# App Intents — launch a new session from Quick Actions, Shortcuts, and the Action button (#93)

Normative invariants for the App-Intents feature. Architecture mirrors push notifications
(`docs/features/push-notifications.md`): the app target feeds a process-wide bridge
(`IntentBridge`, HermesKit) and `AppFeature` routes the request through the reducer, so all
decisions are `TestStore`-tested and the app target carries no logic.

## The intents

| Intent | What it does |
|---|---|
| `StartNewSessionIntent` ("New Hermes chat") | Open the app on a fresh chat under the selected profile |
| `StartNewSessionWithDictationIntent` ("Dictate to Hermes") | Same, then immediately start voice input (mic → transcribe into the composer) |

Both are `openAppWhenRun` and **only route** — no agent logic runs from the intent
(thin-client rule: the socket only lives in the foreground). `AppShortcutsProvider`
declares Shortcuts/Siri/Spotlight phrases. Home Screen icon Quick Actions are a separate
UIKit surface: static `UIApplicationShortcutItems` in `Project.swift` route through the
app delegate into the same `IntentBridge`.

## The pipeline

`AppIntent.perform()` **or** the Home Screen Quick Action delegate →
`IntentBridge.shared.received(intent)` → `IntentClient.incomingIntents()` stream →
`AppFeature.launchIntentReceived`:

- **Not signed in / retry screen** (`home == nil`) → the intent is stashed in
  `AppFeature.State.pendingLaunchIntent` (single stash, last-wins, process-lifetime,
  cleared on logout) and replayed through `.launchIntentReceived` when `home` is created
  (`.autoConnectSucceeded`, the manual-login and retry-screen `.connected` delegates) —
  mirroring the cold-launch push-tap stash (#46). No cross-server guard: an intent can
  only originate from this device's UI surface (no foreign-server identity to verify).
  If a deferred push route also exists, the explicit local intent wins deterministically;
  the push navigation is dropped while any approval badge remains available to the user.
- **Signed in** → the existing `.home(.delegate(.createSession))` path (slot replacement
  included — an intent fired while an idle chat is open REPLACES it, never stacks, same
  rule as push taps). If the live slot is running or has queued work, the app first asks
  the user to confirm replacement; it never silently discards that work. The dictation
  variant arms `ChatFeature.State.pendingInitialVoiceAction`.
- **Not signed in and the user never logs in** → the stash dies with the process; nothing
  persists across launches.

## The armed dictation (`pendingInitialVoiceAction`)

- Set by `AppFeature` on `createSession(initialVoiceAction:)`, consumed by `ChatFeature`
  via `.onChange(of: status)` the first time the slot reaches `.ready` — a recording never
  fires into a still-bootstrapping chat, and a later reconnect's `.ready` can't re-arm it
  (consumed on first fire).
- Transient and unpersisted — a snapshot repaint must never re-arm it.
- A denied mic permission surfaces the app's existing banner via the normal
  `recordingPermission` flow; the intent itself never fails.
- Every live-chat slot carries a monotonic generation copied into its navigation marker.
  A delayed `onDisappear` from the replaced destination is ignored when its generation no
  longer owns the slot, so it cannot cancel recording in the dictation-armed replacement.

## Conventions (mirroring push)

- The `LaunchIntent`/`InitialVoiceAction` types live in HermesKit; the `AppIntent` structs
  live in the app target (`HermesMobile/Sources/Intents/`, needs `tuist generate`) because
  App Intents is iOS-only and HermesKit must stay macOS-testable.
- `IntentBridge` is Foundation-only (`NSLock` + `AsyncStream`), so its consume-once
  cold-launch buffer is unit-tested on macOS (`swift test`) — same pattern as
  `PushBridge` (#46).
- The push and launch-intent stream observers are installed once per app state lifetime.
  A repeated root `.task` never cancels/replaces a stream after its bridge has accepted an
  event but before the reducer has consumed it.
- The voice-conversation intent (`StartVoiceConversationIntent`) joins with #92, which
  depends on #74 (TTS playback of replies).

## Out of scope

Intents that send a prompt without opening the app, or Siri answering from the agent —
the app is a thin client and the socket only lives in the foreground.