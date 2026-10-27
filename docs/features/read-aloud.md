# Read replies aloud (#74)

The short rules live in `CLAUDE.md` → "Composer & input"; this doc is the full contract.
Design history: `docs/plans/completed/`.

Desktop parity for **"Read replies aloud"**: an auto-speak toggle in the composer that reads
every completed assistant reply, plus a per-message **Read aloud** button in the action bar.
Voice was input-only before (mic → `POST /api/audio/transcribe`). This is also the base for the
later voice-conversation ticket.

## The setting is device-local, not `voice.auto_tts`

`ChatFeature.State.autoSpeakReplies` is a `PreferencesClient` pref (`loadAutoSpeakReplies` /
`saveAutoSpeakReplies` / `clearAutoSpeakReplies`, live key `hermes.auto-speak-replies`, default
off). It is read synchronously once per slot on the first `.task` (behind `hasStarted`).
`.autoSpeakToggled` flips it and saves it. A local write cannot fail, so there is no banner and
no revert. The app never reads or writes `/api/config`.

The server's `voice.auto_tts` is deliberately not used. It is the messaging gateway's
voice-reply default, so mirroring it would turn Telegram/Discord voice replies on and off with
the phone's toggle. Upstream moved the desktop toggle to localStorage for this reason
(`938a3dc8f9`, "keep read-aloud independent of gateway auto-TTS", #99076, first released in
v0.21.6). The desktop also seeds its local value once from `voice.auto_tts`, as a migration of
its own legacy state. Mobile has no legacy state, so it does not seed.

All three full logouts clear the pref: Settings → Log Out, the retry screen's Log Out, and the
re-auth sheet's "Quit to start". It is NOT part of `clearIdentityScopedPrefs`. A re-auth user
switch keeps device UI prefs, the same as the swipe default.

## Synthesis and playback

- **Synthesis = `POST /api/audio/speak?profile=` `{text}` only** (`HermesRESTClient.speak`). It
  returns `{ok, data_url, mime_type, provider}`, and `TTSAudio.parse(dataURL:)` decodes the
  `data:<mime>;base64,…` URL (`audio/mpeg` by default; `audio/ogg`, `audio/wav` and `audio/flac`
  depending on the provider). The profile is the slot's `profileName`, passed verbatim (#114).
  The per-request timeout is `speakTimeout(forCharacterCount:)` = `min(600, max(180, 0.035 ×
  chars))`, the desktop's formula, because synthesis blocks and the server chunks long text.
  Auth goes through the same `RequestAuth` path as every REST call (token, cookie or bearer).
- **The text is sanitized first**: `SpeechText.sanitize` is a step-for-step port of the
  desktop's `sanitizeTextForSpeech` (`apps/desktop/src/lib/speech-text.ts`). Tables become their
  header row, code and URLs become silence, `MEDIA:` tokens and dense identifiers are pruned,
  and list/heading markers are stripped. The identifier rules are tested against the shared
  corpus `tests/fixtures/identifier_speech_corpus.json`, so phone, desktop and the server's
  normalizer say the same thing. The port uses `NSRegularExpression`, not Swift `Regex`, because
  ICU matches code points the way the JS engine does. `MarkdownSegment` is NOT reused: its table
  detection is looser than the desktop's. A reply that sanitizes to empty is skipped and
  consumed (no request is sent).
- **`TTSClient` is a dumb player**: one `AVAudioPlayer` clip at a time, on an `.playback`
  session (mode `.default`, no options). It plays through the silent switch because the user
  explicitly asked to hear the reply. `play` writes a temp file (extension chosen by mime type),
  suspends until the clip ends, and returns normally on finish, on `stop()`, on task
  cancellation, or on an `AVAudioSession` interruption (a call or Siri ends the clip, which is
  not an error). It throws `.failed` if decoding or starting fails, and `.stalled` from a 15 s
  watchdog (the desktop's `PLAYBACK_STALL_MS`). The watchdog is armed before `play()` and
  re-armed whenever `currentTime` advances. Every exit stops the player, deletes the file and
  deactivates the session with `.notifyOthersOnDeactivation`. `stop()` is idempotent and
  returns only after that deactivation. The live actor is behind `#if canImport(UIKit)`, and
  the `testValue` returns immediately.
- **The playback state machine lives in `ChatFeature`**, per slot: `ttsPlayback` is `.idle`,
  `.preparing(rowID)` (synthesizing) or `.speaking(rowID)`. `speakRow` runs one effect,
  cancellable with cancel-in-flight on `CancelID.ttsPlayback`: sanitize → `rest.speak` →
  `.ttsSpeaking` → `tts.play` → `.ttsFinished`, or `.ttsFailed` on any failure. A cancel that
  lands while `speak` is still decoding never reaches `tts.play`. Every stop path goes through
  `silenceReadAloud` (back to `.idle`) and cancels the effect (which drops its trailing
  `.ttsFinished`, so a stop is never a speak edge); `stopReadAloudPlayback` then calls
  `tts.stop()` only if a clip was active (the mic path runs its own ordered stop, below).
  Because playback is slot-owned, it ends when the chat leaves the screen. On
  desktop, playback survives a chat switch; on a phone, stopping when the transcript is no
  longer visible is the expected behaviour.

## The anchor: completed assistant rows

`spokenAssistantCount` counts the COMPLETED assistant message rows that are already consumed:
spoken, skipped, or already present when the toggle was armed. A reply is pending only while
`completedAssistantCount > spokenAssistantCount`. A streaming row never counts. The anchor is
not snapshot-persisted, so every open re-arms.

**Arming** (`arm`: anchor = current completed count) happens at three points:

- toggle-on;
- the first `.task` when the pref is on, so the instant-paint snapshot's replies are never read;
- the slot's first hydrate (`hasHydrated` false → true): in `applyActivate` AND in the
  `session.create` handshake. This runs unconditionally, whatever the toggle says.

**Every later hydrate re-bases** (`rebaseSpokenAnchor`). Keeping the old count would be wrong.
The live fold keeps ONE assistant row per turn (`streamingRowID` survives tool events), while
`reconstructTranscript` emits one row per history assistant message. A hydrate after a
tool-using turn can therefore raise that turn's row count, which would make an already-spoken
turn look pending. The anchor is re-derived from the rebuilt transcript instead:
`completedCount − (wasPending ? 1 : 0)`. `wasPending` is captured
before the rebuild. A hydrate never CREATES a pending reply. It only PRESERVES the one the user
was already waiting on, for example a reply that completed live while the app was
backgrounded. This mirrors the desktop's `absorbSpokenReplyRewrite`, which re-keys its
spoken-row id across the same hydrate rewrite.

Two more consumers:

- **A dropped partial is never spoken.** When `finalizeInFlight` (`.gatewayClosed`,
  `.authExpired`) closes a streaming row, it arms. Whether that turn really finished is for the
  reconnect replay and the hydrate to decide.
- **A failed read stays consumed.** The desktop's `releaseUnplayedSpokenReply` (un-mark on
  failure) is not ported. `.ttsFailed` is itself a speak edge, so un-marking would retry in a
  loop. The user can re-read the reply from the action bar (no automatic retries).

A hydrate that rebuilds the row a clip is attached to re-points `.preparing`/`.speaking` to the
newest completed assistant row of the same turn (turn = user rows before it, captured before
the rebuild), else to the newest completed assistant row (`repointPlaybackAfterRebuild`). The
live `uuid()` row becomes a deterministic history id, and the action bar has to keep showing
the right state. The clip itself keeps playing.

## The speak check

`autoSpeakIfReady` runs at three edges:

- a LIVE `message.complete`;
- every playback-idle edge (`.ttsFinished`, `.ttsFailed`);
- the mic going idle (transcript, failure, cancel, permission denied);
- `.foreground`.

It does NOT run on `.reattached`: navigating back to a chat only puts it back on screen. The
check reads the **newest** assistant row when all of these hold:

- `autoSpeakReplies`, `ttsSupported`, and no active clip;
- `!recording.isBusy`: the mic owns the audio session, and `.playback` would cut the recorder's
  input;
- `!isSceneBackgrounded`, `isOnScreen`, and `!isFoldingReplay`;
- the newest assistant message row is COMPLETE, and a reply is pending.

It then sets the anchor to the full completed count, so a backlog that built up during a clip
collapses to the newest reply. Replies are never queued. If a reply finished during a clip
while the next turn is already streaming, the idle edge waits; that turn's completion then
reads the newest reply. A turn that ends in `.error` is not a `message.complete`, so it is
never spoken.

In `.foreground`, the check runs BEFORE the dead-socket `connect` and the `isReplayReadPending`
early returns. A reply held while backgrounded is therefore read whatever the socket is doing.

`isOnScreen` is set by `.task` (every appearance) and `.reattached`, and cleared by
`.viewDisappeared`. A detached compact slot (#80) is off screen and stays silent. Coming back on
screen arms the anchor (`returnOnScreen`), so a reply that completed off screen is never read
later.

## Replay rule (#98) — past turn boundaries are never read

A `message.complete` folded by `foldReplayedEvents` is a past turn boundary. The fold already
suppresses the drain, park, `runningChanged` and timer side effects for such boundaries
(`docs/architecture.md` → "Reconnect event replay"), and it suppresses auto-speak the same way.
`autoSpeakIfReady` is inert under `isFoldingReplay`. The fold also arms the anchor. This holds
even when the fold completes the still-live streaming row: after `.teardownSocketOnly` nothing
was finalized, so a replayed `message.complete` does mark that row complete. Arming right away
means no speak edge before the trailing hydrate (or after a failed hydrate) can read the reply,
and with nothing pending the hydrate's re-base keeps it consumed. A plain-hydrate reconnect (no
cursor, an older agent, `truncated`, an epoch change, a read failure) ends up in the same place
through the re-base rule. A reply the client never saw complete live arrives only through the
hydrate, and it is not pending.

**The conflict, resolved (option 1, user-confirmed):** "returning to the app reads a reply that
completed while away" now holds only for a LIVE completion. A running turn keeps its socket
for the ~30 s background grace, so its `message.complete` arrives live. `isSceneBackgrounded`
holds it, and `.foreground` reads it. A reply that completes after the grace expired
(`.teardownSocketOnly`, then the foreground redial replays the gap) or during a network drop is
consumed silently. That includes a drop of a few seconds while the user is watching the chat
hands-off. Rejected alternatives: (2) treat a replayed completion as live when it is the newest
reply and the chat is foreground and on screen; (3) speak whatever completed while away, which
drops the rule (desktop parity, since the desktop has no replay gating).

## Barge-in latch

A USER submit while a clip is preparing or playing silences the clip and stamps
`readAloudInterruptedAt = now` (`stopReadAloudPlayback(bargeIn: true)`). This covers both branches of
`.composerSubmitted`:

- the idle send;
- the mid-turn queue append (#66).

The stamp is written only after the submit passes its `canSend` / `canQueue` guards, so a
rejected tap never cuts the clip. A mic tap from `.idle` also stamps, if a clip was active.

**Every regular `prompt.submit` takes the latch** (`takeReadAloudInterruption`). Both regular
builders in `submitDraft` (upload+submit and plain) do this, on the composer path and the
`fromQueue:` drain path alike. A stamp less than 120 s old (the desktop's `INTERRUPT_TTL_MS`)
adds `"interrupted": true` to the params. The stamp is cleared either way, so a stale stamp is
dropped, not carried forward; a submit that then fails does not restore it. Without a stamp, the frame is byte-identical to the legacy one,
including the #17 heal's replay of the same submit. The slash-exec and compress branches do not
take the latch, so a stamp left there rides the next regular prompt or expires.

**The queue drain never barges in.** It fires on the same live `message.complete` that starts
auto-speak, and it must not cut off the reply it just triggered. A drained prompt can still
CARRY a stamp from the user's earlier queued submit (`docs/features/prompt-queue.md`).

**Mic ordering.** `.voiceButtonTapped` runs `await tts.stop()` at the top of its permission
effect, before `requestPermission` and recording. It runs unconditionally, which is safe
because `stop()` is idempotent, and it also serializes behind a Stop tapped just before the
mic. `stop()` deactivates the session with `.notifyOthersOnDeactivation`. If that raced the
recorder, it would kill the recorder's freshly activated `.playAndRecord` session.

The server floor for `interrupted` on `prompt.submit` is v2026.7.30. Older agents read params
with `dict.get` and ignore the key. Validated agents list it in `PromptSubmitParams`.

## Lifecycle

| Event | Playback | Auto-speak |
|---|---|---|
| `.viewDisappeared` | stopped (`releaseVoiceResources`) | `isOnScreen = false`: silent while detached |
| `.teardown` | stopped (`releaseVoiceResources`) | slot gone |
| `.teardownSocketOnly` (grace expiry) | stopped explicitly; this path skips `releaseVoiceResources`, and the clip is normally already stopped by `.sceneBackgrounded` | held (still backgrounded) |
| `.sceneBackgrounded` (`AppFeature` `.background`, before `persistNow`, idle AND running slots) | stopped; no latch (not a barge-in) | held: `isSceneBackgrounded = true` |
| `.foreground` | — | flag cleared, speak check runs (reads a reply held live) |
| `.reattached` (and a later `.task`) | — | `isOnScreen = true` and the anchor armed; NOT a speak edge |
| Audio-session interruption (call, Siri) | clip ends normally, no banner | the idle edge runs the speak check |
| User submit / mic tap | stopped and latch stamped | — |

There is no background audio and no lock-screen control. The background grace keeps the
process alive for a running turn, so the clip has to be stopped explicitly; otherwise it would
keep playing. A push tap's `.foreground` may arrive just before `.active` and clear
`isSceneBackgrounded` slightly early (accepted).

## Keep-awake

`State.wantsScreenAwake = isOnScreen && (ttsPlayback.isActive || (autoSpeakReplies &&
ttsSupported && isSending) || recording.isBusy)` covers the hands-off loop: a clip is preparing
or playing, a turn is running whose reply is about to be read, or the mic is busy (including
transcription). An `.onChange(of: \.wantsScreenAwake)` on the main `Reduce` reports each edge to
`IdleTimerClient.setDisabled`, a synchronous call, so the edges reach
`UIApplication.isIdleTimerDisabled` in reduction order (one FIFO main-queue hop each). Once a
slot is nilled out no edge can fire, so `AppFeature.releaseSlotDeviceResources` sends
`setDisabled(false)` for a slot still awake at every nil-out (`.clearLiveChat` and the identity
teardowns). Off screen, including on the session list, auto-lock behaves normally.

## Capability gating by failure

TTS is not advertised anywhere: not in `/api/status`, not in `gateway.ready`, not in
`client.capabilities`. So the gate is reactive. The first `RESTError.isMissingEndpointVerdict`
from `speak` silently flips `ttsSupported = false`, and both controls disappear: the composer
toggle (`showsAutoSpeak`) and the action-bar button (`State.ReadAloudButtonState.hidden`). That
verdict is FastAPI's unmatched-route 404 (`{"detail": "Not Found"}` or no detail), or the
**405** an older agent returns, because its GET-only SPA catch-all matches the path. A 404 with
any other detail (an unknown `?profile=`) is a `.server(404, detail)` banner. The flag is per slot and unpersisted, so an agent upgrade is picked up by
the next chat. Other errors banner and leave the controls in place:

- a 400 carries the server's `detail` verbatim (e.g. no TTS provider configured, "Text is empty
  after TTS cleanup");
- other statuses use `RESTError.message`;
- `.stalled` → "Playback stalled.";
- `.failed` → "Couldn’t play the audio.".

**Server floor: v2026.6.5** (`POST /api/audio/speak`, shipped with the desktop app). Anything
older hides both controls after the first attempt.

## UI (thin views)

- **Composer toggle** (`ComposerView.autoSpeakButton`, before the attach button):
  `speaker.wave.2.fill` in the accent color when on, `speaker.slash` in secondary when off.
  Accessibility label "Read replies aloud" / "Stop reading replies aloud", with `.isSelected`
  when on. Both glyphs share a `ZStack` so the width stays the same and a tap never
  re-truncates the model chip. Mobile has no voice menu (the desktop's toggle is a voice-menu
  row), so the toggle is a standalone button.
- **`ReadAloudPill`** sits in `ChatView`'s fixed region between the queued-prompts panel and
  the slash suggestions, shown while `ttsPlayback.isActive`. It shows "Preparing audio…" with a
  spinner or "Reading aloud" with `speaker.wave.2`, plus a trailing Stop. It is one fixed line,
  so the region still does not scroll (#65). VoiceOver announces each state, including the
  first appearance.
- **Action bar** (`MessageActionBar`, third button after Copy and Branch) is driven by
  `State.readAloudState(for:)`:
  - `hidden`: unsupported;
  - `idle`: `waveform`, "Read aloud";
  - `disabled`: another row's clip is active, or the mic is busy;
  - `preparing`: spinner, "Preparing audio…";
  - `speaking`: `speaker.slash`, "Stop reading", and a tap sends `.stopReadAloud`.

  `.readAloudTapped` re-checks the guards (supported, no active clip, mic not busy, a completed
  assistant row). It
  raises the anchor past that row and never lowers it, so a newer pending reply stays pending.

## Deferred rungs and out of scope

The desktop tries client-direct synthesis, then the `speak-stream` WS (PCM), then `speak`.
Mobile ships only `speak`, the last rung:

- `speak-stream` arrives with the voice-conversation ticket (`AVAudioEngine` PCM playback);
- client-direct synthesis is skipped on purpose, because it would ship provider API keys to the
  phone;
- the `tts-lease` warm-up only matters for local engines' first-clip latency.

Also out of scope:

- a Settings → Voice mirror of the toggle;
- a playback waveform in the pill;
- background audio and lock-screen controls;
- the desktop's multi-window turn claims (there is one slot on mobile);
- the Shift-click "read the full response group" (no modifier keys on touch).

Device checks still open:

- audio routes (speaker, wired and Bluetooth headphones);
- a call interrupting a clip;
- Ogg/Opus playback from a provider whose output is `audio/ogg`;
- the timeout on a reply longer than 5 000 characters.
