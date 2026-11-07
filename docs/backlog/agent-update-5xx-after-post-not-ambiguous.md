---
worth: yes
where: HermesKit/Sources/HermesKit/Features/AgentUpdateFeature.swift:435
added: 2026-11-07
---
# a 5xx from the update POST settles as failed, not uncertain

`isAmbiguousAfterSend` covers only `.unreachable`, `.offline` and `.decoding`. A 502/503/504 from a
reverse proxy while the agent restarts mid-request maps to `.server(status: 5xx)` → `.failed(...)`, and
`.failed` offers "Check for updates" → a fresh check → the Update button again. So a second POST is
reachable after an outcome that is genuinely unknown, against the "never retried" invariant in
`docs/features/agent-update.md`. The server's `already_running` guard limits the damage.

Fix: treat `.server(status: 500...)` as ambiguous after send, plus a test in `AgentUpdateTests`'s
`ambiguousPostFailureIsUncertainAndNeverRetried` arguments. Surfaced reviewing PR #153.
