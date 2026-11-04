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

  private func reasoning(_ n: Int) -> ChatRow {
    ChatRow(id: uuid(n), kind: .reasoning(text: "hmm"))
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
          + (call.isExpanded ? " open" : "")
      case let .toolBody(row):
        return "body #\(Int(row.id.uuidString.suffix(12), radix: 16)!)"
      case let .row(row):
        return "row #\(Int(row.id.uuidString.suffix(12), radix: 16)!)"
      case .liveIndicator:
        return "live"
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
    #expect(header.finishedTitle == "Worked for 4m 31s")
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
    // A call is running: the live line names it in the present tense.
    let calling = [user(0), assistant(1), tool(2), tool(3, "read_file", running: true)]
    #expect(shape(items(calling, collapsed, running: 0, liveLine: "ಠ_ಠ pondering…")) == [
      "row #0", "header 0 running closed [Reading read_file #3]",
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
    #expect(TurnHeader.liveLabel(" ಠ_ಠ pondering… ") == "ಠ_ಠ pondering…")
    #expect(TurnHeader.liveLabel("  ") == "Working")
    #expect(TurnHeader.liveLabel(nil) == "Working")
  }

  @Test func aTurnWithNothingToFoldHasNoHeader() {
    let rows = [user(0), assistant(1), status(2)]
    #expect(shape(items(rows)) == ["row #0", "row #1", "row #2"])
  }

  @Test func finishedHeaderWithoutAKnownDurationSaysWorked() {
    let result = items([user(0), tool(1), assistant(2)])
    guard case let .turnHeader(header) = result[1] else { Issue.record("no header"); return }
    #expect(header.duration == nil)
    #expect(header.finishedTitle == "Worked")
  }

  @Test func anAbsurdDurationIsClampedNotATrap() {
    let header = TurnHeader(id: UUID(), ordinal: 0, isRunning: false, isExpanded: false, duration: 1e300)
    #expect(header.finishedTitle.hasPrefix("Worked for "))
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

  @Test func aRunningPreambleEndsWithTheLiveIndicator() {
    // No user row to hang a header off: the indicator carries the live label instead.
    #expect(shape(items([assistant(0), tool(1, running: true)], running: -1)) == [
      "row #0", "call 0 #1", "live",
    ])
    #expect(shape(items([], running: -1)) == ["live"])
    // Idle preamble, or a running turn WITH a header: no indicator.
    #expect(shape(items([assistant(0), tool(1)])) == ["row #0", "call 0 #1"])
    #expect(!items([assistant(0), user(1), tool(2)], running: 0).contains(.liveIndicator))
    #expect(TranscriptItem.liveIndicator.id == TranscriptItem.liveIndicatorID)
  }

  @Test(arguments: [
    ("I'm going to bring up the skill now. Then I'll read it.", "I'm going to bring up the skill now."),
    ("  Checking the logs!  Next up", "Checking the logs!"),
    ("Is it 3.5 or 4? Let me see.", "Is it 3.5 or 4?"),
    ("**Planning the fix**\n\nI need to look at the reducer.", "Planning the fix"),
    ("First line without a period\nsecond line", "First line without a period"),
    ("No terminator at all", "No terminator at all"),
    ("Ends with a period.", "Ends with a period."),
    ("   ", ""),
  ])
  func reasoningPreviewIsTheFirstSentence(text: String, preview: String) {
    #expect(TranscriptFold.reasoningPreview(text) == preview)
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

  // MARK: Expanded call bodies

  @Test func anExpandedCallIsFollowedByItsBody() {
    let rows = [user(0), tool(1), assistant(2), tool(3), assistant(4)]
    let open = FoldExpansion(turnOverride: [0: .expanded])
    #expect(shape(items(rows, open)) == [
      "row #0", "header 0 open", "call 0 #1", "row #2", "call 1 #3", "row #4",
    ])
    var expanded = open
    expanded.toggleCall(CallKey(turnOrdinal: 0, callOrdinal: 1))
    let result = items(rows, expanded)
    #expect(shape(result) == [
      "row #0", "header 0 open", "call 0 #1", "row #2", "call 1 #3 open", "body #3", "row #4",
    ])
    // The body carries the call's row (what the view renders), under a derived id.
    #expect(result[5] == .toolBody(tool(3)))
    #expect(result[5].id == TranscriptItem.toolBodyID(callRowID: uuid(3)))

    // Folding it back removes exactly the body item.
    expanded.toggleCall(CallKey(turnOrdinal: 0, callOrdinal: 1))
    #expect(items(rows, expanded) == items(rows, open))
  }

  @Test func bodiesInsideAnExpandedRunFollowTheirCalls() {
    let rows = [user(0), tool(1), reasoning(2), tool(3), tool(4), assistant(5)]
    let expansion = FoldExpansion(
      turnOverride: [0: .expanded], expandedRuns: [RunKey(turnOrdinal: 0, runOrdinal: 0)],
      expandedCalls: [CallKey(turnOrdinal: 0, callOrdinal: 0), CallKey(turnOrdinal: 0, callOrdinal: 2)]
    )
    #expect(shape(items(rows, expansion)) == [
      "row #0", "header 0 open", "run 0 x3 open", "call 0 #1 open", "body #1", "row #2",
      "call 1 #3", "call 2 #4 open", "body #4", "row #5",
    ])
  }

  @Test func aHiddenCallShowsNoBody() {
    let rows = [user(0), tool(1), tool(2), assistant(3)]
    let calls: Set<CallKey> = [CallKey(turnOrdinal: 0, callOrdinal: 0)]
    // A collapsed run hides its calls — and their bodies.
    #expect(shape(items(rows, FoldExpansion(turnOverride: [0: .expanded], expandedCalls: calls))) == [
      "row #0", "header 0 open", "run 0 x2", "row #3",
    ])
    // A collapsed turn hides everything it folds, bodies included.
    #expect(shape(items(rows, FoldExpansion(expandedCalls: calls))) == ["row #0", "header 0 closed", "row #3"])
  }

  @Test func aPreambleCallExpandsInPlaceToo() {
    let rows = [assistant(0), tool(1), user(2), assistant(3)]
    let expansion = FoldExpansion(expandedCalls: [CallKey(turnOrdinal: -1, callOrdinal: 0)])
    #expect(shape(items(rows, expansion)) == ["row #0", "call 0 #1 open", "body #1", "row #2", "row #3"])
  }

  @Test func aLiveCallsBodyFollowsTheRowAsItCompletes() {
    let key = CallKey(turnOrdinal: 0, callOrdinal: 0)
    let expansion = FoldExpansion(expandedCalls: [key])
    let running = items([user(0), tool(1, running: true)], expansion, running: 0)
    let done = items([user(0), tool(1)], expansion, running: 0)
    // Same ids (the cell is reconfigured, not recreated); the body's payload moves on.
    #expect(running.map(\.id) == done.map(\.id))
    #expect(running.last == .toolBody(tool(1, running: true)))
    #expect(done.last == .toolBody(tool(1)))
    #expect(TranscriptItem.toolBodyID(callRowID: uuid(1)) != uuid(1))
    #expect(TranscriptItem.toolBodyID(callRowID: uuid(1)) != TranscriptItem.runSummaryID(firstToolRowID: uuid(1)))
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
}
