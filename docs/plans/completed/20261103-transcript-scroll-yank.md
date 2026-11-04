# Keep a scrolled-up reader in place when the live window slides (#125)

## Overview
- **Bug (#125)**: while a turn runs and emits tool calls, a reader who scrolls up gets yanked back to
  the bottom each time a new row lands. Expected: follow only when the reader was already at the
  bottom; otherwise keep the on-screen position and leave the jump-to-latest button.
- **Root cause**: the reducer keeps a fixed 50-row live window (`ChatFeature.State.initialWindow`).
  `maintainWindowAfterStreaming` re-pins `windowStart` to the bottom window after every event when
  the user hasn't loaded older pages (`wasAtBottomWindow`). So on any transcript of 50+ rows, every
  appended row (a `tool.start` row, the answer row, a user echo) drops the FIRST visible row.
  `TranscriptDiffKind.classify` then sees an old id missing — not a prefix, suffix, permutation, or
  superset — and returns `.reset`. `CollectionTranscriptView.apply(rows:)` treats `.reset` as a
  wholesale hydrate and jumps to the bottom regardless of pin state.
- **Why tool calls**: deltas mutate a row in place (no slide); tool calls add a row each, so a
  tool-heavy turn slides the window repeatedly. Short chats (< 50 rows) never slide and don't yank.
- **The reducer's "scrolled up" is coarser than the reader's**: it only knows "loaded older pages"
  (`ChatWindowingTests.streamingDoesNotYankScrolledUpUser` covers that). Scrolling up *within* the
  bottom window is invisible to it, and that is exactly the case that yanks.
- **Fix**: recognise the slide as its own diff shape and handle it in the renderer — follow when
  pinned, preserve the reader's anchor row when scrolled up. Stick-to-bottom stays renderer-local.

## Context (from discovery)
- `HermesKit/Sources/HermesKit/Models/TranscriptScrollMath.swift` — pure `TranscriptScrollMath`
  (pin threshold, `offsetAfterPrepend`) and `TranscriptDiffKind.classify` (the misclassification).
- `HermesMobile/Sources/Features/Chat/Transcript/CollectionTranscriptView.swift` —
  `Coordinator.apply(rows:)` (reset ⇒ jump branch), `preserveOffsetAfterPrepend`,
  `isAdjustingOffset` guard, `updatePinState`.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `initialWindow`/`pageSize`,
  `bottomWindowStart`, `visibleRows`, `maintainWindowAfterStreaming`, `reduceGatewayEvent`.
- Tests: `HermesKit/Tests/HermesKitTests/TranscriptScrollMathTests.swift` (classify suite, no slide
  case today), `HermesKit/Tests/HermesKitTests/ChatWindowingTests.swift` (window invariants).
- Measured hosted-layout precedent: `HermesMobileTests/MarkdownTableLayoutTests.swift` (`UIWindow`).
- No `docs/features/` doc covers the transcript renderer; the contract lives in CLAUDE.md
  ("History paginates client-side", "`CollectionTranscriptView` is the ONLY renderer") and the
  renderer/classifier doc comments.

## Development Approach
- **testing approach**: TDD for the pure HermesKit logic (write the failing regression first),
  regular for the renderer glue
- complete each task fully before moving to the next; small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- commit at each task completion (capitalized verb, no conventional prefixes)
- maintain backward compatibility: every existing classify/windowing test keeps its verdict

## Testing Strategy
- **unit tests** (`make test`): classifier slide shapes, anchor-shift math, and a reducer-level
  regression proving the live `tool.start` path produces the slide shape.
- **measured hosted-layout test** (`make snapshot` runs the `HermesMobileTests` target): the
  anchor row's on-screen y is unchanged after a slide apply while scrolled up. Layout fact, no
  debug counters or test hooks in production code — if it can't be written without them, drop it
  and record that here (project rule: no hosted behavior-probe tests).
- **snapshots**: no visual change expected; `make snapshot` must stay clean.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- **Approaches considered**:
  - **A. Classify the slide; renderer preserves the anchor** (chosen). Pure, unit-testable verdict
    in HermesKit; the renderer already owns follow/preserve; no new reducer state.
  - B. Freeze the reducer window while the reader is scrolled up (renderer reports pin state to
    the reducer). Fixes it at the source but moves stick-to-bottom knowledge into reducer state,
    against the "renderer-local" rule, and needs a re-trim path when the reader returns.
  - C. Hysteresis on window trimming (grow to 100, trim to 50). Only makes the yank rarer.
- **Slide rule** (in `classify`, after the permutation/superset checks): some old rows are gone
  but at least one survives, and the window did not both shrink and lose its head ⇒
  `.slide(droppedHeadCount:)` (`0` for a turn-end row removal). Survivor order is not checked.
- **What stays `.reset`** (jump to bottom): no old row survives, or the window shrank AND lost its
  head — notably a hydrate after paging up, which trims the reader's rows. Existing reset tests
  unchanged.
- **Renderer**: every `holdsReaderAnchor` update (`.slide`, `.appendOrMutate`) captures the
  reader's anchor before the apply — the topmost on-screen surviving row, else the surviving row
  nearest the viewport (a reader inside a tall dropped row). Right after the non-animated apply
  returns (same pass), `layoutIfNeeded`, measure the anchor's shift and, if it moved, set the
  offset to pre-apply offset + shift (clamped; a shift to the window top pages older rows). The
  prepend preserve runs in the same place. The apply's completion (a later pass) only jumps
  (open / `.reset` / a pinned `.slide`) or follows a pinned append with an animated scroll, both
  against the live pin state.
- **Deliberate contract change (flag in PR)**: a hydrate whose rows survive keeps a scrolled-up
  reader's position instead of jumping. A hydrate that removes the rows they were reading still
  jumps. Consistent with #125's intent.

## Technical Details
- `TranscriptDiffKind` gains `case slide(droppedHeadCount: Int)` plus `isPrepend` /
  `holdsReaderAnchor`.
- Classify sketch:
  ```swift
  guard let firstSurvivor = old.firstIndex(where: newSet.contains) else { return .reset }
  if new.count < old.count, firstSurvivor > 0 { return .reset }
  return .slide(droppedHeadCount: firstSurvivor)
  ```
- `TranscriptScrollMath.offsetAfterAnchorShift(previousOffsetY:anchorShift:contentHeight:viewportHeight:topInset:bottomInset:)`
  = `previousOffsetY + anchorShift` clamped to `[-topInset, maxOffsetY]`; it replaces
  `offsetAfterPrepend` (a prepend is a positive shift).
- `apply(rows:)` flow: classify → capture pre-apply offset, content height, and the anchor →
  `dataSource.apply(animatingDifferences: false)` → same pass: prepend preserve or anchor hold
  (skipped when the anchor moved ≤ 0.5pt, so a plain append leaves the offset alone) → completion:
  jump-and-settle, or the pinned animated follow. Offsets are written directly (`assignOffset`).
- Unverified on device: whether a fling continues smoothly across a hold.

## What Goes Where
- **Implementation Steps**: classifier, math helper, renderer glue, tests, CLAUDE.md/doc comments.
- **Post-Completion**: on-device repro of #125, TestFlight confirmation.

## Implementation Steps

### Task 1: Add the window-slide diff kind to the classifier

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/TranscriptScrollMath.swift`
- Modify: `HermesKit/Tests/HermesKitTests/TranscriptScrollMathTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatWindowingTests.swift`

- [x] write failing test: plain slide (old `[0..<50]`, new `[1..<51]`) ⇒ `.slide(droppedHeadCount: 1)`
- [x] write failing test: live tool-call slide (old `[r0…r48, thinking]`, new `[r1…r48, tool, thinking]`) ⇒ `.slide(1)`
- [x] write failing test: multi-row slide (two rows appended in one update) ⇒ `.slide(2)`
- [x] write tests that stay `.reset`: window shrank with overlap (paged-up then hydrate), zero overlap; existing reset/prepend/append tests unchanged
- [x] write failing reducer regression in `ChatWindowingTests`: 200-row transcript at the bottom window, `.messageStart` then `.toolStart(...)`; `classify(old visibleRows ids, new visibleRows ids)` is `.slide`, never `.reset`
- [x] add `case slide(droppedHeadCount:)` and the slide rule to `classify` with doc comments; update the enum's top doc comment
- [x] run `make test` — must pass before task 2

### Task 2: Add the anchor-shift offset helper

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/TranscriptScrollMath.swift`
- Modify: `HermesKit/Tests/HermesKitTests/TranscriptScrollMathTests.swift`

- [x] write tests for `offsetAfterAnchorShift`: negative shift (head removed), positive shift, clamp at `-topInset`, clamp at `maxOffsetY`
- [x] implement `offsetAfterAnchorShift`; route `offsetAfterPrepend` through it
- [x] confirm existing `offsetAfterPrepend` tests still pass unchanged
- [x] run `make test` — must pass before task 3

### Task 3: Preserve the reader's anchor on a slide in the renderer

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/Transcript/CollectionTranscriptView.swift`

- [x] before `dataSource.apply`, when the diff is `.slide` and not pinned, capture the topmost visible surviving row id and its `frame.minY`
- [x] in the completion: pinned slide ⇒ `scrollToBottom(animated:)`; unpinned with anchor ⇒ `preserveAnchorAfterSlide` (layout, measure, `offsetAfterAnchorShift`, `isAdjustingOffset` guard like `preserveOffsetAfterPrepend`); no anchor ⇒ reset-jump fallback
- [x] update the `apply(rows:)` and Coordinator doc comments (follow / preserve / slide-preserve / jump)
- [x] `make build` compiles cleanly
- [x] tests for this task land in task 4 (renderer glue lives in the app target)

### Task 4: Measured layout test for slide preservation

**Files:**
- Create: `HermesMobileTests/TranscriptSlidePreservationTests.swift`

- [x] host `CollectionTranscriptView` in a `UIWindow` (pattern from `MarkdownTableLayoutTests`) with 50 fixed-height rows, `.dynamicTypeSize(.large)`
- [x] test: scroll up mid-list, apply a slid 50-row window ⇒ the anchor row's on-screen y is unchanged (±0.5pt) and the list is not at the bottom
- [x] test: pinned at bottom, apply a slid window ⇒ ends at the bottom
- [x] if either needs test hooks in production code, drop this task, mark it ⚠️ here, and rely on post-completion manual verification (not needed — driven through the collection view's own delegate; no production hooks)
- [x] `tuist generate` (new source file), then run `make snapshot` — must pass before task 5

### Task 5: Verify acceptance criteria
- [x] scrolled-up reader is not moved by tool-call rows on a 50+ row chat; pinned reader still follows (`liveToolCallSlidesWindowNotReset`, `classify*Slide*`, `TranscriptSlidePreservationTests`; on-device check in Post-Completion)
- [x] load-older prepend preservation and open/hydrate-to-bottom behave as before (existing classify/windowing tests unchanged and green; renderer reset/prepend branches only extracted `jumpToBottomAndSettle`)
- [x] run full test suite: `make test` (1940 tests passed)
- [x] run `make snapshot` (clean, no baseline changes — 253/253)

### ➕ Task 5b: Review phase 1 fixes (never yank a scrolled-up reader)
- [x] ➕ classify: any update that keeps an old row is a `.slide` unless the window shrank AND lost its head; turn-end empty-thinking removal (`freezeThinking`) and `reparkDrainingEntry` no longer `.reset` (`turnEndRemovingEmptyThinkingRowSlidesWindowNotReset`, `classifyTurnEndRowRemoval*`, `classifyTailRemovalThatShrinksIsSlide`)
- [x] ➕ renderer: hold the reader's anchor on every `holdsReaderAnchor` update; no on-screen survivor ⇒ nearest survivor (tall dropped row clamps at the window top), never the jump-to-bottom fallback
- [x] ➕ renderer: a programmatic shift that lands near the window top pages older rows (`loadOlderIfNearTop`)
- [x] ➕ renderer: offsets assigned directly (`assignOffset`), fling continuity unverified on device
- [x] ➕ review phase 4: hold and prepend preserve run in the same pass as the apply (no stale-offset overwrite, no uncorrected frame); a pinned slide jumps and settles (a re-id'd tail lands on estimated heights); measured tests `testHoldLandsWithTheSlideAndKeepsAScrollThatFollowsIt`, `testPinnedReaderEndsAtTheBottomAfterAHydrateReIdsTheTailRows`
- [x] ➕ `offsetAfterPrepend` folded into `offsetAfterAnchorShift`; `TranscriptDiffKind.isPrepend` / `holdsReaderAnchor`
- [x] ➕ measured tests: live tool-row shape, near-top paging, tall dropped row, pinned follow start; hydrate classify assertions in `ChatWindowingTests`

### Task 6: [Final] Update documentation
- [x] CLAUDE.md "History paginates client-side" bullet: note the live window slides and the renderer classifies that as `.slide` (follow-if-pinned, anchor-preserve otherwise), never `.reset`
- [x] note the hydrate contract nuance (jump only when the reader's rows are gone) in the renderer doc comment
- [x] move this plan to `docs/plans/completed/` (deferred to the orchestrator's completion step)

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification**:
- On a chat with 50+ rows, start a tool-heavy turn, scroll up a few screens, and watch several tool
  calls land: the view stays put and the jump button shows; tapping it returns and follows again.
- Repeat while actively dragging/decelerating when a tool row lands (no stutter or jump).
- Stay at the bottom during the same turn: the list keeps following.
- Background and foreground mid-turn while scrolled up: position kept if the rows survive.
- TestFlight build for reporter confirmation of #125.
