import Foundation

// MARK: - InlineFileSegment

/// One piece of a prose line after `FileReferenceScanner` has marked the file references in
/// it. Renderers map `.text` to plain runs and `.file` to a run carrying the
/// `FileReference.url(for:)` link (displayed as `display`, which for a `MEDIA:` tag is the
/// bare filename and for a bare path is the path itself).
public enum InlineFileSegment: Equatable, Sendable {
  case text(String)
  case file(display: String, path: String)
}

// MARK: - FileReference

/// The `hermes-file:` URL convention that both prose renderers attach to a file reference and
/// the one `openURL` hook in `ChatView` recognises: `hermes-file://preview?path=<encoded>`.
/// The app is the scheme's intended producer, so the hook routes it into
/// `ChatFeature.fileReferenceTapped` and lets every other URL fall through to the system
/// (`https:` keeps opening Safari). An inbound `hermes-file:` markdown link in model output is
/// accepted as-is — it opens the same sheet, and the server still gates sensitive files.
public enum FileReference {
  public static let scheme = "hermes-file"
  static let host = "preview"
  static let pathQueryItem = "path"

  /// Builds the tappable link for a host path. Every character outside the unreserved set is
  /// percent-encoded (incl. `/`, `?`, `#`, `%`, `+`, spaces and non-ASCII) so arbitrary paths
  /// round-trip through `path(from:)` byte-for-byte.
  public static func url(for path: String) -> URL {
    // `addingPercentEncoding` only fails for a string that is not valid Unicode — a Swift
    // `String` always is — and the resulting URL is pure ASCII, so neither unwrap can fail.
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .fileReferenceUnreserved) ?? ""
    return URL(string: "\(scheme)://\(host)?\(pathQueryItem)=\(encoded)")!
  }

  /// Inverts `url(for:)`. Returns nil for any other scheme or host, and for an empty path.
  public static func path(from url: URL) -> String? {
    guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let value = components.queryItems?.first(where: { $0.name == pathQueryItem })?.value,
      !value.isEmpty
    else { return nil }
    return value
  }

  /// The host path named by a markdown link target, or nil when the link points anywhere else
  /// (`https:`, `mailto:`, anchors, relative paths) and must be left untouched.
  ///
  /// Accepted shapes: a `file` URL (`file:///a%20b.pdf` and `file://localhost/a%20b.pdf` both
  /// yield `/a b.pdf`) or a scheme-less target whose text starts with `/` or `~/`.
  public static func path(fromLinkTarget url: URL) -> String? {
    if let scheme = url.scheme?.lowercased() {
      guard scheme == "file" else { return nil }
      let path = url.path(percentEncoded: false)
      return path.isEmpty ? nil : path
    }
    let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
    // `//cdn.example.com/lib.js` is a protocol-relative URL, not a host path.
    guard !raw.hasPrefix("//") else { return nil }
    return raw.hasPrefix("/") || raw.hasPrefix("~/") ? raw : nil
  }
}

extension CharacterSet {
  /// RFC 3986 unreserved characters — the only ones left bare in a path query value, here and
  /// in `FilePreviewClient`'s `/api/fs/*` query (so `+` travels as `%2B`, never as a space).
  static let fileReferenceUnreserved: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()
}

// MARK: - FileReferenceScanner

/// Pure detection of file references in ONE prose line (both renderers already work line by
/// line, and paths never span lines). Two passes; earlier matches claim their ranges:
///
/// 1. **`MEDIA:` tags** — `MEDIA:` immediately followed by a double-quoted path (may contain
///    spaces) or a run of non-whitespace characters; display text is the last path component.
///    A bare capture sheds trailing sentence punctuation (`MEDIA:/tmp/a.pdf.`), and a capture
///    that cannot name a file (no `/`, no `.ext` — `MEDIA:...`) stays prose: a dead link is
///    worse than no link.
/// 2. **Bare absolute paths** on the remaining text — a `/` or `~/` root at a non-word
///    boundary, filename-safe segments, and a final segment with a 1–10 character extension
///    (see `barePathPattern`). Relative paths, paths with spaces and extension-less paths are
///    deliberately NOT linked; the generic preview card makes a residual false positive
///    harmless.
///
/// Markdown link targets are the renderers' job (`FileReference.path(fromLinkTarget:)`) —
/// the inline markdown parse has already produced them as `.link` runs by the time the text
/// reaches this scanner.
public enum FileReferenceScanner {
  /// Returns the line split into text and file segments. A line with no reference comes back
  /// as a single `.text` segment equal to the input (incl. the empty line); adjacent text
  /// pieces are merged so there is never an empty `.text` and never two in a row.
  public static func segments(_ line: String) -> [InlineFileSegment] {
    // Fast path: neither shape can occur without a slash or the tag prefix.
    guard line.contains("/") || line.contains("MEDIA:") else { return [.text(line)] }

    var out: [InlineFileSegment] = []
    var cursor = line.startIndex
    for match in mediaTagRegex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
      guard let range = Range(match.range, in: line),
        let media = mediaPath(in: line, match: match)
      else { continue }
      appendBarePaths(in: line[cursor..<range.lowerBound], to: &out)
      out.append(.file(display: lastPathComponent(of: media.path), path: media.path))
      out.appendText(media.trailing)
      cursor = range.upperBound
    }
    appendBarePaths(in: line[cursor...], to: &out)
    return out.isEmpty ? [.text(line)] : out
  }

  // MARK: MEDIA: tags

  /// Group 1: the quoted path (quotes excluded). Group 2: the bare run — stops at whitespace,
  /// a double quote or a backtick so an inline-code closer or a stray quote is never
  /// swallowed into the path.
  private static let mediaTagRegex = try! NSRegularExpression(
    pattern: #"MEDIA:(?:"([^"\n]+)"|([^\s"`]+))"#
  )

  /// The path a `MEDIA:` match names plus the sentence punctuation that trailed a bare
  /// capture, or nil when the capture cannot plausibly name a file.
  private static func mediaPath(
    in line: String, match: NSTextCheckingResult
  ) -> (path: String, trailing: String)? {
    if let quoted = Range(match.range(at: 1), in: line) {
      let path = String(line[quoted])
      return isPlausibleMediaPath(path) ? (path, "") : nil
    }
    guard let bare = Range(match.range(at: 2), in: line) else { return nil }
    let (path, trailing) = splitTrailingPunctuation(String(line[bare]))
    return isPlausibleMediaPath(path) ? (path, trailing) : nil
  }

  /// Desktop parity (`isPlausibleMediaPath`): a path separator, or a dot with content after
  /// it (`report.md`, `.env`). An ellipsis or a bare word is prose.
  private static func isPlausibleMediaPath(_ value: String) -> Bool {
    if value.contains("/") { return true }
    guard let dot = value.firstIndex(of: ".") else { return false }
    let next = value.index(after: dot)
    return next < value.endIndex && value[next] != "."
  }

  // MARK: Bare paths

  /// A `/` or `~/` root at a non-word boundary (the lookbehind rules out `https://x/y.z`,
  /// `1/2/2026`, `./out/x.pdf`, `src/foo.swift`), filename-safe segments, and a final segment
  /// ending in `.ext` (1–10 alphanumerics). A `/` root needs at least one directory segment
  /// (`/report.pdf` alone is too close to a fraction or a URL path) while `~/x.md` is
  /// unambiguous and needs none. The lookahead keeps `/x/y.toolongextension` from matching
  /// its first ten letters, `/x/y.z.longext` from matching `/x/y.z`, and a filename
  /// character right after the extension (`/a/b.pdf-old`, `/a/b.pdf@2x`, `/a/b.pdf/`) from
  /// linking a truncated path, while a sentence period after the extension (`/a/b.pdf.`)
  /// still ends the match cleanly.
  private static let barePathPattern =
    #"(?<![\w/~.])(?:~(?:/[A-Za-z0-9._\-+@%~]+)*|(?:/[A-Za-z0-9._\-+@%~]+)+)/[A-Za-z0-9._\-+@%~]*\.[A-Za-z0-9]{1,10}(?!\w|\.\w|[\-+@%~/])"#

  private static let barePathRegex = try! NSRegularExpression(pattern: barePathPattern)

  private static func appendBarePaths(in text: Substring, to out: inout [InlineFileSegment]) {
    guard !text.isEmpty else { return }
    guard text.contains("/") else {
      out.appendText(String(text))
      return
    }
    let piece = String(text)
    var cursor = piece.startIndex
    for match in barePathRegex.matches(in: piece, range: NSRange(piece.startIndex..., in: piece)) {
      guard let range = Range(match.range, in: piece) else { continue }
      // The regex already ends every match on an extension character, so the trim is a
      // no-op today; it stays as the documented safety net for the grammar's trailing edge.
      let (path, trailing) = splitTrailingPunctuation(String(piece[range]))
      guard !path.isEmpty else { continue }
      out.appendText(String(piece[cursor..<range.lowerBound]))
      out.append(.file(display: path, path: path))
      out.appendText(trailing)
      cursor = range.upperBound
    }
    out.appendText(String(piece[cursor...]))
  }

  // MARK: Helpers

  /// Characters that legitimately follow a path in prose and are never part of it.
  private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", ")", "]", "}", "'", "\"", "`"]

  /// Splits `value` into the path and the sentence punctuation that trailed it
  /// (`/tmp/a.pdf.` → `/tmp/a.pdf` + `.`).
  static func splitTrailingPunctuation(_ value: String) -> (path: String, trailing: String) {
    var end = value.endIndex
    while end > value.startIndex, trailingPunctuation.contains(value[value.index(before: end)]) {
      end = value.index(before: end)
    }
    return (String(value[..<end]), String(value[end...]))
  }

  static func lastPathComponent(of path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
  }
}

extension Array where Element == InlineFileSegment {
  /// Appends text, merging into a preceding `.text` and dropping empties.
  fileprivate mutating func appendText(_ text: String) {
    guard !text.isEmpty else { return }
    if case .text(let previous)? = last {
      self[count - 1] = .text(previous + text)
    } else {
      append(.text(text))
    }
  }
}

// MARK: - FilePreviewKind

/// How the preview sheet loads a file, decided client-side by extension ONLY for the two
/// kinds that need the data-URL route. Everything else asks `read-text` and lets the server's
/// `binary` verdict pick the text view or the generic card — no client MIME table.
public enum FilePreviewKind: Equatable, Sendable {
  case image
  case pdf
  case other

  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
  ]

  /// Extensions that get the text-document glyph on the generic card.
  private static let textExtensions: Set<String> = [
    "txt", "md", "markdown", "log", "json", "yaml", "yml", "toml", "xml", "html", "htm",
    "css", "js", "ts", "tsx", "jsx", "py", "swift", "rb", "go", "rs", "java", "kt", "c",
    "h", "cpp", "hpp", "m", "sh", "zsh", "bash", "sql", "ini", "cfg", "conf", "rtf", "env",
  ]

  private static let tableExtensions: Set<String> = ["csv", "tsv", "xls", "xlsx", "numbers"]

  private static let archiveExtensions: Set<String> = [
    "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg",
  ]

  public static func infer(path: String) -> FilePreviewKind {
    let ext = fileExtension(of: path)
    if imageExtensions.contains(ext) { return .image }
    if ext == "pdf" { return .pdf }
    return .other
  }

  /// The last path component — the sheet title and the generic card's headline.
  public static func displayName(for path: String) -> String {
    FileReferenceScanner.lastPathComponent(of: path)
  }

  /// SF Symbol for the generic card and the share sheet's icon, by kind then extension.
  public static func symbolName(for path: String) -> String {
    switch infer(path: path) {
    case .image: return "photo"
    case .pdf: return "doc.richtext"
    case .other:
      let ext = fileExtension(of: path)
      if textExtensions.contains(ext) { return "doc.text" }
      if tableExtensions.contains(ext) { return "tablecells" }
      if archiveExtensions.contains(ext) { return "doc.zipper" }
      return "doc"
    }
  }

  /// Lowercased extension of the last path component, or `""` when there is none. A leading
  /// dot alone (`.env`, `.gitignore`) is a dotfile name, not an extension.
  static func fileExtension(of path: String) -> String {
    let name = displayName(for: path)
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return name[name.index(after: dot)...].lowercased()
  }
}
