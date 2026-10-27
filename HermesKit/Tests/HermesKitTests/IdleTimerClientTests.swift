import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

extension IdleTimerClient {
  /// A recording double: every `setDisabled` value is appended to `calls`, in order.
  /// Shared with the `ChatFeature` keep-awake tests.
  static func recording(into calls: LockIsolated<[Bool]>) -> IdleTimerClient {
    IdleTimerClient(setDisabled: { disabled in
      calls.withValue { $0.append(disabled) }
    })
  }
}

struct IdleTimerClientTests {
  @Test func recordingOverrideReceivesEveryValueInOrder() async {
    let calls = LockIsolated<[Bool]>([])
    let client = IdleTimerClient.recording(into: calls)

    await client.setDisabled(true)
    await client.setDisabled(false)
    await client.setDisabled(true)

    #expect(calls.value == [true, false, true])
  }

  @Test func recordingOverrideReachesThroughTheDependency() async {
    let calls = LockIsolated<[Bool]>([])
    await withDependencies {
      $0.idleTimer = .recording(into: calls)
    } operation: {
      @Dependency(\.idleTimer) var idleTimer
      await idleTimer.setDisabled(true)
    }

    #expect(calls.value == [true])
  }

  @Test func testValueIsANoOp() async {
    // The default double must be callable without an unimplemented-closure failure, since
    // every `ChatFeature` test that never overrides it still flows through it.
    await IdleTimerClient.testValue.setDisabled(true)
    await IdleTimerClient.testValue.setDisabled(false)
  }
}
