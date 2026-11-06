# Widgets, controls and the running-agents Live Activity (#138)

The short rule lives in `CLAUDE.md` → "Push notifications" (next to the App Intents bullet whose
routing it reuses); this doc is the full contract. Design history: `docs/plans/completed/`
(`20261106-widgets-live-activity.md`).

Home Screen, Lock Screen and Control Center surfaces, plus ONE aggregate Live Activity that
shows running agents on the Lock Screen and in the Dynamic Island. The thin-client rule holds
all the way out: the widget extension never touches the network or the Keychain, every tap is
a `hermesmobile://` URL the app routes, and freshness is local only. When the app can no
longer observe, the surfaces say "Outdated" instead of guessing. No plugin or gateway change,
no ActivityKit push.

## Surfaces

All six live in one `WidgetBundle` (`HermesWidgets/Sources/HermesWidgetsBundle.swift`):

| Surface | Families | Tap |
|---|---|---|
| `QuickActionsWidget` ("Hermes") | `systemSmall`: "Ask" pill + Camera + Mic; `systemMedium`: "Ask Hermes" pill + Camera + Photos + Mic | small: `Button(intent: OpenHermesURLIntent)`; medium: `Link` per button |
| `SessionsWidget` ("Sessions") | `systemMedium`: the headline row; `systemLarge`: up to 5 rows | `Link` per row; no `widgetURL` (a tap elsewhere opens the app as is) |
| `NewChatAccessoryWidget` ("New Chat") | `accessoryCircular`: the Hermes glyph | `widgetURL` new chat |
| `NewChatControl` / `DictateControl` | Control Center, Lock Screen, Action button | `ControlWidgetButton(action: OpenHermesURLIntent)` |
| `AgentsLiveActivity` | Lock Screen + Dynamic Island | `widgetURL` to the headline session (none without a headline) |

- **The small pill reads "Ask"**: "Ask Hermes" truncates at 126 pt. VoiceOver still reads
  "Ask Hermes". The voice-conversation waveform waits for #92; the labeled shortcut-grid kind
  is deliberately not built.
- **Controls reuse the #93 titles and symbols** from `LaunchIntent.shortcutTitle` /
  `shortcutSymbolName` ("New Chat" `plus.message`, "Dictate" `mic.badge.plus`). The widget
  circles use plain camera / photo / mic symbols.
- **The glyph** is a template "HA" mask (`HermesWidgets/Resources`, `HermesGlyph`) drawn with
  `.widgetAccentable()`, so tinted and clear Home Screens recolor it.
- **Sessions rows**: title; folder icon + workspace (`Session.workspaceLabel`, omitted when
  `cwd` is blank) · relative time ("… ago"); a trailing glyph: working = `progress.indicator`
  in system blue, needs input = `questionmark.circle` in yellow, outdated = `clock` in
  secondary, idle = none. Row text uses `Color.primary` / `Color.secondary`: inside a `Link`
  the hierarchical styles resolve to the link tint. Empty states: signed out → "Sign in to
  Hermes"; no sessions → "No sessions yet" plus a New Chat link.
- **Live Activity, lock screen**: "Hermes" + "N active agent(s)" header ("No active agents"
  when Done); the headline title, or the workspace in its place when titles are off, then the
  workspace as secondary text; a trailing status label: Working (blue), Needs input (yellow),
  Done (green), Outdated (secondary, when `context.isStale`). **Dynamic Island**: compact
  leading = glyph; compact trailing = the count, `?` when the headline needs input, a green
  checkmark when Done, a secondary count when stale; minimal = glyph; expanded = the
  lock-screen layout in the bottom region.
- The wording (`displayStatus(isStale:)`, `countLabel`, `headlineText`, `secondaryText`,
  `tapIntent`) lives on `AgentActivityContent` in HermesWidgetKit and is unit-tested
  (`AgentActivityPresentationTests`); the views only lay it out.

## Packaging: `HermesWidgetKit`

HermesKit can't be linked into an extension (`UIApplication.shared` in `PushClient`,
`QuickActionsClient`, `IdleTimerClient`, `BackgroundTaskClient`, `OAuthLoginClient`), so the
package has a second, **Foundation-only** library product, `HermesWidgetKit`, with no package
dependencies. HermesKit depends on it and re-exports it
(`HermesKit/Sources/HermesKit/HermesWidgetKitExports.swift`, `@_exported import`), so app code
sees one module.

- **The extension links ONLY `HermesWidgetKit`** (no TCA, no GRDB, no HermesKit) and is built
  with `APPLICATION_EXTENSION_API_ONLY = YES`. The built `.appex` links only system frameworks
  (ActivityKit, AppIntents, Foundation, SwiftUI, UIKit, WidgetKit).
- **What lives there**: everything both processes must agree on. `SessionStatus` and
  `LaunchIntent` (moved down from HermesKit; `SessionStatus` gained a `String` raw value so its
  Codable form is the stable case names), `LaunchAction`, `AppGroup`, `WidgetDeepLink`,
  `WidgetSessionRow` / `WidgetSessionSnapshot`, `WidgetStaleness`, `AgentActivityContent`.
- **`HermesActivityAttributes`** (`ContentState = AgentActivityContent`, no static
  attributes) is there too, under `#if os(iOS) && canImport(ActivityKit)`. ActivityKit matches
  an activity to its UI by type, so the app (which requests it) and the extension (which
  renders it) must share ONE definition. The macOS test build compiles it out; the pure content
  type stays outside the guard.
- **Widget views take plain values** (no `TimelineEntry` / `ActivityViewContext`), so
  `HermesMobileTests` compiles `HermesWidgets/Sources/Views/**` directly and snapshots them (an
  extension can't be imported). That is why the row view is `SessionsWidgetRowView`: the app
  already has a `SessionRowView`.
- **Targets** (`Project.swift`): the `HermesWidgets` `.appExtension`
  (`me.honcharenko.HermesMobile.Widgets`, iOS 18, the `com.apple.widgetkit-extension` point) is
  embedded in the app. Both targets carry the App Group `group.me.honcharenko.HermesMobile`
  and share the `marketingVersion` / `currentProjectVersion` / `appGroupIdentifier` constants,
  so they can't drift. The app adds `NSSupportsLiveActivities = true` and the `hermesmobile`
  `CFBundleURLTypes` scheme. Signing: `docs/development.md`.

## Every tap is a URL

| URL | `LaunchIntent` |
|---|---|
| `hermesmobile://new` | `.newChat` |
| `hermesmobile://new?with=dictation` | `.newChatWithDictation` |
| `hermesmobile://new?with=camera` | `.newChatWithCamera` |
| `hermesmobile://new?with=photos` | `.newChatWithPhotos` |
| `hermesmobile://session/<id>[?profile=<name>]` | `.openSession(id:profile:)` |

- **`WidgetDeepLink`** builds and parses them. The id and the profile are strictly
  percent-encoded (a `/`, `&`, `+` or space round-trips byte for byte); scheme and host match
  case-insensitively. Anything else is `nil`: another scheme or host, an empty id, an extra
  path segment, an unknown `with=` value. An empty `?profile=` decodes to `nil`.
- **The app has ONE entry point**: `HermesMobileApp`'s `.onOpenURL` calls
  `LaunchIntentBridge.shared.received(url:)`, which maps through `WidgetDeepLink.intent(from:)`
  and ignores a `nil`. The mapping lives in HermesKit so "unknown link ignored" is unit-tested.
  There is no scene-delegate `openURLContexts` handler (it would double-deliver). The in-app
  `hermes-file://` scheme (`docs/features/file-preview.md`) is separate.
- **From there it is the #93 path** (`docs/features/app-intents.md`): cold-launch buffer, stash
  before sign-in, last-wins with a push tap, cleared on every logout.
- **`OpenHermesURLIntent`** (`isDiscoverable = false`) is what the small widget and the
  controls run, because neither can host a `Link`. Its `perform()` only returns
  `.result(opensIntent: OpenURLIntent(url))`; it routes nothing. A target that
  `WidgetDeepLink` doesn't recognise opens a plain new chat.
- **`.openSession` follows push-tap routing (#32)** through the shared
  `reduceOpenSessionRouting`: on screen → in place; a detached compact slot → re-attach;
  otherwise replace the slot, never stack. It dismisses list presentations first and never
  arms the #30 approval hint. A row from another profile than the list's (profiles API present)
  opens directly under the row's profile without changing the list's selection; a `nil`
  profile or an agent without the profiles API routes exactly like a push tap.
- **Its stash remembers the server.** Before `home` exists, `.openSession` records
  `pendingLaunchIntentServerURL`; a landing on a different server drops it (the same guard as
  `pendingPushTapServerURL`). New-chat intents stay origin-free.
- **Camera and photos** seat a new chat with a one-shot `pendingLaunchAction`
  (`docs/features/app-intents.md`).

## The projection and the ONE edge

`AppFeature.State.agentStatus: AgentStatusProjection?` is computed, pure and `Equatable`, with
no timestamps, so its edge fires only on a real change. Built by
`AgentStatusProjection.make(sessions:needsInput:slotRunning:showsTitles:profile:)`:

- **Source = `SessionListFeature.State.statusSessions`**, the list's UNFILTERED rows: `nil`
  until the first unfiltered fetch of the process succeeds, replaced on every unfiltered
  success (decided by `!isSearching` when the response lands, because list and search share
  one cancel-in-flight fetch), never touched by a search, patched by the same `runningChanged`
  mutation that sets a row's `isActive`, and reset to `nil` on any `scopedProfileName` change
  (not on a rename). Optimistic archive / delete leave it; the next fetch replaces it.
- **`nil` means unknown**: no `home`, or no unfiltered fetch yet. **A cached guess never starts
  anything**: the GRDB paint never feeds the projection.
- **Rules**: interactive sessions only (cron excluded); status from `needsInputSessionIDs` and
  the working flag, never `.unread` (the widgets paint no unread state, and a read flip must
  not churn the mirror). The live slot's running flag overrides its row's polled `isActive`,
  but only when the slot is in the list's profile (`isSameProfile`).
- **Order**: needs input, then working, then `updatedAt` newest first, server order breaking
  ties. `rows` is capped at `WidgetSessionSnapshot.maxRows` (5); `activeCount` counts every
  needs-input or working row of the whole list; `headline` = the first active row.
- **`activityContent`** is `nil` when nothing is active. It carries the headline title only
  while "Show session titles" is on. `showsTitles` is part of the projection, so flipping it is
  a projection change: the Live Activity drops the title, the Home Screen widgets don't.

**One `.onChange(of: \.agentStatus)`** in `AppFeature`, evaluated after every child reducer
(same pattern as `offersQuickActions`), drives both surfaces: `syncMirror` and
`syncLiveActivity` (the activity). A `nil` projection HOLDS: write nothing, never end. Only a
logout clears. Never add a writer in `SessionListFeature` or `ChatFeature`.

## The App Group mirror

`WidgetMirrorClient` (`write` / `clear` / `reloadTimelines`) is the extension's ONLY data
source: a `WidgetSessionSnapshot` JSON file (`AppGroup.snapshotFileURL()`,
`widget-sessions.json`) in the App Group container.

- **Writes**: debounced 1 s on `continuousClock` (`surfacesSyncDebounce`), last-wins under
  `CancelID.mirrorSync`, so a list fetch landing next to a slot's running flip is one write.
  Each write reloads the sessions widget's timelines (`AppGroup.sessionsWidgetKind`). The file
  is written `.atomic`, so the widget never reads a torn file. A failed write is only
  debug-logged: the mirror is a non-authoritative cache the next change rewrites.
- **The snapshot** is versioned (`currentVersion = 1`). `decodeLeniently` reads a version
  header first and returns `nil` for corrupt bytes or a newer version; the provider treats a
  missing or unreadable file as `.signedOut`.
- **Logout**: `clearSurfaces` writes `.signedOut` (`isSignedIn = false`) and reloads, at every
  identity teardown that clears `pendingPushTap` (Settings → Sign out, the retry screen's
  Log Out, re-auth's "Quit to start", a different-user re-auth). It shares the sync cancel id,
  so a write still waiting out its debounce can't land after it.
- `liveValue` is the file-backed client over the App Group container plus
  `WidgetCenter.shared.reloadTimelines(ofKind:)`, iOS-guarded. `fileBacked(at:reloadTimelines:)`
  holds the file logic, so macOS tests cover it. `testValue` is a no-op (every logout and list
  fetch reaches it).

## Staleness: `freshUntil`

The app vouches for what it wrote until `freshUntil`; past it nothing observes the agents.

- **Foreground writes**: `now + 8 h` (`foregroundFreshness`). It only bounds a crash or kill
  that skips the background edge.
- **`.background`**: written at once, not debounced (an idle app may be suspended within
  seconds): `now + (running slot ? 30 s : 0) + 10 s`. The stamp is kept in
  `State.backgroundFreshUntil` and reused by every edge write until `.active`, so a change
  during the grace window can't extend the promise.
- **`.active`**: clears the stamp and rewrites at once with `now + 8 h`, so the scheduled
  "Outdated" doesn't fire under a live app.
- **The widget**: `WidgetStaleness.timelineDates` = an entry for now plus an "outdated" entry
  at `freshUntil` while that is ahead; policy `.never` (the app reloads after every write).
  Exactly at `freshUntil` is already outdated. Past it, working / needs-input glyphs become the
  clock; titles stay.
- **The Live Activity**: `staleDate = freshUntil`, the same promise, so it reads "Outdated" at
  the same instant the widget does.

## Live Activity lifecycle

`LiveActivityClient` (`areActivitiesEnabled`, `start`, `update`, `end`, `endAll`): the live
value wraps ActivityKit under `#if os(iOS) && canImport(ActivityKit)` and requests with
`pushType: nil`. `testValue` is a no-op that reports activities disabled. `AppFeature` decides
everything in `syncLiveActivity`, so every transition is a `TestStore` assertion.

- **`State.liveActivity: LiveActivitySeat?`** holds the id (nil while the start is in flight)
  and the last content sent; `liveActivityID` is computed from it.
- **Start**: agents active, no seat, the pref on, the scene NOT backgrounded and iOS allowing
  activities. The seat is taken at once, so a second change can't start a second activity.
  The start is NOT debounced: `Activity.request` is foreground-only and the user may
  background within the second. `liveActivityStarted(id)` adopts the id and catches up with
  anything that changed meanwhile. A start failure is only debug-logged
  (`liveActivityStartFailed` frees the seat for the next change), never a banner.
- **Update**: debounced 1 s via `.liveActivitySyncDue` under `CancelID.liveActivitySync`, so a
  turn ending right before the next queued turn starts updates the activity instead of ending
  and restarting it. Unchanged content is not re-sent.
- **End**: nothing active → end with the last headline as `.done` content
  (`activeCount = 0`), dismissed after 5 min (`liveActivityDismissal`).
- **Scene edges restamp** the stale date at once (`.background` with `backgroundFreshUntil`,
  `.active` with `+8 h`); `.active` also starts a missed activity when agents are active and
  none is up. The background edge never starts one.
- **Orphans end at once**: a start that lands with no seat (toggle off or logout mid-request)
  or with an already-adopted seat (a fast off→on) ends that activity immediately.
- **Every landing sweeps**: `landOnHome` ends every activity on screen when there is no seat.
  None can be this landing's (a start needs the first fetch, which comes after), so it belongs
  to a previous process, killed in the background or crashed, that nothing would ever update
  or end. A still-active agent restarts it after the first fetch.
- **Logout** (the four `clearSurfaces` sites) ends every activity and drops the seat.

## Settings toggles

Two device-local prefs in `PreferencesClient`, both default on: `liveActivityEnabled`
("Live Activity") and `liveActivityShowsTitles` ("Show session titles", shown only while Live
Activity is on). Rows, footer and seeding: `docs/features/settings.md`.

- **Off** → `endAll`, drop the seat, cancel a pending update. **On** → sync at once (starts
  if agents are active). Show-titles goes through the projection edge.
- Settings persists and delegates; the list forwards; `AppFeature` handles the delegate and
  its own direct actions through one `setLiveActivityEnabled`. `landOnHome` seeds both from
  prefs on every landing.
- **Titles off OMITS the title** from the activity content (the workspace takes its place),
  not `.privacySensitive()` redaction. The Home Screen widgets are unaffected.
- `clearLiveActivityPrefs()` resets both at the Settings sign-out and both `AppFeature` full
  logouts. A different-user re-auth ends the activity but keeps the device prefs.

## Accepted residuals

- **Start is foreground-only.** A turn that starts while the app is backgrounded or killed
  (including one started from the desktop) gets no activity until the app is next opened.
  Pushing the activity would need plugin and gateway work.
- **A foreground crash or kill skips the background edge**, so the mirror stays "fresh" for
  up to 8 h and the widgets keep the last working / needs-input glyphs until the app runs
  again. The activity, stamped with the same 8 h, keeps its last status until the next landing
  sweeps it (or iOS's own Live Activity time limit ends it).
- **Desktop-started turns while the app is foregrounded** show up at the list's next fetch or
  poll, not instantly.
- **Not verified on a device yet**: `OpenURLIntent` opening the app from the small widget and
  the controls on iOS 18 (fallback if not: one `widgetURL` new chat for the small widget and
  `openAppWhenRun` intents compiled into both targets for the controls); `.onOpenURL` cold and
  warm; the tinted and clear rendering modes (`widgetRenderingMode` can't be injected into a
  snapshot).

## Tests

- HermesWidgetKit (`swift test`, macOS): `LaunchIntentTests`, `SessionStatusTests`,
  `WidgetDeepLinkTests` (every case round-trips, malformed URLs → `nil`), `WidgetSnapshotTests`
  (lenient decode, cap, staleness boundaries, glyphs, timeline dates, mirror read),
  `AgentActivityPresentationTests`.
- HermesKit: `AgentStatusProjectionTests`, `AppAgentStatusTests`, `WidgetLaunchRoutingTests`
  (URL routing, `openSession`, stash, last-wins, logout, camera / photos),
  `WidgetSurfacesTests` (debounce on `TestClock`, background / foreground stamps, every Live
  Activity transition, orphans, the landing sweep, logout), list `statusSessions` tests,
  `SettingsFeatureTests` (toggles), `PreferencesClientTests`.
- Snapshots (`HermesMobileTests/WidgetSnapshotTests.swift`): quick actions small / medium,
  accessory circular, sessions medium / large (light, dark, outdated, signed out, empty) with
  pinned relative times (`WidgetRelativeTime.fixed(now:)`), and the activity views (working,
  needs input, done, outdated, title omitted, expanded, compact trailing). The Settings rows
  are in `SettingsSnapshotTests`.
