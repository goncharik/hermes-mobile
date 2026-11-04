import Foundation
import Testing

@testable import HermesKit

/// `ToolPresentation` classification (tool-call display plan, Task 9): icon, run category,
/// target, past / present title and outcome per tool, over fixture payloads shaped like the
/// real wire data — live (`tool.start` args + `tool.complete` result), hydrated (cooked args +
/// context, result only for edit tools) and an older agent's bare `{name, context}`.
struct ToolPresentationTests {
  /// Decodes a JSON literal into a `JSONValue` (fixtures read like the wire).
  private static func json(_ text: String) -> JSONValue {
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  struct Fixture: CustomTestStringConvertible, Sendable {
    let label: String
    let name: String
    var args: String?
    var result: String?
    var resultText: String?
    var inlineDiff: String?
    var context: String?
    let icon: ToolPresentation.Icon
    let category: ToolPresentation.RunCategory
    let target: String?
    let settled: String
    let live: String
    var outcome: ToolPresentation.Outcome = .unknown

    var testDescription: String { label }

    func presentation() -> ToolPresentation {
      ToolPresentation(
        name: name,
        args: args.map(ToolPresentationTests.json),
        result: result.map(ToolPresentationTests.json),
        resultText: resultText,
        inlineDiff: inlineDiff,
        context: context
      )
    }
  }

  static let fixtures: [Fixture] = [
    // terminal
    Fixture(
      label: "terminal live", name: "terminal",
      args: #"{"command": "cd /repo && pytest -q 2>&1 | tail -20", "timeout": 120}"#,
      result: #"{"output": "12 passed", "exit_code": 0, "error": null}"#,
      context: "cd /repo && pytest -q 2>&1 | tail -20",
      icon: .terminal, category: .run, target: "pytest -q",
      settled: "Ran pytest -q", live: "Running pytest -q", outcome: .success
    ),
    Fixture(
      label: "terminal hydrated (args, no output)", name: "terminal",
      args: #"{"command": "ls -la"}"#, context: "ls -la",
      icon: .terminal, category: .run, target: "ls -la",
      settled: "Ran ls -la", live: "Running ls -la"
    ),
    Fixture(
      label: "terminal older agent (context only)", name: "terminal", context: "Running npm test",
      icon: .terminal, category: .run, target: "npm test",
      settled: "Ran npm test", live: "Running npm test"
    ),
    Fixture(
      label: "terminal with nothing", name: "terminal",
      icon: .terminal, category: .run, target: nil,
      settled: "Ran command", live: "Running command"
    ),
    Fixture(
      label: "execute_code", name: "execute_code",
      args: ##"{"code": "# probe the env\n\nimport os\nprint(os.environ)"}"##,
      result: #"{"status": "success", "output": "{...}"}"#,
      icon: .terminal, category: .run, target: "import os",
      settled: "Ran code import os", live: "Scripting import os", outcome: .success
    ),
    // read_file
    Fixture(
      label: "read_file offset + limit", name: "read_file",
      args: #"{"path": "/repo/Sources/ChatFeature.swift", "offset": 10, "limit": 31}"#,
      result: #"{"content": "10|import Foundation", "total_lines": 400}"#,
      icon: .file, category: .explore, target: "ChatFeature.swift L10-40",
      settled: "Read ChatFeature.swift L10-40", live: "Reading ChatFeature.swift L10-40",
      outcome: .success
    ),
    Fixture(
      label: "read_file single line", name: "read_file",
      args: #"{"path": "a/b.txt", "offset": 7, "limit": 1}"#,
      icon: .file, category: .explore, target: "b.txt L7",
      settled: "Read b.txt L7", live: "Reading b.txt L7"
    ),
    Fixture(
      label: "read_file limit only → content line numbers", name: "read_file",
      args: #"{"path": "/x/notes.md", "limit": 3}"#,
      result: #"{"content": "1|one\n2|two\n3|three"}"#,
      icon: .file, category: .explore, target: "notes.md L1-3",
      settled: "Read notes.md L1-3", live: "Reading notes.md L1-3", outcome: .success
    ),
    Fixture(
      label: "read_file whole file (hydrated)", name: "read_file",
      args: #"{"path": "/repo/README.md"}"#, context: "/repo/README.md",
      icon: .file, category: .explore, target: "README.md",
      settled: "Read README.md", live: "Reading README.md"
    ),
    Fixture(
      label: "read_file older agent path context", name: "read_file", context: "/repo/Package.swift",
      icon: .file, category: .explore, target: "Package.swift",
      settled: "Read Package.swift", live: "Reading Package.swift"
    ),
    Fixture(
      label: "read_file not found is a notice", name: "read_file",
      args: #"{"path": "/nope.txt"}"#,
      result: #"{"error": "File not found: /nope.txt"}"#,
      icon: .file, category: .explore, target: "nope.txt",
      settled: "Read nope.txt", live: "Reading nope.txt",
      outcome: .notice("File not found: /nope.txt")
    ),
    Fixture(
      label: "list_files", name: "list_files", args: #"{"path": "/repo/Sources"}"#,
      icon: .file, category: .explore, target: "Sources",
      settled: "Listed files", live: "Listing files"
    ),
    // edits
    Fixture(
      label: "write_file live", name: "write_file",
      args: #"{"path": "/repo/src/foo.tsx", "content": "export {}"}"#,
      result: #"{"success": true, "bytes_written": 9}"#,
      icon: .edit, category: .edit, target: "foo.tsx",
      settled: "Edited foo.tsx", live: "Editing foo.tsx", outcome: .success
    ),
    Fixture(
      label: "patch hydrated (content as resultText + diff)", name: "patch",
      args: #"{"mode": "replace", "path": "/x/y.py", "old_string": "a", "new_string": "b"}"#,
      resultText: #"{"success": true, "diff": "--- a/x/y.py\n+++ b/x/y.py"}"#,
      inlineDiff: "--- a/x/y.py\n+++ b/x/y.py\n@@ -1 +1 @@\n-a\n+b", context: "/x/y.py",
      icon: .edit, category: .edit, target: "y.py",
      settled: "Edited y.py", live: "Editing y.py", outcome: .success
    ),
    Fixture(
      label: "patch path from the result", name: "patch",
      args: #"{"mode": "patch", "patch": "*** Begin Patch"}"#,
      result: #"{"success": true, "resolved_path": "/r/z.swift"}"#,
      icon: .edit, category: .edit, target: "z.swift",
      settled: "Edited z.swift", live: "Editing z.swift", outcome: .success
    ),
    Fixture(
      label: "patch path from the inline diff (ANSI)", name: "patch",
      args: #"{"mode": "patch"}"#,
      inlineDiff: "\u{1B}[1m--- a/src/q.swift\u{1B}[0m\n\u{1B}[1m+++ b/src/q.swift\u{1B}[0m\n@@ -1 +1 @@",
      icon: .edit, category: .edit, target: "q.swift",
      settled: "Edited q.swift", live: "Editing q.swift"
    ),
    Fixture(
      label: "patch with no path anywhere", name: "patch",
      icon: .edit, category: .edit, target: nil,
      settled: "Patched file", live: "Patching file"
    ),
    // search
    Fixture(
      label: "web_search live (summary title ignored)", name: "web_search",
      args: #"{"query": "swift testing parameterized"}"#,
      result: #"{"data": {"web": [{"title": "A", "url": "https://a.dev"}]}}"#,
      context: "Did 1 search in 1.2s",
      icon: .search, category: .search, target: "swift testing parameterized",
      settled: "Searched “swift testing parameterized”", live: "Searching “swift testing parameterized”",
      outcome: .success
    ),
    Fixture(
      label: "web_search legacy search_term", name: "web_search",
      args: #"{"search_term": "hermes"}"#,
      icon: .search, category: .search, target: "hermes",
      settled: "Searched “hermes”", live: "Searching “hermes”"
    ),
    Fixture(
      label: "web_search long query is compacted", name: "web_search",
      args: #"{"query": "an   extremely long query that goes on and on past the forty eight char cap"}"#,
      icon: .search, category: .search, target: "an extremely long query that goes on and on pas…",
      settled: "Searched “an extremely long query that goes on and on pas…”",
      live: "Searching “an extremely long query that goes on and on pas…”"
    ),
    Fixture(
      label: "search_files", name: "search_files", args: #"{"pattern": "TODO", "path": "."}"#,
      icon: .search, category: .explore, target: "TODO",
      settled: "Searched “TODO”", live: "Searching “TODO”"
    ),
    Fixture(
      label: "session_search_recall", name: "session_search_recall", args: #"{"query": "deploy"}"#,
      icon: .search, category: .search, target: "deploy",
      settled: "Searched history for “deploy”", live: "Searching history for “deploy”"
    ),
    // web / browser
    Fixture(
      label: "web_extract urls list", name: "web_extract",
      args: #"{"urls": ["https://example.com/docs/page?x=1", "https://b.dev"]}"#,
      context: "Extracted 2 pages in 3.0s",
      icon: .web, category: .read, target: "example.com/docs/page",
      settled: "Read example.com/docs/page", live: "Reading example.com/docs/page"
    ),
    Fixture(
      label: "web_extract older agent URL context", name: "web_extract", context: "https://news.dev/",
      icon: .web, category: .read, target: "news.dev",
      settled: "Read news.dev", live: "Reading news.dev"
    ),
    Fixture(
      label: "browser_navigate", name: "browser_navigate", args: #"{"url": "https://example.com/"}"#,
      result: #"{"success": true, "title": "Example"}"#,
      icon: .web, category: .browse, target: "example.com",
      settled: "Opened example.com", live: "Opening example.com", outcome: .success
    ),
    Fixture(
      label: "browser_navigate failed", name: "browser_navigate", args: #"{"url": "https://down.dev/x"}"#,
      result: #"{"success": false, "error": "net::ERR_TIMED_OUT"}"#,
      icon: .web, category: .browse, target: "down.dev/x",
      settled: "Failed to open down.dev/x", live: "Opening down.dev/x",
      outcome: .failure("net::ERR_TIMED_OUT")
    ),
    Fixture(
      label: "browser_click", name: "browser_click", args: #"{"ref": "@e12"}"#,
      icon: .web, category: .interact, target: nil,
      settled: "Clicked page element", live: "Clicking page element"
    ),
    Fixture(
      label: "browser_take_screenshot", name: "browser_take_screenshot",
      icon: .eye, category: .interact, target: nil,
      settled: "Captured screenshot", live: "Capturing screenshot"
    ),
    Fixture(
      label: "browser_exec step comment", name: "browser_exec",
      args: ##"{"code": "# Search Amazon for paper towels\nawait page.fill('#q', 'towels')"}"##,
      icon: .web, category: .interact, target: "Search Amazon for paper towels",
      settled: "Search Amazon for paper towels", live: "Search Amazon for paper towels"
    ),
    Fixture(
      label: "unknown browser_ tool keeps the family", name: "browser_scroll", args: #"{"direction": "down"}"#,
      icon: .web, category: .interact, target: nil,
      settled: "Browser scroll", live: "Running browser scroll"
    ),
    Fixture(
      label: "unknown web_ tool", name: "web_crawl", context: "docs.dev",
      icon: .web, category: .other, target: "docs.dev",
      settled: "Web crawl: docs.dev", live: "Running web crawl: docs.dev"
    ),
    // analyze / skills / delegate / memory
    Fixture(
      label: "vision_analyze", name: "vision_analyze",
      args: #"{"image_url": "/tmp/a.png", "question": "What does the error dialog say?"}"#,
      icon: .eye, category: .analyze, target: "What does the error dialog say?",
      settled: "Analyzed “What does the error dialog say?”",
      live: "Analyzing “What does the error dialog say?”"
    ),
    Fixture(
      label: "skill_view", name: "skill_view", args: #"{"name": "pdf"}"#,
      result: ##"{"success": true, "content": "# PDF"}"##,
      icon: .skill, category: .other, target: "pdf",
      settled: "Loaded skill: pdf", live: "Loading skill: pdf", outcome: .success
    ),
    Fixture(
      label: "skill_view resource", name: "skill_view",
      args: #"{"name": "pdf", "file_path": "references/forms.md"}"#,
      icon: .skill, category: .other, target: "pdf → references/forms.md",
      settled: "Read skill resource: pdf → references/forms.md",
      live: "Reading skill resource: pdf → references/forms.md"
    ),
    Fixture(
      label: "skill_view failed", name: "skill_view", args: #"{"name": "nope"}"#,
      result: #"{"success": false, "error": "Skill 'nope' not found"}"#,
      icon: .skill, category: .other, target: "nope",
      settled: "Failed to load skill: nope", live: "Loading skill: nope",
      outcome: .failure("Skill 'nope' not found")
    ),
    Fixture(
      label: "skills_list", name: "skills_list",
      icon: .skill, category: .other, target: nil,
      settled: "Listed skills", live: "Listing skills"
    ),
    Fixture(
      label: "delegate_task batch", name: "delegate_task",
      args: #"{"tasks": [{"goal": "Audit the API"}, {"goal": "Write tests"}]}"#,
      icon: .delegate, category: .delegate, target: "2 tasks",
      settled: "Delegated 2 tasks", live: "Delegating 2 tasks"
    ),
    Fixture(
      label: "delegate_task single goal", name: "delegate_task", args: #"{"goal": "Fix the flaky test"}"#,
      icon: .delegate, category: .delegate, target: "Fix the flaky test",
      settled: "Delegated Fix the flaky test", live: "Delegating Fix the flaky test"
    ),
    Fixture(
      label: "memory saved", name: "memory", args: #"{"action": "add", "content": "likes tea"}"#,
      result: #"{"success": true}"#,
      icon: .memory, category: .other, target: nil,
      settled: "Saved to memory", live: "Saving to memory", outcome: .success
    ),
    Fixture(
      label: "memory refused is a notice", name: "memory", args: #"{"action": "add"}"#,
      result: #"{"success": false, "error": "Memory over budget"}"#,
      icon: .memory, category: .other, target: nil,
      settled: "Memory write noted", live: "Saving to memory", outcome: .notice("Memory over budget")
    ),
    Fixture(
      label: "todo", name: "todo", args: #"{"todos": []}"#,
      icon: .generic, category: .other, target: nil,
      settled: "Updated todos", live: "Updating todos"
    ),
    // fallback
    Fixture(
      label: "unknown tool with context", name: "mcp_github_list_repos",
      args: #"{"owner": "nous"}"#, context: "nous/hermes",
      icon: .generic, category: .other, target: "nous/hermes",
      settled: "Mcp github list repos: nous/hermes", live: "Running mcp github list repos: nous/hermes"
    ),
    Fixture(
      label: "unknown tool falls to its primary arg", name: "text_to_speech",
      args: #"{"text": "Hello there"}"#,
      icon: .generic, category: .other, target: "Hello there",
      settled: "Text to speech: Hello there", live: "Running text to speech: Hello there"
    ),
    Fixture(
      label: "unknown tool with nothing", name: "foo_bar",
      icon: .generic, category: .other, target: nil,
      settled: "Foo bar", live: "Running foo bar"
    ),
    Fixture(
      label: "nameless tool", name: "", context: "something",
      icon: .generic, category: .other, target: "something",
      settled: "Tool: something", live: "Running tool: something"
    ),
    Fixture(
      label: "unknown skill-family tool", name: "skill_manage",
      args: #"{"action": "patch", "name": "pdf"}"#,
      result: #"{"success": false, "error": "patch refused"}"#,
      icon: .skill, category: .other, target: "pdf",
      settled: "Skill manage: pdf", live: "Running skill manage: pdf", outcome: .notice("patch refused")
    ),
    // malformed args
    Fixture(
      label: "args as a JSON-object string", name: "terminal", args: #""{\"command\": \"make\"}""#,
      icon: .terminal, category: .run, target: "make", settled: "Ran make", live: "Running make"
    ),
    Fixture(
      label: "args not an object falls back to context", name: "terminal", args: #"["ls"]"#,
      context: "git status",
      icon: .terminal, category: .run, target: "git status",
      settled: "Ran git status", live: "Running git status"
    ),
    Fixture(
      label: "args a plain string on an unknown tool", name: "custom_tool", args: #""not json""#,
      context: "ctx",
      icon: .generic, category: .other, target: "ctx",
      settled: "Custom tool: ctx", live: "Running custom tool: ctx"
    ),
    Fixture(
      label: "wrong-typed arg values", name: "read_file",
      args: #"{"path": 42, "offset": "ten"}"#, context: "/repo/a.swift",
      icon: .file, category: .explore, target: "a.swift",
      settled: "Read a.swift", live: "Reading a.swift"
    ),
  ]

  @Test(arguments: fixtures)
  func classifiesEachTool(_ fixture: Fixture) {
    let presentation = fixture.presentation()
    #expect(presentation.name == fixture.name)
    #expect(presentation.icon == fixture.icon)
    #expect(presentation.category == fixture.category)
    #expect(presentation.target == fixture.target)
    #expect(presentation.title(live: false) == fixture.settled)
    #expect(presentation.title(live: true) == fixture.live)
    #expect(presentation.outcome == fixture.outcome)
  }

  // MARK: - From a transcript row

  @Test func classifiesALiveRowFromItsToolCall() {
    let running = ToolCall(
      name: "terminal", title: "pytest -q", state: .running,
      detail: ToolDetail(args: Self.json(#"{"command": "pytest -q"}"#))
    )
    let presentation = ToolPresentation(call: running)
    #expect(presentation.title(live: true) == "Running pytest -q")
    #expect(presentation.outcome == .unknown)

    var complete = running
    complete.state = .complete
    complete.detail?.result = Self.json(#"{"output": "", "exit_code": 2}"#)
    #expect(ToolPresentation(call: complete).outcome == .failure("Command failed with exit code 2."))
  }

  @Test func aTitleThatIsJustTheNameIsNotContext() {
    // A row whose server context was absent carries `title == name`; that must not read as
    // a target ("Foo bar: foo_bar").
    let call = ToolCall(name: "foo_bar", title: "foo_bar", state: .complete)
    let presentation = ToolPresentation(call: call)
    #expect(presentation.target == nil)
    #expect(presentation.title(live: false) == "Foo bar")
  }

  @Test func anOldAgentRowClassifiesFromItsContextTitle() {
    let call = ToolCall(name: "web_search", title: "hermes agent", state: .complete)
    let presentation = ToolPresentation(call: call)
    #expect(presentation.title(live: false) == "Searched “hermes agent”")
    #expect(presentation.outcome == .unknown)
  }

  @Test func aHydratedEditRowCarriesItsResultAndPath() {
    // `cookedToolDetail` shape: raw content as resultText + parsed result, inline diff.
    let call = ToolCall(
      name: "write_file", title: "/repo/a.swift", state: .complete,
      detail: ToolDetail(
        argsText: "/repo/a.swift",
        args: Self.json(#"{"path": "/repo/a.swift", "content": "x"}"#),
        result: Self.json(#"{"success": true}"#),
        resultText: #"{"success": true}"#,
        inlineDiff: "--- a/repo/a.swift\n+++ b/repo/a.swift"
      )
    )
    let presentation = ToolPresentation(call: call)
    #expect(presentation.title(live: false) == "Edited a.swift")
    #expect(presentation.outcome == .success)
  }

  // MARK: - Outcome heuristics

  struct OutcomeCase: CustomTestStringConvertible, Sendable {
    let label: String
    var name = "some_tool"
    var result: String?
    var resultText: String?
    let expected: ToolPresentation.Outcome
    var testDescription: String { label }
  }

  static let outcomes: [OutcomeCase] = [
    OutcomeCase(label: "no result", expected: .unknown),
    OutcomeCase(label: "blank result text", resultText: "  \n", expected: .unknown),
    OutcomeCase(label: "JSON null result", result: "null", expected: .unknown),
    OutcomeCase(label: "plain string result", result: #""done""#, expected: .success),
    OutcomeCase(label: "plain result text", resultText: "all good", expected: .success),
    OutcomeCase(label: "explicit success", result: #"{"success": true}"#, expected: .success),
    OutcomeCase(label: "success beats a stale error", result: #"{"success": true, "error": "stale"}"#,
                expected: .success),
    OutcomeCase(label: "ok true", result: #"{"ok": true, "errors": ["x"]}"#, expected: .success),
    OutcomeCase(label: "error string", result: #"{"error": "boom"}"#, expected: .failure("boom")),
    OutcomeCase(label: "non-error error text", result: #"{"error": "none", "output": "x"}"#,
                expected: .success),
    OutcomeCase(label: "error false", result: #"{"error": false}"#, expected: .success),
    OutcomeCase(label: "empty error object", result: #"{"error": {}}"#, expected: .success),
    OutcomeCase(label: "error object message", result: #"{"error": {"message": "nested msg", "code": 4}}"#,
                expected: .failure("nested msg")),
    OutcomeCase(label: "errors array joined", result: #"{"errors": ["a", "b", "c", "d"]}"#,
                expected: .failure("a; b; c")),
    OutcomeCase(label: "error as JSON-encoded string", result: #"{"error": "{\"message\": \"inner\"}"}"#,
                expected: .failure("inner")),
    OutcomeCase(label: "success false with message", result: #"{"success": false, "message": "denied"}"#,
                expected: .failure("denied")),
    OutcomeCase(label: "ok false bare", result: #"{"ok": false}"#,
                expected: .failure("Tool returned success=false.")),
    OutcomeCase(label: "status failed", result: #"{"status": "Failed"}"#,
                expected: .failure("Tool returned status \"Failed\".")),
    OutcomeCase(label: "status error with reason", result: #"{"status": "error", "reason": "quota"}"#,
                expected: .failure("quota")),
    OutcomeCase(label: "status success is fine", result: #"{"status": "success"}"#, expected: .success),
    OutcomeCase(label: "declared failure unwraps data", result: #"{"success": false, "data": {"error": "deep"}}"#,
                expected: .failure("deep")),
    OutcomeCase(label: "undeclared data error is data", result: #"{"data": {"error": "described"}}"#,
                expected: .success),
    OutcomeCase(label: "nested error chain",
                result: #"{"error": {"error": {"error": {"message": "lvl3"}}}}"#,
                expected: .failure("lvl3")),
    OutcomeCase(label: "array of results with an error", result: #"[{"ok": true}, {"error": "second failed"}]"#,
                expected: .failure("second failed")),
    OutcomeCase(label: "exit code with output", name: "terminal",
                result: #"{"output": "match lines", "exit_code": 2}"#, expected: .success),
    OutcomeCase(label: "exit code with stderr only", result: #"{"stderr": "warn", "exit_code": 3}"#,
                expected: .success),
    OutcomeCase(label: "exit code no output", result: #"{"output": "  ", "exit_code": 3}"#,
                expected: .failure("Command failed with exit code 3.")),
    OutcomeCase(label: "exit code as a string", result: #"{"exit_code": "4"}"#,
                expected: .failure("Command failed with exit code 4.")),
    OutcomeCase(label: "terminal exit 1 no output is neutral", name: "terminal", result: #"{"exit_code": 1}"#,
                expected: .notice("Command failed with exit code 1.")),
    OutcomeCase(label: "non-terminal exit 1 stays a failure", name: "execute_code", result: #"{"exit_code": 1}"#,
                expected: .failure("Command failed with exit code 1.")),
    OutcomeCase(label: "read_file permission error stays a failure", name: "read_file",
                result: #"{"error": "Permission denied: /etc/shadow"}"#,
                expected: .failure("Permission denied: /etc/shadow")),
    OutcomeCase(label: "skill_manage rollback failure is real", name: "skill_manage",
                result: #"{"success": false, "error": "ROLLBACK FAILED: disk"}"#,
                expected: .failure("ROLLBACK FAILED: disk")),
    OutcomeCase(label: "result text JSON is parsed", resultText: #"{"error": "from text"}"#,
                expected: .failure("from text")),
    OutcomeCase(label: "malformed result text is plain text", resultText: #"{"error": "#,
                expected: .success),
  ]

  @Test(arguments: outcomes)
  func judgesTheOutcome(_ testCase: OutcomeCase) {
    let presentation = ToolPresentation(
      name: testCase.name, args: nil, result: testCase.result.map(Self.json),
      resultText: testCase.resultText, inlineDiff: nil, context: nil
    )
    #expect(presentation.outcome == testCase.expected)
  }

  @Test(arguments: [(2, "too deep"), (7, "Tool returned success=false.")])
  func nestedErrorsAreSearchedFiveLevelsDeep(_ wrappers: Int, _ expected: String) {
    // A declared failure unwraps `data` / `details` to explain itself, down to the desktop's
    // depth cap; past it the generic envelope message stands in.
    var value = JSONValue.object(["error": .string("too deep")])
    for _ in 0..<wrappers { value = .object(["details": value]) }
    let presentation = ToolPresentation(
      name: "x", args: nil, result: .object(["success": .bool(false), "data": value]),
      resultText: nil, inlineDiff: nil, context: nil
    )
    #expect(presentation.outcome == .failure(expected))
  }

  @Test func aLongErrorIsClippedToTwelveLines() {
    let message = (1...20).map { "line \($0)" }.joined(separator: "\n")
    let presentation = ToolPresentation(
      name: "x", args: nil, result: .object(["error": .string(message)]),
      resultText: nil, inlineDiff: nil, context: nil
    )
    let expected = (1...12).map { "line \($0)" }.joined(separator: "\n") + "…"
    #expect(presentation.outcome == .failure(expected))
    #expect(presentation.outcome.isFailure)
    #expect(presentation.outcome.message == expected)
  }

  @Test func outcomeHelpers() {
    #expect(ToolPresentation.Outcome.notice("n").isFailure == false)
    #expect(ToolPresentation.Outcome.notice("n").message == "n")
    #expect(ToolPresentation.Outcome.success.message == nil)
    #expect(ToolPresentation.Outcome.unknown.isFailure == false)
  }

  @Test func categoryOrderIsTheDesktopClauseOrder() {
    #expect(ToolPresentation.RunCategory.allCases.map(\.rawValue) == [
      "edit", "explore", "search", "read", "browse", "interact", "analyze", "run", "delegate", "other",
    ])
  }

  // MARK: - Shell command summary

  @Test(arguments: [
    ("", ""),
    ("pytest -q", "pytest -q"),
    ("cd /repo && pytest -q", "pytest -q"),
    ("npm test 2>&1 | tail -20", "npm test"),
    ("swift build > build.log", "swift build"),
    ("cd a && make build && make test", "make build + 1 command"),
    ("cd a; make; make test; make lint", "make + 2 commands"),
    ("FOO=1 cd x; echo \"---\"; ls", "ls"),
    ("cd x && npm test; echo \"x_exit=${PIPESTATUS[0]}\"", "npm test"),
    ("echo 'a && b'", "echo 'a && b'"),
    ("git log | grep fix", "git log | grep fix"),
    ("cd x && export Y=1", "cd x && export Y=1"),
    ("cd x || exit 1\nls -la | head -5", "exit 1 + 1 command"),
  ])
  func summarizesShellCommands(_ input: String, _ expected: String) {
    #expect(ToolPresentation.summarizeShellCommand(input) == expected)
  }

  @Test func aVeryLongCommandIsCappedAt160() {
    let command = "echo " + String(repeating: "x", count: 300)
    let presentation = ToolPresentation(
      name: "terminal", args: .object(["command": .string(command)]),
      result: nil, resultText: nil, inlineDiff: nil, context: nil
    )
    #expect(presentation.target?.count == 160)
    #expect(presentation.target?.hasSuffix("…") == true)
  }

  // MARK: - Helpers

  @Test(arguments: [
    ("foo_bar", "Foo bar"),
    ("mcp-github-search", "Mcp github search"),
    ("x", "X"),
    ("", "Tool"),
    ("__", "Tool"),
  ])
  func humanizesNames(_ name: String, _ expected: String) {
    #expect(ToolPresentation.humanize(name) == expected)
  }

  @Test(arguments: [
    ("https://example.com", "example.com"),
    ("https://example.com/", "example.com"),
    ("https://example.com/a/b?q=1#f", "example.com/a/b"),
    ("not a url", "not a url"),
  ])
  func hostAndPath(_ url: String, _ expected: String) {
    #expect(ToolPresentation.hostAndPath(url) == expected)
  }
}
