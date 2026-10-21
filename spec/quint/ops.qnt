// The life of one environment's operations between the control plane and a
// box's agent: dispatch, resend after a reconnect, the agent's dedupe and
// per-environment queue, cancel, Housekeeping's timeout, and results held
// in the agent's outbox until acknowledged. Failures are disconnects,
// agent crashes (its in-memory state is lost) and time passing.
//
//   quint run ops.qnt --invariant=allInvariants --max-samples=30000 --max-steps=40
//
// Code it follows (apps/foreman unless noted):
//   lib/foreman/environments/server.ex    dispatch_next, do_resend, resend_op
//   lib/foreman/agents.ex                 agent_connected, cancel_operation, handle_event
//   lib/foreman/operations.ex             claim, finish (a late result beats a timeout), timed_out
//   lib/foreman/jobs/housekeeping.ex      fail_stale_environment_ops
//   foreman_agent/lib/foreman_agent/ops.ex      submit, cancel, finish
//   foreman_agent/lib/foreman_agent/outbox.ex   results redelivered on attach until acked
//
// Modelling choices:
//   - One environment, so the agent has one queue. Box commands aren't modelled;
//     op.cancel is only a message.
//   - Time is in coarse steps (STALE of them is Housekeeping's three hours).
//     Messages and casts land within a step: the clock only moves when nothing
//     is in flight.
//   - The agent's done-map is unbounded (the real one keeps 500).
//
// The FIX_* switches are the fixes for #31 and #95, on as in the code.
// With both off this is the code as of v0.4.3.
module ops {
  // ------------------------------------------------------------------ parameters
  pure val N_OPS = 3
  pure val STALE = 3
  pure val MAX_TIME = 9
  // #31: the join restarts Housekeeping's clock (dispatched_at), before the
  // box counts as online, for what's about to be resent and isn't in the
  // agent's in_flight (what it lost in a restart). What it kept keeps its
  // clock.
  pure val FIX_RESEND_CLOCK = true
  // #95: a cancel survives a reconnect. The control plane remembers it was
  // asked for (args.cancel_requested), a resend sends the cancel instead of
  // the command, and the agent records a cancel for an op it doesn't know (a
  // tombstone in its done-map) and reports it cancelled.
  pure val FIX_CANCEL = true

  pure val OPS = 0.to(N_OPS - 1)

  // ------------------------------------------------------------------ types
  type Status = Queued | Dispatched | Running | Succeeded | Failed | Cancelled
  type Outcome = Ok | Err | Killed            // Killed: reported with the error "cancelled"
  // cancelRequested is args.cancel_requested (FIX_CANCEL).
  type OpRec = { status: Status, timedOut: bool, dispatchedAt: int, cancelRequested: bool }
  type ToAgent = Cmd(int) | CancelMsg(int)
  type ToCP = Accepted(int) | Result({ op: int, out: Outcome })
  type Slot = Idle | Run(int) | Drain         // Drain: a cancelled op's processes being killed

  type State = {
    now: int,
    // control plane
    ops: int -> OpRec,                // operations created so far
    nextOp: int,
    online: bool,                     // the agent's channel is registered
    resendPending: Set[int],          // agent_connected's casts to the environment server
    // the wire (lost on disconnect)
    toAgent: List[ToAgent],
    toCP: List[ToCP],
    // agent
    agentUp: bool,
    known: Set[int],                  // queued or running
    queue: List[int],
    slot: Slot,
    done: int -> Outcome,             // results kept to answer a repeat
    unacked: int -> Outcome,          // outbox: results not acknowledged yet
    // ghosts
    heldSince: int -> int,            // when this agent life took the op on (kept across
                                      // disconnects and after it finishes; a crash clears it)
    startedThisLife: Set[int],
    userCancelled: Set[int],          // a user sent op.cancel for it
    agentToldToStop: Set[int],        // an agent (any life) has received op.cancel for it
    ranOk: Set[int],                  // the agent finished it successfully at some point
    prematureTimeout: bool,
    ranTwice: bool,
    resentAfterCancel: bool,
    startedAfterStop: bool,
    // witnesses: the paths the properties are about do happen
    startedEver: Set[int],
    everTimedOut: bool,
    everTombstoned: bool,
    everRerun: bool,
  }

  var st: State

  // ------------------------------------------------------------------ helpers
  pure def active(o: OpRec): bool = o.status == Dispatched or o.status == Running
  pure def finished(o: OpRec): bool = Set(Succeeded, Failed, Cancelled).contains(o.status)
  pure def without(m: int -> a, k: int): int -> a = m.keys().exclude(Set(k)).mapBy(x => m.get(x))
  pure def statusOf(out: Outcome): Status = match out {
    | Ok => Succeeded
    | Err => Failed
    | Killed => Cancelled
  }

  def activeOps(s: State): Set[int] = s.ops.keys().filter(k => active(s.ops.get(k)))

  // ForemanAgent.Ops: remember the result and hand it to the outbox, which
  // sends it now if connected and keeps it until acknowledged.
  pure def emitResult(s: State, k: int, out: Outcome): State = {
    ...s,
    known: s.known.exclude(Set(k)),
    done: s.done.put(k, out),
    unacked: s.unacked.put(k, out),
    toCP: if (s.online) s.toCP.append(Result({ op: k, out: out })) else s.toCP,
  }

  // op.accepted isn't kept for a later connection.
  pure def emitAccepted(s: State, k: int): State =
    if (s.online) { ...s, toCP: s.toCP.append(Accepted(k)) } else s

  // ------------------------------------------------------------------ init
  action init = st' = {
    now: 0,
    ops: Map(),
    nextOp: 0,
    online: true,
    resendPending: Set(),
    toAgent: List(),
    toCP: List(),
    agentUp: true,
    known: Set(),
    queue: List(),
    slot: Idle,
    done: Map(),
    unacked: Map(),
    heldSince: Map(),
    startedThisLife: Set(),
    userCancelled: Set(),
    agentToldToStop: Set(),
    ranOk: Set(),
    prematureTimeout: false,
    ranTwice: false,
    resentAfterCancel: false,
    startedAfterStop: false,
    startedEver: Set(),
    everTimedOut: false,
    everTombstoned: false,
    everRerun: false,
  }

  // ------------------------------------------------------------------ control plane

  // A user queues an operation (Environments.enqueue).
  action create = all {
    st.nextOp < N_OPS,
    st' = { ...st,
      ops: st.ops.put(st.nextOp,
        { status: Queued, timedOut: false, dispatchedAt: 0, cancelRequested: false }),
      nextOp: st.nextOp + 1 },
  }

  // Server.dispatch_next: nothing in flight, the box online, the oldest queued
  // op is claimed (dispatched_at = now) and sent.
  action dispatchNext = {
    val queued = st.ops.keys().filter(k => st.ops.get(k).status == Queued)
    all {
      st.online,
      activeOps(st) == Set(),
      queued != Set(),
      val k = queued.fold(N_OPS, (m, x) => if (x < m) x else m)
      st' = { ...st,
        ops: st.ops.set(k, { ...st.ops.get(k), status: Dispatched, dispatchedAt: st.now }),
        toAgent: st.toAgent.append(Cmd(k)) },
    }
  }

  // Server.do_resend: still dispatched or running, so send it again with the
  // same op_id. Nothing is sent if the box went away again.
  action resend = {
    nondet k = OPS.oneOf()
    all {
      st.resendPending.contains(k),
      val stillActive = if (st.ops.keys().contains(k)) active(st.ops.get(k)) else false
      val send = stillActive and st.online
      val cancelInstead = FIX_CANCEL and stillActive and st.ops.get(k).cancelRequested
      st' = { ...st,
        resendPending: st.resendPending.exclude(Set(k)),
        toAgent: if (not(send)) st.toAgent
                 else if (cancelInstead) st.toAgent.append(CancelMsg(k))
                 else st.toAgent.append(Cmd(k)),
        resentAfterCancel: st.resentAfterCancel
          or (send and not(cancelInstead) and st.userCancelled.contains(k)) },
    }
  }

  // Agents.cancel_operation from the UI. Refused while the box is offline.
  action userCancel = {
    nondet k = OPS.oneOf()
    all {
      st.online,
      st.ops.keys().contains(k),
      active(st.ops.get(k)),
      st' = { ...st,
        toAgent: st.toAgent.append(CancelMsg(k)),
        ops: if (FIX_CANCEL) st.ops.set(k, { ...st.ops.get(k), cancelRequested: true }) else st.ops,
        userCancelled: st.userCancelled.union(Set(k)) },
    }
  }

  // Housekeeping.fail_stale_environment_ops: dispatched over STALE ago and the
  // box online, so cancel it on the box and fail it (timed_out). A real
  // result arriving later still replaces this.
  action housekeeping = {
    nondet k = OPS.oneOf()
    all {
      st.online,
      st.ops.keys().contains(k),
      active(st.ops.get(k)),
      st.now - st.ops.get(k).dispatchedAt >= STALE,
      val heldLongEnough =
        if (st.heldSince.keys().contains(k)) st.now - st.heldSince.get(k) >= STALE else false
      st' = { ...st,
        ops: st.ops.set(k, { ...st.ops.get(k), status: Failed, timedOut: true }),
        toAgent: st.toAgent.append(CancelMsg(k)),
        prematureTimeout: st.prematureTimeout or not(heldLongEnough),
        everTimedOut: true },
    }
  }

  // AgentChannel.handle_in("event"): op.accepted marks it running; op.result
  // goes through Operations.finish and is acknowledged.
  action cpReceive = all {
    st.online,
    st.toCP.length() > 0,
    val ev = st.toCP.head()
    val s1 = { ...st, toCP: st.toCP.tail() }
    st' = match ev {
      | Accepted(k) =>
          if (s1.ops.get(k).status == Dispatched)
            { ...s1, ops: s1.ops.set(k, { ...s1.ops.get(k), status: Running }) }
          else s1
      | Result(r) =>
          val o = s1.ops.get(r.op)
          val acked = { ...s1, unacked: without(s1.unacked, r.op) }
          if (finished(o) and not(o.timedOut)) acked   // :already
          else { ...acked,
            ops: acked.ops.set(r.op, { ...o, status: statusOf(r.out), timedOut: false }) }
    },
  }

  // ------------------------------------------------------------------ the connection

  action disconnect = all {
    st.online,
    st' = { ...st, online: false, toAgent: List(), toCP: List() },
  }

  // The agent joins: its outbox redelivers unacknowledged results, and
  // agent_connected resends whatever the control plane has in flight.
  action connect = {
    val inFlight = activeOps(st)
    val lost = inFlight.exclude(st.known)   // not in the join's in_flight
    all {
      st.agentUp,
      not(st.online),
      st' = { ...st,
        online: true,
        toCP: st.unacked.keys().fold(List(), (l, k) => l.append(Result({ op: k, out: st.unacked.get(k) }))),
        resendPending: inFlight,
        ops: if (FIX_RESEND_CLOCK)
               st.ops.keys().mapBy(k =>
                 if (lost.contains(k)) { ...st.ops.get(k), dispatchedAt: st.now } else st.ops.get(k))
             else st.ops },
    }
  }

  // The agent's BEAM dies. Its processes, queue, done-map and outbox go with it.
  action agentCrash = all {
    st.agentUp,
    st' = { ...st,
      agentUp: false, online: false, toAgent: List(), toCP: List(),
      known: Set(), queue: List(), slot: Idle, done: Map(), unacked: Map(),
      heldSince: Map(), startedThisLife: Set() },
  }

  action agentBoot = all {
    not(st.agentUp),
    st' = { ...st, agentUp: true },
  }

  // ------------------------------------------------------------------ agent

  // Connection.handle_message("command") -> Ops.submit
  action agentReceive = all {
    st.online,
    st.agentUp,
    st.toAgent.length() > 0,
    val s1 = { ...st, toAgent: st.toAgent.tail() }
    st' = match st.toAgent.head() {
      | Cmd(k) =>
          if (s1.done.keys().contains(k))
            // A repeat of a finished op gets its stored result.
            emitResult(s1, k, s1.done.get(k))
          else if (s1.known.contains(k))
            emitAccepted(s1, k)
          else
            emitAccepted({ ...s1,
              known: s1.known.union(Set(k)),
              queue: s1.queue.append(k),
              heldSince: s1.heldSince.put(k, s1.now) }, k)
      | CancelMsg(k) =>
          val s2 = { ...s1, agentToldToStop: s1.agentToldToStop.union(Set(k)) }
          if (s2.slot == Run(k))
            emitResult({ ...s2, slot: Drain }, k, Killed)
          else if (s2.queue.indices().exists(i => s2.queue[i] == k))
            emitResult({ ...s2, queue: s2.queue.select(x => x != k) }, k, Killed)
          else if (FIX_CANCEL and not(s2.done.keys().contains(k)))
            { ...emitResult(s2, k, Killed), everTombstoned: true }
          else
            s2   // unknown or finished: nothing to stop
    },
  }

  // Ops.maybe_start: the environment's next op starts once nothing of its own
  // is running or draining.
  action agentStart = all {
    st.agentUp,
    st.slot == Idle,
    st.queue.length() > 0,
    val k = st.queue.head()
    st' = { ...st,
      queue: st.queue.tail(),
      slot: Run(k),
      startedThisLife: st.startedThisLife.union(Set(k)),
      ranTwice: st.ranTwice or st.startedThisLife.contains(k),
      startedAfterStop: st.startedAfterStop or st.agentToldToStop.contains(k),
      startedEver: st.startedEver.union(Set(k)),
      everRerun: st.everRerun or (st.startedEver.contains(k) and not(st.startedThisLife.contains(k))) },
  }

  action agentFinish = {
    nondet out = Set(Ok, Err).oneOf()
    all {
      st.agentUp,
      match st.slot { | Run(_) => true | _ => false },
      val k = match st.slot { | Run(j) => j | _ => -1 }
      val s1 = emitResult({ ...st, slot: Idle }, k, out)
      st' = if (out == Ok) { ...s1, ranOk: s1.ranOk.union(Set(k)) } else s1,
    }
  }

  action drainDone = all {
    st.agentUp,
    st.slot == Drain,
    st' = { ...st, slot: Idle },
  }

  // ------------------------------------------------------------------ time
  // Coarse steps: messages and casts land within one.
  action tick = all {
    st.now < MAX_TIME,
    st.toAgent.length() == 0,
    st.toCP.length() == 0,
    st.resendPending == Set(),
    st' = { ...st, now: st.now + 1 },
  }

  action step = any {
    create, dispatchNext, resend, userCancel, housekeeping, cpReceive,
    disconnect, connect, agentCrash, agentBoot,
    agentReceive, agentStart, agentFinish, drainDone,
    tick,
  }

  // ------------------------------------------------------------------ properties

  // #31. Housekeeping only gives up on an op the agent has had for STALE.
  val noPrematureTimeout = not(st.prematureTimeout)

  // The agent's dedupe: an op runs at most once per agent life. (A crash
  // forgets everything, and a resend then runs it again; that's at-least-once
  // by design.)
  val atMostOncePerLife = not(st.ranTwice)

  // A cancel isn't undone. The control plane never sends the command again
  // for an op a user cancelled, and an agent never starts an op it's been
  // told to stop. (An agent that got the command and then lost the cancel
  // in a disconnect may still run it: it can't know.)
  val noResendAfterCancel = not(st.resentAfterCancel)
  val noStartAfterStop = not(st.startedAfterStop)
  val cancelSticks = noResendAfterCancel and noStartAfterStop

  // Connected, idle, nothing in flight: then nothing is left dispatched or
  // running on the control plane, waiting hours for Housekeeping.
  val quiet = st.online and st.agentUp and st.toAgent.length() == 0 and st.toCP.length() == 0
    and st.resendPending == Set() and st.slot == Idle and st.queue.length() == 0
    and st.unacked.keys() == Set()
  val noStuckWhenQuiet = quiet implies activeOps(st) == Set()

  // The control plane only says succeeded if the agent did it.
  val succeededMeansRan = st.ops.keys().forall(k =>
    st.ops.get(k).status == Succeeded implies st.ranOk.contains(k))

  // A reconnect never gives an op the agent kept running more time: its clock
  // never starts later than when the agent took it on. Otherwise a
  // connection that keeps dropping keeps a hung op alive forever.
  val noEndlessExtension = st.ops.keys().forall(k =>
    (active(st.ops.get(k)) and st.known.contains(k) and st.heldSince.keys().contains(k))
      implies st.ops.get(k).dispatchedAt <= st.heldSince.get(k))

  // Witnesses, expected to be violated: each says a path the properties are
  // about is reachable, so they don't pass for want of it.
  val noTimeouts = not(st.everTimedOut)
  val noTombstones = not(st.everTombstoned)
  val noReruns = not(st.everRerun)

  val allInvariants = and {
    noPrematureTimeout,
    noEndlessExtension,
    atMostOncePerLife,
    cancelSticks,
    noStuckWhenQuiet,
    succeededMeansRan,
  }
}
