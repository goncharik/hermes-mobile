---
worth: yes
where: HermesKit/Sources/HermesKit/Features/SettingsFeature.swift:516
added: 2026-11-07
---
# updater delegate round-trips through `.send(.agentStatusLoaded)`

`.agentUpdate(.delegate(.updated(version)))` returns `.send(.agentStatusLoaded(version))` to share the
Agent-row update logic — the action-for-shared-logic pattern TCA discourages (an extra store round trip,
noise in tests). Extract an `applyAgentVersion(&state, version)` helper used by both cases; it must keep
updating a pushed Diagnostics screen's `agentVersion` too. Mechanical, covered by `SettingsFeatureTests`.
Surfaced reviewing PR #153.
