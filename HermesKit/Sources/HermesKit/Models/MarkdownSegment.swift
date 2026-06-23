import Foundation

/// A chunk of assistant Markdown. Splitting structure out of the raw text lets the UI
/// render code in a monospaced box (Task 11) and lay out block-level constructs that
/// SwiftUI's `Text` can't (#27) — pure and testable, kept out of the view layer.
///
/// Fenced code takes precedence: inside ``` fences nothing else is classified. Outside
/// fences the parser recognizes ATX **headers** (`#`..`######`), **blockquotes** (`>`),
/// GitHub-style pipe **tables** (a header row + a `---` separator row + body rows), and
/// everything else is **prose**. Malformed/odd markup degrades to prose — never crashes.
public enum MarkdownSegment: Equatable, Sendable {
  case prose(String)
  /// A fenced code block: the fence-stripped raw text (whitespace preserved) plus the
  /// optional language hint from the opening fence (e.g. ```` ```swift ````). The raw
  /// `text` is what the per-block copy button (#9) puts on the pasteboard.
  case code(text: String, language: String?)
  /// An ATX header: `level` is 1–6 (number of leading `#`), `text` is the trimmed title
  /// (trailing closing `#` run stripped). Inline Markdown still applies to `text`.
  case heading(level: Int, text: String)
  /// A blockquote: one or more consecutive `>` lines, with the leading `> ` stripped from
  /// each. `text` joins the stripped lines with newlines. Inline Markdown applies.
  case blockquote(text: String)
  /// A GitHub-style pipe table: the header cells plus zero+ body rows (each an array of
  /// cells). Cells are trimmed; inline Markdown applies within each cell.
  case table(headers: [String], rows: [[String]])

  /// Split `text` into segments. The fence lines themselves are dropped, but the opening
  /// fence's language hint is retained on the code segment. An unterminated fence (as seen
  /// mid-stream) leaves its remainder as code. Empty/whitespace-only prose is omitted.
  ///
  /// Outside fences, headers / blockquotes / tables are classified line-by-line; anything
  /// that doesn't match degrades to prose (lenient).
  public static func parse(_ text: String) -> [MarkdownSegment] {
    var result: [MarkdownSegment] = []
    var inCode = false
    var codeBuffer: [Substring] = []
    var language: String?
    // Pending non-code, non-special lines accumulate here and flush as a single prose block
    // (preserving the original combined-prose behavior and empty-prose omission).
    var proseBuffer: [Substring] = []

    func flushProse() {
      guard !proseBuffer.isEmpty else { return }
      let joined = proseBuffer.joined(separator: "\n")
      proseBuffer.removeAll()
      let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { result.append(.prose(trimmed)) }
    }

    func flushCode() {
      let joined = codeBuffer.joined(separator: "\n")
      codeBuffer.removeAll()
      result.append(.code(text: joined, language: language))
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var i = 0
    while i < lines.count {
      let line = lines[i]
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)

      // Fence handling first — fenced code takes precedence over every block type.
      if trimmedLine.hasPrefix("```") {
        if inCode {
          flushCode()
          inCode = false
          language = nil
        } else {
          flushProse()
          inCode = true
          let hint = trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespaces)
          language = hint.isEmpty ? nil : hint
        }
        i += 1
        continue
      }

      if inCode {
        codeBuffer.append(line)
        i += 1
        continue
      }

      // Header: 1–6 leading `#` followed by a space (or the line being just `#`s + spaces).
      if let heading = parseHeading(trimmedLine) {
        flushProse()
        result.append(heading)
        i += 1
        continue
      }

      // Blockquote: consume consecutive `>` lines into one block.
      if isBlockquoteLine(trimmedLine) {
        flushProse()
        var quoteLines: [String] = []
        while i < lines.count {
          let t = lines[i].trimmingCharacters(in: .whitespaces)
          guard isBlockquoteLine(t) else { break }
          quoteLines.append(stripBlockquoteMarker(t))
          i += 1
        }
        result.append(.blockquote(text: quoteLines.joined(separator: "\n")))
        continue
      }

      // Table: a header pipe row immediately followed by a separator row.
      if isPipeRow(trimmedLine), i + 1 < lines.count {
        let sepTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
        if isSeparatorRow(sepTrimmed) {
          let headers = splitPipeCells(trimmedLine)
          let separatorCols = splitPipeCells(sepTrimmed).count
          if separatorCols == headers.count {
            flushProse()
            var bodyRows: [[String]] = []
            i += 2
            while i < lines.count {
              let t = lines[i].trimmingCharacters(in: .whitespaces)
              guard isPipeRow(t), !isSeparatorRow(t) else { break }
              bodyRows.append(splitPipeCells(t))
              i += 1
            }
            result.append(.table(headers: headers, rows: bodyRows))
            continue
          }
        }
      }

      // Anything else: prose.
      proseBuffer.append(line)
      i += 1
    }

    flushProse()
    if inCode { flushCode() }
    return result
  }

  // MARK: - Block classifiers (pure)

  /// Parse an ATX header line. Returns `nil` unless the line is 1–6 `#`s followed by a
  /// space and some text (the trailing closing-`#` run is stripped).
  static func parseHeading(_ trimmed: String) -> MarkdownSegment? {
    let hashes = trimmed.prefix { $0 == "#" }
    let level = hashes.count
    guard level >= 1, level <= 6 else { return nil }
    let rest = trimmed[hashes.endIndex...]
    // Require a space after the hashes (or end-of-line for a bare `##` → treat as no-text).
    guard rest.first == " " else { return nil }
    var title = rest.trimmingCharacters(in: .whitespaces)
    // Strip an optional closing run of `#` (and surrounding spaces): "## Title ##".
    while title.hasSuffix("#") { title = String(title.dropLast()) }
    title = title.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }
    return .heading(level: level, text: title)
  }

  static func isBlockquoteLine(_ trimmed: String) -> Bool {
    trimmed.hasPrefix(">")
  }

  static func stripBlockquoteMarker(_ trimmed: String) -> String {
    var rest = Substring(trimmed)
    rest = rest.dropFirst() // the ">"
    if rest.first == " " { rest = rest.dropFirst() }
    return String(rest)
  }

  /// A line that looks like a table row: contains a `|` and (after trimming) holds at
  /// least one cell once split.
  static func isPipeRow(_ trimmed: String) -> Bool {
    guard trimmed.contains("|") else { return false }
    return !splitPipeCells(trimmed).isEmpty
  }

  /// A separator row: every cell is made only of `-`, `:`, and spaces and contains at
  /// least one `-`.
  static func isSeparatorRow(_ trimmed: String) -> Bool {
    let cells = splitPipeCells(trimmed)
    guard !cells.isEmpty else { return false }
    for cell in cells {
      let stripped = cell.trimmingCharacters(in: .whitespaces)
      guard !stripped.isEmpty else { return false }
      guard stripped.contains("-") else { return false }
      guard stripped.allSatisfy({ $0 == "-" || $0 == ":" }) else { return false }
    }
    return true
  }

  /// Split a pipe row into trimmed cells, ignoring a single leading/trailing `|` and
  /// treating `\|` as an escaped literal pipe within a cell.
  static func splitPipeCells(_ trimmed: String) -> [String] {
    var cells: [String] = []
    var current = ""
    var escaped = false
    for ch in trimmed {
      if escaped {
        current.append(ch)
        escaped = false
      } else if ch == "\\" {
        escaped = true
      } else if ch == "|" {
        cells.append(current)
        current = ""
      } else {
        current.append(ch)
      }
    }
    cells.append(current)
    // Drop a leading empty cell (from a leading `|`) and a trailing empty cell (trailing `|`).
    if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
    if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
  }
}
