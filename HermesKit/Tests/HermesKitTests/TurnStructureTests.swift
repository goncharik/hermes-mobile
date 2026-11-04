import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Turn structure (tool-call display plan, Phase A): `turnSpans` splits a transcript into
/// user-delimited turns with their final reply and duration, and `ChatFeature.State` derives
/// the final-reply consumers (action bar, read aloud) and the live-turn indicator row from it.
struct TurnStructureTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func at(_ seconds: TimeInterval?) -> Date? {
    seconds.map { Date(timeIntervalSince1970: 1_000 + $0) }
  }

  private func user(_ n: Int, _ text: String = "q", t: TimeInterval? = nil) -> ChatRow {
    ChatRow(id: uuid(n), kind: .message(role: .user, text: text, isComplete: true), timestamp: at(t))
  }

  private func assistant(
    _ n: Int, _ text: String = "a", complete: Bool = true, t: TimeInterval? = nil
  ) -> ChatRow {
    ChatRow(
      id: uuid(n), kind: .message(role: .assistant, text: text, isComplete: complete), timestamp: at(t)
    )
  }

  private func tool(_ n: Int, t: TimeInterval? = nil) -> ChatRow {
    ChatRow(
      id: uuid(n), kind: .tool(name: "terminal", title: "ls", state: .complete, detail: nil, durationS: nil),
      timestamp: at(t)
    )
  }

  private func reasoning(_ n: Int, complete: Bool = true, t: TimeInterval? = nil) -> ChatRow {
    ChatRow(id: uuid(n), kind: .reasoning(text: "hmm", isComplete: complete), timestamp: at(t))
  }

  // MARK: turnSpans

  @Test func emptyTranscriptHasNoTurns() {
    #expect(turnSpans([ChatRow]()) == [])
    #expect(turnSpans([ChatRow](), runningTurnOrdinal: -1) == [])
  }

  @Test func preambleBeforeTheFirstUserRowIsOrdinalMinusOne() {
    // A branch's seeded reply (no user row): its own span, with that reply as final.
    let rows = [assistant(0, "seed"), user(1), assistant(2)]
    let spans = turnSpans(rows)
    #expect(spans == [
      TurnSpan(ordinal: -1, userRowIndex: nil, rowRange: 0..<1, finalReplyIndex: 0,
               isRunning: false, duration: nil),
      TurnSpan(ordinal: 0, userRowIndex: 1, rowRange: 1..<3, finalReplyIndex: 2,
               isRunning: false, duration: nil),
    ])
  }

  @Test func finalReplyIsTheLastAssistantMessageAfterCommentaryAndTools() {
    let rows = [
      user(0, t: 0), reasoning(1, t: 2), assistant(2, "Let me check.", t: 3), tool(3, t: 10),
      reasoning(4, t: 12), assistant(5, "Found 3 files.", t: 20),
      user(6, t: 30), assistant(7, t: 31),
    ]
    let spans = turnSpans(rows)
    #expect(spans.map(\.ordinal) == [0, 1])
    #expect(spans.map(\.rowRange) == [0..<6, 6..<8])
    #expect(spans.map(\.userRowIndex) == [0, 6])
    #expect(spans.map(\.finalReplyIndex) == [5, 7])
    #expect(spans.map(\.duration) == [20, 1])
  }

  @Test func aRunningTurnHasNoFinalReplyAndNoDuration() {
    let rows = [
      user(0, t: 0), assistant(1, t: 5),
      user(2, t: 10), assistant(3, "Let me check.", t: 11), tool(4, t: 12),
      assistant(5, "Found", complete: false, t: 13),
    ]
    let spans = turnSpans(rows, runningTurnOrdinal: 1)
    #expect(spans.map(\.isRunning) == [false, true])
    #expect(spans.map(\.finalReplyIndex) == [1, nil])
    #expect(spans.map(\.duration) == [5, nil])
  }

  @Test func aRunningPreambleIsTheOnlySpan() {
    let spans = turnSpans([assistant(0, complete: false)], runningTurnOrdinal: -1)
    #expect(spans.count == 1)
    #expect(spans[0].isRunning)
    #expect(spans[0].finalReplyIndex == nil)
  }

  @Test func aToolOnlyTurnHasNoFinalReplyButADuration() {
    let spans = turnSpans([user(0, t: 0), reasoning(1, t: 1), tool(2, t: 4), tool(3, t: 9)])
    #expect(spans.count == 1)
    #expect(spans[0].finalReplyIndex == nil)
    #expect(spans[0].duration == 9)
  }

  @Test func anErroredTurnEndsOnWhateverItLastSaid() {
    // Errored after sealing commentary: that segment is the turn's last word.
    let afterText = turnSpans([user(0), assistant(1, "Let me check."), tool(2)])
    #expect(afterText[0].finalReplyIndex == 1)
    // Errored before any text: no final reply at all.
    let beforeText = turnSpans([user(0), reasoning(1), tool(2)])
    #expect(beforeText[0].finalReplyIndex == nil)
  }

  @Test func statusAndCommandOutputRowsStayInsideTheirTurn() {
    let rows = [
      user(0), ChatRow(id: uuid(1), kind: .commandOutput(text: "model: x")),
      assistant(2), ChatRow(id: uuid(3), kind: .status(kind: "review", text: "Saved a memory")),
    ]
    let spans = turnSpans(rows)
    #expect(spans.count == 1)
    #expect(spans[0].rowRange == 0..<4)
    #expect(spans[0].finalReplyIndex == 2)
  }

  @Test(arguments: [
    // (user stamp, other stamps, expected) — a missing endpoint means "unknown", never 0.
    (TimeInterval?.none, [TimeInterval?](arrayLiteral: 5, 10), TimeInterval?.none),
    (0, [nil, nil], nil),
    (0, [nil, 7], 7),
    (0, [12, 7], 12), // the LATEST stamp, not the last row's
    (30, [10], 0), // clock skew clamps at zero
  ])
  func durationNeedsBothEndpoints(
    userStamp: TimeInterval?, others: [TimeInterval?], expected: TimeInterval?
  ) {
    var rows = [user(0, t: userStamp)]
    for (offset, stamp) in others.enumerated() {
      rows.append(tool(offset + 1, t: stamp))
    }
    #expect(turnSpans(rows)[0].duration == expected)
  }

  @Test func offsetsAreRelativeToASlice() {
    let all = [user(0), assistant(1), user(2), tool(3), assistant(4)]
    let spans = turnSpans(all.dropFirst(2))
    #expect(spans.map(\.rowRange) == [0..<3])
    #expect(spans.map(\.userRowIndex) == [0])
    #expect(spans.map(\.finalReplyIndex) == [2])
    #expect(spans.map(\.ordinal) == [0])
  }

  // MARK: Final-reply consumers on ChatFeature.State

  private var toolTurn: IdentifiedArrayOf<ChatRow> {
    [
      user(0), assistant(1, "Let me check."), tool(2), assistant(3, "Found 3 files."),
      user(4), assistant(5, "On it."), tool(6),
    ]
  }

  @Test func finalReplyRowIDsExcludeCommentaryAndTheRunningTurn() {
    var state = ChatFeature.State(connection: conn, transcript: toolTurn)
    state.isTurnLive = true
    // Turn 0: only its last segment. Turn 1 is running: nothing yet (its "On it." may be
    // commentary — the action bar waits for the turn to end).
    #expect(state.finalReplyRowIDs == [uuid(3)])
    #expect(state.completedReplies.map(\.id) == [uuid(3)])

    state.isTurnLive = false
    // Finished (e.g. errored): the turn's last word is its final reply.
    #expect(state.finalReplyRowIDs == [uuid(3), uuid(5)])
    #expect(state.completedReplyCount == 2)
    #expect(state.completedReplyOrdinal(of: uuid(5)) == 1)
    #expect(state.completedReplyOrdinal(of: uuid(1)) == nil) // commentary is off the scale
  }

  @Test func anIncompleteFinalRowIsAFinalReplyButNotACompletedOne() {
    // An idle slot whose last row never completed (a stale streaming row): the view gates the
    // bar on `isComplete` too, and read aloud never counts it.
    let state = ChatFeature.State(
      connection: conn, transcript: [user(0), assistant(1, "half", complete: false)]
    )
    #expect(state.finalReplyRowIDs == [uuid(1)])
    #expect(state.completedReplyCount == 0)
    #expect(state.lastCompletedReply == nil)
  }

  @Test func aBranchSeedInThePreambleIsAFinalReply() {
    let state = ChatFeature.State(connection: conn, transcript: [assistant(0, "seed")])
    #expect(state.finalReplyRowIDs == [uuid(0)])
  }

  // MARK: Live-turn indicator row

  @Test func aLiveTurnWithoutAnOpenBurstGetsTheIndicatorRow() {
    var state = ChatFeature.State(connection: conn, transcript: [user(0), tool(1)])
    #expect(state.renderedRows.map(\.id) == [uuid(0), uuid(1)]) // idle: none

    state.isTurnLive = true
    let rows = state.renderedRows
    #expect(rows.map(\.id) == [uuid(0), uuid(1), ChatFeature.State.liveTurnIndicatorRowID])
    #expect(rows.last?.kind == .reasoning(text: "", isComplete: false))
    #expect(state.transcript.count == 2) // never stored
  }

  @Test func theOpenBurstCarriesTheIndicatorItself() {
    var state = ChatFeature.State(
      connection: conn, transcript: [user(0), reasoning(1, complete: false)]
    )
    state.isTurnLive = true
    state.reasoningRowID = uuid(1)
    #expect(state.renderedRows.map(\.id) == [uuid(0), uuid(1)])
  }

  @Test func indicatorFollowsTheWindow() {
    var state = ChatFeature.State(connection: conn, transcript: toolTurn)
    state.isTurnLive = true
    state.windowStart = 4
    #expect(state.renderedRows.map(\.id)
      == [uuid(4), uuid(5), uuid(6), ChatFeature.State.liveTurnIndicatorRowID])
  }
}
