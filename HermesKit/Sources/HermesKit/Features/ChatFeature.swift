import ComposableArchitecture
import Foundation

/// The live chat surface for one session. Owns the WebSocket lifecycle, folds the
/// gateway event stream into a transcript, sends prompts, and reconnects with backoff.
///
/// Session bootstrap (unified): the first `gateway.ready` with no stored id sends
/// `session.create`; any ready *with* a stored id (resume entry, or a reconnect after
/// we've learned the id) sends `session.resume`. History is hydrated over REST.
///
/// Streaming fold rules are verified against the M0 probe: message events carry no id,
/// so a single in-flight assistant row is tracked; `session_id` is frame-level.
@Reducer
public struct ChatFeature {
  @ObservableState
  public struct State: Equatable {
    /// Rows rendered when the chat first opens / after a wholesale hydrate (the bottom window).
    static let initialWindow = 50
    /// Rows revealed per `.loadOlderRequested` (scroll-up).
    static let pageSize = 50

    public var connection: ServerConnection
    /// The active profile this chat is scoped to. `nil` (or `"default"`) means the
    /// default profile — session create/resume and history hydration omit the `profile`
    /// param, byte-identical to the single-profile behavior. A custom profile name is
    /// threaded into `session.create`/`session.resume` and the REST `messages` fetch.
    public var profileName: String?
    public var title: String?
    public var transcript: IdentifiedArrayOf<ChatRow>
    /// Index of the oldest currently-rendered row — the top of the client-side rendering
    /// window over the full in-memory `transcript`. There is NO network pagination: the
    /// server returns the full history in one `session.resume` payload, so this is purely a
    /// client-side window to bound relayout cost on long chats. Defaults to the bottom window
    /// (`max(0, count - initialWindow)`), grows downward as the user pulls in older rows via
    /// `.loadOlderRequested`, and is reset to the bottom window on every wholesale transcript
    /// replace (hydrate). The view renders `visibleRows`, never `transcript` directly.
    public var windowStart: Int
    /// Which transcript rendering engine to use — a device-local A/B preference loaded from
    /// `PreferencesClient` on `.task`. The view switches renderers on this; flipping it (via
    /// Settings) re-instantiates the renderer with the same rows on next chat open.
    public var chatRenderer: ChatRendererKind = .default
    public var composerText: String
    public var status: Status
    public var errorBanner: String?
    public var isSending: Bool
    /// A blocking request from the agent (approval/clarify/secret). While set, the
    /// composer is disabled and a card is the focal point.
    public var pendingInteraction: PendingInteraction?
    /// The tool/skill row whose detail sheet is open, if any (Task 4).
    public var presentedTool: ChatRow?
    /// Current model + reasoning effort (from `session.info`), shown in the composer chip.
    public var model: String?
    public var reasoningEffort: String?
    /// Latest context-window usage (from `session.info` / `message.complete`), driving the
    /// composer's context pill. `nil` until the agent reports usage (old agents never do).
    public var usage: Usage?
    /// The model/reasoning picker sheet, when open (Task 7).
    public var modelPicker: ModelPicker?
    /// Draft text for the rename alert. `nil` = alert closed; non-nil = alert open
    /// with the in-progress title (Task 4).
    public var renameDraft: String?
    /// Token of the code block whose copy button was most recently tapped, for the
    /// transient "copied" checkmark. Cleared by a clock-driven effect (#9).
    public var recentlyCopiedToken: String?
    /// Voice-input recording lifecycle (#7).
    public var recording: RecordingState
    /// Rolling window of normalized (0...1) mic amplitudes driving the recording waveform.
    public var waveformLevels: [Float]
    /// Seconds elapsed while recording, for the composer's mm:ss readout.
    public var recordingSeconds: Int
    /// Seconds elapsed in the in-flight turn's live "Thinking" indicator. Ticked by a
    /// cancellable `continuousClock` loop while a turn runs; baked into the row's
    /// `elapsedSeconds` and reset to 0 on completion. The active row's view renders this.
    public var thinkingSeconds: Int
    /// Files staged for the next message (#8), uploaded on submit.
    public var attachments: [ComposerAttachment]
    /// Set once the agent rejects an attach RPC as unknown (`-32601`) — too old to support
    /// uploads. Hides the attach affordance for the rest of the session.
    public var attachmentsUnsupported: Bool

    /// Voice-input state machine: tap mic → permission → record (waveform) → stop →
    /// transcribe → text appended to the composer.
    public enum RecordingState: Equatable, Sendable {
      case idle
      case requestingPermission
      case recording
      case transcribing

      /// Anything other than `.idle` means the composer is in voice mode.
      public var isBusy: Bool { self != .idle }
    }

    /// State for the interactive model + reasoning-effort picker.
    public struct ModelPicker: Equatable, Sendable {
      public var isLoading: Bool
      public var options: ModelOptions?
      public var error: String?

      public init(isLoading: Bool = true, options: ModelOptions? = nil, error: String? = nil) {
        self.isLoading = isLoading
        self.options = options
        self.error = error
      }
    }

    // Bookkeeping (internal).
    var liveSessionID: String?
    var storedSessionID: String?
    var streamingRowID: ChatRow.ID?
    var thinkingRowID: ChatRow.ID?
    var toolRowIDs: [String: ChatRow.ID]
    var reconnectAttempt: Int
    var hasRequestedSession: Bool
    /// Set when the gated session died (`.authExpired`): reconnect backoff is paused and the
    /// trailing `.gatewayClosed` (the finished stream) is ignored until re-auth resumes us.
    var awaitingReauth: Bool

    public enum Status: Equatable, Sendable {
      case connecting
      case ready
      case reconnecting
    }

    /// A blocking interactive request the agent is waiting on.
    public enum PendingInteraction: Equatable, Sendable {
      case approval(ApprovalRequest)
      case clarify(ClarifyRequest)        // wired in Task 10
      case secret(SecretKind, SecretPrompt) // wired in Task 10

      public enum SecretKind: Equatable, Sendable { case sudo, secret }
    }

    public init(
      connection: ServerConnection,
      resumeStoredID: String? = nil,
      profileName: String? = nil,
      title: String? = nil,
      transcript: IdentifiedArrayOf<ChatRow> = [],
      composerText: String = "",
      status: Status = .connecting,
      chatRenderer: ChatRendererKind = .default
    ) {
      self.connection = connection
      self.chatRenderer = chatRenderer
      self.profileName = profileName
      self.storedSessionID = resumeStoredID
      self.title = title
      self.transcript = transcript
      self.composerText = composerText
      self.status = status
      self.errorBanner = nil
      self.isSending = false
      self.liveSessionID = nil
      self.streamingRowID = nil
      self.thinkingRowID = nil
      self.toolRowIDs = [:]
      self.reconnectAttempt = 0
      self.hasRequestedSession = false
      self.awaitingReauth = false
      self.pendingInteraction = nil
      self.presentedTool = nil
      self.model = nil
      self.reasoningEffort = nil
      self.usage = nil
      self.modelPicker = nil
      self.renameDraft = nil
      self.recentlyCopiedToken = nil
      self.recording = .idle
      self.waveformLevels = []
      self.recordingSeconds = 0
      self.thinkingSeconds = 0
      self.attachments = []
      self.attachmentsUnsupported = false

      // Instant paint: read the non-authoritative snapshot synchronously so the chat shows
      // its cached tail + model/usage immediately, before `session.resume` lands. The
      // server always wins on hydrate (these rows are replaced wholesale in `applyActivate`).
      // Only paint when the caller didn't already supply a transcript and we have a stored
      // session id to look up.
      //
      // NOTE: this is the *only* init-time dependency read in HermesKit — a deliberate,
      // one-of-its-kind exception. It relies on TCA propagating the dependency context into
      // `State.init` (the store/preview supplies `\.chatSnapshot`), which only holds for this
      // synchronous instant-paint path. Do NOT copy this pattern into other feature inits;
      // everywhere else, read dependencies from the reducer (`@Dependency`), not from `init`.
      var resolvedTranscript = transcript
      if transcript.isEmpty, let storedID = resumeStoredID,
         let snapshot = Dependency(\.chatSnapshot).wrappedValue.loadSnapshot(storedID) {
        resolvedTranscript = IdentifiedArrayOf(uniqueElements: snapshot.rows)
        self.transcript = resolvedTranscript
        self.model = snapshot.model
        self.reasoningEffort = snapshot.reasoningEffort
        self.usage = snapshot.usage
      }

      // Open at the bottom window over whatever transcript we ended up with (instant-paint
      // snapshot or a caller-supplied one). Hydrate later resets this again — server wins.
      self.windowStart = State.bottomWindowStart(count: resolvedTranscript.count)
    }

    /// The bottom (newest) rendering window over a transcript of `count` rows.
    static func bottomWindowStart(count: Int) -> Int { max(0, count - initialWindow) }

    /// True when older rows exist above the current window — drives the scroll-up "load more"
    /// sentinel in the view.
    public var hasMoreAbove: Bool { windowStart > 0 }

    /// The view boundary: the windowed slice of `transcript` from `windowStart` to the end.
    /// Newly appended (streaming) rows always fall after `windowStart`, so they stay visible.
    public var visibleRows: ArraySlice<ChatRow> {
      let count = transcript.count
      guard count > 0 else { return [] }
      let start = min(max(0, windowStart), count)
      return transcript.elements[start..<count]
    }

    public var canSend: Bool {
      let hasContent = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.isEmpty
      return hasContent
        && liveSessionID != nil
        && pendingInteraction == nil
    }

    /// Rename is only meaningful once we have a live session id (otherwise `confirmRename`
    /// silently no-ops) — drives whether the toolbar Rename control is enabled.
    public var canRename: Bool { liveSessionID != nil }

    /// The profile name to thread into session create/resume + REST scoping, or `nil` for
    /// the default profile. Treating the default name as `nil` keeps requests byte-identical
    /// to the single-profile behavior. The canonical default name lives on
    /// `SessionListFeature.State.defaultProfileName` (single source of truth).
    var scopedProfile: String? {
      guard let name = profileName, name != SessionListFeature.State.defaultProfileName
      else { return nil }
      return name
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case delegate(Delegate)
    case task
    case onDisappear
    /// Scroll-up reached the top of the current window: reveal another `pageSize` of older
    /// rows from the in-memory transcript (client-side only — no network call).
    case loadOlderRequested
    case thinkingTick
    case gatewayEvent(GatewayEvent)
    case gatewayClosed
    case reconnectTick
    /// Re-auth succeeded for the *same* user (`AppFeature`): swap in the fresh `AuthSession`
    /// and reconnect the (previously paused) socket so the chat resumes in place.
    case resumeAfterReauth(ServerConnection)
    /// Fires after the persist debounce window — writes a fresh snapshot to the cache.
    case persistSnapshotTick
    /// App is backgrounding/inactivating — flush the snapshot to the cache IMMEDIATELY
    /// (cancel the pending debounce, write now) and reaffirm the turn-start anchor while a
    /// turn is in flight, so a process kill doesn't lose the latest paint or timer anchor.
    case persistNow
    /// App returned to the foreground — reconnect the socket and re-`hydrate` (re-read
    /// running/inflight/usage) via the same unified path used by open/cold-launch.
    case foreground
    case sessionResult(Result<SessionHandle, GatewayError>)
    /// Result of the `session.resume` hydration call — the server-authoritative
    /// re-hydration payload (messages + info + running + inflight). (The associated
    /// `ActivateResponse` type keeps its name; the RPC used is `session.resume`.)
    case activateResult(Result<ActivateResponse, GatewayError>)
    case usageResponse(Usage)
    case composerSubmitted
    case promptSubmitFailed(message: String)
    /// A self-heal re-resume/recreate landed a fresh live session id for an outbound RPC that
    /// failed with "session not found" (#17). Apply it WITHOUT a wholesale transcript rebuild
    /// (unlike `activateResult`) so the optimistic user/attachment row stays put while the
    /// retried RPC replays. Carries the fresh stored id too when the heal learned one.
    case liveSessionIDRefreshed(liveSessionID: String, storedSessionID: String?)
    case interruptTapped
    case respondToApproval(approve: Bool, all: Bool)
    case respondToClarify(answer: String)
    case respondToSecret(value: String)
    case copyRow(id: ChatRow.ID)
    case copyCode(text: String, token: String)
    case copyFeedbackExpired(token: String)
    // Voice input (#7)
    case voiceButtonTapped
    case recordingPermission(Bool)
    case recordingStarted
    case recordingLevel(Float)
    case recordingTick
    case recordingStopped(RecordedAudio)
    case transcriptionSucceeded(String)
    case voiceInputFailed(message: String)
    case recordingCancelled
    case toolTapped(id: ChatRow.ID)
    case toolDetailDismissed
    case modelChipTapped
    case modelOptionsResponse(Result<ModelOptions, GatewayError>)
    case modelSelected(String)
    case reasoningSelected(String)
    case modelPickerDismissed
    case renameButtonTapped
    case confirmRename
    case renameFailed(previousTitle: String?)
    case cancelRename
    // Attachments (#8)
    case attachPhotosTapped
    case attachCameraTapped
    case attachFilesTapped
    case attachmentAdded(ComposerAttachment)
    case removeAttachment(id: ComposerAttachment.ID)
    case attachmentsSubmitted(displayText: String, images: [Data], rowID: UUID)
    case attachmentUploadFailed(message: String)
    case attachmentsUnsupportedDetected

    /// Signals the parent (`AppFeature`) routes: the dead-session signal that raises the
    /// re-auth modal (reconnect backoff is paused for it), and the authoritative
    /// working-state change that drives the session-list glow.
    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// The gated session is fully dead (ws-ticket `401`). Re-auth is required — do **not**
      /// keep retrying the socket.
      case sessionExpired
      /// The agent's authoritative working state for this session changed — emitted on
      /// `message.start` (running), `message.complete`/`error` (stopped), and from the
      /// `session.resume` `running` flag on hydrate. The parent routes this to the
      /// session list so the row's working glow clears/sets INSTANTLY (event-driven),
      /// rather than waiting for the next poll. Always server-confirmed — never a cached
      /// guess (the SQLite `running-guess` must never start a glow on its own).
      case runningChanged(sessionID: String, running: Bool)
    }
  }

  private enum CancelID { case socket, reconnect, copyFeedback, voiceLevels, voiceTimer, thinkingTimer, persist }

  /// Debounce window for write-back so heavy streaming doesn't thrash SQLite.
  private static let persistDebounce: Duration = .seconds(1)

  @Dependency(\.hermesGateway) var gateway
  @Dependency(\.hermesREST) var rest
  @Dependency(\.chatSnapshot) var chatSnapshot
  @Dependency(\.preferences) var preferences
  @Dependency(\.date.now) var now
  @Dependency(\.continuousClock) var clock
  @Dependency(\.uuid) var uuid
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.audioRecorder) var audioRecorder
  @Dependency(\.attachmentPicker) var attachmentPicker
  @Dependency(\.debugLog) var debugLog

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .delegate:
        // Bubbled to the parent (AppFeature) — no local state change.
        return .none

      case .task:
        // Load the device-local A/B renderer preference so the view can pick the engine.
        state.chatRenderer = preferences.loadChatRenderer()
        // History is now hydrated server-authoritatively from the `session.resume`
        // response on `.ready` — see `hydrate`. No separate
        // REST `loadHistory` call: the activate response carries `messages` + `info` +
        // `running` + `inflight`, and rebuilding the transcript wholesale from it is what
        // keeps model/usage/status correct on every re-open (the core state-sync fix).
        return connect(state.connection)

      case .onDisappear:
        let wasRecording = state.recording.isBusy
        state.recording = .idle
        state.waveformLevels = []
        state.recordingSeconds = 0
        return .merge(
          .cancel(id: CancelID.socket),
          .cancel(id: CancelID.reconnect),
          .cancel(id: CancelID.voiceLevels),
          .cancel(id: CancelID.voiceTimer),
          .cancel(id: CancelID.thinkingTimer),
          .cancel(id: CancelID.persist),
          // Release the mic/session if we leave mid-recording.
          wasRecording ? .run { [audioRecorder] _ in await audioRecorder.cancel() } : .none
        )

      case .loadOlderRequested:
        // Reveal another page of older rows, clamped at the top of the transcript. Purely a
        // window move over the already-fetched in-memory transcript (no network).
        state.windowStart = max(0, state.windowStart - State.pageSize)
        return .none

      case .thinkingTick:
        state.thinkingSeconds += 1
        return .none

      case let .gatewayEvent(event):
        // Snapshot whether the user is parked at the bottom window *before* the fold appends any
        // streaming rows, so we can re-pin afterward without yanking a user who scrolled up.
        let wasAtBottomWindow = state.windowStart >= State.bottomWindowStart(count: state.transcript.count)
        let effect = reduce(event: event, into: &state)
        maintainWindowAfterStreaming(wasAtBottomWindow: wasAtBottomWindow, into: &state)
        // Write-back: any event that mutates the transcript / model / usage schedules a
        // debounced snapshot persist so the next open paints instantly. Debounced (and
        // cancel-in-flight) so heavy streaming coalesces into one SQLite write. Gated on a
        // known session id — nothing to key the snapshot on (and nothing to persist) until
        // the session resolves.
        guard persistRelevant(event), state.storedSessionID != nil || state.liveSessionID != nil
        else { return effect }
        return .merge(effect, debouncedPersist())

      case .gatewayClosed:
        state.hasRequestedSession = false
        // Finalize anything mid-stream so a dropped socket doesn't leave a row
        // spinning forever; the transcript itself persists across the reconnect.
        finalizeInFlight(into: &state)
        // A dead session already paused us (see `.authExpired`): the stream finishing is just
        // the tail of that — don't schedule a backoff reconnect, wait for re-auth.
        guard !state.awaitingReauth else { return .cancel(id: CancelID.thinkingTimer) }
        state.status = .reconnecting
        state.reconnectAttempt += 1
        let delay = backoffDelay(attempt: state.reconnectAttempt)
        return .merge(
          .cancel(id: CancelID.thinkingTimer),
          .run { [clock] send in
            try await clock.sleep(for: delay)
            await send(.reconnectTick)
          }
          .cancellable(id: CancelID.reconnect, cancelInFlight: true)
        )

      case .reconnectTick:
        return connect(state.connection)

      case let .resumeAfterReauth(connection):
        // The re-auth modal minted a fresh session for the same user. Swap in the new auth
        // regime (fresh cookies), lift the pause, and reconnect — the socket re-mints a
        // ws-ticket from the new cookies and the transcript resumes in place.
        state.connection = connection
        state.awaitingReauth = false
        state.status = .reconnecting
        state.reconnectAttempt = 0
        return .merge(
          .cancel(id: CancelID.reconnect),
          connect(connection)
        )

      case let .sessionResult(.success(handle)):
        // `session.create` only — a fresh session has no context yet, so no usage fetch.
        // (Re-hydration of a stored session goes through `.activateResult` instead.)
        state.liveSessionID = handle.sessionID
        state.storedSessionID = handle.storedSessionID ?? state.storedSessionID
        state.status = .ready
        return .none

      case let .usageResponse(usage):
        state.usage = usage
        return .none

      case let .sessionResult(.failure(error)):
        // A dropped socket (e.g. lock/unlock) reconnects on its own — the `.reconnecting`
        // status conveys it; don't raise a banner that would linger past reconnect. Surface
        // only real protocol/server failures.
        if error.isDisconnected {
          state.status = .reconnecting
        } else {
          state.errorBanner = error.message
        }
        return .none

      case let .activateResult(.success(response)):
        return applyActivate(response, into: &state)

      case let .activateResult(.failure(error)):
        // A real server "session not found" from the foreground `session.resume` is NOT a
        // benign socket drop: the stored id the agent had is gone (e.g. it expired/rebuilt).
        // Don't leave a stale `liveSessionID` standing (the next prompt.submit would fail too) —
        // recreate a fresh session so the chat can keep sending (#17). Keep the cached paint.
        if error.isSessionNotFound {
          state.status = .reconnecting
          state.liveSessionID = nil
          state.hasRequestedSession = true // createSession is the in-flight request
          return createSession(profile: state.scopedProfile)
        }
        // Offline / connection error: keep the cached instant-paint on screen (never blank
        // it) and show a subtle reconnecting status. The cached rows stay until a successful
        // resume replaces them wholesale. A plain `.disconnected` (the socket dropped — e.g.
        // lock/unlock) is already conveyed by the `.reconnecting` status, so we do NOT raise a
        // banner for it (it would otherwise linger after reconnect); only a real protocol/server
        // error gets a banner.
        state.status = .reconnecting
        if !error.isDisconnected { state.errorBanner = error.message }
        return .none

      case .persistSnapshotTick:
        // Debounced write-back landed: persist a fresh non-authoritative snapshot.
        return persistSnapshotNow(state)

      case .persistNow:
        // App backgrounding: don't wait for the 1s debounce — cancel it and write the
        // snapshot synchronously now. Reaffirm the turn-start anchor while a turn is in
        // flight so a kill mid-turn doesn't lose the elapsed-timer start instant.
        let anchor = state.isSending ? setTurnAnchor(state) : .none
        return .merge(
          .cancel(id: CancelID.persist),
          persistSnapshotNow(state),
          anchor
        )

      case .foreground:
        // App returned to the foreground: reconnect + re-`hydrate` via the same socket path
        // used on open. A live socket is torn down on `.onDisappear`/background, so reconnect
        // re-fires `.ready` → `hydrate`, re-reading the authoritative running/inflight/usage.
        //
        // Reset `hasRequestedSession` so the fresh `.ready` actually re-hydrates. On a fast
        // background→foreground the prior socket may still be alive; `connect`'s
        // `cancelInFlight` then cancels it mid-`for await`, and TCA drops the cancelled
        // task's trailing `await send(.gatewayClosed)` — the only place that resets the flag.
        // Without this reset the flag stays `true` and the new `.ready` short-circuits at the
        // `guard !state.hasRequestedSession` below, so foreground would never re-hydrate.
        state.hasRequestedSession = false
        return connect(state.connection)

      case .composerSubmitted:
        guard state.canSend, let sessionID = state.liveSessionID else { return .none }
        let text = state.composerText

        // With attachments we must upload bytes first (iOS shares no FS with the agent),
        // then submit — so we keep the composer/attachments until success and only echo the
        // user row once the upload+submit lands (a failed upload mustn't lose the input).
        if !state.attachments.isEmpty {
          let attachments = state.attachments
          state.errorBanner = nil
          state.isSending = true
          for index in state.attachments.indices { state.attachments[index].uploadState = .uploading }
          // Anchor the turn start so a hydrate while it runs resumes the elapsed timer.
          let anchor = setTurnAnchor(state)
          let stored = state.storedSessionID
          let profile = state.scopedProfile
          return .merge(anchor, .run { [gateway, uuid] send in
            // The uploads + submit target the live id, which can be stale after a
            // background→foreground; self-heal the whole upload→submit sequence once on a
            // "session not found" by re-resuming for a fresh id and replaying (#17). The
            // uploads are idempotent (the agent re-stages the bytes against the fresh session).
            func runUploadAndSubmit(_ targetID: String) async throws {
              var refs: [String] = []
              for attachment in attachments {
                if let ref = try await uploadAttachment(attachment, sessionID: targetID, gateway: gateway) {
                  refs.append(ref)
                }
              }
              // `@file:` refs (from file.attach) go on their own lines above the text;
              // image/pdf are picked up from session state by prompt.submit.
              let body = (refs + (text.isEmpty ? [] : [text])).joined(separator: "\n")
              _ = try await gateway.send("prompt.submit", .object([
                "session_id": .string(targetID), "text": .string(body),
              ]))
            }
            do {
              // Stale live id: re-resume/recreate for a fresh one, apply it, replay the whole
              // upload→submit sequence once (uploads are idempotent).
              try await withSessionHeal(
                runUploadAndSubmit, sessionID: sessionID, storedSessionID: stored,
                profile: profile, gateway: gateway, send: send
              )
              // Echo images as thumbnails in the bubble; non-image files (no thumbnail)
              // fall back to their names when there's no typed text.
              let images = attachments.filter { $0.kind == .image }.map(\.data)
              let nonImageNames = attachments.filter { $0.kind != .image }.map(\.filename)
              let display = text.isEmpty ? nonImageNames.joined(separator: ", ") : text
              await send(.attachmentsSubmitted(displayText: display, images: images, rowID: uuid()))
            } catch let error as GatewayError {
              // An old agent without the byte-upload methods → gate the feature off.
              if error.isUnknownMethod {
                await send(.attachmentsUnsupportedDetected)
              } else {
                await send(.attachmentUploadFailed(message: error.message))
              }
            } catch {
              await send(.attachmentUploadFailed(message: GatewayError.disconnected.message))
            }
          })
        }

        let wasAtBottomWindow = state.windowStart >= State.bottomWindowStart(count: state.transcript.count)
        state.transcript.append(ChatRow(id: uuid(), kind: .message(role: .user, text: text, isComplete: true)))
        maintainWindowAfterStreaming(wasAtBottomWindow: wasAtBottomWindow, into: &state)
        state.composerText = ""
        state.errorBanner = nil
        state.isSending = true
        // Anchor the turn start so a hydrate while it runs resumes the elapsed timer.
        let anchor = setTurnAnchor(state)
        // prompt.submit acks fast (`{status:"streaming"}`); the turn streams via events,
        // so success does nothing here — only a thrown error (timeout / server / drop)
        // surfaces. Don't swallow it (Issue #6: a stuck server left the spinner hung). A stale
        // live id after background→foreground answers "session not found" — self-heal once by
        // re-resuming for a fresh id and replaying the submit (#17).
        let stored = state.storedSessionID
        let profile = state.scopedProfile
        return .merge(anchor, .run { [gateway] send in
          await submitPrompt(
            sessionID: sessionID, storedSessionID: stored, profile: profile,
            gateway: gateway, send: send
          ) { healedID in
            _ = try await gateway.send("prompt.submit", .object([
              "session_id": .string(healedID), "text": .string(text),
            ]))
          }
        })

      case let .promptSubmitFailed(message):
        state.errorBanner = "Prompt failed: \(message)"
        state.isSending = false
        // The anchor was written on submit; a failed submit never starts a turn (no
        // `message.start`/`complete` to clear it), so clear it here. This keeps every
        // `setTurnAnchor` paired with a clear, so anchors can't accumulate for sessions that
        // never produce a snapshot row (those aren't counted by the LRU sweep, which only
        // evicts `sessions` rows).
        return clearTurnAnchor(state)

      case let .liveSessionIDRefreshed(liveSessionID, storedSessionID):
        // Self-heal landed a fresh runtime id (#17). Swap it in so subsequent RPCs target the
        // valid session; do NOT touch the transcript (the retried RPC's events repaint it, and a
        // wholesale replace here would wipe the optimistic user/attachment row mid-retry).
        state.liveSessionID = liveSessionID
        state.storedSessionID = storedSessionID ?? state.storedSessionID
        state.status = .ready
        return .none

      case .interruptTapped:
        guard let sessionID = state.liveSessionID else { return .none }
        state.isSending = false
        // Freeze the live thinking row + stop the elapsed timer (mirrors the `.error` /
        // socket-drop turn-ending paths) so an interrupt doesn't leave it shimmering forever.
        freezeThinking(into: &state)
        return .merge(
          .cancel(id: CancelID.thinkingTimer),
          // Interrupt ends the turn — drop the anchor so it can't resurrect on hydrate.
          clearTurnAnchor(state),
          .run { [gateway] _ in
            _ = try? await gateway.send("session.interrupt", .object(["session_id": .string(sessionID)]))
          }
        )

      case let .respondToApproval(approve, all):
        guard case .approval = state.pendingInteraction,
              let sessionID = state.liveSessionID
        else { return .none }
        state.pendingInteraction = nil
        state.transcript.append(
          ChatRow(id: uuid(), kind: .status(kind: "approval", text: approve ? "Approved" : "Denied"))
        )
        // Choice vocabulary matches `tools/approval.py`: "deny" blocks; "once" allows
        // just this command; "session" persists the pattern for the rest of the session
        // (the "Approve all in this session" toggle). Approvals are resolved by the
        // server's per-session queue, so NO `request_id` is sent (unlike clarify/secret);
        // `all` maps to `resolve_all` to clear any other queued approvals at once.
        let choice = approve ? (all ? "session" : "once") : "deny"
        return .run { [gateway] _ in
          _ = try? await gateway.send("approval.respond", .object([
            "session_id": .string(sessionID),
            "choice": .string(choice),
            "all": .bool(all),
          ]))
        }

      case let .respondToClarify(answer):
        guard case let .clarify(request) = state.pendingInteraction,
              let sessionID = state.liveSessionID
        else { return .none }
        state.pendingInteraction = nil
        // Echo the answer so the transcript records what was chosen/typed.
        state.transcript.append(
          ChatRow(id: uuid(), kind: .status(kind: "clarify", text: answer))
        )
        let requestID = request.requestID
        return .run { [gateway] _ in
          _ = try? await gateway.send("clarify.respond", .object([
            "session_id": .string(sessionID),
            "request_id": .string(requestID),
            "answer": .string(answer),
          ]))
        }

      case let .respondToSecret(value):
        guard case let .secret(kind, prompt) = state.pendingInteraction,
              let sessionID = state.liveSessionID
        else { return .none }
        state.pendingInteraction = nil
        // Never echo the secret value into the transcript.
        let label = kind == .sudo ? "Password submitted" : "Secret submitted"
        state.transcript.append(
          ChatRow(id: uuid(), kind: .status(kind: "secret", text: label))
        )
        // Method + value key differ per kind (verified against tui_gateway/server.py):
        // sudo.respond → "password", secret.respond → "value".
        let method = kind == .sudo ? "sudo.respond" : "secret.respond"
        let valueKey = kind == .sudo ? "password" : "value"
        let requestID = prompt.requestID
        return .run { [gateway] _ in
          _ = try? await gateway.send(method, .object([
            "session_id": .string(sessionID),
            "request_id": .string(requestID),
            valueKey: .string(value),
          ]))
        }

      case let .copyRow(id):
        guard let text = state.transcript[id: id]?.copyText, !text.isEmpty else { return .none }
        return .run { [pasteboard] _ in pasteboard.copy(text) }

      case let .copyCode(text, token):
        guard !text.isEmpty else { return .none }
        state.recentlyCopiedToken = token
        // Copy now; clear the checkmark after a beat. Re-tapping any block restarts
        // the timer (cancelInFlight) so the latest copy owns the feedback.
        return .merge(
          .run { [pasteboard] _ in pasteboard.copy(text) },
          .run { [clock] send in
            try await clock.sleep(for: .seconds(1.5))
            await send(.copyFeedbackExpired(token: token))
          }
          .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
        )

      case let .copyFeedbackExpired(token):
        if state.recentlyCopiedToken == token { state.recentlyCopiedToken = nil }
        return .none

      // MARK: Voice input (#7)

      case .voiceButtonTapped:
        switch state.recording {
        case .idle:
          state.recording = .requestingPermission
          return .run { [audioRecorder] send in
            await send(.recordingPermission(audioRecorder.requestPermission()))
          }
        case .recording:
          // Stop and hand the audio off to transcription.
          state.recording = .transcribing
          return .merge(
            .cancel(id: CancelID.voiceLevels),
            .cancel(id: CancelID.voiceTimer),
            .run { [audioRecorder] send in
              await send(.recordingStopped(try await audioRecorder.stopRecording()))
            } catch: { _, send in
              await send(.voiceInputFailed(message: "Couldn’t finish recording."))
            }
          )
        case .requestingPermission, .transcribing:
          return .none
        }

      case let .recordingPermission(granted):
        guard granted else {
          state.recording = .idle
          state.errorBanner = "Microphone access is off. Enable it in Settings to use voice input."
          return .none
        }
        return .run { [audioRecorder] send in
          try await audioRecorder.startRecording()
          await send(.recordingStarted)
        } catch: { _, send in
          await send(.voiceInputFailed(message: "Couldn’t start recording."))
        }

      case .recordingStarted:
        state.recording = .recording
        state.waveformLevels = []
        state.recordingSeconds = 0
        return .merge(
          .run { [audioRecorder] send in
            for await level in audioRecorder.levels() {
              await send(.recordingLevel(level))
            }
          }
          .cancellable(id: CancelID.voiceLevels, cancelInFlight: true),
          .run { [clock] send in
            while true {
              try await clock.sleep(for: .seconds(1))
              await send(.recordingTick)
            }
          }
          .cancellable(id: CancelID.voiceTimer, cancelInFlight: true)
        )

      case let .recordingLevel(level):
        state.waveformLevels.append(level)
        let maxBars = 48
        if state.waveformLevels.count > maxBars {
          state.waveformLevels.removeFirst(state.waveformLevels.count - maxBars)
        }
        return .none

      case .recordingTick:
        state.recordingSeconds += 1
        return .none

      case let .recordingStopped(audio):
        return .run { [rest, connection = state.connection] send in
          do {
            let text = try await rest.transcribe(connection, audio.dataURL, audio.mimeType)
            await send(.transcriptionSucceeded(text))
          } catch {
            let message = (error as? RESTError)?.message ?? "Couldn’t transcribe the audio."
            await send(.voiceInputFailed(message: message))
          }
        }

      case let .transcriptionSucceeded(text):
        state.recording = .idle
        state.waveformLevels = []
        state.recordingSeconds = 0
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
          // Append to whatever's already typed, with a single separating space.
          if state.composerText.isEmpty {
            state.composerText = transcript
          } else {
            state.composerText += (state.composerText.hasSuffix(" ") ? "" : " ") + transcript
          }
        }
        return .none

      case let .voiceInputFailed(message):
        state.recording = .idle
        state.waveformLevels = []
        state.recordingSeconds = 0
        state.errorBanner = message
        return .merge(.cancel(id: CancelID.voiceLevels), .cancel(id: CancelID.voiceTimer))

      case .recordingCancelled:
        state.recording = .idle
        state.waveformLevels = []
        state.recordingSeconds = 0
        return .merge(
          .cancel(id: CancelID.voiceLevels),
          .cancel(id: CancelID.voiceTimer),
          .run { [audioRecorder] _ in await audioRecorder.cancel() }
        )

      // MARK: Attachments (#8)

      case .attachPhotosTapped:
        return .run { [attachmentPicker, uuid] send in
          for item in await attachmentPicker.pickPhotos() {
            await send(.attachmentAdded(item.attachment(id: uuid())))
          }
        }

      case .attachCameraTapped:
        return .run { [attachmentPicker, uuid] send in
          for item in await attachmentPicker.capturePhoto() {
            await send(.attachmentAdded(item.attachment(id: uuid())))
          }
        }

      case .attachFilesTapped:
        return .run { [attachmentPicker, uuid] send in
          for item in await attachmentPicker.pickFiles() {
            await send(.attachmentAdded(item.attachment(id: uuid())))
          }
        }

      case let .attachmentAdded(attachment):
        state.attachments.append(attachment)
        return .none

      case let .removeAttachment(id):
        state.attachments.removeAll { $0.id == id }
        return .none

      case let .attachmentsSubmitted(displayText, images, rowID):
        // Upload + submit landed: echo the user row (with image thumbnails), clear composer +
        // attachments. isSending stays true — the turn streams (clears on completion).
        let wasAtBottomWindow = state.windowStart >= State.bottomWindowStart(count: state.transcript.count)
        state.transcript.append(ChatRow(
          id: rowID,
          kind: .message(role: .user, text: displayText, isComplete: true),
          attachmentImages: images
        ))
        maintainWindowAfterStreaming(wasAtBottomWindow: wasAtBottomWindow, into: &state)
        state.composerText = ""
        state.attachments = []
        return .none

      case let .attachmentUploadFailed(message):
        // Keep the composer text + attachments so the user can retry; just flag the failure.
        state.errorBanner = "Attachment failed: \(message)"
        state.isSending = false
        for index in state.attachments.indices { state.attachments[index].uploadState = .failed(message) }
        // The attachment-submit path wrote the turn anchor; a failed upload never starts a
        // turn, so clear it — keeping every `setTurnAnchor` paired with a clear (mirrors
        // `.promptSubmitFailed`).
        return clearTurnAnchor(state)

      case .attachmentsUnsupportedDetected:
        // The agent is too old to accept uploads: hide the affordance for the session and
        // explain why, rather than leaving the user with a generic RPC error.
        state.attachmentsUnsupported = true
        state.isSending = false
        state.errorBanner = "This Hermes agent is too old to accept attachments. Update the agent to send files."
        for index in state.attachments.indices { state.attachments[index].uploadState = .failed("Attachments not supported") }
        return .none

      case let .toolTapped(id):
        guard let row = state.transcript[id: id], case .tool = row.kind else { return .none }
        state.presentedTool = row
        return .none

      case .toolDetailDismissed:
        state.presentedTool = nil
        return .none

      case .modelChipTapped:
        guard let sessionID = state.liveSessionID else { return .none }
        state.modelPicker = State.ModelPicker(isLoading: true)
        return .run { [gateway] send in
          do {
            let result = try await gateway.send("model.options", .object(["session_id": .string(sessionID)]))
            if let options = result.decoded(ModelOptions.self) {
              await send(.modelOptionsResponse(.success(options)))
            } else {
              await send(.modelOptionsResponse(.failure(.server("Malformed model.options result"))))
            }
          } catch let error as GatewayError {
            await send(.modelOptionsResponse(.failure(error)))
          } catch {
            await send(.modelOptionsResponse(.failure(.disconnected)))
          }
        }

      case let .modelOptionsResponse(.success(options)):
        state.modelPicker?.isLoading = false
        state.modelPicker?.options = options
        return .none

      case let .modelOptionsResponse(.failure(error)):
        state.modelPicker?.isLoading = false
        state.modelPicker?.error = error.message
        return .none

      case let .modelSelected(model):
        // Blocked mid-turn (server returns 4009); the picker disables selection too.
        guard !state.isSending, let sessionID = state.liveSessionID else { return .none }
        state.model = model // optimistic; reconciled by the next session.info
        return configSet(key: "model", value: model, sessionID: sessionID)

      case let .reasoningSelected(effort):
        guard !state.isSending, let sessionID = state.liveSessionID else { return .none }
        state.reasoningEffort = effort
        return configSet(key: "reasoning", value: effort, sessionID: sessionID)

      case .modelPickerDismissed:
        state.modelPicker = nil
        return .none

      case .renameButtonTapped:
        // Pre-fill the alert with the current title.
        state.renameDraft = state.title ?? ""
        return .none

      case .confirmRename:
        guard let sessionID = state.liveSessionID, let draft = state.renameDraft else {
          state.renameDraft = nil
          return .none
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // The gateway `session.title` method rejects an empty title (server error 4021),
        // so an empty/whitespace draft is a no-op: just close the alert, don't round-trip.
        guard !trimmed.isEmpty else {
          state.renameDraft = nil
          return .none
        }
        let previousTitle = state.title
        // Optimistic: update the header immediately; roll back on RPC failure.
        state.title = trimmed
        state.renameDraft = nil
        state.errorBanner = nil
        let stored = state.storedSessionID
        let profile = state.scopedProfile
        return .run { [gateway] send in
          func rename(_ targetID: String) async throws {
            _ = try await gateway.send("session.title", .object([
              "session_id": .string(targetID),
              "title": .string(trimmed),
            ]))
          }
          do {
            // Stale live id after foreground: self-heal once, then replay the rename (#17).
            try await withSessionHeal(
              rename, sessionID: sessionID, storedSessionID: stored,
              profile: profile, gateway: gateway, send: send
            )
          } catch {
            await send(.renameFailed(previousTitle: previousTitle))
          }
        }

      case let .renameFailed(previousTitle):
        state.title = previousTitle
        state.errorBanner = "Couldn’t rename the session."
        return .none

      case .cancelRename:
        state.renameDraft = nil
        return .none
      }
    }
  }

  // MARK: - Event fold

  private func reduce(event: GatewayEvent, into state: inout State) -> Effect<Action> {
    switch event {
    case .ready:
      state.status = .ready
      state.reconnectAttempt = 0
      // The socket is (re)connected — clear any stale connection banner (e.g. a "Connection
      // lost." left over from a lock/unlock drop) so it doesn't linger after we reconnect.
      state.errorBanner = nil
      guard !state.hasRequestedSession else { return .none }
      state.hasRequestedSession = true
      // No stored id → a fresh session: `session.create` (handle only). A stored id →
      // re-hydrate server-authoritatively via the unified `hydrate` path.
      if let stored = state.storedSessionID {
        return hydrate(sessionID: stored, profile: state.scopedProfile)
      }
      return createSession(profile: state.scopedProfile)

    case .messageStart:
      // Defer creating the assistant row until the first delta — a tool-only turn emits
      // message.start with no text, and an eager empty row renders as a blank bubble.
      state.streamingRowID = nil
      state.errorBanner = nil
      state.isSending = true
      // Defensive: a second message.start without an intervening message.complete would
      // otherwise orphan the prior live thinking row (shimmering forever). Freeze/clear it
      // first (idempotent; removes the row if it carried no reasoning/status) before
      // creating the fresh one. Also resets `thinkingSeconds = 0` for the new turn.
      freezeThinking(into: &state)
      // Unlike the assistant bubble, the thinking row is created eagerly so an immediate
      // "Thinking 0s" indicator appears even before any reasoning text arrives. Start the
      // live elapsed timer (mirrors the voice-recording tick).
      let thinkingID = uuid()
      state.transcript.append(ChatRow(
        id: thinkingID, kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
      ))
      state.thinkingRowID = thinkingID
      state.thinkingSeconds = 0
      // Reaffirm the turn-start anchor at the authoritative turn start (the submit anchor is
      // optimistic; `message.start` is the agent's first beat). A hydrate mid-turn reconciles
      // the live elapsed timer against this instant. Tell the list this session is now
      // working so its row glow lights up immediately (server-confirmed).
      return .merge(setTurnAnchor(state), startThinkingTimer(), runningChanged(true, state))

    case let .messageDelta(text):
      appendToStreamingMessage(text, into: &state)
      keepThinkingLast(into: &state)
      return .none

    case let .messageComplete(text, usage):
      if let u = usage { state.usage = u }
      if let id = state.streamingRowID {
        state.transcript[id: id]?.kind = .message(role: .assistant, text: text, isComplete: true)
      } else if !text.isEmpty {
        // No deltas arrived (non-streamed reply) — materialise the row now.
        state.transcript.append(ChatRow(id: uuid(), kind: .message(role: .assistant, text: text, isComplete: true)))
      }
      // else: empty tool-only turn → no row at all.
      state.streamingRowID = nil
      // Move the thinking row below the answer, then freeze it in place so the turn ends as
      // […answer][Thought · <elapsed>].
      keepThinkingLast(into: &state)
      freezeThinking(into: &state)
      state.isSending = false
      // Turn ended — drop the anchor so a later hydrate doesn't resurrect a phantom timer,
      // and tell the list to clear this session's working glow immediately.
      return .merge(.cancel(id: CancelID.thinkingTimer), clearTurnAnchor(state), runningChanged(false, state))

    case let .thinkingDelta(text):
      appendToThinking(text, into: &state)
      return .none

    case let .reasoningAvailable(text):
      appendToThinking(text, into: &state)
      return .none

    case let .statusUpdate(_, text):
      setThinkingStatus(text, into: &state)
      return .none

    case let .toolStart(toolID, name, title, argsText):
      let id = uuid()
      let detail = argsText.map { ToolDetail(argsText: $0) }
      state.transcript.append(ChatRow(id: id, kind: .tool(
        name: name, title: title?.nonEmpty ?? name, state: .running, detail: detail, durationS: nil
      )))
      if let toolID { state.toolRowIDs[toolID] = id }
      keepThinkingLast(into: &state)
      return .none

    case let .toolComplete(toolID, name, title, args, resultText, inlineDiff, durationS):
      let detail = ToolDetail(args: args, resultText: resultText?.nonEmpty, inlineDiff: inlineDiff?.nonEmpty)
      if let toolID, let id = state.toolRowIDs[toolID],
         case let .tool(existingName, existingTitle, _, existingDetail, _) = state.transcript[id: id]?.kind {
        // Merge: keep the start-time args_text; fill in result/diff/structured args.
        let merged = ToolDetail(
          argsText: existingDetail?.argsText,
          args: detail.args, resultText: detail.resultText, inlineDiff: detail.inlineDiff
        )
        state.transcript[id: id]?.kind = .tool(
          name: name ?? existingName,
          title: title?.nonEmpty ?? existingTitle,
          state: .complete,
          detail: merged.isEmpty ? nil : merged,
          durationS: durationS
        )
      } else {
        // tool.complete with no prior start — create the row directly.
        let resolvedName = name ?? ""
        state.transcript.append(ChatRow(id: uuid(), kind: .tool(
          name: resolvedName,
          title: title?.nonEmpty ?? resolvedName,
          state: .complete,
          detail: detail.isEmpty ? nil : detail,
          durationS: durationS
        )))
      }
      keepThinkingLast(into: &state)
      return .none

    case let .error(message):
      state.errorBanner = message
      state.isSending = false
      freezeThinking(into: &state)
      // Turn ended in error — drop the anchor (prevents a phantom timer on the next hydrate)
      // and clear the list's working glow for this session immediately.
      return .merge(.cancel(id: CancelID.thinkingTimer), clearTurnAnchor(state), runningChanged(false, state))

    case .authExpired:
      // The gated session is fully dead (ws-ticket 401). Pause reconnect — do NOT back off —
      // and bubble up so the app raises the re-auth modal. The trailing `.gatewayClosed`
      // (the finished stream) is suppressed via `awaitingReauth`.
      state.awaitingReauth = true
      state.status = .reconnecting
      finalizeInFlight(into: &state)
      return .merge(
        .cancel(id: CancelID.reconnect),
        .cancel(id: CancelID.thinkingTimer),
        .send(.delegate(.sessionExpired))
      )

    case let .approvalRequest(request):
      // Nice-to-have skipped: the thinking timer keeps running while a blocking card is the
      // focus rather than pausing — simpler reducer, and wall-clock still reflects the turn.
      state.pendingInteraction = .approval(request)
      return .none

    case let .clarifyRequest(request):
      state.pendingInteraction = .clarify(request)
      return .none

    case let .sudoRequest(prompt):
      state.pendingInteraction = .secret(.sudo, prompt)
      return .none

    case let .secretRequest(prompt):
      state.pendingInteraction = .secret(.secret, prompt)
      return .none

    case let .sessionInfo(info):
      // Update the model/reasoning chip; later session.info events can be partial, so
      // only overwrite fields that are present.
      if let model = info.model?.nonEmpty { state.model = model }
      if let effort = info.reasoningEffort?.nonEmpty { state.reasoningEffort = effort }
      if let u = info.usage { state.usage = u }
      return .none

    case .unknown:
      return .none
    }
  }

  private func appendToStreamingMessage(_ text: String, into state: inout State) {
    if let id = state.streamingRowID,
       case let .message(role, existing, _) = state.transcript[id: id]?.kind {
      state.transcript[id: id]?.kind = .message(role: role, text: existing + text, isComplete: false)
    } else {
      // First delta of the turn — create the assistant row lazily (see `.messageStart`).
      let id = uuid()
      state.transcript.append(ChatRow(id: id, kind: .message(role: .assistant, text: text, isComplete: false)))
      state.streamingRowID = id
    }
  }

  /// Close out any row that was still streaming when the socket dropped: mark the
  /// in-flight assistant message complete and freeze the in-flight thinking row so a
  /// dropped socket leaves a static `Thinking · <elapsed>` rather than a live one.
  /// Idempotent.
  private func finalizeInFlight(into state: inout State) {
    if let id = state.streamingRowID,
       case let .message(role, text, _) = state.transcript[id: id]?.kind {
      state.transcript[id: id]?.kind = .message(role: role, text: text, isComplete: true)
    }
    state.streamingRowID = nil
    freezeThinking(into: &state)
    state.isSending = false
  }

  /// 1s `continuousClock` loop that drives the live "Thinking" elapsed timer. Mirrors the
  /// voice-recording tick. Cancel any prior loop first so a fresh turn starts at 0.
  private func startThinkingTimer() -> Effect<Action> {
    .run { [clock] send in
      while true {
        try await clock.sleep(for: .seconds(1))
        await send(.thinkingTick)
      }
    }
    .cancellable(id: CancelID.thinkingTimer, cancelInFlight: true)
  }

  /// Append reasoning text into the active thinking row, creating it defensively (with the
  /// current `thinkingSeconds`) if `.messageStart` was missed so reasoning never drops.
  private func appendToThinking(_ text: String, into state: inout State) {
    if let id = state.thinkingRowID,
       case let .thinking(reasoning, status, elapsed, isComplete) = state.transcript[id: id]?.kind {
      state.transcript[id: id]?.kind = .thinking(
        reasoning: reasoning + text, status: status, elapsedSeconds: elapsed, isComplete: isComplete
      )
    } else {
      let id = uuid()
      state.transcript.append(ChatRow(
        id: id, kind: .thinking(reasoning: text, status: nil, elapsedSeconds: 0, isComplete: false)
      ))
      state.thinkingRowID = id
    }
  }

  /// Set the latest `status.update` line on the active thinking row, creating it
  /// defensively if `.messageStart` was missed so status never drops.
  private func setThinkingStatus(_ text: String, into state: inout State) {
    if let id = state.thinkingRowID,
       case let .thinking(reasoning, _, elapsed, isComplete) = state.transcript[id: id]?.kind {
      state.transcript[id: id]?.kind = .thinking(
        reasoning: reasoning, status: text, elapsedSeconds: elapsed, isComplete: isComplete
      )
    } else {
      let id = uuid()
      state.transcript.append(ChatRow(
        id: id, kind: .thinking(reasoning: "", status: text, elapsedSeconds: 0, isComplete: false)
      ))
      state.thinkingRowID = id
    }
  }

  /// Freeze the in-flight thinking row at turn end (completion / error / socket drop): bake
  /// the live `thinkingSeconds` into `elapsedSeconds`, flip `isComplete = true`, and remove
  /// the row entirely if it carried neither reasoning nor status. Resets the timer counter
  /// and clears the pointer. Idempotent. The caller cancels `CancelID.thinkingTimer`.
  private func freezeThinking(into state: inout State) {
    let elapsed = state.thinkingSeconds
    if let id = state.thinkingRowID,
       case let .thinking(reasoning, status, _, _) = state.transcript[id: id]?.kind {
      if reasoning.isEmpty, status == nil {
        state.transcript.remove(id: id)
      } else {
        state.transcript[id: id]?.kind = .thinking(
          reasoning: reasoning, status: status,
          elapsedSeconds: elapsed, isComplete: true
        )
      }
    }
    state.thinkingRowID = nil
    state.thinkingSeconds = 0
  }

  /// Keep the active thinking row pinned to the bottom of the transcript so the live
  /// "Thinking …" indicator (and the frozen "Thought" row it becomes) always sits below the
  /// turn's answer and tool rows, even as they stream in. Called after every row append
  /// during a turn; a no-op when no thinking row is active or it is already last.
  private func keepThinkingLast(into state: inout State) {
    guard let id = state.thinkingRowID,
          state.transcript.last?.id != id,
          let row = state.transcript.remove(id: id)
    else { return }
    state.transcript.append(row)
  }

  /// Keep the client-side rendering window sensible as rows append live (streaming deltas, a
  /// freshly-echoed user row). When the user was parked at the bottom window (i.e. hadn't
  /// scrolled up to pull in older history), re-pin to the bottom window so the newest rows stay
  /// visible and the live window stays bounded by `initialWindow` — capping relayout cost on a
  /// long streaming turn. A user who DID scroll up (a window wider than the bottom one) is left
  /// untouched: we never yank their scroll. Always clamps `windowStart` into range.
  private func maintainWindowAfterStreaming(wasAtBottomWindow: Bool, into state: inout State) {
    let count = state.transcript.count
    if wasAtBottomWindow {
      state.windowStart = State.bottomWindowStart(count: count)
    }
    // Clamp defensively (a removal could otherwise leave windowStart past the end).
    state.windowStart = min(max(0, state.windowStart), count)
  }

  // MARK: - Effects

  private func connect(_ connection: ServerConnection) -> Effect<Action> {
    .run { [gateway, debugLog] send in
      // Pass the full auth regime: `.token` → `?token=` (byte-identical); `.cookie` mints a
      // fresh single-use ws-ticket per connect. A dead session surfaces as `.authExpired`.
      for await event in gateway.connect(connection.baseURL, connection.auth) {
        debugLog.append(event) // mirror into the app-wide debug buffer (Task 12)
        await send(.gatewayEvent(event))
      }
      await send(.gatewayClosed)
    }
    .cancellable(id: CancelID.socket, cancelInFlight: true)
  }

  /// Create a brand-new session (`session.create`). New sessions send no title so the
  /// server auto-names from the first message (passing any title disables Hermes'
  /// auto-title generation). The default/nil profile is omitted → byte-identical to the
  /// single-profile request.
  private func createSession(profile: String?) -> Effect<Action> {
    .run { [gateway] send in
      var fields: [String: JSONValue] = [:]
      if let profile { fields["profile"] = .string(profile) }
      do {
        let result = try await gateway.send("session.create", .object(fields))
        if let handle = result.decoded(SessionHandle.self) {
          await send(.sessionResult(.success(handle)))
        } else {
          await send(.sessionResult(.failure(.server("Malformed session.create result"))))
        }
      } catch let error as GatewayError {
        await send(.sessionResult(.failure(error)))
      } catch {
        await send(.sessionResult(.failure(.disconnected)))
      }
    }
  }

  /// The single, idempotent server-authoritative re-hydration path, shared by open,
  /// foreground, and cold launch. Calls `session.resume`, which works for BOTH a stored
  /// session (the agent is rebuilt from the DB) and an already-live one (the transport is
  /// reattached) and returns the same authoritative payload: `messages` + `info` + `running`
  /// + `inflight`. We deliberately do NOT use `session.activate` — that is live-only and
  /// answers "session not found" for any stored session opened from the list (the common
  /// case). The decoded `ActivateResponse` is applied wholesale in `applyActivate` — server
  /// wins.
  private func hydrate(sessionID: String, profile: String?) -> Effect<Action> {
    .run { [gateway] send in
      var fields: [String: JSONValue] = ["session_id": .string(sessionID)]
      // Scope to the active profile (binds that profile's HERMES_HOME + state.db).
      if let profile { fields["profile"] = .string(profile) }
      let params: JSONValue = .object(fields)
      do {
        let result = try await gateway.send("session.resume", params)
        if let response = result.decoded(ActivateResponse.self), !response.sessionID.isEmpty {
          await send(.activateResult(.success(response)))
        } else {
          await send(.activateResult(.failure(.server("Malformed session.resume result"))))
        }
      } catch let error as GatewayError {
        await send(.activateResult(.failure(error)))
      } catch {
        await send(.activateResult(.failure(.disconnected)))
      }
    }
  }

  /// Apply a server-authoritative `ActivateResponse` into state: bind the live/stored ids,
  /// `applyRuntimeInfo` (model/reasoning/usage), drive the working indicator from the
  /// authoritative `running` flag, rebuild the transcript wholesale from `messages`
  /// (server wins — no merge/dedup), then seed the in-flight turn. When `inflight.streaming`
  /// is set we seed an assistant streaming row eagerly and point `streamingRowID` at it so
  /// the next `message.delta` appends to it instead of lazily creating a duplicate.
  private func applyActivate(_ response: ActivateResponse, into state: inout State) -> Effect<Action> {
    state.liveSessionID = response.sessionID
    state.storedSessionID = response.storedSessionID ?? state.storedSessionID
    state.status = .ready
    // A successful hydrate means we're connected — clear any stale connection banner.
    state.errorBanner = nil

    // Runtime info: model / reasoning / usage straight from the response (fixes the blank
    // model + context-0 bugs on re-open).
    if let info = response.info {
      var target = RuntimeInfoTarget(
        model: state.model, reasoningEffort: state.reasoningEffort, usage: state.usage
      )
      applyRuntimeInfo(info, into: &target)
      state.model = target.model
      state.reasoningEffort = target.reasoningEffort
      state.usage = target.usage
    }

    // Working indicator from the authoritative `running` flag.
    let running = response.running ?? false
    state.isSending = running

    // #26: when the hydrate reports a STILL-RUNNING turn, the agent is mid-turn and the
    // client's own live thinking + tool rows are not in the server payload (`SessionInflight`
    // carries only user/assistant/streaming — no reasoning, no tools). Capture those live rows
    // (in transcript order, tools then thinking) BEFORE the wholesale replace so they survive
    // the round-trip; we re-append them after the authoritative history is rebuilt and restore
    // their tracking ids so subsequent `tool.*`/`message.delta` events reconcile in place.
    // A COMPLETED turn (`running == false`) keeps the strict server-wins behavior: no preserved
    // live rows leak into a finished transcript.
    var preservedToolRows: [(toolKey: String, row: ChatRow)] = []
    var preservedThinkingRow: ChatRow?
    if running {
      // Tool rows in transcript order (so re-append preserves the original ordering).
      preservedToolRows = state.transcript.compactMap { row -> (String, ChatRow)? in
        guard let entry = state.toolRowIDs.first(where: { $0.value == row.id }) else { return nil }
        return (entry.key, row)
      }
      if let thinkingID = state.thinkingRowID {
        preservedThinkingRow = state.transcript[id: thinkingID]
      }
    }

    // Rebuild the transcript wholesale from the authoritative history (server wins).
    state.transcript = IdentifiedArrayOf(uniqueElements: reconstructTranscript(response.messages))
    state.streamingRowID = nil
    state.thinkingRowID = nil
    state.toolRowIDs = [:]

    // Seed the in-flight turn snapshot (lost when the agent process restarts — acceptable).
    // Use DETERMINISTIC, position-derived ids (same convention as `reconstructTranscript`) so
    // repeated hydrates of the same running turn yield byte-identical in-flight row ids — no
    // identity churn (a re-hydrate diffs the unchanged in-flight rows as a stable update, not a
    // delete/insert). Streaming is unaffected: `streamingRowID` still points at the seeded row,
    // so the next `message.delta` mutates it in place under the same id.
    if let inflight = response.inflight {
      if let user = inflight.user?.nonEmpty {
        let userKind = ChatRow.Kind.message(role: .user, text: user, isComplete: true)
        state.transcript.append(ChatRow(
          id: ChatRow.deterministicID(
            sequenceIndex: state.transcript.count, role: userKind.role,
            kindDiscriminator: userKind.discriminator
          ),
          kind: userKind
        ))
      }
      // Seed the streaming row eagerly when the turn is still streaming so the next
      // `message.delta` reuses it (avoids a duplicate from the lazy first-delta path).
      let assistant = inflight.assistant ?? ""
      if inflight.streaming == true || !assistant.isEmpty {
        let assistantKind = ChatRow.Kind.message(role: .assistant, text: assistant, isComplete: false)
        let id = ChatRow.deterministicID(
          sequenceIndex: state.transcript.count, role: assistantKind.role,
          kindDiscriminator: assistantKind.discriminator
        )
        state.transcript.append(ChatRow(id: id, kind: assistantKind))
        state.streamingRowID = id
      }
    }

    // #26: re-append the preserved live tool rows (in their original transcript order) after the
    // rebuilt history + seeded inflight rows, restoring `toolRowIDs` so a later `tool.complete`
    // for the same tool key reconciles the same row in place. Keep the ORIGINAL row ids (the
    // running tool calls already exist client-side under those ids) — no UUID churn, no diff
    // delete/insert. The thinking row is handled by `reconcileTurnTimer` so it can stay last.
    for (toolKey, row) in preservedToolRows where state.transcript[id: row.id] == nil {
      state.transcript.append(row)
      state.toolRowIDs[toolKey] = row.id
    }

    // Reconcile the live "Thinking" elapsed timer from the client-persisted turn-start anchor
    // against the authoritative `running` flag. `running` decides *whether* the timer runs;
    // the anchor only supplies the *start instant*. A `!running` + stale anchor must DISCARD
    // the anchor (no phantom timer); a `running` turn resumes the tick seeded at the elapsed
    // offset rather than restarting at 0.
    let timerEffect = reconcileTurnTimer(
      running: running, preservedThinkingRow: preservedThinkingRow, into: &state
    )

    // Server wins: a wholesale transcript replace resets the client-side window to the bottom
    // (newest) so the chat opens/re-hydrates parked at the latest rows, discarding any prior
    // scroll-up that revealed older history. Computed after every append above (inflight +
    // reconciled thinking row) so the count is final.
    state.windowStart = State.bottomWindowStart(count: state.transcript.count)

    // Persist the freshly-hydrated, server-authoritative state back to the cache so the next
    // cold open paints from it (debounced — coalesces with any immediately-following deltas).
    let persist = debouncedPersist()

    // Tell the list this session's authoritative working state so its row glow reconciles
    // immediately (event-driven), without waiting for the next poll. Server-confirmed: the
    // `running` flag is straight from `session.resume`.
    let runningEffect = runningChanged(running, state)

    // Pull usage on-demand only when the response didn't carry it (older agents) — mirrors
    // the prior resume behavior so the gauge isn't blank until the next turn.
    if state.usage == nil {
      return .merge(fetchUsage(sessionID: response.sessionID), persist, timerEffect, runningEffect)
    }
    return .merge(persist, timerEffect, runningEffect)
  }

  /// Reconcile the live "Thinking" elapsed timer on hydrate from the persisted turn-start
  /// anchor and the authoritative `running` flag (`reconcileTimer`):
  ///   - `.running(elapsed:)` → seed `thinkingSeconds` to the elapsed offset, recreate the
  ///     live thinking row eagerly (so a "Thinking <n>s" indicator appears immediately even
  ///     before more reasoning arrives), and resume the `continuousClock` tick from there;
  ///   - `.frozen` → no live tick; **discard** the stale anchor so it can't resurrect a
  ///     phantom timer; the reconstructed (complete) reasoning row stands as a static
  ///     `Thought · <elapsed>` disclosure;
  ///   - `.none` → no in-flight turn; nothing to do.
  private func reconcileTurnTimer(
    running: Bool, preservedThinkingRow: ChatRow? = nil, into state: inout State
  ) -> Effect<Action> {
    // Read the anchor under the same key the submit path wrote it (`storedSessionID ??
    // liveSessionID`), NOT `response.sessionID` (the live id) — they differ for a resumed
    // session keyed by its stored id.
    let anchor = anchorKey(state).flatMap { chatSnapshot.turnAnchor($0) }
    switch reconcileTimer(running: running, anchor: anchor, now: now) {
    case let .running(elapsed):
      let seconds = Int(elapsed)
      state.thinkingSeconds = seconds
      // #26: if a live thinking row was preserved from before the wholesale replace, re-use it
      // (same id + accumulated reasoning + latest status) so the thinking block does NOT restart
      // — its content survives the background→foreground round-trip and the next `thinking.delta`
      // mutates it in place. Otherwise recreate an empty live thinking row (the in-flight one was
      // dropped by the wholesale rebuild) with a deterministic, position-derived id so repeated
      // hydrates of the same running turn don't churn its identity. Either way it renders as a
      // live shimmering "Thinking <n>s" (the view reads the live `thinkingSeconds`) while the
      // tick continues.
      let thinkingID: ChatRow.ID
      if let preserved = preservedThinkingRow {
        thinkingID = preserved.id
        if state.transcript[id: preserved.id] == nil {
          state.transcript.append(preserved)
        }
      } else {
        let thinkingKind = ChatRow.Kind.thinking(
          reasoning: "", status: nil, elapsedSeconds: seconds, isComplete: false
        )
        thinkingID = ChatRow.deterministicID(
          sequenceIndex: state.transcript.count, role: thinkingKind.role,
          kindDiscriminator: thinkingKind.discriminator
        )
        state.transcript.append(ChatRow(id: thinkingID, kind: thinkingKind))
      }
      state.thinkingRowID = thinkingID
      keepThinkingLast(into: &state)
      // Resume the tick (seeded `thinkingSeconds` continues incrementing from `elapsed`).
      return startThinkingTimer()
    case .frozen:
      // Stale anchor on a stopped turn — discard it so it never starts a phantom timer.
      state.thinkingSeconds = 0
      return clearTurnAnchor(state)
    case .none:
      state.thinkingSeconds = 0
      return .none
    }
  }

  /// Pull current context-window usage right after a session resolves. `session.info` /
  /// `message.complete` only deliver usage mid/after a turn, so a resumed session would
  /// otherwise show a blank gauge until the next reply. The gateway's on-demand
  /// `session.usage` RPC returns the same `Usage` shape (mirrors the TUI's `/usage`). Old
  /// agents lacking the method answer `-32601` → ignored (gauge stays hidden); other errors
  /// are transient and the value still arrives on the next `message.complete`.
  private func fetchUsage(sessionID: String) -> Effect<Action> {
    .run { [gateway] send in
      do {
        let result = try await gateway.send("session.usage", .object(["session_id": .string(sessionID)]))
        if let usage = result.decoded(Usage.self) {
          await send(.usageResponse(usage))
        }
      } catch let error as GatewayError where error.isUnknownMethod {
        // Agent too old to support session.usage — leave the gauge hidden.
      } catch {
        // Transient failure; usage will still arrive on the next message.complete.
      }
    }
  }

  // MARK: - Snapshot write-back

  /// Whether a gateway event changes the transcript / model / usage enough to warrant a
  /// snapshot refresh. (`.unknown`, blocking-request prompts, and bare status lines don't.)
  private func persistRelevant(_ event: GatewayEvent) -> Bool {
    switch event {
    case .messageStart, .messageDelta, .messageComplete,
         .thinkingDelta, .reasoningAvailable, .statusUpdate,
         .toolStart, .toolComplete, .sessionInfo:
      return true
    case .ready, .error, .authExpired, .approvalRequest, .clarifyRequest,
         .sudoRequest, .secretRequest, .unknown:
      return false
    }
  }

  /// Debounced write-back trigger: coalesces a burst of streaming deltas into a single
  /// SQLite write `persistDebounce` after the last change (cancel-in-flight resets the timer).
  private func debouncedPersist() -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: Self.persistDebounce)
      await send(.persistSnapshotTick)
    }
    .cancellable(id: CancelID.persist, cancelInFlight: true)
  }

  /// Persist the current chat as a non-authoritative snapshot (model / reasoning / usage +
  /// transcript rows). A no-op until we know the stored session id to key on. The store owns
  /// the single row-tail cap (`maxRowsPerSession`), so we pass the full transcript. Attachment
  /// image bytes never reach the cache: `ChatRow`'s `Codable` omits `attachmentImages` (so the
  /// store can't persist them even if we passed them through) — they can't be re-hydrated from
  /// the server and base64 blobs would bloat the cache.
  private func persistSnapshotNow(_ state: State) -> Effect<Action> {
    guard let sessionID = state.storedSessionID ?? state.liveSessionID else { return .none }
    let snapshot = ChatSnapshot(
      model: state.model,
      reasoningEffort: state.reasoningEffort,
      usage: state.usage,
      updatedAt: now,
      rows: Array(state.transcript)
    )
    return .run { [chatSnapshot] _ in
      chatSnapshot.saveSnapshot(sessionID, snapshot)
    }
  }

  // MARK: - Turn-start anchor (timer continuity)

  /// The key the turn-start anchor is stored under. Mirrors the snapshot key
  /// (`storedSessionID ?? liveSessionID`) so the anchor written on submit is read back by
  /// `hydrate` (which keys on the stored id) on the next open.
  private func anchorKey(_ state: State) -> String? {
    state.storedSessionID ?? state.liveSessionID
  }

  /// Emit `delegate(.runningChanged)` for the session list so the row's working glow
  /// clears/sets INSTANTLY (event-driven) rather than waiting for the next poll. Keyed by the
  /// **stored** session id (`storedSessionID ?? liveSessionID`) since the list keys rows by
  /// the persisted id. A no-op until the session resolves (nothing to key on). Always
  /// server-confirmed (`message.start`/`complete`/`error` and the activate `running` flag) —
  /// never a cached guess.
  private func runningChanged(_ running: Bool, _ state: State) -> Effect<Action> {
    guard let key = anchorKey(state) else { return .none }
    return .send(.delegate(.runningChanged(sessionID: key, running: running)))
  }

  /// Persist the turn-start anchor (`@Dependency(\.date.now)`) so a later hydrate can
  /// reconcile the elapsed timer against the authoritative `running` flag. The anchor is
  /// **non-authoritative** — it only supplies the *start instant*; `running` decides whether
  /// the timer runs at all. Written on `prompt.submit`, reaffirmed on `message.start`.
  private func setTurnAnchor(_ state: State) -> Effect<Action> {
    guard let key = anchorKey(state) else { return .none }
    return .run { [chatSnapshot, now] _ in
      chatSnapshot.setTurnAnchor(key, now)
    }
  }

  /// Drop the turn-start anchor at turn end (completion / error / interrupt) so a stopped
  /// turn never leaves a stale anchor that a later hydrate could mistake for a live timer.
  private func clearTurnAnchor(_ state: State) -> Effect<Action> {
    guard let key = anchorKey(state) else { return .none }
    return .run { [chatSnapshot] _ in
      chatSnapshot.clearTurnAnchor(key)
    }
  }

  /// Change a session setting (model / reasoning) over the gateway. Fire-and-forget —
  /// the authoritative value comes back on the next `session.info`.
  private func configSet(key: String, value: String, sessionID: String) -> Effect<Action> {
    .run { [gateway] _ in
      _ = try? await gateway.send("config.set", .object([
        "session_id": .string(sessionID),
        "key": .string(key),
        "value": .string(value),
      ]))
    }
  }

}

private func backoffDelay(attempt: Int) -> Duration {
  .seconds(min(30.0, pow(2.0, Double(max(0, attempt - 1)))))
}

/// Self-heal an outbound RPC that failed with "session not found" (#17): obtain a FRESH live
/// session id by re-resuming the stored session (`session.resume`), or — when no stored id is
/// known (a brand-new session whose `session.create` returned no `stored_session_id`) —
/// recreating one (`session.create`). Applies the fresh id to state via
/// `.liveSessionIDRefreshed` (no transcript rebuild, so the optimistic row survives the retry)
/// and returns it so the caller can replay the original RPC ONCE. Throws if the heal itself
/// fails (the caller surfaces the banner — no second retry, no recursion). The default/nil
/// profile is omitted so single-profile/token-mode requests stay byte-identical.
private func healLiveSessionID(
  storedSessionID: String?,
  profile: String?,
  gateway: HermesGatewayClient,
  send: Send<ChatFeature.Action>
) async throws -> String {
  if let storedSessionID {
    var fields: [String: JSONValue] = ["session_id": .string(storedSessionID)]
    if let profile { fields["profile"] = .string(profile) }
    let result = try await gateway.send("session.resume", .object(fields))
    guard let response = result.decoded(ActivateResponse.self), !response.sessionID.isEmpty else {
      throw GatewayError.server("Malformed session.resume result")
    }
    await send(.liveSessionIDRefreshed(
      liveSessionID: response.sessionID, storedSessionID: response.storedSessionID
    ))
    return response.sessionID
  }
  // No stored id to resume against — recreate a fresh session so the heal still has a target.
  var fields: [String: JSONValue] = [:]
  if let profile { fields["profile"] = .string(profile) }
  let result = try await gateway.send("session.create", .object(fields))
  guard let handle = result.decoded(SessionHandle.self) else {
    throw GatewayError.server("Malformed session.create result")
  }
  await send(.liveSessionIDRefreshed(
    liveSessionID: handle.sessionID, storedSessionID: handle.storedSessionID
  ))
  return handle.sessionID
}

/// Run an outbound RPC with transparent self-heal on "session not found" (#17): run `op`
/// against the current live id; if it throws `isSessionNotFound`, re-resume/recreate for a
/// fresh id (applying it via `.liveSessionIDRefreshed`) and replay `op(healedID)` ONCE. A
/// single retry — never recurses. This is the SHARED inner mechanism; callers keep their own
/// OUTER catch to map a failure (heal, retry, or any other error) to the right per-call action
/// (`.promptSubmitFailed` / `.attachmentUploadFailed` / `.renameFailed`).
private func withSessionHeal(
  _ op: (_ targetID: String) async throws -> Void,
  sessionID: String,
  storedSessionID: String?,
  profile: String?,
  gateway: HermesGatewayClient,
  send: Send<ChatFeature.Action>
) async throws {
  do {
    try await op(sessionID)
  } catch let error as GatewayError where error.isSessionNotFound {
    let healedID = try await healLiveSessionID(
      storedSessionID: storedSessionID, profile: profile, gateway: gateway, send: send
    )
    try await op(healedID)
  }
}

/// Run a `prompt.submit` with transparent self-heal on "session not found" (#17): replay the
/// submit ONCE against a freshly re-resumed/recreated id; on any other failure (or a failed
/// heal/retry) surface `.promptSubmitFailed`.
private func submitPrompt(
  sessionID: String,
  storedSessionID: String?,
  profile: String?,
  gateway: HermesGatewayClient,
  send: Send<ChatFeature.Action>,
  submit: @escaping (_ targetID: String) async throws -> Void
) async {
  do {
    try await withSessionHeal(
      submit, sessionID: sessionID, storedSessionID: storedSessionID,
      profile: profile, gateway: gateway, send: send
    )
  } catch let error as GatewayError {
    await send(.promptSubmitFailed(message: error.message))
  } catch {
    await send(.promptSubmitFailed(message: GatewayError.disconnected.message))
  }
}

/// Upload one staged attachment to the session via the method its kind dictates (#8).
/// Returns the `@file:` ref for `.file` uploads (nil for image/pdf, which the agent picks
/// up from `attached_images` on the next `prompt.submit`). Mirrors the desktop's remote
/// branch (`image.attach_bytes` / `pdf.attach` / `file.attach`).
private func uploadAttachment(
  _ attachment: ComposerAttachment, sessionID: String, gateway: HermesGatewayClient
) async throws -> String? {
  switch attachment.kind {
  case .image:
    _ = try await gateway.send("image.attach_bytes", .object([
      "session_id": .string(sessionID),
      "content_base64": .string(attachment.base64),
      "filename": .string(attachment.filename),
    ]))
    return nil
  case .pdf:
    _ = try await gateway.send("pdf.attach", .object([
      "session_id": .string(sessionID),
      "content_base64": .string(attachment.base64),
      "name": .string(attachment.filename),
    ]))
    return nil
  case .file:
    let result = try await gateway.send("file.attach", .object([
      "session_id": .string(sessionID),
      "data_url": .string(attachment.dataURL),
      "name": .string(attachment.filename),
    ]))
    return result["ref_text"]?.stringValue
  }
}
