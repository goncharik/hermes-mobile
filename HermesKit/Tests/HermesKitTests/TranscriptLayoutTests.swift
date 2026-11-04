import Foundation
import Testing

@testable import HermesKit

/// The pure turn-fold layout (tool-call display plan, Phase B): `TranscriptFold.items`
/// flattens rows into headers, run summaries, call lines and plain rows per the fold rules.
struct TranscriptLayoutTests {
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func at(_ seconds: TimeInterval?) -> Date? {
    seconds.map { Date(timeIntervalSince1970: 1_000 + $0) }
  }

  private func user(_ n: Int, t: TimeInterval? = nil) -> ChatRow {
    ChatRow(id: uuid(n), kind: .message(role: .user, text: "q\(n)", isComplete: true), timestamp: at(t))
  }

  private func assistant(_ n: Int, complete: Bool = true, t: TimeInterval? = nil) -> ChatRow {
    ChatRow(
      id: uuid(n), kind: .message(role: .assistant, text: "a\(n)", isComplete: complete), timestamp: at(t)
    )
  }

  private func tool(
    _ n: Int, _ name: String = "terminal", running: Bool = false, t: TimeInterval? = nil
  ) -> ChatRow {
    ChatRow(
      id: uuid(n),
      kind: .tool(name: name, title: "\(name) #\(n)", state: running ? .running : .complete,
                  detail: nil, durationS: nil),
      timestamp: at(t)
    )
  }

  private func reasoning(_ n: Int, complete: Bool = true) -> ChatRow {
    ChatRow(id: uuid(n), kind: .reasoning(text: "hmm", isComplete: complete))
  }

  private func status(_ n: Int) -> ChatRow {
    ChatRow(id: uuid(n), kind: .status(kind: "error", text: "boom"))
  }

  private func items(
    _ rows: [ChatRow], _ expansion: FoldExpansion = FoldExpansion(),
    running: Int? = nil, liveLine: String? = nil, offset: Int = 0
  ) -> [TranscriptItem] {
    TranscriptFold.items(
      rows: rows, expansion: expansion, runningTurnOrdinal: running, liveLine: liveLine,
      ordinalOffset: offset
    )
  }

  /// A compact, readable rendering of the items for whole-layout assertions.
  private func shape(_ items: [TranscriptItem]) -> [String] {
    items.map { item in
      switch item {
      case let .turnHeader(header):
        return "header \(header.ordinal)\(header.isRunning ? " running" : "")"
          + (header.isExpanded ? " open" : " closed")
          + (header.liveLine.map { " [\($0)]" } ?? "")
      case let .runSummary(summary):
        return "run \(summary.key.runOrdinal) x\(summary.calls.count)" + (summary.isExpanded ? " open" : "")
      case let .toolCall(call):
        return "call \(call.key.callOrdinal) #\(Int(call.row.id.uuidString.suffix(12), radix: 16)!)"
      case let .row(row):
        return "row #\(Int(row.id.uuidString.suffix(12), radix: 16)!)"
      }
    }
  }

  private var finishedToolTurn: [ChatRow] {
    [
      user(0, t: 0), reasoning(1), assistant(2), tool(3), tool(4, "read_file"),
      reasoning(5), assistant(6, t: 271),
    ]
  }

  // MARK: Turn fold

  @Test func aFinishedTurnIsCollapsedByDefault() {
    let result = items(finishedToolTurn)
    #expect(shape(result) == ["row #0", "header 0 closed", "row #6"])
    guard case let .turnHeader(header) = result[1] else { Issue.record("no header"); return }
    #expect(header.duration == 271)
    #expect(header.title(activityLabel: nil, elapsedSeconds: 0) == "Worked for 4m 31s")
    #expect(header.liveLine == nil)
  }

  @Test func anExpandedOverrideShowsTheFoldedContentAndSurvivesFinish() {
    let expansion = FoldExpansion(turnOverride: [0: .expanded])
    // While running and once finished: the user's last action (expand) wins.
    let running = items(Array(finishedToolTurn.dropLast()), expansion, running: 0)
    #expect(shape(running) == [
      "row #0", "header 0 running open", "row #1", "row #2", "run 0 x2", "row #5",
    ])
    let finished = items(finishedToolTurn, expansion)
    #expect(shape(finished) == [
      "row #0", "header 0 open", "row #1", "row #2", "run 0 x2", "row #5", "row #6",
    ])
  }

  @Test func aCollapsedOverrideOnAFinishedTurnMatchesTheDefault() {
    #expect(items(finishedToolTurn, FoldExpansion(turnOverride: [0: .collapsed])) == items(finishedToolTurn))
  }

  @Test func aRunningTurnIsExpandedByDefault() {
    let rows = [user(0), reasoning(1), tool(2), assistant(3, complete: false)]
    #expect(shape(items(rows, running: 0)) == [
      "row #0", "header 0 running open", "row #1", "call 0 #2", "row #3",
    ])
  }

  @Test func aCollapsedRunningTurnShowsTheLiveLineAndTheStreamingRow() {
    let collapsed = FoldExpansion(turnOverride: [0: .collapsed])
    // A call is running: the live line names it.
    let calling = [user(0), assistant(1), tool(2), tool(3, "read_file", running: true)]
    #expect(shape(items(calling, collapsed, running: 0, liveLine: "ಠ_ಠ pondering…")) == [
      "row #0", "header 0 running closed [read_file #3]",
    ])
    // No call running: the spinner label; the streaming row (maybe the answer) stays visible.
    let streaming = [user(0), tool(1), reasoning(2), assistant(3, complete: false)]
    #expect(shape(items(streaming, collapsed, running: 0, liveLine: " ಠ_ಠ pondering… ")) == [
      "row #0", "header 0 running closed [ಠ_ಠ pondering…]", "row #3",
    ])
    // Neither: no live line.
    #expect(shape(items([user(0), tool(1)], collapsed, running: 0, liveLine: "  ")) == [
      "row #0", "header 0 running closed",
    ])
  }

  @Test func aRunningTurnWithNothingYetStillHasAHeader() {
    let result = items([user(0), assistant(1), user(2)], running: 1)
    #expect(shape(result) == ["row #0", "row #1", "row #2", "header 1 running open"])
    guard case let .turnHeader(header) = result[3] else { Issue.record("no header"); return }
    #expect(header.title(activityLabel: "ಠ_ಠ pondering…", elapsedSeconds: 19) == "ಠ_ಠ pondering… · 19s")
    #expect(header.title(activityLabel: nil, elapsedSeconds: 19) == "Working · 19s")
    #expect(header.title(activityLabel: "  ", elapsedSeconds: 61) == "Working · 1m 1s")
  }

  @Test func aTurnWithNothingToFoldHasNoHeader() {
    let rows = [user(0), assistant(1), status(2)]
    #expect(shape(items(rows)) == ["row #0", "row #1", "row #2"])
  }

  @Test func finishedHeaderWithoutAKnownDurationSaysWorked() {
    let result = items([user(0), tool(1), assistant(2)])
    guard case let .turnHeader(header) = result[1] else { Issue.record("no header"); return }
    #expect(header.duration == nil)
    #expect(header.title(activityLabel: "ignored", elapsedSeconds: 99) == "Worked")
  }

  @Test func statusAndCommandOutputRowsAreNeverFolded() {
    let rows = [
      user(0), ChatRow(id: uuid(1), kind: .commandOutput(text: "model: x")), tool(2),
      status(3), tool(4),
    ]
    // Collapsed (finished, no final reply): only the never-folded rows remain, in order.
    #expect(shape(items(rows)) == ["row #0", "header 0 closed", "row #1", "row #3"])
    // Expanded: the status row splits the calls into two runs of one.
    #expect(shape(items(rows, FoldExpansion(turnOverride: [0: .expanded]))) == [
      "row #0", "header 0 open", "row #1", "call 0 #2", "row #3", "call 1 #4",
    ])
  }

  @Test func aToolOnlyTurnFoldsEverything() {
    let rows = [user(0), reasoning(1), tool(2), tool(3)]
    #expect(shape(items(rows)) == ["row #0", "header 0 closed"])
  }

  @Test func eachTurnFoldsOnItsOwnOrdinal() {
    let rows = [user(0), tool(1), assistant(2), user(3), tool(4), assistant(5)]
    #expect(shape(items(rows, FoldExpansion(turnOverride: [1: .expanded]))) == [
      "row #0", "header 0 closed", "row #2", "row #3", "header 1 open", "call 0 #4", "row #5",
    ])
  }

  @Test func thePreambleIsNeverFolded() {
    let rows = [assistant(0), tool(1), tool(2), user(3), assistant(4)]
    #expect(shape(items(rows)) == ["row #0", "call 0 #1", "call 1 #2", "row #3", "row #4"])
  }

  @Test func ordinalOffsetMakesWindowOrdinalsAbsolute() {
    let window = [user(10), tool(11), assistant(12), user(13), tool(14)]
    let result = items(window, FoldExpansion(turnOverride: [7: .expanded]), running: 8, offset: 7)
    #expect(shape(result) == [
      "row #10", "header 7 open", "call 0 #11", "row #12", "row #13", "header 8 running open", "call 0 #14",
    ])
  }

  // MARK: Runs

  @Test func runsSplitOnAssistantTextAndKeepInnerReasoning() {
    let rows = [
      user(0), tool(1), reasoning(2), tool(3), reasoning(4), assistant(5), tool(6), tool(7),
      tool(8), assistant(9),
    ]
    let expansion = FoldExpansion(
      turnOverride: [0: .expanded], expandedRuns: [RunKey(turnOrdinal: 0, runOrdinal: 1)]
    )
    // Run 0 (#1, #2, #3) is collapsed; the reasoning after its last call (#4) is outside it.
    // Run 1 is expanded: its summary, then its calls with turn-wide call ordinals.
    #expect(shape(items(rows, expansion)) == [
      "row #0", "header 0 open", "run 0 x2", "row #4", "row #5", "run 1 x3 open",
      "call 2 #6", "call 3 #7", "call 4 #8", "row #9",
    ])
  }

  @Test func anExpandedRunListsInnerReasoningBetweenItsCalls() {
    let rows = [user(0), tool(1), reasoning(2), tool(3), assistant(4)]
    let expansion = FoldExpansion(
      turnOverride: [0: .expanded], expandedRuns: [RunKey(turnOrdinal: 0, runOrdinal: 0)]
    )
    #expect(shape(items(rows, expansion)) == [
      "row #0", "header 0 open", "run 0 x2 open", "call 0 #1", "row #2", "call 1 #3", "row #4",
    ])
  }

  @Test func aRunOfOneHasNoSummary() {
    let rows = [user(0), tool(1), assistant(2), tool(3), assistant(4)]
    let result = items(rows, FoldExpansion(turnOverride: [0: .expanded]))
    #expect(shape(result) == ["row #0", "header 0 open", "call 0 #1", "row #2", "call 1 #3", "row #4"])
    #expect(!result.contains { if case .runSummary = $0 { return true } else { return false } })
  }

  @Test func expandedCallsAreFlaggedByCallKey() {
    let rows = [user(0), tool(1), assistant(2)]
    let expansion = FoldExpansion(
      turnOverride: [0: .expanded], expandedCalls: [CallKey(turnOrdinal: 0, callOrdinal: 0)]
    )
    guard case let .toolCall(call) = items(rows, expansion)[2] else { Issue.record("no call"); return }
    #expect(call.isExpanded)
    #expect(call.key == CallKey(turnOrdinal: 0, callOrdinal: 0))
  }

  // MARK: Ids

  @Test func idsAreStableWhileARunGrows() {
    let base = [user(0), assistant(1), tool(2), tool(3)]
    let grown = base + [tool(4, running: true)]
    let before = items(base, running: 0)
    let after = items(grown, running: 0)
    // The header and the run summary keep their ids; only the summary's payload changes.
    #expect(before.map(\.id) == after.map(\.id))
    #expect(before.map(\.id) == [
      uuid(0), TranscriptItem.turnHeaderID(userRowID: uuid(0)), uuid(1),
      TranscriptItem.runSummaryID(firstToolRowID: uuid(2)),
    ])
    guard case let .runSummary(summary) = after[3] else { Issue.record("no summary"); return }
    #expect(summary.calls.count == 3)
    #expect(summary.isLive)

    // A run of one growing to two keeps its RunKey (so an expansion choice carries over).
    let single = items([user(0), tool(1)], running: 0)
    let pair = items([user(0), tool(1), tool(2)], running: 0)
    guard case let .toolCall(call) = single[2], case let .runSummary(run) = pair[2] else {
      Issue.record("unexpected shape"); return
    }
    #expect(call.key.callOrdinal == 0)
    #expect(run.key == RunKey(turnOrdinal: 0, runOrdinal: 0))
  }

  @Test func idsAreStableAcrossReLayout() {
    let expansion = FoldExpansion(
      turnOverride: [0: .expanded], expandedRuns: [RunKey(turnOrdinal: 0, runOrdinal: 0)]
    )
    let first = items(finishedToolTurn, expansion)
    let second = items(finishedToolTurn, expansion)
    #expect(first == second)
    #expect(Set(first.map(\.id)).count == first.count) // unique within a layout
    // Header / summary ids derive from row ids, distinct from them.
    #expect(TranscriptItem.turnHeaderID(userRowID: uuid(0)) != uuid(0))
    #expect(TranscriptItem.runSummaryID(firstToolRowID: uuid(3)) != uuid(3))
    #expect(TranscriptItem.turnHeaderID(userRowID: uuid(3)) != TranscriptItem.runSummaryID(firstToolRowID: uuid(3)))
  }

  // MARK: Expansion defaults

  @Test func turnExpansionDefaultsAndOverrides() {
    let none = FoldExpansion()
    #expect(none.isTurnExpanded(ordinal: 0, isRunning: true))
    #expect(!none.isTurnExpanded(ordinal: 0, isRunning: false))
    let collapsed = FoldExpansion(turnOverride: [0: .collapsed])
    #expect(!collapsed.isTurnExpanded(ordinal: 0, isRunning: true))
    #expect(!collapsed.isTurnExpanded(ordinal: 0, isRunning: false))
    let expanded = FoldExpansion(turnOverride: [0: .expanded])
    #expect(expanded.isTurnExpanded(ordinal: 0, isRunning: true))
    #expect(expanded.isTurnExpanded(ordinal: 0, isRunning: false))
    #expect(!expanded.isTurnExpanded(ordinal: 1, isRunning: false))
  }

  // MARK: Placeholder summary text

  @Test func placeholderSummaryNamesToolsByWireName() {
    func call(_ name: String, running: Bool = false) -> ToolCall {
      ToolCall(name: name, title: name, state: running ? .running : .complete)
    }
    #expect(RunSummary.text(calls: [call("terminal"), call("read_file"), call("terminal")], live: false)
      == "Used 3 tools: terminal, read_file")
    #expect(RunSummary.text(calls: [call("terminal"), call("terminal")], live: true)
      == "Using 2 tools: terminal")
    #expect(RunSummary.text(
      calls: ["a", "b", "c", "d", "e"].map { call($0) }, live: false
    ) == "Used 5 tools: a, b, c, and 2 more")
    let summary = RunSummary(
      id: uuid(1), key: RunKey(turnOrdinal: 0, runOrdinal: 0),
      calls: [call("terminal"), call("read_file", running: true)], isExpanded: false
    )
    #expect(summary.isLive)
    #expect(summary.text == "Using 2 tools: terminal, read_file")
  }
}
