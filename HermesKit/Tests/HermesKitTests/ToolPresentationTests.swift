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

// MARK: - Bodies (Task 10)

extension ToolPresentationTests {
  private static func presentation(
    _ name: String, args: String? = nil, result: String? = nil, resultText: String? = nil,
    inlineDiff: String? = nil, context: String? = nil, running: Bool = false
  ) -> ToolPresentation {
    ToolPresentation(
      name: name, args: args.map(json), result: result.map(json), resultText: resultText,
      inlineDiff: inlineDiff, context: context, isRunning: running
    )
  }

  private static let unavailable = ToolPresentation.Body.unavailable(note: ToolPresentation.unavailableNote)

  // terminal / execute_code

  @Test func terminalBodyShowsTheFullCommandExitCodeAndOutput() {
    let presentation = Self.presentation(
      "terminal", args: #"{"command": "cd /repo && pytest -q 2>&1 | tail -20"}"#,
      result: #"{"output": "....\n12 passed in 0.4s\n", "exit_code": 0, "error": null}"#
    )
    #expect(presentation.body == .terminal(
      command: "cd /repo && pytest -q 2>&1 | tail -20", exitCode: 0,
      stdout: "....\n12 passed in 0.4s", stderr: nil
    ))
  }

  @Test func terminalBodySplitsStdoutAndStderrWhenTheBackendDoes() {
    let presentation = Self.presentation(
      "terminal", args: #"{"command": "npm i"}"#,
      result: #"{"stdout": "added 3 packages", "stderr": "npm warn deprecated", "exit_code": 0}"#
    )
    #expect(presentation.body == .terminal(
      command: "npm i", exitCode: 0, stdout: "added 3 packages", stderr: "npm warn deprecated"
    ))
  }

  @Test func terminalBodyStripsANSIHeavyOutput() {
    let output = "\u{1B}[1m\u{1B}[32m✓\u{1B}[0m builds\r\n\u{1B}[33m50%\u{1B}[0m\r\u{1B}[33m100%\u{1B}[0m"
    let presentation = ToolPresentation(
      name: "terminal", args: .object(["command": .string("make")]),
      result: .object(["output": .string(output), "exit_code": .number(0)]),
      resultText: nil, inlineDiff: nil, context: nil
    )
    #expect(presentation.body == .terminal(command: "make", exitCode: 0, stdout: "✓ builds\n100%", stderr: nil))
  }

  @Test func terminalErrorEnvelopeKeepsTheExitCodeAndFails() {
    let presentation = Self.presentation(
      "terminal", args: #"{"command": "rm -rf /"}"#,
      result: #"{"output": "", "exit_code": -1, "error": "Blocked by guard"}"#
    )
    #expect(presentation.body == .terminal(command: "rm -rf /", exitCode: -1, stdout: nil, stderr: nil))
    #expect(presentation.outcome == .failure("Blocked by guard"))
  }

  @Test func terminalHugeOutputKeepsTheFullTextAndCapsInline() {
    let output = (1...5_000).map { "line \($0)" }.joined(separator: "\n")
    let presentation = ToolPresentation(
      name: "terminal", args: .object(["command": .string("seq 5000")]),
      result: .object(["output": .string(output), "exit_code": .number(0)]),
      resultText: nil, inlineDiff: nil, context: nil
    )
    #expect(presentation.body == .terminal(command: "seq 5000", exitCode: 0, stdout: output, stderr: nil))
    let inline = presentation.body.inline()
    #expect(inline.isTruncated)
    #expect(inline.body == .terminal(
      command: "seq 5000", exitCode: 0,
      stdout: (1...12).map { "line \($0)" }.joined(separator: "\n"), stderr: nil
    ))
  }

  @Test func terminalOlderAgentPlainResultTextIsTheOutput() {
    let presentation = Self.presentation("terminal", resultText: "hello\n", context: "echo hello")
    #expect(presentation.body == .terminal(command: "echo hello", exitCode: nil, stdout: "hello", stderr: nil))
  }

  @Test func terminalEmptyResultShowsJustTheCommand() {
    let presentation = Self.presentation("terminal", args: #"{"command": "true"}"#, result: "{}")
    #expect(presentation.body == .terminal(command: "true", exitCode: nil, stdout: nil, stderr: nil))
  }

  @Test func runningTerminalShowsTheCommandWithNoOutputYet() {
    let presentation = Self.presentation("terminal", args: #"{"command": "sleep 5"}"#, running: true)
    #expect(presentation.body == .terminal(command: "sleep 5", exitCode: nil, stdout: nil, stderr: nil))
  }

  @Test func hydratedTerminalIsUnavailable() {
    // Cooked history keeps `content` only for edit tools: a reloaded command has no output.
    let presentation = Self.presentation("terminal", args: #"{"command": "ls"}"#, context: "ls")
    #expect(presentation.body == Self.unavailable)
  }

  @Test func executeCodeBodyHasOutputButNoShellLine() {
    let presentation = Self.presentation(
      "execute_code", args: #"{"code": "print(1)"}"#,
      result: #"{"status": "success", "output": "1\n", "tool_calls_made": 0}"#
    )
    #expect(presentation.body == .terminal(command: nil, exitCode: nil, stdout: "1", stderr: nil))
  }

  @Test func terminalWithAMalformedResultFallsBackToNoOutput() {
    let presentation = Self.presentation("terminal", args: #"{"command": "x"}"#, result: #"[1, 2]"#)
    #expect(presentation.body == .terminal(command: "x", exitCode: nil, stdout: nil, stderr: nil))
  }

  // diff

  private static let renderedDiff = [
    "  ┊ review diff",
    "\u{1B}[38;5;250ma/src/App.swift → b/src/App.swift\u{1B}[0m",
    "\u{1B}[36m@@ -1 +1 @@\u{1B}[0m",
    "\u{1B}[31m-let a = 1\u{1B}[0m",
    "\u{1B}[32m+let a = 2\u{1B}[0m",
  ].joined(separator: "\n")

  private static let renderedDiffLines = [
    DiffLine(kind: .file, text: "src/App.swift"),
    DiffLine(kind: .hunk, text: "@@ -1 +1 @@"),
    DiffLine(kind: .removed, text: "let a = 1"),
    DiffLine(kind: .added, text: "let a = 2"),
  ]

  @Test func liveEditBodyIsTheParsedInlineDiff() {
    let presentation = Self.presentation(
      "patch", args: #"{"path": "/repo/src/App.swift", "old_string": "1", "new_string": "2"}"#,
      result: #"{"success": true, "diff": "--- a/src/App.swift\n+++ b/src/App.swift"}"#,
      inlineDiff: Self.renderedDiff
    )
    #expect(presentation.body == .diff(path: "src/App.swift", lines: Self.renderedDiffLines))
    #expect(presentation.title(live: false) == "Edited App.swift")
  }

  @Test func hydratedEditWithContentAndDiffRendersTheDiff() {
    // `cookedToolDetail`: raw content as resultText (+ parsed result), inline diff from
    // `display_metadata.tool_result_metadata`.
    let call = ToolCall(
      name: "write_file", title: "/repo/src/App.swift", state: .complete,
      detail: ToolDetail(
        argsText: "/repo/src/App.swift",
        args: Self.json(#"{"path": "/repo/src/App.swift", "content": "let a = 2"}"#),
        result: Self.json(#"{"bytes_written": 9}"#),
        resultText: #"{"bytes_written": 9}"#,
        inlineDiff: Self.renderedDiff
      )
    )
    #expect(ToolPresentation(call: call).body == .diff(path: "src/App.swift", lines: Self.renderedDiffLines))
  }

  @Test func patchResultDiffIsUsedWithoutAnInlineDiff() {
    let presentation = Self.presentation(
      "patch", args: #"{"path": "/r/x.py"}"#,
      result: #"{"success": true, "diff": "--- a/r/x.py\n+++ b/r/x.py\n@@ -1 +1 @@\n-a\n+b"}"#
    )
    #expect(presentation.body == .diff(path: "r/x.py", lines: [
      DiffLine(kind: .file, text: "r/x.py"),
      DiffLine(kind: .hunk, text: "@@ -1 +1 @@"),
      DiffLine(kind: .removed, text: "a"),
      DiffLine(kind: .added, text: "b"),
    ]))
  }

  @Test func headerlessDiffTakesThePathFromTheArgs() {
    let presentation = Self.presentation(
      "edit_file", args: #"{"path": "/r/y.swift"}"#, inlineDiff: "@@ -1 +1 @@\n-a\n+b"
    )
    #expect(presentation.body == .diff(path: "/r/y.swift", lines: [
      DiffLine(kind: .hunk, text: "@@ -1 +1 @@"),
      DiffLine(kind: .removed, text: "a"),
      DiffLine(kind: .added, text: "b"),
    ]))
  }

  @Test func editWithoutADiff() {
    // A failed write: no diff, the result explains.
    let failed = Self.presentation(
      "write_file", args: #"{"path": "/r/z"}"#, result: #"{"error": "Permission denied"}"#
    )
    #expect(failed.body == .generic(summary: nil, raw: "{\n  \"error\" : \"Permission denied\"\n}"))
    #expect(failed.outcome == .failure("Permission denied"))
    // A reloaded create keeps no diff and no content.
    #expect(Self.presentation("write_file", args: #"{"path": "/r/z"}"#).body == Self.unavailable)
  }

  // read_file

  @Test func readFileBodyShowsPathRangeAndContent() {
    let presentation = Self.presentation(
      "read_file", args: #"{"path": "/repo/Sources/App.swift", "offset": 10, "limit": 3}"#,
      result: #"{"content": "    10|  let a = 1\n    11|  let b = 2\n    12|}", "total_lines": 40}"#
    )
    #expect(presentation.body == .fileRead(
      path: "/repo/Sources/App.swift", range: "L10-12",
      content: "    10|  let a = 1\n    11|  let b = 2\n    12|}"
    ))
  }

  @Test func readFileNotFoundHasNoContentAndANotice() {
    let presentation = Self.presentation(
      "read_file", args: #"{"path": "/nope.txt"}"#,
      result: #"{"error": "File not found: /nope.txt", "not_found": true}"#
    )
    #expect(presentation.body == .fileRead(path: "/nope.txt", range: nil, content: nil))
    #expect(presentation.outcome == .notice("File not found: /nope.txt"))
  }

  @Test(arguments: [
    #"{"path": "/a", "offset": 1e19}"#,
    #"{"path": "/a", "offset": 9e18, "limit": 9e18}"#,
    #"{"path": "/a", "offset": -1e300, "limit": 1e300}"#,
  ])
  func absurdReadRangesNeverTrap(args: String) {
    let presentation = Self.presentation("read_file", args: args, result: #"{"content": "1|x"}"#)
    #expect(presentation.settledTitle.hasPrefix("Read a"))
    _ = presentation.body
  }

  @Test func absurdCountsAndLineNumbersNeverTrap() {
    let terminal = Self.presentation(
      "terminal", args: #"{"command": "ls"}"#, result: #"{"output": "", "exit_code": 1e19}"#
    )
    guard case let .terminal(_, exitCode, _, _) = terminal.body else {
      Issue.record("expected a terminal body")
      return
    }
    #expect(exitCode == nil)
    _ = terminal.outcome
    let search = Self.presentation(
      "search_files", args: #"{"pattern": "x"}"#,
      result: #"{"total_count": 1e300, "matches": [{"path": "a.swift", "line": -1e19, "content": "x"}]}"#
    )
    #expect(search.body == .search(query: "x", hits: [.init(title: "a.swift", snippet: "x")], totalCount: nil))
    let counts = Self.presentation("search_files", args: #"{"pattern": "x"}"#, result: #"{"counts": {"a": 1e19}}"#)
    #expect(counts.body == .search(query: "x", hits: [.init(title: "a", snippet: "0 matches")], totalCount: nil))
  }

  @Test func hydratedReadFileIsUnavailable() {
    #expect(Self.presentation("read_file", args: #"{"path": "/a"}"#).body == Self.unavailable)
  }

  @Test func readFileWithoutAnyPathFallsBackToGeneric() {
    let presentation = Self.presentation("read_file", args: #""not an object""#, result: #"{"content": "x"}"#)
    #expect(presentation.body == .generic(summary: nil, raw: "{\n  \"content\" : \"x\"\n}"))
  }

  // search

  @Test func searchFilesBodyListsMatches() {
    let presentation = Self.presentation(
      "search_files", args: #"{"pattern": "TODO", "path": "."}"#,
      result: #"""
        {"total_count": 2, "matches": [
          {"path": "a.swift", "line": 3, "content": "  // TODO: one"},
          {"path": "b.swift", "line": 9, "content": "// TODO two"}
        ]}
        """#
    )
    #expect(presentation.body == .search(query: "TODO", hits: [
      .init(title: "a.swift:3", snippet: "// TODO: one"),
      .init(title: "b.swift:9", snippet: "// TODO two"),
    ], totalCount: 2))
  }

  @Test func searchFilesReadsThePathGroupedMatchesText() {
    let presentation = Self.presentation(
      "search_files", args: #"{"pattern": "foo"}"#,
      result: #"{"total_count": 9, "matches_text": "src/a.py\n  1: foo()\n  7: foo = 2\nsrc/b.py\n  4:   return foo"}"#
    )
    #expect(presentation.body == .search(query: "foo", hits: [
      .init(title: "src/a.py:1", snippet: "foo()"),
      .init(title: "src/a.py:7", snippet: "foo = 2"),
      .init(title: "src/b.py:4", snippet: "return foo"),
    ], totalCount: 9))
  }

  @Test func searchFilesFileListIsCappedAtSixHits() {
    let files = (1...20).map { "\"f\($0).txt\"" }.joined(separator: ", ")
    let presentation = Self.presentation(
      "search_files", args: #"{"pattern": "*.txt", "target": "files"}"#,
      result: #"{"total_count": 20, "files": [\#(files)]}"#
    )
    guard case let .search(query, hits, total) = presentation.body else {
      Issue.record("expected a search body")
      return
    }
    #expect(query == "*.txt")
    #expect(hits.map(\.title) == (1...6).map { "f\($0).txt" })
    #expect(total == 20)
  }

  @Test func webSearchBodyListsAtMostSixHitsWithLinks() {
    let items = (1...8).map {
      #"{"title": "Result \#($0)", "url": "https://e.com/\#($0)", "description": "Snippet \#($0)", "position": \#($0)}"#
    }.joined(separator: ", ")
    let presentation = Self.presentation(
      "web_search", args: #"{"query": "swift testing"}"#,
      result: #"{"success": true, "data": {"web": [\#(items)]}}"#
    )
    #expect(presentation.body == .search(
      query: "swift testing",
      hits: (1...6).map { .init(title: "Result \($0)", url: "https://e.com/\($0)", snippet: "Snippet \($0)") },
      totalCount: nil
    ))
  }

  @Test func webSearchWithNoHitsIsAnEmptySearch() {
    let presentation = Self.presentation(
      "web_search", args: #"{"query": "q"}"#, result: #"{"success": true, "data": {"web": []}}"#
    )
    #expect(presentation.body == .search(query: "q", hits: [], totalCount: nil))
  }

  @Test func hydratedSearchesAreUnavailable() {
    #expect(Self.presentation("web_search", args: #"{"query": "q"}"#).body == Self.unavailable)
    #expect(Self.presentation("search_files", args: #"{"pattern": "q"}"#).body == Self.unavailable)
  }

  // web page

  @Test func webExtractBodyShowsTheURLAndPageText() {
    let presentation = Self.presentation(
      "web_extract", args: #"{"urls": ["https://docs.swift.org/x"]}"#,
      result: ##"{"results": [{"url": "https://docs.swift.org/x", "title": "X", "content": "# X\nBody"}]}"##
    )
    #expect(presentation.body == .webPage(url: "https://docs.swift.org/x", content: "# X\nBody"))
  }

  @Test func browserNavigateBodyAndItsHydratedShape() {
    let live = Self.presentation(
      "browser_navigate", args: #"{"url": "https://e.com"}"#, result: #"{"success": true, "title": "E"}"#
    )
    #expect(live.body == .webPage(url: "https://e.com", content: nil))
    #expect(Self.presentation("browser_navigate", args: #"{"url": "https://e.com"}"#).body == Self.unavailable)
  }

  // skill / delegate

  @Test func skillBodyNeedsOnlyTheArgs() {
    let hydrated = Self.presentation("skill_view", args: #"{"name": "pdf", "file_path": "forms.md"}"#)
    #expect(hydrated.body == .skill(name: "pdf", file: "forms.md", description: nil))
    let live = Self.presentation(
      "skill_view", args: #"{"name": "pdf"}"#,
      result: #"{"success": true, "name": "pdf", "description": "Work with PDFs", "content": "..."}"#
    )
    #expect(live.body == .skill(name: "pdf", file: nil, description: "Work with PDFs"))
  }

  @Test func delegateBodyListsTheGoals() {
    let presentation = Self.presentation(
      "delegate_task", args: #"{"tasks": [{"goal": "Audit auth"}, {"goal": "Write tests"}]}"#
    )
    #expect(presentation.body == .delegate(goals: ["Audit auth", "Write tests"]))
    #expect(Self.presentation("delegate_task", args: #"{"goal": "One"}"#).body == .delegate(goals: ["One"]))
    #expect(Self.presentation("delegate_task").body == Self.unavailable)
  }

  // generic / unknown

  @Test func unknownToolBodyIsGenericWithTheRawResult() {
    let presentation = Self.presentation(
      "mcp_github_create_issue", args: #"{"title": "Bug"}"#,
      result: #"{"message": "Created #12", "number": 12}"#
    )
    #expect(presentation.body == .generic(
      summary: "Created #12", raw: "{\n  \"message\" : \"Created #12\",\n  \"number\" : 12\n}"
    ))
  }

  @Test func unknownToolStringResultIsTheRawText() {
    let presentation = Self.presentation("foo", resultText: "\u{1B}[1mdone\u{1B}[0m\n")
    #expect(presentation.body == .generic(summary: nil, raw: "done"))
  }

  @Test func unknownToolEmptyResultFallsBackToTheContext() {
    let presentation = Self.presentation("foo", result: "{}", context: "ctx")
    #expect(presentation.body == .generic(summary: "ctx", raw: nil))
  }

  @Test func runningUnknownToolShowsItsArgs() {
    let withArgs = Self.presentation("foo", args: #"{"q": 1}"#, running: true)
    #expect(withArgs.body == .generic(summary: nil, raw: "{\n  \"q\" : 1\n}"))
    let bare = Self.presentation("foo", context: "working", running: true)
    #expect(bare.body == .generic(summary: "working", raw: nil))
  }

  @Test func hydratedUnknownToolIsUnavailable() {
    #expect(Self.presentation("foo", args: #"{"q": 1}"#, context: "q").body == Self.unavailable)
  }

  @Test func callStateDrivesTheRunningBody() {
    let args = Self.json(#"{"command": "make"}"#)
    let running = ToolCall(name: "terminal", title: "make", state: .running, detail: ToolDetail(args: args))
    #expect(ToolPresentation(call: running).body == .terminal(command: "make", exitCode: nil, stdout: nil, stderr: nil))
    let settled = ToolCall(name: "terminal", title: "make", state: .complete, detail: ToolDetail(args: args))
    #expect(ToolPresentation(call: settled).body == Self.unavailable)
  }

  // inline caps

  @Test func inlineTerminalSharesOneBudgetAcrossStdoutAndStderr() {
    let stdout = (1...10).map { "out \($0)" }.joined(separator: "\n")
    let stderr = (1...5).map { "err \($0)" }.joined(separator: "\n")
    let body = ToolPresentation.Body.terminal(command: "x", exitCode: 1, stdout: stdout, stderr: stderr)
    let inline = body.inline()
    #expect(inline.isTruncated)
    #expect(inline.body == .terminal(command: "x", exitCode: 1, stdout: stdout, stderr: "err 1\nerr 2"))
  }

  @Test func inlineDropsStderrOnceStdoutSpentTheBudget() {
    let stdout = (1...12).map { "out \($0)" }.joined(separator: "\n")
    let body = ToolPresentation.Body.terminal(command: nil, exitCode: 0, stdout: stdout, stderr: "warn")
    #expect(body.inline() == .init(
      body: .terminal(command: nil, exitCode: 0, stdout: stdout, stderr: nil), isTruncated: true
    ))
  }

  @Test func inlineDiffKeepsTwelveLines() {
    let lines = (1...30).map { DiffLine(kind: .added, text: "line \($0)") }
    let inline = ToolPresentation.Body.diff(path: "a", lines: lines).inline()
    #expect(inline == .init(body: .diff(path: "a", lines: Array(lines.prefix(12))), isTruncated: true))
  }

  @Test func inlineDiffCutsAHugeLine() {
    let lines = [DiffLine(kind: .added, text: String(repeating: "x", count: 5_000))]
    let inline = ToolPresentation.Body.diff(path: nil, lines: lines).inline()
    #expect(inline.isTruncated)
    #expect(inline.body == .diff(path: nil, lines: [DiffLine(kind: .added, text: String(repeating: "x", count: 2_000))]))
  }

  @Test func inlineLeavesShortAndListBodiesAlone() {
    let bodies: [ToolPresentation.Body] = [
      .fileRead(path: "/a", range: "L1", content: "    1|x"),
      .webPage(url: "https://e.com", content: "short"),
      .generic(summary: "s", raw: "r"),
      .search(query: "q", hits: [.init(title: "t")], totalCount: 1),
      .skill(name: "pdf", file: nil, description: nil),
      .delegate(goals: ["g"]),
      Self.unavailable,
    ]
    for body in bodies {
      #expect(body.inline() == .init(body: body, isTruncated: false))
    }
  }

  @Test func inlineGenericCapsTheRawAfterTheSummary() {
    let raw = (1...20).map { "r\($0)" }.joined(separator: "\n")
    let inline = ToolPresentation.Body.generic(summary: "headline", raw: raw).inline()
    #expect(inline == .init(
      body: .generic(summary: "headline", raw: (1...11).map { "r\($0)" }.joined(separator: "\n")),
      isTruncated: true
    ))
  }

  @Test func renderedInlineDiffNamesTheEditTarget() {
    // The live wire `inline_diff` is the rendered shape (`a/x → b/x`), not `+++ b/x`.
    let presentation = Self.presentation("patch", inlineDiff: Self.renderedDiff)
    #expect(presentation.target == "App.swift")
  }
}
