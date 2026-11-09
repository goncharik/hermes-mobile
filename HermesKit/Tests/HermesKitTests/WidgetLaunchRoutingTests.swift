import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Widget / Control Center / Live Activity routing (#138): `hermesmobile://` URLs map to a
/// `LaunchIntent` that reaches `AppFeature.launchIntentReceived` through the #93 bridge. An
/// `.openSession` follows the push-tap routing (#32) without its approval bookkeeping, and its
/// pre-home stash carries a server-origin guard like a stashed tap.
@MainActor
struct WidgetLaunchRoutingTests {
  private let connection = ServerConnection(
    baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok"
  )

  // MARK: Warm routing (list present)

  /// The widget row is the session ALREADY on screen (compact, marker on the path): no
  /// navigation, no slot re-init. Exhaustive: any follow-up action would fail the send.
  @Test func openSessionForOnScreenSessionStaysInPlace() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.composerText = "unsent draft"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
    }

    await store.send(.launchIntentReceived(.openSession(id: "s1", profile: nil)))
    await store.finish()
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.composerText == "unsent draft")
    // A widget open never arms the approval-recovery hint (only an approval push tap does).
    #expect(store.state.liveChat?.expectsPendingApproval == false)
  }

  /// A DETACHED compact slot (the user popped to the list mid-turn): the open re-attaches
  /// through the list's `openSession` path — the marker is pushed back once and the slot's
  /// state survives.
  @Test func openSessionForDetachedSlotReattachesWithoutDuplicate() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true
    chat.composerText = "unsent draft"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live1"),
          "stored_session_id": .string("s1"),
          "messages": .array([]),
          "running": .bool(false),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.launchIntentReceived(.openSession(id: "s1", profile: nil)))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.reattached)
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.composerText == "unsent draft")
    #expect(store.state.liveChat?.expectsPendingApproval == false)

    await store.send(.liveChat(.teardown))
  }

  /// A DIFFERENT session replaces the occupied compact slot through the full teardown chain
  /// and SETS the path to the single new marker — never stacks.
  @Test func openSessionForDifferentSessionReplacesSlotAndSetsPath() async {
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    liveChat.liveSessionID = "old-live"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "new", title: "Widget row")]
        ),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off

    await store.send(.launchIntentReceived(.openSession(id: "new", profile: nil)))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat)
    await store.receive(\.fillLiveChat)
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "new")
    #expect(store.state.liveChat?.storedSessionID == "new")
    // The loaded row is reused, so its title carries over.
    #expect(store.state.liveChat?.title == "Widget row")
    #expect(store.state.liveChat?.expectsPendingApproval == false)
  }

  /// Regular: a different session replaces the slot and leaves the path EMPTY (the slot IS
  /// the detail column).
  @Test func openSessionForDifferentSessionInRegularReplacesSlotWithEmptyPath() async {
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    liveChat.liveSessionID = "old-live"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: liveChat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.launchIntentReceived(.openSession(id: "new", profile: nil)))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat)
    await store.receive(\.fillLiveChat)
    await store.receive(\.liveChat.task)
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat?.storedSessionID == "new")
    await store.send(.liveChat(.teardown))
  }

  /// A session already badged by an approval push (the usual Live Activity headline): on
  /// screen, the open only clears its badge entry — no hint, no extra hydrate.
  @Test func openSessionForBadgedOnScreenSessionClearsTheBadgeOnly() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat,
        pendingApprovalSessionIDs: ["s1"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
    }

    // Exhaustive: no `.liveChat(.foreground)` follows.
    await store.send(.launchIntentReceived(.openSession(id: "s1", profile: nil))) {
      $0.pendingApprovalSessionIDs = []
    }
    await store.finish()
    #expect(store.state.liveChat?.expectsPendingApproval == false)
  }

  /// …and off screen it opens like a list tap on a badged row: the replacement chat expects
  /// the approval it may have missed (#30), and the badge entry clears.
  @Test func openSessionForBadgedOtherSessionArmsTheHintLikeAListOpen() async {
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    liveChat.liveSessionID = "old-live"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "new")]),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: liveChat,
        pendingApprovalSessionIDs: ["new"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off

    await store.send(.launchIntentReceived(.openSession(id: "new", profile: nil)))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat)
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.storedSessionID == "new")
    #expect(store.state.liveChat?.expectsPendingApproval == true)
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
  }

  /// The open can arrive over a list sheet: presentations are dismissed first, like the #93
  /// new-chat intents.
  @Test func openSessionDismissesListPresentations() async {
    var home = SessionListFeature.State(connection: connection, selectedTab: .settings)
    home.settings = SettingsFeature.State(connection: connection)
    home.renamingID = "s1"
    let store = TestStore(initialState: AppFeature.State(home: home)) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off

    await store.send(.launchIntentReceived(.openSession(id: "s1", profile: nil))) {
      $0.home?.renamingID = nil
    }
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "s1")
    // The Settings tab is left by the path rule once the chat's marker lands.
    await store.receive(\.home.selectTab, .sessions)
    #expect(store.state.home?.settings == nil)
    #expect(store.state.home?.effectiveTab == .sessions)
  }

  /// A row from ANOTHER profile than the list shows resumes under that profile, without
  /// changing the list's selection (and without borrowing the list's same-id row).
  @Test func openSessionFromOtherProfileResumesUnderItsProfile() async {
    let writes = LockIsolated<[(String, String?)]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          sessions: [Session(id: "s-w", title: "Default-profile row")],
          selectedProfileName: "default",
          profilesSupported: true
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
      $0.hermesREST.setUnread = { _, id, _, profile in
        writes.withValue { $0.append((id, profile)) }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Opened directly, not through the list's `openSession` delegate: that path would scope
    // the chat to the list's "default" profile.
    await store.send(.launchIntentReceived(.openSession(id: "s-w", profile: "work")))
    await store.finish()
    #expect(store.state.liveChat?.storedSessionID == "s-w")
    #expect(store.state.liveChat?.profileName == "work")
    #expect(store.state.liveChat?.title == nil)
    #expect(store.state.path.last?.sessionKey == "s-w")
    #expect(store.state.home?.selectedProfileName == "default")
    #expect(writes.value.first?.0 == "s-w")
    #expect(writes.value.first?.1 == "work")
  }

  /// The list's own profile (or no profile on the URL) routes through the list's
  /// `openSession` like a push tap, scoped to the selected profile.
  @Test func openSessionForSelectedProfileUsesTheListPath() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off

    await store.send(.launchIntentReceived(.openSession(id: "s-w", profile: "work")))
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.profileName == "work")
  }

  /// An agent without the profiles API keeps every call profile-less (#114): a stale row
  /// profile from the mirror is ignored.
  @Test func openSessionIgnoresProfileWithoutProfilesAPI() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off

    await store.send(.launchIntentReceived(.openSession(id: "s1", profile: "work")))
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "s1")
    #expect(store.state.liveChat?.profileName == nil)
  }

  // MARK: New chat with camera / photos

  /// The camera and photos intents run the "New session" path: compact seats a fresh chat
  /// under a single new marker, carrying the one-shot action for its first `.task`.
  @Test(arguments: [LaunchIntent.newChatWithCamera, .newChatWithPhotos])
  func cameraAndPhotosIntentsSeatANewChat(intent: LaunchIntent) async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }

    await store.send(.launchIntentReceived(intent)) {
      var chat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      chat.pendingLaunchAction = intent.launchAction
      $0.liveChat = chat
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
  }

  /// Over a reusable seat — already started, so no first `.task` will run — the camera /
  /// photos intent resets the draft and sends `startLaunchAction` straight to the slot, which
  /// opens that picker once (no teardown, no redial).
  @Test(arguments: [LaunchIntent.newChatWithCamera, .newChatWithPhotos])
  func cameraAndPhotosIntentsOverReusableSeatOpenThePicker(intent: LaunchIntent) async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "half-typed")
    seat.liveSessionID = "live-new"
    seat.status = .ready
    seat.hasStarted = true
    let opened = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.attachmentPicker.capturePhoto = { @Sendable in
        opened.withValue { $0.append("camera") }
        return PickedBatch()
      }
      $0.attachmentPicker.pickPhotos = { @Sendable in
        opened.withValue { $0.append("photos") }
        return PickedBatch()
      }
    }

    await store.send(.launchIntentReceived(intent)) {
      $0.liveChat?.composerText = ""
    }
    await store.receive(\.liveChat.startLaunchAction, intent.launchAction!)
    await store.finish()
    #expect(opened.value == [intent == .newChatWithCamera ? "camera" : "photos"])
    #expect(store.state.liveChat?.liveSessionID == "live-new", "the live session survives")
    #expect(store.state.slotGeneration == 0, "the seat is reused, not refilled")
  }

  /// Behind the re-auth modal the camera / photos intent still seats the chat, but never with
  /// a picker the user can't see: the action is dropped.
  @Test(arguments: [LaunchIntent.newChatWithCamera, .newChatWithPhotos])
  func cameraAndPhotosIntentsBehindReauthDropTheAction(intent: LaunchIntent) async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        reauth: ReauthFeature.State(serverURL: URL(string: "http://mac.tailnet:9119")!, method: .token)
      )
    ) {
      AppFeature()
    }

    await store.send(.launchIntentReceived(intent)) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
  }

  /// Cold launch: a camera / photos intent stashed before the list exists keeps its action on
  /// the launch auto-connect landing — the one landing that replays it.
  @Test(arguments: [LaunchIntent.newChatWithCamera, .newChatWithPhotos])
  func preHomeCameraAndPhotosIntentsKeepTheActionOnAutoConnect(intent: LaunchIntent) async {
    let store = TestStore(initialState: AppFeature.State(autoConnecting: true)) {
      AppFeature()
    }

    await store.send(.launchIntentReceived(intent)) {
      $0.pendingLaunchIntent = intent
    }
    await store.send(.autoConnectSucceeded(connection)) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingLaunchIntent = nil
      var chat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      chat.pendingLaunchAction = intent.launchAction
      $0.liveChat = chat
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
  }

  /// A manual login (onboarding fallback) can land minutes or hours after the tap, so a
  /// stashed camera / photos intent replays as a plain new chat — no picker pops up unasked.
  ///
  /// Two tests, not one parameterized: the onboarding landing mints a stack id, and every
  /// case of a parameterized test shares one cached stack-ID generator.
  @Test func preHomeCameraIntentDropsTheActionOnManualLogin() async {
    await assertIntentDropsTheActionOnManualLogin(.newChatWithCamera)
  }

  @Test func preHomePhotosIntentDropsTheActionOnManualLogin() async {
    await assertIntentDropsTheActionOnManualLogin(.newChatWithPhotos)
  }

  private func assertIntentDropsTheActionOnManualLogin(_ intent: LaunchIntent) async {
    let store = TestStore(initialState: AppFeature.State(autoConnecting: true)) {
      AppFeature()
    }

    await store.send(.launchIntentReceived(intent)) {
      $0.pendingLaunchIntent = intent
    }
    await store.send(.autoConnectFailed(connection, .unauthorized)) {
      $0.autoConnecting = false
      $0.onboarding = ConnectionFeature.State(
        recovering: self.connection.baseURL,
        token: self.connection.auth.token
      )
    }
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingLaunchIntent = nil
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
  }

  // MARK: Pre-home stash

  /// Cold launch from a widget row: the open is stashed with the stored server URL, then
  /// replayed through the push-tap routing when the list lands.
  @Test func preHomeOpenSessionStashedThenReplayedOnAutoConnect() async {
    let store = TestStore(initialState: AppFeature.State(autoConnecting: true)) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.push = PushClient.inMemory().client
    }

    await store.send(.launchIntentReceived(.openSession(id: "s-w", profile: nil))) {
      $0.pendingLaunchIntent = .openSession(id: "s-w", profile: nil)
      $0.pendingLaunchIntentServerURL = URL(string: "http://mac.tailnet:9119")!
    }
    #expect(store.state.liveChat == nil)

    store.exhaustivity = .off
    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingLaunchIntent = nil
      $0.pendingLaunchIntentServerURL = nil
    }
    await store.receive(\.home.delegate.openSession)
    await store.finish()
    #expect(store.state.liveChat?.storedSessionID == "s-w")
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s-w")
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
  }

  /// Cold launch from a row of ANOTHER profile than the persisted selection: the landing list
  /// is seeded with the profiles capability from the prefs, so the replay resumes the session
  /// under its own profile and leaves the selection alone.
  @Test func preHomeOpenSessionFromOtherProfileReplaysUnderItsProfile() async {
    let store = TestStore(initialState: AppFeature.State(autoConnecting: true)) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.preferences.loadSelectedProfileID = { "default" }
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.launchIntentReceived(.openSession(id: "s-w", profile: "work")))
    await store.send(.autoConnectSucceeded(connection))
    await store.finish()
    #expect(store.state.home?.profilesSupported == true)
    #expect(store.state.home?.selectedProfileName == "default")
    #expect(store.state.liveChat?.storedSessionID == "s-w")
    #expect(store.state.liveChat?.profileName == "work")
    #expect(store.state.path.last?.sessionKey == "s-w")
  }

  /// The stash survives an onboarding fallback and replays on a manual login to the SAME
  /// server (the compare ignores scheme/host casing).
  @Test func preHomeOpenSessionReplaysAfterManualLoginToSameServer() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "HTTP://Mac.tailnet:9119" }
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off

    await store.send(.launchIntentReceived(.openSession(id: "s-same", profile: nil)))
    await store.send(.onboarding(.delegate(.connected(connection))))
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "s-same")
  }

  /// A stash recorded under one server is DROPPED on a login to a different one — resuming a
  /// foreign id there would self-heal into a spurious empty chat. Exhaustive: a stray replay
  /// would fail the send.
  @Test func preHomeOpenSessionDroppedWhenLoginTargetsDifferentServer() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://old.tailnet:9119" }
      $0.push = PushClient.inMemory().client
    }

    await store.send(.launchIntentReceived(.openSession(id: "s-old", profile: nil))) {
      $0.pendingLaunchIntent = .openSession(id: "s-old", profile: nil)
      $0.pendingLaunchIntentServerURL = URL(string: "http://old.tailnet:9119")!
    }
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingLaunchIntent = nil
      $0.pendingLaunchIntentServerURL = nil
    }
  }

  /// …and in regular width the dropped open still leaves the detail seated (never blank).
  @Test func preHomeOpenSessionDroppedInRegularStillSeatsTheDetail() async {
    let store = TestStore(initialState: AppFeature.State(layout: .regular)) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://old.tailnet:9119" }
      $0.push = PushClient.inMemory().client
    }

    await store.send(.launchIntentReceived(.openSession(id: "s-old", profile: nil))) {
      $0.pendingLaunchIntent = .openSession(id: "s-old", profile: nil)
      $0.pendingLaunchIntentServerURL = URL(string: "http://old.tailnet:9119")!
    }
    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingLaunchIntent = nil
      $0.pendingLaunchIntentServerURL = nil
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    #expect(store.state.path.isEmpty)
  }

  /// A new-chat intent records no origin: it belongs to no session, so it replays on any
  /// server (the #93 rule stays unchanged).
  @Test func preHomeNewChatIntentRecordsNoOrigin() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://old.tailnet:9119" }
    }

    await store.send(.launchIntentReceived(.newChatWithCamera)) {
      $0.pendingLaunchIntent = .newChatWithCamera
    }
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingLaunchIntent = nil
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
  }

  // MARK: Last-wins against a push tap

  /// An open, then a push tap, pre-home → only the TAP replays; the open's origin goes with it.
  @Test func preHomeOpenSessionThenPushTapReplaysOnlyTheTap() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.push = PushClient.inMemory().client
    }

    await store.send(.launchIntentReceived(.openSession(id: "s-widget", profile: nil))) {
      $0.pendingLaunchIntent = .openSession(id: "s-widget", profile: nil)
      $0.pendingLaunchIntentServerURL = URL(string: "http://mac.tailnet:9119")!
    }
    await store.send(.pushTapped(PushTap(sessionID: "s-tap"))) {
      $0.pendingPushTap = PushTap(sessionID: "s-tap")
      $0.pendingPushTapServerURL = URL(string: "http://mac.tailnet:9119")!
      $0.pendingLaunchIntent = nil
      $0.pendingLaunchIntentServerURL = nil
    }
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
      $0.pendingPushTapServerURL = nil
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    await store.finish()
    #expect(store.state.liveChat?.storedSessionID == "s-tap")
    #expect(store.state.path.count == 1)
  }

  /// …and a push tap, then an open → only the OPEN replays.
  @Test func preHomePushTapThenOpenSessionReplaysOnlyTheOpen() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.push = PushClient.inMemory().client
    }

    await store.send(.pushTapped(PushTap(sessionID: "s-tap"))) {
      $0.pendingPushTap = PushTap(sessionID: "s-tap")
      $0.pendingPushTapServerURL = URL(string: "http://mac.tailnet:9119")!
    }
    await store.send(.launchIntentReceived(.openSession(id: "s-widget", profile: nil))) {
      $0.pendingLaunchIntent = .openSession(id: "s-widget", profile: nil)
      $0.pendingLaunchIntentServerURL = URL(string: "http://mac.tailnet:9119")!
      $0.pendingPushTap = nil
    }
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingLaunchIntent = nil
      $0.pendingLaunchIntentServerURL = nil
      $0.pendingPushTapServerURL = nil
    }
    // The open's replay; the landing itself cleared the tap stash (asserted above).
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.receive(\.home.delegate.openSession)
    await store.finish()
    #expect(store.state.liveChat?.storedSessionID == "s-widget")
    #expect(store.state.path.count == 1)
  }

  // MARK: Logout

  /// The open stash and its origin die with the identity: a retry-screen logout clears both,
  /// so a later login replays nothing (exhaustive).
  @Test func retryScreenLogoutClearsOpenSessionStash() async {
    let store = TestStore(
      initialState: AppFeature.State(
        connectionFailed: ConnectionFailedFeature.State(connection: connection, reason: .offline)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.keychain.deleteSession = { @Sendable in }
    }
    store.exhaustivity = .off

    await store.send(.launchIntentReceived(.openSession(id: "s-w", profile: nil)))
    await store.send(.connectionFailed(.delegate(.logoutConfirmed)))
    #expect(store.state.pendingLaunchIntent == nil)
    #expect(store.state.pendingLaunchIntentServerURL == nil)
    await store.finish()

    store.exhaustivity = .on
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
    }
  }

  /// The Settings disconnect and the re-auth quit clear it too (defensive — with `home`
  /// present the stash is structurally nil).
  @Test func disconnectAndQuitClearOpenSessionStash() async {
    var initial = AppFeature.State(home: SessionListFeature.State(connection: connection))
    initial.pendingLaunchIntent = .openSession(id: "s-w", profile: nil)
    initial.pendingLaunchIntentServerURL = URL(string: "http://mac.tailnet:9119")
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off
    await store.send(.home(.delegate(.disconnect)))
    #expect(store.state.pendingLaunchIntent == nil)
    #expect(store.state.pendingLaunchIntentServerURL == nil)

    var quitting = AppFeature.State(
      home: SessionListFeature.State(connection: connection),
      reauth: ReauthFeature.State(serverURL: URL(string: "http://mac.tailnet:9119")!, method: .token)
    )
    quitting.pendingLaunchIntent = .openSession(id: "s-w", profile: nil)
    quitting.pendingLaunchIntentServerURL = URL(string: "http://mac.tailnet:9119")
    let quitStore = TestStore(initialState: quitting) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
    }
    quitStore.exhaustivity = .off
    await quitStore.send(.reauth(.presented(.delegate(.quit))))
    #expect(quitStore.state.pendingLaunchIntent == nil)
    #expect(quitStore.state.pendingLaunchIntentServerURL == nil)
    await store.finish()
    await quitStore.finish()
  }

  // MARK: URL entry point

  /// The app's `.onOpenURL` hands every URL to the bridge: a recognised deep link is delivered
  /// as its intent; an unknown one is ignored — nothing delivered, nothing buffered for a later
  /// subscriber.
  @Test func bridgeRoutesKnownDeepLinksAndIgnoresUnknownOnes() async {
    let bridge = LaunchIntentBridge()
    // Unknown before anyone subscribes: must not be buffered for the cold-launch subscriber.
    #expect(bridge.received(url: URL(string: "hermesmobile://bogus")!) == false)
    #expect(bridge.received(url: URL(string: "https://example.com/session/s1")!) == false)
    #expect(bridge.received(url: URL(string: "hermes-file://preview?path=/tmp/a.txt")!) == false)
    let stream = bridge.stream()
    let open = LaunchIntent.openSession(id: "s 1", profile: "work")
    #expect(bridge.received(url: WidgetDeepLink.url(for: open)) == true)
    #expect(bridge.received(url: WidgetDeepLink.url(for: .newChatWithPhotos)) == true)
    // The first value is the first KNOWN link: the unknown ones left nothing behind.
    #expect(await collect(2, from: stream) == [open, .newChatWithPhotos])
  }

  private func collect<Value: Sendable>(
    _ count: Int,
    from stream: AsyncStream<Value>,
    timeout: Duration = .seconds(2)
  ) async -> [Value] {
    await withTaskGroup(of: [Value]?.self) { group in
      group.addTask {
        var values: [Value] = []
        for await value in stream {
          values.append(value)
          if values.count == count { break }
        }
        return values
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner ?? []
    }
  }
}
