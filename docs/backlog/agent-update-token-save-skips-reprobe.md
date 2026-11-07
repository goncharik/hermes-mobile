---
worth: yes
where: HermesKit/Sources/HermesKit/Features/SettingsFeature.swift:528
added: 2026-11-07
---
# saving a token doesn't re-probe the agent updater

In token mode with an empty token, `AgentUpdateFeature` stays `.hidden` (no dashboard credential).
`saveTokenTapped` copies the new token into `agentUpdate.connection` but never re-sends
`.agentUpdate(.task)`, so the updater stays hidden until Settings is closed and reopened. Fix: re-send the
child's `.task` (or call its probe) when the saved token turns a previously empty one non-empty.
Surfaced reviewing PR #153.
