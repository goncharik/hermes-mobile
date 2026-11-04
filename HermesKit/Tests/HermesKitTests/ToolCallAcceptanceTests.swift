import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Tool-call display plan, Task 14: end-to-end checks for the acceptance criteria the per-task
/// suites only cover piecewise — a 15-call turn driven through real gateway events (#55), every
/// listed tool's body (#45), a reloaded session through decode → reconstruct → layout →
/// presentation, and an older agent's live turn (no `args`, no `message.interim`).
@MainActor
struct ToolCallAcceptanceTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  private nonisolated static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

  private let userID = UUID(uuidString: "00000000-0000-0000-0003-000000000000")!

  private func makeStore(
    _ rows: [ChatRow], now: LockIsolated<Date>
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, transcript: IdentifiedArrayOf(uniqueElements: rows))
    ) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = DateGenerator { now.value }
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off
    return store
  }

  private func headers(_ items: [TranscriptItem]) -> [TurnHeader] {
    items.compactMap { if case let .turnHeader(header) = $0 { return header } else { return nil } }
  }

  private func summaries(_ items: [TranscriptItem]) -> [RunSummary] {
    items.compactMap { if case let .runSummary(summary) = $0 { return summary } else { return nil } }
  }

  // MARK: #55 — a 15-call finished turn is [user][Worked for …][reply]

  @Test func aFifteenCallFinishedTurnFoldsToUserHeaderAndReply() async {
    let now = LockIsolated(Self.at(0))
    let question = ChatRow(
      id: userID, kind: .message(role: .user, text: "Fix the tests", isComplete: true), timestamp: Self.at(0)
    )
    let store = makeStore([question], now: now)

    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.spinnerFrame(text: "ಠ_ಠ pondering…")))
    await store.send(.gatewayEvent(.reasoningDelta(text: "Look at the failing suite first.")))
    await store.send(.gatewayEvent(.messageDelta(text: "Let me look")))
    await store.send(.gatewayEvent(.messageInterim(
      text: "Let me look at the tests.", alreadyStreamed: true, turnID: "turn-1", segment: 0
    )))
    for index in 0..<15 {
      now.setValue(Self.at(TimeInterval(10 + index * 15)))
      let isCommand = index.isMultiple(of: 2)
      let args: JSONValue = isCommand
        ? .object(["command": .string("swift test --filter Suite\(index)")])
        : .object(["path": .string("/repo/Sources/File\(index).swift")])
      await store.send(.gatewayEvent(.toolStart(
        toolID: "t\(index)", name: isCommand ? "terminal" : "read_file", title: nil, argsText: nil, args: args
      )))
      if index == 7 { await store.send(.gatewayEvent(.reasoningDelta(text: "Halfway there."))) }
      await store.send(.gatewayEvent(.toolComplete(
        toolID: "t\(index)", name: nil, title: nil, args: nil, resultText: nil, inlineDiff: nil, durationS: 1,
        result: isCommand ? .object(["output": .string("ok"), "exit_code": .number(0)])
          : .object(["content": .string("1|x")])
      )))
    }
    now.setValue(Self.at(270))
    await store.send(.gatewayEvent(.messageDelta(text: "All green")))
    now.setValue(Self.at(271))
    await store.send(.gatewayEvent(.messageComplete(text: "All green.", usage: nil)))

    let reply = store.state.transcript.last
    #expect(reply?.kind == .message(role: .assistant, text: "All green.", isComplete: true))
    #expect(store.state.transcript.filter { if case .tool = $0.kind { true } else { false } }.count == 15)

    // Collapsed by default: three items, the reply directly under the header — on screen
    // without scrolling past any tool activity.
    let items = store.state.transcriptItems
    #expect(items.map(\.id) == [userID, TranscriptItem.turnHeaderID(userRowID: userID), reply?.id])
    let header = headers(items).first
    #expect(header?.isRunning == false)
    #expect(header?.finishedTitle == "Worked for 4m 31s")

    // Expanded, the commentary is its own row and the 15 calls are ONE summary line (the
    // reasoning between calls stays inside the run).
    await store.send(.turnHeaderTapped(0))
    let expanded = store.state.transcriptItems
    #expect(summaries(expanded).map(\.calls.count) == [15])
    #expect(summaries(expanded).first?.text == "Ran 8 commands and read 7 files")
    #expect(expanded.contains { $0.id == store.state.transcript[1].id }) // turn-opening reasoning
    #expect(expanded.last?.id == reply?.id)
    // Spinner frames never became reasoning text.
    for row in store.state.transcript {
      if case let .reasoning(text, _) = row.kind { #expect(!text.contains("pondering")) }
    }

    await store.send(.teardown)
  }

  // MARK: #45 — every listed tool renders its body

  private struct BodyCase: Sendable, CustomTestStringConvertible {
    let name: String
    let args: String
    let result: String?
    var inlineDiff: String?
    let kind: String
    var testDescription: String { name }
  }

  private nonisolated static let bodyCases: [BodyCase] = [
    BodyCase(name: "terminal", args: #"{"command": "pytest -q"}"#,
             result: #"{"output": "3 passed", "exit_code": 0}"#, kind: "terminal"),
    BodyCase(name: "execute_code", args: #"{"code": "print(1)"}"#, result: #"{"output": "1"}"#, kind: "terminal"),
    BodyCase(name: "read_file", args: #"{"path": "/repo/a.swift", "offset": 10, "limit": 5}"#,
             result: #"{"content": "10|let x = 1"}"#, kind: "fileRead"),
    BodyCase(name: "write_file", args: #"{"path": "a.txt", "content": "x"}"#, result: #"{"success": true}"#,
             inlineDiff: "--- a/a.txt\n+++ b/a.txt\n@@ -0,0 +1 @@\n+x", kind: "diff"),
    BodyCase(name: "patch", args: #"{"path": "a.txt"}"#,
             result: #"{"success": true, "diff": "--- a/a.txt\n+++ b/a.txt\n-a\n+b"}"#, kind: "diff"),
    BodyCase(name: "edit_file", args: #"{"path": "a.txt"}"#, result: #"{"success": true}"#,
             inlineDiff: "--- a/a.txt\n+++ b/a.txt\n-a\n+b", kind: "diff"),
    BodyCase(name: "search_files", args: #"{"pattern": "TODO"}"#,
             result: #"{"total_count": 1, "matches": [{"path": "a.swift", "line": 3, "content": "// TODO"}]}"#,
             kind: "search"),
    BodyCase(name: "web_search", args: #"{"query": "swift testing"}"#,
             result: #"{"data": {"web": [{"title": "T", "url": "https://x.dev", "description": "d"}]}}"#,
             kind: "search"),
    BodyCase(name: "web_extract", args: #"{"urls": ["https://x.dev/a"]}"#,
             result: #"{"results": [{"url": "https://x.dev/a", "content": "Page text"}]}"#, kind: "webPage"),
    BodyCase(name: "browser_navigate", args: #"{"url": "https://x.dev"}"#, result: #"{"success": true}"#,
             kind: "webPage"),
    BodyCase(name: "vision_analyze", args: #"{"question": "what is it?"}"#,
             result: #"{"success": true, "analysis": "A cat."}"#, kind: "generic"),
    BodyCase(name: "skill_view", args: #"{"name": "swift-style"}"#,
             result: #"{"success": true, "description": "House style"}"#, kind: "skill"),
    BodyCase(name: "delegate_task", args: #"{"tasks": [{"goal": "Write docs"}, {"goal": "Add tests"}]}"#,
             result: #"{"success": true}"#, kind: "delegate"),
    BodyCase(name: "frobnicate_widget", args: #"{"widget": "w1"}"#, result: #"{"frobbed": 3}"#, kind: "generic"),
  ]

  private static func json(_ text: String?) -> JSONValue? {
    text.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
  }

  private static func kind(_ body: ToolPresentation.Body) -> String {
    switch body {
    case .terminal: "terminal"
    case .diff: "diff"
    case .fileRead: "fileRead"
    case .search: "search"
    case .webPage: "webPage"
    case .skill: "skill"
    case .delegate: "delegate"
    case .generic: "generic"
    case .unavailable: "unavailable"
    }
  }

  @Test(arguments: bodyCases)
  private func everyListedToolRendersItsBody(_ testCase: BodyCase) {
    let call = ToolCall(
      name: testCase.name, title: testCase.name, state: .complete,
      detail: ToolDetail(
        args: Self.json(testCase.args), result: Self.json(testCase.result), resultText: testCase.result,
        inlineDiff: testCase.inlineDiff
      )
    )
    let presentation = ToolPresentation(call: call)
    #expect(Self.kind(presentation.body) == testCase.kind)
    // Every call line carries a real title, never an empty string.
    #expect(!presentation.settledTitle.isEmpty)
    // The sheet's Raw section keeps the args and the result verbatim-in-substance.
    let raw = call.rawSections.map(\.text).joined(separator: "\n")
    if case let .object(record)? = Self.json(testCase.args), let firstArgKey = record.keys.sorted().first {
      #expect(raw.contains(firstArgKey))
    }
  }

  @Test func theUnknownToolKeepsItsResultAndHumanizesItsName() {
    let presentation = ToolPresentation(
      name: "frobnicate_widget", args: Self.json(#"{"widget": "w1"}"#), result: Self.json(#"{"frobbed": 3}"#),
      resultText: nil, inlineDiff: nil, context: "w1"
    )
    #expect(presentation.settledTitle == "Frobnicate widget: w1")
    guard case let .generic(_, raw) = presentation.body else { Issue.record("not generic"); return }
    #expect(raw?.contains("frobbed") == true)
  }

  // MARK: #45 — a reloaded session: targets + edit diffs survive, live-only output doesn't

  private static let reloadedHistoryJSON = """
  [
    {"role": "user", "text": "fix it", "timestamp": 1700000000},
    {"role": "assistant", "text": "On it.", "timestamp": 1700000001},
    {"role": "tool", "name": "terminal", "context": "pytest -q",
     "args": {"command": "pytest -q"}, "timestamp": 1700000002},
    {"role": "tool", "name": "read_file", "context": "/repo/Sources/A.swift",
     "args": {"path": "/repo/Sources/A.swift"}, "timestamp": 1700000003},
    {"role": "tool", "name": "patch", "context": "/repo/Sources/A.swift",
     "args": {"path": "/repo/Sources/A.swift", "old_string": "a", "new_string": "b"},
     "content": "{\\"success\\": true}", "timestamp": 1700000004,
     "display_metadata": {"tool_result_metadata": {
       "inline_diff": "--- a/Sources/A.swift\\n+++ b/Sources/A.swift\\n@@ -1 +1 @@\\n-a\\n+b"}}},
    {"role": "tool", "name": "web_search", "context": "swift testing",
     "args": {"query": "swift testing"}, "timestamp": 1700000005},
    {"role": "assistant", "text": "Fixed.", "timestamp": 1700000095}
  ]
  """

  @Test func aReloadedSessionShowsTargetsEditDiffsAndUnavailableOutput() throws {
    let messages = try JSONDecoder().decode([SessionMessage].self, from: Data(Self.reloadedHistoryJSON.utf8))
    let rows = reconstructTranscript(messages)
    let calls = rows.compactMap { if case let .tool(call) = $0.kind { call } else { nil } }
    let presentations = calls.map(ToolPresentation.init(call:))

    // Targets survive the reload.
    #expect(presentations.map(\.settledTitle) == [
      "Ran pytest -q", "Read A.swift", "Edited A.swift", "Searched “swift testing”",
    ])
    // The edit's diff survives; output-only tools say it isn't kept.
    guard case let .diff(path, lines) = presentations[2].body else { Issue.record("no diff"); return }
    #expect(path == "Sources/A.swift")
    #expect(lines.map(\.kind).contains(.added))
    #expect(lines.map(\.kind).contains(.removed))
    for index in [0, 1, 3] {
      #expect(presentations[index].body == .unavailable(note: ToolPresentation.unavailableNote))
    }
    // No result → no false success or failure.
    #expect(presentations[0].outcome == .unknown)

    // The fold: a collapsed header timed from the server stamps, then the reply.
    let items = TranscriptFold.items(
      rows: rows, expansion: FoldExpansion(), runningTurnOrdinal: nil, liveLine: nil
    )
    #expect(items.map(\.id) == [rows[0].id, TranscriptItem.turnHeaderID(userRowID: rows[0].id), rows.last?.id])
    #expect(headers(items).first?.finishedTitle == "Worked for 1m 35s")
  }

  // MARK: Older agent — no `args`, no `message.interim`, cooked `{name, context}` only

  @Test func anOlderAgentsLiveTurnStillRendersSensibly() async {
    let now = LockIsolated(Self.at(0))
    let question = ChatRow(
      id: userID, kind: .message(role: .user, text: "List files", isComplete: true), timestamp: Self.at(0)
    )
    let store = makeStore([question], now: now)

    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.messageDelta(text: "Checking.")))
    now.setValue(Self.at(2))
    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "terminal", title: "ls -la", argsText: nil)))
    now.setValue(Self.at(3))
    await store.send(.gatewayEvent(.toolComplete(
      toolID: "t1", name: "terminal", title: nil, args: nil, resultText: "total 0", inlineDiff: nil, durationS: 1
    )))
    now.setValue(Self.at(5))
    await store.send(.gatewayEvent(.messageDelta(text: " Empty.")))
    await store.send(.gatewayEvent(.messageComplete(text: "Checking. Empty.", usage: nil)))

    // No interim seal: one assistant row (commentary + answer, as before), never duplicated.
    let assistants = store.state.transcript.filter {
      if case .message(.assistant, _, _) = $0.kind { true } else { false }
    }
    #expect(assistants.map(\.copyText) == ["Checking. Empty."])
    #expect(store.state.finalReplyRowIDs == [assistants[0].id])

    // The tool still renders from its context title and plain result text.
    guard case let .tool(call)? = store.state.transcript.first(where: {
      if case .tool = $0.kind { true } else { false }
    })?.kind else { Issue.record("no tool row"); return }
    let presentation = ToolPresentation(call: call)
    #expect(presentation.settledTitle == "Ran ls -la")
    #expect(presentation.body == .terminal(command: "ls -la", exitCode: nil, stdout: "total 0", stderr: nil))

    // Collapsed: the header and the reply; expanded, the call line is there too.
    let items = store.state.transcriptItems
    #expect(items.map(\.id) == [userID, TranscriptItem.turnHeaderID(userRowID: userID), assistants[0].id])
    #expect(headers(items).first?.finishedTitle == "Worked for 5s")
    await store.send(.turnHeaderTapped(0))
    #expect(store.state.transcriptItems.contains {
      if case let .toolCall(item) = $0 { item.row.kind == .tool(call) } else { false }
    })

    await store.send(.teardown)
  }

  @Test func anOlderAgentsReloadedSessionStillRendersSensibly() {
    let rows = reconstructTranscript([
      SessionMessage(id: 1, role: "user", content: "fix it"),
      SessionMessage(id: 2, role: "tool", name: "terminal", context: "pytest -q"),
      SessionMessage(id: 3, role: "tool", name: "read_file", context: "/repo/Sources/A.swift"),
      SessionMessage(id: 4, role: "tool", name: "patch", context: "/repo/Sources/A.swift"),
      SessionMessage(id: 5, role: "tool", name: "frobnicate_widget", context: "w1"),
      SessionMessage(id: 6, role: "assistant", content: "Fixed."),
    ])
    let presentations = rows.compactMap { row -> ToolPresentation? in
      if case let .tool(call) = row.kind { ToolPresentation(call: call) } else { nil }
    }
    #expect(presentations.map(\.settledTitle) == [
      "Ran pytest -q", "Read A.swift", "Edited A.swift", "Frobnicate widget: w1",
    ])
    #expect(presentations.allSatisfy { $0.body == .unavailable(note: ToolPresentation.unavailableNote) })
    #expect(RunSummary.text(calls: rows.compactMap {
      if case let .tool(call) = $0.kind { call } else { nil }
    }, live: false) == "Ran 1 command, read 1 file, edited A.swift, and performed 1 other action")

    // No timestamps: the header still folds the turn, it just says "Worked".
    let items = TranscriptFold.items(
      rows: rows, expansion: FoldExpansion(), runningTurnOrdinal: nil, liveLine: nil
    )
    #expect(items.map(\.id) == [rows[0].id, TranscriptItem.turnHeaderID(userRowID: rows[0].id), rows[5].id])
    #expect(headers(items).first?.finishedTitle == "Worked")
  }
}
