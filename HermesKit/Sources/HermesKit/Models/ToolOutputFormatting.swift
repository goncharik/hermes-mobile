import Foundation

/// One line of an edit diff, classified for tinting (tool-call display plan, Phase C).
public struct DiffLine: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// A file header — `text` is the edited path (`b/` side, `a/` when the file was deleted).
    case file
    /// An `@@ … @@` hunk header, verbatim.
    case hunk
    case added
    case removed
    case context
    /// Anything else, verbatim: the server's "… N diff line(s) omitted" footer,
    /// `\ No newline at end of file`, `diff --git` / `index` lines.
    case note
  }

  public let kind: Kind
  /// The line without its `+` / `-` / ` ` marker; the path for `.file`; verbatim otherwise.
  public let text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

/// A text clipped for the inline (expanded-in-place) body, with whether anything was cut —
/// the view offers "Show all" only when it was.
public struct CappedText: Equatable, Sendable {
  public let text: String
  public let isTruncated: Bool

  public init(text: String, isTruncated: Bool) {
    self.text = text
    self.isTruncated = isTruncated
  }
}

/// Pure display formatting for tool output: ANSI stripping, carriage-return collapsing, the
/// inline caps, and the edit-diff parser. Outside any UIKit guard so it is unit-tested on macOS.
public enum ToolOutputFormatting {
  /// Inline body cap — the full text lives in the detail sheet.
  public static let inlineLineLimit = 12
  public static let inlineCharacterLimit = 2_000

  /// Tool output made readable: ANSI escapes stripped, CRLF normalized, a `\r`-rewritten line
  /// (progress bars) reduced to what a terminal would finally show, blank leading lines and
  /// trailing whitespace dropped. `nil` when nothing visible is left.
  public static func clean(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    let normalized = text.strippingANSI.replacingOccurrences(of: "\r\n", with: "\n")
    var lines = normalized.components(separatedBy: "\n").map { line -> String in
      guard line.contains("\r") else { return line }
      return line.components(separatedBy: "\r").last { !$0.isEmpty } ?? ""
    }
    while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
    let joined = lines.joined(separator: "\n")
    let trimmed = String(joined.reversed().drop(while: \.isWhitespace).reversed())
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The first `lines` lines / `characters` characters of `text`. Scans only as far as the
  /// cap, so a multi-megabyte output costs no more than its head.
  public static func cap(
    _ text: String, lines: Int = inlineLineLimit, characters: Int = inlineCharacterLimit
  ) -> CappedText {
    guard lines > 0, characters > 0 else {
      return CappedText(text: "", isTruncated: text.contains { !$0.isWhitespace })
    }
    var index = text.startIndex
    var lineCount = 1
    var characterCount = 0
    while index < text.endIndex {
      let character = text[index]
      if character.isNewline {
        if lineCount == lines { break }
        lineCount += 1
      }
      if characterCount == characters { break }
      characterCount += 1
      index = text.index(after: index)
    }
    let rest = text[index...]
    let truncated = rest.contains { !$0.isWhitespace }
    var head = String(text[..<index])
    while head.last?.isNewline == true { head.removeLast() }
    return CappedText(text: head, isTruncated: truncated)
  }

  /// Parses an edit diff into classified lines. Reads both shapes the server sends: the
  /// rendered `inline_diff` (`agent/display.py` `_render_inline_unified_diff` — ANSI-colored,
  /// a localized `┊ review diff` header, `a/x → b/x` file lines, an "omitted" footer) and a
  /// raw unified diff (`--- a/x` / `+++ b/x`, a `patch` result's `diff`).
  public static func diffLines(_ diff: String) -> [DiffLine] {
    let lines = diff.strippingANSI.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var result: [DiffLine] = []
    var pendingFrom: String?
    var sawContent = false

    func flushPendingFrom() {
      if let from = pendingFrom { result.append(DiffLine(kind: .file, text: from)) }
      pendingFrom = nil
    }

    for line in lines where !line.isEmpty {
      // The review header (`  ┊ review diff`, localized) opens the rendered shape.
      if !sawContent, line.trimmingCharacters(in: .whitespaces).hasPrefix("┊") { continue }
      sawContent = true
      if line.hasPrefix("--- ") {
        flushPendingFrom()
        pendingFrom = diffHeaderPath(line.dropFirst(4))
        continue
      }
      if line.hasPrefix("+++ ") {
        let path = diffHeaderPath(line.dropFirst(4)) ?? pendingFrom
        pendingFrom = nil
        if let path { result.append(DiffLine(kind: .file, text: path)) }
        continue
      }
      flushPendingFrom()
      if line.hasPrefix("@@") {
        result.append(DiffLine(kind: .hunk, text: line))
      } else if line.hasPrefix("+") {
        result.append(DiffLine(kind: .added, text: String(line.dropFirst())))
      } else if line.hasPrefix("-") {
        result.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
      } else if line.hasPrefix(" ") {
        result.append(DiffLine(kind: .context, text: String(line.dropFirst())))
      } else if let path = renderedFileHeaderPath(line) {
        result.append(DiffLine(kind: .file, text: path))
      } else {
        result.append(DiffLine(kind: .note, text: line))
      }
    }
    flushPendingFrom()
    return result
  }

  /// The edited file's path: the first file header of `diff`, either shape.
  public static func diffPath(_ diff: String?) -> String? {
    guard let diff else { return nil }
    return diffLines(diff).first { $0.kind == .file }?.text
  }

  /// `a/path\t<timestamp>` → `path`; `/dev/null` and blanks → nil.
  private static func diffHeaderPath(_ raw: Substring) -> String? {
    var path = String(raw)
    if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
    return normalizedDiffPath(path)
  }

  /// The rendered shape's `a/x → b/x` header: the `b` side, else the `a` side (a deletion).
  private static func renderedFileHeaderPath(_ line: String) -> String? {
    let parts = line.components(separatedBy: " → ")
    guard parts.count == 2 else { return nil }
    return normalizedDiffPath(parts[1]) ?? normalizedDiffPath(parts[0])
  }

  private static func normalizedDiffPath(_ raw: String) -> String? {
    var path = raw.trimmingCharacters(in: .whitespaces)
    if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
    // `a/?` / `b/?` is the renderer's placeholder for a missing side.
    guard !path.isEmpty, path != "/dev/null", path != "?" else { return nil }
    return path
  }
}
