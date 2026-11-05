# TestFlight bug fixes (#128, #132, #131)

## Overview
- Fix the three open `bug` issues, all from TestFlight feedback, in priority order:
  - **#128** (`priority: high`): crash `_UIContentViewAssertValidFittingSize`, called from
    `UICollectionViewDiffableDataSource.apply` in `CollectionTranscriptView.Coordinator.apply`.
    Happens when a transcript update lands while the app is backgrounded, or during rotation or app
    switching.
  - **#132**: "Attachment failed: session not found" in a new, untitled chat, even though the
    #17 heal (`withSessionHeal`) is in place.
  - **#131**: the chat nav-bar `…` button still moves on iOS 27 after the #82/#86 fix. No repro
    yet, so this one starts with investigation.
- One plan, one branch, one PR. Each bug gets its own commits.

## Context (from discovery)
- **#128**
  - `HermesMobile/Sources/Features/Chat/Transcript/CollectionTranscriptView.swift`:
    `updateUIView` (~L186) calls `coordinator.apply(items:rowIDs:)` with no check of size or
    window. `apply` calls `dataSource.apply` (crash frame L398).
  - `TranscriptCollectionView.layoutSubviews` fires `onLayout`, which calls
    `coordinator.didLayout()`. Today `didLayout` is used only for the open-at-bottom settle.
  - The FIRST apply already runs before the collection view has a size (zero frame), and the
    open-at-bottom settle depends on that. Any gate must not regress the open/hydrate jump.
  - Pure scroll math lives in `HermesKit/Sources/HermesKit/Models/TranscriptScrollMath.swift`,
    which is unit-tested on macOS.
  - Row content that could report non-finite sizes: `CappedWidthLayout`, `BoundedHeightLayout`,
    any `GeometryReader` or `.frame(maxHeight: .infinity)` in cell content.
- **#132**
  - `ChatFeature.submitDraft` attachment branch → `withSessionHeal(runUploadAndSubmit, …)` →
    `healLiveSessionID`. When a stored id exists, the heal calls `session.resume(stored)`;
    `session.create` is used only when there is no stored id.
  - Upstream gateway (`tui_gateway/methods_session.py` `_resume_locate`) returns
    `4007 "session not found"` when the stored id has no DB row. A new chat's DB row is created
    lazily on its first prompt ("A draft has no row yet"). So a new chat whose live session was
    reaped has a heal that fails itself, and the banner fires. Newer upstream creates the row
    for server-minted keys on resume (`_resume_materialize_minted`), but older agents still fail.
  - The app already models the same "no DB row until first prompt" fact for branches (#34):
    `attachLiveSessionID` and `branchSeed`, cleared on the first `message.start`. A plain new
    chat has no equivalent flag.
  - Existing tests: `HermesKit/Tests/HermesKitTests/SelfHealTests.swift`
    (`attachUploadSelfHealsOnSessionNotFoundThenSucceeds`,
    `promptSubmitHealWithNoStoredIDRecreatesSession`, …).
- **#131**
  - `HermesMobile/Sources/Features/Chat/ChatMenuButton.swift` (the #86 split; it observes only
    `canRename` and `sessionKey`). It is the only `ToolbarItem` in `ChatView`, alongside
    `.navigationTitle(store.title ?? "Chat")`.

## Development Approach
- **testing approach**: TDD. Write the failing test first, then make it pass.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Project test rules apply: logic goes in HermesKit, views stay thin. Use only snapshot tests
  and unit tests (no hosted behavior-probe tests, no debug counters in views). Layout facts a
  snapshot can't prove go in a measured `UIWindow`-hosted XCTest.

## Testing Strategy
- **unit tests**: `make test` (HermesKit `swift test`). Reducer tests use `TestStore` with
  `@Dependency` overrides.
- **snapshot/layout tests**: `make snapshot` (currently clean, 313/313, so any failure is a
  real signal). Add a measured layout test only where it proves a sizing fact.
- No UI e2e suite in this project; manual simulator/device checks are listed under
  Post-Completion.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- **#128: defer the snapshot apply while the view can't be measured.** A pure predicate in
  `TranscriptScrollMath` decides whether the collection view can take a diff apply now, based
  on finite, positive width and a window being present. When it can't, the coordinator keeps
  only the LATEST `(items, rowIDs)` and skips `dataSource.apply`. The next `didLayout` with a
  valid size flushes that latest pending update through the normal `apply` path, so the
  classification and stick-to-bottom contract stay unchanged. The predicate must let the
  first-population apply through in the configuration that works today. Task 1 checks which
  condition the first open meets. If it is "zero frame but has a window" or "no window yet",
  the gate is shaped to match: the first apply may be deferred, and its flush must still trigger
  the initial jump. Separately, audit cell content for any path that can report NaN, infinite or
  negative sizes under a degenerate proposal, and clamp at the source.
- **#132: fall back from resume to create for a chat that was never saved on the server.**
  Add a per-slot "never saved" fact for plain new chats, true until the first `message.start`
  (mirroring how `attachLiveSessionID` is cleared). When it is true and the heal's
  `session.resume(stored)` itself throws `isSessionNotFound`, `healLiveSessionID` falls back to
  `session.create` with the same profile and branch-seed rules, then sends
  `.liveSessionIDRefreshed`. The original op is still replayed exactly ONCE. This adds a second
  heal step, not a retry loop. A resumed or already-prompted chat keeps today's behaviour: the
  resume failure shows the banner and no session is quietly swapped in. Newer agents that create
  the row on resume never reach the fallback.
- **#131: investigate first, and fix only once the cause is known.** Time-box the repro. If the
  cause is reducer-state churn (for example `title`/`sessionKey`, or a field the toolbar depends
  on, being rewritten on every `session.info` or hydrate), fix it in HermesKit with a unit test.
  If the cause is view-level (title width relayout, `.id(slotGeneration)` re-creation, iOS 27
  toolbar behaviour), fix it in the view and verify manually, with no probe test. If it can't be
  reproduced, document the findings on the issue and leave it open.

## Technical Details
- **#128 gate** (sketch; final name decided during implementation):
  `TranscriptScrollMath.canApplySnapshot(width: CGFloat, height: CGFloat, hasWindow: Bool) -> Bool`.
  It checks `width.isFinite && width > 0`, plus the window and height conditions from the Task 1
  findings. It sits outside the `#if canImport(UIKit)` guard so `swift test` covers it.
- Coordinator state: `pendingApply: (items: [TranscriptItem], rowIDs: [ChatRow.ID])?`. It is
  overwritten (never queued) by each deferred `updateUIView` and cleared by the flush. A flush
  calls the existing `apply(items:rowIDs:)`, so `currentRowIDs`/`currentOrder` reflect only
  updates that were actually applied, and the diff classification stays correct across the gap.
- **#132 flag**: a `State` field such as `awaitsFirstPersist: Bool`, initialised to
  `!resumesStoredSession && branchSeed == nil` and cleared on the first `message.start`, on
  `.liveSessionIDRefreshed` from a successful resume, and on hydrate with server history. It is
  captured into the effect next to `stored`/`seed`/`profile` and passed to `healLiveSessionID`
  as `fallbackToCreate: Bool`. All `withSessionHeal` callers get the same behaviour (submit,
  attachments, slash, rename, config.set), because they share the heal.

## What Goes Where
- **Implementation Steps**: code, tests, and docs in this repo.
- **Post-Completion**: device/simulator repro checks, TestFlight build, closing issues.

## Implementation Steps

### Task 1: Investigate #128's invalid fitting size

**Files:**
- Modify: `docs/plans/20261105-testflight-bug-fixes.md` (findings)

- [x] reproduce on the iOS 18 and iOS 26 simulators: stream a long turn, then background the app
      (and rotate in the app switcher) while deltas arrive; capture any assert/console output
      (partial — see findings: no iOS 18 runtime installed and no Simulator GUI to rotate; iOS
      26.5 background run done, no assert)
- [x] log `collectionView.bounds`, `window != nil`, and the first-apply conditions at
      `updateUIView` time on first open, on a background update, and mid-rotation (temporary
      logging, removed before commit; mid-rotation not drivable here)
- [x] audit cell content (`CappedWidthLayout`, `BoundedHeightLayout`, `MarkdownTableView`,
      `GeometryReader`, `.infinity` frames) for non-finite or negative sizes under a zero-width
      or zero-height proposal
- [x] record the findings and the exact gate conditions in this plan (➕ any extra source fix)

**Task 1 findings (2026-11-05)**

- **Environment limits.** The only installed runtimes are iOS 26.5, 27.0 and 27.1; the iOS
  18.x runtimes are "unavailable" on this host, so the crash's own OS (18.7) could not be run.
  There is no Simulator GUI app in this environment, so rotation (and the app switcher) could
  not be driven; `axe button home` is a no-op here (backgrounding was done by launching
  Settings over the app). No real agent was driven: the live repro used demo mode with a
  temporary gateway stub streaming a `message.delta` every 150 ms plus a `tool.start` every
  40 frames. **The assert did not reproduce** on iOS 26.5 or 27.0.
- **First open** (instrumented `updateUIView` / `apply` / `didLayout`, iOS 26.5 demo chat):
  the FIRST `updateUIView` → `apply` runs at `bounds = 0×0`, `window == nil`,
  `applicationState = .inactive`, `didInitialJump == false`. The apply's completion runs
  before any real layout (`didLayout` at 0×0, no window, already `didInitialJump == true`),
  then the next `didLayout` is the first real one: `402×619.67`, window present. So today's
  open-at-bottom is "first apply with no window and a zero frame, settled by `didLayout`".
- **Background update** (Settings launched over the app, deltas still arriving): applies kept
  landing through `.inactive` (≈1 s) and `.background` (≈10 s) at the unchanged
  `402×619.67` with the window attached. No size change, no assert. A plain background on the
  simulator does NOT produce the degenerate frame — the device-side trigger is most likely the
  system's background snapshot / app-switcher re-layout in the other orientation, or a
  transient size during a rotation, which this environment can't produce.
- **Degenerate collection-view sizes** (scratch hosted harness on the production
  `TranscriptLayout.makeLayout()`, iOS 26.5 and 27.0, deleted before commit): the
  compositional layout gives an item `width − 2 × horizontalSectionInset` (32pt), clamped at
  0. Width ≤ 32 → item width 0 (width exactly 32 lays out no cells at all; 20 and 33 lay out
  cells at 0pt and 1pt wide) → every cell is self-sized at a 0–1pt fitting width and reports
  1000–4700pt of character-wrapped height. Finite, so no assert on 26/27, but it is a
  fully degenerate self-sizing pass. Zero width, zero height (any width), and no window lay
  out no cells (no fitting call). Shrinking a populated view to 20pt or 0×0 and then applying
  a reconfigure: no assert.
- **Cell content audit** — every display item the fold produces (user message, reasoning,
  collapsed/expanded run summaries, call lines, every expanded tool body: terminal, read_file,
  patch, skill_view, running terminal; turn header live and finished; markdown with heading,
  lists, quote, code block, table, rule, file link, bare path, `MEDIA:` tag; status, error,
  command output, streaming partial reply), hosted in a real `UICollectionViewCell` through
  `UIHostingConfiguration` + `ChatView.itemView`, measured with
  `systemLayoutSizeFitting` AND `preferredLayoutAttributesFitting` at fitting sizes 0×60, 0×0,
  0.5×60, 1×60, 8×60, 288×60, 288×0, on iOS 26.5 and 27.0: **0 non-finite or negative sizes**.
  At 0pt several items report a width wider than offered (14–111pt) and very tall heights,
  all finite. Static read: `CappedWidthLayout` ignores the proposal (constant cap, finite);
  `BoundedHeightLayout` is only used by the prompt cards' `BoundedScrollRegion` (the pinned
  row, never a transcript cell) and is finite for finite input; the only cell
  `GeometryReader` is the turn header's shimmer overlay (an overlay, does not size the cell);
  the `.infinity` frames in cell content are all `maxWidth: .infinity`, which a width-fixed
  fitting pass resolves to the offered width. **No non-finite sizing source found → Task 3 is
  expected to be "not needed".**
- **Conclusion.** The crash could not be reproduced on the available runtimes; the strongest
  code-level candidate is a diff apply (and its self-sizing pass) landing while the collection
  view is narrower than its section insets or has no window — on iOS 18.7 the 0pt-wide
  self-sizing pass (or a transient non-finite frame during the background snapshot / rotation)
  is what UIKit rejects. The gate removes every such pass from our side; it cannot be proven
  red/green against the device crash here.
- **Gate conditions for Task 2** (decided): apply now only when ALL hold —
  `hasWindow`, `width.isFinite`, `height.isFinite`, `height > 0`, and
  `width > 2 × TranscriptLayout.horizontalSectionInset` (the row width is positive; passed in
  as a parameter, since the inset lives in the app target and the predicate in HermesKit).
  Otherwise keep only the latest `(items, rowIDs)` and flush it from `didLayout()`. The first
  open meets "zero frame, no window", so its first apply IS deferred; the flush happens on the
  first real `didLayout` (window + real size, seen above) and, because `didInitialJump` is
  still false, takes the normal open jump-and-settle path.

### Task 2: Gate transcript snapshot applies on a measurable view (#128)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/TranscriptScrollMath.swift`
- Modify: `HermesKit/Tests/HermesKitTests/` (existing scroll-math test file, or a new
  `TranscriptApplyGateTests.swift`)
- Modify: `HermesMobile/Sources/Features/Chat/Transcript/CollectionTranscriptView.swift`

- [ ] write failing unit tests for the gate predicate: valid size + window → true; zero, negative,
      NaN or infinite width → false; no window → as decided in Task 1; first-open configuration → as
      decided in Task 1
- [ ] implement the predicate in `TranscriptScrollMath` (outside the UIKit guard)
- [ ] add `pendingApply` to the coordinator: defer in `apply` entry (or `updateUIView`) when the
      gate says no, keeping only the latest update
- [ ] flush `pendingApply` from `didLayout()` when the gate passes, before the existing
      initial-settle logic, so the first-open jump and the follow behaviour still happen
- [ ] run `make test` and `make snapshot`, which must pass, including
      `TranscriptSlidePreservationTests` and `TranscriptKeyboardScrollTests`

### Task 3: Fix any non-finite row sizing source found in Task 1 (#128)

**Files:**
- Modify: the layout(s) identified in Task 1 (e.g. `CappedWidthLayout` / `BoundedHeightLayout`)
- Modify: the matching measured layout test (e.g. `HermesMobileTests/MarkdownTableLayoutTests.swift`)

- [ ] write a failing measured `UIWindow`-hosted layout test: the layout's `sizeThatFits` under a
      zero-width (and zero-height) proposal returns finite, non-negative values
- [ ] clamp or guard at the source
- [ ] run `make snapshot` and `make test`, which must pass
- [ ] if Task 1 found no such source, mark this task ⚠️ "not needed" with the evidence and skip it

### Task 4: Track "never saved on the server" for plain new chats (#132)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SelfHealTests.swift` (or `ChatReductionTests.swift`)

- [ ] write failing tests: a new chat starts with the flag set; the first `message.start` clears
      it; a resumed chat (`resumesStoredSession`) and a branch never set it; a hydrate with server
      history clears it
- [ ] add the `State` field with a doc comment linking it to the server's lazy row creation and
      the #34 branch analogue
- [ ] set/clear it in the reducer at the points listed in Technical Details
- [ ] run `make test`, which must pass

### Task 5: Fall back from resume to create in the heal for never-saved chats (#132)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`healLiveSessionID`,
  `withSessionHeal`, and their call sites that capture effect inputs)
- Modify: `HermesKit/Tests/HermesKitTests/SelfHealTests.swift`

- [ ] write a failing test for the reported case: new chat, staged image, `image.attach_bytes`
      → "session not found", `session.resume(stored)` → "session not found", then
      `session.create` → fresh ids, `.liveSessionIDRefreshed`, upload + `prompt.submit` replayed
      once, `.attachmentsSubmitted` (no banner)
- [ ] write failing tests for the guards: a resumed or already-prompted chat whose resume fails
      still banners, with no `session.create`; if the fallback create also fails → banner, no
      replay; the op is replayed exactly once (fallback + replay failing → banner, no loop); the
      profile is threaded and nil is omitted (#114); a branch seed still goes through the seeded
      create
- [ ] implement `fallbackToCreate` in `healLiveSessionID` and capture the flag at every
      `withSessionHeal` call site
- [ ] add a plain `prompt.submit` variant of the reported-case test so the shared heal is covered
      outside attachments
- [ ] run `make test`, which must pass

### Task 6: Investigate and fix #131's moving toolbar button (time-boxed)

**Files:**
- Modify: `docs/plans/20261105-testflight-bug-fixes.md` (findings)
- Modify (conditional): `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` and its tests,
  or `HermesMobile/Sources/Features/Chat/ChatView.swift` / `ChatMenuButton.swift`

- [ ] try to reproduce on the iOS 27 simulator (AXe screenshots or recording): stream tool-heavy
      turns, change the title (auto-title after the first reply and a rename), go through
      background/foreground cycles and re-hydrates, and compare compact and regular layouts
- [ ] check whether `title`, `canRename` or `sessionKey` are written with unchanged values on
      `session.info` or hydrate in a way that triggers Observation, and whether
      `.id(slotGeneration)` or a re-hydrate rebuilds the toolbar
- [ ] if the cause is in the reducer: write a failing `TestStore` test proving the field isn't
      rewritten, then fix it
- [ ] if the cause is in the view: apply the fix and record the before/after manual check here (no
      probe test)
- [ ] if not reproducible within the time box: record the findings here and as an issue comment
      draft, and leave #131 open
- [ ] run `make test` and `make snapshot`, which must pass

### Task 7: Verify acceptance criteria
- [ ] #128: backgrounding and rotating mid-stream no longer asserts; open-at-bottom, hydrate jump,
      slide/hold and keyboard behaviour are unchanged
- [ ] #132: a never-saved new chat recovers from a reaped live session on attach and plain
      submit; resumed chats keep today's behaviour
- [ ] #131: fixed with evidence, or findings documented
- [ ] run full test suite: `make test`
- [ ] run snapshot/layout suite: `make snapshot`

### Task 8: [Final] Update documentation
- [ ] update `docs/architecture.md` (heal section) and `docs/features/attachments-and-paste.md`
      with the never-saved fallback
- [ ] update CLAUDE.md's #17 heal bullet with a one-line note on the never-saved fallback
      (keep the bullet short)
- [ ] document the #128 deferred-apply rule on the `CollectionTranscriptView` bullet in CLAUDE.md
      if it is a new invariant
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- Device check for #128 on an older phone (the crash was on an iPhone XS, iOS 18.7): stream, then
  background for over 30s; rotate with the app switcher open; rotate while a permission prompt
  is up.
- Device check for #132: new chat → attach an image → background long enough for the orphan reap
  → send. Test against both an older agent and current upstream.
- #131: watch the `…` button on an iOS 27 device across a long-running session.

**External system updates**:
- Ship a TestFlight build (internal by default) and reference #128/#132/#131 in What to Test.
- Close #128 and #132 from the PR; close #131 only if a fix was confirmed.
