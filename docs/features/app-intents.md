# App Intents: new chat from outside the app (#93)

The short rule lives in `CLAUDE.md` → "Push notifications" (next to the push-tap routing it
mirrors); this doc is the full contract. Design history: `docs/plans/completed/`
(`20261106-app-intents-new-chat.md`).

Two App Intents open the app on a fresh chat under the selected profile, from Shortcuts, Siri,
Spotlight and the Action button (iPhone 15 Pro and later). The app is a thin client here too:
both intents are `openAppWhenRun = true` and only ROUTE. No agent logic runs in the intent.

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
  `AppShortcutsProvider`, so every surface works without user setup.
- **Explicit phrases only.** There is deliberately no "Open \(.applicationName)" phrase mapped
  to a new chat (opening the app should just open it), and no "Talk to \(.applicationName)":
  that phrase is reserved for the voice-conversation intent (#92), which will add a third
  `LaunchIntent` case.

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
  shared bridge, `testValue` is a finished stream, and `.inMemory()` yields live only (no
  buffering, like `PushClient.InMemory`); put a real bridge behind the client to test the
  buffer.
- **The observer** (`CancelID.launchIntents`, `cancelInFlight`) is merged with the push-tap
  observer on every return path of `.task`. The push observer itself is unchanged.
- **Stash before sign-in, never drop.** On a cold launch `home` doesn't exist until the
  auto-connect probe (or a manual login) finishes, and the Action button from a cold start is
  the main use case. With `home == nil`, `launchIntentReceived` stores the intent in
  `State.pendingLaunchIntent` and returns. The stash survives onboarding and the retry screen;
  every `landOnHome` caller (auto-connect success, the retry screen's connect, onboarding's
  connect) replays it via `.send(.launchIntentReceived(_))`. The replay seats the chat itself,
  so `landOnHome` skips its regular-width detail fill for that landing.
- **Last-wins across both stashes.** Stashing an intent clears `pendingPushTap` (and its server
  URL); stashing a push tap clears `pendingLaunchIntent`. `landOnHome` replays only the most
  recent request. Approval badge entries are inserted independently and stay.
- **No server-origin guard.** Unlike a push tap, a new chat belongs to no session, so it is
  valid on whatever server the user signs into.
- **Cleared on every logout path**, at each site that clears `pendingPushTap`: Settings → Sign
  out, the retry screen's Log Out, the re-auth sheet's "Quit to start", and a different-user
  re-auth. The stash is process-lifetime only (never persisted).

## Routing: the exact "New session" path

With `home` set, the intent runs `reduceCreateSession(_:composerText:startsDictation:)`, the
body the list's "New session" button (`.home(.delegate(.createSession))`) also calls, so the
two can never drift. That gives, unchanged:

- selected-profile scoping (`newChat(for: home)`, #114);
- the reusable-seat shortcut (`isReusableNewChat`): a slot the list would rebuild identically
  is reset in place (draft text and staged attachments cleared) instead of being torn down and
  redialed, and a detached compact seat gets its marker back;
- compact vs regular (#80): a single new `ChatScreen` marker in compact; the detail fill (with
  its `slotGeneration` bump) and an empty path in regular;
- slot replacement through `teardownSlot(thenFill:)`, never stacking.

**Busy-slot policy: silent replace.** A slot with a running turn or `hasQueuedWork` is replaced
without a prompt, exactly as the "New session" button and a push tap to a different session
replace it (the PR #95 review asked for the policies to match). The running turn continues on
the server, keeps its working glow in the list and is reachable from there; the client-side
queue (#66) goes with the slot, as it does for the button.

## Dictation: a one-shot, consumed at first start

`.newChatWithDictation` sets `ChatFeature.State.pendingDictation` (per slot, unpersisted) on
the chat it seats. The flag is consumed by `consumePendingDictation`, which always clears it
and starts the mic only when it was set AND `recording == .idle`:

- **New chat**: at the slot's first `.task` (the `hasStarted` branch, merged with `connect`).
  In compact that is the chat view's `.task`; in regular the `.id(slotGeneration)`-keyed detail
  view sends `.task` on appear. A re-appearance never re-fires (`hasStarted`).
- **Reused seat**: that slot has already started, so `reduceCreateSession` sets the flag and
  sends `.liveChat(.startPendingDictation)` right away. The action exists only so the parent can
  reach a started slot; the view never sends it.

Consequences, all deliberate (they replace PR #95's "arm on `.ready`", which could fire minutes
later after a backoff reconnect and toggled the user's own recording off):

- It never waits for the socket. Transcription is REST (`POST /api/audio/transcribe`) and the
  mic button is not gated on connection state, so there is nothing to wait for, and a flag
  that waited could fire after the user has started typing.
- It never toggles: a recording, pending permission or transcription already in progress just
  clears the flag.
- **It goes through the normal permission flow.** Both the mic button's `.voiceButtonTapped`
  idle leg and the consume call one shared `startVoiceRecording` helper (not a
  `.send(.voiceButtonTapped)`), so the read-aloud barge-in order (`await tts.stop()` BEFORE
  `requestPermission`, `docs/features/read-aloud.md`) can't drift. A first run shows the system
  mic prompt and then records; a denial lands on `.recordingPermission(false)` and shows the
  existing mic banner with `recording == .idle`.

## Demo mode

`DemoMode` sets `launchIntents.incoming` to a never-emitting stream: an intent fired during a
screenshot capture still opens the app, but never swaps the curated chat for a new one.

## No static Quick Actions, no scene delegate

The app is scene-based (SwiftUI `App`). Static `UIApplicationShortcutItems` would need a scene
delegate (`application(_:configurationForConnecting:)` → `windowScene(_:performActionFor:)`,
plus `connectionOptions.shortcutItem` for a cold launch), which was PR #95's first review bug.
App Shortcuts may already appear in the Home Screen icon's long-press menu on iOS 17+. **Verify
that on device**; static items become a follow-up only if the App Shortcuts are absent there.

## Tests

- `LaunchIntentClientTests`: the bridge's buffer (pre-subscribe delivery to the first subscriber
  only, last-wins, no buffering on live delivery, fan-out, re-buffer after a subscriber
  terminates) and the finished `testValue`.
- `AppFeatureTests`: compact marker, regular fill, profile scoping, busy-slot replace, reusable
  seat (no redial), pre-home stash replayed after auto-connect, the retry screen and the
  onboarding fallback, logout clears, intent/tap last-wins both ways, dictation flag on a new
  chat and `startPendingDictation` on a reused seat.
- `ChatReductionTests`: first `.task` with the flag → permission → recording, no re-fire on a
  second `.task`, denial banner, no toggle while recording, `startPendingDictation` consumes
  once.

The intent structs are declarations only (no tests); App Intents metadata extraction lists both.

## Device checks still open

- Shortcuts lists both shortcuts with no setup; each runs warm and from a killed app.
- Siri: "New Hermes chat" and "Dictate to Hermes". Spotlight: "Hermes" shows both.
- Action button: the dictation shortcut starts the mic on a fresh chat, including the first-run
  mic prompt.
- Home Screen long-press: whether the App Shortcuts appear (see above).
- Busy slot: fire an intent during a long turn; the new chat opens, the old session glows in
  the list and continues when reopened.
