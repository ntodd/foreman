// Agent self-update and rollback on one box: the control plane sends
// agent.update, the running agent installs the new release and restarts
// into it when idle, systemd restarts whatever `current` points at, and two
// things roll a bad release back: the connection's watchdog (a release that
// hasn't joined) and the systemd rollback unit (OnFailure). The new
// release's behaviour is chosen at the start, and the network comes and goes.
//
//   quint run updates.qnt --invariant=allInvariants --max-samples=30000 --max-steps=80
//
// Code it follows:
//   apps/foreman_agent/lib/foreman_agent/updater.ex     install/swap, confirm, rollback_due?, rollback
//   apps/foreman_agent/lib/foreman_agent/connection.ex  confirm on join, the update watchdog
//   apps/foreman_agent/lib/foreman_agent/handler.ex     agent.update, restart_when_idle
//   apps/foreman_agent/lib/foreman_agent/outbox.ex      the update's result kept across a disconnect
//   apps/foreman/priv/agent/install.sh                  Restart=always, StartLimitBurst=5 in 120s,
//                                                       OnFailure=foreman-agent-rollback
//   apps/foreman/lib/foreman/agents/releases.ex         maybe_update, settle_updates, update_failed
//
// Modelling choices:
//   - A tick is about a minute. What happens within seconds (systemd's restart,
//     a crash at boot, a join, the watchdog's check every 30s, the rollback
//     unit, an idle agent restarting into an update) happens before the clock
//     moves: tick waits while any of it is due.
//   - A release that joins and then crashes does so within CRASH_AFTER_JOIN
//     of first joining, connected or not.
//     FIX_CONFIRM's probation (CONFIRM_AFTER) is longer; a release that
//     crashes after it's confirmed isn't modelled.
//   - The control plane's grace periods are shortened (they only need to be
//     longer than the box's own recovery).
//   - Environments aren't modelled, so the old agent is idle as soon as it has
//     installed the update.
//
// SYSTEMD_254 picks systemd's behaviour. From 254 (Ubuntu 24.04 has 255), a
// failed exit of a Restart=always unit goes through the failed state and runs
// OnFailure every time. Before (Ubuntu 22.04 has 249, Debian 12 has 252),
// OnFailure only runs once the start limit is hit. Foreman supports both.
//
// The FIX_* switches turn on proposed fixes. With all of them off this is
// the code as of v0.4.3.
module updates {
  // ------------------------------------------------------------------ parameters
  pure val SYSTEMD_254 = false
  pure val BURST = 5               // StartLimitBurst
  pure val WINDOW = 2              // StartLimitIntervalSec, in ticks
  pure val WATCHDOG = 5            // @rollback_after
  pure val SLOW_CRASH_AFTER = 2    // a SlowCrash release dies this long after starting
  pure val CRASH_AFTER_JOIN = 1    // a CrashAfterJoin release dies within this of joining
  pure val CP_GRACE = 6            // @update_grace_seconds, shortened
  pure val CP_RESTART_GRACE = 8    // @restart_grace_seconds, shortened
  pure val CONFIRM_AFTER = 3       // FIX_CONFIRM's probation
  pure val BACK_ONLINE = WATCHDOG + CONFIRM_AFTER + 2
  pure val SETTLE = WATCHDOG + CONFIRM_AFTER + 2
  pure val MAX_TIME = 40
  pure val MAX_OUTAGES = 3         // the network drops at most this many times
  // #24: the agent confirms a release once this run of it has stayed up for
  // CONFIRM_AFTER since it first joined, not as soon as it joins. Measured
  // from the first join and not reset by a reconnect: probation that every
  // reconnect restarts never ends on a flaky network. The control plane counts the
  // update as done when the agent confirms (it hears at once if connected,
  // else from the next join, which says whether an update is still pending),
  // not when it first joins.
  pure val FIX_CONFIRM = false
  // #24: the watchdog rolls back a release that isn't confirmed yet once it
  // has run WATCHDOG without joining since it was installed, added up across
  // restarts, or, checked at boot before it connects, has started more than
  // MAX_UNCONFIRMED_STARTS times since (both kept in `update-pending`). Today every restart restarts its clock, so
  // before systemd 254 a release that dies every couple of minutes is never
  // rolled back, and one that joins and crashes each time never is either:
  // too slow for the start limit, and it joins. (The watchdog's own exit can
  // land on a used-up start limit; FIX_ROLLBACK_UNIT is what makes that safe.)
  pure val FIX_WATCHDOG = false
  pure val MAX_UNCONFIRMED_STARTS = 3
  // The rollback unit resets the failure and starts the agent again even
  // when there's no `previous` to switch to. Today it gives up, so the
  // watchdog's own exit landing on a used-up start limit strands the box,
  // even on a good release.
  pure val FIX_ROLLBACK_UNIT = false

  pure val NONE = -1

  // ------------------------------------------------------------------ types
  type Quality = Good | CrashAtBoot | SlowCrash | NoJoin | CrashAfterJoin
  type Life = { ver: int, since: int, joined: bool, joinedAt: int, firstJoinedAt: int, restartScheduled: bool }
  type Proc = Down | Up(Life) | Failed
  type Update = NoUpdate | Active({ dispatchedAt: int, restartAt: int })
  type Reply = NoReply | RestartReply | ErrorReply

  type State = {
    now: int,
    quality: Quality,                 // how release 1 behaves
    netUp: bool,
    outages: int,
    // the box
    current: int,
    previous: int,                    // NONE: no `previous` link
    pendingAt: int,                   // NONE: no `update-pending` marker
    pendingRun: int,                  // unjoined run time since the install (FIX_WATCHDOG)
    pendingStarts: int,               // starts since the install (FIX_WATCHDOG)
    proc: Proc,
    limitStart: int,                  // systemd's start limit: when its window began
    limitCount: int,                  //   and the starts in it
    onFailure: bool,                  // OnFailure queued (the rollback unit)
    // the control plane
    online: bool,
    boxVersion: int,                  // the version the agent last joined with
    update: Update,
    failures: int,                    // updates to 1 that failed in a row
    failedVersion: bool,              // 1 failed twice: not sent again
    // the wire
    cmdPending: bool,                 // agent.update on its way (lost on disconnect)
    reply: Reply,                     // its result, in the outbox until the control plane has it
    // ghosts
    installs: int,
    cpSucceeded: bool,
    stranded: bool,                   // the rollback unit gave up on a failed agent
    netUpSince: int,
    lastOnline: int,
  }

  var st: State

  // ------------------------------------------------------------------ helpers
  pure def maxi(a: int, b: int): int = if (a > b) a else b

  def lifeOf(s: State): Life = match s.proc { | Up(l) => l | _ => { ver: NONE, since: 0, joined: false, joinedAt: 0, firstJoinedAt: NONE, restartScheduled: false } }
  def isUp(s: State): bool = match s.proc { | Up(_) => true | _ => false }

  def joins(s: State, v: int): bool =
    v == 0 or s.quality == Good or s.quality == CrashAfterJoin

  // When the running life may crash, and when it must have.
  def crashCan(s: State): bool = isUp(s) and {
    val l = lifeOf(s)
    l.ver == 1 and (match s.quality {
      | CrashAtBoot => true
      | SlowCrash => s.now - l.since >= SLOW_CRASH_AFTER
      | CrashAfterJoin => l.firstJoinedAt != NONE
      | _ => false
    })
  }
  def crashDue(s: State): bool = crashCan(s) and (match s.quality {
    | CrashAfterJoin => s.now - lifeOf(s).firstJoinedAt >= CRASH_AFTER_JOIN
    | _ => true
  })

  // FIX_WATCHDOG's boot check: before connecting, an unconfirmed release that
  // has started too many times since the install rolls back.
  def bootCapHit(s: State): bool = FIX_WATCHDOG and isUp(s) and {
    val l = lifeOf(s)
    l.since == s.now and l.firstJoinedAt == NONE and l.ver == s.current
      and s.pendingAt != NONE and s.previous != NONE and s.pendingStarts > MAX_UNCONFIRMED_STARTS
  }

  def canJoin(s: State): bool =
    isUp(s) and s.netUp and not(lifeOf(s).joined) and joins(s, lifeOf(s).ver) and not(bootCapHit(s))

  // Updater.rollback_due?: only the release `current` points at, an update
  // not confirmed, a release to go back to, and the grace period run out,
  // timed from the later of the install and this start.
  //
  // FIX_WATCHDOG's start cap is checked at boot, before the connection joins:
  // the watchdog itself only looks while the agent isn't joined, and a
  // release that joins and then crashes is joined by its first check.
  def watchdogDue(s: State): bool = isUp(s) and {
    val l = lifeOf(s)
    l.ver == s.current and s.pendingAt != NONE and s.previous != NONE and (
      if (FIX_WATCHDOG) (not(l.joined) and s.pendingRun >= WATCHDOG) or bootCapHit(s)
      else not(l.joined) and s.now - maxi(s.pendingAt, l.since) >= WATCHDOG)
  }

  def confirmDue(s: State): bool = FIX_CONFIRM and isUp(s) and {
    val l = lifeOf(s)
    l.firstJoinedAt != NONE and l.ver == s.current and s.pendingAt != NONE
      and s.now - l.firstJoinedAt >= CONFIRM_AFTER
  }

  // Updater.confirm: nothing to go back to any more.
  pure def confirmed(s: State): State =
    { ...s, previous: NONE, pendingAt: NONE, pendingRun: 0, pendingStarts: 0 }

  // The process ends. A failed exit (a crash, the watchdog's System.stop(1))
  // runs OnFailure from systemd 254; a clean one (restart_when_idle) doesn't.
  // The outbox goes with the process.
  pure def exited(s: State, failed: bool): State = { ...s,
    proc: Down, online: false, cmdPending: false, reply: NoReply,
    onFailure: s.onFailure or (failed and SYSTEMD_254) }

  // ------------------------------------------------------------------ init
  action init = {
    nondet q = Set(Good, CrashAtBoot, SlowCrash, NoJoin, CrashAfterJoin).oneOf()
    st' = {
      now: 0,
      quality: q,
      netUp: true,
      outages: 0,
      current: 0,
      previous: NONE,
      pendingAt: NONE,
      pendingRun: 0,
      pendingStarts: 0,
      proc: Up({ ver: 0, since: 0, joined: true, joinedAt: 0, firstJoinedAt: 0, restartScheduled: false }),
      limitStart: 0,
      limitCount: 1,
      onFailure: false,
      online: true,
      boxVersion: 0,
      update: NoUpdate,
      failures: 0,
      failedVersion: false,
      cmdPending: false,
      reply: NoReply,
      installs: 0,
      cpSucceeded: false,
      stranded: false,
      netUpSince: 0,
      lastOnline: 0,
    }
  }

  // ------------------------------------------------------------------ the box: systemd

  // Restart=always: start whatever `current` points at. The start limit is a
  // counter in a window that starts with its first start; the sixth start in
  // a window fails the unit, which runs OnFailure.
  action systemdStart = all {
    st.proc == Down,
    not(st.onFailure),
    val fresh = st.now - st.limitStart >= WINDOW
    val count = if (fresh) 0 else st.limitCount
    if (count >= BURST)
      st' = { ...st, proc: Failed, onFailure: true }
    else
      st' = { ...st,
        proc: Up({ ver: st.current, since: st.now, joined: false, joinedAt: 0, firstJoinedAt: NONE, restartScheduled: false }),
        limitStart: if (fresh) st.now else st.limitStart,
        limitCount: count + 1,
        pendingStarts: if (st.pendingAt != NONE) st.pendingStarts + 1 else st.pendingStarts },
  }

  // foreman-agent-rollback.service: back to `previous` if there is one, then
  // reset-failed and start. Otherwise it only prints a message, and a failed
  // agent stays down until someone fixes the box (FIX_ROLLBACK_UNIT: it
  // resets and starts anyway).
  action rollbackUnit = all {
    st.onFailure,
    val failedUnit = st.proc == Failed
    if (st.previous != NONE)
      st' = { ...st, onFailure: false, current: st.previous, previous: NONE, pendingAt: NONE,
              pendingRun: 0, pendingStarts: 0, limitCount: 0, limitStart: st.now,
              proc: if (failedUnit) Down else st.proc }
    else if (FIX_ROLLBACK_UNIT)
      st' = { ...st, onFailure: false, limitCount: 0, limitStart: st.now,
              proc: if (failedUnit) Down else st.proc }
    else
      st' = { ...st, onFailure: false, stranded: st.stranded or failedUnit },
  }

  action crash = all {
    crashCan(st),
    st' = exited(st, true),
  }

  // ------------------------------------------------------------------ the box: the agent

  // Connection.handle_join: confirm, then the control plane's agent_connected
  // records the version and settles an update that's arrived.
  action join = all {
    canJoin(st),
    val l = lifeOf(st)
    val s1 = { ...st, proc: Up({ ...l, joined: true, joinedAt: st.now,
                                 firstJoinedAt: if (l.firstJoinedAt == NONE) st.now else l.firstJoinedAt }),
               online: true,
               boxVersion: l.ver, lastOnline: st.now }
    val s2 = if (not(FIX_CONFIRM) and s1.pendingAt != NONE and s1.current == l.ver) confirmed(s1) else s1
    // settle_updates: done if it's on the version it was sent. With
    // FIX_CONFIRM, only once the agent has confirmed it.
    val done = match s2.update {
      | Active(_) => l.ver == 1 and (not(FIX_CONFIRM) or s2.pendingAt == NONE)
      | NoUpdate => false
    }
    st' = if (done) { ...s2, update: NoUpdate, failures: 0, cpSucceeded: true } else s2,
  }

  // FIX_CONFIRM: confirmed once this run has been up for CONFIRM_AFTER since
  // it first joined. The control plane hears now if connected, else from the next
  // join.
  action confirmLate = all {
    confirmDue(st),
    val s1 = confirmed(st)
    val done = match s1.update { | Active(_) => s1.online | NoUpdate => false }
    st' = if (done) { ...s1, update: NoUpdate, failures: 0, cpSucceeded: true } else s1,
  }

  // The connection's update watchdog: roll back and exit with status 1.
  action watchdog = all {
    watchdogDue(st),
    st' = exited({ ...st, current: st.previous, previous: NONE, pendingAt: NONE, pendingRun: 0, pendingStarts: 0 }, true),
  }

  // Handler: agent.update arrives at the running agent. Updater.run installs
  // (or finds it installed), or fails (a download cut short, a full disk).
  action agentInstall = {
    nondet ok = Set(true, false).oneOf()
    all {
      st.cmdPending,
      st.online,
      isUp(st),
      lifeOf(st).joined,
      val l = lifeOf(st)
      val s1 = { ...st, cmdPending: false }
      st' =
        if (s1.current == 1)
          // Already installed: restart if this isn't it.
          { ...s1, reply: if (l.ver != 1) RestartReply else NoReply,
                   proc: Up({ ...l, restartScheduled: l.ver != 1 }) }
        else if (not(ok))
          { ...s1, reply: ErrorReply }
        else {
          // swap: `previous` is the last release that joined, so not one
          // still waiting to.
          val unconfirmed = s1.pendingAt != NONE and s1.previous != NONE
          { ...s1,
            previous: if (unconfirmed) s1.previous else s1.current,
            pendingAt: s1.now,
            pendingRun: 0, pendingStarts: 0,
            current: 1,
            installs: s1.installs + 1,
            reply: RestartReply,
            proc: Up({ ...l, restartScheduled: true }) }
        },
    }
  }

  // restart_when_idle: exit 0 so systemd starts the new release. It waits
  // for the outbox to settle, so the result has gone out first.
  action agentRestart = all {
    isUp(st),
    lifeOf(st).restartScheduled,
    st.reply == NoReply or not(st.online),
    st' = exited(st, false),
  }

  // ------------------------------------------------------------------ the network

  action netDown = all {
    st.netUp,
    st.outages < MAX_OUTAGES,
    st' = { ...st, netUp: false, outages: st.outages + 1, online: false, cmdPending: false,
            proc: if (isUp(st)) Up({ ...lifeOf(st), joined: false }) else st.proc },
  }

  action netBack = all {
    not(st.netUp),
    st' = { ...st, netUp: true, netUpSince: st.now },
  }

  // ------------------------------------------------------------------ the control plane

  // Releases.maybe_update (on join and from the minutely check).
  action cpMaybeUpdate = all {
    st.online,
    st.boxVersion != 1,
    not(st.failedVersion),
    st.update == NoUpdate,
    st' = { ...st, update: Active({ dispatchedAt: st.now, restartAt: NONE }), cmdPending: true },
  }

  // The update's result: a reported restart isn't the end of it; an error is
  // a failure.
  action cpReply = all {
    st.online,
    st.reply != NoReply,
    st' = match st.update {
      | Active(u) =>
          if (st.reply == RestartReply)
            { ...st, reply: NoReply, update: Active({ ...u, restartAt: st.now }) }
          else
            { ...st, reply: NoReply, update: NoUpdate, failures: st.failures + 1,
                     failedVersion: st.failures + 1 >= 2 }
      | NoUpdate => { ...st, reply: NoReply }
    },
  }

  // settle_updates: not back on the new version within the grace period.
  action cpSettleOverdue = all {
    match st.update {
      | Active(u) =>
          if (u.restartAt == NONE) st.now - u.dispatchedAt > CP_GRACE
          else st.now - u.restartAt > CP_RESTART_GRACE
      | NoUpdate => false
    },
    st' = { ...st, update: NoUpdate, failures: st.failures + 1, failedVersion: st.failures + 1 >= 2 },
  }

  // ------------------------------------------------------------------ time

  // What happens within seconds happens before the clock moves.
  def urgent(s: State): bool = or {
    s.proc == Down and not(s.onFailure),
    s.onFailure,
    crashDue(s),
    canJoin(s),
    watchdogDue(s),
    confirmDue(s),
    isUp(s) and lifeOf(s).restartScheduled and (s.reply == NoReply or not(s.online)),
    s.cmdPending and s.online,
    s.reply != NoReply and s.online,
  }

  action tick = all {
    st.now < MAX_TIME,
    not(urgent(st)),
    val l = lifeOf(st)
    val unjoinedPending = isUp(st) and not(l.joined) and l.ver == st.current and st.pendingAt != NONE
    st' = { ...st, now: st.now + 1,
            pendingRun: if (unjoinedPending) st.pendingRun + 1 else st.pendingRun,
            lastOnline: if (st.online) st.now + 1 else st.lastOnline },
  }

  action step = any {
    systemdStart, rollbackUnit, crash,
    join, confirmLate, watchdog, agentInstall, agentRestart,
    netDown, netBack,
    cpMaybeUpdate, cpReply, cpSettleOverdue,
    tick,
  }

  // ------------------------------------------------------------------ properties

  // #24. With the network up, the agent is back online within BACK_ONLINE:
  // nothing leaves it down (stranded by the rollback unit) or stuck on a
  // release that never joins.
  val backOnline =
    (st.netUp and st.now - st.netUpSince >= BACK_ONLINE) implies st.now - st.lastOnline <= BACK_ONLINE

  // An installed update is confirmed or rolled back within SETTLE.
  val updateSettles = st.pendingAt != NONE implies st.now - st.pendingAt <= SETTLE

  // A release that misbehaves is never confirmed (the rollback state deleted).
  val badNeverKept = st.quality != Good implies not(st.current == 1 and st.pendingAt == NONE)

  // A bad version is installed at most twice before the control plane stops
  // sending it. (Counts installs, not sends: a send that fails to install
  // counts toward the two failures too.)
  val boundedInstalls = st.installs <= 2

  // An update the control plane called done stays installed. (Whether the
  // box is healthy on it is backOnline's and badNeverKept's to say.)
  val succeededSticks = st.cpSucceeded implies st.current == 1

  val allInvariants = and {
    backOnline,
    updateSettles,
    badNeverKept,
    boundedInstalls,
    succeededSticks,
  }

  // Witnesses, expected to be violated: the paths the properties are about
  // are reached.
  val noRollbacks = st.installs == 0 or st.current == 1 or st.quality == Good
  val noUpdates = not(st.cpSucceeded)
}
