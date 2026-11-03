import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// File references in assistant prose (file preview in chat): every detection shape — a
/// bare absolute path, a `MEDIA:` tag, a backticked path, a markdown `file://` link — renders
/// as a tappable `hermes-file:` link in BOTH prose renderers (`SelectableText`'s `UITextView`
/// for prose blocks, SwiftUI `Text` for blockquotes/headings/table cells). The snapshots pin
/// the link tint on the path and the filename shown for a `MEDIA:` tag; the attribute tests
/// pin the URL each renderer attaches, which a pixel can't prove.
final class FileReferenceLinkSnapshotTests: SnapshotTestCase {
  /// The plan's fixture line plus one more paragraph covering the backticked and markdown
  /// link shapes, so one bubble shows every linkified shape next to plain prose.
  private static let bubbleText = """
    Saved to /home/e/out/report.pdf and MEDIA:/a/b.png

    Log: `~/logs/run.log`, or [the summary](file:///home/e/out/summary.md). \
    The [docs](https://example.com/a/b.pdf) stay on the web.
    """

  private func bubble() -> some View {
    MessageBubbleView(role: .assistant, text: Self.bubbleText, isComplete: true)
      .padding()
      .frame(width: device.size?.width ?? 390)
      .background(Color(uiColor: .systemBackground))
  }

  // MARK: Snapshots

  /// Prose path (`UITextView`): the bare path, the `MEDIA:` filename, the backticked path
  /// (code font, tinted) and the markdown label are links; the `https` link keeps its own
  /// tint untouched; prose between them stays label-coloured.
  func testAssistantBubble_fileReferences() {
    assertSnapshot(of: bubble(), as: componentImage())
  }

  /// Same bubble in light appearance — the link tint over a light background is what's
  /// under test.
  func testAssistantBubble_fileReferences_light() {
    assertSnapshot(of: bubble(), as: componentImage(appearance: .light))
  }

  /// SwiftUI `Text` path: a blockquote line carries the link too (the quote's secondary
  /// foreground does not swallow it).
  func testBlockquote_fileReference() {
    let view = MarkdownText(text: "> Full output in /home/e/out/report.pdf — see MEDIA:/a/b.png")
      .padding()
      .frame(width: device.size?.width ?? 390)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Attached links

  /// `ProseAttributedBuilder` (the `UITextView` string): the path range carries the
  /// `hermes-file:` URL, a `MEDIA:` tag renders its filename with the FULL path in the link,
  /// a backticked path keeps the monospaced font, and a `file://` markdown link is
  /// re-targeted while its label stays.
  func testProseBuilder_attachesFileReferenceLinks() {
    let attributed = ProseAttributedBuilder.make(
      "Saved to /home/e/out/report.pdf and MEDIA:/a/b.png or `~/logs/run.log` ([sum](file:///x/s.md))"
    )
    XCTAssertEqual(
      attributed.string,
      "Saved to /home/e/out/report.pdf and b.png or ~/logs/run.log (sum)"
    )
    XCTAssertEqual(Self.links(in: attributed), [
      "/home/e/out/report.pdf": "/home/e/out/report.pdf",
      "b.png": "/a/b.png",
      "~/logs/run.log": "~/logs/run.log",
      "sum": "/x/s.md",
    ])
    let codeRange = (attributed.string as NSString).range(of: "~/logs/run.log")
    let codeFont = attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? UIFont
    XCTAssertTrue(codeFont?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
    let tint = attributed.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? UIColor
    XCTAssertEqual(tint, .tintColor)
  }

  /// `MarkdownText.inline` (the SwiftUI `Text` string): same links, same display swap, and
  /// the bold intent survives on a path inside `**…**`.
  func testInline_attachesFileReferenceLinks() {
    let inline = MarkdownText.inline("See **/a/b.pdf** and MEDIA:\"/with space/c.txt\".")
    XCTAssertEqual(String(inline.characters), "See /a/b.pdf and c.txt.")
    var links: [String: String] = [:]
    var boldPath = false
    for run in inline.runs {
      guard let link = run.link else { continue }
      links[String(inline[run.range].characters)] = FileReference.path(from: link)
      if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { boldPath = true }
    }
    XCTAssertEqual(links, ["/a/b.pdf": "/a/b.pdf", "c.txt": "/with space/c.txt"])
    XCTAssertTrue(boldPath)
  }

  /// A foreign link target is left exactly as parsed — `https` stays `https` so the
  /// `OpenURLAction` can hand it to the system.
  func testInline_leavesForeignLinksUntouched() {
    let inline = MarkdownText.inline("[docs](https://example.com/a/b.pdf) and 1/2/2026")
    let links = inline.runs.compactMap(\.link)
    XCTAssertEqual(links, [URL(string: "https://example.com/a/b.pdf")!])
  }

  /// Display text → the host path decoded from each `.link` attribute.
  private static func links(in attributed: NSAttributedString) -> [String: String] {
    var out: [String: String] = [:]
    attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
      guard let url = value as? URL else { return }
      out[attributed.attributedSubstring(from: range).string] = FileReference.path(from: url)
    }
    return out
  }
}
