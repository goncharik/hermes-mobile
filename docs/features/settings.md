# Settings: groups, app icon picker, feedback, diagnostics (#137, #135)

The short rules live in `CLAUDE.md` → "UI idioms"; this doc is the full contract. Design
history: `docs/plans/completed/` (settings overhaul + app icons).

## Shape: one Form, a three-row stack

Settings is ONE `Form` in a sheet, in six groups. Inline groups have no child reducers; only
three rows push a sub-screen, and they push through a TCA stack:

- **`SettingsPath`** is a top-level `@Reducer enum` (not nested in `SettingsFeature`) with
  `appIcon(AppIconPickerFeature)`, `diagnostics(DiagnosticsFeature)` and
  `acknowledgements(AcknowledgementsFeature)`. `SettingsFeature.State.path` is a
  `StackState<SettingsPath.State>`; the body ends with `.forEach(\.path, action: \.path)`.
- **Rows push by appending in the reducer** (`appIconRowTapped`, `diagnosticsRowTapped`,
  `acknowledgementsRowTapped`), so every push is a `TestStore` assertion with its seed. The
  rows are a private `SettingsNavigationRow` (a `Button` with a drawn chevron and
  `.tint(.primary)`, since a Form button resolves `.primary` to the tint), never a
  `NavigationLink`.
- **`SettingsView` owns the `NavigationStack(path:)`**, with the `Form` as root and
  `switch pathStore.case` as the destination. The session list presents `SettingsView` bare:
  wrapping the sheet in another `NavigationStack` would nest two stacks.
- **`.task` and the push-guide `.sheet` sit on the `NavigationStack`, not the Form root.** A
  root `.task` re-fires on every pop back from a sub-screen and would re-probe `/api/status`.

## Seeding and `.task`

`SessionListFeature.settingsButtonTapped` seeds `connection`, `pushAvailable`,
`defaultSwipeAction`, `deleteSupported` and `profileName: scopedProfileName`. The auth session
is not copied: `State.authSession` is computed from `connection.auth`, because
`saveTokenTapped` rewrites `connection.token` and a stored copy would drift.

`.task` assigns the two synchronous facts directly, `bundleInfo.info()` and
`appIcon.catalog()` (so there is no `bundleInfoLoaded` action), then merges four effects:
`rest.status(baseURL)` → `agentStatusLoaded`, `appIcon.current()` → `currentAppIconLoaded`,
the push authorization status, and the push plugin info.

## The six groups and their gates

1. **Server.** URL; Auth = `authLabel` (`AuthSession.settingsLabel`): `Token`,
   `Password · <username>`, or `<provider> · <userID>`. `BearerSession` has no username, so
   the bearer label uses the WIRE provider name (e.g. `nous`) and the user id, the same
   fallback as `ReauthFeature.State.providerLabel`. An empty identity drops the `· …` suffix,
   and an empty bearer provider reads `OAuth`. Profile shows only when `profileName != nil`
   (nil when the agent has no profiles API). Agent shows only once `agentVersion` lands: the
   `/api/status` probe is informational, so a failure maps to `nil` with **no banner** (the
   row stays hidden). The token `SecureField` + "Save token" show only when `showsTokenField`
   (`AuthSession.isToken`): a password or OAuth session has no token to re-paste. Reconnect.
2. **App.** "App Icon" (value `selectedAppIconLabel`) pushes the picker. "Default swipe
   action" stays gated on `deleteSupported` (`docs/features/session-list.md`).
3. **Notifications.** The existing block, unchanged (`docs/features/push-notifications.md`).
4. **Feedback.** "Report a bug" and "Request a feature" open `reportBugURL` /
   `requestFeatureURL`, which fall back to `FeedbackLinks.allIssues` until `bundleInfo`
   loads, so the view never unwraps. "Rate Hermes Mobile" calls the SwiftUI `requestReview`
   environment action in the view, then opens `FeedbackLinks.writeReview(appID:)` only when
   `AppStoreIdentity.appID` is set (it is `nil` until the App Store record exists). "All
   issues on GitHub".
5. **About.** `versionLabel` (`"Version 1.0 (79)"`); GitHub repository; Hermes Agent; Privacy
   policy (`FeedbackLinks.privacyPolicy`, the repo's `PRIVACY.md` on GitHub);
   Acknowledgements and Diagnostics push. The Diagnostics row shows no entry count.
6. **Sign out.** A destructive button sending the same `clearTokenTapped`, with the same
   name and the same clear list (logout clears every prefs entry); only the copy changed. It
   never calls `appIcon.set`: the icon survives logout.

External rows (`ExternalLinkRow`) are `Link`s with a trailing `arrow.up.right`; the Rate row
is a `Button` with a star glyph, because with `appID == nil` it never leaves the app.

## App icon picker (#135)

### The six icons

| Label | Set name (`.appiconset`) | Preview image set | Notes |
|---|---|---|---|
| Gold | `AppIcon` | `AppIconPreview-AppIcon` | App Store release primary |
| Blueprint | `AppIconDev` | `AppIconPreview-AppIconDev` | Debug + every TestFlight primary |
| Hermes | `AppIconHermes` | `AppIconPreview-AppIconHermes` | |
| Hermes Blueprint | `AppIconHermesBlueprint` | `AppIconPreview-AppIconHermesBlueprint` | |
| Hermes Classic | `AppIconHermesClassic` | `AppIconPreview-AppIconHermesClassic` | |
| Hermes Classic Blueprint | `AppIconHermesClassicBlueprint` | `AppIconPreview-AppIconHermesClassicBlueprint` | |

`AppIconOption.all` is this table in display order. The previews are plain 180 px
single-scale image sets because an app icon set cannot be loaded with `Image(_:)`. The picker
draws them as fixed 76 pt continuous-corner tiles in a three-column grid, so the layout is the
same at every sheet width.

### Catalog derivation

`AppIconCatalog.parse(infoDictionary:)` is pure (outside any UIKit guard). It reads
`CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName` and the keys of
`CFBundleIcons.CFBundleAlternateIcons`, falling back to `CFBundleIcons~ipad` when the
universal key is absent. Names not in the table are dropped, the primary is filtered out of
`alternates`, and alternates keep table order; a missing or malformed dictionary is `.empty`.
`options` is primary + alternates in table order (the grid), and `label(for:)` maps
`nil` → the primary's label and an unknown name → `nil`.

### The all-six alternates rule

The primary differs per build (`ASSETCATALOG_COMPILER_APPICON_NAME`: Gold for an App Store
release, Blueprint for Debug and TestFlight; `docs/development.md`). So `Project.swift` lists
**all six** sets in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, the primary included, with
`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`; every build can then reach every
icon without per-configuration lists.

**actool omits the primary from the built `CFBundleAlternateIcons`**, so a built `Info.plist`
lists five alternates, not six. That is harmless: the parser filters the primary anyway, and
the primary is reachable as `set(nil)`. Choosing the primary is ALWAYS `set(nil)`, never its
alternate twin: `State.iconName(for:)` maps the primary tile to `nil`, and `isSelected(_:)`
checks the primary tile when `selected == nil`. Pinned by
`AppIconCatalogTests.actoolOutputWithoutPrimaryAlternate` (the real built shape) and
`tableNamesMatchProjectAlternateIconNames` (a literal copy of the `Project.swift` list that
documents the coupling).

### Selection

`AppIconClient` (`@DependencyClient`): `catalog()` is synchronous (bundle plist), `current()`
is async (the main-actor `alternateIconName` hop lives inside the client), and `set(_:)` throws
when iOS refuses. The live value is UIKit-guarded; `testValue` is `.inMemory()` with the full
six-icon `testCatalog` (primary `AppIcon`).

`AppIconPickerFeature` reloads the catalog and the current icon on `.task`. A tap is
**optimistic**: the checkmark moves, `appIcon.set` runs, and a refusal sends
`setFailed(previous:)`, which rolls the checkmark back and raises `setFailedBanner`. A new tap
clears a stale banner; tapping the already-selected icon is a no-op. The `set` effect is
`cancelInFlight`, so the last tap wins and a superseded effect lands neither a rollback nor a
delegate. Only a CONFIRMED change sends `delegate(.iconChanged)`, which the parent maps to
`selectedAppIcon`, so the App Icon row never shows a refused icon.

**iOS persists the choice.** Nothing is mirrored into `PreferencesClient`, so logout leaves
the icon alone.

## Feedback links

`FeedbackLinks` is pure. Constants: `repository`, `allIssues`, `hermesAgent`, `privacyPolicy`
(repo `goncharik/hermes-mobile`). `reportBug(_:)` and `requestFeature(_:)` build
`<allIssues>/new?title=…&body=…` with the title prefixes `Bug: ` / `Feature request: ` and a
body of short markdown prompts followed by a `---` environment block:

```
App: <marketingVersion> (<build>)
iOS: <osVersion>
Device: <deviceModel>
```

Values are encoded with an RFC 3986 unreserved-only set, so `&`, `=`, `+`, `#`, newlines and
non-ASCII are all escaped (`URLComponents.queryItems` leaves `+` literal, which GitHub reads as
a space). `writeReview(appID:)` is the App Store `?action=write-review` URL.

`BundleInfo` comes from `BundleInfoClient.info()` (synchronous, platform-neutral):
`CFBundleShortVersionString` / `CFBundleVersion`, the OS version from
`ProcessInfo.operatingSystemVersion` (formatted like `UIDevice.systemVersion`, which is
main-actor isolated), and the `utsname` machine identifier, with `SIMULATOR_MODEL_IDENTIFIER`
winning on a simulator (which would otherwise report `arm64`). `testValue` is `BundleInfo.test`
(`1.0`, `79`, `18.0`, `iPhone`).

## Diagnostics

`DiagnosticsFeature` is seeded by the parent with facts it already holds: `bundleInfo`,
`serverURL`, `authLabel` and `agentVersion`. It owns the live gateway log: `.task` subscribes to
`debugLog.stream()` (cancellable `logStream`), and the explicit `.onDisappear` action cancels it.
The log moved here from `SettingsFeature`, so it streams only while the screen is on screen.

"Copy diagnostics" puts `State.report` (`DiagnosticsReport.render`) on the pasteboard, bumps
`copiedToken` and runs the `cancelInFlight` `copiedFeedbackDuration` dwell (the transient-toast
idiom); the view shows the shared `CopiedToastView` ("Diagnostics copied", announced to
VoiceOver). `ConnectionDebugView(entries:header:)` renders the button as a leading `Section` of
the same `List` as the log (no list-in-list), and the empty state is a row, because an overlay
would hide the button.

The report, in order: a `Hermes Mobile diagnostics` header; `App: <version> (<build>)`, `iOS`,
`Device` (or `App: unknown` before bundle info loads); `Server:` (redacted); `Auth:` (the label);
`Agent:` (the version or `unknown`); then the last `DiagnosticsReport.defaultLogLimit` (50) log
entries as `type — summary`, or `Recent events: none`. A summary is
`GatewayEvent.debugSummary`, which carries up to 80 characters of event text (message and
reasoning fragments, commands, clarify questions): conversation excerpts, not credentials.
The copy is user-initiated and goes only to the pasteboard; `PRIVACY.md` says so.

**No-secrets invariant.** The report is built only from its arguments, and none carries a
credential: the auth row arrives pre-rendered as `settingsLabel` (identity only), and the server
URL is stripped of userinfo, query and fragment, so a `?token=` URL or `user:pass@host` cannot
leak. **Never add an `AuthSession` parameter** to `DiagnosticsReport.render` or an
`AuthSession` field to `DiagnosticsFeature.State`. `DiagnosticsReportTests.neverContainsSecrets`
asserts the absence of known token, cookie and bearer strings across all three regimes plus a
credential-bearing URL.

## Acknowledgements

`Acknowledgement.all` is a static list of the RUNTIME package dependencies (`GRDB.swift`,
`swift-composable-architecture`, `swift-dependencies`, all MIT); test-only packages are not
listed. Adding a runtime dependency to HermesKit's `Package.swift` means adding it here.
`AcknowledgementsFeature` is an `EmptyReducer` that exists only to be a `SettingsPath` case;
`AcknowledgementsView` renders the list directly and takes no store.

## Tests

- HermesKit: `AppIconCatalogTests`, `FeedbackLinksTests`, `BundleInfoClientTests`,
  `AuthSessionTests` (labels), `DiagnosticsReportTests`, `AppIconPickerFeatureTests`,
  `DiagnosticsFeatureTests`, `SettingsFeatureTests` (seeding, pushes, gates, sign out never
  touching the icon), `SessionListFeatureTests` (`profileName` seeding).
- Snapshots: `SettingsSnapshotTests` (per-regime auth, profile, unloaded, Acknowledgements;
  whole-Form fixtures at `deviceImage(height: formHeight)`, 1 800 pt, so Feedback, About and
  Sign out are in frame), `AppIconPickerSnapshotTests`,
  `DiagnosticsSnapshotTests`.
