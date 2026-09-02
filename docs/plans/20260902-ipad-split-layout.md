# iPad split-view layout

GitHub issue: #80 (closes). Related: #90 (multi-slot sockets, deliberately out of scope).

## Overview

The app runs on iPad as a scaled iPhone layout. This plan makes it a native iPad app:
a `NavigationSplitView` with the session list in the sidebar and the live chat in the
detail column, an empty-chat hero view like the Hermes desktop app (also shown for a
brand-new chat on iPhone), and a readable-width cap on the chat column for wide layouts.

Key constraint: the app has ONE live-chat slot (#33) and the navigation path holds thin
`ChatScreen` markers. Today `path.isEmpty` in `AppFeature` means "the chat is detached
(user is on the list)". In a split view the chat is never detached in regular width, so
that predicate gets an explicit definition that both layouts feed.

Out of scope (decided in the brainstorm):
- keyboard shortcuts (Cmd+N, Cmd+Return, arrow navigation);
- multi-window / Stage Manager showing two chats at once;
- keeping a socket per running session — filed as #90; the single slot stays.

## Context (from discovery)

- `HermesKit/Sources/HermesKit/AppFeature.swift` — owns `liveChat` slot, `path:
  StackState<ChatScreen.State>`, `currentViewingSessionID` (~L96), `openSession`
  (~L442), `createSession` (~L491), `chatViewDisappeared` (~L530), `runningChanged`
  teardown (~L699), `fillLiveChat` (~L843), push-tap routing + `replayPendingPushTap`,
  `scenePhaseChanged` (the pattern `layoutChanged` mirrors).
- `HermesKit/Sources/HermesKit/Features/ChatScreen.swift` — marker-only reducer.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `State.transcript`,
  `isSending`, `streamingRowID`, `storedSessionID`, `hasStarted`, `activateResult`
  (~L1035) is the hydrate completion; no "hydrated" flag exists yet.
- `HermesMobile/Sources/AppView.swift` — root `NavigationStack(path:)` under
  `rootScreen == .home` (L35–50); `scenePhase` reported via `.onChange`.
- `HermesMobile/Sources/Features/Chat/ChatView.swift` — `VStack`: banner, `transcript`
  (`CollectionTranscriptView`, the ONLY renderer), footer, `pendingCard`, panels,
  `ComposerView`.
- `HermesMobile/Sources/Features/SessionListView.swift` — rows via `SessionRowView`
  (~L504) with `.listRowBackground(Color.clear)`; settings is a sheet (no nav impact).
- `Project.swift` — `destinations: [.iPhone]` on the app target (L28) and the
  `HermesMobileTests` target (L107); `infoPlist: .extendingDefault(with:)`.
- Tests: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`,
  `ChatFeatureTests*.swift`; iOS target `HermesMobileTests/` with
  `SnapshotTestSupport.swift` (`componentImage()`), measured layout tests in
  `MarkdownTableLayoutTests.swift` / `ApprovalCardLayoutTests.swift`.
- Conventions: `CLAUDE.md` (logic in HermesKit, views thin, TestStore tests, capability
  gating, snapshot rules), `docs/architecture.md` navigation section, `docs/features/`.

## Development Approach

- **testing approach**: Regular (implement, then write tests, per task)
- complete each task fully before moving to the next; commit at each task completion
- make small, focused changes; the iPhone behaviour must stay byte-identical while
  `layout == .compact` (the default) — every existing test must pass untouched
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - TCA reducers: `TestStore` + `@Dependency` overrides + `TestClock`
  - snapshot tests for new views; measured `UIWindow`-hosted XCTest for layout facts a
    snapshot cannot prove
- **CRITICAL: all tests must pass before starting next task** — `make test` for
  HermesKit (`script -q /dev/null swift test --package-path HermesKit`), `make snapshot`
  for the iOS target (judge failures by render-size mismatch — the recorded baselines
  predate the current simulator runtime, see `CLAUDE.md`)
- **CRITICAL: update this plan file when scope changes during implementation**
- commit messages: capitalized verb, no conventional-commit prefixes

## Testing Strategy

- **unit tests**: required for every task (HermesKit `swift test`)
- **snapshot tests**: `make snapshot`; adding ONE new snapshot = run twice (first records
  and fails by design, second asserts). Never `make snapshot-record` in this plan — the
  global re-record is its own commit.
- **layout tests**: `UIWindow`-hosted XCTest with `.dynamicTypeSize(.large)` pinned.
- **manual**: simulator pass on iPhone, iPad landscape, iPad portrait (overlay sidebar),
  Slide Over — recorded in the PR description (Post-Completion).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

1. **Layout is reducer state.** `AppFeature.State.layout: Layout` (`.compact` |
   `.regular`), default `.compact`. `AppView` reports the horizontal size class through
   `layoutChanged(Layout)`, exactly like `scenePhaseChanged`. Size class — not device
   idiom — is the input, so Slide Over and narrow iPadOS 26 windows get the stack.
2. **One predicate.** `isChatDetached = layout == .compact && path.isEmpty` replaces
   every `path.isEmpty` read. In regular the chat is never detached.
3. **The marker is compact-only.** `fillLiveChat` and the re-open path append a
   `ChatScreen` marker only in compact; regular keeps the path empty and the slot IS
   the detail. Layout transitions reconcile: regular→compact with a slot pushes its
   marker; compact→regular clears the path. Layout is updated first so the
   `onDisappear` fired by the chat view moving columns is a no-op via the predicate.
4. **No selection = a fresh new chat.** In regular, `home` present with a nil slot fills
   a new `ChatFeature.State`; archive/delete of the on-screen session refills one after
   teardown; "new session" over an already-empty new chat is a no-op except clearing
   the composer. Connect timing is unchanged (a never-prompted session has no DB row).
5. **One `NavigationSplitView` for both widths.** Sidebar column = the existing
   `NavigationStack(path:)` (list root, chat destination) — in compact the collapsed
   split shows only this column, so the stack is the whole screen. Detail column = the
   slot's `ChatView`. `columnVisibility` is view-local `@State`; style `.automatic`
   (side-by-side landscape, overlay sidebar in portrait).
6. **Selected-row highlight** by passing `currentViewingSessionID` into
   `SessionListView` as a plain optional parameter (nil in compact). No `List(selection:)`.
7. **Hero empty view** swaps the transcript REGION in `ChatView` when
   `ChatFeature.State.showsEmptyHero` is true; predicate in HermesKit, unit-tested;
   `CollectionTranscriptView` stays the only renderer.
8. **Readable-width cap**: transcript + composer wrapped in one container capped at
   `ChatLayout.readableMaxWidth` (760pt) and centered. Cap on the OUTER container only.

## Technical Details

### `AppFeature` additions

```swift
public enum Layout: Equatable, Sendable { case compact, regular }
public var layout: Layout = .compact
public var isChatDetached: Bool { layout == .compact && path.isEmpty }
case layoutChanged(Layout)
```

- `currentViewingSessionID`: `guard !isChatDetached else { return nil }; return liveChat?.sessionKey`.
- `openSession` re-open branch: push a marker only `if layout == .compact && path.isEmpty`.
- `chatViewDisappeared`: `guard isChatDetached, !chat.isRunning, !chat.hasQueuedWork else { return cleanup }`.
- `runningChanged`: `guard !running, isChatDetached, ...`.
- `fillLiveChat`: `state.path.removeAll()`; append the marker only in compact.
- `layoutChanged(new)`: `guard new != state.layout`; set it FIRST; then if a slot exists:
  regular→compact → `path = [ChatScreen.State(sessionKey: chat.sessionKey)]`;
  compact→regular → `path.removeAll()`. If no slot and `new == .regular` and `home != nil`
  → fill a fresh new chat (same construction as `createSession(nil)`).
- New-chat fill helper `newChat(for home:) -> ChatFeature.State` shared by
  `createSession`, `layoutChanged`, `home` appearance in regular, and the post-teardown
  refill for archive/delete in regular. `createSession(nil)` is a no-op (clear composer
  only) when the slot is an EMPTY new chat: `storedSessionID == nil && transcript.isEmpty
  && !isSending && !hasQueuedWork` — exposed as `ChatFeature.State.isEmptyNewChat`.
- Push-tap routing: replace marker checks with the predicate; "different session" sets
  the path to one marker in compact, leaves it empty in regular (this is `fillLiveChat`).
- Logout / profile switch / reauth-different-user already nil the slot and empty the
  path; in regular the `home` re-appearance refills a new chat.

### `ChatFeature` additions

```swift
/// Set when the first hydrate (`activateResult` success) or the fresh
/// `session.create` handshake lands. Unpersisted; per slot.
var hasHydrated: Bool = false
public var showsEmptyHero: Bool {
  transcript.isEmpty && !isSending && streamingRowID == nil
    && (storedSessionID == nil || hasHydrated)
}
public var isEmptyNewChat: Bool { ... see above ... }
public enum ChatLayout { public static let readableMaxWidth: CGFloat = 760 }
```

The `storedSessionID == nil || hasHydrated` clause keeps the hero from flashing for a
resumed session with no snapshot cache before history lands. A resumed session whose
server history is genuinely empty shows the hero after hydrate (correct).

### `AppView`

```swift
case .home:
  NavigationSplitView(columnVisibility: $columnVisibility) {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      SessionListView(store: homeStore, highlightedSessionID: highlighted)
    } destination: { _ in chatDetail }
    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
  } detail: {
    chatDetail   // slot ChatView + .onDisappear { store.send(.chatViewDisappeared) }
  }
  .navigationSplitViewStyle(.automatic)
  .onChange(of: horizontalSizeClass, initial: true) { store.send(.layoutChanged(...)) }
```

`highlighted = store.layout == .regular ? store.currentViewingSessionID : nil`.
`chatDetail` is a `@ViewBuilder` property so both columns render the same view.

### `ChatView` cap + hero

- Wrap `transcript`/`footer`/`pendingCard`/panels/`ComposerView` in a `VStack` given
  `.frame(maxWidth: ChatLayout.readableMaxWidth)` and centered with
  `.frame(maxWidth: .infinity)` on the parent. The cell rule ("never `.frame(maxWidth:)`
  on table cells") is untouched — this is the outer container.
- `transcript` becomes: `if store.showsEmptyHero { ChatEmptyHeroView() } else {
  CollectionTranscriptView(...) }` with the same overlay for the copy toast.
- `ChatEmptyHeroView`: wordmark ("HERMES AGENT", app brand treatment — system serif
  design or the existing brand font/colour, NOT the desktop's licensed face), one tagline
  `String` constant in one place, centered, Dynamic Type, `accessibilityElement(children:
  .combine)`. Dark and light supported via existing `Color+Hermes`.

### `Project.swift`

- App target: `destinations: [.iPhone, .iPad]`; `infoPlist` adds
  `"UISupportedInterfaceOrientations~ipad": [portrait, portraitUpsideDown,
  landscapeLeft, landscapeRight]`; no `UIRequiresFullScreen`.
- `HermesMobileTests` target: `destinations: [.iPhone, .iPad]`.
- Deployment target stays iOS 18.

## Implementation Steps

### Task 1: Layout state and the detached predicate in `AppFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] add `Layout` enum, `layout` state (default `.compact`), `isChatDetached`, and the
  `layoutChanged(Layout)` action with the transition rules (set layout first; push marker
  regular→compact with a slot; clear path compact→regular)
- [x] replace `path.isEmpty` reads with `isChatDetached` in `currentViewingSessionID`,
  `openSession` re-open guard, `chatViewDisappeared`, `runningChanged`
- [x] make the marker compact-only in `fillLiveChat` and the re-open branch
- [x] write tests: default layout compact + full existing suite green untouched;
  `layoutChanged(.regular)` with a pushed marker clears the path and keeps the slot;
  `layoutChanged(.compact)` with a live slot pushes its marker; same layout twice is a no-op
- [x] write tests: in regular, `chatViewDisappeared` never tears down (idle slot);
  `runningChanged(false)` in regular keeps the slot; `currentViewingSessionID` in regular
  reads the slot key with an empty path
- [x] run `make test` — must pass before task 2

### Task 2: New-chat filling rules for regular width

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`isEmptyNewChat`)
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift` (or the closest existing
  ChatFeature state test file)

- [x] add `ChatFeature.State.isEmptyNewChat`
- [x] extract `newChat(for:)` helper; use it in `createSession`; `createSession(nil)`
  over an empty new chat → clear composer only, no teardown/redial
- [x] fill a fresh new chat when `layout == .regular` and the slot is nil: on
  `layoutChanged(.regular)`, when `home` becomes non-nil in regular, and after the
  archive/delete teardown of the on-screen session in regular
- [x] `openSession` in regular fills the slot with no marker (path stays empty)
- [x] write tests: home appearing in regular fills a new chat; `layoutChanged(.regular)`
  with nil slot fills a new chat; new-session over empty new chat is a no-op (composer
  cleared, no `teardown` action); new-session over a non-empty chat tears down and refills;
  archive of the on-screen session in regular tears down then refills a new chat; the same
  in compact leaves the slot nil
- [x] write tests for `isEmptyNewChat` (true for fresh; false with stored id / transcript /
  sending / queued work)
- [x] run `make test` — must pass before task 3

### Task 3: Push-tap routing under the predicate

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] rewrite the #32 rules on `isChatDetached`: match + not detached → in-place
  hydrate; match + detached (compact only) → push marker + `.reattached`; different →
  `fillLiveChat` (marker only in compact); cold-launch `replayPendingPushTap` unchanged in
  shape
- [x] write tests in regular: tap for the on-screen session hydrates in place with empty
  path; tap for a different session replaces the slot with empty path; cold-launch replay
  in regular ends with empty path and filled slot
- [x] re-run the existing compact push-tap tests untouched (they define the compact rules)
- [x] run `make test` — must pass before task 4

### Task 4: `showsEmptyHero` predicate in `ChatFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatFeatureTests.swift` (closest existing file)

- [x] add `hasHydrated` (set on `activateResult(.success)` and on the fresh-session
  `.ready`/create path; cleared never — per-slot lifetime)
- [x] add `showsEmptyHero` and `ChatLayout.readableMaxWidth = 760`
- [x] write the truth-table tests: fresh new chat → true; resumed + not hydrated + empty
  transcript → false; resumed + hydrated + empty → true; any transcript row → false;
  `isSending` → false; `streamingRowID != nil` → false
- [x] write a reducer test: `activateResult(.success(empty history))` flips `hasHydrated`
  and the hero shows; a delta then hides it
- [x] run `make test` — must pass before task 5

### Task 5: Project manifest — iPad destination and orientations

**Files:**
- Modify: `Project.swift`

- [x] add `.iPad` to the `HermesMobile` and `HermesMobileTests` destinations
- [x] add `UISupportedInterfaceOrientations~ipad` (all four); confirm no
  `UIRequiresFullScreen`
- [x] `tuist generate --no-open` and `make build` — the app builds for
  `generic/platform=iOS Simulator`
- [x] run `make snapshot` to confirm the test target still builds and the failure set is
  unchanged from `main` (baseline-drift only; see CLAUDE.md) — 199 run / 36 failed, every
  failure equal render size (pixel residual only)
- [x] run tests — must pass before task 6

### Task 6: `ChatEmptyHeroView` and the transcript-region swap

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/ChatEmptyHeroView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Create: `HermesMobileTests/ChatEmptyHeroSnapshotTests.swift`

- [x] create `ChatEmptyHeroView` (wordmark + one tagline constant, centered, Dynamic Type,
  combined accessibility element, light/dark)
- [x] in `ChatView.transcript`, render the hero instead of `CollectionTranscriptView` when
  `store.showsEmptyHero`, keeping the copy-toast overlay and the layout priority behaviour
- [x] snapshot tests: phone width (390pt) and 760pt column, light + dark, pinned
  `.dynamicTypeSize(.large)`; one at `.accessibility3` — pin BOTH width and height (the
  hero fills a scrollable region's slot); plus one fixed-frame `ChatView` render of a
  brand-new chat proving the region swap (hero above the pinned composer)
- [x] record each new snapshot with two `make snapshot` runs; verify the images by eye
- [x] run `make test` + `make snapshot` — must pass (new ones clean) before task 7 —
  1253 HermesKit tests green; snapshot 205 run / 36 failed, the same equal-render-size
  drift set as Task 5, the 6 new hero snapshots assert clean

### Task 7: Readable-width cap on the chat column

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Create: `HermesMobileTests/ChatColumnLayoutTests.swift`

- [x] wrap transcript/footer/card/panels/composer in one container limited to
  `ChatLayout.readableMaxWidth` and centered; the connection banner and toast stay
  within the same container — `.frame(maxWidth: readableMaxWidth)` + `.frame(maxWidth:
  .infinity)` on `ChatView`'s outer `VStack`, which already holds all of them
- [x] confirm `MarkdownTableView` panning and `CappedWidthLayout` cells are untouched (cap
  is on the outer container) — no change to `MarkdownTableView.swift`; measured: a
  five-column prose table inside the capped 1024pt column still pans within the column
- [x] measured `UIWindow`-hosted XCTest (1024×768 window, `.dynamicTypeSize(.large)`):
  the chat content width equals `readableMaxWidth` and is horizontally centered; at a
  390pt window the content width equals the window width (no cap below the constant) —
  `ChatColumnLayoutTests` (4 tests, incl. the cap boundary from both sides); red-checked
  against the un-capped view (3 of 4 go red, the phone one passes both ways by contract)
- [x] run `make snapshot` — existing chat snapshots unchanged in render size (phone widths
  are below the cap) — 209 run / 36 failed, zero size mismatches (all 36 are the
  equal-render-size pixel drift set from Tasks 5–6), the 4 new layout tests pass
- [x] run tests — must pass before task 8 — 1253 HermesKit tests green

### Task 8: `NavigationSplitView` root in `AppView`

**Files:**
- Modify: `HermesMobile/Sources/AppView.swift`

- [ ] replace the `.home` branch with `NavigationSplitView`: sidebar = existing
  `NavigationStack(path:)` block verbatim (list root, chat destination with
  `.onDisappear { store.send(.chatViewDisappeared) }`); detail = the same `chatDetail`
  builder; `columnVisibility` as `@State`, `.automatic` style, sidebar column width
  `min 280 / ideal 320 / max 400`
- [ ] report `horizontalSizeClass` via `.onChange(of:initial:)` → `layoutChanged`
- [ ] detail fallback when the slot is nil: empty view (section 4 guarantees a fill in
  regular)
- [ ] `make build`; launch on an iPhone simulator via `make run` and confirm the list,
  push, pop, and running-turn keep-alive behave as on `main` (collapsed split container)
- [ ] launch on an iPad simulator (landscape + portrait) and confirm: sidebar + detail,
  hero on empty detail, tapping a session fills the detail with no push, portrait shows
  the overlay sidebar, rotating keeps the chat
- [ ] run `make test` — must pass before task 9

### Task 9: Selected-row highlight in the sidebar

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobile/Sources/AppView.swift`
- Modify: `HermesMobileTests/SessionSnapshotTests.swift`

- [ ] add `highlightedSessionID: String? = nil` to `SessionListView`; tint the matching
  row's `listRowBackground` with the brand accent at low opacity (respecting
  reduce-transparency)
- [ ] pass `store.layout == .regular ? store.currentViewingSessionID : nil` from `AppView`
- [ ] snapshot test: a list with one highlighted row (pinned width/height) — two
  `make snapshot` runs to record
- [ ] verify on iPad that the highlight tracks the detail after open, new session (no
  highlight), and archive of the on-screen session
- [ ] run tests — must pass before task 10

### Task 10: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented (split layout, hero on both
  devices, cap, compact behaviour byte-identical)
- [ ] verify edge cases: layout change mid-turn keeps the socket; `chatViewDisappeared`
  during the column move is a no-op; logout in regular lands on onboarding with no slot;
  profile switch in regular refills a new chat under the new profile; Slide Over (compact)
  on iPad behaves like the phone
- [ ] run full test suite: `make test`
- [ ] run `make snapshot` and confirm every new snapshot asserts clean; pre-existing
  failures are baseline drift only (equal render size)
- [ ] run `make build`

### Task 11: [Final] Update documentation

- [ ] create `docs/features/ipad-layout.md`: `isChatDetached`, compact-only marker,
  transition rules, new-chat fill rules, `readableMaxWidth`, `showsEmptyHero` +
  `hasHydrated`, why `List(selection:)` was rejected, why the marker stays compact-only,
  #90 pointer for multi-slot
- [ ] update `docs/architecture.md` navigation section (#33 paragraph) with the split view
  and "detached means compact and empty path"
- [ ] update `CLAUDE.md` #33 bullets with the predicate wording, the hero rule, the cap
  rule, and add `ipad-layout.md` to the features pointer
- [ ] update `README.md` platform line (iPhone + iPad) if it names the platform
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- iPhone 17 Pro simulator: list → chat → pop while a turn runs → glow → re-open resumes
  live rows (the #33 policy, now inside a collapsed split container)
- iPad landscape: sidebar + detail; hero; open; switch mid-turn (old row glows); new
  session no-op over an empty chat; approval card renders inside the capped column
- iPad portrait: overlay sidebar via toggle; rotate landscape↔portrait with a running
  turn — socket survives
- Slide Over / narrow window on iPadOS 26: stack layout; widen back to regular — path
  clears, chat stays
- Dynamic Type at accessibility sizes on the hero
- PR description records the four simulator passes; PR closes #80

**External system updates:**
- App Store Connect: iPad screenshots become required for the listing once the iPad
  destination ships (separate ASC task, not part of this plan)
- TestFlight build: bump build number as usual; the iPad TestFlight reviewer from #80's
  feedback can validate
