import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Delivers App Intent launch requests (#93) to the reducer. The intents in the app target
/// call `LaunchIntentBridge.shared.received(_:)`; `AppFeature.task` observes `incoming()` next
/// to the push-tap observer and routes each request.
@DependencyClient
public struct LaunchIntentClient: Sendable {
  /// A stream of launch requests raised by App Intents. A request that arrived before anyone
  /// subscribed (a cold launch from an intent) is delivered to the first subscriber, once.
  public var incoming: @Sendable () -> AsyncStream<LaunchIntent> = { AsyncStream { $0.finish() } }
}

extension LaunchIntentClient: DependencyKey {
  /// The bridge is Foundation-only, so the live value needs no UIKit guard and is the same on
  /// every platform.
  public static var liveValue: LaunchIntentClient {
    LaunchIntentClient(incoming: { LaunchIntentBridge.shared.stream() })
  }

  /// No-op double: a finished stream. Spelled out, not `Self()`: the macro reports the
  /// property default as unimplemented when called. Tests that need intents put a fresh
  /// `LaunchIntentBridge()` behind `incoming`.
  public static var testValue: LaunchIntentClient {
    LaunchIntentClient(incoming: { AsyncStream { $0.finish() } })
  }
}

public extension DependencyValues {
  var launchIntents: LaunchIntentClient {
    get { self[LaunchIntentClient.self] }
    set { self[LaunchIntentClient.self] = newValue }
  }
}

// MARK: - App Intent bridge (process-wide hub)

/// Process-wide hub the App Intents feed into, fanned out to every `incoming()` consumer. The
/// intents carry no logic of their own; they just call `received(_:)`. Foundation-only
/// (`NSLock`, `AsyncStream`), so it sits outside any UIKit guard and its buffering is
/// unit-tested on macOS.
///
/// Same shape as `PushBridge`'s tap half (consume-once buffer for the launch race, live
/// fan-out, pruning on termination). Duplicated rather than abstracted: about 40 lines don't
/// justify a shared generic.
public final class LaunchIntentBridge: @unchecked Sendable {
  public static let shared = LaunchIntentBridge()

  private let lock = NSLock()
  /// Live subscribers, keyed per subscription so `onTermination` prunes the exact continuation
  /// when its consumer goes away (the reducer's `.task` observer is cancelled and re-subscribed,
  /// leaving a gap where an intent must buffer, not vanish).
  private var continuations: [UUID: AsyncStream<LaunchIntent>.Continuation] = [:]
  /// The last intent no live subscriber accepted. An App Intent with `openAppWhenRun` performs
  /// before the reducer's `.task` subscribes on a cold launch. Consume-once: the first
  /// `stream()` subscriber drains it, so a stale intent never re-opens a chat for a later
  /// re-subscriber. Last-wins: only the newest unaccepted intent is kept.
  private var pendingIntent: LaunchIntent?

  /// Internal (not `private`) so unit tests can create isolated instances; production code
  /// goes through `shared`.
  init() {}

  func stream() -> AsyncStream<LaunchIntent> {
    AsyncStream { continuation in
      let id = UUID()
      lock.withLock {
        continuations[id] = continuation
        // Deliver the intent that raced ahead of subscription, exactly once. Yielded inside
        // the lock so a concurrent `received` can't slot a newer intent in front of it.
        if let buffered = pendingIntent {
          pendingIntent = nil
          continuation.yield(buffered)
        }
      }
      // Registered after insertion: a stream that already terminated invokes the handler
      // immediately, so the entry is removed either way.
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
      }
    }
  }

  /// Called by an App Intent's `perform()`. When no live subscriber ACCEPTS the intent, it is
  /// buffered for the next `stream()` subscriber. Acceptance is judged per yield, not by
  /// `continuations.isEmpty`: a consumer cancelled on another thread can leave its terminated
  /// continuation in the dictionary while its prune waits for this lock, and yielding to it
  /// delivers nothing.
  public func received(_ intent: LaunchIntent) {
    lock.withLock {
      var delivered = false
      for continuation in continuations.values {
        if case .enqueued = continuation.yield(intent) { delivered = true }
      }
      if !delivered { pendingIntent = intent }
    }
  }

  /// Called by the app's `.onOpenURL` with a widget / control / Live Activity tap (#138): a
  /// `hermesmobile://` URL `WidgetDeepLink` maps to an intent goes through `received(_:)`,
  /// so it shares the cold-launch buffer and the reducer's stash; anything else is ignored
  /// (returns `false`, nothing buffered).
  @discardableResult
  public func received(url: URL) -> Bool {
    guard let intent = WidgetDeepLink.intent(from: url) else { return false }
    received(intent)
    return true
  }
}
