# Tool-call display: turn folds, run summaries, per-tool views

## Overview

Rethink how a turn's tool activity renders in chat, closing two issues:

- **#55 — tool calls bury the reply.** Today every call is its own full-height row
  (`checkmark.seal` + raw name + chevron); a 15-call turn pushes the answer off-screen.
- **#45 — raw JSON everywhere.** The row shows only the name/title; `ToolDetailSheet`
  dumps args/result as monospaced text.

The design follows the T3 Code mobile app (the visual reference the user supplied) with one
deliberate extension, and the desktop app's run-summary vocabulary:

1. **Turn fold.** A FINISHED turn renders `[user] [Worked for 4m 31s ›] [final reply]` —
   everything before the final assistant segment (interim commentary, tool runs, reasoning)
   folds behind the header, collapsed. A RUNNING turn shows a header too (`ಠ_ಠ pondering… ·
   19s` / `Working · 19s`), **expanded by default** (T3 parity) but **tappable to collapse**
   (our extension) — collapsed it shows one live line for the current call. When the turn
   finishes it collapses **unless the user's last action on that header was expand**.
2. **Run summary.** Consecutive tool calls fold into one line — "Read 1 file, ran 4 commands,
   and performed 1 other action" — with a category icon; tap to list the calls. A run of one
   call shows the call line directly (desktop: runs of < 2 calls render expanded).
3. **Call line.** Icon per tool kind + a parsed one-line target (`$ pytest -q`, `Read
   ChatFeature.swift L10-40`, `Searched "query"`); failure turns the icon red. Tap **expands
   in place** to a capped, purpose-built body (terminal output + exit badge, colored diff,
   file range, search hits, …); "Show all" opens the redesigned sheet with the full content
   rendered by the same per-tool views (raw payload only in a collapsed "Raw" disclosure).

The Thinking row is **broken up**: its timer moves to the turn header, reasoning becomes
per-burst lines inside the fold, the status line becomes a caption under the live header,
and the agent's spinner frames (`thinking.delta`) become the live header label instead of
being appended to reasoning (a bug today — see Context).

Shipped as **three PRs from this one plan** (Phase A → B → C); each phase leaves the app
releasable.

## Context (from discovery)

**Current iOS code**
- Row model: `HermesKit/Sources/HermesKit/Models/ChatRow.swift` —
  `.tool(name, title, state, detail: ToolDetail?, durationS)`; `ToolDetail` =
  `argsText` / `args: JSONValue?` / `resultText` / `inlineDiff`. `.thinking(reasoning, status,
  elapsedSeconds, isComplete)` is one row per turn, kept LAST (`keepThinkingLast`) and frozen
  under the answer as `Thought · 12s`.
- Live fold: `ChatFeature.swift` ~2722–2860 (`messageStart`, `messageDelta` →
  `appendToStreamingMessage`, `messageComplete`, `thinkingDelta`, `reasoningAvailable`,
  `statusUpdate`, `toolStart`, `toolComplete`). Live rows get random `uuid()` ids;
  `toolRowIDs[tool_id]` merges complete into start.
- Hydrate: `reconstructTranscript` (`Models/TranscriptReconstruction.swift`) — deterministic
  FNV ids from `(sequenceIndex, role, kindDiscriminator)`; tool rows from cooked
  `{role:"tool", name, context}` only. `applyActivate` ~4030 holds the #26 running-turn
  preservation (`preservedToolRows`, `preservedThinkingRow`).
- Decoding: `Models/GatewayEvent.swift` ~60–95; `Models/Session.swift` `SessionMessage`
  (~240–330).
- Rendering: `ChatView.rowView` (~270) → `ToolStatusView`, `ThinkingIndicatorView`;
  `.sheet(item: toolDetailBinding)` → `ToolDetailSheet`; `CollectionTranscriptView`
  (`HermesMobile/Sources/Features/Chat/Transcript/`) — diffable source keyed on
  `ChatRow.ID`, `UIHostingConfiguration` cells, `.estimated(60)` heights,
  `apply(…, animatingDifferences: false)`; window = `visibleRows` (`initialWindow` /
  `pageSize` = 50 raw rows).

**Bugs / gaps found (fixed in Phase A)**
- `thinking.delta` is the agent's **kawaii spinner** (`agent_callbacks._agent_thinking_update`;
  frames are rewrites, plus provider-wait diagnostics). iOS maps it to `.thinkingDelta` and
  APPENDS it to reasoning → `ಠ_ಠ pondering…٩(๑❛ᴗ❛๑)۶ mulling…` piles up and persists into
  `Thought`. Desktop keeps it out of the transcript (`message-stream.ts:289`).
- Interim commentary is not segmented: every `message.delta` appends to ONE streaming row
  that sits above all the turn's tools. The server seals segments with **`message.interim`**
  `{text, already_streamed, turn_id?, segment?}` (`contracts/events.py:183`) — iOS decodes it
  as `.unknown`. (`message.delta` also stamps `segment`; `text:null` boundaries go to
  local-viewer turns only — not relied on.)
- `tool.start` now carries full `args` (and `preview`); `tool.complete.result` is parsed
  JSON. iOS reads neither `tool.start.args` nor structured `result`.
- Cooked `session.resume` tool rows (`tui_gateway/session_history.py:333-346`) carry
  `args`, `tool_call_id`, `timestamp`, `display_metadata.tool_result_metadata.inline_diff`,
  `labels`, and `content` (the result) **only for `write_file` / `patch` / `skill_manage`**.
  `SessionMessage` drops all of them. → summaries, targets and edit diffs survive a reload;
  terminal output / search hits do not (live-only).

**Desktop reference** (`hermes-agent` `upstream/main`, read via `git show`)
- `apps/desktop/src/components/assistant-ui/tool/run-summary.ts` — category order edit,
  explore, search, read, browse, interact, analyze, run, delegate, other; one item → names
  its target ("Edited foo.tsx", `Searched "q"`); clauses joined, first capitalized; failure
  clause "N tool calls failed"; present tense while live.
- `tool/fallback-model/index.ts` (`TOOL_META`, `dynamicTitle`, `toolStatus`,
  `toolErrorText`) — per-tool titles/targets/arg keys and failure heuristics;
  `tool/fallback.tsx` — bodies (terminal `$ cmd` + exit badge + ANSI output, diff panel,
  search hits ≤ 6, …); unknown → humanized name + first of result summary / args / context.
- `agent/display.py:353-361,487-510` (`build_tool_preview`) — how `context` is derived.

**Invariants this plan must respect** (CLAUDE.md): deterministic content-derived row ids;
`CollectionTranscriptView` is the only renderer and stick-to-bottom stays renderer-local;
server-authoritative wholesale hydrate + the #26 running-turn exception; decode leniently
(unknown → fallback, never crash, never hide info); logic in HermesKit, views thin; elapsed
timer continuity via the persisted turn anchor; `ChatSnapshotClient` is a non-authoritative
cache; read-aloud completed-row anchor; branch `canBranch` gates; streaming append never yanks
a scrolled-up user.

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task) — consistent with
  every prior plan in `docs/plans/completed/`.
- complete each task fully before moving to the next; small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - unit tests for new/modified functions; success AND edge/error paths
  - update existing tests whose behavior changes (thinking-row tests move to the new model)
- **CRITICAL: all tests must pass before starting the next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run `make test` after each change; `make snapshot` for view tasks
- maintain backward compatibility with older agents: every new field is optional; absent →
  today's behavior (name + context)
- commit at each task completion (no conventional prefixes, capitalized verb)

## Testing Strategy

- **Unit (HermesKit, `swift test`)** — the bulk: event decoding, fold reductions
  (`TestStore` + `TestClock`), `reconstructTranscript`, the pure `ToolPresentation` /
  `RunSummary` / `TranscriptLayout` functions (table-driven over fixture payloads shaped like
  real wire data from the desktop/contract sources).
- **Snapshot (`HermesMobileTests`, `make snapshot`)** — turn header (live/collapsed/finished),
  run summary, each call-body presentation + generic fallback, failure state, the redesigned
  sheet; light + dark where existing suites do. New snapshots: run `make snapshot` twice
  (record, then assert). Re-record baselines the change legitimately alters, in the same PR.
- **Measured layout XCTest** only where a snapshot can't prove the fact (capped body height).
- No hosted behavior-probe tests / debug counters (project rule).
- No UI e2e suite exists in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix
- update the plan if implementation deviates from scope

## Solution Overview

**Phase A — fold & data (no visual redesign; PR 1).** Make the transcript model carry what
the new UI needs, for both live and hydrated turns:
- `thinking.delta` → a transient per-slot `turnActivityLabel` (replace, never append); only
  `reasoning.delta` / `reasoning.available` produce reasoning.
- `.thinking` row kind → `.reasoning(text:isComplete:)`, **one row per reasoning burst**
  (a burst = consecutive reasoning with no tool/text row after it). Turn timer, frozen
  duration and status move off the row into state / derivation.
- `message.interim` seals the current streaming segment; the next delta starts a new row.
- Tool rows gain structured `args` (from `tool.start` and `tool.complete`) and structured
  `result`; hydrated tool rows gain `args`, `content` (edit tools), `inline_diff`.
- `ChatRow.timestamp: Date?` (server `timestamp` on hydrate; client clock live) → turn
  duration on reloaded sessions.
- Turn structure (pure, HermesKit): turns are delimited by user rows; the **final reply** of
  a finished turn = its last assistant `.message` row. Read-aloud, the action bar and
  `canBranch` key off "final reply", so interim segments get no action bar and are never
  read aloud.
- Phase A keeps rendering roughly as today (reasoning rows render with the existing
  disclosure styling, no header yet) so it ships independently.

**Phase B — turn fold + run summaries (PR 2, closes #55).** A pure
`TranscriptLayout.items(rows:expansion:runningTurn:…)` in HermesKit flattens the windowed
rows into **display items** — `turnHeader`, `runSummary`, `toolCall`, `reasoning`,
`message`, `status`, `commandOutput` (+ `toolBody` in Phase C). `CollectionTranscriptView`
keys on `TranscriptItem.ID` instead of `ChatRow.ID`. Expansion state lives in `ChatFeature`
(in-memory, per slot) keyed by **ordinals**, not row ids, so it survives the live→hydrate id
change. The window snaps to turn boundaries. Auto-collapse on finish preserves the reply's
on-screen position when the user isn't pinned.

**Phase C — per-tool presentation + expand in place (PR 3, closes #45).** A pure
`ToolPresentation(name:args:result:resultText:inlineDiff:context:)` classifies each call →
icon kind, run-summary category, verb + target title (past / present tense), failure
outcome, and a `Body` enum. Tapping a call inserts a `toolBody` display item rendered by a
per-body view, capped (~12 lines); "Show all" opens the redesigned `ToolDetailSheet`.

## Technical Details

### Row model (Phase A)

```swift
public enum Kind {
  case message(role: Role, text: String, isComplete: Bool)
  case tool(ToolCall)                                   // payload struct, see below
  case reasoning(text: String, isComplete: Bool)        // replaces .thinking
  case status(kind: String, text: String)
  case commandOutput(text: String)
}
public struct ToolCall: Equatable, Sendable, Codable {
  public var name: String
  public var title: String            // server context/summary → fallback name (kept for the fallback path)
  public var state: ChatRow.ToolState // running | complete
  public var detail: ToolDetail?      // argsText, args, result (JSONValue?), resultText, inlineDiff
  public var durationS: Double?
}
// ChatRow gains `timestamp: Date?` (decodeIfPresent; excluded from id derivation).
```
- Discriminators: `"tool"` unchanged; `"reasoning"` replaces `"thinking"` (ids differ from
  old cached snapshots — harmless, the cache is non-authoritative).
- `ChatSnapshotStore` decode of an old snapshot containing `.thinking` fails → treated as a
  cache miss (verify `loadSnapshot` returns `nil`, not a crash; add a test).
- `ToolDetail.result: JSONValue?` added; `isEmpty` updated.

### Live state (Phase A)
- `turnActivityLabel: String?` — latest `thinking.delta` text (trimmed; empty → nil);
  cleared on `tool.start`, `message.delta`, terminals. Never persisted, never in a row.
- `turnStatus: String?` — latest `status.update` text (was the thinking row's `status`).
- `thinkingSeconds` → renamed `turnSeconds` (same `continuousClock` tick, same anchor);
  frozen value lands as the final row's `timestamp`-derived duration, so no per-row elapsed.
- `streamingRowID` semantics unchanged; `message.interim`:
  - `already_streamed == true` and a streaming row exists → set its text to the sealed
    `text`, `isComplete = true`, `streamingRowID = nil`.
  - otherwise → append a completed assistant row with `text` (skip empty; skip inside a #98
    replay fold if the same segment was already sealed — dedup on `(turn_id, segment)` when
    present).
- `message.complete` text applies to the CURRENT streaming row only (verify against the
  server: `response_reused` means the text was already delivered — don't duplicate it).

### Hydrate (Phase A)
- `SessionMessage` decodes `args` (JSONValue), `display_metadata` (→ `inlineDiff` from
  `tool_result_metadata.inline_diff`), and keeps `content` for tool rows.
- `reconstructTranscript`: tool rows get `ToolDetail(argsText: context, args:, result: content
  parsed as JSON when possible else resultText:, inlineDiff:)`; every row gets `timestamp`.
- #26 running-hydrate exception: preserve the live turn's tool rows (existing tool-key
  dedup) AND its reasoning rows instead of the single thinking row; keep the existing
  ordering rules. Read `docs/architecture.md` (hydration section) before editing.

### Turn structure (Phase A, pure)
```swift
public struct TurnSpan { userRowIndex: Int?; rowRange: Range<Int>; finalReplyIndex: Int?; ordinal: Int }
public func turnSpans(_ rows: some Collection<ChatRow>) -> [TurnSpan]
```
- Ordinal = count of user rows before it (rows before the first user row → ordinal −1,
  never folded). `finalReplyIndex` = last assistant `.message` in the span — only for a
  finished turn; nil while running. `.status` / `.commandOutput` rows are never folded.
- Duration = latest row `timestamp` in span − user row `timestamp`; nil if either missing →
  header shows "Worked".

### Display items (Phase B)
```swift
public enum TranscriptItem: Identifiable, Equatable {
  case turnHeader(TurnHeader)        // id: deterministic("turn|\(userRow.id)")
  case runSummary(RunSummary)        // id: deterministic("run|\(firstToolRow.id)")
  case toolCall(ChatRow, expanded: Bool)   // id: row.id
  case toolBody(ChatRow)             // Phase C; id: deterministic("body|\(row.id)")
  case row(ChatRow)                  // message / reasoning / status / commandOutput; id: row.id
}
public struct FoldExpansion: Equatable {     // in ChatFeature.State, in-memory per slot
  var turnOverride: [Int: Override]           // turn ordinal → .expanded | .collapsed (absent = default)
  var expandedRuns: Set<RunKey>               // (turnOrdinal, runOrdinal)
  var expandedCalls: Set<CallKey>             // (turnOrdinal, callOrdinal)  — Phase C
}
```
- Turn visibility: running → `override != .collapsed`; finished → `override == .expanded`.
- Folded content of a turn = its rows minus the final reply and never-folded kinds. Collapsed
  running turn still shows the streaming assistant row (it may be the answer) and a live
  line (current running call's present-tense title → `turnActivityLabel` → nothing).
- Runs: maximal sequences of tool rows within a turn, broken only by assistant text;
  reasoning rows inside a run stay inside it (T3 shows reasoning lines between calls). A run
  of 1 call → no summary item, the call line directly. Default collapsed for ≥ 2 calls.
- Header label: running → `"\(turnActivityLabel ?? "Working") · \(formatElapsed(turnSeconds))"`;
  finished → `"Worked for \(formatElapsed(duration))"` or `"Worked"`.
- Window: `visibleRows` start snaps DOWN to the containing turn's user row so a header is
  never orphaned; paging unchanged otherwise.
- Renderer: `CollectionTranscriptView` generic over `TranscriptItem`; reconfigure detection
  by `Equatable` item; auto-collapse that removes items above the viewport while NOT pinned
  reuses the prepend-preservation offset math anchored on the final reply / header.
  Pinned → normal re-pin. Expand/collapse applies without animation first; evaluate a
  short crossfade on device (Post-Completion).
- Taps: header / summary / call lines use `onTapGesture` + `.accessibilityAddTraits(.isButton)`
  (memory: `Button` over a scroll view lost taps), routed as `turnHeaderTapped(ordinal)`,
  `runSummaryTapped(RunKey)`, `toolCallTapped(CallKey)`.

### Tool presentation (Phase C, pure, HermesKit)
```swift
public struct ToolPresentation: Equatable {
  var icon: Icon                 // terminal, file, edit, search, web, eye, skill, delegate, memory, generic
  var category: RunCategory      // edit, explore, search, read, browse, interact, analyze, run, delegate, other
  var target: String?            // command / path / query / host+path / skill name
  func title(live: Bool) -> String   // "Ran pytest -q" / "Running pytest -q"
  var outcome: Outcome           // success | failure(message) | unknown
  var body: Body
}
public enum Body {
  case terminal(command: String, exitCode: Int?, stdout: String?, stderr: String?)
  case diff(path: String?, lines: [DiffLine])            // from inline_diff
  case fileRead(path: String, range: String?, content: String?)
  case search(query: String, hits: [SearchHit])          // ≤ 6
  case webPage(url: String, content: String?)
  case skill(name: String, file: String?)
  case delegate(goals: [String])
  case generic(summary: String?, raw: String?)            // pretty JSON of args/result
  case unavailable(note: String)                          // reloaded call with no stored result
}
```
- Arg keys mirror the desktop: `terminal` → `command` (else `code`, else `context`),
  `summarizeShellCommand` lite (drop leading `cd …&&`, cap 160); `execute_code` → `code`;
  `read_file` → `path|file|filepath` + `offset`/`limit`; `write_file`/`patch`/`edit_file` →
  `path` (else `result.path`, else parsed from diff); `web_search` → `query|search_term`;
  `web_extract` → `urls[0]|url`; `browser_navigate` → `url`; `vision_analyze` → `question`;
  `skill_view` → `name` (+ `file_path`); `delegate_task` → `tasks[].goal|goal`;
  `search_files` → `pattern`. Unknown → humanized name (`foo_bar` → "Foo bar") + context.
- Outcome heuristics (desktop `toolStatus`): `success|ok == true` → success; `error` /
  `errors` key (≤ 5 levels), `success|ok == false`, `status ~ error|failed|fatal` →
  failure; non-zero `exit_code` → failure ONLY when there's no output; no result → unknown
  (neutral, no checkmark). `read_file` "File not found:" and `terminal` exit 1 → neutral.
- Run summary: `RunSummary.text(calls:live:)` — category clauses in desktop order, single
  item names its target, Oxford-style join ("A, B, and C"), first word capitalized,
  "N other actions" for `other`, appended "N tool calls failed".
- Body caps (pure): strip ANSI escapes; first 12 lines / 2 000 chars inline, full text in the
  sheet; diff parsed to `+`/`-`/context lines.
- Fallback rule: a presentation that can't parse ANYTHING still yields `.generic` with the
  raw args/result — never hides data (lenient-decode rule). The sheet always has a
  collapsed "Raw" section with pretty-printed args + result.

### Out of scope (deliberately)
- REST `GET /api/sessions/{id}/messages` to recover terminal output / search hits after a
  reload — reloaded calls show `.unavailable` ("Output isn't kept in history"). Candidate
  follow-up (backlog item in the final task).
- File-edit calls as standalone diff cards outside runs (desktop does this; the T3
  reference folds them). Edits stay inside runs, counted as "Edited N files", diff in the
  expanded body.
- `tool.generating`, `tool.progress`, `subagent.*` live tickers; a Settings toggle for the
  live default (the tap toggle covers it).

## What Goes Where

- **Implementation Steps** (`[ ]`): code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): on-device feel checks, TestFlight, follow-ups.

## Implementation Steps

### Phase A — fold & data (PR 1)

### Task 1: Decode the new tool and segment payloads

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/Session.swift`
- Modify: `HermesKit/Tests/HermesKitTests/` (gateway event + session message decode tests)

- [x] split `thinking.delta` into its own case (`.spinnerFrame(text:)`) — `reasoning.delta` keeps `.thinkingDelta` (rename to `.reasoningDelta`)
- [x] add `.messageInterim(text:alreadyStreamed:turnID:segment:)` for `message.interim`
- [x] `tool.start`: decode `args` (JSONValue) alongside `context` / `args_text`; `tool.complete`: decode `result` as structured `JSONValue` in addition to `result_text`
- [x] `SessionMessage`: decode `args`, `display_metadata.tool_result_metadata.inline_diff`, keep tool-row `content`; all lenient (`try?`)
- [x] write decode tests for each new field/case incl. absent fields (older agent) and odd shapes (`args` not an object, `display_metadata` missing keys)
- [x] run tests — must pass before Task 2

### Task 2: Replace the thinking row with per-burst reasoning rows and turn state

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ChatRow.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/ChatSnapshotStore.swift` (if the miss path needs work)
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`, `RowIdentityTests.swift`, `ChatSnapshotClientTests.swift`

- [x] `ChatRow.Kind.thinking` → `.reasoning(text:isComplete:)`; discriminator `"reasoning"`; update `copyText`
- [x] add `turnActivityLabel` (spinner frame, replace semantics, cleared on `tool.start` / `message.delta` / terminals) and `turnStatus` to `ChatFeature.State`; rename `thinkingSeconds` → `turnSeconds` keeping the clock + turn-anchor behavior
- [x] reasoning deltas append to the current burst row when it is the last row of the turn, else start a new row; `reasoning.available` keeps today's dedup semantics scoped to the burst; remove `keepThinkingLast` / eager thinking-row creation; `freezeThinking` → mark open reasoning rows complete
- [x] verify an old cached snapshot holding `.thinking` decodes as a cache miss (no crash) — per-row miss: the legacy row is skipped, the rest of the snapshot still paints
- [x] update existing thinking-row tests to the new model; add tests: spinner frames never reach a row, label replace/clear, multi-burst reasoning around tools, timer start/freeze/discard-stale-anchor unchanged
- [x] run tests — must pass before Task 3

### Task 3: Segment interim commentary and carry structured tool data live

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ChatRow.swift` (`ToolCall` payload struct, `ToolDetail.result`, `ChatRow.timestamp`)
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`, `ReplayTests.swift`

- [x] wrap tool payload in a `ToolCall` struct (`.tool(ToolCall)`) and add `ToolDetail.result`; keep the start/complete merge via `toolRowIDs`, now merging `args` from start when complete omits them
- [x] `message.interim`: seal the streaming row (`already_streamed`) or append a sealed row; dedup a re-sent seal by `(turn_id, segment)`; inert-duplicate guard inside a #98 replay fold
- [x] check `message.complete` against the server contract (`response_reused`) so the final text lands on the final segment only — never overwrites a sealed interim row (➕ `message.complete` now decodes `response_reused`)
- [x] add `ChatRow.timestamp` (`decodeIfPresent`, excluded from id derivation); stamp live rows from the `date` dependency on append and on completion
- [x] tests: interim → final produces two rows in order around tool rows; replayed seal not duplicated; complete-without-deltas; tool args from start survive complete; timestamps stamped
- [x] run tests — must pass before Task 4

### Task 4: Rebuild hydrate and the #26 preservation on the new rows

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/TranscriptReconstruction.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`applyActivate`)
- Modify: `HermesKit/Tests/HermesKitTests/TranscriptReconstructionTests.swift`, `HydrateTests.swift`

- [x] `reconstructTranscript`: reasoning → `.reasoning(isComplete: true)`; tool rows carry `args`, `content` (raw text always as `resultText`, plus `result` when it parses as a JSON object/array — mirrors the live `tool.complete` shape), `inlineDiff`; every row gets `timestamp`
- [x] #26: a running hydrate preserves the live turn's tool rows (existing tool-key dedup) and its reasoning rows (➕ `State.liveReasoningRowIDs`, same lifecycle as `toolRowIDs`); completed turns stay strict server-wins
- [x] re-read the hydration section of `docs/architecture.md` and keep `inflight` seeding of the streaming row intact
- [x] tests: deterministic ids reproduce; old-agent rows (name + context only) still reconstruct; running hydrate keeps live reasoning + tools without duplicates; completed hydrate replaces wholesale
- [x] run tests — must pass before Task 5

### Task 5: Add turn structure and point final-reply consumers at it

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/TurnStructure.swift`
- Create: `HermesKit/Tests/HermesKitTests/TurnStructureTests.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (read-aloud anchor / auto-speak, `canBranch`)
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift` (action bar gate, reasoning row rendering)
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift` (+ branch tests as needed)

- [x] `turnSpans(_:runningTurnOrdinal:)` pure function: ordinals, ranges, `finalReplyIndex` (finished turns only), duration from timestamps
- [x] read-aloud: auto-speak and the completed-row anchor use the final reply only — interim segments never read; `MessageActionBar` and branch shown only on final replies (➕ anchor kept in step at turn edges: `.error` / socket drop consume a promoted segment, a `message.start` without a user row clamps; hydrate re-base moved after the running verdict)
- [x] `ChatView`: render `.reasoning` rows with the existing disclosure look (interim only — Phase B replaces it); `ThinkingIndicatorView` shows `turnActivityLabel ?? "Thinking"` + `turnSeconds` while running so Phase A ships coherently (➕ `State.renderedRows` adds a placeholder live row while a turn is live without an open burst)
- [x] tests: spans for preamble / running / tool-only / errored turns, missing timestamps; read-aloud never reads interim; action-bar predicate
- [x] re-record affected snapshots (thinking / hydration suites) in their own commit; `make snapshot` clean (no existing baseline changed — 285/285 before the new tests; 2 new baselines added: spinner label, interim row without action bar → 287/287)
- [x] run tests — must pass before Task 6

### Phase B — turn fold & run summaries (PR 2, closes #55)

### Task 6: Build the pure display-item layout

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/TranscriptLayout.swift`
- Create: `HermesKit/Tests/HermesKitTests/TranscriptLayoutTests.swift`

- [x] `TranscriptItem` + deterministic derived ids; `FoldExpansion` with ordinal keys
- [x] `TranscriptLayout.items(rows:expansion:runningTurnOrdinal:liveLine:)` — header per turn, folded content per visibility rules, runs (≥ 2 calls → summary), status/commandOutput never folded, collapsed-running keeps the streaming row + live line (➕ the namespace is `TranscriptFold` — the app target already has a `TranscriptLayout` enum that would shadow it; file name kept; extra `ordinalOffset:` param makes window ordinals absolute; `.toolCall` carries a `ToolCallItem` with its `CallKey`)
- [x] a plain `RunSummary.text` using tool NAMES only for now (categories arrive in Task 11) so Phase B is shippable
- [x] tests: finished turn collapsed by default; `.expanded` override survives finish; `.collapsed` running → header + live line + streaming row; runs split by interim text; run of 1 has no summary; ids stable while a run grows; ids stable across re-layout
- [x] run tests — must pass before Task 7

### Task 7: Hold fold expansion state in ChatFeature

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift` (or new `ChatFoldTests.swift`)

- [x] `State.fold: FoldExpansion`; actions `turnHeaderTapped(ordinal)`, `runSummaryTapped(RunKey)`; a computed `transcriptItems` over `visibleRows`
- [x] snap `visibleRows` start down to the containing turn's user row; `loadOlderRequested` keeps paging (➕ `windowStart` stays raw, `snappedWindowStart` is derived; paging steps from the snapped start)
- [x] fold state survives a hydrate (ordinal keys) and resets on session switch / slot teardown; logout clears it with the slot (➕ a hydrate prunes choices on turns the history no longer has, e.g. `/undo`)
- [x] tests: tri-state toggle transitions; finish collapses unless last action was expand; survives hydrate id change; window snap never orphans a header
- [x] run tests — must pass before Task 8

### Task 8: Render display items in the collection transcript

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/Transcript/CollectionTranscriptView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Create: `HermesMobile/Sources/Features/Chat/TurnHeaderView.swift`
- Create: `HermesMobile/Sources/Features/Chat/RunSummaryView.swift`
- Delete: `HermesMobile/Sources/Features/Chat/ThinkingIndicatorView.swift` (logic folded into the header + reasoning line)
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`, `HydrationSnapshotTests.swift`

- [x] make `CollectionTranscriptView` key on `TranscriptItem.ID`; keep stick-to-bottom, prepend preservation, reconfigure-on-change (➕ open/hydrate/prepend classification still runs on the window's ROW ids, so a fold change never reads as a reset)
- [x] auto-collapse while NOT pinned preserves the final reply's on-screen offset (reuse `preserveOffsetAfterPrepend` math); pinned re-pins (➕ generalized: any fold change while scrolled up holds the first visible surviving item, falling to the final reply when everything visible folded — pure `TranscriptScrollMath.preservationAnchor` / `offsetPreservingAnchor`)
- [x] `TurnHeaderView` (live label + timer + status caption, chevron, collapsed live line), `RunSummaryView`, reasoning line (first sentence, tap to disclose); `onTapGesture` + button a11y traits; call lines keep `ToolStatusView` restyled to the T3 line (icon + title, no green seal) (➕ `TranscriptItem.liveIndicator` for a running turn with no user row; `TranscriptFold.reasoningPreview`)
- [x] `tuist generate`; snapshot tests: live expanded / live collapsed / finished collapsed / finished expanded / run summary / reasoning line, light + dark; re-record legitimately changed baselines (new `TurnFoldSnapshotTests`; `ThinkingIndicatorSnapshotTests` removed with the view)
- [x] `make snapshot` clean (two runs for new tests) and `make test` pass before Task 9 (288/288; 2132 tests)

### Phase C — per-tool views & expand in place (PR 3, closes #45)

### Task 9: Classify tool calls into presentations

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/ToolPresentation.swift`
- Create: `HermesKit/Tests/HermesKitTests/ToolPresentationTests.swift`

- [x] icon kind, category, target extraction per the arg-key table (desktop parity), live/settled title (➕ `ToolPresentation(call:)` reads `ToolCall.title` as the context unless it is the name fallback; `Body` lands in Task 10)
- [x] outcome heuristics (success / failure(message) / unknown) incl. the neutral downgrades (➕ the downgrades are a fourth `.notice(message)` case — routine error, explanation kept, never red)
- [x] fallback: humanized name + context; never drops data
- [x] table-driven tests over fixture payloads per tool (live shape and hydrated args-only shape) + unknown tool + malformed args
- [x] run tests — must pass before Task 10

### Task 10: Build the per-tool bodies

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ToolPresentation.swift` (`Body`)
- Create: `HermesKit/Sources/HermesKit/Models/ToolOutputFormatting.swift` (ANSI strip, caps, diff line parse)
- Modify: `HermesKit/Tests/HermesKitTests/ToolPresentationTests.swift`; Create `ToolOutputFormattingTests.swift`

- [x] bodies: terminal (stdout/stderr/exit code from `result` JSON or `result_text`), diff (`inline_diff` → lines), fileRead, search hits (≤ 6), webPage, skill, delegate, generic, unavailable (reloaded call without stored result) (➕ `body` is computed on demand from stored inputs; `isRunning` init param separates "no result yet" from "not kept"; terminal `command` is optional — nil for `execute_code`; `search` gains `totalCount`, `skill` gains `description`; `Body.inline()` applies the caps with one shared budget)
- [x] pure formatting: strip ANSI, cap 12 lines / 2 000 chars with a truncated flag, parse diff `+`/`-`/context (➕ parser reads the rendered wire `inline_diff` — `┊ review diff` header, `a/x → b/x` file lines, omitted footer — and raw unified diffs; `diffPath` now uses it)
- [x] tests per body incl. huge output, ANSI-heavy output, empty result, hydrated edit with content + diff, hydrated terminal → unavailable
- [x] run tests — must pass before Task 11

### Task 11: Categorized run summaries and failure-aware call lines

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/RunSummary.swift` (replaces the Task 6 placeholder)
- Modify: `HermesKit/Sources/HermesKit/Models/TranscriptLayout.swift`
- Create: `HermesKit/Tests/HermesKitTests/RunSummaryTests.swift`
- Modify: `HermesMobile/Sources/Features/Chat/RunSummaryView.swift`, `ToolStatusView.swift`

- [x] `RunSummary.text(calls:live:)` — desktop category order, single-item target naming, Oxford join, failure clause, present tense while live; run icon = category icon when uniform, hammer when mixed (➕ clauses follow FIRST APPEARANCE with "other" last — the only order that yields both T3 references and still never reorders as a run grows; `read_file` is its own "read N files" clause, list/search stay "explored"; a settled lone item names its target only for edit / web search / page read / navigation — commands, file reads and "other" count, per the T3 reference; failures append as "; N tool call(s) failed"; `isLive` is set by the layout = running turn AND a running call, and only the narrating call's clause is present tense)
- [x] call line uses `ToolPresentation.title(live:)` + icon; failure → red icon; live line in the collapsed header uses the present-tense title (➕ `ToolCallItem.isLive`, same running-turn rule)
- [x] tests: the reference strings ("Read 1 file, ran 4 commands, and performed 1 other action", "Ran 6 commands and read 5 files"), single-target clauses, failure clause, live tense
- [x] snapshot updates for summary + call lines; `make snapshot` clean (289/289: new `testRunSummaries`; 5 baselines re-recorded in their own commit)
- [x] run tests — must pass before Task 12

### Task 12: Expand calls in place

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/TranscriptLayout.swift` (`toolBody` item)
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`toolCallTapped(CallKey)`, "Show all" → `presentedTool`)
- Create: `HermesMobile/Sources/Features/Chat/ToolBodyViews.swift` (one view per `Body` case)
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/TranscriptLayoutTests.swift`, `ChatReductionTests.swift`; `HermesMobileTests/` snapshot suite

- [x] tap a call line toggles `expandedCalls`; layout inserts a `toolBody` item after it; state survives hydrate (ordinal keys) (➕ `toolTapped(id:)` stays as the body's "Show all" → `presentedTool`; every fold call line expands — a call with no detail expands to the "unavailable" note — chevron `›` folded / `⌄` open)
- [x] body views: terminal (`$ cmd`, exit badge green/amber, monospaced output), diff (+/- tinted), file range, search hit links, generic; selectable text that doesn't fight the line's tap; "Show all" when truncated (➕ also webPage / skill / delegate / unavailable, the outcome message over the body — red failure, grey notice — and a "Details" link when nothing was cut so the sheet stays reachable; `ToolBodyContent` renders a full body for Task 13's sheet)
- [x] expanding while pinned re-pins; while scrolled up, content below shifts, nothing above moves (Task 8's fold-change handling already covers it: an insert keeps every old item, so the first visible one holds — pinned by a `TranscriptScrollMathTests` case)
- [x] tests: layout inserts/removes the body item; tap action transitions; snapshot per body case + unavailable + failure, light + dark (pin explicit size for any scrollable body) (bodies hold no scroll views — long lines wrap — so nothing to pin)
- [x] `make snapshot` clean and `make test` pass before Task 13 (298/298; 2231 tests; `testToolRows` re-recorded in its own commit)

### Task 13: Redesign the tool detail sheet

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ToolDetailSheet.swift`
- Modify: `HermesMobileTests/` snapshot suite

- [ ] header: icon + title + duration + outcome; body = the same per-tool view, uncapped
- [ ] collapsed "Raw" disclosure with pretty-printed args + result (never hide info)
- [ ] snapshot tests: terminal full output, diff, generic/unknown, failure
- [ ] `make snapshot` clean and `make test` pass before Task 14

### Task 14: Verify acceptance criteria
- [ ] #55: a 15-call finished turn shows `[user][Worked for …][reply]`; the reply is on screen without scrolling
- [ ] live turn: expanded by default, collapsible, collapsed shows the live line; finish collapses unless the user last expanded it
- [ ] #45: every listed tool renders its body; unknown tools fall back without losing data; reloaded sessions show targets + edit diffs and "unavailable" for live-only output
- [ ] spinner frames never appear in reasoning; interim commentary is separate from the reply; read-aloud reads only the reply
- [ ] older agent (no `args`, no `message.interim`, cooked `{name, context}` only) still renders sensibly
- [ ] run full suite: `make test`
- [ ] run snapshots: `make snapshot` (clean; update the 285/285 count in CLAUDE.md)

### Task 15: [Final] Update documentation
- [ ] create `docs/features/tool-calls.md` (turn fold rules, ordinal-keyed expansion, display items, presentation table, data availability live vs hydrated, out-of-scope list)
- [ ] CLAUDE.md: replace the "live Thinking indicator" bullet; add a compact tool-calls bullet pointing at the feature doc; note `thinking.delta` = spinner, never reasoning; keep the file ~200 lines
- [ ] `docs/architecture.md`: hydration section (#26 preserves reasoning rows, new tool-row fields) and event list (`message.interim`, `thinking.delta`)
- [ ] add a `docs/backlog/` item for REST `/api/sessions/{id}/messages` output recovery after reload
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems — informational only*

**Manual verification**
- On device against a live agent: a long multi-tool turn (live expanded → collapse → finish),
  scrolled-up auto-collapse (no jump), reconnect mid-turn (#98 replay + #26 hydrate keep the
  fold sane), cold relaunch of an old session (headers show "Worked for …" from timestamps).
- Judge expand/collapse feel: plain snap vs a short crossfade on the collection view; adopt
  the crossfade only if it doesn't flicker self-sizing cells.
- iPad regular width: header/summary lines inside the 760 pt readable column.
- VoiceOver: header, summary and call lines announce as buttons with state (expanded /
  collapsed).

**External**
- Older agents without `message.interim` / tool `args`: confirm graceful degradation on the
  oldest agent version still in use.
- TestFlight build after each phase PR (internal by default).
