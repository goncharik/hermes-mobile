import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Authorization state for push notifications. A small Sendable mirror of
/// `UNAuthorizationStatus` so HermesKit doesn't leak `UserNotifications` types to the
/// non-iOS test host (the package is also built/tested on macOS via `swift test`).
public enum PushAuthorizationStatus: Equatable, Sendable {
  case notDetermined
  case denied
  case authorized
  /// Provisional / ephemeral authorizations (treated as "may deliver" by callers).
  case provisional
}

/// A tapped push notification, carrying just enough to deep-link (#push). Only generic
/// metadata transits the gateway — real message content is fetched in-app — so a tap
/// surfaces the `session_id` (+ the trigger `type` when the payload includes it) and
/// nothing sensitive.
public struct PushTap: Equatable, Sendable {
  public let sessionID: String
  /// The trigger type (`"approval"`, `"clarify"`, `"complete"`, `"error"`) when the APNs
  /// payload carries it; `nil` for payloads that omit it (older gateway builds). Drives the
  /// pending-approval badge — only `"approval"` taps bump it.
  public let type: String?

  public init(sessionID: String, type: String? = nil) {
    self.sessionID = sessionID
    self.type = type
  }

  /// Whether this tap is an approval request (the only type that bumps the badge).
  public var isApproval: Bool { type == PushClient.approvalType }

  /// Whether this push reports the session's turn over (completed or failed).
  public var endsTurn: Bool { type.map(PushClient.turnEndedTypes.contains) ?? false }
}

/// Bridges APNs registration + notification handling behind a dependency so reducers stay
/// testable and never touch `UserNotifications`/`UIKit` directly. The app-delegate bridge
/// (C2) feeds device tokens and taps into the streams this client exposes.
@DependencyClient
public struct PushClient: Sendable {
  /// Prompt for (or read) notification permission. `true` ⇒ granted.
  public var requestAuthorization: @Sendable () async -> Bool = { false }
  /// Current authorization status (no prompt).
  public var authorizationStatus: @Sendable () async -> PushAuthorizationStatus = { .notDetermined }
  /// Trigger `registerForRemoteNotifications` and stream device tokens as lowercase hex
  /// strings. The app-delegate bridge yields a token here once APNs registration succeeds;
  /// the stream re-yields on token rotation. Finishes when the consumer is cancelled.
  public var register: @Sendable () -> AsyncStream<String> = { AsyncStream { $0.finish() } }
  /// A stream of incoming notification taps (carrying the `session_id`) for deep-linking.
  public var incomingTaps: @Sendable () -> AsyncStream<PushTap> = { AsyncStream { $0.finish() } }
  /// A stream of pushes DELIVERED to the running app — the background wake the gateway's
  /// `content-available` flag asks for — carrying the same `session_id` + `type` as a tap.
  /// Live-only: a push no subscriber takes is dropped (a wake that relaunched the process has
  /// no surfaces state to correct). Drives the Live Activity / widgets (#138).
  public var deliveredPushes: @Sendable () -> AsyncStream<PushTap> = {
    AsyncStream { $0.finish() }
  }
  /// The app's short version string (`CFBundleShortVersionString`), sent with the device-token
  /// registration so the plugin/gateway can record which build registered. Behind the client so
  /// reducers stay free of `Bundle` access and tests can inject a fixed value.
  public var appVersion: @Sendable () -> String = { "0.0" }
  /// Set the app-icon badge to `count` (the pending-approval total). Behind the client so the
  /// reducer owns the count and the only `UIApplication`/`UNUserNotificationCenter` side effect
  /// lives here; the test double is a no-op.
  public var setBadgeCount: @Sendable (_ count: Int) async -> Void
  /// Record (or clear, with `nil`) the session the user is currently viewing. The app-delegate's
  /// `willPresent` reads this via the bridge so a push for the session already on screen is
  /// suppressed (foreground suppression). Updated by the reducer on chat open/close.
  public var setCurrentSession: @Sendable (_ sessionID: String?) -> Void

  // MARK: - Pure logic (unit-tested on macOS, outside the iOS guard)

  /// The trigger `type` string for an approval request (the only push that bumps the badge).
  public static let approvalType = "approval"
  /// The trigger types that end a turn: the plugin's `complete` (`post_llm_call`, once per turn
  /// after the tool loop) and `error` (`on_session_end`, genuine failures only).
  public static let turnEndedTypes: Set<String> = ["complete", "error"]

  /// The foreground-presentation decision (#push C5), kept pure so it's unit-tested on any
  /// platform and the app delegate stays logic-free. Suppress the banner (return `false`) only
  /// when the incoming push targets the **same** session the user is already viewing; otherwise
  /// present it. A `nil` `currentlyViewing` (no chat open) always presents.
  public static func shouldPresentForeground(
    incomingSessionID: String?,
    currentlyViewingSessionID: String?
  ) -> Bool {
    guard let incoming = incomingSessionID, let viewing = currentlyViewingSessionID
    else { return true }
    return incoming != viewing
  }

  /// Encode an APNs device-token `Data` blob as a lowercase hex string (the form the
  /// gateway/plugin expect). Pure so it's testable on any platform.
  public static func hexToken(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  /// The APNs environment baked in at compile time. A Debug build registers with the APNs
  /// *sandbox*; a Release build registers with *production*. The env→host mismatch is the
  /// classic push footgun, so it's a single compile-time constant threaded to registration.
  public static let apnsEnv: String = {
    #if DEBUG
      return "sandbox"
    #else
      return "production"
    #endif
  }()

  /// Parse the `session_id` out of an APNs userInfo payload (`{ "session_id": "…" }`).
  /// Returns `nil` when absent/empty so the bridge can drop a malformed tap. Pure.
  public static func sessionID(fromPayload payload: [AnyHashable: Any]) -> String? {
    guard let id = payload["session_id"] as? String, !id.isEmpty else { return nil }
    return id
  }

  /// Build a `PushTap` from an APNs userInfo payload, parsing the `session_id` (required) and
  /// the optional trigger `type` (`{ "session_id": "…", "type": "approval" }`). Returns `nil`
  /// for a malformed payload (no/empty session id). Pure. The `type` is only present when the
  /// gateway includes it; absent → a non-approval tap (badge unaffected).
  public static func tap(fromPayload payload: [AnyHashable: Any]) -> PushTap? {
    guard let id = sessionID(fromPayload: payload) else { return nil }
    let type = (payload["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return PushTap(sessionID: id, type: type)
  }
}

extension PushClient: DependencyKey {
  /// No-op double: never granted, empty streams. Override individual closures in tests.
  /// (Spelled out rather than the bare memberwise init so the `@DependencyClient` macro's
  /// unimplemented closures don't leak into the default test double.)
  public static var testValue: PushClient {
    PushClient(
      requestAuthorization: { false },
      authorizationStatus: { .notDetermined },
      register: { AsyncStream { $0.finish() } },
      incomingTaps: { AsyncStream { $0.finish() } },
      deliveredPushes: { AsyncStream { $0.finish() } },
      appVersion: { "0.0" },
      setBadgeCount: { _ in },
      setCurrentSession: { _ in }
    )
  }
}

public extension DependencyValues {
  var push: PushClient {
    get { self[PushClient.self] }
    set { self[PushClient.self] = newValue }
  }
}

// MARK: - In-memory (deterministic test variant)

/// Thread-safe mailbox driving the in-memory client's streams and authorize result, so
/// tests can inject a token / tap / granted-result and observe them through the public API.
private final class PushBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _granted: Bool
  private var _status: PushAuthorizationStatus
  private var _badgeCount: Int = 0
  private var _currentSession: String?
  private var tokenContinuations: [AsyncStream<String>.Continuation] = []
  private var tapContinuations: [AsyncStream<PushTap>.Continuation] = []
  private var deliveryContinuations: [AsyncStream<PushTap>.Continuation] = []

  init(granted: Bool, status: PushAuthorizationStatus) {
    _granted = granted
    _status = status
  }

  var badgeCount: Int { lock.withLock { _badgeCount } }
  var currentSession: String? { lock.withLock { _currentSession } }

  func setBadgeCount(_ count: Int) { lock.withLock { _badgeCount = count } }
  func setCurrentSession(_ sessionID: String?) { lock.withLock { _currentSession = sessionID } }

  var granted: Bool {
    lock.withLock { _granted }
  }

  var status: PushAuthorizationStatus {
    lock.withLock { _status }
  }

  func setAuthorized(_ granted: Bool) {
    lock.withLock {
      _granted = granted
      _status = granted ? .authorized : .denied
    }
  }

  func tokenStream() -> AsyncStream<String> {
    AsyncStream { continuation in
      lock.withLock { tokenContinuations.append(continuation) }
    }
  }

  func tapStream() -> AsyncStream<PushTap> {
    AsyncStream { continuation in
      lock.withLock { tapContinuations.append(continuation) }
    }
  }

  func emit(token: String) {
    let continuations = lock.withLock { tokenContinuations }
    for continuation in continuations { continuation.yield(token) }
  }

  func emit(tap: PushTap) {
    let continuations = lock.withLock { tapContinuations }
    for continuation in continuations { continuation.yield(tap) }
  }

  func deliveryStream() -> AsyncStream<PushTap> {
    AsyncStream { continuation in
      lock.withLock { deliveryContinuations.append(continuation) }
    }
  }

  func emit(delivery: PushTap) {
    let continuations = lock.withLock { deliveryContinuations }
    for continuation in continuations { continuation.yield(delivery) }
  }
}

public extension PushClient {
  /// A deterministic, controllable client for tests: `authorize()` returns the configured
  /// result and exposes hooks to push a token / tap into the live streams. Mirrors
  /// `AudioRecorderClient` / `KeychainClient` `.inMemory()` variants.
  struct InMemory: Sendable {
    public let client: PushClient
    private let box: PushBox

    public init(granted: Bool = true, status: PushAuthorizationStatus = .authorized) {
      let box = PushBox(granted: granted, status: status)
      self.box = box
      self.client = PushClient(
        requestAuthorization: {
          box.setAuthorized(box.granted)
          return box.granted
        },
        authorizationStatus: { box.status },
        register: { box.tokenStream() },
        incomingTaps: { box.tapStream() },
        deliveredPushes: { box.deliveryStream() },
        appVersion: { "1.2.3" },
        setBadgeCount: { count in box.setBadgeCount(count) },
        setCurrentSession: { sessionID in box.setCurrentSession(sessionID) }
      )
    }

    /// Push a device token into the `register()` stream as if APNs delivered it.
    public func emit(token: String) { box.emit(token: token) }
    /// Push a tap into the `incomingTaps()` stream as if the user tapped a notification.
    /// Taps are delivered LIVE-ONLY: unlike the production `PushBridge`, the double does
    /// no launch-race buffering, so a tap emitted with no active subscriber is silently
    /// dropped — deterministic for tests (subscribe first, then emit). To exercise the
    /// cold-launch buffer itself, inject a real `PushBridge` behind a `PushClient`
    /// instead (see `coldLaunchTapBufferedInBridgeReplaysThroughTaskObserver`).
    public func emit(tap: PushTap) { box.emit(tap: tap) }
    /// Push a delivered (background-wake) push into the `deliveredPushes()` stream. Live-only,
    /// like the production bridge.
    public func emit(delivery: PushTap) { box.emit(delivery: delivery) }
    /// Change the granted result the next `requestAuthorization()` returns.
    public func setAuthorized(_ granted: Bool) { box.setAuthorized(granted) }
    /// The last badge count the reducer set (spy hook for tests).
    public var badgeCount: Int { box.badgeCount }
    /// The session id the reducer last marked as currently-viewing (spy hook for tests).
    public var currentSession: String? { box.currentSession }
  }

  /// Convenience: a controllable in-memory client + handle for driving its streams.
  static func inMemory(
    granted: Bool = true,
    status: PushAuthorizationStatus = .authorized
  ) -> InMemory {
    InMemory(granted: granted, status: status)
  }
}

// MARK: - App-delegate bridge (process-wide hub)

/// Process-wide hub the app-delegate bridge (C2) feeds tokens/taps into, fanned out to
/// every `register()` / `incomingTaps()` consumer. Lives here so the bridge has no logic
/// of its own — it just calls `tokenReceived` / `tapReceived`. Uses only Foundation
/// (`NSLock`, `AsyncStream`) + the pure `PushClient` helpers, so it sits OUTSIDE the
/// UIKit guard and its stream/buffering behavior is unit-tested on macOS (`swift test`).
public final class PushBridge: @unchecked Sendable {
  public static let shared = PushBridge()

  private let lock = NSLock()
  /// Live subscribers, keyed per-subscription so `onTermination` can prune the exact
  /// continuation when its consumer goes away (the reducer's `.task` observer is
  /// cancelled and re-subscribed — `cancelInFlight` — leaving a gap where a tap must
  /// buffer, not vanish into a dead continuation). Pruning keeps the dictionaries from
  /// accreting dead entries; on the tap side `tapReceived` additionally inspects each
  /// yield's RESULT, so even a terminated-but-not-yet-pruned continuation (its
  /// `onTermination` still racing for this lock) can't swallow a tap.
  private var tokenContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
  private var tapContinuations: [UUID: AsyncStream<PushTap>.Continuation] = [:]
  /// Live subscribers to delivered (background-wake) pushes. Unlike taps these are never
  /// buffered: a push that finds no observer belongs to a process with nothing to correct.
  private var deliveryContinuations: [UUID: AsyncStream<PushTap>.Continuation] = [:]
  private var lastToken: String?
  /// The last tap no live subscriber accepted (a launch-from-push fires the app
  /// delegate's `didReceive` before the reducer's `.task` subscribes — #46). Unlike
  /// `lastToken` (idempotent, replayed to every late subscriber), a tap is consume-once:
  /// the first `tapStream()` subscriber drains it, so a stale tap never re-navigates a
  /// later re-subscriber. A tap delivered to at least one live continuation is never
  /// cached — buffering exists only for the launch race.
  private var pendingTap: PushTap?
  /// The session the user is currently viewing, set by the reducer (via
  /// `PushClient.setCurrentSession`) on chat open/close. Read by `willPresent` to decide
  /// foreground suppression — kept here so the app delegate carries no state of its own.
  private var currentSessionID: String?

  /// Internal (not `private`) so unit tests can create isolated instances; production
  /// code goes through `shared`.
  init() {}

  /// Update the currently-viewing session (reducer → `PushClient.setCurrentSession`).
  public func setCurrentSession(_ sessionID: String?) {
    lock.withLock { currentSessionID = sessionID }
  }

  /// Decide whether a foreground push should present its banner, given the session it
  /// targets. Suppresses (returns `false`) when the user is already viewing that session.
  /// Called by the app delegate's `willPresent`; the actual rule is the pure
  /// `PushClient.shouldPresentForeground`.
  public func shouldPresentForeground(for payload: [AnyHashable: Any]) -> Bool {
    let incoming = PushClient.sessionID(fromPayload: payload)
    let viewing = lock.withLock { currentSessionID }
    return PushClient.shouldPresentForeground(
      incomingSessionID: incoming, currentlyViewingSessionID: viewing
    )
  }

  func tokenStream() -> AsyncStream<String> {
    AsyncStream { continuation in
      let id = UUID()
      lock.withLock {
        tokenContinuations[id] = continuation
        // Re-deliver the most recent token so a late subscriber still registers. Yielded
        // inside the lock so a concurrent rotation can't slot a newer token in front.
        if let cached = lastToken { continuation.yield(cached) }
      }
      // Prune on consumer termination (cancellation/dealloc) so dead continuations never
      // accumulate. Registered after insertion — a stream that already terminated invokes
      // the handler immediately, so the entry is removed either way.
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { _ = self.tokenContinuations.removeValue(forKey: id) }
      }
    }
  }

  func tapStream() -> AsyncStream<PushTap> {
    AsyncStream { continuation in
      let id = UUID()
      lock.withLock {
        tapContinuations[id] = continuation
        // Deliver the tap that raced ahead of subscription (launch-from-push), exactly
        // once. Yielded INSIDE the lock: a `tapReceived` on another thread must not slot
        // a newer tap in front of the buffered one — for taps, delivery order is the
        // contract (the consumer's last-wins routing navigates to the final tap).
        if let buffered = pendingTap {
          pendingTap = nil
          continuation.yield(buffered)
        }
      }
      // Prune on consumer termination so `tapContinuations.isEmpty` keeps meaning "no
      // LIVE subscriber" — the buffer must re-engage after the observer goes away (the
      // reducer's `.task` re-fire cancels the old effect before the replacement
      // subscribes; a tap landing in that gap has to buffer, not no-op into a dead
      // continuation).
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { _ = self.tapContinuations.removeValue(forKey: id) }
      }
    }
  }

  func deliveryStream() -> AsyncStream<PushTap> {
    AsyncStream { continuation in
      let id = UUID()
      lock.withLock { deliveryContinuations[id] = continuation }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { _ = self.deliveryContinuations.removeValue(forKey: id) }
      }
    }
  }

  /// Called by the app delegate when a push is delivered to the running app
  /// (`didReceiveRemoteNotification`, the gateway's `content-available` wake). Fans out to the
  /// live subscribers; dropped when there are none (see `deliveryContinuations`). Malformed
  /// payloads (no session id) are dropped.
  public func pushDelivered(_ payload: [AnyHashable: Any]) {
    guard let push = PushClient.tap(fromPayload: payload) else { return }
    lock.withLock {
      for continuation in deliveryContinuations.values { continuation.yield(push) }
    }
  }

  /// Called by the app delegate on `didRegisterForRemoteNotificationsWithDeviceToken`.
  public func tokenReceived(_ data: Data) {
    let hex = PushClient.hexToken(from: data)
    lock.withLock {
      lastToken = hex
      for continuation in tokenContinuations.values { continuation.yield(hex) }
    }
  }

  /// Called by the app delegate on a notification tap (`didReceive`). When no live
  /// subscriber ACCEPTS the tap, it is buffered for the next `tapStream()` subscriber.
  /// Acceptance is judged per-yield, not by `tapContinuations.isEmpty`: a consumer
  /// cancelled on another thread can leave its already-terminated continuation in the
  /// dictionary while its `onTermination` prune waits for this lock — yielding to it
  /// returns `.terminated` and delivers nothing, so the tap must fall back to the
  /// buffer instead of vanishing. Yields happen inside the lock so two rapid taps
  /// can't be observed out of order.
  public func tapReceived(_ payload: [AnyHashable: Any]) {
    guard let tap = PushClient.tap(fromPayload: payload) else { return }
    lock.withLock {
      var delivered = false
      for continuation in tapContinuations.values {
        if case .enqueued = continuation.yield(tap) { delivered = true }
      }
      if !delivered { pendingTap = tap }
    }
  }
}

// MARK: - Live (iOS only)

// `UNUserNotificationCenter`/`UIApplication.registerForRemoteNotifications` are iOS-only;
// the package is also built/tested on macOS via `swift test`, so the live client is
// compiled in only where UIKit exists. Elsewhere `liveValue` falls back to the no-op
// double (#push).
#if canImport(UIKit)
  import UIKit
  import UserNotifications

  extension PushClient {
    public static var liveValue: PushClient {
      PushClient(
        requestAuthorization: {
          let center = UNUserNotificationCenter.current()
          let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
          if granted {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
          }
          return granted
        },
        authorizationStatus: {
          let settings = await UNUserNotificationCenter.current().notificationSettings()
          switch settings.authorizationStatus {
          case .authorized: return .authorized
          case .provisional, .ephemeral: return .provisional
          case .denied: return .denied
          case .notDetermined: return .notDetermined
          @unknown default: return .notDetermined
          }
        },
        register: {
          Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
          return PushBridge.shared.tokenStream()
        },
        incomingTaps: { PushBridge.shared.tapStream() },
        deliveredPushes: { PushBridge.shared.deliveryStream() },
        appVersion: {
          (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
        },
        setBadgeCount: { count in
          try? await UNUserNotificationCenter.current().setBadgeCount(count)
        },
        setCurrentSession: { sessionID in
          PushBridge.shared.setCurrentSession(sessionID)
        }
      )
    }
  }
#else
  extension PushClient {
    /// No push off-device (macOS `swift test`): fall back to the no-op double.
    public static var liveValue: PushClient { testValue }
  }
#endif
