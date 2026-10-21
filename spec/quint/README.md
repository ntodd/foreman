# Formal models

`ops.qnt` models one environment's operations between the control plane and a box's agent:
dispatch, resend after a reconnect, the agent's dedupe and queue, cancel, Housekeeping's
three-hour timeout, and results held in the agent's outbox until acknowledged. It also models
failures: disconnects, agent crashes and time passing. The header lists the code each action
follows.

`updates.qnt` models agent self-update and rollback on one box: `agent.update`, the install and
restart into the new release, systemd's restarts and start limit, the connection's watchdog,
the rollback unit, and the control plane settling the update. The new release's behaviour is
picked at the start (good, crashes at boot, crashes slowly without joining, never joins, or
joins and then crashes), and the network comes and goes.

Run them with [Quint](https://quint-lang.org) 0.33 (`npx @informalsystems/quint` works without
installing anything):

```sh
quint run ops.qnt --invariant=allInvariants --max-samples=30000 --max-steps=40
quint run updates.qnt --invariant=allInvariants --max-samples=30000 --max-steps=80
./check.sh   # what both say about the code as it is, and with and without the fixes
```

## Operations (`ops.qnt`)

### What it found

Against v0.4.3 it broke three invariants. The fixes are in the code, and the `FIX_*` switches
model them (on by default; off reproduces v0.4.3).

| Invariant | v0.4.3 | Fix |
|---|---|---|
| `noPrematureTimeout` | Violated: #31. After an outage, Housekeeping fails an op by its original `dispatched_at`, sometimes before the resend has even reached the agent. | `FIX_RESEND_CLOCK`: the join resets `dispatched_at` for ops the agent no longer has, before the box counts as online. Resetting it in `resend_op` (the issue's suggestion) leaves a gap between the reconnect and the resend cast. |
| `noResendAfterCancel` | Violated: #95. A cancel lost in a disconnect isn't retried (box commands aren't resent), and the op is resent and runs anyway. | `FIX_CANCEL`: the operation records `cancel_requested`, and a resend sends the cancel instead of the command. |
| `noStartAfterStop` | Violated: #95. A cancel that reaches a restarted agent before the resend does nothing, since the agent doesn't know the op, and the resend then starts it. | `FIX_CANCEL`: the agent records a cancel for an op it doesn't know and reports it cancelled. |
| `atMostOncePerLife` | Holds: the agent's dedupe works. A crash forgets everything, so a resend runs the op again (at least once, by design). | |
| `noStuckWhenQuiet` | Holds: a connected, idle agent never leaves an op hanging on the control plane. The resend on every join covers lost commands and results. | |
| `noEndlessExtension` | Holds. Added after review: resetting the clock for every resent op, as a first version of the fix did, lets a connection that keeps dropping keep a hung op alive forever. Only ops the agent's `in_flight` doesn't list get a fresh clock. | |
| `succeededMeansRan` | Holds, but largely by construction: the agent's success and the ghost are recorded together. | |

With both fixes, `allInvariants` holds over 300,000 runs of up to 60 steps. `check.sh` also
checks witnesses (`noTimeouts`, `noTombstones`, `noReruns` are expected to be violated), so a
pass isn't for want of the paths being reached.

### Assumptions and limits

This is evidence under the assumptions below, not a proof that the code is right.

- Messages and casts land long before Housekeeping's three hours run out: the clock only moves
  when nothing is in flight. A command left undelivered for hours on a live connection would
  break `noPrematureTimeout`, and isn't modelled.
- The join is one step: the code restarts the clock before registering the channel, so the box
  never looks online with a stale clock, and Housekeeping rechecks `dispatched_at` in the same
  statement that fails the op. The model relies on both.
- A resend reads `cancel_requested_at` and later sends. A cancel recorded in between still
  reaches the agent, whose tombstone stops the op, unless the agent also restarts within that
  window. Not modelled.
- The outbox is per op, with acks applied as results land. The real one acks per event, and a
  failed push waits for the next connection.
- Not modelled: the secrets write sent ahead of a resent start, cancelling queued ops, dispatch
  needing a kick, command build failures, the gap between claiming an op and sending it, Ops
  restarting on its own (the agent supervises it one for one), and the done-map's 500 entries.

## Agent updates (`updates.qnt`)

`SYSTEMD_254` picks systemd's behaviour. From 254 (Ubuntu 24.04 has 255), a failed exit of a
`Restart=always` unit runs `OnFailure` every time; before it (Ubuntu 22.04 has 249, Debian 12
has 252), only once the start limit is hit. Foreman supports both, and `check.sh` checks both.
The `FIX_*` switches are proposed fixes for #24, off by default.

| Invariant | Code as it is | Fix |
|---|---|---|
| `backOnline` | Violated on both. A release that joins and then crashes (on its first command, say) is confirmed at the join, which deletes `previous`. Its crash loop hits the start limit, and the rollback unit has nothing to go back to. The agent stays down until someone fixes the box. | `FIX_CONFIRM` |
| `badNeverKept` | Violated on both, the same path: a release that misbehaves gets confirmed. | `FIX_CONFIRM`: confirm once this run has been up for a few minutes since it first joined, and have the control plane count the update as done when the agent confirms (it hears at once, or from the next join, which says whether an update is still pending), not at the first join. |
| `updateSettles` | Violated before 254. A release that dies every couple of minutes without joining is never rolled back: every start restarts the watchdog's clock (`max(installed_at, running_since)`), and a crash every two minutes is too slow for the start limit (5 in 120s). From 254, `OnFailure` on the first crash catches it. | `FIX_WATCHDOG`: roll back an unconfirmed release once it has run five minutes unjoined since the install, added up across restarts, or, checked at boot before it connects, has started more than three times since. Both are kept in `update-pending`. |
| `boundedInstalls` | Holds: a bad version is installed at most twice. | |
| `succeededSticks` | Holds. | |

`backOnline` (with the network up, the agent is back online within a bound) and
`updateSettles` (an installed update is confirmed or rolled back within a bound) are progress
properties. They replaced two in the first version that Codex showed could pass by
construction. `noRollbacks` and `noUpdates` are witnesses, expected to be violated.

Getting to a fix that holds took several rounds, each found by the model or by review:

- Confirming at the end of probation measured from the latest join never confirms on a flaky
  network; measured as uptime from the start, it confirms a release that sat unjoined through
  an outage and joins just as probation ends. Measuring from the first join of this run works.
- Before 254, a release that joins and crashes about once a minute never hits the start limit
  (systemd's window starts with its first start, so 2 or 3 starts land in each) and never trips
  the watchdog (it joins). Capping starts since the install catches it, but only as a check at
  boot: the watchdog only looks while the agent isn't joined, and this release is joined by its
  first check, 20 seconds in. A 200,000-run search found that one after 20,000 runs had passed.
- The watchdog can now roll back right after a fast crash loop, and its exit lands on a used-up
  start limit. The rollback unit, with `previous` already used, gives up and leaves the box down
  on the good release. `FIX_ROLLBACK_UNIT` closes that: the rollback unit resets the failure and
  starts the agent again even when there's nothing to switch to.

With all three, `allInvariants` holds on both systemd versions over 400,000 runs of up to 100
steps. Before 254, leaving any one out breaks something; from 254, `FIX_CONFIRM` alone holds.

### Assumptions and limits

- What happens within seconds happens before the clock moves: systemd's restart, a crash at
  boot, a join, the watchdog's 30-second check, the rollback unit, and an idle agent restarting
  into an update. `RestartSec=3` is left out.
- A release that joins and then crashes does so within a minute of first joining; probation is
  longer. One that crashes after it's confirmed isn't modelled.
- The network drops at most three times per run.
- The fixes need work the model only assumes: the probation timer, an `update_pending` field in
  the join so the control plane hears about a confirmation it missed, persisting run time and
  starts in `update-pending` (checkpoints lose the last interval before a crash), and a new
  rollback unit, which self-update can't install: boxes need `install.sh` again.
- Codex noted a simpler watchdog passes too: time from the install alone, without the `max`.
  It rolls back a good release on a box that was off for five minutes after an update, which is
  the case the `max` is there for.
- Not modelled: the disk filling during a download (#39) and `install.sh` re-runs (#32).

## Not modelled anywhere

The environment lifecycle (#23, #38).
