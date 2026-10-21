# Formal models

`ops.qnt` models one environment's operations between the control plane and a box's agent:
dispatch, resend after a reconnect, the agent's dedupe and queue, cancel, Housekeeping's
three-hour timeout, and results held in the agent's outbox until acknowledged. It also models
failures: disconnects, agent crashes and time passing. The header lists the code each action
follows.

Run it with [Quint](https://quint-lang.org) 0.33 (`npx @informalsystems/quint` works without
installing anything):

```sh
quint run ops.qnt --invariant=allInvariants --max-samples=30000 --max-steps=40
./check.sh   # the code as it is, and v0.4.3 before the fixes below
```

## What it found

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

## Not modelled anywhere

Agent updates and rollback (#24), and the environment lifecycle (#23, #38).
