import Foundation
import Testing

@testable import HermesKit

struct LaunchIntentClientTests {
  /// Collect up to `count` values from `stream`, bailing out after `timeout` with an EMPTY
  /// array, so a value that is never delivered fails the comparison instead of hanging the
  /// suite. Mirrors the helper in `PushClientTests`.
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
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner ?? []
    }
  }

  // MARK: Client double

  @Test func testValueYieldsAFinishedStream() async {
    var values: [LaunchIntent] = []
    for await value in LaunchIntentClient.testValue.incoming() { values.append(value) }
    #expect(values.isEmpty)
  }

  // MARK: LaunchIntentBridge buffering (cold-launch race)

  @Test func bridgeDeliversIntentReceivedBeforeSubscriptionToFirstSubscriberOnly() async {
    let bridge = LaunchIntentBridge()
    // The intent performs BEFORE the reducer subscribes (cold launch from an intent)…
    bridge.received(.newChatWithDictation)
    // …the first subscriber gets it ahead of any live follow-up…
    let first = bridge.stream()
    // …and a second subscriber must NOT see it again (consume-once). Its first value is the
    // next live intent, used as a sentinel.
    let second = bridge.stream()
    bridge.received(.newChat)
    #expect(await collect(2, from: first) == [.newChatWithDictation, .newChat])
    #expect(await collect(1, from: second) == [.newChat])
  }

  @Test func bridgeBufferKeepsOnlyTheNewestIntent() async {
    let bridge = LaunchIntentBridge()
    bridge.received(.newChat)
    bridge.received(.newChatWithDictation)
    let stream = bridge.stream()
    bridge.received(.newChat)
    // The sentinel in slot 2 proves the older buffered intent was dropped, not delayed.
    #expect(await collect(2, from: stream) == [.newChatWithDictation, .newChat])
  }

  @Test func bridgeIntentDeliveredLiveIsNotBuffered() async {
    let bridge = LaunchIntentBridge()
    let live = bridge.stream()
    bridge.received(.newChatWithDictation)
    // Delivered live, so nothing is cached: a late subscriber's first value is the next live
    // intent, never the old one.
    let late = bridge.stream()
    bridge.received(.newChat)
    #expect(await collect(2, from: live) == [.newChatWithDictation, .newChat])
    #expect(await collect(1, from: late) == [.newChat])
  }

  @Test func bridgeReachesAllLiveSubscribers() async {
    let bridge = LaunchIntentBridge()
    let streamA = bridge.stream()
    let streamB = bridge.stream()
    bridge.received(.newChat)
    #expect(await collect(1, from: streamA) == [.newChat])
    #expect(await collect(1, from: streamB) == [.newChat])
  }

  /// A terminated subscriber (the reducer's `.task` observer being cancelled and restarted)
  /// must not defeat the buffer: an intent sent in the re-subscribe gap is buffered again.
  @Test func bridgeBuffersAgainAfterSubscriberTermination() async {
    let bridge = LaunchIntentBridge()
    // Dropping the stream terminates its continuation, so a yield to it is not `.enqueued`.
    // This checks the re-buffer only, not that the dead entry is pruned.
    var stream: AsyncStream<LaunchIntent>? = bridge.stream()
    _ = stream
    stream = nil
    bridge.received(.newChatWithDictation)
    let revived = bridge.stream()
    #expect(await collect(1, from: revived) == [.newChatWithDictation])
  }
}
