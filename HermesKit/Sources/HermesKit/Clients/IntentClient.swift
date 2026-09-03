import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Bridges external launch surfaces (App Intents and UIKit Home Screen Quick Actions) into
/// a stream the reducer observes, so `AppFeature` stays testable and never touches either
/// platform framework. Mirrors `PushClient`/`PushBridge`: the client is the dependency the
/// reducer reads; the bridge is the process-wide hub the app target feeds.
@DependencyClient
public struct IntentClient: Sendable {
  /// A stream of launch intents for the reducer to route (deep-link style, #93).
  public var incomingIntents: @Sendable () -> AsyncStream<LaunchIntent> = {
    AsyncStream { $0.finish() }
  }
}

extension IntentClient: DependencyKey {
  public static var liveValue: IntentClient {
    IntentClient(incomingIntents: { IntentBridge.shared.intentStream() })
  }

  /// No-op double: empty stream. Override `incomingIntents` in tests to inject intents.
  public static var testValue: IntentClient {
    IntentClient(incomingIntents: { AsyncStream { $0.finish() } })
  }
}

public extension DependencyValues {
  var launchIntent: IntentClient {
    get { self[IntentClient.self] }
    set { self[IntentClient.self] = newValue }
  }
}

// MARK: - App-intent bridge (process-wide hub)

/// Process-wide hub the app target's App Intents / Quick Actions feed into, fanned out to every
/// `incomingIntents()` consumer. Mirrors `PushBridge`: Foundation-only (`NSLock` +
/// `AsyncStream`), so its stream/buffering behavior is unit-tested on macOS
/// (`swift test`). A launch-from-intent fires `perform()` before the reducer's `.task`
/// observer subscribes (the same cold-launch race push solves in #46), so an intent with
/// no live subscriber is buffered and drained **consume-once** by the first subscriber —
/// a stale intent must not re-navigate a later re-subscriber.
public final class IntentBridge: @unchecked Sendable {
  public static let shared = IntentBridge()

  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<LaunchIntent>.Continuation] = [:]
  /// The last intent no live subscriber accepted (launch-from-intent race). Consume-once:
  /// the first `intentStream()` subscriber drains it. An intent delivered to at least one
  /// live continuation is never cached — buffering exists only for the launch race.
  private var pendingIntent: LaunchIntent?

  /// Internal (not `private`) so unit tests can create isolated instances; production
  /// code goes through `shared`.
  init() {}

  func intentStream() -> AsyncStream<LaunchIntent> {
    AsyncStream { continuation in
      let id = UUID()
      lock.withLock {
        continuations[id] = continuation
        // Deliver the intent that raced ahead of subscription (launch-from-intent),
        // exactly once. Yielded INSIDE the lock so a concurrent `received` can't slot a
        // newer intent in front of the buffered one — delivery order is the contract.
        if let buffered = pendingIntent {
          pendingIntent = nil
          continuation.yield(buffered)
        }
      }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
      }
    }
  }

  /// Called by an App Intent's `perform()` or the Quick Action delegate. When no live subscriber
  /// ACCEPTS the intent, it is buffered for the next `intentStream()` subscriber.
  /// Acceptance is judged per-yield (not by `continuations.isEmpty`), so a consumer
  /// cancelled on another thread can't swallow an intent while its `onTermination` prune
  /// waits for the lock — the intent falls back to the buffer instead of vanishing.
  public func received(_ intent: LaunchIntent) {
    lock.withLock {
      var delivered = false
      for continuation in continuations.values {
        if case .enqueued = continuation.yield(intent) { delivered = true }
      }
      if !delivered { pendingIntent = intent }
    }
  }
}
