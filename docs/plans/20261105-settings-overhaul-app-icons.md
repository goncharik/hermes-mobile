# Settings overhaul + app icon picker (#137, #135)

## Overview

Restructure the Settings sheet from the MVP grab bag into six groups (Server, App,
Notifications, Feedback, About, Sign out) and add a user-selectable app icon with six
choices. Gives the App Store build a version row, feedback links, a privacy policy, and the
icon choice TestFlight users asked for.

Out of scope (split out during brainstorm): model defaults for new sessions (#140) and the
StoreKit tip jar (#141). Also deliberately out: a read-aloud toggle in Settings (the chat
pill stays the single source), a TestFlight-only feedback row, haptics, an email row, and
iOS 18 dark/tinted icon variants (#83).

## Context (from discovery)

- `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift` — flat reducer: token
  re-paste, reconnect, debug-log stream, notifications + plugin update, swipe default,
  `clearTokenTapped` (logout clear list).
- `HermesMobile/Sources/Features/Settings/SettingsView.swift` — one `Form`, a plain
  `NavigationLink` to `ConnectionDebugView` (not state-driven).
- `HermesMobile/Sources/Features/SessionListView.swift:142` — presents Settings in a sheet
  wrapped in a bare `NavigationStack {}`; `SessionListFeature.settingsButtonTapped`
  (~line 1206) seeds connection, push availability, swipe default, delete capability.
- Stack-navigation precedent: `AppFeature.path: StackState<ChatScreen.State>` +
  `AppView.swift:55` `NavigationStack(path: $store.scope(...))`.
- `AuthSession` (`Models/AuthSession.swift`): `.token(String)`, `.cookie(CookieSession)`
  with `username`/`provider`, `.bearer(BearerSession)` with `provider` + identity.
- `HermesRESTClient.status(baseURL)` already decodes `/api/status` into `ServerStatus`
  with a `version: String?`.
- `PasteboardClient.copy(text)`, `DebugLogClient.stream() -> AsyncStream<[GatewayLogEntry]>`.
- Icons: `AppIcon` (gold HA, App Store) and `AppIconDev` (blue blueprint HA, Debug + every
  TestFlight) in `HermesMobile/Resources/Assets.xcassets`; primary chosen per build via
  `ASSETCATALOG_COMPILER_APPICON_NAME` in `Project.swift` (lines ~92–110). No alternates yet.
- New icon sources (1254×1254 PNG, no alpha) at
  `/Users/eugene/.t3/userdata/attachments/62307417-2ed1-41c0-9bc5-fa87acdcf5d4-<id>.png`:
  - `2d3c3195-a277-4e0b-ac83-fa58c94ee8a2` → `AppIconHermes` ("Hermes")
  - `9820d562-7dec-415b-942b-0333f08f37f0` → `AppIconHermesBlueprint` ("Hermes Blueprint")
  - `0c21d3f7-26e4-486c-acf8-769ddd8829a2` → `AppIconHermesClassic` ("Hermes Classic")
  - `0c1dfaef-5e45-4aad-aa90-12b1d742fc4f` → `AppIconHermesClassicBlueprint` ("Hermes Classic Blueprint")
- Runtime SPM deps for Acknowledgements: swift-composable-architecture,
  swift-dependencies, GRDB.swift.
- Snapshot tests: `HermesMobileTests/SettingsSnapshotTests.swift` wraps `SettingsView` in a
  `NavigationStack` and uses `.ignoring(\.task)`; that wrapper goes away once the view owns
  its stack.

## Development Approach

- **testing approach**: Regular (code first, then tests)
- complete each task fully before moving to the next
- make small, focused changes; commit at each task completion (capitalized verb, no
  conventional-commit prefix)
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - unit tests for new and modified functions; success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- HermesKit tests: `script -q /dev/null swift test --package-path HermesKit`
- Snapshot tests: `make snapshot` (a NEW snapshot test needs two runs: first records and
  fails by design, second asserts clean). A view change re-records its own baselines.
- `git checkout -- HermesKit/Package.resolved` if a local resolve dirties it; never commit it.
- New source files in the app target need `tuist generate` before an `xcodebuild` build.

## Testing Strategy

- **unit tests**: `TestStore` + `@Dependency` overrides + `TestClock` for every reducer
  change; plain XCTest for pure helpers. Required for every task.
- **snapshot tests**: per-section light/dark images in `HermesMobileTests`; the picker grid
  is scrollable, so pin width AND height.
- **no e2e suite** in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview

- **Shape**: one `Form` in the Settings sheet; three rows push sub-screens through a TCA
  stack. No hub-and-spoke, no child reducers for inline groups.
- **Navigation**: top-level `@Reducer enum SettingsPath` (not nested in `SettingsFeature`)
  with `appIcon(AppIconPickerFeature)`, `diagnostics(DiagnosticsFeature)`,
  `acknowledgements(AcknowledgementsFeature)`. `SettingsFeature.State.path:
  StackState<SettingsPath.State>`, `Action.path(StackActionOf<SettingsPath>)`, body ends
  with `.forEach(\.path, action: \.path) { SettingsPath.body }`. Rows push by appending in
  the reducer so a push is a `TestStore` assertion. `SettingsView` owns
  `NavigationStack(path: $store.scope(state: \.path, action: \.path))` with the `Form` as
  root and `switch pathStore.case` as destination; the session list's sheet drops its bare
  `NavigationStack` wrapper.
- **App icon**: `AppIconClient` (`@DependencyClient`) wraps `UIApplication.shared`
  alternate-icon APIs under `#if canImport(UIKit)`; the catalog is derived from the bundle's
  `CFBundleIcons` / `CFBundleAlternateIcons` by a pure parser, ordered by a static
  `AppIconOption` table (name → label → preview asset). All six sets are listed as
  alternates in `Project.swift` (primary included on purpose, since the primary differs
  per build); the parser filters the primary out. iOS persists the choice; logout never
  touches it.
- **Logic in HermesKit, views thin**: bundle facts come from `BundleInfoClient`; feedback
  URLs from the pure `FeedbackLinks`; the auth row label from `AuthSession.settingsLabel`;
  the diagnostics text from the pure `DiagnosticsReport.render`.
- **Rate**: SwiftUI `requestReview` stays in the view (environment action, like the existing
  `openSettingsURLString` link); the write-review URL fallback is gated on
  `AppStoreIdentity.appID`, a single constant that starts `nil`.
- **Sign out**: `clearTokenTapped` keeps its name and clear list; only the copy changes.

## Technical Details

**Groups and rows (top to bottom):**

1. Server — URL; Auth (`"Token"` | `"Password · <username>"` | `"<Provider> · <username>"`);
   Profile (only when `profileName != nil`); Agent (version from `/api/status`, row hidden
   until loaded or on failure); token `SecureField` + "Save token" ONLY when
   `showsTokenField` (token regime); Reconnect.
2. App — "App Icon" row (value = current icon label) → pushes `.appIcon`; "Default swipe
   action" picker (gated on `deleteSupported`, unchanged).
3. Notifications — existing block, untouched.
4. Feedback — "Report a bug", "Request a feature" (GitHub new-issue URLs with prefilled
   title and body: app version, build, iOS version, device model), "Rate Hermes Mobile"
   (`requestReview`; opens the write-review URL only when `AppStoreIdentity.appID` is set),
   "All issues on GitHub".
5. About — "Version <marketing> (<build>)"; GitHub repository; Hermes Agent; Privacy policy
   (`PRIVACY.md` on GitHub); Acknowledgements → pushes `.acknowledgements`; Diagnostics →
   pushes `.diagnostics` (no entry count on the row).
6. Sign out — destructive button, same `clearTokenTapped` action, reworded footer.

**New HermesKit types:**

- `BundleInfo { marketingVersion, build, osVersion, deviceModel }` +
  `BundleInfoClient.info() -> BundleInfo` (testValue: "1.0", "79", "18.0", "iPhone").
- `FeedbackLinks`: `reportBug(_: BundleInfo) -> URL`, `requestFeature(_: BundleInfo) -> URL`,
  `allIssues`, `repository`, `hermesAgent`, `privacyPolicy`, `writeReview(appID:) -> URL`.
  Repo: `https://github.com/goncharik/hermes-mobile`. `AppStoreIdentity.appID: String? = nil`.
- `AuthSession.settingsLabel: String`, `AuthSession.isToken: Bool`.
- `AppIconOption { name, label, previewAsset }` static table (six entries, display order:
  Gold, Blueprint, Hermes, Hermes Blueprint, Hermes Classic, Hermes Classic Blueprint);
  `AppIconCatalog { primary: AppIconOption?, alternates: [AppIconOption] }` with
  `static func parse(infoDictionary: [String: Any]) -> AppIconCatalog` (reads
  `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName` and `CFBundleAlternateIcons` keys;
  drops names not in the table; filters the primary out of alternates).
- `AppIconClient { catalog() -> AppIconCatalog, current() -> String?, set(String?) async throws }`.
- `DiagnosticsReport.render(bundleInfo:serverURL:authLabel:agentVersion:log:) -> String` —
  never includes the token, cookies, or bearer tokens.
- Reducers: `AppIconPickerFeature`, `DiagnosticsFeature`, `AcknowledgementsFeature`
  (`EmptyReducer`), `SettingsPath`.

**SettingsFeature state additions:** `path`, `authSession: AuthSession`, `profileName:
String?`, `agentVersion: String?`, `bundleInfo: BundleInfo?`, `selectedAppIcon: String?`
(nil = primary) + `selectedAppIconLabel` (derived via the table). `log` and the
`CancelID.logStream` subscription move to `DiagnosticsFeature`. New actions:
`appIconRowTapped`, `diagnosticsRowTapped`, `acknowledgementsRowTapped`,
`bundleInfoLoaded`, `agentStatusLoaded(String?)`, `currentAppIconLoaded(String?)`,
`path(StackActionOf<SettingsPath>)`.

**Seeding:** `SessionListFeature.settingsButtonTapped` passes `state.scopedProfileName` and
the connection's `AuthSession` in addition to today's inputs.

**Assets / build:** four new `.appiconset`s (1024×1024 via `sips -Z 1024`, no alpha), six
`AppIconPreview-<SetName>.imageset`s at 180px; `Project.swift` base settings gain
`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "AppIcon AppIconDev AppIconHermes
AppIconHermesBlueprint AppIconHermesClassic AppIconHermesClassicBlueprint"` and
`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`. The per-configuration primary rule
and the TestFlight command-line override stay as they are.

## What Goes Where

- **Implementation Steps** (`[ ]`): code, assets, tests, docs in this repo.
- **Post-Completion**: the TestFlight device verification and the App Store id fill-in.

## Implementation Steps

### Task 1: App icon catalog model, parser, and client

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/AppIconCatalog.swift`
- Create: `HermesKit/Sources/HermesKit/Clients/AppIconClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/AppIconCatalogTests.swift`

- [x] add `AppIconOption` (name, label, previewAsset) with the static six-entry table in display order
- [x] add `AppIconCatalog` + pure `parse(infoDictionary:)` outside any UIKit guard (primary from `CFBundlePrimaryIcon.CFBundleIconName`, alternates from `CFBundleAlternateIcons` keys, unknown names dropped, primary filtered out, order from the table); `label(for name: String?)` helper (nil → primary's label)
- [x] add `AppIconClient` (`@DependencyClient`): `catalog`, `current`, `set`; `liveValue` under `#if canImport(UIKit)` over `Bundle.main.infoDictionary` + `UIApplication.shared.alternateIconName` / `setAlternateIconName` (main-actor hop inside the client); non-UIKit `liveValue = testValue`; `testValue` in-memory with the full six-icon catalog, primary `AppIcon`
- [x] register `DependencyValues.appIcon`
- [x] write tests: parse a fixture plist dict (primary filtered, unknown dropped, table order kept); empty/malformed dict → empty catalog; `label(for:)` nil and unknown names
- [x] run tests - must pass before next task

### Task 2: Icon assets and build wiring

**Files:**
- Create: `HermesMobile/Resources/Assets.xcassets/AppIconHermes.appiconset/{Contents.json,icon-1024.png}` (and the three other sets)
- Create: `HermesMobile/Resources/Assets.xcassets/AppIconPreview-{AppIcon,AppIconDev,AppIconHermes,AppIconHermesBlueprint,AppIconHermesClassic,AppIconHermesClassicBlueprint}.imageset/`
- Modify: `Project.swift`

- [x] generate the four 1024×1024 icons with `sips -Z 1024` from the attachment sources (verify `hasAlpha: no`, 1024×1024 with `sips -g`), `Contents.json` copied from `AppIcon.appiconset`
- [x] generate six 180px previews (`sips -Z 180`) as plain image sets, single-scale, named `AppIconPreview-<SetName>`
- [x] add `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` (all six) and `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES` to the base settings in `Project.swift`, with a comment explaining why the primary is listed too
- [x] `tuist generate` and build the Debug app; dump the built `Info.plist` and confirm `CFBundleAlternateIcons` lists the six names and `CFBundlePrimaryIcon` is `AppIconDev`
  - ⚠️ actual: `CFBundlePrimaryIcon` = `AppIconDev`, but actool OMITS the primary from `CFBundleAlternateIcons` (five names: AppIcon + the four Hermes sets). Harmless — the parser filters the primary anyway; all six remain reachable (primary via `set(nil)`). Pinned by `AppIconCatalogTests.actoolOutputWithoutPrimaryAlternate`.
- [x] write a HermesKit test that the `AppIconOption` table names match the six set names used in `Project.swift` (literal list in the test, documents the coupling)
- [x] run tests - must pass before next task

### Task 3: BundleInfoClient and FeedbackLinks

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/BundleInfoClient.swift`
- Create: `HermesKit/Sources/HermesKit/Models/FeedbackLinks.swift`
- Create: `HermesKit/Tests/HermesKitTests/FeedbackLinksTests.swift`

- [x] add `BundleInfo` + `BundleInfoClient.info()`; `liveValue` reads `CFBundleShortVersionString` / `CFBundleVersion`, `UIDevice.current.systemVersion`, and the `utsname` machine identifier under the UIKit guard; `testValue` fixed strings; register `DependencyValues.bundleInfo`
  - ⚠️ actual: the OS version comes from `ProcessInfo.operatingSystemVersion` (formatted like `systemVersion`), not the main-actor `UIDevice`, so `info()` stays synchronous and the live value needs no UIKit guard; a simulator reports `SIMULATOR_MODEL_IDENTIFIER` instead of the host `arm64`.
- [x] add `AppStoreIdentity.appID: String? = nil` and `FeedbackLinks` (`reportBug`, `requestFeature`, `allIssues`, `repository`, `hermesAgent`, `privacyPolicy`, `writeReview(appID:)`); new-issue URLs percent-encode a title prefix and a body block with version, build, iOS, device
- [x] write tests: `reportBug` / `requestFeature` exact URL strings for the fixed `BundleInfo`; body contains all four facts; constants are the expected URLs; `writeReview` format
- [x] run tests - must pass before next task

### Task 4: Auth row label and diagnostics report (pure)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/AuthSession.swift`
- Create: `HermesKit/Sources/HermesKit/Models/DiagnosticsReport.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AuthSessionTests.swift` (create if absent)
- Create: `HermesKit/Tests/HermesKitTests/DiagnosticsReportTests.swift`

- [x] add `AuthSession.settingsLabel` (token → "Token"; cookie → "Password · <username>"; bearer → "<provider> · <username>") and `AuthSession.isToken`
  - ⚠️ actual: `BearerSession` has no username, so bearer renders `"<provider> · <userID>"` with the WIRE provider name (e.g. `nous`; the server owns display names, same fallback as `ReauthFeature.providerLabel`). An empty identity drops the `· …` suffix; an empty bearer provider reads `"OAuth"`.
- [x] add `DiagnosticsReport.render(bundleInfo:serverURL:authLabel:agentVersion:log:)` producing a plain-text block (app facts, server URL, auth label, agent version or "unknown", then the last N log entries as `type — summary`)
  - ⚠️ actual: `bundleInfo` is `BundleInfo?` (matches `DiagnosticsFeature.State`; nil → "App: unknown"); extra `logLimit` param defaults to `defaultLogLimit = 50`; the server URL is stripped of userinfo/query/fragment so a credential-bearing URL can't leak.
- [x] write tests: label per regime; report contains the facts and log lines; report NEVER contains the token / cookie values / bearer tokens (assert absence against a session built with known secret strings)
- [x] run tests - must pass before next task

### Task 5: AppIconPickerFeature reducer

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/AppIconPickerFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/AppIconPickerFeatureTests.swift`

- [x] state: `catalog: AppIconCatalog`, `selected: String?` (nil = primary), `errorBanner: String?`; `public init`
  - ➕ pure tile helpers on `State`: `isSelected(_:)` and `iconName(for:)` (primary tile → `nil`) so the view stays declarative
- [x] actions: `task` (loads `appIcon.catalog()` + `appIcon.current()` → `loaded`), `iconTapped(String?)` (optimistic `selected`, runs `appIcon.set`), `setFailed(previous: String?)`, `delegate(.iconChanged(String?))`
- [x] tapping the already-selected icon is a no-op; a failed `set` restores `previous` and sets `errorBanner`; a success sends the delegate
  - ➕ a new tap clears a stale banner; the `set` effect is `cancelInFlight` so the last tap wins (a superseded set lands no delegate/rollback)
- [x] write tests: seed on task; tap alternate → `set` called with the name and delegate fires; tap primary → `set(nil)`; failure → rollback + banner; same icon → no effect
- [x] run tests - must pass before next task

### Task 6: DiagnosticsFeature reducer

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/DiagnosticsFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/DiagnosticsFeatureTests.swift`

- [x] state: `bundleInfo: BundleInfo?`, `serverURL: URL`, `authLabel: String`, `agentVersion: String?`, `log: [GatewayLogEntry]`, `copiedToken: Int?`; `public init`
  - ➕ derived `State.report` (the `DiagnosticsReport.render` output) so the view/tests read one source
- [x] actions: `task` (subscribes `debugLog.stream()`, cancellable `logStream`), `logUpdated`, `copyTapped` (renders `DiagnosticsReport`, `pasteboard.copy`, bumps `copiedToken`, `cancelInFlight` clock dwell using the project's `copiedFeedbackDuration` idiom), `copiedFeedbackExpired`, `onDisappear` (cancel the stream)
- [x] write tests: stream feeds `log`; copy → pasteboard receives the rendered report and token bumps per copy; dwell clears on `TestClock` advance; a second copy inside the dwell restarts it
- [x] run tests - must pass before next task

### Task 7: SettingsPath and SettingsFeature restructure

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/SettingsPath.swift` (`SettingsPath` + `AcknowledgementsFeature` + `Acknowledgement` static list)
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` (`settingsButtonTapped` seeding)
- Modify: `HermesKit/Tests/HermesKitTests/SettingsFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift` (settings seeding assertion, if one exists)

- [x] add `AcknowledgementsFeature` (empty state, `EmptyReducer`) with the static `Acknowledgement` list (TCA, swift-dependencies, GRDB: name, URL, license) and the top-level `@Reducer enum SettingsPath` with the three cases
- [x] `SettingsFeature.State`: add `path`, `authSession`, `profileName`, `agentVersion`, `bundleInfo`, `selectedAppIcon`, derived `authLabel`, `showsTokenField`, `selectedAppIconLabel`, `versionLabel`; remove `log`; extend `init`
  - ⚠️ actual: `authSession` is a computed `connection.auth` (not a stored copy — `saveTokenTapped` rewrites `connection.token`, so a second copy could drift); ➕ stored `appIconCatalog` (loaded on `.task`) so `selectedAppIconLabel` can resolve `nil` → the build's primary label and the picker push is seeded with the catalog; `versionLabel` = `"Version 1.0 (79)"`
- [x] `.task`: drop the log stream; add bundle info load, `rest.status(baseURL)` → `agentStatusLoaded(version)` (failure → nil, no banner), `appIcon.current()` → `currentAppIconLoaded`
  - ⚠️ actual: bundle info and the icon catalog are synchronous client reads, so `.task` assigns them directly — no `bundleInfoLoaded` action
- [x] row actions append the path element: `appIconRowTapped` → `.appIcon(AppIconPickerFeature.State(...))`, `diagnosticsRowTapped` → `.diagnostics(DiagnosticsFeature.State(seeded from parent))`, `acknowledgementsRowTapped` → `.acknowledgements(.init())`; `.forEach(\.path, action: \.path) { SettingsPath.body }`
- [x] handle `.path(.element(id:action:.appIcon(.delegate(.iconChanged(name)))))` → `selectedAppIcon = name`
- [x] `clearTokenTapped` unchanged (clear list identical; icon not touched); `SessionListFeature.settingsButtonTapped` passes `scopedProfileName` and the connection's auth session
  - ⚠️ actual: the auth session already rides in `connection`; only `profileName: scopedProfileName` was added to the seed
- [x] update existing `SettingsFeatureTests` for the removed `log` / new init; write tests: task seeding (bundle info, agent version, current icon; status failure → nil); each row tap pushes the expected case with the expected seed; `iconChanged` delegate updates `selectedAppIcon`; auth label / `showsTokenField` per regime; profile row nil when unsupported; sign out still clears every prefs entry and never calls `appIcon.set`
  - ⚠️ the app target (`SettingsView` reads `store.log`) and `SettingsSnapshotTests` stay broken until Task 8 rebuilds the view
- [x] run tests - must pass before next task

### Task 8: SettingsView restructure and sheet hosting

**Files:**
- Modify: `HermesMobile/Sources/Features/Settings/SettingsView.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobileTests/SettingsSnapshotTests.swift`

- [ ] `SettingsView` owns `NavigationStack(path: $store.scope(state: \.path, action: \.path))` with the `Form` as root and `switch pathStore.case` destinations (placeholder views for the three cases until Task 9); `SessionListView` sheet drops its bare `NavigationStack`
- [ ] rebuild the `Form` into the six groups from Technical Details; token field gated on `showsTokenField`; Agent row hidden while `agentVersion == nil`; Profile row gated on `profileName`; Notifications block moved verbatim
- [ ] Feedback rows as `Link`s from `FeedbackLinks` with the external-link affordance; "Rate Hermes Mobile" calls `@Environment(\.requestReview)` then opens `writeReview` only when `AppStoreIdentity.appID` is set
- [ ] Sign out button copy + footer; version row from `versionLabel`
- [ ] update existing `SettingsSnapshotTests` (no outer `NavigationStack`, new init, no `log`) and add light/dark snapshots for token vs cookie vs bearer auth and `profileName` present; re-record the changed baselines (`make snapshot` twice for new tests)
- [ ] run `make snapshot` + HermesKit tests - must pass before next task

### Task 9: Sub-screen views and their snapshots

**Files:**
- Create: `HermesMobile/Sources/Features/Settings/AppIconPickerView.swift`
- Create: `HermesMobile/Sources/Features/Settings/DiagnosticsView.swift`
- Create: `HermesMobile/Sources/Features/Settings/AcknowledgementsView.swift`
- Modify: `HermesMobile/Sources/Features/Settings/ConnectionDebugView.swift` (embedded by `DiagnosticsView`)
- Modify: `HermesMobile/Sources/Features/Settings/SettingsView.swift` (wire destinations)
- Create: `HermesMobileTests/AppIconPickerSnapshotTests.swift`
- Create: `HermesMobileTests/DiagnosticsSnapshotTests.swift`

- [ ] `AppIconPickerView`: three-column `LazyVGrid` inside a `ScrollView`, each tile = `Image(option.previewAsset)` clipped to a continuous rounded rect, label below, checkmark overlay on the selected one, `errorBanner` footnote; sends `iconTapped`, `.task { store.send(.task) }`
- [ ] `DiagnosticsView`: "Copy diagnostics" button + copied toast off `copiedToken` (VoiceOver announcement), then the existing `ConnectionDebugView(entries:)`; `.task` / `.onDisappear` wiring
- [ ] `AcknowledgementsView`: static list of name, license, link
- [ ] wire the three destinations in `SettingsView`; `tuist generate`; build
- [ ] snapshots: picker grid with an alternate selected (light/dark, pinned width + height), picker with banner; Diagnostics with log entries and the copied toast; Acknowledgements — `make snapshot` twice each
- [ ] run `make snapshot` + HermesKit tests - must pass before next task

### Task 10: Privacy policy and docs

**Files:**
- Create: `PRIVACY.md`
- Create: `docs/features/settings.md`
- Modify: `docs/development.md` (App icon per build section)
- Modify: `README.md` (feature list)
- Modify: `CLAUDE.md` (one bullet under UI idioms or Session list pointing at the feature doc)

- [ ] write `PRIVACY.md`: the app talks only to the user's own agent; no analytics, no third-party services; what is stored on device (Keychain secrets, prefs, snapshot cache); push payloads are generic (link `docs/features/push-notifications.md`)
- [ ] `docs/features/settings.md`: groups and gating rules, `SettingsPath` model, icon catalog derivation and the all-six alternates rule, the six-icon table with labels and asset names, feedback link composition, diagnostics report contents and the no-secrets invariant
- [ ] `docs/development.md`: extend the icon section with the alternates list and the "primary differs per build, parser filters it" note; how to add a seventh icon (set + preview + table + alternates)
- [ ] README feature list: app icon picker, feedback links, About; CLAUDE.md bullet (5–8 lines, rule + pointer)
- [ ] verify every code identifier named in the docs exists (grep)
- [ ] run tests - must pass before next task

### Task 11: Verify acceptance criteria
- [ ] verify all requirements from Overview are implemented: six groups, six icons selectable, version row, feedback links prefilled, About links, Diagnostics copy, Acknowledgements, sign out semantics unchanged
- [ ] verify edge cases: gated auth hides the token field; unsupported profiles hide the Profile row; status failure hides the Agent row; icon set failure rolls back with a banner; logout leaves the icon alone
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run `make snapshot` — must be clean (every failure is a real signal)
- [ ] build the Debug app via `xcodebuild` after `tuist generate`; pick an icon in the simulator and confirm the home screen changes and the choice survives relaunch

### Task 12: [Final] Update documentation
- [ ] re-read `docs/features/settings.md` against the shipped code; fix drift
- [ ] update CLAUDE.md if new patterns were discovered during implementation
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- One TestFlight build (primary overridden to `AppIconDev` on the command line): confirm the
  version row shows the real marketing version and build, that the six-name alternates
  list builds and installs with the overlapping primary, that every alternate applies, and
  that picking "Blueprint" (the primary) via `setAlternateIconName(nil)` restores it.
- Tap each Feedback link on device: GitHub new-issue pages open prefilled; the Rate row
  shows the system review prompt.

**External updates:**
- Fill in `AppStoreIdentity.appID` once the App Store Connect record exists (write-review
  fallback stays off until then).
- Add the `PRIVACY.md` GitHub URL as the privacy policy URL in App Store Connect.
- Close #135 and #137 when merged; #140 / #141 remain open.
