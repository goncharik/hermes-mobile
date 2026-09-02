# iPad split-view layout (#80)

The short rules live in `CLAUDE.md` → "Gateway & session lifecycle" (#33 bullet) and
"Transcript & chat UI"; this doc is the full contract. Design history:
`docs/plans/completed/20260902-ipad-split-layout.md`. Multi-slot sockets (one socket per
running session, so two chats could stream side by side) are deliberately out of scope —
tracked as **#90**; the app keeps ONE live-chat slot.

## Layout is reducer state; the input is the size class, not the idiom

`AppFeature.State.layout: Layout` (`.compact` | `.regular`, default `.compact`) is mirrored
from SwiftUI's `horizontalSizeClass` by `AppView` through `layoutChanged(Layout)` — the same
shape as `scenePhaseChanged`. **Size class, not `UIUserInterfaceIdiom`**: Slide Over, a narrow
Stage Manager window, and an iPhone all report `.compact` and get the stack layout; the same
iPad flips between regimes as its window narrows and widens. `nil` (unresolved) maps to
`.compact` so an early read never flips anything. The size class is read at the `AppView`
ROOT and the `.onChange(of:initial: true)` is attached to `content` (every root branch), not
to the split view: inside a sidebar column the environment reports `.compact` even on a 13"
iPad, and the home-landing fills + the cold-launch push replay read `state.layout` the moment
`home` appears, so the layout must be known before the `.home` branch exists.

## `isChatDetached` — the one predicate

```swift
public var isChatDetached: Bool { layout == .compact && path.isEmpty }
```

Before #80, `path.isEmpty` in `AppFeature` meant "the chat is detached (user is on the list)".
In a split view the chat is never detached in regular width — the slot IS the detail column
and the path is always empty there — so a bare `path.isEmpty` would read every regular-width
chat as popped and tear it down. Every former `path.isEmpty` read moved to the predicate:
`currentViewingSessionID` (nil when detached → pushes for that session are NOT suppressed),
the `chatViewDisappeared` idle-pop teardown guard, the `runningChanged(false)`
detached-turn-end teardown, the `openSession` re-open marker push, and the #32 push-tap dedup.
Compact is byte-identical by construction: with `layout == .compact` the predicate reduces to
the old `path.isEmpty`.

Consequences in regular: `chatViewDisappeared` is always cleanup-only (the view fires it when
it moves between the stack and the detail column on a size-class change — never a teardown);
`runningChanged(false)` only updates the glow; the slot survives every layout flip with its
socket (one dial, zero terminations across compact→regular→compact→regular, mid-turn).

## The `ChatScreen` marker is compact-only

`fillLiveChat` clears the path and appends the marker **only in compact**; the `openSession`
re-open branch pushes one only when `isChatDetached`. In regular the path stays empty because
the detail column renders the slot directly — a marker there would render the chat TWICE
(sidebar stack + detail), and a running turn's rows would stream into both.

**Layout transitions** (`layoutChanged`): same layout twice is a no-op. Otherwise `layout` is
set FIRST — so the `chatViewDisappeared` fired by the column move reads the new regime through
the predicate — then the path is reconciled with the slot: regular→compact with a slot SETS the
path to that chat's single marker (`StackState([…])`, never append — one slot ↔ one marker;
a not-yet-created new chat gets a nil-key marker); compact→regular clears the path. The slot
itself (socket, rows, ticker) is untouched either way. Widening with NO slot falls into the
new-chat fill below.

## New-chat fill rules for regular width

Regular renders the detail column at all times, so an empty slot would be a blank column.
`newChat(for: home, composerText:)` is the ONE construction (connection + `scopedProfileName`
from the list) behind every fill, so they cannot drift:

- **Home appearance** — `landOnHome` (the renamed cold-launch replay funnel, shared by the
  launch probe, the retry screen, manual login, and different-user reauth). Replay decides
  first: a stashed tap's `openSession` fills the slot itself, so a replayed tap never has to
  tear down a throwaway seat; only the no-replay (and dropped-foreign-origin) branches call
  `fillNewChatIfDetailEmpty` (`layout == .regular && liveChat == nil && home != nil`).
- **`layoutChanged(.regular)`** with a nil slot seats one; narrowing never fills.
- **Archive / delete of the on-screen session** — `teardownSlot(thenFill: detailRefill(state))`:
  a fresh new chat in regular, `nil` in compact (the user is on the list). Delete keeps its
  `flushSnapshot: false` + snapshot wipe (`docs/features/session-list.md`).
- **Profile-switch reseat** — a reducer-level `.onChange(of: \.home?.scopedProfileName)`,
  evaluated after the list reducer so it reads the new selection. In regular only, an
  `isEmptyNewChat` slot whose connection/profile no longer match the list's is reseated
  through the standard teardown chain (its socket may already be dialled) so its first prompt
  lands in the right profile's `state.db`. A chat with anything in it is left alone — the
  profile is the LIST's scope, not the open chat's. Observing the value (not `.selectProfile`)
  covers every path that changes it: the profiles-404 verdict re-homing to default, a
  rename/delete of the selected profile, the capability flipping off. Landing on a fresh
  `home` trips it too, but the seat `landOnHome` just filled already matches → no-op.
- **"New session" is a no-op over a reusable seat** — `isReusableNewChat(chat, for: home)` =
  `ChatFeature.State.isEmptyNewChat` (`storedSessionID == nil && transcript.isEmpty &&
  !isSending && !hasQueuedWork` — a draft, staged attachments, or a connected-but-unprompted
  live id do NOT make it non-empty) AND same connection AND same `scopedProfileName`. Tearing
  it down to fill an identical fresh one would redial the socket for nothing, so it resets the
  composer draft (text → the `initialComposerText` seed or empty; attachments cleared) and
  returns `.none`. A stale profile/connection falls through to a real refill. Compact safety
  net: a detached empty chat in that branch gets its marker re-pushed so a "New" tap always
  lands on a screen.

**`.fillLiveChat` dials the replacement in regular.** The initial connect is the chat view's
`.task`. In compact the fresh marker's destination is a NEW view, so it fires. In regular
there is no marker: the detail column renders the slot directly, and the whole
`persistNow → .teardown → .clearLiveChat → .fillLiveChat` chain reduces synchronously
(`.send` is a `Just`), so SwiftUI never observes the nil slot, the `ChatView` keeps its
identity, and its `.task` never re-fires — the replacement would sit undialled. So
`.fillLiveChat` returns `.send(.liveChat(.task))` when `layout == .regular` (`.none` in
compact, unchanged); `hasStarted` makes a later view `.task` idempotent, never a redial. A
view-side `.id()` was rejected: there is no stable per-fill key (`sessionKey` flips nil → id
on create and would recreate the view mid-turn). Connect timing for a never-prompted seat is
otherwise unchanged — it has no DB row until the first prompt.

## One `NavigationSplitView` for both widths

`AppView`'s `.home` branch is ONE `NavigationSplitView(columnVisibility:)` with
`.navigationSplitViewStyle(.automatic)`: the **sidebar column hosts the existing
`NavigationStack(path:)`** (list root, `chatDetail` destination, column width min 280 / ideal
320 / max 400); the **detail column is the same `chatDetail`** `@ViewBuilder` (slot `ChatView` +
`.onDisappear { store.send(.chatViewDisappeared) }`; an implicit empty view when the slot is
nil, which the reducer prevents in regular). In compact the split collapses to its sidebar
column, so the stack is the whole screen — the pre-#80 iPhone root inside a collapsed
container. `columnVisibility` is view-local `@State`, not reducer state: it decides nothing
the reducer needs (`layout` does that) and mirroring it would only add a binding round-trip
for the system's own toggle. `.automatic` gives side-by-side columns in landscape and an
overlay sidebar in portrait.

**Selected-row highlight, no `List(selection:)`.** `AppView` passes
`store.layout == .regular ? store.currentViewingSessionID : nil` into `SessionListView`
(`highlightedSessionID: String? = nil`; `currentViewingSessionID` is `public` for this) and the
matching row gets `.listRowBackground(SelectedRowBackground())` — an inset 12pt continuous
rounded rect in `hermesAccent` at 0.18 opacity, swapped for the equivalent OPAQUE mix into
`systemBackground` under Reduce Transparency; every other row passes `nil` (a `Color.clear`
would change the iPhone render). `List(selection:)` was rejected because selection would be a
SECOND source of truth for "which session is open", racing the reducer-owned slot on push
taps, archive/delete refills, and layout changes; a new chat whose id hasn't resolved reads
`nil` and highlights nothing. In compact the list is never visible alongside the chat, so the
row stays plain and the 25 pre-existing session-list baselines are unchanged.

## Empty-chat hero: `showsEmptyHero` + `hasHydrated`

```swift
public var showsEmptyHero: Bool {
  transcript.isEmpty && !isSending && streamingRowID == nil
    && (storedSessionID == nil || hasHydrated)
}
```

`ChatView.transcript` swaps the REGION: `ChatEmptyHeroView` when true, else the unchanged
`CollectionTranscriptView` (still the ONLY transcript renderer — the hero is display-only,
no store). Both branches are greedy in the same way, so the copy-toast overlay and the
approval-card `layoutPriority` at the call site behave identically. The hero shows on any
device (a brand-new chat on iPhone too): wordmark `HERMES AGENT` (system serif, `.largeTitle`
semibold, tracking 4, `hermesAccent`) over the ONE tagline constant
`ChatEmptyHeroView.tagline` = "Start a conversation with your agent." (`.body` secondary),
centered, wraps at accessibility sizes (`fixedSize(horizontal: false, vertical: true)`), one
combined VoiceOver element.

**The no-flash rationale.** `hasHydrated` (internal, false at init, never cleared — per-slot,
unpersisted) is set on every `applyActivate` success (resume / activate / branch probe /
post-slash refresh) AND on the fresh-session `session.create` handshake (`sessionResult`).
Without the `storedSessionID == nil || hasHydrated` clause a resumed session opened with no
snapshot cache has an empty transcript for the round-trip before history lands and would flash
the hero, then replace it with history. A resumed session whose server history is genuinely
empty shows the hero after the hydrate (correct). The create-handshake set matters because the
handle may carry `stored_session_id`, which would otherwise flip the hero OFF for a chat whose
only history is the nothing the server just created. A running-turn hydrate with empty history
hides it via `isSending`.

## `ChatLayout.readableMaxWidth` — the cap on the OUTER container

`ChatLayout.readableMaxWidth = 760` lives in HermesKit (`ChatFeature.swift`) so the view and
the measured layout test read ONE value. `ChatView`'s outer `VStack` — banner, transcript +
toast, footer, pending card, queued-prompts and slash panels, `Divider`, `ComposerView` — carries
`.frame(maxWidth: ChatLayout.readableMaxWidth)` then `.frame(maxWidth: .infinity)`, so in a
wide column the whole chat is one 760pt container centered by the greedy outer frame and the
composer sits under the text it belongs to. The frames precede `.animation`/`.navigationTitle`
so the nav chrome still spans the window. Every phone width is below the cap → compact is
byte-identical. **The cap is on the OUTER container only**: table cells keep `CappedWidthLayout`
(a `.frame(maxWidth:)` cannot cap anything inside a horizontal `ScrollView` —
`docs/features/markdown-rendering.md`), and `MarkdownTableView` still pans inside the column.

## Project manifest

`destinations: [.iPhone, .iPad]` on both `HermesMobile` and `HermesMobileTests`;
`UISupportedInterfaceOrientations~ipad` lists all four orientations (iPhone keeps Tuist's
default three); **no `UIRequiresFullScreen`** — Slide Over and narrow windows must resolve to
the compact layout. Deployment target stays iOS 18 (`Color.mix(with:by:)` is iOS 18 API).

## Known limitations

- **The portrait overlay sidebar does not auto-dismiss after a row tap** — the detail updates
  behind it; the user taps outside to close it. Dismissing needs the view to observe the slot
  change and set `columnVisibility = .detailOnly`, which is not a one-line reduce-motion-safe
  change and re-introduces exactly the view-side selection tracking `List(selection:)` was
  rejected for. Left as system behaviour.
- **iPad LANDSCAPE side-by-side columns and rotate-keeps-chat were never verified on a
  simulator** (⚠️): `simctl` has no rotate, the Simulator orientation pref did not rotate the
  device, and System Events is denied assistive access in the sandbox. Portrait (overlay
  sidebar, fill-without-push, hero seat, refill after archive, highlight tracking) was verified
  on an iPad Pro 13" / iOS 26.5. The reducer side of rotation — the socket surviving the layout
  change both ways — is covered by `layoutChangeMidTurnKeepsSocketAndSlotBothWays`.
- The profile-switch reseat was not exercised live on the iPad (demo mode exposes only the
  default profile); it is covered by reducer tests.
- Out of scope by decision: keyboard shortcuts, multi-window / Stage Manager showing two chats,
  a socket per running session (#90).

## Tests that pin each invariant

- `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift` — "Layout regime + the detached
  predicate" (`defaultLayoutIsCompactAndDetachedMeansEmptyPath`,
  `layoutChangedToRegularClearsPathAndKeepsSlot`, `layoutChangedToCompactWithLiveSlotPushesMarker`,
  `layoutChangedToCompactWithNewChatPushesNilKeyMarker`, `layoutChangedToSameLayoutIsNoOp`,
  regular `chatViewDisappeared` / `runningChanged` / `currentViewingSessionID`); "New-chat
  filling rules for regular width" (`homeAppearingInRegularFillsNewChat`,
  `homeAppearingInRegularWithStashedTapOpensThatSessionInstead`,
  `layoutChangedToRegularWithNilSlotFillsNewChat`, `layoutChangedToCompactWithNilSlotDoesNotFill`,
  `newSessionOverEmptyNewChatClearsComposerOnly`, `newSessionOverEmptyNewChatUnderStaleProfileRefills`,
  `newSessionOverNonEmptyChatInRegularTearsDownAndRefills`,
  `openingSessionInRegularOverEmptyNewChatReplacesItWithoutMarker`,
  `slotReplacementInRegularDialsReplacementExactlyOnce`, `archivingOnScreenSessionInRegularRefillsNewChat`
  + the compact/delete counterparts); "Push-tap routing in regular width" (on-screen tap
  hydrates in place with an empty path; different session replaces with an empty path;
  cold-launch replay in regular); "Acceptance edge cases"
  (`layoutChangeMidTurnKeepsSocketAndSlotBothWays`, `chatViewDisappearedDuringColumnMoveKeepsIdleSlotBothWays`,
  `logoutInRegularLandsOnOnboardingWithNoSlot`, `profileSwitchInRegularReseatsEmptyChatUnderNewProfile`,
  `profileSwitchInRegularLeavesNonEmptyChatAlone`, `profileSwitchInCompactLeavesEmptyChatAlone`).
  Every pre-existing compact test is untouched — that is the byte-identical guard.
- `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift` — `isEmptyNewChat*` (5) and the
  `showsEmptyHero*` truth table + `hydrateWithEmptyHistoryShowsHeroAndADeltaHidesIt`,
  `hydrateOfRunningTurnWithEmptyHistoryHidesHero`, `createHandshakeMarksHydratedSoStoredIDKeepsHero`.
- `HermesMobileTests/ChatColumnLayoutTests.swift` — measured `UIWindow`-hosted: 1024pt window →
  760pt column at x=132 with the composer centered; the cap boundary from both sides (760 fills
  edge to edge, 800 → 760 at x=20); a 390pt window is never narrowed; a five-column table inside
  the capped column is laid out within it and still pans.
- `HermesMobileTests/ChatEmptyHeroSnapshotTests.swift` — hero at 390pt and the 760pt column,
  light + dark, `.accessibility3` wrap, and `testChatView_newChat_showsHero` (the region swap
  above the pinned composer). Every render pins BOTH dimensions (greedy region).
- `HermesMobileTests/SessionSnapshotTests.swift` — `testSessionList_highlightedRow` (+ `_light`)
  via `deviceImage()` (a `.sizeThatFits` layer render of the `List` painted no rows).
