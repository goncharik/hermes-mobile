import ComposableArchitecture
import Foundation

/// Layout constants for the chat column (#80). Lives in HermesKit so the view and the
/// measured layout tests read ONE value.
public enum ChatLayout {
  /// The readable-width cap on full-width content in wide (iPad regular) layouts: the
  /// transcript, footer, cards, panels, and composer are wrapped in one OUTER container
  /// limited to this width and centered, and `ConnectionView`'s onboarding form uses the
  /// same cap for the same reason. Phone widths are below the cap, so compact rendering is
  /// unchanged. The cap is never applied to table cells — those stay under
  /// `CappedWidthLayout` (see `docs/features/markdown-rendering.md`).
  public static let readableMaxWidth: CGFloat = 760
}

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
    /// Whether this stored session came from a server row carrying the shared `unread`
    /// field. Retained with the chat so read acknowledgements keep their original
    /// profile scope even if the sidebar switches profiles.
    public var serverUnreadSupported: Bool
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
    public var composerText: String
    public var status: Status
    public var errorBanner: String?
    public var isSending: Bool
    /// True while a turn is in flight — the same signal that powers the `runningChanged`
    /// delegate (set on submit/`message.start`, cleared on complete/error/interrupt, and
    /// reconciled from the authoritative `session.resume` `running` flag on hydrate).
    /// The app-level slot policy reads this: a RUNNING chat keeps its slot (socket and
    /// streaming effects) across a nav pop; an idle one is torn down.
    public var isRunning: Bool { isSending }
    /// A blocking request from the agent (approval/clarify/secret). While set, `canSend` is
    /// false and a card is the focal point — and `ChatView` hands the keyboard back so the
    /// card gets the fixed region (the composer's *field* stays live for a draft; only
    /// sending is blocked).
    ///
    /// **Raise it through ``present(_:)``**, never by assigning here: the assignment alone
    /// leaves ``pendingInteractionToken`` behind, and a replacement card would then inherit
    /// the previous one's `@State` — its scroll offset, its "Approve all" toggle, or, worst,
    /// a typed sudo password. `internal(set)` so that is structural rather than a convention
    /// for everything outside HermesKit (the app target, where the view identity lives, now
    /// *cannot* assign one without the token). Assigning `nil` to dismiss is fine — a card
    /// that is gone has no identity to keep.
    public internal(set) var pendingInteraction: PendingInteraction?
    /// Is the standing card an *approval*? The only card `ChatView` gives layout priority
    /// over the transcript — it is the one built to absorb the squeeze (a bounded, scrollable
    /// region), so priority buys it readable command lines; the clarify/secret card is rigid
    /// stacked content and priority would only take room from the transcript.
    public var isApprovalPending: Bool {
      if case .approval = pendingInteraction { return true }
      return false
    }
    /// Monotonic count of blocking requests *presented* — bumped by ``present(_:)`` every
    /// time a card is raised, never reset. The view uses it as the card's identity so a
    /// replacement always gets fresh `@State` (its "Approve all" toggle off, its command
    /// scrolled to the top, a secret prompt's typed value gone). Identity cannot come from
    /// the request itself: a queued replacement can be *equal* to the card it replaces — an
    /// agent retrying the same command — and a value-derived id would be unchanged for
    /// exactly that pair, which is the one case where the replacement does not pass through
    /// `nil` first. `internal(set)` so the invariant "every presentation bumps the token" is
    /// enforceable: outside HermesKit the only way to raise a card is ``present(_:)``.
    public internal(set) var pendingInteractionToken: Int
    /// Raise a blocking card, bumping ``pendingInteractionToken`` so the view rebuilds.
    /// Every presentation goes through here; dismissal is a plain `pendingInteraction = nil`
    /// (a card that is gone has no identity to keep).
    public mutating func present(_ interaction: PendingInteraction) {
      pendingInteraction = interaction
      pendingInteractionToken &+= 1
    }
    /// One-shot push-tap approval-recovery hint (client-side workaround for hermes-agent
    /// #30: an `approval.request` that fired while the socket was down is gone — the
    /// server does not re-surface pending approvals on `session.resume`). Set by
    /// `AppFeature` when an approval-typed push tap puts this session's chat on screen;
    /// consumed (reset to `false`) by the next hydrate, which synthesizes a generic
    /// command-less approval card when the turn is still `running` and no real blocking
    /// request arrived over the socket. Transient: deliberately NOT persisted in
    /// `ChatSnapshotClient` (a snapshot repaint must never resurrect a card), and cleared
    /// by a real `.approvalRequest` (the real event wins — no later re-synthesis).
    public var expectsPendingApproval: Bool
    /// The tool/skill row whose detail sheet is open, if any (Task 4).
    public var presentedTool: ChatRow?
    /// Current model + reasoning effort (from `session.info`), shown in the composer chip.
    public var model: String?
    public var reasoningEffort: String?
    /// Rollback target for an in-flight `config.set`, keyed by config key — the value the
    /// SERVER last confirmed, captured before the FIRST optimistic pick of a run. A second
    /// same-key pick must NOT capture the first pick's still-unconfirmed value: when the first
    /// is superseded (`CancelID.configSet`) and the second is then rejected, rolling back to it
    /// would leave the chip showing a value the server never accepted. Written on a pick, and
    /// dropped again either by the rollback (`.configSetFailed`) or by the next authoritative
    /// confirmation of that key (`session.info` / hydrate), after which the chip IS the server's
    /// value and the next pick captures it fresh. Internal and unpersisted.
    var pendingConfigRollback: [String: String?]
    /// Latest context-window usage (from `session.info` / `message.complete`), driving the
    /// composer's context pill. `nil` until the agent reports usage (old agents never do).
    public var usage: Usage?
    /// The model/reasoning picker sheet, when open (Task 7).
    public var modelPicker: ModelPicker?
    /// Draft text for the rename alert. `nil` = alert closed; non-nil = alert open
    /// with the in-progress title (Task 4).
    public var renameDraft: String?
    /// Token of the copy target most recently tapped — a code block (#9) or a whole
    /// message row (`ChatFeature.rowCopyToken(_:)`, #34) — for the transient "copied"
    /// checkmark. Cleared by a clock-driven effect; the latest copy owns the feedback.
    public var recentlyCopiedToken: String?
    /// Non-`nil` while the transient "Session ID copied" toast is showing. Purely transient
    /// confirmation state: raised by a copy, cleared by the timed expiry. It's a counter
    /// rather than a `Bool` so a re-copy while the toast is already up is still an
    /// observable change — that's what re-announces the copy to VoiceOver (a `Bool` would
    /// stay `true` and the announcement would be swallowed).
    public var copiedIDToastToken: Int?
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
    /// The slash-command catalog (`commands.catalog`), fetched once per screen when the
    /// session becomes ready (#36). `nil` until loaded — a transient fetch failure leaves
    /// it `nil` and the next hydrate naturally retries.
    public var commandCatalog: CommandCatalog?
    /// Set once the agent rejects `commands.catalog` as unknown (`-32601`) — too old for
    /// slash commands. Suppresses future catalog fetches; typed `/text` then goes out as a
    /// plain prompt, byte-identical to the pre-feature behavior (backward-compat guard).
    public var commandsUnsupported: Bool
    /// Whether the agent accepts the extended reasoning levels `max`/`ultra` (upstream #62650,
    /// 2026-07-12). Optimistically `true`: unlike the attach/commands gates there is no probe —
    /// an older gateway answers a `config.set {key:"reasoning"}` with server error 4002
    /// `unknown reasoning value: <v>`, so this flips only on that verdict
    /// (`GatewayError.isUnknownReasoningValue`), never on a transport failure or any other
    /// server error. Per chat slot and unpersisted (same lifetime as `commandsUnsupported`): a
    /// fresh slot re-offers the levels, so an agent upgrade is picked up on the next chat (#81).
    public var extendedReasoningSupported: Bool
    /// True while a `slash.exec`/`command.dispatch` round-trip is outstanding (#36).
    ///
    /// A slash exec locks the composer (`isSending`) but is explicitly **NOT a turn**: no
    /// `message.start`/`complete` bracket it and the authoritative `running` flag stays
    /// false throughout. Without this flag a hydrate landing mid-exec (`.foreground`,
    /// `.reattached`, a reconnect `.ready`) would set `isSending = running == false` and
    /// UNLOCK the composer, letting a second command be submitted whose state the first
    /// exec's terminal action would then tear down. `applyActivate` therefore keeps the
    /// lock while this is set, and only the exec's own terminal action clears it.
    public var slashExecInFlight: Bool
    /// True while a branch `session.create` is in flight (#34) — the double-fire guard so
    /// a second tap on the branch button is a no-op until the RPC resolves. Public so the
    /// view can dim the affordance while it runs.
    public var isBranching: Bool

    /// Prompts queued while a turn (or slash exec) was running (#66), in send order.
    /// Client-side by design — see `QueuedPrompt`. Drained head-first by
    /// `drainQueueIfReady` when the session goes idle; rendered by `QueuedPromptsPanel`
    /// pinned above the composer (never in the transcript, so hydrates can't touch it).
    public var queuedPrompts: [QueuedPrompt]
    /// True when auto-drain is suspended (#66): set by a manual Stop (auto-firing a queued
    /// prompt right after would un-stop the agent — desktop park-on-explicit-stop parity)
    /// and by a turn `.error` (auto-firing into whatever just failed could burn the whole
    /// queue against a broken server). Parked entries wait for an explicit per-entry
    /// Send-now, which clears this.
    public var isQueueParked: Bool
    /// The entry currently being submitted by a drain (#66) — set when the drain pops the
    /// head, cleared once the submit demonstrably reached the server (`message.start`, a
    /// turn terminal, `.attachmentsSubmitted`, or the slash exec's own terminal). A submit
    /// FAILURE with this standing re-inserts it at the head + parks (never silently lost).
    var drainingEntry: QueuedPrompt?
    /// The optimistic echo row `submitDraft` appended for the draining entry, so a failed
    /// drain can remove it again (the entry goes back to the panel — leaving the bubble too
    /// would show the text twice).
    var drainingRowID: ChatRow.ID?
    /// One-shot Send-now override (#66): the next drain attempt ignores (and clears)
    /// `isQueueParked`, and the interrupted turn's terminal `.error` skips re-parking.
    /// Cleared by the drain that consumes it and by a manual Stop (stop intent wins).
    var sendNowArmed: Bool

    /// Mid-turn counterpart to `canSend` (#66): whether `.composerSubmitted` while
    /// `isSending`/`slashExecInFlight` will queue the draft. Same gates as `canSend`
    /// minus the two turn-lock flags (which are the whole point). The view's send arrow
    /// is enabled by `canSend || canQueue`.
    public var canQueue: Bool {
      let hasContent = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.isEmpty
      return hasContent
        && (isSending || slashExecInFlight)
        && liveSessionID != nil
        && pendingInteraction == nil
        && !isBranching
        && pendingPasteCount == 0
    }

    /// True while the queue still owes work — entries waiting OR one mid-drain. The
    /// app-level slot policy reads this alongside `isRunning`: a detached slot with
    /// queued work must not be torn down at turn end (the drain fires the next turn
    /// into it), and an idle pop must not destroy a parked queue.
    public var hasQueuedWork: Bool { !queuedPrompts.isEmpty || drainingEntry != nil }

    /// No prompt has been sent yet — but the composer may hold a draft. This chat was
    /// created as a NEW session (`resumesStoredSession` false, no branch attach), nothing is
    /// rendered, no turn is in flight, no prompts are queued. The app-level "new session"
    /// policy reads this: filling a fresh chat over one that has never been prompted would
    /// tear down and redial a socket for an identical result, so it clears the composer
    /// draft instead — the draft and staged attachments are exactly what that no-op clears.
    /// A connected-but-unprompted chat still qualifies: its `session.create` handshake holds
    /// nothing worth keeping (the server creates the DB row lazily, on the first prompt).
    /// That handshake is also why the test is `resumesStoredSession`, not
    /// `storedSessionID == nil` — the handle carries a `stored_session_id` the moment the
    /// socket is ready, so the id alone stops telling a fresh seat from a resumed session.
    public var isUnpromptedNewChat: Bool {
      !resumesStoredSession && attachLiveSessionID == nil && branchSeed == nil
        && transcript.isEmpty && !isSending && !hasQueuedWork
    }

    /// Nothing typed, staged, sent, or still arriving — an `isDiscardableNewChat` with an
    /// empty composer and no attachments, i.e. the regular-width detail seat exactly as it
    /// was seated. Narrowing to the stack drops such a seat instead of pushing an empty chat
    /// over the session list.
    public var isPristineNewChat: Bool {
      isDiscardableNewChat && composerText.isEmpty && attachments.isEmpty
    }

    /// Composer input still resolving outside the draft itself: a clipboard load whose batch
    /// lands later (#54, paired by `pendingPasteCount`) or voice input mid
    /// permission/recording/transcription. Clearing `composerText`/`attachments` under either
    /// is not a reset — the in-flight result appends into the supposedly fresh composer, and
    /// the mic keeps running; tearing the chat down loses the result outright (the paste's
    /// pairing token is per-`State`, and `.teardown` releases the mic).
    public var hasInFlightComposerInput: Bool {
      pendingPasteCount > 0 || recording.isBusy
    }

    /// The seat holds nothing the user would lose: an `isUnpromptedNewChat` whose composer
    /// input has all landed. This is the single predicate every app-level "this seat can be
    /// reused, dropped, or reseated" decision is built on (`isPristineNewChat` here; the
    /// "New session" reuse shortcut and the regular-width profile reseat in `AppFeature`),
    /// so the three cannot judge the same seat differently.
    public var isDiscardableNewChat: Bool {
      isUnpromptedNewChat && !hasInFlightComposerInput
    }

    /// Whether the transcript REGION renders the empty-chat hero (#80) instead of the
    /// transcript. True only when there is provably nothing to show: no rows, no turn in
    /// flight, no streaming row — and, for a RESUMED session (`storedSessionID != nil`),
    /// only once its first hydrate has landed. A resumed chat opened without a snapshot
    /// cache has an empty transcript for the round-trip before history arrives; without
    /// the `hasHydrated` clause the hero would flash and be replaced by the history. A
    /// resumed session whose server history is genuinely empty shows the hero after the
    /// hydrate (correct). A brand-new chat (`storedSessionID == nil`) shows it at once.
    /// Pure state — `CollectionTranscriptView` stays the only transcript renderer; the
    /// view swaps the region, it never derives this.
    public var showsEmptyHero: Bool {
      transcript.isEmpty && !isSending && streamingRowID == nil
        && (storedSessionID == nil || hasHydrated)
    }

    /// Pastes whose clipboard providers are still loading (#54) — a counter, not a flag,
    /// because two pastes in quick succession chain in the view's coordinator and both must
    /// be outstanding at once.
    ///
    /// It holds `canSend` down. A paste is the one attachment source with no modal sheet over
    /// it, so the user is looking at a composer that already holds their typed text while the
    /// load runs: submitting in that window sent the message *without* the image, which then
    /// reappeared, orphaned, in the next draft. Every load is
    /// deadline-bounded and the coordinator delivers its batch unconditionally, so
    /// `attachmentsPasting` / `attachmentsPasted` are a balanced pair and this cannot leak.
    ///
    /// It is also the **pairing token** that keeps a paste in the chat it was made in: the
    /// load runs outside TCA's effect lifecycle, so its batch can arrive after the live-chat
    /// slot has been replaced. A `0` here means this state never saw the paste's
    /// `attachmentsPasting` half, and `attachmentsPasted` ignores the batch (see the reducer).
    public var pendingPasteCount: Int

    /// Whether the branch affordance is enabled (#34): the session must have a PERSISTED
    /// id (`parent_session_id` has to match a REST list row id for the branch to nest —
    /// a live-only handle would stamp a parent link no list row ever matches, so the
    /// branch would render flat forever; old agents that return no `stored_session_id`
    /// at create simply can't branch) that has an actual DB ROW — an unpersisted branch
    /// (`attachLiveSessionID != nil`) holds only the create's row-less `session_key`, so
    /// a grandchild branched from it would stamp that never-materializing key as its
    /// parent (the slot replacement tears the never-prompted middle branch down for the
    /// server to reap, so its row never lands) and render flat forever. A standing
    /// `branchSeed` also blocks branching even when `attachLiveSessionID` has already
    /// been nilled by an interrupted seed replay (socket blip mid-reap-recovery,
    /// c35fd59): the seed keeps `storedSessionID` pointing at the OLD, now-dead session
    /// id for the several seconds until the replay's fresh `session.create` lands, so a
    /// branch stamped from it during that window would dangle the same way. No turn may
    /// be streaming and no other branch RPC may be in flight. Also requires
    /// `status == .ready` (review finding 2): `.gatewayClosed` finalizes a mid-stream
    /// row as `isComplete` and clears `isSending` the moment the socket drops (so a
    /// truncated reply would otherwise look branchable while `.reconnecting`), and the
    /// branch RPC itself would just fail against the dead socket — gate on connected
    /// instead of relying on that failure to surface the problem. The view mirrors this;
    /// the reducer re-guards it.
    public var canBranch: Bool {
      storedSessionID != nil && attachLiveSessionID == nil && branchSeed == nil
        && !isSending && !isBranching && status == .ready
    }

    /// A branch's client-held reconstruction seed (#34): the assistant text seeded into
    /// the branch `session.create` plus the parent's persisted id. Carried by the branch
    /// chat while it is UNPERSISTED so a server-side reap of the never-prompted live
    /// session (detached socket past the ~20s orphan grace) can be healed by replaying
    /// the seeded create — the seed is only gone server-side, never client-side.
    public struct BranchSeed: Equatable, Sendable {
      public var text: String
      public var parentSessionID: String

      public init(text: String, parentSessionID: String) {
        self.text = text
        self.parentSessionID = parentSessionID
      }
    }

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
      /// The `model.options` LOAD failure — the sheet has no list to show at all.
      public var error: String?
      /// The last `config.set` rejection while this sheet was up. Rendered inline over a
      /// still-usable list (the rollback happens in the rows behind it); cleared by the
      /// next selection.
      public var applyError: String?

      public init(
        isLoading: Bool = true, options: ModelOptions? = nil, error: String? = nil,
        applyError: String? = nil
      ) {
        self.isLoading = isLoading
        self.options = options
        self.error = error
        self.applyError = applyError
      }
    }

    // Bookkeeping (internal).
    var liveSessionID: String?
    var storedSessionID: String?
    /// This chat was opened to RESUME an existing session (a list tap, a push tap, a branch
    /// primed from its create) rather than created as a new chat. Fixed at init from
    /// `resumeStoredID` and never mutated — `storedSessionID` can't answer the question
    /// after the fact, because a new chat's `session.create` handshake writes one too.
    /// Read only by `isUnpromptedNewChat` (and through it the regular-width seat policy).
    let resumesStoredSession: Bool
    /// Set when this chat was opened from a branch `session.create` (#34): the session is
    /// live in server memory but has NO DB row until its first prompt (the server creates
    /// it lazily), so every hydrate must attach by THIS live id via `session.activate` —
    /// which re-binds the session's transport to the current socket (also cancelling the
    /// server's orphan reap of parked WS sessions) and returns the seeded history —
    /// instead of `session.resume` by stored id, which hard-fails "session not found"
    /// without a DB row and would self-heal into an unrelated fresh session. Cleared on
    /// the first `message.start` (the first prompt persisted the row), after a heal
    /// re-bound fresh ids, and when a not-found self-heal recreates the session.
    var attachLiveSessionID: String?
    /// The unpersisted branch's seed (#34), set alongside `attachLiveSessionID` when the
    /// parent primes this chat from the branch create. A "session not found" while it is
    /// set means the server reaped the never-prompted live session — replay the SEEDED
    /// `session.create` from this (rebuilding context + nesting) instead of silently
    /// degrading to a bare, context-less session under the still-painted seed. This is
    /// the DURABLE fact branch recovery keys on (`attachLiveSessionID` is transient —
    /// the replay trigger consumes it before the replayed create resolves). Cleared
    /// with `attachLiveSessionID` on the first `message.start` (the seed is durable
    /// server-side now) and whenever recovery degrades to the bannered fresh create —
    /// a stale seed must never survive onto a plain session (it would mis-arm
    /// attach-by-live-id in `liveSessionIDRefreshed`); a TRANSPORT-interrupted replay
    /// keeps it (the seed is the only copy of the branch).
    var branchSeed: BranchSeed?
    /// One-shot guard for the seed replay: at most ONE replayed `session.create` per
    /// successful hydrate (reset in `applyActivate` and on `message.start`), so a server
    /// answering "session not found" even for a just-recreated session can't loop
    /// replay → attach → replay forever — the bounded fallback is the bannered fresh
    /// create. A replay interrupted by transport (disconnect/timeout — no server
    /// verdict) REFUNDS the budget so the post-reconnect hydrate can replay again.
    var hasReplayedBranchSeed: Bool
    /// STRUCTURAL INVARIANT (2026-07-24 review, replacing a one-shot `hasProbedBranchResume`
    /// spend/refund flag): before ever discarding a branch's real history via a bare seed
    /// replay, `.activateResult(.failure)` probes `session.resume` against the branch's
    /// PERSISTED `storedSessionID` (server calls it `session_key`) — NOT the live
    /// `attachLiveSessionID` `session.activate` just answered "not found" for. The server
    /// persists the DB row in `prompt.submit` (`_ensure_session_db_row` +
    /// `_persist_branch_seed`) BEFORE `message.start` reaches the client, under
    /// `session_key` (`session.create`'s `stored_session_id`) — a DIFFERENT value from the
    /// live runtime `session_id` `attachLiveSessionID` holds (probing by the live id always
    /// 404s even when the row exists). `session.activate` is live-only (no DB fallback) and
    /// 404s regardless; `session.resume` DOES fall back to the DB by `session_key`, so it
    /// recovers the persisted branch without losing the real turn.
    ///
    /// There is deliberately NO budget field here anymore: the probe is a read-only
    /// `session.resume`, safe to re-issue on EVERY not-found as long as this hydrate
    /// hasn't already replayed the seed (`!hasReplayedBranchSeed` alone gates it). The old
    /// `hasProbedBranchResume` flag was spent BEFORE the probe effect fired and only
    /// refunded from inside `.branchResumeProbeResult(.failure)` — so a cancelled probe
    /// (superseded by `.foreground`/`.reattached`/`.teardownSocketOnly`, all sharing
    /// `CancelID.hydrate`; TCA drops a cancelled task's trailing `send`) or a non-not-found
    /// server rejection (session cap, internal error, malformed payload) left the budget
    /// permanently spent with no result ever landing to refund it — silently arming a LATER
    /// not-found to skip the probe and replay the bare seed over what could be a persisted
    /// turn. Removing the budget removes the bug class: ONLY a genuine not-found returned
    /// BY THE PROBE ITSELF (`.branchResumeProbeResult(.failure)` falling through to
    /// `handleActivateFailure`'s `error.isSessionNotFound` branch) is positive evidence the
    /// row is absent and may replay the seed; every other probe outcome — cancelled,
    /// `.disconnected`/`.notConnected`/`.timedOut`, or any other server error — re-arms
    /// (status-only / self-redial) so the next `.ready`/`.foreground`/`.reattached` retries
    /// the probe from scratch. A probe success is treated exactly like `message.start`
    /// (clears `attachLiveSessionID`/`branchSeed`, hydrates wholesale via the normal path).
    ///
    /// The companion half of the fix lives in `canSend`: the stale `liveSessionID` a
    /// hydrate just 404'd on is nilled the INSTANT the probe decision is made — before the
    /// probe's result is even awaited — so a concurrent submit can't race this recovery
    /// with its own independent self-heal `session.create` (two live sessions born from one
    /// seed, the typed message landing in the untracked one).
    /// The PARENT side of a branch in flight: the seed stashed at `.branchFromMessage`
    /// and handed to `Delegate.branchCreated` on success (so the replacement chat can
    /// carry it as `branchSeed`). Distinct from `branchSeed`, which lives on the CHILD.
    var pendingBranchSeed: BranchSeed?
    /// The stable key this chat's session is addressed by (`storedSessionID ??
    /// liveSessionID`) — what the parent's slot routing (push-tap dedup, re-open compare,
    /// archive matching, push suppression) and the snapshot/anchor store key on. `nil`
    /// until a brand-new chat's `session.create` resolves. Public (read-only) so the app
    /// target can mirror `fillLiveChat`'s marker construction (demo mode).
    public var sessionKey: String? { storedSessionID ?? liveSessionID }
    var streamingRowID: ChatRow.ID?
    var thinkingRowID: ChatRow.ID?
    var toolRowIDs: [String: ChatRow.ID]
    var reconnectAttempt: Int
    var hasRequestedSession: Bool
    /// Set by the first `.task` (the initial connect). The view's `.task` fires on EVERY
    /// appearance — including re-appearing over a LIVE slot after a nav pop — and an
    /// unconditional `connect` there would cancel-and-redial a healthy socket (the dial
    /// gap drops streamed events). Once started, later appearances are routed by
    /// `AppFeature` through `.reattached`, which guards the live socket.
    var hasStarted: Bool
    /// Set when the gated session died (`.authExpired`): reconnect backoff is paused and the
    /// trailing `.gatewayClosed` (the finished stream) is ignored until re-auth resumes us.
    var awaitingReauth: Bool
    /// True while the single same-socket hydrate retry after a `.timedOut` failure is
    /// outstanding. A timeout over a live-but-slow socket (huge history, busy gateway) is
    /// indistinguishable from a HALF-OPEN one, so the first timeout retries `session.resume`
    /// over the SAME socket; only a second consecutive timeout concludes half-open and
    /// redials. Reset on hydrate success and at every fresh hydrate issuance.
    var hydrateRetriedAfterTimeout: Bool
    /// Set once this slot's first server handshake has landed: a successful
    /// `activateResult` (the `session.resume`/`session.activate` hydrate — `applyActivate`)
    /// or the fresh-session `session.create` handle (`sessionResult`). Never cleared —
    /// per-slot lifetime, unpersisted. Only `showsEmptyHero` reads it: "the transcript is
    /// empty because the server said so" vs "empty because history hasn't arrived yet".
    var hasHydrated: Bool

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
      serverUnreadSupported: Bool = false,
      title: String? = nil,
      transcript: IdentifiedArrayOf<ChatRow> = [],
      composerText: String = "",
      status: Status = .connecting
    ) {
      self.connection = connection
      self.profileName = profileName
      self.serverUnreadSupported = serverUnreadSupported
      self.storedSessionID = resumeStoredID
      self.resumesStoredSession = resumeStoredID != nil
      self.title = title
      self.transcript = transcript
      self.composerText = composerText
      self.status = status
      self.errorBanner = nil
      self.isSending = false
      self.liveSessionID = nil
      self.attachLiveSessionID = nil
      self.branchSeed = nil
      self.hasReplayedBranchSeed = false
      self.pendingBranchSeed = nil
      self.streamingRowID = nil
      self.thinkingRowID = nil
      self.toolRowIDs = [:]
      self.reconnectAttempt = 0
      self.hasRequestedSession = false
      self.hasStarted = false
      self.awaitingReauth = false
      self.hydrateRetriedAfterTimeout = false
      self.hasHydrated = false
      self.pendingInteraction = nil
      self.pendingInteractionToken = 0
      self.expectsPendingApproval = false
      self.presentedTool = nil
      self.model = nil
      self.reasoningEffort = nil
      self.pendingConfigRollback = [:]
      self.usage = nil
      self.modelPicker = nil
      self.renameDraft = nil
      self.recentlyCopiedToken = nil
      self.copiedIDToastToken = nil
      self.recording = .idle
      self.waveformLevels = []
      self.recordingSeconds = 0
      self.thinkingSeconds = 0
      self.attachments = []
      self.attachmentsUnsupported = false
      self.commandCatalog = nil
      self.commandsUnsupported = false
      self.extendedReasoningSupported = true
      self.slashExecInFlight = false
      self.isBranching = false
      self.pendingPasteCount = 0
      self.queuedPrompts = []
      self.isQueueParked = false
      self.drainingEntry = nil
      self.drainingRowID = nil
      self.sendNowArmed = false

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
        // `liveSessionID` is `nil` both before the first successful attach/hydrate AND
        // for the whole duration of a branch reap-recovery probe/replay (2026-07-24
        // review, finding 1) — `.activateResult(.failure)` nils it the instant a
        // not-found starts the recovery, before the probe's result is even awaited, so a
        // concurrent submit can't race the reducer's own recovery with an independent
        // self-heal `session.create` (two live sessions born from one seed).
        && liveSessionID != nil
        && pendingInteraction == nil
        // The visible send button becomes the interrupt button mid-turn, so this is
        // defence-in-depth against a `.composerSubmitted` that races the swap (a tap already
        // in flight, a stale view). A second submit while a turn streams must be a no-op (it
        // would corrupt `isSending` and, if it later failed, emit a spurious
        // `runningChanged(false)` that tears down a detached slot whose first turn is still
        // genuinely running).
        && !isSending
        // A slash exec locks the composer via `isSending` too, but `isSending` can be
        // cleared out from under it — an interrupt tap (`.interruptTapped`) or a socket
        // finalization clears `isSending` while the `slash.exec`/`command.dispatch`
        // round-trip is still outstanding. Guarding on the dedicated in-flight flag as well
        // blocks a SECOND submission in that window, whose state the first command's
        // completion (`finishSlashExec`) would otherwise clear (#36).
        && !slashExecInFlight
        // Review finding 3: a branch `session.create` in flight must not let a NEW parent
        // turn start — when `branchResult` lands, `AppFeature` tears down this whole slot
        // to open the replacement chat, and a just-submitted turn would be silently lost
        // (its socket/effects cancelled with no server response ever observed).
        && !isBranching
        // A paste whose providers are still loading (#54). Unlike the three pickers there is
        // no sheet in the way, so Send is right there and reachable — and a submit that wins
        // the race ships the typed text without the image the user pasted to send it with,
        // stranding the chip on the *next* message. Bounded by the loader's per-provider
        // deadline, so the lock is always released.
        && pendingPasteCount == 0
    }

    /// Rename is only meaningful once we have a live session id (otherwise `confirmRename`
    /// silently no-ops) — drives whether the toolbar Rename control is enabled.
    public var canRename: Bool { liveSessionID != nil }

    /// Rows for the slash-command autocomplete panel (#36), derived PURELY from
    /// `composerText` + the cached catalog on every keystroke — no stored suggestion
    /// state, nothing to keep in sync. Empty when the catalog isn't loaded yet or the
    /// agent predates slash commands (`commandsUnsupported`), so the panel simply never
    /// appears on old agents.
    ///
    /// Also empty while a **blocking card stands** (#65): the panel is a fixed slab (up to 5.5
    /// rows) in the same non-scrolling region as the card and the composer, so a slash draft
    /// left in the composer when a card is raised mid-turn — or typed into it afterwards, since
    /// the card only resigns the field, never disables it — stacked the two and pushed the
    /// Deny/Approve row off screen on a small phone (measured: the composer's bottom at 431pt in
    /// a 352pt window). Nothing is lost: `composerText` is untouched, so the draft and its panel
    /// come straight back when the card is answered, and the command the panel completes could
    /// not have been submitted meanwhile anyway — `canSend` is false while `pendingInteraction`
    /// is non-nil. Gated here rather than in the view so the whole derivation stays one pure
    /// rule with no stored suggestion state.
    public var slashSuggestions: [SlashSuggestion] {
      guard !commandsUnsupported, pendingInteraction == nil else { return [] }
      return SlashSuggestionFilter.suggestions(for: composerText, catalog: commandCatalog)
    }

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
    /// The chat VIEW left the screen (forwarded by `AppFeature.chatViewDisappeared`, which
    /// guards a nil slot — the view never sends into this scope directly). Releases
    /// view-session resources only (the mic / voice recording) — the socket and streaming
    /// effects are owned by the app-level live-chat slot and torn down separately via
    /// `.teardown` (an `AppFeature` policy).
    case viewDisappeared
    /// Full slot teardown (sent by `AppFeature`, never the view): cancel every
    /// long-running effect — socket, reconnect backoff, voice, thinking ticker, debounced
    /// persist — and release the mic. `AppFeature` flushes the snapshot (`.persistNow`)
    /// before this where the pending debounce matters.
    case teardown
    /// Background-grace expiry (sent by `AppFeature`, never the view): the finite
    /// background window ran out while still backgrounded — cancel the socket + reconnect
    /// backoff CLEANLY but keep ALL chat state in memory (transcript, live thinking/tool
    /// row pointers, composer draft), so the next `.foreground` reconnect re-hydrates with
    /// the #26 live-row preservation intact. Status flips to `.reconnecting` (the socket
    /// is genuinely gone), so a later `.reattached` reconnects instead of hydrating a
    /// dead socket.
    case teardownSocketOnly
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
    /// App returned to the foreground — re-`hydrate` (re-read running/inflight/usage) via
    /// the same unified path used by open/cold-launch, reconnecting the socket only if it
    /// isn't `.ready` (a socket the background grace window kept alive must NOT be
    /// cancel-and-redialed — the dial gap would drop streamed events). Shares its handler
    /// with `.reattached`.
    case foreground
    /// The slot's own session was re-opened over LIVE, surviving chat state (`AppFeature`'s
    /// re-open policy — a re-pushed marker in compact, a plain sidebar tap on the detail
    /// column's session in regular): always re-hydrate (server authority; `applyActivate`'s
    /// #26 path preserves a still-running turn's live thinking/tool rows), but do NOT
    /// cancel-and-redial a healthy socket — the dial gap would drop streamed events.
    /// Only a dead/dialing socket reconnects (then `.ready` re-hydrates). Shares its
    /// handler with `.foreground`.
    case reattached
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
    // Queued-prompt panel interactions (#66)
    /// Remove a queued entry (no confirmation — it's a draft).
    case queuedPromptDeleted(id: UUID)
    /// Lift a queued entry back into the composer for editing (`/undo`-prefill style).
    /// Guarded to an EMPTY composer so it can never clobber a draft mid-typing.
    case queuedPromptEditTapped(id: UUID)
    /// Fire this entry next, immediately: idle → submit now (ahead of any parked
    /// entries); mid-turn → interrupt-then-send (desktop semantics — stop the current
    /// turn, the entry fires as the next one). Un-parks the queue.
    case queuedPromptSendNow(id: UUID)
    /// Deterministic drain re-check, sent by the Send-now effect after its
    /// `session.interrupt` resolves — covers a turn whose terminal event never arrives
    /// (already over, or lost on a reconnecting socket). Safe to send any time; every
    /// precondition is re-checked in `drainQueueIfReady`.
    case maybeDrainQueue
    case respondToApproval(approve: Bool, all: Bool)
    /// Outcome of the awaited `approval.respond` RPC. `resolved` carries the server's
    /// `{"resolved": n}` count — `0` means the per-session queue was already empty (the
    /// approval was handled elsewhere), so the optimistic "Approved"/"Denied" status row
    /// at `rowID` is patched to say so. `nil` means the RPC threw → user-facing banner.
    /// The effect feeds back only those two actionable outcomes: a `resolved >= 1` or
    /// missing-key (older agent, lenient decode) success sends nothing — the optimistic
    /// row is already correct.
    case approvalRespondResult(rowID: ChatRow.ID, resolved: Int?)
    case respondToClarify(answer: String)
    case respondToSecret(value: String)
    case copyRow(id: ChatRow.ID)
    case copyCode(text: String, token: String)
    case copyFeedbackExpired(token: String)
    /// Branch this assistant message into a new chat (#34): a one-shot `session.create`
    /// seeded with ONLY that message's text + `parent_session_id` — desktop parity; no
    /// dedicated branch RPC exists. Old agents silently ignore the extra params (the
    /// method exists, so no `-32601`) and degrade to a plain empty chat.
    case branchFromMessage(id: ChatRow.ID)
    case branchResult(Result<SessionHandle, GatewayError>)
    /// The replayed seeded `session.create` after the server reaped an unpersisted
    /// branch's live session (#34) — re-arms the attach bookkeeping on success rather
    /// than emitting a second `branchCreated` slot replacement.
    case branchReplayResult(Result<SessionHandle, GatewayError>)
    /// Result of the resume PROBE (review finding 1) tried once before ever replaying the
    /// branch seed on a `session.activate` not-found: `session.resume` by the SAME id —
    /// which, unlike `session.activate`, falls back to the DB — either finds the branch's
    /// real persisted history (success, applied like any other hydrate) or confirms it
    /// truly has no row (failure, falls through to the existing not-found/degrade
    /// handling).
    case branchResumeProbeResult(Result<ActivateResponse, GatewayError>)
    /// Put this chat's session id (`sessionKey`) on the pasteboard and raise the transient
    /// confirmation toast. A no-op before the session resolves (`sessionKey == nil`).
    case copySessionIDTapped
    /// The copy toast's dwell time elapsed — hide it.
    case copiedIDToastExpired
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
    /// The provider SLUG of the section the row was tapped in (nil for a programmatic
    /// selection with no section context). Appended to the `config.set` value as
    /// `--provider <slug>` so the gateway routes the model to the provider the picker
    /// showed it under, instead of guessing from the model id (a `openai/…` OpenRouter
    /// row would otherwise resolve to the direct OpenAI provider and fail on its key).
    case modelSelected(model: String, provider: String?)
    case reasoningSelected(String)
    /// A `config.set` that failed for good (the #17 heal has already had its single replay).
    /// Carries the rejected `value` so the latch banner can name it and `previousValue` so the
    /// optimistic picker write can roll back. One path serves both keys (#81).
    case configSetFailed(key: String, value: String, previousValue: String?, error: GatewayError)
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
    /// Images pasted into the composer (#54) — the fourth attachment source, entering at the
    /// same point as the three pickers. The view's paste coordinator already resolved the
    /// clipboard's `NSItemProvider`s into `PickedItem`s (the implicit pasteboard grant is
    /// scoped to the paste command, so the load cannot be deferred into an effect), which is
    /// why this arrives pre-loaded rather than as an `attachPastedTapped`-style trigger.
    /// One action per paste — one user act, one capability check, one ordering assertion.
    /// An **empty** batch is meaningful: the clipboard advertised an image (that is the only
    /// reason the view claims **Paste**) and none of it could be loaded → error banner. A
    /// batch with a non-zero `droppedCount` is just as meaningful: some of a multi-image paste
    /// survived and the rest did not, which the user has to be told before sending what looks
    /// like the complete set. Only honoured by the state that sent the matching
    /// `attachmentsPasting` — a batch reaching a replacement chat is dropped.
    case attachmentsPasted(PickedBatch)
    /// A paste was claimed and its providers are loading. Sent synchronously from the view's
    /// paste coordinator, and always followed by exactly one `attachmentsPasted`; the pair
    /// brackets the window in which `canSend` must stay down (see `pendingPasteCount`) and
    /// identifies the chat the batch belongs to.
    case attachmentsPasting
    /// A picker returned fewer files than the user chose (an iCloud original that never
    /// downloaded, an unreadable file, a type that could not be re-encoded). A **cancel**
    /// never sends this — `PickedBatch.droppedCount` is what separates the two — so the
    /// banner only ever fires on something the user actually asked for and lost.
    case attachmentsDropped(count: Int)
    case removeAttachment(id: ComposerAttachment.ID)
    /// `fromQueue` marks a drained entry's upload+submit (#66): the echo row still lands,
    /// but the live composer must NOT be cleared (it belongs to whatever the user typed
    /// since) and the standing `drainingEntry` is consumed instead.
    case attachmentsSubmitted(displayText: String, images: [Data], rowID: UUID, fromQueue: Bool)
    case attachmentUploadFailed(message: String)
    case attachmentsUnsupportedDetected
    // Slash commands (#36)
    case commandCatalogLoaded(CommandCatalog)
    case commandsUnsupportedDetected
    /// A row in the suggestion panel was tapped — put its insertion text in the composer
    /// ("/cmd " trailing-space ready for args, or "/cmd sub"). Nothing else changes; the
    /// computed `slashSuggestions` updates/clears automatically and the keyboard stays up.
    case slashSuggestionTapped(SlashSuggestion)
    /// The slash pipeline produced its ephemeral output (`slash.exec` or an
    /// `exec`/`plugin` directive): append the bubble-less `commandOutput` row, unlock the
    /// composer, then fire the full server-authoritative refresh (`session.resume` →
    /// `applyActivate` via `.slashHistoryRefreshed`, carrying the ephemeral output row
    /// across the wholesale replace). The output is local-only, desktop parity — a normal
    /// hydrate drops it (never in server history).
    case slashCommandOutput(String)
    /// A `send` directive's `notice` (e.g. "⊙ Goal set …" from `/goal`) — the backend's
    /// only user feedback before the directive's message is submitted. Renders the output
    /// row ONLY: no lock/turn-state changes (the `prompt.submit` that follows owns the
    /// turn lifecycle). Desktop parity (`slash.ts` renders the notice before submitting).
    case slashCommandNotice(String)
    /// A `skill`/`send` directive's `prompt.submit` landed: the slash round-trip is over
    /// (releasing the mid-exec hydrate guard) but a real turn now owns the composer lock,
    /// so nothing else changes.
    case slashCommandHandedOff
    /// A `prefill` directive (`/undo`): the server rewound history and hands back the
    /// undone message for editing. Drop it into the composer, render the notice as the
    /// output row, unlock. `notice` arrives pre-trimmed-or-nil.
    case slashCommandPrefill(message: String, notice: String?)
    /// The slash pipeline failed outright: banner + unlock (never a swallowed `try?`).
    case slashCommandFailed(message: String)
    /// The post-command refresh landed — the FULL server-authoritative `session.resume`
    /// payload, applied through `applyActivate` (slash commands mutate history: `/undo`
    /// rewinds, `/compress` rewrites, `/retry` truncates). The ephemeral `commandOutput`
    /// rows are carried across the wholesale replace by the reducer.
    case slashHistoryRefreshed(ActivateResponse)

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
      /// A branch `session.create` resolved (#34) — the parent replaces the slot with a
      /// chat PRIMED from the create response (the full `SessionHandle`: stored id for
      /// list/marker identity + live id for `session.activate` attach). The new session
      /// has no DB row until its first prompt, so it must NOT be opened through the
      /// resume-by-stored-id flow — `session.resume` hard-fails "session not found".
      /// Also carries the SEED (text + parent id) the parent copies onto the replacement
      /// chat's `branchSeed`, so a server-side reap of the never-prompted branch can be
      /// healed by replaying the seeded create.
      case branchCreated(BranchCreation)

      /// The `branchCreated` payload: the create response's handle plus the client-held
      /// seed that can rebuild the branch wholesale after an orphan reap.
      public struct BranchCreation: Equatable, Sendable {
        public var handle: SessionHandle
        public var seed: State.BranchSeed

        public init(handle: SessionHandle, seed: State.BranchSeed) {
          self.handle = handle
          self.seed = seed
        }
      }
    }
  }

  private enum CancelID: Hashable {
    case socket, reconnect, hydrate, copyFeedback, copyIDToast, voiceLevels, voiceTimer,
         thinkingTimer, persist
    /// One id per `config.set` key so a newer pick for that key supersedes the in-flight
    /// one: a cancelled effect never emits `.configSetFailed`, so a stale rejection can't
    /// roll the newer value back. The two keys never cancel each other.
    case configSet(String)
  }

  /// Debounce window for write-back so heavy streaming doesn't thrash SQLite.
  private static let persistDebounce: Duration = .seconds(1)

  /// How long a copy confirmation stays up. Shared by the code-block checkmark and the
  /// "Session ID copied" toast so the two can't visually desync.
  static let copiedFeedbackDuration: Duration = .seconds(1.5)

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
        // History is now hydrated server-authoritatively from the `session.resume`
        // response on `.ready` — see `hydrate`. No separate
        // REST `loadHistory` call: the activate response carries `messages` + `info` +
        // `running` + `inflight`, and rebuilding the transcript wholesale from it is what
        // keeps model/usage/status correct on every re-open (the core state-sync fix).
        //
        // The view's `.task` fires on EVERY appearance — including re-appearing over a
        // live slot after a nav pop. Only the slot's FIRST appearance performs the
        // initial connect; re-opens are routed by `AppFeature` through `.reattached`,
        // which must not cancel-and-redial a healthy socket.
        guard !state.hasStarted else { return .none }
        state.hasStarted = true
        return connect(state.connection)

      case .viewDisappeared:
        // View-only cleanup: the screen left, but the slot (socket, streaming fold,
        // thinking ticker, persist debounce) lives on — `AppFeature` decides teardown.
        return releaseVoiceResources(&state)

      case .teardown:
        return .merge(
          releaseVoiceResources(&state),
          .cancel(id: CancelID.socket),
          .cancel(id: CancelID.reconnect),
          .cancel(id: CancelID.hydrate),
          .cancel(id: CancelID.thinkingTimer),
          .cancel(id: CancelID.persist)
        )

      case .teardownSocketOnly:
        // Cancelling the socket effect drops its trailing `await send(.gatewayClosed)`
        // (TCA discards sends from a cancelled task), so no backoff reconnect is
        // scheduled while suspended — `.foreground` owns the redial. Everything else
        // (streaming fold pointers, thinking ticker, debounced persist) stays untouched:
        // the state must survive intact for the foreground hydrate's #26 preservation of
        // a still-running turn's live thinking/tool rows.
        //
        // Also cancel any pending hydrate: socket cancellation resumes its RPC with
        // `.disconnected`, and a stale `.activateResult` reducing AFTER this deliberate
        // teardown could otherwise act on a socket we just chose to drop (e.g. redial
        // while backgrounded after grace expiry, wasting a single-use ws-ticket).
        state.status = .reconnecting
        state.hasRequestedSession = false
        return .merge(
          .cancel(id: CancelID.socket),
          .cancel(id: CancelID.reconnect),
          .cancel(id: CancelID.hydrate)
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
        // The create handshake IS this chat's hydrate (#80): the handle may carry a
        // `stored_session_id`, which would otherwise flip `showsEmptyHero` off for a chat
        // whose only history is the nothing the server just created.
        state.hasHydrated = true
        // A fresh session never hydrates (`session.create` resolves directly to ready), so
        // this is its catalog-fetch point (#36) — without it a brand-new chat would have no
        // slash panel until the first foreground re-hydrate.
        return commandCatalogEffect(state, sessionID: handle.sessionID)

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
        // Structural fix (2026-07-24 review) — see the `hasReplayedBranchSeed`/probe doc
        // comment on `State` for the full invariant. Before ever assuming an unpersisted
        // branch was never prompted, probe once PER NOT-FOUND EVENT (no spend/refund
        // budget — see the State doc comment): `session.activate` (attach-by-live-id) is
        // live-only — no DB fallback — so its "not found" does NOT prove the branch has no
        // history: the server persists the DB row in `prompt.submit`
        // (`_ensure_session_db_row` + `_persist_branch_seed`) BEFORE `message.start`
        // reaches the client, under the row's PERSISTED key (`storedSessionID`, the
        // server's `session_key` / `session.create`'s `stored_session_id`) — a DIFFERENT
        // value from the live `attachLiveSessionID` (`session.create`'s `session_id`)
        // `session.activate` just 404'd on (probing with `attachLiveSessionID` always
        // 404s, fully defeating this guard). `session.resume` DOES fall back to the DB by
        // `session_key`, so try it, by `storedSessionID`, first — only a not-found from
        // the PROBE proves the branch is truly unpersisted. Gated only on
        // `!hasReplayedBranchSeed` (once a replay this hydrate has already established
        // there's nothing to find, re-probing the fresh replayed session is pointless —
        // its own not-found falls straight through to the degrade below).
        if error.isSessionNotFound, state.attachLiveSessionID != nil,
           let storedID = state.storedSessionID, !state.hasReplayedBranchSeed {
          // The stale live id this hydrate just 404'd on is no longer trustworthy — nil
          // it NOW (before the probe's result is even awaited) so `canSend` blocks a
          // concurrent submit's own independent self-heal from racing this recovery with
          // a second, untracked `session.create`.
          state.liveSessionID = nil
          return probeBranchResume(sessionID: storedID, profile: state.scopedProfile)
        }
        return handleActivateFailure(error, into: &state)

      case let .branchResumeProbeResult(.success(response)):
        // The probe found what `session.activate` couldn't: a persisted DB row under
        // the branch's stored key. Treat this exactly like `message.start` clearing the
        // unpersisted-branch bookkeeping — it's now a normal persisted session with real
        // history, hydrated via the standard authoritative path.
        state.attachLiveSessionID = nil
        state.branchSeed = nil
        state.hasReplayedBranchSeed = false
        return applyActivate(response, into: &state)

      case let .branchResumeProbeResult(.failure(error)):
        // Structural fix (2026-07-24 review): there is no budget to refund here (see the
        // `State` doc comment) — a transport-shaped interruption (socket drop / deliberate
        // teardown while the probe was in flight, or a cancellation from a superseding
        // `.foreground`/`.reattached`/`.teardownSocketOnly`) is simply no server verdict,
        // so it re-arms status-only; the next not-found re-probes from scratch (nothing
        // was ever spent). Mirrors `.branchReplayResult(.failure)`'s transport handling.
        if error.isDisconnected || error == .notConnected {
          state.status = .reconnecting
          // The companion `.gatewayClosed` owns the backoff redial — don't stack one.
          return .none
        }
        if error.isTimedOut {
          // A HALF-OPEN socket may never surface `.gatewayClosed` — schedule the redial
          // ourselves so the chat isn't stranded in `.reconnecting`; the fresh `.ready`
          // re-hydrates and, on a repeat not-found, re-probes.
          state.status = .reconnecting
          guard !state.awaitingReauth else { return .none }
          state.hasRequestedSession = false
          return .merge(
            .cancel(id: CancelID.reconnect),
            connect(state.connection)
          )
        }
        // A genuine rejection: either the positive evidence a real not-found provides
        // (falls through to `handleActivateFailure`'s `error.isSessionNotFound` seed-replay
        // branch — the ONLY place the seed is ever replayed) or some other server error
        // (session cap, internal error, malformed payload) that is NOT proof of absence and
        // so does NOT replay — it surfaces via `errorBanner` there instead, leaving the
        // seed/attach bookkeeping standing for the next retry. Either way, nothing here
        // needs a budget to protect: a non-not-found error simply isn't matched by the
        // replay branch's `error.isSessionNotFound` gate.
        return handleActivateFailure(error, into: &state)

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

      case .foreground, .reattached:
        // Two re-attach entry points, one policy: the app returned to the foreground, or
        // the slot's marker was re-pushed over live, surviving chat state. Always
        // re-hydrate (server authority), but NEVER cancel-and-redial a HEALTHY socket —
        // the dial gap drops streamed events, and within the background grace window the
        // socket kept streaming precisely so foreground would not have to redial it.
        guard state.status == .ready else {
          // Dead/dialing socket (including after a grace-expiry `.teardownSocketOnly`):
          // reconnect — the fresh `.ready` re-hydrates. Reset `hasRequestedSession` so
          // that ready actually hydrates: on a fast background→foreground the prior
          // socket is cancelled mid-`for await`, and TCA drops the cancelled task's
          // trailing `await send(.gatewayClosed)` — the only other place that resets
          // the flag.
          state.hasRequestedSession = false
          return connect(state.connection)
        }
        // Socket healthy: hydrate directly against it — no reconnect, so the live socket
        // keeps streaming throughout (no event gap). A socket that silently died while
        // suspended still self-heals: the hydrate RPC fails, the receive loop finishes →
        // `.gatewayClosed` → backoff reconnect. `applyActivate` is the same
        // server-authoritative path as `.ready`, with the #26 preservation of a
        // still-running turn's live thinking/tool rows.
        // An unpersisted branch (#34) re-attaches by LIVE id (`session.activate`) — its
        // stored id has no DB row until the first prompt, so `session.resume` would 4007.
        if let live = state.attachLiveSessionID {
          state.hasRequestedSession = true
          state.hydrateRetriedAfterTimeout = false
          return attachLive(sessionID: live)
        }
        guard let sessionID = state.sessionKey else {
          // Connected but the session id hasn't resolved yet (`session.create` still in
          // flight on this same socket) — nothing to hydrate; the pending result lands
          // on its own.
          return .none
        }
        state.hasRequestedSession = true
        state.hydrateRetriedAfterTimeout = false // fresh hydrate: the retry budget resets
        return hydrate(sessionID: sessionID, profile: state.scopedProfile)

      case .composerSubmitted:
        // Mid-turn the draft QUEUES instead of submitting (#66): the send arrow returns as
        // soon as the composer has content (empty composer keeps Stop), and nothing goes on
        // the wire until the turn ends — the server's `busy_input_mode` policy deliberately
        // never engages from mobile (its queued slot is merge-only with no edit/delete API).
        // The queue entry freezes the whole draft; the drain replays it through the normal
        // submit pipeline (attachments, slash routing, #17 heal) once the session is idle.
        if state.isSending || state.slashExecInFlight {
          guard state.canQueue else { return .none }
          let queuedText = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
          // Degenerate "/" or "/ <payload>" fails the same local check the idle path runs —
          // WITHOUT consuming the draft (queuing it would only fail at drain time, out of
          // sight of the typo).
          if SlashSuggestionFilter.isCommandShaped(queuedText), state.commandCatalog != nil,
             parseSlashCommand(queuedText).name.isEmpty {
            state.errorBanner = "Command failed: empty command"
            return .none
          }
          state.queuedPrompts.append(
            QueuedPrompt(id: uuid(), text: queuedText, attachments: state.attachments)
          )
          state.composerText = ""
          state.attachments = []
          return .none
        }
        guard state.canSend, let sessionID = state.liveSessionID else { return .none }
        // Trim stray leading/trailing whitespace/newlines (soft-wrap, dictation, accidental
        // returns) before submitting; interior formatting is preserved (#31). `canSend`
        // already rejects whitespace-only input with no attachments, so the text can only be
        // empty here when attachments carry the send.
        let text = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return submitDraft(
          text: text, attachments: state.attachments, fromQueue: false,
          sessionID: sessionID, state: &state
        )

      case let .promptSubmitFailed(message):
        state.errorBanner = "Prompt failed: \(message)"
        state.isSending = false
        // A drained entry's submit failed (#66) — back to the panel's head, parked, so the
        // queued message is never silently lost (echo row removed with it).
        reparkDrainingEntry(into: &state)
        // The anchor was written on submit; a failed submit never starts a turn (no
        // `message.start`/`complete` to clear it), so clear it here. This keeps every
        // `setTurnAnchor` paired with a clear, so anchors can't accumulate for sessions that
        // never produce a snapshot row (those aren't counted by the LRU sweep, which only
        // evicts `sessions` rows).
        // This is also a CLIENT-SIDE turn end — no server event will ever follow — so emit
        // `runningChanged(false)` like `.messageComplete`/`.error` do: a DETACHED slot kept
        // alive only while running would otherwise leak forever (`AppFeature`'s teardown
        // policy keys off this delegate). Harmless to the list glow (it only lights on
        // `message.start`).
        return .merge(clearTurnAnchor(state), runningChanged(false, state))

      case let .liveSessionIDRefreshed(liveSessionID, storedSessionID):
        // Self-heal landed a fresh runtime id (#17). Swap it in so subsequent RPCs target the
        // valid session; do NOT touch the transcript (the retried RPC's events repaint it, and a
        // wholesale replace here would wipe the optimistic user/attachment row mid-retry).
        state.liveSessionID = liveSessionID
        state.storedSessionID = storedSessionID ?? state.storedSessionID
        if state.branchSeed != nil {
          // The heal replayed the SEEDED create for a reaped unpersisted branch (#34):
          // the fresh session is again live-only (its DB row lands when the replayed
          // submit's `message.start` fires moments later), so keep attaching by live id
          // and keep the seed for a further reap.
          state.attachLiveSessionID = liveSessionID
        } else {
          // The heal bound this chat to a real resumed/recreated session — any
          // unpersisted-branch bookkeeping (#34) is stale now and must not redirect
          // later hydrates.
          state.attachLiveSessionID = nil
        }
        state.status = .ready
        return .none

      case .interruptTapped:
        guard let sessionID = state.liveSessionID else { return .none }
        state.isSending = false
        // A manual Stop PARKS the queue (#66): auto-firing a queued prompt right after
        // would un-stop the agent the user just stopped (desktop park-on-explicit-stop
        // parity). Stop intent also wins over a not-yet-consumed Send-now arm.
        state.sendNowArmed = false
        if !state.queuedPrompts.isEmpty { state.isQueueParked = true }
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

      case let .queuedPromptDeleted(id):
        state.queuedPrompts.removeAll { $0.id == id }
        return .none

      case let .queuedPromptEditTapped(id):
        // Lift the entry back into the composer (`/undo`-prefill style) — only into an
        // EMPTY composer (no text, no staged attachments), so an edit can never clobber a
        // draft mid-typing. The panel disables the item on the same condition; this guard
        // is the authoritative one.
        guard state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              state.attachments.isEmpty,
              let index = state.queuedPrompts.firstIndex(where: { $0.id == id })
        else { return .none }
        let entry = state.queuedPrompts.remove(at: index)
        state.composerText = entry.text
        state.attachments = entry.attachments
        return .none

      case let .queuedPromptSendNow(id):
        guard let index = state.queuedPrompts.firstIndex(where: { $0.id == id }) else { return .none }
        // Promote to the head (the drain always fires the head) and un-park: an explicit
        // Send-now is the queue's resume signal after a Stop/error park.
        let entry = state.queuedPrompts.remove(at: index)
        state.queuedPrompts.insert(entry, at: 0)
        state.isQueueParked = false
        // Idle: fires immediately, ahead of everything else that was waiting.
        if !state.isSending, !state.slashExecInFlight {
          return drainQueueIfReady(into: &state)
        }
        // Busy: arm the one-shot override so the terminal event drains the promoted head
        // even where it would otherwise park (the interrupted turn's `.error`).
        state.sendNowArmed = true
        // A slash exec can't be interrupted (`session.interrupt` stops TURNS; the exec
        // round-trip finishes on its own) — the exec's terminal action drains the armed head.
        guard !state.slashExecInFlight, let sessionID = state.liveSessionID else { return .none }
        // Interrupt-then-send (desktop semantics): stop the current turn optimistically
        // (mirrors `.interruptTapped`, minus its park). The terminal event drains the
        // head — plus a deterministic re-check once the interrupt RPC resolves, covering
        // a turn that was already over or whose terminal was lost on a dropping socket.
        state.isSending = false
        freezeThinking(into: &state)
        return .merge(
          .cancel(id: CancelID.thinkingTimer),
          clearTurnAnchor(state),
          .run { [gateway] send in
            _ = try? await gateway.send("session.interrupt", .object(["session_id": .string(sessionID)]))
            await send(.maybeDrainQueue)
          }
        )

      case .maybeDrainQueue:
        return drainQueueIfReady(into: &state)

      case let .respondToApproval(approve, all):
        guard case .approval = state.pendingInteraction,
              let sessionID = state.liveSessionID
        else { return .none }
        state.pendingInteraction = nil
        // Answering ANY approval moots the push-tap recovery hint (#30 workaround) — an
        // armed hint left behind (e.g. a tap whose consuming hydrate raced past it) must
        // not make a later, unrelated hydrate synthesize a phantom card.
        state.expectsPendingApproval = false
        let rowID = uuid()
        state.transcript.append(
          ChatRow(id: rowID, kind: .status(kind: "approval", text: approve ? "Approved" : "Denied"))
        )
        // Choice vocabulary matches `tools/approval.py`: "deny" blocks; "once" allows
        // just this command; "session" persists the pattern for the rest of the session
        // (the "Approve all in this session" toggle). Approvals are resolved by the
        // server's per-session queue, so NO `request_id` is sent (unlike clarify/secret);
        // `all` maps to `resolve_all` to clear any other queued approvals at once.
        let choice = approve ? (all ? "session" : "once") : "deny"
        return .run { [gateway] send in
          do {
            let result = try await gateway.send("approval.respond", .object([
              "session_id": .string(sessionID),
              "choice": .string(choice),
              "all": .bool(all),
            ]))
            // The server answers `{"resolved": n}` — the count of queue entries this
            // respond resolved. `0` means the queue was already empty (handled on another
            // client, or a recovered-card blind respond after the fact), so the optimistic
            // row must stop claiming "Approved"/"Denied". A missing key (older agent) is
            // treated as success — decode leniently, only actionable outcomes feed back.
            if result["resolved"]?.intValue == 0 {
              await send(.approvalRespondResult(rowID: rowID, resolved: 0))
            }
          } catch {
            await send(.approvalRespondResult(rowID: rowID, resolved: nil))
          }
        }

      case let .approvalRespondResult(rowID, resolved):
        switch resolved {
        case .some(0):
          // Nothing was resolved server-side (verified no-op) — the approval was already
          // handled elsewhere. Patch the optimistic status row honestly; the next hydrate
          // replaces it wholesale with deterministic ids anyway (server wins), and a row
          // already replaced by such a hydrate is a silent nil-lookup no-op.
          state.transcript[id: rowID]?.kind = .status(kind: "approval", text: "Already handled elsewhere")
        case .none:
          // The RPC threw — the card is already dismissed, so surface the failure instead
          // of silently swallowing it (never a false "Approved").
          state.errorBanner = "Failed to send the approval response."
        default:
          // Defensive only: the effect never feeds back a resolved >= 1 (the optimistic
          // "Approved"/"Denied" row is already correct, no action needed).
          break
        }
        return .none

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
        return copyWithFeedback(text, token: Self.rowCopyToken(id), state: &state)

      case let .copyCode(text, token):
        guard !text.isEmpty else { return .none }
        return copyWithFeedback(text, token: token, state: &state)

      case let .copyFeedbackExpired(token):
        if state.recentlyCopiedToken == token { state.recentlyCopiedToken = nil }
        return .none

      // MARK: Branch a message into a new chat (#34)

      case let .branchFromMessage(id):
        // Only a COMPLETED assistant message with actual text can seed a branch. The view
        // hides the button on other rows, but the reducer stays the authority — a
        // streaming, empty, or non-message row is a silent no-op.
        guard case let .message(role, text, isComplete)? = state.transcript[id: id]?.kind,
              role == .assistant, isComplete,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .none }
        // Double-fire guard: one branch RPC at a time — a second tap is a no-op.
        guard !state.isBranching else { return .none }
        // Desktop parity: the running turn must be stopped before branching.
        if state.isSending {
          state.errorBanner = "Stop the current turn before branching."
          return .none
        }
        // Only a PERSISTED id with an actual DB ROW may parent a branch:
        // `parent_session_id` must match a REST list row id for the branch to nest — a
        // live-only handle would stamp a link no list row ever matches, and an
        // UNPERSISTED branch (`attachLiveSessionID != nil`) holds only the row-less
        // `session_key`; branching from it would dangle the grandchild's parent link
        // forever (the slot replacement tears the never-prompted middle branch down for
        // the server to reap, so its row never lands). A standing `branchSeed` is the
        // same hazard even once `attachLiveSessionID` has been nilled by an interrupted
        // reap-recovery replay — `storedSessionID` still points at the dead pre-reap
        // session for several seconds until the replay's fresh create lands. The view
        // disables the button via `canBranch`; a race still gets honest feedback, not a
        // silent no-op. Also requires a connected socket (review finding 2) — a
        // `.gatewayClosed` finalizes a mid-stream row as complete and clears `isSending`
        // the instant the socket drops, so without this the bar would look branchable
        // (from a possibly-truncated reply) while `.reconnecting`, and the RPC would
        // just fail against the dead socket instead of being blocked up front.
        guard let parentID = state.storedSessionID, state.attachLiveSessionID == nil,
              state.branchSeed == nil, state.status == .ready
        else {
          state.errorBanner = "This chat can’t be branched yet."
          return .none
        }
        let seed = State.BranchSeed(text: text, parentSessionID: parentID)
        state.pendingBranchSeed = seed
        state.isBranching = true
        return branchSession(seed: seed, profile: state.scopedProfile)

      case let .branchResult(.success(handle)):
        state.isBranching = false
        // Hand the parent the full handle — the stored id is the branch's list/marker
        // identity, and the live id is what the replacement chat attaches to
        // (`session.activate`; the branch has no DB row until its first prompt, so it
        // cannot be opened via `session.resume` by stored id) — plus the stashed seed,
        // which the replacement chat carries so an orphan-reaped branch can be rebuilt.
        guard let seed = state.pendingBranchSeed else { return .none }
        state.pendingBranchSeed = nil
        return .send(.delegate(.branchCreated(.init(handle: handle, seed: seed))))

      case let .branchResult(.failure(error)):
        // Surface the failure — never a swallowed `try?` (project convention).
        state.isBranching = false
        state.pendingBranchSeed = nil
        state.errorBanner = "Couldn’t branch the chat: \(error.message)"
        return .none

      case let .branchReplayResult(.success(handle)):
        // The reaped branch was rebuilt from the client-held seed (#34): bind the FRESH
        // live session — still unpersisted (no DB row until its first prompt), so re-arm
        // the attach-by-live-id bookkeeping and KEEP the seed for a further reap — then
        // attach for the authoritative seeded history. `hasReplayedBranchSeed` stays set
        // until that attach lands (`applyActivate` resets it), bounding a pathological
        // replay → attach-fail → replay loop to one round before the bannered degrade.
        state.liveSessionID = handle.sessionID
        state.storedSessionID = handle.storedSessionID ?? state.storedSessionID
        state.attachLiveSessionID = handle.sessionID
        return attachLive(sessionID: handle.sessionID)

      case let .branchReplayResult(.failure(error)):
        // A transport-shaped interruption (socket drop / deliberate teardown while the
        // seeded create was in flight) is no server verdict, and the client-held seed is
        // the ONLY copy of the branch — KEEP it and refund the replay budget so the
        // post-reconnect hydrate's not-found replays it again. Mirrors
        // `.sessionResult(.failure(.disconnected))`: status-only, no destructive side
        // effect, and never a `createSession` fired into a dead socket (it would fail
        // `.notConnected`, overwrite the banner, and the eventual `.ready` clears
        // banners anyway).
        if error.isDisconnected || error == .notConnected {
          state.hasReplayedBranchSeed = false
          state.status = .reconnecting
          // The companion `.gatewayClosed` owns the backoff redial — don't stack one.
          return .none
        }
        if error.isTimedOut {
          // A HALF-OPEN socket may never surface `.gatewayClosed` (see the hydrate
          // timeout arm) — schedule the redial ourselves so the chat isn't stranded in
          // `.reconnecting` with the seed parked forever; the fresh `.ready` re-runs
          // the recovery and replays the kept seed.
          state.hasReplayedBranchSeed = false
          state.status = .reconnecting
          guard !state.awaitingReauth else { return .none }
          state.hasRequestedSession = false
          return .merge(
            .cancel(id: CancelID.reconnect),
            connect(state.connection)
          )
        }
        // A genuine server rejection: the rebuild itself failed — degrade to a fresh
        // session so the chat still works, but NEVER silently: the on-screen seeded
        // message is not in the fresh session's context, and the user must know before
        // asking follow-ups about it.
        state.errorBanner = "Couldn’t restore the branch — starting a fresh chat."
        state.branchSeed = nil
        return createSession(profile: state.scopedProfile)

      case .copySessionIDTapped:
        // No session yet (brand-new chat before `session.create` resolves) — nothing to
        // copy, and no toast to promise one.
        guard let sessionID = state.sessionKey else { return .none }
        state.copiedIDToastToken = (state.copiedIDToastToken ?? 0) + 1
        // Copy now; hide the confirmation after a beat. A second copy while the toast is
        // up restarts the dwell (cancelInFlight) so the latest copy owns the countdown.
        return .merge(
          .run { [pasteboard] _ in pasteboard.copy(sessionID) },
          .run { [clock] send in
            try await clock.sleep(for: Self.copiedFeedbackDuration)
            await send(.copiedIDToastExpired)
          }
          .cancellable(id: CancelID.copyIDToast, cancelInFlight: true)
        )

      case .copiedIDToastExpired:
        state.copiedIDToastToken = nil
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
          await stagePicked(await attachmentPicker.pickPhotos(), uuid: uuid, send: send)
        }

      case .attachCameraTapped:
        return .run { [attachmentPicker, uuid] send in
          await stagePicked(await attachmentPicker.capturePhoto(), uuid: uuid, send: send)
        }

      case .attachFilesTapped:
        return .run { [attachmentPicker, uuid] send in
          await stagePicked(await attachmentPicker.pickFiles(), uuid: uuid, send: send)
        }

      case let .attachmentAdded(attachment):
        // A pick that worked takes the stale banner down with it, exactly as a successful
        // paste does — a "Couldn’t add the selected item." left hanging over the chip the
        // *next* pick just staged reads as a verdict on that chip. `stagePicked` stages every
        // surviving item before reporting the shortfall, so a partial loss still ends with its
        // own banner up.
        state.errorBanner = nil
        state.attachments.append(attachment)
        return .none

      case .attachmentsPasting:
        state.pendingPasteCount += 1
        return .none

      case let .attachmentsPasted(batch):
        // **Pairing check, not a defensive clamp.** The paste load is the one attachment
        // source that runs outside TCA's effect lifecycle — the three pickers are `.run`
        // effects, which `ifLet` cancels when `AppFeature` nils the live-chat slot, but the
        // load lives in the view coordinator's own `Task` and delivers unconditionally
        // through the store `ChatView` captured. An ordinary `store.send` on an invalidated
        // child store is still forwarded to the root, where `.ifLet(\.liveChat)` applies it
        // to WHATEVER chat now occupies the slot — and the window is the whole load (seconds
        // for a Universal Clipboard item, up to `clipboardLoadTimeout` for a hung one), long
        // enough for an idle pop + open, a push tap for another session (#32), or a branch
        // creation to have replaced it. Without this guard the image silently appears in a
        // conversation it was never pasted into, and uploads there on Send.
        //
        // A zero count means this state never saw the paste's `attachmentsPasting` half, so
        // the batch is not ours: drop it. Sound because `attachmentsPasting` is sent
        // SYNCHRONOUSLY inside `paste(_:)` (it always lands on the state that owns the
        // paste), a replacement slot is a fresh `State` and therefore starts at `0`, and
        // hydrate mutates state in place rather than rebuilding it — nothing else anywhere
        // writes `pendingPasteCount`.
        guard state.pendingPasteCount > 0 else { return .none }
        // Released first and unconditionally from here on: every branch below is a terminal
        // outcome for this paste, and a `return` that skipped the decrement would lock the
        // composer for the rest of the session.
        state.pendingPasteCount -= 1
        // The view already refuses to claim **Paste** without the capability
        // (`ComposerInputTextView.acceptsPastedImages`), so this is the backstop for the
        // async window it can't cover: the providers load asynchronously, and an
        // `attachmentsUnsupportedDetected` can land between the paste and the finished items.
        // Drop them silently — no chip that could never upload, and that flip already
        // bannered its own explanation.
        guard !state.attachmentsUnsupported else { return .none }
        guard !batch.items.isEmpty else {
          // The view only hands over a paste it claimed, i.e. one the clipboard advertised as
          // an image, so an empty batch means every provider failed to load or re-encode. The
          // user asked for this and the menu promised it — a silent no-op is the one outcome
          // the composer must not have.
          state.errorBanner = "Couldn’t paste the image."
          return .none
        }
        // A paste that worked clears whatever failure was still on screen — including this
        // path's own previous banner, which would otherwise read as a verdict on the chip
        // that just appeared.
        state.errorBanner = nil
        for item in batch.items { state.attachments.append(item.attachment(id: uuid())) }
        // …but a paste that only *partly* worked says so, after staging, exactly as a partial
        // pick does (`.attachmentsDropped`). Silence here let a user send two chips believing
        // they had pasted three. Worded for the clipboard rather than reusing the picker's
        // "selected item" copy.
        if batch.droppedCount > 0 {
          state.errorBanner = batch.droppedCount == 1
            ? "Couldn’t paste 1 of the images."
            : "Couldn’t paste \(batch.droppedCount) of the images."
        }
        return .none

      case let .attachmentsDropped(count):
        // Something the user picked never became a chip. The sheet has already dismissed, so
        // without this the whole gesture is a silent no-op (see `PickedBatch.droppedCount`).
        state.errorBanner = count == 1
          ? "Couldn’t add the selected item."
          : "Couldn’t add \(count) of the selected items."
        return .none

      case let .removeAttachment(id):
        state.attachments.removeAll { $0.id == id }
        return .none

      case let .attachmentsSubmitted(displayText, images, rowID, fromQueue):
        // Upload + submit landed: echo the user row (with image thumbnails), clear composer +
        // attachments. isSending stays true — the turn streams (clears on completion).
        let wasAtBottomWindow = state.windowStart >= State.bottomWindowStart(count: state.transcript.count)
        state.transcript.append(ChatRow(
          id: rowID,
          kind: .message(role: .user, text: displayText, isComplete: true),
          attachmentImages: images
        ))
        maintainWindowAfterStreaming(wasAtBottomWindow: wasAtBottomWindow, into: &state)
        if fromQueue {
          // A drained entry (#66): its bytes lived in `drainingEntry`, never the composer —
          // clearing the composer here would destroy whatever the user typed since.
          clearDrainingEntry(into: &state)
        } else {
          state.composerText = ""
          state.attachments = []
        }
        return .none

      case let .attachmentUploadFailed(message):
        // Keep the composer text + attachments so the user can retry; just flag the failure.
        state.errorBanner = "Attachment failed: \(message)"
        state.isSending = false
        if state.drainingEntry != nil {
          // A drained entry's upload failed (#66): the failed bytes live in the entry, not
          // the composer — re-park it and leave the composer's own staged attachments alone.
          reparkDrainingEntry(into: &state)
        } else {
          for index in state.attachments.indices { state.attachments[index].uploadState = .failed(message) }
        }
        // The attachment-submit path wrote the turn anchor; a failed upload never starts a
        // turn, so clear it — keeping every `setTurnAnchor` paired with a clear (mirrors
        // `.promptSubmitFailed`). Client-side turn end: also emit `runningChanged(false)` so
        // a DETACHED slot waiting on the turn is torn down (no server event will follow).
        return .merge(clearTurnAnchor(state), runningChanged(false, state))

      case .attachmentsUnsupportedDetected:
        // The agent is too old to accept uploads: hide the affordance for the session and
        // explain why, rather than leaving the user with a generic RPC error.
        state.attachmentsUnsupported = true
        state.isSending = false
        state.errorBanner = "This Hermes agent is too old to accept attachments. Update the agent to send files."
        if state.drainingEntry != nil {
          // A drained entry hit the capability wall (#66): re-park it (edit/delete stay
          // available from the panel) and leave the composer's staged attachments alone.
          reparkDrainingEntry(into: &state)
        } else {
          for index in state.attachments.indices { state.attachments[index].uploadState = .failed("Attachments not supported") }
        }
        // Client-side turn end (the submit was aborted; no server event will follow): emit
        // `runningChanged(false)` so a DETACHED slot waiting on the turn is torn down
        // (mirrors `.promptSubmitFailed` / `.attachmentUploadFailed`).
        return runningChanged(false, state)

      case let .commandCatalogLoaded(catalog):
        state.commandCatalog = catalog
        return .none

      case .commandsUnsupportedDetected:
        // Attach pattern (#36): the agent predates `commands.catalog`. Silently hide the
        // whole slash affordance — nothing the user did failed, so no banner; plain sends
        // stay byte-identical to today.
        state.commandsUnsupported = true
        return .none

      case let .slashSuggestionTapped(suggestion):
        state.composerText = suggestion.insertionText
        return .none

      case let .slashCommandOutput(output):
        appendCommandOutput(output, into: &state)
        return finishSlashExec(refresh: true, into: &state)

      case let .slashCommandNotice(text):
        // Output row only — no lock/turn-state changes: the `prompt.submit` following a
        // `send` directive owns the turn lifecycle, so unlocking (or emitting
        // `runningChanged(false)`) here would blip the composer open and tear down a
        // detached slot mid-directive.
        appendCommandOutput(text, into: &state)
        return .none

      case .slashCommandHandedOff:
        // A `skill`/`send` directive's `prompt.submit` landed: the exec round-trip is over
        // and a REAL turn now owns `isSending` (it stays locked, driven by the turn's own
        // lifecycle). Only the mid-exec hydrate guard is released — nothing else changes.
        state.slashExecInFlight = false
        // A drained slash entry that handed off to a real turn is consumed (#66).
        clearDrainingEntry(into: &state)
        return .none

      case let .slashCommandPrefill(message, notice):
        // `/undo`: the server ALREADY rewound history on disk and answered
        // `{type:"prefill", message, notice}` — drop the undone message into the composer
        // for editing and render the notice (desktop parity: `slash.ts` sets the composer
        // draft). The rewound turns are removed from the transcript by the refresh below,
        // which is server-authoritative precisely because the rewind IS a history change.
        if let notice { appendCommandOutput(notice, into: &state) }
        // The prefilled draft is set straight into the composer (not through
        // `appendCommandOutput`), so strip ANSI here too (#36 follow-up).
        if !message.isEmpty { state.composerText = message.strippingANSI }
        return finishSlashExec(refresh: true, into: &state)

      case let .slashCommandFailed(message):
        state.errorBanner = "Command failed: \(message)"
        // A drained slash entry whose exec failed goes back to the panel, parked (#66) —
        // its echo row comes out with it, and the park keeps `finishSlashExec` from
        // immediately re-draining the same doomed command.
        reparkDrainingEntry(into: &state)
        // No refresh — a failure lands no history change (unlike output/prefill).
        return finishSlashExec(refresh: false, into: &state)

      case let .slashHistoryRefreshed(response):
        // Stale-refresh guard (#36): the refresh's `session.resume` was fired when the exec
        // finished, but its round-trip is async and the composer is UNLOCKED for that window
        // (`finishSlashExec` already cleared the lock). If a NEW turn (`prompt.submit`) or a
        // NEW slash exec started in the meantime, this response PREDATES it — applying it
        // would wholesale-replace the transcript, wiping the new turn's optimistic user/
        // streaming rows and resetting `isSending`, unlocking or erasing a genuinely-running
        // turn. Drop it; the new turn's own lifecycle (and any later real hydrate) is
        // authoritative. `isSending` catches both a fresh `prompt.submit` and a live
        // `message.start`; `slashExecInFlight`/`thinkingRowID` are belt-and-suspenders.
        guard !state.isSending, !state.slashExecInFlight, state.thinkingRowID == nil
        else { return .none }
        // The post-command refresh landed. It is the FULL server-authoritative hydrate,
        // not a runtime-only patch: slash commands MUTATE server history — `/undo` rewinds
        // it (`db.rewind_to_message`), `/compress`//`/compact` rewrite it, `/retry`
        // truncates it — and a runtime-only refresh left those rows on screen indefinitely
        // (re-persisted into the snapshot cache, so even a cold relaunch repainted them,
        // and re-sending a `/undo` prefill produced a visually duplicated turn). It costs
        // nothing extra on the wire: `session.resume` already returns the whole cooked
        // history; the old path decoded it and threw it away.
        //
        // Carry ONLY the JUST-produced ephemeral `commandOutput` row (the current command's
        // own output/notice — never in server history) across the wholesale replace, so this
        // command's feedback survives the refresh that removes the rows it acted on. Each
        // refresh-triggering command appends exactly one such row immediately before firing
        // the refresh, so it's the LAST `commandOutput` row. Older ones from EARLIER execs
        // are dropped here (like any real hydrate drops them): re-appending them all after
        // the whole server transcript put them out of chronological order once more than one
        // exec had run. Normal hydrates are untouched — they still drop every such row.
        let ephemeral = state.transcript.filter { $0.kind.discriminator == "commandOutput" }.suffix(1)
        let effect = applyActivate(response, into: &state)
        for row in ephemeral where state.transcript[id: row.id] == nil { state.transcript.append(row) }
        // Title isn't part of `applyActivate`'s runtime info — apply it so `/title x`
        // updates the open chat's nav title immediately.
        if let title = response.info?.title?.nonEmpty { state.title = title }
        // Re-pin the bottom window after the re-append (the count changed).
        state.windowStart = State.bottomWindowStart(count: state.transcript.count)
        return effect

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

      case let .modelSelected(model, providerSlug):
        // Blocked mid-turn (server returns 4009); the picker disables selection too.
        guard !state.isSending, let sessionID = state.liveSessionID else { return .none }
        // Roll back to the last SERVER-confirmed value, not to a still-in-flight pick's.
        let previousModel = state.pendingConfigRollback["model"] ?? state.model
        state.pendingConfigRollback.updateValue(previousModel, forKey: "model")
        state.model = model // optimistic; reconciled by the next session.info
        clearConfigError(&state)
        // Desktop parity (`use-model-controls.ts`): the value carries the picker
        // section's provider slug so the gateway's model routing never guesses from
        // the model id alone. A nil slug (no section context) stays a bare model id —
        // the gateway's own detection ladder handles it exactly as before.
        let wireValue = providerSlug.map { "\(model) --provider \($0)" } ?? model
        return configSet(
          key: "model", value: wireValue, previousValue: previousModel, sessionID: sessionID,
          storedSessionID: state.storedSessionID, branchSeed: state.branchSeed,
          profile: state.scopedProfile
        )

      case let .reasoningSelected(effort):
        guard !state.isSending, let sessionID = state.liveSessionID else { return .none }
        let previousEffort = state.pendingConfigRollback["reasoning"] ?? state.reasoningEffort
        state.pendingConfigRollback.updateValue(previousEffort, forKey: "reasoning")
        state.reasoningEffort = effort
        clearConfigError(&state)
        return configSet(
          key: "reasoning", value: effort, previousValue: previousEffort, sessionID: sessionID,
          storedSessionID: state.storedSessionID, branchSeed: state.branchSeed,
          profile: state.scopedProfile
        )

      case let .configSetFailed(key, value, previousValue, error):
        // Roll the optimistic picker write back so the chip stops lying (the next authoritative
        // `session.info` wins again anyway), then surface the failure — never swallowed.
        switch key {
        case "model": state.model = previousValue
        case "reasoning": state.reasoningEffort = previousValue
        default: break
        }
        state.pendingConfigRollback.removeValue(forKey: key)
        // ONLY the 4002 verdict is a capability statement; a transport failure or any other
        // server error (e.g. a mid-turn 4009) says nothing about the agent's ladder (#62 logic).
        let message: String
        if key == "reasoning", error.isUnknownReasoningValue {
          state.extendedReasoningSupported = false
          message = "This agent doesn’t support \"\(value)\" reasoning."
        } else {
          message = "Couldn’t change \(key): \(error.message)"
        }
        state.errorBanner = message
        // The banner sits behind the still-presented sheet, so the picker carries the same
        // text inline — otherwise the pick just silently snaps back.
        state.modelPicker?.applyError = message
        // Deliberately no `isSending`/`activity` change: a config change is not a turn. The
        // sheet stays open, the row deselects under the inline error (desktop parity).
        return .none

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
      // An unpersisted branch (#34) attaches to its already-live session by LIVE id —
      // it has no DB row until its first prompt, so `session.resume` would 4007.
      if let live = state.attachLiveSessionID {
        state.hydrateRetriedAfterTimeout = false
        return attachLive(sessionID: live)
      }
      // No stored id → a fresh session: `session.create` (handle only). A stored id →
      // re-hydrate server-authoritatively via the unified `hydrate` path.
      if let stored = state.storedSessionID {
        state.hydrateRetriedAfterTimeout = false // fresh hydrate: the retry budget resets
        return hydrate(sessionID: stored, profile: state.scopedProfile)
      }
      // A standing branch seed with no stored id (an interrupted replay on a branch
      // whose create returned no session_key) recovers the branch here — never a
      // silent bare create under the still-painted seed; a spent replay budget
      // degrades honestly (banner + seed drop) instead.
      if let seed = state.branchSeed {
        if !state.hasReplayedBranchSeed {
          state.hasReplayedBranchSeed = true
          return replayBranchSeed(seed, profile: state.scopedProfile)
        }
        state.errorBanner = "Couldn’t restore the branch — starting a fresh chat."
        state.branchSeed = nil
      }
      return createSession(profile: state.scopedProfile)

    case .messageStart:
      // Defer creating the assistant row until the first delta — a tool-only turn emits
      // message.start with no text, and an eager empty row renders as a blank bubble.
      state.streamingRowID = nil
      state.errorBanner = nil
      state.isSending = true
      // The drained entry's turn started (#66) — the submit demonstrably reached the
      // server, so the entry is consumed (its echo row is now the turn's real user row).
      clearDrainingEntry(into: &state)
      // A turn started, so the first prompt landed — the server has persisted the DB row
      // for an unpersisted branch (#34); from here the standard `session.resume` by
      // stored id serves every subsequent hydrate, the client-held seed is durable
      // server-side (drop it), and the replay budget resets.
      state.attachLiveSessionID = nil
      state.branchSeed = nil
      state.hasReplayedBranchSeed = false
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
      // A turn can never legitimately COMPLETE with an approval still queued (the server
      // blocks on the queue), so a standing approval card here is stale — most visibly a
      // push-tap-recovered card (#30 workaround) whose approval was answered on another
      // client, letting the turn run to completion. Drop it (and the armed hint) so the
      // finished chat isn't stuck behind a phantom card locking the composer.
      clearStaleApproval(into: &state)
      // A stale draining entry here means the start event was lost/reordered — the turn
      // demonstrably ran, so the entry is consumed either way (never re-queued).
      clearDrainingEntry(into: &state)
      // Turn ended — drop the anchor so a later hydrate doesn't resurrect a phantom timer,
      // and tell the list to clear this session's working glow immediately. This is also
      // the primary DRAIN edge (#66): the queue's head fires as the next turn. (The drain's
      // own `setTurnAnchor` can race `clearTurnAnchor` across the merged effects, but
      // `message.start` reaffirms the anchor moments later, so the race is harmless.)
      return .merge(
        .cancel(id: CancelID.thinkingTimer), clearTurnAnchor(state), runningChanged(false, state),
        drainQueueIfReady(into: &state)
      )

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
      // Same staleness rule as `message.complete`: an errored turn is over, so any
      // standing approval card (real or recovered) and the recovery hint are moot.
      clearStaleApproval(into: &state)
      // The errored turn consumed any draining entry (#66) — it ran; never re-queue it.
      clearDrainingEntry(into: &state)
      // An error PARKS the queue rather than draining it (#66): auto-firing the next entry
      // into whatever just failed could burn the whole queue against a broken server. The
      // one exception is a Send-now that interrupted this turn — its terminal lands here on
      // some agents — where the user explicitly asked for the next entry.
      let drain: Effect<Action>
      if state.sendNowArmed {
        drain = drainQueueIfReady(into: &state)
      } else {
        if !state.queuedPrompts.isEmpty { state.isQueueParked = true }
        drain = .none
      }
      // Turn ended in error — drop the anchor (prevents a phantom timer on the next hydrate)
      // and clear the list's working glow for this session immediately.
      return .merge(.cancel(id: CancelID.thinkingTimer), clearTurnAnchor(state), runningChanged(false, state), drain)

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
      // The real event overwrites any push-tap-synthesized card unconditionally and clears
      // the recovery hint so a later hydrate can't re-synthesize (#30 workaround).
      state.present(.approval(request))
      state.expectsPendingApproval = false
      return .none

    case let .clarifyRequest(request):
      state.present(.clarify(request))
      return .none

    case let .sudoRequest(prompt):
      state.present(.secret(.sudo, prompt))
      return .none

    case let .secretRequest(prompt):
      state.present(.secret(.secret, prompt))
      return .none

    case let .sessionInfo(info):
      // Update the model/reasoning chip; later session.info events can be partial, so
      // only overwrite fields that are present.
      if let model = info.model?.nonEmpty { state.model = model }
      if let effort = info.reasoningEffort?.nonEmpty { state.reasoningEffort = effort }
      if let u = info.usage { state.usage = u }
      confirmConfigKeys(info, into: &state)
      return .none

    case let .reviewSummary(text):
      // Live-only self-improvement review summary (#47): render as a bubble-less system
      // line, verbatim (the 💾 prefix arrives on the wire). Ephemeral by design — the
      // event never lands in session history, so the next hydrate replaces it wholesale.
      guard Self.hasRenderableReviewText(text) else { return .none }
      state.transcript.append(
        ChatRow(id: uuid(), kind: .status(kind: ChatRow.Kind.reviewStatusKind, text: text))
      )
      keepThinkingLast(into: &state)
      return .none

    case .unknown:
      return .none
    }
  }

  /// The feedback token for a whole-row copy (#34). Public so the view's action bar can
  /// derive the same token to drive its checkmark-swap without duplicating the format.
  public static func rowCopyToken(_ id: ChatRow.ID) -> String { "row:\(id.uuidString)" }

  /// Shared copy-with-checkmark path for code blocks (#9) and whole rows (#34): put the
  /// text on the pasteboard, mark `token` as recently copied, and clear it after a beat.
  /// Re-tapping any copy target restarts the timer (`cancelInFlight`) so the latest copy
  /// owns the feedback.
  private func copyWithFeedback(_ text: String, token: String, state: inout State) -> Effect<Action> {
    state.recentlyCopiedToken = token
    return .merge(
      .run { [pasteboard] _ in pasteboard.copy(text) },
      .run { [clock] send in
        try await clock.sleep(for: .seconds(1.5))
        await send(.copyFeedbackExpired(token: token))
      }
      .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
    )
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

  /// Drop a standing approval card + the push-tap recovery hint when the turn is known
  /// to be over (turn-end events, or a hydrate reporting `running == false`). The server
  /// never ends a turn with an approval still queued, so a card outliving its turn is
  /// stale by definition — answered on another client (the mainline recovered-card
  /// false-positive path, #30 workaround) or timed out. Scoped to `.approval` only:
  /// clarify/secret are request-id-keyed and out of this workaround's scope. NOT called
  /// on socket drop (`finalizeInFlight`) — the turn may still be running server-side.
  private func clearStaleApproval(into state: inout State) {
    if case .approval = state.pendingInteraction {
      state.pendingInteraction = nil
    }
    state.expectsPendingApproval = false
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

  /// Shared voice cleanup for `.viewDisappeared` and `.teardown`: reset the recording UI
  /// state, cancel the level/tick effects, and release the mic/session if we leave
  /// mid-recording.
  private func releaseVoiceResources(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.recording.isBusy
    state.recording = .idle
    state.waveformLevels = []
    state.recordingSeconds = 0
    return .merge(
      .cancel(id: CancelID.voiceLevels),
      .cancel(id: CancelID.voiceTimer),
      wasRecording ? .run { [audioRecorder] _ in await audioRecorder.cancel() } : .none
    )
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
      await send(.sessionResult(createSessionRPC(fields: [:], profile: profile, gateway: gateway)))
    }
  }

  /// Branch a message into a new chat (#34): the desktop-parity `session.create` carrying
  /// a single-message seed (`messages`) + `parent_session_id`. Otherwise byte-identical to
  /// `createSession` — no `title` (the server auto-names on the first submit), the
  /// default/nil profile omitted. The server stores the parent link in memory and creates
  /// the DB row lazily on the first prompt, so an abandoned branch never appears in the
  /// session list (documented v1 behavior — no optimistic insert).
  private func branchSession(seed: State.BranchSeed, profile: String?) -> Effect<Action> {
    .run { [gateway] send in
      await send(.branchResult(
        createSessionRPC(fields: branchSeedFields(seed), profile: profile, gateway: gateway)
      ))
    }
  }

  /// Replay the seeded branch `session.create` after the server reaped the unpersisted
  /// live session (#34) — the same wire shape as `branchSession`, routed to
  /// `.branchReplayResult` so the fresh handle re-arms the attach bookkeeping in place
  /// instead of emitting a second `branchCreated` slot replacement.
  private func replayBranchSeed(_ seed: State.BranchSeed, profile: String?) -> Effect<Action> {
    .run { [gateway] send in
      await send(.branchReplayResult(
        createSessionRPC(fields: branchSeedFields(seed), profile: profile, gateway: gateway)
      ))
    }
  }

  /// Attach to an already-live session by its runtime id — the unpersisted-branch hydrate
  /// (#34). The branch's `session.create` ran on the PARENT chat's socket, which the slot
  /// replacement tears down, and the new session has no DB row until its first prompt, so
  /// `session.resume` by stored id hard-fails. `session.activate` looks the session up in
  /// server memory, re-binds its transport to THIS socket (also cancelling the server's
  /// orphan reap of parked WS sessions), and returns the same authoritative payload shape
  /// (`messages`/`info`/`running`/`inflight`) — applied through the standard
  /// `.activateResult` path. No `profile` param: the live session already carries its
  /// profile binding. Shares `CancelID.hydrate` with `hydrate` (one outstanding hydrate;
  /// a deliberate socket teardown cancels it).
  private func attachLive(sessionID: String) -> Effect<Action> {
    .run { [gateway] send in
      do {
        let result = try await gateway.send(
          "session.activate", .object(["session_id": .string(sessionID)])
        )
        if let response = result.decoded(ActivateResponse.self), !response.sessionID.isEmpty {
          await send(.activateResult(.success(response)))
        } else {
          await send(.activateResult(.failure(.server("Malformed session.activate result"))))
        }
      } catch let error as GatewayError {
        await send(.activateResult(.failure(error)))
      } catch {
        await send(.activateResult(.failure(.disconnected)))
      }
    }
    .cancellable(id: CancelID.hydrate, cancelInFlight: true)
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
    // Only one hydrate may be outstanding, and a DELIBERATE socket teardown
    // (`.teardownSocketOnly` / `.teardown`) cancels it so no stale `.activateResult`
    // reduces afterwards (the socket cancellation would otherwise resume this RPC with
    // `.disconnected`, e.g. redialing while backgrounded after grace expiry).
    .cancellable(id: CancelID.hydrate, cancelInFlight: true)
  }

  /// Review finding 1's recovery probe: `session.resume` by the branch's PERSISTED
  /// `storedSessionID` (server `session_key`) — NOT the live id `session.activate` just
  /// answered "not found" for (review iteration 2 finding a: those are different values;
  /// probing with the live id always 404s). Wire-identical to `hydrate`, but routed to
  /// `.branchResumeProbeResult` instead of `.activateResult` — a distinct action so a
  /// not-found here falls through to `handleActivateFailure` exactly once, rather than
  /// re-triggering the probe gate and looping. Shares `CancelID.hydrate` (one outstanding
  /// hydrate at a time; a deliberate socket teardown cancels it).
  private func probeBranchResume(sessionID: String, profile: String?) -> Effect<Action> {
    .run { [gateway] send in
      var fields: [String: JSONValue] = ["session_id": .string(sessionID)]
      if let profile { fields["profile"] = .string(profile) }
      let params: JSONValue = .object(fields)
      do {
        let result = try await gateway.send("session.resume", params)
        if let response = result.decoded(ActivateResponse.self), !response.sessionID.isEmpty {
          await send(.branchResumeProbeResult(.success(response)))
        } else {
          await send(.branchResumeProbeResult(.failure(.server("Malformed session.resume result"))))
        }
      } catch let error as GatewayError {
        await send(.branchResumeProbeResult(.failure(error)))
      } catch {
        await send(.branchResumeProbeResult(.failure(.disconnected)))
      }
    }
    .cancellable(id: CancelID.hydrate, cancelInFlight: true)
  }

  /// The synthetic approval request the push-tap recovery path synthesizes (#30
  /// workaround): the real `approval.request` fired while the socket was down and its
  /// payload is unrecoverable (the push deliberately carries no content per the
  /// generic-body privacy rule), so the recovered card is command-less with honest copy.
  /// `ApprovalCardView` already renders a `command == nil` request (detail-only card);
  /// no `isSynthesized` marker exists anywhere — the card is distinguished only by its
  /// content, and `approval.respond` works identically (approvals have no `request_id`).
  public static let recoveredApprovalRequest = ApprovalRequest(
    command: nil,
    detail: "The agent is waiting for approval of a command, but the details couldn't "
      + "be recovered after reconnecting. Approve only if you know what it's doing."
  )

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
    state.hydrateRetriedAfterTimeout = false // hydrate landed: the timeout-retry budget resets
    state.hasReplayedBranchSeed = false // and so does the branch seed-replay budget (#34)
    state.hasHydrated = true // the transcript below is now server-authoritative (#80 hero gate)
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
      confirmConfigKeys(info, into: &state)
    }

    // Working indicator from the authoritative `running` flag — except while a slash exec
    // is outstanding (#36). An exec is NOT a turn (no `message.start`/`complete`, `running`
    // stays false), so taking `running` verbatim here would UNLOCK the composer mid-exec
    // and let a second command be submitted whose state the first exec's terminal action
    // would then tear down. The exec's own terminal action clears the flag and the lock.
    let running = response.running ?? false
    state.isSending = running || state.slashExecInFlight

    // Push-tap approval recovery (#30 workaround): consume the one-shot hint here — every
    // open/foreground/cold-launch/reattach path funnels through this hydrate, so this is
    // the single synthesis point. Synthesize the generic card only when the authoritative
    // `running` says the agent is still blocked AND the socket didn't already deliver a
    // real blocking request. Not running → the approval resolved/denied/timed out while
    // we were detached → drop silently (no phantom card). Consuming the hint first means
    // a double hydrate of the same running turn can't synthesize twice.
    if state.expectsPendingApproval {
      state.expectsPendingApproval = false
      if running, state.pendingInteraction == nil {
        state.present(.approval(Self.recoveredApprovalRequest))
      }
    }
    // The inverse staleness rule: the authoritative "not running" means no approval can
    // be pending server-side (the server never ends a turn with one queued), so a card
    // still standing — e.g. a recovered card synthesized on an earlier hydrate, then
    // answered on another client while the socket was down and the turn ended — must be
    // dropped, or it would sit over a finished transcript locking the composer. (The
    // helper's hint-clear is a no-op here: the block above already consumed it.)
    if !running {
      clearStaleApproval(into: &state)
    }

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

    // One-shot slash-command catalog fetch now the hydrate reached ready (#36). Gated: only
    // when not yet loaded and the capability wasn't ruled out — a transient failure left the
    // catalog `nil`, making this next hydrate the natural retry point.
    let catalogEffect = commandCatalogEffect(state, sessionID: response.sessionID)

    // A hydrate confirming idle is a drain edge (#66): it covers `.gatewayClosed`
    // finalization (no `message.complete` ever arrives on a socket drop — the reconnect
    // hydrate is what learns the turn ended), the post-slash refresh, and plain
    // foreground/reattach. Preconditions all live in `drainQueueIfReady` — a running turn,
    // a standing card, or a parked queue make this a no-op. Evaluated after the wholesale
    // rebuild so the drained entry's echo row lands after the authoritative history.
    let drainEffect = drainQueueIfReady(into: &state)

    // Pull usage on-demand only when the response didn't carry it (older agents) — mirrors
    // the prior resume behavior so the gauge isn't blank until the next turn.
    if state.usage == nil {
      return .merge(
        fetchUsage(sessionID: response.sessionID), persist, timerEffect, runningEffect,
        catalogEffect, drainEffect
      )
    }
    return .merge(persist, timerEffect, runningEffect, catalogEffect, drainEffect)
  }

  /// The not-found/degrade/reconnect handling shared by a plain `session.activate` or
  /// `session.resume` hydrate failure AND — after review finding 1's resume probe comes back
  /// empty — a confirmed-unpersisted branch. Unchanged from before the probe was introduced:
  /// a standing `branchSeed` replays the seeded `session.create`; otherwise an unpersisted
  /// branch or an old agent's unknown `session.activate` degrades to a bannered fresh create;
  /// `.disconnected`/`.timedOut` get transport-symptom handling (banner-less reconnect/retry);
  /// anything else surfaces the error banner.
  private func handleActivateFailure(_ error: GatewayError, into state: inout State) -> Effect<Action> {
    // An unpersisted branch (#34) answering "session not found" means the server REAPED
    // the never-prompted live session (detached socket past the ~20s orphan grace —
    // routine on background→foreground). The seed is only gone SERVER-side; the client
    // still holds it in `branchSeed`, so replay the SEEDED `session.create` (messages +
    // parent_session_id), rebuilding the branch wholesale (context + nesting) instead of
    // degrading to a bare session under the still-painted seed. One replay per hydrate
    // (`hasReplayedBranchSeed`); a replay that fails — or a server that keeps answering
    // not-found — degrades to the bannered fresh create below. Recovery keys on the
    // DURABLE `branchSeed`, never the transient `attachLiveSessionID`: an interrupted
    // replay (socket drop while the seeded create was in flight) has already nilled the
    // attach redirect, and the post-reconnect hydrate's not-found on the row-less stored
    // id must still replay the seed rather than silently swap in a bare session.
    if error.isSessionNotFound,
       let seed = state.branchSeed, !state.hasReplayedBranchSeed {
      state.status = .reconnecting
      state.liveSessionID = nil
      state.attachLiveSessionID = nil // re-armed by the replay's fresh live id
      state.hasRequestedSession = true // the replayed create is the in-flight request
      state.hasReplayedBranchSeed = true
      return replayBranchSeed(seed, profile: state.scopedProfile)
    }
    // A real server "session not found" from the foreground `session.resume` is NOT a
    // benign socket drop: the stored id the agent had is gone (e.g. it expired/rebuilt).
    // Don't leave a stale `liveSessionID` standing (the next prompt.submit would fail too) —
    // recreate a fresh session so the chat can keep sending (#17). Keep the cached paint.
    // For an unpersisted branch (#34) that CAN'T seed-replay (no seed carried, or the
    // one replay already failed to stick) — and for an old agent whose
    // `session.activate` is unknown (`-32601`, it ignored the seed params anyway) —
    // degrade to the same fresh create, but NEVER silently: the on-screen seeded
    // message is not in the fresh session's context, and the user must know before
    // asking follow-ups about it. The branch bookkeeping must not stick to the fresh
    // session either way.
    if error.isSessionNotFound || (state.attachLiveSessionID != nil && error.isUnknownMethod) {
      // A standing seed counts as branch bookkeeping even when the attach redirect
      // was already consumed (interrupted replay): degrading past it must banner
      // AND drop the seed, or it would dangle on the fresh plain session and later
      // mis-arm attach-by-live-id via `liveSessionIDRefreshed`.
      if state.attachLiveSessionID != nil || state.branchSeed != nil {
        state.errorBanner = "Couldn’t restore the branch — starting a fresh chat."
        state.branchSeed = nil
      }
      state.status = .reconnecting
      state.liveSessionID = nil
      state.attachLiveSessionID = nil
      state.hasRequestedSession = true // createSession is the in-flight request
      return createSession(profile: state.scopedProfile)
    }
    // Offline / connection error: keep the cached instant-paint on screen (never blank
    // it) and show a subtle reconnecting status. The cached rows stay until a successful
    // resume replaces them wholesale.
    state.status = .reconnecting
    // `.disconnected` is never the lone symptom: the connection teardown that resumed
    // this RPC with `.disconnected` also finishes the event stream, so a companion
    // `.gatewayClosed` — with its escalating backoff — follows on its own. Redialing
    // here would defeat that backoff (a crash-looping server that drops on
    // `session.resume` would reconnect in a zero-delay storm) and would be actively
    // wrong when the socket effect was deliberately cancelled. Status-only; banner-less
    // (a banner would linger past the reconnect).
    if error.isDisconnected { return .none }
    // The hydrate RPC `.timedOut` over a stale-`.ready` socket after suspension/NAT
    // rebind: a HALF-OPEN socket may not surface `.gatewayClosed` for minutes, so we
    // must schedule the redial OURSELVES rather than strand the chat in `.reconnecting`
    // with no reconnect pending. Two guards keep this from killing a healthy socket:
    // - during the re-auth pause do nothing (a redial would waste a single-use
    //   ws-ticket; `.resumeAfterReauth` owns the reconnect), and
    // - a timeout over a live-but-SLOW socket (huge history, busy gateway) is
    //   indistinguishable from half-open, so the first timeout retries the hydrate once
    //   over the SAME socket instead of killing a possibly-streaming connection; only a
    //   second consecutive timeout concludes half-open and redials. (Trade-off: a truly
    //   half-open socket takes two request timeouts before the redial — accepted, since
    //   repeatedly killing a demonstrably-alive streaming socket mid-turn is worse.)
    // `connect` is cancellable on `CancelID.socket` with `cancelInFlight: true`, so a
    // concurrent `.gatewayClosed` backoff dial is safe (last dial wins); cancel any
    // pending backoff tick so it can't later redial over the fresh socket. Reset
    // `hasRequestedSession` so the fresh `.ready` actually re-hydrates. Banner-less —
    // a timeout is a transport symptom, not a server verdict; only a real
    // protocol/server error gets a banner.
    if error.isTimedOut {
      guard !state.awaitingReauth else { return .none }
      if !state.hydrateRetriedAfterTimeout, let live = state.attachLiveSessionID {
        // Unpersisted branch (#34): the same-socket retry re-attaches by live id.
        state.hydrateRetriedAfterTimeout = true
        return attachLive(sessionID: live)
      }
      if !state.hydrateRetriedAfterTimeout, let sessionID = state.sessionKey {
        state.hydrateRetriedAfterTimeout = true
        return hydrate(sessionID: sessionID, profile: state.scopedProfile)
      }
      state.hydrateRetriedAfterTimeout = false
      state.hasRequestedSession = false
      return .merge(
        .cancel(id: CancelID.reconnect),
        connect(state.connection)
      )
    }
    state.errorBanner = error.message
    return .none
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

  // MARK: - Slash-command catalog (#36)

  /// The one-shot `commands.catalog` fetch when it's due — not yet loaded and the
  /// capability not ruled out — or `.none`, so repeated hydrates never refetch a loaded
  /// catalog and never poke an agent that already answered `-32601`. The fetch follows
  /// the `model.options` convention (a discrete one-shot `gateway.send`), capability-gated
  /// the attach way: `-32601` flips `commandsUnsupported`; any other failure is silent —
  /// the catalog stays `nil` and the next hydrate naturally retries.
  private func commandCatalogEffect(_ state: State, sessionID: String) -> Effect<Action> {
    guard state.commandCatalog == nil, !state.commandsUnsupported else { return .none }
    return .run { [gateway] send in
      do {
        let result = try await gateway.send(
          "commands.catalog", .object(["session_id": .string(sessionID)])
        )
        // The lenient decode never throws, so an arbitrary/garbage payload surfaces as an
        // EMPTY catalog — as useless as none. Don't latch it: leave the state `nil`
        // (suggestions are empty either way) so a later hydrate can still recover.
        if let catalog = result.decoded(CommandCatalog.self), !catalog.commands.isEmpty {
          await send(.commandCatalogLoaded(catalog))
        }
      } catch let error as GatewayError where error.isUnknownMethod {
        await send(.commandsUnsupportedDetected)
      } catch {
        // Transient failure: silent — the catalog stays `nil`; the next hydrate retries.
      }
    }
  }

  /// The server-authoritative refresh after a slash command completes (#36): the same
  /// `session.resume` round-trip the hydrate uses, applied in full via `applyActivate` —
  /// model/reasoning/usage AND the transcript. A slash command can change either: `/model`
  /// swaps the chip, `/compress` shrinks the context pill AND rewrites history, `/undo`
  /// rewinds it, `/retry` truncates it. (The ephemeral `commandOutput` rows are preserved
  /// by the `.slashHistoryRefreshed` reducer case, so the output survives the replace.)
  ///
  /// Shares `CancelID.hydrate` so only ONE hydrate is ever outstanding — this refresh and
  /// a `.foreground`/`.reattached` hydrate must not race to reduce stale payloads.
  /// Failure is silent by design: the next real hydrate reconciles.
  private func refreshAfterSlashCommand(sessionID: String, profile: String?) -> Effect<Action> {
    .run { [gateway] send in
      var fields: [String: JSONValue] = ["session_id": .string(sessionID)]
      if let profile { fields["profile"] = .string(profile) }
      guard
        let result = try? await gateway.send("session.resume", .object(fields)),
        let response = result.decoded(ActivateResponse.self), !response.sessionID.isEmpty
      else { return }
      await send(.slashHistoryRefreshed(response))
    }
    .cancellable(id: CancelID.hydrate, cancelInFlight: true)
  }

  /// Append one ephemeral `commandOutput` row, keeping the bottom window pinned like a
  /// streaming append (a scrolled-up user is never yanked).
  private func appendCommandOutput(_ text: String, into state: inout State) {
    let wasAtBottomWindow = state.windowStart >= State.bottomWindowStart(count: state.transcript.count)
    // Strip ANSI/VT100 escapes (#36 follow-up): slash output/warnings/notices are formatted
    // for a terminal and render as literal garbage on mobile. This is the single chokepoint
    // for every ephemeral `commandOutput` row (`.slashCommandOutput`, `.slashCommandNotice`,
    // and the prefill notice), so nothing terminal-formatted leaks into the transcript.
    state.transcript.append(ChatRow(id: uuid(), kind: .commandOutput(text: text.strippingANSI)))
    maintainWindowAfterStreaming(wasAtBottomWindow: wasAtBottomWindow, into: &state)
  }

  /// Shared terminal tail for the slash-exec pipeline's completion actions
  /// (`.slashCommandOutput` / `.slashCommandPrefill` / `.slashCommandFailed`). The exec
  /// round-trip is over: release the mid-exec composer lock (a hydrate may now set
  /// `isSending` from the authoritative `running` again). Then — UNLESS a REAL server turn
  /// began while the exec was in flight (`message.start` set the thinking row + `isSending`),
  /// in which case the lock and running state belong to that turn's own lifecycle and
  /// `runningChanged` must stay server-confirmed — end the client-side "turn": no server
  /// event follows an exec-style command, so emit `runningChanged(false)` like
  /// `.promptSubmitFailed` does (tearing down a DETACHED slot waiting on the turn; harmless
  /// to the list glow, which only lights on `message.start`). When `refresh` is true and a
  /// live session exists, also fire the full server-authoritative `refreshAfterSlashCommand`
  /// hydrate (output/prefill land history changes; a failure passes `refresh: false`).
  private func finishSlashExec(refresh: Bool, into state: inout State) -> Effect<Action> {
    state.slashExecInFlight = false
    // A drained slash entry that reached its own terminal is consumed (#66) — a FAILED
    // exec was already re-parked by `.slashCommandFailed` before this ran, so this only
    // ever clears a successfully-executed entry. The queue itself drains on the refresh
    // hydrate (`applyActivate`) rather than here, so the post-command refresh isn't
    // clobbered by an immediately-started queued turn; the no-refresh path (a failure)
    // is parked anyway.
    clearDrainingEntry(into: &state)
    guard state.thinkingRowID == nil else { return .none }
    state.isSending = false
    guard refresh, let sessionID = state.liveSessionID else { return runningChanged(false, state) }
    return .merge(
      runningChanged(false, state),
      refreshAfterSlashCommand(sessionID: sessionID, profile: state.scopedProfile)
    )
  }


  // MARK: - Draft submission (shared by composer submit and queue drain, #66)

  /// The ONE submit pipeline for a full draft (text + staged attachments): attachment
  /// upload → degenerate-slash guard → compress family → slash pipeline → plain
  /// `prompt.submit`, all with the #17 session-not-found heal. Called with
  /// `fromQueue: false` from `.composerSubmitted`'s idle path (byte-identical to the
  /// pre-#66 inline behavior) and with `fromQueue: true` by `drainQueueIfReady` for a
  /// queued entry — which must NOT touch the live composer (`state.composerText` /
  /// `state.attachments` belong to whatever the user is typing NOW), and which records
  /// the optimistic echo row in `drainingRowID` so a failed drain can take it back out.
  private func submitDraft(
    text: String, attachments: [ComposerAttachment], fromQueue: Bool,
    sessionID: String, state: inout State
  ) -> Effect<Action> {
    // With attachments we must upload bytes first (iOS shares no FS with the agent),
    // then submit — so the composer path keeps the composer/attachments until success and
    // only echoes the user row once the upload+submit lands (a failed upload mustn't lose
    // the input); a drained entry instead rides `drainingEntry` for the same guarantee.
    if !attachments.isEmpty {
      state.errorBanner = nil
      state.isSending = true
      if !fromQueue {
        for index in state.attachments.indices { state.attachments[index].uploadState = .uploading }
      }
      // Anchor the turn start so a hydrate while it runs resumes the elapsed timer.
      let anchor = setTurnAnchor(state)
      // An unpersisted branch's stored id has no DB row (#34) — a heal resuming it
      // would 4007 again, so heal by recreating from the client-held seed (the typed
      // prompt is replayed and the seeded context + parent link are rebuilt; the
      // reap only removed them server-side).
      let stored = state.attachLiveSessionID == nil ? state.storedSessionID : nil
      let seed = state.branchSeed
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
            branchSeed: seed, profile: profile, gateway: gateway, send: send
          )
          // Echo images as thumbnails in the bubble; non-image files (no thumbnail)
          // fall back to their names when there's no typed text.
          let images = attachments.filter { $0.kind == .image }.map(\.data)
          let nonImageNames = attachments.filter { $0.kind != .image }.map(\.filename)
          let display = text.isEmpty ? nonImageNames.joined(separator: ", ") : text
          await send(.attachmentsSubmitted(
            displayText: display, images: images, rowID: uuid(), fromQueue: fromQueue
          ))
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

    // Slash-command branch (#36): a typed command executes through the gateway's
    // dedicated slash pipeline (`slash.exec`), never as plain prompt text — but ONLY
    // when the text is COMMAND-SHAPED (`SlashSuggestionFilter.isCommandShaped`, the
    // desktop's `SLASH_COMMAND_RE`) and the catalog actually loaded (backward-compat
    // guard: an old agent without `commands.catalog`, or one whose catalog never
    // arrived, falls through to the plain path byte-identical to today). A bare
    // `hasPrefix("/")` would swallow prose — `/tmp/agent.log look at this`,
    // `/Users/me/notes.md summarize`, `// TODO fix this` — fail it twice and DESTROY
    // the text (the composer is cleared here and the echoed row is local-only). The
    // shape rule is shared with the suggestion panel so the two always agree.
    //
    // Degenerate "/" or "/ <payload>" parses to an EMPTY name. The server would only
    // answer "empty command" after a doomed round-trip, so fail locally — and crucially
    // WITHOUT clearing the composer or echoing a row, or the payload after the slash
    // would be lost forever (desktop restores the draft for exactly this case,
    // `use-prompt-actions/slash.ts`). The drain pre-checks this before popping an entry,
    // so `fromQueue` can't reach it with `drainingEntry` standing.
    if SlashSuggestionFilter.isCommandShaped(text), state.commandCatalog != nil,
       parseSlashCommand(text).name.isEmpty {
      state.errorBanner = "Command failed: empty command"
      return .none
    }
    // The compress family (`/compress` + alias `/compact`) routes to the DEDICATED
    // `session.compress` gateway RPC — NEVER the generic `slash.exec` pipeline (desktop
    // parity: `use-prompt-actions/slash.ts`). This detection is BY CANONICAL INTENT — a
    // hardcoded `compressCommandNames` set matched on the parsed first token — and runs
    // BEFORE (and independent of) the `resolvesCommand`/canonicalization gate below,
    // because an OLDER agent's `commands.catalog` mislabels the alias (its `canon`
    // self-maps `/compact → /compact` instead of `→ /compress`): the client-side
    // canonicalization is then a no-op and the raw `/compact` would fall through
    // `slash.exec` to the isolated slash-worker subprocess whose registry can't resolve
    // the alias → "Unknown command: /compact". `session.compress` (a first-class RPC
    // since 2026-04-03) sidesteps the worker entirely, so it works version-independently.
    // Gated on a loaded catalog like the slash branch (a nil-catalog / `commandsUnsupported`
    // old agent keeps today's byte-identical plain `prompt.submit` path). The RAW typed
    // `/compress`/`/compact` is echoed as the user row; a typed argument becomes the
    // compression `focus_topic`.
    if SlashSuggestionFilter.isCommandShaped(text), state.commandCatalog != nil,
       compressCommandNames.contains(parseSlashCommand(text).name.lowercased()) {
      let rowID = uuid()
      let wasAtBottomWindow = state.windowStart >= State.bottomWindowStart(count: state.transcript.count)
      state.transcript.append(ChatRow(id: rowID, kind: .message(role: .user, text: text, isComplete: true)))
      maintainWindowAfterStreaming(wasAtBottomWindow: wasAtBottomWindow, into: &state)
      if fromQueue { state.drainingRowID = rowID } else { state.composerText = "" }
      state.errorBanner = nil
      state.isSending = true
      state.slashExecInFlight = true
      // Thread storedSessionID/branchSeed/profile through the same #17 session-heal the
      // slash and prompt paths use (an unpersisted branch heals by recreating from its
      // client-held seed, not by resuming a row-less stored id).
      let stored = state.attachLiveSessionID == nil ? state.storedSessionID : nil
      let seed = state.branchSeed
      let profile = state.scopedProfile
      let focusTopic = parseSlashCommand(text).arg
      return .run { [gateway] send in
        await executeCompress(
          focusTopic: focusTopic, sessionID: sessionID, storedSessionID: stored,
          branchSeed: seed, profile: profile, gateway: gateway, send: send
        )
      }
    }
    // Take the slash pipeline ONLY when the command RESOLVES in the curated catalog (a
    // visible command/skill route or a known alias — `CommandCatalog.resolvesCommand`).
    // A manually-typed HIDDEN command (`/new`, `/quit`, `/branch`, `/yolo`, … — the
    // `mobileHiddenCommands` hide-list is applied at decode) or a genuinely-unknown one
    // would otherwise reach `slash.exec`, run in the isolated slash-worker subprocess,
    // and report FAKE success while this live session is untouched. Those fall through
    // to the plain `prompt.submit` path below — byte-identical to the old-agent /
    // nil-catalog backward-compat behavior (the LLM just sees the literal text). Skill
    // routes still resolve (they live in the catalog with `isSkill == true`), so they
    // exec. Staged attachments always take the plain path (they returned above). The
    // typed `/cmd` is echoed as a normal user row; no turn anchor is set (an exec is not
    // a turn — no `message.start` will follow, so a hydrate mid-exec must not resurrect a
    // phantom elapsed timer).
    if SlashSuggestionFilter.isCommandShaped(text),
       let catalog = state.commandCatalog,
       catalog.resolvesCommand(named: parseSlashCommand(text).name) {
      let rowID = uuid()
      let wasAtBottomWindow = state.windowStart >= State.bottomWindowStart(count: state.transcript.count)
      state.transcript.append(ChatRow(id: rowID, kind: .message(role: .user, text: text, isComplete: true)))
      maintainWindowAfterStreaming(wasAtBottomWindow: wasAtBottomWindow, into: &state)
      if fromQueue { state.drainingRowID = rowID } else { state.composerText = "" }
      state.errorBanner = nil
      state.isSending = true
      state.slashExecInFlight = true
      // An unpersisted branch's stored id has no DB row (#34) — a heal resuming it
      // would 4007 again, so heal by recreating from the client-held seed (context +
      // parent link rebuilt) exactly like the plain-prompt / attachments paths do.
      let stored = state.attachLiveSessionID == nil ? state.storedSessionID : nil
      let seed = state.branchSeed
      let profile = state.scopedProfile
      // Resolve a typed ALIAS to its canonical name for the WIRE command only (#36
      // follow-up): the gateway's live handler recognizes only canonical names, so a
      // raw alias (`/compact`) would fall through to the isolated slash-worker and
      // report "Unknown command". The echoed user row above keeps the RAW typed text.
      let wireCommand = catalog.canonicalizedCommandText(text)
      return .run { [gateway] send in
        await executeSlashCommand(
          command: wireCommand, sessionID: sessionID, storedSessionID: stored,
          branchSeed: seed, profile: profile, gateway: gateway, send: send
        )
      }
    }

    let rowID = uuid()
    let wasAtBottomWindow = state.windowStart >= State.bottomWindowStart(count: state.transcript.count)
    state.transcript.append(ChatRow(id: rowID, kind: .message(role: .user, text: text, isComplete: true)))
    maintainWindowAfterStreaming(wasAtBottomWindow: wasAtBottomWindow, into: &state)
    if fromQueue { state.drainingRowID = rowID } else { state.composerText = "" }
    state.errorBanner = nil
    state.isSending = true
    // Anchor the turn start so a hydrate while it runs resumes the elapsed timer.
    let anchor = setTurnAnchor(state)
    // prompt.submit acks fast (`{status:"streaming"}`); the turn streams via events,
    // so success does nothing here — only a thrown error (timeout / server / drop)
    // surfaces. Don't swallow it (Issue #6: a stuck server left the spinner hung). A stale
    // live id after background→foreground answers "session not found" — self-heal once by
    // re-resuming for a fresh id and replaying the submit (#17). An unpersisted branch's
    // stored id has no DB row (#34) — its heal recreates from the client-held seed
    // (context + parent link rebuilt) instead of resuming.
    let stored = state.attachLiveSessionID == nil ? state.storedSessionID : nil
    let seed = state.branchSeed
    let profile = state.scopedProfile
    return .merge(anchor, .run { [gateway] send in
      await submitPrompt(
        sessionID: sessionID, storedSessionID: stored, branchSeed: seed,
        profile: profile, gateway: gateway, send: send
      ) { healedID in
        _ = try await gateway.send("prompt.submit", .object([
          "session_id": .string(healedID), "text": .string(text),
        ]))
      }
    })
  }

  // MARK: - Queue drain (#66)

  /// Attempt to fire the queue's head as the next turn. Called at every idle edge —
  /// `message.complete`, a `running == false` hydrate (`applyActivate`, which also covers
  /// `.gatewayClosed` finalization + reconnect and the post-slash refresh), and Send-now's
  /// deterministic re-check — with every precondition re-checked HERE so callers can
  /// attempt freely. Head-only, one turn per entry: the next entry waits for this turn's
  /// own completion. A parked queue drains only when Send-now armed the one-shot override.
  private func drainQueueIfReady(into state: inout State) -> Effect<Action> {
    guard !state.queuedPrompts.isEmpty,
          state.drainingEntry == nil,
          !state.isSending, !state.slashExecInFlight,
          state.pendingInteraction == nil,
          !state.isBranching,
          state.status == .ready,
          let sessionID = state.liveSessionID
    else { return .none }
    guard !state.isQueueParked || state.sendNowArmed else { return .none }
    state.sendNowArmed = false
    state.isQueueParked = false
    var entry = state.queuedPrompts.removeFirst()
    // Enqueue already trims; re-trim so a panel-edited entry can't drift from submit's rule.
    entry.text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Degenerate "/" or "/ <payload>" (the catalog can load AFTER enqueue, so the enqueue
    // check alone can't cover this): park it back with the same local error the composer
    // path shows, rather than burning a doomed round-trip or silently losing the payload.
    if entry.attachments.isEmpty, SlashSuggestionFilter.isCommandShaped(entry.text),
       state.commandCatalog != nil, parseSlashCommand(entry.text).name.isEmpty {
      state.queuedPrompts.insert(entry, at: 0)
      state.isQueueParked = true
      state.errorBanner = "Command failed: empty command"
      return .none
    }
    state.drainingEntry = entry
    return submitDraft(
      text: entry.text, attachments: entry.attachments, fromQueue: true,
      sessionID: sessionID, state: &state
    )
  }

  /// A drained entry's submit failed before demonstrably reaching the server (submit RPC
  /// error, upload failure, unsupported-attachments abort, slash failure — including an
  /// old agent's stray 4009 in the completion race): put it back at the HEAD, parked, and
  /// remove its optimistic echo row — a queued message is never silently lost, and its
  /// text must not show twice (bubble + panel).
  private func reparkDrainingEntry(into state: inout State) {
    guard let entry = state.drainingEntry else { return }
    state.drainingEntry = nil
    state.queuedPrompts.insert(entry, at: 0)
    state.isQueueParked = true
    if let rowID = state.drainingRowID {
      state.transcript.remove(id: rowID)
    }
    state.drainingRowID = nil
  }

  /// The drained entry's submit demonstrably reached the server (`message.start`, a turn
  /// terminal, `.attachmentsSubmitted`, or the slash exec's own terminal) — the entry is
  /// consumed and its echo row is now the turn's real user row.
  private func clearDrainingEntry(into state: inout State) {
    state.drainingEntry = nil
    state.drainingRowID = nil
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
    case let .reviewSummary(text):
      // Blank text is dropped by the fold with zero state change — don't schedule a
      // pointless snapshot write for it.
      return Self.hasRenderableReviewText(text)
    case .ready, .error, .authExpired, .approvalRequest, .clarifyRequest,
         .sudoRequest, .secretRequest, .unknown:
      return false
    }
  }

  /// Whether a `review.summary` payload has visible content. Whitespace-only text would
  /// render a blank status row, so the fold (drop the row) and `persistRelevant` (skip the
  /// snapshot write for a no-op fold) share this one check and can't drift.
  private static func hasRenderableReviewText(_ text: String) -> Bool {
    text.trimmedNonEmpty != nil
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
  /// the server and base64 blobs would bloat the cache. An `isUnpromptedNewChat` is skipped
  /// too: its key comes from a `session.create` handshake the server has no DB row for until
  /// the first prompt, so the row would be an empty cache entry for a session the list can
  /// never show and nothing prunes.
  private func persistSnapshotNow(_ state: State) -> Effect<Action> {
    guard let sessionID = state.sessionKey, !state.isUnpromptedNewChat else { return .none }
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
    state.sessionKey
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

  /// Drop the previous `config.set` rejection when a new pick is made, so a successful retry
  /// isn't read under a stale failure (nothing else clears it: success has no action and
  /// `session.info` leaves the banner alone).
  /// Drop the rollback target for every key this authoritative `SessionInfo` carries: the chip
  /// now holds the server's own value, so the next pick captures it fresh instead of an older
  /// one. Keys the info omits keep their entry — an absent field preserves, it doesn't confirm.
  private func confirmConfigKeys(_ info: SessionInfo, into state: inout State) {
    if info.model?.nonEmpty != nil { state.pendingConfigRollback.removeValue(forKey: "model") }
    if info.reasoningEffort?.nonEmpty != nil {
      state.pendingConfigRollback.removeValue(forKey: "reasoning")
    }
  }

  private func clearConfigError(_ state: inout State) {
    state.errorBanner = nil
    state.modelPicker?.applyError = nil
  }

  /// Change a session setting (model / reasoning) over the gateway. If iOS resumed with a
  /// reaped live id, refresh it and replay once rather than letting the optimistic picker value
  /// snap back when the next authoritative `session.info` arrives. A failure that survives that
  /// single replay is surfaced as `.configSetFailed` (rollback + banner, and the 4002 latch for
  /// `reasoning`) — never swallowed.
  private func configSet(
    key: String, value: String, previousValue: String?, sessionID: String,
    storedSessionID: String?, branchSeed: State.BranchSeed?, profile: String?
  ) -> Effect<Action> {
    .run { [gateway] send in
      func setConfig(_ targetID: String) async throws {
        _ = try await gateway.send("config.set", .object([
          "session_id": .string(targetID),
          "key": .string(key),
          "value": .string(value),
        ]))
      }
      do {
        _ = try await withSessionHeal(
          setConfig, sessionID: sessionID, storedSessionID: storedSessionID,
          branchSeed: branchSeed, profile: profile, gateway: gateway, send: send
        )
      } catch let error as GatewayError {
        await send(.configSetFailed(key: key, value: value, previousValue: previousValue, error: error))
      } catch {
        await send(.configSetFailed(
          key: key, value: value, previousValue: previousValue, error: .disconnected
        ))
      }
    }
    .cancellable(id: CancelID.configSet(key), cancelInFlight: true)
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
  branchSeed: ChatFeature.State.BranchSeed? = nil,
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
  // No stored id to resume against — recreate a fresh session so the heal still has a
  // target. An unpersisted branch (#34) whose live session was orphan-reaped recreates
  // WITH its client-held seed + parent link, so the replayed prompt lands in a session
  // that still contains the on-screen seeded context and still nests under its parent.
  var fields: [String: JSONValue] = branchSeed.map(branchSeedFields) ?? [:]
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

/// The branch `session.create` extras (#34): the single-assistant-message seed + the
/// parent link. Shared by the first branch create, the orphan-reap replay, and the
/// submit-heal recreate so all three rebuild an identical session.
private func branchSeedFields(_ seed: ChatFeature.State.BranchSeed) -> [String: JSONValue] {
  [
    "messages": .array([.object([
      "role": .string("assistant"), "content": .string(seed.text),
    ])]),
    "parent_session_id": .string(seed.parentSessionID),
  ]
}

/// One `session.create` round-trip shared by the fresh-chat and branch (#34) effects:
/// `fields` carries the per-call extras (empty for a plain create; seed `messages` +
/// `parent_session_id` for a branch), the default/nil profile is omitted (byte-identical
/// to the single-profile request), and the result decodes to a `SessionHandle` — a
/// malformed shape or a non-`GatewayError` throw maps to the same failures each caller
/// previously produced inline.
private func createSessionRPC(
  fields: [String: JSONValue],
  profile: String?,
  gateway: HermesGatewayClient
) async -> Result<SessionHandle, GatewayError> {
  var fields = fields
  if let profile { fields["profile"] = .string(profile) }
  do {
    let result = try await gateway.send("session.create", .object(fields))
    guard let handle = result.decoded(SessionHandle.self) else {
      return .failure(.server("Malformed session.create result"))
    }
    return .success(handle)
  } catch let error as GatewayError {
    return .failure(error)
  } catch {
    return .failure(.disconnected)
  }
}

/// Run an outbound RPC with transparent self-heal on "session not found" (#17): run `op`
/// against the current live id; if it throws `isSessionNotFound`, re-resume/recreate for a
/// fresh id (applying it via `.liveSessionIDRefreshed`) and replay `op(healedID)` ONCE. A
/// single retry — never recurses. Returns `op`'s value (discardable for fire-and-forget
/// RPCs). This is the SHARED inner mechanism; callers keep their own OUTER catch to map a
/// failure (heal, retry, or any other error) to the right per-call action
/// (`.promptSubmitFailed` / `.attachmentUploadFailed` / `.renameFailed` /
/// `.slashCommandFailed`).
@discardableResult
private func withSessionHeal<T>(
  _ op: (_ targetID: String) async throws -> T,
  sessionID: String,
  storedSessionID: String?,
  branchSeed: ChatFeature.State.BranchSeed? = nil,
  profile: String?,
  gateway: HermesGatewayClient,
  send: Send<ChatFeature.Action>
) async throws -> T {
  do {
    return try await op(sessionID)
  } catch let error as GatewayError where error.isSessionNotFound {
    let healedID = try await healLiveSessionID(
      storedSessionID: storedSessionID, branchSeed: branchSeed, profile: profile,
      gateway: gateway, send: send
    )
    return try await op(healedID)
  }
}

/// Split a typed slash command into its `name` (leading slashes stripped, first token)
/// and trimmed argument remainder — the web reference's `parseSlash`
/// (`web/src/lib/slashExec.ts`). Splits on ANY whitespace (tab/newline too — the server
/// and desktop both `split(maxsplit=1)`, so multiline args like `/goal <pasted text>`
/// must parse). Pure; internal for direct unit tests.
func parseSlashCommand(_ command: String) -> (name: String, arg: String) {
  let stripped = command.drop(while: { $0 == "/" })
  guard let space = stripped.firstIndex(where: \.isWhitespace) else {
    return (String(stripped), "")
  }
  let name = String(stripped[..<space])
  let arg = String(stripped[stripped.index(after: space)...])
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return (name, arg)
}

/// Commands `slash.exec` routes to `command.dispatch` **itself**, server-side — a verbatim
/// mirror of the gateway's `_PENDING_INPUT_COMMANDS` (`tui_gateway/server.py`). The CLI
/// queues these onto `_pending_input`, which the slash-worker subprocess has no reader for,
/// so the gateway dispatches them inline and returns the directive as the `slash.exec`
/// result.
///
/// An ERROR for one of these is therefore an error from a dispatch that ALREADY RAN, so the
/// client's `command.dispatch` fallback must be skipped: re-issuing it would re-enter the
/// same handler a second time. Mostly benign (handlers guard-then-act) but not universally —
/// a `/retry` that reached its truncate-and-resend path has already mutated history and would
/// run twice. Same double-execution class as the transport-failure guard.
///
/// `compress`/`compact` are deliberately ABSENT: they no longer reach `executeSlashCommand`
/// at all (routed to the dedicated `session.compress` RPC before the slash branch), so
/// listing them here would be dead + misleading.
private let serverRoutedSlashCommands: Set<String> = [
  "retry", "queue", "q", "steer", "plan", "goal", "moa", "undo", "learn",
]

/// The compress family — the parsed first token (lowercased) that routes to the dedicated
/// `session.compress` gateway RPC rather than the generic `slash.exec` pipeline. HARDCODED
/// on purpose: it must NOT depend on the server `commands.catalog`, because an older agent's
/// catalog mislabels the `/compact` alias (its `canon` self-maps `/compact → /compact`), so a
/// catalog-derived resolution would send `/compact` back down the broken slash-worker path.
private let compressCommandNames: Set<String> = ["compress", "compact"]

/// The typed `command.dispatch` directive `type`s the client acts on — the SINGLE source of
/// truth for both `isDispatchDirective` (the gate) and `runDispatchDirective`'s switch (the
/// behavior). Adding a directive type means adding it here AND a switch case; anything not
/// listed here is treated as a plain `{output, warning}` exec result (never a directive).
private let dispatchDirectiveTypes: Set<String> = ["exec", "plugin", "alias", "skill", "send", "prefill"]

/// True when a slash-pipeline result carries a typed `command.dispatch` directive. A
/// SUCCESSFUL `slash.exec` can answer one too — the server routes `_PENDING_INPUT_COMMANDS`
/// (`/retry`, `/queue`, `/steer`, `/goal`, `/moa`, `/undo`, `/learn`, …) and skill-bundle
/// commands through `command.dispatch` internally and returns the directive as the
/// `slash.exec` result (`tui_gateway/server.py`), so the success path must check for a
/// directive FIRST (desktop parity: `slash.ts` runs `parseCommandDispatch` on the exec
/// result before falling back to the `{output, warning}` shape).
private func isDispatchDirective(_ result: JSONValue) -> Bool {
  guard let type = result["type"]?.stringValue else { return false }
  return dispatchDirectiveTypes.contains(type)
}

/// Act on a typed `command.dispatch` directive (from either surface — a directive-shaped
/// `slash.exec` success or the explicit fallback), decoded LENIENTLY: a malformed/unknown
/// directive is an error surface, never a crash. Fully self-handling (every branch ends in
/// a sent action or a delegated pipeline re-entry) so neither call site can accidentally
/// fall through to a second execution.
private func runDispatchDirective(
  _ directive: JSONValue,
  name: String,
  arg: String,
  sessionID: String,
  storedSessionID: String?,
  branchSeed: ChatFeature.State.BranchSeed? = nil,
  profile: String?,
  gateway: HermesGatewayClient,
  send: Send<ChatFeature.Action>,
  allowAliasHop: Bool
) async {
  // The cases here MUST cover `dispatchDirectiveTypes` (the gate); the `default` is only
  // reached for a malformed/unexpected directive (e.g. a `command.dispatch` fallback answer
  // with no recognized `type`).
  switch directive["type"]?.stringValue {
  case "exec", "plugin":
    await send(.slashCommandOutput(directive["output"]?.stringValue?.nonEmpty ?? "(no output)"))

  case "alias":
    guard let target = directive["target"]?.stringValue?.nonEmpty else {
      await send(.slashCommandFailed(message: "invalid response: command.dispatch"))
      return
    }
    guard allowAliasHop else {
      // Single hop only — a registry misconfigured with alias → alias must fail,
      // never loop.
      await send(.slashCommandFailed(message: "/\(name): alias resolved to another alias (/\(target))"))
      return
    }
    await executeSlashCommand(
      command: "/\(target)\(arg.isEmpty ? "" : " \(arg)")",
      sessionID: sessionID, storedSessionID: storedSessionID,
      branchSeed: branchSeed, profile: profile, gateway: gateway, send: send,
      allowAliasHop: false
    )

  case "prefill":
    // `/undo`: the server already rewound history and hands back the undone message for
    // editing (never auto-resubmitted — desktop parity). The `notice` ("↶ Undid …") is
    // the only user-visible confirmation, so it rides the action too.
    guard let message = directive["message"]?.stringValue else {
      await send(.slashCommandFailed(message: "invalid response: command.dispatch"))
      return
    }
    await send(.slashCommandPrefill(
      message: message,
      notice: directive["notice"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    ))

  case "skill", "send":
    let isSkill = directive["type"]?.stringValue == "skill"
    // A `send` directive's `notice` (e.g. "⊙ Goal set …" from `/goal`/`/moa`) is the
    // backend's only feedback for the state change — render it BEFORE submitting
    // (desktop parity), as a row-append only (the submit owns the turn lifecycle).
    if let notice = directive["notice"]?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
      await send(.slashCommandNotice(notice))
    }
    guard
      let message = directive["message"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    else {
      await send(.slashCommandFailed(
        message: "/\(name): \(isSkill ? "skill payload missing message" : "empty message")"))
      return
    }
    // The directive's message goes through the NORMAL prompt flow, suppressing the
    // duplicate optimistic user row (the typed `/cmd` is already in the transcript).
    // Success only hands the turn off: the ack is `{status:"streaming"}` and the turn
    // streams via events, so `isSending` (already true) follows the standard turn
    // lifecycle and `message.start` writes the turn anchor. `.slashCommandHandedOff`
    // releases the mid-exec hydrate guard without touching the lock.
    do {
      try await withSessionHeal(
        { targetID in
          _ = try await gateway.send("prompt.submit", .object([
            "session_id": .string(targetID), "text": .string(message),
          ]))
        },
        sessionID: sessionID, storedSessionID: storedSessionID,
        branchSeed: branchSeed, profile: profile, gateway: gateway, send: send
      )
      await send(.slashCommandHandedOff)
    } catch let error as GatewayError {
      await send(.slashCommandFailed(message: error.message))
    } catch {
      await send(.slashCommandFailed(message: GatewayError.disconnected.message))
    }

  default:
    await send(.slashCommandFailed(message: "invalid response: command.dispatch"))
  }
}

/// Run a submitted slash command through the gateway's dedicated slash pipeline (#36),
/// mirroring the desktop reference client (`apps/desktop/…/use-prompt-actions/slash.ts`):
///
/// 1. `slash.exec {command (no leading slash), session_id}` covers every registry-backed
///    command. A success is EITHER a typed directive (`_PENDING_INPUT_COMMANDS` and
///    skill bundles — the server routes them through `command.dispatch` internally and
///    returns its directive as the exec result) → `runDispatchDirective`, OR the plain
///    `{output, warning?}` shape → an ephemeral `commandOutput` row (empty output
///    degrades to "/name: no output", a warning is prefixed).
/// 2. On a genuine `slash.exec` rejection fall back to `command.dispatch
///    {name, arg, session_id}` and run its typed directive: `exec`/`plugin` → output row;
///    `alias` → re-enter the pipeline ONCE with the target (single hop — a second alias
///    directive fails to the error path; deliberate divergence from the web reference's
///    unbounded recursion); `prefill` → composer prefill + notice (`/undo`);
///    `skill`/`send` → notice row (when present) then the directive's message through the
///    normal `prompt.submit` with the duplicate optimistic user row suppressed. Two
///    exec failures do NOT fall back: a `-32601` (an agent without `slash.exec` has no
///    `command.dispatch` either — same pipeline, the fallback would only add a second
///    unknown-method roundtrip), a TRANSPORT-shaped failure (timeout/drop — the exec
///    may still be running server-side, `slash.exec` is documented slow, so re-running it
///    via dispatch could execute the command TWICE, e.g. `/retry`'s truncate-and-resend),
///    and any `serverRoutedSlashCommands` name (the server already dispatched it itself).
/// 3. Any remaining failure surfaces `.slashCommandFailed` — never a swallowed `try?`. When
///    BOTH the exec and the fallback fail, the ORIGINAL `slash.exec` error is preferred if
///    the fallback only reported the routing-noise "not a quick/…/skill command" error (a
///    worker timeout/crash must not be buried under it — desktop parity, `slash.ts`).
///
/// Every RPC rides the standard session-not-found self-heal (#17): a stale live id
/// re-resumes once and replays.
private func executeSlashCommand(
  command: String,
  sessionID: String,
  storedSessionID: String?,
  branchSeed: ChatFeature.State.BranchSeed? = nil,
  profile: String?,
  gateway: HermesGatewayClient,
  send: Send<ChatFeature.Action>,
  allowAliasHop: Bool = true
) async {
  let (name, arg) = parseSlashCommand(command)

  // Defense in depth: `composerSubmitted` already rejects a degenerate "/" / "/ text"
  // before clearing the composer (so the payload isn't lost), and an alias hop always
  // re-enters with a non-empty target — but never let an empty name reach the wire.
  guard !name.isEmpty else {
    await send(.slashCommandFailed(message: "empty command"))
    return
  }

  // The genuine `slash.exec` rejection, kept so the `command.dispatch` fallback can prefer
  // it over the fallback's own routing-noise error (see below).
  var slashExecError: GatewayError?

  // 1. Primary dispatcher: slash.exec.
  do {
    let result = try await withSessionHeal(
      { targetID in
        try await gateway.send("slash.exec", .object([
          "command": .string(String(command.drop(while: { $0 == "/" }))),
          "session_id": .string(targetID),
        ]))
      },
      sessionID: sessionID, storedSessionID: storedSessionID,
      branchSeed: branchSeed, profile: profile, gateway: gateway, send: send
    )
    // Directive-shaped success FIRST (desktop parity): `/retry`, `/queue`, `/goal`,
    // `/undo`, bundle skills, … answer their `command.dispatch` directive as the exec
    // result — dropping it here would silently discard the command's entire outcome.
    if isDispatchDirective(result) {
      await runDispatchDirective(
        result, name: name, arg: arg,
        sessionID: sessionID, storedSessionID: storedSessionID,
        branchSeed: branchSeed, profile: profile, gateway: gateway, send: send,
        allowAliasHop: allowAliasHop
      )
    } else {
      let body = result["output"]?.stringValue?.nonEmpty ?? "/\(name): no output"
      let text = result["warning"]?.stringValue?.nonEmpty.map { "warning: \($0)\n\(body)" } ?? body
      await send(.slashCommandOutput(text))
    }
    return
  } catch let error as GatewayError where error.isUnknownMethod {
    // The agent predates the slash pipeline entirely (shouldn't happen once the catalog
    // loaded, but stay defensive) — `command.dispatch` shipped alongside `slash.exec`,
    // so the fallback would only add a second `-32601` roundtrip.
    await send(.slashCommandFailed(message: error.message))
    return
  } catch let error as GatewayError where error.isTimedOut || error.isDisconnected {
    // Transport-shaped failure: the exec may STILL be running server-side (`slash.exec` is
    // documented as blocking its dispatcher "for seconds to minutes"; the client budgets it
    // 120s via `HermesGatewayClient.longRunningMethods`). Falling back to
    // `command.dispatch` would run the command a SECOND time (`/retry` would truncate
    // and resend twice) — fail directly instead.
    await send(.slashCommandFailed(message: error.message))
    return
  } catch let error as GatewayError where serverRoutedSlashCommands.contains(name.lowercased()) {
    // The server already ran `command.dispatch` for this name internally
    // (`_PENDING_INPUT_COMMANDS`) — this error came FROM that dispatch, so our own fallback
    // would only re-enter the same handler. Fail directly.
    await send(.slashCommandFailed(message: error.message))
    return
  } catch let error as GatewayError {
    // Genuine server rejection (unknown to the registry, needs client dispatch) — fall
    // through to the command.dispatch fallback, but KEEP this error: a `slash.exec` worker
    // timeout/crash is the real failure, not the fallback's "not a quick/…/skill command"
    // routing noise (desktop parity: `slash.ts` preserves `slashExecError`).
    slashExecError = error
  } catch {
    // Non-gateway error — nothing informative to preserve; still attempt the fallback.
  }

  // 2. Fallback: command.dispatch answers the typed directive.
  do {
    let directive = try await withSessionHeal(
      { targetID in
        try await gateway.send("command.dispatch", .object([
          "name": .string(name),
          "arg": .string(arg),
          "session_id": .string(targetID),
        ]))
      },
      sessionID: sessionID, storedSessionID: storedSessionID,
      branchSeed: branchSeed, profile: profile, gateway: gateway, send: send
    )
    await runDispatchDirective(
      directive, name: name, arg: arg,
      sessionID: sessionID, storedSessionID: storedSessionID,
      branchSeed: branchSeed, profile: profile, gateway: gateway, send: send,
      allowAliasHop: allowAliasHop
    )
  } catch let error as GatewayError {
    // If the fallback ONLY reports the routing-noise "not a quick/plugin/bundle/skill
    // command" error (`tui_gateway/server.py`, code 4018), the real failure is the original
    // `slash.exec` error (worker timeout/crash) — surface that instead of burying it under
    // the noise (desktop parity: `slash.ts` ~270-278). Otherwise the dispatch error is the
    // informative one.
    if let original = slashExecError,
       error.message.range(of: "not a quick", options: .caseInsensitive) != nil {
      await send(.slashCommandFailed(message: original.message))
    } else {
      await send(.slashCommandFailed(message: error.message))
    }
  } catch {
    await send(.slashCommandFailed(message: GatewayError.disconnected.message))
  }
}

/// Run `/compress` / `/compact` through the DEDICATED `session.compress` gateway RPC — the
/// desktop's version-independent path (`use-prompt-actions/slash.ts`), sidestepping the
/// `slash.exec` slash-worker subprocess whose registry can't resolve the `compact` alias on
/// older agents ("Unknown command: /compact"). A typed argument threads through as the
/// compression `focus_topic` (the server reads `focus_topic`; omitted when empty for a
/// byte-minimal request). The RPC rides the standard #17 session-not-found self-heal, exactly
/// like the slash / prompt paths.
///
/// Terminal handling reuses the SLASH pipeline's own actions so the composer-lock,
/// `runningChanged`, cross-client `thinkingRowID` guard, and post-command server-authoritative
/// refresh (`session.resume` → context-usage pill + rewritten transcript) all behave
/// identically: success → `.slashCommandOutput(confirmation)` (`finishSlashExec(refresh:true)`),
/// failure → `.slashCommandFailed` (`finishSlashExec(refresh:false)`). Never a swallowed `try?`.
private func executeCompress(
  focusTopic: String,
  sessionID: String,
  storedSessionID: String?,
  branchSeed: ChatFeature.State.BranchSeed? = nil,
  profile: String?,
  gateway: HermesGatewayClient,
  send: Send<ChatFeature.Action>
) async {
  do {
    let result = try await withSessionHeal(
      { targetID in
        var fields: [String: JSONValue] = ["session_id": .string(targetID)]
        let topic = focusTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { fields["focus_topic"] = .string(topic) }
        return try await gateway.send("session.compress", .object(fields))
      },
      sessionID: sessionID, storedSessionID: storedSessionID,
      branchSeed: branchSeed, profile: profile, gateway: gateway, send: send
    )
    await send(.slashCommandOutput(compressConfirmation(from: result)))
  } catch let error as GatewayError {
    await send(.slashCommandFailed(message: error.message))
  } catch {
    await send(.slashCommandFailed(message: GatewayError.disconnected.message))
  }
}

/// Build the transcript confirmation for a `session.compress` response, preferring the
/// server's own display text and degrading to a synthesized line so the user always gets an
/// honest acknowledgement (the response shape varies: a rich `summary`, a lock-held
/// `message`, a compute-host `host_ack.output`, a bare `removed` count, or nothing). ANSI is
/// stripped downstream by `appendCommandOutput`.
private func compressConfirmation(from result: JSONValue) -> String {
  // The rich summary (headline + token line + note) — the most informative, when present.
  if let headline = result["summary"]?["headline"]?.stringValue?.nonEmpty {
    let lines = [headline, result["summary"]?["token_line"]?.stringValue, result["summary"]?["note"]?.stringValue]
      .compactMap { $0?.nonEmpty }
    return lines.joined(separator: "\n")
  }
  // Lock-held (another compression already running) carries a human-readable `message`.
  if let message = result["message"]?.stringValue?.nonEmpty { return message }
  // Compute-host isolated sessions return their acknowledgement text under `host_ack`.
  if let hostOutput = result["host_ack"]?["output"]?.stringValue?
    .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
    return hostOutput
  }
  // A plain compressed count, then the honest catch-all confirmation.
  if let removed = result["removed"]?.intValue, removed > 0 {
    return "Compressed \(removed) message\(removed == 1 ? "" : "s")."
  }
  return "Context compressed."
}

/// Run a `prompt.submit` with transparent self-heal on "session not found" (#17): replay the
/// submit ONCE against a freshly re-resumed/recreated id; on any other failure (or a failed
/// heal/retry) surface `.promptSubmitFailed`.
private func submitPrompt(
  sessionID: String,
  storedSessionID: String?,
  branchSeed: ChatFeature.State.BranchSeed? = nil,
  profile: String?,
  gateway: HermesGatewayClient,
  send: Send<ChatFeature.Action>,
  submit: @escaping (_ targetID: String) async throws -> Void
) async {
  do {
    try await withSessionHeal(
      submit, sessionID: sessionID, storedSessionID: storedSessionID,
      branchSeed: branchSeed, profile: profile, gateway: gateway, send: send
    )
  } catch let error as GatewayError {
    await send(.promptSubmitFailed(message: error.message))
  } catch {
    await send(.promptSubmitFailed(message: GatewayError.disconnected.message))
  }
}

/// Stage what a picker returned: one `attachmentAdded` per loaded file, plus one
/// `attachmentsDropped` when the user's selection was **lost** rather than never made.
///
/// Shared by all three pickers so none of them can quietly go back to swallowing a failed
/// pick: the sheet dismisses either way, so a drop that says nothing is indistinguishable
/// from a cancel. A cancel carries no drops and therefore stays silent.
private func stagePicked(
  _ batch: PickedBatch,
  uuid: UUIDGenerator,
  send: Send<ChatFeature.Action>
) async {
  for item in batch.items { await send(.attachmentAdded(item.attachment(id: uuid()))) }
  if batch.droppedCount > 0 { await send(.attachmentsDropped(count: batch.droppedCount)) }
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
