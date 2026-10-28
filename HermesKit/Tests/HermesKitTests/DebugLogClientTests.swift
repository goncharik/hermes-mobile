import Foundation
import Testing

@testable import HermesKit

struct DebugLogClientTests {
  @Test func appendAccumulatesSnapshotWithSequentialIDsAndSummaries() {
    let log = DebugLogClient.ringBuffer()
    log.append(.ready)
    log.append(.messageDelta(text: "Hello"))

    let entries = log.snapshot()
    #expect(entries.map(\.id) == [0, 1])
    #expect(entries.map(\.type) == ["gateway.ready", "message.delta"])
    #expect(entries[1].summary == "Hello")
  }

  @Test func noteSharesTheRingAndDigestWithEvents() {
    // A free-text client note (#98's swallowed replay failure) takes the next id in the same
    // buffer and the same collapsed, truncated summary as an event entry.
    let log = DebugLogClient.ringBuffer()
    log.append(.ready)
    log.note("session.events.since", "unknown method\n" + String(repeating: "x", count: 100))

    let entries = log.snapshot()
    #expect(entries.map(\.id) == [0, 1])
    #expect(entries.map(\.type) == ["gateway.ready", "session.events.since"])
    #expect(entries[1].summary.hasPrefix("unknown method⏎xxx"))
    #expect(entries[1].summary.count == 81) // 80-char preview + ellipsis
  }

  @Test func ringBufferCapsToCapacity() {
    let log = DebugLogClient.ringBuffer(capacity: 3)
    for _ in 0..<5 { log.append(.ready) }

    let entries = log.snapshot()
    #expect(entries.count == 3)
    // Oldest dropped: ids should be the last three appended.
    #expect(entries.map(\.id) == [2, 3, 4])
  }

  @Test func streamPrimesWithCurrentSnapshotThenBroadcastsAppends() async {
    let log = DebugLogClient.ringBuffer()
    log.append(.ready) // present before subscribing

    var iterator = log.stream().makeAsyncIterator()
    let primed = await iterator.next()
    #expect(primed?.map(\.type) == ["gateway.ready"])

    log.append(.error(message: "boom"))
    let next = await iterator.next()
    #expect(next?.map(\.type) == ["gateway.ready", "error"])
    #expect(next?.last?.summary == "boom")
  }

  @Test func multilineSummaryIsCollapsedAndTruncated() {
    let log = DebugLogClient.ringBuffer()
    log.append(.messageComplete(text: "line one\nline two", usage: nil))
    #expect(log.snapshot().last?.summary == "line one⏎line two")
  }

  @Test func reviewSummaryEntryUsesWireTypeAndTruncatesLongText() {
    // A real review summary is exactly the long, multi-line payload the 80-char digest
    // truncation exists for — pin the wire-style type label and the collapsed preview.
    let log = DebugLogClient.ringBuffer()
    let text = "💾 Self-improvement review:\n" + String(repeating: "tightened the retry loop. ", count: 10)
    log.append(.reviewSummary(text: text))

    let entry = log.snapshot().last
    #expect(entry?.type == "review.summary")
    #expect(entry?.summary.hasPrefix("💾 Self-improvement review:⏎tightened") == true)
    #expect(entry?.summary.hasSuffix("…") == true)
    #expect(entry?.summary.count == 81) // 80-char preview + ellipsis
  }
}
