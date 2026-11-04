import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// The turn fold (tool-call display plan, Phase B): headers, run summaries, call lines and
/// reasoning lines, laid out by `TranscriptFold.items` and rendered cell by cell through the
/// real `ChatView.itemView` — the same builder the collection view hosts — in a plain `VStack`
/// (component render; no scroll view, so nothing to pin). Light + dark.
final class TurnFoldSnapshotTests: SnapshotTestCase {
  private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

  private func tool(
    _ n: Int, _ name: String, _ title: String, args: [String: JSONValue]? = nil, result: String? = nil,
    running: Bool = false
  ) -> ChatRow {
    ChatRow(
      id: id(n),
      kind: .tool(
        name: name, title: title, state: running ? .running : .complete,
        detail: ToolDetail(argsText: title, args: args.map(JSONValue.object), resultText: result),
        durationS: running ? nil : 0.4
      ),
      timestamp: at(Double(n) * 10)
    )
  }

  /// A long agent turn in the T3 reference's shape: reasoning, a run of three calls with a
  /// reasoning burst between them, interim commentary, one more call, then the final reply.
  private var turnRows: [ChatRow] {
    [
      ChatRow(id: id(0), kind: .message(role: .user, text: "Triage the new TestFlight crashes.",
                                        isComplete: true), timestamp: at(0)),
      ChatRow(id: id(1), kind: .reasoning(
        text: "I'm going to bring up the asc-crash-triage skill now. It lists crashes per build."
      )),
      tool(2, "skill_view", "skill_view", args: ["name": .string("asc-crash-triage")]),
      tool(3, "terminal", "asc testflight crashes --app 6740 --limit 20 2>&1 | head -40",
           result: #"{"error": "unknown flag: --limit"}"#),
      ChatRow(id: id(4), kind: .reasoning(
        text: "**Checking the newest items first**\n\nThe Nov 3 crashes, then feedback."
      )),
      tool(5, "read_file", "/Users/eugene/Documents/Development/Personal/hermes-mobile/ChatFeature.swift"),
      ChatRow(id: id(6), kind: .message(
        role: .assistant,
        text: "Pulled the crash and feedback lists. Now I'm fetching the individual crash logs.",
        isComplete: true
      ), timestamp: at(60)),
      tool(7, "terminal", "gh issue list --label crash"),
    ]
  }

  private var finalReply: ChatRow {
    ChatRow(id: id(8), kind: .message(
      role: .assistant,
      text: "I went through all 17 crash reports and opened five new GitHub issues.",
      isComplete: true
    ), timestamp: at(271))
  }

  private func store(configure: (inout ChatFeature.State) -> Void = { _ in }) -> StoreOf<ChatFeature> {
    var state = ChatFeature.State(
      connection: connection,
      resumeStoredID: "snapshot-session",
      title: "Fold",
      transcript: [],
      status: .ready
    )
    configure(&state)
    return Store(initialState: state) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
      $0.continuousClock = ImmediateClock()
    }
  }

  /// Render `items` through `ChatView.itemView`, both appearances.
  private func assertFold(
    _ items: [TranscriptItem],
    finalReplyIDs: Set<ChatRow.ID> = [],
    configure: (inout ChatFeature.State) -> Void = { _ in },
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    let chat = ChatView(store: store(configure: configure))
    let view = VStack(alignment: .leading, spacing: 10) {
      ForEach(items) { item in
        chat.itemView(item, finalReplyIDs: finalReplyIDs)
      }
    }
    .padding()
    .frame(width: device.size?.width ?? 390)
    .background(Color(uiColor: .systemBackground))
    for appearance in [UIUserInterfaceStyle.dark, .light] {
      assertSnapshot(
        of: view, as: componentImage(appearance: appearance),
        named: appearance == .dark ? "dark" : "light",
        file: file, testName: testName, line: line
      )
    }
  }

  private func finishedItems(_ expansion: FoldExpansion) -> [TranscriptItem] {
    TranscriptFold.items(
      rows: turnRows + [finalReply], expansion: expansion, runningTurnOrdinal: nil, liveLine: nil
    )
  }

  private func liveItems(_ expansion: FoldExpansion) -> [TranscriptItem] {
    var rows = turnRows
    rows[7] = tool(7, "terminal", "gh issue list --label crash", running: true)
    return TranscriptFold.items(
      rows: rows, expansion: expansion, runningTurnOrdinal: 0, liveLine: "ಠ_ಠ pondering…"
    )
  }

  private func live(_ state: inout ChatFeature.State) {
    state.turnSeconds = 19
    state.turnActivityLabel = "ಠ_ಠ pondering…"
    state.turnStatus = "Context: 42% used (84k / 200k tokens)"
  }

  /// `[user] [Worked for 4m 31s ›] [reply]` — the whole turn behind one line.
  func testFinishedTurn_collapsed() {
    assertFold(finishedItems(FoldExpansion()), finalReplyIDs: [id(8)])
  }

  /// Expanded: reasoning line, a collapsed run summary, the interim commentary as body text,
  /// a single call line, then the reply.
  func testFinishedTurn_expanded() {
    assertFold(finishedItems(FoldExpansion(turnOverride: [0: .expanded])), finalReplyIDs: [id(8)])
  }

  /// An expanded run lists its calls, with the reasoning burst between them.
  func testRunSummary_expanded() {
    assertFold(
      finishedItems(FoldExpansion(
        turnOverride: [0: .expanded], expandedRuns: [RunKey(turnOrdinal: 0, runOrdinal: 0)]
      )),
      finalReplyIDs: [id(8)]
    )
  }

  /// Run summary variants: a command-only run (terminal icon), a mixed run (hammer), a run
  /// with a failed call, a single named edit, and a live run narrating its running call.
  func testRunSummaries() {
    func command(_ text: String, running: Bool = false, failed: Bool = false) -> ToolCall {
      ToolCall(
        name: "terminal", title: text, state: running ? .running : .complete,
        detail: ToolDetail(
          args: .object(["command": .string(text)]),
          resultText: running ? nil : (failed ? #"{"error": "exit 2"}"# : #"{"output": "ok", "exit_code": 0}"#)
        )
      )
    }
    func read(_ path: String) -> ToolCall {
      ToolCall(name: "read_file", title: path, state: .complete,
               detail: ToolDetail(args: .object(["path": .string(path)]), resultText: #"{"content": "1|x"}"#))
    }
    let edit = ToolCall(name: "patch", title: "patch", state: .complete,
                        detail: ToolDetail(args: .object(["path": .string("/src/ChatView.swift")]),
                                           resultText: #"{"success": true}"#))
    let runs: [(calls: [ToolCall], live: Bool)] = [
      ((0..<6).map { command("gh issue view \($0)") }, false),
      ([command("asc crashes")] + (0..<5).flatMap { [read("/tmp/log\($0).txt"), command("cat \($0)")] }, false),
      ([command("make"), command("make test", failed: true), read("/src/Makefile")], false),
      ([edit, command("swift build")], false),
      ([read("/src/Feature.swift"), command("pytest -q", running: true)], true),
    ]
    let view = VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
        RunSummaryView(summary: RunSummary(
          id: self.id(index), key: RunKey(turnOrdinal: 0, runOrdinal: index), calls: run.calls,
          isExpanded: false, isLive: run.live
        )) {}
      }
    }
    .padding()
    .frame(width: device.size?.width ?? 390)
    .background(Color(uiColor: .systemBackground))
    for appearance in [UIUserInterfaceStyle.dark, .light] {
      assertSnapshot(
        of: view, as: componentImage(appearance: appearance),
        named: appearance == .dark ? "dark" : "light"
      )
    }
  }

  /// A running turn, expanded by default: live label + timer + status caption over the fold.
  func testLiveTurn_expanded() {
    assertFold(liveItems(FoldExpansion()), configure: live)
  }

  /// A running turn the user collapsed: the header plus one live line naming the running call.
  func testLiveTurn_collapsed() {
    assertFold(liveItems(FoldExpansion(turnOverride: [0: .collapsed])), configure: live)
  }

  /// A running turn with no user row of ours (a branch seed's turn): the headerless indicator.
  func testLiveIndicator_noHeader() {
    let seed = ChatRow(id: id(1), kind: .message(
      role: .assistant, text: "Seeded from the branch point.", isComplete: true
    ))
    let items = TranscriptFold.items(
      rows: [seed], expansion: FoldExpansion(), runningTurnOrdinal: -1, liveLine: nil
    )
    assertFold(items, configure: live)
  }

  /// A reasoning line: first sentence, then the full text once disclosed.
  func testReasoningLine() {
    let text = """
    **Planning the fix**

    The reducer folds every tool row into the turn. I need to check how the window snaps \
    before touching the renderer, then verify the hydrate keeps the fold choices.
    """
    let view = VStack(alignment: .leading, spacing: 10) {
      ReasoningLineView(text: text)
      ReasoningLineView(text: text, initiallyExpanded: true)
    }
    .padding()
    .frame(width: device.size?.width ?? 390)
    .background(Color(uiColor: .systemBackground))
    for appearance in [UIUserInterfaceStyle.dark, .light] {
      assertSnapshot(
        of: view, as: componentImage(appearance: appearance),
        named: appearance == .dark ? "dark" : "light"
      )
    }
  }
}
