# Settings: groups, app icon picker, feedback, diagnostics (#137, #135)

The short rules live in `CLAUDE.md` → "UI idioms"; this doc is the full contract. Design
history: `docs/plans/completed/` (settings overhaul + app icons).

## Shape: one Form, a three-row stack

Settings is ONE `Form` on the home screen's Settings TAB, in six groups. Inline groups have no child reducers; only
three rows push a sub-screen, and they push through a TCA stack:

- **`SettingsPath`** is a top-level `@Reducer enum` (not nested in `SettingsFeature`) with
  `appIcon(AppIconPickerFeature)`, `diagnostics(DiagnosticsFeature)` and
  `acknowledgements(AcknowledgementsFeature)`. `SettingsFeature.State.path` is a
  `StackState<SettingsPath.State>`; the body ends with `.forEach(\.path, action: \.path)`.
- **Rows push by appending in the reducer** (`appIconRowTapped`, `diagnosticsRowTapped`,
  `acknowledgementsRowTapped`), so every push is a `TestStore` assertion with its seed. The
  rows are a `SettingsNavigationRow` (`SettingsRows.swift`; a `Button` with a drawn chevron and
  `.tint(.primary)`, since a Form button resolves `.primary` to the tint), never a
  `NavigationLink`.
- **`SettingsView` owns the `NavigationStack(path:)`**, with the `Form` as root and
  `switch pathStore.case` as the destination. `AppView` layers it OVER the whole split view
  (never inside a column: that would nest two stacks) while `effectiveTab == .settings`, and
  passes the `HomeTabBar` as `bottomBar`, inset on the Form root only so a pushed sub-screen
  covers it. There is no Done button; tab lifecycle rules are in
  `docs/features/session-list.md` ("The Settings tab").
- **`.task` and the push-guide `.sheet` sit on the `NavigationStack`, not the Form root.** A
  root `.task` re-fires on every pop back from a sub-screen and would re-probe `/api/status`.

## Seeding and `.task`

`SessionListFeature.selectTab(.settings)` (`seedSettings`, fresh on every visit — the state is
dropped when the tab is left) seeds `connection`, `pushAvailable`,
`defaultSwipeAction`, `deleteSupported`, `profileName: scopedProfileName`, and the two Live
Activity prefs (`liveActivityEnabled`, `liveActivityShowsTitles`, read synchronously from
`PreferencesClient`). The auth session
is not copied: `State.authSession` is computed from `connection.auth`, because
`saveTokenTapped` rewrites `connection.token` and a stored copy would drift.

`.task` assigns the two synchronous facts directly, `bundleInfo.info()` and
`appIcon.catalog()` (so there is no `bundleInfoLoaded` action), plus
`liveActivity.areActivitiesEnabled()` → `liveActivitiesAllowedBySystem` (default `true`, so a
fixture that skips `.task` shows the normal footer; not re-read on foreground), then merges four effects:
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
   row stays hidden), only an `api.status` debug-log note. Under it, `AgentUpdateRows` hosts
   the agent updater (hidden unless the agent has the update endpoints and accepts this
   credential; contract in `docs/features/agent-update.md`). The token `SecureField` + "Save token" show only when `showsTokenField`
   (`AuthSession.isToken`): a password or OAuth session has no token to re-paste. Reconnect.
2. **App.** "App Icon" (value `selectedAppIconLabel`, plus a small thumbnail of
   `selectedAppIconOption`'s preview) pushes the picker. "Default swipe
   action" stays gated on `deleteSupported` (`docs/features/session-list.md`).
3. **Notifications.** The push block, unchanged (`docs/features/push-notifications.md`),
   then a second, headerless `Section` with the Live Activity rows (#138,
   `docs/features/widgets.md`). It is a separate section so it has its own footer, and it shows
   whether or not push is available (the Live Activity is local; no plugin). "Live Activity"
   (default on) with "Show session titles" (default on) nested under it, hidden while Live
   Activity is off. Footer: "Shows running agents on the Lock Screen and in the Dynamic
   Island.", or "Live Activities are turned off for Hermes in iOS Settings." when
   `liveActivitiesAllowedBySystem` is false (no link; the toggle stays usable and keeps the
   pref). Each toggle persists through `PreferencesClient` and sends a delegate
   (`liveActivityToggled` / `liveActivityShowsTitlesToggled`) that the session list forwards to
   `AppFeature`: off ends every activity, show-titles changes the projection.
4. **Feedback.** "Report a bug" and "Request a feature" open `reportBugURL` /
   `requestFeatureURL`, which fall back to `FeedbackLinks.allIssues` until `bundleInfo`
   loads, so the view never unwraps. "Rate Hermes Mobile" opens `FeedbackLinks.rateApp` (the
   write-review page) and is hidden while that is `nil`, i.e. until `AppStoreIdentity.appID`
   is set once the app is live on the App Store. "All issues on GitHub" opens
   `FeedbackLinks.allIssues`.
5. **About.** `versionLabel` (`"Version 1.0 (79)"`); GitHub repository; Hermes Agent; Privacy
   policy (`FeedbackLinks.privacyPolicy`, the repo's `PRIVACY.md` on GitHub);
   Acknowledgements and Diagnostics push. The Diagnostics row shows no entry count.
6. **Sign out.** A destructive button sending the same `clearTokenTapped`, with the same
   name and the same clear list (logout clears every prefs entry, including
   `clearLiveActivityPrefs()`, which resets both Live Activity toggles to on) plus
   `debugLog.clear()`. It never calls `appIcon.set`: the icon survives logout.

External rows (`ExternalLinkRow`) are `Link`s with a trailing `arrow.up.right`.

## App icon picker (#135)

### The icons

| Label | Set name (`.appiconset`) | Preview image set | Notes |
|---|---|---|---|
| Gold | `AppIcon` | `AppIconPreview-AppIcon` | App Store release primary |
| Blueprint | `AppIconDev` | `AppIconPreview-AppIconDev` | Debug + every TestFlight primary |
| Hermes Neo | `AppIconHermesNeo` | `AppIconPreview-AppIconHermesNeo` | Dark + tinted variants |
| Hermes Neo Dark | `AppIconHermesNeoDark` | `AppIconPreview-AppIconHermesNeoDark` | Dark + tinted variants |
| Hermes Neo Blueprint | `AppIconHermesNeoBlueprint` | `AppIconPreview-AppIconHermesNeoBlueprint` | |
| Hermes Classic | `AppIconHermesClassic` | `AppIconPreview-AppIconHermesClassic` | Dark + tinted variants |
| Hermes Classic Dark | `AppIconHermesClassicDark` | `AppIconPreview-AppIconHermesClassicDark` | Dark + tinted variants |
| Hermes Classic Blueprint | `AppIconHermesClassicBlueprint` | `AppIconPreview-AppIconHermesClassicBlueprint` | |

`AppIconOption.all` is this table in display order. The previews are plain 240 px
single-scale image sets because an app icon set cannot be loaded with `Image(_:)`. The picker
draws them as fixed 76 pt continuous-corner tiles in a three-column grid, so the layout is the
same at every sheet width.

The four black-and-white sets (white and black backgrounds) carry explicit `luminosity`
appearance variants: `dark` is the original art and `tinted` is its grayscale copy. Without
them, iOS auto-generates the Dark, Clear and Tinted Home Screen renditions and inverts the
art. With them, the art keeps its own background and line colours in every mode (Tinted and
Clear still apply the system tint). The gold and blue sets have no variants yet (#83).

### Catalog derivation

`AppIconCatalog.parse(infoDictionary:)` is pure (outside any UIKit guard). It reads
`CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName` and the keys of
`CFBundleIcons.CFBundleAlternateIcons`. Names not in the table are dropped, the primary is filtered out of
`alternates`, and alternates keep table order; a missing or malformed dictionary is `.empty`.
`options` is primary + alternates in table order (the grid), and `label(for:)` maps
`nil` → the primary's label and an unknown name → `nil`.

### The every-set-is-an-alternate rule

The primary differs per build (`ASSETCATALOG_COMPILER_APPICON_NAME`: Gold for an App Store
release, Blueprint for Debug and TestFlight; `docs/development.md`). So `Project.swift` lists
**every** set in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, the primary included, with
`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`; every build can then reach every
icon without per-configuration lists.

**actool omits the primary from the built `CFBundleAlternateIcons`**, so a built `Info.plist`
lists one alternate fewer than the table. That is harmless: the parser filters the primary anyway, and
the primary is reachable as `set(nil)`. Choosing the primary is ALWAYS `set(nil)`, never its
alternate twin: `State.iconName(for:)` maps the primary tile to `nil`, and `isSelected(_:)`
checks the primary tile when `selected == nil`. Pinned by
`AppIconCatalogTests.actoolOutputWithoutPrimaryAlternate` (the real built shape) and
`tableNamesMatchProjectAlternateIconNames` (reads the `Project.swift` list from the checkout
and checks every set's `.appiconset` and preview image set exist).

### Selection

`AppIconClient` (`@DependencyClient`): `catalog()` is synchronous (bundle plist), `current()`
is async (the main-actor `alternateIconName` hop lives inside the client), and `set(_:)` throws
when iOS refuses. The live value is UIKit-guarded; `testValue` is `.inMemory()` with the full
`testCatalog` (primary `AppIcon`).

`AppIconPickerFeature` loads nothing itself: the push seeds the catalog and current icon
Settings already read. A tap is **optimistic**: the checkmark moves and `appIcon.set` runs.
One change at a time: a tap while `isApplying` is ignored, because cancelling the effect would
not stop the UIKit change already under way. A refusal re-reads `appIcon.current()` and sends
`setFailed(current:)`, which shows what iOS actually has and sets `errorBanner` to
`setFailedBanner`. A new tap clears a stale banner; tapping the already-selected icon is a
no-op. Success and refusal both send `delegate(.iconChanged)` with the resulting icon, which the
parent maps to `selectedAppIcon`. Popping the picker mid-change cancels its effect, so the
parent re-reads `appIcon.current()` on any pop that removes the picker; if the UIKit change
completes after that read, the row stays stale until Settings reopens.

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

`DiagnosticsFeature` is seeded by the parent with `serverURL`, `authLabel` and `agentVersion`;
a version that lands after the push is forwarded into the open screen. Build facts come from
`bundleInfo.info()` at copy time. It owns the live gateway log: `.task` subscribes to
`debugLog.stream()` (cancellable `logStream`); popping the screen ends it, because the stack
cancels a removed element's effects (no `.onDisappear` action, which would reach a missing
element). The log streams only while the screen is pushed. Every logout path clears it
(`debugLog.clear()`: Settings → Sign out, the retry screen's Log Out, re-auth's "Quit to
start"), so a report never mixes in a previous server's events. A re-auth that signs back in
(same or different user, same server) keeps it.

"Copy diagnostics" puts `DiagnosticsReport.render` on the pasteboard, bumps
`copiedToken` and runs the `cancelInFlight` `copiedFeedbackDuration` dwell (the transient-toast
idiom); the view shows the shared `CopiedToastView` ("Diagnostics copied", announced to
VoiceOver). `DiagnosticsView` puts the button and the gateway events in one `List` (no
list-in-list), and the empty state is a row, because an overlay would hide the button.

The report, in order: a `Hermes Mobile diagnostics` header; `App: <version> (<build>)`, `iOS`,
`Device`; `Server:` (redacted); `Auth:` (the label);
`Agent:` (the version or `unknown`); a blank line; then `Recent events (last N of M):` over the
last `DiagnosticsReport.defaultLogLimit` (50) log entries as `type — summary`, or
`Recent events: none`. `render` caps every summary with `GatewayEvent.truncate` (80
characters plus an ellipsis, newlines collapsed), whatever fed the log; the text can still be
message and reasoning fragments, commands or clarify questions: conversation excerpts, not
credentials. The copy is user-initiated and goes only to the
pasteboard; `PRIVACY.md` and the screen's footer under the button both say the events may
include snippets of messages and commands.

**No-secrets invariant.** The report is built only from its arguments, and none carries a
credential: the auth row arrives pre-rendered as `settingsLabel` (identity only), and the server
URL is stripped of userinfo, query and fragment, so a `?token=` URL or `user:pass@host` cannot
leak. **Never add an `AuthSession` parameter** to `DiagnosticsReport.render` or an
`AuthSession` field to `DiagnosticsFeature.State`. `DiagnosticsReportTests.neverContainsSecrets`
asserts the absence of known token, cookie and bearer strings across all three regimes plus a
credential-bearing URL.

## Acknowledgements

`Acknowledgement.all` lists every package in `HermesKit/Package.resolved` except the build- and
test-only ones (`swift-syntax`, `swift-snapshot-testing`), each with its LICENSE text verbatim
(MIT and Apache-2.0 both require it in the binary). `AcknowledgementTests` pins the list against
`Package.resolved` and each text against the SwiftPM checkout, so a new or removed dependency
fails until the list follows. `AcknowledgementsFeature` is an `EmptyReducer` that exists only to
be a `SettingsPath` case; `AcknowledgementsView` renders the list directly (each row expands to
the license text) and takes no store.

## Tests

- HermesKit: `AppIconCatalogTests`, `AcknowledgementTests`, `FeedbackLinksTests`, `BundleInfoClientTests`,
  `AuthSessionTests` (labels), `DiagnosticsReportTests`, `AppIconPickerFeatureTests`,
  `DiagnosticsFeatureTests`, `SettingsFeatureTests` (seeding, pushes, gates, sign out never
  touching the icon, the Live Activity toggles and the iOS-permission read),
  `SessionListFeatureTests` (`profileName` and Live Activity seeding, delegate forwarding),
  `AgentUpdateTests` (the updater; see `agent-update.md`).
- Snapshots: `SettingsSnapshotTests` (per-regime auth, profile, unloaded, Acknowledgements,
  the Live Activity rows with titles off, off, and disabled by iOS;
  whole-Form fixtures at `deviceImage(height: formHeight)`, 1 800 pt, so Feedback, About and
  Sign out are in frame), `AppIconPickerSnapshotTests`,
  `DiagnosticsSnapshotTests`.
