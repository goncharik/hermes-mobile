---
worth: yes
where: HermesKit/Sources/HermesKit/Features/AgentUpdateFeature.swift:170
added: 2026-11-09
---
# a re-probe after an uncertain POST re-offers Update before any status read

A POST that ends `.uncertain` without an action id (a 5xx, a transport failure) persists nothing, so any
re-probe forgets it: `.task` goes `.checking` → `.ready` and Update is enabled before the recovery status
read lands, and stays enabled if that read fails. Two doors reach it: reopening Settings (since #153) and
saving a token in Settings, which re-sends `.agentUpdate(.task)` from any phase except `.starting`
(`SettingsFeature.swift:560`, since #156). That breaks the "no second Update button until a status read
settles it" invariant in `docs/features/agent-update.md`. The server's `already_running` guard limits the
damage while the first run is alive.

Cheap partial fix for the token door: re-probe only when `agentUpdate.phase == .hidden`. Closing the reopen
door needs the unresolved POST remembered across re-probes (persisted like `OwnedAgentUpdate`, or hold
`.ready` until the recovery read reports idle). Surfaced reviewing PR #156 (Codex P2 on the same path).
