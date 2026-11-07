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
