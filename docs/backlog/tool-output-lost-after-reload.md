---
worth: later
where: HermesKit/Sources/HermesKit/Models/ToolPresentation.swift:501
added: 2026-11-04
---
# tool output is lost after a reload

Cooked `session.resume` history carries a tool row's result (`content`) only for `write_file` /
`patch` / `skill_manage`. A reloaded session therefore keeps call targets and edit diffs, but
terminal output, file reads, search hits and web pages expand to "Output isn't kept in history"
(`ToolPresentation.Body.unavailable`). Deferred from the tool-call display plan
(`docs/plans/completed/20261104-tool-call-display.md`, "Out of scope";
`docs/features/tool-calls.md`).

Proposal: when the user expands such a call (or opens its detail sheet), lazily fetch REST
`GET /api/sessions/{id}/messages` (profile-scoped like the other session REST calls), match the
row by `tool_call_id`, and fill `ToolDetail.result` / `resultText` in place. Gate it like every
other capability: a 404 (405 on an older catch-all) flips a per-slot `*Supported` flag off and
the "unavailable" note stays. Never on hydrate: the cost is paid only for calls someone opens.

Unknown that settles the value: whether that endpoint returns the raw tool `content` for every
tool (not just the cooked subset) and how large its payload is for a long session, since the
call would fetch the whole transcript to recover one result.
