# App Intents: start a new chat (plain / with dictation) from outside the app (#93)

## Overview
- Two App Intents that open the app on a fresh chat under the selected profile:
  `StartNewSessionIntent` ("New Hermes chat") and `StartNewSessionWithDictationIntent`
  ("Dictate to Hermes", which starts the mic as soon as the chat opens).
- Surfaces: Shortcuts, Siri, Spotlight, the Action button (iPhone 15 Pro and later) and, if
  iOS shows App Shortcuts there, the Home Screen icon long-press menu. All of them come from one
  `AppShortcutsProvider`.
- Thin client: both intents are `openAppWhenRun = true` and only route. No agent logic runs in
  the intent.
- Kept deliberately small. This is a fresh implementation on current `main`. Closed PR #95
  (`netera-michael/feat/app-intents`, based on 2026-09-09 main) is reference only. Its
  `reduceCore` extraction, `slotGeneration` ownership change and push-observer change stay out.

## Context (from discovery)
- Cold-launch push-tap replay (#46) is the model:
  - `PushBridge`: consume-once buffer plus live fan-out
    (`HermesKit/Sources/HermesKit/Clients/PushClient.swift:261`).
  - `AppFeature.task`: the observer (`AppFeature.swift:310`).
  - `reducePushTapped`: the stash when `home == nil` (`AppFeature.swift:988`).
  - `landOnHome`: the replay (`AppFeature.swift:1174`).
  - The stash is cleared on logout (`AppFeature.swift` at the `logoutConfirmed`,
    `.disconnect` and reauth `.quit` cases).
- "New session" is `.home(.delegate(.createSession(initialComposerText:)))`
  (`AppFeature.swift:578`):
  - A slot `isReusableNewChat` would rebuild identically is reused: reset the draft, re-push the
    marker if detached.
  - Otherwise `newChat(for: home)` is built, seated or swapped in with `teardownSlot(thenFill:)`.
  - Profile scoping and the compact/regular split are already handled there.
- Voice input: `ChatFeature.voiceButtonTapped` toggles on `recording`
  (`ChatFeature.swift:2223`):
  - `.idle` → `requestingPermission` → `recordingPermission`. A denial sets the existing banner.
  - Transcription is REST (`/api/audio/transcribe`), not the socket, and the mic button is not
    gated on connection state. So dictation does NOT need to wait for `.ready`.
- `ChatFeature.task` (`ChatFeature.swift:1485`): the slot's first-start branch
  (`hasStarted` guard). In compact it fires from the chat view's `.task`; in regular it comes
  from `.fillLiveChat`.
- No App Intents code exists yet, so the app target needs `tuist generate` after adding files.

## Development Approach
- **testing approach**: Regular (code first, then tests)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change: `make test` (or `script -q /dev/null swift test --package-path HermesKit`)
- maintain backward compatibility

## Testing Strategy
- **unit tests**: `TestStore` reducer tests in HermesKit (AppFeature routing, ChatFeature
  dictation consume) plus a plain test for the bridge's buffering.
- **snapshot tests**: none. There is no view change.
- The intent structs in the app target are declarations only and are verified on device.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

### Decisions
1. **Routing reuses the "New session" path exactly.** An intent becomes the same
   `createSession` handling the list's "New session" button runs. This gives:
   - selected-profile scoping
   - the reusable-seat shortcut
   - compact marker vs regular detail
   - slot replacement through `teardownSlot(thenFill:)`

   A busy slot (running turn, or `hasQueuedWork`) is replaced silently. That matches push taps
   and the "New session" button (the PR #95 review asked for the two policies to match). The
   running turn continues on the server and stays reachable from the list.
2. **Stash before sign-in, never drop.** On a cold launch `home` doesn't exist until the
   auto-connect probe finishes, so dropping would break the main use case (Action button from a
   cold start). Stash rules:
   - One optional `pendingLaunchIntent`, last-wins, replayed in `landOnHome`, cleared on every
     logout path.
   - No server-origin guard: a new chat belongs to no session, so it is valid on whatever server
     the user signs into.
   - Last-wins across both stashes: stashing an intent clears `pendingPushTap` and vice versa,
     so `landOnHome` replays only the most recent request. Approval badge entries are unaffected
     (they're inserted independently).
3. **Dictation is a one-shot flag on the new chat, consumed when the slot first starts.** This
   replaces PR #95's "arm on `.ready`" and so removes both bugs the review found there: the
   toggle stopping the user's own recording, and the arm never expiring.
   - The flag is consumed immediately, at the slot's first `.task` (or right away on the
     reused-seat path), not on a later `.ready`. So it can't fire minutes later after a backoff
     reconnect, or after the user starts typing.
   - It only starts recording when `recording == .idle`, so it never toggles an existing
     recording off.
   - It goes through the normal `voiceButtonTapped` → permission flow. A denial shows the
     existing banner.
4. **No static Quick Actions, no scene delegate.** The app is scene-based, so
   `UIApplicationShortcutItems` would need a scene delegate (the PR #95 review's bug 1).
   App Shortcuts may cover the long-press menu on iOS 17+. That gets verified on device (see
   Post-Completion), and static items become a follow-up only if they don't.
5. **Phrases**: only explicit ones. "New \(.applicationName) chat" / "Start a chat in
   \(.applicationName)" and "Dictate to \(.applicationName)". There is no
   "Open \(.applicationName)" mapping to a new chat. Both intents use one `categoryName`
   ("Chats").

### Flow
`AppIntent.perform()` → `LaunchIntentBridge.shared.received(intent)` →
`LaunchIntentClient.incoming()` stream (observed in `AppFeature.task` next to the push-tap
observer) → `AppFeature.launchIntentReceived(intent)`:
- `home == nil` → stash it (clearing `pendingPushTap`) and return.
- otherwise → run the `createSession` body with `startsDictation: intent == .newChatWithDictation`.

## Technical Details
- `LaunchIntent` (HermesKit `Models/`): `enum LaunchIntent: Equatable, Sendable { case newChat,
  newChatWithDictation }`. #92 adds the voice-conversation case later.
- `LaunchIntentBridge` (HermesKit, Foundation only, outside any UIKit guard):
  - `NSLock`, live continuations keyed by UUID and pruned `onTermination`.
  - `pendingIntent` is buffered only when no live subscriber accepted the intent (check each
    yield's result as `PushBridge.tapReceived` does) and drained once by the first subscriber.
  - Same shape as `PushBridge`'s tap half. It is duplicated rather than abstracted, since about
    40 lines don't justify a shared generic.
- `LaunchIntentClient` (`@DependencyClient`):
  - `incoming: @Sendable () -> AsyncStream<LaunchIntent>`.
  - `liveValue` wraps `LaunchIntentBridge.shared`.
  - `testValue` is a finished stream. A test helper yields intents live.
- `AppFeature.State.pendingLaunchIntent: LaunchIntent?`.
- New action `launchIntentReceived(LaunchIntent)`.
- `CancelID.launchIntents` observer, merged with `tapObserver` in every return path of `.task`
  (same `cancelInFlight` restart as the push observer, unchanged).
- The `createSession` case body is extracted to
  `reduceCreateSession(&state, composerText:, startsDictation:)`, called by both the delegate
  case and the intent.
- `ChatFeature.State.pendingDictation: Bool` (default `false`, not persisted).
- New action `startPendingDictation`:
  - clear the flag
  - return `.none` unless `recording == .idle`
  - otherwise `.send(.voiceButtonTapped)`
  - It is sent from the `.task` first-start branch (merged with `connect`) when the flag is set,
    and from `reduceCreateSession`'s reused-seat branch.

## What Goes Where
- **Implementation Steps**: HermesKit model/bridge/client, reducer routing, intents in the app
  target, docs.
- **Post-Completion**: on-device verification of each surface.

## Implementation Steps

### Task 1: Add `LaunchIntent`, `LaunchIntentBridge` and `LaunchIntentClient`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/LaunchIntent.swift`
- Create: `HermesKit/Sources/HermesKit/Clients/LaunchIntentClient.swift` (client + bridge)
- Create: `HermesKit/Tests/HermesKitTests/LaunchIntentClientTests.swift`

- [x] add the `LaunchIntent` enum (`newChat`, `newChatWithDictation`)
- [x] add `LaunchIntentBridge` with `shared`, internal `init()` for tests, `received(_:)` and
      `stream()`. It has a consume-once buffer for the launch race, live fan-out, and pruning on
      termination, mirroring `PushBridge`'s tap half
- [x] add the `LaunchIntentClient` `@DependencyClient` with `liveValue` over the bridge, a finished
      `testValue`, and a live-yield test double
- [x] write tests:
  - an intent received before any subscriber is delivered to the first subscriber only
  - a live subscriber receives it and nothing is buffered
  - an intent sent after a subscriber terminated is buffered again
- [x] run tests, which must pass before Task 2

### Task 2: Route intents in `AppFeature` (stash, replay, new chat)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] add `pendingLaunchIntent`, the `launchIntentReceived` action, and the `launchIntents`
      observer merged with `tapObserver` on every `.task` return path
- [x] extract the `createSession` body into `reduceCreateSession(_:composerText:startsDictation:)`.
      The delegate case calls it with `startsDictation: false` and behaves identically
- [x] `launchIntentReceived`: when `home == nil`, stash it and clear `pendingPushTap` (plus its
      server URL); otherwise call `reduceCreateSession`
- [x] in `reducePushTapped`'s stash branch, clear `pendingLaunchIntent` (last-wins). In
      `landOnHome`, replay a stashed intent via `.send(.launchIntentReceived(_))`. Clear
      `pendingLaunchIntent` at every site that clears `pendingPushTap` on logout
- [x] write tests:
  - intent with `home` set, compact: the slot is seated and the path is a single new marker
  - intent with `home` set, regular: the detail is filled and the path stays empty
  - intent over an occupied slot: the slot is replaced via teardown, never stacked
  - intent over a reusable new-chat seat: the seat is reused with no redial
- [x] write tests:
  - pre-home intent is stashed, then replayed when `home` lands
  - logout clears the stash
  - intent then push tap pre-home → only the tap replays
  - push tap then intent → only the intent replays
- [x] run tests, which must pass before Task 3

### Task 3: Start dictation once on the new chat

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] add `ChatFeature.State.pendingDictation` and the `startPendingDictation` action (clear the
      flag; `.send(.voiceButtonTapped)` only when `recording == .idle`)
      (implemented as a shared `startVoiceRecording` helper used by both `voiceButtonTapped`
      and `consumePendingDictation`, instead of sending an action to share logic)
- [x] the `.task` first-start branch merges `.send(.startPendingDictation)` with `connect` when
      the flag is set. It is not sent on re-appearance (the `hasStarted` guard)
      (calls `consumePendingDictation` directly rather than sending the action)
- [x] `reduceCreateSession(startsDictation: true)`:
  - sets the flag on the new chat
  - on the reused-seat branch, sets it and sends `.liveChat(.startPendingDictation)`
- [x] write ChatFeature tests:
  - `.task` with the flag → `requestingPermission` → granted → recording starts
  - denied → the existing mic banner and `recording == .idle`
  - flag set while `recording != .idle` → the flag is cleared and recording is NOT toggled
  - a second `.task` doesn't re-fire
- [x] write AppFeature tests:
  - `.newChatWithDictation` seats a chat with `pendingDictation == true`
  - over a reusable seat it sends `startPendingDictation`
- [x] run tests, which must pass before Task 4

### Task 4: Declare the App Intents and App Shortcuts in the app target

**Files:**
- Create: `HermesMobile/Sources/Intents/LaunchIntents.swift`
- Create: `HermesMobile/Sources/Intents/HermesAppShortcuts.swift`

- [x] add `StartNewSessionIntent` and `StartNewSessionWithDictationIntent`:
  - `openAppWhenRun = true`
  - one `categoryName` ("Chats")
  - `perform()` only calls `LaunchIntentBridge.shared.received(_)`
- [x] add the `HermesAppShortcuts: AppShortcutsProvider` with explicit phrases only (see
      Decisions §5), `shortTitle` and an SF Symbol per shortcut
- [x] check `DemoMode.swift`: an intent in demo mode must not crash (either the demo store
      ignores the stream, or routing works against the demo home)
      (the demo store ignores the stream: `launchIntents.incoming` is a never-emitting stream,
      so a capture's curated chat is never swapped)
- [x] `tuist generate`, then build the app target for the simulator (`xcodebuild … build`)
- [x] run `make test` and `make snapshot`; both must stay green (no new tests, since this task
      only declares intents)
      (⚠️ 3 attachment snapshots failed identically on a clean HEAD worktree: pre-existing
      runtime drift at equal render size, re-recorded in their own commit; suite is 331/331)

### Task 5: Verify acceptance criteria
- [x] both intents route to a fresh chat under the selected profile, in compact and regular
- [x] cold launch from an intent lands on the new chat once auto-connect finishes. A launch that
      ends on onboarding or the retry screen holds the intent until `home` exists
      (➕ added the two missing tests: held through the retry screen, held through the
      onboarding fallback)
- [x] dictation starts only from idle, and a denied permission shows the existing banner
- [x] nothing outside scope changed: no `reduceCore`, no `slotGeneration` change, push observer
      untouched
- [x] run the full suite: `make test` and `make snapshot`

### Task 6: [Final] Update documentation
- [ ] create `docs/features/app-intents.md`: intents, phrases, bridge/stash/replay, the
      dictation one-shot rule, the busy-slot policy, why there are no static Quick Actions
- [ ] add a short CLAUDE.md bullet (rule + pointer, ≤5 lines) and a README feature-list line
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems*

**Manual verification (device, iOS 18 and 26):**
- Shortcuts app: both shortcuts are listed without setup. Run each warm and from a killed app.
- Siri: "New Hermes chat" and "Dictate to Hermes".
- Spotlight: typing "Hermes" shows both shortcuts.
- Action button (iPhone 15 Pro or later): assign the dictation shortcut. The mic starts on a
  fresh chat, and a first-run mic prompt appears and then records.
- Home Screen long-press: check whether the App Shortcuts appear. If they don't, open a
  follow-up for static `UIApplicationShortcutItems`, which needs a scene delegate
  (`application(_:configurationForConnecting:)` → `windowScene(_:performActionFor:)` and
  `connectionOptions.shortcutItem`).
- Busy slot: start a long turn, fire the intent, and confirm the new chat opens. The old session
  shows its working glow in the list and continues when reopened.
