import Foundation
import Testing

@testable import HermesKit

/// The tool detail sheet's pure parts (tool-call display plan, Task 13): the "Raw" disclosure
/// never drops anything the call carried, without repeating a value under two labels, and the
/// header's duration label.
struct ToolCallDetailTests {
  private func json(_ text: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
  }

  private func labels(_ call: ToolCall) -> [String] { call.rawSections.map(\.label) }

  private func section(_ call: ToolCall, _ label: String) -> String? {
    call.rawSections.first { $0.label == label }?.text
  }

  // MARK: - rawSections

  @Test func liveTerminalCallShowsPrettyArgsAndResult() {
    let result = #"{"output":"ok","exit_code":0}"#
    let call = ToolCall(
      name: "terminal", title: "pytest -q", state: .complete,
      detail: ToolDetail(args: json(#"{"command":"pytest -q"}"#), result: json(result), resultText: result)
    )
    #expect(labels(call) == ["Context", "Arguments", "Result"])
    #expect(section(call, "Context") == "pytest -q")
    #expect(section(call, "Arguments") == "{\n  \"command\" : \"pytest -q\"\n}")
    // Pretty and key-sorted, not the compact wire text (which is the same JSON, so no
    // separate "Result (text)").
    #expect(section(call, "Result") == "{\n  \"exit_code\" : 0,\n  \"output\" : \"ok\"\n}")
  }

  @Test func aSeparateResultTextIsKeptBesideTheStructuredResult() {
    let call = ToolCall(
      name: "web_search", title: "web_search", state: .complete,
      detail: ToolDetail(result: json(#"{"data":{"web":[]}}"#), resultText: "Found 0 results")
    )
    #expect(labels(call) == ["Result", "Result (text)"])
    #expect(section(call, "Result (text)") == "Found 0 results")
  }

  @Test func aStringResultIsShownOnce() {
    let call = ToolCall(
      name: "custom", title: "custom", state: .complete,
      detail: ToolDetail(result: .string("done"), resultText: "done")
    )
    #expect(call.rawSections == [ToolCall.RawSection(label: "Result", text: "done")])
  }

  @Test func textOnlyResultFallsBackToTheText() {
    let call = ToolCall(
      name: "custom", title: "custom", state: .complete,
      detail: ToolDetail(resultText: "plain output\nline 2")
    )
    #expect(call.rawSections == [ToolCall.RawSection(label: "Result", text: "plain output\nline 2")])
  }

  @Test func verboseArgsTextIsKeptWhenItSaysSomethingElse() {
    let call = ToolCall(
      name: "read_file", title: "Reading foo.swift", state: .running,
      detail: ToolDetail(argsText: "path=foo.swift offset=10", args: json(#"{"path":"foo.swift","offset":10}"#))
    )
    #expect(labels(call) == ["Context", "Arguments", "Arguments (text)"])
    #expect(section(call, "Arguments (text)") == "path=foo.swift offset=10")
  }

  @Test func hydratedArgsTextEqualToTheContextIsNotRepeated() {
    // A cooked history row stores its `context` as both the title and `argsText`.
    let call = ToolCall(
      name: "patch", title: "src/app.py", state: .complete,
      detail: ToolDetail(argsText: "src/app.py", args: json(#"{"path":"src/app.py"}"#))
    )
    #expect(labels(call) == ["Context", "Arguments"])
  }

  @Test func argsTextWithoutStructuredArgsIsTheArguments() {
    let call = ToolCall(
      name: "terminal", title: "terminal", state: .complete, detail: ToolDetail(argsText: "ls -la")
    )
    #expect(call.rawSections == [ToolCall.RawSection(label: "Arguments", text: "ls -la")])
  }

  @Test func diffIsKeptWithItsColorsStripped() {
    let call = ToolCall(
      name: "patch", title: "patch", state: .complete,
      detail: ToolDetail(inlineDiff: "\u{1B}[31m- old\u{1B}[0m\n\u{1B}[32m+ new\u{1B}[0m")
    )
    #expect(call.rawSections == [ToolCall.RawSection(label: "Diff", text: "- old\n+ new")])
  }

  @Test func olderAgentCallKeepsItsContext() {
    let call = ToolCall(name: "terminal", title: "ls -la /srv", state: .complete)
    #expect(call.rawSections == [ToolCall.RawSection(label: "Context", text: "ls -la /srv")])
  }

  @Test func aCallCarryingNothingHasNoSections() {
    #expect(ToolCall(name: "todo", title: "todo", state: .complete).rawSections.isEmpty)
    #expect(ToolCall(name: "todo", title: "  ", state: .complete, detail: ToolDetail()).rawSections.isEmpty)
  }

  @Test func nullAndBlankValuesAreSkipped() {
    let call = ToolCall(
      name: "custom", title: "custom", state: .complete,
      detail: ToolDetail(argsText: "  ", args: .null, result: .null, resultText: "\n", inlineDiff: "")
    )
    #expect(call.rawSections.isEmpty)
  }

  @Test func nonObjectArgsAndScalarResultsStillShow() {
    let call = ToolCall(
      name: "custom", title: "custom", state: .complete,
      detail: ToolDetail(args: .array([.string("a"), .number(2)]), result: .number(42), resultText: "42")
    )
    #expect(labels(call) == ["Arguments", "Result"])
    #expect(section(call, "Result") == "42")
  }

  // MARK: - durationLabel

  @Test(arguments: [
    (0.4, "0.4s"),
    (1.44, "1.4s"),
    (9.94, "9.9s"),
    (9.96, "10s"),
    (12.4, "12s"),
    (59.6, "1m 0s"),
    (125, "2m 5s"),
    (3_661, "1h 1m 1s"),
    (0.01, "<0.1s"),
    (0, "0s"),
    (-3, "0s"),
    (.infinity, "0s"),
    (.nan, "0s"),
  ] as [(Double, String)])
  func durationLabel(seconds: Double, expected: String) {
    #expect(ToolPresentation.durationLabel(seconds) == expected)
  }
}
