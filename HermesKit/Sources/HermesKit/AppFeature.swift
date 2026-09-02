import ComposableArchitecture
import Foundation

/// Root feature: onboarding until connected, then a session list that pushes chat
/// screens. Wires the child features together via their delegate actions.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var onboarding: ConnectionFeature.State
    public var home: SessionListFeature.State?
    /// The navigation path holds only thin session-key markers (`ChatScreen.State`) — the
    /// real chat state lives in the `liveChat` slot below, so popping a marker never
    /// destroys the chat's state or effects by itself.
    public var path: StackState<ChatScreen.State>
    /// The app-owned "live chat slot": the one open (or detached-but-live) chat. Composed
    /// via `.ifLet`, so its socket, reconnect backoff, thinking ticker, and debounced
    /// persist are slot-rooted and survive navigation pops. One live session at a time —
    /// opening a different session replaces the slot.
    public var liveChat: ChatFeature.State?
    /// Identity of the current live-chat slot. Incremented whenever a slot is cleared so a
    /// delayed destination `onDisappear` from the outgoing slot cannot clean up its replacement.
    var liveChatGeneration: UInt = 0
    /// True during the launch auto-connect probe — `AppView` shows a brief placeholder
    /// instead of flashing the onboarding screen.
    public var autoConnecting: Bool
    /// The "can't reach the server" screen, raised for **every** launch auto-connect failure
    /// that isn't a verdict on the stored credentials — transport (`.offline`/`.unreachable`)
    /// *and* a server that answered badly (500, 404, 429, 503, a captive portal's
    /// `.decoding`). Only `.unauthorized` / a 401-403 `.server` falls back to prefilled
    /// onboarding; the single rule lives in `ConnectionFailedFeature.isRetryable`, which this
    /// routing defers to. Stored credentials stay untouched — a password-mode user must never
    /// be made to re-type a password that never expired just because Tailscale was off or the
    /// agent threw a 500.
    public var connectionFailed: ConnectionFailedFeature.State?
    /// The re-auth modal, presented when a live (gated) session dies mid-use. While shown,
    /// the dead chat's reconnect stays paused (it pauses itself via `awaitingReauth`).
    @Presents public var reauth: ReauthFeature.State?
    /// Confirmation raised when a launch intent would replace a running chat or discard
    /// queued prompts. The single-slot architecture cannot open the new chat safely without
    /// an explicit choice (#93).
    @Presents public var launchIntentConflict: ConfirmationDialogState<Action.LaunchIntentDialog>?
    /// The intent awaiting the conflict confirmation above. Kept separate from the dialog's
    /// button action so the confirmation remains a simple, stable enum action.
    var pendingConflictingLaunchIntent: LaunchIntent?
    /// Session ids with a pending approval surfaced via a push tap, not yet viewed. The app-icon
    /// badge mirrors `pendingApprovalSessionIDs.count`; tapping/opening a session clears its
    /// entry (and recomputes the badge). A small dedicated count — distinct from the list's
    /// per-session *unread* (`seenCounts`) concept, which tracks message deltas, not approvals.
    public var pendingApprovalSessionIDs: Set<String>
    /// Whether the scene is currently backgrounded (set on `.background`, cleared on
    /// `.active`). Guards `.backgroundGraceExpired`: an expiry whose send escaped just as
    /// the user returned must not tear down the socket `.active` freshly redialed.
    var isSceneBackgrounded = false
    /// The launch auto-connect probe has been started once this process — a re-sent `.task`
    /// (a re-created `AppView`) must never restart it, which would flip the root back to the
    /// "Connecting…" spinner over the retry screen the user is standing on.
    var didRunLaunchProbe = false
    /// The process-lifetime push/App-Intent observers are installed once. Re-sending `.task`
    /// must not cancel and replace an observer in the narrow window where its bridge has
    /// accepted an event but TCA has not reduced the resulting action yet.
    var didStartExternalObservers = false
    /// A push tap that arrived before the session list existed (cold launch — #46): the
    /// routing in `.pushTapped` can't open anything without `home`, so the tap is stashed
    /// here (single stash, last-wins) and replayed once `.autoConnectSucceeded` / a manual
    /// login creates the list. Process-lifetime only (never persisted) — the race it
    /// covers is intra-launch — and cleared on logout (the stash dies with the identity).
    var pendingPushTap: PushTap?
    /// A launch intent (#93) that arrived before the session list existed (cold launch —
    /// the routing in `.launchIntentReceived` can't open anything without `home`): stashed
    /// here (single stash, last-wins) and replayed once `.autoConnectSucceeded` / a manual
    /// login creates the list. Process-lifetime only (never persisted) — cleared on logout,
    /// like `pendingPushTap` (the stash dies with the identity).
    var pendingLaunchIntent: LaunchIntent?
    /// The server the stashed tap belongs to: the persisted server URL at stash time (the
    /// agent whose push plugin this device registered with). Guards the replay — a login
    /// that targets a DIFFERENT server drops the stash instead of resuming a foreign
    /// session id there (the resume self-heal would silently create a spurious empty
    /// chat). `nil` when no URL was stored at stash time (fully logged out); the replay
    /// then proceeds unverified — the plan's logged-out → login → open flow, accepted
    /// because pushes only come from a server this device registered with.
    ///
    /// This is the best identity available CLIENT-SIDE, not proof of origin: the push
    /// payload carries no server identity (the generic-body privacy rule forbids adding
    /// one), so a push from a STALE registration on a previous server — logout's
    /// unregister is best-effort — is stamped with the CURRENT pref and replays here.
    /// Accepted corner: the worst outcome is the same spurious-empty-chat the self-heal
    /// produces for any unknown id, and logout's unregister keeps the window narrow.
    var pendingPushTapServerURL: URL?

    public init(
      onboarding: ConnectionFeature.State = .init(),
      home: SessionListFeature.State? = nil,
      path: StackState<ChatScreen.State> = .init(),
      liveChat: ChatFeature.State? = nil,
      autoConnecting: Bool = false,
      connectionFailed: ConnectionFailedFeature.State? = nil,
      reauth: ReauthFeature.State? = nil,
      pendingApprovalSessionIDs: Set<String> = []
    ) {
      self.onboarding = onboarding
      self.home = home
      self.path = path
      self.liveChat = liveChat
      self.autoConnecting = autoConnecting
      self.connectionFailed = connectionFailed
      self.reauth = reauth
      self.pendingApprovalSessionIDs = pendingApprovalSessionIDs
    }

    /// The session the user is currently viewing — the live chat's session key
    /// (`storedSessionID ?? liveSessionID`) while its marker is pushed, or `nil` when no
    /// chat is on screen (or a new chat whose id hasn't resolved yet). A detached slot
    /// (user on the list) reads `nil` so pushes for that session are NOT suppressed.
    /// Drives foreground push suppression via `.onChange`.
    var currentViewingSessionID: String? {
      guard !path.isEmpty else { return nil }
      return liveChat?.sessionKey
    }

    /// Which root branch the app shell renders. The precedence is **logic, not layout**, so it
    /// lives here rather than in `AppView`: the connection-failed screen (#62) is reachable
    /// purely by sitting between the `autoConnecting` spinner and the onboarding fallback, and
    /// reordering it would silently disable the whole feature with every other test still
    /// green. Keeping it in the package makes that ordering assertable by `swift test`
    /// instead of a simulator run.
    public var rootScreen: RootScreen {
      if home != nil { return .home }
      if autoConnecting { return .connecting }
      if connectionFailed != nil { return .connectionFailed }
      return .onboarding
    }
  }

  /// The root branches of the app shell, in the order `State.rootScreen` resolves them.
  public enum RootScreen: Equatable, Sendable {
    case home
    case connecting
    case connectionFailed
    case onboarding
  }

  /// App lifecycle phase, mirrored from SwiftUI's `ScenePhase` by the thin app shell so
  /// HermesKit never imports SwiftUI. The shell maps `.active/.inactive/.background` onto
  /// these cases and dispatches `scenePhaseChanged`.
  public enum ScenePhase: Equatable {
    case active
    case inactive
    case background
  }

  public enum Action {
    case task
    case autoConnectSucceeded(ServerConnection)
    /// The launch probe failed. The `RESTError` decides where we land, via the one rule in
    /// `ConnectionFailedFeature.isRetryable`: only a credentials verdict (`.unauthorized`, or
    /// a `.server` with status 401/403) falls back to onboarding for re-entry — **every**
    /// other failure (transport, 500, 404, 429, 503, `.decoding`) raises the retry screen with
    /// the session intact.
    case autoConnectFailed(ServerConnection, RESTError)
    /// The app's scene phase changed (foreground/background) — observed at the app shell and
    /// fanned out: `.active` reconnects + re-hydrates the open chat and refreshes the list;
    /// `.background`/`.inactive` flushes the open chat's snapshot + anchor immediately, and
    /// `.background` with a RUNNING turn additionally requests a finite background window
    /// (`BackgroundTaskClient`) so the socket keeps streaming ~30s past suspension.
    case scenePhaseChanged(ScenePhase)
    /// A push notification was tapped — deep-link to its session, routed by comparing the
    /// tapped id against the live slot + path (#32): already on screen → badge bookkeeping
    /// only; detached slot match → re-attach push; different session → replace the slot and
    /// SET the path (never stack). Approval taps clear their pending-badge entry on view.
    case pushTapped(PushTap)
    /// An App Intent launched the app from outside (Quick Actions / Shortcuts / Spotlight /
    /// Action button, #93) requesting a specific entry point. Routed only when `home`
    /// exists — otherwise stashed (`pendingLaunchIntent`) and replayed on login, mirroring
    /// the cold-launch push-tap stash (#46). Replaces any open chat (never stacks).
    case launchIntentReceived(LaunchIntent)
    /// Internal route after either no conflict was found or the user explicitly confirmed
    /// replacing the busy slot. Kept separate so confirmation cannot re-trigger itself.
    case launchIntentConfirmed(LaunchIntent)
    case launchIntentConflict(PresentationAction<LaunchIntentDialog>)
    case onboarding(ConnectionFeature.Action)
    /// The launch retry screen's actions (present only while the slot is filled).
    case connectionFailed(ConnectionFailedFeature.Action)
    case home(SessionListFeature.Action)
    case path(StackActionOf<ChatScreen>)
    /// The pushed chat view finished leaving the screen (sent by the destination in
    /// `AppView` — never through the child scope, so a nil slot can be guarded here
    /// instead of tripping the `ifLet` nil-child warning). Forwards the view-session
    /// cleanup (`.viewDisappeared`) and applies the pop-to-list teardown policy AFTER the
    /// pop animation — tearing down at `.popFrom` time would blank the outgoing screen
    /// mid-animation.
    case chatViewDisappeared(generation: UInt)
    /// The live chat slot's actions — the chat is composed here (via `.ifLet`), NOT in the
    /// navigation path, so its effects survive pops.
    case liveChat(ChatFeature.Action)
    /// Internal: fill the live-chat slot with a fresh chat and (re)set its path marker.
    /// Used when opening while the slot is occupied — sequenced after the old slot's
    /// `.teardown` AND `.clearLiveChat` (the nil-out is what cancels the outgoing chat's
    /// un-ID'd one-shot RPC effects) so nothing can leak into the replacement.
    case fillLiveChat(ChatFeature.State)
    /// Internal: clear the slot after its `.teardown` ran (`teardownSlot`). Nil-ing the
    /// slot makes `ifLet` cancel every remaining child effect — including one-shot RPCs
    /// that carry no cancel ID. Does not touch the path (a replacement resets it in the
    /// immediately-following `.fillLiveChat`).
    case clearLiveChat
    /// Internal: the finite background window (`BackgroundTaskClient`) expired while still
    /// backgrounded — final flush, then disconnect the socket cleanly
    /// (`.teardownSocketOnly`), keeping the chat state in memory for the #26-preserving
    /// foreground re-hydrate.
    case backgroundGraceExpired
    case reauth(PresentationAction<ReauthFeature.Action>)

    @CasePathable
    public enum LaunchIntentDialog: Equatable, Sendable {
      case replace
    }
  }

  /// Ids for the long-running incoming-tap observer and the background-grace listener.
  private enum CancelID { case pushTaps, launchIntents, backgroundGrace }

  /// Name of the finite background task requested while a running turn is backgrounded
  /// (shows up in OS background-task diagnostics). Tests re-type the literal on purpose —
  /// an accidental rename should fail the suite, not silently follow the constant.
  private static let backgroundGraceTaskName = "hermes.chat.background-grace"

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.hermesREST) var rest
  @Dependency(\.push) var push
  @Dependency(\.launchIntent) var launchIntent
  @Dependency(\.backgroundTask) var backgroundTask
  @Dependency(\.chatSnapshot) var chatSnapshot

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.onboarding, action: \.onboarding) {
      ConnectionFeature()
    }
    Reduce { state, action in
      reduceCore(into: &state, action: action)
    }
    .ifLet(\.connectionFailed, action: \.connectionFailed) {
      ConnectionFailedFeature()
    }
    .ifLet(\.home, action: \.home) {
      SessionListFeature()
    }
    .ifLet(\.$reauth, action: \.reauth) {
      ReauthFeature()
    }
    .ifLet(\.$launchIntentConflict, action: \.launchIntentConflict)
    .ifLet(\.liveChat, action: \.liveChat) {
      ChatFeature()
    }
    .forEach(\.path, action: \.path) {
      ChatScreen()
    }
    // Keep the push bridge's "currently viewing" session in sync with the slot + nav stack
    // (one source of truth, evaluated AFTER the child reducers so pops/dismissals AND a new chat
    // resolving its `liveSessionID` are reflected) so a foreground push for the on-screen session
    // is suppressed. Opening, popping back to the list, and id-resolution all flow through here.
    .onChange(of: \.currentViewingSessionID) { _, newValue in
      Reduce { _, _ in
        .run { [push] _ in push.setCurrentSession(newValue) }
      }
    }
  }

  /// Keep the reducer builder expression small enough for the iOS compiler. The app's
  /// action routing remains a regular synchronous reducer function; this is only a
  /// type-checking boundary, not a behavioral split.
  private func reduceCore(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .task:
      // Install the process-lifetime external observers exactly once. Re-sent `.task`
      // actions must not cancel/restart them: a bridge may have accepted an event into the
      // old stream just before cancellation, after which TCA could discard its pending send.
      let tapObserver: Effect<Action>
      let intentObserver: Effect<Action>
      if state.didStartExternalObservers {
        tapObserver = .none
        intentObserver = .none
      } else {
        state.didStartExternalObservers = true
        // Observe push taps for the whole app lifetime (a tap can arrive cold-launch or while
        // running) and deep-link them; the actual nav happens in `.pushTapped`.
        tapObserver = .run { [push] send in
          for await tap in push.incomingTaps() {
            await send(.pushTapped(tap))
          }
        }
        .cancellable(id: CancelID.pushTaps)
        // Observe App-Intent launches for the whole app lifetime (#93): Quick Actions /
        // Shortcuts / Spotlight / Action button feed `IntentBridge` from the app target;
        // the routing happens in `.launchIntentReceived`.
        intentObserver = .run { [launchIntent] send in
          for await intent in launchIntent.incomingIntents() {
            await send(.launchIntentReceived(intent))
          }
        }
        .cancellable(id: CancelID.launchIntents)
      }
      // Launch auto-connect: if a persisted session (token *or* gated cookie) + server
      // URL exist, silently validate and skip onboarding. Only runs once, before we have
      // a home. `loadSession` rehydrates a `.cookie` session's cookies into `.shared` so
      // the REST/WS transports authenticate on this fresh launch.
      // `!didRunLaunchProbe` is the real once-per-process gate (see the property): a
      // re-sent `.task` must never start a SECOND probe while the retry screen is up (it
      // would flip the UI back to the "Connecting…" spinner and, on success, build `home`
      // beside a still-populated slot). The other checks are cheap belt-and-braces.
      guard !state.didRunLaunchProbe, state.home == nil, state.connectionFailed == nil,
            !state.autoConnecting,
            let session = keychain.loadSession(.shared),
            let urlString = preferences.loadServerURL(),
            let url = parseServerURL(urlString)
      else { return .merge(tapObserver, intentObserver) }
      // A `.token` session with an empty token is treated as "no creds" (matches the old
      // `loadToken()`-non-empty guard) so we stay on onboarding rather than probe blindly.
      if case .token("") = session { return .merge(tapObserver, intentObserver) }
      state.didRunLaunchProbe = true
      state.autoConnecting = true
      let connection = ServerConnection(baseURL: url, auth: session)
      return .merge(
        tapObserver,
        intentObserver,
        .run { [rest] send in
          do {
            _ = try await rest.sessions(connection, 1, 0, .recent)
            await send(.autoConnectSucceeded(connection))
          } catch {
            await send(.autoConnectFailed(connection, asRESTError(error)))
          }
        }
      )

    case let .autoConnectSucceeded(connection):
      state.autoConnecting = false
      // Defensive: a retry screen and a live list must never coexist (see the `.task` guard).
      state.connectionFailed = nil
      state.home = makeHomeState(connection: connection)
      return replayPendingExternalRoute(&state)

    case let .autoConnectFailed(connection, error):
      state.autoConnecting = false
      guard ConnectionFailedFeature.isRetryable(error) else {
        // Stored creds didn't validate (expired token / dead cookies) — fall back to
        // onboarding for re-entry; retrying can't repair dead credentials.
        fallBackToOnboarding(&state, connection: connection)
        return .none
      }
      // Either we never reached the server, or a proxy told us the agent is down — the
      // stored session is presumed fine, so keep it and offer a Retry instead of dropping to
      // onboarding (which, in password mode, would demand a password that never expired just
      // because the VPN was off).
      state.connectionFailed = ConnectionFailedFeature.State(
        connection: connection, reason: error
      )
      return .none

    case let .connectionFailed(.delegate(.connected(connection))):
      // The retry validated the stored session — identical landing to a successful launch
      // auto-connect, cold-launch push-tap replay included.
      state.connectionFailed = nil
      state.home = makeHomeState(connection: connection)
      return replayPendingExternalRoute(&state)

    case let .connectionFailed(.delegate(.credentialsRejected(connection))):
      // The retry reached the server and it turned us away — retrying can't fix that, so
      // land exactly where a launch auth failure lands: prefilled onboarding, nothing
      // cleared, which is also where the connection-help sheet's entry points live.
      state.connectionFailed = nil
      fallBackToOnboarding(&state, connection: connection)
      return .none

    case .connectionFailed(.delegate(.logoutConfirmed)):
      // "Log Out" from the retry screen (confirmed): the user is abandoning the stored
      // session, so run the same logout as "Quit to start" (Keychain session + every pref)
      // and land on a *fresh* onboarding — nothing prefilled, there is no session left to
      // repair. The tap stash and the approval badge set die with the identity too.
      let connection = state.connectionFailed?.connection
      try? keychain.deleteSession()
      preferences.clearServerURL()
      preferences.clearIdentityScopedPrefs()
      preferences.saveGroupingMode(.default)
      preferences.saveDefaultSessionSwipeAction(.default)
      preferences.saveShowCronSection(true)
      state.connectionFailed = nil
      state.path = .init()
      state.liveChat = nil
      state.home = nil
      state.onboarding = .init()
      state.pendingPushTap = nil
      state.pendingPushTapServerURL = nil
      state.pendingLaunchIntent = nil
      state.pendingConflictingLaunchIntent = nil
      state.launchIntentConflict = nil
      state.pendingApprovalSessionIDs = []
      return .merge(setBadge(state), unregisterPushOnLogout(connection: connection))

    case let .scenePhaseChanged(phase):
      // Fan lifecycle out to the live chat slot (if any) and the session list — no
      // top-of-path hunting: the slot IS the one live chat, attached or not. We do NOT
      // auto-restore the nav stack on cold launch — opening a session is enough.
      switch phase {
      case .active:
        // Foreground: release the background-execution window (cancel the grace listener;
        // `end()` is idempotent — a no-op when none is active), then re-hydrate the live
        // chat via `.foreground` (which reconnects only if the socket died — a socket the
        // grace window kept alive is reused, not redialed) and refresh the list
        // immediately (don't wait for the poll).
        state.isSceneBackgrounded = false
        return .merge(
          .cancel(id: CancelID.backgroundGrace),
          .run { [backgroundTask] _ in await backgroundTask.end() },
          state.liveChat != nil ? .send(.liveChat(.foreground)) : .none,
          state.home != nil ? .send(.home(.pulledToRefresh)) : .none,
          // Stuck on the retry screen? Foregrounding is exactly the moment the user just
          // flipped the VPN back on — re-probe without making them tap. The child SUPERSEDES
          // whatever is in flight (`cancelInFlight` on its probe), so this can't fan out
          // into parallel probes; a stalled one is simply abandoned. Accepted trade-off:
          // `.active` also fires for Control Center / notification-pull / app-switcher
          // blips, so churn can restart the probe more often than the user asked. Gating on
          // "was really backgrounded" would break the main case — flipping airplane mode or
          // Wi-Fi from Control Center never backgrounds the app — and swallowing the
          // foreground is the latch bug this design exists to avoid. One GET per blip.
          state.connectionFailed != nil ? .send(.connectionFailed(.sceneBecameActive)) : .none
        )
      case .background:
        // Backgrounding: flush the live chat's snapshot + anchor IMMEDIATELY (don't rely on
        // the 1s debounce) so a process kill can't lose the latest paint or the timer anchor.
        state.isSceneBackgrounded = true
        guard let chat = state.liveChat else { return .none }
        let flush: Effect<Action> = .send(.liveChat(.persistNow))
        // A RUNNING turn buys itself a finite background window (~30s): the socket simply
        // keeps streaming, no `ChatFeature` changes. If iOS expires the window while still
        // backgrounded, the listener fires `.backgroundGraceExpired` → final flush + clean
        // socket-only disconnect (state stays in memory for the #26-preserving foreground
        // hydrate); catch-up is then the existing push + `.foreground` reconnect. An idle
        // chat starts NO task — nothing to keep alive, no battery burn.
        guard chat.isRunning else { return flush }
        return .merge(
          flush,
          .run { [backgroundTask] send in
            for await _ in await backgroundTask.begin(Self.backgroundGraceTaskName) {
              await send(.backgroundGraceExpired)
            }
          }
          .cancellable(id: CancelID.backgroundGrace, cancelInFlight: true)
        )
      case .inactive:
        // Transient occlusion (app switcher, notification shade): flush only — the process
        // isn't suspending yet, so no background window is needed.
        return state.liveChat != nil ? .send(.liveChat(.persistNow)) : .none
      }

    case .backgroundGraceExpired:
      // The background window ran out while still backgrounded. Final flush, then cancel
      // the socket ONLY — `liveChat` stays in memory so the foreground re-hydrate can
      // preserve the live thinking/tool rows (#26). No explicit `end()` here: the client
      // performed the mandatory end bookkeeping inside its expiration handler before
      // yielding. Guards: an expiry whose send escaped just as `.active` cancelled the
      // listener must be a no-op — `.active` already redialed, and tearing that fresh
      // socket down would strand the chat with no reconnect scheduled. Likewise nothing
      // to do when the slot was already torn down (e.g. the detached turn ended).
      guard state.isSceneBackgrounded, state.liveChat != nil else { return .none }
      return .concatenate(
        .send(.liveChat(.persistNow)),
        .send(.liveChat(.teardownSocketOnly))
      )

    case let .pushTapped(tap):
      // Deep-link a tapped push to its session — routed by comparing `tap.sessionID`
      // against the live slot + path (#32) so a tap for the already-open session never
      // stacks a duplicate chat screen.
      //
      // Badge bookkeeping: an approval tap first MARKS the session pending (it's a relevant
      // approval), then opening it CLEARS that entry below — so a tap that opens nets to zero,
      // while an approval that can't be opened (no list yet) stays badged until viewed.
      if tap.isApproval {
        state.pendingApprovalSessionIDs.insert(tap.sessionID)
      }
      guard state.home != nil else {
        // No session list yet (cold launch still auto-connecting or on onboarding) — can't
        // open. Stash the tap for replay once the list exists (#46), remembering which
        // server it belongs to (the stored URL — the agent this device's push
        // registration points at) so a login to a DIFFERENT server drops it instead of
        // replaying; the badge reflects the now-pending approval either way.
        state.pendingPushTap = tap
        state.pendingPushTapServerURL = preferences.loadServerURL().flatMap(parseServerURL)
        return setBadge(state)
      }
      // The tapped session is the one ALREADY on screen (slot match + marker on the
      // path) → NO navigation. Badge bookkeeping only: the user is now viewing it, so
      // the pending entry clears (mark-then-clear nets zero); the content update arrives
      // in place — the live socket is already streaming, and the tap's app activation
      // fires the existing `.foreground` re-hydrate.
      if state.currentViewingSessionID == tap.sessionID {
        state.pendingApprovalSessionIDs.remove(tap.sessionID)
        // Approval-recovery hint (#30 workaround): the socket may have been down when the
        // `approval.request` fired, so arm the one-shot hint AND drive the consuming
        // hydrate ourselves — the tap's scene activation is delivered independently of
        // this action, so a `.foreground` that reduced BEFORE the tap (or never fires)
        // would otherwise leave the hint armed for an arbitrary later hydrate.
        // `.foreground` is idempotent: it never cancel-and-redials a healthy socket,
        // just re-hydrates. Nil slot guarded (the hint is meaningless without one).
        if tap.isApproval, state.liveChat != nil {
          state.liveChat?.expectsPendingApproval = true
          return .merge(setBadge(state), .send(.liveChat(.foreground)))
        }
        return setBadge(state)
      }
      // Otherwise share the SAME `openSession` flow a list tap uses: a detached slot match
      // (user on the list) pushes the marker back and re-attaches live (no re-init, no dup);
      // a different session replaces the slot and SETS the path to the single new marker
      // (`fillLiveChat` resets rather than appends — no stacking on cold launch either).
      // Prefer the loaded `Session` (carries a title); fall back to a minimal `Session(id:)`
      // if it isn't in the list (the chat resumes by stored id and hydrates the title).
      let session = state.home?.sessions[id: tap.sessionID] ?? Session(id: tap.sessionID)
      // Opening clears the badge entry + marks current-viewing (handled in the openSession case).
      return .send(.home(.delegate(.openSession(session))))

    case let .launchIntentReceived(intent):
      // Route an App-Intent launch (#93) through the SAME `createSession` flow the "+"
      // button uses — the intent only routes, no agent logic runs from it (thin-client
      // rule). No `home` yet (cold launch still auto-connecting or on onboarding) → stash
      // for replay once the list exists, mirroring the cold-launch push-tap stash (#46).
      // Unlike a push tap there is no badge bookkeeping and no server identity to verify:
      // the intent originates from THIS device's UI surface (no foreign-server risk), so
      // the replay proceeds unconditionally. The dictation variant arms the new chat's
      // initial voice action (consumed at `.ready`); the voice-conversation variant joins
      // with #92.
      guard state.home != nil else {
        state.pendingLaunchIntent = intent
        return .none
      }
      // A launch intent must not silently tear down a running turn or an in-memory prompt
      // queue. Surface the single-slot conflict and require an explicit replacement (#93).
      if let chat = state.liveChat, chat.isRunning || chat.hasQueuedWork {
        state.pendingConflictingLaunchIntent = intent
        state.launchIntentConflict = ConfirmationDialogState {
          TextState("Start a new chat?")
        } actions: {
          ButtonState(role: .destructive, action: .replace) {
            TextState("Open New Chat")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "The current chat is still working or has queued prompts. Opening a new chat will leave it and discard any queued prompts on this device."
          )
        }
        return .none
      }
      return .send(.launchIntentConfirmed(intent))

    case let .launchIntentConfirmed(intent):
      switch intent {
      case .startNewSession:
        return .send(.home(.delegate(.createSession(initialComposerText: nil))))
      case .startNewSessionWithDictation:
        return .send(.home(.delegate(
          .createSession(initialComposerText: nil, initialVoiceAction: .startDictation)
        )))
      }

    case .launchIntentConflict(.presented(.replace)):
      guard let intent = state.pendingConflictingLaunchIntent else { return .none }
      state.pendingConflictingLaunchIntent = nil
      return .send(.launchIntentConfirmed(intent))

    case .launchIntentConflict(.dismiss):
      state.pendingConflictingLaunchIntent = nil
      return .none

    case .launchIntentConflict:
      return .none

    case let .onboarding(.delegate(.connected(connection))):
      // Defensive, mirroring `.autoConnectSucceeded`: a retry screen and a live list must
      // never coexist. `AppView` would render `home` while the `ifLet` child stayed alive,
      // re-probing on every foreground for the process lifetime.
      state.connectionFailed = nil
      state.home = makeHomeState(connection: connection)
      // Auto-connect failure falls back to onboarding, so a manual login must also replay
      // a stashed cold-launch tap (#46) — and a stashed launch intent (#93).
      return replayPendingExternalRoute(&state)

    case let .home(.delegate(.openSession(session))):
      guard let home = state.home else { return .none }
      // Approval-recovery hint (#30 workaround): a badged session (approval push tapped or
      // received) may have missed the real `approval.request` while detached — read the flag
      // BEFORE clearing the badge entry so the hydrating chat can synthesize a generic card
      // when the turn is still running. Covers tap→open, slot replacement, and a badged
      // session opened later from the list.
      let expectsApproval = state.pendingApprovalSessionIDs.contains(session.id)
      // Opening a session clears its pending-approval badge entry (the user is now viewing it).
      // The current-viewing marker is updated by the `.onChange(of: currentViewingSessionID)`
      // modifier below (one source of truth for nav-derived state).
      state.pendingApprovalSessionIDs.remove(session.id)
      let badge = setBadge(state)
      // Re-opening the slot's OWN session (e.g. tapping the glowing row of a detached
      // running turn): the accumulated live state must survive — a fresh
      // `ChatFeature.State` would discard the detached thinking/tool/streaming rows.
      // Push the marker back (the path is empty when coming from the list) and
      // re-attach: hydrate against the live socket, reconnecting only if it died.
      if let chat = state.liveChat, chat.sessionKey == session.id {
        if expectsApproval {
          state.liveChat?.expectsPendingApproval = true
        }
        // Defensive guard: the path is normally empty here (re-opens come from the list,
        // and an on-screen match short-circuits in `pushTapped` before reaching this
        // delegate) — but a double-delivered open must not stack a second marker.
        if state.path.isEmpty {
          state.path.append(ChatScreen.State(
            sessionKey: session.id, generation: state.liveChatGeneration
          ))
        }
        return .merge(badge, .send(.liveChat(.reattached)))
      }
      // `resolvedTitle` keeps the server's "Untitled" placeholder out of the header
      // (and the rename pre-fill); a real title arrives via `session.info` on resume.
      // Carry the active profile so resume/history scope to the right `state.db`.
      var chat = ChatFeature.State(
        connection: home.connection,
        resumeStoredID: session.id,
        profileName: home.scopedProfileName,
        title: session.resolvedTitle
      )
      chat.expectsPendingApproval = expectsApproval
      guard state.liveChat != nil else {
        fillLiveChat(chat, into: &state)
        return badge
      }
      // Slot occupied (e.g. a push tap while a chat is open): replace it — the old chat
      // must be fully torn down (through the nil-out, so even its un-ID'd one-shot RPC
      // effects are cancelled) before the new chat fills the slot.
      return .merge(badge, teardownSlot(thenFill: chat))

    case let .home(.delegate(.createSession(initialComposerText, initialVoiceAction))):
      guard let home = state.home else { return .none }
      // New chats are created under the currently-selected profile. `initialComposerText`
      // (push "Ask agent to install") seeds the composer draft but is NOT auto-sent.
      // `initialVoiceAction` (#93) arms the chat's initial voice action — fired by
      // `ChatFeature` once the slot reaches `.ready`.
      var chat = ChatFeature.State(
        connection: home.connection,
        profileName: home.scopedProfileName,
        composerText: initialComposerText ?? ""
      )
      chat.pendingInitialVoiceAction = initialVoiceAction
      guard state.liveChat != nil else {
        fillLiveChat(chat, into: &state)
        return .none
      }
      // Slot occupied: flush + fully tear the old chat down before filling (same rule
      // as open — the replacement goes through the nil-out).
      return teardownSlot(thenFill: chat)

    case let .fillLiveChat(chat):
      fillLiveChat(chat, into: &state)
      return .none

    case .clearLiveChat:
      // Pop-to-list teardown completed — drop the slot state. `ifLet` auto-cancels any
      // remaining child effects on the nil-out.
      state.liveChat = nil
      state.liveChatGeneration &+= 1
      return .none

    case .path(.popFrom):
      // Popped back to the session list. Nothing to do at pop-START: the teardown policy
      // runs on `.chatViewDisappeared` (below), once the pop animation has finished —
      // clearing the slot here would blank the outgoing screen mid-animation and route
      // the view's disappearance into a nil child.
      return .none

    case let .chatViewDisappeared(generation):
      // The pushed chat view finished leaving the screen: the pop animation completed,
      // or its marker was swapped by a slot replacement. Forward the view-session
      // cleanup (mic/voice) to whatever chat owns the slot, then apply the pop policy:
      // a RUNNING detached turn keeps its slot untouched — the socket streams on, rows
      // accumulate, and the list's row glow tracks via `runningChanged` (whose
      // `running: false` while detached tears the slot down below). An idle detached
      // chat has nothing to keep alive — flush the snapshot, cancel everything, clear
      // the slot. A non-empty path means the disappearance came from a slot replacement
      // (the new chat is on screen) → cleanup only. No slot (logout/quit/teardown
      // already cleared it) → no-op.
      //
      // A replaced destination disappears asynchronously. Its generation no longer owns
      // the slot, so ignore it completely — forwarding cleanup would stop dictation in the
      // newly-filled chat.
      guard generation == state.liveChatGeneration, let chat = state.liveChat else {
        return .none
      }
      let cleanup: Effect<Action> = .send(.liveChat(.viewDisappeared))
      // `hasQueuedWork` (#66) keeps the slot alive like a running turn does: queued
      // prompts are in-memory only, so an idle pop with entries waiting (a parked
      // queue, or the gap before a drain's turn starts) must not destroy them — the
      // drain fires the next turn into the detached slot, and teardown comes when the
      // queue empties and that turn ends (the `runningChanged` policy below).
      guard state.path.isEmpty, !chat.isRunning, !chat.hasQueuedWork else { return cleanup }
      return .concatenate(cleanup, teardownSlot())

    case let .home(.delegate(.sessionArchived(id))):
      // The user archived a session from the list. If it's the slot's session (possibly
      // detached mid-turn), tear the live chat down FIRST — its socket must not keep
      // streaming into a session that's now archived. Any other session → nothing to do
      // (the list's optimistic archive handles itself).
      guard let chat = state.liveChat, chat.sessionKey == id else { return .none }
      // Deliberate asymmetry: if the archive PATCH later FAILS, the list restores the
      // row (optimistic rollback) but the slot stays torn down — re-opening simply
      // resumes the session fresh. Resurrecting live slot state for a rare failure path
      // isn't worth replaying the teardown.
      return teardownSlot()

    case let .home(.delegate(.sessionDeleted(id))):
      // The user permanently deleted a session. ALWAYS wipe its cached snapshot + turn
      // anchor — a deleted session must never repaint from the non-authoritative cache.
      // When it's the slot's session (possibly detached mid-turn), tear the live chat
      // down too, WITHOUT the snapshot flush (`flushSnapshot: false`): the flush would
      // re-save the very snapshot this wipe deletes. Same deliberate asymmetry as
      // archive: if the DELETE later fails, the list restores the row but the slot and
      // cache stay cleared — re-opening simply resumes the session fresh.
      let wipeSnapshot: Effect<Action> = .run { [chatSnapshot] _ in
        chatSnapshot.deleteSnapshot(id)
      }
      guard let chat = state.liveChat, chat.sessionKey == id else {
        return wipeSnapshot
      }
      return .concatenate(teardownSlot(flushSnapshot: false), wipeSnapshot)

    case let .home(.delegate(.sessionDeleteSucceeded(id))):
      // The server CONFIRMED the delete — only now drop the session's pending-approval
      // badge entry (opening the session, the normal clear path, no longer exists).
      // Clearing at initiation (`sessionDeleted` above) would be premature: a failed
      // DELETE restores the row, but its still-pending approval would badge nowhere —
      // nothing short of a fresh approval push repopulates the entry. Unlike the
      // wipe/teardown asymmetry above, the badge waits for confirmation.
      state.pendingApprovalSessionIDs.remove(id)
      return setBadge(state)

    case .home(.delegate(.disconnect)):
      // Token cleared in Settings → tear down and return to onboarding. Nil-ing the slot
      // auto-cancels its effects (socket included). The tap stash is structurally nil
      // here (home existed, so any stash was consumed at creation) — cleared
      // defensively: the stash dies with the identity. The pending-approval badge set
      // dies with it too (entries reference sessions on the server just left — they'd
      // leak a stale icon badge into the next login), so reset the badge to zero.
      let connection = state.home?.connection
      state.path = .init()
      state.liveChat = nil
      state.home = nil
      state.onboarding = .init()
      state.pendingPushTap = nil
      state.pendingPushTapServerURL = nil
      state.pendingLaunchIntent = nil
      state.pendingConflictingLaunchIntent = nil
      state.launchIntentConflict = nil
      state.pendingApprovalSessionIDs = []
      return .merge(setBadge(state), unregisterPushOnLogout(connection: connection))

    case .liveChat(.delegate(.sessionExpired)):
      // The live (gated) session died — attached or detached, the slot is the one chat.
      // The chat already paused its own reconnect; raise the re-auth modal seeded from its
      // connection (server URL + regime + identity). Ignore if a modal is already up.
      guard state.reauth == nil, let chat = state.liveChat else { return .none }
      state.reauth = makeReauthState(for: chat.connection)
      return .none

    case let .reauth(.presented(.delegate(.reauthenticated(connection, sameUser)))):
      state.reauth = nil
      if sameUser {
        // Same user → resume the dead slot chat in place with the fresh auth regime.
        guard state.liveChat != nil else { return .none }
        return .send(.liveChat(.resumeAfterReauth(connection)))
      }
      // Different user signed in → drop everything identity-scoped and force a fresh list.
      // (`makeHomeState` reads the profile pref AFTER the clear, so it seeds defaults.)
      // The approval badge set + tap stash are identity-scoped too — the old user's
      // pending approvals must not badge (or replay into) the new user's list.
      preferences.clearIdentityScopedPrefs()
      state.path = .init()
      state.liveChat = nil
      state.pendingPushTap = nil
      state.pendingPushTapServerURL = nil
      state.pendingLaunchIntent = nil
      state.pendingConflictingLaunchIntent = nil
      state.launchIntentConflict = nil
      state.pendingApprovalSessionIDs = []
      state.home = makeHomeState(connection: connection)
      return setBadge(state)

    case .reauth(.presented(.delegate(.quit))):
      // "Quit to start" → full logout (Keychain session + every pref) → onboarding.
      // The tap stash and the approval badge set die with the identity (same clears
      // as `.disconnect`, through the other logout path); badge reset to zero.
      let connection = state.home?.connection ?? state.liveChat?.connection
      try? keychain.deleteSession()
      preferences.clearServerURL()
      preferences.clearIdentityScopedPrefs()
      preferences.saveGroupingMode(.default)
      preferences.saveDefaultSessionSwipeAction(.default)
      preferences.saveShowCronSection(true)
      state.reauth = nil
      state.path = .init()
      state.liveChat = nil
      state.home = nil
      state.onboarding = .init()
      state.pendingPushTap = nil
      state.pendingPushTapServerURL = nil
      state.pendingLaunchIntent = nil
      state.pendingConflictingLaunchIntent = nil
      state.launchIntentConflict = nil
      state.pendingApprovalSessionIDs = []
      return .merge(setBadge(state), unregisterPushOnLogout(connection: connection))

    case let .liveChat(.delegate(.branchCreated(creation))):
      // A branch `session.create` resolved (#34). The new session lives ONLY in server
      // memory until its first prompt (the DB row is created lazily), so it must NOT go
      // through the resume-by-stored-id `openSession` flow — `session.resume` hard-fails
      // "session not found" without a DB row, and the not-found self-heal would then
      // strand the user in a fresh, unrelated, EMPTY session. Mirror the desktop's fork
      // flow instead: prime the replacement chat straight from the create response —
      // the stored id (list/marker identity) plus `attachLiveSessionID`, which makes
      // the new chat's socket attach via `session.activate` (re-binding the live
      // session's transport and returning the seeded history), plus the SEED (text +
      // parent id) so a server-side orphan reap of the never-prompted branch can be
      // healed by replaying the seeded create. Slot replacement still runs through
      // `teardownSlot(thenFill:)` (persist → teardown → nil-out → fill — never a
      // direct swap). Finally request a list refetch so the branch shows (nested
      // under its parent) once its DB row exists server-side — an abandoned branch
      // simply never appears (documented v1 behavior, no optimistic insert).
      guard let home = state.home else { return .none }
      var chat = ChatFeature.State(
        connection: home.connection,
        resumeStoredID: creation.handle.storedSessionID,
        profileName: home.scopedProfileName
      )
      chat.attachLiveSessionID = creation.handle.sessionID
      chat.branchSeed = creation.seed
      let reload: Effect<Action> = .send(.home(.pulledToRefresh))
      guard state.liveChat != nil else {
        fillLiveChat(chat, into: &state)
        return reload
      }
      return .concatenate(teardownSlot(thenFill: chat), reload)

    case let .liveChat(.delegate(.runningChanged(sessionID, running))):
      // Route the live chat's authoritative working-state change to the session list so its
      // row glow clears/lights INSTANTLY (event-driven), without waiting for the next poll.
      // The poll stays the backstop for not-open sessions. No `home` → nothing to patch.
      let glow: Effect<Action> = state.home != nil
        ? .send(.home(.setSessionRunning(id: sessionID, running: running)))
        : .none
      // A DETACHED slot (no marker in the path — the user popped to the list) only
      // outlives the pop while its turn runs. The turn ending — `message.complete`,
      // `.error`, or a foreground hydrate confirming `running == false` — means there's
      // nothing left to keep alive: flush the snapshot, then tear the slot down.
      // UNLESS the queue still owes work (#66): the chat's own reducer drained (or
      // parked) in the same reduction that emitted this delegate, so by now
      // `hasQueuedWork` is true exactly when a next turn is mid-drain or entries are
      // parked waiting — either way the in-memory queue must survive. The drained
      // turn's own end (queue empty by then) re-enters here and tears down normally;
      // a queue parked by an error while detached deliberately keeps the slot (bounded
      // by the user re-opening or archiving the session).
      guard !running, state.path.isEmpty, let chat = state.liveChat, !chat.hasQueuedWork
      else { return glow }
      return .concatenate(glow, teardownSlot())

    case .onboarding, .connectionFailed, .home, .path, .reauth, .liveChat:
      return .none
    }
  }

  /// The standard "slot is done" sequence (idle view-disappearance, detached turn
  /// completion, archived session, slot replacement): flush the snapshot + turn anchor
  /// first (the debounced persist is about to be cancelled), cancel every long-running
  /// chat effect, then clear the slot — the nil-out makes `ifLet` cancel ALL remaining
  /// child effects, including the un-ID'd one-shot RPCs (hydrate, submit, rename …) whose
  /// results must never reduce into a replacement chat. Passing `thenFill` replaces the
  /// slot with a fresh chat right after the clear. Any background grace window is released
  /// early in parallel (idempotent no-ops in the foreground) — a torn-down slot has
  /// nothing left for the OS task to keep alive.
  ///
  /// `flushSnapshot: false` skips the `persistNow` flush — used ONLY for permanent session
  /// deletion, where flushing would re-save the very snapshot the delete path is about to
  /// wipe from the cache. Every other teardown keeps the flush (the debounced persist is
  /// about to be cancelled and the session still exists).
  ///
  /// The action chain is delivered atomically: `Effect.send` emits synchronously, so the
  /// store drains persist → teardown → clear (→ fill) in one send loop — no user action
  /// can interleave between the steps.
  private func teardownSlot(
    thenFill replacement: ChatFeature.State? = nil,
    flushSnapshot: Bool = true
  ) -> Effect<Action> {
    var chain: [Effect<Action>] = []
    if flushSnapshot {
      chain.append(.send(.liveChat(.persistNow)))
    }
    chain.append(contentsOf: [
      .send(.liveChat(.teardown)),
      .send(.clearLiveChat),
    ])
    if let replacement {
      chain.append(.send(.fillLiveChat(replacement)))
    }
    return .merge(
      .cancel(id: CancelID.backgroundGrace),
      .run { [backgroundTask] _ in await backgroundTask.end() },
      .concatenate(chain)
    )
  }

  /// Build a fresh session-list state, seeding the device-local persisted profile
  /// selection (normally reloaded later, in the list view's `.task`). Seeding at creation
  /// matters for work that runs BEFORE the list appears — the cold-launch push-tap replay
  /// (#46) opens a chat synchronously here, and an unseeded `scopedProfileName` would
  /// resume the session UNSCOPED (wrong `state.db` on a non-default profile →
  /// "session not found" → the self-heal recreates a spurious empty chat under
  /// "default"). A persisted non-default name implies the agent supported profiles when
  /// it was selected (prefs are wiped on logout, bounding staleness); the list's
  /// capability probe still corrects `profilesSupported` right after. A profile
  /// deleted/renamed server-side since selection is the accepted corner: the scoped
  /// resume fails exactly as a warm list-tap under the same stale pref would — parity
  /// with the warm path is the contract, and the rare stale-profile miss is a far
  /// smaller surface than the unscoped-resume misroute this seeding fixes (which hit
  /// EVERY cold-launch replay on a non-default profile).
  private func makeHomeState(connection: ServerConnection) -> SessionListFeature.State {
    let persisted = SessionListFeature.State.persistedProfileName(preferences)
    return SessionListFeature.State(
      connection: connection,
      selectedProfileName: persisted,
      profilesSupported: persisted != SessionListFeature.State.defaultProfileName
    )
  }

  /// Deterministically resolve the two independent cold-launch route stashes. A local App
  /// Intent/Quick Action is an explicit request to open a new chat, so it wins over a pending
  /// notification navigation when both exist at login. The push route is dropped, but its
  /// approval badge bookkeeping remains intact so the user can still find that session later.
  private func replayPendingExternalRoute(_ state: inout State) -> Effect<Action> {
    if state.pendingLaunchIntent != nil {
      state.pendingPushTap = nil
      state.pendingPushTapServerURL = nil
      return replayPendingLaunchIntent(&state)
    }
    return replayPendingPushTap(&state)
  }

  /// Consume the cold-launch tap stash (#46): a tap dropped while `home` was nil is
  /// replayed through the normal `.pushTapped` routing the moment the list exists — slot
  /// compare, #32 dedup, and approval-hint arming all reuse the one code path (duplicating
  /// any of it here would drift). No stash → no effect. The replayed approval badge insert
  /// is idempotent (`Set` insert; the open then clears it, netting zero like a warm tap).
  ///
  /// Cross-server guard: a stash whose recorded origin differs from the server just
  /// connected to is DROPPED, not replayed — resuming a foreign session id would trip the
  /// "session not found" self-heal into creating a spurious empty chat. Dropping also
  /// scrubs EVERY pending-approval badge entry, not just the stashed tap's: the stash is
  /// last-wins, but every pre-home tap was stamped with the same origin (the persisted
  /// URL is constant across the pre-home window, and each identity teardown clears the
  /// set), so earlier badged approvals are equally foreign — they can never be viewed
  /// here (a foreign session never appears in this server's list, and opening is the
  /// only other clear path), and would otherwise stick for the process lifetime. An
  /// unknown origin (`nil` — no stored URL at stash time) replays unverified; see
  /// `pendingPushTapServerURL`.
  private func replayPendingPushTap(_ state: inout State) -> Effect<Action> {
    guard let tap = state.pendingPushTap else { return .none }
    let origin = state.pendingPushTapServerURL
    state.pendingPushTap = nil
    state.pendingPushTapServerURL = nil
    if let origin, let connected = state.home?.connection.baseURL,
       !Self.isSameServer(origin, connected) {
      guard !state.pendingApprovalSessionIDs.isEmpty else { return .none }
      state.pendingApprovalSessionIDs.removeAll()
      return setBadge(state)
    }
    return .send(.pushTapped(tap))
  }

  /// Consume the cold-launch intent stash (#93): an intent dropped while `home` was nil is
  /// replayed through the normal `.launchIntentReceived` routing the moment the list
  /// exists. Unlike the push-tap stash there is no cross-server guard — an intent can only
  /// originate from this device's own UI surface (Quick Actions / Shortcuts / Action
  /// button), so there is no foreign-server identity to verify and the replay proceeds
  /// unconditionally. No stash → no effect.
  private func replayPendingLaunchIntent(_ state: inout State) -> Effect<Action> {
    guard let intent = state.pendingLaunchIntent else { return .none }
    state.pendingLaunchIntent = nil
    return .send(.launchIntentReceived(intent))
  }

  /// Server identity for the stash guard: scheme + host (both case-insensitive per
  /// RFC 3986, so lowercased) + literal port — path/trailing-slash/casing variations of
  /// the same server must not drop a legitimate replay. Default-port drift
  /// (`http://host` vs `http://host:80`) is accepted as a mismatch: both URLs come from
  /// the same persisted-string pipeline, so they only diverge across a genuine re-login.
  private static func isSameServer(_ a: URL, _ b: URL) -> Bool {
    a.scheme?.lowercased() == b.scheme?.lowercased()
      && a.host?.lowercased() == b.host?.lowercased()
      && a.port == b.port
  }

  /// Fill the live-chat slot and (re)set the navigation path to that chat's single marker.
  /// One slot ↔ one marker: the path never holds more than one chat screen, so replacing the
  /// contents (rather than appending) can't stack duplicates.
  private func fillLiveChat(_ chat: ChatFeature.State, into state: inout State) {
    state.liveChat = chat
    state.path.removeAll()
    state.path.append(ChatScreen.State(
      sessionKey: chat.sessionKey, generation: state.liveChatGeneration
    ))
  }

  /// The prefilled-onboarding landing for a connection that needs *editing* rather than
  /// retrying: token mode prefills both fields so the user can fix them; cookie mode prefills
  /// only the URL (the password is never persisted), so they re-enter it. Shared by the launch
  /// auth-failure fallback and the retry screen's `.credentialsRejected` delegate, so
  /// onboarding is constructed in exactly one place.
  private func fallBackToOnboarding(_ state: inout State, connection: ServerConnection) {
    state.onboarding = ConnectionFeature.State(
      serverURL: connection.baseURL.absoluteString,
      token: connection.auth.token ?? ""
    )
  }

  /// Best-effort push cleanup on logout: unregister the last-known device token with the
  /// agent's push plugin (failures ignored — the server prunes dead tokens on a 410 anyway),
  /// then clear the persisted device token (prefs). Part of
  /// "logout clears everything". Uses the persisted token so it works even when the live
  /// `register()` stream isn't producing; a `nil` connection (nothing to talk to) still clears
  /// local push state.
  private func unregisterPushOnLogout(connection: ServerConnection?) -> Effect<AppFeature.Action> {
    let token = preferences.loadPushDeviceToken()
    preferences.clearPushDeviceToken()
    preferences.clearPushPromptSnooze() // device-local push prompt state — reset on logout
    guard let connection, let token else { return .none }
    return .run { [rest] _ in
      try? await rest.unregisterPush(connection, token)
    }
  }

  /// Push the app-icon badge to the current pending-approval count (the only side effect; the
  /// count itself lives in `state.pendingApprovalSessionIDs`, kept testable in the reducer).
  private func setBadge(_ state: State) -> Effect<AppFeature.Action> {
    let count = state.pendingApprovalSessionIDs.count
    return .run { [push] _ in await push.setBadgeCount(count) }
  }

  /// Seed a `ReauthFeature.State` from the connection of the expired chat: a fixed server
  /// URL, the matching auth regime, and (cookie mode) the prefilled username + provider used
  /// for the same-user vs user-switch decision.
  private func makeReauthState(for connection: ServerConnection) -> ReauthFeature.State {
    switch connection.auth {
    case .token:
      return ReauthFeature.State(serverURL: connection.baseURL, method: .token)
    case let .cookie(session):
      return ReauthFeature.State(
        serverURL: connection.baseURL,
        method: .password,
        provider: session.provider,
        previousUsername: session.username
      )
    }
  }
}
