import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured (not eyeballed) checks for the live-window slide (#125).
///
/// The reducer keeps a fixed 50-row bottom window, so on a long chat every appended row (a tool
/// call, the answer, a user echo) drops the window's first row. `TranscriptDiffKind.classify`
/// calls that a `.slide`, and `CollectionTranscriptView` must then:
///
/// - **preserve** — a reader scrolled up keeps the row they were reading at the same on-screen
///   y (the dropped head row was above it, so the offset shifts by exactly that row's height);
/// - **follow** — a reader pinned at the bottom ends at the new bottom.
///
/// A snapshot can't see either: both are offsets across an update. So these tests host the real
/// `CollectionTranscriptView` in a window, drive the user scroll through the collection view's
/// own delegate (the coordinator), apply a slid window by re-rendering the representable, and
/// read the geometry straight off the `UICollectionView`. Rows are fixed-height so every number
/// below is exact, and Dynamic Type is pinned to `.large` so nothing follows the simulator.
///
/// **Red-checked** against a renderer whose scrolled-up slide takes the reset jump (the pre-fix
/// behaviour): every watched row moved ~2000pt off screen and the offset landed on the bottom,
/// so the preserve test went red on every assertion.
final class TranscriptSlidePreservationTests: XCTestCase {
  /// iPhone 13 Pro width, a phone-height transcript region.
  private static let windowSize = CGSize(width: 390, height: 700)

  private var windows: [UIWindow] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    super.tearDown()
  }

  // MARK: - Scrolled up: preserve

  /// The #125 yank: scrolled up mid-list, a slid window lands. The row the reader was looking at
  /// must stay exactly where it was on screen, and the list must not have jumped to the bottom.
  @MainActor
  func testScrolledUpReaderKeepsTheirRowOnScreenWhenTheWindowSlides() throws {
    let hosted = try host(rows: Self.rows(0..<50))
    let transcript = hosted.transcript

    // A real user drag ends the open-at-bottom settle, then parks the reader mid-list.
    transcript.delegate?.scrollViewWillBeginDragging?(transcript)
    Self.selfSizeEveryRow(in: transcript)
    let parked = Self.maxOffsetY(of: transcript) / 2
    transcript.setContentOffset(CGPoint(x: 0, y: parked), animated: false)
    transcript.delegate?.scrollViewDidScroll?(transcript)
    spinRunLoop()
    // Lay the cells out at the new offset, as the next frame would during a real scroll.
    transcript.layoutIfNeeded()
    XCTAssertEqual(transcript.contentOffset.y, parked, accuracy: 0.5, "Fixture sanity: the reader is parked")

    // Track every row fully on screen, not just one, so a partial preservation can't slip by.
    let watched = Self.fullyVisibleRowIndices(in: transcript)
    XCTAssertGreaterThanOrEqual(watched.count, 3, "Fixture sanity: several rows must be on screen")
    let before = watched.map { Self.onScreenMinY(ofRow: $0, in: transcript) }

    // The live slide: row 0 drops off the head, row 50 lands at the tail.
    hosted.update(rows: Self.rows(1..<51))

    for (index, row) in watched.enumerated() {
      let after = Self.onScreenMinY(ofRow: row, in: transcript, firstRow: 1)
      XCTAssertEqual(
        after, before[index], accuracy: 0.5,
        "Row \(row) must stay where the reader saw it — moving it is the #125 yank"
      )
    }
    XCTAssertLessThan(
      transcript.contentOffset.y, Self.maxOffsetY(of: transcript) - 100,
      "A scrolled-up reader must not be jumped to the bottom by a live slide"
    )
  }

  // MARK: - Pinned: follow

  /// The other half of the contract: a reader parked at the bottom follows the slide to the new
  /// bottom. The landing row is taller than the one that drops, so the bottom genuinely moves —
  /// a renderer that did nothing would end short of it.
  @MainActor
  func testPinnedReaderFollowsTheSlideToTheNewBottom() throws {
    let tailID = Self.rowID(50)
    let hosted = try host(rows: Self.rows(0..<50), tallRows: [tailID: 400])
    let transcript = hosted.transcript

    // A touch at the bottom ends the open settle (so the follow below is the slide's, not the
    // settle re-pinning on layout) and leaves the reader pinned.
    transcript.delegate?.scrollViewWillBeginDragging?(transcript)
    transcript.delegate?.scrollViewDidScroll?(transcript)
    spinRunLoop()
    let oldBottom = Self.maxOffsetY(of: transcript)
    XCTAssertEqual(transcript.contentOffset.y, oldBottom, accuracy: 0.5, "Fixture sanity: opens at the bottom")

    hosted.update(rows: Self.rows(1..<51))

    let newBottom = Self.maxOffsetY(of: transcript)
    XCTAssertGreaterThan(
      newBottom, oldBottom + 200, "Fixture sanity: the tall landing row must move the bottom"
    )
    // The follow animates (reduce motion is off), so wait for it to land.
    let deadline = Date().addingTimeInterval(2)
    while abs(transcript.contentOffset.y - newBottom) > 0.5, Date() < deadline {
      spinRunLoop()
    }
    XCTAssertEqual(
      transcript.contentOffset.y, newBottom, accuracy: 0.5,
      "A pinned reader must follow the slide to the new bottom"
    )
  }

  // MARK: - Hosting

  /// The real `CollectionTranscriptView`, rendered into a hosting controller whose root view the
  /// test swaps to deliver a new `rows` slice — the same `updateUIView` → `apply(rows:)` path
  /// the store drives in the app.
  @MainActor
  private struct Hosted {
    let controller: UIHostingController<TranscriptHarnessView>
    let transcript: UICollectionView
    let tallRows: [ChatRow.ID: CGFloat]

    func update(rows: [ChatRow]) {
      controller.rootView = TranscriptHarnessView(rows: rows, tallRows: tallRows)
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      transcript.layoutIfNeeded()
    }
  }

  @MainActor
  private func host(
    rows: [ChatRow],
    tallRows: [ChatRow.ID: CGFloat] = [:],
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> Hosted {
    let controller = UIHostingController(
      rootView: TranscriptHarnessView(rows: rows, tallRows: tallRows)
    )
    let window = UIWindow(frame: CGRect(origin: .zero, size: Self.windowSize))
    window.rootViewController = controller
    window.isHidden = false
    windows.append(window)
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    // Let the open-at-bottom settle run over the self-sizing passes before reading geometry.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    let transcript = try XCTUnwrap(
      Self.collectionView(in: controller.view), "the transcript must be hosted", file: file, line: line
    )
    XCTAssertGreaterThan(
      transcript.contentSize.height, transcript.bounds.height * 2,
      "Fixture sanity: the transcript must be several screens tall", file: file, line: line
    )
    return Hosted(controller: controller, transcript: transcript, tallRows: tallRows)
  }

  /// Let queued main-queue work (the coordinator clears its `isAdjustingOffset` guard on the
  /// next runloop) and any in-flight layout run.
  private func spinRunLoop() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }

  // MARK: - Geometry

  private static func maxOffsetY(of view: UICollectionView) -> CGFloat {
    TranscriptScrollMath.maxOffsetY(
      contentHeight: view.contentSize.height,
      viewportHeight: view.bounds.height,
      topInset: view.adjustedContentInset.top,
      bottomInset: view.adjustedContentInset.bottom
    )
  }

  /// Scroll the whole list through the viewport so every `.estimated(60)` row self-sizes to
  /// its real height — otherwise parking mid-list measures rows that were still estimates and
  /// the layout nudges the offset under the fixture. Called after the drag that ends the open
  /// settle, which would otherwise re-pin to the bottom on every pass.
  private static func selfSizeEveryRow(in view: UICollectionView) {
    var y = -view.adjustedContentInset.top
    while y < maxOffsetY(of: view) {
      view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
      view.layoutIfNeeded()
      y += view.bounds.height / 2
    }
    view.setContentOffset(CGPoint(x: 0, y: maxOffsetY(of: view)), animated: false)
    view.layoutIfNeeded()
  }

  /// A row's top edge in viewport coordinates. `firstRow` is the row number at item 0 of the
  /// current window (1 after the slide drops row 0).
  private static func onScreenMinY(
    ofRow row: Int, in view: UICollectionView, firstRow: Int = 0
  ) -> CGFloat {
    let indexPath = IndexPath(item: row - firstRow, section: 0)
    let frame = view.layoutAttributesForItem(at: indexPath)?.frame ?? .null
    return frame.minY - view.contentOffset.y
  }

  /// Row numbers (window starting at row 0) whose frames lie entirely inside the viewport.
  private static func fullyVisibleRowIndices(in view: UICollectionView) -> [Int] {
    let visible = view.bounds
    return view.indexPathsForVisibleItems
      .filter { indexPath in
        guard let frame = view.layoutAttributesForItem(at: indexPath)?.frame else { return false }
        return visible.contains(frame)
      }
      .map(\.item)
      .sorted()
  }

  private static func collectionView(in view: UIView) -> UICollectionView? {
    if let found = view as? UICollectionView { return found }
    for sub in view.subviews {
      if let found = collectionView(in: sub) { return found }
    }
    return nil
  }

  // MARK: - Fixtures

  /// Deterministic per-row ids, so the same row number is the same row across windows.
  private static func rowID(_ number: Int) -> ChatRow.ID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }

  private static func rows(_ numbers: Range<Int>) -> [ChatRow] {
    numbers.map { number in
      ChatRow(
        id: rowID(number),
        kind: .message(role: .assistant, text: "Row \(number)", isComplete: true)
      )
    }
  }
}

/// The transcript as `ChatView` mounts it, with fixed-height cells in place of message bubbles:
/// the scroll behaviour under test lives entirely in the renderer, and exact row heights make
/// every offset in the assertions exact.
private struct TranscriptHarnessView: View {
  /// Every row's height unless `tallRows` overrides it.
  static let rowHeight: CGFloat = 80


  let rows: [ChatRow]
  let tallRows: [ChatRow.ID: CGFloat]

  var body: some View {
    CollectionTranscriptView(
      rows: rows,
      turnState: .streaming,
      canLoadOlder: false,
      onLoadOlder: {}
    ) { row in
      FixedHeightRow(row: row, height: tallRows[row.id] ?? Self.rowHeight)
    }
    .dynamicTypeSize(.large)
  }
}

private struct FixedHeightRow: View {
  let row: ChatRow
  let height: CGFloat

  var body: some View {
    Text(label)
      .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
  }

  private var label: String {
    if case let .message(_, text, _) = row.kind { return text }
    return ""
  }
}
