# Read replies aloud — TTS playback of agent replies (issue #74)

## Overview

Voice on mobile is input-only today (mic → `POST /api/audio/transcribe`). Reddit feedback
(and a second request since) asks for the desktop's **"Read replies aloud"**: an auto-speak
toggle that reads every completed assistant reply, plus a per-message **Read aloud** action.
This is also the backbone for the later voice-conversation ticket.

This plan ships the desktop feature with parity wherever the phone allows it:

- **The toggle is a device-local preference (`PreferencesClient`), default off — NOT the
  server's `voice.auto_tts`** (refreshed 2026-10-27; confirmed by the user 2026-10-27). The plan was
  written when the desktop mirrored `voice.auto_tts` over `GET`/`PUT /api/config`; upstream
  `938a3dc8f9` ("keep read-aloud independent of gateway auto-TTS", Fixes #99076, first release
  v0.21.6) moved the desktop toggle to localStorage because `voice.auto_tts` is the messaging
  gateway's voice-reply default and flipping one flipped the other — exactly the coupling this
  plan had "accepted". Desktop seeds its local value once from `voice.auto_tts` (a migration of
  its own legacy state); mobile has no legacy state, so it does not seed and never touches
  `/api/config`. Alternatives if the user disagrees: (A1) local + the desktop's one-time seed
  from `GET /api/config` `voice.auto_tts`; (B) the original server-key design (GET + deep-merge
  `PUT /api/config {config: {voice: {auto_tts}}}`, optimistic flip, revert + "Couldn’t save the
  setting." banner on failure).
- **Synthesis = `POST /api/audio/speak` only** (the last rung of the desktop ladder; desktop now
  tries client-direct → `speak-stream` WS → `speak`). The PCM `speak-stream` socket lands with
  the voice-conversation ticket; the client-direct rung (provider API keys shipped to the phone)
  is skipped on purpose.
- **Playback = one app-wide `AVAudioPlayer` clip**, `.playback` category (plays through the
  silent switch — the user explicitly asked for spoken content), **stops on backgrounding**
  (no background-audio entitlement; the ~30 s background grace keeps the process running for
  a running turn, so the stop must be explicit), 15 s stall watchdog, "Reading aloud" pill with
  Stop, a new user submit silences playback and attaches `interrupted: true`.
- **Past turn boundaries are never spoken**: a `message.complete` folded by the #98 reconnect
  replay does not auto-speak, and its trailing hydrate consumes the reply (see Solution
  Overview → "Replay rule").
- **Keep the screen awake** (`UIApplication.isIdleTimerDisabled`) during the hands-off loop:
  while a clip is preparing/playing, while a turn runs with auto-speak on, or while the mic
  records — but only while the chat is on screen.
- **Capability-gated by failure** (TTS is still not advertised in `/api/status`, the
  `gateway.ready` payload or `client.capabilities`): the first missing-endpoint verdict from
  `speak` (`RESTError.isMissingEndpointVerdict` — 404, or the 405 an older agent's GET-only SPA
  catch-all answers to a POST) flips `ttsSupported` off and hides both controls; a 400 carries
  the server's human-readable detail ("no TTS provider configured", …) into the error banner.

Out of scope (decided in the brainstorm, YAGNI): `speak-stream` WS, client-direct
synthesis, `tts-lease` warm-up (swallowed fire-and-forget on desktop; only matters for
local engines), a Settings → Voice mirror of the toggle, a playback waveform in the pill,
`source: voiceConversation` on the playback state, lock-screen controls / background audio,
the desktop's multi-window turn claims (`claimSpeech`/`ownsAmbientCue` — one slot on mobile),
Shift-click "read the full response group" (#118864; no modifier on touch).

## Context (from discovery)

Verified against upstream Hermes `upstream/main` @ `69f73ec5f1` (2026-10-27; plan originally
written against `22c5684b98`, 2026-09-07) — read via
`git -C /Users/eugene/Documents/Development/Personal/hermes-agent show upstream/main:<path>`.

**Server requirement / release notes.** Upstream tags are now `v0.2x.y` (latest stable
`v0.22.5`, 2026-10-22; nightly `v0.22.5+canary.*`) after the dated `v2026.M.D` line (last
`v2026.9.24`).
- `POST /api/audio/speak` — since **v2026.6.5** (shipped with the desktop app, `51c68d4ab1`);
  handler byte-identical since the plan was written. Older agents degrade through the
  missing-endpoint gate (they answer **405**: the pre-desktop web server's
  `@app.get("/{full_path:path}")` SPA catch-all matches the path for GET only).
- `interrupted` on `prompt.submit` — since **v2026.7.30** (`05b3637d8b`); part of the
  `PromptSubmitParams` contract (`tui_gateway/contracts/prompt_voice.py:34`) since contract
  validation (`extra="forbid"`) arrived 2026-09-14, so no validated agent rejects it, and
  older agents read params with `dict.get` (unknown keys ignored).
- `voice.auto_tts` default `false` — since v2026.3.17; `PUT /api/config` deep-merge since
  v2026.7.1. Only relevant to alternatives A1/B above.
- Desktop toggle device-local — since **v0.21.6** (2026-10-08).
- Effective minimum for the feature: **v2026.6.5**; anything older hides both controls.

**Server (`hermes_cli/web_routers/audio.py` ~:295, model `TTSSpeakRequest` in
`hermes_cli/web_models.py` ~:244):**
- `POST /api/audio/speak?profile=` body `{"text"}` (only field) → `{ok: true, data_url:
  "data:<mime>;base64,…", mime_type, provider}`. Mime by generated extension
  (`_SPEAK_MIME_BY_EXT` ~:53): `.mp3` → `audio/mpeg` (default), `.ogg`/`.opus` → `audio/ogg`,
  `.wav` → `audio/wav`, `.flac` → `audio/flac`. Errors all via HTTP status (a success body is
  never `ok: false`): **400** empty text ("Text is required") / bad profile / provider
  failed-or-missing / "Text is empty after TTS cleanup" (`detail` = provider error text), **404**
  unknown profile (`_config_profile_scope`) and, on agents without the route, 404/405 (above),
  **500** synthesis raised / "Invalid TTS response" / "Audio file missing" / "Could not read
  audio". No 503. Blocking; the server itself normalizes text (`tools/tts_text_normalize.py`
  `prepare_spoken_text`) and chunks long text. Desktop timeout `max(180 s, 35 ms × chars)` capped
  at 600 s (`apps/desktop/src/api/system.ts:28-38`, unchanged).
- `GET /api/config` (`hermes_cli/web_routers/config_env.py` ~:80, now with
  `include_defaults`) / `PUT /api/config` (~:117, `?profile=` or body `profile`, deep-merge) —
  no longer used by this plan (alternatives A1/B only).
- Auth: same `RequestAuth` as every other REST call (token header / cookie / bearer).

**Desktop rules ported (`apps/desktop/src/…`):**
- `app/chat/composer/hooks/use-auto-speak-replies.ts` — only completed replies; mark the
  current last reply spoken on toggle-on and on chat open (`sessionId` change); never overlap
  (wait for the playback-idle edge); backlog collapses to the newest; never while a voice
  conversation is active. New since the plan: per-turn cross-window claims (N/A) and a failed
  or never-started play *releases* the mark (`releaseUnplayedSpokenReply`) — **not ported**:
  mobile's `.ttsFailed` is itself a speak edge, so releasing would retry in a loop; a failed
  reply stays consumed (no automatic retries — the user re-reads it from the action bar).
  Desktop has **no** replay-specific gating: it would speak a reply a reconnect replay
  delivers. Mobile's replay rule (below) is a deliberate deviation.
- `lib/spoken-reply.ts` — ⚠️ changed: desktop no longer keys on the assistant ordinal but on
  the last spoken row id, migrated across the hydrate's live-id rewrite by the owning **user
  turn** (`absorbSpokenReplyRewrite`), because "hydration rewrites the live id and folds tool
  segments into one bubble, so the ordinal moves". Mobile's mirror image of that problem: the
  live fold keeps ONE assistant row per turn (`streamingRowID` survives tool events) while
  `reconstructTranscript` emits one row per history assistant message, so a hydrate can raise
  the assistant count of a turn already spoken. Mobile keeps a completed-assistant-row counter
  and re-bases it on every hydrate (the `absorbSpokenReplyRewrite` analog — Solution Overview).
- `lib/speech-text.ts` `sanitizeTextForSpeech` — ⚠️ materially changed since the plan (Task 1
  lists the current pipeline): tables are summarized to their header row, code/URLs become
  silence (no English placeholder words, #86602), line-final colons close as periods, `MEDIA:`
  tokens and identifier-dense tokens (#119207) are pruned. The identifier rules are mirrored by
  the server's `tools/tts_text_normalize.py` against the shared corpus
  `tests/fixtures/identifier_speech_corpus.json`.
- `lib/voice-playback.ts` — single playback (stop drains every live stop, bumps a sequence),
  15 s stall watchdog armed before `play()` and re-armed on each `timeupdate`
  (`PLAYBACK_STALL_MS` :21), `markVoicePlaybackInterrupted` / `takeVoicePlaybackInterrupted`
  latch with a **120 s TTL** (`INTERRUPT_TTL_MS` :845); the text is sanitized before `speak`.
- `app/session/hooks/use-prompt-actions/submit.ts` ~:333-357 — a submit while playback is
  active marks the latch + stops; every submit (incl. queue drains) takes the latch.
- `components/assistant-ui/thread/assistant-message.tsx` — `useReadAloudAction` (~:1158) +
  `ReadAloudButton` (~:1413): disabled while preparing or while any other playback is active;
  icons AudioLines / Loader2 (spinning) / VolumeX; labels "Read aloud" / "Preparing audio..." /
  "Stop reading"; failure → notification titled "Read aloud failed"; marks the row spoken after
  a play. Bar order: Branch, Copy, Copy full, Read aloud, Refresh.
- `app/chat/composer/voice-activity.tsx` `VoicePlaybackActivity` (~:208) — pill above the
  composer, "Preparing audio" / "Reading aloud", Stop button, `aria-live="polite"`.
- `app/chat/composer/voice-menu.tsx` ~:136 — the toggle is now ONLY a checkbox row in the voice
  menu ("Read replies aloud" / "Stop reading replies aloud", Volume2/VolumeX), trigger lit while
  on; the standalone `AutoSpeakButton` in `controls.tsx` is gone. Mobile has no voice menu (the
  mic is a direct button), so it keeps a standalone composer toggle.
- `store/voice-prefs.ts` — `$autoSpeakReplies` persisted in localStorage
  (`hermes.desktop.autoSpeakReplies`); "hydration and local toggles never edit backend
  configuration".
- No focus gating on desktop (speaks unfocused); playback survives a chat switch there.
  On mobile leaving the chat tears the slot down, so playback stops — accepted.

**Mobile mount points (verified 2026-10-27 against main @ `9089ab2`):**
- `HermesKit/Sources/HermesKit/Clients/AudioRecorderClient.swift` — the live-actor
  (`AudioRecorderEngine` ~:90) + `#if canImport(UIKit)` pattern to mirror; `.playAndRecord`
  session (`.duckOthers, .defaultToSpeaker`, ~:96) for the mic, deactivated with
  `.notifyOthersOnDeactivation`.
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` — `transcribe` (field :258, live
  ~:447) is the `postJSON` pattern (its `{ok: false}` maps to `RESTError.transcriptionFailed`);
  `deleteSession` (live ~:436) the profile-query pattern (`nil` → no query; per #114 callers
  pass the literal profile name, `"default"` included, and `nil` only when the profiles API is
  unsupported); `RESTError` ~:130 with `isMissingEndpointVerdict` ~:173; `get` ~:738,
  `validate` ~:768 (404 → `.notFound`, other statuses → `.server(status:detail:)` with the
  server `detail`), `postJSON` ~:793, `send` ~:820; `testValue` ~:541 (unimplemented except the
  `setUnread` no-op).
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (still one file, 4 898 lines) —
  `profileName` ~:41; replay state `replayCursor`/`isFoldingReplay`/`isReplayReadPending`
  ~:562-584; `CancelID` ~:1079; dependencies ~:1098-1108 (`rest` :1099, `preferences` :1101,
  `now` = `@Dependency(\.date.now)` :1102, `uuid` :1104, `audioRecorder` :1106, `debugLog`
  :1108); `.task` ~:1123 (first-appearance connect behind `hasStarted`); `.viewDisappeared`
  ~:1138 / `.teardown` ~:1143 / `.teardownSocketOnly` ~:1155; `.gatewayEvent` ~:1189 and
  `.gatewayFrame` ~:1192 (ready replay rules + cursor, then the same `reduceGatewayEvent`);
  `.eventReplayResult` ~:1199; `.gatewayClosed` ~:1202 (`finalizeInFlight`); `session.create`
  handshake `hasHydrated = true` ~:1253; `.foreground, .reattached` shared handler ~:1365 (dead
  socket → `connect` ~:1371; `isReplayReadPending` guard ~:1383; else hydrate); `.composerSubmitted`
  ~:1407 (queue branch ~:1414); `.copyRow` ~:1697 / `.branchFromMessage` ~:1711;
  `.voiceButtonTapped` ~:1842; the reconnect `.ready` replay branch ~:2385; the event fold
  `reduce(event:)` ~:2356 with `.messageComplete` ~:2450 (already skips materialising a row
  under `isFoldingReplay`) and `.error` ~:2554; `finalizeInFlight` ~:2975;
  `releaseVoiceResources` ~:2988; `reduceGatewayEvent` ~:3098; `applyEventReplayResult` ~:3170
  and `foldReplayedEvents` ~:3202 (sets `isFoldingReplay` around the batch, tracks the last
  turn boundary); `applyActivate` ~:3435 (`hasHydrated = true` :3441, transcript rebuild
  ~:3525, idle-edge drain ~:3606); `submitDraft` ~:3910 — the ONE submit pipeline shared by
  the idle composer and the queue drain (`fromQueue:`), with both regular `prompt.submit`
  builders inside it (~:3948 upload+submit, ~:4108 plain); `drainQueueIfReady` ~:4123; the
  slash-directive `prompt.submit` ~:4596 (untouched).
- `HermesKit/Sources/HermesKit/AppFeature.swift` — `.scenePhaseChanged` ~:416: `.active` ~:421
  forwards `.liveChat(.foreground)` (:431); `.background` ~:444 forwards `.liveChat(.persistNow)`
  (:449) and, for a running turn only, begins the ~30 s `BackgroundTaskClient` grace (~:456);
  `.backgroundGraceExpired` ~:475 → `persistNow` + `.teardownSocketOnly`; `.reattached` ~:540;
  regular-width fill `.liveChat(.task)` ~:605; `.chatViewDisappeared` ~:620 (forwards
  `.viewDisappeared` only for a detached compact slot); push-tap `.foreground` ~:1012;
  `teardownSlot` ~:1094.
- `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift` — `load*/save*/clear*` closure
  pattern + `.inMemory()` (~:114); logout clears every entry in
  `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift` ~:351-355.
- `HermesMobile/Sources/Features/Chat/ComposerView.swift` — trailing `HStack` (:83-93):
  `modelChip`, usage ring, `Spacer`, `attachButton`, `voiceButton`, `sendButton`.
- `HermesMobile/Sources/Features/Chat/ChatView.swift` — the fixed region above the composer
  is `pendingCard` (:42, `.layoutPriority` for compressible cards, `BoundedHeightLayout`
  inside, #65/#97) → `queuedPromptsPanel` (:45, defined ~:317) → `suggestionPanel` (:46) →
  `Divider` → `ComposerView` (:48); emptiness-keyed `.animation`s ~:93-96; `MessageActionBar`
  call site in `rowView` (~:247).
- `HermesMobile/Sources/Features/Chat/MessageActionBar.swift` — Copy + Branch buttons.
- Tests: `HermesKit/Tests/HermesKitTests/` (`ChatReductionTests`, `ChatInteractionTests`,
  `HermesRESTClientTests`, `AudioRecorderClientTests`, `AppFeatureTests`,
  `PreferencesClientTests`, `SettingsFeatureTests`, `MarkdownSegmentTests` as patterns; the #98
  replay pattern is `ReplayTests.swift` — `ReplayHarness` + `droppedState()`, driving
  `.gatewayClosed` → `.gatewayFrame(ready)` → `\.eventReplayResult` → `\.activateResult`;
  live events can still be driven with `.gatewayEvent(...)`, the action still exists);
  `HermesMobileTests/` (`ComposerSnapshotTests`, `ChatSnapshotTests`,
  `QueuedPromptsPanelSnapshotTests` as patterns; suite at 242/242).

## Development Approach

- **Testing approach**: Regular (code first, then tests within the same task) — consistent
  with every prior plan.
- Complete each task fully before moving to the next; small focused changes.
- **CRITICAL: every task MUST include new/updated tests** for the code it changes — unit tests
  for new/modified functions, success + error paths, listed as separate checklist items.
- **CRITICAL: all tests must pass before starting the next task** — `make test` (HermesKit,
  streamed) and, for view tasks, `make snapshot` (run twice when adding a new snapshot: the
  first records + fails by design, the second asserts clean).
- **CRITICAL: update this plan file when scope changes during implementation.**
- Logic in `HermesKit`, views thin. Clients are `@DependencyClient` with `liveValue` +
  `testValue`; iOS-only live values behind `#if canImport(UIKit)`, pure logic outside.
- Commit per task (capitalized verb, no conventional-commit prefix).

## Testing Strategy

- **Unit tests** (`swift test` via `make test`): pure helpers (`SpeechText`, `TTSAudio`),
  REST client calls (stubbed `URLProtocol`, following `HermesRESTClientTests`), and TCA
  reductions on `TestStore` with `@Dependency` overrides + `TestClock`. Replay cases reuse the
  `ReplayTests` harness shape.
- **Snapshot tests** (`make snapshot`): composer toggle on/off, the pill in both states, the
  action bar in idle/preparing/speaking/disabled. No measured `UIWindow` test — no layout
  floors or caps change.
- No e2e suite in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview

**Option A from the brainstorm: playback state lives per-slot in `ChatFeature`; `TTSClient`
is a dumb player.** Every existing lifecycle hook (`viewDisappeared`, `teardown`,
`teardownSocketOnly`) then stops audio through the same `releaseVoiceResources` path that
releases the mic, the pill/action-bar/composer all read one store, and the whole state
machine is `TestStore`-testable. The cost — playback dies when the chat leaves the screen —
is the natural phone behaviour (the transcript being read is no longer visible).

Rejected: an `AppFeature`-owned singleton (desktop-parity chat-switch survival, but two-way
plumbing that fights the slot model) and a status stream owned by the client actor (two
sources of truth).

### State machine (in `ChatFeature.State`)

| Field | Purpose |
|---|---|
| `autoSpeakReplies: Bool` | The device-local pref (`PreferencesClient`, confirmed 2026-10-27), read on the slot's first `.task`; default `false`. |
| `ttsSupported: Bool = true` | Capability gate; flips off on the first missing-endpoint verdict from `speak`. |
| `ttsPlayback: TTSPlayback` | `.idle` / `.preparing(rowID)` / `.speaking(rowID)`. |
| `spokenAssistantCount: Int` | Anchor = COMPLETED assistant message rows consumed (an in-flight/streaming row never counts). Not snapshot-persisted (every open re-arms). |
| `replayConsumedReply: Bool` | ➕ Set when a #98 replay fold folds a `message.complete`; the next hydrate consumes everything and clears it. |
| `ttsInterruptedAt: Date?` | Barge-in latch; consumed by the next regular `prompt.submit` if < 120 s old. |
| `isSceneBackgrounded: Bool` | Set by the new `.sceneBackgrounded`, cleared by `.foreground`; the speak check refuses to start while set. |
| `isOnScreen: Bool` | Set on `.task` / `.reattached`, cleared on `.viewDisappeared`; gates keep-awake AND the speak check (a detached compact slot is off screen). |

**Arming** (`spokenAssistantCount = completedAssistantCount`): on toggle-on, on the `.task`
pref load returning `true`, and on the slot's **first** hydrate (`hasHydrated` false → true,
both the `applyActivate` and the `session.create` handshake sites).

➕ **Re-basing on every later hydrate** (`applyActivate` with `hasHydrated` already true —
foreground, reattach, reconnect, post-slash refresh, branch probe). The rebuild changes the
count under the anchor (a live turn is one row, history may be several), so the anchor is
re-derived from the rebuilt transcript instead of kept: `anchor = newCompletedCount − (wasPending
&& !replayConsumedReply ? 1 : 0)`, where `wasPending` = before the rebuild the last completed
assistant row was unspoken (`completedCount > anchor`). A hydrate therefore never *creates* a
pending reply, it only *preserves* one the user was already waiting on (e.g. a reply that
completed live while backgrounded) — the original "a reply the user was waiting on is never
silently consumed" intent, without re-reading a turn whose row count moved. Clears
`replayConsumedReply`.

➕ **A dropped partial is never spoken**: when `finalizeInFlight` (`.gatewayClosed`,
`.authExpired`) closes a streaming row, it consumes it (`anchor = completedCount`); whether that
turn really finished is the reconnect replay's and hydrate's business.

**Speak check** (`autoSpeakIfReady`) runs at three edges — a LIVE `.messageComplete`, playback →
idle (`.ttsFinished` / `.ttsFailed`), and `.foreground` (not `.reattached`). It speaks the
**last** assistant row iff `autoSpeakReplies && ttsSupported && ttsPlayback == .idle &&
!isSceneBackgrounded && isOnScreen && !isFoldingReplay` and the row is complete with non-empty
sanitized text and `completedCount > anchor`; then sets `anchor = completedCount` (backlog
collapse). A turn ending in `.error` is not a `.messageComplete` → never spoken.

➕ **Replay rule (#98).** A `message.complete` folded by `foldReplayedEvents` is a past turn
boundary, exactly like the drain/park/`runningChanged`/anchor side effects the fold already
suppresses through `isFoldingReplay`: it must NOT auto-speak — not even when the fold completes
the still-live streaming row (after `.teardownSocketOnly` nothing was finalized, so a replayed
`message.complete` does mark that row complete). The fold sets `replayConsumedReply`, and the
trailing hydrate (every replay result ends in one) re-bases with the reply consumed, so no later
edge (`.foreground`, `.ttsFinished` after a manual read, …) picks the replayed reply up. A
plain-hydrate reconnect (no cursor, older agent, `truncated`, epoch change, read failure) is
treated the same way by the re-basing rule: a reply the client never saw complete live arrives
only through the hydrate and is not pending.

**Replay rule vs. "returning speaks a reply that completed while away" (decided: option 1,
confirmed by the user 2026-10-27).** They conflict partially. Still true: a reply that completes while the socket is
alive (a running turn keeps it ~30 s via the background grace) arrives as a LIVE
`message.complete`, is held by `isSceneBackgrounded`, and is spoken on `.foreground`. No longer
true: a reply that completes after the grace expired (`.teardownSocketOnly` → the foreground
redial replays the gap) or during a network drop (`.gatewayClosed` → reconnect replay) is
consumed silently — including a drop of a few seconds while the user watches the chat in the
hands-off loop. (Pre-#98 such a reply arrived only through the hydrate, which was not a speak
edge either, but it stayed pending and was read at some arbitrary later edge.) Options:
(1) **replay rule wins** — written into this plan, per the explicit instruction; (2) speak a
replayed completion when it is the newest reply and the scene is foreground + on screen
(treats a short drop as "live"), keeping the rule for everything else; (3) speak on return
whatever completed while backgrounded, replayed or not (drops the rule; desktop parity —
desktop has no replay gating).

**Keep-awake**: `wantsScreenAwake = isOnScreen && (ttsPlayback != .idle ||
(autoSpeakReplies && isSending) || recording.isBusy)`; a reducer `onChange` drives
`idleTimer.setDisabled`.

## Technical Details

- **`TTSClient`** — `play(data:mimeType:) async throws` writes a temp file, sets
  `AVAudioSession` `.playback` (mode `.default`, no options), activates, plays via
  `AVAudioPlayer`, suspends until the delegate's `didFinishPlaying`, a stall (15 s with
  `currentTime` not advancing, armed before `play()` like the desktop →
  `TTSPlaybackError.stalled`), or an `AVAudioSession` interruption notification (treated as clip
  end, not an error); throws `.failed` on decode/`prepareToPlay`/`play()` failure. On every
  exit — including task cancellation via `withTaskCancellationHandler` — stops the player,
  deactivates with `.notifyOthersOnDeactivation`, deletes the temp file. `stop() async` is
  idempotent, makes a suspended `play` return normally, and returns only after the session is
  deactivated (the mic path relies on that ordering — Task 7). Live value in a private actor
  behind `#if canImport(UIKit)`; `testValue` returns immediately.
- **`TTSAudio.parse(dataURL:)`** — pure: `data:<mime>;base64,<payload>` → `TTSAudio(data,
  mimeType)`; throws on a missing prefix / non-base64 payload. Outside the UIKit guard.
- **`IdleTimerClient`** — `setDisabled: @Sendable (Bool) async -> Void`; live value hops to
  `MainActor` and sets `UIApplication.shared.isIdleTimerDisabled`; `testValue` no-op.
- **REST** — `speak(connection, text, profile) -> TTSAudio` (profile query only when non-nil;
  the caller passes `state.profileName` verbatim, #114; per-call `URLRequest.timeoutInterval`
  from `HermesRESTClient.speakTimeout(forCharacterCount:)` = `min(600, max(180, 0.035 ×
  chars))`; response `{ok, data_url, mime_type, provider}` — the server never answers `ok:
  false` (errors are HTTP statuses), so a defensive `ok == false` maps to
  `RESTError.server(status: 200, detail: nil)`, not a new case). No `/api/config` calls.
- **Preference** — `PreferencesClient.loadAutoSpeakReplies: () -> Bool` (default `false`) +
  `saveAutoSpeakReplies(Bool)` + `clearAutoSpeakReplies()`; cleared on logout like every pref.
- **`prompt.submit`** — the two regular builders in `submitDraft` gain `"interrupted":
  .bool(true)` when the reducer hands the effect `interrupted == true` (computed from
  `ttsInterruptedAt` with the existing `@Dependency(\.date.now) var now`, then cleared). Both the
  composer and the queue-drain paths consume the latch (desktop takes it on every submit); only a
  USER submit stamps it. The slash-directive path is untouched.
- **Row → text** for speech: `ChatRow.Kind.message(role: .assistant, text, isComplete:
  true)` only; `SpeechText.sanitize(text)`.
- **Errors → banner**: `isMissingEndpointVerdict` ⇒ silent gate flip; anything else ⇒
  `errorBanner = error.message` (400 details verbatim), `TTSPlaybackError.stalled` ⇒
  "Playback stalled.", `.failed` ⇒ "Couldn’t play the audio.".

## What Goes Where

- **Implementation Steps** (`[ ]`): everything below is achievable in this repo.
- **Post-Completion** (no checkboxes): manual device checks and the voice-conversation
  follow-ups.

## Implementation Steps

### Task 1: Port `sanitizeTextForSpeech` as `SpeechText.sanitize`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/SpeechText.swift`
- Create: `HermesKit/Tests/HermesKitTests/SpeechTextTests.swift`

Port `apps/desktop/src/lib/speech-text.ts` @ `69f73ec5f1` step for step (⚠️ implemented on
`NSRegularExpression`/ICU instead of Swift `Regex` literals: `Regex` matches grapheme
clusters by default, where `"\r\n"` and ZWJ emoji are single `Character`s, while ICU matches
code points like the JS engine and takes `$1` templates; JS's ASCII `\w`/`\b` are spelled out,
JS's non-multiline `$` is `\z`; the emoji class uses the same code-point ranges `\u{1F000}-\u{1FAFF}`,
`\u{2600}-\u{27BF}`, `\u{FE0F}`, `\u{200D}`, `\u{E0020}-\u{E007F}`). Do **not** reuse
`MarkdownSegment` — its table detection is looser than the desktop's and the two clients must
say the same thing. `cutSentences` / `IncrementalSpeechSentenceBuffer` are streaming-only — not
ported. ⚠️ The pipeline changed materially since the plan was written (items marked ➕).

- [x] ➕ `summarizeMarkdownTables` (was `stripMarkdownTables`): a table starts where line *i*
      is a delimiter row (every cell `^:?-{3,}:?$`) and line *i-1* a header row with the same
      cell count and blockquote depth; header + delimiter + every following row at that depth
      are replaced by ONE line, the header cells (`\|` → space, trimmed, empties dropped)
      joined with `", "` and closed with `.` unless already ending in `.!?:`; an all-empty
      header leaves nothing. Port `parseMarkdownTableRow` exactly (≤3-space indent, no tabs,
      `>`-depth counting, unescaped-pipe splitting, ≥2 cells unless fully piped). Runs first
      (a right-align marker is a trailing colon).
- [x] ➕ Line-final colons → `.` BEFORE line breaks are flattened (`/:\s*$/gm`).
- [x] `normalizeLineBreaks`: CRLF→LF; `(\p{L})-\n(\p{L})` → `$1$2`; punctuated paragraph
      break `([.!?])([*_~\`>"'’”)}\]]*)[ \t]*\n{2,}[ \t]*` → `$1$2 `; remaining `\n{2,}` →
      `. `; single `\n` → ` `.
- [x] Then, in order: fenced code (incl. unterminated) → `""` (➕ silence, was ` code block
      omitted `); leading `THINKING_PREFIX_RE` → ` `; `[label](url)` → label; inline code →
      contents; bare `\bhttps?://\S+` → `""` (➕ silence, was ` link `); ➕ `MEDIA:` tokens
      (`[ \t]*MEDIA:\S+?(?=[.,;:!?)\]]*(?:\s|$))`) → `""`; emoji runs → ` `.
- [x] ➕ `pruneIdentifierTokens`: hash-prefixed hex (`sha256:…`, `md5 …`, …) → ` `, then every
      `[A-Za-z0-9_./~@-]+` token that `isDenseIdentifier` (port verbatim: emails and dates
      stay; paths; `/`-tokens with an extension or digit; the extension list; UUIDs; hex runs
      ≥7 containing a digit; digit tokens with ≥2 separators or ≥2 hyphens, or a `/`, or a
      hyphen plus a separator) → ` `.
- [x] Tail: `^#{1,6}\s+` per line; every `[*_~>#]`; `^\s*[-+*]\s+` per line (ordered-list
      numbers stay); ➕ a trailing orphaned colon → `.`; collapse `\s+` → ` `, trim.
- [x] Write `SpeechTextTests`: one case per rule using the desktop's own fixture shapes
      (`speech-text.test.ts`: table inside a blockquote → its header sentence, empty-header
      table → silence, escaped pipe, hyphen across a line break, punctuated vs plain paragraph
      break, "the list:" before a code block → "the list.", unterminated fence, "(pause)
      Thinking..." prefix, link + bare URL, `MEDIA:/x.py.` keeps the period, emoji with
      VS16/ZWJ, nested bullets, ordered list untouched).
- [x] ➕ Write identifier tests from the shared corpus
      (`hermes-agent/tests/fixtures/identifier_speech_corpus.json`, copied as a parameterized
      `@Test(arguments:)` table — `mustNotContain` / `mustContain` per row, plus the
      pass-through rows), so the phone, desktop and server normalizer agree.
- [x] Write edge-case tests: empty/whitespace-only input → `""`, text that sanitizes to
      empty (only a code block, only a URL), a mixed real reply asserting the full expected
      string.
- [x] run `make test` — must pass before Task 2

### Task 2: `TTSAudio` data-URL parsing and `TTSClient`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/TTSClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/TTSClientTests.swift`

- [x] Add `public struct TTSAudio: Equatable, Sendable { data, mimeType }` with pure
      `static func parse(dataURL:) throws -> TTSAudio` (outside the UIKit guard) and
      `enum TTSAudioError { malformedDataURL, invalidBase64 }`. (➕ an empty mime or empty
      payload is `malformedDataURL`; media-type params before `;base64` are dropped; pure
      `TTSAudio.fileExtension(forMimeType:)` picks the temp-file extension, `mp3` fallback.)
- [x] Add `public enum TTSPlaybackError: Error, Equatable, Sendable { failed, stalled }` and
      the `@DependencyClient struct TTSClient { play: (Data, String) async throws -> Void;
      stop: () async -> Void }` + `DependencyValues.tts` + `testValue` (returns instantly).
- [x] Implement the live actor behind `#if canImport(UIKit)` mirroring `AudioRecorderEngine`:
      temp file (`hermes-tts-<uuid>.<ext>` by mime), `.playback` session, `AVAudioPlayer`
      + delegate bridged to a `CheckedContinuation`, 15 s stall watchdog armed before `play()`
      and re-armed while `currentTime` advances (`TTSPlaybackError.stalled`),
      `AVAudioSession.interruptionNotification` `.began` ⇒ finish normally,
      `withTaskCancellationHandler` ⇒ `stop()`; every exit stops, deactivates with
      `.notifyOthersOnDeactivation`, and deletes the file. `stop()` is idempotent (resumes the
      continuation once; a second call does not deactivate again) and returns after the
      deactivation. (⚠️ `swift test` runs on macOS where the live code is compiled out —
      verified with `xcodebuild build -scheme HermesKit -destination 'generic/platform=iOS
      Simulator'` in `HermesKit/`, warning-free; the delegate is `nonisolated` because the
      SDK's `AVAudioPlayerDelegate` is main-actor.)
- [x] Write `TTSClientTests` for `TTSAudio.parse`: the four server mime types
      (`audio/mpeg`, `audio/ogg`, `audio/wav`, `audio/flac`), a payload round-trip, missing
      `data:` prefix, missing `;base64,` marker, invalid base64.
- [x] Write a test that `TTSClient.testValue.play` returns without throwing and `stop` is
      callable (guards the double's contract used by `ChatFeature` tests).
- [x] run `make test` — must pass before Task 3

### Task 3: `IdleTimerClient`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/IdleTimerClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/IdleTimerClientTests.swift`

- [x] Add `@DependencyClient struct IdleTimerClient { setDisabled: @Sendable (Bool) async
      -> Void }` + `DependencyValues.idleTimer`; `testValue` no-op; live value behind
      `#if canImport(UIKit)` hops to `MainActor` and sets
      `UIApplication.shared.isIdleTimerDisabled` (non-UIKit `liveValue = testValue`).
- [x] Write a test using a recording override (`LockIsolated<[Bool]>`) that the closure
      receives the values it is called with — the same recorder `ChatFeature` tests reuse.
- [x] run `make test` — must pass before Task 4

### Task 4: REST — `speak`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

⚠️ `config` / `updateConfig` are dropped with the device-local toggle (Overview). Under
alternative A1 add back `config` (GET, lenient `JSONValue`); under B also `updateConfig` (`PUT
/api/config {config: <patch>}` via `send`) with the original tests.

- [x] Add `speak: (ServerConnection, String, String?) async throws -> TTSAudio`:
      `POST /api/audio/speak` (+ `?profile=` only when non-nil, `deleteSession`'s query
      pattern), body `{text}`, private `SpeakResponse {ok, data_url, mime_type, provider}`;
      `ok == false` (defensive — the server never sends it) ⇒ `RESTError.server(status: 200,
      detail: nil)`; success ⇒ `TTSAudio.parse(dataURL:)` (a parse failure maps to
      `RESTError.decoding`). Per-request timeout from a pure `static func
      speakTimeout(forCharacterCount:) -> TimeInterval` = `min(600, max(180, 0.035 × n))` —
      extend `postJSON` with an optional `timeout:` (default unchanged for `transcribe`).
- [x] Leave `speak` unimplemented in `testValue` (the `setUnread`-style no-op default is only
      for calls issued on every open; `speak` is issued only by an explicit edge, so tests
      stub it and an unexpected call fails loudly).
- [x] Write tests (stubbed `URLProtocol`, existing pattern): `speak` success decodes the
      data URL and sends `{text}` with/without `?profile=` (incl. the literal `"default"`);
      404 → `.notFound` and 405 → `.server(405, …)`, both `isMissingEndpointVerdict`; 400
      with `detail` → `.server(400, detail)` (e.g. "Text is empty after TTS cleanup"); 500 →
      `.server(500, detail)`; malformed data URL → `.decoding`; the request carries the
      `speakTimeout` interval; `speakTimeout` table (short text → 180, 10 000 chars → 350,
      20 000 chars → 600).
- [x] run `make test` — must pass before Task 5

### Task 5: `ChatFeature` — setting load, toggle, arming

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift` (➕ the two other logout paths)
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/PreferencesClientTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SettingsFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`
- Modify (➕ exhaustive hydrate / `.gatewayClosed` assertions now see the anchor):
  `ChatBranchTests.swift`, `ChatReductionTests.swift`, `HydrateTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`

- [x] ➕ `PreferencesClient`: `loadAutoSpeakReplies` (default `{ false }`),
      `saveAutoSpeakReplies`, `clearAutoSpeakReplies` in live + `.inMemory()`; the logout path
      in `SettingsFeature` (~:351-355) clears it ("logout must clear every prefs entry").
      ➕ Also cleared by `AppFeature`'s two other full logouts (retry-screen "Log Out" and
      re-auth "Quit to start"), which reset the swipe-default pref the same way. Not part of
      `clearIdentityScopedPrefs` (a re-auth user switch keeps device UI prefs, like the swipe
      default). Live key `hermes.auto-speak-replies`.
- [x] Add state: `autoSpeakReplies`, `ttsSupported`, `ttsPlayback` (`public enum
      TTSPlayback: Equatable, Sendable { idle, preparing(ChatRow.ID), speaking(ChatRow.ID) }`
      + `isActive`), `spokenAssistantCount`, `replayConsumedReply`, `ttsInterruptedAt`,
      `isSceneBackgrounded`, `isOnScreen`; pure `completedAssistantCount` and
      `lastCompletedAssistantRow` helpers (an incomplete assistant row never counts); a
      private `arm(&state)` that sets the anchor.
- [x] Action: `autoSpeakToggled`. On the slot's first `.task` (after the `hasStarted` guard,
      ~:1134) read `preferences.loadAutoSpeakReplies()` synchronously, set the flag, and arm
      when `true`. No effect is emitted, so the existing exhaustive `.task` tests stay
      untouched (the in-memory/test default is `false`).
- [x] `.autoSpeakToggled`: flip, `preferences.saveAutoSpeakReplies(new)`, arm if now on (a
      local write cannot fail — no banner, no revert).
- [x] Arm on the slot's first hydrate: in `applyActivate` (~:3441) and the `session.create`
      handshake (~:1253) where `hasHydrated` goes false → true (unconditionally; cheap and
      correct whatever the toggle says). ➕ Consequence: nine existing exhaustive assertions
      (first hydrates with a completed reply, two `.gatewayClosed` mid-stream) now also
      assert `spokenAssistantCount = 1`.
- [x] ➕ Re-base on every later hydrate in `applyActivate` (Solution Overview): capture
      `wasPending` BEFORE the transcript rebuild (~:3525), then `anchor = newCompletedCount −
      (wasPending && !replayConsumedReply ? 1 : 0)` after the rebuild + inflight seed; clear
      `replayConsumedReply`. (One private `rebaseSpokenAnchor` covers the first-hydrate arm
      and the later re-base.)
- [x] ➕ In `finalizeInFlight` (~:2975): when a streaming row is closed, `anchor =
      completedCount` (a dropped partial is never spoken).
- [x] Write tests: `.task` with the pref `true` sets the flag and arms to the current
      completed count; pref `false` leaves the anchor; toggle on saves `true` + arms; toggle off
      saves `false` and does not touch the anchor; a second `.task` (re-appearance) does not
      re-read; first hydrate arms; ➕ a foreground re-hydrate that turns one live assistant row
      into two history rows (the turn's progress text + final) does NOT leave a pending reply
      (no speak at the next `.foreground`); ➕ a re-hydrate with a pending live reply (completed
      while backgrounded) keeps exactly that reply pending; ➕ a `.gatewayClosed` mid-stream
      consumes the finalized partial; ➕ `PreferencesClientTests` round-trip + clear;
      `SettingsFeatureTests` logout clears the key. (The speak check lands in Task 6, so "no
      speak at the next `.foreground`" is asserted here as `spokenAssistantCount ==
      completedAssistantCount`; Task 6's replay tests cover the edge itself. ➕ Also: replay
      flag consumed by the re-base, a hydrate never creates a pending reply, a later
      `session.create` keeps a pending reply, `AppFeatureTests` for both other logouts.)
- [x] run `make test` — must pass before Task 6

### Task 6: `ChatFeature` — playback flow, speak check, per-message read

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`

- [x] Add `CancelID.ttsPlayback` (in the enum ~:1079) and `@Dependency(\.tts)`. Actions:
      `readAloudTapped(id)`, `stopReadAloud`, `ttsSpeaking(id)`, `ttsFinished`,
      `ttsFailed(id, RESTOrPlaybackError)`. Private `speakRow(id, &state) -> Effect`:
      `ttsPlayback = .preparing(id)`; effect (`cancellable(id: .ttsPlayback, cancelInFlight:
      true)`): `SpeechText.sanitize` → empty ⇒ `.ttsFinished`; `rest.speak(connection, text,
      state.profileName)` → `send(.ttsSpeaking(id))` → `tts.play` → `send(.ttsFinished)`;
      catch ⇒ `.ttsFailed`. (➕ the error type is `ChatFeature.ReadAloudFailure { rest(RESTError),
      playback(TTSPlaybackError) }`; `.ttsSpeaking` keeps the row the state points at, which a
      hydrate may have re-pointed.)
- [x] `.ttsFailed`: `isMissingEndpointVerdict` ⇒ `ttsSupported = false` silently (and turn
      `autoSpeakReplies` handling into a no-op while unsupported); other REST errors ⇒
      `errorBanner = message`; `.stalled` ⇒ "Playback stalled."; `.failed` ⇒ "Couldn’t play
      the audio."; all ⇒ `.idle` then run the speak check (the failed reply stays consumed —
      unlike desktop's `releaseUnplayedSpokenReply`, so the failure edge cannot loop).
- [x] `.stopReadAloud`: `.idle` + `.cancel(id: .ttsPlayback)` + `tts.stop()`. (➕ a no-op
      while idle; not a speak edge.)
- [x] Private `autoSpeakIfReady(&state) -> Effect` per the Solution Overview conditions
      (incl. `isOnScreen` and `!isFoldingReplay`); call it from `.messageComplete` (in
      `reduce(event:)` ~:2450, after the existing merge — inert during a replay fold),
      `.ttsFinished`, `.ttsFailed`, and the `.foreground` action only (split the shared
      `.foreground, .reattached` case ~:1365 by `if case .foreground = action`, and merge the
      speak effect BEFORE the dead-socket `connect` / `isReplayReadPending` early returns so a
      reply held while backgrounded is spoken whatever the socket is doing). (➕ the shared
      re-attach body moved to a private `reattach(&state)`; "the row is complete" is read as
      "the NEWEST assistant message row is complete" — a reply that finished during a clip
      waits while the next turn streams, then the newest is read.)
- [x] ➕ Replay rule: in `foldReplayedEvents` (~:3202) set `state.replayConsumedReply = true`
      when the batch folds a `.messageComplete` (the `.ended` boundary branch already
      identifies it; an `.error` boundary is never spoken anyway). The trailing hydrate's
      re-base (Task 5) consumes it. (➕ the fold also arms the anchor right away, so a speak
      edge landing before that hydrate — or after a failed one — cannot read the reply.)
- [x] ➕ When a hydrate rebuild removes the row `ttsPlayback` targets (the live `uuid()` row
      becomes a deterministic history id), re-point `.preparing`/`.speaking` to the last
      completed assistant row so the action bar keeps showing the right state (desktop absorbs
      the same live-id rewrite); the clip itself is untouched.
- [x] `.readAloudTapped(id)`: guard `ttsSupported`, `ttsPlayback == .idle`, row is a complete
      assistant message; `speakRow` and bump `spokenAssistantCount` to that row's
      completed-ordinal+1 (never lower it).
- [x] Write tests (`TestStore`, recording `tts`/`rest` overrides; live events via
      `.gatewayEvent`): armed + idle + on-screen `messageComplete` ⇒ preparing → speaking →
      finished with the sanitized text sent and `profileName` passed through; unarmed ⇒
      nothing; toggle off ⇒ nothing; off screen (detached slot) ⇒ nothing; a completion during
      playback waits and the idle edge speaks only the newest row; empty-after-sanitize reply
      is skipped and consumes the anchor; `.error` terminal never speaks.
- [x] ➕ Write replay tests (in `ChatReadAloudTests`, reusing the `ReplayTests` harness shape:
      `droppedState()`, `.gatewayClosed` → `.gatewayFrame(ready)` → `\.eventReplayResult` →
      `\.activateResult`): with auto-speak armed, idle and on screen, a replayed
      `message.complete` ⇒ no `rest.speak` call and `ttsPlayback` never leaves `.idle` (no
      `.preparing`); after the trailing hydrate a `.foreground` (healthy socket) and a
      `.ttsFinished` from a manual read of an older row still do not speak the replayed reply;
      the NEXT live `message.complete` is spoken; the `.teardownSocketOnly` variant (the fold
      completes the still-live streaming row) behaves the same; a replay whose gap holds no
      `message.complete` leaves a live-pending reply pending.
- [x] Write tests: `readAloudTapped` speaks that row and bumps the anchor so the next
      `messageComplete`-less idle edge does not re-speak; tap while another row plays is a
      no-op; `stopReadAloud` cancels and calls `tts.stop`; 404 and 405 flip `ttsSupported` and
      hide without a banner; 400 detail lands in `errorBanner`; stalled/failed banners; a
      hydrate mid-playback re-points `ttsPlayback` to the rebuilt row.
- [x] run `make test` — must pass before Task 7

### Task 7: Interruption latch and lifecycle (background, disappear, teardown)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`
- Modify (➕ exhaustive `.task` / `.reattached` assertions now see `isOnScreen = true`):
  `ChatReductionTests.swift`, `HydrateTests.swift`, `ServerRequestTests.swift`

- [x] Barge-in (USER submits only): in `.composerSubmitted` (~:1407 — both the idle path and
      the mid-turn queue branch) and `.voiceButtonTapped` (~:1842, from `.idle`), if
      `ttsPlayback.isActive` ⇒ stop (cancel + `tts.stop`) and stamp `ttsInterruptedAt = now`.
      NOT in `drainQueueIfReady`: the drain fires on the same `message.complete` that starts
      auto-speak, and must not cut the reply it just triggered. (➕ stamped only once the
      submit passes its `canSend` / `canQueue` guards; private `bargeInReadAloud` +
      `stopReadAloudPlayback`, which `.stopReadAloud` now shares.)
- [x] ⚠️ Mic ordering: in `.voiceButtonTapped` run `await tts.stop()` at the top of the
      permission `.run`, before `requestPermission`/recording starts — `stop()` deactivates the
      session with `.notifyOthersOnDeactivation`, which would otherwise race and kill the
      recorder's freshly activated `.playAndRecord` session. (➕ called unconditionally — it is
      idempotent, and it also serializes behind a Stop tapped just before the mic.)
- [x] Consume: in `submitDraft` (~:3910, both regular builders ~:3948 upload+submit and ~:4108
      plain; composer and `fromQueue` paths alike; not the slash-directive path ~:4596),
      compute `interrupted = ttsInterruptedAt.map { now.timeIntervalSince($0) < 120 } ??
      false`, clear the stamp, and add `"interrupted": .bool(true)` to the params only when true
      (byte-identical frames otherwise, incl. the #17 heal replay of the same submit).
      (➕ `takeReadAloudInterruption` + a static `promptSubmitParams`; the slash/compress
      branches of `submitDraft` leave a stamp for the next regular submit within the TTL.)
- [x] Extend `releaseVoiceResources` (~:2988) to cancel `.ttsPlayback`, reset `ttsPlayback =
      .idle`, and call `tts.stop()` when it was active — covers `viewDisappeared`, `teardown`.
      ➕ `.teardownSocketOnly` (~:1155) does NOT call `releaseVoiceResources` today; add the TTS
      half there explicitly (it is reached only while backgrounded, so playback is normally
      already stopped by `.sceneBackgrounded`). `viewDisappeared` also clears `isOnScreen`;
      `.task` (every appearance) and `.reattached` set it.
- [x] Add `ChatFeature.Action.sceneBackgrounded` (stop playback, `isSceneBackgrounded =
      true`); `.foreground` clears it before the speak check. In `AppFeature`'s
      `.scenePhaseChanged(.background)` branch (~:444) forward `.liveChat(.sceneBackgrounded)`
      alongside the existing `persistNow`, for idle AND running slots (the grace keeps a
      running turn's process alive, so the clip would otherwise keep playing; the `.inactive`
      branch stays untouched). Accepted: a push tap's `.foreground` (~:1012) may arrive just
      before `.active` and clear the flag a beat early. (➕ concatenated BEFORE `persistNow`.)
- [x] Write tests: submit mid-playback stops and the next `prompt.submit` frame carries
      `interrupted: true` (assert the exact `JSONValue` params); a queued submit mid-playback
      (turn running) stops + stamps and the drained `prompt.submit` carries the flag; a
      121 s-old stamp is dropped; a submit with no stamp sends the byte-identical legacy frame;
      a queue drain at `message.complete` does not stop the auto-speak it triggers; mic tap
      mid-playback stops + stamps (with `tts.stop` recorded before `requestPermission`), and
      the later composer send carries the flag.
- [x] Write tests: `sceneBackgrounded` stops playback; a live `messageComplete` while
      backgrounded (grace socket) does not start playback; `.foreground` clears the flag and
      speaks the pending newest row; `.reattached` does not speak; `viewDisappeared` /
      `teardown` / `teardownSocketOnly` each stop an active clip; `AppFeature` `.background`
      forwards `sceneBackgrounded` only when a slot exists, for both an idle and a running slot
      (update the existing exhaustive `.background` tests ~:1771-1914 to receive it).
- [x] run `make test` — must pass before Task 8

### Task 8: Keep-awake predicate

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`

- [x] Add `public var wantsScreenAwake: Bool` on `State` (`isOnScreen && (ttsPlayback
      != .idle || (autoSpeakReplies && isSending) || recording.isBusy)`).
- [x] Add `@Dependency(\.idleTimer)` and a `Reduce` `.onChange(of: \.wantsScreenAwake)`
      effect calling `idleTimer.setDisabled(new)`; `.teardown` additionally sends an explicit
      `setDisabled(false)`. (➕ the `.onChange` wraps the main `Reduce` only, not the
      `BindingReducer` — no binding writes a predicate input.)
- [x] Write tests with the recording `IdleTimerClient`: on/off transitions for each of the
      four triggers (playback start/finish; auto-speak on + turn start/`messageComplete`;
      recording start/stop; `viewDisappeared` while playing ⇒ false); teardown emits `false`.
- [x] run `make test` — must pass before Task 9

### Task 9: Composer auto-speak toggle button

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/ComposerSnapshotTests.swift`

- [x] Add `var autoSpeak: Bool = false`, `var showsAutoSpeak: Bool = true`,
      `var onToggleAutoSpeak: () -> Void = {}` (defaults keep existing call sites intact).
- [x] Insert `autoSpeakButton` before `attachButton` in the trailing `HStack` (:83-93):
      `speaker.wave.2.fill` on / `speaker.slash` off (desktop Volume2/VolumeX), `.font(.title3)`,
      `Color.hermesAccent` when on / `.secondary` off, accessibility label "Read replies
      aloud" / "Stop reading replies aloud", the `.isSelected` trait when on; rendered only when
      `showsAutoSpeak` (the recording bar already replaces the row while recording).
      (➕ both glyphs sit in a `ZStack`, one at opacity 0, so the button keeps the wider glyph's
      width in either state and a tap never re-truncates the model chip beside it.)
- [x] Wire in `ChatView`'s `ComposerView(...)` call (~:48): `autoSpeak:
      store.autoSpeakReplies`, `showsAutoSpeak: store.ttsSupported`, `onToggleAutoSpeak: {
      store.send(.autoSpeakToggled) }`.
- [x] Add snapshots: composer with the toggle on, off, and hidden (`showsAutoSpeak: false`)
      in light + dark (`make snapshot` twice). (➕ one three-row stack per appearance; the
      `showsAutoSpeak: true` default puts the toggle into every composer/`ChatView` baseline,
      so those 19 were re-recorded deliberately — all at unchanged render size.)
- [x] run `make snapshot` — must pass before Task 10

### Task 10: "Reading aloud" pill

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/ReadAloudPill.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Create: `HermesMobileTests/ReadAloudPillSnapshotTests.swift`

- [x] `ReadAloudPill(state: ChatFeature.State.TTSPlayback, onStop:)`: preparing ⇒
      `ProgressView().controlSize(.small)` + "Preparing audio"; speaking ⇒
      `speaker.wave.2` + "Reading aloud"; trailing "Stop" button; secondary-background
      capsule matching `QueuedPromptsPanel` styling; `.accessibilityElement(children:
      .combine)` + `.accessibilityAddTraits(.updatesFrequently)`; announce state changes via
      `AccessibilityNotification.Announcement`. (➕ the Stop label carries `speaker.slash`
      like the desktop's VolumeX + "Stop"; leading glyph in a fixed-width slot so the label
      does not shift on preparing → speaking; announced on appearance too — `onChange(initial:)`.)
- [x] Mount in `ChatView`'s fixed region between `queuedPromptsPanel` (:45) and
      `suggestionPanel` (:46) — below `pendingCard`, whose `.layoutPriority` keeps winning the
      height (#65: the region does not scroll; the pill is one fixed line) — with
      `.transition(.opacity)`, shown while `ttsPlayback != .idle`; `onStop: {
      store.send(.stopReadAloud) }`; add an emptiness-style `.animation` keyed on
      `store.ttsPlayback == .idle` next to the queue's (~:96).
- [x] Add snapshots: preparing and speaking, light + dark. (➕ one two-row stack per
      appearance, `ReadAloudPillSnapshotTests`; no existing baseline changed — every fixture
      is idle.)
- [x] run `make snapshot` — must pass before Task 11

### Task 11: Per-message "Read aloud" action

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesMobile/Sources/Features/Chat/MessageActionBar.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`

- [x] Add `public enum ReadAloudButtonState: Equatable, Sendable { hidden, idle, disabled,
      preparing, speaking }` and pure `ChatFeature.State.readAloudState(for rowID:)`:
      `hidden` when `!ttsSupported`; `preparing`/`speaking` when `ttsPlayback` targets this
      row; `disabled` when any other playback is active; else `idle`.
- [x] `MessageActionBar`: add `readAloud: ReadAloudButtonState`, `onReadAloud`,
      `onStopReading`; third button after Branch — `waveform` (idle/disabled; desktop
      AudioLines; 0.4 opacity + `.disabled` when disabled), `ProgressView` (preparing,
      disabled), `speaker.slash` (speaking → `onStopReading`; desktop VolumeX); labels "Read
      aloud" / "Preparing audio..." / "Stop reading"; nothing rendered for `hidden`.
      (➕ the three props default to `.hidden`/no-op so direct component call sites are
      unchanged; the spinner and stop glyph overlay a hidden `waveform`, so the glyph slot
      never resizes between states.)
- [x] Wire in `ChatView`'s action-bar call site (`rowView` ~:247): `readAloud:
      store.readAloudState(for: row.id)`, `onReadAloud: { store.send(.readAloudTapped(id:
      row.id)) }`, `onStopReading: { store.send(.stopReadAloud) }`. (➕ as
      `store.state.readAloudState(for:)` — the store's dynamic member lookup cannot reach a
      State method.)
- [x] Write `readAloudState` unit tests (all five outcomes).
- [x] Add snapshots of a completed assistant cell with the bar in idle, preparing, speaking,
      and disabled (`rowView` component render, as the existing action-bar snapshots do).
      (➕ the button renders under every completed assistant reply by default, so 12 existing
      baselines were re-recorded on purpose: 9 failed outright, and 3 more (reviewSummary,
      slashSuggestionPanel, rehydrated_rendersStoredHistory) were stale but still passed within
      the 0.98 device budget. Render sizes are unchanged except `copiedViaStoreToken`, 278 →
      281 px: the waveform glyph is 1pt taller than the checkmark that used to set that bar's
      height.)
- [x] run `make test` and `make snapshot` — must pass before Task 12

### Task 12: Verify acceptance criteria

No real agent or device was available, so each item cites the automated tests that cover its
logic (`ChatReadAloudTests` unless named otherwise); ➕ marks a test this task added.

- [x] Toggle on → reply completes → pill "Preparing audio" → "Reading aloud" → audio plays
      through the silent switch → pill hides; the reply on screen at toggle time was not read.
      (Logic covered by ➕ `toggleOnLeavesTheReplyOnScreenUnreadAndReadsTheNextOne`,
      `toggleOnSavesTrueAndArms`, `liveCompletionIsReadPreparingSpeakingFinished`; pill states
      by `ReadAloudPillSnapshotTests`, toggle by `ComposerSnapshotTests.testComposer_autoSpeakToggle*`.
      Device check deferred to Post-Completion: real audio through the silent switch.)
- [x] Second reply completing mid-playback waits, then only the newest is read.
      (`completionsDuringPlaybackWaitAndTheIdleEdgeReadsOnlyTheNewest`,
      `aStreamingNewestReplyHoldsTheIdleEdge`.)
- [x] Per-message Read aloud reads that row; other rows' buttons are disabled meanwhile;
      Stop silences; auto-speak does not re-read that row. (`readAloudTappedReadsThatRowAndBumpsTheAnchor`,
      `readingAnOlderRowNeverLowersTheAnchorAndKeepsANewerReplyPending`,
      `readAloudTappedIgnoresNonRepliesAndAnActiveClip`, the four `readAloudState*` tests,
      `stopReadAloudCancelsTheClipAndStopsThePlayer`; bar by
      `ChatSnapshotTests.testAssistantRow_readAloud{Idle,Preparing,Speaking,Disabled}`.)
- [x] Typing a new message mid-playback silences it and the frame carries `interrupted`.
      (`submitMidPlaybackStopsTheClipAndFlagsThePrompt`,
      `aQueuedSubmitMidPlaybackStampsAndTheDrainedPromptCarriesTheFlag`,
      `theLatchExpiresAfter120Seconds`, `aSubmitWithoutAStampSendsTheLegacyFrame`,
      `micTapMidPlaybackStopsBeforeThePermissionPromptAndStamps`,
      `aQueueDrainAtMessageCompleteDoesNotStopTheAutoSpeakItTriggers`.)
- [x] Backgrounding stops audio; returning speaks a reply that completed LIVE while away
      (within the ~30 s grace of a running turn). A reply that completed after the grace
      expired, or during a socket drop (delivered by the #98 replay or a plain reconnect
      hydrate), is NOT read — per the replay rule (Solution Overview, user-confirmed).
      (`sceneBackgroundedStopsPlaybackWithoutALatch`,
      `aReplyCompletingWhileBackgroundedIsReadOnForeground`,
      `foregroundReadsAHeldReplyBeforeRedialing`, `aReplayedCompletionIsNeverRead` (socket drop
      + grace expiry), ➕ `aReplyDeliveredOnlyByAPlainReconnectHydrateIsNeverRead` (read failure
      / truncated × both drops), `aReplayWithoutACompletionKeepsALivePendingReplyPending`;
      `AppFeatureTests.backgroundRoutesPersistNowToOpenChat`,
      `backgroundWhileRunningBeginsGraceAndKeepsSocketStreaming`,
      `backgroundWhileIdleStartsNoGraceTask` forward `sceneBackgrounded`. Device check
      deferred to Post-Completion: real background grace timing.)
- [x] A foreground re-hydrate after a tool-using turn does not re-read its reply.
      (➕ `foregroundRehydrateAfterASpokenToolTurnNeverRereadsItsReply`,
      `rehydrateSplittingASpokenTurnIntoTwoRowsLeavesNothingPending`,
      `rehydrateKeepsExactlyThePendingReplyPending`, `hydrateMidPlaybackRepointsToTheRebuiltRow`.)
- [x] Screen does not autolock while a turn runs with the toggle on or while speaking; does
      autolock on the session list. (Logic covered by `wantsScreenAwakeNeedsAnOnScreenChatAndOneTrigger`,
      `playbackStartAndFinishToggleTheIdleTimer`, `autoSpeakOnWhileATurnRunsKeepsTheScreenAwake`,
      `aTurnWithAutoSpeakOnStaysAwakeThroughTheReadOfItsReply`,
      `viewDisappearedWhilePlayingReleasesTheScreen`,
      `viewDisappearedReleasesARunningAutoSpeakTurnAndReappearingWakesItAgain`,
      `teardownReleasesTheScreenExplicitly`, `teardownWhilePlayingReleasesTheScreen`. Device
      check deferred to Post-Completion: real autolock.)
- [x] The toggle survives an app relaunch and is off after logout; it does not change the
      agent's `voice.auto_tts` (messaging voice replies unaffected).
      (`PreferencesClientTests.liveAutoSpeakRepliesBacksOntoProvidedDefaults` +
      `inMemoryAutoSpeakRepliesRoundTripAndClear`, `taskWithPrefOnSetsTheFlagAndArmsToTheCompletedCount`,
      `reappearanceDoesNotRereadThePref`; logout: `SettingsFeatureTests.clearTokenDeletesAndEmitsDisconnect`,
      `AppFeatureTests.quitFromReauthFullyLogsOutToOnboarding`,
      `logoutFromRetryScreenClearsEverythingAndShowsFreshOnboarding`; no server write: the
      exhaustive `toggleOnSavesTrueAndArms` / `toggleOffSavesFalseAndKeepsTheAnchor` emit no
      effect, and `HermesRESTClient` has no `/api/config` call.)
- [x] Against an agent with no TTS provider: banner with the server's detail, controls stay.
      Against an older agent without the route (< v2026.6.5, answers 405): controls disappear
      silently. (`badRequestDetailLandsInTheBanner` — exhaustive, `ttsSupported` stays true;
      `missingEndpointHidesReadAloudSilently` (404 + 405), `unsupportedSlotNeverAutoSpeaks`,
      `readAloudStateIsHiddenWhenUnsupportedWhateverThePlayback`;
      `HermesRESTClientTests.speakBadRequestCarriesServerDetail`,
      `speakMethodNotAllowedIsMissingEndpointVerdict`, `speakNotFoundIsMissingEndpointVerdict`.
      Device check against real agents deferred to Post-Completion.)
- [x] Token, cookie, and bearer auth regimes all reach `/api/audio/speak`; a non-default
      profile synthesizes with that profile's TTS provider. (`speak` builds its request via
      `postJSON` → `authFor(conn)` → `resolveAuth` → `RequestAuth.apply`, the same path as every
      REST call. Token: `HermesRESTClientTests.speakDecodesDataURLAndPostsTextBody` (now also
      asserts no `Authorization`); cookie: ➕ `speakInCookieModeSendsNeitherAuthHeader`; bearer:
      ➕ `NativeOAuthClientTests.speakRefreshesFirstAndSendsTheStoreBearer` (refresh hop, then
      `Bearer AT2`). Profile: `speakWithProfileAddsProfileQueryOnly` ("work" + "default"),
      `liveCompletionIsReadPreparingSpeakingFinished` passes `profileName` through. Live-agent
      check of each regime deferred to Post-Completion.)
- [x] run full test suite: `make test` and `make snapshot` (1911 tests passed; snapshots
      250/250)
- [x] `git checkout -- HermesKit/Package.resolved` if it drifted (it did; reverted)

### Task 13: [Final] Update documentation

**Files:**
- Create: `docs/features/read-aloud.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `docs/architecture.md` (REST surface list, if it enumerates endpoints; the replay
  "Past turn boundaries stay past" bullet gains auto-speak)
- Modify: `docs/features/prompt-queue.md` (the drain never barges in on auto-speak)

- [ ] Write `docs/features/read-aloud.md`: the setting's device-local home and why not
      `voice.auto_tts` (upstream #99076), the arming rule (three arm points) and the
      every-hydrate re-base, the speak-check conditions and edges, the completed-row anchor
      rationale (live one row per turn vs history rows), the replay rule and its conflict
      resolution, the barge-in latch (120 s TTL, user submits stamp, every regular submit
      consumes), the lifecycle table (disappear / teardown / socket-only / background /
      foreground / interruption), keep-awake predicate, capability gating by failure (404/405),
      server floor (v2026.6.5), and the deferred rungs (speak-stream, client-direct, lease).
- [ ] Add a 5–8 line CLAUDE.md bullet under "Composer & input" (rule + pointer only).
- [ ] Add a README feature line under the existing feature list.
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion

**Manual verification (device, not simulator):**
- Real audio route checks: speaker, wired/Bluetooth headphones, a phone call arriving
  mid-playback (interruption ends the clip cleanly, no stall banner).
- Both a cloud agent (edge default provider → `speak` returns MP3) and a self-hosted agent
  with ElevenLabs/OpenAI configured, plus one with no provider (400 detail path).
- ⚠️ A provider whose web output is `.ogg`/`.opus` (`audio/ogg`): confirm `AVAudioPlayer`
  plays the Ogg container on the deployment target, else it lands on the "Couldn’t play the
  audio." banner.
- A long reply (> 5 000 chars) to confirm the timeout formula and the watchdog do not fire.

**Follow-ups (separate tickets):**
- Voice-conversation mode: adds `speak-stream` PCM playback via `AVAudioEngine`, the
  `source` field on `ttsPlayback`, the conversation keep-awake condition, and (maybe)
  background audio.
- `tts-lease` warm-up if local engines' first-clip latency turns out to matter.
- Settings → Voice mirror of the toggle if testers go looking there.
