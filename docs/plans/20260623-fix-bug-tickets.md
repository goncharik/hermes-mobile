# Fix open bug-tagged GitHub tickets (#17, #26, #27)

## Overview

Address all three open GitHub issues labeled `bug`, ordered by risk (data/correctness
first, UI polish last):

- **#17 — "session not found" on the next outbound RPC after background→foreground.**
  The gateway socket reconnects and `session.resume` *appears* to recover, but the next
  `prompt.submit`/attach fails with `session not found` because the client keeps a stale
  `liveSessionID` the server has invalidated. Reporter confirms it is **distinct** from the
  already-merged #22 state-sync work. (Highest risk: silently breaks sending.)

- **#26 — In-flight thinking + streaming tool-call rows vanish on background→foreground.**
  On foreground, `applyActivate` rebuilds the transcript **wholesale** from
  `response.messages` + `inflight`, but `SessionInflight` carries only `user`/`assistant`/
  `streaming` (**no reasoning, no tools** — verified). The live thinking row and tool-call
  rows are wiped and never re-seeded, so the thinking block restarts and streamed tool calls
  disappear.

- **#27 — Markdown support + chat UI restructure.** `MarkdownText` renders prose
  line-by-line with `inlineOnlyPreservingWhitespace` parsing — no **headers / blockquotes /
  tables**. Agent responses aren't fully copyable (only user `Text` has `textSelection`).
  The ticket also asks for a **full restructure**: bubbles only for user messages; assistant
  text, tool calls, and thinking blocks rendered as plain text with no bubble wrapper
  (Anthropic Claude iOS app as reference).

These benefit the chat experience's correctness (#17, #26) and readability (#27). Only the
iOS app in this repo is touched — no server/plugin/gateway changes.

## Context (from discovery)

Files/components involved:
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — the reducer: `.ready` →
  `hydrate` → `session.resume` → `applyActivate` (wholesale transcript replace, in-flight
  seeding); `.foreground` reconnect; `.composerSubmitted`/attach use `state.liveSessionID`;
  `activateResult`/`sessionResult` failure handling (swallows `.disconnected` silently).
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` — `GatewayError` enum with
  `isUnknownMethod`/`isDisconnected` matchers; `send`/`connect`.
- `HermesKit/Sources/HermesKit/Models/Session.swift` — `SessionHandle`, `ActivateResponse`,
  `SessionInflight` (user/assistant/streaming only).
- `HermesKit/Sources/HermesKit/Models/MarkdownSegment.swift` — pure prose/fenced-code split.
- `HermesMobile/Sources/Features/Chat/MarkdownText.swift` — line-by-line prose rendering,
  inline-only Markdown, list markers, `CodeBlockView`.
- `HermesMobile/Sources/Features/Chat/MessageBubbleView.swift` — user/assistant bubble
  (`bubbleColor` background); `ToolStatusView.swift` (`.secondarySystemBackground` bubble);
  `ThinkingIndicatorView.swift`; `ChatView.swift` `rowView`/`transcriptCell` (already has a
  per-row context-menu `Copy` → `.copyRow(id:)`).

Related patterns found:
- Server-authoritative hydrate: `session.resume` (NOT `session.activate`); server wins,
  transcript replaced wholesale. Deterministic content-derived `ChatRow.ID`
  (`ChatRow.deterministicID`). Capability-gating via `GatewayError.isUnknownMethod`.
- `GatewayError` already exposes typed matchers — adding `isSessionNotFound` follows the
  `isUnknownMethod` precedent.
- Pure, testable logic lives in HermesKit; views stay thin. Markdown block parsing belongs
  in `MarkdownSegment` (pure, `MarkdownSegmentTests`), rendering in `MarkdownText`.

Dependencies identified:
- `SessionInflight` cannot supply reasoning/tools (mirrors desktop `SessionInflightTurn`), so
  #26 must **preserve client-side live rows**, not read a richer server payload.
- #17 fix relies on a stored session id to re-resume against — confirm `session.create`
  populates `storedSessionID` (see Task 1 investigation).

## Development Approach

- **Testing approach**: Regular (implement, then write/update tests within the same task).
- Complete each task fully before moving to the next; small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** (HermesKit reducer/unit tests via
  `TestStore` + `@Dependency` + `TestClock`; snapshot tests for view changes). Tests are a
  required deliverable, not optional. Cover success + error/edge cases.
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run tests after each change; maintain backward compatibility (token-mode requests stay
  byte-identical; single-profile requests unchanged).
- Commit at each task completion (per-task commits, not batched).

## Testing Strategy

- **Unit/reducer tests**: required every task. Use `script -q /dev/null swift test
  --package-path HermesKit` (or `make test`) for live output. New cases in
  `HydrateTests`, `ChatReductionTests`/`ChatInteractionTests`, `MarkdownSegmentTests`,
  `GatewayEventDecodingTests`/a new `GatewayErrorTests`, `TranscriptReconstructionTests`.
- **Snapshot tests**: `make snapshot` (assert) / `make snapshot-record` (re-record). #27 view
  changes require re-recording `ChatSnapshotTests` (and any markdown fixture snapshots). Row
  timestamps are pinned for determinism.
- No project e2e/UI-driver suite beyond snapshot tests; manual TestFlight verification of the
  background→foreground flows is listed under Post-Completion.

## Solution Overview

- **#17**: add a typed `GatewayError.isSessionNotFound` matcher; make outbound RPCs
  (`prompt.submit`, the attach uploads, `session.title`) **self-heal** — on a
  `session not found` failure, transparently `hydrate(storedSessionID)` to obtain a fresh
  live id, then retry the RPC **once**; surface the error only if the re-resume or the retry
  also fails. Stop silently swallowing a real server `session not found` from the foreground
  `session.resume`.
- **#26**: in `applyActivate`, when the hydrate reports a still-**running** turn, **preserve**
  the client's existing in-flight live rows (thinking + tool rows + any streaming assistant
  row tracked by `thinkingRowID`/`toolRowIDs`/`streamingRowID`) instead of discarding them,
  re-appending them after the reconstructed authoritative history so the thinking block and
  tool calls survive the round-trip. Completed turns still replace wholesale (server wins).
- **#27**: (a) extend the pure Markdown parser to recognize **headers, blockquotes, tables**
  and render them as distinct blocks; (b) make assistant messages **fully copyable** (inline
  `textSelection` across the rendered text + the existing row `Copy`); (c) **restructure** so
  only user messages keep a bubble — assistant text, tool rows, and thinking rows render as
  bubble-less plain content (Claude-app style).

## Technical Details

- `GatewayError.isSessionNotFound`: case-insensitive match on the `server(String)` message
  containing "session not found" (mirrors `isUnknownMethod`'s "unknown method" match).
- Self-heal helper in `ChatFeature`: a private `reduce`-side effect that, given a failed
  outbound action + its rebuild closure, runs `gateway.send("session.resume", …)`, applies
  the fresh live id, and replays the original RPC once. Guarded so it never loops (single
  retry; second failure surfaces the banner).
- `applyActivate` change: capture `preservedInFlightRows = running ? [thinking row + tool
  rows in transcript order] : []` **before** `state.transcript` is replaced; after rebuilding
  from `messages` and seeding the inflight user/assistant rows, re-append the preserved rows
  and restore `thinkingRowID`/`toolRowIDs`/`streamingRowID` so subsequent deltas reconcile
  in place. Keep the "thinking row last" contract (`keepThinkingLast`).
- Markdown blocks: add cases to `MarkdownSegment` (e.g. `.heading(level:text:)`,
  `.blockquote(lines:)`, `.table(headers:rows:)`) or an analogous block model; parser stays
  pure and line-driven (fences still take precedence). `MarkdownText` renders each block:
  headings → scaled bold `Text`; blockquote → indented bar + secondary text; table → a
  `Grid` with header row. Inline Markdown still applied within cells/lines.
- Copyability: wrap assistant rendered content in `.textSelection(.enabled)`; verify the
  existing `.copyRow(id:)` context-menu copies the full row text (`ChatRow.copyText`/
  `displayText`).
- Restructure: `MessageBubbleView` drops the `.background(bubbleColor …)` for
  `role == .assistant` (plain leading-aligned text, full width); `ToolStatusView` drops its
  `.secondarySystemBackground` rect; `ThinkingIndicatorView` stays bubble-less. User messages
  retain the trailing bubble.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and in-repo doc/CLAUDE.md updates.
- **Post-Completion** (no checkboxes): manual TestFlight reproduction of the
  background→foreground flows (#17, #26) and visual verification of #27 on device; closing
  the GitHub issues.

## Implementation Steps

### Task 1: Investigate #17 + add `GatewayError.isSessionNotFound`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/GatewayErrorTests.swift`

- [x] Reproduce #17 against a live agent (static analysis — live repro not automatable in
      sandbox). Findings recorded below under `## Investigation notes (#17)`: `session.create`
      may return `stored_session_id == nil` for a fresh session; foreground `session.resume`
      failures are swallowed as `.reconnecting` without refreshing/clearing the stale
      `liveSessionID`; `prompt.submit`/attach use `state.liveSessionID` (refreshed only by a
      successful `applyActivate`).
- [x] Add `var isSessionNotFound: Bool` to `GatewayError` — case-insensitive match on
      `server(message)` containing "session not found" (mirrors `isUnknownMethod`).
- [x] Write tests for `isSessionNotFound` (matches server "session not found" variants;
      false for `.disconnected`/`.timedOut`/`.authExpired`/other `server` messages).
- [x] Run tests — must pass before Task 2.

### Task 2: Self-heal outbound RPCs on "session not found" (#17 fix)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift` (or
  `ChatInteractionTests.swift`)

- [x] On `prompt.submit` failure where `error.isSessionNotFound`, transparently re-resume:
      `session.resume(storedSessionID)` → apply the fresh `liveSessionID` → replay
      `prompt.submit` **once**; surface the banner only if re-resume or the retry fails.
      Guard against retry loops (single retry).
- [x] Apply the same self-heal to the attach-upload path and `session.title` rename
      (they also use `liveSessionID`).
- [x] Stop silently swallowing a real server `session not found` from the foreground
      `session.resume`/`activateResult(.failure)` path: distinguish it from a benign
      `.disconnected` drop and trigger a re-resume/recreate rather than leaving a stale
      `liveSessionID`.
- [x] If investigation shows `storedSessionID` is `nil` for fresh sessions, ensure it is
      captured from `session.create`'s handle (and/or fall back to `session.create` when no
      stored id exists), so re-resume always has a target.
- [x] Write reducer tests: foreground `prompt.submit` returns `session not found` →
      reducer re-resumes (assert `session.resume` effect) → applies new live id → retries
      submit → succeeds with no error banner. Add the failure-of-retry case (banner shown).
- [x] Write a test for the attach path self-heal (success + retry-failure).
- [x] Run tests — must pass before Task 3.

### Task 3: Preserve in-flight thinking + tool rows across foreground (#26 fix)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`applyActivate`)
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`

- [x] In `applyActivate`, when `running == true`, capture the existing in-flight live rows
      (the thinking row via `thinkingRowID` and tool rows via `toolRowIDs`, in transcript
      order) **before** the wholesale transcript replace.
- [x] After rebuilding from `messages` and seeding the inflight user/assistant rows,
      re-append the preserved thinking + tool rows and restore
      `thinkingRowID`/`toolRowIDs`/`streamingRowID` so subsequent deltas reconcile in place;
      preserve the "thinking row last" contract.
- [x] Confirm a **completed** turn (`running == false`) still replaces wholesale (server
      wins) — no preserved live rows leak into a finished transcript.
- [x] Reconcile the elapsed timer continuity with the preserved thinking row (existing
      `reconcileTurnTimer` anchor behavior must still hold).
- [x] Write reducer tests: hydrate with `running == true` while client has a live thinking
      row + N tool rows → assert they survive (ids/content preserved, thinking last);
      hydrate with `running == false` → assert wholesale replace (no leftover live rows).
- [x] Run tests — must pass before Task 4.

### Task 4: Markdown block support — headers, blockquotes, tables (#27 part a)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/MarkdownSegment.swift`
- Modify: `HermesMobile/Sources/Features/Chat/MarkdownText.swift`
- Modify: `HermesKit/Tests/HermesKitTests/MarkdownSegmentTests.swift`

- [x] Extend the pure parser to classify **headers** (`#`..`######`), **blockquotes**
      (`>`), and **tables** (`| … |` with a `---` separator row), with fenced code still
      taking precedence; unterminated/odd markup degrades to prose (lenient, never crashes).
- [x] Render the new blocks in `MarkdownText`: headings as scaled bold `Text`; blockquote
      as an indented bar + secondary-styled lines; table as a `Grid` (header row emphasized),
      inline Markdown still applied within cells/lines.
- [x] Write parser tests (success: each block type; edge: heading with trailing `#`,
      nested/lazy blockquote, table without separator → prose, mixed prose+table+code).
- [x] Run tests — must pass before Task 5.

### Task 5: Full copyability of agent responses (#27 part b)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/MessageBubbleView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/MarkdownText.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/ChatRow.swift` (only if a `copyText` accessor
  is needed)
- Modify: `HermesKit/Tests/HermesKitTests/RowIdentityTests.swift` or
  `TranscriptReconstructionTests.swift`

- [x] Enable `.textSelection(.enabled)` across the assistant rendered Markdown so any part
      of an agent response can be selected/copied (not just the per-block code button).
- [x] Verify the existing row context-menu `Copy` (`.copyRow(id:)`) yields the full row's
      plain text for message/thinking/tool rows; add a `ChatRow` copy-text accessor if the
      current source is incomplete.
- [x] Write a unit test for the row copy-text accessor (assistant message, thinking,
      tool) covering full-content extraction.
- [x] Run tests — must pass before Task 6.

### Task 6: Bubble-less chat restructure (#27 part c)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/MessageBubbleView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ToolStatusView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ThinkingIndicatorView.swift` (if it carries a
  bubble background)
- Modify: `HermesMobileTests/ChatSnapshotTests.swift` + `__Snapshots__`

- [x] Remove the bubble wrapper for `role == .assistant` in `MessageBubbleView` (plain
      leading-aligned, full-width text); keep the trailing user bubble.
- [x] Remove the `.secondarySystemBackground` bubble from `ToolStatusView`; render tool rows
      as bubble-less plain content (keep tap-to-detail affordance and state styling).
- [x] Ensure thinking rows render bubble-less and consistent with the new layout
      (`ThinkingIndicatorView` already had no bubble background — left as-is, spacing fits).
- [x] Re-record affected snapshots (`make snapshot-record`) and review the diffs for the new
      Claude-app-style layout; then `make snapshot` must pass. (Re-recorded on a Mac with the
      iOS 26.2 simulator; `make snapshot` passes against the new baselines.)
- [x] Run reducer tests + snapshot tests — must pass before Task 7. (HermesKit `swift test`:
      593 tests pass; `make snapshot`: TEST SUCCEEDED.)

### Task 7: Verify acceptance criteria

- [x] #17: a foreground after backgrounding a new session no longer fails the next
      `prompt.submit`/attach with `session not found` (verified via `SelfHealTests.swift`:
      `promptSubmitSelfHealsOnSessionNotFoundThenSucceeds`, the retry-failure and
      re-resume-failure banner cases, both attach-path cases, and
      `foregroundResumeSessionNotFoundRecreatesSession`; manual TestFlight spot-check of the
      live background→foreground repro tracked in Post-Completion — not automatable in sandbox).
- [x] #26: backgrounding mid-thinking and returning preserves the thinking block + streamed
      tool calls (no restart) — verified via `HydrateTests.swift`:
      `hydrateRunningPreservesLiveThinkingAndToolRows` (running==true preserves thinking + tool
      rows, thinking last), `hydrateNotRunningWipesLiveThinkingAndToolRows` (running==false
      wholesale replace), and `repeatedHydrateOfRunningTurnKeepsStableInflightIDs`.
- [x] #27: headers/blockquotes/tables render (`MarkdownSegmentTests` — headers each level,
      trailing-hash strip, 7-hashes-not-header, inline markdown in headers, multi-line/lazy
      blockquotes, tables with/without separator + alignment + surrounding prose); agent
      responses are fully copyable (`ChatRowCopyTests` for message/streaming/tool/status +
      `.textSelection(.enabled)` on the assistant Markdown in `MarkdownText.swift`); only user
      messages have bubbles (bubble-less snapshots re-recorded in Task 6).
- [x] Run the full suite: `script -q /dev/null swift test --package-path HermesKit` (593 tests
      pass, 45 suites) and `make snapshot` (71 tests pass — TEST SUCCEEDED).

### Task 8: [Final] Update documentation

- [ ] Update `CLAUDE.md` if new conventions emerged (e.g. the self-heal-on-`session not
      found` RPC pattern; in-flight-row preservation on hydrate; Markdown block rendering).
- [ ] Update `README.md`/`docs/` only if user-facing behavior described there changed.
- [ ] Move this plan to `docs/plans/completed/`.

## Investigation notes (#17)

*Static analysis — no live agent in the sandbox, so this is a code read of `ChatFeature.swift`
(`.ready` / `hydrate` / `createSession` / `applyActivate` / `.foreground` / `.composerSubmitted` /
`activateResult` failure handling), `Session.swift` (`SessionHandle` / `ActivateResponse` /
`SessionInflight`), and `HermesGatewayClient.swift` (`send` / `GatewayError`).*

**Symptom (from the ticket).** After background→foreground on a fresh session, the socket
reconnects and `session.resume` *appears* to recover, but the next outbound RPC (`prompt.submit`
or an attach upload) fails with `session not found`.

**Three concrete questions answered by the code:**

1. **Does `session.create` populate `storedSessionID`?** *Partially / not guaranteed.*
   `SessionHandle` decodes `stored_session_id` (`Session.swift:81`), and the success handler
   sets `state.storedSessionID = handle.storedSessionID ?? state.storedSessionID`
   (`ChatFeature.swift:449`). So **if** the server returns a `stored_session_id` in the
   `session.create` result, it is captured. But a brand-new session that hasn't persisted a turn
   yet may return only the live `session_id` with `stored_session_id == nil`, leaving
   `state.storedSessionID == nil`. On the next `.ready` (foreground reconnect),
   `.ready` branches on `state.storedSessionID` (`ChatFeature.swift:976`): a `nil` stored id
   takes the `createSession` branch (creates *another* new session) rather than re-resuming the
   one in flight — so the in-flight session id is never refreshed and the original turn is
   orphaned. This is the root-cause hinge for Task 2's "fall back / capture stored id" checkbox.

2. **Does the foreground `session.resume` failure get silently swallowed?** *Effectively yes for
   the failure path.* On foreground, `.foreground` resets `hasRequestedSession` and reconnects
   (`ChatFeature.swift:497-509`); the fresh `.ready` re-`hydrate`s when a stored id exists.
   If `session.resume` throws (or returns malformed), it lands in `activateResult(.failure)`
   (`ChatFeature.swift:471-480`), which only sets `state.status = .reconnecting` and raises a
   banner *unless* the error is `.disconnected`. Crucially **it leaves `state.liveSessionID`
   unchanged** — there is no re-resume, no recreate, no clearing of the stale id. A genuine server
   `session not found` from `session.resume` is therefore not distinguished from a benign socket
   drop and never triggers recovery; the stale `liveSessionID` survives. (And when stored id is
   `nil` per (1), `hydrate` isn't even attempted — `createSession` runs instead.)

3. **What id does `prompt.submit` use?** **`state.liveSessionID`** (the short live/runtime id) —
   `ChatFeature.swift:512` guards on it and passes it as `session_id` at lines 537 (attach path)
   and 571 (plain submit). The attach uploads (`uploadAttachment`) and `session.title` rename
   (line 923) use the same `liveSessionID`. After a background→foreground the agent may have torn
   down / rebuilt the in-memory live session and assigned a **new** live id; the only thing that
   refreshes `state.liveSessionID` is a *successful* `applyActivate` (`ChatFeature.swift:1329`,
   `state.liveSessionID = response.sessionID`). If resume failed/was swallowed (or never ran due
   to a `nil` stored id), `prompt.submit` reuses the now-stale `liveSessionID`, producing the
   server's `session not found`.

**Most-likely root cause.** The client keeps a stale `liveSessionID` after foreground because
(a) a fresh session may have no `storedSessionID` to re-resume against, so `.ready` recreates
instead of re-resuming, and (b) even when a stored id exists, a `session.resume` failure is
swallowed as `.reconnecting` without refreshing or clearing `liveSessionID`. The next
`prompt.submit`/attach then sends the invalidated live id → `session not found`.

**What this implies for Task 2.** (i) Add the typed `GatewayError.isSessionNotFound` matcher
(done in Task 1) so the submit/attach/rename paths can detect the condition. (ii) On a
`session not found` from an outbound RPC, self-heal by re-resuming `storedSessionID` to obtain a
fresh `liveSessionID`, then replay the RPC once (guarded against loops). (iii) Stop swallowing a
real `session not found` from the foreground `session.resume` — distinguish it from
`.disconnected` and trigger re-resume/recreate. (iv) Ensure `storedSessionID` is captured from
`session.create` (and fall back to `session.create` when no stored id exists) so re-resume always
has a target.

## Post-Completion
*Items requiring manual intervention or external systems — informational only.*

**Manual verification (TestFlight / device):**
- #17: new session → one turn → background → foreground → reconnect → send a message and add
  an attachment; both must succeed (no `session not found`).
- #26: send a long prompt; while the agent is thinking/running tools, background the app and
  return; the prior thinking text and tool-call rows must remain (block does not restart).
- #27: visually confirm headers/blockquotes/tables render, agent text is selectable/copyable,
  and the bubble-less assistant/tool/thinking layout matches the Claude-app reference.

**External system updates:**
- Close GitHub issues #17, #26, #27 with references to the implementing commits/PR once the
  fixes ship in a TestFlight build and manual verification passes.
- #26 known limitation: thinking/tool content that streamed **while the app was backgrounded**
  (socket dead) cannot be recovered (no server replay; `SessionInflight` has no reasoning/
  tools field) — pre-background content is preserved, mid-background events are still lost.
  Note this on the issue if the reporter expects full mid-background replay.
