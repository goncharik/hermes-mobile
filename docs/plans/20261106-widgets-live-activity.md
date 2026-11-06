# Widgets, Control Center controls and a running-agents Live Activity (#138)

## Overview
- Home Screen, Lock Screen and Control Center surfaces for Hermes, plus one aggregate Live
  Activity that shows running agents on the Lock Screen and in the Dynamic Island (T3 Code style).
- Surfaces:
  - **Quick actions** widget, `systemSmall` + `systemMedium`: an "Ask Hermes" pill plus round
    buttons. Small = Camera + Mic; medium = Camera + Photos + Mic. The voice-conversation
    waveform waits for #92. The labeled shortcut-grid kind is deliberately not built.
  - **Sessions** widget: `systemMedium` (headline session) + `systemLarge` (top 5 rows), with
    status glyphs (working / needs input / outdated).
  - **Lock screen** `accessoryCircular` (opens a new chat) and two **Control Center**
    `ControlWidget`s (New Chat, Dictate).
  - **Live Activity**: ONE aggregate activity, "N active agent(s)", headline session title,
    workspace and status (Working / Needs input / Done / Outdated). Settings toggles: Live
    Activity (default on) and Show session titles (default on).
- Thin client holds: the widget extension never touches the network or the Keychain. Freshness
  is local only. When the app can no longer observe, the surfaces say "Outdated" instead of
  guessing (`ActivityContent.staleDate` + a scheduled "outdated" timeline entry). No plugin or
  gateway changes and no ActivityKit pushes.
- Design is user-validated (brainstorm 2026-11-06); this plan does not reopen decisions.

## Context (from discovery)
- **#93 routing is the model** (`docs/features/app-intents.md`):
  - `LaunchIntent` (`HermesKit/Sources/HermesKit/Models/LaunchIntent.swift`): `.newChat`,
    `.newChatWithDictation`, quick-action literals.
  - `LaunchIntentBridge` / `LaunchIntentClient` (`Clients/LaunchIntentClient.swift`): cold-launch
    buffer.
  - `AppFeature.launchIntentReceived` (`AppFeature.swift:537`): stash when `home == nil`,
    last-wins with `pendingPushTap`, replay in `landOnHome` (`:1266`), cleared at the four logout
    sites (`:448`, `:745`, `:792`, `:824`).
  - `reduceCreateSession` (`:996`) sets `chat.pendingDictation` or sends `.liveChat(.startDictation)`.
- **Push-tap routing (#32)**: `reducePushTapped` (`AppFeature.swift:1067`) has the in-place /
  detached / replace rules plus a stash that records `pendingPushTapServerURL`, so a different
  server's login drops it.
- **Dictation one-shot**: `ChatFeature.State.pendingDictation` (`ChatFeature.swift:765`),
  consumed by `consumePendingDictation` (`:3873`) at the `hasStarted` branch of `.task` (`:1521`);
  `.startDictation` (`:2256`) for a reused seat.
- **Attachments**: `.attachCameraTapped` / `.attachPhotosTapped` (`ChatFeature.swift:2426`) call
  `attachmentPicker.capturePhoto()` / `pickPhotos()`.
- **Running / needs-input state**:
  - `SessionStatus` (`Models/SessionCardContent.swift:48`).
  - `AppFeature.State.needsInputSessionIDs` (`AppFeature.swift:147`).
  - The list row's `isActive` is set instantly by `runningChanged` (`SessionListFeature.swift:716`)
    and refreshed by the poll.
  - Search shares `sessions` (`isSearching`, `:260`), so the projection needs an unfiltered source.
- **Scene edges**: `AppFeature` `.background` (`AppFeature.swift:476`) sets `isSceneBackgrounded`,
  and a running slot begins the ~30 s grace task (`chat.isRunning`).
- **Existing derived edge to copy**: `.onChange(of: \.offersQuickActions)` → `quickActions.setItems`
  (`AppFeature.swift:956`).
- **Prefs**: `PreferencesClient` (`Clients/PreferencesClient.swift`), logout clears every entry.
- **Settings**: `SettingsView` Notifications group (`HermesMobile/Sources/Features/Settings/SettingsView.swift:125`),
  `docs/features/settings.md`.
- **HermesKit cannot be linked into an extension** as is: `UIApplication.shared` in `PushClient`,
  `QuickActionsClient`, `IdleTimerClient`, `BackgroundTaskClient`, `OAuthLoginClient`.
- **Build / signing**:
  - `Project.swift` has two targets: `HermesMobile` and `HermesMobileTests`.
  - The `aps-environment` entitlement comes from `$(APS_ENVIRONMENT)`.
  - TestFlight uses a manual-signing export (`docs/development.md` §TestFlight distribution).
  - A git worktree needs an empty untracked `Tuist/` dir at the root.

## Development Approach
- **testing approach**: Regular (code first, then tests)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change: `script -q /dev/null swift test --package-path HermesKit`
- new source files in the app / extension / test targets need `tuist generate --no-open` before
  `xcodebuild` sees them
- app build check: `make build` (Simulator, no signing). It must build the new extension too.
- snapshot tests: `make snapshot`. Run it twice when adding new tests: the first run records and
  fails by design, the second must pass.
- maintain backward compatibility: the #93 intents, quick actions and push-tap routing are
  unchanged in behaviour
- commit at each task completion (capitalized verb, no conventional prefixes); never commit
  `HermesKit/Package.resolved` drift (`git checkout -- HermesKit/Package.resolved`)

## Testing Strategy
- **unit tests (`swift test`, macOS)**:
  - HermesWidgetKit pure types: deep links, staleness, snapshot coding.
  - `AgentStatusProjection`.
  - `TestStore` suites for `AppFeature` (URL routing, `openSession`, mirror + Live Activity sync,
    background edge, logout), `ChatFeature` (`pendingLaunchAction`), `SettingsFeature` (toggles).
  - `TestClock` for the debounce.
- **snapshot tests (`HermesMobileTests`, `make snapshot`)**:
  - Every widget family in light / dark, plus the tinted rendering mode where the API allows.
  - The outdated, signed-out and empty states.
  - The Live Activity lock-screen and expanded views rendered as plain views.
  - The Settings rows.
  - Widget views are compiled into the test target directly (an extension can't be imported).
- No UI e2e suite exists; on-device behaviour (widget gallery, controls, Live Activity) is listed
  under Post-Completion.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Packaging**:
  - A second, Foundation-only library product `HermesWidgetKit` in `HermesKit/Package.swift`.
  - HermesKit depends on it and re-exports it (`@_exported import HermesWidgetKit`), so existing
    code is unchanged.
  - The extension links ONLY HermesWidgetKit: no TCA, no GRDB, no `UIApplication`.
  - `SessionStatus` and `LaunchIntent` move down into it.
- **Every tap is a URL** (`hermesmobile://…`):
  - Widgets use `Link` / `widgetURL`.
  - The small widget and the controls use an AppIntent in the extension that returns
    `.result(opensIntent: OpenURLIntent(url))`.
  - The app has one `.onOpenURL` → `WidgetDeepLink.parse` → `LaunchIntentBridge.shared.received`.
  - All #93 machinery (cold-launch buffer, stash, last-wins, logout clear) applies unchanged.
- **New `LaunchIntent` cases**:
  - `.newChatWithCamera` and `.newChatWithPhotos`: new chat plus a one-shot action.
  - `.openSession(id:profile:)`: follows #32 push-tap routing, does not arm the approval hint,
    and its stash remembers the server URL.
- **`ChatFeature.pendingDictation: Bool` → `pendingLaunchAction: LaunchAction?`**
  (`.dictation` / `.camera` / `.photos`), with one `consumePendingLaunchAction`. The reused-seat
  path sends `.startLaunchAction(_)`. The #93 rules carry over:
  - only the launch auto-connect landing keeps the action;
  - the action is dropped behind re-auth;
  - the mic starts only from idle.
- **One derived projection, one edge**:
  - `AppFeature.State.agentStatus: AgentStatusProjection?` is pure and `Equatable`, with no
    timestamps.
  - One `.onChange(of: \.agentStatus)` drives a debounced effect that writes the App Group mirror,
    reloads widget timelines, and syncs the Live Activity (start / update / end).
  - `nil` means "unknown": hold, write nothing, never end.
- **Staleness = `freshUntil`**:
  - Foreground writes `now + 8h`.
  - The background edge writes `now + (grace task ? 30 s : 0) + 10 s`.
  - The activity `staleDate = freshUntil`.
  - The widget timeline returns a fresh entry plus an "outdated" entry at `freshUntil`.
- Rejected alternatives (brainstorm):
  - Writers scattered across `SessionListFeature` / `ChatFeature`.
  - A `@Shared(.fileStorage)` mirror plus an observer outside the reducer (untestable, breaks
    "clients over `@Shared`").
  - Push-driven Live Activity (would need plugin and gateway work).

## Technical Details

### HermesWidgetKit types (Foundation-only, all `Sendable`, `Codable` where persisted)

```swift
public enum SessionStatus { case needsInput, working, unread, idle }   // moved, + Codable
public enum LaunchIntent: Equatable, Sendable {                         // moved
  case newChat, newChatWithDictation, newChatWithCamera, newChatWithPhotos
  case openSession(id: String, profile: String?)
}
public enum LaunchAction: String, Codable, Sendable { case dictation, camera, photos }

public enum AppGroup {
  public static let identifier = "group.me.honcharenko.HermesMobile"
  public static let snapshotFileName = "widget-sessions.json"
}

public enum WidgetDeepLink {            // hermesmobile://new[?with=camera|photos|dictation]
  public static let scheme = "hermesmobile"   //   hermesmobile://session/<id>[?profile=<name>]
  public static func url(for intent: LaunchIntent) -> URL
  public static func intent(from url: URL) -> LaunchIntent?   // nil for anything unknown
}

public struct WidgetSessionRow: Codable, Equatable, Sendable, Identifiable {
  public var id: String; public var title: String; public var workspace: String?
  public var status: SessionStatus; public var updatedAt: Date?; public var profile: String?
}
public struct WidgetSessionSnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public var version: Int; public var freshUntil: Date
  public var isSignedIn: Bool; public var rows: [WidgetSessionRow]   // ≤ 5
  public static func decodeLeniently(_ data: Data?) -> WidgetSessionSnapshot?   // corrupt/newer → nil
}

public enum WidgetStaleness {
  public static func isOutdated(_ snapshot: WidgetSessionSnapshot, at now: Date) -> Bool
  /// What a row's trailing glyph shows: working/needsInput become `.outdated` past freshUntil.
  public static func displayStatus(_ row: WidgetSessionRow, snapshot: WidgetSessionSnapshot,
                                   at now: Date) -> RowGlyph   // .working .needsInput .outdated .none
}

public struct AgentActivityContent: Codable, Hashable, Sendable {   // ActivityKit ContentState
  public enum Status: String, Codable, Sendable { case working, needsInput, done }
  public var activeCount: Int
  public var headlineTitle: String?      // nil when "Show session titles" is off
  public var headlineWorkspace: String?
  public var headlineSessionID: String?
  public var headlineProfile: String?
  public var status: Status
}
```

`HermesActivityAttributes: ActivityAttributes` (`ContentState = AgentActivityContent`, no
static attributes) lives in HermesWidgetKit under `#if os(iOS) && canImport(ActivityKit)`, so the
app (via HermesKit) and the extension share one type. ActivityKit requires the same type in both
processes. The macOS test build compiles it out; the pure `AgentActivityContent` stays outside the
guard.

### HermesKit additions
- `AgentStatusProjection: Equatable` (pure, `Models/AgentStatusProjection.swift`):
  - `make(sessions: [Session]?, needsInput: Set<String>, slotRunning: (id: String, running: Bool)?, showsTitles: Bool, profile: String?)`
    → `AgentStatusProjection?`; returns `nil` when `sessions == nil`.
  - Rules: interactive only (`!isCron`). `status` per row from
    `SessionStatus(needsInput:isWorking:isUnread:)`. The slot's live running flag overrides the
    row's `isActive`.
  - Sort: needs-input, then working, then `updatedAt` desc. Rows capped at 5.
  - `activeCount` = needs-input ∪ working.
  - `headline` = the first needs-input row, else the first working row, else `nil`.
  - `activityContent` (`AgentActivityContent?`, `nil` when `activeCount == 0`) carries the title
    only when `showsTitles`.
- `SessionListFeature.State.statusSessions: IdentifiedArrayOf<Session>?`:
  - `nil` until the first successful UNFILTERED fetch of the process. This is the "a cached guess
    never starts anything" gate.
  - Replaced on each unfiltered `sessionsResponse(.success)`; search responses never touch it.
  - Patched by the same `runningChanged` mutation that sets `isActive`.
  - Reset to `nil` on a profile switch (the list refetches).
- `WidgetMirrorClient` (`@DependencyClient`):
  - `write(WidgetSessionSnapshot)`, `clear()`, `reloadTimelines()`.
  - `liveValue` writes atomically to `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
    and calls `WidgetCenter.shared.reloadTimelines(ofKind:)` (`#if canImport(WidgetKit)` + iOS
    guard; non-iOS `liveValue = testValue`).
  - `testValue` unimplemented-by-default via the macro.
- `LiveActivityClient` (`@DependencyClient`):
  - `areActivitiesEnabled() -> Bool`
  - `start(AgentActivityContent, staleDate: Date) async throws -> String`
  - `update(id: String, AgentActivityContent, staleDate: Date) async`
  - `end(id: String, final: AgentActivityContent?, dismissAfter: Date?) async`
  - `endAll() async`
  - The live value lives in HermesKit under `#if os(iOS) && canImport(ActivityKit)` (it uses
    HermesWidgetKit's `HermesActivityAttributes`); non-iOS `liveValue = testValue`, like the
    other iOS-only clients.
- `PreferencesClient`: `liveActivityEnabled` (default true) and `liveActivityShowsTitles`
  (default true), with load/save and inclusion in the logout clear.
- `AppFeature` additions:
  - `State.agentStatus` (computed): `nil` when `home == nil` or `home.statusSessions == nil`.
  - `State.liveActivityID: String?`, `State.liveActivityEnabled`, `State.liveActivityShowsTitles`
    (seeded from prefs in `makeHomeState` / landing).
  - `.onChange(of: \.agentStatus)` → `.send(.agentStatusChanged)` → `syncSurfaces(&state, freshUntil:)`:
    a `.run` with `cancellable(id: CancelID.surfacesSync, cancelInFlight: true)` that sleeps 1 s on
    `continuousClock`, then writes the mirror and reloads timelines.
  - The activity decision happens in the reducer so the state change is testable:
    - count > 0 and `liveActivityID == nil`, enabled, not backgrounded → `start`, then
      `.liveActivityStarted(id)`;
    - count > 0 and an id exists → `update`;
    - count == 0 and an id exists → `end` with final `.done` content, `dismissAfter = now + 5 min`,
      and `liveActivityID = nil`;
    - start failure → `debugLog` only (`.liveActivityStartFailed`), no banner.
  - The background edge (`.background` case) additionally re-sends the sync with
    `freshUntil = now + (chat?.isRunning == true ? 30 : 0) + 10` and updates the activity's
    `staleDate`. `.foreground` re-sends with `now + 8h`.
  - Live Activity toggle off → `endAll` + `liveActivityID = nil`. Show-titles toggle changes the
    projection, so the activity updates through the edge.
  - Every logout site that clears `pendingPushTap` also: `liveActivity.endAll()`,
    `widgetMirror.clear()` + reload, `liveActivityID = nil`. The prefs reset comes from the
    existing clear-all.

### Routing
- `.openSession(id:profile:)` in `launchIntentReceived`:
  - With `home != nil`, dismiss list presentations, then run the same routing body as a push tap
    (extract the non-badge part of `reducePushTapped` into `reduceOpenSessionRouting(id:profile:)`
    shared by both; push taps keep their badge and approval-hint bookkeeping around it).
  - With `home == nil`, stash with `pendingLaunchIntentServerURL` (stored URL at stash time).
    `landOnHome` drops it on a different server (same guard as `pendingPushTapServerURL`).
  - If `profile` differs from the selected one, the open uses the row's profile for
    `session.resume` (as a push tap does with the placeholder session); it does not change the
    selected profile.
- `.newChatWithCamera` / `.newChatWithPhotos` → `reduceCreateSession(…, launchAction: .camera/.photos)`.
  The `startsDictation:` parameter becomes `launchAction: LaunchAction?`.
- `HermesMobileApp`: `.onOpenURL { url in if let intent = WidgetDeepLink.intent(from: url) { LaunchIntentBridge.shared.received(intent) } }`.
  The `hermes-file://` scheme stays separate (in-app only).

### Extension (`HermesWidgets/`)
- `Sources/HermesWidgetsBundle.swift` (`@main WidgetBundle`): `QuickActionsWidget`,
  `SessionsWidget`, `NewChatAccessoryWidget`, `NewChatControl`, `DictateControl`,
  `AgentsLiveActivity`.
- `Sources/OpenHermesURLIntent.swift`: an `AppIntent` with an `url` parameter
  (`@Parameter var target: String`) whose `perform()` returns `.result(opensIntent: OpenURLIntent(url))`.
- `Sources/SessionsTimelineProvider.swift` reads the mirror (`WidgetSessionSnapshot.decodeLeniently`)
  and returns `[entry(now), entry(freshUntil, outdated)]` with policy `.never`. Signed out or
  missing file → signed-out entry.
- `Sources/Views/*.swift`: pure SwiftUI views taking plain values (no `TimelineEntry` /
  `ActivityViewContext` types), so `HermesMobileTests` can compile and snapshot them.
- Info.plist: `NSExtension` → `NSExtensionPointIdentifier = com.apple.widgetkit-extension`.
- Entitlements: the App Group. The app adds the same App Group, `NSSupportsLiveActivities = true`
  and `CFBundleURLTypes` (`hermesmobile`).

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, Tuist config, docs in this repo.
- **Post-Completion** (no checkboxes): Developer-portal registration (extension bundle id, App
  Group, profiles), on-device checks (widget gallery, `OpenURLIntent` from the small widget and the
  controls, the Live Activity on the lock screen and in the Dynamic Island), the TestFlight build.

## Implementation Steps

### Task 1: Add the `HermesWidgetKit` library product and move `SessionStatus` / `LaunchIntent` into it

**Files:**
- Modify: `HermesKit/Package.swift`
- Create: `HermesKit/Sources/HermesWidgetKit/SessionStatus.swift`
- Create: `HermesKit/Sources/HermesWidgetKit/LaunchIntent.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/SessionCardContent.swift` (remove the moved enum)
- Delete: `HermesKit/Sources/HermesKit/Models/LaunchIntent.swift`
- Create: `HermesKit/Sources/HermesKit/HermesWidgetKitExports.swift` (`@_exported import HermesWidgetKit`)
- Create: `HermesKit/Tests/HermesWidgetKitTests/LaunchIntentTests.swift`

- [x] add `.library(name: "HermesWidgetKit", targets: ["HermesWidgetKit"])`, a Foundation-only `HermesWidgetKit` target, make `HermesKit` depend on it, and add a `HermesWidgetKitTests` test target
- [x] move `SessionStatus` (add `Codable`) and `LaunchIntent` (with its quick-action literals, unchanged) into HermesWidgetKit as `public`; re-export from HermesKit so no call site changes
- [x] confirm the app still builds (`tuist generate --no-open && make build`)
- [x] write tests for the moved `LaunchIntent` quick-action mapping (round-trip `shortcutItemType`, unknown → nil) in `HermesWidgetKitTests` (➕ plus a `SessionStatus` Codable raw-value test; the existing HermesKit mapping tests stay untouched)
- [x] run tests (`swift test --package-path HermesKit`) - must pass before task 2

### Task 2: Add the widget data types, deep links and staleness rules to HermesWidgetKit

**Files:**
- Create: `HermesKit/Sources/HermesWidgetKit/LaunchAction.swift`
- Create: `HermesKit/Sources/HermesWidgetKit/AppGroup.swift`
- Create: `HermesKit/Sources/HermesWidgetKit/WidgetDeepLink.swift`
- Create: `HermesKit/Sources/HermesWidgetKit/WidgetSessionSnapshot.swift`
- Create: `HermesKit/Sources/HermesWidgetKit/WidgetStaleness.swift`
- Create: `HermesKit/Sources/HermesWidgetKit/AgentActivityContent.swift`
- Modify: `HermesKit/Sources/HermesWidgetKit/LaunchIntent.swift` (new cases)
- Create: `HermesKit/Tests/HermesWidgetKitTests/WidgetDeepLinkTests.swift`
- Create: `HermesKit/Tests/HermesWidgetKitTests/WidgetSnapshotTests.swift`

- [x] add `LaunchAction`, the new `LaunchIntent` cases (`newChatWithCamera`, `newChatWithPhotos`, `openSession(id:profile:)`) and a `launchAction` accessor (`.newChatWithDictation` → `.dictation`, …); keep `quickActions` = `[.newChat, .newChatWithDictation]` (➕ the widget-only cases get distinct `shortcutItemType` literals that `init(shortcutItemType:)` rejects, plus titles / symbols for the controls)
- [x] implement `WidgetDeepLink.url(for:)` / `intent(from:)` per Technical Details (percent-encode the id and profile; reject other schemes, hosts, an empty id and unknown `with=` values)
- [x] implement `WidgetSessionSnapshot` (versioned, `decodeLeniently` returns nil on corrupt data or a newer version), `WidgetStaleness`, `AgentActivityContent`, `AppGroup` (➕ `WidgetSessionSnapshot.signedOut`, `maxRows` cap in `init`, `AppGroup.snapshotFileURL()` shared by the app mirror and the provider)
- [x] fix the exhaustive `switch`es over `LaunchIntent` in HermesKit / the app so they compile (the new cases route in Task 3; until then they map like `.newChat` with a `// Task 3` note) (➕ no exhaustive switch outside `LaunchIntent` existed: `AppFeature` compares `== .newChatWithDictation`, so only the two `// Task 3` notes were added)
- [x] write tests: deep-link round-trip for every case, unknown and malformed URLs → nil, a profile with spaces / `default`
- [x] write tests: snapshot encode/decode, corrupt bytes → nil, `version` > current → nil, staleness boundaries (`freshUntil` exactly, before, after) and the row-glyph mapping
- [x] run tests - must pass before task 3

### Task 3: Route deep links and `openSession` through `AppFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesMobile/Sources/HermesMobileApp.swift` (or wherever the `WindowGroup` lives) — `.onOpenURL`
- Modify: `Project.swift` (`CFBundleURLTypes` with the `hermesmobile` scheme)
- Create: `HermesKit/Tests/HermesKitTests/WidgetLaunchRoutingTests.swift`

- [x] extract the session-opening body of `reducePushTapped` (in-place / detached / replace, never stack) into one helper shared by push taps and `.openSession`; push taps keep their badge and approval-hint bookkeeping around it; no behaviour change for push taps (existing push-routing tests stay green unchanged) (➕ `reduceOpenSessionRouting` + the list delegate's body extracted into `reduceOpenSession(session:profileName:)` so a cross-profile row can resume under its own profile)
- [x] handle `.openSession(id:profile:)` in `launchIntentReceived`: with `home` set → `dismissPresentations()` + the shared helper (no approval hint); with `home == nil` → stash with `pendingLaunchIntentServerURL`; `landOnHome` drops a stashed `openSession` whose server differs (same guard as push taps); every logout site clears the new field
- [x] route `.newChatWithCamera` / `.newChatWithPhotos` to `reduceCreateSession` (the action itself lands in Task 4; here pass it through the new `launchAction:` parameter that replaces `startsDictation:`) (➕ `landOnHome(replaysDictation:)` renamed `replaysLaunchAction:`)
- [x] register the URL scheme in `Project.swift`, add `.onOpenURL` in the app that maps through `WidgetDeepLink.intent(from:)` to `LaunchIntentBridge.shared.received(_:)` (➕ the mapping lives in `LaunchIntentBridge.received(url:)` so it is unit-tested; the app calls that)
- [x] write `TestStore` tests: `openSession` in place (slot already on screen), a detached compact slot, a different session replacing the slot (compact and regular), the stash before home and its replay, a cross-server stash dropped, last-wins vs a push tap, cleared on logout (➕ cross-profile open, profiles-API-less agent, presentations dismissed, camera / photos seat a new chat, regular foreign drop seats the detail)
- [x] write tests: an unknown deep link is ignored (`intent(from:)` nil means no action)
- [x] run tests and `make build` - must pass before task 4

### Task 4: Generalize `pendingDictation` into a one-shot `pendingLaunchAction`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: the existing dictation tests (`grep -rl pendingDictation HermesKit/Tests`)

- [x] replace `pendingDictation: Bool` with `pendingLaunchAction: LaunchAction?`; `consumePendingDictation` → `consumePendingLaunchAction`: always clears; `.dictation` → existing `startVoiceRecording` only from `recording == .idle`; `.camera` → the `.attachCameraTapped` effect; `.photos` → the `.attachPhotosTapped` effect (share the effect builders, don't `.send` the tap actions) (➕ one `runLaunchAction` shared by the consume and `.startLaunchAction`; `pickPhotos()` / `capturePhoto()` effect builders shared with the composer buttons)
- [x] replace `.startDictation` with `.startLaunchAction(LaunchAction)` for the reused-seat path in `reduceCreateSession`
- [x] keep the #93 rules: only the launch auto-connect landing replays the action (other landings replay a plain new chat); behind `reauth` the action is dropped (unchanged routing from Task 3; now covered for camera / photos too)
- [x] update and rename the existing dictation tests; add tests for camera and photos: consumed once at first `.task`, not re-fired on re-appearance, the reused-seat path, dropped on a manual-login landing, dropped behind re-auth (➕ cancelled picker stages nothing, auto-connect landing keeps the action)
- [x] run tests - must pass before task 5

### Task 5: Scaffold the `HermesWidgets` extension target with the quick-actions widget, accessory and controls

**Files:**
- Modify: `Project.swift` (new `.appExtension` target, App Group entitlement on both targets, app depends on the extension, `NSSupportsLiveActivities`, test target compiles `HermesWidgets/Sources/Views/**`)
- Create: `HermesWidgets/Sources/HermesWidgetsBundle.swift`
- Create: `HermesWidgets/Sources/OpenHermesURLIntent.swift`
- Create: `HermesWidgets/Sources/QuickActionsWidget.swift`
- Create: `HermesWidgets/Sources/NewChatAccessoryWidget.swift`
- Create: `HermesWidgets/Sources/HermesControls.swift`
- Create: `HermesWidgets/Sources/Views/QuickActionsView.swift`
- Create: `HermesWidgets/Sources/Views/HermesGlyph.swift`
- Create: `HermesWidgets/Resources/Assets.xcassets` (monochrome Hermes glyph as a template image; reuse the existing artwork in `HermesMobile/Resources`)
- Create: `HermesMobileTests/WidgetSnapshotTests.swift`

- [ ] add the `HermesWidgets` target (`me.honcharenko.HermesMobile.Widgets`, iOS 18, `NSExtension` widgetkit point, links only `HermesWidgetKit`, same `DEVELOPMENT_TEAM` / version settings as the app) and embed it in the app; App Group `group.me.honcharenko.HermesMobile` entitlement on both targets (keep `aps-environment` on the app); `NSSupportsLiveActivities = true` on the app
- [ ] implement `OpenHermesURLIntent` returning `.result(opensIntent: OpenURLIntent(url))`; the quick-actions widget: small = "Ask Hermes" pill (new chat) + Camera + Mic buttons via `Button(intent:)`; medium = pill + Camera + Photos + Mic via `Link`; `.widgetAccentable()` glyphs; `containerBackground`
- [ ] implement `NewChatAccessoryWidget` (`accessoryCircular`, `widgetURL` new chat) and the two `ControlWidget`s (titles and symbols from `LaunchIntent.shortcutTitle` / `shortcutSymbolName`)
- [ ] `tuist generate --no-open && make build` - app plus extension build for the Simulator
- [ ] write snapshot tests for `QuickActionsView` small and medium in light / dark (and tinted if `widgetRenderingMode` can be injected; otherwise note it) at the widget family sizes; run `make snapshot` twice
- [ ] run tests - must pass before task 6

### Task 6: Add `statusSessions` and the pure `AgentStatusProjection`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Create: `HermesKit/Sources/HermesKit/Models/AgentStatusProjection.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift` (`State.agentStatus`, show-titles state)
- Create: `HermesKit/Tests/HermesKitTests/AgentStatusProjectionTests.swift`
- Modify: the list tests (`statusSessions` assertions)

- [ ] add `statusSessions` to `SessionListFeature.State` per Technical Details (set on an unfiltered success, untouched by search, patched by `runningChanged`, reset on a profile switch)
- [ ] implement `AgentStatusProjection.make(...)` and `activityContent`; add `AppFeature.State.agentStatus`
- [ ] write projection tests: nil before the first fetch, cron excluded, sort order, cap at 5, headline choice, slot override, count, title omitted when show-titles is off, nil activity content at zero
- [ ] write list `TestStore` tests: an unfiltered fetch sets `statusSessions`; a search fetch leaves it; `runningChanged` patches it; a profile switch resets it
- [ ] run tests - must pass before task 7

### Task 7: Write the App Group mirror from the single `agentStatus` edge

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/WidgetMirrorClient.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/WidgetSurfacesTests.swift`

- [ ] implement `WidgetMirrorClient` (live: atomic write into the App Group container + `WidgetCenter.reloadTimelines(ofKind:)`, iOS-guarded; test: unimplemented)
- [ ] add `.onChange(of: \.agentStatus)` → a debounced `cancelInFlight` sync effect (1 s, `continuousClock`) that writes `WidgetSessionSnapshot(freshUntil: now + 8h)`; `nil` → no write
- [ ] on `.background` re-sync with `freshUntil = now + (running slot ? 30 : 0) + 10 s`; on `.foreground` re-sync with `+ 8h`
- [ ] on every logout site: `widgetMirror.clear()` + reload (a signed-out snapshot, `isSignedIn = false`)
- [ ] write `TestStore` tests with `TestClock`: a change writes once after the debounce; a burst coalesces; nil writes nothing; the background `freshUntil` with and without a running slot; the foreground restore; logout clears
- [ ] run tests - must pass before task 8

### Task 8: Build the sessions widget and its timeline provider

**Files:**
- Create: `HermesWidgets/Sources/SessionsWidget.swift`
- Create: `HermesWidgets/Sources/SessionsTimelineProvider.swift`
- Create: `HermesWidgets/Sources/Views/SessionsWidgetView.swift`
- Create: `HermesWidgets/Sources/Views/SessionRowView.swift`
- Modify: `HermesWidgets/Sources/HermesWidgetsBundle.swift`
- Modify: `HermesMobileTests/WidgetSnapshotTests.swift`

- [ ] provider: read the mirror from the App Group container, `decodeLeniently`; entries = fresh now + outdated at `freshUntil` (when it is in the future), policy `.never`; placeholder / gallery snapshot use demo rows
- [ ] views: medium = "Hermes" header + the headline row; large = header + up to 5 rows; row = title, workspace (folder icon) + `Text(updatedAt, style: .relative)`, trailing glyph (working = static spinner-style symbol in blue, needs input = `questionmark.circle` in yellow, outdated = `clock` in secondary); `Link` per row to `WidgetDeepLink.url(for: .openSession(...))`; empty states (signed out → "Sign in to Hermes"; no sessions → "No sessions yet" + New chat link)
- [ ] `tuist generate --no-open && make build`
- [ ] write snapshot tests: medium and large in light / dark, the outdated entry, signed out, empty; pinned dates for the relative text (pass a fixed `now` into the view, render the relative text deterministically); `make snapshot` twice
- [ ] run tests - must pass before task 9

### Task 9: Drive the aggregate Live Activity from `AppFeature`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/LiveActivityClient.swift` (interface, test value, iOS-guarded ActivityKit live value)
- Create: `HermesKit/Sources/HermesWidgetKit/HermesActivityAttributes.swift` (`#if os(iOS) && canImport(ActivityKit)`)
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift` (`liveActivityEnabled`, `liveActivityShowsTitles`, logout clear)
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/WidgetSurfacesTests.swift`

- [ ] implement `HermesActivityAttributes` and the client (live: `Activity.request(attributes:content:pushType: nil)`, `update`, `end(_:dismissalPolicy:)`, `Activity<HermesActivityAttributes>.activities` for `endAll`, `ActivityAuthorizationInfo().areActivitiesEnabled`)
- [ ] add the two prefs (default true) and include them in the logout clear; seed `AppFeature` state from prefs at landing
- [ ] in the sync effect, decide start / update / end per Technical Details (start only while not backgrounded and enabled; `liveActivityStarted(id)` stores the id; start failure → debug log only; end sends final `.done` content and dismisses after 5 min; the activity `staleDate = freshUntil`); `nil` projection → hold
- [ ] the Live Activity toggle off → `endAll` + clear the id; every logout site → `endAll` + clear the id
- [ ] write `TestStore` tests: start on the first active count, update on change, end at zero with `.done`, no start while backgrounded, no start when disabled, the start-failure path, the background edge updates `staleDate`, toggle off ends, show-titles off removes the title, logout ends
- [ ] run tests - must pass before task 10

### Task 10: Add the Live Activity UI and the Settings toggles

**Files:**
- Create: `HermesWidgets/Sources/AgentsLiveActivity.swift` (`ActivityConfiguration` + Dynamic Island)
- Create: `HermesWidgets/Sources/Views/AgentsActivityView.swift` (plain view: content + `isStale`)
- Modify: `HermesWidgets/Sources/HermesWidgetsBundle.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift` (two toggles, `areActivitiesEnabled` footer flag, delegate to the parent)
- Modify: `HermesMobile/Sources/Features/Settings/SettingsView.swift` (Notifications group rows)
- Modify: `HermesKit/Tests/HermesKitTests/SettingsFeatureTests.swift` (or the existing settings test file)
- Modify: `HermesMobileTests/WidgetSnapshotTests.swift`, the Settings snapshot tests

- [ ] lock-screen view (T3 layout): "Hermes" + "N active agent(s)" header; headline title (truncated) or the workspace when the title is omitted; secondary workspace; trailing status label (Working blue / Needs input yellow / Done green / Outdated secondary when `isStale`); `widgetURL` opens the headline session
- [ ] Dynamic Island: compact leading glyph, compact trailing count (or `?` when needs input), minimal glyph, expanded = the lock-screen layout
- [ ] Settings: "Live Activity" toggle + nested "Show session titles" (hidden when off) in the Notifications group; footer copy per the brief; when iOS has activities disabled the footer says so; toggles persist via `PreferencesClient` and notify `AppFeature` (endAll on off, projection update on show-titles)
- [ ] `tuist generate --no-open && make build`
- [ ] write `TestStore` tests for the Settings toggles (persist, delegate) and snapshot tests for the activity view (working, needs input, done, outdated, title omitted; expanded) and the Settings rows (on, off, disabled-by-iOS footer); `make snapshot` twice
- [ ] run tests - must pass before task 11

### Task 11: Verify acceptance criteria
- [ ] verify all Overview surfaces exist and route correctly (deep-link table covered by tests)
- [ ] verify the thin-client rule: `HermesWidgets` links only `HermesWidgetKit` and has no network or Keychain code (`grep` the target)
- [ ] verify the #93 behaviour is unchanged (existing intent / quick-action / push-routing tests pass untouched apart from the `pendingDictation` rename)
- [ ] run the full suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run `make snapshot` (all green) and `make build`

### Task 12: [Final] Update documentation
- [ ] create `docs/features/widgets.md` (surfaces, URL table, `HermesWidgetKit` packaging rule, projection and edge, staleness, Live Activity lifecycle and toggles, the accepted residuals: foreground crash and the foreground-only start)
- [ ] update `docs/features/app-intents.md` (new `LaunchIntent` cases, the URL path, `pendingLaunchAction`), `docs/features/settings.md` (the new rows), `docs/development.md` (App Group, extension bundle id, profiles for both ids in the export recipe)
- [ ] add one short `CLAUDE.md` bullet under Push notifications / App Intents pointing at `docs/features/widgets.md` (keep CLAUDE.md about 200 lines)
- [ ] update README feature list if it enumerates surfaces
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Developer portal / signing**:
- Register the bundle id `me.honcharenko.HermesMobile.Widgets` and the App Group
  `group.me.honcharenko.HermesMobile`, and enable the App Group capability on both bundle ids.
- Create App Store provisioning profiles for both ids and install them; the export options list
  both profiles.

**Manual verification (device)**:
- The widget gallery shows all four widget kinds.
- Every tap opens the right thing, cold and warm.
- **Spike**: `OpenURLIntent` from the small widget and the Control Center controls opens the app on
  iOS 18. If not, fall back to a single `widgetURL` (new chat) for the small widget and
  `openAppWhenRun` intents compiled into both targets for the controls.
- Live Activity:
  - Appears when a turn runs and the app is backgrounded.
  - Shows "Outdated" about 40 s after backgrounding a running slot.
  - Ends with "Done" when the turn finishes in the foreground.
  - The toggles behave as specified.
- The tinted and clear Home Screen modes.

**Distribution**:
- Internal TestFlight build (bump `CURRENT_PROJECT_VERSION`).
