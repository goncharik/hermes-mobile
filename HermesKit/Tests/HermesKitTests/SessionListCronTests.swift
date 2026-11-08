import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Cron Jobs tab: job rows, capability gating, the expanded job's runs, and job actions.
@MainActor
struct SessionListCronTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")
  private let now = Date(timeIntervalSince1970: 1_749_600_000)

  private func cronSession(
    _ jobID: String, stamp: String, messageCount: Int = 1, updatedAt: TimeInterval = 0
  ) -> Session {
    Session(
      id: "cron_\(jobID)_\(stamp)",
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      messageCount: messageCount,
      source: "cron"
    )
  }

  // MARK: Job rows + tab gating (pure state)

  @Test func sortedCronJobsListsJobsOnlyNotRuns() {
    // Runs (any id shape, including upstream `local-*` ids) never feed the job rows: the tab
    // lists the fetched jobs, and an expanded job loads its runs from `/runs`.
    let state = SessionListFeature.State(
      connection: connection,
      sessions: [
        cronSession("job1", stamp: "20260701_090000", updatedAt: 100),
        Session(id: "local-abc123", updatedAt: Date(timeIntervalSince1970: 200), source: "cron"),
        Session(id: "interactive", title: "Chat"),
      ],
      cronJobs: [CronJob(id: "job1", name: "Digest"), CronJob(id: "job2", name: "Backup")]
    )

    // Neither job has a next run → alphabetical by title: Backup (job2), Digest (job1).
    #expect(state.sortedCronJobs.map(\.id) == ["job2", "job1"])
    // The cron slice still holds both runs (the flat-fallback source and the tab gate).
    #expect(state.cronSessions.map(\.id) == ["local-abc123", "cron_job1_20260701_090000"])
  }

  @Test func jobsSortSoonestNextRunFirstThenNilThenTitle() {
    let state = SessionListFeature.State(
      connection: connection,
      cronJobs: [
        CronJob(id: "j-none-b", name: "Zeta"),
        CronJob(id: "j-late", name: "Late", nextRunAt: now.addingTimeInterval(7200)),
        CronJob(id: "j-none-a", name: "Alpha"),
        CronJob(id: "j-soon", name: "Soon", nextRunAt: now.addingTimeInterval(60)),
      ]
    )

    #expect(state.sortedCronJobs.map(\.id) == ["j-soon", "j-late", "j-none-a", "j-none-b"])
  }

  @Test func sortedCronJobsEmptyWhenUnsupportedOrNoJobs() {
    let unsupported = SessionListFeature.State(
      connection: connection,
      sessions: [cronSession("job1", stamp: "20260702_090000")],
      cronJobs: [CronJob(id: "job1")],
      cronJobsSupported: false
    )
    #expect(unsupported.sortedCronJobs.isEmpty)  // the view falls back to the flat run list
    #expect(unsupported.cronSessions.count == 1)

    let noJobs = SessionListFeature.State(
      connection: connection,
      sessions: [cronSession("job1", stamp: "20260702_090000")]
    )
    #expect(noJobs.sortedCronJobs.isEmpty)
  }

  @Test func jobsWithoutRunsKeepTheCronTabAndThePlaceholderFollowsTheTab() {
    // No sessions at all (no runs in the fetched window), but the agent has a job: the
    // Cron Jobs tab must stay so the job can still be run, paused, resumed, or deleted. The
    // Sessions tab has nothing interactive, so it shows "No sessions"; the Cron tab never does.
    var jobsOnly = SessionListFeature.State(
      connection: connection,
      cronJobs: [CronJob(id: "job1", name: "Digest")]
    )
    #expect(jobsOnly.cronSessions.isEmpty)
    #expect(jobsOnly.sortedCronJobs.map(\.id) == ["job1"])
    #expect(jobsOnly.hasCronContent)
    #expect(jobsOnly.showsTabBar)
    #expect(jobsOnly.showsEmptyPlaceholder)
    jobsOnly.selectedTab = .cron
    #expect(jobsOnly.effectiveTab == .cron)
    #expect(!jobsOnly.showsEmptyPlaceholder)

    // Search is a Sessions-only mode: an empty result set shows the placeholder.
    var searching = jobsOnly
    searching.searchQuery = "digest"
    #expect(searching.showsEmptyPlaceholder)

    // Jobs fetched but the API is unsupported → no Cron Jobs tab.
    var unsupported = SessionListFeature.State(
      connection: connection,
      cronJobs: [CronJob(id: "job1")],
      cronJobsSupported: false
    )
    unsupported.selectedTab = .cron
    #expect(!unsupported.hasCronContent)
    #expect(unsupported.effectiveTab == .sessions)
    #expect(unsupported.showsEmptyPlaceholder)

    // Runs alone (flat fallback, no jobs) still make a Cron Jobs tab, and cron runs never
    // count as Sessions-tab content.
    let runsOnly = SessionListFeature.State(
      connection: connection,
      sessions: [cronSession("job1", stamp: "20260702_090000")]
    )
    #expect(runsOnly.hasCronContent)
    #expect(runsOnly.showsEmptyPlaceholder)

    // Nothing at all → placeholder, unless still loading or failed.
    var empty = SessionListFeature.State(connection: connection)
    empty.selectedTab = .cron
    #expect(!empty.hasCronContent)
    #expect(empty.effectiveTab == .sessions)
    #expect(empty.showsEmptyPlaceholder)
    #expect(!SessionListFeature.State(connection: connection, isLoading: true).showsEmptyPlaceholder)
    #expect(
      !SessionListFeature.State(connection: connection, loadError: "boom").showsEmptyPlaceholder
    )
  }

  // MARK: Fetch + capability gate (store)

  @Test func refreshFetchesCronJobsScopedToSelectedProfile() async {
    let requestedProfile = LockIsolated<String?>("unset")
    // Hoisted: the @Sendable dependency closure can't call the MainActor-isolated helper.
    let run = cronSession("job1", stamp: "20260702_090000")
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, selectedProfileName: "work", profilesSupported: true
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _, _ in [run] }
      $0.hermesREST.cronJobs = { @Sendable _, profile in
        requestedProfile.setValue(profile)
        return [CronJob(id: "job1", name: "Digest")]
      }
    }

    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.sessions = [self.cronSession("job1", stamp: "20260702_090000")]
      // Cron rows ride along; the projection, not the source, excludes them.
      $0.statusSessions = [self.cronSession("job1", stamp: "20260702_090000")]
      $0.seenCounts = ["cron_job1_20260702_090000": 1]  // cron sessions ARE seeded (issue #24 gap 1)
    }
    await store.receive(\.cronJobsResponse.success) {
      $0.cronJobs = [CronJob(id: "job1", name: "Digest")]
    }
    // Profile-scoped agents get the LITERAL selected name (matching the scoped session list).
    #expect(requestedProfile.value == "work")
  }

  /// Cron runs are always the newest rows, so one shared page let a busy job crowd the
  /// interactive list out of the window. The load fetches two source-scoped slices instead.
  @Test func loadFetchesInteractiveAndCronRunsAsSeparateSlices() async {
    let requested = LockIsolated<[SessionSourceFilter]>([])
    let chat = Session(id: "chat", title: "Chat", updatedAt: now.addingTimeInterval(-3600))
    let run = cronSession("job1", stamp: "20260702_090000")
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, limit, _, _, source in
        requested.withValue { $0.append(source) }
        #expect(limit == 50)
        return source == .cron ? [run] : [chat]
      }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.pulledToRefresh)
    await store.receive(\.sessionsResponse.success) {
      $0.sessions = [chat, run]
    }
    #expect(requested.value == [.interactive, .cron])
  }

  @Test func failedCronSliceFailsTheLoadAndKeepsTheRows() async {
    let existing = Session(id: "kept", title: "Kept")
    let store = TestStore(
      initialState: SessionListFeature.State(connection: connection, sessions: [existing])
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _, source in
        if source == .cron { throw RESTError.unreachable }
        return [Session(id: "fresh", title: "Fresh")]
      }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.pulledToRefresh)
    await store.receive(\.sessionsResponse.failure) {
      $0.loadError = RESTError.unreachable.message
    }
    #expect(store.state.sessions.map(\.id) == ["kept"])
  }

  @Test func mergeKeepsInteractiveOrderAndDropsRepeatedRows() {
    let a = Session(id: "a"), b = Session(id: "b")
    let run = cronSession("job1", stamp: "20260702_090000")
    #expect(mergeSessionSlices([a, b], [run]).map(\.id) == ["a", "b", run.id])
    // An agent that ignores the scoping returns the same page twice: it merges to one copy.
    #expect(mergeSessionSlices([a, run], [a, run]).map(\.id) == ["a", run.id])
  }

  @Test func notFoundDisablesCronJobsAndSkipsLaterFetches() async {
    let fetchCount = LockIsolated(0)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in
        fetchCount.withValue { $0 += 1 }
        throw RESTError.notFound
      }
    }

    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.statusSessions = $0.sessions  // unfiltered: the widgets' source follows
    }
    await store.receive(\.cronJobsResponse.failure) {
      $0.isLoading = false
      $0.cronJobsSupported = false
    }

    // The flag is definitive: the next refresh fetches sessions only.
    await store.send(.pulledToRefresh) {
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
    }
    #expect(fetchCount.value == 1)
  }

  @Test func transientFailureKeepsPreviousJobs() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        cronJobs: [CronJob(id: "job1", name: "Digest")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.unreachable }
    }

    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.isLoading = false
      $0.statusSessions = []
    }
    // No state change: previous jobs survive a transient failure (no section flapping).
    await store.receive(\.cronJobsResponse.failure)
    #expect(store.state.cronJobs == [CronJob(id: "job1", name: "Digest")])
    #expect(store.state.cronJobsSupported)
  }

  @Test func unscopedAgentFetchesCronJobsWithNilProfile() async {
    let requestedProfile = LockIsolated<String?>("unset")
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, profile in
        requestedProfile.setValue(profile)
        return []
      }
    }

    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.statusSessions = $0.sessions  // unfiltered: the widgets' source follows
    }
    await store.receive(\.cronJobsResponse.success) {
      $0.isLoading = false
    }
    #expect(requestedProfile.value == nil)
  }

  @Test func jobsOnlyLoadSettlesOnceWithTheCronTab() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [CronJob(id: "job1", name: "Digest")] }
    }

    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    // An empty list is still loading until the sequential cron fetch lands, so neither the
    // placeholder nor the tab bar appears ahead of the other.
    await store.receive(\.sessionsResponse.success) {
      $0.statusSessions = $0.sessions  // unfiltered: the widgets' source follows
    }
    #expect(!store.state.showsEmptyPlaceholder)
    #expect(!store.state.showsTabBar)
    await store.receive(\.cronJobsResponse.success) {
      $0.isLoading = false
      $0.cronJobs = [CronJob(id: "job1", name: "Digest")]
    }
    #expect(store.state.showsTabBar)
    #expect(store.state.showsEmptyPlaceholder, "the Sessions tab really is empty")
  }

  @Test func emptyLoadWithTransientCronFailureSettlesOnThePlaceholder() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.unreachable }
    }

    await store.send(.pulledToRefresh) {
      $0.now = self.now
      $0.isLoading = true
    }
    await store.receive(\.sessionsResponse.success) {
      $0.statusSessions = $0.sessions  // unfiltered: the widgets' source follows
    }
    // A transient jobs failure still ends the load (no stuck spinner); no job is known.
    await store.receive(\.cronJobsResponse.failure) {
      $0.isLoading = false
    }
    #expect(store.state.cronJobsSupported)
    #expect(store.state.showsEmptyPlaceholder)
  }

  // MARK: Inline peek + unread-on-open

  @Test func cronJobTappedTogglesSingleOpenPeek() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.cronJobRuns = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.cronJobTapped(id: "job1")) {
      $0.expandedCronJobID = "job1"
    }
    await store.receive(\.cronRunsResponse) {
      $0.expandedCronRuns = []
    }
    // Expanding another job collapses the first (single-open) and starts its slot empty.
    await store.send(.cronJobTapped(id: "job2")) {
      $0.expandedCronJobID = "job2"
      $0.expandedCronRuns = nil
    }
    await store.receive(\.cronRunsResponse) {
      $0.expandedCronRuns = []
    }
    // Tapping the open job collapses it.
    await store.send(.cronJobTapped(id: "job2")) {
      $0.expandedCronJobID = nil
      $0.expandedCronRuns = nil
    }
  }

  // MARK: Expanded job runs (`/runs`)

  /// A `/runs` session row — a `local-*` id (upstream `e2042c84`), not `cron_{job}_…`.
  private func runRow(_ id: String, messageCount: Int = 1) -> Session {
    Session(id: id, messageCount: messageCount, source: "cron")
  }

  private let scriptRow = Session(id: "cron_output:job1:20260702_090000", source: "cron_output")

  @Test func expandingFetchesTheJobsRunsScopedToTheProfile() async {
    let requested = LockIsolated<(id: String, profile: String?, limit: Int)?>(nil)
    let runs = [runRow("local-2"), runRow("local-1"), scriptRow]
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, selectedProfileName: "work", profilesSupported: true,
        cronJobs: [CronJob(id: "job1", name: "Digest")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.cronJobRuns = { @Sendable _, id, profile, limit in
        requested.setValue((id, profile, limit))
        return runs
      }
    }

    await store.send(.cronJobTapped(id: "job1")) {
      $0.expandedCronJobID = "job1"
    }
    await store.receive(\.cronRunsResponse) {
      $0.expandedCronRuns = runs
    }
    #expect(requested.value?.id == "job1")
    #expect(requested.value?.profile == "work")
    #expect(requested.value?.limit == SessionListFeature.State.cronPeekLimit)
  }

  @Test func unscopedAgentFetchesRunsWithNilProfile() async {
    let requestedProfile = LockIsolated<String?>("unset")
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.cronJobRuns = { @Sendable _, _, profile, _ in
        requestedProfile.setValue(profile)
        return []
      }
    }

    await store.send(.cronJobTapped(id: "job1")) {
      $0.expandedCronJobID = "job1"
    }
    await store.receive(\.cronRunsResponse) {
      $0.expandedCronRuns = []
    }
    #expect(requestedProfile.value == nil)
  }

  @Test func collapsingCancelsTheRunsFetchAndClearsTheSlot() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.cronJobRuns = { @Sendable _, _, _, _ in try await Task.never() }
    }

    await store.send(.cronJobTapped(id: "job1")) {
      $0.expandedCronJobID = "job1"
    }
    // The pending fetch is cancelled: no response ever arrives (the store would fail on
    // an unfinished effect otherwise).
    await store.send(.cronJobTapped(id: "job1")) {
      $0.expandedCronJobID = nil
    }
  }

  @Test func switchingJobsCancelsTheOldFetchAndLoadsTheNewOne() async {
    let job2Runs = [runRow("local-9")]
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.cronJobRuns = { @Sendable _, id, _, _ in
        if id == "job1" { try await Task.never() }
        return job2Runs
      }
    }

    // job1's fetch hangs.
    await store.send(.cronJobTapped(id: "job1")) {
      $0.expandedCronJobID = "job1"
    }
    // Switching away cancels job1's hanging fetch and loads job2's runs into a fresh slot.
    await store.send(.cronJobTapped(id: "job2")) {
      $0.expandedCronJobID = "job2"
    }
    await store.receive(\.cronRunsResponse) {
      $0.expandedCronRuns = job2Runs
    }
  }

  @Test func aStaleRunsResponseForAnotherJobIsIgnored() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, expandedCronJobID: "job2", expandedCronRuns: [runRow("local-9")]
      )
    ) {
      SessionListFeature()
    }

    // job1's late success or failure never lands under job2.
    await store.send(.cronRunsResponse(jobID: "job1", .success([runRow("local-1")])))
    await store.send(.cronRunsResponse(jobID: "job1", .failure(.unreachable)))

    // …nor after a collapse.
    let collapsed = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    }
    await collapsed.send(.cronRunsResponse(jobID: "job2", .success([runRow("local-9")])))
  }

  @Test func aFirstLoadFailureShowsTheFailedState() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.cronJobRuns = { @Sendable _, _, _, _ in throw RESTError.unreachable }
    }

    await store.send(.cronJobTapped(id: "job1")) {
      $0.expandedCronJobID = "job1"
    }
    await store.receive(\.cronRunsResponse) {
      $0.expandedCronRunsFailed = true
    }
    // A later successful refresh replaces the failed state with the runs.
    await store.send(.cronRunsResponse(jobID: "job1", .success([runRow("local-1")]))) {
      $0.expandedCronRuns = [self.runRow("local-1")]
      $0.expandedCronRunsFailed = false
    }
    // Re-expanding after a collapse starts clean (no stale failed flag).
    await store.send(.cronJobTapped(id: "job1")) {
      $0.expandedCronJobID = nil
      $0.expandedCronRuns = nil
    }
  }

  @Test func aRefreshFailureKeepsTheRunsOnScreen() async {
    let shown = [runRow("local-1")]
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, expandedCronJobID: "job1", expandedCronRuns: shown
      )
    ) {
      SessionListFeature()
    }

    // No state change: the runs stay and the failed flag stays off.
    await store.send(.cronRunsResponse(jobID: "job1", .failure(.unreachable)))
    #expect(store.state.expandedCronRuns == shown)
    #expect(!store.state.expandedCronRunsFailed)
  }

  @Test func aPollTickRefetchesRunsOnlyWhileAJobIsExpanded() async {
    let runsFetches = LockIsolated<[String]>([])
    let fresh = [runRow("local-2"), runRow("local-1")]
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [CronJob(id: "job1", name: "Digest")] }
      $0.hermesREST.cronJobRuns = { @Sendable _, id, _, _ in
        runsFetches.withValue { $0.append(id) }
        return fresh
      }
    }
    store.exhaustivity = .off

    // Nothing expanded → the poll reloads the list and jobs only.
    await store.send(.pollTick)
    await store.receive(\.cronJobsResponse.success)
    #expect(runsFetches.value.isEmpty)

    // Expanded → the poll also refreshes the open job's runs.
    await store.send(.cronJobTapped(id: "job1"))
    await store.receive(\.cronRunsResponse)
    #expect(runsFetches.value == ["job1"])
    await store.send(.pollTick)
    await store.receive(\.cronJobsResponse.success)
    await store.finish()
    #expect(runsFetches.value == ["job1", "job1"])
    #expect(store.state.expandedCronRuns == fresh)
  }

  @Test func runNowSuccessRefetchesTheExpandedJobsRuns() async {
    let afterTrigger = [runRow("local-new"), runRow("local-1")]
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, cronJobs: [CronJob(id: "job1", name: "Digest")],
        expandedCronJobID: "job1", expandedCronRuns: [runRow("local-1")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.triggerCronJob = { @Sendable _, _, _ in }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [CronJob(id: "job1", name: "Digest")] }
      $0.hermesREST.cronJobRuns = { @Sendable _, _, _, _ in afterTrigger }
    }
    store.exhaustivity = .off

    await store.send(.triggerCronJob(id: "job1"))
    await store.receive(\.cronJobActionFinished)
    await store.finish()
    await store.skipReceivedActions()
    #expect(store.state.expandedCronRuns == afterTrigger)
    #expect(store.state.expandedCronJobID == "job1")
  }

  @Test func aProfileSwitchClearsTheExpandedJobAndItsRuns() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, profilesSupported: true,
        cronJobs: [CronJob(id: "job1")], expandedCronJobID: "job1",
        expandedCronRuns: [runRow("local-1")], expandedCronRunsFailed: false
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.preferences = .inMemory()
      $0.hermesProfiles.sessions = { @Sendable _, _, _, _, _, _, _ in [] }
      // `cronJobRuns` deliberately unstubbed: the switch must not refetch the old job.
      $0.hermesREST.cronJobs = { @Sendable _, _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.selectProfile(name: "work")) {
      $0.expandedCronJobID = nil
      $0.expandedCronRuns = nil
      $0.cronJobs = []
    }
    await store.finish()
  }

  @Test func theJobsAPI404ClearsTheExpandedJobAndItsRuns() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, cronJobs: [CronJob(id: "job1")],
        expandedCronJobID: "job1", expandedCronRunsFailed: true
      )
    ) {
      SessionListFeature()
    }

    await store.send(.cronJobsResponse(.failure(.notFound))) {
      $0.cronJobsSupported = false
      $0.cronJobs = []
      $0.expandedCronJobID = nil
      $0.expandedCronRunsFailed = false
    }
  }

  @Test func cronRunTappedOpensASessionRunAndMarksItSeen() async {
    // The run is also in the list's cron slice (unread 5 > 2), so the open marks it seen.
    let run = runRow("local-1", messageCount: 5)
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, sessions: [run], seenCounts: [run.id: 2],
        expandedCronJobID: "job1", expandedCronRuns: [run]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    await store.send(.cronRunTapped(id: run.id)) {
      $0.seenCounts[run.id] = 5
    }
    await store.receive(\.delegate.openSession, run)
  }

  @Test func cronRunTappedOpensARunOutsideTheListSlice() async {
    // An older run the 50-row cron slice no longer carries still opens (nothing to mark).
    let run = runRow("local-old")
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, expandedCronJobID: "job1", expandedCronRuns: [run]
      )
    ) {
      SessionListFeature()
    }

    await store.send(.cronRunTapped(id: run.id))
    await store.receive(\.delegate.openSession, run)
  }

  @Test func cronRunTappedIgnoresScriptRowsAndUnknownIDs() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, expandedCronJobID: "job1", expandedCronRuns: [scriptRow]
      )
    ) {
      SessionListFeature()
    }

    // A `cron_output` row has no backing session; an id outside the slot is unknown.
    await store.send(.cronRunTapped(id: scriptRow.id))
    await store.send(.cronRunTapped(id: "local-missing"))
  }

  // MARK: Manage actions (trigger / pause / resume)

  @Test func triggerSuccessRefetchesSessionsAndJobs() async {
    let triggered = LockIsolated<String?>(nil)
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = TestClock()
      $0.hermesREST.triggerCronJob = { @Sendable _, id, _ in triggered.setValue(id) }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [CronJob(id: "job1", state: "running")] }
    }

    await store.send(.triggerCronJob(id: "job1")) {
      $0.cronActionInFlightIDs = ["job1"]
    }
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
      $0.now = self.now
      $0.isLoading = true  // trigger → FULL load so the new run session appears
    }
    await store.receive(\.sessionsResponse.success) {
      $0.statusSessions = $0.sessions  // unfiltered: the widgets' source follows
    }
    await store.receive(\.cronJobsResponse.success) {
      $0.isLoading = false
      $0.cronJobs = [CronJob(id: "job1", state: "running")]
    }
    #expect(triggered.value == "job1")
  }

  @Test func pauseSuccessRefetchesJobsOnly() async {
    // `hermesREST.sessions` is deliberately NOT stubbed: if pause triggered a session
    // fetch, the unimplemented dependency would fail this test.
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        cronJobs: [CronJob(id: "job1", state: "scheduled")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.pauseCronJob = { @Sendable _, _, _ in }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [CronJob(id: "job1", state: "paused")] }
    }

    await store.send(.pauseCronJob(id: "job1")) {
      $0.cronActionInFlightIDs = ["job1"]
    }
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
    }
    await store.receive(\.cronJobsResponse.success) {
      $0.cronJobs = [CronJob(id: "job1", state: "paused")]  // server-reconciled, not optimistic
    }
  }

  @Test func resumeSuccessRefetchesJobsOnly() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        cronJobs: [CronJob(id: "job1", state: "paused")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.resumeCronJob = { @Sendable _, _, _ in }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [CronJob(id: "job1", state: "scheduled")] }
    }

    await store.send(.resumeCronJob(id: "job1")) {
      $0.cronActionInFlightIDs = ["job1"]
    }
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
    }
    await store.receive(\.cronJobsResponse.success) {
      $0.cronJobs = [CronJob(id: "job1", state: "scheduled")]
    }
  }

  @Test func actionFailureSurfacesBannerAndKeepsState() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        cronJobs: [CronJob(id: "job1", state: "scheduled")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.triggerCronJob = { @Sendable _, _, _ in
        throw RESTError.server(status: 400, detail: "job is paused")
      }
    }

    await store.send(.triggerCronJob(id: "job1")) {
      $0.cronActionInFlightIDs = ["job1"]
    }
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
      $0.loadError = RESTError.server(status: 400, detail: "job is paused").message
    }
    // No refetch on failure — jobs stay as they were.
    #expect(store.state.cronJobs == [CronJob(id: "job1", state: "scheduled")])
  }

  @Test func actionIsIgnoredWhileAlreadyInFlight() async {
    var initial = SessionListFeature.State(
      connection: connection,
      cronJobs: [CronJob(id: "job1", name: "Digest")],
      cronActionInFlightIDs: ["job1"]
    )
    initial.confirmationDialog = deleteDialog(title: "Digest", id: "job1")
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    }
    // No RPC stub: firing the request would fail on the unimplemented dependency.
    await store.send(.triggerCronJob(id: "job1"))
    await store.send(.pauseCronJob(id: "job1"))
    await store.send(.resumeCronJob(id: "job1"))
    await store.send(.confirmationDialog(.presented(.confirmDeleteCronJob(id: "job1")))) {
      $0.confirmationDialog = nil
    }
  }

  // MARK: Delete

  /// A state with the delete confirmation for `jobs.first` already up (the `ifLet` drops a
  /// confirm sent without it).
  private func confirmingDelete(
    _ jobs: IdentifiedArrayOf<CronJob>, sessions: IdentifiedArrayOf<Session> = [],
    expandedCronJobID: String? = nil, expandedCronRuns: [Session]? = nil
  ) -> SessionListFeature.State {
    var state = SessionListFeature.State(
      connection: connection, sessions: sessions, cronJobs: jobs,
      expandedCronJobID: expandedCronJobID, expandedCronRuns: expandedCronRuns
    )
    state.confirmationDialog = deleteDialog(title: jobs[0].title, id: jobs[0].id)
    return state
  }

  private func deleteDialog(title: String, id: String) -> ConfirmationDialogState<SessionListFeature.Action.Dialog> {
    ConfirmationDialogState {
      TextState("Delete “\(title)”?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeleteCronJob(id: id)) {
        TextState("Delete")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("This permanently removes the job. It will stop running immediately.")
    }
  }

  @Test func deleteTapPresentsTheConfirmationAndCancelSendsNothing() async {
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, cronJobs: [CronJob(id: "job1", name: "Digest")]
      )
    ) {
      SessionListFeature()
    }
    // No `deleteCronJob` stub: a DELETE on cancel would fail the unimplemented dependency.
    await store.send(.deleteCronJobTapped(id: "job1")) {
      $0.confirmationDialog = self.deleteDialog(title: "Digest", id: "job1")
    }
    await store.send(.confirmationDialog(.dismiss)) {
      $0.confirmationDialog = nil
    }
    #expect(store.state.cronJobs.map(\.id) == ["job1"])
  }

  @Test func deleteTapForAnUnknownJobIsANoOp() async {
    let store = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    }
    await store.send(.deleteCronJobTapped(id: "gone"))
  }

  @Test func confirmDeletesWithTheProfileRemovesTheJobCollapsesAndRefetches() async {
    let deleted = LockIsolated<[String]>([])
    let deleteProfile = LockIsolated<String?>("unset")
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection, selectedProfileName: "work", profilesSupported: true,
        cronJobs: [CronJob(id: "job1", name: "Digest"), CronJob(id: "job2", name: "Backup")],
        expandedCronJobID: "job1", expandedCronRuns: [runRow("local-1")]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteCronJob = { @Sendable _, id, profile in
        deleted.withValue { $0.append(id) }
        deleteProfile.setValue(profile)
      }
      // `hermesREST.sessions` deliberately unstubbed: a delete refetches jobs only.
      $0.hermesREST.cronJobs = { @Sendable _, _ in [CronJob(id: "job2", name: "Backup")] }
    }

    await store.send(.deleteCronJobTapped(id: "job1")) {
      $0.confirmationDialog = self.deleteDialog(title: "Digest", id: "job1")
    }
    await store.send(.confirmationDialog(.presented(.confirmDeleteCronJob(id: "job1")))) {
      $0.confirmationDialog = nil
      $0.cronActionInFlightIDs = ["job1"]
    }
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
      $0.cronJobs = [CronJob(id: "job2", name: "Backup")]
      $0.expandedCronJobID = nil
      $0.expandedCronRuns = nil
    }
    await store.receive(\.cronJobsResponse.success)
    #expect(deleted.value == ["job1"])
    #expect(deleteProfile.value == "work")
  }

  @Test func aSecondConfirmWhileTheDeleteIsInFlightIsGuarded() async {
    let deletes = LockIsolated(0)
    let gate = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: confirmingDelete([CronJob(id: "job1", name: "Digest")])) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteCronJob = { @Sendable _, _, _ in
        deletes.withValue { $0 += 1 }
        for await _ in gate.stream { break }
      }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [] }
    }

    await store.send(.confirmationDialog(.presented(.confirmDeleteCronJob(id: "job1")))) {
      $0.confirmationDialog = nil
      $0.cronActionInFlightIDs = ["job1"]
    }
    // Not optimistic: the row is still there, so the menu can raise the dialog again —
    // but its confirm hits the in-flight guard.
    await store.send(.deleteCronJobTapped(id: "job1")) {
      $0.confirmationDialog = self.deleteDialog(title: "Digest", id: "job1")
    }
    await store.send(.confirmationDialog(.presented(.confirmDeleteCronJob(id: "job1")))) {
      $0.confirmationDialog = nil
    }
    gate.continuation.yield()
    gate.continuation.finish()
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
      $0.cronJobs = []
    }
    await store.receive(\.cronJobsResponse.success)
    #expect(deletes.value == 1)
  }

  @Test func aDelete404IsTreatedAsAlreadyGone() async {
    let store = TestStore(
      initialState: confirmingDelete([
        CronJob(id: "job1", name: "Digest"), CronJob(id: "job2", name: "Backup"),
      ])
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteCronJob = { @Sendable _, _, _ in throw RESTError.notFound }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [CronJob(id: "job2", name: "Backup")] }
    }

    await store.send(.confirmationDialog(.presented(.confirmDeleteCronJob(id: "job1")))) {
      $0.confirmationDialog = nil
      $0.cronActionInFlightIDs = ["job1"]
    }
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
      $0.cronJobs = [CronJob(id: "job2", name: "Backup")]  // no banner, no capability flip
    }
    await store.receive(\.cronJobsResponse.success)
    #expect(store.state.cronJobsSupported)
    #expect(store.state.loadError == nil)
  }

  @Test func aDelete400SurfacesTheBannerAndKeepsTheJob() async {
    let error = RESTError.server(status: 400, detail: "Invalid job id")
    let store = TestStore(
      initialState: confirmingDelete(
        [CronJob(id: "job1", name: "Digest")], expandedCronJobID: "job1", expandedCronRuns: []
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      // `cronJobs` deliberately unstubbed: a failed delete refetches nothing.
      $0.hermesREST.deleteCronJob = { @Sendable _, _, _ in throw error }
    }

    await store.send(.confirmationDialog(.presented(.confirmDeleteCronJob(id: "job1")))) {
      $0.confirmationDialog = nil
      $0.cronActionInFlightIDs = ["job1"]
    }
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
      $0.loadError = error.message
    }
    #expect(store.state.cronJobs.map(\.id) == ["job1"])
    #expect(store.state.expandedCronJobID == "job1")
  }

  @Test func deletingTheLastJobWithNoRunsLeavesTheCronTab() async {
    var initial = confirmingDelete(
      [CronJob(id: "job1", name: "Digest")], sessions: [Session(id: "chat", title: "Chat")]
    )
    initial.selectedTab = .cron
    let store = TestStore(initialState: initial) {
      SessionListFeature()
    } withDependencies: {
      $0.hermesREST.deleteCronJob = { @Sendable _, _, _ in }
      $0.hermesREST.cronJobs = { @Sendable _, _ in [] }
    }
    #expect(store.state.effectiveTab == .cron)

    await store.send(.confirmationDialog(.presented(.confirmDeleteCronJob(id: "job1")))) {
      $0.confirmationDialog = nil
      $0.cronActionInFlightIDs = ["job1"]
    }
    await store.receive(\.cronJobActionFinished) {
      $0.cronActionInFlightIDs = []
      $0.cronJobs = []
    }
    await store.receive(\.cronJobsResponse.success)
    #expect(!store.state.hasCronContent)
    #expect(!store.state.showsTabBar)
    #expect(store.state.effectiveTab == .sessions)
  }

  @Test func openingACronRunMarksItSeen() async {
    let run = cronSession("job1", stamp: "20260702_090000", messageCount: 5)
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [run],
        seenCounts: [run.id: 2]  // unread: 5 > 2
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
    }

    #expect(store.state.unreadSessionIDs.contains(run.id))
    await store.send(.sessionTapped(run.id)) {
      $0.seenCounts[run.id] = 5
    }
    await store.receive(\.delegate.openSession)
    #expect(!store.state.unreadSessionIDs.contains(run.id))
  }
}
