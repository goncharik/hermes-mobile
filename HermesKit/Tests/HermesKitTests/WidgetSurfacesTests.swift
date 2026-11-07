import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// The widget surfaces sync (#138): the single `agentStatus` edge writes the App Group mirror
/// after a 1 s debounce, the scene edges restamp `freshUntil` at once, `nil` holds, and every
/// logout clears the mirror.
@MainActor
struct WidgetSurfacesTests {
  private let connection = ServerConnection(
    baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok"
  )
  private let now = Date(timeIntervalSince1970: 1_749_600_000)
  private let updatedAt = Date(timeIntervalSince1970: 1_749_590_000)

  private func session(_ id: String, active: Bool = false) -> Session {
    Session(id: id, title: "Title \(id)", updatedAt: updatedAt, isActive: active)
  }

  private func row(_ id: String, _ status: SessionStatus) -> WidgetSessionRow {
    WidgetSessionRow(id: id, title: "Title \(id)", status: status, updatedAt: updatedAt)
  }

  /// A list that has had its first unfiltered fetch (`statusSessions` set), so `agentStatus`
  /// is known.
  private func fetchedHome(_ sessions: [Session]) -> SessionListFeature.State {
    let rows = IdentifiedArray(uniqueElements: sessions)
    return SessionListFeature.State(connection: connection, sessions: rows, statusSessions: rows)
  }

  private func snapshot(
    freshFor interval: TimeInterval, _ rows: [WidgetSessionRow]
  ) -> WidgetSessionSnapshot {
    WidgetSessionSnapshot(freshUntil: now.addingTimeInterval(interval), isSignedIn: true, rows: rows)
  }

  // MARK: The agentStatus edge

  @Test func aChangeWritesOnceAfterTheDebounce() async {
    let mirror = MirrorRecorder()
    let clock = TestClock()
    let store = TestStore(initialState: AppFeature.State(home: fetchedHome([session("s1")]))) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.continuousClock = clock
      $0.date = .constant(now)
    }

    await store.send(.home(.setSessionRunning(id: "s1", running: true))) {
      $0.home?.sessions[id: "s1"]?.isActive = true
      $0.home?.statusSessions?[id: "s1"]?.isActive = true
    }
    await clock.advance(by: .milliseconds(999))
    #expect(mirror.writes.value.isEmpty)
    await clock.advance(by: .milliseconds(1))
    await store.finish()
    #expect(mirror.writes.value == [snapshot(freshFor: 8 * 60 * 60, [row("s1", .working)])])
    #expect(mirror.reloads.value == 1)
    #expect(mirror.clears.value == 0)
  }

  /// A burst (a slot's running flip next to a list fetch) coalesces: the last change wins and
  /// restarts the debounce.
  @Test func aBurstCoalescesIntoOneWrite() async {
    let mirror = MirrorRecorder()
    let clock = TestClock()
    let store = TestStore(
      initialState: AppFeature.State(home: fetchedHome([session("s1"), session("s2")]))
    ) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.continuousClock = clock
      $0.date = .constant(now)
    }

    await store.send(.home(.setSessionRunning(id: "s1", running: true))) {
      $0.home?.sessions[id: "s1"]?.isActive = true
      $0.home?.statusSessions?[id: "s1"]?.isActive = true
    }
    await clock.advance(by: .milliseconds(600))
    await store.send(.home(.setSessionRunning(id: "s2", running: true))) {
      $0.home?.sessions[id: "s2"]?.isActive = true
      $0.home?.statusSessions?[id: "s2"]?.isActive = true
    }
    await clock.advance(by: .milliseconds(600))
    #expect(mirror.writes.value.isEmpty, "the second change restarted the debounce")
    await clock.advance(by: .milliseconds(400))
    await store.finish()
    #expect(mirror.writes.value == [
      snapshot(freshFor: 8 * 60 * 60, [row("s1", .working), row("s2", .working)]),
    ])
    #expect(mirror.reloads.value == 1)
  }

  /// Before the first unfiltered fetch the projection is unknown: a list change writes
  /// nothing, and backgrounding neither writes nor stamps a freshness.
  @Test func anUnknownProjectionWritesNothing() async {
    let mirror = MirrorRecorder()
    let clock = TestClock()
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [session("s1")])
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.continuousClock = clock
      $0.date = .constant(now)
    }

    await store.send(.home(.setSessionRunning(id: "s1", running: true))) {
      $0.home?.sessions[id: "s1"]?.isActive = true
    }
    await store.send(.scenePhaseChanged(.background)) {
      $0.isSceneBackgrounded = true
    }
    await clock.advance(by: .seconds(5))
    await store.finish()
    #expect(mirror.writes.value.isEmpty)
    #expect(mirror.reloads.value == 0)
  }

  // MARK: Scene edges

  /// No running slot: the app can vouch only for the suspension margin. Written at once —
  /// an idle app may be suspended within seconds.
  @Test func backgroundWithoutARunningSlotRestampsTenSeconds() async {
    let mirror = MirrorRecorder()
    let store = TestStore(
      initialState: AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    ) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.date = .constant(now)
    }

    await store.send(.scenePhaseChanged(.background)) {
      $0.isSceneBackgrounded = true
      $0.backgroundFreshUntil = self.now.addingTimeInterval(10)
    }
    await store.finish()
    #expect(mirror.writes.value == [snapshot(freshFor: 10, [row("s1", .working)])])
    #expect(mirror.reloads.value == 1)
  }

  /// A running slot keeps observing through its ~30 s grace window, so the promise covers it.
  @Test func backgroundWithARunningSlotCoversTheGraceWindow() async {
    let mirror = MirrorRecorder()
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1")
    chat.isSending = true
    let store = TestStore(
      initialState: AppFeature.State(
        home: fetchedHome([session("s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.date = .constant(now)
      $0.chatSnapshot = .inMemory()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.background))
    #expect(store.state.backgroundFreshUntil == now.addingTimeInterval(40))
    await store.skipReceivedActions()
    await store.finish()
    // The slot's live running flag makes the (polled-idle) row working.
    #expect(mirror.writes.value == [snapshot(freshFor: 40, [row("s1", .working)])])
  }

  /// A change while backgrounded keeps the background promise instead of re-extending it to
  /// the foreground freshness.
  @Test func aChangeWhileBackgroundedKeepsTheBackgroundFreshness() async {
    let mirror = MirrorRecorder()
    let clock = TestClock()
    let freshUntil = now.addingTimeInterval(25)
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.isSceneBackgrounded = true
    state.backgroundFreshUntil = freshUntil
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.continuousClock = clock
      $0.date = .constant(now)
    }

    await store.send(.home(.setSessionRunning(id: "s1", running: false))) {
      $0.home?.sessions[id: "s1"]?.isActive = false
      $0.home?.statusSessions?[id: "s1"]?.isActive = false
    }
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(mirror.writes.value == [
      WidgetSessionSnapshot(freshUntil: freshUntil, isSignedIn: true, rows: [row("s1", .idle)]),
    ])
  }

  /// Foregrounding restores the long foreground freshness at once (the "Outdated" entry the
  /// background write scheduled must not fire under a live app) and drops the background stamp.
  @Test func foregroundRestoresTheForegroundFreshness() async {
    let mirror = MirrorRecorder()
    let sessions = [session("s1", active: true)]
    var state = AppFeature.State(home: fetchedHome(sessions))
    state.isSceneBackgrounded = true
    state.backgroundFreshUntil = now.addingTimeInterval(10)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.continuousClock = TestClock()
      $0.date = .constant(now)
      // The list refresh returns the same rows, so the edge itself doesn't fire.
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in sessions }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active)) {
      $0.isSceneBackgrounded = false
      $0.backgroundFreshUntil = nil
    }
    await store.skipReceivedActions()
    await store.finish()
    #expect(mirror.writes.value == [snapshot(freshFor: 8 * 60 * 60, [row("s1", .working)])])
  }

  // MARK: Logout

  /// Every identity teardown replaces the mirror with the signed-out snapshot, and a write
  /// still waiting out its debounce never lands after the clear.
  @Test func everyLogoutClearsTheMirrorAndDropsAPendingWrite() async {
    for action in [
      AppFeature.Action.home(.delegate(.disconnect)),
      .connectionFailed(.delegate(.logoutConfirmed)),
      .reauth(.presented(.delegate(.quit))),
      .reauth(.presented(.delegate(.reauthenticated(
        connection: ServerConnection(baseURL: connection.baseURL, token: "other"),
        sameUser: false
      )))),
    ] {
      let label = "\(action)"
      let mirror = MirrorRecorder()
      let clock = TestClock()
      let store = TestStore(
        initialState: AppFeature.State(
          home: fetchedHome([session("s1")]),
          connectionFailed: ConnectionFailedFeature.State(connection: connection, reason: .offline),
          reauth: ReauthFeature.State(serverURL: connection.baseURL, method: .token)
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.widgetMirror = mirror.client
        $0.continuousClock = clock
        $0.date = .constant(now)
        $0.preferences = .inMemory()
        $0.push = PushClient.inMemory().client
      }
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(.home(.setSessionRunning(id: "s1", running: true)))
      await store.send(action)
      await clock.advance(by: .seconds(5))
      await store.finish()
      #expect(mirror.clears.value == 1, "\(label) left the mirror in place")
      #expect(mirror.reloads.value == 1, "\(label) didn't reload the widget")
      #expect(mirror.writes.value.isEmpty, "\(label) let the pending write land after the clear")
    }
  }

  // MARK: The Live Activity

  private static let foreground: TimeInterval = 8 * 60 * 60

  /// The activity content for `ids` working, headlined by the first.
  private func working(
    _ ids: [String], status: AgentActivityContent.Status = .working, titled: Bool = true
  ) -> AgentActivityContent {
    AgentActivityContent(
      activeCount: ids.count,
      headlineTitle: titled ? "Title \(ids[0])" : nil,
      headlineSessionID: ids[0],
      status: status
    )
  }

  private func seat(
    _ id: String?, _ content: AgentActivityContent, request: Int = 1
  ) -> AppFeature.LiveActivitySeat {
    AppFeature.LiveActivitySeat(id: id, content: content, request: request)
  }

  private func makeStore(
    _ state: AppFeature.State,
    activity: ActivityRecorder,
    clock: TestClock<Duration> = TestClock(),
    preferences: PreferencesClient = .inMemory()
  ) -> TestStoreOf<AppFeature> {
    TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = MirrorRecorder().client
      $0.liveActivity = activity.client
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.preferences = preferences
    }
  }

  /// The first active agent starts the activity AT ONCE (a start is foreground-only, so it
  /// can't wait out the debounce), stale at the foreground freshness; the seat is taken before
  /// the request returns and adopts the id when it does. The start first ends whatever is
  /// still on screen — the previous turn's lingering "Done" — so turns never stack.
  @Test func theFirstActiveAgentStartsTheActivity() async {
    let activity = ActivityRecorder()
    let clock = TestClock()
    let store = makeStore(
      AppFeature.State(home: fetchedHome([session("s1")])), activity: activity, clock: clock
    )

    await store.send(.home(.setSessionRunning(id: "s1", running: true))) {
      $0.home?.sessions[id: "s1"]?.isActive = true
      $0.home?.statusSessions?[id: "s1"]?.isActive = true
      $0.liveActivityRequests = 1
      $0.liveActivity = self.seat(nil, self.working(["s1"]))
    }
    await store.receive(\.liveActivityStarted) {
      $0.liveActivity?.id = "activity-1"
    }
    #expect(store.state.liveActivityID == "activity-1")
    await clock.advance(by: .seconds(1)) // the mirror's debounced write
    await store.finish()
    #expect(activity.calls.value == [
      .endAll,
      .start(working(["s1"]), staleDate: now.addingTimeInterval(Self.foreground)),
    ])
  }

  /// A new chat's first turn: its session isn't in the list yet, but the running slot brings
  /// its own row, so the activity starts without waiting for the list to refetch.
  @Test func aNewChatsFirstTurnStartsTheActivity() async {
    let activity = ActivityRecorder()
    var chat = ChatFeature.State(connection: connection, profileName: nil, composerText: "")
    chat.liveSessionID = "new"
    chat.isSending = true
    // The list's first fetch hasn't landed yet: the projection is unknown.
    let store = makeStore(
      AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: StackState([ChatScreen.State(sessionKey: nil)]),
        liveChat: chat
      ),
      activity: activity
    )
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.sessionsResponse(.success([session("old")]))))
    await store.receive(\.liveActivityStarted)
    #expect(store.state.liveActivityID == "activity-1")
    let content = AgentActivityContent(
      activeCount: 1, headlineTitle: "new", headlineSessionID: "new", status: .working
    )
    #expect(activity.calls.value == [
      .endAll, .start(content, staleDate: now.addingTimeInterval(Self.foreground)),
    ])
  }

  @Test func aChangeUpdatesTheActivityAfterTheDebounce() async {
    let activity = ActivityRecorder()
    let clock = TestClock()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true), session("s2")]))
    state.liveActivity = seat("a1", working(["s1"]))
    let store = makeStore(state, activity: activity, clock: clock)

    await store.send(.home(.setSessionRunning(id: "s2", running: true))) {
      $0.home?.sessions[id: "s2"]?.isActive = true
      $0.home?.statusSessions?[id: "s2"]?.isActive = true
    }
    await clock.advance(by: .milliseconds(999))
    #expect(activity.calls.value.isEmpty)
    await clock.advance(by: .milliseconds(1))
    await store.receive(\.liveActivitySyncDue) {
      $0.liveActivity?.content = self.working(["s1", "s2"])
    }
    await store.finish()
    #expect(activity.calls.value == [
      .update("a1", working(["s1", "s2"]), staleDate: now.addingTimeInterval(Self.foreground)),
    ])
  }

  /// Nothing active: the activity ends showing its last headline as "Done", left on the Lock
  /// Screen for five minutes.
  @Test func zeroActiveEndsTheActivityWithDone() async {
    let activity = ActivityRecorder()
    let clock = TestClock()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.liveActivity = seat("a1", working(["s1"]))
    let store = makeStore(state, activity: activity, clock: clock)

    await store.send(.home(.setSessionRunning(id: "s1", running: false))) {
      $0.home?.sessions[id: "s1"]?.isActive = false
      $0.home?.statusSessions?[id: "s1"]?.isActive = false
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.liveActivitySyncDue) {
      $0.liveActivity = nil
    }
    await store.finish()
    let done = AgentActivityContent(
      activeCount: 0, headlineTitle: "Title s1", headlineSessionID: "s1", status: .done
    )
    #expect(activity.calls.value == [
      .end("a1", done, dismissAfter: now.addingTimeInterval(5 * 60)),
    ])
  }

  /// A turn ending right before the next one starts (a drained queue) settles inside the
  /// debounce: no "Done", no restart — and an unchanged content isn't re-sent.
  @Test func aGapInsideTheDebounceNeitherEndsNorUpdates() async {
    let activity = ActivityRecorder()
    let clock = TestClock()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.liveActivity = seat("a1", working(["s1"]))
    let store = makeStore(state, activity: activity, clock: clock)

    await store.send(.home(.setSessionRunning(id: "s1", running: false))) {
      $0.home?.sessions[id: "s1"]?.isActive = false
      $0.home?.statusSessions?[id: "s1"]?.isActive = false
    }
    await clock.advance(by: .milliseconds(500))
    await store.send(.home(.setSessionRunning(id: "s1", running: true))) {
      $0.home?.sessions[id: "s1"]?.isActive = true
      $0.home?.statusSessions?[id: "s1"]?.isActive = true
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.liveActivitySyncDue)
    await store.finish()
    #expect(activity.calls.value.isEmpty)
  }

  /// `Activity.request` is foreground-only: an agent going active while backgrounded starts
  /// nothing (the foreground edge starts it).
  @Test func noStartWhileBackgrounded() async {
    let activity = ActivityRecorder()
    let clock = TestClock()
    var state = AppFeature.State(home: fetchedHome([session("s1")]))
    state.isSceneBackgrounded = true
    state.backgroundFreshUntil = now.addingTimeInterval(10)
    let store = makeStore(state, activity: activity, clock: clock)

    await store.send(.home(.setSessionRunning(id: "s1", running: true))) {
      $0.home?.sessions[id: "s1"]?.isActive = true
      $0.home?.statusSessions?[id: "s1"]?.isActive = true
    }
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(activity.calls.value.isEmpty)
  }

  /// The Settings toggle off, or Live Activities disabled for the app in iOS Settings: no start.
  @Test func noStartWhenDisabled() async {
    for (prefOn, iOSOn) in [(false, true), (true, false)] {
      let activity = ActivityRecorder(enabled: iOSOn)
      let clock = TestClock()
      var state = AppFeature.State(home: fetchedHome([session("s1")]))
      state.liveActivityEnabled = prefOn
      let store = makeStore(state, activity: activity, clock: clock)

      await store.send(.home(.setSessionRunning(id: "s1", running: true))) {
        $0.home?.sessions[id: "s1"]?.isActive = true
        $0.home?.statusSessions?[id: "s1"]?.isActive = true
      }
      await clock.advance(by: .seconds(1))
      await store.finish()
      #expect(activity.calls.value.isEmpty, "pref \(prefOn), iOS \(iOSOn)")
    }
  }

  /// iOS refusing the start is only debug-logged (no banner) and frees the seat, so the next
  /// change tries again.
  @Test func aStartFailureIsOnlyLoggedAndFreesTheSeat() async {
    let activity = ActivityRecorder(startFails: true)
    let notes = LockIsolated<[String]>([])
    let clock = TestClock()
    let store = TestStore(
      initialState: AppFeature.State(home: fetchedHome([session("s1"), session("s2")]))
    ) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = MirrorRecorder().client
      $0.liveActivity = activity.client
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.debugLog.note = { @Sendable type, _ in notes.withValue { $0.append(type) } }
    }

    await store.send(.home(.setSessionRunning(id: "s1", running: true))) {
      $0.home?.sessions[id: "s1"]?.isActive = true
      $0.home?.statusSessions?[id: "s1"]?.isActive = true
      $0.liveActivityRequests = 1
      $0.liveActivity = self.seat(nil, self.working(["s1"]))
    }
    await store.receive(\.liveActivityStartFailed) {
      $0.liveActivity = nil
    }
    // The next change starts again.
    await store.send(.home(.setSessionRunning(id: "s2", running: true))) {
      $0.home?.sessions[id: "s2"]?.isActive = true
      $0.home?.statusSessions?[id: "s2"]?.isActive = true
      $0.liveActivityRequests = 2
      $0.liveActivity = self.seat(nil, self.working(["s1", "s2"]), request: 2)
    }
    await store.receive(\.liveActivityStartFailed) {
      $0.liveActivity = nil
    }
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(notes.value == ["live.activity", "live.activity"])
    let staleDate = now.addingTimeInterval(Self.foreground)
    #expect(activity.calls.value == [
      .endAll, .start(working(["s1"]), staleDate: staleDate),
      .endAll, .start(working(["s1", "s2"]), staleDate: staleDate),
    ])
  }

  /// A change while the start is in flight is caught up the moment the id lands.
  @Test func aChangeDuringTheStartIsCaughtUpWhenItLands() async {
    let activity = ActivityRecorder()
    let clock = TestClock()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true), session("s2")]))
    state.liveActivity = seat(nil, working(["s1"]))
    let store = makeStore(state, activity: activity, clock: clock)

    await store.send(.home(.setSessionRunning(id: "s2", running: true))) {
      $0.home?.sessions[id: "s2"]?.isActive = true
      $0.home?.statusSessions?[id: "s2"]?.isActive = true
    }
    await store.send(.liveActivityStarted(id: "a1", request: 1)) {
      $0.liveActivity = self.seat("a1", self.working(["s1", "s2"]))
    }
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(activity.calls.value == [
      .update("a1", working(["s1", "s2"]), staleDate: now.addingTimeInterval(Self.foreground)),
    ])
  }

  /// The plan's main scenario: send a prompt and background at once. The background edge can't
  /// restamp a seat whose start is still in flight, so the landing start does — otherwise the
  /// activity would vouch "Working" for the foreground freshness.
  @Test func aStartLandingWhileBackgroundedIsRestamped() async {
    let activity = ActivityRecorder()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.liveActivity = seat(nil, working(["s1"]))
    let store = makeStore(state, activity: activity)

    await store.send(.scenePhaseChanged(.background)) {
      $0.isSceneBackgrounded = true
      $0.backgroundFreshUntil = self.now.addingTimeInterval(10)
    }
    #expect(activity.calls.value.isEmpty)
    await store.send(.liveActivityStarted(id: "a1", request: 1)) {
      $0.liveActivity?.id = "a1"
    }
    await store.finish()
    #expect(activity.calls.value == [
      .update("a1", working(["s1"]), staleDate: now.addingTimeInterval(10)),
    ])
  }

  /// A start that lands after its seat was dropped (toggle off, logout) is an orphan: ended at
  /// once.
  @Test func anOrphanedStartIsEndedAtOnce() async {
    let activity = ActivityRecorder()
    let store = makeStore(
      AppFeature.State(home: fetchedHome([session("s1", active: true)])), activity: activity
    )

    await store.send(.liveActivityStarted(id: "a9", request: 1))
    await store.finish()
    #expect(activity.calls.value == [.end("a9", nil, dismissAfter: nil)])
  }

  /// A fast toggle off→on: the first request's result can land while the second request's seat
  /// waits. It is matched by request, not arrival order — ended, never adopted — and its
  /// failure can't free the live request's seat.
  @Test func aStaleRequestNeverTakesTheWaitingSeat() async {
    let activity = ActivityRecorder()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.liveActivityRequests = 2
    state.liveActivity = seat(nil, working(["s1"]), request: 2)
    let store = makeStore(state, activity: activity)

    await store.send(.liveActivityStarted(id: "a-old", request: 1))
    await store.send(.liveActivityStartFailed(request: 1))
    await store.send(.liveActivityStarted(id: "a-new", request: 2)) {
      $0.liveActivity?.id = "a-new"
    }
    await store.finish()
    #expect(activity.calls.value == [.end("a-old", nil, dismissAfter: nil)])
  }

  /// The background edge moves the activity's stale date to the mirror's promise, so the
  /// Lock Screen shows "Outdated" once the app can no longer observe.
  @Test func backgroundRestampsTheStaleDate() async {
    let activity = ActivityRecorder()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.liveActivity = seat("a1", working(["s1"]))
    let store = makeStore(state, activity: activity)

    await store.send(.scenePhaseChanged(.background)) {
      $0.isSceneBackgrounded = true
      $0.backgroundFreshUntil = self.now.addingTimeInterval(10)
    }
    await store.finish()
    #expect(activity.calls.value == [
      .update("a1", working(["s1"]), staleDate: now.addingTimeInterval(10)),
    ])
  }

  /// Foregrounding restores the foreground stale date at once, and starts the activity when
  /// agents went active while the app couldn't.
  @Test func foregroundRestampsAndStartsAMissedActivity() async {
    let sessions = [session("s1", active: true)]
    for hasActivity in [true, false] {
      let activity = ActivityRecorder()
      var state = AppFeature.State(home: fetchedHome(sessions))
      state.isSceneBackgrounded = true
      state.backgroundFreshUntil = now.addingTimeInterval(10)
      if hasActivity { state.liveActivity = seat("a1", working(["s1"])) }
      let store = TestStore(initialState: state) {
        AppFeature()
      } withDependencies: {
        $0.widgetMirror = MirrorRecorder().client
        $0.liveActivity = activity.client
        $0.continuousClock = TestClock()
        $0.date = .constant(now)
        $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in sessions }
        $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
        $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      }
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(.scenePhaseChanged(.active))
      await store.skipReceivedActions()
      await store.finish()
      let staleDate = now.addingTimeInterval(Self.foreground)
      #expect(activity.calls.value == (
        hasActivity
          ? [.update("a1", working(["s1"]), staleDate: staleDate)]
          : [.endAll, .start(working(["s1"]), staleDate: staleDate)]
      ))
      #expect(store.state.liveActivityID == (hasActivity ? "a1" : "activity-1"))
    }
  }

  /// An activity the user swiped away (or iOS ended at its time limit) while backgrounded is
  /// gone: foregrounding drops its seat and starts a fresh one, instead of updating a dead id
  /// for the rest of the run.
  @Test func foregroundReplacesAnActivityThatIsGone() async {
    let sessions = [session("s1", active: true)]
    let activity = ActivityRecorder(gone: ["a1"])
    var state = AppFeature.State(home: fetchedHome(sessions))
    state.isSceneBackgrounded = true
    state.backgroundFreshUntil = now.addingTimeInterval(10)
    state.liveActivity = seat("a1", working(["s1"]))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = MirrorRecorder().client
      $0.liveActivity = activity.client
      $0.continuousClock = TestClock()
      $0.date = .constant(now)
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in sessions }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active))
    await store.skipReceivedActions()
    await store.finish()
    #expect(activity.calls.value == [
      .endAll, .start(working(["s1"]), staleDate: now.addingTimeInterval(Self.foreground)),
    ])
    #expect(store.state.liveActivityID == "activity-1")
  }

  /// A brief `.active` that never left the foreground (Control Center, the notification shade)
  /// has nothing to restamp: no mirror write, no activity update.
  @Test func aBriefActiveRestampsNothing() async {
    let sessions = [session("s1", active: true)]
    let mirror = MirrorRecorder()
    let activity = ActivityRecorder()
    var state = AppFeature.State(home: fetchedHome(sessions))
    state.liveActivity = seat("a1", working(["s1"]))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.liveActivity = activity.client
      $0.continuousClock = TestClock()
      $0.date = .constant(now)
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in sessions }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scenePhaseChanged(.active))
    await store.skipReceivedActions()
    await store.finish()
    #expect(mirror.writes.value.isEmpty)
    #expect(activity.calls.value.isEmpty)
  }

  /// A profile switch resets the list's rows, so the projection goes unknown under a live
  /// activity and a vouched mirror. They keep their content but stop vouching for it (the
  /// suspension margin): the refetch may fail offline, or the user may background first —
  /// the background edge then has nothing to stamp, and the old profile must not read fresh
  /// for hours.
  @Test func aProfileSwitchStopsVouchingForTheOldRows() async {
    let mirror = MirrorRecorder()
    let activity = ActivityRecorder()
    var home = fetchedHome([session("s1", active: true)])
    home.profilesSupported = true
    home.selectedProfileName = "default"
    var state = AppFeature.State(home: home)
    state.liveActivity = seat("a1", working(["s1"]))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.liveActivity = activity.client
      $0.continuousClock = TestClock()
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      // The scoped refetch fails: the user is offline.
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _, _ in throw RESTError.offline }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.offline }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.selectProfile(name: "work")))
    #expect(store.state.agentStatus == nil)
    await store.send(.scenePhaseChanged(.background))
    await store.finish()
    let oldRow = WidgetSessionRow(
      id: "s1", title: "Title s1", status: .working, updatedAt: updatedAt, profile: "default"
    )
    #expect(mirror.writes.value == [snapshot(freshFor: 10, [oldRow])])
    #expect(activity.calls.value == [
      .update("a1", working(["s1"]), staleDate: now.addingTimeInterval(10)),
    ])
  }

  /// …and once the switched profile's rows land the surfaces vouch again: the activity is
  /// restamped with the foreground freshness even when its content didn't change.
  @Test func theRefetchAfterAProfileSwitchVouchesAgain() async {
    let activity = ActivityRecorder()
    let clock = TestClock()
    var home = fetchedHome([session("s1", active: true)])
    home.profilesSupported = true
    home.selectedProfileName = "default"
    var state = AppFeature.State(home: home)
    // Already showing what the "work" profile's rows will project.
    var content = working(["s1"])
    content.headlineProfile = "work"
    state.liveActivity = seat("a1", content)
    let rows = [session("s1", active: true)]
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = MirrorRecorder().client
      $0.liveActivity = activity.client
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _, _ in rows }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.selectProfile(name: "work")))
    await store.receive(\.home.sessionsResponse)
    #expect(store.state.agentStatus != nil)
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(activity.calls.value == [
      .update("a1", content, staleDate: now.addingTimeInterval(10)),
      .update("a1", content, staleDate: now.addingTimeInterval(Self.foreground)),
    ])
  }

  /// The first fetch landing while backgrounded (nothing to stamp at the background edge)
  /// still writes the short promise, never the foreground freshness.
  @Test func aFirstFetchWhileBackgroundedWritesTheMargin() async {
    let mirror = MirrorRecorder()
    let clock = TestClock()
    var state = AppFeature.State(home: SessionListFeature.State(connection: connection))
    state.isSceneBackgrounded = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.widgetMirror = mirror.client
      $0.continuousClock = clock
      $0.date = .constant(now)
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.sessionsResponse(.success([session("s1", active: true)]))))
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(mirror.writes.value == [snapshot(freshFor: 10, [row("s1", .working)])])
  }

  /// The toggle off ends every activity at once and drops the seat; back on, it starts again.
  @Test func theToggleOffEndsAndOnRestarts() async {
    let activity = ActivityRecorder()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.liveActivity = seat("a1", working(["s1"]))
    let store = makeStore(state, activity: activity)

    await store.send(.home(.delegate(.liveActivityToggled(false)))) {
      $0.liveActivityEnabled = false
      $0.liveActivity = nil
    }
    await store.send(.home(.delegate(.liveActivityToggled(true)))) {
      $0.liveActivityEnabled = true
      $0.liveActivityRequests = 1
      $0.liveActivity = self.seat(nil, self.working(["s1"]))
    }
    await store.receive(\.liveActivityStarted) {
      $0.liveActivity?.id = "activity-1"
    }
    await store.finish()
    #expect(activity.calls.value == [
      .endAll,
      .endAll,
      .start(working(["s1"]), staleDate: now.addingTimeInterval(Self.foreground)),
    ])
  }

  /// The Settings toggles reach `AppFeature` through the session list's delegate: off ends
  /// the activity, show-titles off drops the title through the edge (the activity is already
  /// gone here, so nothing more is sent).
  @Test func theSettingsTogglesArriveThroughTheListDelegate() async {
    let activity = ActivityRecorder()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.liveActivity = seat("a1", working(["s1"]))
    let clock = TestClock()
    let store = makeStore(state, activity: activity, clock: clock)

    await store.send(.home(.delegate(.liveActivityShowsTitlesToggled(false)))) {
      $0.liveActivityShowsTitles = false
    }
    await store.send(.home(.delegate(.liveActivityToggled(false)))) {
      $0.liveActivityEnabled = false
      $0.liveActivity = nil
    }
    await clock.advance(by: .seconds(1)) // the mirror's debounced write; the update was dropped
    await store.finish()
    #expect(activity.calls.value == [.endAll])
  }

  /// "Show session titles" off omits the headline title from the activity (through the edge).
  @Test func showTitlesOffRemovesTheTitle() async {
    let activity = ActivityRecorder()
    let clock = TestClock()
    var state = AppFeature.State(home: fetchedHome([session("s1", active: true)]))
    state.liveActivity = seat("a1", working(["s1"]))
    let store = makeStore(state, activity: activity, clock: clock)

    await store.send(.home(.delegate(.liveActivityShowsTitlesToggled(false)))) {
      $0.liveActivityShowsTitles = false
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.liveActivitySyncDue) {
      $0.liveActivity?.content = self.working(["s1"], titled: false)
    }
    await store.finish()
    #expect(activity.calls.value == [
      .update(
        "a1", working(["s1"], titled: false), staleDate: now.addingTimeInterval(Self.foreground)
      ),
    ])
  }

  /// Every identity teardown ends every activity, drops the seat and a pending update.
  @Test func everyLogoutEndsTheActivity() async {
    for action in [
      AppFeature.Action.home(.delegate(.disconnect)),
      .connectionFailed(.delegate(.logoutConfirmed)),
      .reauth(.presented(.delegate(.quit))),
      .reauth(.presented(.delegate(.reauthenticated(
        connection: ServerConnection(baseURL: connection.baseURL, token: "other"),
        sameUser: false
      )))),
    ] {
      let label = "\(action)"
      let activity = ActivityRecorder()
      let clock = TestClock()
      var state = AppFeature.State(
        home: fetchedHome([session("s1", active: true), session("s2")]),
        connectionFailed: ConnectionFailedFeature.State(connection: connection, reason: .offline),
        reauth: ReauthFeature.State(serverURL: connection.baseURL, method: .token)
      )
      state.liveActivity = seat("a1", working(["s1"]))
      let store = TestStore(initialState: state) {
        AppFeature()
      } withDependencies: {
        $0.widgetMirror = MirrorRecorder().client
        $0.liveActivity = activity.client
        $0.continuousClock = clock
        $0.date = .constant(now)
        $0.preferences = .inMemory()
        $0.push = PushClient.inMemory().client
      }
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(.home(.setSessionRunning(id: "s2", running: true)))
      await store.send(action)
      #expect(store.state.liveActivity == nil, "\(label) kept the seat")
      await clock.advance(by: .seconds(5))
      await store.finish()
      #expect(activity.calls.value == [.endAll], "\(label)")
    }
  }

  /// Every landing seeds the toggles from the device prefs.
  @Test func landingSeedsTheTogglesFromPreferences() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveLiveActivityEnabled(false)
    preferences.saveLiveActivityShowsTitles(false)
    let store = makeStore(AppFeature.State(), activity: ActivityRecorder(), preferences: preferences)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.onboarding(.delegate(.connected(connection))))
    #expect(store.state.liveActivityEnabled == false)
    #expect(store.state.liveActivityShowsTitles == false)
  }

  /// Every landing ends whatever activity is already on screen: none can be this landing's (a
  /// start needs the list's first fetch), so it is a previous process's leftover — killed in
  /// the background or crashed — that nothing would update or end, and it would otherwise sit
  /// "Outdated" next to the new one.
  @Test func everyLandingEndsAPreviousProcessActivity() async {
    for action in [
      AppFeature.Action.autoConnectSucceeded(connection),
      .connectionFailed(.delegate(.connected(connection))),
      .onboarding(.delegate(.connected(connection))),
    ] {
      let label = "\(action)"
      let activity = ActivityRecorder()
      let store = makeStore(
        AppFeature.State(
          connectionFailed: ConnectionFailedFeature.State(connection: connection, reason: .offline)
        ),
        activity: activity
      )
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(action)
      await store.finish()
      #expect(store.state.home != nil, "\(label) didn't land")
      #expect(activity.calls.value == [.endAll], "\(label)")
    }
  }

  // MARK: The file-backed client

  @Test func fileBackedClientWritesAndClearsTheMirrorAtomically() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("widget-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(AppGroup.snapshotFileName)
    let reloads = LockIsolated(0)
    let client = WidgetMirrorClient.fileBacked(at: file) { reloads.withValue { $0 += 1 } }

    let written = snapshot(freshFor: 60, [row("s1", .needsInput)])
    try client.write(written)
    #expect(WidgetSessionSnapshot.decodeLeniently(try Data(contentsOf: file)) == written)

    try client.clear()
    #expect(WidgetSessionSnapshot.decodeLeniently(try Data(contentsOf: file)) == .signedOut)

    client.reloadTimelines()
    #expect(reloads.value == 1)
  }

  @Test func fileBackedClientWithoutAContainerThrows() {
    let client = WidgetMirrorClient.fileBacked(at: nil) {}
    #expect(throws: WidgetMirrorUnavailable()) { try client.write(.signedOut) }
    #expect(throws: WidgetMirrorUnavailable()) { try client.clear() }
  }
}

/// Records every Live Activity call, in order. `start` returns `activity-<n>` (or throws).
private final class ActivityRecorder: Sendable {
  enum Call: Equatable, Sendable {
    case start(AgentActivityContent, staleDate: Date)
    case update(String, AgentActivityContent, staleDate: Date)
    case end(String, AgentActivityContent?, dismissAfter: Date?)
    case endAll
  }

  let calls = LockIsolated<[Call]>([])
  let enabled: Bool
  let startFails: Bool
  /// Ids the user swiped away / iOS ended (`isActive` reads `false`).
  let gone: Set<String>

  init(enabled: Bool = true, startFails: Bool = false, gone: Set<String> = []) {
    self.enabled = enabled
    self.startFails = startFails
    self.gone = gone
  }

  var client: LiveActivityClient {
    LiveActivityClient(
      areActivitiesEnabled: { [enabled] in enabled },
      start: { [calls, startFails] content, staleDate in
        calls.withValue { $0.append(.start(content, staleDate: staleDate)) }
        if startFails { throw LiveActivitiesUnavailable() }
        return "activity-\(calls.value.count { if case .start = $0 { true } else { false } })"
      },
      update: { [calls] id, content, staleDate in
        calls.withValue { $0.append(.update(id, content, staleDate: staleDate)) }
      },
      end: { [calls] id, final, dismissAfter in
        calls.withValue { $0.append(.end(id, final, dismissAfter: dismissAfter)) }
      },
      endAll: { [calls] in calls.withValue { $0.append(.endAll) } },
      isActive: { [gone] id in !gone.contains(id) }
    )
  }
}

/// Records every mirror call for assertions.
private final class MirrorRecorder: Sendable {
  let writes = LockIsolated<[WidgetSessionSnapshot]>([])
  let clears = LockIsolated(0)
  let reloads = LockIsolated(0)

  var client: WidgetMirrorClient {
    WidgetMirrorClient(
      write: { [writes] snapshot in writes.withValue { $0.append(snapshot) } },
      clear: { [clears] in clears.withValue { $0 += 1 } },
      reloadTimelines: { [reloads] in reloads.withValue { $0 += 1 } }
    )
  }
}
