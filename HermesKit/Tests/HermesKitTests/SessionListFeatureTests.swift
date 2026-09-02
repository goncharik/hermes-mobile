import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct SessionListFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  private let now = Date(timeIntervalSince1970: 1_749_600_000)

  @Test func loadSuccess() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      // Old agent (no /api/profiles) → falls back to the unscoped session fetch.
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown } // can't tell → don't nag
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        [Session(id: "s1", title: "Hello", preview: "hi")]
      }
    }

    await store.send(.task) {
      $0.now = now
      $0.isLoading = true
    }
    await store.receive(\.setupPush) // probes the plugin hub
    await store.receive(\.pushPluginStatusLoaded) // unknown → no further effects
    await store.receive(\.profilesResponse.failure) // capability probe → not supported
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1", title: "Hello", preview: "hi")]
      $0.seenCounts = ["s1": 0] // seeded so the session isn't shown unread on first sight
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    await store.send(.onDisappear) // cancels the auto-poll loop
  }

  @Test func loadFailureSetsError() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.task) {
      $0.now = now
      $0.isLoading = true
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.failure)
    await store.receive(\.sessionsResponse.failure) {
      $0.isLoading = false
      $0.loadError = RESTError.unreachable.message
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    await store.send(.onDisappear) // cancels the auto-poll loop
  }

  // MARK: Auto-poll (working glow freshness)

  @Test func pollRefreshesAfterIntervalAndStopsOnDisappear() async {
    let clock = TestClock()
    let fetchCount = LockIsolated(0)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = clock
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        fetchCount.withValue { $0 += 1 }
        return [Session(id: "s1", isActive: true)]
      }
    }

    // .task does the initial load and starts the 10s poll loop.
    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.failure)
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1", isActive: true)]
      $0.seenCounts = ["s1": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    #expect(fetchCount.value == 1)

    // Advancing the clock by the interval fires a poll tick → refresh → re-fetch.
    await clock.advance(by: .seconds(10))
    await store.receive(\.pollTick)
    await store.receive(\.pulledToRefresh) {
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
    #expect(fetchCount.value == 2)

    // Disappearing cancels the loop — advancing further triggers no more refreshes.
    await store.send(.onDisappear)
    await clock.advance(by: .seconds(30))
    #expect(fetchCount.value == 2)
  }

  @Test func pollTickIsSkippedWhileSearching() async {
    let fetchCount = LockIsolated(0)
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, searchQuery: "foo")
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        fetchCount.withValue { $0 += 1 }
        return []
      }
      $0.hermesREST.search = { @Sendable _, _ in
        fetchCount.withValue { $0 += 1 }
        return []
      }
    }
    // While a query is active the poll tick is a no-op — no refresh, no fetch of any kind.
    await store.send(.pollTick)
    await store.finish()
    #expect(fetchCount.value == 0)
  }

  @Test func pollResumesAfterSuccessfulArchive() async {
    // The archiving guard is transient: once archiveSucceeded clears it, a pollTick (not
    // searching, archivingIDs empty) DOES refresh — the poll isn't permanently disabled.
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, archivingIDs: ["a"])
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    // While the archive is in flight, the poll skips (guard non-empty).
    await store.send(.pollTick)

    // Success clears the transient guard (and cancels any in-flight fetch).
    await store.send(.archiveSucceeded(id: "a")) {
      $0.archivingIDs = []
    }

    // Now a poll tick refreshes again — the poll was only paused, not killed.
    await store.send(.pollTick)
    await store.receive(\.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
  }

  @Test func searchIsCancelledOnDisappear() async {
    let clock = TestClock()
    let fetchCount = LockIsolated(0)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.hermesREST.search = { @Sendable _, _ in
        fetchCount.withValue { $0 += 1 }
        return []
      }
    }

    // Typing schedules a 300ms-debounced search…
    await store.send(\.binding.searchQuery, "foo") { $0.searchQuery = "foo" }
    // …but disappearing before the debounce fires cancels it.
    await store.send(.onDisappear)
    await clock.advance(by: .milliseconds(300))
    await store.finish()
    #expect(fetchCount.value == 0) // no .sessionsResponse — the debounced search was cancelled
  }

  @Test func searchIsDebouncedAndHitsSearchEndpoint() async {
    let clock = TestClock()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.search = { @Sendable _, query in
        [Session(id: "r1", title: nil, preview: query)]
      }
      $0.continuousClock = clock
    }

    await store.send(\.binding.searchQuery, "foo") { $0.searchQuery = "foo" }
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.sessionsResponse.success) {
      $0.sessions = [Session(id: "r1", title: nil, preview: "foo")]
      $0.seenCounts = ["r1": 0]
    }
  }

  // MARK: Duplicate ids in the server response (#78)

  /// The list AND search endpoints can return the same session id more than once;
  /// `IdentifiedArray(uniqueElements:)` trapped on that in the field. The response must
  /// dedupe by id, keeping the FIRST occurrence (server order), and seed `seenCounts`
  /// from that first occurrence only.
  @Test func sessionsResponseWithDuplicateIDsDedupesKeepingFirst() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    await store.send(.sessionsResponse(.success([
      Session(id: "a", title: "First a", messageCount: 3),
      Session(id: "b", title: "b", messageCount: 1),
      Session(id: "a", title: "Second a", messageCount: 9),
      Session(id: "b", title: "b again"),
    ]))) {
      $0.isLoading = false
      $0.sessions = [
        Session(id: "a", title: "First a", messageCount: 3),
        Session(id: "b", title: "b", messageCount: 1),
      ]
      $0.seenCounts = ["a": 3, "b": 1]
    }
    #expect(store.state.sessions.map(\.id) == ["a", "b"])
  }

  /// A duplicate that is also filtered by the in-flight archive/delete guard stays gone —
  /// the guard filter and the dedupe compose (neither re-admits the removed row).
  @Test func sessionsResponseWithDuplicateIDsRespectsInFlightGuard() async {
    var initial = SessionListFeature.State(
      connection: connection, sessions: [Session(id: "a"), Session(id: "b")]
    )
    initial.deletingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    await store.send(.sessionsResponse(.success([
      Session(id: "a"), Session(id: "b"), Session(id: "a"), Session(id: "b"),
    ]))) {
      $0.isLoading = false
      $0.sessions = [Session(id: "b")]
      $0.seenCounts = ["b": 0]
    }
    #expect(store.state.seenCounts["a"] == nil)
  }

  /// End-to-end through the search path (the crash reports' primary trigger): the search
  /// endpoint answering with a repeated id must land as a deduped list, not a trap.
  @Test func searchResponseWithDuplicateIDsDoesNotTrap() async {
    let clock = TestClock()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.search = { @Sendable _, query in
        [
          Session(id: "r1", title: nil, preview: query),
          Session(id: "r2", title: nil, preview: query),
          Session(id: "r1", title: "dup", preview: query),
        ]
      }
      $0.continuousClock = clock
      $0.preferences = .inMemory()
    }

    await store.send(\.binding.searchQuery, "foo") { $0.searchQuery = "foo" }
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.sessionsResponse.success) {
      $0.sessions = [
        Session(id: "r1", title: nil, preview: "foo"),
        Session(id: "r2", title: nil, preview: "foo"),
      ]
      $0.seenCounts = ["r1": 0, "r2": 0]
    }
  }

  /// Same hardening for profiles: a duplicate `name` in `GET /api/profiles` (both the
  /// initial probe and the post-create refresh) dedupes instead of trapping.
  @Test func profilesResponseWithDuplicateNamesDedupesKeepingFirst() async {
    let prefs = PreferencesClient.inMemory()
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, selectedProfileName: "work")
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }

    let duplicated = [
      Profile(name: "default", isDefault: true),
      Profile(name: "work", model: "first"),
      Profile(name: "work", model: "second"),
    ]
    await store.send(.profilesResponse(.success(duplicated))) {
      $0.profilesSupported = true
      $0.profiles = [Profile(name: "default", isDefault: true), Profile(name: "work", model: "first")]
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }

    await store.send(.profilesRefreshed(duplicated))
    #expect(store.state.profiles.map(\.id) == ["default", "work"])
    #expect(store.state.profiles[id: "work"]?.model == "first")
  }

  @Test func tappingSessionEmitsOpenDelegateAndMarksSeen() async {
    let session = Session(id: "s1", title: "Hello", messageCount: 7)
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [session], seenCounts: ["s1": 3])
    ) {
      SessionListFeature()
    }

    await store.send(.sessionTapped("s1")) {
      $0.seenCounts = ["s1": 7] // opening marks the session read at its current count
    }
    await store.receive(\.delegate.openSession)
  }

  // MARK: Unread + pagination

  @Test func unreadReflectsMessageCountAboveSeen() {
    var state = SessionListFeature.State(
      connection: connection,
      sessions: [
        Session(id: "a", messageCount: 5),  // seen 5 → read
        Session(id: "b", messageCount: 8),  // seen 5 → unread
        Session(id: "c", messageCount: 2),  // no seen entry → not unread (unseeded)
      ],
      seenCounts: ["a": 5, "b": 5]
    )
    #expect(state.unreadSessionIDs == ["b"])
    state.seenCounts["b"] = 8
    #expect(state.unreadSessionIDs.isEmpty)
  }

  // MARK: Pinning

  @Test func pinMovesSessionIntoPinnedSetAndOutOfGroup() async {
    let prefs = PreferencesClient.inMemory()
    let sessions = [
      Session(id: "a", cwd: "/w", startedAt: Date(timeIntervalSince1970: 1)),
      Session(id: "b", cwd: "/w", startedAt: Date(timeIntervalSince1970: 2)),
    ]
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: IdentifiedArray(uniqueElements: sessions))
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    #expect(store.state.pinnedSessions.isEmpty)
    #expect(store.state.groups[0].sessions.map(\.id) == ["a", "b"])

    await store.send(.pinSession(id: "a")) {
      $0.pinnedIDs = ["a"]
    }
    #expect(store.state.pinnedSessions.map(\.id) == ["a"])
    #expect(store.state.groups[0].sessions.map(\.id) == ["b"]) // pinned dropped from group
    #expect(prefs.loadPinnedIDs() == ["a"]) // persisted
  }

  @Test func unpinRestoresSessionToGroup() async {
    let prefs = PreferencesClient.inMemory()
    let sessions = [
      Session(id: "a", cwd: "/w", startedAt: Date(timeIntervalSince1970: 1)),
      Session(id: "b", cwd: "/w", startedAt: Date(timeIntervalSince1970: 2)),
    ]
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: IdentifiedArray(uniqueElements: sessions),
        pinnedIDs: ["a"]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    #expect(store.state.pinnedSessions.map(\.id) == ["a"])

    await store.send(.unpinSession(id: "a")) {
      $0.pinnedIDs = []
    }
    #expect(store.state.pinnedSessions.isEmpty)
    #expect(store.state.groups[0].sessions.map(\.id) == ["a", "b"]) // restored to group
    #expect(prefs.loadPinnedIDs() == []) // persisted
  }

  @Test func pinnedSessionsFollowPinInsertionOrder() async {
    let prefs = PreferencesClient.inMemory()
    // `sessions` array order is a, b — but pinning b first then a should yield [b, a].
    let sessions = [Session(id: "a"), Session(id: "b")]
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: IdentifiedArray(uniqueElements: sessions))
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    await store.send(.pinSession(id: "b")) { $0.pinnedIDs = ["b"] }
    await store.send(.pinSession(id: "a")) { $0.pinnedIDs = ["b", "a"] }
    // Pin order, not session-array order.
    #expect(store.state.pinnedSessions.map(\.id) == ["b", "a"])
  }

  @Test func stalePinnedIDIsIgnored() {
    let state = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "a")],
      pinnedIDs: ["a", "ghost"] // "ghost" no longer exists
    )
    #expect(state.pinnedSessions.map(\.id) == ["a"]) // stale id dropped
  }

  // MARK: Copy session ID (transient toast)

  // The reducer copies the tapped id verbatim — it deliberately does NOT look the session
  // up in `state.sessions`, because the id always comes from a row rendered from that
  // array. No fixture is seeded here, so the test can't pretend otherwise.
  @Test func copyIDPutsSessionIDOnPasteboardAndAutoDismissesToast() async {
    let copied = LockIsolated<String?>(nil)
    let clock = TestClock()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
      $0.continuousClock = clock
    }

    await store.send(.copyIDButtonTapped(id: "s1")) { $0.copiedIDToastToken = 1 }

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copiedIDToastExpired) { $0.copiedIDToastToken = nil }
    // Asserted after the effects have been drained — `send` alone doesn't guarantee the
    // merged copy effect has run.
    #expect(copied.value == "s1")
  }

  @Test func recopyingWhileToastVisibleRestartsTheDwellTimer() async {
    let copied = LockIsolated<[String]>([])
    let clock = TestClock()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.withValue { $0.append(text) } }
      $0.continuousClock = clock
    }

    await store.send(.copyIDButtonTapped(id: "a")) { $0.copiedIDToastToken = 1 }
    await clock.advance(by: .seconds(1)) // first dwell is 2/3 elapsed…
    // …a second copy cancels it (cancelInFlight) so the toast does NOT dismiss early. The
    // token bumps even though the toast never hid — that bump is what the view turns into
    // a second VoiceOver announcement.
    await store.send(.copyIDButtonTapped(id: "b")) { $0.copiedIDToastToken = 2 }
    await clock.advance(by: .seconds(1)) // past the first timer's deadline — still visible
    #expect(store.state.copiedIDToastToken == 2)

    await clock.advance(by: .seconds(0.5)) // completes the restarted dwell
    await store.receive(\.copiedIDToastExpired) { $0.copiedIDToastToken = nil }
    #expect(copied.value == ["a", "b"])
  }

  // MARK: Cron partition

  @Test func cronSessionsAreRecencyOrderedAndExcludedFromInteractiveSections() {
    let sessions = [
      Session(id: "i1", updatedAt: Date(timeIntervalSince1970: 10), cwd: "/w", startedAt: Date(timeIntervalSince1970: 1)),
      Session(id: "c1", updatedAt: Date(timeIntervalSince1970: 5), source: "cron"),
      Session(id: "i2", updatedAt: Date(timeIntervalSince1970: 20), cwd: "/w", startedAt: Date(timeIntervalSince1970: 2)),
      Session(id: "c2", updatedAt: Date(timeIntervalSince1970: 50), source: "cron"),
      Session(id: "c3", updatedAt: nil, source: "cron"), // nil date sorts last
    ]
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions)
    )

    // Cron rows only, recency-ordered (c2 > c1 > c3 with nil last).
    #expect(state.cronSessions.map(\.id) == ["c2", "c1", "c3"])
    // Interactive sections see only non-cron rows.
    #expect(state.interactiveSessions.map(\.id) == ["i1", "i2"])
    #expect(state.chronologicalSessions.map(\.id) == ["i2", "i1"]) // updatedAt desc
    let groupedIDs = state.groups.flatMap { $0.sessions.map(\.id) }
    #expect(groupedIDs.sorted() == ["i1", "i2"])
    #expect(groupedIDs.contains(where: { $0.hasPrefix("c") }) == false)
  }

  @Test func pinnedCronSessionSurfacesOnlyUnderCronJobs() {
    let sessions = [
      Session(id: "c1", updatedAt: Date(timeIntervalSince1970: 5), source: "cron"),
      Session(id: "i1", cwd: "/w", startedAt: Date(timeIntervalSince1970: 1)),
    ]
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions),
      pinnedIDs: ["c1"] // pinned, but also cron
    )

    #expect(state.cronSessions.map(\.id) == ["c1"]) // appears under Cron Jobs
    #expect(state.pinnedSessions.isEmpty) // NOT in pinned
    #expect(state.chronologicalSessions.map(\.id) == ["i1"]) // not in interactive list either
  }

  @Test func noCronSessionsLeavesInteractiveListUnchanged() {
    let sessions = [
      Session(id: "a", updatedAt: Date(timeIntervalSince1970: 10), cwd: "/w", startedAt: Date(timeIntervalSince1970: 1)),
      Session(id: "b", updatedAt: Date(timeIntervalSince1970: 20), cwd: "/w", startedAt: Date(timeIntervalSince1970: 2)),
    ]
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions),
      pinnedIDs: ["a"]
    )

    #expect(state.cronSessions.isEmpty)
    // Interactive computeds behave exactly as before the cron partition.
    #expect(state.interactiveSessions.map(\.id) == ["a", "b"])
    #expect(state.pinnedSessions.map(\.id) == ["a"])
    #expect(state.unpinnedSessions.map(\.id) == ["b"])
    #expect(state.chronologicalSessions.map(\.id) == ["b"])
    #expect(state.groups.flatMap { $0.sessions.map(\.id) } == ["b"])
  }

  // MARK: Branch nesting per lane

  @Test func branchNestsUnderParentInChronologicalLane() {
    let sessions = [
      Session(id: "other", updatedAt: Date(timeIntervalSince1970: 30)),
      Session(id: "parent", updatedAt: Date(timeIntervalSince1970: 10)),
      Session(id: "branch", updatedAt: Date(timeIntervalSince1970: 20), parentSessionID: "parent"),
    ]
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions)
    )

    // Plain chronological order would be other > branch > parent; the entries lane nests
    // the branch under its parent (elbow stem) and sorts the cluster by its freshest
    // member (the branch at 20), still below "other" (30).
    #expect(state.chronologicalEntries.map(\.id) == ["other", "parent", "branch"])
    #expect(state.chronologicalEntries.map(\.branchStem) == [nil, nil, "└─ "])
  }

  @Test func branchNestsUnderParentInWorkspaceGroupLane() throws {
    let sessions = [
      Session(id: "parent", updatedAt: Date(timeIntervalSince1970: 10), cwd: "/w"),
      Session(id: "branch", updatedAt: Date(timeIntervalSince1970: 20), cwd: "/w", parentSessionID: "parent"),
      Session(id: "other", updatedAt: Date(timeIntervalSince1970: 30), cwd: "/w"),
    ]
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions)
    )

    let group = try #require(state.groups.first)
    let entries = state.visibleEntries(in: group)
    #expect(entries.map(\.id) == ["other", "parent", "branch"])
    #expect(entries.map(\.branchStem) == [nil, nil, "└─ "])
  }

  @Test func branchWhoseParentIsCappedOutOfCollapsedGroupDeNests() throws {
    // Six rows in one workspace: the collapsed cap (5) cuts the stale parent, so its
    // (visible) branch de-nests — nesting happens within the RENDERED slice only.
    var sessions = (1...4).map { i in
      Session(id: "s\(i)", updatedAt: Date(timeIntervalSince1970: Double(100 - i)), cwd: "/w")
    }
    sessions.append(
      Session(id: "branch", updatedAt: Date(timeIntervalSince1970: 50), cwd: "/w", parentSessionID: "parent")
    )
    sessions.append(Session(id: "parent", updatedAt: Date(timeIntervalSince1970: 1), cwd: "/w"))
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions)
    )

    let group = try #require(state.groups.first)
    let entries = state.visibleEntries(in: group)
    #expect(entries.count == SessionListFeature.State.collapsedLimit)
    #expect(!entries.map(\.id).contains("parent")) // capped out while collapsed
    #expect(entries.first { $0.id == "branch" }?.branchStem == nil) // de-nested, not hidden
  }

  @Test func pinnedBranchDeNestsInPinnedLane() {
    let sessions = [
      Session(id: "parent", updatedAt: Date(timeIntervalSince1970: 10)),
      Session(id: "branch", updatedAt: Date(timeIntervalSince1970: 20), parentSessionID: "parent"),
    ]
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions),
      pinnedIDs: ["branch"]
    )

    // The pinned slice doesn't contain the parent → the branch renders as a normal row.
    #expect(state.pinnedEntries.map(\.id) == ["branch"])
    #expect(state.pinnedEntries.map(\.branchStem) == [nil])
    // The parent stays in the main lane, unstemmed and without its pinned child.
    #expect(state.chronologicalEntries.map(\.id) == ["parent"])
    #expect(state.chronologicalEntries.map(\.branchStem) == [nil])
  }

  @Test func pinnedLaneKeepsPinOrderAndNestsWithinPinnedSlice() {
    let sessions = [
      Session(id: "a", updatedAt: Date(timeIntervalSince1970: 1)),
      Session(id: "parent", updatedAt: Date(timeIntervalSince1970: 2)),
      Session(id: "branch", updatedAt: Date(timeIntervalSince1970: 30), parentSessionID: "parent"),
    ]
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions),
      pinnedIDs: ["a", "parent", "branch"] // "a" pinned first despite being oldest
    )

    // Both parent and branch are pinned → they nest, but top-level order stays the
    // user's pin order (a recency sort would have lifted the parent cluster above "a").
    #expect(state.pinnedEntries.map(\.id) == ["a", "parent", "branch"])
    #expect(state.pinnedEntries.map(\.branchStem) == [nil, nil, "└─ "])
  }

  @Test func cronRowsStayOutOfBranchNesting() {
    let sessions = [
      Session(id: "parent", updatedAt: Date(timeIntervalSince1970: 10)),
      Session(
        id: "cron_job1_1", updatedAt: Date(timeIntervalSince1970: 20),
        source: "cron", parentSessionID: "parent"
      ),
    ]
    let state = SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: sessions)
    )

    // The cron partition runs FIRST: a cron row never nests into (or lifts) the
    // interactive lanes, and the cron section itself stays flat.
    #expect(state.chronologicalEntries.map(\.id) == ["parent"])
    #expect(state.chronologicalEntries.map(\.branchStem) == [nil])
    #expect(state.cronSessions.map(\.id) == ["cron_job1_1"])
  }

  @Test func searchResultsStayFlatInServerOrder() async {
    let clock = TestClock()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.search = { @Sendable _, _ in
        [
          Session(id: "branch", updatedAt: Date(timeIntervalSince1970: 20), parentSessionID: "parent"),
          Session(id: "other", updatedAt: Date(timeIntervalSince1970: 15)),
          Session(id: "parent", updatedAt: Date(timeIntervalSince1970: 10)),
        ]
      }
      $0.continuousClock = clock
    }

    await store.send(\.binding.searchQuery, "foo") { $0.searchQuery = "foo" }
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.sessionsResponse.success) {
      $0.sessions = [
        Session(id: "branch", updatedAt: Date(timeIntervalSince1970: 20), parentSessionID: "parent"),
        Session(id: "other", updatedAt: Date(timeIntervalSince1970: 15)),
        Session(id: "parent", updatedAt: Date(timeIntervalSince1970: 10)),
      ]
      $0.seenCounts = ["branch": 0, "other": 0, "parent": 0]
    }
    // Search renders `sessions` directly (flat, server relevance order) — a branch in the
    // results is NOT regrouped under its parent.
    #expect(store.state.isSearching)
    #expect(store.state.sessions.map(\.id) == ["branch", "other", "parent"])
  }

  @Test func taskLoadsPinnedIDsFromPreferences() async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePinnedIDs(["s1"])
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [Session(id: "s1")] }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
      $0.pinnedIDs = ["s1"]
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.failure)
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1")]
      $0.seenCounts = ["s1": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    await store.send(.onDisappear) // cancels the auto-poll loop
  }

  @Test func toggleGroupExpansionExpandsThenCollapses() async {
    let sessions = (0..<7).map { Session(id: "s\($0)", cwd: "/w", startedAt: Date(timeIntervalSince1970: Double($0))) }
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: IdentifiedArray(uniqueElements: sessions))
    ) {
      SessionListFeature()
    }
    let group = store.state.groups[0]
    #expect(store.state.visibleSessions(in: group).count == 5) // collapsed

    await store.send(.toggleGroupExpansion(groupID: group.id)) {
      $0.expandedGroups = [group.id]
    }
    #expect(store.state.visibleSessions(in: store.state.groups[0]).count == 7) // expanded

    await store.send(.toggleGroupExpansion(groupID: group.id)) {
      $0.expandedGroups = []
    }
    #expect(store.state.visibleSessions(in: store.state.groups[0]).count == 5) // re-collapsed
  }

  // MARK: Archiving

  @Test func archiveButtonPresentsConfirmationDialog() async {
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [Session(id: "a")])
    ) {
      SessionListFeature()
    }

    await store.send(.archiveButtonTapped(id: "a")) {
      $0.confirmationDialog = ConfirmationDialogState {
        TextState("Archive session?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmArchive(id: "a")) {
          TextState("Archive")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This hides the session from the list. You can restore it from the server.")
      }
    }
  }

  @Test func cancellingDialogKeepsSession() async {
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [Session(id: "a")])
    ) {
      SessionListFeature()
    }

    await store.send(.archiveButtonTapped(id: "a")) {
      $0.confirmationDialog = ConfirmationDialogState {
        TextState("Archive session?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmArchive(id: "a")) {
          TextState("Archive")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This hides the session from the list. You can restore it from the server.")
      }
    }
    // Dismissing (cancel) clears the dialog and leaves the session in place.
    await store.send(.confirmationDialog(.dismiss)) {
      $0.confirmationDialog = nil
    }
    #expect(store.state.sessions.map(\.id) == ["a"])
  }

  @Test func confirmArchiveRemovesSessionOptimisticallyAndCallsRPC() async {
    let prefs = PreferencesClient.inMemory()
    let archived = LockIsolated<[(String, Bool)]>([])
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "a"), Session(id: "b")],
      seenCounts: ["a": 1, "b": 2],
      pinnedIDs: ["a"]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "a")) { TextState("Archive") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesREST.archive = { @Sendable _, id, flag, _ in
        archived.withValue { $0.append((id, flag)) }
      }
    }

    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.pinnedIDs = []
      $0.seenCounts = ["b": 2]
      $0.archivingIDs = ["a"] // in-flight guard while the PATCH runs
    }
    // The parent is told FIRST (it tears the live-chat slot down when it matches).
    await store.receive(\.delegate.sessionArchived)
    // Success clears the transient guard (so the poll resumes) and cancels any stale in-flight
    // fetch — no permanent filter (server now excludes the archived session anyway).
    await store.receive(\.archiveSucceeded) {
      $0.archivingIDs = []
    }
    await store.finish()
    #expect(store.state.archivingIDs.isEmpty)
    #expect(archived.value.count == 1)
    #expect(archived.value.first?.0 == "a")
    #expect(archived.value.first?.1 == true)
    #expect(prefs.loadPinnedIDs() == [])
    #expect(prefs.loadSeenCounts() == ["b": 2]) // archived session's seen baseline persisted-cleared
  }

  @Test func staleLoadAfterArchiveDoesNotResurrectSession() async {
    // A list fetch already in flight when the user archives a session must NOT land
    // afterward and re-add the just-removed row. `confirmArchive` cancels it — and
    // because that leaves `isLoading` stranded, `archiveSucceeded` RESTARTS the fetch:
    // the fresh, post-archive response (without "a") lands and clears the spinner.
    let prefs = PreferencesClient.inMemory()
    let calls = LockIsolated(0)
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "a"), Session(id: "b")]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "a")) { TextState("Archive") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesREST.archive = { @Sendable _, _, _, _ in }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        // First call (in flight at confirm time) parks forever with the STALE list —
        // cancelled, its response must never arrive. Second call (the restart) returns
        // the authoritative post-archive list.
        if calls.withValue({ $0 += 1; return $0 }) == 1 { try await Task.never() }
        return [Session(id: "b")]
      }
    }

    // Kick off a load that parks inside the fetch (the response can't land yet).
    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }

    // Archive "a" — this cancels the in-flight load and optimistically drops the row.
    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.archivingIDs = ["a"]
    }
    // The parent notification precedes the PATCH bookkeeping.
    await store.receive(\.delegate.sessionArchived)
    // Success clears the guard and — with a load still pending — restarts the fetch.
    await store.receive(\.archiveSucceeded) {
      $0.archivingIDs = []
    }
    // Only the RESTARTED fetch's authoritative response arrives; "a" stays archived.
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "b")]
      $0.seenCounts = ["b": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    await store.finish()
    #expect(store.state.sessions.map(\.id) == ["b"])
  }

  @Test func archiveFailureRestoresSessionLocallyAndSetsError() async {
    // On failure the optimistic removal is reversed LOCALLY (no reliance on a reload): the
    // session is re-inserted at its saved index, the guard is lifted, and the error is set.
    // `rest.sessions` throws on reload — proving the row is back purely from the local restore.
    let session = Session(id: "a", title: "Keep me")
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [session, Session(id: "b")]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "a")) { TextState("Archive") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in throw RESTError.unreachable }
      // No reload happens; if one did, it would throw — the row must come back regardless.
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.archivingIDs = ["a"]
    }
    // The parent notification fires regardless of the PATCH outcome (the archive was confirmed).
    await store.receive(\.delegate.sessionArchived)
    // Failure restores the session at its original index (no reload), lifts the guard, sets error.
    await store.receive(\.archiveFailed) {
      $0.sessions = [session, Session(id: "b")]
      $0.archivingIDs = []
      $0.loadError = "Couldn’t archive the session."
    }
    await store.finish()
    #expect(store.state.sessions.map(\.id) == ["a", "b"])
  }

  @Test func archiveFailureRestoresPinAndSeenState() async {
    let prefs = PreferencesClient.inMemory()
    let session = Session(id: "a", title: "Keep me", messageCount: 5)
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [session, Session(id: "b")],
      seenCounts: ["a": 3, "b": 2],
      pinnedIDs: ["a"]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "a")) { TextState("Archive") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.archive = { @Sendable _, _, _, _ in throw RESTError.unreachable }
      // No reload happens; if one did it would throw — restore must be purely local.
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    // Optimistic removal clears pin + seen and persists the cleared prefs.
    await store.send(.confirmationDialog(.presented(.confirmArchive(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.pinnedIDs = []
      $0.seenCounts = ["b": 2]
      $0.archivingIDs = ["a"]
    }
    // The parent notification fires regardless of the PATCH outcome (the archive was confirmed).
    await store.receive(\.delegate.sessionArchived)
    // Failure restores the session + pin + seen baseline LOCALLY (no reload), persists them,
    // lifts the guard, and sets the error.
    await store.receive(\.archiveFailed) {
      $0.sessions = [session, Session(id: "b")]
      $0.pinnedIDs = ["a"]
      $0.seenCounts = ["a": 3, "b": 2]
      $0.archivingIDs = []
      $0.loadError = "Couldn’t archive the session."
    }
    await store.finish()
    // The restored prefs are persisted (not left as the cleared prefs).
    #expect(prefs.loadPinnedIDs() == ["a"])
    #expect(prefs.loadSeenCounts() == ["a": 3, "b": 2])
  }

  @Test func successResponseDuringArchiveIsFilteredButGuardIsTransient() async {
    // A fetch that completes mid-PATCH (its response still carrying the archiving session)
    // must be filtered WHILE the id is in flight. The guard is transient: archiveSucceeded
    // clears it, so a LATER response would include the id again (no permanent filter).
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "b")],
      isLoading: true,
      seenCounts: ["b": 2]
    )
    initial.archivingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    // A stale response landing DURING the in-flight window still includes "a" (and "b"); only
    // "b" survives, and "a" is NOT re-seeded into seenCounts (filtered before the seeding loop).
    await store.send(.sessionsResponse(.success([Session(id: "a"), Session(id: "b")]))) {
      $0.isLoading = false
      $0.sessions = [Session(id: "b")] // "a" filtered out while in flight
    }
    #expect(store.state.seenCounts["a"] == nil)

    // Success clears the transient guard (cancelling any in-flight fetch).
    await store.send(.archiveSucceeded(id: "a")) {
      $0.archivingIDs = []
    }
    #expect(store.state.archivingIDs.isEmpty)

    // With the guard cleared, a LATER authoritative response is no longer filtered — there is
    // no permanent filter (the server is the source of truth for archived state now).
    await store.send(.sessionsResponse(.success([Session(id: "a"), Session(id: "b")]))) {
      $0.sessions = [Session(id: "a"), Session(id: "b")]
      $0.seenCounts = ["a": 0, "b": 2]
    }
    #expect(store.state.sessions.map(\.id) == ["a", "b"])
  }

  // MARK: Deleting (mirrors archive: dialog → optimistic removal + rollback + guard)

  @Test func deleteButtonPresentsConfirmationDialog() async {
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [Session(id: "a")])
    ) {
      SessionListFeature()
    }

    await store.send(.deleteButtonTapped(id: "a")) {
      $0.confirmationDialog = ConfirmationDialogState {
        TextState("Delete session?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmDelete(id: "a")) {
          TextState("Delete")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This permanently deletes the session and its history.")
      }
    }
    // Dismissing (cancel) clears the dialog and leaves the session in place.
    await store.send(.confirmationDialog(.dismiss)) {
      $0.confirmationDialog = nil
    }
    #expect(store.state.sessions.map(\.id) == ["a"])
  }

  @Test func confirmDeleteRemovesSessionOptimisticallyAndCallsRPC() async {
    let prefs = PreferencesClient.inMemory()
    let deleted = LockIsolated<[(String, String?)]>([])
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "a"), Session(id: "b")],
      seenCounts: ["a": 1, "b": 2],
      pinnedIDs: ["a"]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Delete session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDelete(id: "a")) { TextState("Delete") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesREST.deleteSession = { @Sendable _, id, profile in
        deleted.withValue { $0.append((id, profile)) }
      }
    }

    await store.send(.confirmationDialog(.presented(.confirmDelete(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.pinnedIDs = []
      $0.seenCounts = ["b": 2]
      $0.deletingIDs = ["a"] // in-flight guard while the DELETE runs
    }
    // The parent is told FIRST (it tears the live-chat slot down + wipes the cached snapshot).
    await store.receive(\.delegate.sessionDeleted)
    // Success clears the transient guard (so the poll resumes) and cancels any stale fetch.
    await store.receive(\.deleteSucceeded) {
      $0.deletingIDs = []
    }
    // Confirmation delegate — `AppFeature` drops the approval-badge entry on THIS one
    // (not at initiation, so a failed delete keeps badging its still-pending approval).
    await store.receive(\.delegate.sessionDeleteSucceeded)
    await store.finish()
    #expect(store.state.deletingIDs.isEmpty)
    #expect(deleted.value.count == 1)
    #expect(deleted.value.first?.0 == "a")
    #expect(deleted.value.first?.1 == nil) // default profile → no scoping
    #expect(prefs.loadPinnedIDs() == [])
    #expect(prefs.loadSeenCounts() == ["b": 2]) // deleted session's seen baseline persisted-cleared
  }

  @Test func deleteFailureRestoresSessionPinAndSeenStateAndSetsError() async {
    // On failure the optimistic removal is reversed LOCALLY (no reliance on a reload): the
    // session, its pin, and its seen baseline come back; the restored prefs are persisted.
    let prefs = PreferencesClient.inMemory()
    let session = Session(id: "a", title: "Keep me", messageCount: 5)
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [session, Session(id: "b")],
      seenCounts: ["a": 3, "b": 2],
      pinnedIDs: ["a"]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Delete session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDelete(id: "a")) { TextState("Delete") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw RESTError.unreachable }
      // No reload happens; if one did it would throw — restore must be purely local.
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.confirmationDialog(.presented(.confirmDelete(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.pinnedIDs = []
      $0.seenCounts = ["b": 2]
      $0.deletingIDs = ["a"]
    }
    // The parent notification fires regardless of the DELETE outcome (the delete was confirmed).
    await store.receive(\.delegate.sessionDeleted)
    // Failure restores the session + pin + seen baseline LOCALLY, persists them, lifts the
    // guard, sets the banner — and the capability stays ON (a transient failure is no verdict).
    await store.receive(\.deleteFailed) {
      $0.sessions = [session, Session(id: "b")]
      $0.pinnedIDs = ["a"]
      $0.seenCounts = ["a": 3, "b": 2]
      $0.deletingIDs = []
      $0.loadError = "Couldn’t delete the session."
    }
    await store.finish()
    #expect(store.state.deleteSupported)
    #expect(prefs.loadPinnedIDs() == ["a"])
    #expect(prefs.loadSeenCounts() == ["a": 3, "b": 2])
  }

  @Test(arguments: [RESTError.notFound, RESTError.server(status: 405, detail: nil)])
  func deleteOnOlderAgentFlipsCapabilityOffSilently(error: RESTError) async {
    // Older agents lack the DELETE route: a 404 — or a 405, since `/api/sessions/{id}`
    // exists there for PATCH/GET — restores the row and flips `deleteSupported` off with
    // NO banner (mirror the silent capability flips).
    let session = Session(id: "a", title: "Keep me")
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [session, Session(id: "b")]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Delete session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDelete(id: "a")) { TextState("Delete") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw error }
    }

    await store.send(.confirmationDialog(.presented(.confirmDelete(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.deletingIDs = ["a"]
    }
    await store.receive(\.delegate.sessionDeleted)
    await store.receive(\.deleteFailed) {
      $0.sessions = [session, Session(id: "b")]
      $0.deletingIDs = []
      $0.deleteSupported = false // capability off — Delete affordances hide from here on
      // NO loadError — the flip is silent.
    }
    await store.finish()
    #expect(store.state.loadError == nil)
    // With the capability off, a persisted `.delete` swipe pref clamps back to Archive.
    #expect(store.state.effectiveSwipeAction == .archive)
  }

  @Test func successResponseDuringDeleteIsFilteredButGuardIsTransient() async {
    // A fetch that completes mid-DELETE (its response still carrying the deleting session)
    // must be filtered WHILE the id is in flight. The guard is transient: deleteSucceeded
    // clears it, so a LATER response would include the id again (no permanent filter).
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "b")],
      isLoading: true,
      seenCounts: ["b": 2]
    )
    initial.deletingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    // A stale response landing DURING the in-flight window still includes "a" (and "b"); only
    // "b" survives, and "a" is NOT re-seeded into seenCounts (filtered before the seeding loop).
    await store.send(.sessionsResponse(.success([Session(id: "a"), Session(id: "b")]))) {
      $0.isLoading = false
      $0.sessions = [Session(id: "b")] // "a" filtered out while in flight
    }
    #expect(store.state.seenCounts["a"] == nil)

    // Success clears the transient guard (cancelling any in-flight fetch).
    await store.send(.deleteSucceeded(id: "a")) {
      $0.deletingIDs = []
    }
    await store.receive(\.delegate.sessionDeleteSucceeded)

    // With the guard cleared, a LATER authoritative response is no longer filtered — the
    // server is the source of truth (a genuinely deleted session just won't be in it).
    await store.send(.sessionsResponse(.success([Session(id: "b")])))
    #expect(store.state.sessions.map(\.id) == ["b"])
  }

  @Test func pollSkipsWhileDeleteInFlight() async {
    let store = TestStore(
      initialState: {
        var state = SessionListFeature.State(connection: connection)
        state.deletingIDs = ["a"]
        return state
      }()
    ) {
      SessionListFeature()
    }

    // No `.pulledToRefresh` is received — the poll skips while a DELETE is in flight
    // (a reload could resurrect the optimistically-removed row).
    await store.send(.pollTick)
  }

  @Test func deleteAffordancesAreNoOpsWhenUnsupported() async {
    // The view hides Delete when the capability is off, but a context menu rendered
    // before the flag flipped can still fire — the reducer refuses instead of
    // round-tripping a doomed DELETE (mirrors the archived sheet's guard).
    var initial = SessionListFeature.State(
      connection: connection, sessions: [Session(id: "a")]
    )
    initial.deleteSupported = false
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.deleteButtonTapped(id: "a")) // guard: no dialog raised

    // And the confirm itself: the flag can flip (mirrored from the archived sheet) while
    // a dialog is already up — no removal, no request.
    var withDialog = initial
    withDialog.confirmationDialog = ConfirmationDialogState {
      TextState("Delete session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDelete(id: "a")) { TextState("Delete") }
    }
    let confirmStore = TestStore(initialState: withDialog) { SessionListFeature() }
    await confirmStore.send(.confirmationDialog(.presented(.confirmDelete(id: "a")))) {
      $0.confirmationDialog = nil // the presentation machinery still dismisses
    }
    #expect(confirmStore.state.sessions[id: "a"] != nil) // row untouched
  }

  @Test func deleteFailureReinsertClampsWhenListShrankDuringFlight() async {
    // If the list shrank while the DELETE was in flight (a refresh replaced `sessions`
    // wholesale), the saved row/pin indices can exceed the current counts — the rollback
    // must clamp both re-inserts, not crash or land out of bounds.
    var initial = SessionListFeature.State(
      connection: connection, sessions: [Session(id: "a")] // shrank while "c" was deleting
    )
    initial.deletingIDs = ["c"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    await store.send(.deleteFailed(
      id: "c", session: Session(id: "c", title: "Tail"), index: 2, pinIndex: 3,
      seenCount: 7, profileName: nil, searchQuery: "", error: .unreachable
    )) {
      $0.deletingIDs = []
      // Saved index 2 > count 1 → row clamps to the end; pin index 3 > count 0 → front.
      $0.sessions = [Session(id: "a"), Session(id: "c", title: "Tail")]
      $0.pinnedIDs = ["c"]
      $0.seenCounts = ["c": 7]
      $0.loadError = "Couldn’t delete the session."
    }
  }

  @Test func staleLoadAfterDeleteDoesNotResurrectSession() async {
    // A list fetch already in flight (gated behind a continuation) when the user confirms
    // a delete must NOT land afterward and re-add the just-removed row — `confirmDelete`
    // cancels it, and `deleteFailed` (which follows here) deliberately does not restart it.
    let prefs = PreferencesClient.inMemory()
    let gate = AsyncStream.makeStream(of: Void.self)
    var initial = SessionListFeature.State(
      connection: connection,
      sessions: [Session(id: "a"), Session(id: "b")]
    )
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Delete session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDelete(id: "a")) { TextState("Delete") }
    }
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw RESTError.unreachable }
      // The cancelled load still runs its trailing cron fetch (the send is dropped) — stub
      // it so the unimplemented-dependency check doesn't trip; no response is received.
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        // Block until released, then return the OLD list (both sessions) — stale data.
        var iterator = gate.stream.makeAsyncIterator()
        await iterator.next()
        return [Session(id: "a"), Session(id: "b")]
      }
    }

    // Kick off a load that parks inside the fetch (the response can't land yet).
    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }

    // Confirm the delete — this cancels the in-flight load and optimistically drops the row.
    await store.send(.confirmationDialog(.presented(.confirmDelete(id: "a")))) {
      $0.confirmationDialog = nil
      $0.sessions = [Session(id: "b")]
      $0.deletingIDs = ["a"]
    }
    await store.receive(\.delegate.sessionDeleted)
    // The DELETE fails and rolls the row back locally — but the parked fetch stays
    // cancelled: releasing it below must deliver NO `.sessionsResponse`.
    await store.receive(\.deleteFailed) {
      $0.deletingIDs = []
      $0.sessions = [Session(id: "a"), Session(id: "b")]
      $0.loadError = "Couldn’t delete the session."
    }

    gate.continuation.yield()
    gate.continuation.finish()
    await store.finish()
    #expect(store.state.sessions.map(\.id) == ["a", "b"])
  }

  @Test func deleteSuccessRestartsAFetchStartedDuringTheWindow() async {
    // A fetch started DURING the delete window (manual pull-to-refresh — the poll skips,
    // but the user can still pull) is only defended by the `deletingIDs` filter while the
    // guard is up. `deleteSucceeded` lifts the guard, so it must supersede that fetch —
    // its stale response landing afterwards would resurrect the deleted row — but NOT
    // with a bare cancel, which would strand `isLoading` until the next poll. It RESTARTS
    // the fetch: the parked stale one is cancelled and a fresh post-delete response lands.
    let calls = LockIsolated(0)
    var initial = SessionListFeature.State(connection: connection)
    initial.deletingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        // First call (the mid-window refresh) parks forever — stale, its response must
        // never land. Second call (the restart) returns the authoritative list.
        if calls.withValue({ $0 += 1; return $0 }) == 1 { try await Task.never() }
        return [Session(id: "b")]
      }
    }

    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.send(.deleteSucceeded(id: "a")) {
      $0.deletingIDs = []
    }
    await store.receive(\.delegate.sessionDeleteSucceeded)
    // The restarted fetch delivers fresh data — the spinner clears, nothing is stranded.
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "b")]
      $0.seenCounts = ["b": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    await store.finish()
  }

  @Test func deleteSuccessDuringSearchRefreshesTheSearchResults() async {
    // While searching the poll is PAUSED — a bare fetch-cancel on delete success would
    // leave stale search results (and a possibly stuck spinner) on screen indefinitely.
    // Success during an active search re-runs the search instead: authoritative,
    // post-delete results replace the list.
    let searched = LockIsolated<[String]>([])
    var initial = SessionListFeature.State(connection: connection, searchQuery: "plan")
    initial.sessions = [Session(id: "b")]
    initial.deletingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.search = { @Sendable _, query in
        searched.withValue { $0.append(query) }
        return [Session(id: "b")]
      }
    }

    await store.send(.deleteSucceeded(id: "a")) {
      $0.now = self.now
      $0.deletingIDs = []
      $0.isLoading = true // the restarted search fetch is on its way
    }
    await store.receive(\.delegate.sessionDeleteSucceeded)
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.seenCounts = ["b": 0]
    }
    await store.finish()
    #expect(searched.value == ["plan"]) // the ACTIVE query re-ran, not a plain list load
  }

  @Test func deleteFailureAfterProfileSwitchDoesNotReinsertIntoTheNewProfilesList() async {
    // The DELETE was issued under "work"; by the time it fails the user has switched to
    // the default profile. Re-inserting the captured session would put a cross-profile
    // row in the new list — opening it would resume under the wrong scope — so the ROW
    // re-insert is dropped (the old profile's list re-fetches the still-existing row on
    // return). The pin/seen metadata is device-GLOBAL (keyed by session id, not
    // profile-scoped) though, so it IS restored and persisted — the server kept the
    // session, and skipping it would lose the pin/unread baseline for good. The failure
    // itself is still surfaced.
    let prefs = PreferencesClient.inMemory()
    var initial = SessionListFeature.State(connection: connection)
    initial.profilesSupported = true
    initial.selectedProfileName = SessionListFeature.State.defaultProfileName
    initial.sessions = [Session(id: "d1")] // the default profile's list
    initial.deletingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    await store.send(.deleteFailed(
      id: "a", session: Session(id: "a", title: "Work row"), index: 0, pinIndex: 0,
      seenCount: 4, profileName: "work", searchQuery: "", error: .unreachable
    )) {
      $0.deletingIDs = []
      $0.loadError = "Couldn’t delete the session."
      // No row re-insert — but the global pin/seen metadata comes back (and persists).
      $0.pinnedIDs = ["a"]
      $0.seenCounts = ["a": 4]
    }
    #expect(store.state.sessions.map(\.id) == ["d1"])
    #expect(prefs.loadPinnedIDs() == ["a"])
    #expect(prefs.loadSeenCounts() == ["a": 4])
  }

  @Test func deleteVerdictAfterProfileSwitchStillFlipsCapability() async {
    // Same mid-flight profile switch, but the failure is the 404/405 capability verdict:
    // the flag is SERVER-wide, so it still flips (silently) even though the rollback is
    // dropped for the changed context.
    var initial = SessionListFeature.State(connection: connection)
    initial.profilesSupported = true
    initial.sessions = [Session(id: "d1")]
    initial.deletingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    await store.send(.deleteFailed(
      id: "a", session: Session(id: "a"), index: 0, pinIndex: nil,
      seenCount: nil, profileName: "work", searchQuery: "", error: .notFound
    )) {
      $0.deletingIDs = []
      $0.deleteSupported = false // verdict applies; no banner, no re-insert
    }
    #expect(store.state.loadError == nil)
    #expect(store.state.sessions.map(\.id) == ["d1"])
  }

  @Test func archiveFailureAfterProfileSwitchDoesNotReinsertIntoTheNewProfilesList() async {
    // The archive rollback mirrors the delete guard: a PATCH issued under "work" that
    // fails after a switch to the default profile must not re-insert the old profile's
    // row into the new list.
    var initial = SessionListFeature.State(connection: connection)
    initial.profilesSupported = true
    initial.sessions = [Session(id: "d1")]
    initial.archivingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    await store.send(.archiveFailed(
      id: "a", session: Session(id: "a", title: "Work row"), index: 0, pinIndex: nil,
      seenCount: nil, profileName: "work", searchQuery: ""
    )) {
      $0.archivingIDs = []
      $0.loadError = "Couldn’t archive the session."
    }
    #expect(store.state.sessions.map(\.id) == ["d1"])
  }

  @Test func deleteFailureAfterSearchChangeDoesNotReinsertIntoTheNewQuerysResults() async {
    // The DELETE was issued from the "old" query's results; by the time it fails the
    // user is searching "new". The poll is PAUSED while searching, so re-inserting the
    // captured row would park a wrong-query result on screen with nothing to reconcile
    // it — the row re-insert is dropped (same context rule as the profile switch), while
    // the device-global pin/seen metadata is still restored and persisted.
    let prefs = PreferencesClient.inMemory()
    var initial = SessionListFeature.State(connection: connection, searchQuery: "new")
    initial.sessions = [Session(id: "n1")] // the new query's results
    initial.deletingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    await store.send(.deleteFailed(
      id: "a", session: Session(id: "a", title: "Old result"), index: 0, pinIndex: 0,
      seenCount: 4, profileName: nil, searchQuery: "old", error: .unreachable
    )) {
      $0.deletingIDs = []
      $0.loadError = "Couldn’t delete the session."
      $0.pinnedIDs = ["a"]
      $0.seenCounts = ["a": 4]
    }
    #expect(store.state.sessions.map(\.id) == ["n1"])
    #expect(prefs.loadPinnedIDs() == ["a"])
  }

  @Test func archiveFailureAfterSearchChangeDoesNotReinsertIntoTheNewQuerysResults() async {
    // The archive rollback shares the delete's context rule: a PATCH issued from one
    // query's results must not re-insert its row into a different query's results.
    var initial = SessionListFeature.State(connection: connection, searchQuery: "new")
    initial.sessions = [Session(id: "n1")]
    initial.archivingIDs = ["a"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    await store.send(.archiveFailed(
      id: "a", session: Session(id: "a", title: "Old result"), index: 0, pinIndex: nil,
      seenCount: nil, profileName: nil, searchQuery: "old"
    )) {
      $0.archivingIDs = []
      $0.loadError = "Couldn’t archive the session."
    }
    #expect(store.state.sessions.map(\.id) == ["n1"])
  }

  @Test func clearingTheSearchReloadsTheListImmediately() async {
    // Clearing the query must NOT go through the 300ms search debounce: it reloads via
    // `load`, which raises `isLoading` — the flag `cancelOrRestartFetch` keys on. The
    // debounced search effect raises nothing, and with the query already empty
    // `isSearching` is false too, so a mutation success landing in a debounced window
    // would bare-cancel the pending reload and strand the stale search results.
    var initial = SessionListFeature.State(connection: connection, searchQuery: "foo")
    initial.sessions = [Session(id: "stale-result")]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.continuousClock = TestClock() // never advanced — proves there is no debounce
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [Session(id: "fresh")] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
    }

    await store.send(\.binding.searchQuery, "") {
      $0.searchQuery = ""
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "fresh")]
      $0.seenCounts = ["fresh": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
  }

  @Test func archiveSuccessAfterClearingSearchRestartsThePendingReload() async {
    // An archive is in flight from search results and the user clears the search during
    // the RPC window: the pending reload (raised by the cleared binding) is only visible
    // through `isLoading` — `isSearching` is already false. Success must RESTART it, not
    // bare-cancel it: a cancel would leave the old search results on screen until the
    // next poll.
    let calls = LockIsolated(0)
    var initial = SessionListFeature.State(connection: connection, searchQuery: "foo")
    initial.sessions = [Session(id: "stale-result")]
    initial.archivingIDs = ["x"]
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        // The cleared-search reload parks (a pre-archive response that must never
        // land); the restart returns the authoritative post-archive list.
        if calls.withValue({ $0 += 1; return $0 }) == 1 { try await Task.never() }
        return [Session(id: "fresh")]
      }
    }

    await store.send(\.binding.searchQuery, "") {
      $0.searchQuery = ""
      $0.now = self.now
      $0.isLoading = true
    }
    await store.send(.archiveSucceeded(id: "x")) {
      $0.archivingIDs = []
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "fresh")]
      $0.seenCounts = ["fresh": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    await store.finish()
  }

  @Test func effectiveSwipeActionClampsToArchiveWhenDeleteUnsupported() {
    var state = SessionListFeature.State(connection: connection)
    state.defaultSwipeAction = .delete
    #expect(state.effectiveSwipeAction == .delete) // supported → the pref rules

    state.deleteSupported = false
    #expect(state.effectiveSwipeAction == .archive) // unsupported → clamped, pref untouched
    #expect(state.defaultSwipeAction == .delete)
  }

  @Test func loadSeedsDefaultSwipeActionFromPreferences() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveDefaultSessionSwipeAction(.delete)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
      $0.defaultSwipeAction = .delete // seeded from prefs with the other pref reloads
    }
    await store.receive(\.sessionsResponse.success) { $0.isLoading = false }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
  }

  // MARK: Rename (optimistic + rollback, mirroring archive)

  @Test func renameOptimisticallyUpdatesTitleAndCallsRPC() async {
    let renamed = LockIsolated<[(String, String)]>([])
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "a", title: "Old"), Session(id: "b")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.rename = { @Sendable _, id, title, _ in
        renamed.withValue { $0.append((id, title)) }
      }
    }

    // Tapping rename seeds the draft with the row's current title and opens the alert.
    await store.send(.renameButtonTapped(id: "a")) {
      $0.renamingID = "a"
      $0.renameDraft = "Old"
    }

    // Edit the draft (pure binding, no side effect).
    await store.send(\.binding.renameDraft, "New name") {
      $0.renameDraft = "New name"
    }

    // Confirm optimistically updates the title, clears the alert, marks in-flight, and fires the RPC.
    await store.send(.confirmRename) {
      $0.sessions[id: "a"]?.title = "New name"
      $0.renamingID = nil
      $0.renameDraft = ""
      $0.renamingInFlightIDs = ["a"]
    }
    await store.receive(\.renameSucceeded) {
      $0.renamingInFlightIDs = [] // guard lifted, poll resumes
    }
    #expect(renamed.value.count == 1)
    #expect(renamed.value.first?.0 == "a")
    #expect(renamed.value.first?.1 == "New name")
  }

  @Test func pollResumesAfterSuccessfulRename() async {
    // The rename guard is transient: once renameSucceeded clears it, a pollTick (not searching,
    // renamingInFlightIDs empty) DOES refresh — and renameSucceeded cancels any fetch started
    // during the PATCH window so a stale response can't clobber the optimistic title.
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, renamingInFlightIDs: ["a"]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    // While the rename is in flight, the poll skips (guard non-empty).
    await store.send(.pollTick)

    // Success clears the transient guard (and cancels any in-flight fetch).
    await store.send(.renameSucceeded(id: "a")) {
      $0.renamingInFlightIDs = []
    }

    // Now a poll tick refreshes again — the poll was only paused, not killed.
    await store.send(.pollTick)
    await store.receive(\.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
  }

  @Test func renameFailureRestoresPreviousTitleAndSetsError() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "a", title: "Keep me")],
        renamingID: "a",
        renameDraft: "Too long"
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.rename = { @Sendable _, _, _, _ in throw RESTError.server(status: 400) }
    }

    // Optimistic update, then the RPC throws → renameFailed restores the previous title.
    await store.send(.confirmRename) {
      $0.sessions[id: "a"]?.title = "Too long"
      $0.renamingID = nil
      $0.renameDraft = ""
      $0.renamingInFlightIDs = ["a"]
    }
    await store.receive(\.renameFailed) {
      $0.renamingInFlightIDs = [] // guard lifted on failure too
      $0.sessions[id: "a"]?.title = "Keep me"
      $0.loadError = "Couldn’t rename the session."
    }
  }

  @Test func pollTickIsSkippedWhileRenameInFlight() async {
    // While a rename PATCH is in flight a pollTick must not fetch — a fetch landing mid-PATCH
    // would clobber the optimistic title with the server's old one.
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "a", title: "New name")],
        renamingInFlightIDs: ["a"]
      )
    ) {
      SessionListFeature()
    }
    // No .pulledToRefresh / fetch follows — the guard short-circuits the tick.
    await store.send(.pollTick)
  }

  @Test func cancelRenameDismissesAlertWithoutChange() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "a", title: "Old")],
        renamingID: "a",
        renameDraft: "Edited"
      )
    ) {
      SessionListFeature()
    }

    await store.send(.cancelRename) {
      $0.renamingID = nil
      $0.renameDraft = ""
    }
    #expect(store.state.sessions[id: "a"]?.title == "Old")
  }

  @Test func newSessionButtonEmitsCreateDelegate() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    }

    await store.send(.newSessionButtonTapped)
    await store.receive(\.delegate.createSession)
  }

  // MARK: Push onboarding (plugin readiness + info sheet + snooze)

  @Test func setupPushReadyClearsSnoozeAndRequestsAuthorization() async {
    let push = PushClient.inMemory(granted: true)
    let prefs = PreferencesClient.inMemory()
    prefs.savePushPromptSnooze(2, now.addingTimeInterval(86_400)) // a stale snooze to be cleared
    let registered = LockIsolated<String?>(nil)
    var initial = SessionListFeature.State(connection: connection)
    initial.pushAvailable = false
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.push = push.client
      $0.preferences = prefs
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .ready }
      $0.hermesREST.registerPush = { @Sendable _, token, _, _ in registered.setValue(token) }
    }

    await store.send(.setupPush)
    await store.receive(\.pushPluginStatusLoaded) {
      $0.pushAvailable = true // ready → push available
    }
    #expect(prefs.loadPushPromptSnooze() == nil) // snooze cleared on ready
    await store.receive(\.requestPushAuthorization)
    push.emit(token: "deadbeef")
    await store.receive(\.pushTokenReceived)
    await store.receive(\.pushRegistered)
    #expect(registered.value == "deadbeef")
    await store.send(.onDisappear)
  }

  @Test func setupPushNotReadyAndNotSnoozedRaisesSheet() async {
    let prefs = PreferencesClient.inMemory()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .notReady }
    }

    await store.send(.setupPush)
    await store.receive(\.pushPluginStatusLoaded) {
      $0.pushAvailable = false // plugin not enabled → not available
      $0.showPushSetupSheet = true // not snoozed → raise the sheet
    }
  }

  @Test func setupPushNotReadyButSnoozedDoesNotRaiseSheet() async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePushPromptSnooze(1, now.addingTimeInterval(86_400)) // snoozed until tomorrow
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .notReady }
    }

    await store.send(.setupPush)
    await store.receive(\.pushPluginStatusLoaded) {
      $0.pushAvailable = false
      // showPushSetupSheet stays false — still snoozed.
    }
  }

  @Test func setupPushUnknownLeavesCapabilityUnchanged() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.pushAvailable = true // optimistic default
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = .inMemory()
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
    }

    await store.send(.setupPush)
    await store.receive(\.pushPluginStatusLoaded) // unknown → no state change, no sheet
    #expect(store.state.pushAvailable == true)
    #expect(store.state.showPushSetupSheet == false)
  }

  @Test func pushSetupLaterSnoozesOneDayOnFirstTap() async {
    let prefs = PreferencesClient.inMemory()
    var initial = SessionListFeature.State(connection: connection)
    initial.showPushSetupSheet = true
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
    }

    // First "Later" → count 1 → 1 day.
    await store.send(.pushSetupLaterTapped) {
      $0.showPushSetupSheet = false
    }
    let snooze = prefs.loadPushPromptSnooze()
    #expect(snooze?.count == 1)
    #expect(snooze?.until == now.addingTimeInterval(1 * 86_400))
  }

  @Test func pushSetupLaterIncrementsCountAndUsesNextFibonacciInterval() async {
    // A prior snooze already recorded one "Later" — the next bumps to count 2 → 2 days out.
    let prefs = PreferencesClient.inMemory()
    prefs.savePushPromptSnooze(1, now.addingTimeInterval(-1)) // already elapsed
    var initial = SessionListFeature.State(connection: connection)
    initial.showPushSetupSheet = true
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
    }

    await store.send(.pushSetupLaterTapped) {
      $0.showPushSetupSheet = false
    }
    let snooze = prefs.loadPushPromptSnooze()
    #expect(snooze?.count == 2)
    #expect(snooze?.until == now.addingTimeInterval(2 * 86_400))
  }

  @Test func pushSetupAskAgentOpensPrefilledChat() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.showPushSetupSheet = true
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.pushSetupAskAgentTapped) {
      $0.showPushSetupSheet = false
    }
    // The create delegate carries the install prompt (the AppFeature test asserts it reaches
    // the composer); here we only confirm the delegate fires from the "Ask agent" button.
    await store.receive(\.delegate.createSession)
  }

  @Test func settingsInstallPushPluginOpensPrefilledChat() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.settings = SettingsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.settings(.presented(.delegate(.installPushPlugin)))) {
      $0.settings = nil
    }
    await store.receive(\.delegate.createSession)
  }

  // MARK: Settings presentation (Task 12)

  @Test func settingsButtonPresentsSettings() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    }

    await store.send(.settingsButtonTapped) {
      $0.settings = SettingsFeature.State(connection: self.connection)
    }
  }

  @Test func settingsPresentationThreadsPushAvailability() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.pushAvailable = false // a 404 earlier flipped push off
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.settingsButtonTapped) {
      $0.settings = SettingsFeature.State(connection: self.connection, pushAvailable: false)
    }
  }

  @Test func settingsPresentationThreadsSwipeActionAndDeleteSupport() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.defaultSwipeAction = .delete
    initial.deleteSupported = false // an earlier 404/405 flipped delete off
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.settingsButtonTapped) {
      $0.settings = SettingsFeature.State(
        connection: self.connection, defaultSwipeAction: .delete, deleteSupported: false
      )
    }
  }

  @Test func settingsSwipeActionDelegateUpdatesTheList() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.settings = SettingsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) { SessionListFeature() }

    // Settings already persisted the pref; the list mirrors it in-memory immediately.
    await store.send(.settings(.presented(.delegate(.defaultSwipeActionChanged(.delete))))) {
      $0.defaultSwipeAction = .delete
    }
  }

  // MARK: Push registration (Task C4)

  @Test func requestAuthorizationRegistersWhenAuthorized() async {
    let push = PushClient.inMemory(granted: true)
    let registered = LockIsolated<(token: String, env: String, version: String)?>(nil)
    // Start with push "unavailable" so a successful registration visibly flips the flag on.
    var initial = SessionListFeature.State(connection: connection)
    initial.pushAvailable = false
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.push = push.client
      $0.preferences = .inMemory()
      $0.hermesREST.registerPush = { @Sendable _, token, env, version in
        registered.setValue((token, env, version))
      }
    }

    // The ready branch requests authorization; granted → observe tokens.
    await store.send(.requestPushAuthorization)
    // APNs delivers a device token.
    push.emit(token: "deadbeef")
    await store.receive(\.pushTokenReceived)
    await store.receive(\.pushRegistered) {
      $0.pushAvailable = true
    }
    #expect(registered.value?.token == "deadbeef")
    #expect(registered.value?.env == PushClient.apnsEnv)
    #expect(registered.value?.version == "1.2.3") // the in-memory client's app version
    await store.send(.onDisappear) // cancels the token-observe effect
  }

  @Test func requestAuthorizationDoesNothingWhenNotAuthorized() async {
    let push = PushClient.inMemory(granted: false)
    let registered = LockIsolated(false)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.push = push.client
      $0.hermesREST.registerPush = { @Sendable _, _, _, _ in
        registered.setValue(true)
      }
    }

    // Denied → the token stream is never observed, so no registration happens.
    await store.send(.requestPushAuthorization)
    push.emit(token: "deadbeef") // ignored — no consumer
    await store.finish()
    #expect(registered.value == false)
    #expect(store.state.pushAvailable == true) // unchanged (no definitive 404)
  }

  @Test func tokenRotationReRegisters() async {
    let push = PushClient.inMemory(granted: true)
    let tokens = LockIsolated<[String]>([])
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.push = push.client
      $0.preferences = .inMemory()
      $0.hermesREST.registerPush = { @Sendable _, token, _, _ in
        tokens.withValue { $0.append(token) }
      }
    }

    await store.send(.requestPushAuthorization)
    push.emit(token: "tok1")
    await store.receive(\.pushTokenReceived)
    await store.receive(\.pushRegistered)
    // The OS rotates the token — a second emission re-registers.
    push.emit(token: "tok2")
    await store.receive(\.pushTokenReceived)
    await store.receive(\.pushRegistered)
    #expect(tokens.value == ["tok1", "tok2"])
    await store.send(.onDisappear)
  }

  @Test func registerPush404DisablesPushCapability() async {
    let push = PushClient.inMemory(granted: true)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.push = push.client
      $0.preferences = .inMemory()
      $0.hermesREST.registerPush = { @Sendable _, _, _, _ in throw RESTError.notFound }
    }

    await store.send(.requestPushAuthorization)
    push.emit(token: "deadbeef")
    await store.receive(\.pushTokenReceived)
    await store.receive(\.pushRegisterFailed) {
      $0.pushAvailable = false // plugin absent → capability-gated off
    }
    await store.send(.onDisappear)
  }

  @Test func settingsDisconnectDismissesAndBubblesUp() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.settings = SettingsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.settings(.presented(.delegate(.disconnect)))) {
      $0.settings = nil
    }
    await store.receive(\.delegate.disconnect)
  }

  @Test func settingsReconnectTriggersReload() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.settings = SettingsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [Session(id: "s1")] }
    }

    await store.send(.settings(.presented(.delegate(.reconnect))))
    await store.receive(\.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1")]
      $0.seenCounts = ["s1": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
  }

  @Test func settingsTokenSavedUpdatesConnection() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.settings = SettingsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.settings(.presented(.delegate(.tokenSaved("newtok"))))) {
      $0.connection.token = "newtok"
    }
  }

  // MARK: - Grouping mode

  @Test func setGroupingModeUpdatesStateAndPersists() async {
    let prefs = PreferencesClient.inMemory()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    #expect(store.state.groupingMode == .workspace) // default
    await store.send(.setGroupingMode(.chronological)) {
      $0.groupingMode = .chronological
    }
    #expect(prefs.loadGroupingMode() == .chronological) // persisted

    // Re-sending the same mode is a no-op (no state change).
    await store.send(.setGroupingMode(.chronological))
  }

  @Test func loadSeedsGroupingModeFromPreferences() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveGroupingMode(.chronological)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
      $0.groupingMode = .chronological // seeded from prefs on load
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.failure)
    await store.receive(\.sessionsResponse.success) { $0.isLoading = false }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    await store.send(.onDisappear)
  }

  // MARK: - Cron section visibility

  @Test func setShowCronSectionUpdatesStateAndPersists() async {
    let prefs = PreferencesClient.inMemory()
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    #expect(store.state.showCronSection == true) // default: shown
    await store.send(.setShowCronSection(false)) {
      $0.showCronSection = false
    }
    #expect(prefs.loadShowCronSection() == false) // persisted

    // Re-sending the same value is a no-op (no state change).
    await store.send(.setShowCronSection(false))
  }

  @Test func loadSeedsShowCronSectionFromPreferences() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveShowCronSection(false)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
      $0.showCronSection = false // seeded from prefs on load
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.failure)
    await store.receive(\.sessionsResponse.success) { $0.isLoading = false }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    await store.send(.onDisappear)
  }

  @Test func chronologicalSessionsAreRecencyOrderedAndExcludePinned() {
    var state = SessionListFeature.State(connection: connection)
    state.sessions = [
      Session(id: "a", updatedAt: Date(timeIntervalSince1970: 100)),
      Session(id: "b", updatedAt: Date(timeIntervalSince1970: 300)),
      Session(id: "c", updatedAt: Date(timeIntervalSince1970: 200)),
    ]
    state.pinnedIDs = ["b"] // pinned → excluded from the chronological body

    #expect(state.chronologicalSessions.map(\.id) == ["c", "a"]) // recency desc, pinned dropped
  }

  // MARK: - Archived sheet

  @Test func archivedButtonPresentsTheSheet() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    }

    await store.send(.archivedButtonTapped) {
      $0.archivedSheetGeneration = 1 // each presentation is a new correlation generation
      $0.archived = ArchivedSessionsFeature.State(
        connection: self.connection,
        now: Date(timeIntervalSince1970: 0) // the list's default `now`
      )
    }
  }

  @Test func openingFromArchivedDismissesSheetAndForwardsOpen() async {
    let session = Session(id: "a", title: "Old")
    var initial = SessionListFeature.State(connection: connection)
    initial.archived = ArchivedSessionsFeature.State(connection: connection, sessions: [session])
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.archived(.presented(.delegate(.openSession(session))))) {
      $0.archived = nil // sheet dismissed
    }
    await store.receive(\.delegate.openSession) // forwarded to the main stack
  }

  @Test func archivedSheetSeedsDeleteSupportedFromTheList() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.deleteSupported = false // an earlier delete already got the 404/405 verdict
    let store = TestStore(initialState: initial) { SessionListFeature() }

    await store.send(.archivedButtonTapped) {
      $0.archivedSheetGeneration = 1
      $0.archived = ArchivedSessionsFeature.State(
        connection: self.connection,
        now: Date(timeIntervalSince1970: 0),
        deleteSupported: false // seeded — the sheet hides Delete from the start
      )
    }
  }

  @Test func archivedSheetDeleteUnsupportedMirrorsOntoTheList() async {
    var initial = SessionListFeature.State(connection: connection)
    initial.archived = ArchivedSessionsFeature.State(connection: connection)
    let store = TestStore(initialState: initial) { SessionListFeature() }

    // The sheet's delete answered 404/405 → the list's own flag flips too, so its
    // Delete affordances (swipe default, context menu, settings row) hide as well.
    await store.send(.archived(.presented(.delegate(.deleteUnsupported)))) {
      $0.deleteSupported = false
    }
  }

  @Test func archivedSheetDeleteRunsTheRoundTripAtTheListAndReinjectsSuccess() async {
    // The sheet's delegate hands over the DELETE with its rollback payload; the
    // round-trip runs HERE (a presented child's effects die with the sheet, so a
    // sheet-run DELETE would be cancelled by Done/swipe-down mid-flight).
    // `sessionDeleted` is forwarded FIRST (cache wipe + possible slot teardown in
    // `AppFeature`), and the success is re-injected into the still-presented sheet.
    let deleted = LockIsolated<[(String, String?)]>([])
    var initial = SessionListFeature.State(connection: connection)
    var sheet = ArchivedSessionsFeature.State(connection: connection)
    sheet.deletingIDs = ["a"] // the sheet already removed the row and raised its guard
    initial.archived = sheet
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, id, profile in
        deleted.withValue { $0.append((id, profile)) }
      }
    }

    await store.send(.archived(.presented(.delegate(.deleted(
      id: "a", session: Session(id: "a", title: "Old"), index: 0
    )))))
    await store.receive(\.delegate.sessionDeleted)
    await store.receive(\.archivedDeleteSucceeded)
    // Confirmation delegate (badge clear in `AppFeature`) + re-injection into the sheet.
    await store.receive(\.delegate.sessionDeleteSucceeded)
    await store.receive(\.archived.presented.deleteSucceeded) {
      $0.archived?.deletingIDs = []
    }
    #expect(deleted.value.map(\.0) == ["a"])
    #expect(deleted.value.first?.1 == nil) // unscoped sheet → no profile threaded
  }

  @Test func archivedSheetDeleteThreadsTheSheetsProfileScope() async {
    // The round-trip (now parent-run) still scopes the DELETE to the profile the sheet
    // was presented under.
    let profile = LockIsolated<String??>(nil)
    var initial = SessionListFeature.State(connection: connection)
    var sheet = ArchivedSessionsFeature.State(connection: connection, profileName: "work")
    sheet.deletingIDs = ["a"]
    initial.archived = sheet
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, p in profile.setValue(.some(p)) }
    }

    await store.send(.archived(.presented(.delegate(.deleted(
      id: "a", session: Session(id: "a"), index: 0
    )))))
    await store.receive(\.delegate.sessionDeleted)
    await store.receive(\.archivedDeleteSucceeded)
    await store.receive(\.delegate.sessionDeleteSucceeded)
    await store.receive(\.archived.presented.deleteSucceeded) {
      $0.archived?.deletingIDs = []
    }
    #expect(profile.value == .some("work"))
  }

  @Test func archivedSheetDeleteSurvivesSheetDismissal() async {
    // THE reason the round-trip is parent-run: dismissing the sheet (Done / swipe-down)
    // while the DELETE is still in flight must not cancel it — the cache and badge were
    // already updated, so a silently dropped request would leave the session alive on
    // the server with no trace client-side.
    let gate = AsyncStream.makeStream(of: Void.self)
    let deleted = LockIsolated(false)
    var initial = SessionListFeature.State(connection: connection)
    var sheet = ArchivedSessionsFeature.State(connection: connection)
    sheet.deletingIDs = ["a"]
    initial.archived = sheet
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in
        // Parks until released — keeps the DELETE in flight across the dismissal.
        var iterator = gate.stream.makeAsyncIterator()
        await iterator.next()
        deleted.setValue(true)
      }
    }

    await store.send(.archived(.presented(.delegate(.deleted(
      id: "a", session: Session(id: "a"), index: 0
    )))))
    await store.receive(\.delegate.sessionDeleted)
    // Done/swipe-down while the DELETE is parked mid-flight.
    await store.send(.archived(.dismiss)) {
      $0.archived = nil
    }
    // Releasing the request proves it stayed alive past the dismissal.
    gate.continuation.yield()
    gate.continuation.finish()
    await store.receive(\.archivedDeleteSucceeded)
    // The confirmation delegate still fires (badge clear); with the sheet gone there is
    // nothing to re-inject into.
    await store.receive(\.delegate.sessionDeleteSucceeded)
    await store.finish()
    #expect(deleted.value)
  }

  @Test(arguments: [RESTError.notFound, RESTError.server(status: 405, detail: nil)])
  func archivedSheetDeleteVerdictAfterDismissalStillFlipsTheListsCapability(error: RESTError) async {
    // The sheet is gone when the 404/405 verdict lands — the capability is server-wide,
    // so the list's own flag still flips (silently), hiding its Delete affordances.
    let gate = AsyncStream.makeStream(of: Void.self)
    var initial = SessionListFeature.State(connection: connection)
    var sheet = ArchivedSessionsFeature.State(connection: connection)
    sheet.deletingIDs = ["a"]
    initial.archived = sheet
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in
        var iterator = gate.stream.makeAsyncIterator()
        await iterator.next()
        throw error
      }
    }

    await store.send(.archived(.presented(.delegate(.deleted(
      id: "a", session: Session(id: "a"), index: 0
    )))))
    await store.receive(\.delegate.sessionDeleted)
    await store.send(.archived(.dismiss)) {
      $0.archived = nil
    }
    gate.continuation.yield()
    gate.continuation.finish()
    await store.receive(\.archivedDeleteFailed) {
      $0.deleteSupported = false
    }
    await store.finish()
    #expect(store.state.loadError == nil) // the flip is silent
  }

  @Test func archivedSheetDeleteFailureAfterDismissalSurfacesTheListBanner() async {
    // A transient failure landing after the sheet was dismissed must not vanish — the
    // session is still on the server, so the list surfaces the banner instead.
    let gate = AsyncStream.makeStream(of: Void.self)
    var initial = SessionListFeature.State(connection: connection)
    var sheet = ArchivedSessionsFeature.State(connection: connection)
    sheet.deletingIDs = ["a"]
    initial.archived = sheet
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in
        var iterator = gate.stream.makeAsyncIterator()
        await iterator.next()
        throw RESTError.unreachable
      }
    }

    await store.send(.archived(.presented(.delegate(.deleted(
      id: "a", session: Session(id: "a"), index: 0
    )))))
    await store.receive(\.delegate.sessionDeleted)
    await store.send(.archived(.dismiss)) {
      $0.archived = nil
    }
    gate.continuation.yield()
    gate.continuation.finish()
    await store.receive(\.archivedDeleteFailed) {
      $0.loadError = "Couldn’t delete the session."
    }
    await store.finish()
    #expect(store.state.deleteSupported) // a transient failure is no capability verdict
  }

  @Test func archivedSheetDeleteFailureWhilePresentedIsReinjectedIntoTheSheet() async {
    // While the sheet still owns the delete (guard holds the id), the failure routes back
    // into it: rollback + banner happen in the sheet, and the list stays untouched.
    var initial = SessionListFeature.State(connection: connection)
    var sheet = ArchivedSessionsFeature.State(connection: connection)
    sheet.deletingIDs = ["a"]
    initial.archived = sheet
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.archived(.presented(.delegate(.deleted(
      id: "a", session: Session(id: "a", title: "Old"), index: 0
    )))))
    await store.receive(\.delegate.sessionDeleted)
    await store.receive(\.archivedDeleteFailed)
    await store.receive(\.archived.presented.deleteFailed) {
      $0.archived?.deletingIDs = []
      $0.archived?.sessions = [Session(id: "a", title: "Old")]
      $0.archived?.loadError = "Couldn’t delete the session."
    }
    await store.finish()
    #expect(store.state.loadError == nil) // the failure surfaced in the sheet, not the list
  }

  @Test func archivedSheetDeleteOutcomeFromAPreviousPresentationIsNotReinjected() async {
    // Delete "a" in sheet presentation #1, dismiss while the DELETE is slow, reopen
    // (`archivedSheetGeneration` bumps), and delete the still-listed "a" AGAIN. The id
    // alone can no longer correlate outcomes: presentation #1's late FAILURE must not
    // clear presentation #2's own guard and resurrect its row (it lands at the list,
    // like any post-dismissal failure) — and presentation #2's real outcome must still
    // re-inject afterwards.
    var initial = SessionListFeature.State(connection: connection)
    initial.archivedSheetGeneration = 2 // presentation #2 is live
    var sheet = ArchivedSessionsFeature.State(connection: connection)
    sheet.deletingIDs = ["a"] // #2's own in-flight delete of the SAME id
    initial.archived = sheet
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    }

    // Presentation #1's stale failure: applied at the list; the sheet stays untouched.
    await store.send(.archivedDeleteFailed(
      id: "a", session: Session(id: "a", title: "Old"), index: 0, generation: 1,
      error: .unreachable
    )) {
      $0.loadError = "Couldn’t delete the session."
    }
    #expect(store.state.archived?.deletingIDs == ["a"]) // guard intact
    #expect(store.state.archived?.sessions.isEmpty == true) // no resurrected row

    // Presentation #2's real outcome (current generation) still re-injects.
    await store.send(.archivedDeleteSucceeded(id: "a", generation: 2))
    await store.receive(\.delegate.sessionDeleteSucceeded)
    await store.receive(\.archived.presented.deleteSucceeded) {
      $0.archived?.deletingIDs = []
    }
  }

  // MARK: - Profiles (Task 8)

  @Test func taskPopulatesProfilesAndScopedSessions() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveSelectedProfileID("work")
    let scopedFetch = LockIsolated<[String]>([])
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in
        [Profile(name: "default", isDefault: true), Profile(name: "work")]
      }
      $0.hermesProfiles.sessions = { @Sendable _, profile, _, _, _, _ in
        scopedFetch.withValue { $0.append(profile) }
        return [Session(id: "w1", title: "Work")]
      }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
      $0.selectedProfileName = "work" // loaded from the persisted pref
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.success) {
      $0.profilesSupported = true
      $0.profiles = [Profile(name: "default", isDefault: true), Profile(name: "work")]
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "w1", title: "Work")]
      $0.seenCounts = ["w1": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    #expect(scopedFetch.value == ["work"]) // scoped to the active profile
    await store.send(.onDisappear)
  }

  @Test func notFoundFromProfilesListFallsBackToUnscopedFetch() async {
    let unscopedFetch = LockIsolated(0)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        unscopedFetch.withValue { $0 += 1 }
        return [Session(id: "s1")]
      }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.failure) // old agent → selector stays hidden
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1")]
      $0.seenCounts = ["s1": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    #expect(store.state.profilesSupported == false)
    #expect(unscopedFetch.value == 1) // today's /api/sessions, not the scoped endpoint
    await store.send(.onDisappear)
  }

  @Test func selectProfilePersistsResetsAndRefetches() async {
    let prefs = PreferencesClient.inMemory()
    let scopedFetch = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        searchQuery: "stale",
        expandedGroups: ["g1"],
        profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
        selectedProfileName: "default",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.sessions = { @Sendable _, profile, _, _, _, _ in
        scopedFetch.withValue { $0.append(profile) }
        return [Session(id: "w1")]
      }
    }

    await store.send(.selectProfile(name: "work")) {
      $0.selectedProfileName = "work"
      $0.searchQuery = "" // list UI reset on switch
      $0.expandedGroups = []
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "w1")]
      $0.seenCounts = ["w1": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    #expect(prefs.loadSelectedProfileID() == "work") // persisted
    #expect(scopedFetch.value == ["work"]) // refetched scoped to the new profile

    // Re-selecting the same profile is a no-op (no refetch).
    await store.send(.selectProfile(name: "work"))
    #expect(scopedFetch.value == ["work"])
  }

  @Test func createdProfileDelegateRefreshesAndSelects() async {
    let prefs = PreferencesClient.inMemory()
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true)],
        selectedProfileName: "default",
        profilesSupported: true,
        addProfile: AddProfileFeature.State(connection: connection)
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in
        [Profile(name: "default", isDefault: true), Profile(name: "fresh")]
      }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }

    await store.send(.addProfile(.presented(.delegate(.created(name: "fresh"))))) {
      $0.addProfile = nil // sheet dismissed
    }
    // Refresh the profile list (no fetch yet)…
    await store.receive(\.profilesRefreshed) {
      $0.profiles = [Profile(name: "default", isDefault: true), Profile(name: "fresh")]
    }
    // …then switch to the freshly-created profile and fetch its (scoped) sessions.
    await store.receive(\.selectProfile) {
      $0.selectedProfileName = "fresh"
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    #expect(prefs.loadSelectedProfileID() == "fresh")
  }

  @Test func deleteConfirmationDeletesAndReHomesToDefault() async {
    let prefs = PreferencesClient.inMemory()
    let deleted = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
        selectedProfileName: "work",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.delete = { @Sendable _, name in deleted.withValue { $0.append(name) } }
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _ in [] }
    }

    // Tapping delete presents the confirmation dialog.
    await store.send(.deleteProfileButtonTapped(name: "work")) {
      $0.confirmationDialog = ConfirmationDialogState {
        TextState("Delete profile?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmDeleteProfile(name: "work")) {
          TextState("Delete")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This permanently deletes the profile and its sessions on the server.")
      }
    }

    // Confirming deletes on the server.
    await store.send(.confirmationDialog(.presented(.confirmDeleteProfile(name: "work")))) {
      $0.confirmationDialog = nil
    }
    // Success removes the profile and, since it was active, re-homes to default + refetches.
    await store.receive(\.deleteProfileSucceeded) {
      $0.profiles = [Profile(name: "default", isDefault: true)]
      $0.selectedProfileName = "default"
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    #expect(deleted.value == ["work"])
    #expect(prefs.loadSelectedProfileID() == "default")
  }

  @Test func defaultProfileCannotBeRenamedOrDeleted() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true)],
        selectedProfileName: "default",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    }

    // Both actions are guarded in the reducer — no state change, no effects.
    await store.send(.renameProfileButtonTapped(name: "default", newName: "renamed"))
    await store.send(.deleteProfileButtonTapped(name: "default"))
    #expect(store.state.confirmationDialog == nil)
    #expect(store.state.profiles.map(\.name) == ["default"])
  }

  @Test func renameCustomProfileIsOptimisticWithRollback() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveSelectedProfileID("work")
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
        selectedProfileName: "work",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesProfiles.rename = { @Sendable _, _, _ in throw RESTError.server(status: 400) }
    }

    // Optimistic rename updates the profile + the active selection.
    await store.send(.renameProfileButtonTapped(name: "work", newName: "work-renamed")) {
      $0.profiles = [Profile(name: "default", isDefault: true), Profile(name: "work-renamed")]
      $0.selectedProfileName = "work-renamed"
    }

    // The PATCH throws → rollback restores the prior profiles + selection.
    await store.receive(\.renameProfileFailed) {
      $0.profiles = [Profile(name: "default", isDefault: true), Profile(name: "work")]
      $0.selectedProfileName = "work"
      $0.loadError = "Couldn’t rename the profile."
    }
    #expect(prefs.loadSelectedProfileID() == "work")
  }

  // (a) The persisted profile no longer exists on the server → re-home to default and fetch
  // the default's (scoped) sessions unscoped-by-default-name.
  @Test func taskReHomesWhenPersistedProfileMissing() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveSelectedProfileID("gone")
    let scopedFetch = LockIsolated<[String]>([])
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = prefs
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in
        [Profile(name: "default", isDefault: true), Profile(name: "work")]
      }
      $0.hermesProfiles.sessions = { @Sendable _, profile, _, _, _, _ in
        scopedFetch.withValue { $0.append(profile) }
        return [Session(id: "d1")]
      }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
      $0.selectedProfileName = "gone" // loaded from the (now-stale) persisted pref
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.success) {
      $0.profilesSupported = true
      $0.profiles = [Profile(name: "default", isDefault: true), Profile(name: "work")]
      $0.selectedProfileName = "default" // re-homed because "gone" is absent
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "d1")]
      $0.seenCounts = ["d1": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }
    #expect(prefs.loadSelectedProfileID() == "default") // persisted re-home
    #expect(scopedFetch.value == ["default"]) // scoped to default
    await store.send(.onDisappear)
  }

  // (b) Deleting a NON-active profile removes it without touching the selection or refetching.
  @Test func deleteNonActiveProfileLeavesSelectionAndDoesNotRefetch() async {
    let prefs = PreferencesClient.inMemory()
    let deleted = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
        selectedProfileName: "default",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.preferences = prefs
      $0.hermesProfiles.delete = { @Sendable _, name in deleted.withValue { $0.append(name) } }
    }

    await store.send(.deleteProfileButtonTapped(name: "work")) {
      $0.confirmationDialog = ConfirmationDialogState {
        TextState("Delete profile?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmDeleteProfile(name: "work")) {
          TextState("Delete")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This permanently deletes the profile and its sessions on the server.")
      }
    }
    await store.send(.confirmationDialog(.presented(.confirmDeleteProfile(name: "work")))) {
      $0.confirmationDialog = nil
    }
    // Non-active deletion: profile removed, selection untouched, no re-home/refetch.
    await store.receive(\.deleteProfileSucceeded) {
      $0.profiles = [Profile(name: "default", isDefault: true)]
    }
    #expect(deleted.value == ["work"])
    #expect(store.state.selectedProfileName == "default")
  }

  // (c) Delete RPC throws → surface the error and leave the list intact.
  @Test func deleteProfileFailureSetsErrorAndRestoresList() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
        selectedProfileName: "default",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.hermesProfiles.delete = { @Sendable _, _ in throw RESTError.server(status: 500) }
    }

    await store.send(.deleteProfileButtonTapped(name: "work")) {
      $0.confirmationDialog = ConfirmationDialogState {
        TextState("Delete profile?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmDeleteProfile(name: "work")) {
          TextState("Delete")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This permanently deletes the profile and its sessions on the server.")
      }
    }
    await store.send(.confirmationDialog(.presented(.confirmDeleteProfile(name: "work")))) {
      $0.confirmationDialog = nil
    }
    await store.receive(\.deleteProfileFailed) {
      $0.loadError = "Couldn’t delete the profile."
    }
    // The list is untouched — nothing was optimistically removed.
    #expect(store.state.profiles.map(\.name) == ["default", "work"])
  }

  // (d) A real differing rename succeeds: the RPC is called with (name, newName), the
  // optimistic name stands, no rollback.
  @Test func renameCustomProfileSucceeds() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveSelectedProfileID("work")
    let renamed = LockIsolated<[(String, String)]>([])
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
        selectedProfileName: "work",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesProfiles.rename = { @Sendable _, name, newName in
        renamed.withValue { $0.append((name, newName)) }
      }
    }

    await store.send(.renameProfileButtonTapped(name: "work", newName: "work-renamed")) {
      $0.profiles = [Profile(name: "default", isDefault: true), Profile(name: "work-renamed")]
      $0.selectedProfileName = "work-renamed"
    }
    await store.receive(\.renameProfileSucceeded) // optimistic value stands, no rollback
    #expect(renamed.value.count == 1)
    #expect(renamed.value.first?.0 == "work")
    #expect(renamed.value.first?.1 == "work-renamed")
    #expect(prefs.loadSelectedProfileID() == "work-renamed")
  }

  // The rename ALERT flow: open seeds the draft, confirm forwards the entered name.
  @Test func renameProfileAlertOpensAndConfirms() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveSelectedProfileID("work")
    let renamed = LockIsolated<[(String, String)]>([])
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
        selectedProfileName: "work",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesProfiles.rename = { @Sendable _, name, newName in
        renamed.withValue { $0.append((name, newName)) }
      }
    }

    // Opening the alert seeds the draft with the current name.
    await store.send(.renameProfileTapped(name: "work")) {
      $0.renamingProfileName = "work"
      $0.profileRenameDraft = "work"
    }
    // User edits the draft.
    await store.send(.binding(.set(\.profileRenameDraft, "work-2"))) {
      $0.profileRenameDraft = "work-2"
    }
    // Confirm clears the alert and forwards the entered name to the rename action.
    await store.send(.confirmRenameProfile) {
      $0.renamingProfileName = nil
      $0.profileRenameDraft = ""
    }
    await store.receive(\.renameProfileButtonTapped) {
      $0.profiles = [Profile(name: "default", isDefault: true), Profile(name: "work-2")]
      $0.selectedProfileName = "work-2"
    }
    await store.receive(\.renameProfileSucceeded)
    #expect(renamed.value.first?.1 == "work-2")
  }

  // Cancelling the rename alert dismisses it without renaming.
  @Test func renameProfileAlertCancelDismisses() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        profiles: [Profile(name: "default", isDefault: true), Profile(name: "work")],
        selectedProfileName: "work",
        profilesSupported: true
      )
    ) {
      SessionListFeature()
    }

    await store.send(.renameProfileTapped(name: "work")) {
      $0.renamingProfileName = "work"
      $0.profileRenameDraft = "work"
    }
    await store.send(.cancelRenameProfile) {
      $0.renamingProfileName = nil
      $0.profileRenameDraft = ""
    }
    #expect(store.state.profiles.map(\.name) == ["default", "work"])
  }

  // MARK: Event-driven working glow (Task 7)

  // The open chat's `runningChanged(false)` clears the row's working flag (glow) INSTANTLY —
  // no poll required.
  @Test func setSessionRunningFalseClearsGlowImmediately() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "s1", isActive: true)]
      )
    ) {
      SessionListFeature()
    }

    await store.send(.setSessionRunning(id: "s1", running: false)) {
      $0.sessions[id: "s1"]?.isActive = false
    }
  }

  // The open chat's `runningChanged(true)` lights the row's working flag (glow) instantly.
  @Test func setSessionRunningTrueSetsGlowImmediately() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "s1", isActive: false)]
      )
    ) {
      SessionListFeature()
    }

    await store.send(.setSessionRunning(id: "s1", running: true)) {
      $0.sessions[id: "s1"]?.isActive = true
    }
  }

  // No-op when the patched id isn't in the current list (archived/filtered) — the poll handles
  // not-open sessions. And a no-op when the flag already matches (no spurious state change).
  @Test func setSessionRunningIgnoresUnknownIdAndNoChange() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "s1", isActive: true)]
      )
    ) {
      SessionListFeature()
    }

    // Unknown id → no state change.
    await store.send(.setSessionRunning(id: "ghost", running: true))
    // Same value → no state change.
    await store.send(.setSessionRunning(id: "s1", running: true))
  }

  // Poll backstop: a session that started working ELSEWHERE (no open chat, so no delegate)
  // is reconciled by the next REST poll flipping `isActive` true.
  @Test func pollReconcilesSessionStartedElsewhere() async {
    let clock = TestClock()
    let active = LockIsolated(false)
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection)
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = clock
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.hermesREST.pushPluginStatus = { @Sendable _ in .unknown }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        [Session(id: "s1", isActive: active.value)]
      }
    }

    await store.send(.task) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.setupPush)
    await store.receive(\.pushPluginStatusLoaded)
    await store.receive(\.profilesResponse.failure)
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1", isActive: false)]
      $0.seenCounts = ["s1": 0]
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.cronJobsSupported = false
    }

    // The agent starts working this session elsewhere; the next poll observes it.
    active.setValue(true)
    await clock.advance(by: .seconds(10))
    await store.receive(\.pollTick)
    await store.receive(\.pulledToRefresh) { $0.isLoading = true }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [Session(id: "s1", isActive: true)] // glow lit by the poll backstop
    }

    await store.send(.onDisappear)
  }
}
