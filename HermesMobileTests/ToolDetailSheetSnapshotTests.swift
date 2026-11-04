import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// The redesigned tool detail sheet (tool-call display plan, Task 13): the header (icon, title,
/// outcome, duration), the per-tool body UNCAPPED, and the collapsed "Raw" disclosure.
///
/// The sheet is a `ScrollView`, so every case renders as a whole screen (`deviceImage`) — width
/// and height pinned; the full-output case pins a taller height so the uncapped output shows.
final class ToolDetailSheetSnapshotTests: SnapshotTestCase {
  private func json(_ text: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
  }

  private func call(
    _ name: String, title: String? = nil, args: String? = nil, result: String? = nil,
    inlineDiff: String? = nil, durationS: Double? = 0.4
  ) -> ToolCall {
    ToolCall(
      name: name, title: title ?? name, state: .complete,
      detail: ToolDetail(
        args: args.map(json), result: result.map(json), resultText: result, inlineDiff: inlineDiff
      ),
      durationS: durationS
    )
  }

  /// A terminal call's full output — 30 lines, past the 12-line inline cap — under `$ command`
  /// and a green `exit 0`.
  func testTerminalFullOutput() {
    let output = (1...30).map { "tests/test_api.py::test_case_\($0) PASSED" }.joined(separator: "\\n")
    let view = ToolDetailSheet(call: call(
      "terminal", title: "pytest -q tests/", args: #"{"command": "pytest -q tests/"}"#,
      result: #"{"output": "\#(output)", "exit_code": 0}"#, durationS: 3.24
    ))
    assertSnapshot(of: view, as: deviceImage(height: 1_100))
  }

  /// An edit's diff, tinted — light and dark.
  func testDiff() {
    let diff = """
    --- a/HermesMobile/Sources/Features/Chat/ChatView.swift
    +++ b/HermesMobile/Sources/Features/Chat/ChatView.swift
    @@ -124,6 +124,4 @@
         .sheet(item: toolDetailBinding) { row in
           if case let .tool(call) = row.kind {
    -        ToolDetailSheet(
    -          name: call.name, title: call.title, detail: call.detail ?? ToolDetail(), durationS: call.durationS
    -        )
    +        ToolDetailSheet(call: call)
           }
         }
    """
    let view = ToolDetailSheet(call: call(
      "patch", args: #"{"path": "HermesMobile/Sources/Features/Chat/ChatView.swift"}"#,
      result: #"{"success": true}"#, inlineDiff: diff, durationS: 1.4
    ))
    assertSnapshot(of: view, as: deviceImage(), named: "dark")
    assertSnapshot(of: view, as: deviceImage(appearance: .light), named: "light")
  }

  /// An unknown tool: the generic body (headline + pretty result), and the "Raw" disclosure
  /// opened on everything the call carried — context, arguments, result.
  func testGenericUnknownWithRawExpanded() {
    let view = ToolDetailSheet(
      call: call(
        "homeassistant_call", title: "light.turn_on",
        args: #"{"service": "light.turn_on", "entity_id": "light.office"}"#,
        result: #"{"message": "Turned on the office light", "state": "on", "brightness": 180}"#,
        durationS: 0.8
      ),
      rawExpanded: true
    )
    assertSnapshot(of: view, as: deviceImage(height: 1_100))
  }

  /// A failed call: red icon + "Failed" badge, the error message, and the collapsed "Raw".
  func testFailure() {
    let view = ToolDetailSheet(call: call(
      "terminal", args: #"{"command": "asc testflight crashes --app 6740 --limit 20"}"#,
      result: #"{"error": "unknown flag: --limit\nRun 'asc testflight crashes --help' for usage."}"#,
      durationS: 0.6
    ))
    assertSnapshot(of: view, as: deviceImage())
  }

  /// A reloaded call whose output the history doesn't keep: no badge, the "unavailable" note,
  /// and its arguments still reachable under "Raw".
  func testReloadedUnavailable() {
    let view = ToolDetailSheet(
      call: call(
        "terminal", title: "gh issue list --label crash",
        args: #"{"command": "gh issue list --label crash"}"#, durationS: nil
      ),
      rawExpanded: true
    )
    assertSnapshot(of: view, as: deviceImage())
  }
}
