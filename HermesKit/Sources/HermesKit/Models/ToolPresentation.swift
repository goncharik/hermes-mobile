import Foundation

/// How one tool call reads in the transcript (tool-call display plan, Phase C): icon kind,
/// run-summary category, parsed one-line target, past / present-tense title and outcome.
///
/// Pure and lenient — classified from whatever the call carries: the live shape (`tool.start`
/// `args` + `tool.complete` `result`), the hydrated shape (cooked `args` + `context`, result
/// only for edit tools), or an older agent's bare `{name, context}`. Per-tool titles, arg keys
/// and failure heuristics mirror the desktop (`apps/desktop/src/components/assistant-ui/tool/
/// fallback-model`, `run-summary.ts`, `lib/tool-result-summary.ts`). A call nothing can be
/// parsed from still gets a humanized-name title plus its context — never an empty line.
public struct ToolPresentation: Equatable, Sendable {
  /// The call line's glyph. The view maps each case to an SF Symbol.
  public enum Icon: Equatable, Sendable {
    case terminal, file, edit, search, web, eye, skill, delegate, memory, generic
  }

  /// Run-summary category: a run whose calls share one gets that category's icon (see
  /// ``RunSummary/icon(calls:)``); ``RunSummary`` splits file reads off `explore` for its clauses.
  public enum RunCategory: Equatable, Sendable {
    case edit, explore, search, read, browse, interact, analyze, run, delegate, other
  }

  /// The call's verdict, from its result (desktop `toolStatus`).
  public enum Outcome: Equatable, Sendable {
    /// The result reports success (or carries no error signal).
    case success
    /// A real failure — the line's icon turns red.
    case failure(String)
    /// An error that is routine, not alarming (a guessed read path missing, `grep` finding
    /// nothing, a refused memory write): the explanation stays available, no red.
    case notice(String)
    /// No result to judge — still running, or a reloaded call whose output isn't kept.
    case unknown

    public var isFailure: Bool {
      if case .failure = self { return true }
      return false
    }

    /// The error / notice text, when there is one.
    public var message: String? {
      switch self {
      case let .failure(message), let .notice(message): return message
      case .success, .unknown: return nil
      }
    }
  }

  /// The tool's wire name.
  public let name: String
  public let icon: Icon
  public let category: RunCategory
  /// The bare thing the call acted on — summarized command, `file.swift L10-40`, query,
  /// host + path, skill name, delegated goal — or the call's context when nothing parses.
  /// `nil` when the call carries neither.
  public let target: String?
  public let outcome: Outcome
  /// "Ran pytest -q", "Read ChatFeature.swift L10-40", `Searched “query”`.
  public let settledTitle: String
  /// "Running pytest -q" — the present tense for a call still in flight.
  public let liveTitle: String

  /// The call line's text in the tense the caller needs.
  public func title(live: Bool) -> String { live ? liveTitle : settledTitle }

  // The classified inputs, kept so `body` is built only when a call is expanded (a run
  // summary classifies every call on each layout pass and never needs one).
  private let args: [String: JSONValue]
  private let resultValue: JSONValue?
  private let inlineDiff: String?
  private let context: String?
  private let isRunning: Bool

  /// Classifies a transcript tool row.
  public init(call: ToolCall) {
    self.init(
      name: call.name,
      args: call.detail?.args,
      result: call.detail?.result,
      resultText: call.detail?.resultText,
      inlineDiff: call.detail?.inlineDiff,
      context: call.context,
      isRunning: call.state == .running
    )
  }

  /// `isRunning` only shapes the body: a call still in flight has no result YET, while a
  /// settled one without a result is a reloaded call whose output isn't kept.
  public init(
    name: String,
    args: JSONValue?,
    result: JSONValue?,
    resultText: String?,
    inlineDiff: String?,
    context: String?,
    isRunning: Bool = false
  ) {
    let args = Self.object(args) ?? [:]
    let resultValue = Self.resultValue(result: result, resultText: resultText)
    let resultRecord = Self.object(resultValue) ?? [:]
    let context = context?.trimmedNonEmpty
    let outcome = Self.outcome(name: name, result: resultValue)

    let spec = Self.spec(
      name: name, args: args, resultRecord: resultRecord, hasResult: resultValue != nil,
      inlineDiff: inlineDiff, context: context, outcome: outcome
    )
    self.name = name
    self.icon = spec.icon
    self.category = spec.category
    self.target = spec.target
    self.outcome = outcome
    self.settledTitle = spec.settled
    self.liveTitle = spec.live
    self.args = args
    self.resultValue = resultValue
    self.inlineDiff = inlineDiff?.trimmedNonEmpty
    self.context = context
    self.isRunning = isRunning
  }
}

// MARK: - Per-tool classification

extension ToolPresentation {
  private struct Spec {
    var icon: Icon
    var category: RunCategory
    var target: String?
    var settled: String
    var live: String
  }

  /// One title pair: `"<verb> <target>"` when a target parsed, else the fixed fallback.
  private static func titled(
    _ icon: Icon, _ category: RunCategory, target: String?,
    past: String, present: String, fallbackPast: String, fallbackPresent: String,
    quoted: Bool = false
  ) -> Spec {
    guard let target else {
      return Spec(icon: icon, category: category, target: nil, settled: fallbackPast, live: fallbackPresent)
    }
    let shown = quoted ? "“\(target)”" : target
    return Spec(
      icon: icon, category: category, target: target,
      settled: "\(past) \(shown)", live: "\(present) \(shown)"
    )
  }

  /// A fixed title pair (no parsed target in the line).
  private static func fixed(
    _ icon: Icon, _ category: RunCategory, _ past: String, _ present: String, target: String? = nil
  ) -> Spec {
    Spec(icon: icon, category: category, target: target, settled: past, live: present)
  }

  /// `host/path` of the page a `web_extract` / `browser_navigate` call targets.
  private static func pageTarget(args: [String: JSONValue], context: String?) -> String? {
    (firstURL(.object(args)) ?? context.flatMap { firstURL(.string($0)) }).map(hostAndPath)
  }

  private static func spec(
    name: String, args: [String: JSONValue], resultRecord: [String: JSONValue], hasResult: Bool,
    inlineDiff: String?, context: String?, outcome: Outcome
  ) -> Spec {
    switch name {
    case "terminal":
      let command = firstString(args, commandKeys) ?? context
      let target = command.map { withoutLeadingVerb(compact(summarizeShellCommand($0), Width.line)) }?.nonEmpty
      return titled(.terminal, .run, target: target, past: "Ran", present: "Running",
                    fallbackPast: "Ran command", fallbackPresent: "Running command")

    case "execute_code":
      let code = firstString(args, ["code"]) ?? context
      let target = code.flatMap(firstCodeLine).map { compact($0, Width.line) }
      return titled(.terminal, .run, target: target, past: "Ran code", present: "Scripting",
                    fallbackPast: "Ran code", fallbackPresent: "Scripting")

    case "read_file":
      let target = firstString(args, pathKeys).map { path in
        [basename(path), readFileLineLabel(args: args, result: resultRecord)]
          .compactMap { $0 }.joined(separator: " ")
      } ?? context.map(displayPath)
      return titled(.file, .explore, target: target, past: "Read", present: "Reading",
                    fallbackPast: "Read file", fallbackPresent: "Reading file")

    case "list_files":
      let target = firstString(args, ["path", "directory", "dir"]).map(basename) ?? context
      return fixed(.file, .explore, "Listed files", "Listing files", target: target)

    case "write_file", "patch", "edit_file":
      let path = firstString(args, pathKeys)
        ?? firstString(resultRecord, pathKeys + ["resolved_path"])
        ?? ToolOutputFormatting.diffPath(inlineDiff ?? firstString(resultRecord, ["inline_diff", "diff"]))
      let target = path.map(basename) ?? context.map(displayPath)
      let patch = name == "patch"
      return titled(.edit, .edit, target: target, past: "Edited", present: "Editing",
                    fallbackPast: patch ? "Patched file" : "Edited file",
                    fallbackPresent: patch ? "Patching file" : "Editing file")

    case "search_files":
      let target = (firstString(args, ["pattern", "query"]) ?? context).map { compact($0, Width.query) }
      return titled(.search, .explore, target: target, past: "Searched", present: "Searching",
                    fallbackPast: "Searched files", fallbackPresent: "Searching files", quoted: true)

    case "web_search":
      let target = (firstString(args, ["query", "search_term"]) ?? context).map { compact($0, Width.query) }
      return titled(.search, .search, target: target, past: "Searched", present: "Searching",
                    fallbackPast: "Searched web", fallbackPresent: "Searching web", quoted: true)

    case "session_search_recall", "session_search":
      let target = (firstString(args, ["query"]) ?? context).map { compact($0, Width.query) }
      return titled(.search, .search, target: target, past: "Searched history for",
                    present: "Searching history for",
                    fallbackPast: "Searched session history", fallbackPresent: "Searching session history",
                    quoted: true)

    case "web_extract":
      return titled(.web, .read, target: pageTarget(args: args, context: context), past: "Read", present: "Reading",
                    fallbackPast: "Read webpage", fallbackPresent: "Reading webpage")

    case "browser_navigate":
      let target = pageTarget(args: args, context: context)
      let failed = outcome.isFailure || resultRecord["success"] == .bool(false)
        || resultRecord["ok"] == .bool(false) || firstString(resultRecord, ["error"]) != nil
      var spec = titled(.web, .browse, target: target, past: "Opened", present: "Opening",
                        fallbackPast: "Opened page", fallbackPresent: "Opening page")
      if failed, let target { spec.settled = "Failed to open \(target)" }
      return spec

    case "browser_click": return fixed(.web, .interact, "Clicked page element", "Clicking page element")
    case "browser_fill": return fixed(.web, .interact, "Filled form field", "Filling form field")
    case "browser_snapshot": return fixed(.web, .interact, "Captured page snapshot", "Capturing page snapshot")
    case "browser_take_screenshot": return fixed(.eye, .interact, "Captured screenshot", "Capturing screenshot")
    case "browser_type": return fixed(.web, .interact, "Typed on page", "Typing on page")

    case "browser_exec":
      if let label = firstString(args, ["code"]).flatMap(browserExecStepLabel) {
        return fixed(.web, .interact, label, label, target: label)
      }
      return fixed(.web, .interact, "Browser exec", "Running browser exec", target: context)

    case "vision_analyze":
      let target = (firstString(args, ["question"]) ?? context).map { compact($0, Width.query) }
      return titled(.eye, .analyze, target: target, past: "Analyzed", present: "Analyzing",
                    fallbackPast: "Analyzed image", fallbackPresent: "Analyzing image", quoted: true)

    case "image_generate":
      return fixed(.eye, .other, "Generated image", "Generating image",
                   target: (firstString(args, ["prompt"]) ?? context).map { compact($0, Width.phrase) })

    case "skill_view":
      let skill = firstString(args, ["name"]) ?? context
      let file = firstString(args, ["file_path"])
      let target = [skill, file].compactMap { $0 }.joined(separator: " → ").nonEmpty
      let (past, present, failedLabel) = file == nil
        ? ("Loaded skill", "Loading skill", "Failed to load skill")
        : ("Read skill resource", "Reading skill resource", "Failed to read skill resource")
      let settled = outcome.isFailure ? failedLabel : past
      return Spec(
        icon: .skill, category: .other, target: target,
        settled: target.map { "\(settled): \($0)" } ?? settled,
        live: target.map { "\(present): \($0)" } ?? present
      )

    case "skills_list":
      let target = firstString(args, ["category"]) ?? context
      let settled = outcome.isFailure ? "Failed to list skills" : "Listed skills"
      return Spec(
        icon: .skill, category: .other, target: target,
        settled: target.map { "\(settled): \($0)" } ?? settled,
        live: target.map { "Listing skills: \($0)" } ?? "Listing skills"
      )

    case "delegate_task":
      let goals = delegateGoals(args)
      let target: String?
      switch goals.count {
      case 0: target = firstString(args, ["action"]).map { action in
          [action, firstString(args, ["subagent_id"])].compactMap { $0 }.joined(separator: " ")
        } ?? context.map { compact($0, Width.phrase) }
      case 1: target = compact(goals[0], Width.phrase)
      default: target = "\(goals.count) tasks"
      }
      return titled(.delegate, .delegate, target: target, past: "Delegated", present: "Delegating",
                    fallbackPast: "Delegated task", fallbackPresent: "Delegating task")

    case "memory":
      // A refused (over-budget) write is not "Saved" (desktop `memoryWriteNoted`).
      let missed = hasResult && outcome != .success
      return fixed(.memory, .other, missed ? "Memory write noted" : "Saved to memory", "Saving to memory",
                   target: context)

    case "todo": return fixed(.generic, .other, "Updated todos", "Updating todos")
    case "clarify": return fixed(.generic, .other, "Asked a question", "Asking a question")
    case "cronjob": return fixed(.generic, .other, "Cron job", "Scheduling cron job", target: context)

    default:
      return fallbackSpec(name: name, args: args, context: context)
    }
  }

  /// Unknown tool: humanized name (`foo_bar` → "Foo bar") + its context (else the primary
  /// arg, as `agent/display.py` derives `context`). `browser_*` / `web_*` keep their family.
  private static func fallbackSpec(name: String, args: [String: JSONValue], context: String?) -> Spec {
    let target = context.map { compact($0, Width.line) } ?? primaryArgPreview(args)
    var icon = Icon.generic
    var category = RunCategory.other
    var past = humanize(name)
    var present = "Running \(past.lowercased())"
    for (prefix, label) in [("browser_", "Browser"), ("web_", "Web")] where name.hasPrefix(prefix) {
      let action = humanize(String(name.dropFirst(prefix.count))).lowercased()
      icon = .web
      category = prefix == "browser_" ? .interact : .other
      past = "\(label) \(action)"
      present = "Running \(label.lowercased()) \(action)"
    }
    if name.hasPrefix("skill") { icon = .skill }
    return Spec(
      icon: icon, category: category, target: target,
      settled: target.map { "\(past): \($0)" } ?? past,
      live: target.map { "\(present): \($0)" } ?? present
    )
  }
}

// MARK: - Outcome heuristics (desktop `toolStatus` / `toolErrorText` / `extractToolErrorMessage`)

extension ToolPresentation {
  private static let errorKeys = ["error", "errors", "failure", "exception"]
  private static let errorMessageKeys = ["message", "reason", "detail"]
  private static let wrapperKeys = ["data", "result", "output", "response", "payload"]
  private static let nonErrorText: Set<String> = [
    "", "0", "false", "none", "null", "nil", "ok", "success", "n/a", "na",
  ]
  private static let failedStatus = #"^(error|failed|failure|fatal|exception)$"#

  private static func outcome(name: String, result: JSONValue?) -> Outcome {
    guard let result else { return .unknown }
    let record = object(result) ?? [:]
    // Explicit success wins over every nested-error heuristic.
    if record["success"] == .bool(true) || record["ok"] == .bool(true) { return .success }
    guard let error = errorText(result: result, record: record) else { return .success }
    // A guessed read path missing is routine exploration; `grep` / `diff` exit 1 is not a
    // broken command; a refused skill patch and an over-budget memory write are negotiations.
    if name == "read_file", error.lowercased().hasPrefix("file not found:") { return .notice(error) }
    if name == "terminal", error == "Command failed with exit code 1." { return .notice(error) }
    if name == "skill_manage", !neutralFailureRolledBackBadly(result: result, record: record) {
      return .notice(error)
    }
    if name == "memory" { return .notice(error) }
    return .failure(error)
  }

  private static func neutralFailureRolledBackBadly(result: JSONValue, record: [String: JSONValue]) -> Bool {
    let error = record["error"]?.displayString ?? result.stringValue ?? ""
    return error.contains("ROLLBACK FAILED")
  }

  private static func errorText(result: JSONValue, record: [String: JSONValue]) -> String? {
    if let nested = nestedError(result, depth: 0, failed: false) { return nested }
    if record["success"] == .bool(false) || record["ok"] == .bool(false) {
      return firstString(record, errorMessageKeys) ?? "Tool returned success=false."
    }
    if let status = record["status"]?.stringValue?.trimmingCharacters(in: .whitespaces),
       status.range(of: failedStatus, options: [.regularExpression, .caseInsensitive]) != nil {
      return firstString(record, errorMessageKeys) ?? "Tool returned status \"\(status)\"."
    }
    // A non-zero exit alone is weak (grep no-match, diff differences): a failure only when
    // the command produced no output to show.
    if let exit = number(record["exit_code"]), exit != 0 {
      let hasOutput = firstString(record, ["output", "stdout", "stderr", "output_preview"]) != nil
      return hasOutput ? nil : "Command failed with exit code \(formatNumber(exit))."
    }
    return nil
  }

  private static func nestedError(_ value: JSONValue?, depth: Int, failed: Bool) -> String? {
    guard depth <= 5, let value = value.map(normalized) else { return nil }
    switch value {
    case let .array(items):
      for item in items {
        if let nested = nestedError(item, depth: depth + 1, failed: failed) { return nested }
      }
      return nil
    case let .object(record):
      if record["success"] == .bool(true) || record["ok"] == .bool(true) { return nil }
      for key in errorKeys where isMeaningfulError(record[key]) {
        if let text = valueErrorText(record[key]) { return text }
      }
      let signal = hasErrorSignal(record)
      if signal, let direct = firstString(record, errorMessageKeys) { return clipBlock(direct) }
      // Returned data can describe failures without the tool failing — only unwrap it to
      // explain a failure the envelope already declared.
      let declared = failed || signal
      let keys = declared ? errorKeys + wrapperKeys + ["details"] : errorKeys
      for key in keys {
        if let nested = nestedError(record[key], depth: depth + 1, failed: declared) { return nested }
      }
      return nil
    default:
      return nil
    }
  }

  private static func valueErrorText(_ value: JSONValue?) -> String? {
    guard let value = value.map(normalized) else { return nil }
    switch value {
    case let .string(text):
      return isMeaningfulError(value) ? clipBlock(text) : nil
    case let .array(items):
      let joined = items.compactMap(valueErrorText).prefix(3).joined(separator: "; ")
      return joined.isEmpty ? nil : clipBlock(joined)
    case let .object(record):
      return firstString(record, errorMessageKeys).map(clipBlock)
    default:
      return nil
    }
  }

  private static func isMeaningfulError(_ value: JSONValue?) -> Bool {
    guard let value = value.map(normalized) else { return false }
    switch value {
    case .null: return false
    case let .string(text):
      return !nonErrorText.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    case let .bool(flag): return flag
    case let .number(n): return n != 0
    case let .array(items): return items.contains { isMeaningfulError($0) }
    case let .object(record): return !record.isEmpty
    }
  }

  private static func hasErrorSignal(_ record: [String: JSONValue]) -> Bool {
    let status = record["status"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    return record["success"] == .bool(false) || record["ok"] == .bool(false)
      || status.range(of: failedStatus, options: [.regularExpression, .caseInsensitive]) != nil
      || errorKeys.contains { isMeaningfulError(record[$0]) }
  }

  /// First 12 lines / 700 chars of an error message, `…` when clipped.
  private static func clipBlock(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = trimmed.components(separatedBy: "\n")
    var text = lines.prefix(12).joined(separator: "\n")
    let clipped = lines.count > 12 || text.count > 700
    if text.count > 700 {
      text = String(text.prefix(699)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return clipped && !text.hasSuffix("…") ? text + "…" : text
  }
}

// MARK: - Body (what an expanded call shows)

extension ToolPresentation {
  /// One search result: a web hit (title + link + snippet) or a file match (`path:line` +
  /// the matched line).
  public struct SearchHit: Equatable, Sendable {
    public let title: String
    public let url: String?
    public let snippet: String?

    public init(title: String, url: String? = nil, snippet: String? = nil) {
      self.title = title
      self.url = url
      self.snippet = snippet
    }
  }

  /// The purpose-built body an expanded call renders. Texts are display-clean (ANSI stripped,
  /// see `ToolOutputFormatting.clean`) and FULL — the sheet shows them as is, the inline body
  /// goes through `inline()` for the capped head.
  public enum Body: Equatable, Sendable {
    /// `$ command` + exit badge + output. `command` is nil for `execute_code` (a script, not a
    /// shell line — the sheet's raw args carry it).
    case terminal(command: String?, exitCode: Int?, stdout: String?, stderr: String?)
    /// An edit diff (`inline_diff`, else a `patch` result's `diff`).
    case diff(path: String?, lines: [DiffLine])
    /// The file read, its `L10-40` range, and the returned (line-numbered) content.
    case fileRead(path: String, range: String?, content: String?)
    /// The query, the first `maxSearchHits` hits, and the server's total when it reports one.
    case search(query: String?, hits: [SearchHit], totalCount: Int?)
    case webPage(url: String, content: String?)
    case skill(name: String, file: String?, description: String?)
    case delegate(goals: [String])
    /// Anything without a dedicated body: a headline summary plus the pretty-printed result
    /// (or, while running, the args) — never hides data.
    case generic(summary: String?, raw: String?)
    /// A settled call carrying no result — a reloaded session keeps only edit-tool output.
    case unavailable(note: String)
  }

  /// A body cut to the inline caps, with whether anything was cut.
  public struct InlineBody: Equatable, Sendable {
    public let body: Body
    public let isTruncated: Bool
  }

  public static let maxSearchHits = 6
  public static let unavailableNote = "Output isn't kept in history"

  /// The expanded call's body, built on demand. Lenient: a call whose shape doesn't match its
  /// tool's body falls back to `.generic` with whatever it carries.
  public var body: Body {
    Self.body(
      name: name, args: args, result: resultValue, inlineDiff: inlineDiff,
      context: context, isRunning: isRunning
    )
  }

  private static func body(
    name: String, args: [String: JSONValue], result: JSONValue?, inlineDiff: String?,
    context: String?, isRunning: Bool
  ) -> Body {
    let record = object(result) ?? [:]
    // Edit diffs, skill and delegate bodies come from what a reloaded call still carries
    // (inline_diff, args); everything else is output-only.
    let hasOutput = result != nil || isRunning
    let unavailable = Body.unavailable(note: unavailableNote)
    let generic = { genericBody(args: args, result: result, record: record, context: context) }

    switch name {
    case "terminal", "execute_code":
      guard hasOutput else { return unavailable }
      let command = name == "terminal" ? firstString(args, commandKeys) ?? context : nil
      let streams = outputStreams(result: result, record: record)
      return .terminal(
        command: command, exitCode: integer(record["exit_code"]),
        stdout: streams.stdout, stderr: streams.stderr
      )

    case "read_file":
      guard hasOutput else { return unavailable }
      guard let path = firstString(args, pathKeys) ?? context else { return generic() }
      let content = result?.stringValue.flatMap { parseJSONLike($0) == nil ? $0 : nil }
        ?? rawString(record, ["content", "text", "data", "body"])
      return .fileRead(
        path: path, range: readFileLineLabel(args: args, result: record),
        content: ToolOutputFormatting.clean(content)
      )

    case "write_file", "patch", "edit_file":
      let diff = [inlineDiff, rawString(record, ["inline_diff", "diff"])]
        .lazy.compactMap { $0 }.map(ToolOutputFormatting.diffLines).first { !$0.isEmpty }
      if let diff {
        let path = diff.first { $0.kind == .file }?.text
          ?? firstString(args, pathKeys)
          ?? firstString(record, pathKeys + ["resolved_path"])
        return .diff(path: path, lines: diff)
      }
      return hasOutput ? generic() : unavailable

    case "search_files":
      guard hasOutput else { return unavailable }
      return .search(
        query: firstString(args, ["pattern", "query"]) ?? context,
        hits: fileSearchHits(record), totalCount: integer(record["total_count"])
      )

    case "web_search":
      guard hasOutput else { return unavailable }
      return .search(
        query: firstString(args, ["query", "search_term"]) ?? context,
        hits: webSearchHits(result), totalCount: nil
      )

    case "web_extract", "browser_navigate":
      guard hasOutput else { return unavailable }
      guard let url = firstURL(.object(args)) ?? firstString(record, ["url"])
        ?? context.flatMap({ firstURL(.string($0)) }) else { return generic() }
      return .webPage(url: url, content: ToolOutputFormatting.clean(pageContent(record)))

    case "skill_view":
      guard let skill = firstString(args, ["name"]) ?? firstString(record, ["name"]) ?? context else {
        return hasOutput ? generic() : unavailable
      }
      return .skill(
        name: skill, file: firstString(args, ["file_path"]),
        description: firstString(record, ["description"])
      )

    case "delegate_task":
      let goals = delegateGoals(args)
      if !goals.isEmpty { return .delegate(goals: goals) }
      return hasOutput ? generic() : unavailable

    default:
      return hasOutput ? generic() : unavailable
    }
  }

  /// `stdout` / `stderr` when the backend splits them, else `output` (`terminal`,
  /// `execute_code`) or `lines`; a non-JSON result is the output itself.
  private static func outputStreams(
    result: JSONValue?, record: [String: JSONValue]
  ) -> (stdout: String?, stderr: String?) {
    if case let .string(text)? = result, parseJSONLike(text) == nil {
      return (ToolOutputFormatting.clean(text), nil)
    }
    let lines = record["lines"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n")
    let stdout = rawString(record, ["stdout", "output"]) ?? lines
    return (ToolOutputFormatting.clean(stdout), ToolOutputFormatting.clean(rawString(record, ["stderr"])))
  }

  /// `web_extract`'s page text: a direct field, else every `results[]` page joined.
  private static func pageContent(_ record: [String: JSONValue]) -> String? {
    let contentKeys = ["content", "text", "markdown", "body"]
    if let direct = rawString(record, contentKeys) { return direct }
    let pages = (record["results"]?.arrayValue ?? []).compactMap { item in
      object(item).flatMap { rawString($0, contentKeys) }
    }
    return pages.isEmpty ? nil : pages.joined(separator: "\n\n---\n\n")
  }

  /// `search_files` hits: `matches[]` (`path`, `line`, `content`), the path-grouped
  /// `matches_text` the server sends for larger result sets, `files[]`, or `counts`.
  private static func fileSearchHits(_ record: [String: JSONValue]) -> [SearchHit] {
    var hits: [SearchHit] = []
    if let matches = record["matches"]?.arrayValue {
      hits = matches.compactMap { item in
        guard let match = object(item), let path = firstString(match, ["path", "file"]) else { return nil }
        let line = integer(match["line"] ?? match["line_number"]).map { ":\($0)" } ?? ""
        return SearchHit(title: path + line, snippet: firstString(match, ["content", "text"]).map { compact($0, Width.snippet) })
      }
    } else if let dense = record["matches_text"]?.stringValue {
      hits = denseMatchHits(dense)
    } else if let files = record["files"]?.arrayValue {
      hits = files.compactMap { $0.stringValue?.trimmedNonEmpty }.map { SearchHit(title: $0) }
    } else if case let .object(counts)? = record["counts"] {
      hits = counts.keys.sorted().map { path in
        let count = integer(counts[path]) ?? 0
        return SearchHit(title: path, snippet: "\(count) \(count == 1 ? "match" : "matches")")
      }
    }
    return Array(hits.prefix(maxSearchHits))
  }

  /// `matches_text`: a path on its own line, then indented `<line>: <content>` rows.
  private static func denseMatchHits(_ text: String) -> [SearchHit] {
    var hits: [SearchHit] = []
    var path: String?
    for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      guard line.first?.isWhitespace == true else {
        path = line.trimmingCharacters(in: .whitespaces)
        continue
      }
      guard let path else { continue }
      let row = line.trimmingCharacters(in: .whitespaces)
      if let colon = row.firstIndex(of: ":"), let number = Int(row[..<colon]) {
        let content = row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        hits.append(SearchHit(title: "\(path):\(number)", snippet: content.nonEmpty.map { compact($0, Width.snippet) }))
      } else {
        hits.append(SearchHit(title: path, snippet: compact(row, Width.snippet)))
      }
      if hits.count == maxSearchHits { break }
    }
    return hits
  }

  /// `web_search` hits, found where the desktop looks (`extractSearchResults`): a top-level
  /// list, a known list key (`web`, `results`, …), else inside a `data`-style wrapper.
  private static func webSearchHits(_ result: JSONValue?) -> [SearchHit] {
    let hits = collectResultItems(result, depth: 0).lazy.compactMap { item -> SearchHit? in
      guard let hit = object(item) else { return nil }
      let title = firstString(hit, ["title", "name"]).map { compact($0, Width.line) }
      let url = firstString(hit, ["url", "href", "link"])
      guard let shown = title ?? url else { return nil }
      return SearchHit(
        title: shown, url: url,
        snippet: firstString(hit, ["snippet", "description", "body"]).map { compact($0, Width.snippet) }
      )
    }
    return Array(hits.prefix(maxSearchHits))
  }

  private static let resultListKeys = [
    "web", "results", "search_results", "sources", "web_sources", "items", "organic_results",
    "organic", "matches", "documents",
  ]

  private static func collectResultItems(_ value: JSONValue?, depth: Int) -> [JSONValue] {
    guard depth <= 5, let value = value.map(normalized) else { return [] }
    if case let .array(items) = value { return items }
    guard case let .object(record) = value else { return [] }
    for key in resultListKeys {
      switch record[key] {
      case let .array(items)?: return items
      case let .object(nested)?:
        let items = collectResultItems(.object(nested), depth: depth + 1)
        if !items.isEmpty { return items }
      default: continue
      }
    }
    for key in wrapperKeys {
      if let payload = record[key], payload != .null { return collectResultItems(payload, depth: depth + 1) }
    }
    return []
  }

  /// The generic body: a headline from the result's message-like field and the pretty
  /// result — or, with no result yet, the pretty args; the context when there is nothing else.
  private static func genericBody(
    args: [String: JSONValue], result: JSONValue?, record: [String: JSONValue], context: String?
  ) -> Body {
    let summary = firstString(record, ["message", "summary", "analysis", "answer", "description"])
    let raw: String?
    if let result, result != .object([:]), result != .array([]) {
      raw = ToolOutputFormatting.clean(result.displayString)
    } else if !args.isEmpty {
      raw = JSONValue.object(args).displayString
    } else {
      raw = nil
    }
    return .generic(summary: summary ?? (raw == nil ? context : nil), raw: raw)
  }
}

extension ToolPresentation.Body {
  /// This body cut to the inline caps (`ToolOutputFormatting.inlineLineLimit` lines /
  /// `inlineCharacterLimit` characters across its text), with whether anything was cut.
  public func inline() -> ToolPresentation.InlineBody {
    var budget = Budget(
      lines: ToolOutputFormatting.inlineLineLimit, characters: ToolOutputFormatting.inlineCharacterLimit
    )
    switch self {
    case let .terminal(command, exitCode, stdout, stderr):
      let out = budget.take(stdout)
      let err = budget.take(stderr)
      return .init(
        body: .terminal(command: command, exitCode: exitCode, stdout: out, stderr: err),
        isTruncated: budget.truncated
      )
    case let .diff(path, diffLines):
      return .init(body: .diff(path: path, lines: budget.take(diffLines)), isTruncated: budget.truncated)
    case let .fileRead(path, range, content):
      return .init(body: .fileRead(path: path, range: range, content: budget.take(content)), isTruncated: budget.truncated)
    case let .webPage(url, content):
      return .init(body: .webPage(url: url, content: budget.take(content)), isTruncated: budget.truncated)
    case let .generic(summary, raw):
      let headline = budget.take(summary)
      let detail = budget.take(raw)
      return .init(body: .generic(summary: headline, raw: detail), isTruncated: budget.truncated)
    case .search, .skill, .delegate, .unavailable:
      return .init(body: self, isTruncated: false)
    }
  }

  /// A shared line / character budget spent across a body's texts in order.
  private struct Budget {
    var lines: Int
    var characters: Int
    var truncated = false

    mutating func take(_ text: String?) -> String? {
      guard let text, !text.isEmpty else { return text }
      guard lines > 0, characters > 0 else {
        truncated = true
        return nil
      }
      let capped = ToolOutputFormatting.cap(text, lines: lines, characters: characters)
      truncated = truncated || capped.isTruncated
      lines -= capped.text.split(separator: "\n", omittingEmptySubsequences: false).count
      characters -= capped.text.count
      return capped.text.isEmpty ? nil : capped.text
    }

    mutating func take(_ diffLines: [DiffLine]) -> [DiffLine] {
      var kept: [DiffLine] = []
      for line in diffLines {
        guard lines > 0, characters > 0 else {
          truncated = true
          break
        }
        let text = line.text.count > characters ? String(line.text.prefix(characters)) : line.text
        if text.count < line.text.count { truncated = true }
        kept.append(DiffLine(kind: line.kind, text: text))
        lines -= 1
        characters -= max(text.count, 1)
      }
      return kept
    }
  }
}

// MARK: - Value helpers

extension ToolPresentation {
  /// The arg / result keys a file path arrives under.
  private static let pathKeys = ["path", "file", "filepath"]
  /// The arg keys a shell command arrives under.
  private static let commandKeys = ["command", "code"]

  /// `compact` widths, in characters.
  private enum Width {
    /// A quoted query / question in a call line.
    static let query = 48
    /// A prompt, goal or step label.
    static let phrase = 80
    /// A command, context or hit title.
    static let line = 160
    /// A search hit's snippet.
    static let snippet = 300
  }

  /// An object from a value, parsing a JSON-object string (args arrive both ways).
  static func object(_ value: JSONValue?) -> [String: JSONValue]? {
    switch value {
    case let .object(record): return record
    case let .string(text):
      if case let .object(record)? = parseJSONLike(text) { return record }
      return nil
    default: return nil
    }
  }

  /// The result to judge: the structured `result`, else `resultText` (parsed when it is
  /// JSON-shaped). `nil` when the call carries no result at all.
  private static func resultValue(result: JSONValue?, resultText: String?) -> JSONValue? {
    if let result, result != .null { return result }
    guard let text = resultText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return parseJSONLike(text) ?? .string(text)
  }

  /// A string that encodes a JSON object, array or string, decoded; else nil (a bare number
  /// or boolean stays text).
  private static func parseJSONLike(_ text: String) -> JSONValue? {
    switch JSONValue(parsing: text) {
    case let value? where value.isObject || value.arrayValue != nil || value.stringValue != nil: value
    default: nil
    }
  }

  /// Desktop `norm`: a JSON-shaped string is read as the value it encodes.
  private static func normalized(_ value: JSONValue) -> JSONValue {
    if case let .string(text) = value, let parsed = parseJSONLike(text) { return parsed }
    return value
  }

  /// First non-blank string among `keys`, trimmed.
  private static func firstString(_ record: [String: JSONValue], _ keys: [String]) -> String? {
    for key in keys {
      if let text = record[key]?.stringValue?.trimmedNonEmpty { return text }
    }
    return nil
  }

  /// First non-blank string among `keys`, UNtrimmed — output and file content keep their
  /// leading indentation.
  private static func rawString(_ record: [String: JSONValue], _ keys: [String]) -> String? {
    for key in keys {
      if let text = record[key]?.stringValue, text.trimmedNonEmpty != nil { return text }
    }
    return nil
  }

  private static func number(_ value: JSONValue?) -> Double? {
    switch value {
    case let .number(n)?: return n.isFinite ? n : nil
    case let .string(text)?: return Double(text.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  /// A model-written number as an `Int` (truncated), or nil past ±1e15 — so no conversion or
  /// later arithmetic on it can trap.
  private static func integer(_ value: JSONValue?) -> Int? {
    number(value).flatMap(integer)
  }

  private static func integer(_ value: Double) -> Int? {
    abs(value) < 1e15 ? Int(value) : nil
  }

  private static func formatNumber(_ value: Double) -> String {
    guard value == value.rounded(), let whole = integer(value) else { return String(value) }
    return String(whole)
  }

  /// One line, whitespace collapsed, capped at `max` with `…`.
  private static func compact(_ value: String, _ max: Int) -> String {
    let line = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.count > max ? String(line.prefix(max - 1)) + "…" : line
  }

  /// A model-authored context sometimes opens with the verb the title prepends
  /// ("Running grep …") — drop it so the verb appears once.
  private static func withoutLeadingVerb(_ value: String) -> String {
    let parts = value.split(separator: " ", maxSplits: 1)
    guard parts.count == 2, ["ran", "running"].contains(parts[0].lowercased()) else { return value }
    return String(parts[1])
  }

  private static func basename(_ path: String) -> String {
    let normalized = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces)
    return normalized.split(separator: "/").last.map(String.init) ?? normalized
  }

  /// A context that is a bare path shows its file name; anything else stays as is.
  private static func displayPath(_ context: String) -> String {
    let looksLikePath = context.range(of: #"^(?:/|\.{1,2}/|~/)\S+$"#, options: .regularExpression) != nil
    return looksLikePath ? basename(context) : compact(context, Width.line)
  }

  /// `L10` / `L10-40` from `offset` / `limit`, else from the `N|` line numbers of the
  /// returned content; nil when the call read the whole file.
  private static func readFileLineLabel(args: [String: JSONValue], result: [String: JSONValue]) -> String? {
    let offset = args["offset"]?.doubleValue
    let limit = args["limit"]?.doubleValue
    guard offset != nil || limit != nil else { return nil }
    if let start = offset.flatMap(integer), start > 0 {
      guard let lines = limit.flatMap(integer), lines > 1 else { return "L\(start)" }
      return "L\(start)-\(start + lines - 1)"
    }
    let numbers = (firstString(result, ["content"]) ?? "")
      .split(separator: "\n")
      .compactMap { line -> Int? in
        guard let bar = line.firstIndex(of: "|") else { return nil }
        return Int(line[line.startIndex..<bar])
      }
    guard let first = numbers.first, let last = numbers.last else { return nil }
    return first == last ? "L\(first)" : "L\(first)-\(last)"
  }

  private static let urlPattern = #"https?://[^\s'"<>)\]]+"#

  /// First http(s) URL anywhere in a value; `url` / `urls` keys first, then the rest in key
  /// order so the walk is deterministic.
  private static func firstURL(_ value: JSONValue) -> String? {
    switch value {
    case let .string(text):
      guard let range = text.range(of: urlPattern, options: [.regularExpression, .caseInsensitive]) else {
        return nil
      }
      return String(text[range])
    case let .array(items):
      return items.lazy.compactMap(firstURL).first
    case let .object(record):
      let preferred = ["urls", "url"].filter { record[$0] != nil }
      let rest = record.keys.filter { !preferred.contains($0) }.sorted()
      return (preferred + rest).lazy.compactMap { record[$0].flatMap(firstURL) }.first
    default:
      return nil
    }
  }

  /// `host/path` of a URL (desktop `hostnameOf`); the input when it doesn't parse.
  static func hostAndPath(_ value: String) -> String {
    guard let url = URLComponents(string: value), let host = url.host, !host.isEmpty else { return value }
    let path = url.path
    return path.isEmpty || path == "/" ? host : host + path
  }

  /// The first meaningful line of a code blob (skips blanks and `#` comments).
  private static func firstCodeLine(_ code: String) -> String? {
    code.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty && !$0.hasPrefix("#") }
  }

  /// `browser_exec` code opens with a `# …` step comment (agent/display.py).
  private static func browserExecStepLabel(_ code: String) -> String? {
    let first = code.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\n", maxSplits: 1).first.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    guard first.hasPrefix("#") else { return nil }
    let label = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { return nil }
    return compact(label, Width.phrase)
  }

  /// `tasks[].goal`, else `goal`.
  private static func delegateGoals(_ args: [String: JSONValue]) -> [String] {
    if let tasks = args["tasks"]?.arrayValue {
      let goals = tasks.compactMap { object($0).flatMap { firstString($0, ["goal"]) } }
      if !goals.isEmpty { return goals }
    }
    return firstString(args, ["goal"]).map { [$0] } ?? []
  }

  /// The unknown tool's primary arg, as `agent/display.py` `_FALLBACK_PREVIEW_KEYS` picks it.
  private static func primaryArgPreview(_ args: [String: JSONValue]) -> String? {
    for key in ["query", "text", "command", "path", "name", "prompt", "code", "goal"] {
      switch args[key] {
      case let .string(text)?:
        if let text = text.trimmedNonEmpty { return compact(text, Width.line) }
      case let .array(items)?:
        if let text = items.first?.stringValue?.trimmedNonEmpty { return compact(text, Width.line) }
      default:
        continue
      }
    }
    return nil
  }

  /// `foo_bar` → "Foo bar"; an empty name reads "Tool".
  static func humanize(_ name: String) -> String {
    let words = name.split { $0 == "_" || $0 == "-" || $0.isWhitespace }.map(String.init)
    guard let first = words.first else { return "Tool" }
    return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
  }
}

// MARK: - Shell command summary (desktop `summarizeShellCommand`)

extension ToolPresentation {
  private static let silentHeads: Set<String> = [
    "cd", "pushd", "popd", "export", "set", "unset", "source", ".", "true", "false", ":",
  ]
  private static let pipeTailHeads: Set<String> = ["head", "tail", "wc", "sort", "uniq"]

  /// Reduces an agent's plumbing-wrapped command (`cd dir && cmd 2>&1 | tail -20; echo
  /// "x_exit=${PIPESTATUS[0]}"`) to the command the user cares about — display only. Several
  /// real commands read "first + N commands".
  static func summarizeShellCommand(_ raw: String) -> String {
    let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !original.isEmpty else { return "" }
    let segments = splitCompound(original)
    // A single segment still loses its pipe tail (`npm test 2>&1 | tail -20` → `npm test`);
    // the desktop cleans the unsplit original there, keeping the tail.
    if segments.count <= 1 { return cleanSegment(segments.first ?? original).nonEmpty ?? original }
    let core = segments.map(cleanSegment).filter {
      !$0.isEmpty && !silentHeads.contains(headWord($0)) && !isBoundaryEcho($0)
    }
    switch core.count {
    case 0: return original
    case 1: return core[0]
    default: return "\(core[0]) + \(core.count - 1) \(core.count == 2 ? "command" : "commands")"
    }
  }

  /// Splits on top-level `&&` `||` `;` and newlines (quote-aware), not on pipes; each
  /// segment loses its trailing `| head`-style pipe tail.
  private static func splitCompound(_ input: String) -> [String] {
    let chars = Array(input)
    var segments: [String] = []
    var buffer = ""
    var quote: Character?
    var i = 0
    while i < chars.count {
      let ch = chars[i]
      if let open = quote {
        buffer.append(ch)
        if ch == open, i == 0 || chars[i - 1] != "\\" { quote = nil }
        i += 1
        continue
      }
      if ch == "\"" || ch == "'" {
        quote = ch
        buffer.append(ch)
        i += 1
        continue
      }
      let pair = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
      if pair == "&&" || pair == "||" {
        segments.append(buffer)
        buffer = ""
        i += 2
        continue
      }
      if ch == ";" || ch == "\n" {
        segments.append(buffer)
        buffer = ""
        i += 1
        continue
      }
      buffer.append(ch)
      i += 1
    }
    segments.append(buffer)
    return segments
      .map { stripPipeTail($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { !$0.isEmpty }
  }

  private static func splitWords(_ segment: String) -> [String] {
    let chars = Array(segment)
    var words: [String] = []
    var buffer = ""
    var quote: Character?
    for (i, ch) in chars.enumerated() {
      if let open = quote {
        buffer.append(ch)
        if ch == open, i == 0 || chars[i - 1] != "\\" { quote = nil }
        continue
      }
      if ch == "\"" || ch == "'" {
        quote = ch
        buffer.append(ch)
        continue
      }
      if ch.isWhitespace {
        if !buffer.isEmpty { words.append(buffer); buffer = "" }
        continue
      }
      buffer.append(ch)
    }
    if !buffer.isEmpty { words.append(buffer) }
    return words
  }

  private static func commandBasename(_ head: String) -> String {
    head.split(separator: "/").last.map(String.init) ?? head
  }

  /// The command word, skipping `FOO=bar` env assignments.
  private static func headWord(_ segment: String) -> String {
    let tokens = splitWords(segment)
    let head = tokens.first { $0.range(of: #"^[A-Za-z_]\w*="#, options: .regularExpression) == nil }
    return commandBasename(head ?? "")
  }

  private static func stripPipeTail(_ segment: String) -> String {
    let words = splitWords(segment)
    var out: [String] = []
    for (i, word) in words.enumerated() {
      if word == "|", i + 1 < words.count, pipeTailHeads.contains(commandBasename(words[i + 1])) { break }
      out.append(word)
    }
    return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
  }

  /// Drops redirects (`2>&1`, `> out.log`, `< in`).
  private static func cleanSegment(_ segment: String) -> String {
    let words = splitWords(segment)
    var out: [String] = []
    var i = 0
    while i < words.count {
      let word = words[i]
      if word.range(of: #"^\d*(?:>>?|<)$"#, options: .regularExpression) != nil {
        i += 2
        continue
      }
      if word.range(of: #"^\d*(?:>&|<&)\d+$"#, options: .regularExpression) != nil {
        i += 1
        continue
      }
      out.append(word)
      i += 1
    }
    return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
  }

  /// Banner / status echoes (`echo "---"`, `echo "x_exit=$?"`) are plumbing; a plain
  /// `echo $VALUE` may be the real output and stays.
  private static func isBoundaryEcho(_ segment: String) -> Bool {
    let words = splitWords(segment)
    guard let first = words.first, commandBasename(first) == "echo" else { return false }
    let rest = words.dropFirst().joined(separator: " ")
    return rest.range(of: #"-{2,}|_exit=|(?:^|\s|=)\$[?{]|PIPESTATUS"#, options: .regularExpression) != nil
  }
}
