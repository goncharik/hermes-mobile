import Foundation
import Testing

@testable import HermesKit

struct PushClientTests {
  // MARK: device-token Data → lowercase hex

  @Test func hexTokenEncodesKnownBytes() {
    let data = Data([0x00, 0x0f, 0xab, 0xff])
    #expect(PushClient.hexToken(from: data) == "000fabff")
  }

  @Test func hexTokenIsEmptyForEmptyData() {
    #expect(PushClient.hexToken(from: Data()) == "")
  }

  // MARK: compile-time apns_env constant

  @Test func apnsEnvMatchesBuildConfiguration() {
    // Tests run under a Debug build → sandbox.
    #if DEBUG
      #expect(PushClient.apnsEnv == "sandbox")
    #else
      #expect(PushClient.apnsEnv == "production")
    #endif
    #expect(["sandbox", "production"].contains(PushClient.apnsEnv))
  }

  // MARK: payload → session_id parsing

  @Test func sessionIDParsesFromPayload() {
    #expect(PushClient.sessionID(fromPayload: ["session_id": "abc"]) == "abc")
  }

  @Test func sessionIDIsNilWhenMissingOrEmpty() {
    #expect(PushClient.sessionID(fromPayload: [:]) == nil)
    #expect(PushClient.sessionID(fromPayload: ["session_id": ""]) == nil)
    #expect(PushClient.sessionID(fromPayload: ["session_id": 42]) == nil)
  }

  // MARK: payload → PushTap (session_id + optional type)

  @Test func tapParsesSessionAndType() {
    let tap = PushClient.tap(fromPayload: ["session_id": "abc", "type": "approval"])
    #expect(tap == PushTap(sessionID: "abc", type: "approval"))
    #expect(tap?.isApproval == true)
  }

  @Test func tapHasNilTypeWhenMissingOrEmpty() {
    #expect(PushClient.tap(fromPayload: ["session_id": "abc"]) == PushTap(sessionID: "abc", type: nil))
    #expect(PushClient.tap(fromPayload: ["session_id": "abc", "type": ""]) == PushTap(sessionID: "abc", type: nil))
    #expect(PushClient.tap(fromPayload: ["session_id": "abc"])?.isApproval == false)
  }

  @Test func tapIsNilForMalformedPayload() {
    #expect(PushClient.tap(fromPayload: [:]) == nil)
    #expect(PushClient.tap(fromPayload: ["session_id": ""]) == nil)
  }

  // MARK: pure foreground-presentation decision

  @Test func suppressesForegroundOnlyForTheSessionBeingViewed() {
    // Same session in the foreground → suppress (false).
    #expect(PushClient.shouldPresentForeground(
      incomingSessionID: "s1", currentlyViewingSessionID: "s1"
    ) == false)
    // Different session → present.
    #expect(PushClient.shouldPresentForeground(
      incomingSessionID: "s2", currentlyViewingSessionID: "s1"
    ) == true)
    // No chat open → present.
    #expect(PushClient.shouldPresentForeground(
      incomingSessionID: "s1", currentlyViewingSessionID: nil
    ) == true)
    // Malformed incoming (no session) → present (don't silently drop).
    #expect(PushClient.shouldPresentForeground(
      incomingSessionID: nil, currentlyViewingSessionID: "s1"
    ) == true)
  }

  // MARK: testValue (no-op double)

  @Test func testValueDeniesAndYieldsEmptyStreams() async {
    let client = PushClient.testValue
    #expect(await client.requestAuthorization() == false)
    #expect(await client.authorizationStatus() == .notDetermined)
    var tokens: [String] = []
    for await token in client.register() { tokens.append(token) }
    #expect(tokens.isEmpty)
    var taps: [PushTap] = []
    for await tap in client.incomingTaps() { taps.append(tap) }
    #expect(taps.isEmpty)
  }

  // MARK: in-memory authorize flow

  @Test func inMemoryAuthorizeReturnsConfiguredResult() async {
    let granted = PushClient.inMemory(granted: true)
    #expect(await granted.client.requestAuthorization() == true)
    #expect(await granted.client.authorizationStatus() == .authorized)

    let denied = PushClient.inMemory(granted: false, status: .notDetermined)
    #expect(await denied.client.requestAuthorization() == false)
    #expect(await denied.client.authorizationStatus() == .denied)
  }

  // MARK: in-memory register flow (token via AsyncStream)

  @Test func inMemoryRegisterYieldsInjectedToken() async {
    let push = PushClient.inMemory()
    // Retain the stream so it isn't torn down before we emit (per project memory).
    let stream = push.client.register()
    var iterator = stream.makeAsyncIterator()
    push.emit(token: "deadbeef")
    let received = await iterator.next()
    #expect(received == "deadbeef")
  }

  // MARK: in-memory incoming taps

  @Test func inMemoryIncomingTapsDeliversInjectedTap() async {
    let push = PushClient.inMemory()
    let stream = push.client.incomingTaps()
    var iterator = stream.makeAsyncIterator()
    push.emit(tap: PushTap(sessionID: "session-7"))
    let received = await iterator.next()
    #expect(received == PushTap(sessionID: "session-7"))
  }

  // MARK: in-memory badge + current-session spies

  @Test func inMemoryRecordsBadgeCount() async {
    let push = PushClient.inMemory()
    #expect(push.badgeCount == 0)
    await push.client.setBadgeCount(3)
    #expect(push.badgeCount == 3)
    await push.client.setBadgeCount(0)
    #expect(push.badgeCount == 0)
  }

  @Test func inMemoryRecordsCurrentSession() {
    let push = PushClient.inMemory()
    #expect(push.currentSession == nil)
    push.client.setCurrentSession("s9")
    #expect(push.currentSession == "s9")
    push.client.setCurrentSession(nil)
    #expect(push.currentSession == nil)
  }

  // MARK: PushBridge token stream (outside the UIKit guard → testable on macOS)

  /// Collect up to `count` values from `stream`, bailing out after `timeout` with an
  /// EMPTY array (partial values are discarded — the tests only ever compare complete
  /// arrays). A regression (a value never delivered) then FAILS the array comparison
  /// instead of hanging the whole suite on an `iterator.next()` that never resolves.
  private func collect<Value: Sendable>(
    _ count: Int,
    from stream: AsyncStream<Value>,
    timeout: Duration = .seconds(2)
  ) async -> [Value] {
    await withTaskGroup(of: [Value]?.self) { group in
      group.addTask {
        var values: [Value] = []
        for await value in stream {
          values.append(value)
          if values.count == count { break }
        }
        return values
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      // First finisher wins: the collector (complete) or the timeout (partial → `[]`).
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner ?? []
    }
  }

  @Test func bridgeTokenStreamReplaysLastTokenToLateSubscriber() async {
    let bridge = PushBridge()
    // Token arrives BEFORE anyone subscribes (the launch race)…
    bridge.tokenReceived(Data([0xde, 0xad, 0xbe, 0xef]))
    // …the late subscriber still gets the cached token first, then live rotations. The
    // rotation doubles as a sentinel: a broken replay yields ["0ff0"], not a hang.
    let stream = bridge.tokenStream()
    bridge.tokenReceived(Data([0x0f, 0xf0]))
    #expect(await collect(2, from: stream) == ["deadbeef", "0ff0"])
  }

  // MARK: PushBridge tap buffering (cold-launch race, #46)

  @Test func bridgeTapStreamDeliversBufferedTapToFirstSubscriber() async {
    let bridge = PushBridge()
    // Tap arrives BEFORE anyone subscribes (launch-from-push race)…
    bridge.tapReceived(["session_id": "s1", "type": "approval"])
    // …then the first subscriber receives the buffered tap FIRST, ahead of any live
    // follow-up (order is the contract — the consumer's last-wins routing must end on
    // the newest tap). The follow-up doubles as the no-hang sentinel.
    let stream = bridge.tapStream()
    bridge.tapReceived(["session_id": "sentinel"])
    #expect(await collect(2, from: stream) == [
      PushTap(sessionID: "s1", type: "approval"),
      PushTap(sessionID: "sentinel"),
    ])
  }

  @Test func bridgeTapBufferIsConsumeOnce() async {
    let bridge = PushBridge()
    bridge.tapReceived(["session_id": "s1"])
    // The first subscriber drains the buffer…
    let firstStream = bridge.tapStream()
    // …so a later second subscriber must NOT see the stale tap again (re-yielding it
    // would re-navigate). Its first value is the next live tap, used as a sentinel.
    let secondStream = bridge.tapStream()
    bridge.tapReceived(["session_id": "s2"])
    #expect(await collect(2, from: firstStream) == [
      PushTap(sessionID: "s1"), PushTap(sessionID: "s2"),
    ])
    #expect(await collect(1, from: secondStream) == [PushTap(sessionID: "s2")])
  }

  @Test func bridgeTapBufferKeepsOnlyTheNewestTap() async {
    let bridge = PushBridge()
    // Two taps land before anyone subscribes → the buffer is last-wins (a single stale
    // navigation replay; the older tap must never arrive).
    bridge.tapReceived(["session_id": "s1"])
    bridge.tapReceived(["session_id": "s2"])
    let stream = bridge.tapStream()
    bridge.tapReceived(["session_id": "sentinel"])
    // The sentinel occupying slot 2 proves "s1" was dropped, not merely delayed.
    #expect(await collect(2, from: stream) == [
      PushTap(sessionID: "s2"), PushTap(sessionID: "sentinel"),
    ])
  }

  @Test func bridgeTapDeliveredLiveIsNotBuffered() async {
    let bridge = PushBridge()
    // A live subscriber receives the tap directly…
    let liveStream = bridge.tapStream()
    bridge.tapReceived(["session_id": "s1"])
    // …and because it was delivered, it is NOT cached: a new subscriber gets nothing
    // buffered — its first value is the next live tap (sentinel), never the old one.
    let lateStream = bridge.tapStream()
    bridge.tapReceived(["session_id": "s2"])
    #expect(await collect(2, from: liveStream) == [
      PushTap(sessionID: "s1"), PushTap(sessionID: "s2"),
    ])
    #expect(await collect(1, from: lateStream) == [PushTap(sessionID: "s2")])
  }

  @Test func bridgeTapReachesAllLiveSubscribers() async {
    let bridge = PushBridge()
    let streamA = bridge.tapStream()
    let streamB = bridge.tapStream()
    bridge.tapReceived(["session_id": "s1", "type": "complete"])
    let expected = PushTap(sessionID: "s1", type: "complete")
    #expect(await collect(1, from: streamA) == [expected])
    #expect(await collect(1, from: streamB) == [expected])
  }

  /// A subscriber that has TERMINATED (the reducer's `.task` observer being cancelled and
  /// restarted) must not defeat the buffer: without `onTermination` pruning, its dead
  /// continuation would keep `tapContinuations` non-empty forever, so a tap landing in
  /// the re-subscribe gap would be yielded into the void instead of buffered (#46's drop,
  /// resurrected in a narrower window).
  @Test func bridgeTapBufferReengagesAfterSubscriberTermination() async {
    let bridge = PushBridge()
    // A subscriber comes and goes. Dropping the stream deallocates its storage, which
    // fires the continuation's termination synchronously → the bridge prunes it.
    var stream: AsyncStream<PushTap>? = bridge.tapStream()
    _ = stream
    stream = nil
    // No LIVE subscriber remains → this tap must be buffered, not fanned out to the
    // dead continuation.
    bridge.tapReceived(["session_id": "s1"])
    let revived = bridge.tapStream()
    #expect(await collect(1, from: revived) == [PushTap(sessionID: "s1")])
  }

  // MARK: PushBridge delivered pushes (background wake, #138)

  /// A delivered push reaches the live subscribers with its session id and type; a malformed
  /// payload (no session id) is dropped.
  @Test func bridgeDeliveredPushReachesLiveSubscribers() async {
    let bridge = PushBridge()
    let stream = bridge.deliveryStream()
    bridge.pushDelivered(["type": "complete"])
    bridge.pushDelivered(["session_id": "s1", "type": "complete"])
    #expect(await collect(1, from: stream) == [PushTap(sessionID: "s1", type: "complete")])
  }

  /// Unlike a tap, a delivered push is never buffered: one that lands before anyone observes
  /// is gone, and a later subscriber's first value is the next live push.
  @Test func bridgeDeliveredPushIsNotBuffered() async {
    let bridge = PushBridge()
    bridge.pushDelivered(["session_id": "early", "type": "complete"])
    let stream = bridge.deliveryStream()
    bridge.pushDelivered(["session_id": "live", "type": "error"])
    #expect(await collect(1, from: stream) == [PushTap(sessionID: "live", type: "error")])
  }

  /// Only `complete` and `error` end a turn; an approval / clarify push (or none) doesn't.
  @Test func onlyCompleteAndErrorEndATurn() {
    #expect(PushTap(sessionID: "s", type: "complete").endsTurn)
    #expect(PushTap(sessionID: "s", type: "error").endsTurn)
    #expect(!PushTap(sessionID: "s", type: "approval").endsTurn)
    #expect(!PushTap(sessionID: "s", type: "clarify").endsTurn)
    #expect(!PushTap(sessionID: "s").endsTurn)
  }
}
