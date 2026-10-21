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
| `noPrematureTimeout` | Violated: #31. After an outage, Housekeeping fails an op by its original `dispatched_at`, sometimes before the resend has even reached the agent. | `FIX_RESEND_CLOCK`: `agent_connected` resets `dispatched_at` before the resends go out. Resetting it in `resend_op` (the issue's suggestion) leaves a gap between the reconnect and the resend cast. |
| `noResendAfterCancel` | Violated: #95. A cancel lost in a disconnect isn't retried (box commands aren't resent), and the op is resent and runs anyway. | `FIX_CANCEL`: the operation records `cancel_requested`, and a resend sends the cancel instead of the command. |
| `noStartAfterStop` | Violated: #95. A cancel that reaches a restarted agent before the resend does nothing, since the agent doesn't know the op, and the resend then starts it. | `FIX_CANCEL`: the agent records a cancel for an op it doesn't know and reports it cancelled. |
| `atMostOncePerLife` | Holds: the agent's dedupe works. A crash forgets everything, so a resend runs the op again (at least once, by design). | |
| `noStuckWhenQuiet` | Holds: a connected, idle agent never leaves an op hanging on the control plane. The resend on every join covers lost commands and results. | |
| `succeededMeansRan` | Holds. | |

With both fixes, `allInvariants` holds over 300,000 runs of up to 60 steps.

## Not modelled

- Agent updates, rollback (#24) and the environment lifecycle (#23, #38).
- The gap between claiming an op and sending it, and box commands other than `op.cancel`.
- The agent's done-map limit (500 entries).
