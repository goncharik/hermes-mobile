import Clocks
import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct DiagnosticsFeatureTests {
  private let serverURL = URL(string: "https://hermes.example.com")!

  private func state(log: [GatewayLogEntry] = []) -> DiagnosticsFeature.State {
    DiagnosticsFeature.State(
      serverURL: serverURL,
      authLabel: "Password · eugene",
      agentVersion: "0.9.1",
      log: log
    )
  }

  // MARK: - Log stream

  /// The log streams while the screen is pushed; popping it (the stack cancels a removed
  /// element's effects) ends the subscription — no explicit disappear action.
  @Test func streamFeedsTheLogUntilPopped() async {
    let (stream, continuation) = AsyncStream<[GatewayLogEntry]>.makeStream()
    let terminated = LockIsolated(false)
    continuation.onTermination = { _ in terminated.setValue(true) }
    let first = [GatewayLogEntry(id: 1, type: "message.delta", summary: "hi")]
    let second = first + [GatewayLogEntry(id: 2, type: "message.complete", summary: "done")]
    let connection = ServerConnection(baseURL: serverURL, token: "tok")
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.debugLog.stream = { @Sendable in stream }
    }

    await store.send(.diagnosticsRowTapped) {
      $0.path[id: 0] = .diagnostics(
        DiagnosticsFeature.State(serverURL: self.serverURL, authLabel: "Token", agentVersion: nil)
      )
    }
    await store.send(\.path[id: 0].diagnostics.task)
    continuation.yield(first)
    await store.receive(\.path[id: 0].diagnostics.logUpdated) {
      $0.path[id: 0, case: \.diagnostics]?.log = first
    }
    continuation.yield(second)
    await store.receive(\.path[id: 0].diagnostics.logUpdated) {
      $0.path[id: 0, case: \.diagnostics]?.log = second
    }

    await store.send(.path(.popFrom(id: 0))) { $0.path.pop(from: 0) }
    await waitUntil({ terminated.value })
    #expect(terminated.value)
  }

  // MARK: - Copy diagnostics

  @Test func copyPutsTheRenderedReportOnThePasteboardAndClearsAfterTheDwell() async {
    let copied = LockIsolated<[String]>([])
    let clock = TestClock()
    let log = [GatewayLogEntry(id: 1, type: "session.resume", summary: "ok")]
    let store = TestStore(initialState: state(log: log)) {
      DiagnosticsFeature()
    } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.withValue { $0.append(text) } }
      $0.continuousClock = clock
    }

    await store.send(.copyTapped) { $0.copiedToken = 1 }
    let expected = DiagnosticsReport.render(
      bundleInfo: .test,
      serverURL: serverURL,
      authLabel: "Password · eugene",
      agentVersion: "0.9.1",
      log: log
    )
    await waitUntil({ copied.value.count == 1 })
    expectNoDifference(copied.value, [expected])
    #expect(copied.value.first?.contains("session.resume — ok") == true)

    await clock.advance(by: .seconds(1.5))
    await store.receive(.copiedFeedbackElapsed) { $0.copiedToken = nil }
  }

  @Test func copyingAgainInsideTheDwellBumpsTheTokenAndRestartsTheTimer() async {
    let copied = LockIsolated<[String]>([])
    let clock = TestClock()
    let store = TestStore(initialState: state()) {
      DiagnosticsFeature()
    } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.withValue { $0.append(text) } }
      $0.continuousClock = clock
    }

    await store.send(.copyTapped) { $0.copiedToken = 1 }
    await clock.advance(by: .seconds(1.0))
    // Every copy bumps the token (a `Bool` could not re-trigger the toast) and the first
    // timer dies with it (cancelInFlight).
    await store.send(.copyTapped) { $0.copiedToken = 2 }
    await clock.advance(by: .seconds(1.0)) // 2.0 s after the first copy — nothing fires
    #expect(store.state.copiedToken == 2)
    await clock.advance(by: .seconds(0.5)) // 1.5 s after the second copy
    await store.receive(.copiedFeedbackElapsed) { $0.copiedToken = nil }
    await waitUntil({ copied.value.count == 2 })
    #expect(copied.value.count == 2)
  }

  /// The copy reflects the log as it stands at tap time, not the seed.
  @Test func copyUsesTheLatestStreamedLog() async {
    let copied = LockIsolated<[String]>([])
    let clock = TestClock()
    let entries = [GatewayLogEntry(id: 7, type: "error", summary: "socket closed")]
    let store = TestStore(initialState: state()) {
      DiagnosticsFeature()
    } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.withValue { $0.append(text) } }
      $0.continuousClock = clock
    }

    await store.send(.logUpdated(entries)) { $0.log = entries }
    await store.send(.copyTapped) { $0.copiedToken = 1 }
    await waitUntil({ copied.value.count == 1 })
    #expect(copied.value.first?.contains("error — socket closed") == true)
    await clock.advance(by: .seconds(1.5))
    await store.receive(.copiedFeedbackElapsed) { $0.copiedToken = nil }
  }
}
