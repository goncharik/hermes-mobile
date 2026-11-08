import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// The Settings agent updater (`docs/features/agent-update.md`). Every server is a scripted
/// closure: nothing here touches a live host.
@MainActor
struct AgentUpdateTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")
  private let other = ServerConnection(baseURL: URL(string: "http://other.tailnet:9119")!, token: "tok")
  private let available = AgentUpdateCheck(currentVersion: "1.0", behind: 3, updateAvailable: true, canApply: true)
  /// 2026-10-03T10:00:00Z — the phone's POST time.
  private let postedAt = Date(timeIntervalSince1970: 1_791_021_600)
  private var scope: String { connection.agentUpdateScope }

  /// A gate a test opens explicitly, so a response can be held "slow".
  final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func open() { continuation.yield(); continuation.finish() }
    func wait() async { for await _ in stream { return } }
  }

  private func makeStore(
    preferences: PreferencesClient = .inMemory(),
    connection: ServerConnection? = nil,
    check: @escaping @Sendable () async throws -> AgentUpdateCheck = {
      AgentUpdateCheck(currentVersion: "1.0", behind: 3, updateAvailable: true, canApply: true)
    },
    status: @escaping @Sendable () async throws -> AgentUpdateActionStatus = { AgentUpdateActionStatus(running: false) },
    start: @escaping @Sendable () async throws -> AgentUpdateStart = { .started(actionID: "a-1") },
    posts: LockIsolated<Int> = LockIsolated(0)
  ) -> TestStoreOf<AgentUpdateFeature> {
    let store = TestStore(initialState: AgentUpdateFeature.State(connection: connection ?? self.connection)) {
      AgentUpdateFeature()
    } withDependencies: { [postedAt] in
      $0.preferences = preferences
      $0.hermesREST.checkAgentUpdate = { _ in try await check() }
      $0.hermesREST.agentUpdateStatus = { _ in try await status() }
      $0.hermesREST.startAgentUpdate = { _ in
        posts.withValue { $0 += 1 }
        return try await start()
      }
      $0.continuousClock = ImmediateClock()
      $0.date.now = postedAt
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  /// Open Settings on an idle server with an update available, then confirm.
  private func confirmUpdate(_ store: TestStoreOf<AgentUpdateFeature>) async {
    await store.send(.task)
    await store.receive(\.checked)
    await store.receive(\.observed)
    #expect(store.state.offersUpdate)
    await store.send(.updateTapped)
    #expect(store.state.confirmationDialog != nil)
    await store.send(.confirmationDialog(.presented(.confirmUpdate)))
  }

  private func receipt(
    _ outcome: String, version: String? = nil, started: String = "2026-10-03T10:00:01.250000+00:00",
    finished: String? = "2026-10-03T10:05:00+00:00", id: String? = nil
  ) -> AgentUpdateReceipt {
    AgentUpdateReceipt(outcome: outcome, postVersion: version, startedAt: started, finishedAt: finished, actionID: id)
  }

  private func isFailed(_ phase: AgentUpdateFeature.State.Phase) -> Bool {
    if case .failed = phase { return true }
    return false
  }

  private func isSucceeded(_ phase: AgentUpdateFeature.State.Phase) -> Bool {
    if case .succeeded = phase { return true }
    return false
  }

  // MARK: Availability and gating

  @Test(arguments: [RESTError.notFound, .server(status: 405), .unauthorized, .server(status: 403)])
  func hiddenWhenEndpointsMissingOrCredentialRejected(error: RESTError) async {
    let reads = LockIsolated(0)
    let store = makeStore(check: { throw error }, status: { reads.withValue { $0 += 1 }; return .init(running: false) })
    await store.send(.task)
    await store.receive(\.checked)
    #expect(store.state.phase == .hidden)
    #expect(!store.state.offersUpdate)
    #expect(reads.value == 0)   // no status probe against a server without the updater
    await store.finish()
  }

  @Test func hiddenWithoutADashboardCredential() async {
    let checks = LockIsolated(0)
    let store = makeStore(connection: ServerConnection(baseURL: connection.baseURL, token: ""), check: {
      checks.withValue { $0 += 1 }
      return AgentUpdateCheck(updateAvailable: true, canApply: true)
    })
    await store.send(.task)
    #expect(store.state.phase == .hidden)
    #expect(checks.value == 0)
    await store.finish()
  }

  @Test func nonGitInstallShowsServerGuidanceAndNoButton() async {
    let guidance = "Hermes is managed by Termux APT; run `pkg upgrade hermes-agent`."
    let store = makeStore(check: {
      AgentUpdateCheck(installMethod: "apt", currentVersion: "1.0", updateAvailable: false, canApply: false, message: guidance)
    })
    await store.send(.task)
    await store.receive(\.checked)
    #expect(store.state.phase == .ready)
    #expect(!store.state.offersUpdate)
    #expect(store.state.guidance == guidance)
    await store.send(.updateTapped)
    #expect(store.state.confirmationDialog == nil)
    await store.finish()
  }

  @Test func upToDateGitInstallOffersNothing() async {
    let store = makeStore(check: { AgentUpdateCheck(behind: 0, updateAvailable: false, canApply: true, message: "You're on the latest version.") })
    await store.send(.task)
    await store.receive(\.checked)
    #expect(!store.state.offersUpdate)
    #expect(store.state.guidance == nil)
    await store.finish()
  }

  @Test func confirmationWarnsAboutInterruptedSessions() async {
    let store = makeStore()
    await store.send(.task)
    await store.receive(\.checked)
    await store.send(.updateTapped)
    let message = store.state.confirmationDialog?.message.map { String(state: $0) } ?? ""
    #expect(message.contains("interrupted"))
    #expect(message.contains("dashboard"))
    #expect(message.contains("messaging gateways"))
    await store.finish()
  }

  @Test func cancellingTheConfirmationSendsNothing() async {
    let posts = LockIsolated(0)
    let store = makeStore(posts: posts)
    await store.send(.task)
    await store.receive(\.checked)
    await store.send(.updateTapped)
    await store.send(.confirmationDialog(.dismiss))
    #expect(store.state.confirmationDialog == nil)
    #expect(store.state.phase == .ready)
    #expect(posts.value == 0)
    await store.finish()
  }

  // MARK: The owned run

  /// Current agents: the receipt names our action, so success settles with its version.
  @Test func ownedRunSucceedsFromItsOwnReceipt() async {
    let preferences = PreferencesClient.inMemory()
    let posts = LockIsolated(0)
    let reads = LockIsolated(0)
    // Captured at the first poll: the immediate clock settles (and clears) the run before
    // the test can look, so the persisted id is checked from inside the run.
    let persistedWhilePolling = LockIsolated<String?>(nil)
    let store = makeStore(preferences: preferences, status: { [scope] in
      let n = reads.withValue { $0 += 1; return $0 }
      if n == 1 { return .init(running: false) }                  // recovery: idle
      if n == 2 {                                                 // ours, in progress
        persistedWhilePolling.setValue(preferences.loadOwnedAgentUpdate(scope)?.actionID)
        return .init(running: true)
      }
      return .init(running: false, actionID: "a-1", exitCode: 0,
                   receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1",
                                               startedAt: "2026-10-03T10:00:01+00:00",
                                               finishedAt: "2026-10-03T10:05:00+00:00", actionID: "a-1"))
    }, posts: posts)
    await confirmUpdate(store)
    await store.receive(\.started)
    #expect(store.state.phase == .running)
    await store.receive(\.observed)
    await store.receive(\.observed)
    #expect(persistedWhilePolling.value == "a-1")
    #expect(store.state.phase == .succeeded("1.1"))
    await store.receive(\.delegate.updated)
    #expect(store.state.owned == nil)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    #expect(posts.value == 1)
    await store.finish()
  }

  @Test func ownedRunFailureSettlesFailedNeverSuccess() async {
    let reads = LockIsolated(0)
    let store = makeStore(status: {
      reads.withValue { $0 += 1; return $0 } == 1
        ? .init(running: false)
        : .init(running: false, exitCode: 1, receipt: AgentUpdateReceipt(
            outcome: "partial", postVersion: "1.1", startedAt: "2026-10-03T10:00:01+00:00",
            finishedAt: "2026-10-03T10:05:00+00:00", actionID: "a-1"))
    })
    await confirmUpdate(store)
    await store.receive(\.started)
    await store.receive(\.observed)
    #expect(isFailed(store.state.phase))
    #expect(store.state.owned == nil)
    #expect(store.state.offersCheckAgain)
    await store.finish()
  }

  @Test(arguments: [
    RESTError.unreachable, .offline, .decoding,
    .server(status: 500), .server(status: 502, detail: "Bad Gateway"), .server(status: 503), .server(status: 504),
  ])
  func ambiguousPostFailureIsUncertainAndNeverRetried(error: RESTError) async {
    let posts = LockIsolated(0)
    let store = makeStore(start: { throw error }, posts: posts)
    await confirmUpdate(store)
    await store.receive(\.started)
    #expect(store.state.phase == .uncertain)
    #expect(!store.state.offersUpdate)
    // The only offer is a read-only status check, which doesn't POST.
    await store.send(.recheckTapped)
    await store.receive(\.observed)
    await store.skipReceivedActions()
    #expect(posts.value == 1)
    await store.finish()
  }

  /// A gateway error after the POST went out (a proxy timing out while the server spawns the
  /// update): exhaustively, the phone lands in `.uncertain`, offers no Update button, and only
  /// a read-only status check that finds the host idle brings the offer back.
  @Test func gatewayErrorAfterSendIsUncertainExhaustively() async {
    let posts = LockIsolated(0)
    var initial = AgentUpdateFeature.State(connection: connection, phase: .ready, check: available)
    initial.confirmationDialog = ConfirmationDialogState {
      TextState("Update Hermes agent?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmUpdate) { TextState("Update") }
    }
    let store = TestStore(initialState: initial) {
      AgentUpdateFeature()
    } withDependencies: { [available, postedAt] in
      $0.hermesREST.checkAgentUpdate = { _ in available }
      $0.hermesREST.agentUpdateStatus = { _ in .init(running: false) }
      $0.hermesREST.startAgentUpdate = { _ in
        posts.withValue { $0 += 1 }
        throw RESTError.server(status: 502, detail: "Bad Gateway")
      }
      $0.date.now = postedAt
    }
    await store.send(.confirmationDialog(.presented(.confirmUpdate))) {
      $0.confirmationDialog = nil
      $0.phase = .starting
    }
    await store.receive(\.started) {
      $0.phase = .uncertain
    }
    #expect(!store.state.offersUpdate)
    #expect(store.state.offersStatusRecheck)
    await store.send(.updateTapped)            // no button, and the action is inert
    await store.send(.recheckTapped) {
      $0.isRechecking = true
    }
    await store.receive(\.observed) {
      $0.phase = .checking
    }
    await store.receive(\.checked) {
      $0.isRechecking = false
      $0.phase = .ready
    }
    await store.receive(\.observed)
    #expect(posts.value == 1)
  }

  /// Only a definitive refusal fails; anything the server might have acted on is ambiguous.
  @Test func ambiguityAfterSend() {
    for status in [500, 502, 503, 504, 599] {
      #expect(RESTError.server(status: status).isAmbiguousAfterSend, "\(status)")
    }
    #expect(RESTError.serviceUnavailable.isAmbiguousAfterSend)
    for error in [RESTError.server(status: 200, detail: "refused"), .server(status: 400), .server(status: 409),
                  .unauthorized, .notFound, .rateLimited] {
      #expect(!error.isAmbiguousAfterSend, "\(error)")
    }
  }

  @Test func refusedPostIsAFailureWithTheServersReason() async {
    let reason = "Hermes is managed by Docker; pull the new image."
    let store = makeStore(start: { throw RESTError.server(status: 200, detail: reason) })
    await confirmUpdate(store)
    await store.receive(\.started)
    #expect(store.state.phase == .failed(reason))
    #expect(store.state.owned == nil)
    await store.finish()
  }

  @Test func alreadyRunningIsExternalNotOurs() async {
    let preferences = PreferencesClient.inMemory()
    let store = makeStore(preferences: preferences, start: { .alreadyRunning })
    await confirmUpdate(store)
    await store.receive(\.started)
    #expect(store.state.phase == .externalRunning)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    await store.finish()
  }

  @Test func startWithoutAnActionIDCannotBeTracked() async {
    let store = makeStore(start: { .started(actionID: nil) })
    await confirmUpdate(store)
    await store.receive(\.started)
    #expect(store.state.phase == .uncertain)
    #expect(store.state.owned == nil)
    await store.finish()
  }

  // MARK: Fencing and ownership

  /// A slow recovery read taken before our start answers late with "another run in
  /// progress": confirming cancelled it, so the answer is dropped and our run still settles.
  /// (Delivered, it would relabel the settled phase `externalRunning`.)
  @Test func slowRecoveryCannotRelabelTheOwnedRun() async {
    let recoveryGate = Gate()
    let reads = LockIsolated(0)
    let store = makeStore(status: {
      let n = reads.withValue { $0 += 1; return $0 }
      if n == 1 {
        await recoveryGate.wait()
        return .init(running: true, actionID: "x-0")
      }
      return .init(running: false, actionID: "a-1", receipt: AgentUpdateReceipt(
        outcome: "success", postVersion: "1.1", startedAt: "2026-10-03T10:00:02+00:00",
        finishedAt: "2026-10-03T10:05:00+00:00", actionID: "a-1"))
    })
    await store.send(.task)
    await store.receive(\.checked)
    await store.send(.updateTapped)
    await store.send(.confirmationDialog(.presented(.confirmUpdate)))
    await store.receive(\.started)
    await store.receive(\.observed)
    #expect(store.state.phase == .succeeded("1.1"))
    recoveryGate.open()
    await store.finish()
    #expect(store.state.phase == .succeeded("1.1"))
  }

  /// A late availability answer can't reset an external observation to "ready".
  @Test func lateAvailabilityCannotOverrideAnExternalRun() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let store = makeStore(preferences: preferences, status: { .init(running: true, actionID: "x-9") })
    await store.send(.task)
    await store.receive(\.observed)
    #expect(store.state.phase == .externalRunning)
    await store.send(.checked(.success(available)))
    #expect(store.state.phase == .externalRunning)
    await store.send(.updateTapped)
    #expect(store.state.confirmationDialog == nil)
    await store.finish()
  }

  /// Dismiss Settings mid-update, then reopen (fresh state, same persisted store): the owned
  /// run is re-observed read-only and settles without a second POST.
  @Test func reopenResumesTheOwnedRunWithoutReplayingThePost() async {
    let preferences = PreferencesClient.inMemory()
    let posts = LockIsolated(0)
    let first = makeStore(preferences: preferences, status: {
      posts.value == 0 ? .init(running: false) : .init(running: true)
    }, posts: posts)
    await confirmUpdate(first)
    await first.receive(\.started)
    #expect(first.state.phase == .running)
    // Leaving Settings tears the store down; the poll is cancelled with it.
    await first.skipInFlightEffects()
    #expect(preferences.loadOwnedAgentUpdate(scope)?.actionID == "a-1")

    let second = makeStore(preferences: preferences, status: {
      .init(running: false, actionID: "a-1", receipt: AgentUpdateReceipt(
        outcome: "success", postVersion: "1.1", startedAt: "2026-10-03T10:00:00.400000+00:00",
        finishedAt: "2026-10-03T10:05:00+00:00", actionID: "a-1"))
    }, posts: posts)
    await second.send(.task)
    #expect(second.state.owned?.actionID == "a-1")
    #expect(second.state.phase == .uncertain)
    await second.receive(\.observed)
    #expect(second.state.phase == .succeeded("1.1"))
    #expect(posts.value == 1)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    await second.finish()
  }

  /// A POST answered after its generation was superseded still hands over ownership.
  @Test func supersededStartStillAdoptsItsRun() async {
    let store = makeStore()
    let owned = OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt)
    await store.send(.started(.success(.started(actionID: "a-1")), owned: owned))
    #expect(store.state.owned == owned)
    #expect(store.state.phase == .uncertain)
    #expect(store.state.offersStatusRecheck)
  }

  /// Another action now owns the host: ours is released, never reported as success.
  @Test func supersededOwnedRunBecomesExternal() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let store = makeStore(preferences: preferences, status: { .init(running: true, actionID: "x-9") })
    await store.send(.task)
    await store.receive(\.observed)
    #expect(store.state.phase == .externalRunning)
    #expect(store.state.owned == nil)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    await store.finish()
  }

  /// An update started elsewhere finishes: it stays external; an explicit recheck that sees
  /// the host idle re-runs the availability check, and success is never ours.
  @Test func externalCompletionIsNeverOwnedSuccess() async {
    let running = LockIsolated(true)
    let store = makeStore(status: {
      running.value
        ? .init(running: true)
        : .init(running: false, actionID: "x-9", receipt: AgentUpdateReceipt(
            outcome: "success", postVersion: "2.0", finishedAt: "t", actionID: "x-9"))
    })
    await store.send(.task)
    await store.receive(\.checked)
    await store.receive(\.observed)
    #expect(store.state.phase == .externalRunning)
    running.setValue(false)
    await store.send(.recheckTapped)
    await store.receive(\.observed)
    await store.receive(\.checked)
    #expect(store.state.phase == .ready)
    #expect(store.state.owned == nil)
    await store.finish()
  }

  // MARK: Receipt correlation

  /// The success marker for our run is logged before the restart/verify steps, while the
  /// newest receipt is still another run's: neither settles ours. Then our own receipt is
  /// finalized `partial` → failed, never success, ownership held until then.
  @Test func markerBeforeReceiptThenPartialEndsFailed() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let reads = LockIsolated(0)
    let sawSuccess = LockIsolated(false)
    let store = makeStore(preferences: preferences, status: {
      reads.withValue { $0 += 1; return $0 } <= 3
        ? .init(running: false, actionID: "a-1", receipt: AgentUpdateReceipt(
            outcome: "success", postVersion: "0.9", startedAt: "2026-10-01T08:00:00+00:00",
            finishedAt: "2026-10-01T08:05:00+00:00", actionID: "old"))
        : .init(running: false, actionID: "a-1", exitCode: 1, receipt: AgentUpdateReceipt(
            outcome: "partial", postVersion: "1.1", startedAt: "2026-10-03T10:00:00+00:00",
            finishedAt: "2026-10-03T10:06:00+00:00", actionID: "a-1"))
    })
    await store.send(.task)
    await store.receive(\.observed)
    #expect(store.state.phase == .running)
    #expect(store.state.owned != nil)
    for _ in 0..<3 {
      await store.receive(\.observed)
      if isSucceeded(store.state.phase) { sawSuccess.setValue(true) }
    }
    #expect(isFailed(store.state.phase), "\(store.state.phase)")
    #expect(!sawSuccess.value)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    await store.finish()
  }

  /// Older agents' receipts carry no action id. Correlated by time (started at/after our
  /// POST), a failure settles failed…
  @Test func olderAgentTimeCorrelatedFailureSettlesFailed() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let store = makeStore(preferences: preferences, status: {
      .init(running: false, exitCode: 1, receipt: AgentUpdateReceipt(
        outcome: "failed", startedAt: "2026-10-03T10:00:00.900000+00:00", finishedAt: "2026-10-03T10:01:00+00:00"))
    })
    await store.send(.task)
    await store.receive(\.observed)
    #expect(isFailed(store.state.phase))
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    await store.finish()
  }

  /// …but a time-correlated success WITHOUT our success marker is not proof: unknown.
  @Test func olderAgentUnmarkedSuccessIsNeverOwnedSuccess() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let store = makeStore(preferences: preferences, status: {
      .init(running: false, exitCode: 0, receipt: AgentUpdateReceipt(
        outcome: "success", postVersion: "1.1", startedAt: "2026-10-03T10:00:01+00:00",
        finishedAt: "2026-10-03T10:05:00+00:00"))
    })
    await store.send(.task)
    await store.receive(\.observed)
    #expect(store.state.phase == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    await store.finish()
  }

  /// A receipt that started before our POST belongs to an older run: never settles ours.
  /// The explicit recheck releases ownership as unknown.
  @Test func olderRunsReceiptCannotSettleTheOwnedRun() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let posts = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      .init(running: false, exitCode: 1, receipt: AgentUpdateReceipt(
        outcome: "failed", startedAt: "2026-10-03T09:58:00+00:00", finishedAt: "2026-10-03T09:59:00+00:00"))
    }, posts: posts)
    await store.send(.task)
    await store.receive(\.observed)
    #expect(store.state.phase == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(scope)?.actionID == "a-1")
    await store.send(.recheckTapped)
    await store.receive(\.observed)
    #expect(store.state.phase == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    #expect(posts.value == 0)
    await store.finish()
  }

  /// Idle with nothing to correlate: released as unknown after a bounded number of reads,
  /// so a lost receipt never blocks the updater for good.
  @Test func idleWithoutReceiptReleasesAfterBoundedObservations() async {
    let preferences = PreferencesClient.inMemory()
    let posts = LockIsolated(0)
    let reads = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      if posts.value > 0 { reads.withValue { $0 += 1 } }
      return .init(running: false)
    }, posts: posts)
    await confirmUpdate(store)
    await store.receive(\.started)
    await store.receive(\.observed)
    await store.receive(\.observed)
    await store.receive(\.observed)
    #expect(store.state.phase == .uncertain)
    #expect(store.state.owned == nil)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    await store.finish()
    #expect(reads.value >= ownedIdleReleaseLimit)
    #expect(posts.value == 1)
  }

  /// Our marker is logged but our receipt never arrives: the bounded poll leaves it
  /// uncertain and still owned; one explicit recheck releases it as unknown.
  @Test func receiptThatNeverArrivesEndsUnknownNotSuccess() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let store = makeStore(preferences: preferences, status: { .init(running: false, actionID: "a-1", exitCode: 0) })
    await store.send(.task)
    await store.finish(timeout: .seconds(60))   // drains all bounded polls
    await store.skipReceivedActions()
    #expect(store.state.phase == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(scope)?.actionID == "a-1")
    await store.send(.recheckTapped)
    await store.receive(\.observed)
    #expect(store.state.phase == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
    await store.finish()
  }

  @Test func unfinishedOwnReceiptKeepsFollowing() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let store = makeStore(preferences: preferences, status: {
      .init(running: false, receipt: AgentUpdateReceipt(
        outcome: "success", startedAt: "2026-10-03T10:00:01+00:00", finishedAt: nil, actionID: "a-1"))
    })
    await store.send(.task)
    await store.receive(\.observed)
    #expect(store.state.phase == .running)
    #expect(store.state.owned != nil)
    await store.skipInFlightEffects()
  }

  // MARK: Persistence and scope

  @Test func ownershipNeverCrossesServersAndClearsByID() {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    #expect(preferences.loadOwnedAgentUpdate(other.agentUpdateScope) == nil)
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)   // dropped by the scope change
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-2", requestedAt: postedAt))
    preferences.clearOwnedAgentUpdate("a-1")                  // stale settle: no effect
    #expect(preferences.loadOwnedAgentUpdate(scope)?.actionID == "a-2")
    preferences.clearOwnedAgentUpdate(nil)                    // logout
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
  }

  @Test func liveStoreSurvivesARelaunch() {
    let suite = "agent-update-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let owned = OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt)
    PreferencesClient.live(defaults: defaults).saveOwnedAgentUpdate(owned)
    let relaunched = PreferencesClient.live(defaults: UserDefaults(suiteName: suite)!)
    #expect(relaunched.loadOwnedAgentUpdate(scope) == owned)
    relaunched.clearOwnedAgentUpdate("a-1")
    #expect(relaunched.loadOwnedAgentUpdate(scope) == nil)
  }

  @Test func scopeIsServerAndAccountButNeverTheCredential() {
    let rotated = ServerConnection(baseURL: URL(string: "HTTP://Mac.Tailnet:9119/")!, token: "new-token")
    #expect(rotated.agentUpdateScope == scope)
    #expect(other.agentUpdateScope != scope)
    let alice = ServerConnection(baseURL: connection.baseURL, auth: .cookie(CookieSession(cookies: [], username: "alice", provider: "basic")))
    let bob = ServerConnection(baseURL: connection.baseURL, auth: .cookie(CookieSession(cookies: [], username: "bob", provider: "basic")))
    #expect(alice.agentUpdateScope != bob.agentUpdateScope)
    #expect(!scope.contains("tok"))
  }

  @Test func receiptCorrelation() {
    let owned = OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt.addingTimeInterval(0.7))
    #expect(owned.owns(receipt("success", id: "a-1")))
    #expect(!owned.owns(receipt("success", id: "b-2")))
    #expect(owned.owns(receipt("failed", started: "2026-10-03T10:00:00.100000+00:00")))  // same second
    #expect(!owned.owns(receipt("failed", started: "2026-10-03T09:59:59+00:00")))
    #expect(!owned.owns(receipt("failed", started: "garbage")))
    #expect(parseServerTimestamp("2026-10-03T10:00:00.123456+00:00") == postedAt)
    #expect(parseServerTimestamp("2026-10-03T10:00:00+00:00") == postedAt)
  }

  // MARK: Settings integration

  @Test func settingsHostsTheUpdaterAndFollowsTheNewVersion() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: { [available] in
      $0.appIcon = .inMemory(current: "AppIconHermesNeo")
      $0.hermesREST.status = { @Sendable _ in ServerStatus(version: "1.0") }
      $0.hermesREST.pushPluginInfo = { @Sendable _ in PushPluginInfo(status: .unknown) }
      $0.hermesREST.checkAgentUpdate = { @Sendable _ in available }
      $0.hermesREST.agentUpdateStatus = { @Sendable _ in .init(running: false) }
      $0.push = PushClient.inMemory(granted: false, status: .notDetermined).client
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.agentUpdate.checked)
    #expect(store.state.agentUpdate.offersUpdate)
    await store.send(.agentUpdate(.delegate(.updated(version: "1.1"))))
    #expect(store.state.agentVersion == "1.1")
    await store.finish()
  }

  /// Saving a token from empty re-runs the probe at once (exhaustive): the updater appears
  /// without reopening Settings, and the probe carries the new credential.
  @Test func savingATokenFromEmptyRerunsTheProbe() async {
    let probedTokens = LockIsolated<[String?]>([])
    let empty = ServerConnection(baseURL: connection.baseURL, token: "")
    let store = TestStore(initialState: SettingsFeature.State(connection: empty)) {
      SettingsFeature()
    } withDependencies: { [available] in
      $0.keychain.saveToken = { @Sendable _ in }
      $0.hermesREST.checkAgentUpdate = { @Sendable conn in
        probedTokens.withValue { $0.append(conn.token) }
        return available
      }
      $0.hermesREST.agentUpdateStatus = { @Sendable _ in .init(running: false) }
    }
    #expect(store.state.agentUpdate.phase == .hidden)
    await store.send(\.binding.token, "tok") {
      $0.token = "tok"
    }
    await store.send(.saveTokenTapped) {
      $0.connection.token = "tok"
      $0.savedConfirmation = true
    }
    await store.receive(\.delegate.tokenSaved)
    await store.receive(\.agentUpdate.task) {
      $0.agentUpdate.phase = .checking
    }
    await store.receive(\.agentUpdate.checked) {
      $0.agentUpdate.check = self.available
      $0.agentUpdate.phase = .ready
    }
    await store.receive(\.agentUpdate.observed)
    #expect(store.state.agentUpdate.offersUpdate)
    #expect(store.state.agentUpdate.connection.token == "tok")
    #expect(probedTokens.value == ["tok"])
  }

  @Test func signingOutForgetsTheOwnedRun() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(OwnedAgentUpdate(scope: scope, actionID: "a-1", requestedAt: postedAt))
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.preferences = preferences
      $0.keychain.deleteSession = { @Sendable in }
      $0.dismiss = DismissEffect {}
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.clearTokenTapped)
    await store.skipReceivedActions()
    #expect(preferences.loadOwnedAgentUpdate(scope) == nil)
  }
}

extension RESTTransportSuite {
  struct AgentUpdateRESTTests {
    private let connection = ServerConnection(baseURL: URL(string: "http://test.local:9119")!, token: "tok")

    private func makeClient() -> HermesRESTClient {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [MockURLProtocol.self]
      return .live(session: URLSession(configuration: config))
    }

    @Test func checkForcesAFreshCheckAndDecodes() async throws {
      MockURLProtocol.set(json: #"""
      {"install_method":"git","current_version":"0.22.7","behind":4,"update_available":true,
       "can_apply":true,"update_command":"hermes update","message":null,"commits":[]}
      """#)
      let check = try await makeClient().checkAgentUpdate(connection)
      #expect(check == AgentUpdateCheck(installMethod: "git", currentVersion: "0.22.7", behind: 4,
                                        updateAvailable: true, canApply: true, updateCommand: "hermes update"))
      let request = try #require(MockURLProtocol.lastRequest)
      #expect(request.url?.path == "/api/hermes/update/check")
      #expect(request.url?.query == "force=true")
      #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    }

    @Test func checkDefaultsMissingFlagsToNothingOffered() async throws {
      MockURLProtocol.set(json: #"{"current_version":"0.9"}"#)
      let check = try await makeClient().checkAgentUpdate(connection)
      #expect(!check.updateAvailable)
      #expect(!check.canApply)
    }

    @Test func checkMissingEndpointIsTheCapabilityVerdict() async {
      MockURLProtocol.set(status: 404, json: #"{"detail":"Not Found"}"#)
      await #expect(throws: RESTError.notFound) { try await makeClient().checkAgentUpdate(connection) }
    }

    @Test func startReturnsTheActionID() async throws {
      MockURLProtocol.set(json: #"{"ok":true,"pid":42,"name":"hermes-update","action_id":"abc123"}"#)
      #expect(try await makeClient().startAgentUpdate(connection) == .started(actionID: "abc123"))
      let request = try #require(MockURLProtocol.lastRequest)
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path == "/api/hermes/update")
      #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func startAlreadyRunningIsNotOurs() async throws {
      MockURLProtocol.set(json: #"{"ok":true,"pid":42,"name":"hermes-update","already_running":true,"action_id":"zzz"}"#)
      #expect(try await makeClient().startAgentUpdate(connection) == .alreadyRunning)
    }

    @Test func startRefusalThrowsTheServersMessage() async {
      MockURLProtocol.set(json: #"""
      {"ok":false,"pid":null,"name":"hermes-update","error":"docker","message":"Pull the new image.","update_command":""}
      """#)
      await #expect(throws: RESTError.server(status: 200, detail: "Pull the new image.")) {
        try await makeClient().startAgentUpdate(connection)
      }
    }

    @Test func statusDecodesTheReceiptSummary() async throws {
      MockURLProtocol.set(json: #"""
      {"name":"hermes-update","running":false,"exit_code":0,"pid":7,"lines":["…"],
       "action_id":"abc123",
       "receipt":{"outcome":"success","started_at":"2026-10-03T10:00:01.5+00:00",
                  "finished_at":"2026-10-03T10:05:00+00:00","action_id":"abc123",
                  "pre_sha":"a","post_sha":"b","post_version":"0.22.8","fleet_states":[],"followups":[]}}
      """#)
      let status = try await makeClient().agentUpdateStatus(connection)
      #expect(status == AgentUpdateActionStatus(running: false, actionID: "abc123", exitCode: 0, receipt: AgentUpdateReceipt(
        outcome: "success", postVersion: "0.22.8", startedAt: "2026-10-03T10:00:01.5+00:00",
        finishedAt: "2026-10-03T10:05:00+00:00", actionID: "abc123")))
      let request = try #require(MockURLProtocol.lastRequest)
      #expect(request.url?.path == "/api/actions/hermes-update/status")
      #expect(request.url?.query == "lines=1")
    }
  }
}
