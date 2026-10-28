import Clocks
import ComposableArchitecture
import Testing

@testable import HermesKit

extension IdleTimerClient {
  /// A recording double: every `setDisabled` value is appended to `calls`, in order. Used by
  /// the `ChatFeature` and `AppFeature` keep-awake tests.
  static func recording(into calls: LockIsolated<[Bool]>) -> IdleTimerClient {
    IdleTimerClient(setDisabled: { disabled in
      calls.withValue { $0.append(disabled) }
    })
  }
}

/// Bounded busy-wait for cross-task spy flags (e.g. a socket stream's `onTermination`
/// firing on a cancelled effect): yields until `condition()` holds, FAILING the test —
/// instead of hanging the suite forever — if it never does.
@MainActor
func waitUntil(
  _ condition: () -> Bool,
  _ comment: Comment? = nil,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  for _ in 0..<100_000 {
    if condition() { return }
    await Task.yield()
  }
  #expect(condition(), comment ?? "Timed out waiting for condition", sourceLocation: sourceLocation)
}

/// Bounded wait on a `TestClock`: advances it by `step` (yielding in between, so a sleeper
/// that registers late still fires on a later step) until `condition()` holds, FAILING the
/// test after `limit` steps instead of hanging on an event that never comes.
@MainActor
func advanceUntil(
  _ clock: TestClock<Duration>,
  step: Duration,
  limit: Int,
  _ condition: () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  for _ in 0..<limit {
    for _ in 0..<100 {
      if condition() { return }
      await Task.yield()
    }
    await clock.advance(by: step)
  }
  await waitUntil(condition, "Clock advanced \(limit) steps without the condition", sourceLocation: sourceLocation)
}

extension AsyncStream<GatewayFrame>.Iterator {
  /// The next frame's bare event (nil once the stream finished), for tests that assert on
  /// what the socket delivered rather than on its sequencing envelope (#98).
  mutating func nextEvent() async -> GatewayEvent? {
    await next()?.event
  }
}
