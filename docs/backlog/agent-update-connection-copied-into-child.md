---
worth: later
where: HermesKit/Sources/HermesKit/Features/SettingsFeature.swift:29
added: 2026-11-07
---
# agent updater holds a hand-synced copy of the Settings connection

`AgentUpdateFeature.State.connection` duplicates `SettingsFeature.State.connection`, kept in step by one
manual assignment in `saveTokenTapped`. Correct today because that is the only place Settings mutates its
connection; the next mutation site can silently leave the updater probing with a stale credential. The
TCA fix is a computed child-state property on the parent (get builds the child from the shared
connection, set writes back everything else).

Unsettled: whether a second connection-mutation site in Settings is likely. If not, the copy is cheap and
the refactor is churn. Surfaced reviewing PR #153.
