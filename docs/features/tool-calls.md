# Tool-call display: turn folds, run summaries, per-tool views (#45, #55)

The short rules live in `CLAUDE.md` → "Transcript & chat UI"; this doc is the full contract.
Design history: `docs/plans/completed/20261104-tool-call-display.md`.

A turn's tool activity folds out of the way of its reply. The visual reference is the T3 Code
mobile app; the run-summary vocabulary, per-tool titles and failure heuristics mirror the
desktop (`apps/desktop/src/components/assistant-ui/tool/run-summary.ts`,
`tool/fallback-model/`, `tool/fallback.tsx`).

- A **finished** turn renders `[user] [Worked for 4m 31s ›] [final reply]`: interim
  commentary, tool runs and reasoning fold behind the header, collapsed.
- A **running** turn's header shows the agent's spinner line (else "Working") and the turn
  timer, with the latest `status.update` as a caption. It is expanded by default (T3 parity)
  and tappable to collapse (our extension). Collapsed, one live line names the current call.
- Consecutive calls fold into a **run summary** ("Read 1 file, ran 4 commands, and performed 1
  other action"). A **call line** is an icon plus a parsed target (`Ran pytest -q`); tapping it
  **expands a capped, purpose-built body in place**, and "Show all" / "Details" opens the
  detail sheet.

## What feeds the fold (wire events)

- **`thinking.delta` is the agent's spinner, never reasoning.** Its frames (`ಠ_ಠ pondering…`,
  provider-wait diagnostics) are rewrites. They decode to `.spinnerFrame` and REPLACE
  `State.turnActivityLabel` (trimmed, empty → nil). The label is never appended, never written
  into a row and never persisted. It is cleared on `tool.start`, `message.delta`,
  `message.interim` and every turn terminal. Desktop parity: `message-stream.ts` keeps it out of the transcript too.
- **Reasoning comes only from `reasoning.delta` (`.reasoningDelta`) and `reasoning.available`**,
  as one `.reasoning(text:)` row per BURST. Deltas append to the open burst
  (`reasoningRowID`) only while it is the last row. A `tool.start`, a new `tool.complete` row
  or a `message.delta` after it closes the burst (`closeReasoningBurst`, the single close
  path), so at most one burst is ever open. `reasoning.available` (sent only when reasoning was
  not streamed) is skipped when the open burst already contains its text, else appended like a
  delta.
- **`status.update`** → `State.turnStatus`, the live header's caption. Transient: cleared at
  `message.start` and every terminal.
- **`message.interim`** `{text, already_streamed, turn_id?, segment?}` seals interim commentary
  (desktop `finalizeInterimAssistantMessage`). A streaming row is sealed in place with the
  sealed text whatever `already_streamed` says, and the next delta starts a new row. With no
  streaming row, a same-text newest assistant row of the turn is a duplicate delivery; anything
  else lands as a completed row (blank skipped). A seal stamped with both `turn_id` and
  `segment` is recorded in `sealedSegments` (reset at `message.start`), so a re-sent seal is a
  no-op. A #98 replay fold skips only STREAMED seals: an unstreamed seal is the only delivery
  of its text.
- **`message.complete`** with `response_reused` is skipped when any of the turn's assistant rows
  already contains the final text; without the flag (older agents) it is skipped only when the
  newest assistant row's normalized text equals it. The final text never overwrites a sealed
  interim row.
- **`tool.start` `args`** and **`tool.complete` `result`** (structured JSON) ride into the row
  next to the legacy `context` / `args_text` / `result_text`. Start and complete merge on
  `toolRowIDs[tool_id]`; args from the start survive a complete that omits them.
- **Timestamps.** Live rows (user echoes, assistant segments, tools, reasoning bursts) are
  stamped from the `date` dependency on append and on completion. Status, command-output and
  inflight-seeded rows stay unstamped.

## Row model

`ChatRow.Kind` is `message` | `tool(ToolCall)` | `reasoning(text:)` | `status` |
`commandOutput`. `.reasoning` replaced the old one-per-turn `.thinking` row (discriminator
`"reasoning"`). Timer, frozen duration and status moved off the row into state.

- `ToolCall {name, title, state, detail, durationS}`. `title` is the server `context` /
  `summary`, falling back to the name. A labelled static `.tool(name:title:state:detail:durationS:)`
  factory keeps old call sites constructing unchanged.
- `ToolDetail {argsText, args, result, resultText, inlineDiff}`. `result: JSONValue?` is new.
- `ChatRow.timestamp: Date?` is `decodeIfPresent`, takes part in `Equatable` (so `TestStore`
  and observation stay honest) and is EXCLUDED from id derivation.
- Old cached snapshots: a legacy `.thinking` row or a pre-`ToolCall` tool row fails its
  per-row decode and is skipped (`ChatSnapshotStore` decodes rows with `compactMap(try?)`);
  the rest of the snapshot still paints and the hydrate rebuilds. No legacy decoder.

## Turn structure (`TurnStructure.swift`)

`turnSpans(_:runningTurnOrdinal:)` splits rows into `TurnSpan`s, delimited by user message rows
only.

- **Ordinal** = user rows before the turn's user row. Rows before the first user row (a branch
  seed's reply, a compressed history's summary) are the **preamble**, ordinal −1, never folded.
- **Running turn** = the newest turn while `isTurnLive` (set at `message.start` and by a running
  hydrate, cleared at every terminal). `isSending` alone does not count: it is also true for a
  slash exec and between submit and `message.start`.
- **Final reply** = the turn's last assistant `.message` row, finished turns only (`nil` while
  running: any segment so far may be interim). It may be blank or incomplete. The view still
  needs `isComplete` + non-blank text for the action bar; read-aloud needs `isComplete`.
- **Duration** = latest row timestamp − the user row's timestamp (clamped at 0), finished turns
  only; `nil` when either is missing (older agents, legacy cached rows) → the header says
  "Worked".

Consumers: `State.finalReplyRowIDs` gates `MessageActionBar` and branch (the cell builder gets
the set once per render, not a per-cell store read); `State.completedReplies` is the read-aloud
anchor's scale (`docs/features/read-aloud.md`). Interim commentary gets no action bar and is
never read aloud. Known limit: a turn another client started (a `message.start` with no user
row of ours) merges into the previous span until the next hydrate. While it runs, the previous
reply loses its action bar; once it finishes, its reply becomes the span's final reply and the
previous reply folds behind the "Worked for …" header as interim commentary, with the duration
spanning both turns.

## Display items (`TranscriptFold.items`)

The pure layout lives in `Models/TranscriptFold.swift` under the namespace **`TranscriptFold`**
(the app target's own `TranscriptLayout` enum, the collection view's metrics, would shadow
it). `TranscriptFold.items(rows:expansion:runningTurnOrdinal:liveLine:ordinalOffset:)` flattens
the windowed rows into `TranscriptItem`s, which is what `CollectionTranscriptView` diffs:

| Item | Id | What |
|---|---|---|
| `.turnHeader(TurnHeader)` | derived from `turn` + the user row id | the fold header, right after the user row |
| `.runSummary(RunSummary)` | derived from `run` + the first tool row id | a run of ≥ 2 calls |
| `.toolCall(ToolCallItem)` | the row's id | one call line (row + `CallKey` + `isExpanded` + `isLive`) |
| `.toolBody(ChatRow)` | derived from `body` + the tool row id | an expanded call's body, after its line |
| `.row(ChatRow)` | the row's id | message / reasoning / status / command output, as itself |
| `.liveIndicator` | fixed `"liveTurnIndicator"` | live label + timer for a running turn with no header |

Every id is deterministic: the same rows and expansion give the same items and ids, and a run's
id holds while the run grows.

- **Header.** Emitted for the running turn always, and for a finished turn only when it has
  foldable content: a plain question and answer gets no header that expands to nothing. The
  running preamble gets no header; it ends the items with `.liveIndicator` instead, so a live
  turn always shows its label and timer. Header title logic is `TurnHeader.finishedTitle` /
  `liveLabel` in HermesKit; the view lays the timer beside the label so a long provider-wait
  line truncates, not the timer.
- **Foldable rows** = tool, reasoning and assistant messages, minus the final reply and the
  running turn's streaming row (it may be the answer). Status and command-output rows never
  fold. A collapsed turn hides exactly the foldable rows, so what stays keeps transcript order.
- **Runs.** A run spans its first to last tool call. Reasoning between two calls stays inside
  it; reasoning after the last call renders after the run. Runs break on assistant text and on
  never-folded rows (they must stay visible in place). ≥ 2 calls → a summary line, listing its
  calls only when expanded; 1 call → the call line directly.
- **Live line** (collapsed running turn only): the newest running call's present-tense title
  ("Running pytest -q"), else the spinner label, else nothing.
- **Ordinals are absolute.** `RunKey` counts every run in the turn (single-call runs included,
  so a run growing 1 → 2 keeps its key); `CallKey` counts every tool row in the turn whatever is
  showing. `ordinalOffset` = user rows before the window.
- **Window snap.** `State.windowStart` stays RAW; `snappedWindowStart` (derived) snaps it down to
  the containing turn's user row, walking back at most one page (a longer turn keeps the raw
  start and shows headerless until older rows load). `visibleRows`, `hasMoreAbove`
  and `transcriptItems` read the snapped start; the many "parked at the bottom" checks keep
  comparing raw values, so a snap never reads as a scroll-up. Paging steps from the snapped
  start.

## Expansion state (`FoldExpansion`)

`ChatFeature.State.fold`: in memory, per slot, keyed by ORDINALS (never row ids), so it
survives the hydrate's live → deterministic id rewrite.

- `turnOverride: [Int: .expanded | .collapsed]` (absent = default). Running → shown unless
  `.collapsed`; finished → shown only when `.expanded`. So a finish collapses the turn **unless
  the user's last action on that header was expand**. A header tap always RECORDS an explicit
  override, even one that matches the default; overrides are never removed by a tap.
- `expandedRuns: Set<RunKey>` (runs default collapsed); `expandedCalls: Set<CallKey>`.
- Actions: `turnHeaderTapped(ordinal)`, `runSummaryTapped(RunKey)`, `toolCallTapped(CallKey)`.
  `toolTapped(id:)` is the body's "Show all" / "Details" → `presentedTool` (the sheet).
- Every hydrate runs `fold.prune(turnCount:)`: a hydrate that removed turns (`/undo`, the
  post-slash refresh) must not let a stale choice latch onto the next turn reusing the ordinal.
  A running hydrate keeps the running turn because `inflight.user` re-seeds its user row.
- Session switch and logout reset it structurally (a fresh `ChatFeature.State`, or the slot is
  nilled); `.teardown` clears it explicitly too.

## Rendering

- **`CollectionTranscriptView` keys on `TranscriptItem.ID`**, but its open / hydrate / prepend /
  slide classification (`TranscriptDiffKind`) runs on the RAW window's row ids
  (`windowRowIDs`, from the unsnapped `windowStart`). A collapse removes items, which an
  item-id diff would read as a reset and jump to the bottom; a fold change leaves row ids
  untouched. The raw window, not the snapped one: at the bottom it keeps its fixed size across
  a live append (#125's `.slide`), while the snapped window shrinks each time its start passes a
  user row — the shape of a hydrate re-trim (`.reset`), which would yank a scrolled-up reader.
- **No diff apply on an unmeasurable view (#128).** `dataSource.apply` self-sizes every cell
  against the current frame. One landing with no window, a non-finite or zero height, or a width
  that leaves the row no positive width (`≤ 2 × TranscriptLayout.horizontalSectionInset`)
  measures cells at a 0pt fitting width — the suspected trigger of iOS 18's
  `_UIContentViewAssertValidFittingSize` (not reproduced on iOS 26.5/27.0). So
  `Coordinator.apply` first checks the pure `TranscriptScrollMath.canApplySnapshot` gate; on a
  "no" it stores only the LATEST update in `pendingApply` (overwritten, never queued) and
  returns. `didLayout()` flushes it through the same `apply`, before the open-at-bottom settle,
  once the gate passes. `TranscriptCollectionView.didMoveToWindow` schedules a layout pass on
  re-attach so a window-less deferral flushes even at an unchanged size. Nothing in the diff
  state (`currentOrder` / `currentRowIDs`) moves until the flush, so the gap classifies as one
  change. The open's FIRST update always defers (zero frame, no window), and its flush is what
  takes the open jump. Never call `dataSource.apply` outside this gate.
- **Fold changes hold the reader's place.** Pinned → normal re-pin. Scrolled up → the first
  visible surviving item keeps its on-screen y, through the same same-pass anchor hold as a
  #125 window slide (pure `TranscriptScrollMath.holdsReaderAnchor` / `preservationAnchor` /
  `offsetAfterAnchorShift`), falling back to the final reply when everything visible folded
  away. This covers auto-collapse on finish, user taps and expanding a body (an insert keeps
  every old item, so nothing above the tapped line moves).
- **Taps** on headers, summaries and call lines are `onTapGesture` + button traits announcing
  the expanded state (a `Button` inside the transcript's scroll view lost taps).
- **The running header** reads `turnSeconds` / `turnActivityLabel` / `turnStatus` inside a small
  `TurnHeaderCell`, so the per-second tick re-renders only that hosted cell. `TurnHeaderView`
  itself is pure. The label shimmers while running (flat under reduce-motion).
- **Reasoning line**: brain icon + `TranscriptFold.reasoningPreview` (first sentence, `**bold**`
  markers dropped); a tap discloses the full burst with inline markdown. The disclosure is
  view-local `@State`, `.id`-keyed on the row so a reused cell starts closed.
- **Chevrons**: header and call lines `›` folded / `⌄` open; summary and reasoning lines
  `⌄` / `⌃`.
  Every call line in the fold expands, including one with no detail (it expands to the
  "unavailable" note rather than being a dead line).
- Views: `TurnHeaderView.swift`, `RunSummaryView.swift` (`FoldLine`, `RunSummaryView`,
  `ReasoningLineView`), `ToolStatusView.swift` (call line + SF Symbol per icon),
  `ToolBodyViews.swift` (`ToolBodyView`, `ToolBodyContent`), `ToolDetailSheet.swift`.

## Per-tool presentation (`ToolPresentation`)

`ToolPresentation(call:)` classifies a call from whatever it carries: the live shape
(`args` + `result`), the hydrated shape (cooked `args` + `context`, result only for edit tools)
or an older agent's bare `{name, context}`. `ToolCall.title` counts as the context unless it is
just the name. Known tools prefer their args keys and fall back to the context only when the key
is missing, so a `tool.complete` summary that overwrote the title ("Did 3 searches in 1.2s")
never becomes a target.

| Tool | Icon | Category | Target (args keys) | Title |
|---|---|---|---|---|
| `terminal` | terminal | run | `command` / `code` / context, shell-summarized (leading `cd …&&` and a pipe tail dropped, cap 160) | Ran / Running … |
| `execute_code` | terminal | run | first non-blank, non-`#` line of `code` | Ran code / Scripting |
| `read_file` | file | explore | basename of `path`/`file`/`filepath` + `L10-40` | Read / Reading … |
| `list_files` | file | explore | `path`/`directory`/`dir` (not in the line) | Listed files |
| `write_file`, `patch`, `edit_file` | edit | edit | `path`, else `result.path`, else parsed from the diff | Edited / Editing … |
| `search_files` | search | explore | `pattern`/`query` (cap 48, quoted) | Searched “…” |
| `web_search` | search | search | `query`/`search_term` (quoted) | Searched “…” |
| `session_search(_recall)` | search | search | `query` (quoted) | Searched history for “…” |
| `web_extract` | web | read | first URL → host + path | Read … |
| `browser_navigate` | web | browse | `url` → host + path | Opened … / Failed to open … |
| `browser_click/fill/snapshot/type/take_screenshot`, `browser_exec` | web / eye | interact | fixed (exec: step label from `code`) | Clicked page element, … |
| `vision_analyze` | eye | analyze | `question` (quoted) | Analyzed “…” |
| `image_generate` | eye | other | `prompt` (not in the line) | Generated image |
| `skill_view`, `skills_list` | skill | other | `name` (+ `file_path`) / `category` | Loaded skill: … |
| `delegate_task` | delegate | delegate | `tasks[].goal` / `goal` (N tasks when several) | Delegated … |
| `memory` | memory | other | context | Saved to memory / Memory write noted |
| `todo`, `clarify`, `cronjob` | generic | other | fixed | Updated todos, … |
| anything else | generic (`browser_*`/`web_*` → web, `skill*` → skill) | other | context, else the primary arg | `<Humanized name>: <context>` |

Titles always carry the verb ("Edited foo.tsx", not the desktop's bare basename, which leans on
its separate diff card).

**Outcome** (desktop `toolStatus`): no result → `.unknown` (neutral, no checkmark);
`success`/`ok == true` wins → `.success`; an `error`/`errors`/`failure`/`exception` key (≤ 5
levels), `success`/`ok == false`, or `status` matching error/failed/fatal → `.failure(message)`;
a non-zero `exit_code` fails only when there is no output; any other result → `.success`.
Routine errors become
**`.notice(message)`**: the explanation is kept but never red (`read_file` "File not found:",
`terminal` exit 1 with no output, `skill_manage` unless `ROLLBACK FAILED`, `memory` refusals).
Only `.failure` turns the icon red and counts as failed.

### Run summaries (`RunSummary`)

- One clause per kind of work, in the order the kind FIRST appeared in the run, "other" pinned
  last. This is not the desktop's fixed `CATEGORY_ORDER`, which cannot produce the T3 reference
  "Ran 6 commands and read 5 files"; first appearance reproduces all three T3 strings and still
  never reorders as a run grows.
- `read_file` is its own clause ("read N files", the T3 wording); listing / searching files is
  "explored N files". Skill tools count as "other actions".
- A settled lone item names its target only for edit, web search, page read and navigation
  ("Edited foo.swift", `Searched “q”`); commands, file reads and other actions count even
  alone ("Read 1 file, ran 4 commands, and performed 1 other action").
- Oxford join, first word capitalized; failures append after `; ` ("…; 1 tool call failed").
- **Live** = the layout's verdict: running turn AND a running call in the run (a call a stopped
  turn left `running` reads settled). Only the narrating clause (first running call, else the
  newest) is present tense, naming the call by its live title when it is the clause's only
  item ("Read 1 file and running pytest -q"). `ToolCallItem.isLive` uses the same rule.
- Icon: uniform category → the calls' shared tool icon (else the category's icon); mixed → a
  hammer.

### Bodies (`ToolPresentation.Body`)

Built on demand (`body` is computed from stored inputs, so summaries never pay for it):
`terminal(command?, exitCode?, stdout?, stderr?)` (`command` nil for `execute_code`),
`diff(path?, lines)`, `fileRead(path, range?, content?)`, `search(query?, hits ≤ 6,
totalCount?)`, `webPage(url, content?)`, `skill(name, file?, description?)`,
`delegate(goals)`, `generic(summary?, raw?)` and `unavailable(note:)`.

- A running call with no result shows what it has (`$ command`, path, query; "Waiting for
  output…"). A SETTLED call with no result is `.unavailable("Output isn't kept in history")`,
  except edit / skill / delegate bodies, which come from args or `inline_diff` and survive a
  reload.
- The diff parser (`ToolOutputFormatting.diffLines`) reads the RENDERED wire `inline_diff`
  (`agent/display.py`: `┊ review diff` header, `a/x → b/x` file lines, ANSI colors, an
  "omitted" footer) as well as raw unified diffs; `inline_diff` wins over a patch result's diff.
- Anything a body cannot parse falls back to `.generic` with the pretty-printed result (args
  while running). Data is never hidden.
- **Inline caps** (`Body.inline()`): 12 lines / 2 000 characters with ANSI stripped, ONE budget
  shared across a body's texts (stderr can drop out when stdout fills it), no ellipsis (the
  truncated flag drives "Show all"). Search, skill, delegate and unavailable bodies are never
  capped.
- The inline body is its own `.toolBody` item so its selectable text never competes with the
  line's tap. The outcome message heads it (red failure, grey notice). It holds no scroll
  views: long lines wrap and the cell self-sizes. Its footer is "Show all" when the caps cut
  something, else "Details"; both open the sheet.

### Detail sheet (`ToolDetailSheet`)

Takes the whole `ToolCall`. Nav title = the tool's wire name; header = icon (red on failure),
parsed title, duration (`ToolPresentation.durationLabel`) and an outcome badge (Succeeded /
Failed / Notice / Running; none for a reloaded call with no result, so no false success).
Body = the same `ToolBodyContent`, UNCAPPED. A collapsed **Raw** disclosure lists
`ToolCall.rawSections` (pure, unit-tested): Context, Arguments, Arguments (text), Result,
Result (text), Diff. Blank sections are skipped, and a "(text)" section appears only when it
isn't just the structured value re-serialized.

## Data availability: live vs reloaded

| | Live turn | Reloaded (`session.resume`) | Older agent |
|---|---|---|---|
| Target / title | `args` (+ context) | cooked `args` + `context` | `context` only |
| Terminal / read / search / web output | `result` | not kept → "unavailable" | `result_text` live, none reloaded |
| Edit diff | `inline_diff` / result | `display_metadata…inline_diff` + `content` | live `inline_diff` only |
| Skill / delegate body | `args` | `args` | context fallback |
| Turn duration | client clock | server `timestamp` | header says "Worked" |
| Reasoning | bursts | bursts | same |

Cooked history tool rows carry `content` only for `write_file` / `patch` / `skill_manage`.
`reconstructTranscript` keeps it as `resultText` always, plus a structured `result` when it
parses as a JSON object or array (the live `tool.complete` shape). The hydrated title is
`context ?? name`, the live shape, so an older agent's reloaded call keeps its target. A
`timestamp` of 0 maps to nil. Hydrate and the #26 running-turn preservation:
`docs/architecture.md` → "Session re-hydration".

## Out of scope

- Recovering terminal output and search hits after a reload via REST
  `GET /api/sessions/{id}/messages`. Reloaded calls say "Output isn't kept in history". Backlog:
  `docs/backlog/tool-output-lost-after-reload.md`.
- File edits as standalone diff cards outside runs (the desktop does this; the T3 reference
  folds them). Edits stay inside runs, the diff in the expanded body.
- `tool.generating`, `tool.progress` and `subagent.*` live tickers; a Settings toggle for the
  live-turn default (the header tap covers it).
- An expand/collapse crossfade: changes apply without animation; a crossfade is an on-device
  feel call, adopted only if it doesn't flicker self-sizing cells.

## Tests

HermesKit: `TranscriptLayoutTests`, `ChatFoldTests`, `TurnStructureTests`,
`ToolPresentationTests`, `ToolOutputFormattingTests`, `RunSummaryTests`, `ToolCallDetailTests`,
`ToolCallAcceptanceTests` (the #45 / #55 / older-agent acceptance cases driven through real
events), plus the fold cases in `ChatReductionTests`, `ReplayTests`, `HydrateTests` and
`ChatReadAloudTests`. Snapshots: `TurnFoldSnapshotTests`, `ToolBodySnapshotTests`,
`ToolDetailSheetSnapshotTests`.
