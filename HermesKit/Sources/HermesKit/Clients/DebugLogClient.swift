import ComposableArchitecture
import DependenciesMacros
import Foundation

/// An app-wide, capped ring buffer of decoded gateway events for the Settings debug
/// log (Task 12). `ChatFeature`'s connect loop appends every event; `SettingsFeature`
/// reads a snapshot and subscribes to live updates. Kept as a dependency (not feature
/// state) so the high-frequency appends never touch `ChatFeature.State` or its tests.
@DependencyClient
public struct DebugLogClient: Sendable {
  public var append: @Sendable (_ event: GatewayEvent) -> Void
  /// A free-text client note (not a wire event), e.g. a swallowed `session.events.since`
  /// failure (#98). Shares the ring buffer, ids, and summary digest with `append`.
  public var note: @Sendable (_ type: String, _ summary: String) -> Void
  public var snapshot: @Sendable () -> [GatewayLogEntry] = { [] }
  /// A live feed: yields the current snapshot immediately, then a new snapshot on each
  /// append. Finishes when the buffer is torn down.
  public var stream: @Sendable () -> AsyncStream<[GatewayLogEntry]> = { .finished }
}

extension DebugLogClient: DependencyKey {
  public static var liveValue: DebugLogClient { .ringBuffer() }
  /// Tests get a no-op by default so `ChatFeature`'s connect loop stays inert; override
  /// per-test to capture or feed entries.
  public static var testValue: DebugLogClient {
    DebugLogClient(append: { _ in }, note: { _, _ in }, snapshot: { [] }, stream: { .finished })
  }

  /// A self-contained in-memory buffer (used live and overridable in tests).
  public static func ringBuffer(capacity: Int = 200) -> DebugLogClient {
    let buffer = Buffer(capacity: capacity)
    return DebugLogClient(
      append: { buffer.append(type: $0.debugType, summary: $0.debugSummary) },
      note: { buffer.append(type: $0, summary: GatewayEvent.truncate($1)) },
      snapshot: { buffer.snapshot() },
      stream: { buffer.stream() }
    )
  }
}

public extension DependencyValues {
  var debugLog: DebugLogClient {
    get { self[DebugLogClient.self] }
    set { self[DebugLogClient.self] = newValue }
  }
}

/// Lock-guarded ring buffer + fan-out to live subscribers.
private final class Buffer: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private var entries: [GatewayLogEntry] = []
  private var nextID = 0
  private var continuations: [UUID: AsyncStream<[GatewayLogEntry]>.Continuation] = [:]

  init(capacity: Int) { self.capacity = capacity }

  func append(type: String, summary: String) {
    let broadcast: [GatewayLogEntry] = lock.withLock {
      entries.append(GatewayLogEntry(id: nextID, type: type, summary: summary))
      nextID += 1
      if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
      let snapshot = entries
      for continuation in continuations.values { continuation.yield(snapshot) }
      return snapshot
    }
    _ = broadcast
  }

  func snapshot() -> [GatewayLogEntry] { lock.withLock { entries } }

  func stream() -> AsyncStream<[GatewayLogEntry]> {
    AsyncStream { continuation in
      let id = UUID()
      lock.withLock {
        continuations[id] = continuation
        continuation.yield(entries) // prime with the current snapshot
      }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
      }
    }
  }
}
