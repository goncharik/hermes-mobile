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
    /// The horizontal layout the app shell is rendering in, reported by the thin app shell
    /// (`layoutChanged`). Defaults to `.compact` (the iPhone layout): in compact the chat is
    /// a pushed screen whose thin marker sits on `path`; in `.regular` (iPad split view) the
    /// slot IS the detail column and the path stays empty — a chat there is never "detached".
    /// The shell decides which one a window is (see `Layout`).
    public var layout: Layout
    /// Bumped on every regular-width slot fill. The app shell keys the detail column's
    /// `ChatView` on it (`.id`), so a slot replacement always gets a FRESH view — otherwise
    /// the incoming session inherits the outgoing one's transcript scroll offset and composer
    /// focus (`docs/features/ipad-layout.md`). Compact never bumps: there a fill pushes a new
    /// marker, whose destination is a new view.
    public internal(set) var slotGeneration: Int = 0
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
    /// A push tap that arrived before the session list existed (cold launch — #46): the
    /// routing in `.pushTapped` can't open anything without `home`, so the tap is stashed
    /// here (single stash, last-wins) and replayed once `.autoConnectSucceeded` / a manual
    /// login creates the list. Process-lifetime only (never persisted) — the race it
    /// covers is intra-launch — and cleared on logout (the stash dies with the identity).
    var pendingPushTap: PushTap?
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
      layout: Layout = .compact,
      autoConnecting: Bool = false,
      connectionFailed: ConnectionFailedFeature.State? = nil,
      reauth: ReauthFeature.State? = nil,
      pendingApprovalSessionIDs: Set<String> = []
    ) {
      self.onboarding = onboarding
      self.home = home
      self.path = path
      self.liveChat = liveChat
      self.layout = layout
      self.autoConnecting = autoConnecting
      self.connectionFailed = connectionFailed
      self.reauth = reauth
      self.pendingApprovalSessionIDs = pendingApprovalSessionIDs
    }

    /// Whether the live chat slot is off screen — the user is on the session list with the
    /// chat popped. The ONE definition every "is the chat detached?" read goes through
    /// (`currentViewingSessionID`, the pop-teardown policy, the detached-turn-end
    /// teardown, the re-open marker push, #32 push-tap dedup): in compact an empty path
    /// means the chat was popped; in regular the slot is always the visible detail column,
    /// so a chat there can never be detached — whatever the path holds.
    public var isChatDetached: Bool { layout == .compact && path.isEmpty }

    /// The session the user is currently viewing — the live chat's session key
    /// (`storedSessionID ?? liveSessionID`) while its chat is on screen, or `nil` when no
    /// chat is on screen (or a new chat whose id hasn't resolved yet). A detached slot
    /// (user on the list) reads `nil` so pushes for that session are NOT suppressed.
    /// Drives foreground push suppression via `.onChange`; the sidebar highlight reads
    /// `highlightedSessionID` below.
    public var currentViewingSessionID: String? {
      guard !isChatDetached else { return nil }
      return liveChat?.sessionKey
    }

    /// The sidebar row to highlight (#80) — the session the detail column is showing, and
    /// only in regular width, where the list and the chat are on screen together. Compact
    /// always reads `nil`: `currentViewingSessionID` is non-nil there whenever the marker is
    /// on the path, which includes the pop animation and an interactive swipe-back, when the
    /// list IS visible — the iPhone list must stay unhighlighted. A new chat whose id hasn't
    /// resolved yet reads `nil` too, so no row is highlighted for it.
    public var highlightedSessionID: String? {
      layout == .regular ? currentViewingSessionID : nil
    }

    /// What the regular-width seat reseat (`reduceProfileReseat`) is watching: the list's
    /// scoped profile, whether the seat's composer input is still resolving, and the layout.
    /// The second member DEFERS rather than skips a reseat that would land mid-paste or
    /// mid-recording — the teardown would drop the batch and cut the mic — because the signal
    /// changes again the moment that input lands, and the reseat then carries the resolved
    /// draft across. The third defers the same way across a resize: the reseat is regular-only,
    /// so a mismatch that falls due in compact (a narrowed window, a server-side rename) would
    /// otherwise be dropped for good — widening re-fires it instead.
    var profileReseatSignal: ProfileReseatSignal {
      ProfileReseatSignal(
        profileName: home?.scopedProfileName,
        composerInputInFlight: liveChat?.hasInFlightComposerInput ?? false,
        layout: layout
      )
    }

    struct ProfileReseatSignal: Equatable, Sendable {
      var profileName: String?
      var composerInputInFlight: Bool
      var layout: Layout
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

  /// Horizontal layout regime, reported via `layoutChanged`. `.compact` = the
  /// navigation-stack layout; `.regular` = the split view with the chat as the detail column.
  /// WHICH one a given window is, is a shell fact the reducer never re-derives — see
  /// `AppView.appLayout(for:)` and `docs/features/ipad-layout.md`.
  public enum Layout: Equatable, Sendable {
    case compact
    case regular
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
    /// The layout regime changed (reported by the app shell, `initial: true`). Sets `layout`
    /// FIRST — so the `chatViewDisappeared` the chat view fires while moving between the
    /// stack and the detail column is a no-op through `isChatDetached` — then reconciles the
    /// path with the slot: regular→compact pushes the live chat's marker (the stack must show
    /// it) unless the slot is an untouched detail seat, which is torn down instead;
    /// compact→regular clears the path (the slot is the detail; a marker would double-render
    /// the chat). Same layout twice is a no-op. Widening with NO slot seats a fresh new chat
    /// in the detail column — regular never shows a blank detail.
    case layoutChanged(Layout)
    /// A push notification was tapped — deep-link to its session, routed by comparing the
    /// tapped id against the live slot under `isChatDetached` (#32): slot match + not
    /// detached (on screen — a compact marker, or any slot in regular) → badge bookkeeping
    /// + in-place hydrate only; slot match + detached (compact only) → re-attach push;
    /// different session → replace the slot and SET the path (one marker in compact, empty
    /// in regular; never stack). Approval taps clear their pending-badge entry on view.
    case pushTapped(PushTap)
    case onboarding(ConnectionFeature.Action)
    /// The launch retry screen's actions (present only while the slot is filled).
    case connectionFailed(ConnectionFailedFeature.Action)
    case home(SessionListFeature.Action)
    case path(StackActionOf<ChatScreen>)
    /// A chat view finished leaving the screen (sent by BOTH columns in `AppView` — never
    /// through the child scope, so a nil slot can be guarded here instead of tripping the
    /// `ifLet` nil-child warning). Acts only on a DETACHED slot: forwards the view-session
    /// cleanup (`.viewDisappeared`) and applies the pop-to-list teardown policy AFTER the
    /// pop animation — tearing down at `.popFrom` time would blank the outgoing screen
    /// mid-animation. The same event fires when the chat moves between columns on a layout
    /// change and when a regular-width replacement re-creates the detail view; the chat is
    /// on screen (or already torn down) in both, so those are no-ops.
    case chatViewDisappeared
    /// The live chat slot's actions — the chat is composed here (via `.ifLet`), NOT in the
    /// navigation path, so its effects survive pops.
    case liveChat(ChatFeature.Action)
    /// Internal: fill the live-chat slot with a fresh chat and (re)set its path marker.
    /// Used when opening while the slot is occupied — sequenced after the old slot's
    /// `.teardown` AND `.clearLiveChat` (the nil-out is what cancels the outgoing chat's
    /// un-ID'd one-shot RPC effects) so nothing can leak into the replacement. In regular
    /// width the replacement is also STARTED here (`.liveChat(.task)`) — the one half of the
    /// dial `swift test` can assert.
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
  }

  /// Ids for the long-running incoming-tap observer and the background-grace listener.
  private enum CancelID { case pushTaps, backgroundGrace }

  /// Name of the finite background task requested while a running turn is backgrounded
  /// (shows up in OS background-task diagnostics). Tests re-type the literal on purpose —
  /// an accidental rename should fail the suite, not silently follow the constant.
  private static let backgroundGraceTaskName = "hermes.chat.background-grace"

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.hermesREST) var rest
  @Dependency(\.push) var push
  @Dependency(\.backgroundTask) var backgroundTask
  @Dependency(\.chatSnapshot) var chatSnapshot
  /// Only for `releaseSlotMic` — the identity teardowns that drop the slot without a
  /// `ChatFeature.teardown` to release the mic for them.
  @Dependency(\.audioRecorder) var audioRecorder
  /// The `.bearer` regime's single token owner (#19). `AppFeature` owns its LIFECYCLE — seed
  /// on launch restore and on a re-auth that hands back a bearer connection, drain on every
  /// logout — while `ConnectionFeature`/`ReauthFeature` seed it for the login they just ran.
  /// Nothing here ever reads a token out of it: `HermesRESTClient`/`HermesGatewayClient` do.
  @Dependency(\.bearerTokens) var bearerTokens

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.onboarding, action: \.onboarding) {
      ConnectionFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        // Observe push taps for the whole app lifetime (a tap can arrive cold-launch or while
        // running) and deep-link them; the actual nav happens in `.pushTapped`.
        let tapObserver: Effect<Action> = .run { [push] send in
          for await tap in push.incomingTaps() {
            await send(.pushTapped(tap))
          }
        }
        .cancellable(id: CancelID.pushTaps, cancelInFlight: true)
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
        else { return tapObserver }
        // A `.token` session with an empty token is treated as "no creds" (matches the old
        // `loadToken()`-non-empty guard) so we stay on onboarding rather than probe blindly.
        if case .token("") = session { return tapObserver }
        state.didRunLaunchProbe = true
        state.autoConnecting = true
        let connection = ServerConnection(baseURL: url, auth: session)
        return .merge(
          tapObserver,
          .run { [rest, keychain, bearerTokens] send in
            // Bearer restore (#19) must happen BEFORE the probe: a `.bearer` connection
            // resolves its `Authorization` header through the token store, so probing an
            // unseeded store sends the request with no credentials at all and 401s a
            // perfectly good session into prefilled onboarding. Seeding also re-arms the
            // Keychain persist hook, so a rotation during the probe is saved.
            await Self.seedBearerStore(session, baseURL: url, keychain: keychain, store: bearerTokens)
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
              await send(.autoConnectSucceeded(connection))
            } catch {
              // A dead refresh token surfaces here as `RESTError.unauthorized` (the store
              // maps the 401 verdict), so it takes the existing credentials-verdict branch
              // in `.autoConnectFailed` — the #62 routing rule needs no bearer carve-out.
              await send(.autoConnectFailed(connection, asRESTError(error)))
            }
          }
        )

      case let .autoConnectSucceeded(connection):
        state.autoConnecting = false
        // Defensive: a retry screen and a live list must never coexist (see the `.task` guard).
        state.connectionFailed = nil
        state.home = makeHomeState(connection: connection)
        return landOnHome(&state)

      case let .autoConnectFailed(connection, error):
        state.autoConnecting = false
        guard ConnectionFailedFeature.isRetryable(error) else {
          // Stored creds didn't validate (expired token / dead cookies / a dead refresh
          // token) — fall back to onboarding for re-entry; retrying can't repair dead
          // credentials.
          return fallBackToOnboarding(&state, connection: connection)
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
        return landOnHome(&state)

      case let .connectionFailed(.delegate(.credentialsRejected(connection))):
        // The retry reached the server and it turned us away — retrying can't fix that, so
        // land exactly where a launch auth failure lands: prefilled onboarding, nothing
        // cleared, which is also where the connection-help sheet's entry points live.
        state.connectionFailed = nil
        return fallBackToOnboarding(&state, connection: connection)

      case .connectionFailed(.delegate(.logoutConfirmed)):
        // "Log Out" from the retry screen (confirmed): the user is abandoning the stored
        // session, so run the same logout as "Quit to start" (Keychain session + every pref)
        // and land on a *fresh* onboarding — nothing prefilled, there is no session left to
        // repair. The tap stash and the approval badge set die with the identity too.
        let connection = state.connectionFailed?.connection
        let releaseMic = releaseSlotMic(state)
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
        state.pendingApprovalSessionIDs = []
        return .merge(releaseMic, setBadge(state), serverSideLogout(connection: connection))

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

      case let .layoutChanged(layout):
        return reduceLayoutChanged(&state, to: layout)

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
        return reducePushTapped(&state, tap: tap)

      case let .onboarding(.delegate(.connected(connection))):
        // Defensive, mirroring `.autoConnectSucceeded`: a retry screen and a live list must
        // never coexist. `AppView` would render `home` while the `ifLet` child stayed alive,
        // re-probing on every foreground for the process lifetime.
        state.connectionFailed = nil
        state.home = makeHomeState(connection: connection)
        // Auto-connect failure falls back to onboarding, so a manual login must also replay
        // a stashed cold-launch tap (#46).
        return landOnHome(&state)

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
          // Marker only when the chat is actually detached (compact + empty path) — in
          // regular the slot is already the visible detail and the path stays empty.
          // Defensive guard too: the path is normally empty here in compact (re-opens come
          // from the list, and an on-screen match short-circuits in `pushTapped` before
          // reaching this delegate) — but a double-delivered open must not stack a second
          // marker.
          if state.isChatDetached {
            state.path.append(ChatScreen.State(sessionKey: session.id))
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
          seatLiveChat(chat, into: &state)
          return badge
        }
        // Slot occupied (e.g. a push tap while a chat is open): replace it — the old chat
        // must be fully torn down (through the nil-out, so even its un-ID'd one-shot RPC
        // effects are cancelled) before the new chat fills the slot.
        return .merge(badge, teardownSlot(thenFill: chat))

      case let .home(.delegate(.createSession(initialComposerText))):
        guard let home = state.home else { return .none }
        // "New session" over a slot the list would rebuild identically (`isReusableNewChat`
        // — regular width keeps one such seat in the detail column at all times): tearing it
        // down to fill an identical fresh one would redial its socket for nothing. Reset the
        // composer draft (text + staged attachments) instead — the only visible difference a
        // fresh chat would have; `initialComposerText` still seeds it. Anything the shortcut
        // can't reproduce (a stale profile, in-flight composer input, a failed handshake)
        // falls through to the real refill. The marker guard is the compact safety net: a
        // detached seat re-attaches rather than leaving the tap without a screen.
        if let chat = state.liveChat, Self.isReusableNewChat(chat, for: home) {
          state.liveChat?.composerText = initialComposerText ?? ""
          state.liveChat?.attachments = []
          if state.isChatDetached {
            state.path.append(ChatScreen.State(sessionKey: chat.sessionKey))
          }
          return .none
        }
        // New chats are created under the currently-selected profile. `initialComposerText`
        // (push "Ask agent to install") seeds the composer draft but is NOT auto-sent.
        let chat = newChat(for: home, composerText: initialComposerText ?? "")
        guard state.liveChat != nil else {
          seatLiveChat(chat, into: &state)
          return .none
        }
        // Slot occupied: flush + fully tear the old chat down before filling (same rule
        // as open — the replacement goes through the nil-out).
        return teardownSlot(thenFill: chat)

      case let .fillLiveChat(chat):
        seatLiveChat(chat, into: &state)
        // The initial connect is the chat view's `.task` (first appearance). In compact the
        // fresh marker's destination is a NEW view, so it fires there. In regular the whole
        // teardown → clear → fill chain reduces synchronously (`.send` is a `Just`), so SwiftUI
        // never observes the nil slot — the detail view is re-created by `slotGeneration`
        // instead, off state the shell has to be keyed on correctly. Dial here so the seat is
        // connected regardless; `hasStarted` makes the view's `.task` a no-op, never a redial.
        return state.layout == .regular ? .send(.liveChat(.task)) : .none

      case .clearLiveChat:
        // Pop-to-list teardown completed — drop the slot state. `ifLet` auto-cancels any
        // remaining child effects on the nil-out.
        state.liveChat = nil
        return .none

      case .path(.popFrom):
        // Popped back to the session list. Nothing to do at pop-START: the teardown policy
        // runs on `.chatViewDisappeared` (below), once the pop animation has finished —
        // clearing the slot here would blank the outgoing screen mid-animation and route
        // the view's disappearance into a nil child.
        return .none

      case .chatViewDisappeared:
        // The chat view finished leaving the screen. Only a DETACHED slot (`isChatDetached`
        // — compact, the pop animation completed) means the chat is genuinely off screen:
        // forward the view-session cleanup (mic/voice) and apply the pop policy. A RUNNING
        // detached turn keeps its slot untouched — the socket streams on, rows accumulate,
        // and the list's row glow tracks via `runningChanged` (whose `running: false` while
        // detached tears the slot down below). An idle detached chat has nothing to keep
        // alive — flush the snapshot, cancel everything, clear the slot.
        //
        // Everything else is a no-op, cleanup included: the slot's chat is still on screen
        // (it moved between the stack and the detail column on a layout change — releasing
        // the mic there would cancel a recording under a visible composer) or the view that
        // left belonged to a chat a slot replacement already tore down, whose `.teardown`
        // released the same resources. No slot (logout/quit) → no-op too.
        guard let chat = state.liveChat, state.isChatDetached else { return .none }
        let cleanup: Effect<Action> = .send(.liveChat(.viewDisappeared))
        // `hasQueuedWork` (#66) keeps the slot alive like a running turn does: queued
        // prompts are in-memory only, so an idle pop with entries waiting (a parked
        // queue, or the gap before a drain's turn starts) must not destroy them — the
        // drain fires the next turn into the detached slot, and teardown comes when the
        // queue empties and that turn ends (the `runningChanged` policy below).
        guard !chat.isRunning, !chat.hasQueuedWork else { return cleanup }
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
        // isn't worth replaying the teardown. In regular the torn-down chat WAS the detail
        // column, so a fresh new chat is seated behind it (`detailRefill`); compact leaves
        // the slot nil — the user is on the list.
        return teardownSlot(thenFill: detailRefill(state))

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
        // Same regular-width refill as archive: the detail column must not go blank.
        return .concatenate(
          teardownSlot(thenFill: detailRefill(state), flushSnapshot: false), wipeSnapshot
        )

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
        // auto-cancels its effects (socket included); the mic is the one thing that outlives
        // them, so `releaseSlotMic` covers it. The tap stash is structurally nil here (home
        // existed, so any stash was consumed at creation) — cleared defensively: the stash
        // dies with the identity. The pending-approval badge set
        // dies with it too (entries reference sessions on the server just left — they'd
        // leak a stale icon badge into the next login), so reset the badge to zero.
        let connection = state.home?.connection
        let releaseMic = releaseSlotMic(state)
        state.path = .init()
        state.liveChat = nil
        state.home = nil
        state.onboarding = .init()
        state.pendingPushTap = nil
        state.pendingPushTapServerURL = nil
        state.pendingApprovalSessionIDs = []
        return .merge(releaseMic, setBadge(state), serverSideLogout(connection: connection))

      case .liveChat(.delegate(.sessionExpired)):
        // The live (gated) session died — attached or detached, the slot is the one chat.
        // The chat already paused its own reconnect; raise the re-auth modal seeded from its
        // connection (server URL + regime + identity). Ignore if a modal is already up.
        guard state.reauth == nil, let chat = state.liveChat else { return .none }
        state.reauth = makeReauthState(
          for: chat.connection,
          // Whatever the onboarding screen last probed — empty after a launch auto-restore,
          // which `providerLabel` handles by falling back to the wire provider name.
          oauthProviders: state.onboarding.capability?.oauthProviders ?? []
        )
        return .none

      case let .reauth(.presented(.delegate(.reauthenticated(connection, sameUser)))):
        state.reauth = nil
        // Adopt the fresh bearer pair in the token store BEFORE anything reconnects. The
        // store still holds the DEAD pair the sheet was raised for, so a resume or a fresh
        // list fetch that overtakes this would re-send exactly the credentials that expired.
        // `.concatenate` below is what makes "before" true; a `.merge` would race.
        let reseed = reseedBearerStore(for: connection)
        if sameUser {
          // Same user → adopt the fresh auth regime EVERYWHERE the app still holds the dead
          // one. The list's connection is the snapshot every later chat is built from (a row
          // tap, the regular-width archive/delete refill, the profile reseat) and the one its
          // own REST calls carry: left stale it would reconnect under expired credentials
          // and, in cookie mode, push that dead jar back into the transport's shared cookie
          // storage (`wsTicket` rehydrates it), undoing the login that just succeeded.
          state.home?.connection = connection
          // Then resume the dead slot chat in place.
          guard state.liveChat != nil else { return reseed }
          return .concatenate(reseed, .send(.liveChat(.resumeAfterReauth(connection))))
        }
        // Different user signed in → drop everything identity-scoped and force a fresh list.
        // (`makeHomeState` reads the profile pref AFTER the clear, so it seeds defaults.)
        // The approval badge set + tap stash are identity-scoped too — the old user's
        // pending approvals must not badge (or replay into) the new user's list.
        preferences.clearIdentityScopedPrefs()
        let releaseMic = releaseSlotMic(state)
        state.path = .init()
        state.liveChat = nil
        state.pendingPushTap = nil
        state.pendingPushTapServerURL = nil
        state.pendingApprovalSessionIDs = []
        state.home = makeHomeState(connection: connection)
        let identityCleanup: Effect<Action> = .merge(releaseMic, setBadge(state))
        // The stash was just cleared, so there is nothing to replay — but in regular the new
        // user's detail column still needs its fresh new chat. Routed through the `.fillLiveChat`
        // ACTION, never a direct fill: this reduction must END with the slot nil so `ifLet`
        // cancels the expired chat's remaining effects (a non-nil→non-nil swap compares equal
        // and cancels nothing), and the action is what starts the replacement's socket.
        guard let seat = detailRefill(state) else { return .merge(identityCleanup, reseed) }
        return .merge(identityCleanup, .concatenate(reseed, .send(.fillLiveChat(seat))))

      case .reauth(.presented(.delegate(.quit))):
        // "Quit to start" → full logout (Keychain session + every pref) → onboarding.
        // The tap stash and the approval badge set die with the identity (same clears
        // as `.disconnect`, through the other logout path); badge reset to zero.
        let connection = state.home?.connection ?? state.liveChat?.connection
        let releaseMic = releaseSlotMic(state)
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
        state.pendingApprovalSessionIDs = []
        return .merge(releaseMic, setBadge(state), serverSideLogout(connection: connection))

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
          seatLiveChat(chat, into: &state)
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
        // A DETACHED slot (`isChatDetached`: compact with no marker in the path — the user
        // popped to the list; never the case in regular, where the slot is the visible
        // detail column) only outlives the pop while its turn runs. The turn ending —
        // `message.complete`, `.error`, or a foreground hydrate confirming `running == false`
        // — means there's nothing left to keep alive: flush the snapshot, then tear the slot
        // down.
        // UNLESS the queue still owes work (#66): the chat's own reducer drained (or
        // parked) in the same reduction that emitted this delegate, so by now
        // `hasQueuedWork` is true exactly when a next turn is mid-drain or entries are
        // parked waiting — either way the in-memory queue must survive. The drained
        // turn's own end (queue empty by then) re-enters here and tears down normally;
        // a queue parked by an error while detached deliberately keeps the slot (bounded
        // by the user re-opening or archiving the session).
        guard !running, state.isChatDetached, let chat = state.liveChat, !chat.hasQueuedWork
        else { return glow }
        return .concatenate(glow, teardownSlot())

      case .onboarding, .connectionFailed, .home, .path, .reauth, .liveChat:
        return .none
      }
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
    // The regular-width seat follows the list's selected profile (#80): the seated unprompted
    // chat exists only as "the next new chat", so when the sidebar's profile changes under
    // it — `selectProfile`, a server verdict re-homing to default, a rename/delete of the
    // selected profile, or the profiles capability flipping — it is reseated under the NEW
    // profile through the standard teardown chain (its socket may already be dialled), so
    // the first prompt lands in the right `state.db`. A chat with anything in it (a resumed
    // session, a running or prompted new chat) is left alone exactly as in compact — the
    // profile is the LIST's scope, not the open chat's. Compact never has a seat (a popped
    // unprompted chat is torn down), so the rule is regular-only and the iPhone path is untouched.
    // Evaluated AFTER the list reducer so it reads the new selection; landing on a fresh
    // `home` also trips it, but the seat `landOnHome` just filled already matches → no-op.
    .onChange(of: \.profileReseatSignal) { _, _ in
      Reduce { state, _ in reduceProfileReseat(&state) }
    }
  }

  /// The layout regime changed: set `layout` FIRST (the view's column move fires
  /// `chatViewDisappeared`, which must read the NEW layout through `isChatDetached` and
  /// leave the slot alone), then reconcile the path with the slot.
  private func reduceLayoutChanged(_ state: inout State, to layout: Layout) -> Effect<Action> {
    guard layout != state.layout else { return .none }
    state.layout = layout
    guard let chat = state.liveChat else {
      // Widening onto an EMPTY slot: the detail column would render blank — seat a
      // fresh new chat (a no-op when narrowing, or with no list to build it from).
      fillNewChatIfDetailEmpty(&state)
      return .none
    }
    switch layout {
    case .compact:
      // A PRISTINE detail seat (regular always keeps one — a new chat with nothing in it,
      // not even a draft) has nothing to show in the stack: pushing it would land the user
      // on an empty chat with a Back button instead of the list, and popping it would tear
      // it down anyway. Drop it here; widening seats a fresh one.
      if chat.isPristineNewChat {
        return teardownSlot()
      }
      // Any other live slot (attached detail moments ago, a running turn, a typed draft)
      // needs its marker so the chat stays visible. SET, never append: one slot ↔ one
      // marker.
      state.path = StackState([ChatScreen.State(sessionKey: chat.sessionKey)])
    case .regular:
      // The slot IS the detail column; a lingering marker would render the chat twice
      // (sidebar stack + detail). The slot itself — socket, rows, ticker — is untouched.
      state.path.removeAll()
    }
    return .none
  }

  /// Deep-link a tapped push to its session — routed by comparing `tap.sessionID` against
  /// the live slot through `isChatDetached` (#32) so a tap for the already-open session
  /// never stacks a duplicate chat screen. Three outcomes, in order below: slot match + not
  /// detached → in-place; slot match + detached (compact only) → re-attach via
  /// `openSession`; different session → slot replacement (marker only in compact).
  /// Cold-launch replay (#46, `landOnHome`) re-enters here unchanged in shape — the same
  /// three rules decide, under whichever layout the list landed in.
  ///
  /// Badge bookkeeping: an approval tap first MARKS the session pending (it's a relevant
  /// approval), then opening it CLEARS that entry below — so a tap that opens nets to zero,
  /// while an approval that can't be opened (no list yet) stays badged until viewed.
  private func reducePushTapped(_ state: inout State, tap: PushTap) -> Effect<Action> {
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
    // The tapped session is the one ALREADY on screen (`currentViewingSessionID` — the
    // slot key when NOT detached: in compact that means its marker is on the path, in
    // regular the slot is always the visible detail) → NO navigation, path untouched
    // (empty in regular). Badge bookkeeping only: the user is now viewing it, so the
    // pending entry clears (mark-then-clear nets zero); the content update arrives in
    // place — the live socket is already streaming, and the tap's app activation fires
    // the existing `.foreground` re-hydrate.
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
    // Otherwise share the SAME `openSession` flow a list tap uses: a DETACHED slot match
    // (compact only — the user popped to the list; in regular a slot match always took
    // the branch above) pushes the marker back and re-attaches live (no re-init, no
    // dup); a different session replaces the slot and SETS the path — the single new
    // marker in compact, left empty in regular where the slot IS the detail column
    // (`seatLiveChat` resets rather than appends — no stacking on cold launch either).
    // Prefer the loaded `Session` (carries a title); fall back to a minimal `Session(id:)`
    // if it isn't in the list (the chat resumes by stored id and hydrates the title).
    let session = state.home?.sessions[id: tap.sessionID] ?? Session(id: tap.sessionID)
    // Opening clears the badge entry + marks current-viewing (handled in the openSession case).
    return .send(.home(.delegate(.openSession(session))))
  }

  /// Body of the `profileReseatSignal` `onChange` above (see it for when and why): reseat a
  /// discardable regular-width seat that is no longer scoped to the profile the list would
  /// build it under. `isDiscardableNewChat` is the same seat predicate the "New session"
  /// shortcut and the narrowing drop read, so a seat with a paste or a recording still in
  /// flight is not reseated out from under the user — the signal re-fires when that input
  /// lands and the reseat carries it across then.
  private func reduceProfileReseat(_ state: inout State) -> Effect<Action> {
    guard state.layout == .regular, let home = state.home, let chat = state.liveChat,
          chat.isDiscardableNewChat, chat.profileName != home.scopedProfileName
    else { return .none }
    // The seat is RE-CREATED under the new profile, not emptied: a typed draft and staged
    // attachments belong to the user, not to the profile, and unlike "New session" the
    // switch is not a request to clear them.
    var replacement = newChat(for: home, composerText: chat.composerText)
    replacement.attachments = chat.attachments
    return teardownSlot(thenFill: replacement)
  }

  /// Whether the slot's chat is ALREADY the fresh, WORKING new chat the list would seat right
  /// now: an `isDiscardableNewChat` (the shared seat predicate — see `ChatFeature.State`)
  /// under the list's currently-selected profile, with no surfaced failure. "New session"
  /// over such a seat resets the composer instead of redialling.
  ///
  /// The banner clause is what keeps the shortcut honest: a seat whose `session.create`
  /// failed keeps `liveSessionID == nil` with `hasRequestedSession` still true, so it can
  /// neither send nor retry until the socket drops — a composer reset would leave the user
  /// tapping "New session" on a dead chat. Any other banner sends it down the same real
  /// refill, which costs one redial and clears the failure.
  ///
  /// The connection is deliberately NOT compared: it is not part of "which chat the list
  /// would seat", and a same-user re-auth refreshes the list's copy alongside the chat's.
  private static func isReusableNewChat(
    _ chat: ChatFeature.State, for home: SessionListFeature.State
  ) -> Bool {
    chat.isDiscardableNewChat && chat.profileName == home.scopedProfileName
      && chat.errorBanner == nil
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

  /// Landing on a freshly built session list (launch probe, retry screen, manual login).
  /// Two duties, ordered: consume the cold-launch tap stash — a replayed tap opens ITS
  /// session into the slot — and, when nothing replays, seat the regular-width detail
  /// column with a fresh new chat (`fillNewChatIfDetailEmpty`). Replay decides first so a
  /// replayed tap never has to tear an unused new chat down on its way in.
  ///
  /// Replay (#46): a tap dropped while `home` was nil is
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
  private func landOnHome(_ state: inout State) -> Effect<Action> {
    guard let tap = state.pendingPushTap else {
      fillNewChatIfDetailEmpty(&state)
      return .none
    }
    let origin = state.pendingPushTapServerURL
    state.pendingPushTap = nil
    state.pendingPushTapServerURL = nil
    if let origin, let connected = state.home?.connection.baseURL,
       !Self.isSameServer(origin, connected) {
      // Dropped, not replayed — nothing will fill the slot, so seat the detail here.
      fillNewChatIfDetailEmpty(&state)
      guard !state.pendingApprovalSessionIDs.isEmpty else { return .none }
      state.pendingApprovalSessionIDs.removeAll()
      return setBadge(state)
    }
    // The replayed tap's `openSession` fills the slot (marker only in compact).
    return .send(.pushTapped(tap))
  }

  /// A fresh new chat under the list's connection and currently-selected profile — the ONE
  /// construction behind every new-chat fill ("new session", the regular-width detail seat
  /// on list appearance / layout change / post-archive-delete refill), so they cannot drift.
  private func newChat(
    for home: SessionListFeature.State, composerText: String = ""
  ) -> ChatFeature.State {
    ChatFeature.State(
      connection: home.connection,
      profileName: home.scopedProfileName,
      composerText: composerText
    )
  }

  /// Seat the detail column when it would otherwise be blank (landing on a fresh list,
  /// widening). No-op when the slot is already filled; `detailRefill` is the one rule for
  /// what the regular-width seat is. The slot was nil, so the detail `ChatView` is created
  /// fresh and its `.task` dials — no reducer-side dial needed (see `seatLiveChat`).
  private func fillNewChatIfDetailEmpty(_ state: inout State) {
    guard state.liveChat == nil, let seat = detailRefill(state) else { return }
    seatLiveChat(seat, into: &state)
  }

  /// The regular-width detail seat for the current list — a fresh new chat under its
  /// connection and selected profile — or `nil` in compact, where the stack shows the list
  /// and an empty slot is exactly right. The ONE rule behind every seat: the landing fill,
  /// the widening fill, the post-archive/delete refill (`teardownSlot(thenFill:)`), and the
  /// different-user re-auth reseat.
  private func detailRefill(_ state: State) -> ChatFeature.State? {
    guard state.layout == .regular, let home = state.home else { return nil }
    return newChat(for: home)
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
  /// contents (rather than appending) can't stack duplicates. The marker is COMPACT-ONLY:
  /// in regular the slot is the detail column, so the path is left empty — a marker there
  /// would render the chat in the sidebar stack as well.
  ///
  /// State only — this does NOT start the chat's socket, so it may be called directly only
  /// where the slot was NIL and SwiftUI therefore creates a view whose `.task` dials. Every
  /// non-nil→non-nil replacement must go through the `.fillLiveChat` ACTION instead, which
  /// wraps this and adds the regular-width dial.
  private func seatLiveChat(_ chat: ChatFeature.State, into state: inout State) {
    state.liveChat = chat
    state.path.removeAll()
    if state.layout == .compact {
      state.path.append(ChatScreen.State(sessionKey: chat.sessionKey))
    } else {
      // Regular has no marker to give the incoming chat a new view — `slotGeneration` does
      // (`AppView` keys the detail column's `ChatView` on it).
      state.slotGeneration &+= 1
    }
  }

  /// The prefilled-onboarding landing for a connection that needs *editing* rather than
  /// retrying: token mode prefills both fields so the user can fix them; cookie and bearer
  /// mode prefill only the URL (neither a password nor a browser leg is persistable), so the
  /// user re-authenticates. Shared by the launch auth-failure fallback and the retry screen's
  /// `.credentialsRejected` delegate, so onboarding is constructed in exactly one place.
  ///
  /// Only the bearer regime has an effect: this is a verdict that the stored pair is DEAD, so
  /// the token store is drained — leaving it seeded would authenticate the next request with
  /// credentials the server just rejected. The Keychain entry is deliberately left alone (the
  /// "nothing cleared" rule of #62); a re-login through onboarding re-seeds and overwrites it.
  private func fallBackToOnboarding(
    _ state: inout State, connection: ServerConnection
  ) -> Effect<Action> {
    state.onboarding = ConnectionFeature.State(
      serverURL: connection.baseURL.absoluteString,
      token: connection.auth.token ?? ""
    )
    guard case .bearer = connection.auth else { return .none }
    return .run { [bearerTokens] _ in await bearerTokens.clear() }
  }

  /// Release the slot's microphone when an identity teardown (Settings "disconnect", either
  /// logout, a different-user re-auth) drops the chat by ASSIGNMENT instead of through
  /// `teardownSlot`. `ifLet`'s auto-cancel on the nil-out reaches every child EFFECT — the
  /// level stream and the tick loop included — but not the resource the client holds outside
  /// them: `AudioRecorderClient` keeps `AVAudioRecorder` and the audio session alive until
  /// someone calls `cancel()`, which is what `ChatFeature.teardown` would have done. The
  /// split sidebar (#80) puts Settings on screen next to a recording composer, so this is
  /// reachable without ever leaving the chat. No slot, or an idle one → no effect.
  private func releaseSlotMic(_ state: State) -> Effect<Action> {
    guard state.liveChat?.recording.isBusy == true else { return .none }
    return .run { [audioRecorder] _ in await audioRecorder.cancel() }
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
  /// URL, the matching auth regime, and the identity baseline the same-user vs user-switch
  /// decision reads — the prefilled username in cookie mode, the dead pair's `user_id` in
  /// bearer mode (OAuth has no username to prefill; the browser leg reports who signed in).
  ///
  /// `oauthProviders` is the last capability probe's list, used only to put the server's
  /// human display name on the "Continue with …" button; an empty list (the common case
  /// after a launch auto-restore, which never probes) falls back to the wire provider name
  /// through `State.providerLabel`.
  private func makeReauthState(
    for connection: ServerConnection,
    oauthProviders: [AuthProvider] = []
  ) -> ReauthFeature.State {
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
    case let .bearer(session):
      return ReauthFeature.State(
        serverURL: connection.baseURL,
        method: .oauth,
        provider: session.provider,
        providerDisplayName: oauthProviders
          .first { $0.name == session.provider }?.displayName ?? "",
        previousUserID: session.userID
      )
    }
  }

  /// Install a restored/refreshed bearer pair in the token store, with the Keychain save as
  /// the persist hook so a rotation performed inside the actor is written back. A no-op for
  /// the other two regimes. Static (and dependency-taking) because it runs inside `@Sendable`
  /// effect closures, where the reducer `self` is not `Sendable`.
  private static func seedBearerStore(
    _ auth: AuthSession,
    baseURL: URL,
    keychain: KeychainClient,
    store: BearerTokenStore
  ) async {
    guard case let .bearer(bearer) = auth else { return }
    await store.seed(bearer, baseURL: baseURL) { rotated in
      try keychain.saveSession(.bearer(rotated))
    }
  }

  /// The effect form of `seedBearerStore` for a freshly re-authenticated connection — `.none`
  /// for token/cookie, so the two older regimes' routing is byte-identical.
  private func reseedBearerStore(for connection: ServerConnection) -> Effect<Action> {
    guard case .bearer = connection.auth else { return .none }
    return .run { [keychain, bearerTokens] _ in
      await Self.seedBearerStore(
        connection.auth, baseURL: connection.baseURL, keychain: keychain, store: bearerTokens
      )
    }
  }

  /// The server-side half of a logout, in the ONE order that works — shared by all three
  /// logout paths (`connectionFailed.logoutConfirmed`, `reauth.quit`, `.disconnect`) so they
  /// cannot drift apart.
  ///
  /// Both hops are best-effort and both need the credentials that are about to die, hence
  /// `.concatenate` rather than `.merge`: persistence is detached, the push unregister
  /// authenticates like any other REST call (through the token store in bearer mode), then
  /// `rest.logout` runs, and only then is the store drained. Draining first would make BOTH
  /// requests silent no-ops — `resolveAuth` has nothing to resolve — which is exactly the
  /// trap Task 6 documented on `HermesRESTClient.logout`.
  ///
  /// The leading `detachPersistence` is what keeps that ordering safe: every caller has
  /// already deleted the Keychain session synchronously, and either hop can rotate a pair
  /// that is inside its refresh leeway — whose persist hook would write the entry straight
  /// back, leaving a dead pair to be restored on the next launch.
  private func serverSideLogout(connection: ServerConnection?) -> Effect<Action> {
    // Called for its synchronous prefs clearing too, so it must run unconditionally.
    let unregister = unregisterPushOnLogout(connection: connection)
    guard let connection, case .bearer = connection.auth else { return unregister }
    return .concatenate(
      .run { [bearerTokens] _ in await bearerTokens.detachPersistence() },
      unregister,
      .run { [rest, bearerTokens] _ in
        await rest.logout(connection)
        await bearerTokens.clear()
      }
    )
  }
}
