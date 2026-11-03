import Foundation
import Testing

@testable import HermesKit

/// The detection grammar behind tappable file references: `MEDIA:` tags and bare absolute
/// paths in one prose line, the `hermes-file:` URL round-trip, markdown link targets and the
/// extension-only preview kind. The false-positive corpus is the contract — a path that is
/// NOT linked costs a tap on the host; a linked non-path costs a dead generic card.
@Suite struct FileReferenceScannerTests {
  private func segments(_ line: String) -> [InlineFileSegment] {
    FileReferenceScanner.segments(line)
  }

  /// Just the detected paths, in order.
  private func paths(_ line: String) -> [String] {
    segments(line).compactMap {
      if case .file(_, let path) = $0 { return path }
      return nil
    }
  }

  // MARK: Bare paths — positives

  @Test(arguments: [
    "/home/e/out/report.pdf",
    "~/Downloads/x.png",
    "~/x.md",
    "/var/log/agent-2026.log",
    "/a/b+c/d@e/f%20g/h~i.tar.gz",
    "/srv/data/report.abcdefghij", // 10-char extension is the ceiling
    "/Users/me/My_Project-v2/out.JSON",
    "/home/e/.env", // dotfiles link: read-text answers 403 → the protected card
    "~/.zshrc",
    "/home/e/.env.local",
  ])
  func barePathIsTheWholeLine(path: String) {
    #expect(segments(path) == [.file(display: path, path: path)])
  }

  @Test func barePathInProseKeepsSurroundingText() {
    #expect(segments("Saved to /home/e/out/report.pdf for you") == [
      .text("Saved to "),
      .file(display: "/home/e/out/report.pdf", path: "/home/e/out/report.pdf"),
      .text(" for you"),
    ])
  }

  @Test func backtickedPathIsLinkedWithoutTheBackticks() {
    // Code spans reach the UITextView builder already unwrapped, but a raw backtick pair
    // in plain text must not leak into the path either.
    #expect(segments("see `/tmp/out.txt` now") == [
      .text("see `"),
      .file(display: "/tmp/out.txt", path: "/tmp/out.txt"),
      .text("` now"),
    ])
  }

  @Test(arguments: [".", ",", ")", ";", ":", "]", "}", "'", "\""])
  func trailingSentencePunctuationStaysOutsideThePath(mark: String) {
    #expect(segments("Wrote /a/b.pdf\(mark) Done") == [
      .text("Wrote "),
      .file(display: "/a/b.pdf", path: "/a/b.pdf"),
      .text("\(mark) Done"),
    ])
  }

  @Test func parenthesisedPathIsLinked() {
    #expect(segments("(see /a/b.pdf)") == [
      .text("(see "),
      .file(display: "/a/b.pdf", path: "/a/b.pdf"),
      .text(")"),
    ])
  }

  @Test func twoPathsInOneLineAreBothLinked() {
    #expect(segments("Compare /a/one.csv with /b/two.csv.") == [
      .text("Compare "),
      .file(display: "/a/one.csv", path: "/a/one.csv"),
      .text(" with "),
      .file(display: "/b/two.csv", path: "/b/two.csv"),
      .text("."),
    ])
  }

  @Test func multiDotFilenameTakesTheLastExtension() {
    #expect(paths("/x/archive.tar.gz ok") == ["/x/archive.tar.gz"])
    #expect(paths("/x/y.z.abcdefghijk") == [])
  }

  @Test func sentencePeriodAfterExtensionDoesNotBlockTheMatch() {
    #expect(paths("Open /a/b.pdf.") == ["/a/b.pdf"])
    #expect(paths("Open /a/b.pdf. Then /c/d.txt.") == ["/a/b.pdf", "/c/d.txt"])
  }

  // MARK: Bare paths — false-positive corpus

  @Test(arguments: [
    "https://host/a/b.pdf",
    "see https://x/y.z today",
    "1/2/2026",
    "on 1/2/2026 at noon",
    "3/4",
    "./out/x.pdf",
    "src/foo.swift",
    "/tmp",
    "/usr/bin/python",
    "a/b.c",
    "/x/y.toolongextension",
    "/x/y.abcdefghijk", // 11-char extension
    "foo/bar.txt",
    "/report.pdf", // a `/` root needs a directory segment
    "/a/b.pdf_old",
    // A filename character right after the extension: linking `/a/b.pdf` out of these would
    // be a truncated, dead link.
    "/a/b.pdf-old",
    "/x/y.z-longext",
    "/a/b.pdf@2x",
    "/a/b.tar+bak",
    "/a/b.pdf/",
    "file:///a/b.pdf", // explicit URLs are the markdown parser's job, not the scanner's
    "",
    "plain prose with no slash",
  ])
  func nonPathTextIsLeftUntouched(line: String) {
    #expect(segments(line) == [.text(line)])
  }

  @Test func relativePathNextToAnAbsoluteOneLinksOnlyTheAbsolute() {
    #expect(paths("copy src/a.swift to /dst/a.swift") == ["/dst/a.swift"])
  }

  // MARK: MEDIA: tags

  @Test func unquotedMediaTagShowsTheFilename() {
    #expect(segments("MEDIA:/a/b.mp3") == [.file(display: "b.mp3", path: "/a/b.mp3")])
  }

  @Test func quotedMediaTagAllowsSpaces() {
    #expect(segments(#"Here: MEDIA:"/a/with space.pdf" done"#) == [
      .text("Here: "),
      .file(display: "with space.pdf", path: "/a/with space.pdf"),
      .text(" done"),
    ])
  }

  @Test func unquotedMediaTagShedsTrailingPunctuation() {
    #expect(segments("Open MEDIA:/tmp/a.pdf.") == [
      .text("Open "),
      .file(display: "a.pdf", path: "/tmp/a.pdf"),
      .text("."),
    ])
  }

  @Test func mediaTagClaimsItsRangeBeforeTheBarePathPass() {
    // The path inside the tag is linked ONCE, as the tag (filename display), and the bare
    // pass still runs on the text around it.
    #expect(segments("MEDIA:/a/b.png and /c/d.txt") == [
      .file(display: "b.png", path: "/a/b.png"),
      .text(" and "),
      .file(display: "/c/d.txt", path: "/c/d.txt"),
    ])
  }

  @Test func mediaTagWithoutAPlausiblePathStaysProse() {
    #expect(segments("MEDIA:...") == [.text("MEDIA:...")])
    #expect(segments("MEDIA:soon") == [.text("MEDIA:soon")])
    // The quoted form too: the tag match is skipped and the raw text falls through intact.
    #expect(segments(#"MEDIA:"soon" later"#) == [.text(#"MEDIA:"soon" later"#)])
    #expect(segments("MEDIA: /a/b.png") == [.text("MEDIA: "), .file(display: "/a/b.png", path: "/a/b.png")])
  }

  @Test func mediaTagStopsAtAnInlineCodeCloser() {
    #expect(segments("`MEDIA:/a/b.png`") == [
      .text("`"),
      .file(display: "b.png", path: "/a/b.png"),
      .text("`"),
    ])
  }

  @Test func mediaTagAcceptsRelativeAndExtensionlessPaths() {
    // Desktop parity: the tag is an explicit marker, so the bare-path rules do not apply.
    #expect(segments("MEDIA:out/report.docx") == [.file(display: "report.docx", path: "out/report.docx")])
    #expect(segments("MEDIA:/usr/bin/tool") == [.file(display: "tool", path: "/usr/bin/tool")])
  }

  // MARK: End-to-end message

  /// Every detection shape from the plan's Overview in ONE realistic assistant message, run the
  /// way the renderers run it: the scanner over each prose line, and `path(fromLinkTarget:)`
  /// over the markdown link targets the inline parse extracts first. The `https` link must stay
  /// untouched on both routes (it keeps opening Safari through `.systemAction`).
  @Test func realisticAssistantMessageLinksEveryShapeAndLeavesHTTPSAlone() throws {
    let message = """
      Done. The report is at /home/eugene/out/report.pdf, and the chart is `~/out/chart.png`.
      Audio: MEDIA:/home/eugene/out/summary.mp3
      Also see [the notes](file:///home/eugene/out/notes.md) and [the docs](https://example.com/a/b.pdf).
      """
    let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    try #require(lines.count == 3)

    // Line 1: bare path followed by punctuation (`,`) + backticked path followed by `.`.
    #expect(segments(lines[0]) == [
      .text("Done. The report is at "),
      .file(display: "/home/eugene/out/report.pdf", path: "/home/eugene/out/report.pdf"),
      .text(", and the chart is `"),
      .file(display: "~/out/chart.png", path: "~/out/chart.png"),
      .text("`."),
    ])

    // Line 2: `MEDIA:` tag displays the filename, links the full path.
    #expect(segments(lines[1]) == [
      .text("Audio: "),
      .file(display: "summary.mp3", path: "/home/eugene/out/summary.mp3"),
    ])

    // Line 3, raw: neither `file:///…` nor `https://…` is a bare path (the `//` is preceded by
    // `:`), so the scanner leaves the whole line alone — link targets are the parser's job.
    #expect(segments(lines[2]) == [.text(lines[2])])

    // Line 3, as the renderer sees it: the link-less runs carry nothing...
    #expect(segments("Also see ") == [.text("Also see ")])
    #expect(segments(" and ") == [.text(" and ")])
    #expect(segments(".") == [.text(".")])
    // ...the `file://` target becomes a host path with its label kept by the renderer...
    #expect(try linkPath("file:///home/eugene/out/notes.md") == "/home/eugene/out/notes.md")
    // ...and the `https` target is left exactly as it was.
    #expect(try linkPath("https://example.com/a/b.pdf") == nil)
    #expect(FileReference.path(from: try #require(URL(string: "https://example.com/a/b.pdf"))) == nil)
  }

  // MARK: Link targets

  /// `path(fromLinkTarget:)` for a markdown link destination as the inline parser emits it.
  private func linkPath(_ target: String) throws -> String? {
    FileReference.path(fromLinkTarget: try #require(URL(string: target)))
  }

  /// `path(from:)` for a URL string.
  private func decodedPath(_ string: String) throws -> String? {
    FileReference.path(from: try #require(URL(string: string)))
  }

  @Test func fileURLTargetsYieldTheDecodedPath() throws {
    #expect(try linkPath("file:///a%20b.pdf") == "/a b.pdf")
    #expect(try linkPath("file://localhost/a%20b.pdf") == "/a b.pdf")
    #expect(try linkPath("file:///home/e/x.md") == "/home/e/x.md")
  }

  @Test func schemelessAbsoluteAndHomeTargetsArePaths() throws {
    #expect(try linkPath("/abs/x.md") == "/abs/x.md")
    #expect(try linkPath("~/x.md") == "~/x.md")
    #expect(try linkPath("/abs/with%20space.md") == "/abs/with space.md")
  }

  @Test(arguments: [
    "https://example.com/a/b.pdf",
    "mailto:someone@example.com",
    "#anchor",
    "relative/x.md",
    "./x.md",
    "hermes-file://preview?path=%2Fa",
    "//cdn.example.com/lib.js", // protocol-relative URL, not a host path
  ])
  func otherLinkTargetsAreLeftAlone(target: String) throws {
    #expect(try linkPath(target) == nil)
  }

  // MARK: hermes-file: URL round-trip

  @Test(arguments: [
    "/home/e/out/report.pdf",
    "/a/with space.pdf",
    "~/Downloads/x.png",
    "/data/отчёт/résumé.pdf",
    "/a/100%/done.txt",
    "/a/why?.txt",
    "/a/#1.txt",
    "/a/b&c=d.txt",
    "/a/b+c.txt",
    "out/relative.docx",
  ])
  func urlRoundTripsArbitraryPaths(path: String) {
    let url = FileReference.url(for: path)
    #expect(url.scheme == "hermes-file")
    #expect(url.host == "preview")
    #expect(FileReference.path(from: url) == path)
  }

  @Test func urlIsPureASCII() {
    let url = FileReference.url(for: "/data/отчёт/a b.pdf")
    let isASCII = url.absoluteString.allSatisfy { $0.isASCII }
    #expect(isASCII)
    #expect(url.absoluteString.hasPrefix("hermes-file://preview?path=%2Fdata%2F"))
  }

  @Test func foreignURLsDoNotDecodeAsFileReferences() throws {
    #expect(try decodedPath("https://preview?path=%2Fa") == nil)
    #expect(try decodedPath("hermes-file://other?path=%2Fa") == nil)
    #expect(try decodedPath("hermes-file://preview?other=%2Fa") == nil)
    #expect(try decodedPath("hermes-file://preview?path=") == nil)
    #expect(try decodedPath("file:///a.pdf") == nil)
  }

  // MARK: FilePreviewKind

  @Test(arguments: ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"])
  func imageExtensionsInferImage(ext: String) {
    #expect(FilePreviewKind.infer(path: "/a/b.\(ext)") == .image)
    #expect(FilePreviewKind.infer(path: "/a/b.\(ext.uppercased())") == .image)
  }

  @Test func pdfAndOtherExtensions() {
    #expect(FilePreviewKind.infer(path: "/a/report.pdf") == .pdf)
    #expect(FilePreviewKind.infer(path: "/a/REPORT.PDF") == .pdf)
    #expect(FilePreviewKind.infer(path: "/a/notes.md") == .other)
    #expect(FilePreviewKind.infer(path: "/a/archive.zip") == .other)
  }

  @Test func noExtensionIsOther() {
    #expect(FilePreviewKind.infer(path: "/usr/bin/python") == .other)
    #expect(FilePreviewKind.infer(path: "/home/e/.env") == .other)
    #expect(FilePreviewKind.infer(path: "") == .other)
  }

  @Test func displayNameIsTheLastPathComponent() {
    #expect(FilePreviewKind.displayName(for: "/home/e/out/report.pdf") == "report.pdf")
    #expect(FilePreviewKind.displayName(for: "~/x.png") == "x.png")
    #expect(FilePreviewKind.displayName(for: "/a/with space.pdf") == "with space.pdf")
    #expect(FilePreviewKind.displayName(for: "report.pdf") == "report.pdf")
    #expect(FilePreviewKind.displayName(for: "/a/dir/") == "dir")
  }

  @Test func symbolNameFollowsKindThenExtension() {
    #expect(FilePreviewKind.symbolName(for: "/a/b.PNG") == "photo")
    #expect(FilePreviewKind.symbolName(for: "/a/b.pdf") == "doc.richtext")
    #expect(FilePreviewKind.symbolName(for: "/a/b.md") == "doc.text")
    #expect(FilePreviewKind.symbolName(for: "/a/b.log") == "doc.text")
    #expect(FilePreviewKind.symbolName(for: "/a/b.csv") == "tablecells")
    #expect(FilePreviewKind.symbolName(for: "/a/b.zip") == "doc.zipper")
    #expect(FilePreviewKind.symbolName(for: "/a/b.tar.gz") == "doc.zipper")
    #expect(FilePreviewKind.symbolName(for: "/a/b.docx") == "doc")
    #expect(FilePreviewKind.symbolName(for: "/usr/bin/python") == "doc")
  }
}
