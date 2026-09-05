import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct AppFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  // MARK: Launch auto-connect (Task 1)

  @Test func autoLoginWithStoredCredsOpensSessionList() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectSucceeded) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: self.connection)
    }
  }

  /// A persisted **gated (cookie) session** must auto-restore on relaunch — the production
  /// path now reads `loadSession` (rehydrating cookies), not `loadToken` (which is `nil` for
  /// cookie sessions). Without this it would force the user through onboarding every launch.
  @Test func autoLoginWithStoredCookieSessionOpensSessionList() async {
    let cookieSession = CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "mac.tailnet", path: "/")],
      username: "alice", provider: "basic"
    )
    let cookieConnection = ServerConnection(
      baseURL: URL(string: "http://mac.tailnet:9119")!, auth: .cookie(cookieSession)
    )
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .cookie(cookieSession) }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectSucceeded) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: cookieConnection)
    }
  }

  @Test func autoLoginWithInvalidTokenFallsBackToPrefilledOnboarding() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("bad") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.onboarding = ConnectionFeature.State(serverURL: "http://mac.tailnet:9119", token: "bad")
    }
    // #62 guard: an AUTH rejection must never raise the retry screen — retrying can't fix
    // dead credentials, so this path stays byte-identical to pre-#62 behavior.
    #expect(store.state.connectionFailed == nil)
  }

  /// A dead **cookie** session falls back to onboarding with only the URL prefilled (the
  /// password is never persisted, so the token field stays empty).
  @Test func autoLoginWithDeadCookieSessionFallsBackToOnboarding() async {
    let cookieSession = CookieSession(cookies: [], username: "alice", provider: "basic")
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .cookie(cookieSession) }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.onboarding = ConnectionFeature.State(serverURL: "http://mac.tailnet:9119", token: "")
    }
  }

  @Test func launchWithoutStoredCredsStaysOnOnboarding() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in nil }
      $0.preferences.loadServerURL = { nil }
    }
    // No creds → no state change, no auto-connect effect.
    await store.send(.task)
  }

  /// Exhaustive — this doubles as the no-replay guard for the manual-login path (#46):
  /// `.onboarding(.delegate(.connected))` with no stashed tap must emit no stray
  /// `.pushTapped` (an unexpected follow-up action would fail the send), mirroring
  /// `autoConnectWithoutStashEmitsNoReplay`.
  @Test func connectingShowsSessionList() async {
    let store = TestStore(initialState: AppFeature.State()) { AppFeature() }

    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
    }
  }

  /// Hardening, mirroring `.autoConnectSucceeded`: a retry screen and a live list must never
  /// coexist. If they ever did, `AppView` would render `home` while the `ifLet` child stayed
  /// alive and re-probed on every foreground for the process lifetime.
  @Test func manualLoginClearsAnyStandingRetryScreen() async {
    let store = TestStore(
      initialState: AppFeature.State(
        connectionFailed: ConnectionFailedFeature.State(
          connection: connection, reason: .unreachable
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.connectionFailed = nil
      $0.home = SessionListFeature.State(connection: self.connection)
    }
  }

  @Test func openingSessionFillsSlotAndPushesMarker() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }
    let session = Session(id: "20260610_abc", title: "Protocol chat")

    await store.send(.home(.delegate(.openSession(session)))) {
      // The chat state fills the app-level live slot; the path only gets a thin marker.
      $0.liveChat = ChatFeature.State(
        connection: self.connection,
        resumeStoredID: "20260610_abc",
        // Default profile → unscoped (nil), so the chat is byte-identical to single-profile.
        profileName: nil,
        title: "Protocol chat"
      )
      $0.path.append(ChatScreen.State(sessionKey: "20260610_abc"))
    }
  }

  @Test func creatingSessionFillsSlotWithNewChat() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      // A brand-new chat has no session key yet — the marker resolves later.
      $0.path.append(ChatScreen.State(sessionKey: nil))
    }
  }

  @Test func creatingSessionWithPrefilledComposerSeedsDraft() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: PushSetup.installPrompt)))) {
      $0.liveChat = ChatFeature.State(
        connection: self.connection, profileName: nil, composerText: PushSetup.installPrompt
      )
      $0.path.append(ChatScreen.State(sessionKey: nil))
    }
  }

  @Test func openingSessionUnderCustomProfilePassesProfileToChat() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        )
      )
    ) {
      AppFeature()
    }
    let session = Session(id: "20260610_abc", title: "Protocol chat")

    await store.send(.home(.delegate(.openSession(session)))) {
      $0.liveChat = ChatFeature.State(
        connection: self.connection,
        resumeStoredID: "20260610_abc",
        profileName: "work",
        title: "Protocol chat"
      )
      $0.path.append(ChatScreen.State(sessionKey: "20260610_abc"))
    }
  }

  @Test func creatingSessionUnderCustomProfilePassesProfileToChat() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: "work", composerText: "")
      $0.path.append(ChatScreen.State(sessionKey: nil))
    }
  }

  // MARK: - Live chat slot lifecycle (keep-alive plan, Tasks 1–2)

  /// Popping back to the list with an IDLE chat tears the slot down (nothing to keep
  /// alive): flush the snapshot, cancel everything, clear the slot. The teardown is
  /// deferred to `.chatViewDisappeared` (the view actually left — pop animation done);
  /// `.popFrom` itself does nothing so the outgoing screen never blanks mid-animation.
  @Test func popTearsDownAndClearsSlot() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      // The pop flushes the snapshot (`.persistNow`), which stamps `updatedAt`.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let session = Session(id: "s1", title: "Chat")

    await store.send(.home(.delegate(.openSession(session))))
    #expect(store.state.liveChat != nil)

    // Pop-start: path empties, slot untouched (the screen is still animating away).
    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    #expect(store.state.liveChat != nil)

    // The view finished disappearing → mic cleanup + the idle teardown sequence.
    await store.send(.chatViewDisappeared)
    await store.receive(\.liveChat.viewDisappeared)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    #expect(store.state.path.isEmpty)
  }

  /// An idle pop with queued prompts waiting (#66) keeps the slot like a running turn
  /// would: the queue is in-memory only, so the idle-pop teardown must not destroy it.
  @Test func popWithQueuedWorkKeepsSlot() async {
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    liveChat.liveSessionID = "live1"
    liveChat.isQueueParked = true
    liveChat.queuedPrompts = [QueuedPrompt(id: UUID(1), text: "held")]
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    await store.send(.chatViewDisappeared)
    await store.receive(\.liveChat.viewDisappeared)
    #expect(store.state.liveChat != nil, "queued work keeps the slot alive across the pop")
  }

  /// Turn-end-while-detached with entries queued (#66): the slot's own reducer drained the
  /// head in the same reduction that emitted `runningChanged(false)`, so the parent keeps
  /// the slot (the drained turn streams into it). Once the queue is empty and THAT turn
  /// ends, the normal detached teardown runs.
  @Test func detachedTurnEndDrainsInsteadOfTearingDownUntilQueueEmpties() async {
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    liveChat.liveSessionID = "live1"
    liveChat.status = .ready
    liveChat.isSending = true
    liveChat.queuedPrompts = [QueuedPrompt(id: UUID(1), text: "next")]
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: liveChat // detached: empty path
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object(["status": .string("streaming")]) }
    }
    store.exhaustivity = .off

    // First turn ends detached → the drain claims the head → slot survives.
    await store.send(.liveChat(.gatewayEvent(.messageComplete(text: "", usage: nil))))
    await store.receive(\.liveChat.delegate.runningChanged)
    #expect(store.state.liveChat != nil, "mid-drain slot must survive turn end")
    #expect(store.state.liveChat?.drainingEntry != nil)

    // The drained turn starts (entry consumed) and later ends with the queue empty →
    // the normal detached teardown finally runs.
    await store.send(.liveChat(.gatewayEvent(.messageStart)))
    await store.send(.liveChat(.gatewayEvent(.messageComplete(text: "", usage: nil))))
    await store.receive(\.clearLiveChat)
    #expect(store.state.liveChat == nil)
  }

  /// A queue PARKED while detached (#66, e.g. the turn errored) keeps the slot alive
  /// without draining — held entries wait for the user, and nothing fires on its own.
  @Test func detachedParkedQueueKeepsSlotWithoutDraining() async {
    let submits = LockIsolated(0)
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    liveChat.liveSessionID = "live1"
    liveChat.status = .ready
    liveChat.isSending = true
    liveChat.isQueueParked = true
    liveChat.queuedPrompts = [QueuedPrompt(id: UUID(1), text: "held")]
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "prompt.submit" { submits.withValue { $0 += 1 } }
        return .object([:])
      }
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.gatewayEvent(.messageComplete(text: "", usage: nil))))
    await store.receive(\.liveChat.delegate.runningChanged)
    #expect(store.state.liveChat != nil, "parked entries keep the slot")
    #expect(store.state.liveChat?.queuedPrompts.count == 1)
    #expect(submits.value == 0, "parked queue never fires on its own")
  }

  /// Opening a different session while the slot is occupied flushes the old chat's snapshot
  /// and tears it down FIRST (its socket must not leak into the replacement), then fills the
  /// slot + resets the marker.
  @Test func openingAnotherSessionReplacesSlotAfterTeardown() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    liveChat.liveSessionID = "old-live"
    liveChat.model = "claude-opus-4-8"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 55))
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.openSession(Session(id: "new", title: "New chat")))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    // The replacement routes through the nil-out: `ifLet` cancels the outgoing chat's
    // remaining (un-ID'd one-shot) effects before the new chat fills the slot.
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(
        connection: self.connection, resumeStoredID: "new", profileName: nil, title: "New chat"
      )
    }
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "new")
    // The outgoing chat's snapshot was flushed before the replacement filled the slot.
    #expect(snapshotClient.loadSnapshot("old")?.model == "claude-opus-4-8")
  }

  /// A branch created from the open chat (#34) replaces the slot with a chat PRIMED from
  /// the create response: the parent chat is torn down THROUGH the nil-out, the new chat
  /// carries the stored id (marker identity) + `attachLiveSessionID` (so it attaches to
  /// the live seeded session via `session.activate` — the branch has no DB row until its
  /// first prompt, so it must NOT resume by stored id), the path is SET to the single new
  /// marker, and a session list reload is requested AFTER the replacement chain.
  @Test func branchCreatedReplacesSlotAndReloadsList() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "parent")
    liveChat.liveSessionID = "parent-live"
    liveChat.model = "claude-opus-4-8"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "parent")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.liveChat(.delegate(.branchCreated(.init(
      handle: SessionHandle(sessionID: "branch-live", storedSessionID: "branch-1"),
      seed: .init(text: "seeded answer", parentSessionID: "parent")
    )))))
    // Slot replacement goes through the mandatory nil-out, never a direct state swap —
    // the parent's snapshot is flushed FIRST, then teardown, clear, fill, and only then
    // the list reload (so the refetch can't interleave into a half-replaced slot).
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      var chat = ChatFeature.State(connection: self.connection, resumeStoredID: "branch-1")
      chat.attachLiveSessionID = "branch-live"
      // The seed rides along so a server-side orphan reap of the never-prompted branch
      // can be healed by replaying the seeded create.
      chat.branchSeed = .init(text: "seeded answer", parentSessionID: "parent")
      $0.liveChat = chat
    }
    // List reload requested so the nested branch row appears once it exists server-side.
    await store.receive(\.home.pulledToRefresh)
    // Path is SET to the single new marker — never stacked on the parent's.
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "branch-1")
    // The parent chat's snapshot was flushed before the replacement filled the slot.
    #expect(snapshotClient.loadSnapshot("parent")?.model == "claude-opus-4-8")

    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  /// Branch open threads the selected profile like any list-tap open — the replacement
  /// chat carries `scopedProfileName` so resume/history scope to the right `state.db`.
  @Test func branchCreatedThreadsActiveProfileIntoNewChat() async {
    var home = SessionListFeature.State(connection: connection)
    home.profilesSupported = true
    home.selectedProfileName = "work"
    let store = TestStore(
      initialState: AppFeature.State(
        home: home,
        path: StackState([ChatScreen.State(sessionKey: "parent")]),
        liveChat: ChatFeature.State(
          connection: connection, resumeStoredID: "parent", profileName: "work"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.liveChat(.delegate(.branchCreated(.init(
      handle: SessionHandle(sessionID: "branch-live", storedSessionID: "branch-1"),
      seed: .init(text: "seeded answer", parentSessionID: "parent")
    )))))
    await store.receive(\.fillLiveChat) {
      var chat = ChatFeature.State(
        connection: self.connection, resumeStoredID: "branch-1", profileName: "work"
      )
      chat.attachLiveSessionID = "branch-live"
      chat.branchSeed = .init(text: "seeded answer", parentSessionID: "parent")
      $0.liveChat = chat
    }
    await store.receive(\.home.pulledToRefresh)

    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  /// `branchCreated` with no session list (defensive — the slot shouldn't outlive `home`)
  /// is a no-op rather than routing actions into a nil child.
  @Test func branchCreatedWithoutHomeIsNoOp() async {
    let store = TestStore(
      initialState: AppFeature.State(
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "parent")
      )
    ) {
      AppFeature()
    }

    await store.send(.liveChat(.delegate(.branchCreated(.init(
      handle: SessionHandle(sessionID: "branch-live", storedSessionID: "branch-1"),
      seed: .init(text: "seeded answer", parentSessionID: "parent")
    )))))
    await store.finish()
  }

  /// Logout (disconnect from Settings) clears the slot unconditionally along with the path.
  @Test func disconnectClearsLiveChatSlot() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.disconnect))) {
      $0.home = nil
      $0.liveChat = nil
      $0.path = .init()
    }
    await store.finish()
  }

  /// The identity teardowns drop the slot by ASSIGNMENT, so no `ChatFeature.teardown` runs to
  /// release the mic — and `ifLet`'s auto-cancel reaches the level/tick EFFECTS but not the
  /// `AVAudioRecorder` and audio session the client holds. In the split layout Settings is on
  /// screen beside a recording composer, so each of these must cancel the recorder itself.
  @Test func identityTeardownsReleaseARecordingSlotsMicrophone() async {
    var recording = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    recording.recording = .recording

    for action in [
      AppFeature.Action.home(.delegate(.disconnect)),
      .connectionFailed(.delegate(.logoutConfirmed)),
      .reauth(.presented(.delegate(.quit))),
      .reauth(.presented(.delegate(.reauthenticated(
        connection: freshCookieConnection(username: "bob"), sameUser: false
      )))),
    ] {
      let cancelled = LockIsolated(0)
      let store = TestStore(
        initialState: AppFeature.State(
          home: SessionListFeature.State(connection: connection),
          path: StackState([ChatScreen.State(sessionKey: "s1")]),
          liveChat: recording,
          connectionFailed: ConnectionFailedFeature.State(connection: connection, reason: .offline),
          reauth: ReauthFeature.State(
            serverURL: connection.baseURL, method: .password,
            provider: "basic", previousUsername: "alice"
          )
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.preferences = .inMemory()
        $0.push = PushClient.inMemory().client
        $0.audioRecorder.cancel = { cancelled.withValue { $0 += 1 } }
      }
      store.exhaustivity = .off

      await store.send(action)
      await store.finish()
      #expect(cancelled.value == 1, "\(action) left the recorder running")
    }
  }

  /// The same teardowns raise no recorder call for an IDLE slot — no audio session is touched
  /// on an ordinary logout.
  @Test func identityTeardownsLeaveAnIdleSlotsRecorderAlone() async {
    let cancelled = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = PushClient.inMemory().client
      $0.audioRecorder.cancel = { cancelled.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.disconnect)))
    await store.finish()
    #expect(cancelled.value == 0)
  }

  /// Popping mid-turn KEEPS the slot untouched — no persist/teardown/clear fires (the send
  /// is exhaustive: any follow-up action would fail it), and the detached slot's fold still
  /// reduces streaming events, so rows keep accumulating while the user sits on the list.
  @Test func popWhileRunningKeepsSlotAndKeepsStreaming() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let clock = TestClock()
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }

    // The turn's live thinking row + elapsed ticker start before the pop.
    let thinkingID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    await store.send(.liveChat(.gatewayEvent(.messageStart))) {
      $0.liveChat?.transcript = [ChatRow(
        id: thinkingID, kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
      )]
      $0.liveChat?.thinkingRowID = thinkingID
    }
    await store.receive(\.liveChat.delegate.runningChanged)
    await store.receive(\.home.setSessionRunning)

    // Exhaustive: the pop only empties the path — the running slot is untouched.
    await store.send(.path(.popFrom(id: store.state.path.ids.last!))) {
      $0.path = StackState()
    }
    #expect(store.state.liveChat != nil)

    // The view finishing its pop animation (what the destination actually sends) forwards
    // mic/voice cleanup only — a RUNNING detached slot is still not torn down (exhaustive:
    // any teardown follow-up would fail here).
    await store.send(.chatViewDisappeared)
    await store.receive(\.liveChat.viewDisappeared)
    #expect(store.state.liveChat != nil)

    // The elapsed ticker keeps ticking while detached — the timer is continuous across the
    // pop (no freeze, no restart from zero on re-open). The 1s advance also fires the
    // debounced snapshot persist `messageStart`'s content change scheduled (same 1s window)
    // — both effects living on after the pop is exactly the point.
    await clock.advance(by: .seconds(1))
    await store.receive(\.liveChat.persistSnapshotTick)
    await store.receive(\.liveChat.thinkingTick) {
      $0.liveChat?.thinkingSeconds = 1
    }

    // A streaming delta arriving after the pop still mutates the detached slot's transcript
    // (the socket fold is slot-rooted, not screen-rooted) — the thinking row is not lost.
    let assistantID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    await store.send(.liveChat(.gatewayEvent(.messageDelta(text: "still streaming")))) {
      $0.liveChat?.transcript = [
        ChatRow(id: assistantID, kind: .message(role: .assistant, text: "still streaming", isComplete: false)),
        ChatRow(id: thinkingID, kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
      $0.liveChat?.streamingRowID = assistantID
    }
    // The delta's debounced persist + the live ticker are still pending — living proof the
    // slot's effects survived the pop. Cancel them via an explicit app-policy teardown.
    await store.send(.liveChat(.teardown))
  }

  /// Socket-leak guard (Task 7 acceptance): the idle-pop teardown path cancels the socket
  /// effect (`CancelID.socket`) exactly once — one dial, one stream termination, nothing
  /// left running and nothing double-cancelled. The gateway client is instrumented to count
  /// connects and terminations.
  @Test func idlePopCancelsSocketExactlyOnce() async {
    let connectCount = LockIsolated(0)
    let cancelCount = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCount.withValue { $0 += 1 }
        return AsyncStream { continuation in
          continuation.onTermination = { _ in cancelCount.withValue { $0 += 1 } }
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // First appearance dials exactly one socket.
    await store.send(.liveChat(.task))
    await waitUntil { connectCount.value == 1 }
    #expect(cancelCount.value == 0)

    // The idle pop's teardown (deferred until the view disappeared) terminates that one
    // stream (a leak would fail the bounded wait).
    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    await store.send(.chatViewDisappeared)
    await store.receive(\.liveChat.viewDisappeared)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await waitUntil { cancelCount.value == 1 }
    // The teardown never redialed.
    #expect(connectCount.value == 1)
  }

  /// Socket-leak guard (Task 7 acceptance): replacing the slot cancels the OLD chat's socket
  /// exactly once BEFORE the replacement dials its own — asserted before the new `.task` so
  /// the fresh connect's `cancelInFlight` can't mask a missing teardown. The new socket then
  /// stays alive until its own teardown.
  @Test func slotReplacementCancelsOldSocketExactlyOnce() async {
    let connectCount = LockIsolated(0)
    let cancelCount = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "old")
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCount.withValue { $0 += 1 }
        return AsyncStream { continuation in
          continuation.onTermination = { _ in cancelCount.withValue { $0 += 1 } }
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.liveChat(.task))
    await waitUntil { connectCount.value == 1 }

    // Opening a different session tears the old slot down first (through the nil-out, so
    // even un-ID'd one-shot effects are cancelled): its socket terminates exactly once,
    // before any replacement dial.
    await store.send(.home(.delegate(.openSession(Session(id: "new")))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat)
    await store.receive(\.fillLiveChat)
    await waitUntil { cancelCount.value == 1 }
    #expect(connectCount.value == 1)

    // The replacement dials its own fresh stream; the count proves the old cancel didn't
    // hit the new socket (position-scoped cancel IDs would otherwise cross-cancel).
    await store.send(.liveChat(.task))
    await waitUntil { connectCount.value == 2 }
    #expect(cancelCount.value == 1)

    // And the new socket's own teardown is the second (and last) termination.
    await store.send(.liveChat(.teardown))
    await waitUntil { cancelCount.value == 2 }
  }

  /// Replacement leak guard: an in-flight ONE-SHOT RPC effect of the outgoing chat (here a
  /// `session.resume` hydrate — one-shots carry NO cancel ID, so `.teardown` alone can't
  /// reach them) must be cancelled by the replacement's nil-out (`.clearLiveChat` →
  /// `ifLet` auto-cancel). Were it leaked, its `.activateResult` would reduce into the
  /// REPLACEMENT chat — overwriting the new chat's session ids and rebuilding its
  /// transcript from the OLD session's history.
  @Test func slotReplacementDropsInFlightHydrateOfOldChat() async {
    let clock = TestClock()
    var oldChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    oldChat.status = .ready
    oldChat.hasStarted = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: oldChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else { return .object([:]) }
        // A slow resume: still in flight when the slot is replaced.
        try await clock.sleep(for: .seconds(5))
        return .object([
          "session_id": .string("old-live"),
          "stored_session_id": .string("old"),
          "messages": .array([
            .object(["id": .number(1), "role": .string("user"), "content": .string("old history")]),
          ]),
          "running": .bool(false),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Kick off the old chat's hydrate (healthy socket → direct hydrate, no redial).
    await store.send(.liveChat(.reattached))

    // Replace the slot while that hydrate is still in flight.
    await store.send(.home(.delegate(.openSession(Session(id: "new", title: "New chat")))))
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.storedSessionID == "new")

    // Let the old RPC's clock fire: its task was cancelled by the nil-out, so NO
    // `.activateResult` may deliver into the replacement chat.
    await clock.advance(by: .seconds(5))
    await store.finish()
    #expect(store.state.liveChat?.storedSessionID == "new")
    #expect(store.state.liveChat?.liveSessionID == nil) // the old live id never leaked in
    #expect(store.state.liveChat?.transcript.isEmpty == true) // nor the old history
  }

  /// A detached slot (user popped to the list) is torn down the moment its turn ends — the
  /// authoritative `runningChanged(running: false)` (message.complete / error / a hydrate
  /// confirming stopped) flushes the snapshot, cancels the effects, and clears the slot.
  /// A `running: true` change must NOT tear anything down.
  @Test func turnEndingWhileDetachedTearsDownSlot() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true
    chat.model = "claude-opus-4-8"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1", isActive: true)]
        ),
        // Empty path — the chat streams detached.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // Still running → glow routing only; the detached slot stays.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: true))))
    await store.receive(\.home.setSessionRunning)
    #expect(store.state.liveChat != nil)

    // Turn ended while detached → glow clears, then flush + teardown + clear.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: false))))
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = false
    }
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    // The snapshot flush landed before the slot cleared.
    #expect(snapshotClient.loadSnapshot("s1")?.model == "claude-opus-4-8")
  }

  /// A CLIENT-SIDE turn end must also tear a detached slot down: the submit RPC failing
  /// (e.g. a 30s timeout after the user already popped to the list) means NO server event
  /// will ever follow — without `promptSubmitFailed` emitting `runningChanged(false)`, the
  /// idle detached chat would keep its socket, backoff, and persist effects forever.
  @Test func promptFailureWhileDetachedTearsDownSlot() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true
    chat.model = "claude-opus-4-8"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1", isActive: true)]
        ),
        // Empty path — the user popped while the submit RPC was still in flight.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // The submit fails after the pop: client-side turn end → glow clears, slot torn down.
    await store.send(.liveChat(.promptSubmitFailed(message: "request timed out: prompt.submit")))
    await store.receive(\.liveChat.delegate.runningChanged)
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = false
    }
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    // The snapshot flush landed before the slot cleared.
    #expect(snapshotClient.loadSnapshot("s1")?.model == "claude-opus-4-8")
  }

  /// Same client-side turn end via the attachment path: a failed upload (no server event
  /// will follow) must tear a detached slot down like `promptSubmitFailed` does.
  @Test func attachmentFailureWhileDetachedTearsDownSlot() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1", isActive: true)]
        ),
        liveChat: chat // empty path — detached
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.attachmentUploadFailed(message: "boom")))
    await store.receive(\.liveChat.delegate.runningChanged)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
  }

  /// Archiving the slot's session from the list tears the (detached) slot down FIRST — its
  /// socket must not keep streaming into a now-archived session. Archiving a DIFFERENT
  /// session leaves the slot alone.
  @Test func archivingSlotSessionTearsDownSlot() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1"), Session(id: "other")]
        ),
        // Empty path — the user is on the list (where archive lives).
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // Archiving an unrelated session: the slot survives.
    await store.send(.home(.archiveButtonTapped(id: "other")))
    await store.send(.home(.confirmationDialog(.presented(.confirmArchive(id: "other")))))
    await store.receive(\.home.delegate.sessionArchived)
    await store.skipReceivedActions()
    #expect(store.state.liveChat != nil)

    // Archiving the slot's session: flush + teardown + clear.
    await store.send(.home(.archiveButtonTapped(id: "s1")))
    await store.send(.home(.confirmationDialog(.presented(.confirmArchive(id: "s1")))))
    await store.receive(\.home.delegate.sessionArchived)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
  }

  /// Archive of the slot's session whose PATCH then FAILS: the list restores the row
  /// locally (optimistic rollback), but the slot deliberately STAYS torn down — the
  /// teardown ran on the optimistic `sessionArchived` delegate, and resurrecting live
  /// slot state for a rare failure path isn't worth replaying it; re-opening simply
  /// resumes the session fresh. This pins that accepted behavior.
  @Test func archiveFailureRestoresRowButSlotStaysDown() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        // Empty path — the user is on the list (where archive lives).
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in throw RESTError.unreachable }
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.home(.archiveButtonTapped(id: "s1")))
    await store.send(.home(.confirmationDialog(.presented(.confirmArchive(id: "s1")))))
    // Optimistic: the slot is torn down FIRST (before the PATCH round-trips)…
    await store.receive(\.home.delegate.sessionArchived)
    await store.receive(\.clearLiveChat)
    // …then the PATCH fails and the row is restored — but the slot stays down.
    await store.receive(\.home.archiveFailed)
    #expect(store.state.home?.sessions[id: "s1"] != nil)
    #expect(store.state.liveChat == nil)
  }

  /// Deleting the slot's session (issue #73) tears the (possibly detached) slot down —
  /// its socket must not keep streaming into a session the server no longer has — and
  /// wipes the session's cached snapshot + turn anchor so it can never repaint from the
  /// non-authoritative cache. The teardown deliberately SKIPS the snapshot flush
  /// (`flushSnapshot: false`): flushing would re-save the very snapshot the wipe deletes.
  /// The flush skip is pinned by SPYING on the cache writes — `exhaustivity = .off` would
  /// silently skip a re-introduced `persistNow`, and the wipe running last would mask a
  /// re-save in the final cache state, so neither can catch the regression on its own.
  @Test func deletingSlotSessionTearsDownSlotAndWipesSnapshot() async {
    let snapshots = ChatSnapshotClient.inMemory()
    snapshots.saveSnapshot("s1", ChatSnapshot(model: "gpt-5", rows: []))
    snapshots.setTurnAnchor("s1", Date(timeIntervalSince1970: 5))
    // Spy wrapper: seeded above through the raw client, so anything recorded below is a
    // write made DURING the delete — a flush would save the snapshot and (with
    // `isSending = true`) re-set the turn anchor.
    let writes = LockIsolated<[String]>([])
    var spy = snapshots
    spy.saveSnapshot = { @Sendable id, snapshot in
      writes.withValue { $0.append("save:\(id)") }
      snapshots.saveSnapshot(id, snapshot)
    }
    spy.setTurnAnchor = { @Sendable id, date in
      writes.withValue { $0.append("anchor:\(id)") }
      snapshots.setTurnAnchor(id, date)
    }

    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        // Empty path — the user is on the list (where delete lives).
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in }
      $0.chatSnapshot = spy
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.home(.deleteButtonTapped(id: "s1")))
    await store.send(.home(.confirmationDialog(.presented(.confirmDelete(id: "s1")))))
    // The delegate fires FIRST (optimistically, before the DELETE round-trips)…
    await store.receive(\.home.delegate.sessionDeleted)
    // …then the slot goes down: teardown + clear (no persist flush for a deleted session).
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.finish()
    #expect(writes.value.isEmpty) // the flush was skipped — nothing re-saved the snapshot
    #expect(snapshots.loadSnapshot("s1") == nil)
    #expect(snapshots.turnAnchor("s1") == nil)
  }

  /// Deleting a session that is NOT the slot's leaves the live chat untouched but still
  /// wipes the deleted session's cached snapshot + turn anchor. The slot session's own
  /// cache entry survives.
  @Test func deletingNonSlotSessionWipesItsSnapshotAndKeepsSlot() async {
    let snapshots = ChatSnapshotClient.inMemory()
    snapshots.saveSnapshot("other", ChatSnapshot(model: "gpt-5", rows: []))
    snapshots.setTurnAnchor("other", Date(timeIntervalSince1970: 5))
    snapshots.saveSnapshot("s1", ChatSnapshot(model: "keep-me", rows: []))

    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1"), Session(id: "other")]
        ),
        // Empty path — the user is on the list (where delete lives).
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in }
      $0.chatSnapshot = snapshots
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.home(.deleteButtonTapped(id: "other")))
    await store.send(.home(.confirmationDialog(.presented(.confirmDelete(id: "other")))))
    await store.receive(\.home.delegate.sessionDeleted)
    await store.skipReceivedActions()
    await store.finish()
    #expect(store.state.liveChat != nil)
    #expect(snapshots.loadSnapshot("other") == nil)
    #expect(snapshots.turnAnchor("other") == nil)
    #expect(snapshots.loadSnapshot("s1") != nil) // the slot session's cache is untouched
  }

  /// A deleted session's pending-approval badge entry is dropped — opening the session
  /// (the normal clear path) is impossible once it no longer exists, so a kept entry
  /// would badge the app icon forever. The entry is dropped on the CONFIRMED delete
  /// (`sessionDeleteSucceeded`), not at initiation — see the failure test below. Also
  /// covers the no-slot shape: with `liveChat` nil the handler wipes the cache only,
  /// no teardown.
  @Test func deletingABadgedSessionClearsItsApprovalBadgeEntry() async {
    let snapshots = ChatSnapshotClient.inMemory()
    snapshots.saveSnapshot("other", ChatSnapshot(model: "gpt-5", rows: []))
    let badge = LockIsolated<Int?>(nil)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "other")]
        ),
        pendingApprovalSessionIDs: ["other", "keep"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in }
      $0.chatSnapshot = snapshots
      $0.push.setBadgeCount = { @Sendable count in badge.setValue(count) }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.home(.deleteButtonTapped(id: "other")))
    await store.send(.home(.confirmationDialog(.presented(.confirmDelete(id: "other")))))
    // Initiation wipes the cache but leaves the badge entry alone…
    await store.receive(\.home.delegate.sessionDeleted)
    // …only the server-confirmed delete drops it.
    await store.receive(\.home.delegate.sessionDeleteSucceeded) {
      $0.pendingApprovalSessionIDs = ["keep"]
    }
    await store.finish()
    #expect(badge.value == 1) // the icon badge follows the surviving entry count
    #expect(snapshots.loadSnapshot("other") == nil)
    #expect(store.state.liveChat == nil) // never had a slot — nothing torn down
  }

  /// A FAILED delete keeps the approval badge entry: the approval is still pending on
  /// the server (opening the restored row remains the clear path), and nothing short of
  /// a fresh approval push would repopulate a prematurely-cleared entry. Only the badge
  /// waits for confirmation — the snapshot wipe/teardown asymmetry stays optimistic.
  @Test func failedDeleteKeepsTheApprovalBadgeEntry() async {
    let badge = LockIsolated<Int?>(nil)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "other")]
        ),
        pendingApprovalSessionIDs: ["other"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw RESTError.unreachable }
      $0.chatSnapshot = .inMemory()
      $0.push.setBadgeCount = { @Sendable count in badge.setValue(count) }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.home(.deleteButtonTapped(id: "other")))
    await store.send(.home(.confirmationDialog(.presented(.confirmDelete(id: "other")))))
    await store.skipReceivedActions()
    await store.finish()
    #expect(store.state.pendingApprovalSessionIDs == ["other"]) // entry survives the failure
    #expect(badge.value == nil) // setBadge never ran — the count never changed
    // And the row itself was rolled back by the list, so the clear path still exists.
    #expect(store.state.home?.sessions[id: "other"] != nil)
  }

  /// Re-opening the slot's OWN session from the list (tapping the glowing row of a detached
  /// running turn) must NOT build a fresh `ChatFeature.State` — the accumulated detached
  /// rows and composer draft survive. The marker is pushed back and `.reattached` hydrates
  /// against the live socket without redialing it.
  @Test func reopeningSlotSessionReattachesKeepingDetachedRows() async {
    let connectCalls = LockIsolated(0)
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true
    chat.isSending = true
    chat.composerText = "unsent draft"
    // Rows accumulated while detached: the live thinking row the server's payload can't
    // rebuild (#26) — a re-init would lose it.
    let thinkingID = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!
    chat.transcript = [
      ChatRow(id: thinkingID, kind: .thinking(
        reasoning: "detached reasoning", status: nil, elapsedSeconds: 3, isComplete: false
      ))
    ]
    chat.thinkingRowID = thinkingID

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        // Empty path — the user popped to the list; the slot streams detached.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
      $0.hermesGateway.send = { @Sendable method, _ in
        // The hydrate may fan out a follow-up (e.g. `session.usage`) — only the resume
        // payload matters here.
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live1"),
          "stored_session_id": .string("s1"),
          "messages": .array([
            .object(["id": .number(1), "role": .string("user"), "content": .string("the question")]),
          ]),
          "running": .bool(true),
          "info": .object(["model": .string("claude-opus-4-8")]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.delegate(.openSession(Session(id: "s1")))))
    // Marker re-pushed; the slot state itself was NOT re-inited (draft survives).
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.composerText == "unsent draft")

    await store.receive(\.liveChat.reattached)
    await store.receive(\.liveChat.activateResult.success)

    // The healthy socket was never redialed, the hydrate landed, and the detached live
    // thinking row survived the server-authoritative rebuild (#26 preservation).
    #expect(connectCalls.value == 0)
    #expect(store.state.liveChat?.model == "claude-opus-4-8")
    #expect(store.state.liveChat?.composerText == "unsent draft")
    #expect(store.state.liveChat?.transcript.contains { row in
      if case let .thinking(reasoning, _, _, isComplete) = row.kind {
        return reasoning == "detached reasoning" && !isComplete
      }
      return false
    } == true)

    await store.send(.liveChat(.teardown))
  }

  // MARK: - Re-auth routing (Task 6)

  private var cookieConnection: ServerConnection {
    ServerConnection(
      baseURL: URL(string: "http://mac.tailnet:9119")!,
      auth: .cookie(CookieSession(
        cookies: [SerializedCookie(name: "hermes_session_at", value: "old", domain: "mac.tailnet", path: "/")],
        username: "alice",
        provider: "basic"
      ))
    )
  }

  private func freshCookieConnection(username: String) -> ServerConnection {
    ServerConnection(
      baseURL: URL(string: "http://mac.tailnet:9119")!,
      auth: .cookie(CookieSession(
        cookies: [SerializedCookie(name: "hermes_session_at", value: "new", domain: "mac.tailnet", path: "/")],
        username: username,
        provider: "basic"
      ))
    )
  }

  @Test func sessionExpiredPresentsReauthModalSeededFromChat() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: cookieConnection)
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.delegate(.sessionExpired))) {
      $0.reauth = ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!,
        method: .password,
        provider: "basic",
        previousUsername: "alice"
      )
    }
  }

  /// The slot chat can be DETACHED (user popped to the list) when the session dies — the
  /// re-auth modal must still surface at root (locked decision: reauth surfaces at root
  /// even while detached).
  @Test func sessionExpiredWhileDetachedStillPresentsReauthModal() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        // Empty path — the chat lives only in the slot.
        liveChat: ChatFeature.State(connection: cookieConnection)
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.delegate(.sessionExpired))) {
      $0.reauth = ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!,
        method: .password,
        provider: "basic",
        previousUsername: "alice"
      )
    }
  }

  @Test func sameUserReauthResumesChatInPlace() async {
    let fresh = freshCookieConnection(username: "alice")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: cookieConnection),
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      // A never-finishing socket so the resume's `connect` effect stays alive (no trailing
      // `gatewayClosed`/reconnect churn); we cancel it via `.teardown` at the end.
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.reauth(.presented(.delegate(.reauthenticated(connection: fresh, sameUser: true))))) {
      $0.reauth = nil
    }
    // Same user → the slot chat is told to resume with the fresh connection (stays in place).
    await store.receive(\.liveChat.resumeAfterReauth) {
      $0.liveChat?.connection = fresh
      $0.liveChat?.awaitingReauth = false
      $0.liveChat?.status = .reconnecting
    }
    // Tear down the live socket the resume opened.
    await store.send(.liveChat(.teardown))
  }

  /// A same-user re-auth must refresh the LIST's connection too, not just the slot's: it is
  /// the snapshot every later chat is built from (a row tap, the regular-width archive/delete
  /// refill, the profile reseat) and the one its own REST calls carry. Left stale, those
  /// reconnect under the dead credentials and, in cookie mode, `wsTicket` pushes the expired
  /// jar back into the shared cookie storage — undoing the login that just succeeded.
  @Test func sameUserReauthRefreshesTheListsConnectionToo() async {
    let fresh = freshCookieConnection(username: "alice")
    var seat = ChatFeature.State(connection: cookieConnection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        liveChat: seat,
        layout: .regular,
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reauth(.presented(.delegate(.reauthenticated(connection: fresh, sameUser: true))))) {
      $0.reauth = nil
      $0.home?.connection = fresh
    }
    await store.receive(\.liveChat.resumeAfterReauth)

    // The refill the sidebar can trigger while the fresh login is still new now carries the
    // fresh credentials, not the expired jar.
    await store.send(.home(.delegate(.sessionArchived(id: "live-new"))))
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.connection == fresh)

    await store.send(.liveChat(.teardown))
  }

  @Test func differentUserReauthPopsToListAndClearsIdentityPrefs() async {
    let fresh = freshCookieConnection(username: "bob")
    let push = PushClient.inMemory()
    let pinsCleared = LockIsolated(false)
    let seenCleared = LockIsolated(false)
    let profileCleared = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: cookieConnection),
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        ),
        // The old user's pending approval must not badge the new user's list.
        pendingApprovalSessionIDs: ["s-alice"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences.savePinnedIDs = { @Sendable ids in if ids.isEmpty { pinsCleared.setValue(true) } }
      $0.preferences.saveSeenCounts = { @Sendable c in if c.isEmpty { seenCleared.setValue(true) } }
      $0.preferences.clearSelectedProfileID = { @Sendable in profileCleared.setValue(true) }
      $0.push = push.client
    }
    store.exhaustivity = .off
    await push.client.setBadgeCount(1)

    await store.send(.reauth(.presented(.delegate(.reauthenticated(connection: fresh, sameUser: false))))) {
      $0.reauth = nil
      $0.path = .init()
      $0.liveChat = nil
      $0.pendingApprovalSessionIDs = []
      $0.home = SessionListFeature.State(connection: fresh)
    }
    #expect(pinsCleared.value)
    #expect(seenCleared.value)
    #expect(profileCleared.value)
    await store.finish()
    #expect(push.badgeCount == 0)
  }

  @Test func quitFromReauthFullyLogsOutToOnboarding() async {
    let sessionDeleted = LockIsolated(false)
    let urlCleared = LockIsolated(false)
    let swipeActionReset = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: cookieConnection),
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.keychain.deleteSession = { @Sendable in sessionDeleted.setValue(true) }
      $0.preferences.clearServerURL = { @Sendable in urlCleared.setValue(true) }
      $0.preferences.saveDefaultSessionSwipeAction = { @Sendable action in
        if action == .default { swipeActionReset.setValue(true) }
      }
    }
    store.exhaustivity = .off

    await store.send(.reauth(.presented(.delegate(.quit)))) {
      $0.reauth = nil
      $0.path = .init()
      $0.liveChat = nil
      $0.home = nil
      $0.onboarding = .init()
    }
    #expect(sessionDeleted.value)
    #expect(urlCleared.value)
    #expect(swipeActionReset.value) // swipe-action pref reset on the quit logout too
  }

  // MARK: Push cleanup on logout (Task C4)

  @Test func disconnectUnregistersPushAndClearsPushState() async {
    let unregistered = LockIsolated<String?>(nil)
    let tokenCleared = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadPushDeviceToken = { "cafef00d" }
      $0.preferences.clearPushDeviceToken = { @Sendable in tokenCleared.setValue(true) }
      $0.hermesREST.unregisterPush = { @Sendable _, token in unregistered.setValue(token) }
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.disconnect))) {
      $0.home = nil
    }
    await store.finish()
    #expect(unregistered.value == "cafef00d") // best-effort unregister with the stored token
    #expect(tokenCleared.value) // device-token pref wiped
  }

  @Test func tokenSessionExpiredSeedsTokenReauthModal() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: connection) // `.token` connection
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.delegate(.sessionExpired))) {
      $0.reauth = ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!, method: .token
      )
    }
  }

  // When the agent lacks the profiles API, a stale custom pref must NOT leak into chats —
  // `scopedProfileName` returns nil so the chat is unscoped (matches the unscoped list).
  @Test func customProfileDoesNotLeakIntoChatWhenProfilesUnsupported() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: false
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.path.append(ChatScreen.State(sessionKey: nil))
    }
  }

  // MARK: Event-driven working glow routing (Task 7)

  // The live chat's `runningChanged` delegate is routed to the session list, which patches the
  // row's working flag (glow) INSTANTLY — no poll required.
  @Test func chatRunningChangedRoutesToSessionListGlow() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          sessions: [Session(id: "s1", isActive: true)]
        ),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    }

    // A finished turn in the live chat → clear the row glow immediately.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: false))))
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = false
    }

    // A started turn → light it again.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: true))))
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = true
    }
  }

  // CRITICAL RULE: painting a chat from its cache must NEVER start a list glow on its own. The
  // list only ever lights a glow from a server-confirmed source (the delegate above, or a poll).
  // Painting a chat from its cache (`ChatFeature.State.init` reading the snapshot) does NOT push
  // any `runningChanged` delegate, so no glow appears until the server confirms via
  // `session.resume`.
  @Test func cachedPaintAloneDoesNotGlow() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    // A persisted snapshot for the session (cache never carries a running hint).
    snapshotClient.saveSnapshot("s1", ChatSnapshot(
      model: "claude-opus-4-8",
      rows: [ChatRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .message(role: .user, text: "hi", isComplete: true))]
    ))

    // Opening the session paints the chat from cache (no server contact yet). The session list
    // row starts NOT active.
    let painted = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: connection, resumeStoredID: "s1")
    }

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          sessions: [Session(id: "s1", isActive: false)]
        ),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: painted
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
    }

    // No delegate was emitted by the cache paint, so the glow stays off. (Sending `.task` on the
    // app would try to auto-connect; we only assert that no glow was set purely from the cache.)
    #expect(store.state.home?.sessions[id: "s1"]?.isActive == false)
  }

  // MARK: App lifecycle — scenePhase (Task 8)

  // `.active` (foreground) fans out: the live chat reconnects + re-activates (`.foreground`),
  // and the session list refreshes immediately (`.pulledToRefresh`) — no waiting for the poll.
  // The thin view scenePhase wiring isn't unit-tested; this `scenePhaseChanged` action is the
  // covered behaviour.
  @Test func foregroundReconnectsOpenChatAndRefreshesList() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    } withDependencies: {
      // The chat reconnect opens a never-yielding socket; the list refresh hits REST.
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active))
    // Live chat told to reconnect + re-activate.
    await store.receive(\.liveChat.foreground)
    // List refreshed immediately.
    await store.receive(\.home.pulledToRefresh)

    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  // `.active` with no open chat still refreshes the list (and doesn't crash on the empty path).
  @Test func foregroundWithNoOpenChatStillRefreshesList() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.home.pulledToRefresh)

    await store.send(.home(.onDisappear))
  }

  // `.background` routes `.persistNow` to the live chat, which flushes its snapshot + anchor to
  // the cache immediately (verified end-to-end via the in-memory snapshot store below).
  @Test func backgroundRoutesPersistNowToOpenChat() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.storedSessionID = "s1"
    chat.liveSessionID = "live1"
    chat.model = "claude-opus-4-8"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 999))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)

    // Snapshot was written synchronously (not waiting for the debounce).
    let saved = snapshotClient.loadSnapshot("s1")
    #expect(saved?.model == "claude-opus-4-8")
    #expect(saved?.updatedAt == Date(timeIntervalSince1970: 999))
  }

  // A turn in flight (`isSending`) when backgrounding reaffirms the turn-start anchor, so a kill
  // mid-turn keeps the elapsed-timer start instant for the next hydrate.
  @Test func backgroundMidTurnPersistsAnchor() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.storedSessionID = "s1"
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 4242))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    #expect(snapshotClient.turnAnchor("s1") == nil)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)

    // Anchor written at the current date.
    #expect(snapshotClient.turnAnchor("s1") == Date(timeIntervalSince1970: 4242))
  }

  // `.inactive` is a flush only — no foreground reconnect, and (unlike `.background`) NO
  // grace task even mid-turn: a transient occlusion (app switcher, notification shade)
  // isn't suspension.
  @Test func inactiveFlushesSnapshot() async {
    let background = BackgroundTaskClient.inMemory()
    let snapshotClient = ChatSnapshotClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.storedSessionID = "s1"
    chat.liveSessionID = "live1"
    // A RUNNING turn — the strongest case: even this must not begin a background task.
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.backgroundTask = background.client
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 7))
    }

    // Exhaustive: the flush is the only follow-up — no grace listener effect.
    await store.send(.scenePhaseChanged(.inactive))
    await store.receive(\.liveChat.persistNow)

    #expect(snapshotClient.loadSnapshot("s1")?.updatedAt == Date(timeIntervalSince1970: 7))
    #expect(background.beginCount == 0)
  }

  // MARK: Background grace window (Task 5)

  /// `.background` with a RUNNING turn begins the finite background window and leaves the
  /// socket streaming: the snapshot flush lands, the grace task starts, and a gateway event
  /// arriving while backgrounded still mutates the slot (nothing was torn down).
  @Test func backgroundWhileRunningBeginsGraceAndKeepsSocketStreaming() async {
    let background = BackgroundTaskClient.inMemory()
    let socketClosed = LockIsolated(false)
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.backgroundTask = background.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in
        AsyncStream { continuation in
          continuation.onTermination = { _ in socketClosed.setValue(true) }
        }
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Dial the slot's socket (first appearance).
    await store.send(.liveChat(.task))

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)

    // The grace task was begun...
    await waitUntil { background.beginCount == 1 }
    #expect(background.activeTaskName == "hermes.chat.background-grace")
    // ...and the socket is untouched: a streaming delta still reduces into the slot.
    #expect(socketClosed.value == false)
    await store.send(.liveChat(.gatewayEvent(.messageDelta(text: "still streaming"))))
    #expect(store.state.liveChat?.transcript.isEmpty == false)

    // Cleanup: returning active cancels the grace listener + ends the task.
    await store.send(.scenePhaseChanged(.active))
    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  /// The window expiring while still backgrounded flushes the snapshot one final time,
  /// disconnects the socket cleanly (`.teardownSocketOnly` — cancelled, so no trailing
  /// `.gatewayClosed` backoff), ends the task, and RETAINS the chat state in memory —
  /// transcript, live thinking-row pointer, composer draft — so the foreground hydrate's
  /// #26 preservation still applies.
  @Test func graceExpiryDisconnectsSocketAndRetainsChatState() async {
    let background = BackgroundTaskClient.inMemory()
    let snapshotClient = ChatSnapshotClient.inMemory()
    let socketClosed = LockIsolated(false)
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true
    chat.model = "claude-opus-4-8"
    chat.composerText = "unsent draft"
    let thinkingID = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!
    chat.transcript = [
      ChatRow(id: thinkingID, kind: .thinking(
        reasoning: "live reasoning", status: nil, elapsedSeconds: 3, isComplete: false
      ))
    ]
    chat.thinkingRowID = thinkingID

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.backgroundTask = background.client
      $0.chatSnapshot = snapshotClient
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in
        AsyncStream { continuation in
          continuation.onTermination = { _ in socketClosed.setValue(true) }
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.liveChat(.task))
    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)
    await waitUntil { background.beginCount == 1 }

    // iOS expires the window while still backgrounded.
    background.expire()
    await store.receive(\.backgroundGraceExpired)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardownSocketOnly) {
      $0.liveChat?.status = .reconnecting
    }

    // The socket effect was cancelled (stream terminated) with no `.gatewayClosed` backoff,
    // the task was ended — by the CLIENT's mandatory expiry bookkeeping (the reducer sends
    // no `end()` of its own on expiry) — and the chat state survived in memory.
    await waitUntil { socketClosed.value }
    #expect(background.endCount == 1)
    #expect(background.activeTaskName == nil)
    #expect(store.state.liveChat != nil)
    #expect(store.state.liveChat?.composerText == "unsent draft")
    #expect(store.state.liveChat?.thinkingRowID == thinkingID)
    #expect(store.state.liveChat?.transcript[id: thinkingID] != nil)
    // The final flush landed before the disconnect.
    #expect(snapshotClient.loadSnapshot("s1")?.model == "claude-opus-4-8")
  }

  /// Returning `.active` before the window expires ends the background task (and cancels
  /// the expiry listener) WITHOUT the grace teardown — no socket-only disconnect fires, and
  /// a stale expiry after the fact is a no-op. The existing `.foreground` fan-out runs
  /// unchanged.
  @Test func activeBeforeExpiryEndsGraceTaskWithoutSocketTeardown() async {
    let background = BackgroundTaskClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.backgroundTask = background.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)
    await waitUntil { background.beginCount == 1 }

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.liveChat.foreground)
    await store.receive(\.home.pulledToRefresh)

    // Task ended by `.active`; a stale expiry can no longer fire (nothing active).
    await waitUntil { background.endCount == 1 }
    #expect(background.activeTaskName == nil)
    background.expire()
    #expect(background.endCount == 1)
    // No socket-only disconnect happened (it would have flipped status to `.reconnecting`).
    #expect(store.state.liveChat?.status == .connecting)

    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  /// `.background` with an IDLE chat flushes only — no background task is begun (nothing to
  /// keep alive, no battery burn). Exhaustive: the flush is the ONLY follow-up, and a
  /// leaked grace listener (a long-running effect) would fail the store's effect check.
  @Test func backgroundWhileIdleStartsNoGraceTask() async {
    let background = BackgroundTaskClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.backgroundTask = background.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }

    await store.send(.scenePhaseChanged(.background)) {
      $0.isSceneBackgrounded = true
    }
    await store.receive(\.liveChat.persistNow)
    #expect(background.beginCount == 0)
  }

  /// `.background` with no slot at all only records the scene phase (exhaustive: no
  /// effects — in particular no background task).
  @Test func backgroundWithNoSlotIsNoOp() async {
    let background = BackgroundTaskClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.backgroundTask = background.client
    }

    await store.send(.scenePhaseChanged(.background)) {
      $0.isSceneBackgrounded = true
    }
    #expect(background.beginCount == 0)
  }

  /// A stray `.backgroundGraceExpired` racing `.active` (its send escaped the listener just
  /// before the cancel landed) must be a strict no-op: `.active` already ran `.foreground`,
  /// and a late `teardownSocketOnly` would kill the socket with no reconnect scheduled —
  /// stranding the chat in `.reconnecting` until the next foreground.
  @Test func staleGraceExpiryAfterActiveIsNoOp() async {
    let background = BackgroundTaskClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.backgroundTask = background.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)
    await waitUntil { background.beginCount == 1 }

    // Return to the foreground: the socket redials via `.foreground`.
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.liveChat.foreground)
    await store.receive(\.home.pulledToRefresh)

    // The raced expiry delivers AFTER `.active` — the scene-phase guard drops it: no
    // socket-only teardown (the status never flips to `.reconnecting`).
    await store.send(.backgroundGraceExpired)
    #expect(store.state.liveChat?.status != .reconnecting)

    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  /// `.backgroundGraceExpired` with no slot left (e.g. the detached turn already ended and
  /// tore it down) is a strict no-op — nothing to flush or disconnect.
  @Test func graceExpiryWithNoSlotIsNoOp() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }

    await store.send(.scenePhaseChanged(.background)) {
      $0.isSceneBackgrounded = true
    }
    // Exhaustive: no `.liveChat` sends, no effects.
    await store.send(.backgroundGraceExpired)
  }

  /// A DETACHED turn ending during the grace window tears the slot down AND releases the
  /// background task early — nothing is left for the OS window to keep alive, so the app
  /// shouldn't stay awake for the rest of it. The cancelled listener also means a later
  /// OS expiry can never deliver `.backgroundGraceExpired` into the empty slot.
  @Test func detachedTurnEndDuringGraceReleasesTaskEarly() async {
    let background = BackgroundTaskClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1", isActive: true)]
        ),
        // Empty path — the turn streams detached while backgrounded.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.backgroundTask = background.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.background))
    await store.receive(\.liveChat.persistNow)
    await waitUntil { background.beginCount == 1 }

    // The turn completes while detached + backgrounded → teardown + early task release.
    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: false))))
    await store.receive(\.clearLiveChat)
    await waitUntil { background.endCount == 1 }
    #expect(background.activeTaskName == nil)
    #expect(store.state.liveChat == nil)

    // A stale OS expiry is now a client-side no-op (the task already ended) and the
    // cancelled listener can't deliver anything anyway.
    background.expire()
    #expect(background.endCount == 1)
  }

  // MARK: Push tap deep-link + foreground suppression + badge (C5)

  /// A push tap routes through the SAME `openSession` delegate path a list tap uses, opening
  /// (resuming) the tapped session. A loaded `Session` is reused (so its title carries over);
  /// here the session isn't loaded, so a minimal `Session(id:)` is resumed.
  @Test func pushTapDeepLinksThroughOpenSession() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "20260620_xyz")))
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "20260620_xyz")
    #expect(store.state.path.last?.sessionKey == "20260620_xyz")
    // The reducer marked the now-open session as currently-viewing (foreground suppression).
    #expect(push.currentSession == "20260620_xyz")
  }

  /// Feeding a tap through `PushClient.incomingTaps()` (the live bridge stream) drives the same
  /// deep-link — taps observed on `.task` and direct `.pushTapped` share one code path.
  @Test func incomingTapStreamDrivesDeepLink() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      // No stored creds → `.task` only starts the tap observer (no auto-connect).
      $0.keychain.loadSession = { @Sendable _ in nil }
      $0.preferences.loadServerURL = { nil }
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.task)
    push.emit(tap: PushTap(sessionID: "from-stream"))
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "from-stream")
    #expect(store.state.path.last?.sessionKey == "from-stream")
    // The tap observer is a long-running effect on the in-memory stream — drop it at teardown.
    await store.skipInFlightEffects()
  }

  /// Foreground suppression: opening a chat marks it currently-viewing; popping back to the list
  /// (empty path) clears the marker so a later foreground push presents again.
  @Test func openAndCloseChatSetsAndClearsCurrentViewingSession() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
      // The pop flushes the snapshot (`.persistNow`), which stamps `updatedAt`.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let session = Session(id: "20260610_abc", title: "Chat")

    await store.send(.home(.delegate(.openSession(session))))
    await store.finish()
    #expect(push.currentSession == "20260610_abc")

    // Pop the chat (path empties) → current-viewing marker cleared immediately (the
    // suppression follows the MARKER, not the slot); the idle teardown then runs once the
    // view finished disappearing.
    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    await store.finish()
    #expect(push.currentSession == nil)
    await store.send(.chatViewDisappeared)
    // Drain the teardown follow-ups (viewDisappeared → persistNow → teardown → clear) so
    // the asserted state reflects the completed teardown.
    await store.skipReceivedActions()
    await store.finish()
    #expect(push.currentSession == nil)
    #expect(store.state.liveChat == nil)
  }

  /// Push suppression while DETACHED (T2): popping to the list with a still-RUNNING slot
  /// clears the currently-viewing session (pushes for it must present again — the user
  /// isn't looking at it), and re-attaching restores it.
  @Test func detachedSlotClearsCurrentViewingUntilReattached() async {
    let push = PushClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.push = push.client
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live1"),
          "stored_session_id": .string("s1"),
          "messages": .array([]),
          "running": .bool(true),
          "info": .object(["model": .string("claude-opus-4-8")]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Pop while running: slot kept, but the suppression marker clears — a push for "s1"
    // must present while the user browses the list.
    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    await store.finish()
    #expect(store.state.liveChat != nil)
    #expect(push.currentSession == nil)

    // Re-attach from the list → the marker (and with it the suppression) is back.
    await store.send(.home(.delegate(.openSession(Session(id: "s1")))))
    await store.receive(\.liveChat.reattached)
    await store.skipReceivedActions()
    await waitUntil { push.currentSession == "s1" }

    await store.send(.liveChat(.teardown))
  }

  /// A pending approval badge whose tap couldn't open its session (and wasn't the one the
  /// cold-launch replay opened — e.g. the older of two pre-home taps, #46 last-wins) clears
  /// when the session is opened later from the LIST, and the entry read before the clear
  /// threads the recovery hint into the freshly-filled slot (#30 badged-then-opened-later).
  @Test func approvalBadgeClearsAndThreadsHintWhenOpenedFromList() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        pendingApprovalSessionIDs: ["s-approve"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.openSession(Session(id: "s-approve"))))) {
      $0.pendingApprovalSessionIDs = []
    }
    await store.finish()
    #expect(push.badgeCount == 0)
    // Badged-then-opened-later route (#30 workaround): the badge entry read before the
    // clear threads the recovery hint into the freshly-filled slot.
    #expect(store.state.liveChat?.expectsPendingApproval == true)
  }

  /// An approval tap that immediately opens its session nets to a zero badge (mark-then-clear).
  @Test func approvalTapThatOpensNetsZeroBadge() async {
    let push = PushClient.inMemory()
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-approve", type: "approval")))
    await store.receive(\.home.delegate.openSession)
    await store.finish()
    #expect(push.badgeCount == 0)
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
  }

  /// A tap for the session that is ALREADY on screen (slot match + marker in the path) must
  /// not navigate at all (#32) — no `openSession`, no duplicate marker, no slot re-init.
  /// (The approval variant additionally arms + consumes the recovery hint — covered by
  /// `approvalTapForOnScreenSessionHydratesRecoveredCard`.)
  @Test func pushTapForOnScreenSessionDoesNotNavigate() async {
    let push = PushClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }

    // Exhaustive: any follow-up action (an `openSession`, a path mutation) would fail the
    // test — a plain tap for the on-screen session is a pure no-nav no-op.
    await store.send(.pushTapped(PushTap(sessionID: "s1")))
    await store.finish()
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.storedSessionID == "s1")
  }

  /// An approval tap for the ON-SCREEN session arms the one-shot recovery hint AND directly
  /// drives the consuming `.foreground` hydrate (#30 workaround) — never relying on the
  /// tap's scene activation racing a scene-phase `.foreground` through the store, which
  /// could leave the hint armed indefinitely for an arbitrary later hydrate. Still no
  /// navigation, and the approval's mark-then-clear badge bookkeeping nets zero.
  @Test func approvalTapForOnScreenSessionHydratesRecoveredCard() async {
    let push = PushClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live1"),
          "stored_session_id": .string("s1"),
          "messages": .array([]),
          "running": .bool(true),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.pushTapped(PushTap(sessionID: "s1", type: "approval"))) {
      $0.liveChat?.expectsPendingApproval = true
      $0.pendingApprovalSessionIDs = []
    }
    // The arming action itself guarantees the consuming hydrate — the still-running
    // resume consumes the hint and synthesizes the generic recovered card in place.
    await store.receive(\.liveChat.foreground)
    await store.skipReceivedActions()
    #expect(
      store.state.liveChat?.pendingInteraction
        == .approval(ChatFeature.recoveredApprovalRequest)
    )
    #expect(store.state.liveChat?.expectsPendingApproval == false)
    // No navigation: single marker, same slot.
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.storedSessionID == "s1")
    #expect(push.badgeCount == 0)

    await store.send(.liveChat(.teardown))
  }

  /// A non-approval tap for the on-screen session must NOT arm the recovery hint — recovery
  /// is approval-typed taps only.
  @Test func nonApprovalOnScreenTapSetsNoRecoveryHint() async {
    let push = PushClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }

    await store.send(.pushTapped(PushTap(sessionID: "s1", type: "complete")))
    await store.finish()
    #expect(store.state.liveChat?.expectsPendingApproval == false)
  }

  /// A tap matching the DETACHED slot's session (user popped to the list mid-turn) routes
  /// through `openSession`'s re-attach branch: the marker is pushed back exactly once (no
  /// duplicate) and the slot state — accumulated rows, composer draft — is NOT re-inited.
  @Test func pushTapForDetachedSlotSessionReattachesWithoutDuplicate() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true
    chat.composerText = "unsent draft"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        // Empty path — the user is on the list; the slot streams detached.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
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

    await store.send(.pushTapped(PushTap(sessionID: "s1")))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.reattached)
    // Marker pushed back exactly once; the slot state survived (no fresh `ChatFeature.State`).
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "s1")
    #expect(store.state.liveChat?.composerText == "unsent draft")
    // Non-approval tap → no recovery hint on the re-attached slot.
    #expect(store.state.liveChat?.expectsPendingApproval == false)

    await store.send(.liveChat(.teardown))
  }

  /// The Overview flow end-to-end (#30 workaround): an approval push fired while the socket
  /// was down on a still-running session; the tap threads the recovery hint through
  /// `openSession` onto the re-attached slot, the hydrate synthesizes the generic card, and
  /// approving it fires a session-scoped `approval.respond` (no `request_id`) whose
  /// `{"resolved": n}` result feeds back honestly.
  @Test func approvalTapForDetachedSlotThreadsRecoveryHint() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true

    let respondParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        // Empty path — the user is on the list; the slot streams detached.
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "approval.respond" {
          respondParams.setValue(params)
          return .object(["resolved": .number(1)])
        }
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live1"),
          "stored_session_id": .string("s1"),
          "messages": .array([]),
          "running": .bool(true),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.pushTapped(PushTap(sessionID: "s1", type: "approval")))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.reattached)
    await store.skipReceivedActions()
    // The hint landed on the surviving slot state before the re-attach hydrate ran; the
    // still-running resume consumed it and synthesized the generic recovered card.
    #expect(
      store.state.liveChat?.pendingInteraction
        == .approval(ChatFeature.recoveredApprovalRequest)
    )
    #expect(store.state.liveChat?.expectsPendingApproval == false)
    // Badge bookkeeping unchanged: tap marked, open cleared.
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)

    // Approve the recovered card: the respond is session-queue-scoped (session_id + choice
    // + all, NO request_id — the synthetic card never had one, by design), and the server's
    // `resolved: 1` keeps the optimistic "Approved" row (no error, no re-patch).
    await store.send(.liveChat(.respondToApproval(approve: true, all: false)))
    await store.finish()
    let params = respondParams.value
    #expect(params?["session_id"] == .string("live1"))
    #expect(params?["choice"] == .string("once"))
    #expect(params?["all"] == .bool(false))
    #expect(params?["request_id"] == nil)
    #expect(store.state.liveChat?.pendingInteraction == nil)
    #expect(store.state.liveChat?.errorBanner == nil)
    let lastRow = store.state.liveChat?.transcript.last
    #expect(lastRow?.kind == .status(kind: "approval", text: "Approved"))

    await store.send(.liveChat(.teardown))
  }

  /// A tap for a DIFFERENT session while the slot is occupied replaces the slot (flush +
  /// teardown first) and SETS the path to the single new marker — never appends on top of
  /// the old one (#32's stacking bug).
  @Test func pushTapForDifferentSessionReplacesSlotAndSetsPath() async {
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    liveChat.liveSessionID = "old-live"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "new")))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat)
    await store.receive(\.fillLiveChat)
    // Path SET, not appended: exactly one marker, pointing at the new session.
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.sessionKey == "new")
    #expect(store.state.liveChat?.storedSessionID == "new")
    // Non-approval tap → no recovery hint on the replacement slot.
    #expect(store.state.liveChat?.expectsPendingApproval == false)
  }

  /// An approval tap for a DIFFERENT session (slot occupied) threads the recovery hint into
  /// the fresh replacement `ChatFeature.State` — its first hydrate can synthesize the card.
  @Test func approvalTapForDifferentSessionThreadsHintIntoReplacementSlot() async {
    var liveChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    liveChat.liveSessionID = "old-live"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "old")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "new", type: "approval")))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.storedSessionID == "new")
    #expect(store.state.liveChat?.expectsPendingApproval == true)
    // Badge bookkeeping unchanged: mark-then-clear nets to empty on open.
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
  }

  /// Opening an un-badged session from the list sets no recovery hint — only sessions marked
  /// by an approval push are candidates for synthesis.
  @Test func openingUnbadgedSessionSetsNoRecoveryHint() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.openSession(Session(id: "plain")))))
    #expect(store.state.liveChat?.expectsPendingApproval == false)
  }

  /// Two distinct pending approvals → badge count 2. Only the LAST pre-home tap is stashed
  /// for the cold-launch replay (#46, last-wins): sign-in auto-opens "s-two" (badge → 1);
  /// the still-badged "s-one" then clears when opened from the list (badge → 0).
  @Test func multiplePendingApprovalsSetBadgeThenClearOne() async {
    let push = PushClient.inMemory()
    // Onboarding (no home) so the approval taps can't open and just accumulate as pending.
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-one", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-one"]
      $0.pendingPushTap = PushTap(sessionID: "s-one", type: "approval")
    }
    await store.send(.pushTapped(PushTap(sessionID: "s-two", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-one", "s-two"]
      // Last-wins: a newer pre-home tap replaces the stash — only one tap replays.
      $0.pendingPushTap = PushTap(sessionID: "s-two", type: "approval")
    }
    await store.finish()
    #expect(push.badgeCount == 2) // two pending approvals

    // Sign in → the stashed LAST tap replays and opens s-two; its entry clears.
    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession) {
      $0.pendingApprovalSessionIDs = ["s-one"]
    }
    await store.finish()
    #expect(push.badgeCount == 1)
    #expect(store.state.liveChat?.storedSessionID == "s-two")

    // Open the remaining badged session from the list → badge drops to zero (the occupied
    // slot is replaced through the standard teardown-then-fill).
    await store.send(.home(.delegate(.openSession(Session(id: "s-one"))))) {
      $0.pendingApprovalSessionIDs = []
    }
    await store.skipReceivedActions()
    await store.finish()
    #expect(push.badgeCount == 0)
    #expect(store.state.liveChat?.storedSessionID == "s-one")
  }

  // MARK: Cold-launch push-tap replay (#46)

  /// Cold launch: the tap arrives while auto-connect is still probing (`home == nil`) — it
  /// must be STASHED, then replayed through the one `.pushTapped` routing path the moment
  /// `.autoConnectSucceeded` creates the list, opening the never-seen session via the
  /// placeholder `Session(id:)` fallback.
  @Test func coldLaunchTapStashedThenReplayedOnAutoConnect() async {
    let push = PushClient.inMemory()
    let store = TestStore(initialState: AppFeature.State(autoConnecting: true)) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    // Pre-home tap: stash only — nothing to navigate yet.
    await store.send(.pushTapped(PushTap(sessionID: "20260724_cron"))) {
      $0.pendingPushTap = PushTap(sessionID: "20260724_cron")
    }
    #expect(store.state.liveChat == nil)
    #expect(store.state.path.isEmpty)

    // The list arriving consumes the stash and replays the tap through normal routing.
    await store.send(.autoConnectSucceeded(connection)) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    await store.finish()
    // The placeholder `Session(id:)` fallback resumed the never-seen session.
    #expect(store.state.liveChat?.storedSessionID == "20260724_cron")
    #expect(store.state.path.last?.sessionKey == "20260724_cron")
    // A NON-approval tap must never touch the approval badge — neither on the stash
    // branch nor on the replay.
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
    #expect(push.badgeCount == 0)
  }

  /// Auto-connect FAILED → the user lands on onboarding; the stashed tap must survive to a
  /// manual login (`.onboarding(.delegate(.connected))`) and replay then.
  @Test func coldLaunchTapReplayedAfterManualLogin() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-manual"))) {
      $0.pendingPushTap = PushTap(sessionID: "s-manual")
    }
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "s-manual")
    #expect(store.state.path.last?.sessionKey == "s-manual")
    // Non-approval tap → the approval badge set stays untouched end to end.
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
  }

  /// An approval tap dropped pre-home badges the session (it can't open yet); the replay
  /// then opens it through the normal flow — arming the recovery hint (#30) — and the
  /// open's mark-then-clear badge bookkeeping nets the entry back to zero.
  @Test func coldLaunchApprovalTapReplaysArmingHintAndNetsBadgeZero() async {
    let push = PushClient.inMemory()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    // Dropped approval tap: badged + stashed.
    await store.send(.pushTapped(PushTap(sessionID: "s-approve", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-approve"]
      $0.pendingPushTap = PushTap(sessionID: "s-approve", type: "approval")
    }
    await store.finish()
    #expect(push.badgeCount == 1)

    // The replay re-runs the (idempotent) badge insert, then the open clears it — net zero.
    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession) {
      $0.pendingApprovalSessionIDs = []
    }
    await store.finish()
    #expect(push.badgeCount == 0)
    // The badge entry read before the clear armed the recovery hint on the fresh slot (#30).
    #expect(store.state.liveChat?.expectsPendingApproval == true)
    #expect(store.state.liveChat?.storedSessionID == "s-approve")
  }

  /// Existing-behavior guard: a warm tap (list present) routes immediately and never
  /// touches the stash.
  @Test func warmTapNeverTouchesPendingStash() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-warm")))
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.pendingPushTap == nil)
    #expect(store.state.liveChat?.storedSessionID == "s-warm")
  }

  /// Existing-behavior guard: `.autoConnectSucceeded` with no stash emits no replay
  /// (exhaustive — a stray `.pushTapped` follow-up would fail this send).
  @Test func autoConnectWithoutStashEmitsNoReplay() async {
    let store = TestStore(initialState: AppFeature.State(autoConnecting: true)) {
      AppFeature()
    }

    await store.send(.autoConnectSucceeded(connection)) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: self.connection)
    }
  }

  /// A cold-launch replay must open the session under the PERSISTED profile: the replay
  /// fires synchronously at home creation, BEFORE the list's `.task` reloads prefs — an
  /// unseeded profile would resume unscoped (wrong `state.db` on a non-default profile),
  /// and the "session not found" self-heal would recreate the session empty under
  /// "default".
  @Test func coldLaunchReplayResumesUnderPersistedProfile() async {
    let store = TestStore(initialState: AppFeature.State(autoConnecting: true)) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadSelectedProfileID = { "work" }
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "cron_job1_20260724"))) {
      $0.pendingPushTap = PushTap(sessionID: "cron_job1_20260724")
    }
    // Home is seeded with the persisted selection (the list's capability probe still
    // corrects `profilesSupported` afterwards).
    await store.send(.autoConnectSucceeded(connection)) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(
        connection: self.connection, selectedProfileName: "work", profilesSupported: true
      )
      $0.pendingPushTap = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    // The replayed open threads the persisted profile into the chat, so `session.resume`
    // scopes to the right `state.db`.
    #expect(store.state.liveChat?.profileName == "work")
    #expect(store.state.liveChat?.storedSessionID == "cron_job1_20260724")
  }

  /// End-to-end #46 launch race: the app delegate's `didReceive` fires BEFORE the
  /// reducer's `.task` subscribes (true launch-from-push). The real bridge buffers the
  /// tap, the `.task` observer drains it into `.pushTapped`, the pre-home stash holds it,
  /// and the login replays it into the open — both halves of the fix composed.
  @Test func coldLaunchTapBufferedInBridgeReplaysThroughTaskObserver() async {
    let bridge = PushBridge()
    bridge.tapReceived(["session_id": "s-race"]) // before ANY subscriber exists

    var client = PushClient.testValue
    client.incomingTaps = { bridge.tapStream() }
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      // No stored creds → `.task` only starts the tap observer (no auto-connect).
      $0.keychain.loadSession = { @Sendable _ in nil }
      $0.preferences.loadServerURL = { nil }
      $0.push = client
    }
    store.exhaustivity = .off

    await store.send(.task)
    // The buffered tap drains into the observer and stashes (no home yet).
    await store.receive(\.pushTapped) {
      $0.pendingPushTap = PushTap(sessionID: "s-race")
    }
    // Manual login → the stash replays into the open.
    await store.send(.onboarding(.delegate(.connected(connection))))
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "s-race")
    #expect(store.state.path.last?.sessionKey == "s-race")
    // The tap observer is a long-running effect on the bridge stream — drop it at teardown.
    await store.skipInFlightEffects()
  }

  /// A stash recorded under one server must NOT replay into a login that targets a
  /// DIFFERENT server — resuming a foreign session id there would trip the resume
  /// self-heal into creating a spurious empty chat. The stash is dropped and its
  /// pending-approval badge entry scrubbed. Exhaustive: a stray `.pushTapped` replay
  /// would fail the send.
  @Test func stashedTapDroppedWhenLoginTargetsDifferentServer() async {
    let push = PushClient.inMemory()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      // The URL stored when the tap arrived — the server the push came from.
      $0.preferences.loadServerURL = { "http://old.tailnet:9119" }
      $0.push = push.client
    }

    await store.send(.pushTapped(PushTap(sessionID: "s-old", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-old"]
      $0.pendingPushTap = PushTap(sessionID: "s-old", type: "approval")
      $0.pendingPushTapServerURL = URL(string: "http://old.tailnet:9119")!
    }
    // Log into a DIFFERENT server → no replay; the foreign approval badge is scrubbed.
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
      $0.pendingPushTapServerURL = nil
      $0.pendingApprovalSessionIDs = []
    }
    await store.finish()
    #expect(push.badgeCount == 0)
  }

  /// A cross-server drop scrubs EVERY pre-home approval badge entry, not just the
  /// stashed (last-wins) tap's: an approval tap lands first, then a non-approval tap
  /// overwrites the stash, and the login targets a DIFFERENT server. The earlier
  /// approval's badge would otherwise leak for the process lifetime — a foreign session
  /// never appears in the new server's list, so opening (the only other clear path)
  /// can never happen. Exhaustive: a stray `.pushTapped` replay would fail the send.
  @Test func crossServerDropScrubsAllPreHomeApprovalBadges() async {
    let push = PushClient.inMemory()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://old.tailnet:9119" }
      $0.push = push.client
    }

    await store.send(.pushTapped(PushTap(sessionID: "s-approval", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-approval"]
      $0.pendingPushTap = PushTap(sessionID: "s-approval", type: "approval")
      $0.pendingPushTapServerURL = URL(string: "http://old.tailnet:9119")!
    }
    // A later non-approval tap takes over the stash (last-wins); the approval stays badged.
    await store.send(.pushTapped(PushTap(sessionID: "s-later"))) {
      $0.pendingPushTap = PushTap(sessionID: "s-later")
    }
    // Log into a DIFFERENT server → no replay; the WHOLE foreign badge set is scrubbed.
    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
      $0.pendingPushTapServerURL = nil
      $0.pendingApprovalSessionIDs = []
    }
    await store.finish()
    #expect(push.badgeCount == 0)
  }

  /// The plan's expired-creds flow: auto-connect fails (URL still stored), the user logs
  /// back into the SAME server — a recorded origin matching the connection replays
  /// normally. The stored URL deliberately differs in scheme/host CASING from the
  /// connection's (`HTTP://Mac.…` vs `http://mac.…`): the compare is case-insensitive
  /// per RFC 3986, so formatting drift can't drop a legitimate tap.
  @Test func stashedTapReplaysWhenLoginTargetsSameServer() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "HTTP://Mac.tailnet:9119" }
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-same"))) {
      $0.pendingPushTap = PushTap(sessionID: "s-same")
      $0.pendingPushTapServerURL = URL(string: "HTTP://Mac.tailnet:9119")!
    }
    await store.send(.onboarding(.delegate(.connected(connection))))
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "s-same")
  }

  /// The stash AND the approval badge set die with the identity: Settings disconnect
  /// clears both and resets the icon badge to zero, so no stale tap or prior-server
  /// badge can survive into the next login. (Structurally the stash is already nil
  /// whenever `home` exists — both creation sites consume it — so this pins the
  /// defensive invariant.)
  @Test func disconnectClearsPushTapStashAndApprovalBadges() async {
    let push = PushClient.inMemory()
    var initial = AppFeature.State(home: SessionListFeature.State(connection: connection))
    initial.pendingPushTap = PushTap(sessionID: "s-stale")
    initial.pendingPushTapServerURL = URL(string: "http://old.tailnet:9119")
    initial.pendingApprovalSessionIDs = ["s-stale", "s-other"]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off
    // Simulate the badge those entries had raised, so the reset to zero is observable.
    await push.client.setBadgeCount(2)
    await store.send(.home(.delegate(.disconnect)))
    #expect(store.state.pendingPushTap == nil)
    #expect(store.state.pendingPushTapServerURL == nil)
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
    await store.finish()
    #expect(push.badgeCount == 0)
  }

  /// Reauth "Quit to start" (full logout) clears the stash and the approval badge set
  /// too — the same defensive invariant as the Settings disconnect, through the other
  /// logout path.
  @Test func reauthQuitClearsPushTapStashAndApprovalBadges() async {
    let push = PushClient.inMemory()
    var initial = AppFeature.State(
      home: SessionListFeature.State(connection: connection),
      reauth: ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!, method: .token
      )
    )
    initial.pendingPushTap = PushTap(sessionID: "s-stale")
    initial.pendingApprovalSessionIDs = ["s-stale"]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off
    await push.client.setBadgeCount(1)
    await store.send(.reauth(.presented(.delegate(.quit))))
    #expect(store.state.pendingPushTap == nil)
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
    await store.finish()
    #expect(push.badgeCount == 0)
  }

  // MARK: Launch connection-failed screen (#62)

  /// A launch probe that never reached the server (`.unreachable`) must raise the retry
  /// screen with the stored session INTACT — onboarding is left untouched, so a password-mode
  /// user is never asked to re-type a password that never expired.
  @Test func autoConnectUnreachableRaisesRetryScreen() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.connectionFailed = ConnectionFailedFeature.State(
        connection: self.connection, reason: .unreachable
      )
    }
    #expect(store.state.onboarding == ConnectionFeature.State())
  }

  /// Same routing for `.offline` — the reason rides along so the screen can say "you're
  /// offline" instead of sending the user hunting for a dead server.
  @Test func autoConnectOfflineRaisesRetryScreenWithOfflineReason() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.offline }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.connectionFailed = ConnectionFailedFeature.State(
        connection: self.connection, reason: .offline
      )
    }
  }

  /// The headline #62 story: a PASSWORD-mode (cookie) session. The retry screen must keep the
  /// cookie session verbatim and leave onboarding pristine — the whole point of the issue is
  /// that a network failure never demands a password that never expired.
  @Test func autoConnectUnreachableKeepsACookieSessionIntact() async {
    let auth = cookieConnection.auth
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in auth }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.connectionFailed = ConnectionFailedFeature.State(
        connection: self.cookieConnection, reason: .unreachable
      )
    }
    #expect(store.state.connectionFailed?.connection.auth == self.cookieConnection.auth)
    #expect(store.state.onboarding == ConnectionFeature.State())
  }

  /// …and a successful retry of that cookie session carries the connection through verbatim,
  /// so the list is built against the same cookies (never a token-first reconstruction).
  @Test func cookieRetrySuccessBuildsHomeWithTheSameConnection() async {
    let store = TestStore(
      initialState: AppFeature.State(
        connectionFailed: ConnectionFailedFeature.State(
          connection: cookieConnection, reason: .offline
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.connectionFailed(.delegate(.connected(cookieConnection)))) {
      $0.connectionFailed = nil
      $0.home = SessionListFeature.State(connection: self.cookieConnection)
    }
    #expect(store.state.home?.connection.auth == self.cookieConnection.auth)
  }

  /// A proxy in front of a down agent answers 502/503/504, an agent with a broken DB answers
  /// 500, a proxy whose upstream route vanished answers 404 — none of those is an auth
  /// rejection, so they all belong on the retry screen rather than in a password prompt.
  @Test(arguments: [502, 503, 504, 500, 418])
  func autoConnectServerSideStatusRaisesRetryScreen(status: Int) async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        throw RESTError.server(status: status, detail: nil)
      }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.connectionFailed = ConnectionFailedFeature.State(
        connection: self.connection, reason: .server(status: status, detail: nil)
      )
    }
    #expect(store.state.onboarding == ConnectionFeature.State())
  }

  /// ONLY a credentials verdict keeps the pre-#62 onboarding fallback: `.unauthorized` (401)
  /// and its untranslated sibling 403. Retrying can't repair dead credentials, so those two
  /// — and nothing else — still land on the prefilled credentials form.
  @Test(arguments: [RESTError.unauthorized, .server(status: 403, detail: "forbidden")])
  func autoConnectCredentialsVerdictStillFallsBackToOnboarding(error: RESTError) async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw error }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.onboarding = ConnectionFeature.State(serverURL: "http://mac.tailnet:9119", token: "tok")
    }
    #expect(store.state.connectionFailed == nil)
  }

  /// A 404 (proxy route gone), a 429 and a captive portal's HTML (`.decoding`) are network /
  /// server conditions, not verdicts on the saved sign-in — a stored connection was a working
  /// Hermes agent when it was persisted. They raise the retry screen with the session intact.
  @Test(arguments: [RESTError.notFound, .rateLimited, .decoding])
  func autoConnectServerSideErrorRaisesRetryScreen(error: RESTError) async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw error }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.connectionFailed = ConnectionFailedFeature.State(
        connection: self.connection, reason: error
      )
    }
    #expect(store.state.onboarding == ConnectionFeature.State())
  }

  /// A RAW (non-`RESTError`) failure from the client — a wrapper, a future transport, a test
  /// double — still classifies through the shared `RESTError(transport:)` funnel, so an
  /// offline device raises the screen with the offline reason rather than a blanket
  /// `.unreachable`.
  @Test func autoConnectRawURLErrorIsClassifiedThroughTheSharedFunnel() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        throw URLError(.notConnectedToInternet)
      }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.connectionFailed = ConnectionFailedFeature.State(
        connection: self.connection, reason: .offline
      )
    }
  }

  /// A re-sent `.task` while the retry screen is up must NOT start a second launch probe —
  /// it would flip the UI back to the spinner and, on success, build `home` beside a
  /// still-populated slot (a phantom child probing on every foreground forever).
  @Test func taskDoesNotRelaunchTheProbeWhileTheRetryScreenIsUp() async {
    let probes = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        connectionFailed: ConnectionFailedFeature.State(
          connection: connection, reason: .unreachable
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        probes.withValue { $0 += 1 }
        return []
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.task)
    await store.finish()
    #expect(store.state.autoConnecting == false)
    #expect(probes.value == 0)
  }

  /// Belt-and-braces on the same invariant from the other end: a successful auto-connect
  /// clears any retry screen, so the two can never coexist.
  @Test func autoConnectSucceededClearsAnyRetryScreen() async {
    let store = TestStore(
      initialState: AppFeature.State(
        connectionFailed: ConnectionFailedFeature.State(
          connection: connection, reason: .unreachable
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.autoConnectSucceeded(connection)) {
      $0.connectionFailed = nil
      $0.home = SessionListFeature.State(connection: self.connection)
    }
  }

  /// A successful retry lands exactly where a successful launch auto-connect lands: the slot
  /// is cleared, the list is built, and a stashed cold-launch push tap (#46) still replays.
  @Test func retrySuccessBuildsHomeAndReplaysStashedTap() async {
    var initial = AppFeature.State(
      connectionFailed: ConnectionFailedFeature.State(connection: connection, reason: .unreachable)
    )
    initial.pendingPushTap = PushTap(sessionID: "s-cold")
    // Stamp the origin the way the real cold-launch stash does — without it the replay takes
    // the "unknown origin, replay unverified" path and the cross-server guard is never
    // exercised.
    initial.pendingPushTapServerURL = connection.baseURL
    let store = TestStore(initialState: initial) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.connectionFailed(.delegate(.connected(connection)))) {
      $0.connectionFailed = nil
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
      $0.pendingPushTapServerURL = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    #expect(store.state.liveChat?.storedSessionID == "s-cold")
    #expect(store.state.path.last?.sessionKey == "s-cold")
  }

  /// The retry reached the server and it rejected us — fall back to the SAME prefilled
  /// onboarding a launch auth failure produces.
  @Test func retryCredentialsRejectedFallsBackToPrefilledOnboarding() async {
    let store = TestStore(
      initialState: AppFeature.State(
        connectionFailed: ConnectionFailedFeature.State(
          connection: connection, reason: .unreachable
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.connectionFailed(.delegate(.credentialsRejected(connection)))) {
      $0.connectionFailed = nil
      $0.onboarding = ConnectionFeature.State(
        serverURL: "http://mac.tailnet:9119", token: "tok"
      )
    }
  }

  /// "Log Out" from the retry screen runs the logout recipe — keychain session, server URL,
  /// identity-scoped prefs, grouping mode, badge, push registration — and lands on a FRESH
  /// (nothing prefilled) onboarding.
  @Test func logoutFromRetryScreenClearsEverythingAndShowsFreshOnboarding() async {
    let sessionDeleted = LockIsolated(false)
    let unregistered = LockIsolated<String?>(nil)
    let preferences = PreferencesClient.inMemory()
    preferences.saveServerURL("http://mac.tailnet:9119")
    preferences.savePinnedIDs(["s-pinned"])
    preferences.saveSeenCounts(["s-pinned": 3])
    preferences.saveSelectedProfileID("work")
    preferences.saveGroupingMode(.chronological)
    preferences.saveDefaultSessionSwipeAction(.delete)
    preferences.savePushDeviceToken("cafef00d")
    let push = PushClient.inMemory()

    var initial = AppFeature.State(
      connectionFailed: ConnectionFailedFeature.State(connection: connection, reason: .offline)
    )
    initial.pendingPushTap = PushTap(sessionID: "s-stale")
    initial.pendingPushTapServerURL = connection.baseURL
    initial.pendingApprovalSessionIDs = ["s-stale"]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.preferences = preferences
      $0.push = push.client
      $0.keychain.deleteSession = { @Sendable in sessionDeleted.setValue(true) }
      $0.hermesREST.unregisterPush = { @Sendable _, token in unregistered.setValue(token) }
    }
    await push.client.setBadgeCount(1)

    // Deliberately EXHAUSTIVE: `.off` would also suppress the in-flight-effect check and any
    // stray state mutation the logout recipe grew.
    await store.send(.connectionFailed(.delegate(.logoutConfirmed))) {
      $0.connectionFailed = nil
      $0.onboarding = .init() // fresh — there is no session left to repair
      $0.pendingPushTap = nil
      $0.pendingPushTapServerURL = nil
      $0.pendingApprovalSessionIDs = []
    }
    await store.finish()
    #expect(sessionDeleted.value)
    #expect(preferences.loadServerURL() == nil)
    #expect(preferences.loadPinnedIDs().isEmpty)
    #expect(preferences.loadSeenCounts().isEmpty)
    #expect(preferences.loadSelectedProfileID() == nil)
    #expect(preferences.loadGroupingMode() == .default)
    #expect(preferences.loadDefaultSessionSwipeAction() == .default) // swipe pref reset too
    #expect(preferences.loadPushDeviceToken() == nil)
    #expect(unregistered.value == "cafef00d") // best-effort unregister with the stored token
    #expect(push.badgeCount == 0)
  }

  /// Foregrounding while stuck on the retry screen auto-probes — the user very likely just
  /// turned the VPN back on, and a probe that succeeds walks straight into the list.
  @Test func foregroundAutoRetriesOnTheConnectionFailedScreen() async {
    let store = TestStore(
      initialState: AppFeature.State(
        connectionFailed: ConnectionFailedFeature.State(
          connection: connection, reason: .unreachable
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.connectionFailed.sceneBecameActive) { $0.connectionFailed?.isRetrying = true }
    await store.receive(\.connectionFailed.retrySucceeded)
    await store.receive(\.connectionFailed.delegate.connected) {
      $0.connectionFailed = nil
      $0.home = SessionListFeature.State(connection: self.connection)
    }
    await store.send(.home(.onDisappear))
  }

  /// A foreground landing while a probe is already in flight SUPERSEDES it (`cancelInFlight`)
  /// rather than fanning out: exactly one probe answers, and the screen can never end up with
  /// a latched `isRetrying` because a stalled probe's result never landed. Assert it through
  /// the composed `.scenePhaseChanged(.active)` path, not just in isolation
  /// (`ConnectionFailedFeatureTests.foregroundSupersedesAStalledProbe`).
  @Test func foregroundWhileRetryingSupersedesTheStalledProbe() async {
    let stall = AsyncStream<Void>.makeStream()
    let probes = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        connectionFailed: ConnectionFailedFeature.State(
          connection: connection, reason: .unreachable
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        let attempt = probes.withValue { value -> Int in
          value += 1
          return value
        }
        if attempt == 1 { for await _ in stall.stream { break } } // never resolves
        return []
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.connectionFailed(.retryTapped))
    #expect(store.state.connectionFailed?.isRetrying == true)
    await store.send(.scenePhaseChanged(.active))
    await store.receive(\.connectionFailed.sceneBecameActive)
    // Exactly ONE result: the stalled probe was cancelled, so it never sends.
    await store.receive(\.connectionFailed.retrySucceeded)
    await store.receive(\.connectionFailed.delegate.connected) {
      $0.connectionFailed = nil
      $0.home = SessionListFeature.State(connection: self.connection)
    }
    #expect(probes.value == 2)
    stall.continuation.finish()
    await store.send(.home(.onDisappear))
  }

  /// Existing-behavior guard: with no retry screen up, `.active` must not emit a stray
  /// `.connectionFailed` action into a nil child.
  @Test func foregroundWithoutRetryScreenEmitsNoRetry() async {
    let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
    await store.send(.scenePhaseChanged(.active))
  }

  // MARK: - Layout regime + the detached predicate (iPad split view, #80)

  /// The default layout is compact (the iPhone stack), so every pre-existing behaviour is
  /// byte-identical: "detached" is exactly "compact with an empty path".
  @Test func defaultLayoutIsCompactAndDetachedMeansEmptyPath() {
    var state = AppFeature.State(
      home: SessionListFeature.State(connection: connection),
      liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
    )
    #expect(state.layout == .compact)
    #expect(state.isChatDetached, "compact + empty path = the chat was popped")
    #expect(state.currentViewingSessionID == nil)

    state.path.append(ChatScreen.State(sessionKey: "s1"))
    #expect(!state.isChatDetached, "compact + marker = the chat is on screen")
    #expect(state.currentViewingSessionID == "s1")
  }

  /// In regular the slot IS the detail column: the chat is never detached and the
  /// current-viewing id reads the slot key even though the path is empty.
  @Test func currentViewingSessionInRegularReadsSlotWithEmptyPath() {
    let state = AppFeature.State(
      home: SessionListFeature.State(connection: connection),
      liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1"),
      layout: .regular
    )
    #expect(state.path.isEmpty)
    #expect(!state.isChatDetached)
    #expect(state.currentViewingSessionID == "s1")
    #expect(state.highlightedSessionID == "s1", "the sidebar marks the detail's session")
  }

  /// The sidebar highlight is regular-only. Compact must read `nil` even with the chat on
  /// screen: `currentViewingSessionID` is non-nil there for the whole life of the marker,
  /// which includes the pop animation and an interactive swipe-back — precisely when the
  /// iPhone list is visible again and must look exactly as it did before #80.
  @Test func highlightedSessionIsNilInCompactEvenWithTheChatOnScreen() {
    var state = AppFeature.State(
      home: SessionListFeature.State(connection: connection),
      path: StackState([ChatScreen.State(sessionKey: "s1")]),
      liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
    )
    #expect(state.currentViewingSessionID == "s1")
    #expect(state.highlightedSessionID == nil)

    state.layout = .regular
    #expect(state.highlightedSessionID == "s1", "the same state highlights in regular")
  }

  /// compact → regular with a pushed marker: the path clears (the slot becomes the detail;
  /// a marker would render the chat twice) and the slot — socket, rows, everything — stays.
  @Test func layoutChangedToRegularClearsPathAndKeepsSlot() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
      $0.path = .init()
    }
    #expect(store.state.liveChat == chat, "the slot is untouched by the column move")
    #expect(store.state.currentViewingSessionID == "s1")
  }

  /// regular → compact with a live slot: the stack now owns the screen, so the slot's
  /// marker is pushed (SET to exactly one) and the slot stays as-is.
  @Test func layoutChangedToCompactWithLiveSlotPushesMarker() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: "s1")])
    }
    #expect(store.state.liveChat == chat)
    #expect(store.state.currentViewingSessionID == "s1")
  }

  /// Narrowing onto a PRISTINE detail seat drops it: the stack shows the list, not an empty
  /// chat with a Back button. Widening seats a fresh one again.
  @Test func layoutChangedToCompactDropsPristineSeat() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
    }

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
    }
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    #expect(store.state.path.isEmpty, "no marker — the user lands on the list")
  }

  /// A seat the user HAS touched (a typed draft) is not disposable: it keeps its marker, so
  /// narrowing shows the draft rather than discarding it. The marker carries the chat's
  /// (still nil) session key, exactly like `fillLiveChat` would have pushed in compact.
  @Test func layoutChangedToCompactWithDraftedSeatPushesNilKeyMarker() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: ChatFeature.State(
          connection: connection, profileName: nil, composerText: "half-typed"
        ),
        layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
    #expect(store.state.liveChat?.composerText == "half-typed")
  }

  /// Staged attachments with NO typed text are equally the user's work: the seat keeps its
  /// marker on narrowing rather than being dropped, so the picked files survive.
  @Test func layoutChangedToCompactWithStagedAttachmentsPushesMarker() async {
    let attachment = ComposerAttachment(
      id: UUID(0), kind: .image, filename: "p.png", mimeType: "image/png", data: Data([1])
    )
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.attachments = [attachment]
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
    #expect(store.state.liveChat?.attachments == [attachment])
  }

  /// A seat with an EMPTY composer is not automatically disposable: a recording (or its
  /// transcription) is composer input still arriving, and the narrowing teardown would cut
  /// the mic and lose it. Such a seat keeps its marker — exhaustive, so any teardown fails.
  @Test func layoutChangedToCompactWithARecordingSeatPushesMarker() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    seat.recording = .recording
    seat.recordingSeconds = 3
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: "live-new")])
    }
    #expect(store.state.liveChat?.recording == .recording)
    #expect(store.state.liveChat?.recordingSeconds == 3)
  }

  /// Same for a clipboard load still resolving (#54): the batch lands into the seat, so the
  /// seat has to still be there. Marker, not teardown.
  @Test func layoutChangedToCompactWithAPendingPasteSeatPushesMarker() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.pendingPasteCount = 1
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
    #expect(store.state.liveChat?.pendingPasteCount == 1, "the paste can still land")
  }

  /// Reporting the same layout twice (the shell's `initial: true` fires on every view
  /// re-creation) is a no-op — no path churn, no effects.
  @Test func layoutChangedToSameLayoutIsNoOp() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1")
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.compact))

    let regular = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1"),
        layout: .regular
      )
    ) {
      AppFeature()
    }

    await regular.send(.layoutChanged(.regular))
  }

  /// With no slot and no list (onboarding / retry screen), a layout change records the
  /// layout only — there is nothing to reconcile.
  @Test func layoutChangedWithoutSlotOrHomeOnlyRecordsLayout() async {
    let store = TestStore(initialState: AppFeature.State()) { AppFeature() }

    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
    }
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat == nil)
  }

  /// The push bridge's "currently viewing" follows the predicate: a compact slot left
  /// detached (running turn, popped to the list) becomes the on-screen detail the moment
  /// the layout widens, so pushes for it are suppressed again — and released on narrowing.
  @Test func layoutChangeUpdatesCurrentViewingSessionForPushSuppression() async {
    let push = PushClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: chat // detached: compact + empty path
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }

    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
    }
    await store.finish()
    #expect(push.currentSession == "s1")

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: "s1")])
    }
    await store.finish()
    #expect(push.currentSession == "s1", "the marker keeps the chat on screen in compact")
  }

  /// In regular the chat view's disappearance (it moved between the stack and the detail
  /// column on a layout change, or the `slotGeneration` key re-created it) must NEVER tear
  /// the slot down — even for an idle chat that the compact pop policy would clear — and
  /// must not forward the view-session cleanup either: the chat is still the visible detail.
  @Test func chatViewDisappearedInRegularIsAFullNoOp() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    }

    // Exhaustive: no `viewDisappeared` / `persistNow` / `teardown` / `clearLiveChat`.
    await store.send(.chatViewDisappeared)
    #expect(store.state.liveChat == chat)
  }

  /// Compact counterpart: a chat whose view disappeared while a marker is STILL on the path
  /// is on screen (a narrowing column move) or was already torn down by the slot replacement
  /// that swapped the marker — either way nothing is forwarded.
  @Test func chatViewDisappearedInCompactWithMarkerIsANoOp() async {
    let chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    }

    await store.send(.chatViewDisappeared)
    #expect(store.state.liveChat == chat)
  }

  /// The reason the cleanup is not forwarded while the chat is on screen: crossing the
  /// regular/compact threshold mid-recording used to cancel the mic under a visible
  /// composer (`.viewDisappeared` → `releaseVoiceResources`). Both directions, with the
  /// recording state intact afterwards.
  @Test func columnMoveWhileRecordingKeepsTheRecording() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.recording = .recording
    chat.recordingSeconds = 4
    chat.waveformLevels = [0.3, 0.6]
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

    // Widen: the marker clears, the detail column takes over, the mic keeps running.
    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
      $0.path = .init()
    }
    await store.send(.chatViewDisappeared)
    #expect(store.state.liveChat?.recording == .recording)
    #expect(store.state.liveChat?.recordingSeconds == 4)

    // Narrow back: the marker returns, the chat is on the stack, still recording.
    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: "s1")])
    }
    await store.send(.chatViewDisappeared)
    #expect(store.state.liveChat?.recording == .recording)
    #expect(store.state.liveChat?.recordingSeconds == 4)
  }

  /// A turn ending in regular routes the glow only: the slot is the visible detail (never
  /// detached), so the detached-turn-end teardown must not run.
  @Test func runningChangedFalseInRegularKeepsSlot() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, sessions: [Session(id: "s1", isActive: true)]
        ),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.liveChat(.delegate(.runningChanged(sessionID: "s1", running: false))))
    await store.receive(\.home.setSessionRunning) {
      $0.home?.sessions[id: "s1"]?.isActive = false
    }
    // Exhaustive: no teardown chain follows.
    #expect(store.state.liveChat == chat)
  }

  /// Re-opening the slot's own session in regular (tapping its sidebar row while it is the
  /// detail) re-attaches without pushing a marker — the path stays empty.
  @Test func reopeningOwnSessionInRegularReattachesWithoutMarker() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      // The re-attach hydrates (`session.resume`); the payload is irrelevant here.
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.openSession(Session(id: "s1")))))
    await store.receive(\.liveChat.reattached)
    #expect(store.state.path.isEmpty, "regular never holds a marker")
    #expect(store.state.liveChat?.sessionKey == "s1")
  }

  /// Opening a session in regular fills the slot with NO marker (the slot is the detail).
  @Test func openingSessionInRegularFillsSlotWithoutMarker() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.openSession(Session(id: "s1", title: "Chat"))))) {
      $0.liveChat = ChatFeature.State(
        connection: self.connection, resumeStoredID: "s1", profileName: nil, title: "Chat"
      )
      $0.slotGeneration = 1
    }
    #expect(store.state.path.isEmpty)
    #expect(store.state.currentViewingSessionID == "s1")
    #expect(store.state.highlightedSessionID == "s1", "the sidebar highlights the detail")
  }

  // MARK: - New-chat filling rules for regular width (iPad split view, #80)

  /// The list appearing in regular (launch probe succeeded) seats a fresh new chat in the
  /// otherwise-blank detail column; the path stays empty — the slot IS the detail.
  @Test func homeAppearingInRegularFillsNewChat() async {
    let store = TestStore(initialState: AppFeature.State(layout: .regular)) { AppFeature() }

    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat?.isUnpromptedNewChat == true)
    #expect(store.state.highlightedSessionID == nil, "an unresolved new chat highlights no row")
  }

  /// Manual login (`onboarding.connected`) lands the same way.
  @Test func onboardingConnectedInRegularFillsNewChat() async {
    let store = TestStore(initialState: AppFeature.State(layout: .regular)) { AppFeature() }

    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    #expect(store.state.path.isEmpty)
  }

  /// …and so does the retry screen (#62), the third `landOnHome` call site: a validated
  /// stored session must seat the detail column exactly like a launch probe would.
  @Test func connectionFailedRetryInRegularFillsNewChat() async {
    var initial = AppFeature.State(layout: .regular)
    initial.connectionFailed = ConnectionFailedFeature.State(
      connection: connection, reason: .offline
    )
    let store = TestStore(initialState: initial) { AppFeature() }

    await store.send(.connectionFailed(.delegate(.connected(connection)))) {
      $0.connectionFailed = nil
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    #expect(store.state.path.isEmpty)
  }

  /// A stashed cold-launch tap replays FIRST: its session fills the slot, so no throwaway
  /// new chat is seated and torn down on the way in. Regular → empty path.
  @Test func homeAppearingInRegularWithStashedTapOpensThatSessionInstead() async {
    var initial = AppFeature.State(layout: .regular)
    initial.pendingPushTap = PushTap(sessionID: "s-tap")
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off

    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    await store.finish()
    #expect(store.state.liveChat?.storedSessionID == "s-tap")
    #expect(store.state.liveChat?.isUnpromptedNewChat == false)
    #expect(store.state.path.isEmpty)
  }

  /// …and when the stash is DROPPED instead (it belongs to another server), nothing replays,
  /// so the landing must still seat the detail column — regular never shows a blank detail.
  @Test func homeAppearingInRegularWithForeignStashedTapStillSeatsTheDetail() async {
    let store = TestStore(initialState: AppFeature.State(layout: .regular)) {
      AppFeature()
    } withDependencies: {
      $0.preferences.loadServerURL = { "http://old.tailnet:9119" }
      $0.push = PushClient.inMemory().client
    }

    await store.send(.pushTapped(PushTap(sessionID: "s-foreign"))) {
      $0.pendingPushTap = PushTap(sessionID: "s-foreign")
      $0.pendingPushTapServerURL = URL(string: "http://old.tailnet:9119")!
    }
    await store.send(.autoConnectSucceeded(connection)) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
      $0.pendingPushTapServerURL = nil
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    #expect(store.state.path.isEmpty)
  }

  /// Widening onto an EMPTY slot with a list present seats a fresh new chat.
  @Test func layoutChangedToRegularWithNilSlotFillsNewChat() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    #expect(store.state.path.isEmpty)
  }

  /// Narrowing with a nil slot never fills — the stack shows the list.
  @Test func layoutChangedToCompactWithNilSlotDoesNotFill() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
    }
    #expect(store.state.liveChat == nil)
  }

  /// The regular seat is the same construction as "new session": it carries the list's
  /// selected profile so its first prompt lands in the right `state.db`.
  @Test func regularSeatCarriesSelectedProfile() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        )
      )
    ) {
      AppFeature()
    }

    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: "work", composerText: "")
      $0.slotGeneration = 1
    }
  }

  /// "New session" over an UNPROMPTED new chat (connected but never prompted): the composer
  /// draft — text AND staged attachments — resets, and nothing else happens: no
  /// `persistNow` / `teardown` / `clearLiveChat` / `fillLiveChat`, so the live socket
  /// is not redialled.
  @Test func newSessionOverUnpromptedChatClearsComposerOnly() async {
    var chat = ChatFeature.State(connection: connection, profileName: nil, composerText: "half-typed")
    chat.liveSessionID = "live-new"
    chat.status = .ready
    chat.attachments = [
      ComposerAttachment(
        id: UUID(), kind: .image, filename: "p.png", mimeType: "image/png", data: Data([1])
      )
    ]
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: chat, layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat?.composerText = ""
      $0.liveChat?.attachments = []
    }
    // Exhaustive store: any teardown chain would have failed the test above.
    #expect(store.state.liveChat?.liveSessionID == "live-new", "the live session survives")
    #expect(store.state.liveChat?.status == .ready)
    #expect(store.state.path.isEmpty)
  }

  /// A SEEDED "new session" (push "Ask agent to install") over an unprompted new chat seeds the
  /// draft the same way — still no refill.
  @Test func seededNewSessionOverUnpromptedChatSeedsComposerOnly() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: ChatFeature.State(connection: connection, profileName: nil, composerText: ""),
        layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: PushSetup.installPrompt)))) {
      $0.liveChat?.composerText = PushSetup.installPrompt
    }
  }

  /// Compact safety net for the no-op: an unprompted new chat that is somehow DETACHED (no
  /// marker) gets its marker back, so the "New" tap always lands on a screen.
  @Test func newSessionOverDetachedUnpromptedChatInCompactReattachesMarker() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: ChatFeature.State(connection: connection, profileName: nil, composerText: "x")
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat?.composerText = ""
      $0.path = StackState([ChatScreen.State(sessionKey: nil)])
    }
  }

  /// The seat's CONNECTION is deliberately not part of the reuse rule — it is not what makes a
  /// seat "the chat the list would build now". Even with the two out of step, "New session"
  /// only resets the composer. Exhaustive: a teardown would fail the send.
  @Test func newSessionOverUnpromptedChatWithFresherCookiesStillOnlyResetsComposer() async {
    var seat = ChatFeature.State(connection: freshCookieConnection(username: "alice"))
    seat.composerText = "half-typed"
    seat.liveSessionID = "live-new"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat?.composerText = ""
    }
    #expect(store.state.liveChat?.connection == freshCookieConnection(username: "alice"))
    #expect(store.state.slotGeneration == 0, "no refill — the seat was reused")
  }

  /// An unprompted new chat under a STALE profile (the selection changed under it) is not "the
  /// same" new chat — it is torn down and refilled under the current profile.
  @Test func newSessionOverUnpromptedChatUnderStaleProfileRefills() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        ),
        liveChat: ChatFeature.State(connection: connection, profileName: nil, composerText: ""),
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: "work", composerText: "")
      $0.slotGeneration = 1
    }
    // Regular: the parent dials the replacement.
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.path.isEmpty)
    await store.send(.liveChat(.teardown))
  }

  /// The seat's `session.create` handshake writes a `stored_session_id` seconds after it is
  /// seated, with no prompt and no DB row behind it. "New session" over such a seat must
  /// still be the composer reset, not a redial. Exhaustive: a teardown would fail the send.
  @Test func newSessionOverAConnectedSeatStillOnlyResetsComposer() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "typed")
    seat.liveSessionID = "live-new"
    seat.storedSessionID = "20260610_seat" // what `session.create` handed back
    seat.status = .ready
    seat.hasHydrated = true
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil)))) {
      $0.liveChat?.composerText = ""
    }
    #expect(store.state.liveChat?.liveSessionID == "live-new", "the live session survives")
    #expect(store.state.slotGeneration == 0, "no refill — the seat was reused")
  }

  /// A clipboard load still resolving (#54) cannot be undone by clearing the draft: its batch
  /// lands later and would append into the "fresh" composer. Such a seat takes the real
  /// refill, whose replacement starts at `pendingPasteCount == 0` and drops the batch.
  @Test func newSessionOverASeatWithAPendingPasteRefillsInstead() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "typed")
    seat.liveSessionID = "live-new"
    seat.pendingPasteCount = 1
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.liveChat?.pendingPasteCount == 0, "the pending paste can no longer land")
    await store.send(.liveChat(.teardown))
  }

  /// Same for voice: a recording (or its transcription) in flight outlives a draft reset —
  /// the mic keeps running and the transcript appends afterwards. The real refill's
  /// `.teardown` releases the mic and the replacement is idle.
  @Test func newSessionOverARecordingSeatRefillsInstead() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    seat.recording = .recording
    seat.recordingSeconds = 3
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown) {
      $0.liveChat?.recording = .idle
      $0.liveChat?.recordingSeconds = 0
    }
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.liveChat?.recording == .idle)
    await store.send(.liveChat(.teardown))
  }

  /// A seat whose `session.create` FAILED looks unprompted but is unusable: no live session,
  /// no retry until the socket drops, and a banner on screen. "New session" over it must be
  /// the real refill (a fresh seat that dials again), not a composer reset that leaves the
  /// user tapping New on a dead chat.
  @Test func newSessionOverASeatWhoseSessionCreateFailedRefillsInstead() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.hasStarted = true
    seat.hasRequestedSession = true
    seat.status = .ready
    seat.errorBanner = "Server error: could not create session"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.liveChat?.errorBanner == nil, "the failure is gone with the dead seat")
    #expect(store.state.liveChat?.hasRequestedSession == false, "the replacement dials again")
    await store.send(.liveChat(.teardown))
  }

  /// "New session" over a NON-empty chat (a resumed session on screen) tears it down and
  /// seats the fresh chat — the path stays empty in regular (no marker).
  @Test func newSessionOverNonEmptyChatInRegularTearsDownAndRefills() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: chat, layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.home(.delegate(.createSession(initialComposerText: nil))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    // Regular: the parent dials the replacement.
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.path.isEmpty)
    await store.send(.liveChat(.teardown))
  }

  /// Opening a session in regular over the seated unprompted new chat replaces it through the
  /// standard teardown-then-fill (its socket may already be dialled) — no marker either way.
  @Test func openingSessionInRegularOverUnpromptedChatReplacesItWithoutMarker() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: seat, layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.home(.delegate(.openSession(Session(id: "s1", title: "Chat")))))
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(
        connection: self.connection, resumeStoredID: "s1", profileName: nil, title: "Chat"
      )
      $0.slotGeneration = 1
    }
    // Regular: the parent dials the replacement.
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.path.isEmpty)
    await store.send(.liveChat(.teardown))
  }

  /// A regular-width slot replacement dials the replacement from the reducer
  /// (`.fillLiveChat`) — exactly one socket, the old one cancelled first. The detail view's
  /// own `.task`, which fires too (the shell re-creates it per `slotGeneration`), is a no-op
  /// through `hasStarted`, never a redial.
  @Test func slotReplacementInRegularDialsReplacementExactlyOnce() async {
    let connectCount = LockIsolated(0)
    let cancelCount = LockIsolated(0)
    var old = ChatFeature.State(connection: connection, resumeStoredID: "old")
    old.liveSessionID = "old-live"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection), liveChat: old, layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCount.withValue { $0 += 1 }
        return AsyncStream { continuation in
          continuation.onTermination = { _ in cancelCount.withValue { $0 += 1 } }
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // The old chat is on screen and dialled (its first appearance).
    await store.send(.liveChat(.task))
    await waitUntil { connectCount.value == 1 }

    // The whole chain reduces synchronously (`.send` is a `Just`), so the counts are asserted
    // after it: the old socket terminated exactly once, the replacement dialled exactly once.
    await store.send(.home(.delegate(.openSession(Session(id: "new")))))
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat)
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    await waitUntil { connectCount.value == 2 }
    await waitUntil { cancelCount.value == 1 }
    #expect(store.state.liveChat?.storedSessionID == "new")
    #expect(store.state.path.isEmpty)

    // A view `.task` on the same slot (the column re-created on a size-class change) must
    // not cancel-and-redial the healthy socket.
    await store.send(.liveChat(.task))
    #expect(connectCount.value == 2)
    #expect(cancelCount.value == 1)

    await store.send(.liveChat(.teardown))
    await waitUntil { cancelCount.value == 2 }
  }

  /// Archiving the ON-SCREEN session in regular tears the slot down and seats a fresh new
  /// chat behind it — the detail column never goes blank. Path stays empty.
  @Test func archivingOnScreenSessionInRegularRefillsNewChat() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in }
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.home(.archiveButtonTapped(id: "s1")))
    await store.send(.home(.confirmationDialog(.presented(.confirmArchive(id: "s1")))))
    await store.receive(\.home.delegate.sessionArchived)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
    }
    // Regular: the parent starts the seated chat; cancel its socket before finishing.
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    await store.send(.liveChat(.teardown))
    await store.finish()
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat?.isUnpromptedNewChat == true)
  }

  /// ACCEPTED COST of the always-seated detail column (see `docs/features/ipad-layout.md`):
  /// the reducer-side dial takes the seat's socket to `.ready`, where `ChatFeature`'s
  /// no-stored-id branch sends a `session.create` — a server-side handle nobody asked for.
  /// It is deliberate: the created session gets no DB row until its first prompt, so an
  /// abandoned seat never reaches the session list.
  @Test func regularSeatRefillCreatesServerSessionWithoutUserAction() async {
    let methods = LockIsolated<[String]>([])
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in }
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { $0.yield(.ready) } }
      $0.hermesGateway.send = { @Sendable method, _ in
        methods.withValue { $0.append(method) }
        return .object([
          "session_id": .string("seat-live"),
          "stored_session_id": .string("seat-stored"),
          "message_count": .number(0),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.archiveButtonTapped(id: "s1")))
    await store.send(.home(.confirmationDialog(.presented(.confirmArchive(id: "s1")))))
    await store.receive(\.home.delegate.sessionArchived)
    await store.receive(\.fillLiveChat)
    // The reducer dials the replacement seat; nothing but the archive was ever tapped.
    await store.receive(\.liveChat.task)
    await store.receive(\.liveChat.gatewayEvent)
    await store.receive(\.liveChat.sessionResult.success)
    #expect(methods.value.contains("session.create"))
    #expect(store.state.liveChat?.liveSessionID == "seat-live")
    await store.send(.liveChat(.teardown))
  }

  /// The same archive in compact leaves the slot nil — the user is on the list, nothing
  /// needs a screen. Asserted after `finish()` so a stray refill cannot hide.
  @Test func archivingSlotSessionInCompactLeavesSlotNil() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in }
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.home(.archiveButtonTapped(id: "s1")))
    await store.send(.home(.confirmationDialog(.presented(.confirmArchive(id: "s1")))))
    await store.receive(\.home.delegate.sessionArchived)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.finish()
    #expect(store.state.liveChat == nil)
    #expect(store.state.path.isEmpty)
  }

  /// Deleting the ON-SCREEN session in regular: teardown WITHOUT the snapshot flush (the
  /// wipe follows), then the fresh new chat is seated and the cache entry is gone.
  @Test func deletingOnScreenSessionInRegularRefillsNewChat() async {
    let snapshots = ChatSnapshotClient.inMemory()
    snapshots.saveSnapshot("s1", ChatSnapshot(model: "gpt-5", rows: []))
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in }
      $0.chatSnapshot = snapshots
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.home(.deleteButtonTapped(id: "s1")))
    await store.send(.home(.confirmationDialog(.presented(.confirmDelete(id: "s1")))))
    await store.receive(\.home.delegate.sessionDeleted)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
    }
    // Regular: the parent starts the seated chat; cancel its socket before finishing.
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    await store.send(.liveChat(.teardown))
    await store.finish()
    #expect(store.state.path.isEmpty)
    #expect(snapshots.loadSnapshot("s1") == nil)
  }

  /// A different user re-authenticating in regular: the old slot is dropped with the old
  /// identity and the NEW user's detail column gets its fresh new chat (under the new
  /// connection, default profile — the prefs were just cleared). The seat arrives through the
  /// `.fillLiveChat` ACTION, in its own reduction — so the expired chat's effects are
  /// cancelled by the nil-out — and is DIALLED; a seat that never connects can never send.
  @Test func differentUserReauthInRegularSeatsNewChatForNewUser() async {
    let connectCount = LockIsolated(0)
    let fresh = freshCookieConnection(username: "bob")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        liveChat: ChatFeature.State(connection: cookieConnection),
        layout: .regular,
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCount.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reauth(.presented(.delegate(.reauthenticated(connection: fresh, sameUser: false))))) {
      $0.reauth = nil
      $0.home = SessionListFeature.State(connection: fresh)
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: fresh, profileName: nil, composerText: "")
      $0.slotGeneration = 1
    }
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.path.isEmpty)
    #expect(connectCount.value == 1, "the new user's seat is connected, not left idle")
    await store.send(.liveChat(.teardown))
    await store.finish()
  }

  // MARK: Push-tap routing in regular width (#32 under `isChatDetached`)

  /// Regular: the slot is the visible detail with an EMPTY path, so a tap for its session is
  /// "already on screen" through `isChatDetached` — no `openSession`, no marker, no slot
  /// re-init. Exhaustive: any follow-up action would fail the send.
  @Test func pushTapForOnScreenSessionInRegularHydratesInPlaceWithEmptyPath() async {
    let push = PushClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.composerText = "unsent draft"

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }

    await store.send(.pushTapped(PushTap(sessionID: "s1")))
    await store.finish()
    // Path stays EMPTY — the compact re-attach branch (marker push) must never fire here.
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat?.storedSessionID == "s1")
    #expect(store.state.liveChat?.composerText == "unsent draft")
    #expect(store.state.liveChat?.expectsPendingApproval == false)
  }

  /// Regular, approval tap for the on-screen session: the #30 hint is armed and the
  /// consuming `.foreground` hydrate is driven directly — the same in-place shape as
  /// compact, still with an empty path and the badge netting zero.
  @Test func approvalTapForOnScreenSessionInRegularDrivesForegroundHydrate() async {
    let push = PushClient.inMemory()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
    chat.hasRequestedSession = true
    chat.hasStarted = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live1"),
          "stored_session_id": .string("s1"),
          "messages": .array([]),
          "running": .bool(true),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.pushTapped(PushTap(sessionID: "s1", type: "approval"))) {
      $0.liveChat?.expectsPendingApproval = true
      $0.pendingApprovalSessionIDs = []
    }
    await store.receive(\.liveChat.foreground)
    await store.skipReceivedActions()
    #expect(
      store.state.liveChat?.pendingInteraction
        == .approval(ChatFeature.recoveredApprovalRequest)
    )
    #expect(store.state.liveChat?.expectsPendingApproval == false)
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat?.storedSessionID == "s1")
    #expect(push.badgeCount == 0)

    await store.send(.liveChat(.teardown))
  }

  /// Regular: a tap for a DIFFERENT session replaces the occupied slot through the full
  /// teardown chain (persist → teardown → nil-out → fill) and leaves the path EMPTY — the
  /// new slot is the detail column; a marker would double-render it in the sidebar stack.
  @Test func pushTapForDifferentSessionInRegularReplacesSlotWithEmptyPath() async {
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
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "new")))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat)
    await store.receive(\.fillLiveChat)
    // Regular: the parent starts the replacement (no marker, so no fresh view `.task`).
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat?.storedSessionID == "new")
    #expect(store.state.liveChat?.expectsPendingApproval == false)
    await store.send(.liveChat(.teardown))
  }

  /// Regular: the seated UNPROMPTED new chat (the detail column's default) counts as an occupied
  /// slot for a tap — it may hold a dialled socket — so the tap replaces it via the teardown
  /// chain rather than a direct swap, still with an empty path.
  @Test func pushTapOverSeatedEmptyChatInRegularReplacesSeatWithEmptyPath() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: ChatFeature.State(connection: connection),
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s1")))
    await store.receive(\.home.delegate.openSession)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat)
    await store.receive(\.fillLiveChat)
    // Regular: the parent starts the replacement (no marker, so no fresh view `.task`).
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat?.storedSessionID == "s1")
    #expect(store.state.liveChat?.isUnpromptedNewChat == false)
    await store.send(.liveChat(.teardown))
  }

  /// Regular cold launch via manual login: the stashed tap replays through the one
  /// `.pushTapped` path (#46, unchanged in shape) and ends with the tapped session filling
  /// the slot and an EMPTY path — no throwaway new-chat seat on the way in.
  @Test func coldLaunchTapReplayedAfterManualLoginInRegularFillsSlotWithEmptyPath() async {
    let store = TestStore(initialState: AppFeature.State(layout: .regular)) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-manual"))) {
      $0.pendingPushTap = PushTap(sessionID: "s-manual")
    }
    #expect(store.state.liveChat == nil)

    await store.send(.onboarding(.delegate(.connected(connection)))) {
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession)
    await store.finish()
    #expect(store.state.liveChat?.storedSessionID == "s-manual")
    #expect(store.state.liveChat?.isUnpromptedNewChat == false)
    #expect(store.state.path.isEmpty)
    #expect(store.state.pendingApprovalSessionIDs.isEmpty)
  }

  /// Regular cold launch, approval tap: the replay arms the #30 recovery hint on the fresh
  /// slot and the mark-then-clear badge bookkeeping nets zero — identical to compact except
  /// for the empty path.
  @Test func coldLaunchApprovalTapReplayInRegularArmsHintWithEmptyPath() async {
    let push = PushClient.inMemory()
    let store = TestStore(initialState: AppFeature.State(layout: .regular, autoConnecting: true)) {
      AppFeature()
    } withDependencies: {
      $0.push = push.client
    }
    store.exhaustivity = .off

    await store.send(.pushTapped(PushTap(sessionID: "s-approve", type: "approval"))) {
      $0.pendingApprovalSessionIDs = ["s-approve"]
      $0.pendingPushTap = PushTap(sessionID: "s-approve", type: "approval")
    }
    await store.finish()
    #expect(push.badgeCount == 1)

    await store.send(.autoConnectSucceeded(connection)) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: self.connection)
      $0.pendingPushTap = nil
    }
    await store.receive(\.pushTapped)
    await store.receive(\.home.delegate.openSession) {
      $0.pendingApprovalSessionIDs = []
    }
    await store.finish()
    #expect(push.badgeCount == 0)
    #expect(store.state.liveChat?.expectsPendingApproval == true)
    #expect(store.state.liveChat?.storedSessionID == "s-approve")
    #expect(store.state.path.isEmpty)
  }

  // MARK: - Acceptance edge cases (iPad split view, #80 — Task 10)

  /// A layout change MID-TURN keeps the socket: widening (compact stack → split) and
  /// narrowing back (split → Slide Over / stack) only reconcile the path — the running
  /// slot's one socket is never terminated or redialled, and the `chatViewDisappeared`
  /// the chat view fires while moving between columns is a no-op in BOTH directions.
  /// Exhaustive from the first layout change on: any teardown-chain action would fail it.
  @Test func layoutChangeMidTurnKeepsSocketAndSlotBothWays() async {
    let connectCount = LockIsolated(0)
    let cancelCount = LockIsolated(0)
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.isSending = true
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCount.withValue { $0 += 1 }
        return AsyncStream { continuation in
          continuation.onTermination = { _ in cancelCount.withValue { $0 += 1 } }
        }
      }
    }

    // The pushed chat dialled its one socket on first appearance (a silent stream).
    await store.send(.liveChat(.task)) {
      $0.liveChat?.hasStarted = true
    }
    await waitUntil { connectCount.value == 1 }
    let running = store.state.liveChat

    // Widen: the marker clears, the slot (and its socket) is untouched.
    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
      $0.path = .init()
    }
    // The chat view left the stack for the detail column: a no-op, no teardown.
    await store.send(.chatViewDisappeared)
    #expect(store.state.liveChat == running)

    // Narrow (Slide Over / a narrow window): the marker comes back, the slot stays.
    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: "s1")])
    }
    // The detail column's view left for the stack: a no-op again.
    await store.send(.chatViewDisappeared)
    #expect(store.state.liveChat == running)

    // Widen once more (the round-trip the plan's manual pass describes).
    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
      $0.path = .init()
    }
    #expect(store.state.currentViewingSessionID == "s1")

    // One dial, zero terminations across the whole sequence — the socket survived.
    #expect(connectCount.value == 1)
    #expect(cancelCount.value == 0)

    await store.send(.liveChat(.teardown))
    await waitUntil { cancelCount.value == 1 }
  }

  /// The column move's `chatViewDisappeared` is a no-op for an IDLE chat too — the case the
  /// compact pop policy would otherwise tear down. Regular reads the new layout through
  /// `isChatDetached` (set first); the marker pushed on narrowing protects the other way.
  @Test func chatViewDisappearedDuringColumnMoveKeepsIdleSlotBothWays() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    chat.status = .ready
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

    await store.send(.layoutChanged(.regular)) {
      $0.layout = .regular
      $0.path = .init()
    }
    await store.send(.chatViewDisappeared)
    #expect(store.state.liveChat == chat)

    await store.send(.layoutChanged(.compact)) {
      $0.layout = .compact
      $0.path = StackState([ChatScreen.State(sessionKey: "s1")])
    }
    await store.send(.chatViewDisappeared)
    #expect(store.state.liveChat == chat)
  }

  /// Logout from Settings in regular lands on onboarding with NO slot and an empty path — the
  /// regular-width seat rule must not refill a chat behind the onboarding screen (there is
  /// no list to seat it from).
  @Test func logoutInRegularLandsOnOnboardingWithNoSlot() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.push = PushClient.inMemory().client
    }

    await store.send(.home(.delegate(.disconnect))) {
      $0.home = nil
      $0.liveChat = nil
      $0.path = .init()
      $0.onboarding = .init()
    }
    await store.finish()
    #expect(store.state.rootScreen == .onboarding)
    #expect(store.state.layout == .regular, "the layout is the window's, not the identity's")
    #expect(store.state.liveChat == nil)
  }

  /// The other full logout — "Quit to start" from the re-auth modal — in regular: same
  /// landing, no slot, empty path.
  @Test func quitFromReauthInRegularLandsOnOnboardingWithNoSlot() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: cookieConnection),
        liveChat: ChatFeature.State(connection: cookieConnection),
        layout: .regular,
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .password,
          provider: "basic", previousUsername: "alice"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.keychain.deleteSession = { @Sendable in }
      $0.preferences = .inMemory()
      $0.push = PushClient.inMemory().client
    }

    await store.send(.reauth(.presented(.delegate(.quit)))) {
      $0.reauth = nil
      $0.home = nil
      $0.liveChat = nil
      $0.path = .init()
      $0.onboarding = .init()
    }
    await store.finish()
    #expect(store.state.rootScreen == .onboarding)
    #expect(store.state.liveChat == nil)
  }

  /// Switching the sidebar's profile in regular reseats the UNPROMPTED new chat under the new
  /// profile — through the standard teardown chain (the seat's socket is dialled in regular),
  /// never a direct swap — so its first prompt lands in the new profile's `state.db`. The
  /// path stays empty and the parent starts the replacement (regular has no marker).
  @Test func profileSwitchInRegularReseatsEmptyChatUnderNewProfile() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.selectProfile(name: "work"))) {
      $0.home?.selectedProfileName = "work"
    }
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: "work", composerText: "")
    }
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.path.isEmpty)
    // The list's own scoped refetch lands independently of the reseat.
    await store.receive(\.home.sessionsResponse)
    await store.receive(\.home.cronJobsResponse)
    await store.send(.liveChat(.teardown))
  }

  /// The same reseat for the seat as it actually exists a second after launch: dialled, with
  /// the `stored_session_id` its `session.create` handshake returned. Nothing has been
  /// prompted, so the profile switch must still reseat it — otherwise the first prompt is
  /// scoped to the profile the user just left.
  @Test func profileSwitchInRegularReseatsTheSeatThatAlreadyCreatedItsSession() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    seat.storedSessionID = "20260610_seat"
    seat.status = .ready
    seat.hasHydrated = true
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.selectProfile(name: "work"))) {
      $0.home?.selectedProfileName = "work"
    }
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: "work", composerText: "")
    }
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    #expect(store.state.liveChat?.profileName == "work")
    await store.send(.liveChat(.teardown))
  }

  /// The reseat re-creates the seat under the new profile; it does not empty it. A typed
  /// draft and staged attachments are the user's — unlike "New session", switching the
  /// sidebar's profile is not a request to clear the composer — so they ride across.
  @Test func profileSwitchInRegularCarriesTheSeatsDraftAcrossTheReseat() async {
    let attachment = ComposerAttachment(
      id: UUID(0), kind: .image, filename: "p.png", mimeType: "image/png", data: Data([1])
    )
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "half-typed")
    seat.liveSessionID = "live-new"
    seat.attachments = [attachment]
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.selectProfile(name: "work")))
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.profileName == "work")
    #expect(store.state.liveChat?.composerText == "half-typed")
    #expect(store.state.liveChat?.attachments == [attachment])
    await store.send(.liveChat(.teardown))
  }

  /// A reseat mid-paste would tear the seat down before the batch lands (the pairing token is
  /// per-`State`, so the replacement drops it). The switch DEFERS instead: the seat keeps its
  /// stale profile while the load runs, and the reseat fires the moment the batch lands —
  /// carrying the draft AND the freshly pasted attachment under the new profile.
  @Test func profileSwitchDuringAPendingPasteDefersTheReseatUntilTheBatchLands() async {
    let pasted = PickedItem(
      data: Data([0x89, 0x50]), filename: "pasted.png", mimeType: "image/png", kind: .image
    )
    let seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "half-typed")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.uuid = .incrementing
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.liveChat(.attachmentsPasting))
    await store.send(.home(.selectProfile(name: "work")))
    #expect(store.state.liveChat?.profileName == nil, "the reseat waits for the paste")
    #expect(store.state.liveChat?.pendingPasteCount == 1)

    await store.send(.liveChat(.attachmentsPasted(PickedBatch(items: [pasted]))))
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.profileName == "work")
    #expect(store.state.liveChat?.composerText == "half-typed")
    #expect(store.state.liveChat?.attachments.count == 1, "the pasted image rode across")
    await store.send(.liveChat(.teardown))
  }

  /// The recording half of the same rule: switching profiles while the mic is live leaves the
  /// seat (and the recording) alone rather than tearing it down mid-sentence.
  @Test func profileSwitchDuringARecordingLeavesTheSeatAlone() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    seat.recording = .recording
    seat.recordingSeconds = 5
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.preferences = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.selectProfile(name: "work")))
    await store.receive(\.home.sessionsResponse)
    await store.receive(\.home.cronJobsResponse)
    #expect(store.state.liveChat?.recording == .recording)
    #expect(store.state.liveChat?.recordingSeconds == 5)
    #expect(store.state.liveChat?.profileName == nil)
  }

  /// The profiles capability flipping OFF (a 404 verdict) makes a seat under a custom profile
  /// stale in the same way — `scopedProfileName` becomes `nil` — so it is reseated unscoped.
  @Test func profilesUnsupportedVerdictInRegularReseatsScopedEmptyChat() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        ),
        liveChat: ChatFeature.State(connection: connection, profileName: "work", composerText: ""),
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.profilesResponse(.failure(.notFound)))) {
      $0.home?.profilesSupported = false
    }
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.connection, profileName: nil, composerText: "")
    }
    await store.receive(\.liveChat.task) {
      $0.liveChat?.hasStarted = true
    }
    await store.receive(\.home.sessionsResponse)
    await store.receive(\.home.cronJobsResponse)
    await store.send(.liveChat(.teardown))
  }

  /// A profile switch never touches a chat with anything in it: a resumed session on screen
  /// in regular belongs to ITS profile, so switching the list's scope leaves the slot alone
  /// (exhaustive — no teardown chain, no refill).
  @Test func profileSwitchInRegularLeavesNonEmptyChatAlone() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.liveSessionID = "live1"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: chat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.preferences = .inMemory()
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }

    await store.send(.home(.selectProfile(name: "work"))) {
      $0.home?.selectedProfileName = "work"
      $0.home?.now = Date(timeIntervalSince1970: 0)
      $0.home?.isLoading = true
    }
    await store.receive(\.home.sessionsResponse) {
      $0.home?.isLoading = false
    }
    await store.receive(\.home.cronJobsResponse) {
      $0.home?.cronJobsSupported = false
    }
    #expect(store.state.liveChat == chat)
  }

  /// Compact has no seat rule: an unprompted new chat left in the slot is untouched by a profile
  /// switch (the iPhone path stays byte-identical; "New session" applies the stale-profile
  /// refill there when tapped).
  @Test func profileSwitchInCompactLeavesEmptyChatAlone() async {
    let chat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.preferences = .inMemory()
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }

    await store.send(.home(.selectProfile(name: "work"))) {
      $0.home?.selectedProfileName = "work"
      $0.home?.now = Date(timeIntervalSince1970: 0)
      $0.home?.isLoading = true
    }
    await store.receive(\.home.sessionsResponse) {
      $0.home?.isLoading = false
    }
    await store.receive(\.home.cronJobsResponse) {
      $0.home?.cronJobsSupported = false
    }
    #expect(store.state.liveChat == chat)
    #expect(store.state.path.isEmpty)
  }

  /// A reseat that falls due while the window is narrow must not be LOST: the mismatch is
  /// deferred, not dropped. Switch profiles mid-recording in regular (deferred), narrow (the
  /// recording seat keeps its marker), let the transcription land in compact — where the
  /// regular-only rule declines — then widen: the reseat fires with the dictated draft.
  @Test func profileSwitchDeferredIntoCompactIsReseatedOnWidening() async {
    var seat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    seat.liveSessionID = "live-new"
    seat.recording = .recording
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: seat,
        layout: .regular
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.uuid = .incrementing
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.selectProfile(name: "work")))
    #expect(store.state.liveChat?.profileName == nil, "the reseat waits for the recording")

    await store.send(.layoutChanged(.compact))
    #expect(store.state.path.count == 1, "a recording seat is not pristine — it keeps a marker")

    await store.send(.liveChat(.transcriptionSucceeded("dictated words")))
    #expect(store.state.liveChat?.profileName == nil, "compact has no seat rule")
    #expect(store.state.liveChat?.composerText == "dictated words")

    await store.send(.layoutChanged(.regular))
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.profileName == "work")
    #expect(store.state.liveChat?.composerText == "dictated words", "the dictation rode across")
    #expect(store.state.path.isEmpty)
    await store.send(.liveChat(.teardown))
  }

  /// The same rule without a resize in the middle: the profiles capability flipping off while
  /// the chat is pushed in compact leaves the seat scoped to a profile the list no longer
  /// has — widening re-evaluates it instead of trusting the stale scope.
  @Test func profileVerdictWhileCompactIsReseatedOnWidening() async {
    let seat = ChatFeature.State(connection: connection, profileName: "work", composerText: "notes")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection, selectedProfileName: "work", profilesSupported: true
        ),
        path: StackState([ChatScreen.State(sessionKey: nil)]),
        liveChat: seat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.profilesResponse(.failure(.notFound))))
    #expect(store.state.liveChat?.profileName == "work", "compact declines the reseat")

    await store.send(.layoutChanged(.regular))
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.profileName == nil)
    #expect(store.state.liveChat?.composerText == "notes")
    #expect(store.state.path.isEmpty)
    await store.send(.liveChat(.teardown))
  }

  // MARK: - Bearer (native OAuth) regime lifecycle (#19, Task 13)

  private func bearerSession(
    userID: String = "user-42", accessToken: String = "access-1"
  ) -> BearerSession {
    BearerSession(
      accessToken: accessToken,
      refreshToken: "refresh-1",
      expiresAt: 4_000_000_000,
      provider: "nous",
      userID: userID
    )
  }

  private func bearerConnection(_ session: BearerSession) -> ServerConnection {
    ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, auth: .bearer(session))
  }

  /// The launch-restore ordering rule: a `.bearer` connection resolves its `Authorization`
  /// header through `BearerTokenStore`, so the store must be seeded BEFORE the probe fires.
  /// Probing an unseeded store sends the request with no credentials and 401s a live session
  /// into onboarding — the assertion that carries the proof is taken from INSIDE the probe.
  @Test func bearerLaunchRestoreSeedsTheTokenStoreBeforeProbing() async {
    let session = bearerSession()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .bearer(session) }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.bearerTokens = tokenStore
      $0.hermesREST.sessions = { @Sendable connection, _, _, _ in
        #expect(await tokenStore.current == session, "the probe must run against a seeded store")
        #expect(connection.token == nil) // never the legacy session-token path
        return []
      }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectSucceeded) {
      $0.autoConnecting = false
      $0.home = SessionListFeature.State(connection: self.bearerConnection(session))
    }
  }

  /// A dead refresh token surfaces from the store as `RESTError.unauthorized`, so it takes
  /// the EXISTING credentials-verdict branch of the #62 routing rule — prefilled onboarding,
  /// no retry screen, no bearer carve-out. The store is drained: the pair is dead, and
  /// leaving it seeded would authenticate the next request with rejected credentials.
  @Test func bearerLaunchProbe401FallsBackToOnboardingAndDrainsTheStore() async {
    let session = bearerSession()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .bearer(session) }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.bearerTokens = tokenStore
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      // URL only — a browser leg is not prefillable, exactly like the cookie regime.
      $0.onboarding = ConnectionFeature.State(serverURL: "http://mac.tailnet:9119", token: "")
    }
    #expect(store.state.connectionFailed == nil) // #62: an auth verdict never raises Retry
    await store.finish()
    #expect(await tokenStore.current == nil)
  }

  /// The other half of the #62 rule, which the bearer regime must not weaken: a TRANSPORT
  /// failure raises the retry screen with the stored pair untouched — both in the Keychain
  /// and in the store, so the retry re-probes with real credentials.
  @Test func bearerLaunchProbeOfflineKeepsTheStoreAndRaisesRetry() async {
    let session = bearerSession()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .bearer(session) }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.bearerTokens = tokenStore
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.offline }
    }

    await store.send(.task) {
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectFailed) {
      $0.autoConnecting = false
      $0.connectionFailed = ConnectionFailedFeature.State(
        connection: self.bearerConnection(session), reason: .offline
      )
    }
    await store.finish()
    #expect(await tokenStore.current == session, "an offline probe must not drop the pair")
  }

  /// A bearer session dying mid-use raises the OAuth variant of the re-auth sheet: no
  /// username (there is nothing to type), the wire provider carried across, the identity
  /// baseline taken from the dead pair's `user_id`, and the human display name looked up
  /// from the last capability probe.
  @Test func bearerSessionExpiredRaisesTheOAuthReauthSheet() async {
    let session = bearerSession(userID: "user-42")
    let connection = bearerConnection(session)
    var onboarding = ConnectionFeature.State()
    onboarding.capability = ServerAuthCapability(
      oauthProviders: [
        AuthProvider(name: "nous", displayName: "Nous Research", supportsPassword: false),
      ],
      supportsNativeFlow: true,
      isGated: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        onboarding: onboarding,
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: connection)
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.delegate(.sessionExpired))) {
      $0.reauth = ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!,
        method: .oauth,
        provider: "nous",
        providerDisplayName: "Nous Research",
        previousUserID: "user-42"
      )
    }
  }

  /// The common case after a launch auto-restore: nothing was ever probed, so there is no
  /// display name to look up. The sheet must still name the provider — `providerLabel` falls
  /// back to the wire name rather than rendering "Continue with ".
  @Test func bearerSessionExpiredWithoutAProbeFallsBackToTheWireProviderName() async {
    let session = bearerSession(userID: "user-7")
    let connection = bearerConnection(session)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: ChatFeature.State(connection: connection)
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.delegate(.sessionExpired)))
    #expect(store.state.reauth?.method == .oauth)
    #expect(store.state.reauth?.providerDisplayName == "")
    #expect(store.state.reauth?.providerLabel == "nous")
    #expect(store.state.reauth?.previousUserID == "user-7")
  }

  /// Same-user re-auth must swap the fresh pair into the store BEFORE the slot resumes —
  /// the store still holds the DEAD pair the sheet was raised for, and a resume that
  /// overtook the reseed would re-send exactly the credentials that just expired.
  @Test func sameUserBearerReauthReseedsTheStoreBeforeResuming() async {
    let dead = bearerSession(accessToken: "dead")
    let fresh = bearerSession(accessToken: "fresh")
    let tokenStore = BearerTokenStore()
    await tokenStore.seed(
      dead, baseURL: URL(string: "http://mac.tailnet:9119")!, persist: { _ in }
    )
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: bearerConnection(dead)),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: bearerConnection(dead)),
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .oauth,
          provider: "nous", previousUserID: "user-42"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.bearerTokens = tokenStore
      $0.keychain = KeychainClient.inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
    store.exhaustivity = .off

    let freshConnection = bearerConnection(fresh)
    await store.send(.reauth(.presented(.delegate(
      .reauthenticated(connection: freshConnection, sameUser: true)
    )))) {
      $0.reauth = nil
      $0.home?.connection = freshConnection
    }
    // The reseed is CONCATENATED ahead of the resume, so by the time the resume is delivered
    // the store already holds the fresh pair.
    await store.receive(\.liveChat.resumeAfterReauth)
    #expect(await tokenStore.current == fresh)

    await store.send(.liveChat(.teardown))
  }

  /// A different `user_id` is an account switch: everything identity-scoped is dropped AND
  /// the store adopts the new account's pair — a stale one would authenticate the new user's
  /// list fetch as the old user.
  @Test func differentUserBearerReauthReseedsAndClearsIdentityPrefs() async {
    let dead = bearerSession(userID: "user-42", accessToken: "dead")
    let fresh = bearerSession(userID: "user-99", accessToken: "fresh")
    let tokenStore = BearerTokenStore()
    let profileCleared = LockIsolated(false)
    await tokenStore.seed(
      dead, baseURL: URL(string: "http://mac.tailnet:9119")!, persist: { _ in }
    )
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: bearerConnection(dead)),
        path: StackState([ChatScreen.State()]),
        liveChat: ChatFeature.State(connection: bearerConnection(dead)),
        reauth: ReauthFeature.State(
          serverURL: URL(string: "http://mac.tailnet:9119")!, method: .oauth,
          provider: "nous", previousUserID: "user-42"
        )
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.bearerTokens = tokenStore
      $0.preferences.clearSelectedProfileID = { @Sendable in profileCleared.setValue(true) }
      $0.push = PushClient.inMemory().client
    }
    store.exhaustivity = .off

    let freshConnection = bearerConnection(fresh)
    await store.send(.reauth(.presented(.delegate(
      .reauthenticated(connection: freshConnection, sameUser: false)
    )))) {
      $0.reauth = nil
      $0.path = .init()
      $0.liveChat = nil
      $0.home = SessionListFeature.State(connection: freshConnection)
    }
    #expect(profileCleared.value)
    await store.finish()
    #expect(await tokenStore.current == fresh)
  }

  /// All THREE logout paths must behave identically for the bearer regime, and in the one
  /// order that works: `rest.logout` resolves its auth through the store like any other
  /// request, so it has to fire BEFORE the drain (a drained store makes it a silent no-op —
  /// see `HermesRESTClient.logout`). The assertion inside the stub is what proves the order.
  @Test func everyLogoutPathPostsLogoutBeforeDrainingTheStore() async {
    let session = bearerSession()
    let connection = bearerConnection(session)
    // `deletesKeychainSession` is pre-existing behaviour, not part of this change: the two
    // full logouts own the Keychain delete here, while Settings' "disconnect" performs it in
    // `SettingsFeature` before delegating. The bearer teardown must be identical across all
    // three regardless.
    for (action, deletesKeychainSession) in [
      (AppFeature.Action.home(.delegate(.disconnect)), false),
      (.connectionFailed(.delegate(.logoutConfirmed)), true),
      (.reauth(.presented(.delegate(.quit))), true),
    ] {
      let tokenStore = BearerTokenStore()
      let logouts = LockIsolated(0)
      let keychain = KeychainClient.inMemory()
      try? keychain.saveSession(.bearer(session))
      await tokenStore.seed(session, baseURL: connection.baseURL, persist: { _ in })
      let store = TestStore(
        initialState: AppFeature.State(
          home: SessionListFeature.State(connection: connection),
          path: StackState([ChatScreen.State(sessionKey: "s1")]),
          liveChat: ChatFeature.State(connection: connection, resumeStoredID: "s1"),
          connectionFailed: ConnectionFailedFeature.State(
            connection: connection, reason: .offline
          ),
          reauth: ReauthFeature.State(
            serverURL: connection.baseURL, method: .oauth, provider: "nous"
          )
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.bearerTokens = tokenStore
        $0.keychain = keychain
        $0.preferences = .inMemory()
        $0.push = PushClient.inMemory().client
        $0.hermesREST.logout = { @Sendable posted in
          #expect(posted == connection)
          #expect(
            await tokenStore.current == session,
            "\(action): the store was drained before the logout could authenticate"
          )
          logouts.withValue { $0 += 1 }
        }
      }
      store.exhaustivity = .off

      await store.send(action)
      await store.finish()
      #expect(logouts.value == 1, "\(action) posted \(logouts.value) logouts")
      #expect(await tokenStore.current == nil, "\(action) left the token store seeded")
      if deletesKeychainSession {
        #expect(keychain.loadSession(.shared) == nil, "\(action) left the Keychain session")
      }
    }
  }

  /// Backward-compat guard: the token and cookie regimes' logout requests are unchanged —
  /// `POST /auth/logout` fires only for `.bearer` (the cookie jar is dropped with the app's
  /// Keychain entry, and a static token has no server-side session to end).
  @Test func tokenAndCookieLogoutSendNoLogoutRequest() async {
    for logoutConnection in [connection, cookieConnection] {
      let logouts = LockIsolated(0)
      let store = TestStore(
        initialState: AppFeature.State(
          home: SessionListFeature.State(connection: logoutConnection)
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.preferences = .inMemory()
        $0.push = PushClient.inMemory().client
        $0.hermesREST.logout = { @Sendable _ in logouts.withValue { $0 += 1 } }
      }
      store.exhaustivity = .off

      await store.send(.home(.delegate(.disconnect))) { $0.home = nil }
      await store.finish()
      #expect(logouts.value == 0, "\(logoutConnection.auth) must not post /auth/logout")
    }
  }
}
