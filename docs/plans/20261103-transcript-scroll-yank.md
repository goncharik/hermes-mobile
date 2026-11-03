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
- **Slide rule** (in `classify`, after the permutation/superset checks, before `.reset`): a
  leading run of `k > 0` old ids is gone, every remaining old id survives in `new`, and the window
  did not shrink (`new.count >= old.count`). The live keepThinkingLast mid-insert (tool row above
  the thinking row) combined with a dropped head must also classify as a slide.
- **What stays `.reset`** (jump to bottom): zero overlap, and any update where the window shrank —
  notably a hydrate after paging up, which trims the reader's rows. Existing reset tests unchanged.
- **Renderer handling of `.slide`**: pinned ⇒ follow (`scrollToBottom`, same as append). Scrolled
  up ⇒ before the apply, capture the topmost *visible* row whose id survives in the new order and
  its `frame.minY`; after the apply, `layoutIfNeeded`, read the anchor's new `minY`, and shift the
  offset by the difference (captured offset + shift, clamped) under the `isAdjustingOffset` guard.
  No surviving visible anchor ⇒ fall back to today's reset jump.
- **Deliberate contract change (flag in PR)**: a foreground hydrate that keeps the window size and
  leaves the reader's visible rows in place now preserves their position instead of jumping. A
  hydrate that removes the rows they were reading still jumps. Consistent with #125's intent.

## Technical Details
- `TranscriptDiffKind` gains `case slide(droppedHeadCount: Int)`; doc comment explains it is the
  reducer's fixed bottom window advancing on a live append (follow-if-pinned, never yank).
- Classify sketch:
  ```swift
  if new.count >= old.count,
     let k = old.firstIndex(where: newSet.contains), k > 0,
     old[k...].allSatisfy(newSet.contains) {
    return .slide(droppedHeadCount: k)
  }
  ```
- `TranscriptScrollMath.offsetAfterAnchorShift(previousOffsetY:anchorShift:contentHeight:viewportHeight:topInset:bottomInset:)`
  = `previousOffsetY + anchorShift` clamped to `[-topInset, maxOffsetY]`. `offsetAfterPrepend`
  becomes a thin call into it (prepend is a positive shift); its existing tests stay green.
- `apply(rows:)` flow: compute `diff` → if `.slide` and `!wasPinned`, capture `(anchorID, minY)`
  BEFORE `dataSource.apply` → completion: existing first-population/reset branch (slide is no
  longer a reset) → `preservePrepend` → `wasPinned` follow → `.slide` anchor preserve → `.slide`
  without anchor ⇒ reset-jump fallback. Plain `.appendOrMutate` while scrolled up stays a no-op.
- Risk to verify manually: a slide arriving mid-drag/deceleration. A delta shift (not an absolute
  target) keeps UIKit's gesture continuous; confirm on device.

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
- [ ] scrolled-up reader is not moved by tool-call rows on a 50+ row chat; pinned reader still follows
- [ ] load-older prepend preservation and open/hydrate-to-bottom behave as before
- [ ] run full test suite: `make test`
- [ ] run `make snapshot` (clean, no baseline changes)

### Task 6: [Final] Update documentation
- [ ] CLAUDE.md "History paginates client-side" bullet: note the live window slides and the renderer classifies that as `.slide` (follow-if-pinned, anchor-preserve otherwise), never `.reset`
- [ ] note the hydrate contract nuance (jump only when the reader's rows are gone) in the renderer doc comment
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification**:
- On a chat with 50+ rows, start a tool-heavy turn, scroll up a few screens, and watch several tool
  calls land: the view stays put and the jump button shows; tapping it returns and follows again.
- Repeat while actively dragging/decelerating when a tool row lands (no stutter or jump).
- Stay at the bottom during the same turn: the list keeps following.
- Background and foreground mid-turn while scrolled up: position kept if the rows survive.
- TestFlight build for reporter confirmation of #125.
