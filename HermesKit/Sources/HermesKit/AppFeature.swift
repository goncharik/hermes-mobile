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
    /// via `.ifLet`, so its socket, reconnect backoff, turn ticker, and debounced
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
    /// agent whose push plugin this device registered with). Kept when an App Intent
    /// supersedes the tap, so the landing still scrubs foreign approval badge entries. Guards
    /// the replay — a login that targets a DIFFERENT server drops the stash instead of
    /// resuming a foreign session id there (the resume self-heal would silently create a spurious empty
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
    /// An App Intent launch request (#93) that arrived before the session list existed — the
    /// cold-launch Action button / Siri / Shortcuts case, where `home` only appears once the
    /// auto-connect probe (or a manual login) finishes. Same shape as `pendingPushTap`: single
    /// stash, last-wins, replayed in `landOnHome` (the launch action — dictation / camera /
    /// photos — only on the launch auto-connect landing), process-lifetime only, cleared on every logout path. Last-wins ACROSS both
    /// stashes too: stashing an intent clears the tap stash and vice versa, so the landing
    /// replays only the most recent request. A new chat belongs to no session, so it is valid
    /// on whatever server the user signs into; an `.openSession` (a widget / Live Activity tap)
    /// names a session, so it carries `pendingLaunchIntentServerURL`.
    var pendingLaunchIntent: LaunchIntent?
    /// The server a stashed `.openSession` intent belongs to: the persisted server URL at stash
    /// time (the server whose sessions the widget mirror showed). Same guard as
    /// `pendingPushTapServerURL` — a login to a DIFFERENT server drops the open instead of
    /// resuming a foreign session id there. `nil` for the new-chat intents (no session to
    /// guard) and when no URL was stored (the replay then proceeds unverified).
    var pendingLaunchIntentServerURL: URL?
    /// The "Show session titles" pref for the Live Activity: off omits the headline title
    /// from the activity content (the Home Screen widgets keep it). Part of `agentStatus`,
    /// so flipping it updates the activity through the one edge.
    public var liveActivityShowsTitles = true
    /// The "Live Activity" pref (#138): off ends the activity and starts none. Seeded from
    /// `PreferencesClient` at every landing; the Settings toggle persists it and reports the
    /// change (`liveActivityToggled`).
    public var liveActivityEnabled = true
    /// The aggregate Live Activity this process started, or `nil` when none is up. Its `id` is
    /// `nil` while the start request is in flight (`liveActivityStarted` adopts it), so a second
    /// change can never start a second activity.
    var liveActivity: LiveActivitySeat?
    /// How many start requests this process sent: the next seat's `request` token.
    var liveActivityRequests = 0
    /// The live slot's session when a turn-complete / error push reported it over while the app
    /// was backgrounded (`deliveredPushReceived`): the slot's running flag is stale with the
    /// socket down, so the surfaces read it as not working while its id is here. (The push
    /// patches the list row directly; the next fetch overwrites that with server truth.) Goes
    /// on the slot's next `runningChanged` for it — fresher evidence either way, and how every
    /// new turn starts — on any slot change (`clearLiveChat`, `seatLiveChat`), and on every
    /// logout / user switch. A set only so the projection's input stays plain.
    var pushFinishedSessionIDs: Set<String> = []
    /// The running Live Activity's ActivityKit id (`nil` while none is up or its start is
    /// still in flight).
    var liveActivityID: String? { liveActivity?.id }
    /// Until when the widget mirror may vouch for working / needs-input while backgrounded:
    /// stamped by the `.background` edge (`now` + the running slot's ~30 s grace + a margin)
    /// and reused by every write until `.active` clears it, so a change during the grace can't
    /// extend the promise past what the app can still observe. `nil` in the foreground, and
    /// when the edge found nothing to mirror (`agentStatus == nil` — the unknown edge already
    /// shortened the surfaces' promise).
    var backgroundFreshUntil: Date?

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

    /// Sessions whose list card shows the needs-input status dot: an approval push this
    /// device hasn't opened yet, plus the live chat while an approval / clarify / secret card
    /// is up. The list has no live events for other sessions, so this is what mobile knows.
    public var needsInputSessionIDs: Set<String> {
      var ids = pendingApprovalSessionIDs
      if let chat = liveChat, chat.pendingInteraction != nil, let key = chat.sessionKey {
        ids.insert(key)
      }
      return ids
    }

    /// What the widgets and the aggregate Live Activity show (`AgentStatusProjection`), or
    /// `nil` ("unknown" — hold, never end) while signed out or before the list's first
    /// unfiltered fetch (of the process, or since a profile switch reset the rows).
    public var agentStatus: AgentStatusProjection? { agentStatusInputs?.projection }

    /// What `agentStatus` is built from — the cheap key the surfaces edge watches, so the
    /// projection is only built when an input moved (not on every streaming frame). The live
    /// slot's running flag overrides its row only when the slot is in the list's profile (the
    /// same rule as the row-glow patch): another profile's id can't be in these rows. A slot
    /// the list doesn't carry yet (a new chat) brings its own row, titled by its first prompt.
    var agentStatusInputs: AgentStatusInputs? {
      guard let home, let sessions = home.statusSessions else { return nil }
      var inputs = AgentStatusInputs(
        connection: home.connection,
        sessions: sessions,
        needsInput: needsInputSessionIDs,
        showsTitles: liveActivityShowsTitles,
        profile: home.scopedProfileName,
        finishedByPush: pushFinishedSessionIDs
      )
      if let chat = liveChat, let key = chat.sessionKey,
        AppFeature.isSameProfile(home.scopedProfileName, chat.profileName) {
        inputs.slotID = key
        inputs.slotRunning = chat.isRunning
        if sessions[id: key] == nil {
          inputs.slotSession = Session(
            id: key, title: chat.title, preview: chat.firstUserMessageText
          )
        }
      }
      return inputs
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

    /// Whether the Home Screen quick actions (#93) are offered: whenever a stored session is
    /// presumed good (the launch probe, the retry screen, home), never on onboarding. A probe
    /// that ends in a credentials verdict lands on onboarding and hides them again.
    var offersQuickActions: Bool { rootScreen != .onboarding }
  }

  /// The aggregate Live Activity as `AppFeature` last drove it (#138).
  struct LiveActivitySeat: Equatable, Sendable {
    /// ActivityKit's id; `nil` while the start request is in flight.
    var id: String?
    /// The content last sent (start or update): the dedupe for the edge's updates and the
    /// headline the final "Done" content keeps.
    var content: AgentActivityContent
    /// Which start request took this seat (`State.liveActivityRequests`), so a request that
    /// lands for a seat it didn't take — a fast toggle off→on — is ended, never adopted.
    var request: Int
  }

  /// `State.agentStatusInputs`: everything `AgentStatusProjection.make` reads, plus the list's
  /// connection (an unknown projection under the SAME list is a profile switch; under a new
  /// one, a different-user re-auth that already cleared the surfaces).
  struct AgentStatusInputs: Equatable, Sendable {
    var connection: ServerConnection
    var sessions: IdentifiedArrayOf<Session>
    var needsInput: Set<String>
    var slotID: String?
    var slotRunning = false
    var slotSession: Session?
    var showsTitles: Bool
    var profile: String?
    var finishedByPush: Set<String> = []

    var projection: AgentStatusProjection {
      AgentStatusProjection.make(
        sessions: Array(sessions),
        needsInput: needsInput,
        slotRunning: slotID.map { ($0, slotRunning) },
        slotSession: slotSession,
        showsTitles: showsTitles,
        profile: profile,
        finishedByPush: finishedByPush
      )
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
    /// A push was delivered to the running app (the gateway's `content-available` wake, #138).
    /// While backgrounded, a turn-complete / error push marks its session finished
    /// (`pushFinishedSessionIDs`) and the Live Activity syncs at once — it is the only news the
    /// app gets with its socket down. Ignored in the foreground, where the app observes itself.
    case deliveredPushReceived(PushTap)
    /// An App Intent asked for a new chat (#93) — routed through the exact "New session" path
    /// (`reduceCreateSession`: selected-profile scoping, the reusable-seat shortcut, compact
    /// marker vs regular detail, a busy slot replaced through `teardownSlot(thenFill:)`). With
    /// no session list yet (cold launch) it is stashed in `pendingLaunchIntent` and replayed
    /// by `landOnHome`.
    case launchIntentReceived(LaunchIntent)
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
    /// Internal: outcome of a chat ⋯ menu Archive/Delete the parent ran on the slot's
    /// behalf (`ChatFeature.Delegate.removeSession`). `failure == nil` = server confirmed.
    case sessionRemovalFinished(ChatFeature.Action.Delegate.SessionRemoval, failure: RESTError?)
    /// Internal: the finite background window (`BackgroundTaskClient`) expired while still
    /// backgrounded — final flush, then disconnect the socket cleanly
    /// (`.teardownSocketOnly`), keeping the chat state in memory for the #26-preserving
    /// foreground re-hydrate.
    case backgroundGraceExpired
    case reauth(PresentationAction<ReauthFeature.Action>)
    /// Internal: the debounced Live Activity update / end fell due.
    case liveActivitySyncDue
    /// Internal: ActivityKit accepted start request `request` (the seat's token).
    case liveActivityStarted(id: String, request: Int)
    /// Internal: ActivityKit refused start request `request` (already debug-logged; no banner).
    case liveActivityStartFailed(request: Int)
  }

  /// Ids for the long-running incoming-tap and launch-intent observers, the
  /// background-grace listener, the chat menu's session removals, the widget-mirror write and
  /// the Live Activity's debounced update / end (both debounced, last-wins).
  private enum CancelID {
    case backgroundGrace, launchIntents, pushTaps, pushDeliveries, sessionRemovals, mirrorSync
    case liveActivitySync
  }

  /// How `syncLiveActivity` applies the projection to the activity.
  private enum LiveActivitySync {
    /// The `agentStatus` edge: a start goes out at once (the user may background the app any
    /// moment, and a start is foreground-only); an update or end waits out
    /// `surfacesSyncDebounce`, so a turn ending right before the next queued one starts updates
    /// the activity instead of ending and restarting it.
    case debounced
    /// Apply now; an update whose content didn't change is skipped.
    case immediate
    /// Apply now and always update: a scene edge moved the stale date.
    case restamp
  }

  /// How long an ended activity keeps its final "Done" content on the Lock Screen.
  static let liveActivityDismissal: TimeInterval = 5 * 60

  /// How long a foreground mirror write vouches for its rows: the app observes the list for
  /// as long as it stays in the foreground, so this only bounds a crash / kill that skips
  /// the `.background` restamp.
  static let foregroundFreshness: TimeInterval = 8 * 60 * 60
  /// The background restamp: the running slot's ~30 s grace window (`BackgroundTaskClient`)
  /// when there is one, plus a margin for the suspension itself.
  static let backgroundGraceFreshness: TimeInterval = 30
  static let backgroundFreshnessMargin: TimeInterval = 10
  /// Coalesces a burst of `agentStatus` changes (a list fetch landing next to a slot's
  /// running flip) into one mirror write + timeline reload.
  static let surfacesSyncDebounce: Duration = .seconds(1)

  /// Name of the finite background task requested while a running turn is backgrounded
  /// (shows up in OS background-task diagnostics). Tests re-type the literal on purpose —
  /// an accidental rename should fail the suite, not silently follow the constant.
  private static let backgroundGraceTaskName = "hermes.chat.background-grace"

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.hermesREST) var rest
  @Dependency(\.push) var push
  @Dependency(\.launchIntents) var launchIntents
  @Dependency(\.quickActions) var quickActions
  @Dependency(\.backgroundTask) var backgroundTask
  @Dependency(\.chatSnapshot) var chatSnapshot
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.widgetMirror) var widgetMirror
  @Dependency(\.liveActivity) var liveActivity
  @Dependency(\.date) var date
  @Dependency(\.continuousClock) var clock
  // Only for `releaseSlotDeviceResources` — what a dropped slot holds outside its effects.
  @Dependency(\.audioRecorder) var audioRecorder
  @Dependency(\.idleTimer) var idleTimer
  @Dependency(\.filePreview) var filePreview
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
        // App Intent launch requests (#93), observed the same way — an intent can raise the
        // app cold or while it runs; the routing happens in `.launchIntentReceived`.
        let intentObserver: Effect<Action> = .run { [launchIntents] send in
          for await intent in launchIntents.incoming() {
            await send(.launchIntentReceived(intent))
          }
        }
        .cancellable(id: CancelID.launchIntents, cancelInFlight: true)
        // Pushes delivered to the running app (#138), for the Live Activity / widgets.
        let deliveryObserver: Effect<Action> = .run { [push] send in
          for await delivered in push.deliveredPushes() {
            await send(.deliveredPushReceived(delivered))
          }
        }
        .cancellable(id: CancelID.pushDeliveries, cancelInFlight: true)
        let observers: Effect<Action> = .merge(tapObserver, intentObserver, deliveryObserver)
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
        else { return observers }
        // A `.token` session with an empty token is treated as "no creds" (matches the old
        // `loadToken()`-non-empty guard) so we stay on onboarding rather than probe blindly.
        if case .token("") = session { return observers }
        state.didRunLaunchProbe = true
        state.autoConnecting = true
        let connection = ServerConnection(baseURL: url, auth: session)
        return .merge(
          observers,
          .run { [rest, keychain, bearerTokens] send in
            // Bearer restore (#19) must happen BEFORE the probe: a `.bearer` connection
            // resolves its `Authorization` header through the token store, so probing an
            // unseeded store sends the request with no credentials at all and 401s a
            // perfectly good session into prefilled onboarding. Seeding also re-arms the
            // Keychain persist hook, so a rotation during the probe is saved.
            Self.seedBearerStore(session, baseURL: url, keychain: keychain, store: bearerTokens)
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent, .all)
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
        return landOnHome(&state, replaysLaunchAction: true)

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
        return landOnHome(&state, replaysLaunchAction: false)

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
        let releaseSlot = releaseSlotDeviceResources(state)
        bearerTokens.detachPersistence() // BEFORE the delete — see `detachPersistence`
        try? keychain.deleteSession()
        preferences.clearServerURL()
        preferences.clearIdentityScopedPrefs()
        preferences.saveDefaultSessionSwipeAction(.default)
        preferences.clearAutoSpeakReplies()
        preferences.clearModelPickerPrefs()
        preferences.clearLiveActivityPrefs()
        preferences.clearOwnedAgentUpdate(nil)
        preferences.clearOnboardingTipsDismissed() // the next sign-in shows the tips again (#136)
        debugLog.clear()
        state.connectionFailed = nil
        state.path = .init()
        state.liveChat = nil
        state.home = nil
        state.onboarding = .init()
        state.pendingPushTap = nil
        state.pendingPushTapServerURL = nil
        state.pendingLaunchIntent = nil
        state.pendingLaunchIntentServerURL = nil
        state.pendingApprovalSessionIDs = []
        state.pushFinishedSessionIDs = []
        return .merge(
          releaseSlot, setBadge(state), clearSurfaces(&state),
          serverSideLogout(connection: connection), .cancel(id: CancelID.sessionRemovals)
        )

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
          let wasBackgrounded = state.isSceneBackgrounded
          state.isSceneBackgrounded = false
          state.backgroundFreshUntil = nil
          // Back from the background, the app observes again: restamp the mirror and the Live
          // Activity with the foreground freshness so the "Outdated" the background edge
          // scheduled doesn't fire under a live app, and start the activity if agents are
          // active without one — including when the one up was swiped away or timed out
          // meanwhile (its seat is dropped). A brief `.active` (Control Center, the
          // notification shade) never left the foreground freshness: nothing to restamp.
          var surfaces: Effect<Action> = .none
          if wasBackgrounded {
            if let id = state.liveActivity?.id, !liveActivity.isActive(id) {
              state.liveActivity = nil
            }
            let status = state.agentStatus
            surfaces = .merge(
              syncMirror(status, state, debounced: false),
              syncLiveActivity(status, &state, .restamp)
            )
          }
          return .merge(
            surfaces,
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
          // The widgets may vouch for working / needs-input only as long as the app can still
          // observe: the grace window of a running slot plus a margin. Written NOW, not
          // debounced — an idle app may be suspended within seconds.
          var surfaces: Effect<Action> = .none
          // An unknown projection has nothing to stamp: going unknown already shortened both
          // surfaces to the margin (the `agentStatusInputs` edge).
          if let status = state.agentStatus {
            var freshFor = Self.backgroundFreshnessMargin
            if state.liveChat?.isRunning == true { freshFor += Self.backgroundGraceFreshness }
            state.backgroundFreshUntil = date.now.addingTimeInterval(freshFor)
            // The Live Activity goes "Outdated" at the same instant (`staleDate`); no start
            // from here — `Activity.request` is foreground-only.
            surfaces = .merge(
              syncMirror(status, state, debounced: false),
              syncLiveActivity(status, &state, .restamp)
            )
          }
          guard let chat = state.liveChat else { return surfaces }
          // Read aloud (#74): no background audio — stop the clip first, idle AND running
          // slots alike (the grace below keeps a running turn's process, and so the player,
          // alive), and hold auto-speak until `.foreground`.
          let flush: Effect<Action> = .concatenate(
            .send(.liveChat(.sceneBackgrounded)),
            .send(.liveChat(.persistNow))
          )
          // A RUNNING turn buys itself a finite background window (~30s): the socket simply
          // keeps streaming, no `ChatFeature` changes. If iOS expires the window while still
          // backgrounded, the listener fires `.backgroundGraceExpired` → final flush + clean
          // socket-only disconnect (state stays in memory for the #26-preserving foreground
          // hydrate); catch-up is then the existing push + `.foreground` reconnect. An idle
          // chat starts NO task — nothing to keep alive, no battery burn.
          guard chat.isRunning else { return .merge(surfaces, flush) }
          return .merge(
            surfaces,
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
        // preserve the live reasoning/tool rows (#26). No explicit `end()` here: the client
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

      case let .launchIntentReceived(intent):
        guard state.home != nil else {
          // No session list yet (cold launch still auto-connecting, or on onboarding / the
          // retry screen) — stash for `landOnHome`, never drop: the Action button from a cold
          // start is the main use case. Last-wins across both stashes, so a tap that came
          // earlier no longer replays. Its origin URL is kept: the landing's cross-server
          // guard still scrubs that tap's approval badge entry on a foreign login. An
          // `.openSession` records its own origin, guarded the same way at the landing.
          state.pendingLaunchIntent = intent
          if case .openSession = intent {
            state.pendingLaunchIntentServerURL = preferences.loadServerURL()
              .flatMap(parseServerURL)
          } else {
            state.pendingLaunchIntentServerURL = nil
          }
          state.pendingPushTap = nil
          return .none
        }
        // Unlike the button, an intent can arrive over a list sheet: dismiss them so the chat
        // it opens is what the user sees.
        state.home?.dismissPresentations()
        if case let .openSession(id, profile) = intent {
          // A widget / Live Activity row: the push-tap routing (#32 — in place, re-attach, or
          // replace, never stack), without a push tap's approval bookkeeping.
          return reduceOpenSessionRouting(
            &state, sessionID: id, profile: profile, armsApprovalHint: false
          )
        }
        // Behind the re-auth modal the chat still seats (it resumes with the re-auth), but
        // never with a hot mic or a picker the user can't see.
        return reduceCreateSession(
          &state,
          composerText: nil,
          launchAction: state.reauth == nil ? intent.launchAction : nil
        )

      case let .onboarding(.delegate(.connected(connection))):
        // Defensive, mirroring `.autoConnectSucceeded`: a retry screen and a live list must
        // never coexist. `AppView` would render `home` while the `ifLet` child stayed alive,
        // re-probing on every foreground for the process lifetime.
        state.connectionFailed = nil
        state.home = makeHomeState(connection: connection)
        // Auto-connect failure falls back to onboarding, so a manual login must also replay
        // a stashed cold-launch tap (#46).
        return landOnHome(&state, replaysLaunchAction: false)

      case let .home(.delegate(.openSession(session))):
        guard let home = state.home else { return .none }
        // Carry the active profile so resume/history scope to the right `state.db`.
        return reduceOpenSession(&state, session: session, profileName: home.scopedProfileName)

      case let .home(.delegate(.createSession(initialComposerText))):
        return reduceCreateSession(
          &state, composerText: initialComposerText, launchAction: nil
        )

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
        // remaining child effects on the nil-out; what the slot holds outside its effects (mic,
        // idle timer, a presented preview's finished download) is released here, read BEFORE
        // the assignment.
        let release = releaseSlotDeviceResources(state)
        state.liveChat = nil
        // A push's "finished" mark only ever overrides this slot's stale flag (#138).
        state.pushFinishedSessionIDs = []
        return release

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
        // Deliberate asymmetry: if the archive PATCH later FAILS, the list restores the
        // row (optimistic rollback) but the slot stays torn down — re-opening simply
        // resumes the session fresh. Resurrecting live slot state for a rare failure path
        // isn't worth replaying the teardown.
        return closeRemovedSession(&state, id: id, isDelete: false)

      case let .home(.delegate(.sessionDeleted(id))):
        // The user permanently deleted a session. ALWAYS wipe its cached snapshot + turn
        // anchor — a deleted session must never repaint from the non-authoritative cache.
        // When it's the slot's session (possibly detached mid-turn), tear the live chat
        // down too, WITHOUT the snapshot flush (`flushSnapshot: false`): the flush would
        // re-save the very snapshot this wipe deletes. Same deliberate asymmetry as
        // archive: if the DELETE later fails, the list restores the row but the slot and
        // cache stay cleared — re-opening simply resumes the session fresh.
        return closeRemovedSession(&state, id: id, isDelete: true)

      case let .home(.delegate(.sessionDeleteSucceeded(id))):
        // The server CONFIRMED the delete — only now drop the session's pending-approval
        // badge entry (opening the session, the normal clear path, no longer exists).
        // Clearing at initiation (`sessionDeleted` above) would be premature: a failed
        // DELETE restores the row, but its still-pending approval would badge nowhere —
        // nothing short of a fresh approval push repopulates the entry. Unlike the
        // wipe/teardown asymmetry above, the badge waits for confirmation.
        return clearDeletedSessionBadge(&state, id: id)

      case .home(.delegate(.disconnect)):
        // Token cleared in Settings → tear down and return to onboarding. Nil-ing the slot
        // auto-cancels its effects (socket included); the mic and the idle timer outlive
        // them, so `releaseSlotDeviceResources` covers those. The tap stash is structurally
        // nil here (home existed, so any stash was consumed at creation) — cleared
        // defensively: the stash dies with the identity. The pending-approval badge set dies
        // with it too (entries reference sessions on the server just left — they'd leak a
        // stale icon badge into the next login), so reset the badge to zero.
        let connection = state.home?.connection
        let releaseSlot = releaseSlotDeviceResources(state)
        state.path = .init()
        state.liveChat = nil
        state.home = nil
        state.onboarding = .init()
        state.pendingPushTap = nil
        state.pendingPushTapServerURL = nil
        state.pendingLaunchIntent = nil
        state.pendingLaunchIntentServerURL = nil
        state.pendingApprovalSessionIDs = []
        state.pushFinishedSessionIDs = []
        return .merge(
          releaseSlot, setBadge(state), clearSurfaces(&state),
          serverSideLogout(connection: connection), .cancel(id: CancelID.sessionRemovals)
        )

      case .liveChat(.delegate(.sessionExpired)):
        // The live (gated) session died — attached or detached, the slot is the one chat.
        // The chat already paused its own reconnect; raise the re-auth modal seeded from its
        // connection (server URL + regime + identity). Ignore if a modal is already up.
        guard state.reauth == nil, let chat = state.liveChat else { return .none }
        state.reauth = makeReauthState(
          for: chat.connection,
          // Whatever the onboarding screen last probed — empty after a launch auto-restore,
          // which `providerLabel` handles by falling back to the wire provider name.
          oauthProviders: state.onboarding.lastProbedCapability?.oauthProviders ?? []
        )
        return .none

      case let .reauth(.presented(.delegate(.reauthenticated(connection, sameUser)))):
        state.reauth = nil
        // NO bearer reseed here. `performNativeOAuthLogin` already put the fresh pair in the
        // store (that is what the sheet's validating call authenticated with), and by now the
        // store may hold a ROTATION of it that `connection` — captured when the sheet
        // finished — does not. Re-seeding the captured pair would put a retired refresh token
        // back in play, and the portal answers a replayed refresh token by revoking the
        // session. The store owns the pair; this reduction only routes the connection.
        if sameUser {
          // Same user → adopt the fresh auth regime EVERYWHERE the app still holds the dead
          // one. The list's connection is the snapshot every later chat is built from (a row
          // tap, the regular-width archive/delete refill, the profile reseat) and the one its
          // own REST calls carry: left stale it would reconnect under expired credentials
          // and, in cookie mode, push that dead jar back into the transport's shared cookie
          // storage (`wsTicket` rehydrates it), undoing the login that just succeeded.
          state.home?.connection = connection
          // Then resume the dead slot chat in place.
          guard state.liveChat != nil else { return .none }
          return .send(.liveChat(.resumeAfterReauth(connection)))
        }
        // Different user signed in → drop everything identity-scoped and force a fresh list.
        // (`makeHomeState` reads the profile pref AFTER the clear, so it seeds defaults.)
        // The approval badge set + tap stash are identity-scoped too — the old user's
        // pending approvals must not badge (or replay into) the new user's list.
        preferences.clearIdentityScopedPrefs()
        let releaseSlot = releaseSlotDeviceResources(state)
        state.path = .init()
        state.liveChat = nil
        state.pendingPushTap = nil
        state.pendingPushTapServerURL = nil
        state.pendingLaunchIntent = nil
        state.pendingLaunchIntentServerURL = nil
        state.pendingApprovalSessionIDs = []
        state.pushFinishedSessionIDs = []
        state.home = makeHomeState(connection: connection)
        // The mirror shows the previous user's sessions: clear it like a logout; the new
        // list's first fetch writes the new user's rows through the `agentStatus` edge.
        let identityCleanup: Effect<Action> = .merge(
          releaseSlot, setBadge(state), clearSurfaces(&state),
          .cancel(id: CancelID.sessionRemovals)
        )
        // The stash was just cleared, so there is nothing to replay — but in regular the new
        // user's detail column still needs its fresh new chat. Routed through the `.fillLiveChat`
        // ACTION, never a direct fill: this reduction must END with the slot nil so `ifLet`
        // cancels the expired chat's remaining effects (a non-nil→non-nil swap compares equal
        // and cancels nothing), and the action is what starts the replacement's socket.
        guard let seat = detailRefill(state) else { return identityCleanup }
        return .merge(identityCleanup, .send(.fillLiveChat(seat)))

      case .reauth(.presented(.delegate(.quit))):
        // "Quit to start" → full logout (Keychain session + every pref) → onboarding.
        // The tap stash and the approval badge set die with the identity (same clears
        // as `.disconnect`, through the other logout path); badge reset to zero.
        let connection = state.home?.connection ?? state.liveChat?.connection
        let releaseSlot = releaseSlotDeviceResources(state)
        bearerTokens.detachPersistence() // BEFORE the delete — see `detachPersistence`
        try? keychain.deleteSession()
        preferences.clearServerURL()
        preferences.clearIdentityScopedPrefs()
        preferences.saveDefaultSessionSwipeAction(.default)
        preferences.clearAutoSpeakReplies()
        preferences.clearModelPickerPrefs()
        preferences.clearLiveActivityPrefs()
        preferences.clearOwnedAgentUpdate(nil)
        preferences.clearOnboardingTipsDismissed() // the next sign-in shows the tips again (#136)
        debugLog.clear()
        state.reauth = nil
        state.path = .init()
        state.liveChat = nil
        state.home = nil
        state.onboarding = .init()
        state.pendingPushTap = nil
        state.pendingPushTapServerURL = nil
        state.pendingLaunchIntent = nil
        state.pendingLaunchIntentServerURL = nil
        state.pendingApprovalSessionIDs = []
        state.pushFinishedSessionIDs = []
        return .merge(
          releaseSlot, setBadge(state), clearSurfaces(&state),
          serverSideLogout(connection: connection), .cancel(id: CancelID.sessionRemovals)
        )

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
        // A seedless (session-authority, #159) child lives in the SOURCE chat's profile, which
        // can differ from the sidebar's after a profile switch kept that chat open: resuming it
        // under the sidebar's profile would miss its state.db and start an unrelated session.
        let profile = creation.seed == nil
          ? (state.liveChat?.profileName ?? home.scopedProfileName)
          : home.scopedProfileName
        var chat = ChatFeature.State(
          connection: home.connection,
          resumeStoredID: creation.handle.storedSessionID,
          profileName: profile
        )
        // A session-authority branch (#159, no seed) is already a persisted copy: it opens by
        // stored id like any list row.
        if let seed = creation.seed {
          chat.attachLiveSessionID = creation.handle.sessionID
          chat.branchSeed = seed
        }
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
        // The slot reporting this session's running state again — a new turn, or a foreground
        // hydrate confirming the end — is fresher than a push's "finished" mark (#138).
        state.pushFinishedSessionIDs.remove(sessionID)
        let canPatchVisibleRow: Bool
        if let home = state.home, let chat = state.liveChat {
          canPatchVisibleRow = Self.isSameProfile(home.scopedProfileName, chat.profileName)
        } else {
          canPatchVisibleRow = false
        }
        let glow: Effect<Action> = canPatchVisibleRow
          ? .send(.home(.setSessionRunning(id: sessionID, running: running)))
          : .none
        // A completion that lands while this chat is on screen has already been seen. Advance
        // the shared backend watermark after the new activity, not just when the row was first
        // opened before the turn, so Desktop does not rediscover it as unread on its next poll.
        let read: Effect<Action>
        if !running,
          state.currentViewingSessionID == sessionID,
          let chat = state.liveChat {
          read = acknowledgeRead(
            &state,
            sessionID: sessionID,
            connection: chat.connection,
            profileName: chat.profileName
          )
        } else {
          read = .none
        }
        let listUpdate: Effect<Action> = .concatenate(glow, read)
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
        else { return listUpdate }
        return .concatenate(listUpdate, teardownSlot())

      case let .liveChat(.delegate(.removeSession(removal))):
        // The open chat's ⋯ menu Archive/Delete was CONFIRMED. The round-trip runs HERE,
        // not in the slot: navigating away or picking another chat clears `liveChat`, and
        // `.ifLet` would cancel a slot effect — a server-applied removal would then never
        // get its row/pin/seen/snapshot/badge cleanup (same reason the archived sheet's
        // DELETE runs in its parent list).
        return .run { [rest] send in
          do {
            switch removal.kind {
            case .archive:
              try await rest.archive(removal.connection, removal.id, true, removal.profileName)
            case .delete:
              try await rest.deleteSession(removal.connection, removal.id, removal.profileName)
            }
            await send(.sessionRemovalFinished(removal, failure: nil))
          } catch {
            await send(.sessionRemovalFinished(removal, failure: asRESTError(error)))
          }
        }
        // Cancelled by every logout / user switch: a reply landing after sign-in to another
        // account or server must not touch the new list (`sessionRemovalFinished` also drops
        // a reply whose server isn't the current one, should one slip through).
        .cancellable(id: CancelID.sessionRemovals)

      case let .sessionRemovalFinished(removal, .none):
        // Server-CONFIRMED: the list-removal contract through the SAME helpers the list's own
        // archive/delete use (`closeRemovedSession`, `clearDeletedSessionBadge`), so the two
        // paths can't drift. The slot is torn down synchronously FIRST — before any awaited
        // effect (`setBadge` awaits the notification center), so a chat opened during that
        // gap can never be the one torn down. Then the list drops the row and pin/seen.
        guard isCurrentServer(removal.connection, state) else { return .none }
        let id = removal.id
        let isDelete = removal.kind == .delete
        let close = closeRemovedSession(&state, id: id, isDelete: isDelete)
        let listUpdate: Effect<Action> = state.home == nil
          ? .none : .send(.home(.sessionRemovedElsewhere(id: id)))
        guard isDelete else { return .concatenate(close, listUpdate) }
        // Delete is already confirmed here, so the badge entry drops at once.
        return .merge(
          .concatenate(close, listUpdate),
          clearDeletedSessionBadge(&state, id: id)
        )

      case let .sessionRemovalFinished(removal, .some(error)):
        // The server kept the session. A missing-endpoint DELETE verdict is server-wide:
        // the list's Delete hides (the `onChange` below mirrors it onto the slot). The
        // failure goes back to the chat that asked while the slot still holds it (banner,
        // items re-enabled); with that chat gone it lands on the list instead, as the
        // archived sheet's orphaned delete failure does.
        // A reply for another server (a logout raced the cancellation) is dropped: its banner
        // and its 404/405 verdict belong to a list that no longer exists.
        guard isCurrentServer(removal.connection, state) else { return .none }
        let isDelete = removal.kind == .delete
        let verdict = isDelete && error.isMissingEndpointVerdict
        if verdict {
          state.home?.deleteSupported = false
        }
        // Routed on the chat's own in-flight id, not `sessionKey`: a #17 heal may have
        // recreated the session meanwhile, and the chat that asked must still get its items
        // back.
        if let chat = state.liveChat, chat.removingSessionID == removal.id {
          return .send(.liveChat(isDelete
            ? .deleteFailed(id: removal.id, error: error)
            : .archiveFailed(id: removal.id, error: error)))
        }
        if !verdict {
          state.home?.loadError = error.sessionMutationBanner(isDelete
            ? "Couldn’t delete the session." : "Couldn’t archive the session.")
        }
        return .none

      case let .home(.delegate(.liveActivityToggled(enabled))):
        return setLiveActivityEnabled(enabled, &state)

      case let .home(.delegate(.liveActivityShowsTitlesToggled(shows))):
        // Part of `agentStatus`: the edge below updates the activity with or without the title.
        state.liveActivityShowsTitles = shows
        return .none

      case .liveActivitySyncDue:
        return syncLiveActivity(state.agentStatus, &state, .immediate)

      case let .deliveredPushReceived(push):
        // Only the backgrounded app is blind (socket down, poll stopped); in the foreground the
        // slot's events and the poll already tell. Only a turn END is news the surfaces can act
        // on: the session stops counting as working, so the last one ends the activity "Done".
        guard state.isSceneBackgrounded, push.endsTurn, state.home != nil else { return .none }
        // A slot still on its live socket (the grace window) is the truth for its session: the
        // push for turn N can land after turn N+1 (a drained queue, another client) already
        // started there, and must not end it. Only a socket-less slot is blind.
        if let chat = state.liveChat, chat.sessionKey == push.sessionID, chat.status == .ready {
          return .none
        }
        debugLog.note("live.activity", "\(push.type ?? "push") ended \(push.sessionID)")
        // The slot's flag (stale, socket down) is overridden here; the list row is patched like
        // a slot event would (`setSessionRunning`). Then the activity syncs at once, not after
        // the edge's debounce: the wake is short. The edge still fires (the inputs moved) and
        // rewrites the mirror; its activity sync then finds nothing new.
        if state.liveChat?.sessionKey == push.sessionID {
          state.pushFinishedSessionIDs.insert(push.sessionID)
        }
        return .concatenate(
          .send(.home(.setSessionRunning(id: push.sessionID, running: false))),
          .send(.liveActivitySyncDue)
        )

      case let .liveActivityStarted(id, request):
        // Adopt the id only for the seat this request took. No seat (the toggle went off or
        // the user logged out mid-request) or another request's seat (a fast toggle off→on):
        // this activity is an orphan — end it at once.
        guard let seat = state.liveActivity, seat.id == nil, seat.request == request else {
          return .run { [liveActivity] _ in await liveActivity.end(id, nil, nil) }
        }
        state.liveActivity?.id = id
        // Catch up with whatever changed while the request was in flight (changes skip a seat
        // without an id). A background edge, or the projection going unknown, during the
        // request moved the stale date too.
        let status = state.agentStatus
        let restamp = state.isSceneBackgrounded || status == nil
        return syncLiveActivity(status, &state, restamp ? .restamp : .immediate)

      case let .liveActivityStartFailed(request):
        // Free the seat so the next change may try again; the failure is only debug-logged.
        if let seat = state.liveActivity, seat.id == nil, seat.request == request {
          state.liveActivity = nil
        }
        return .none

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
    // Home Screen quick actions only while signed in (#93): every sign-in lands on a
    // non-onboarding root and every logout or credentials verdict lands on onboarding, so this
    // one edge covers all of them. iOS persists the items, so a fresh process starting on
    // onboarding (initial value, no edge) got there through a logout that already cleared them.
    .onChange(of: \.offersQuickActions) { _, offers in
      Reduce { _, _ in
        quickActions.setItems(offers ? LaunchIntent.quickActions : [])
        return .none
      }
    }
    // The chat ⋯ menu's Delete follows the list's delete capability (one server-wide flag):
    // a 404/405 verdict from the list, the archived sheet mirrored onto it, or the chat's
    // own delete (`sessionRemovalFinished`), hides the open chat's Delete too. Seats pick the
    // flag up in `seatLiveChat`.
    .onChange(of: \.home?.deleteSupported) { _, supported in
      Reduce { state, _ in
        if let supported, state.liveChat != nil {
          state.liveChat?.deleteSupported = supported
        }
        return .none
      }
    }
    // The ONE edge the widget surfaces sync from (#138): whatever moved the projection — a
    // list fetch, a slot's running flip, an approval card, the show-titles pref — rewrites the
    // App Group mirror once the burst settles and syncs the Live Activity (start / update / end).
    // Evaluated after every child reducer, so it reads the reduced state. It watches the cheap
    // inputs and builds the projection only when one moved. `nil` is "unknown" (signed out, or
    // no unfiltered fetch yet): hold — never end; a logout clears the surfaces on its own. A
    // projection going unknown under the same list (a profile switch reset its rows) stops
    // vouching: both surfaces keep their content but go "Outdated" after the margin unless the
    // refetch lands first — it may fail, or the user may background before it.
    .onChange(of: \.agentStatusInputs) { old, new in
      Reduce { state, _ in
        let previous = old?.projection
        guard let status = new?.projection else {
          guard let previous, let old, state.home?.connection == old.connection else {
            return .none
          }
          return .merge(
            writeMirror(
              rows: previous.rows, freshUntil: unknownFreshUntil(state), debounced: false
            ),
            syncLiveActivity(nil, &state, .restamp)
          )
        }
        guard status != previous else { return .none }
        // Back from unknown, the activity's stale date was shortened: restamp it even when
        // its content didn't change.
        return .merge(
          syncMirror(status, state, debounced: true),
          syncLiveActivity(status, &state, previous == nil ? .restamp : .debounced)
        )
      }
    }
    // Every route that opens a chat leaves the Settings tab: `AppView` layers Settings over
    // the WHOLE split view, so the chat (a compact marker, or the regular detail seat — even
    // an in-place hydrate of the seated session) would otherwise land hidden under it. Sent
    // as a list ACTION, never a direct nil-out, so the list's `ifLet` cancels Settings'
    // effects. Evaluated after the routing itself; a route that stashes (no home yet) or
    // finds nothing to open still just lands on Sessions.
    Reduce { state, action in
      switch action {
      case .pushTapped, .launchIntentReceived,
           .home(.delegate(.openSession)), .home(.delegate(.createSession)):
        guard state.home?.effectiveTab == .settings else { return .none }
        return .send(.home(.selectTab(.sessions)))
      default:
        return .none
      }
    }
  }

  /// How long the surfaces may vouch for the projection: `backgroundFreshUntil` while
  /// backgrounded (`now` + the margin when the background edge had nothing to stamp), else
  /// `now` + `foregroundFreshness`. The mirror's `freshUntil` and the activity's `staleDate`.
  private func freshUntil(_ state: State) -> Date {
    let now = date.now
    return state.isSceneBackgrounded
      ? state.backgroundFreshUntil ?? now.addingTimeInterval(Self.backgroundFreshnessMargin)
      : now.addingTimeInterval(Self.foregroundFreshness)
  }

  /// The promise for content the app can no longer back (the projection went unknown): the
  /// suspension margin, or the background stamp when that is sooner.
  private func unknownFreshUntil(_ state: State) -> Date {
    min(freshUntil(state), date.now.addingTimeInterval(Self.backgroundFreshnessMargin))
  }

  /// The "Live Activity" pref changed (Settings persisted it). Off ends every activity of the
  /// app at once (an in-flight start is ended when it lands — `liveActivityStarted` finds no
  /// seat) and drops a pending update; on starts one at once when agents are active.
  private func setLiveActivityEnabled(_ enabled: Bool, _ state: inout State) -> Effect<Action> {
    state.liveActivityEnabled = enabled
    guard enabled else {
      state.liveActivity = nil
      return .merge(
        .cancel(id: CancelID.liveActivitySync),
        .run { [liveActivity] _ in await liveActivity.endAll() }
      )
    }
    return syncLiveActivity(state.agentStatus, &state, .immediate)
  }

  /// Drives the aggregate Live Activity from `status`, the caller's `state.agentStatus` (#138),
  /// so a caller that already built the projection doesn't build it again. `nil` (unknown) holds
  /// the content; only a `restamp` acts on it, shortening the stale date (`unknownFreshUntil`).
  /// - No activity and agents active → start one, only while the pref is on, the scene is in
  ///   the foreground and iOS allows activities; the seat is taken at once (id pending, a fresh
  ///   request token) so a second change can't start a second one, and `liveActivityStarted`
  ///   adopts the id. The start first ends every activity still on screen — the previous one's
  ///   lingering "Done" — so back-to-back turns never stack. A start failure is only
  ///   debug-logged.
  /// - An activity and agents active → update it (skipped when the content didn't change,
  ///   unless a scene edge `restamp`s the stale date).
  /// - An activity and nothing active → end it with its last headline as "Done", dismissed
  ///   after `liveActivityDismissal`.
  /// The edge debounces the update / end (`LiveActivitySync.debounced`); the stale date is
  /// `freshUntil`, the same promise as the widget mirror.
  private func syncLiveActivity(
    _ status: AgentStatusProjection?, _ state: inout State, _ mode: LiveActivitySync
  ) -> Effect<Action> {
    guard let status else {
      guard mode == .restamp, let seat = state.liveActivity, let id = seat.id else {
        return .none
      }
      let staleDate = unknownFreshUntil(state)
      return .merge(
        .cancel(id: CancelID.liveActivitySync),
        .run { [liveActivity] _ in await liveActivity.update(id, seat.content, staleDate) }
      )
    }
    let content = status.activityContent
    guard let seat = state.liveActivity else {
      guard let content, state.liveActivityEnabled, !state.isSceneBackgrounded,
        liveActivity.areActivitiesEnabled()
      else { return .none }
      state.liveActivityRequests += 1
      let request = state.liveActivityRequests
      state.liveActivity = LiveActivitySeat(id: nil, content: content, request: request)
      let staleDate = freshUntil(state)
      return .run { [liveActivity, debugLog] send in
        await liveActivity.endAll()
        do {
          let id = try await liveActivity.start(content, staleDate)
          await send(.liveActivityStarted(id: id, request: request))
        } catch {
          debugLog.note("live.activity", "start failed: \(error)")
          await send(.liveActivityStartFailed(request: request))
        }
      }
    }
    // A start in flight: `liveActivityStarted` catches up with whatever changed meanwhile.
    guard let id = seat.id else { return .none }
    if mode == .debounced {
      return .run { [clock] send in
        try await clock.sleep(for: Self.surfacesSyncDebounce)
        await send(.liveActivitySyncDue)
      }
      .cancellable(id: CancelID.liveActivitySync, cancelInFlight: true)
    }
    // Applied now: supersedes a debounced update / end still waiting.
    let pending: Effect<Action> = .cancel(id: CancelID.liveActivitySync)
    guard let content else {
      state.liveActivity = nil
      var final = seat.content
      final.activeCount = 0
      final.status = .done
      let dismissAfter = date.now.addingTimeInterval(Self.liveActivityDismissal)
      debugLog.note("live.activity", "end: done")
      return .merge(
        pending,
        .run { [liveActivity, final] _ in await liveActivity.end(id, final, dismissAfter) }
      )
    }
    guard mode == .restamp || content != seat.content else { return pending }
    state.liveActivity?.content = content
    let staleDate = freshUntil(state)
    let staleIn = Int(staleDate.timeIntervalSince(date.now))
    debugLog.note(
      "live.activity", "update: \(content.status.rawValue) ×\(content.activeCount), stale in \(staleIn)s"
    )
    return .merge(
      pending,
      .run { [liveActivity] _ in await liveActivity.update(id, content, staleDate) }
    )
  }

  /// Writes `status` (the caller's `state.agentStatus`) into the widget mirror and reloads the
  /// sessions widget, stamped with how long the app can vouch for it: `backgroundFreshUntil`
  /// while backgrounded (a change during the grace window must not extend the promise; `now` +
  /// the margin when the background edge had nothing to stamp), else `now` +
  /// `foregroundFreshness`. Last-wins under
  /// `CancelID.mirrorSync`: `debounced` waits `surfacesSyncDebounce` first, so a burst
  /// coalesces into one write; the scene edges write at once and supersede a pending one. A
  /// `nil` projection writes nothing. A failed write is only logged — the mirror is a
  /// non-authoritative cache the next change rewrites.
  private func syncMirror(
    _ status: AgentStatusProjection?, _ state: State, debounced: Bool
  ) -> Effect<Action> {
    guard let status else { return .none }
    return writeMirror(rows: status.rows, freshUntil: freshUntil(state), debounced: debounced)
  }

  /// `syncMirror`'s write, for explicit rows and promise (the unknown edge re-sends the last
  /// known rows with a short one).
  private func writeMirror(
    rows: [WidgetSessionRow], freshUntil: Date, debounced: Bool
  ) -> Effect<Action> {
    let snapshot = WidgetSessionSnapshot(freshUntil: freshUntil, isSignedIn: true, rows: rows)
    return .run { [widgetMirror, clock, debugLog] _ in
      if debounced { try await clock.sleep(for: Self.surfacesSyncDebounce) }
      do {
        try widgetMirror.write(snapshot)
      } catch {
        debugLog.note("widget.mirror", "write failed: \(error)")
      }
      widgetMirror.reloadTimelines()
    }
    .cancellable(id: CancelID.mirrorSync, cancelInFlight: true)
  }

  /// The logout half of the surfaces: replace the mirror with the signed-out snapshot and
  /// reload, so the widget stops showing the old identity's sessions, and end every Live
  /// Activity (an in-flight start is ended when it lands — no seat adopts it). Shares the
  /// syncs' cancel ids, so a write or update still waiting out its debounce can't land after.
  private func clearSurfaces(_ state: inout State) -> Effect<Action> {
    state.liveActivity = nil
    return .merge(
      .run { [widgetMirror, debugLog] _ in
        do {
          try widgetMirror.clear()
        } catch {
          debugLog.note("widget.mirror", "clear failed: \(error)")
        }
        widgetMirror.reloadTimelines()
      }
      .cancellable(id: CancelID.mirrorSync, cancelInFlight: true),
      .cancel(id: CancelID.liveActivitySync),
      .run { [liveActivity] _ in await liveActivity.endAll() }
    )
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

  /// "New session": the list's button (`.home(.delegate(.createSession))`) and an App Intent
  /// (`.launchIntentReceived`, #93) both land here, so the two can never drift. No list → no-op.
  /// `launchAction` is the intent's one-shot request (`LaunchIntent.launchAction`), `nil` for a
  /// plain new chat. It is a one-shot `pendingLaunchAction` on the chat, consumed at its first
  /// `.task` — or `.startLaunchAction` on the reused-seat path, whose slot has already started.
  private func reduceCreateSession(
    _ state: inout State, composerText: String?, launchAction: LaunchAction?
  ) -> Effect<Action> {
    guard let home = state.home else { return .none }
    // "New session" over a slot the list would rebuild identically (`isReusableNewChat`
    // — regular width keeps one such seat in the detail column at all times): tearing it
    // down to fill an identical fresh one would redial its socket for nothing. Reset the
    // composer draft (text + staged attachments) instead — the only visible difference a
    // fresh chat would have; `composerText` still seeds it. Anything the shortcut
    // can't reproduce (a stale profile, in-flight composer input, a failed handshake)
    // falls through to the real refill. The marker guard is the compact safety net: a
    // detached seat re-attaches rather than leaving the tap without a screen.
    if let chat = state.liveChat, Self.isReusableNewChat(chat, for: home) {
      state.liveChat?.composerText = composerText ?? ""
      state.liveChat?.attachments = []
      if state.isChatDetached {
        state.path.append(ChatScreen.State(sessionKey: chat.sessionKey))
      }
      return launchAction.map { .send(.liveChat(.startLaunchAction($0))) } ?? .none
    }
    // New chats are created under the currently-selected profile. `composerText` (push "Ask
    // agent to install") seeds the composer draft but is NOT auto-sent.
    var chat = newChat(for: home, composerText: composerText ?? "")
    chat.pendingLaunchAction = launchAction
    guard state.liveChat != nil else {
      seatLiveChat(chat, into: &state)
      return .none
    }
    // Slot occupied: flush + fully tear the old chat down before filling (same rule
    // as open — the replacement goes through the nil-out). A busy slot (running turn, queued
    // work) is replaced too: the turn continues on the server and stays reachable from the list.
    return teardownSlot(thenFill: chat)
  }

  /// Mark a session read under the profile that owns the active chat. Every open sends this
  /// best-effort write—even when a cold-launch push has no loaded row—so a null server
  /// watermark becomes tracked. Older agents reject/ignore the field and keep using the
  /// local message-count fallback.
  private func acknowledgeRead(
    _ state: inout State,
    sessionID: Session.ID,
    connection: ServerConnection,
    profileName: String?
  ) -> Effect<Action> {
    // Only mutate a visible row when the sidebar is showing the same profile. The active
    // chat intentionally survives profile switches, so matching by id alone is unsafe.
    if let home = state.home, Self.isSameProfile(home.scopedProfileName, profileName),
       home.sessions[id: sessionID]?.unread != nil
    {
      state.home?.sessions[id: sessionID]?.unread = false
    }
    return .run { [rest] _ in
      try? await rest.setUnread(connection, sessionID, false, profileName)
    }
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
      // replaying; the badge reflects the now-pending approval either way. Last-wins across
      // both stashes: an earlier App Intent request (#93) no longer replays.
      state.pendingPushTap = tap
      state.pendingPushTapServerURL = preferences.loadServerURL().flatMap(parseServerURL)
      state.pendingLaunchIntent = nil
      state.pendingLaunchIntentServerURL = nil
      return setBadge(state)
    }
    // Approval-recovery hint (#30 workaround): only an approval tap arms it.
    return reduceOpenSessionRouting(
      &state, sessionID: tap.sessionID, profile: nil, armsApprovalHint: tap.isApproval
    )
  }

  /// The session-opening body shared by a push tap (`reducePushTapped`, which adds its badge
  /// marking and stash around it) and a widget / Live Activity `.openSession` intent — so the
  /// #32 rules can never drift between them. Requires `home`; three outcomes, in order:
  /// on screen → in place; detached slot match (compact only) → re-attach; different
  /// session → slot replacement (marker only in compact). Never stacks.
  ///
  /// `profile` is the intent's row profile (`nil` = the list's selected profile, which is
  /// all a push tap knows). A row from ANOTHER profile resumes under that profile without
  /// changing the list's selection — the chat's own `profileName` scopes its calls, exactly
  /// as a slot that outlived a profile switch does. Ignored on an agent without the profiles
  /// API, whose calls must stay profile-less (#114).
  ///
  /// `armsApprovalHint` is a push tap's `isApproval`: the in-place branch then arms the #30
  /// recovery hint and drives its consuming hydrate. The other branches need no flag — the
  /// open reads the hint from `pendingApprovalSessionIDs`, which the tap has just marked.
  private func reduceOpenSessionRouting(
    _ state: inout State, sessionID: Session.ID, profile: String?, armsApprovalHint: Bool
  ) -> Effect<Action> {
    guard let home = state.home else { return .none }
    // The session is the one ALREADY on screen (`currentViewingSessionID` — the slot key
    // when NOT detached: in compact that means its marker is on the path, in regular the
    // slot is always the visible detail) → NO navigation, path untouched (empty in
    // regular). Badge bookkeeping only: the user is now viewing it, so the pending entry
    // clears (a tap's mark-then-clear nets zero); the content update arrives in place —
    // the live socket is already streaming, and the app activation fires the existing
    // `.foreground` re-hydrate.
    if state.currentViewingSessionID == sessionID {
      state.pendingApprovalSessionIDs.remove(sessionID)
      let read: Effect<Action>
      if let chat = state.liveChat {
        read = acknowledgeRead(
          &state,
          sessionID: sessionID,
          connection: chat.connection,
          profileName: chat.profileName
        )
      } else {
        read = .none
      }
      // Approval-recovery hint (#30 workaround): the socket may have been down when the
      // `approval.request` fired, so arm the one-shot hint AND drive the consuming
      // hydrate ourselves — the tap's scene activation is delivered independently of
      // this action, so a `.foreground` that reduced BEFORE the tap (or never fires)
      // would otherwise leave the hint armed for an arbitrary later hydrate.
      // `.foreground` is idempotent: it never cancel-and-redials a healthy socket,
      // just re-hydrates. Nil slot guarded (the hint is meaningless without one).
      if armsApprovalHint, state.liveChat != nil {
        state.liveChat?.expectsPendingApproval = true
        return .merge(setBadge(state), read, .send(.liveChat(.foreground)))
      }
      return .merge(setBadge(state), read)
    }
    // A row from another profile than the list shows: open it directly under its own
    // profile (the list's row, if any, belongs to a different `state.db`).
    if let profile, home.profilesSupported,
       !Self.isSameProfile(profile, home.scopedProfileName)
    {
      return reduceOpenSession(&state, session: Session(id: sessionID), profileName: profile)
    }
    // Otherwise share the SAME `openSession` flow a list tap uses: a DETACHED slot match
    // (compact only — the user popped to the list; in regular a slot match always took
    // the branch above) pushes the marker back and re-attaches live (no re-init, no
    // dup); a different session replaces the slot and SETS the path — the single new
    // marker in compact, left empty in regular where the slot IS the detail column
    // (`seatLiveChat` resets rather than appends — no stacking on cold launch either).
    // Prefer the loaded `Session` (carries a title); fall back to a minimal `Session(id:)`
    // if it isn't in the list (the chat resumes by stored id and hydrates the title).
    let session = home.sessions[id: sessionID] ?? Session(id: sessionID)
    // Opening clears the badge entry + marks current-viewing (handled in the openSession case).
    return .send(.home(.delegate(.openSession(session))))
  }

  /// Open `session` into the live-chat slot under `profileName` — the body of the list's
  /// `openSession` delegate (which passes the selected profile) and of a cross-profile
  /// widget open (which passes the row's).
  private func reduceOpenSession(
    _ state: inout State, session: Session, profileName: String?
  ) -> Effect<Action> {
    guard let home = state.home else { return .none }
    // Approval-recovery hint (#30 workaround): a badged session (approval push tapped or
    // received) may have missed the real `approval.request` while detached — read the flag
    // BEFORE clearing the badge entry so the hydrating chat can synthesize a generic card
    // when the turn is still running. Covers tap→open, slot replacement, and a badged
    // session opened later from the list.
    let expectsApproval = state.pendingApprovalSessionIDs.contains(session.id)
    // Opening a session clears its pending-approval badge entry (the user is now viewing it).
    // The current-viewing marker is updated by the reducer's
    // `.onChange(of: currentViewingSessionID)` (one source of truth for nav-derived state).
    state.pendingApprovalSessionIDs.remove(session.id)
    let badge = setBadge(state)
    // Re-opening the slot's OWN session (e.g. tapping the glowing row of a detached
    // running turn): the accumulated live state must survive — a fresh
    // `ChatFeature.State` would discard the detached reasoning/tool/streaming rows.
    // Push the marker back (the path is empty when coming from the list) and
    // re-attach: hydrate against the live socket, reconnecting only if it died.
    if let chat = state.liveChat, chat.sessionKey == session.id {
      if expectsApproval {
        state.liveChat?.expectsPendingApproval = true
      }
      let read = acknowledgeRead(
        &state,
        sessionID: session.id,
        connection: chat.connection,
        profileName: chat.profileName
      )
      // Marker only when the chat is actually detached (compact + empty path) — in
      // regular the slot is already the visible detail and the path stays empty.
      // Defensive guard too: the path is normally empty here in compact (re-opens come
      // from the list, and an on-screen match short-circuits in `pushTapped` before
      // reaching this delegate) — but a double-delivered open must not stack a second
      // marker.
      if state.isChatDetached {
        state.path.append(ChatScreen.State(sessionKey: session.id))
      }
      return .merge(badge, read, .send(.liveChat(.reattached)))
    }
    // `resolvedTitle` keeps the server's "Untitled" placeholder out of the header
    // (and the rename pre-fill); a real title arrives via `session.info` on resume.
    var chat = ChatFeature.State(
      connection: home.connection,
      resumeStoredID: session.id,
      profileName: profileName,
      title: session.resolvedTitle
    )
    let read = acknowledgeRead(
      &state,
      sessionID: session.id,
      connection: home.connection,
      profileName: profileName
    )
    chat.expectsPendingApproval = expectsApproval
    guard state.liveChat != nil else {
      seatLiveChat(chat, into: &state)
      return .merge(badge, read)
    }
    // Slot occupied (e.g. a push tap while a chat is open): replace it — the old chat
    // must be fully torn down (through the nil-out, so even its un-ID'd one-shot RPC
    // effects are cancelled) before the new chat fills the slot.
    return .merge(badge, read, teardownSlot(thenFill: chat))
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

  /// Whether a chat's and the list's wire profiles name the same profile, for the row
  /// patches (glow, unread) that match by session id: a chat opened before the profiles
  /// probe answered carries `nil` while the list moved on to the literal `"default"` (#114).
  /// The reseat paths compare WIRE values instead — a `nil` seat must be re-created scoped.
  private static func isSameProfile(_ lhs: String?, _ rhs: String?) -> Bool {
    (lhs ?? SessionListFeature.State.defaultProfileName)
      == (rhs ?? SessionListFeature.State.defaultProfileName)
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
  /// (#46) opens a chat synchronously here, as does the regular-width landing seat, and an
  /// unseeded `scopedProfileName` would leave them UNSCOPED — the server's LAUNCH profile,
  /// not the selected one (#114: a resume misses → the self-heal recreates a spurious empty
  /// chat there). `persistedProfilesSupported` seeds the capability from the last probe's
  /// verdict; the list's capability probe still corrects
  /// `profilesSupported` right after, and the regular-width reseat re-creates a seat whose
  /// pre-probe scope turned out wrong. A profile deleted/renamed server-side since
  /// selection is the accepted corner: the scoped resume fails exactly as a warm list-tap
  /// under the same stale pref would — parity with the warm path is the contract.
  private func makeHomeState(connection: ServerConnection) -> SessionListFeature.State {
    SessionListFeature.State(
      connection: connection,
      selectedProfileName: SessionListFeature.State.persistedProfileName(preferences),
      profilesSupported: SessionListFeature.State.persistedProfilesSupported(preferences),
      // Seeded here too (not only on the list's `.task`) so hidden tips never flash.
      showsOnboardingTips: !preferences.loadOnboardingTipsDismissed()
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
  ///
  /// A stashed App Intent request (#93) replays through the "New session" path, which fills
  /// the slot, so no detail seat is filled first. The two stashes are mutually exclusive
  /// (last-wins across both), so at most one replays; the cross-server badge scrub runs either
  /// way. The intent keeps its launch action (dictation, camera, photos) only on the launch
  /// auto-connect landing (`replaysLaunchAction`): a retry-screen re-probe or a manual login
  /// can come minutes or hours later, so those replay it as a plain new chat. A stashed
  /// `.openSession` replays through the push-tap routing instead, under the same cross-server
  /// guard as a tap (its own `pendingLaunchIntentServerURL`).
  ///
  /// The Live Activity (#138): the toggles are seeded from the device prefs, and any activity
  /// already on screen is ended. None can be this landing's — a start needs the list's first
  /// fetch, which comes after — so it is a previous process's (killed in the background, or
  /// crashed) that nothing would ever update or end: it would sit "Outdated" next to the new
  /// one the fetch starts. The sweep ends the activities listed when it runs, and the start
  /// waits on that network fetch.
  private func landOnHome(_ state: inout State, replaysLaunchAction: Bool) -> Effect<Action> {
    // The Live Activity prefs (#138): device-local, reset to on by a logout.
    state.liveActivityEnabled = preferences.loadLiveActivityEnabled()
    state.liveActivityShowsTitles = preferences.loadLiveActivityShowsTitles()
    let sweep: Effect<Action> = .run { [liveActivity] _ in await liveActivity.endAll() }
    return .merge(sweep, replayLandingStash(&state, replaysLaunchAction: replaysLaunchAction))
  }

  /// `landOnHome`'s replay half: the stashed push tap or launch intent, else the detail seat.
  private func replayLandingStash(
    _ state: inout State, replaysLaunchAction: Bool
  ) -> Effect<Action> {
    let intent = state.pendingLaunchIntent
    let intentOrigin = state.pendingLaunchIntentServerURL
    let tap = state.pendingPushTap
    let origin = state.pendingPushTapServerURL
    state.pendingLaunchIntent = nil
    state.pendingLaunchIntentServerURL = nil
    state.pendingPushTap = nil
    state.pendingPushTapServerURL = nil
    let connected = state.home?.connection.baseURL
    func isForeign(_ origin: URL?) -> Bool {
      guard let origin, let connected else { return false }
      return !Self.isSameServer(origin, connected)
    }
    let tapIsForeign = isForeign(origin)
    var badge: Effect<Action> = .none
    if tapIsForeign, !state.pendingApprovalSessionIDs.isEmpty {
      state.pendingApprovalSessionIDs.removeAll()
      badge = setBadge(state)
    }
    if case let .openSession(id, profile) = intent {
      guard !isForeign(intentOrigin) else {
        // Dropped as foreign — nothing will fill the slot, so seat the detail here.
        fillNewChatIfDetailEmpty(&state)
        return badge
      }
      return .merge(
        badge,
        reduceOpenSessionRouting(
          &state, sessionID: id, profile: profile, armsApprovalHint: false
        )
      )
    }
    if let intent {
      return .merge(
        badge,
        reduceCreateSession(
          &state,
          composerText: nil,
          launchAction: replaysLaunchAction ? intent.launchAction : nil
        )
      )
    }
    guard let tap, !tapIsForeign else {
      // No tap, or dropped as foreign — nothing will fill the slot, so seat the detail here.
      fillNewChatIfDetailEmpty(&state)
      return badge
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

  /// The session `id` is gone from the server (archived or deleted — from the list or from the
  /// chat's own ⋯ menu): the ONE place both paths close it. Delete always wipes the cached
  /// snapshot + turn anchor (a deleted session must never repaint from the cache). If the
  /// slot holds the session (by key, or as the chat whose removal is in flight — a #17 heal
  /// may have re-keyed it) it is torn down; Delete skips the flush, which would re-save the
  /// snapshot being wiped. In compact a marker on screen is popped too, or the stack would
  /// show an empty destination under a Back button; in regular the torn-down chat WAS the
  /// detail column, so a fresh new chat is seated behind it (`detailRefill`).
  private func closeRemovedSession(
    _ state: inout State, id: String, isDelete: Bool
  ) -> Effect<Action> {
    let wipeSnapshot: Effect<Action> = isDelete
      ? .run { [chatSnapshot] _ in chatSnapshot.deleteSnapshot(id) } : .none
    guard let chat = state.liveChat,
      chat.sessionKey == id || chat.removingSessionID == id
    else { return wipeSnapshot }
    if state.layout == .compact {
      state.path.removeAll()
    }
    return .concatenate(
      teardownSlot(thenFill: detailRefill(state), flushSnapshot: !isDelete), wipeSnapshot
    )
  }

  /// A delete of `id` is server-CONFIRMED: drop its pending-approval badge entry and update
  /// the badge. Shared by the list's `sessionDeleteSucceeded` and the chat menu's delete.
  private func clearDeletedSessionBadge(_ state: inout State, id: String) -> Effect<Action> {
    state.pendingApprovalSessionIDs.remove(id)
    return setBadge(state)
  }

  /// Whether a chat-menu removal's reply belongs to the server the app is signed in to now.
  /// The removal effect is cancelled on logout; this guard covers a reply already queued.
  private func isCurrentServer(_ connection: ServerConnection, _ state: State) -> Bool {
    guard let home = state.home else { return false }
    return Self.isSameServer(connection.baseURL, home.connection.baseURL)
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
    var chat = chat
    chat.deleteSupported = state.home?.deleteSupported ?? true
    state.liveChat = chat
    // A new slot reports its own running state; no push mark carries over to it (#138).
    state.pushFinishedSessionIDs = []
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
  /// retrying: the Server step auto-probes the stored URL, and token mode prefills the token
  /// into the Sign in step it pushes; cookie and bearer mode prefill nothing more (neither a
  /// password nor a browser leg is persistable), so the user re-authenticates. Shared by the launch auth-failure fallback and the retry screen's
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
      recovering: connection.baseURL,
      token: connection.auth.token
    )
    guard case .bearer = connection.auth else { return .none }
    let claim = bearerTokens.claimOwnership() // minted here, applied on the next tick
    return .run { [bearerTokens] _ in bearerTokens.clear(claim: claim) }
  }

  /// Release what the slot holds OUTSIDE its effects, right before every nil-out: the
  /// `.clearLiveChat` that ends `teardownSlot`, and the identity teardowns (Settings
  /// "disconnect", either logout, a different-user re-auth) that drop the chat by ASSIGNMENT.
  /// `ifLet`'s auto-cancel on the nil-out reaches every child EFFECT — the level stream and
  /// the tick loop included — but not:
  /// - the microphone: `AudioRecorderClient` keeps `AVAudioRecorder` and the audio session
  ///   alive until someone calls `cancel()`, which `ChatFeature.teardown` does but an
  ///   assignment skips. The split sidebar (#80) puts Settings on screen next to a recording
  ///   composer, so this is reachable without ever leaving the chat;
  /// - the idle timer (#74): an awake slot (`wantsScreenAwake`, e.g. a running auto-speak
  ///   turn) disabled auto-lock, and once the slot is gone no `.onChange` edge can restore it;
  /// - a presented file preview's finished Share download: the file `downloadedURL` names is
  ///   held outside the child's effects, and the sheet's own `.filePreview(.dismiss)` cleanup
  ///   is not sent on a slot nil-out (`releaseSlotFilePreviewTemp`).
  /// The idle-timer release runs IMMEDIATELY, when this is called; the mic and temp-file
  /// releases are the returned effect. No slot, or an idle one → nothing.
  private func releaseSlotDeviceResources(_ state: State) -> Effect<Action> {
    guard let chat = state.liveChat else { return .none }
    if chat.wantsScreenAwake { idleTimer.setDisabled(false) }
    let releaseTemp = releaseSlotFilePreviewTemp(state)
    guard chat.recording.isBusy else { return releaseTemp }
    return .merge(.run { [audioRecorder] _ in await audioRecorder.cancel() }, releaseTemp)
  }

  /// Remove a presented file preview's finished Share download when the slot is dropped —
  /// `.clearLiveChat` (every `teardownSlot`) and the identity teardowns alike, via
  /// `releaseSlotDeviceResources`. Must be read BEFORE the assignment. No slot, no preview, or
  /// nothing finished → no effect. Fire-and-forget: nothing can act on a failed delete of a
  /// temp file.
  private func releaseSlotFilePreviewTemp(_ state: State) -> Effect<Action> {
    guard let url = state.liveChat?.filePreview?.downloadedURL else { return .none }
    return .run { [filePreview] _ in await filePreview.removeTemp(url) }
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
  /// the persist hook so a rotation performed inside the store is written back. A no-op for
  /// the other two regimes. Static (and dependency-taking) because it runs inside `@Sendable`
  /// effect closures, where the reducer `self` is not `Sendable`.
  private static func seedBearerStore(
    _ auth: AuthSession,
    baseURL: URL,
    keychain: KeychainClient,
    store: BearerTokenStore
  ) {
    guard case let .bearer(bearer) = auth else { return }
    store.seed(bearer, baseURL: baseURL) { rotated in
      try keychain.saveSession(.bearer(rotated))
    }
  }

  /// The server-side half of a logout, in the ONE order that works — shared by all three
  /// logout paths (`connectionFailed.logoutConfirmed`, `reauth.quit`, `.disconnect`) so they
  /// cannot drift apart.
  ///
  /// Both hops are best-effort and both need the credentials that are about to die, hence
  /// `.concatenate` rather than `.merge`: the push unregister authenticates like any other
  /// REST call (through the token store in bearer mode), then `rest.logout` runs, and only
  /// then is the store drained. Draining first would make BOTH requests silent no-ops —
  /// `resolveAuth` has nothing to resolve — which is exactly the trap Task 6 documented on
  /// `HermesRESTClient.logout`.
  ///
  /// Either hop can rotate a pair that is inside its refresh leeway; what stops that rotation
  /// from rewriting the deleted Keychain entry is `BearerTokenStore.detachPersistence()`,
  /// which every path calls synchronously before its `keychain.deleteSession()`.
  ///
  /// The trailing drain carries a claim minted HERE, synchronously, and not by the effect: both
  /// hops are best-effort against a server that is often the reason the user is logging out, so
  /// each can stall for `URLSession`'s 60 s default while the user completes a fresh sign-in on
  /// the onboarding screen this reduction just landed them on. The claim makes that sign-in
  /// supersede the stale drain instead of being erased by it — see `BearerTokenStore.clear`.
  private func serverSideLogout(connection: ServerConnection?) -> Effect<Action> {
    // Called for its synchronous prefs clearing too, so it must run unconditionally.
    let unregister = unregisterPushOnLogout(connection: connection)
    guard let connection, case .bearer = connection.auth else { return unregister }
    let claim = bearerTokens.claimOwnership()
    return .concatenate(
      unregister,
      .run { [rest, bearerTokens] _ in
        await rest.logout(connection)
        bearerTokens.clear(claim: claim)
      }
    )
  }
}
