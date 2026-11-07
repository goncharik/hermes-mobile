---
worth: later
where: HermesKit/Sources/HermesKit/Features/AgentUpdateFeature.swift:34
added: 2026-11-07
---
# agent updater fences stale responses with a generation counter, not cancel IDs

`AgentUpdateFeature` threads a `generation` through state and four action payloads so a slow check or
status response can't relabel a newer phase. TCA already gives that fence: `send` is a no-op once an effect
is cancelled, so `.cancellable(id: CancelID.check / .status, cancelInFlight: true)` plus `.cancel` on
confirm and on `release` is equivalent. The POST is deliberately unfenced either way. Dropping the counter
would also make exhaustive `TestStore` tests practical — all 38 `AgentUpdateTests` currently run with
`exhaustivity = .off`, partly to avoid asserting the counter everywhere.

Unsettled: whether the refactor (and moving the suite to exhaustive) is worth the churn on a state machine
that works and is well covered. Surfaced reviewing PR #153.
