// Agent self-update and rollback on one box: the control plane sends
// agent.update, the running agent installs the new release and restarts
// into it when idle, systemd restarts whatever `current` points at, and two
// things roll a bad release back: the connection's watchdog (a release that
// hasn't joined) and the systemd rollback unit (a crash loop that hits the
// start limit). The new release's behaviour is chosen at the start, and the
// network comes and goes.
//
//   quint run updates.qnt --invariant=allInvariants --max-samples=30000 --max-steps=80
//
// Code it follows:
//   apps/foreman_agent/lib/foreman_agent/updater.ex     install/swap, confirm, rollback_due?, rollback
//   apps/foreman_agent/lib/foreman_agent/connection.ex  confirm on join, the update watchdog
//   apps/foreman_agent/lib/foreman_agent/handler.ex     agent.update, restart_when_idle
//   apps/foreman/priv/agent/install.sh                  Restart=always, StartLimitBurst=5 in 120s,
//                                                       OnFailure=foreman-agent-rollback
//   apps/foreman/lib/foreman/agents/releases.ex         maybe_update, settle_updates, update_failed
//
// Modelling choices:
//   - A tick is about a minute. What happens within seconds (systemd's restart,
//     a crash at boot, a join, the watchdog's check, the rollback unit) happens
//     before the clock moves: tick waits while any of it is due.
//   - The control plane's grace periods are shortened (they only need to be
//     longer than the box's own recovery).
//   - Environments aren't modelled, so the old agent is idle as soon as it has
//     installed the update.
//
// The FIX_* switches turn on proposed fixes. With all of them off this is
// the code as of v0.4.3.
module updates {
  // ------------------------------------------------------------------ parameters
  pure val BURST = 5               // StartLimitBurst
  pure val WINDOW = 2              // StartLimitIntervalSec, in ticks
  pure val WATCHDOG = 5            // @rollback_after
  pure val SLOW_CRASH_AFTER = 2    // a SlowCrash release dies this long after starting
  pure val CP_GRACE = 6            // @update_grace_seconds, shortened
  pure val CP_RESTART_GRACE = 8    // @restart_grace_seconds, shortened
  pure val ROLLBACK_BOUND = WATCHDOG + 3
  pure val MAX_TIME = 40
  // #24: the agent confirms a release once it has stayed up and joined for
  // CONFIRM_AFTER, not as soon as it joins, and the control plane counts the
  // update as done when the agent confirms, not when it first joins.
  pure val FIX_CONFIRM = false
  pure val CONFIRM_AFTER = 3
  // #24: the watchdog times a release by how long it has run without
  // joining since it was installed, added up across restarts (kept in
  // `update-pending`). Today every restart restarts its clock, so a release
  // that dies every couple of minutes is never rolled back. (Counting starts
  // instead looks simpler, but fires in the middle of a fast crash loop: the
  // watchdog's own exit then hits the start limit, with `previous` already
  // used up, and strands the old release.)
  pure val FIX_WATCHDOG = false
  // The rollback unit resets the failure and starts the agent again even
  // when there's no `previous` to switch to. Today it gives up, so the
  // watchdog's own exit landing on a used-up start limit strands the box,
  // even on a good release.
  pure val FIX_ROLLBACK_UNIT = false

  pure val NONE = -1

  // ------------------------------------------------------------------ types
  type Quality = Good | CrashAtBoot | SlowCrash | NoJoin | CrashAfterJoin
  type Life = { ver: int, since: int, joined: bool, joinedAt: int, restartScheduled: bool }
  type Proc = Down | Up(Life) | Failed
  type Update = NoUpdate | Active({ dispatchedAt: int, restartAt: int })
  type Reply = NoReply | RestartReply | ErrorReply

  type State = {
    now: int,
    quality: Quality,                 // how release 1 behaves
    netUp: bool,
    // the box
    current: int,
    previous: int,                    // NONE: no `previous` link
    pendingAt: int,                   // NONE: no `update-pending` marker
    pendingRun: int,                  // unjoined run time since the install (FIX_WATCHDOG)
    proc: Proc,
    starts: List[int],                // systemd's recent start times
    // the control plane
    online: bool,
    boxVersion: int,                  // the version the agent last joined with
    update: Update,
    failures: int,                    // updates to 1 that failed in a row
    failedVersion: bool,              // 1 failed twice: not sent again
    // the wire
    cmdPending: bool,                 // agent.update on its way
    reply: Reply,                     // the update's result on its way back
    // ghosts
    installs: int,
    v1Started: int,                   // first start of release 1 since it was installed
    cpSucceeded: bool,
    stranded: bool,
  }

  var st: State

  // ------------------------------------------------------------------ helpers
  pure def maxi(a: int, b: int): int = if (a > b) a else b

  def lifeOf(s: State): Life = match s.proc { | Up(l) => l | _ => { ver: NONE, since: 0, joined: false, joinedAt: 0, restartScheduled: false } }
  def isUp(s: State): bool = match s.proc { | Up(_) => true | _ => false }

  // Whether release v ever joins, and when the running life crashes.
  def joins(s: State, v: int): bool =
    v == 0 or s.quality == Good or s.quality == CrashAfterJoin
  def crashDue(s: State): bool = isUp(s) and {
    val l = lifeOf(s)
    l.ver == 1 and (match s.quality {
      | CrashAtBoot => true
      | SlowCrash => s.now - l.since >= SLOW_CRASH_AFTER
      | CrashAfterJoin => l.joined
      | _ => false
    })
  }

  def canJoin(s: State): bool = isUp(s) and s.netUp and not(lifeOf(s).joined) and joins(s, lifeOf(s).ver)

  // Updater.rollback_due?: only the release `current` points at, an update
  // not confirmed, a release to go back to, and the grace period run out,
  // timed from the later of the install and this start.
  def watchdogDue(s: State): bool = isUp(s) and {
    val l = lifeOf(s)
    not(l.joined) and l.ver == s.current and s.pendingAt != NONE and s.previous != NONE and (
      s.now - maxi(s.pendingAt, l.since) >= WATCHDOG
      or (FIX_WATCHDOG and s.pendingRun >= WATCHDOG))
  }

  def confirmDue(s: State): bool = FIX_CONFIRM and isUp(s) and {
    val l = lifeOf(s)
    l.joined and l.ver == s.current and s.pendingAt != NONE and s.now - l.joinedAt >= CONFIRM_AFTER
  }

  def recentStarts(s: State): int = s.starts.select(t => s.now - t < WINDOW).length()

  // Updater.confirm: the release `current` points at has joined, so there's
  // nothing to go back to any more.
  pure def confirmed(s: State): State =
    { ...s, previous: NONE, pendingAt: NONE, pendingRun: 0 }

  // ------------------------------------------------------------------ init
  action init = {
    nondet q = Set(Good, CrashAtBoot, SlowCrash, NoJoin, CrashAfterJoin).oneOf()
    st' = {
      now: 0,
      quality: q,
      netUp: true,
      current: 0,
      previous: NONE,
      pendingAt: NONE,
      pendingRun: 0,
      proc: Up({ ver: 0, since: 0, joined: true, joinedAt: 0, restartScheduled: false }),
      starts: List(0),
      online: true,
      boxVersion: 0,
      update: NoUpdate,
      failures: 0,
      failedVersion: false,
      cmdPending: false,
      reply: NoReply,
      installs: 0,
      v1Started: NONE,
      cpSucceeded: false,
      stranded: false,
    }
  }

  // ------------------------------------------------------------------ the box: systemd

  // Restart=always: whatever `current` points at, unless the start limit is hit,
  // which fails the unit and runs OnFailure (the rollback unit).
  action systemdStart = all {
    st.proc == Down,
    if (recentStarts(st) >= BURST)
      st' = { ...st, proc: Failed }
    else
      st' = { ...st,
        proc: Up({ ver: st.current, since: st.now, joined: false, joinedAt: 0, restartScheduled: false }),
        starts: st.starts.append(st.now),
        v1Started: if (st.current == 1 and st.v1Started == NONE) st.now else st.v1Started },
  }

  // foreman-agent-rollback.service: back to `previous` if there is one;
  // otherwise the agent stays down until someone fixes the box.
  action rollbackUnit = all {
    st.proc == Failed,
    not(st.stranded),
    if (st.previous != NONE)
      st' = { ...st, current: st.previous, previous: NONE, pendingAt: NONE, pendingRun: 0,
              proc: Down, starts: List(), v1Started: NONE }
    else if (FIX_ROLLBACK_UNIT)
      st' = { ...st, proc: Down, starts: List() }
    else
      st' = { ...st, stranded: true },
  }

  action crash = all {
    crashDue(st),
    st' = { ...st, proc: Down, online: false, cmdPending: false, reply: NoReply },
  }

  // ------------------------------------------------------------------ the box: the agent

  // Connection.handle_join: confirm, then the control plane's agent_connected
  // records the version and settles an update that's arrived.
  action join = all {
    canJoin(st),
    val l = lifeOf(st)
    val s1 = { ...st, proc: Up({ ...l, joined: true, joinedAt: st.now }), online: true, boxVersion: l.ver }
    val s2 = if (not(FIX_CONFIRM) and s1.pendingAt != NONE and s1.current == l.ver) confirmed(s1) else s1
    // settle_updates: done if it's on the version it was sent. With
    // FIX_CONFIRM, only once the agent has confirmed it.
    val done = match s2.update {
      | Active(_) => l.ver == 1 and (not(FIX_CONFIRM) or s2.pendingAt == NONE)
      | NoUpdate => false
    }
    st' = if (done) { ...s2, update: NoUpdate, failures: 0, cpSucceeded: true } else s2,
  }

  // FIX_CONFIRM: confirmed once it has stayed joined for CONFIRM_AFTER, and
  // the control plane hears it.
  action confirmLate = all {
    confirmDue(st),
    val s1 = confirmed(st)
    val done = match s1.update { | Active(_) => s1.online | NoUpdate => false }
    st' = if (done) { ...s1, update: NoUpdate, failures: 0, cpSucceeded: true } else s1,
  }

  // The connection's update watchdog: roll back and exit.
  action watchdog = all {
    watchdogDue(st),
    st' = { ...st, current: st.previous, previous: NONE, pendingAt: NONE, pendingRun: 0,
            proc: Down, online: false, cmdPending: false, reply: NoReply, v1Started: NONE },
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
            pendingRun: 0,
            current: 1,
            installs: s1.installs + 1,
            v1Started: NONE,
            reply: RestartReply,
            proc: Up({ ...l, restartScheduled: true }) }
        },
    }
  }

  // restart_when_idle: exit 0 so systemd starts the new release.
  action agentRestart = all {
    isUp(st),
    lifeOf(st).restartScheduled,
    st' = { ...st, proc: Down, online: false, cmdPending: false, reply: NoReply },
  }

  // ------------------------------------------------------------------ the network

  action netDown = all {
    st.netUp,
    st' = { ...st, netUp: false, online: false, cmdPending: false, reply: NoReply,
            proc: if (isUp(st)) Up({ ...lifeOf(st), joined: false }) else st.proc },
  }

  action netBack = all {
    not(st.netUp),
    st' = { ...st, netUp: true },
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
    s.proc == Down,
    s.proc == Failed and not(s.stranded),
    crashDue(s),
    canJoin(s),
    watchdogDue(s),
    confirmDue(s),
    s.cmdPending and s.online,
    s.reply != NoReply and s.online,
  }

  action tick = all {
    st.now < MAX_TIME,
    not(urgent(st)),
    val l = lifeOf(st)
    val unjoinedPending = isUp(st) and not(l.joined) and l.ver == st.current and st.pendingAt != NONE
    st' = { ...st, now: st.now + 1,
            pendingRun: if (unjoinedPending) st.pendingRun + 1 else st.pendingRun },
  }

  action step = any {
    systemdStart, rollbackUnit, crash,
    join, confirmLate, watchdog, agentInstall, agentRestart,
    netDown, netBack,
    cpMaybeUpdate, cpReply, cpSettleOverdue,
    tick,
  }

  // ------------------------------------------------------------------ properties

  // #24. The agent is never left failed with nothing to roll back to, which
  // needs someone on the box.
  val neverStranded = not(st.stranded)

  // A release that misbehaves is never confirmed (the rollback state deleted).
  val badNeverKept = st.quality != Good implies not(st.current == 1 and st.pendingAt == NONE)

  // A release that can't join is rolled back soon after it first starts.
  val rollbackInTime =
    (Set(CrashAtBoot, SlowCrash, NoJoin).contains(st.quality) and st.current == 1 and st.v1Started != NONE)
      implies st.now - st.v1Started <= ROLLBACK_BOUND

  // A bad version is sent and installed at most twice before the control
  // plane stops sending it.
  val boundedRetries = st.installs <= 2

  // An update the control plane called done stays done.
  val succeededSticks = st.cpSucceeded implies st.current == 1

  val allInvariants = and {
    neverStranded,
    badNeverKept,
    rollbackInTime,
    boundedRetries,
    succeededSticks,
  }
}
