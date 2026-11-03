import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured (not eyeballed) checks for the file preview's text renderer.
///
/// A snapshot shows one screenful of a long file but cannot tell "the rest scrolls" from
/// "the rest was clipped and thrown away" — the first screenful looks the same either way.
/// These tests host `MonospacedFileTextView` in a real window at the sheet's size, force a
/// layout pass, and read the numbers off the `UITextView` it renders into:
///
/// - a 400-line file has `contentSize.height > bounds.height` (there is more to scroll to,
///   and it can actually be scrolled to its end);
/// - a 5-line file fits: `contentSize.height <= bounds.height`, nothing to scroll;
/// - in both cases the text view *fills* the region it was given rather than hugging its
///   text — the "expands to fill" half of the contract, which a hugging `UITextView`
///   (the transcript's `SelectableText` recipe) would fail.
///
/// Dynamic Type is pinned to `.large`: the monospaced body font scales with the content size
/// category, so every threshold below would otherwise follow the simulator's text size.
final class FilePreviewTextLayoutTests: XCTestCase {
  /// The sheet's content region as the snapshot suite pins it (phone width, 600pt slot).
  private static let regionSize = CGSize(width: 390, height: 600)

  /// Kept alive for the test: a hosted view only lays out for real while its window exists.
  private var windows: [UIWindow] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    super.tearDown()
  }

  func testLongFileScrollsInsideTheRegion() throws {
    let textView = try hostedTextView(lines: 400)
    XCTAssertGreaterThan(
      textView.contentSize.height, textView.bounds.height,
      "A 400-line file must have more content than the region shows — it scrolls, not clips"
    )
    // The off-screen lines are reachable: scroll to the end and the offset sticks.
    let end = textView.contentSize.height - textView.bounds.height
    textView.setContentOffset(CGPoint(x: 0, y: end), animated: false)
    XCTAssertEqual(textView.contentOffset.y, end, accuracy: 1, "The tail of the file must be scrollable into view")
  }

  func testShortFileDoesNotScroll() throws {
    let textView = try hostedTextView(lines: 5)
    XCTAssertLessThanOrEqual(
      textView.contentSize.height, textView.bounds.height + 1,
      "A 5-line file fits the region; there must be nothing to scroll"
    )
    XCTAssertGreaterThan(textView.contentSize.height, 0, "The text must actually be laid out, not collapsed")
  }

  /// The "expands to fill" half: regardless of how little text there is, the text view takes
  /// the region's full height (so a tap anywhere in the sheet lands on the selectable text
  /// and the empty area below a short file is still the preview, not a gap).
  func testTextViewFillsTheRegionForShortAndLongFiles() throws {
    for lines in [5, 400] {
      let textView = try hostedTextView(lines: lines)
      XCTAssertEqual(textView.bounds.width, Self.regionSize.width, accuracy: 1, "\(lines) lines: full width")
      XCTAssertGreaterThan(
        textView.bounds.height, Self.regionSize.height * 0.9,
        "\(lines) lines: the text view must fill the region (no caption rows in this fixture), not hug its text"
      )
    }
  }

  /// The caption row and the truncation banner take their height off the top; the text view
  /// still fills what is left and still scrolls a long file.
  func testCaptionAndBannerLeaveTheTextViewScrollable() throws {
    let plain = try hostedTextView(lines: 400)
    let decorated = try hostedTextView(lines: 400, language: "swift", truncated: true)
    XCTAssertLessThan(
      decorated.bounds.height, plain.bounds.height - 20,
      "The caption row and banner must take real height off the text view"
    )
    XCTAssertGreaterThan(decorated.bounds.height, Self.regionSize.height * 0.75, "…but only a strip of it")
    XCTAssertGreaterThan(decorated.contentSize.height, decorated.bounds.height)
  }

  // MARK: - Helpers

  /// Hosts `MonospacedFileTextView` for an `n`-line fixture in a real window at the sheet's
  /// region size, forces a layout pass, and hands back the `UITextView` inside.
  private func hostedTextView(
    lines: Int,
    language: String? = nil,
    truncated: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UITextView {
    let read = FileTextRead(
      byteSize: nil, language: language, text: Self.fixture(lines: lines), truncated: truncated
    )
    let host = UIHostingController(
      rootView: MonospacedFileTextView(read: read)
        .frame(width: Self.regionSize.width, height: Self.regionSize.height)
        .dynamicTypeSize(.large)
    )
    let window = UIWindow(frame: CGRect(origin: .zero, size: Self.regionSize))
    window.rootViewController = host
    window.isHidden = false
    windows.append(window)
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    let textView = try XCTUnwrap(
      Self.firstTextView(in: host.view),
      "MonospacedFileTextView must host a UITextView", file: file, line: line
    )
    // A scrolling text view sizes its content lazily; ask for it explicitly after layout.
    textView.layoutIfNeeded()
    return textView
  }

  /// `n` numbered lines of plausible source, each short enough to stay on one line at 390pt.
  private static func fixture(lines: Int) -> String {
    (1...lines).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
  }

  private static func firstTextView(in view: UIView) -> UITextView? {
    if let textView = view as? UITextView { return textView }
    for sub in view.subviews {
      if let found = firstTextView(in: sub) { return found }
    }
    return nil
  }
}
