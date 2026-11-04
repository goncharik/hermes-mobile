import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Calls expanded in place (tool-call display plan, Phase C): each call line followed by its
/// body item, rendered through the real `ChatView.itemView` — the builder the collection view
/// hosts — in a plain `VStack` (component render; the bodies hold no scroll views, so nothing
/// to pin). One test per body case, plus the failure and unavailable states; light + dark.
final class ToolBodySnapshotTests: SnapshotTestCase {
  private func store() -> StoreOf<ChatFeature> {
    let state = ChatFeature.State(
      connection: connection,
      resumeStoredID: "snapshot-session",
      title: "Bodies",
      transcript: [],
      status: .ready
    )
    return Store(initialState: state) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
      $0.continuousClock = ImmediateClock()
    }
  }

  private func json(_ text: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
  }

  private func call(
    _ name: String, title: String? = nil, args: String? = nil, result: String? = nil,
    inlineDiff: String? = nil, running: Bool = false
  ) -> ToolCall {
    ToolCall(
      name: name, title: title ?? name, state: running ? .running : .complete,
      detail: ToolDetail(
        args: args.map(json), result: result.map(json), resultText: result, inlineDiff: inlineDiff
      ),
      durationS: running ? nil : 0.4
    )
  }

  /// Each call as an expanded line + its body, both appearances.
  private func assertBodies(
    _ calls: [ToolCall], file: StaticString = #file, testName: String = #function, line: UInt = #line
  ) {
    let items: [TranscriptItem] = calls.enumerated().flatMap { index, call -> [TranscriptItem] in
      let row = ChatRow(id: id(index + 1), kind: .tool(call))
      return [
        .toolCall(ToolCallItem(
          row: row, key: CallKey(turnOrdinal: 0, callOrdinal: index), isExpanded: true,
          isLive: call.state == .running
        )),
        .toolBody(row),
      ]
    }
    let chat = ChatView(store: store())
    let view = VStack(alignment: .leading, spacing: 10) {
      ForEach(items) { item in
        chat.itemView(item, finalReplyIDs: [])
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

  /// `$ command` + a green `exit 0` + output cut to the inline cap ("Show all"); then a
  /// non-zero exit (amber) with stdout and stderr labelled.
  func testTerminalBodies() {
    let output = (1...20).map { "test_case_\($0) ... ok" }.joined(separator: "\\n")
    assertBodies([
      call("terminal", args: #"{"command": "pytest -q tests/"}"#,
           result: #"{"output": "\#(output)", "exit_code": 0}"#),
      call("terminal", args: #"{"command": "make lint"}"#,
           result: #"{"stdout": "Linting 42 files", "stderr": "warning: unused variable 'x'", "exit_code": 2}"#),
    ])
  }

  /// A failed call: the red icon and the error over its body.
  func testFailureBody() {
    assertBodies([
      call("terminal", args: #"{"command": "asc testflight crashes --app 6740 --limit 20"}"#,
           result: #"{"error": "unknown flag: --limit"}"#),
    ])
  }

  /// An edit's diff: the file header, a hunk, tinted additions / removals, context.
  func testDiffBody() {
    let diff = """
    --- a/HermesMobile/Sources/Features/Chat/ChatView.swift
    +++ b/HermesMobile/Sources/Features/Chat/ChatView.swift
    @@ -270,4 +270,6 @@
       case let .toolCall(item):
    -    toolLine(item.row, isLive: item.isLive)
    +    ToolStatusView(call: call, isLive: item.isLive, isExpanded: item.isExpanded,
    +                   onTap: { store.send(.toolCallTapped(item.key)) })
       case .liveIndicator:
    """
    assertBodies([
      call("patch", args: #"{"path": "HermesMobile/Sources/Features/Chat/ChatView.swift"}"#,
           result: #"{"success": true}"#, inlineDiff: diff),
    ])
  }

  /// A file read: the path + its line range, then the numbered content.
  func testFileReadBody() {
    let content = (10...14).map { "\\t\($0)|let line\($0) = \($0)" }.joined(separator: "\\n")
    assertBodies([
      call("read_file", args: #"{"path": "/srv/app/server.py", "offset": 10, "limit": 5}"#,
           result: #"{"content": "\#(content)"}"#),
    ])
  }

  /// Web hits as title links with snippets; file matches as `path:line` + the matched line.
  func testSearchBodies() {
    let hits = (1...3).map {
      #"{"title": "Swift Testing traits, part \#($0)", "url": "https://developer.apple.com/t\#($0)", "description": "How traits customise a test's behaviour, \#($0)."}"#
    }.joined(separator: ", ")
    assertBodies([
      call("web_search", args: #"{"query": "swift testing traits"}"#,
           result: #"{"success": true, "data": {"web": [\#(hits)]}}"#),
      call("search_files", args: #"{"pattern": "TODO", "path": "."}"#,
           result: #"{"total_count": 14, "matches": [{"path": "Sources/App.swift", "line": 3, "content": "// TODO: wire the body"}, {"path": "Sources/Feature.swift", "line": 91, "content": "// TODO: prune"}]}"#),
    ])
  }

  /// A fetched page: the link, then the page text.
  func testWebPageBody() {
    assertBodies([
      call("web_extract", args: #"{"urls": ["https://docs.swift.org/swift-book/"]}"#,
           result: ##"{"results": [{"url": "https://docs.swift.org/swift-book/", "content": "The Swift Programming Language\nSwift is a fantastic way to write software."}]}"##),
    ])
  }

  /// A skill (name, file, description) and a delegation (its goals).
  func testSkillAndDelegateBodies() {
    assertBodies([
      call("skill_view", args: #"{"name": "asc-crash-triage", "file_path": "SKILL.md"}"#,
           result: #"{"success": true, "name": "asc-crash-triage", "description": "Triage TestFlight crashes and beta feedback."}"#),
      call("delegate_task", args: #"{"tasks": [{"goal": "Audit the auth flow"}, {"goal": "Write the missing tests"}]}"#,
           result: #"{"success": true}"#),
    ])
  }

  /// An unknown tool: its headline and the pretty-printed result — nothing hidden.
  func testGenericBody() {
    assertBodies([
      call("homeassistant_call", title: "light.turn_on",
           args: #"{"service": "light.turn_on", "entity_id": "light.office"}"#,
           result: #"{"message": "Turned on the office light", "state": "on", "brightness": 180}"#),
    ])
  }

  /// A reloaded call whose output the server's history doesn't keep; and a running call that
  /// has produced nothing yet.
  func testUnavailableBody() {
    assertBodies([
      call("terminal", title: "gh issue list --label crash", args: #"{"command": "gh issue list --label crash"}"#),
      call("terminal", args: #"{"command": "swift build"}"#, running: true),
    ])
  }
}
