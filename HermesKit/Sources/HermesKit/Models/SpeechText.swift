import Foundation

// MARK: - SpeechText

/// Turns an assistant reply's markdown into the plain text handed to `POST /api/audio/speak`.
///
/// A step-for-step port of the desktop's `sanitizeTextForSpeech`
/// (`apps/desktop/src/lib/speech-text.ts` @ `69f73ec5f1`) so the phone and the desktop say
/// the same thing for the same reply. Deliberately NOT built on `MarkdownSegment`: its table
/// detection is looser than the desktop's.
///
/// Unspeakable content (code, URLs, `MEDIA:` tokens, identifier-dense tokens) becomes
/// silence, never an English placeholder word (upstream #86602 — the reply may be in any
/// language); a table is announced by its header row only. The identifier rules mirror the
/// server's `tools/tts_text_normalize.py` against the shared
/// `tests/fixtures/identifier_speech_corpus.json` corpus (upstream #119207).
///
/// Patterns run on `NSRegularExpression` (ICU), not Swift `Regex`: ICU matches UTF-16 /
/// scalars like the JS engine, while `Regex` defaults to grapheme clusters (`"\r\n"` and
/// ZWJ emoji sequences are single `Character`s there). JS's ASCII-only `\w` / `\b` are
/// spelled out as `[A-Za-z0-9_]` lookarounds, and JS's non-multiline `$` as `\z`.
public enum SpeechText {
  /// The speakable form of `text`; `""` when nothing speakable remains.
  public static func sanitize(_ text: String) -> String {
    // Tables first: their right-align marker is a trailing colon (":-"), and closing colons
    // before the table detector runs would mangle it.
    let withoutTables = summarizeMarkdownTables(text)

    // Close line-final colons BEFORE newlines are flattened, so "the regex list:" followed
    // by a code block reads "the regex list." instead of hanging on the colon.
    let pre = Pattern.lineFinalColon.replacing(in: withoutTables, with: ".")

    // Identifier pruning runs AFTER code/links/URLs/MEDIA: tokens are consumed, so their
    // contents are not double-processed.
    var flattened = normalizeLineBreaks(pre)
    flattened = Pattern.fencedCode.replacing(in: flattened, with: "")
    flattened = Pattern.thinkingPrefix.replacing(in: flattened, with: " ", firstOnly: true)
    flattened = Pattern.markdownLink.replacing(in: flattened, with: "$1")
    flattened = Pattern.inlineCode.replacing(in: flattened, with: "$1")
    flattened = Pattern.url.replacing(in: flattened, with: "")
    flattened = Pattern.mediaPath.replacing(in: flattened, with: "")
    flattened = Pattern.emoji.replacing(in: flattened, with: " ")
    var spoken = pruneIdentifierTokens(flattened)

    spoken = Pattern.heading.replacing(in: spoken, with: "")
    spoken = Pattern.markupCharacters.replacing(in: spoken, with: "")
    spoken = Pattern.bulletMarker.replacing(in: spoken, with: "")
    // A colon orphaned when its link/code was stripped.
    spoken = Pattern.trailingColon.replacing(in: spoken, with: ".", firstOnly: true)
    spoken = Pattern.whitespaceRun.replacing(in: spoken, with: " ")
    return spoken.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Line breaks

  static func normalizeLineBreaks(_ text: String) -> String {
    var result = Pattern.carriageReturn.replacing(in: text, with: "\n")
    result = Pattern.hyphenatedLineBreak.replacing(in: result, with: "$1$2")
    result = Pattern.punctuatedParagraphBreak.replacing(in: result, with: "$1$2 ")
    result = Pattern.paragraphBreak.replacing(in: result, with: ". ")
    return Pattern.softBreak.replacing(in: result, with: " ")
  }

  // MARK: Identifier-dense tokens (#119207)

  static func pruneIdentifierTokens(_ text: String) -> String {
    let withoutHashes = Pattern.hashPrefixHex.replacing(in: text, with: " ")
    return Pattern.identifierToken.replacing(in: withoutHashes) { token in
      isDenseIdentifier(token) ? " " : token
    }
  }

  /// Filenames, hashes, UUIDs, dense model/version IDs and paths — read character by
  /// character otherwise ("peyton dash sample dash two zero two six…").
  static func isDenseIdentifier(_ token: String) -> Bool {
    if token.contains("@") || Pattern.dateToken.matches(token) {
      return false  // email addresses, dates ("2026-09-28", "2026/06/02")
    }
    if token.hasPrefix("~/") || token.hasPrefix("./") || token.hasPrefix("../")
      || token.hasPrefix("/")
    {
      return true  // filesystem paths
    }
    let hasDigit = token.unicodeScalars.contains { ("0"..."9").contains($0) }
    if token.contains("/") && (Pattern.filenameExtension.matches(token) || hasDigit) {
      return true  // paths and dense model IDs ("meta-llama/Llama-3.3-70B-Instruct")
    }
    if Pattern.filenameExtension.matches(token) || Pattern.uuid.matches(token) {
      return true
    }
    // Hex-hash runs ("73688014f78") — digit-free runs ("defaced") are words and stay.
    if Pattern.hexRun.matches(token) && hasDigit {
      return true
    }
    if !hasDigit {
      return false
    }
    let separators = ["_", ".", "/"].filter { token.contains($0) }.count
    let hyphens = token.unicodeScalars.filter { $0 == "-" }.count
    if separators >= 2 || hyphens >= 2 {
      return true  // v2.1.0-beta.3, Llama-3.3-70B, dated filename slugs
    }
    return token.contains("/") || (hyphens >= 1 && separators >= 1)
  }

  // MARK: Tables

  private struct MarkdownTableRow {
    var blockquoteDepth: Int
    var cells: [String]
  }

  private typealias Scalars = [Unicode.Scalar]

  private static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
  }

  private static func isUnescapedPipe(_ row: Scalars, _ index: Int) -> Bool {
    var backslashes = 0
    var cursor = index - 1
    while cursor >= 0 && row[cursor] == "\\" {
      backslashes += 1
      cursor -= 1
    }
    return backslashes % 2 == 0
  }

  private static func trimmed(_ scalars: some Sequence<Unicode.Scalar>) -> String {
    string(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func splitMarkdownTableCells(_ row: Scalars) -> [String] {
    var cells: [String] = []
    var cellStart = 0
    for index in row.indices where row[index] == "|" && isUnescapedPipe(row, index) {
      cells.append(trimmed(row[cellStart..<index]))
      cellStart = index + 1
    }
    cells.append(trimmed(row[cellStart...]))
    return cells
  }

  private static func parseMarkdownTableRow(_ line: String) -> MarkdownTableRow? {
    var row = Scalars(line.unicodeScalars)
    var blockquoteDepth = 0

    while true {
      let indentation = row.prefix { $0 == " " || $0 == "\t" }
      if indentation.contains("\t") || indentation.count > 3 {
        return nil
      }
      row.removeFirst(indentation.count)
      guard row.first == ">" else { break }
      blockquoteDepth += 1
      row.removeFirst()
      if row.first == " " {
        row.removeFirst()
      }
    }

    while let last = row.last, last.properties.isWhitespace {
      row.removeLast()
    }

    let pipeIndexes = row.indices.filter { row[$0] == "|" && isUnescapedPipe(row, $0) }
    guard let firstPipe = pipeIndexes.first, let lastPipe = pipeIndexes.last else {
      return nil
    }
    let hasLeadingPipe = firstPipe == 0
    let hasTrailingPipe = lastPipe == row.count - 1
    if hasLeadingPipe {
      row.removeFirst()
    }
    if hasTrailingPipe, !row.isEmpty {
      row.removeLast()
    }

    let cells = splitMarkdownTableCells(row)
    if cells.count < 2 && !(hasLeadingPipe && hasTrailingPipe && cells.count == 1) {
      return nil
    }
    return MarkdownTableRow(blockquoteDepth: blockquoteDepth, cells: cells)
  }

  /// The header row is spoken in place of the table ("Model, Price, Context."); a table
  /// with an all-empty header stays silent.
  private static func speakableTableHeader(_ cells: [String]) -> String {
    let header =
      cells
      .map {
        $0.replacingOccurrences(of: "\\|", with: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
    guard let last = header.unicodeScalars.last, !".!?:".unicodeScalars.contains(last) else {
      return header
    }
    return header + "."
  }

  private static func isDelimiterCell(_ cell: String) -> Bool {
    Pattern.tableDelimiterCell.matches(cell)
  }

  static func summarizeMarkdownTables(_ text: String) -> String {
    let lines = Pattern.carriageReturn.replacing(in: text, with: "\n")
      .components(separatedBy: "\n")
    var tableLines = Set<Int>()
    var headers: [Int: String] = [:]

    var index = 1
    while index < lines.count {
      guard
        let delimiterRow = parseMarkdownTableRow(lines[index]),
        let headerRow = parseMarkdownTableRow(lines[index - 1]),
        delimiterRow.cells.allSatisfy(isDelimiterCell),
        headerRow.cells.count == delimiterRow.cells.count,
        headerRow.blockquoteDepth == delimiterRow.blockquoteDepth
      else {
        index += 1
        continue
      }

      tableLines.insert(index - 1)
      tableLines.insert(index)
      headers[index - 1] = speakableTableHeader(headerRow.cells)

      var rowIndex = index + 1
      while rowIndex < lines.count {
        guard let bodyRow = parseMarkdownTableRow(lines[rowIndex]),
          bodyRow.blockquoteDepth == delimiterRow.blockquoteDepth
        else { break }
        tableLines.insert(rowIndex)
        rowIndex += 1
      }
      index = rowIndex
    }

    return lines.enumerated()
      .flatMap { index, line -> [String] in
        guard tableLines.contains(index) else { return [line] }
        guard let header = headers[index], !header.isEmpty else { return [] }
        return [header]
      }
      .joined(separator: "\n")
  }
}

// MARK: - Patterns

extension SpeechText {
  /// The compiled ICU patterns, each annotated with its desktop counterpart.
  fileprivate enum Pattern {
    /// `/\r\n?/g`
    static let carriageReturn = Compiled(#"\r\n?"#)
    /// `/(\p{L})-\n(\p{L})/gu`
    static let hyphenatedLineBreak = Compiled(#"(\p{L})-\n(\p{L})"#)
    /// `PUNCTUATED_PARAGRAPH_BREAK_RE`
    static let punctuatedParagraphBreak = Compiled(
      #"([.!?])([*_~`>"'’”)}\]]*)[ \t]*\n{2,}[ \t]*"#)
    /// `PARAGRAPH_BREAK_RE`
    static let paragraphBreak = Compiled(#"[ \t]*\n{2,}[ \t]*"#)
    /// `SOFT_BREAK_RE`
    static let softBreak = Compiled(#"[ \t]*\n[ \t]*"#)

    /// `FENCED_CODE_RE` — an unterminated fence runs to the end of the text.
    static let fencedCode = Compiled(#"```[\s\S]*?(?:```|\z)"#)
    /// `INLINE_CODE_RE`
    static let inlineCode = Compiled(#"`([^`]+)`"#)
    /// `MARKDOWN_LINK_RE`
    static let markdownLink = Compiled(#"\[([^\]]+)\]\(([^)]+)\)"#)
    /// `URL_RE` (`\b` before an ASCII word character).
    static let url = Compiled(#"(?i)(?<![A-Za-z0-9_])https?://\S+"#)
    /// `MEDIA_PATH_RE` — a sentence-final period/comma after the token is kept.
    static let mediaPath = Compiled(#"[ \t]*MEDIA:\S+?(?=[.,;:!?)\]]*(?:\s|\z))"#)
    /// `LINE_FINAL_COLON_RE` (`/gm`).
    static let lineFinalColon = Compiled(#"(?m):\s*$"#)
    /// `THINKING_PREFIX_RE`
    static let thinkingPrefix = Compiled(
      #"(?i)\A\s*(?:\([^)\n]{1,48}\)\s*)?(?:processing|thinking|reasoning|analyzing|pondering|contemplating|musing|cogitating|ruminating|deliberating|mulling|reflecting|computing|synthesizing|formulating|brainstorming)\.\.\.\s*"#
    )
    /// `EMOJI_RE`
    static let emoji = Compiled(
      #"(?:[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}]|[\x{FE0F}\x{200D}]|[\x{E0020}-\x{E007F}])+"#)

    /// `FILENAME_EXT_RE` (`\w` → ASCII word class, trailing `\b` → no ASCII word char).
    static let filenameExtension = Compiled(
      #"(?i)[A-Za-z0-9_.-]{0,60}\.(?:wav|ogg|mp3|flac|m4a|aac|py|pyc|ts|tsx|js|jsx|mjs|cjs|json|yaml|yml|toml|md|mdx|txt|csv|xlsx|xls|pdf|png|jpg|jpeg|gif|webp|svg|log|sql|sh|bash|zsh|rs|go|java|rb|php|html|css|lock|tar|gz|zip|db|sqlite|sqlite3|onnx|pt|bin|env|ini|conf|cfg|xml)(?![A-Za-z0-9_])"#
    )
    /// `UUID_RE`
    static let uuid = Compiled(
      #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)
    /// `HASH_PREFIX_HEX_RE` (`[:\s]` reordered — ICU would read `[:` as a POSIX class).
    static let hashPrefixHex = Compiled(
      #"(?i)(?<![A-Za-z0-9_])(?:sha(?:-?256|-?512|-?1|3)?|blake2[ab]?|md5|crc32?)[\s:]+[0-9a-fA-F]{7,64}"#
    )
    /// `HEX_RUN_RE`
    static let hexRun = Compiled(#"[0-9a-fA-F]{7,64}"#)
    /// `IDENTIFIER_TOKEN_RE`
    static let identifierToken = Compiled(#"[A-Za-z0-9_./~@-]+"#)
    /// `DATE_TOKEN_RE`
    static let dateToken = Compiled(#"\A[0-9]{4}[-/][0-9]{1,2}(?:[-/][0-9]{1,2})?\z"#)

    /// `MARKDOWN_TABLE_DELIMITER_CELL_RE`
    static let tableDelimiterCell = Compiled(#"\A:?-{3,}:?\z"#)

    /// Tail cleanup: `/^#{1,6}\s+/gm`, `/[*_~>#]/g`, `/^\s*[-+*]\s+/gm`, `/:\s*$/`, `/\s+/g`.
    static let heading = Compiled(#"(?m)^#{1,6}\s+"#)
    static let markupCharacters = Compiled(#"[*_~>#]"#)
    static let bulletMarker = Compiled(#"(?m)^\s*[-+*]\s+"#)
    static let trailingColon = Compiled(#":\s*\z"#)
    static let whitespaceRun = Compiled(#"\s+"#)
  }

  /// A constant ICU pattern. The patterns are compile-time literals covered by
  /// `SpeechTextTests`, so a failure to compile is a programmer error.
  fileprivate struct Compiled: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
      do {
        regex = try NSRegularExpression(pattern: pattern)
      } catch {
        preconditionFailure("SpeechText pattern failed to compile: \(pattern) — \(error)")
      }
    }

    func matches(_ text: String) -> Bool {
      regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Replaces every match (or only the first, like a JS `replace` without `/g`) with an
    /// ICU template (`$1` references a capture group).
    func replacing(in text: String, with template: String, firstOnly: Bool = false) -> String {
      let range = NSRange(text.startIndex..., in: text)
      guard firstOnly else {
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
      }
      guard let match = regex.firstMatch(in: text, range: range) else { return text }
      let replacement = regex.replacementString(
        for: match, in: text, offset: 0, template: template)
      return (text as NSString).replacingCharacters(in: match.range, with: replacement)
    }

    /// Replaces every match with the closure's verdict on the matched text.
    func replacing(in text: String, using transform: (String) -> String) -> String {
      let source = text as NSString
      let result = NSMutableString()
      var cursor = 0
      for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        result.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
        result.append(transform(source.substring(with: match.range)))
        cursor = match.range.location + match.range.length
      }
      result.append(source.substring(from: cursor))
      return result as String
    }
  }
}
