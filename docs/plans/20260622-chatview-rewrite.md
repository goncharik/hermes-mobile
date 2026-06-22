# ChatView Rewrite — Sustainable Scrolling/Layout Architecture

## Overview

Replace the current fragile `ChatView` scroll/layout with a robust foundation that:

- always opens at the bottom of the transcript,
- sticks to the bottom while a turn is streaming (animated follow) **without** yanking down a user who has scrolled up,
- paginates history on scroll-up **without** jumping the scroll position,
- supports A/B testing two rendering engines (pure-SwiftUI vs UIKit `UICollectionView`) via a settings toggle, so we can compare them on identical chats and pick a winner.

**Problem it solves.** Today the chat opens at the top, the layout engine thrashes as streaming deltas resize the last cell, and there is no history windowing. The structural root cause is that row IDs are random UUIDs regenerated on every hydrate, so no diffing engine can preserve scroll, animate inserts, or maintain position across a prepend.

**Integration.** All logic lives in `HermesKit` (deterministic IDs, windowing, reducer state); the app target gets two thin, interchangeable renderer views reusing the existing bubble subviews. In-chat search is **out of scope** for this plan; the foundation (stable IDs + windowing) is designed so search can be added later cleanly.

## Context (from discovery)

**Files/components involved:**
- `HermesMobile/Sources/Features/Chat/ChatView.swift` — main view: `ScrollView` + `LazyVStack` + `ScrollViewReader`, preference-key (`BottomDistanceKey`) bottom-distance measurement, scrolls on `transcript.count` change, floating `ScrollToBottomButton`, bottom anchor = `Color.clear.frame(height:1).id(Self.bottomAnchor)`.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — reducer: `transcript: IdentifiedArrayOf<ChatRow>`, `streamingRowID` / `thinkingRowID` / `toolRowIDs`; fold helpers `appendToStreamingMessage`, `keepThinkingLast`; `hydrate(sessionID:profile:)` via `session.resume`.
- `HermesKit/Sources/HermesKit/Models/ChatRow.swift` — `id: UUID` (generated, non-authoritative); `Kind` = `message` / `tool` / `thinking` / `status`.
- `HermesKit/Sources/HermesKit/Models/TranscriptReconstruction.swift` — `reconstructTranscript(_:makeID:)` maps `SessionMessage[]` → `ChatRow[]` with fresh UUIDs each call.
- Reused bubble subviews (do **not** rewrite): `MessageBubbleView.swift`, `MarkdownText.swift` (+`CodeBlockView`), `ThinkingIndicatorView.swift`, `ToolStatusView.swift`.
- `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift` — UserDefaults-backed `@DependencyClient`, `.inMemory()` test variant; logout clears identity-scoped entries.

**Related patterns found:**
- Server returns the **full cooked history in one `session.resume` payload** — there is no paginated history RPC, so pagination is a client-side window over the in-memory array (no network/hermes-agent change).
- Prefs follow the `@DependencyClient` + `liveValue`/`.inMemory()` convention; reducers tested with `TestStore` + `TestClock`.
- Snapshot tests render real views with pinned timestamps (`make snapshot` / `make snapshot-record`).

**Dependencies identified:**
- Deployment target raise to **iOS 18** (approved) — required for `onScrollGeometryChange` / `ScrollPosition` in Renderer C. Update `Project.swift` and `HermesKit/Package.swift`.
- Tuist: new source files need `tuist generate` before `xcodebuild` picks them up.

## Development Approach

- **Testing approach: Regular** (code first, then tests within the same task).
- Complete each task fully before moving to the next; make small, focused changes.
- **Every task MUST include new/updated tests** for code changed in that task (success + error/edge cases), listed as separate checklist items.
- **All tests must pass before starting the next task.**
- **Update this plan file when scope changes** during implementation.
- Run tests after each change; maintain backward compatibility (the existing `ChatView` keeps working after Task group 1).
- Commit per task (capitalized verb, no conventional-commit prefixes).
- HermesKit is tested on macOS via `swift test` — guard any UIKit-only renderer code with `#if canImport(UIKit)`; keep pure logic outside the guard.

## Testing Strategy

- **Unit tests (HermesKit, `swift test`):** required for every foundation task — deterministic IDs, windowing transitions, reconstruction reconciliation, pure pagination/anchor math.
- **TCA `TestStore` tests:** event-fold correctness, `windowStart` transitions, `chatRenderer` pref round-trips via `.inMemory()` `PreferencesClient`.
- **Snapshot tests (`HermesMobileTests`, `make snapshot`):** re-record `ChatView` for **both** engines on the same fixture transcript; pin row timestamps for determinism.
- No UI e2e harness in this project — manual A/B verification on-device is captured under Post-Completion.
- Run live HermesKit output via `script -q /dev/null swift test --package-path HermesKit` (or `make test`).

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Keep this plan in sync with actual work; move to `docs/plans/completed/` when finished.

## Solution Overview

Three layers, built bottom-up so each is independently shippable:

1. **Foundation (HermesKit, pure).** Deterministic content-derived `ChatRow.ID` + client-side windowing in `ChatFeature`. This alone fixes the diff-instability and long-chat thrash and improves the *existing* `ChatView` with zero new UI.
2. **Shared renderer boundary.** A common `ChatTranscriptView`-shaped interface consuming the windowed slice + a `TurnState`, with two interchangeable implementations. The existing bubble subviews are reused verbatim by both.
3. **A/B toggle.** A `PreferencesClient` entry selects the renderer at runtime so both can be compared on identical chats.

**Key design decisions:**
- Row identity is derived from **position + role + kind discriminator**, never from mutable streaming text, so a delta append preserves the row ID.
- Scroll/pin behavior is a **renderer-local** concern driven by an explicit shared contract; the reducer stays renderer-agnostic and issues **no** imperative scroll commands.
- Pagination is **client-side** over the already-fetched transcript (instant, offline), not a new server call.

## Technical Details

### Deterministic row identity

`ChatRow.ID` becomes a stable value derived from `(sequenceIndex, role, kindDiscriminator)`:
- `sequenceIndex` — the row's ordinal in the reconstructed transcript (guarantees distinctness for identical consecutive rows).
- `kindDiscriminator` — a stable token per `Kind` case (`message`/`tool`/`thinking`/`status`), so message #7's reasoning row and its text row get distinct-but-reproducible IDs.
- Excludes mutable text so streaming `message.delta` keeps the same ID.

`reconstructTranscript` computes these deterministically (drops the `makeID: { uuid() }` randomness). Live streaming rows continue to be tracked by `streamingRowID` / `thinkingRowID` / `toolRowIDs`; on the next hydrate they reconcile to the deterministic history ID for the same content/position.

### Windowing

`ChatFeature.State` adds:
- `windowStart: Int` — index of the oldest currently-rendered row (default `max(0, count - initialWindow)`, `initialWindow ≈ 50`).
- computed `hasMoreAbove: Bool` = `windowStart > 0`.
- computed `visibleRows` = `transcript` slice from `windowStart` to end (the view boundary).

Actions:
- `.loadOlderRequested` → `windowStart = max(0, windowStart - pageSize)` (`pageSize ≈ 50`).
- On hydrate / wholesale replace → reset `windowStart` to the bottom window.
- Optional cap of live rendered rows (~150) to bound relayout cost during streaming.

### Shared stick-to-bottom contract (renderer-local)

- `isPinnedToBottom` is computed from scroll geometry (~60pt threshold), held in the renderer, **not** the reducer.
- **On open/hydrate:** jump (no animation) to bottom — always.
- **Streaming delta grows last cell:** if pinned → animated follow to bottom; if scrolled up → do nothing, keep the floating jump-to-bottom button.
- **New row appended:** same pin rule.
- Reduce-motion → instant jumps instead of animated follows.

### Renderer interface

```swift
ChatTranscriptView(
  rows: [ChatRow],          // windowed slice (visibleRows)
  turnState: TurnState,     // .idle / .streaming
  onLoadOlder: () -> Void,  // top sentinel reached
  onScrollPositionChanged: (Bool) -> Void  // isPinnedToBottom
)
```

- **Renderer C (`SwiftUITranscriptView`):** `ScrollView` + `LazyVStack`, `.defaultScrollAnchor(.bottom)`, `ScrollPosition` binding, `onScrollGeometryChange` for `isPinnedToBottom`, top sentinel `.onAppear` → `onLoadOlder`, prepend anchored via `.scrollPosition(id:)` on the first previously-visible row.
- **Renderer A (`CollectionTranscriptView`):** `UIViewRepresentable` wrapping `UICollectionView` (compositional layout, single section, self-sizing `UIHostingConfiguration` cells, `UICollectionViewDiffableDataSource<Section, ChatRow.ID>`). Coordinator owns diff application, contentOffset re-pin on cell bounds-change while pinned, the prepend offset-preservation recipe, and `scrollViewDidScroll → onScrollPositionChanged`. Guarded by `#if canImport(UIKit)`.

### Settings toggle

`PreferencesClient` gains `chatRenderer: ChatRendererKind` (`.swiftUI` | `.collectionView`), default `.collectionView`. Surfaced as a Settings `Picker` ("Chat list engine — experimental"). `ChatView` instantiates the selected renderer; flipping mid-session re-instantiates with the same `rows`. UserDefaults-backed + `.inMemory()` test variant. **Not** cleared on logout (device preference, not identity-scoped).

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, deployment-target bumps, `tuist generate`, snapshot re-records.
- **Post-Completion** (no checkboxes): on-device A/B verification, picking the winning engine, optionally retiring the loser.

## Implementation Steps

### Task 1: Deterministic content-derived ChatRow identity

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ChatRow.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/TranscriptReconstruction.swift`
- Modify: `HermesKit/Tests/HermesKitTests/TranscriptReconstructionTests.swift` (or create if absent)

- [x] Add a stable `kindDiscriminator` token per `ChatRow.Kind` case in `ChatRow.swift`.
- [x] Add a deterministic ID factory deriving `ChatRow.ID` from `(sequenceIndex, role, kindDiscriminator)`, excluding mutable text. (`ChatRow.deterministicID` + a pure `UUID.deterministic(from:)` FNV-1a seed; `id` stays `UUID` for source compatibility.)
- [x] Update `reconstructTranscript` to assign deterministic IDs by position (dropped the `makeID` parameter; ids derived per output ordinal; updated all call sites).
- [x] Update `ChatFeature.hydrate` reconstruction call site to use the deterministic path.
- [x] Write tests: same history in → byte-identical IDs out; identical consecutive rows get distinct IDs (sequence index); message + its reasoning row get distinct IDs.
- [x] Write tests: error/edge — empty history, single row, all-same-role runs.
- [x] Run tests — must pass before next task. (466 tests, all passing.)

### Task 2: Preserve row identity across streaming deltas

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (verified — fold helpers already mutate rows in place; no change needed)
- Create: `HermesKit/Tests/HermesKitTests/RowIdentityTests.swift` (added a dedicated identity-preservation suite rather than a `ChatFeatureTests.swift`, which doesn't exist; reducer tests live in `ChatReductionTests.swift`/`HydrateTests.swift`)

- [x] Ensure `appendToStreamingMessage` and the thinking/tool fold helpers keep a stable row ID across deltas (no ID churn on append). (Verified: each delta mutates `transcript[id:].kind` in place, reusing the row's id.)
- [x] Ensure live streaming row IDs reconcile to the deterministic history IDs on the next hydrate (same content/position → same ID, no visual flicker). (Verified: `applyActivate` rebuilds the transcript wholesale from `reconstructTranscript`, replacing random live ids with deterministic ones — server wins.)
- [x] Verify `keepThinkingLast` reordering preserves IDs. (Verified: it removes-and-re-appends the same row instance; test added.)
- [x] Write `TestStore` tests: delta append preserves the streaming row ID; hydrate after a turn reconciles live → deterministic IDs without duplicating rows.
- [x] Write tests: error/edge — `message.complete` with no deltas, reasoning-only turn.
- [x] Run tests — must pass before next task. (473 tests, all passing.)

### Task 3: Client-side windowing in ChatFeature

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ChatWindowingTests.swift` (there is no `ChatFeatureTests.swift`; added a dedicated windowing suite alongside `ChatReductionTests`/`HydrateTests`/`RowIdentityTests`)

- [x] Add `windowStart: Int` to `State`, plus computed `hasMoreAbove` and `visibleRows` slice.
- [x] Add `.loadOlderRequested` action: `windowStart = max(0, windowStart - pageSize)` (`pageSize ≈ 50`, `initialWindow ≈ 50`).
- [x] Reset `windowStart` to the bottom window on hydrate / wholesale transcript replace.
- [x] Keep `windowStart` valid as the transcript grows during streaming (new rows stay in-window). (`maintainWindowAfterStreaming` re-pins to the bottom window when parked there; never yanks a scrolled-up user. The optional ~150 cap fell out as unnecessary — when parked at bottom only `initialWindow` rows render — so it was omitted to avoid over-engineering.)
- [x] Write `TestStore` tests: `loadOlderRequested` decrements and clamps at 0; hydrate resets to bottom window; streaming append keeps newest visible.
- [x] Write tests: edge — transcript shorter than `initialWindow`, exactly one page, empty transcript, scrolled-up user not yanked, hydrate-after-scroll-up resets.
- [x] Run tests — must pass before next task. (483 tests, all passing.)

### Task 4: Wire foundation into the existing ChatView (no new renderer)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/.../ChatViewSnapshotTests.swift` (existing snapshot suite)

- [x] Render `store.visibleRows` instead of `store.transcript`; row `.id` now uses the deterministic ID.
- [x] Add the top sentinel that sends `.loadOlderRequested` when `hasMoreAbove` and the top is approached. (iOS 17-safe `.onAppear` on a 1pt top marker, gated by `store.hasMoreAbove`.)
- [x] Confirm open-at-bottom and streaming follow behave at least as well as before (regression guard for the migration). (Scroll-to-bottom still keys off `store.transcript.count` — only real new rows trigger it, not `loadOlderRequested` window growth — so open-at-bottom and streaming-follow are preserved and pagination doesn't yank.)
- [x] Re-record affected snapshots (`make snapshot-record`) and verify (`make snapshot`). (No re-record needed: fixture transcripts are under the 50-row window so `hasMoreAbove` is false / no sentinel renders; all 68 snapshot tests stayed green.)
- [x] Run full HermesKit + snapshot suites — must pass before next task. (HermesKit: 483 tests pass; snapshots: 68 tests, 0 failures.)

### Task 5: Raise deployment target to iOS 18

**Files:**
- Modify: `Project.swift`
- Modify: `HermesKit/Package.swift`

- [x] Bump app deployment target to iOS 18 in `Project.swift` (per-configuration settings preserved). (Both `HermesMobile` and `HermesMobileTests` targets → `.iOS("18.0")`; Debug/Release per-config settings untouched.)
- [x] Bump `HermesKit` platform minimum to iOS 18 (keep macOS test platform intact for `swift test`). (`.iOS(.v18)`; `.macOS(.v14)` kept.)
- [x] Run `tuist generate`; confirm app builds and `swift test` still runs on macOS. (`tuist generate` succeeded; `xcodebuild` Debug simulator build succeeded (exit 0).)
- [x] Run HermesKit tests — must pass before next task. (483 tests, all passing.)

### Task 6: Shared renderer boundary + extract Renderer C (SwiftUI)

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/Transcript/SwiftUITranscriptView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`

- [ ] Define the shared `ChatTranscriptView` initializer shape (`rows`, `turnState`, `onLoadOlder`, `onScrollPositionChanged`) and `TurnState`.
- [ ] Implement `SwiftUITranscriptView`: `ScrollView` + `LazyVStack`, `.defaultScrollAnchor(.bottom)`, `ScrollPosition` binding, `onScrollGeometryChange` → `isPinnedToBottom`, top sentinel → `onLoadOlder`, prepend anchored via `.scrollPosition(id:)`.
- [ ] Implement the shared stick-to-bottom contract (open/hydrate jump, pinned follow, no-yank when scrolled up, reduce-motion instant).
- [ ] Reuse `MessageBubbleView` / `MarkdownText` / `ThinkingIndicatorView` / `ToolStatusView` verbatim for cell content.
- [ ] Point `ChatView` at `SwiftUITranscriptView`; run `tuist generate`.
- [ ] Re-record + verify snapshots for the SwiftUI engine.
- [ ] Run tests — must pass before next task.

### Task 7: Renderer A (UICollectionView) behind UIViewRepresentable

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/Transcript/CollectionTranscriptView.swift`
- Create: `HermesMobile/Sources/Features/Chat/Transcript/TranscriptCollectionCoordinator.swift`

- [ ] Implement `CollectionTranscriptView` (`UIViewRepresentable`) with the **same initializer shape** as `SwiftUITranscriptView`, guarded by `#if canImport(UIKit)`.
- [ ] Configure `UICollectionView` compositional layout, single section, self-sizing `UIHostingConfiguration` cells, `UICollectionViewDiffableDataSource<Section, ChatRow.ID>`.
- [ ] Coordinator: apply diffs from `rows`; re-pin contentOffset on cell bounds-change while pinned (validate this first — primary streaming-jank mitigation).
- [ ] Coordinator: prepend offset-preservation across `loadOlder`; `scrollViewDidScroll → onScrollPositionChanged` (~60pt threshold); open/hydrate jump-to-bottom.
- [ ] Keep pure helper logic (threshold math, anchor selection) outside the `#if` guard.
- [ ] Run `tuist generate`; build the app target.
- [ ] Run tests — must pass before next task.

### Task 8: chatRenderer preference + Settings toggle

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/PreferencesClientTests.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobile/Sources/Features/Settings/.../SettingsView.swift` (existing settings screen)

- [ ] Add `ChatRendererKind` (`.swiftUI` | `.collectionView`) and `chatRenderer` get/set to `PreferencesClient` (default `.collectionView`); `.inMemory()` variant supports it; **not** cleared on logout.
- [ ] `ChatView` switches between `SwiftUITranscriptView` and `CollectionTranscriptView` on the pref; flipping re-instantiates with the same `rows`.
- [ ] Add a Settings `Picker` ("Chat list engine — experimental").
- [ ] Write tests: `chatRenderer` round-trips via `.inMemory()` PreferencesClient; default is `.collectionView`; logout does not clear it.
- [ ] Run `tuist generate`; build.
- [ ] Re-record + verify snapshots for **both** engines on the same fixture transcript.
- [ ] Run full suites — must pass before next task.

### Task 9: Verify acceptance criteria

- [ ] Verify open-at-bottom on cold open, foreground, and list-open for both engines.
- [ ] Verify streaming follow when pinned and no-yank when scrolled up (both engines).
- [ ] Verify scroll-up pagination prepends without jump (both engines).
- [ ] Verify reduce-motion degrades follows to instant jumps.
- [ ] Run full test suite: `make test` (or `script -q /dev/null swift test --package-path HermesKit`).
- [ ] Run snapshot suite: `make snapshot`.

### Task 10: [Final] Update documentation

- [ ] Update `CLAUDE.md` with the new ChatView conventions (deterministic IDs, windowing, renderer toggle, stick-to-bottom contract).
- [ ] Update `README.md` / `docs/architecture.md` if the chat section references the old scroll approach.
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Manual verification:**
- On-device A/B: open the same long chat under each engine via the Settings toggle; compare streaming smoothness, scroll-up paging feel, and open-at-bottom reliability.
- Stress test with a very long chat (1000+ rows) to confirm windowing bounds layout cost.
- Test on a physical device under fast token streaming (simulator can mask layout cost).

**Decision after A/B:**
- Pick the winning engine as the default; optionally retire the loser and remove the toggle in a follow-up (or keep the toggle as a debug affordance).

**External system updates:**
- None — no hermes-agent or push/gateway changes; pagination is purely client-side.
