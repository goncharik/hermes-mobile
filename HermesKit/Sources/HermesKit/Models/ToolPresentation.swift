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
  public enum Icon: String, Equatable, Sendable, CaseIterable {
    case terminal, file, edit, search, web, eye, skill, delegate, memory, generic
  }

  /// Run-summary category. Declaration order IS the desktop's clause order
  /// (`run-summary.ts` `CATEGORY_ORDER`), so `allCases` sorts clauses.
  public enum RunCategory: String, Equatable, Sendable, CaseIterable {
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

  /// Classifies a transcript tool row. `call.title` doubles as the context (server
  /// `context` / `summary`) unless it is just the name fallback.
  public init(call: ToolCall) {
    let context = call.title.trimmedNonEmpty.flatMap { $0 == call.name ? nil : $0 }
    self.init(
      name: call.name,
      args: call.detail?.args,
      result: call.detail?.result,
      resultText: call.detail?.resultText,
      inlineDiff: call.detail?.inlineDiff,
      context: context
    )
  }

  public init(
    name: String,
    args: JSONValue?,
    result: JSONValue?,
    resultText: String?,
    inlineDiff: String?,
    context: String?
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

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private static func spec(
    name: String, args: [String: JSONValue], resultRecord: [String: JSONValue], hasResult: Bool,
    inlineDiff: String?, context: String?, outcome: Outcome
  ) -> Spec {
    switch name {
    case "terminal":
      let command = firstString(args, ["command", "code"]) ?? context
      let target = command.map { withoutLeadingVerb(compact(summarizeShellCommand($0), 160)) }?.nonEmpty
      return titled(.terminal, .run, target: target, past: "Ran", present: "Running",
                    fallbackPast: "Ran command", fallbackPresent: "Running command")

    case "execute_code":
      let code = firstString(args, ["code"]) ?? context
      let target = code.flatMap(firstCodeLine).map { compact($0, 160) }
      return titled(.terminal, .run, target: target, past: "Ran code", present: "Scripting",
                    fallbackPast: "Ran code", fallbackPresent: "Scripting")

    case "read_file":
      let target = firstString(args, ["path", "file", "filepath"]).map { path in
        [basename(path), readFileLineLabel(args: args, result: resultRecord)]
          .compactMap { $0 }.joined(separator: " ")
      } ?? context.map(displayPath)
      return titled(.file, .explore, target: target, past: "Read", present: "Reading",
                    fallbackPast: "Read file", fallbackPresent: "Reading file")

    case "list_files":
      let target = firstString(args, ["path", "directory", "dir"]).map(basename) ?? context
      return fixed(.file, .explore, "Listed files", "Listing files", target: target)

    case "write_file", "patch", "edit_file":
      let path = firstString(args, ["path", "file", "filepath"])
        ?? firstString(resultRecord, ["path", "file", "filepath", "resolved_path"])
        ?? diffPath(inlineDiff ?? firstString(resultRecord, ["inline_diff", "diff"]))
      let target = path.map(basename) ?? context.map(displayPath)
      let patch = name == "patch"
      return titled(.edit, .edit, target: target, past: "Edited", present: "Editing",
                    fallbackPast: patch ? "Patched file" : "Edited file",
                    fallbackPresent: patch ? "Patching file" : "Editing file")

    case "search_files":
      let target = (firstString(args, ["pattern", "query"]) ?? context).map { compact($0, 48) }
      return titled(.search, .explore, target: target, past: "Searched", present: "Searching",
                    fallbackPast: "Searched files", fallbackPresent: "Searching files", quoted: true)

    case "web_search":
      let target = (firstString(args, ["query", "search_term"]) ?? context).map { compact($0, 48) }
      return titled(.search, .search, target: target, past: "Searched", present: "Searching",
                    fallbackPast: "Searched web", fallbackPresent: "Searching web", quoted: true)

    case "session_search_recall", "session_search":
      let target = (firstString(args, ["query"]) ?? context).map { compact($0, 48) }
      return titled(.search, .search, target: target, past: "Searched history for",
                    present: "Searching history for",
                    fallbackPast: "Searched session history", fallbackPresent: "Searching session history",
                    quoted: true)

    case "web_extract":
      let target = (firstURL(.object(args)) ?? context.flatMap { firstURL(.string($0)) }).map(hostAndPath)
      return titled(.web, .read, target: target, past: "Read", present: "Reading",
                    fallbackPast: "Read webpage", fallbackPresent: "Reading webpage")

    case "browser_navigate":
      let target = (firstURL(.object(args)) ?? context.flatMap { firstURL(.string($0)) }).map(hostAndPath)
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
      let target = (firstString(args, ["question"]) ?? context).map { compact($0, 48) }
      return titled(.eye, .analyze, target: target, past: "Analyzed", present: "Analyzing",
                    fallbackPast: "Analyzed image", fallbackPresent: "Analyzing image", quoted: true)

    case "image_generate":
      return fixed(.eye, .other, "Generated image", "Generating image",
                   target: (firstString(args, ["prompt"]) ?? context).map { compact($0, 80) })

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
        } ?? context.map { compact($0, 80) }
      case 1: target = compact(goals[0], 80)
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
    let target = context.map { compact($0, 160) } ?? primaryArgPreview(args)
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

  static func outcome(name: String, result: JSONValue?) -> Outcome {
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

// MARK: - Value helpers

extension ToolPresentation {
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
  static func resultValue(result: JSONValue?, resultText: String?) -> JSONValue? {
    if let result, result != .null { return result }
    guard let text = resultText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return parseJSONLike(text) ?? .string(text)
  }

  /// A string that looks like JSON (`{`, `[` or `"`) decoded; else nil.
  private static func parseJSONLike(_ text: String) -> JSONValue? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first, first == "{" || first == "[" || first == "\"",
          let data = trimmed.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// Desktop `norm`: a JSON-shaped string is read as the value it encodes.
  private static func normalized(_ value: JSONValue) -> JSONValue {
    if case let .string(text) = value, let parsed = parseJSONLike(text) { return parsed }
    return value
  }

  /// First non-blank string among `keys`, trimmed.
  static func firstString(_ record: [String: JSONValue], _ keys: [String]) -> String? {
    for key in keys {
      if let text = record[key]?.stringValue?.trimmedNonEmpty { return text }
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

  private static func formatNumber(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
  }

  /// One line, whitespace collapsed, capped at `max` with `…`.
  static func compact(_ value: String, _ max: Int) -> String {
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

  static func basename(_ path: String) -> String {
    let normalized = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces)
    return normalized.split(separator: "/").last.map(String.init) ?? normalized
  }

  /// A context that is a bare path shows its file name; anything else stays as is.
  private static func displayPath(_ context: String) -> String {
    let looksLikePath = context.range(of: #"^(?:/|\.{1,2}/|~/)\S+$"#, options: .regularExpression) != nil
    return looksLikePath ? basename(context) : compact(context, 160)
  }

  /// `L10` / `L10-40` from `offset` / `limit`, else from the `N|` line numbers of the
  /// returned content; nil when the call read the whole file.
  private static func readFileLineLabel(args: [String: JSONValue], result: [String: JSONValue]) -> String? {
    let offset = args["offset"]?.doubleValue
    let limit = args["limit"]?.doubleValue
    guard offset != nil || limit != nil else { return nil }
    if let offset, offset > 0 {
      let start = Int(offset)
      guard let limit, limit > 1 else { return "L\(start)" }
      return "L\(start)-\(start + Int(limit) - 1)"
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

  /// The edited file's path from a unified diff header (`+++ b/path`, else `--- a/path`).
  private static func diffPath(_ diff: String?) -> String? {
    guard let diff = diff?.strippingANSI else { return nil }
    let lines = diff.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    for marker in ["+++ ", "--- "] {
      for line in lines where line.hasPrefix(marker) {
        var path = String(line.dropFirst(marker.count))
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
        path = path.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        if !path.isEmpty, path != "/dev/null" { return path }
      }
    }
    return nil
  }

  private static let urlPattern = #"https?://[^\s'"<>)\]]+"#

  /// First http(s) URL anywhere in a value; `url` / `urls` keys first, then the rest in key
  /// order so the walk is deterministic.
  static func firstURL(_ value: JSONValue) -> String? {
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
    return label.count > 80 ? String(label.prefix(79)) + "…" : label
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
        if let text = text.trimmedNonEmpty { return compact(text, 160) }
      case let .array(items)?:
        if let text = items.first?.stringValue?.trimmedNonEmpty { return compact(text, 160) }
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
