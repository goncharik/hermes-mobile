import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// The build-77 report of #125: on a long chat with the keyboard up, the reader scrolls up one
/// screen (which dismisses the keyboard), and the list jumps to the bottom when the reply's first
/// words land.
///
/// The keyboard hiding grows the transcript at the bottom, which used up most of the scroll and
/// left the reader inside the 60pt pin threshold, so the renderer re-pinned them by geometry. The
/// pin now follows the user's scroll direction (`TranscriptScrollMath.pinnedAfterUserScroll`).
///
/// Measured, not snapshotted: the real `CollectionTranscriptView` in a `UIWindow`, the user scroll
/// driven through its own scroll delegate, the keyboard modelled as the transcript's frame growing
/// over the second half of the drag, and the rows delivered as the reducer's 50-row bottom window.
/// Red-checked against the geometric pin: the reader's row moved and the list landed on the bottom.
final class TranscriptKeyboardScrollTests: XCTestCase {
  private static let keyboardUpHeight: CGFloat = 350
  private static let keyboardDownHeight: CGFloat = 650

  private var window: UIWindow?

  override func tearDown() {
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
    super.tearDown()
  }

  /// One screen of scrolling ends 50pt from the bottom once the keyboard is gone; a scroll the
  /// keyboard fully uses up ends on the bottom. Neither reader may be moved by the reply.
  @MainActor
  func testReaderWhoScrolledUpWithTheKeyboardStaysPutWhenTheReplyStreams() throws {
    for scroll: CGFloat in [300, 350] {
      var transcript = Array(0..<120)
      var texts: [Int: String] = [:]
      let controller = UIHostingController(rootView: Harness(rows: Self.window(transcript, texts)))
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
      window.rootViewController = controller
      window.isHidden = false
      self.window = window
      controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: Self.keyboardUpHeight)
      controller.view.layoutIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
      let view = try XCTUnwrap(Self.collectionView(in: controller.view))
      func render() {
        controller.rootView = Harness(rows: Self.window(transcript, texts))
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view.layoutIfNeeded()
      }

      // Send: the user's row and the thinking row land while pinned (each slides the window).
      transcript.append(1000); texts[1000] = "hello"; render()
      transcript.append(1001); texts[1001] = "Thinking…"; render()
      XCTAssertLessThan(Self.distanceFromBottom(view), 1, "scroll \(scroll): pinned after the send")

      // Scroll up; the keyboard hides over the second half of the drag.
      view.delegate?.scrollViewWillBeginDragging?(view)
      for step in 1...10 {
        view.contentOffset.y -= scroll / 10
        if step > 5 {
          let progress = CGFloat(step - 5) / 5
          let height = Self.keyboardUpHeight + (Self.keyboardDownHeight - Self.keyboardUpHeight) * progress
          controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: height)
          controller.view.layoutIfNeeded()
        }
        view.delegate?.scrollViewDidScroll?(view)
      }
      view.delegate?.scrollViewDidEndDragging?(view, willDecelerate: false)
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      view.layoutIfNeeded()
      let before = try XCTUnwrap(Self.topRow(in: view, transcript: transcript))

      // The reply's first words land above the thinking row, then keep streaming.
      transcript.insert(1002, at: transcript.count - 1)
      texts[1002] = "The"
      render()
      for word in ["reply", "keeps", "streaming", "in", "more", "words"] {
        texts[1002]! += " " + word
        render()
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.6))
      view.layoutIfNeeded()

      let after = try XCTUnwrap(Self.topRow(in: view, transcript: transcript))
      XCTAssertEqual(after.id, before.id, "scroll \(scroll): the reader's top row must stay on top")
      XCTAssertEqual(after.y, before.y, accuracy: 0.5, "scroll \(scroll): and at the same on-screen y")
      XCTAssertGreaterThan(Self.distanceFromBottom(view), 1, "scroll \(scroll): not jumped to the bottom")
      window.isHidden = true
    }
  }

  // MARK: - Fixtures and geometry

  /// The reducer's 50-row bottom window over `transcript`.
  private static func window(_ transcript: [Int], _ texts: [Int: String]) -> [ChatRow] {
    transcript.suffix(50).map { number in
      ChatRow(id: rowID(number), kind: .message(
        role: number.isMultiple(of: 2) ? .assistant : .user,
        text: texts[number] ?? "Message \(number). An older message with enough text to wrap over a few lines.",
        isComplete: true
      ))
    }
  }

  private static func rowID(_ number: Int) -> ChatRow.ID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }

  /// The topmost row on screen and its top edge in viewport coordinates.
  private static func topRow(in view: UICollectionView, transcript: [Int]) -> (id: Int, y: CGFloat)? {
    let visibleWindow = Array(transcript.suffix(50))
    return view.indexPathsForVisibleItems
      .compactMap { indexPath -> (id: Int, y: CGFloat)? in
        guard let frame = view.layoutAttributesForItem(at: indexPath)?.frame,
              frame.maxY > view.contentOffset.y, indexPath.item < visibleWindow.count
        else { return nil }
        return (visibleWindow[indexPath.item], frame.minY - view.contentOffset.y)
      }
      .min { $0.y < $1.y }
  }

  private static func distanceFromBottom(_ view: UICollectionView) -> CGFloat {
    TranscriptScrollMath.maxOffsetY(
      contentHeight: view.contentSize.height, viewportHeight: view.bounds.height,
      topInset: view.adjustedContentInset.top, bottomInset: view.adjustedContentInset.bottom
    ) - view.contentOffset.y
  }

  private static func collectionView(in view: UIView) -> UICollectionView? {
    if let found = view as? UICollectionView { return found }
    for sub in view.subviews {
      if let found = collectionView(in: sub) { return found }
    }
    return nil
  }
}

/// The transcript as `ChatView` mounts it, with plain text cells.
private struct Harness: View {
  let rows: [ChatRow]

  var body: some View {
    CollectionTranscriptView(
      items: rows.map(TranscriptItem.row), rowIDs: rows.map(\.id),
      turnState: .streaming, canLoadOlder: true, onLoadOlder: {}
    ) { item in
      Text(Self.text(item)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
    .dynamicTypeSize(.large)
  }

  private static func text(_ item: TranscriptItem) -> String {
    if case let .row(row) = item, case let .message(_, text, _) = row.kind { return text }
    return ""
  }
}
