import Foundation
import Testing

@testable import HermesKit

/// The categorized run summary (tool-call display plan, Task 11): clause wording, order,
/// single-target naming, the failure clause, live tense, and the run icon.
struct RunSummaryTests {
  // MARK: Fixtures

  private func call(
    _ name: String, args: JSONValue? = nil, result: String? = nil, context: String? = nil,
    running: Bool = false
  ) -> ToolCall {
    ToolCall(
      name: name, title: context ?? name, state: running ? .running : .complete,
      detail: ToolDetail(args: args, resultText: result)
    )
  }

  private func command(_ text: String, running: Bool = false, result: String? = #"{"output": "ok", "exit_code": 0}"#)
    -> ToolCall {
    call("terminal", args: .object(["command": .string(text)]), result: running ? nil : result, running: running)
  }

  private func read(_ path: String, running: Bool = false) -> ToolCall {
    call("read_file", args: .object(["path": .string(path)]), result: running ? nil : #"{"content": "1|x"}"#,
         running: running)
  }

  private func skill(_ name: String) -> ToolCall {
    call("skill_view", args: .object(["name": .string(name)]), result: #"{"success": true}"#)
  }

  private func edit(_ path: String) -> ToolCall {
    call("patch", args: .object(["path": .string(path)]), result: #"{"success": true}"#)
  }

  private func webSearch(_ query: String) -> ToolCall {
    call("web_search", args: .object(["query": .string(query)]), result: #"{"data": {"web": []}}"#)
  }

  private func extract(_ urls: [String]) -> ToolCall {
    call("web_extract", args: .object(["urls": .array(urls.map(JSONValue.string))]), result: #"{"results": []}"#)
  }

  private func text(_ calls: [ToolCall], live: Bool = false) -> String {
    RunSummary.text(calls: calls, live: live)
  }

  // MARK: Reference strings (T3 Code)

  @Test func readsTheReferenceStrings() {
    // Skill first, then a read, then four commands: clauses by first appearance, "other" last.
    #expect(text([skill("asc-crash-triage"), read("/tmp/SKILL.md")] + (0..<4).map { command("ls \($0)") })
      == "Read 1 file, ran 4 commands, and performed 1 other action")
    // A command first: "ran" leads.
    let interleaved = [command("asc crashes")] + (0..<5).flatMap { [read("/tmp/log\($0).txt"), command("cat \($0)")] }
    #expect(text(interleaved) == "Ran 6 commands and read 5 files")
    let readFirst = (0..<3).map { read("/tmp/f\($0)") } + (0..<7).map { command("echo \($0)") }
    #expect(text(readFirst) == "Read 3 files and ran 7 commands")
    #expect(text((0..<6).map { command("gh issue view \($0)") }) == "Ran 6 commands")
  }

  @Test func clauseOrderHoldsWhileTheRunGrows() {
    // The first appearance never moves, so appending calls never reorders the line.
    let base = [command("ls"), read("/a")]
    #expect(text(base) == "Ran 1 command and read 1 file")
    #expect(text(base + [read("/b"), command("pwd")]) == "Ran 2 commands and read 2 files")
    #expect(text(base + [skill("x"), edit("/src/foo.swift")])
      == "Ran 1 command, read 1 file, edited foo.swift, and performed 1 other action")
  }

  // MARK: Single-target clauses

  @Test func aLoneEditSearchOrPageNamesItsTarget() {
    #expect(text([edit("/src/ChatView.swift"), command("swift build")])
      == "Edited ChatView.swift and ran 1 command")
    #expect(text([edit("/a.swift"), edit("/b.swift")]) == "Edited 2 files")
    #expect(text([webSearch("swift testing traits"), command("ls")])
      == "Searched “swift testing traits” and ran 1 command")
    #expect(text([webSearch("a"), webSearch("b")]) == "Searched 2 queries")
    #expect(text([extract(["https://example.com/docs/intro"]), command("ls")])
      == "Read example.com/docs/intro and ran 1 command")
    // web_extract counts its URLs, not its calls.
    #expect(text([extract(["https://a.com", "https://b.com", "https://c.com"]), command("ls")])
      == "Read 3 pages and ran 1 command")
    #expect(text([
      call("browser_navigate", args: .object(["url": .string("https://hermes.dev/start")]),
           result: #"{"success": true}"#),
      call("browser_click", result: #"{"success": true}"#),
    ]) == "Opened hermes.dev/start and performed 1 browser action")
  }

  @Test func commandsReadsAndOtherActionsCountEvenAlone() {
    #expect(text([command("pytest -q"), read("/src/a.swift"), skill("pdf")])
      == "Ran 1 command, read 1 file, and performed 1 other action")
    #expect(text([
      call("search_files", args: .object(["pattern": .string("TODO")]), result: #"{"matches": []}"#),
      call("vision_analyze", args: .object(["question": .string("what?")]), result: #"{"success": true}"#),
      call("delegate_task", args: .object(["goal": .string("fix it")]), result: #"{"success": true}"#),
    ]) == "Explored 1 file, analyzed 1 image, and delegated 1 task")
  }

  @Test func anEditWithoutATargetCounts() {
    // Older agent: name only, nothing to name.
    #expect(text([call("write_file"), command("ls")]) == "Edited 1 file and ran 1 command")
  }

  @Test func olderAgentCallsStillSummarize() {
    // `{name, context}` only — no args, no result.
    #expect(text([call("terminal", context: "ls -la"), call("read_file", context: "/etc/hosts"),
                  call("mystery_tool", context: "x")])
      == "Ran 1 command, read 1 file, and performed 1 other action")
  }

  // MARK: Failure clause

  @Test func failedCallsAreAppended() {
    let failed = call("terminal", args: .object(["command": .string("make")]), result: #"{"error": "boom"}"#)
    #expect(text([command("ls"), failed]) == "Ran 2 commands; 1 tool call failed")
    let failedRead = call("web_extract", args: .object(["url": .string("https://x.dev")]),
                          result: #"{"success": false, "error": "403"}"#)
    #expect(text([command("ls"), failed, failedRead]) == "Ran 2 commands and read x.dev; 2 tool calls failed")
  }

  @Test func noticesAreNotFailures() {
    let missing = call("read_file", args: .object(["path": .string("/nope.txt")]),
                       result: #"{"error": "File not found: /nope.txt"}"#)
    #expect(text([command("ls"), missing]) == "Ran 1 command and read 1 file")
  }

  // MARK: Live tense

  @Test func theRunningCallsClauseReadsInThePresentTense() {
    #expect(text([read("/a"), command("pytest -q", running: true)], live: true)
      == "Read 1 file and running pytest -q")
    #expect(text([command("ls"), command("pytest -q", running: true)], live: true) == "Running 2 commands")
    #expect(text([command("ls"), read("/src/Foo.swift", running: true)], live: true)
      == "Ran 1 command and reading Foo.swift")
    // A live clause of "other" work counts — its title says nothing a count doesn't.
    #expect(text([command("ls"), call("todo", running: true)], live: true)
      == "Ran 1 command and performing 1 other action")
  }

  @Test func aLiveRunWithNothingPendingNarratesItsNewestCall() {
    #expect(text([read("/a"), command("ls")], live: true) == "Read 1 file and running ls")
  }

  @Test func aRunThatIsNotLiveReadsSettledEvenWithARunningCall() {
    // A stopped turn can leave a call `running`; the caller says the run isn't live.
    #expect(text([read("/a"), command("pytest -q", running: true)], live: false)
      == "Read 1 file and ran 1 command")
  }

  // MARK: Join

  @Test func clausesJoinOxfordStyle() {
    #expect(RunSummary.joined([]) == "")
    #expect(RunSummary.joined(["Ran 2 commands"]) == "Ran 2 commands")
    #expect(RunSummary.joined(["Ran 2 commands", "Read 1 file"]) == "Ran 2 commands and read 1 file")
    #expect(RunSummary.joined(["A", "B", "C", "D"]) == "A, b, c, and d")
  }

  // MARK: Icon

  @Test func iconIsTheSharedToolIconOrAHammer() {
    #expect(RunSummary.icon(calls: [command("a"), command("b")]) == .uniform(.terminal))
    #expect(RunSummary.icon(calls: [command("a"), call("execute_code", args: .object(["code": .string("x=1")]))])
      == .uniform(.terminal))
    // Same category, different tool icons → the category's icon.
    #expect(RunSummary.icon(calls: [
      read("/a"), call("search_files", args: .object(["pattern": .string("x")])),
    ]) == .uniform(.file))
    #expect(RunSummary.icon(calls: [command("a"), read("/b")]) == .mixed)
    #expect(RunSummary.icon(calls: []) == .mixed)
  }

  // MARK: Layout wiring

  @Test func layoutMarksTheSummaryLiveOnlyInTheRunningTurn() {
    let rows = [
      ChatRow(id: UUID(), kind: .message(role: .user, text: "go", isComplete: true)),
      ChatRow(id: UUID(), kind: .tool(read("/a"))),
      ChatRow(id: UUID(), kind: .tool(command("pytest -q", running: true))),
    ]
    func summary(running: Int?) -> RunSummary? {
      TranscriptFold.items(
        rows: rows, expansion: FoldExpansion(turnOverride: [0: .expanded]),
        runningTurnOrdinal: running, liveLine: nil
      ).lazy.compactMap { if case let .runSummary(s) = $0 { return s } else { return nil } }.first
    }
    #expect(summary(running: 0)?.isLive == true)
    #expect(summary(running: 0)?.text == "Read 1 file and running pytest -q")
    // The turn stopped with the call still `running`: settled.
    #expect(summary(running: nil)?.isLive == false)
    #expect(summary(running: nil)?.text == "Read 1 file and ran 1 command")
    #expect(summary(running: nil)?.icon == .mixed)
  }

  @Test func layoutMarksCallLinesLiveOnlyInTheRunningTurn() {
    let rows = [
      ChatRow(id: UUID(), kind: .message(role: .user, text: "go", isComplete: true)),
      ChatRow(id: UUID(), kind: .tool(command("pytest -q", running: true))),
    ]
    func callItem(running: Int?) -> ToolCallItem? {
      TranscriptFold.items(
        rows: rows, expansion: FoldExpansion(turnOverride: [0: .expanded]),
        runningTurnOrdinal: running, liveLine: nil
      ).lazy.compactMap { if case let .toolCall(c) = $0 { return c } else { return nil } }.first
    }
    #expect(callItem(running: 0)?.isLive == true)
    #expect(callItem(running: nil)?.isLive == false)
  }

  @Test func collapsedRunningHeaderNamesTheRunningCallInThePresentTense() {
    let rows = [
      ChatRow(id: UUID(), kind: .message(role: .user, text: "go", isComplete: true)),
      ChatRow(id: UUID(), kind: .tool(command("pytest -q", running: true))),
    ]
    let header = TranscriptFold.items(
      rows: rows, expansion: FoldExpansion(turnOverride: [0: .collapsed]),
      runningTurnOrdinal: 0, liveLine: "ಠ_ಠ pondering…"
    ).lazy.compactMap { if case let .turnHeader(h) = $0 { return h } else { return nil } }.first
    #expect(header?.liveLine == "Running pytest -q")
  }
}
