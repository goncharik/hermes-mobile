# App Intents: new chat from outside the app (#93)

The short rule lives in `CLAUDE.md` → "Push notifications" (next to the push-tap routing it
mirrors); this doc is the full contract. Design history: `docs/plans/completed/`
(`20261106-app-intents-new-chat.md`).

Two App Intents open the app on a fresh chat under the selected profile, from Shortcuts, Siri
and Spotlight, and from the Action button (iPhone 15 Pro and later) once the user assigns one
there. The same two entry points are Home Screen quick actions (below). The app is a thin
client here too:
both intents are `openAppWhenRun = true` and only ROUTE. No agent logic runs in the intent.

The widgets, Control Center controls and the Live Activity (#138) reuse this whole path
through `hermesmobile://` deep links, which add three `LaunchIntent` cases (below; surfaces:
`docs/features/widgets.md`).

## Intents and phrases

| Intent | Title | `LaunchIntent` | App Shortcut phrases | Short title / symbol |
|---|---|---|---|---|
| `StartNewSessionIntent` | "New Hermes chat" | `.newChat` | "New \(.applicationName) chat", "Start a chat in \(.applicationName)" | "New Chat" / `plus.message` |
| `StartNewSessionWithDictationIntent` | "Dictate to Hermes" | `.newChatWithDictation` | "Dictate to \(.applicationName)" | "Dictate" / `mic.badge.plus` |

- Both live in `HermesMobile/Sources/Intents/LaunchIntents.swift`, share one `categoryName`
  ("Chats"), and their `perform()` does exactly one thing: `LaunchIntentBridge.shared
  .received(_:)`. The intent never fails, not even on a denied mic permission (that surfaces
  in the app, below).
- `HermesAppShortcuts` (`HermesMobile/Sources/Intents/HermesAppShortcuts.swift`) is the one
  `AppShortcutsProvider`, so Shortcuts, Siri and Spotlight work without user setup.
- **Explicit phrases only.** There is deliberately no "Open \(.applicationName)" phrase mapped
  to a new chat (opening the app should just open it), and no "Talk to \(.applicationName)":
  that phrase is reserved for the voice-conversation intent (#92), which will add a third
  `LaunchIntent` case.

## `LaunchIntent` and deep links

`LaunchIntent` and `LaunchAction` live in the Foundation-only `HermesWidgetKit` product
(re-exported by HermesKit), because the widget extension builds the same values:

| Case | `launchAction` | Deep link (#138) | Entry points |
|---|---|---|---|
| `.newChat` | none | `hermesmobile://new` | App Intent, quick action, widgets, control |
| `.newChatWithDictation` | `.dictation` | `hermesmobile://new?with=dictation` | App Intent, quick action, widgets, control |
| `.newChatWithCamera` | `.camera` | `hermesmobile://new?with=camera` | quick-actions widget |
| `.newChatWithPhotos` | `.photos` | `hermesmobile://new?with=photos` | quick-actions widget (medium) |
| `.openSession(id:profile:)` | none | `hermesmobile://session/<id>[?profile=<name>]` | sessions widget rows, Live Activity |

- `LaunchIntent.quickActions` stays `[.newChat, .newChatWithDictation]`. The widget-only cases
  have distinct `shortcutItemType` literals that `init?(shortcutItemType:)` rejects, so they
  never become quick actions.
- **The URL path**: the app's one `.onOpenURL` calls `LaunchIntentBridge.shared
  .received(url:)`, which maps through `WidgetDeepLink.intent(from:)` and ignores anything that
  isn't a well-formed Hermes link. Everything below (buffering, stash, last-wins, logout clear)
  then applies unchanged.

## Bridge, stash and replay

The flow is the cold-launch push-tap replay (#46, `docs/features/push-notifications.md`) with
a smaller payload:

`AppIntent.perform()` → `LaunchIntentBridge.shared.received(intent)` →
`LaunchIntentClient.incoming()` (observed in `AppFeature.task`) →
`AppFeature.launchIntentReceived(intent)`.

- **`LaunchIntentBridge`** (`HermesKit/Sources/HermesKit/Clients/LaunchIntentClient.swift`)
  has the same shape as `PushBridge`'s tap half, duplicated rather than abstracted (about 40
  lines): `NSLock`, live continuations keyed by UUID and pruned `onTermination`, live fan-out,
  and a consume-once, last-wins `pendingIntent`. An `openAppWhenRun` intent performs before the
  reducer's `.task` subscribes on a cold launch, so an intent that no live subscriber ACCEPTS is
  buffered (acceptance is judged per `yield` result, not by an empty dictionary) and drained
  once by the first subscriber. It is Foundation-only, so it sits outside any UIKit guard, the
  `liveValue` needs no `#if canImport(UIKit)`, and the buffering is unit-tested on macOS.
- **`LaunchIntentClient`** is a `@DependencyClient` with `incoming`. `liveValue` wraps the
  shared bridge and `testValue` is a finished stream; tests put a fresh `LaunchIntentBridge()`
  behind `incoming`.
- **The observer** (`CancelID.launchIntents`, `cancelInFlight`) is merged with the push-tap
  observer on every return path of `.task`. The push observer itself is unchanged.
- **Stash before sign-in, never drop.** On a cold launch `home` doesn't exist until the
  auto-connect probe (or a manual login) finishes, and the Action button from a cold start is
  the main use case. With `home == nil`, `launchIntentReceived` stores the intent in
  `State.pendingLaunchIntent` and returns. The stash survives onboarding and the retry screen;
  every `landOnHome` caller (auto-connect success, the retry screen's connect, onboarding's
  connect) replays it through `reduceCreateSession` (an `.openSession` through the push-tap
  routing, below). The replay seats the chat itself, so `landOnHome` skips its regular-width
  detail fill for that landing.
- **Only the launch auto-connect landing keeps the launch action**
  (`landOnHome(replaysLaunchAction:)`). The retry screen re-probes on every foreground and a
  manual login can come much later, so those landings replay a stashed dictation, camera or
  photos intent as a plain new chat: the mic or a picker never opens hours after the request.
- **Last-wins across both stashes.** Stashing an intent clears `pendingPushTap`; stashing a
  push tap clears `pendingLaunchIntent`. `landOnHome` replays only the most recent request.
  Approval badge entries are inserted independently and stay, but the tap's server URL is
  kept, so a login to a different server still scrubs them (the #46 cross-server guard).
- **No server-origin guard for a new chat.** Unlike a push tap, a new chat belongs to no
  session, so it is valid on whatever server the user signs into.
- **`.openSession` does carry its origin.** It names a session on one server, so stashing it
  records `pendingLaunchIntentServerURL` (the persisted server URL at stash time), and
  `landOnHome` drops it on a login to a different server, the same guard as
  `pendingPushTapServerURL`. A push tap superseding the stash clears it too.
- **Cleared on every logout path**, at each site that clears `pendingPushTap`: Settings → Sign
  out, the retry screen's Log Out, the re-auth sheet's "Quit to start", and a different-user
  re-auth. The stash is process-lifetime only (never persisted).

## Routing `.openSession`

With `home` set, `.openSession(id:profile:)` dismisses list presentations, then runs
`reduceOpenSessionRouting`, the body a push tap also runs, so the #32 rules can't drift: on
screen → in place; a detached compact slot → re-attach; otherwise replace the slot, never
stack. Approval bookkeeping and the cross-profile rule: `docs/features/widgets.md`.

## Routing: the exact "New session" path

Every other case runs `reduceCreateSession(_:composerText:launchAction:)`, the
body the list's "New session" button (`.home(.delegate(.createSession))`) also calls, so the
two can never drift. That gives, unchanged:

- selected-profile scoping (`newChat(for: home)`, #114);
- the reusable-seat shortcut (`isReusableNewChat`): a slot the list would rebuild identically
  is reset in place (draft text and staged attachments cleared) instead of being torn down and
  redialed, and a detached compact seat gets its marker back;
- compact vs regular (#80): a single new `ChatScreen` marker in compact; the detail fill (with
  its `slotGeneration` bump) and an empty path in regular;
- slot replacement through `teardownSlot(thenFill:)`, never stacking.

Two things differ from the button, because an intent can arrive at any moment:

- **List presentations are dismissed first** (`SessionListFeature.State.dismissPresentations`:
  Settings, Archived, Add Profile, the action sheet, the push-setup sheet, the rename alerts),
  so the new chat isn't seated behind a sheet.
- **Behind the re-auth modal** the chat still seats (it resumes with the re-auth), but the
  launch action is dropped: no recording or picker the user can't see.

**Busy-slot policy: silent replace.** A slot with a running turn or `hasQueuedWork` is replaced
without a prompt, exactly as the "New session" button and a push tap to a different session
replace it. The running turn continues on the server, keeps its working glow in the list and
is reachable from there; the client-side queue (#66) goes with the slot, as it does for the
button.

## Launch actions: a one-shot, consumed at first start

An intent's `launchAction` (`.dictation`, `.camera`, `.photos`) becomes
`ChatFeature.State.pendingLaunchAction: LaunchAction?` (per slot, unpersisted) on the chat it
seats. `consumePendingLaunchAction` always clears it and hands it to `runLaunchAction`:
`.dictation` starts the mic only when `recording == .idle`; `.camera` and `.photos` run the
composer buttons' own `capturePhoto()` / `pickPhotos()` effect builders (shared, not a
`.send` of the tap actions), so a cancelled picker is the same silent empty batch.

- **New chat**: at the slot's first `.task` (the `hasStarted` branch, merged with `connect`).
  In compact that is the chat view's `.task`. In regular it is the reducer's `.fillLiveChat`
  dial (`.liveChat(.task)`) when the intent replaced an occupied slot, otherwise the
  `.id(slotGeneration)`-keyed detail view's `.task`. A re-appearance never re-fires
  (`hasStarted`).
- **Reused seat**: that slot has already started, so `reduceCreateSession` sends
  `.liveChat(.startLaunchAction(_))` (no pending field), which goes through the same
  `runLaunchAction`. The action exists only so the parent can reach a started slot; the view
  never sends it.

Consequences, all deliberate (an "arm on `.ready`" design could fire minutes later after a
backoff reconnect and toggle the user's own recording off):

- It never waits for the socket. Transcription is REST (`POST /api/audio/transcribe`) and
  neither the mic nor the attach buttons are gated on connection state, so there is nothing
  to wait for, and an action that waited could fire after the user has started typing.
- Dictation never toggles: a recording, pending permission or transcription already in
  progress just clears the action.
- **It goes through the normal permission flow.** Both the mic button's `.voiceButtonTapped`
  idle leg and the consume call one shared `startVoiceRecording` helper (not a
  `.send(.voiceButtonTapped)`), so the read-aloud barge-in order (`await tts.stop()` BEFORE
  `requestPermission`, `docs/features/read-aloud.md`) can't drift. A first run shows the system
  mic prompt and then records; a denial lands on `.recordingPermission(false)` and shows the
  existing mic banner with `recording == .idle`.

## Demo mode

`DemoMode` sets `launchIntents.incoming` to a never-emitting stream: an intent fired during a
screenshot capture still opens the app, but never swaps the curated chat for a new one.

## Home Screen quick actions

App Shortcuts never appear in the Home Screen icon's long-press menu (checked on device), so
the same two entry points are also quick actions: "New Chat" (`plus.message`) and "Dictate"
(`mic.badge.plus`).

**Shown only while signed in.** They are dynamic `UIApplication.shortcutItems`, not static
Info.plist entries (those can't be hidden). `QuickActionsClient.setItems` sets them, and
`AppFeature` drives it from one `.onChange(of: \.offersQuickActions)` edge:
`rootScreen != .onboarding`, so the launch probe, the retry screen and home offer them, and
every logout path and a credentials verdict hide them. iOS persists the items across
launches, so they stay on the icon while the app is killed. The cost: a fresh install shows
none until the first sign-in. `LaunchIntent` owns the type, title and symbol of each action
(`quickActions`, `shortcutItemType`, `init?(shortcutItemType:)`), so the literals live in one
place. Like `IdleTimerClient`, the client call is synchronous so the main-queue hops keep
reduction order.

The app is scene-based (SwiftUI `App`), so UIKit delivers a quick-action tap to the scene
delegate only. `PushAppDelegate.application(_:configurationForConnecting:options:)` attaches
`QuickActionSceneDelegate` (`HermesMobile/Sources/Intents/`); SwiftUI still owns the window.
It reads `connectionOptions.shortcutItem` on a cold launch and handles
`windowScene(_:performActionFor:)` while the app runs. Both hand the mapped intent to
`LaunchIntentBridge.shared.received(_:)`, so everything above (buffering, stash, replay,
dictation) applies unchanged.
