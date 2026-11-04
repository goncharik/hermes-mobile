import Foundation

/// What the tool detail sheet shows beyond the per-tool body (tool-call display plan, Task 13):
/// the header's duration label and the collapsed "Raw" disclosure. Pure, so the "never hide
/// info" rule is unit-tested on macOS rather than trusted to the view.
extension ToolCall {
  /// One labelled block of the raw payload.
  public struct RawSection: Equatable, Sendable {
    public let label: String
    public let text: String

    public init(label: String, text: String) {
      self.label = label
      self.text = text
    }
  }

  /// Everything the call carried, as pretty text, for the sheet's "Raw" disclosure — the
  /// fallback that guarantees no data is lost however the presentation classified the call.
  ///
  /// - **Context**: the server's `context` / `summary` (the row title), unless it is just the
  ///   name fallback.
  /// - **Arguments**: the structured args pretty-printed, else the verbose `args_text`.
  /// - **Arguments (text)**: `args_text` too when structured args exist and it says something
  ///   neither they nor the context already say.
  /// - **Result**: the structured result pretty-printed, else the result text.
  /// - **Result (text)**: the result text too when it isn't just the structured result
  ///   re-serialized (a separate `result_text`).
  /// - **Diff**: the edit diff (`inline_diff`), ANSI colors stripped.
  ///
  /// Blank values are skipped; an empty array means the call carried nothing at all.
  public var rawSections: [RawSection] {
    var sections: [RawSection] = []
    func add(_ label: String, _ text: String?) {
      guard let text, text.contains(where: { !$0.isWhitespace }) else { return }
      sections.append(RawSection(label: label, text: text))
    }

    let context = title.trimmedNonEmpty.flatMap { $0 == name ? nil : $0 }
    add("Context", context)

    let args = detail?.args?.nonNull?.displayString
    let argsText = detail?.argsText?.trimmedNonEmpty
    // A cooked history row stores its `context` as both the title and `argsText`: say it once.
    add("Arguments", args ?? (argsText == context ? nil : argsText))
    if args != nil, let argsText, argsText != context, !Self.sameJSON(argsText, detail?.args) {
      add("Arguments (text)", argsText)
    }

    let result = detail?.result?.nonNull
    let resultText = detail?.resultText
    add("Result", result?.displayString ?? resultText)
    if result != nil, let resultText, !Self.sameJSON(resultText, result) {
      add("Result (text)", resultText)
    }

    if let diff = detail?.inlineDiff {
      add("Diff", ToolOutputFormatting.clean(diff) ?? diff)
    }
    return sections
  }

  /// Whether `text` is just `value` serialized — compact or pretty JSON of it, or the plain
  /// string a scalar / string value displays as.
  private static func sameJSON(_ text: String, _ value: JSONValue?) -> Bool {
    guard let value = value?.nonNull else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == value.displayString?.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
    guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else { return false }
    return parsed == value
  }
}

extension ToolPresentation {
  /// A tool call's wall-clock duration for the detail sheet's header: tenths under ten seconds
  /// (`"0.4s"`, `"1.4s"`), whole seconds under a minute (`"12s"`), then the turn timer's
  /// `formatElapsed` style (`"2m 5s"`). Under a twentieth of a second reads `"<0.1s"`; a
  /// zero, negative or non-finite value reads `"0s"`.
  public static func durationLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0s" }
    if seconds < 0.05 { return "<0.1s" }
    if seconds < 9.95 { return String(format: "%.1fs", seconds) }
    return formatElapsed(Int(seconds.rounded()))
  }
}
