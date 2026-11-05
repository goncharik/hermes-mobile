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
/// - **topmost anchor** — with a tool row inserted above the thinking row, the topmost surviving
///   row is held, not the unmoved thinking row;
/// - **page older** — a hold that carries the reader to the window top requests older rows;
/// - **tall dropped row** — a reader inside a dropped row taller than the screen is held at the
///   window top, never jumped to the bottom;
/// - **back-to-back slides** — two slides before UIKit runs the first apply's completion drift
///   nothing;
/// - **drag / scroll before the completion** — the completion never overwrites where the user
///   moved the list, and the hold lands in the same pass as the apply;
/// - **follow** — a reader pinned at the bottom ends at the new bottom, including after a
///   hydrate that re-ids the tail rows (they land on estimated heights and grow).
///
/// A snapshot can't see any of these: they are offsets across an update. So these tests host the real
/// `CollectionTranscriptView` in a window, drive the user scroll through the collection view's
/// own delegate (the coordinator), apply a slid window by re-rendering the representable, and
/// read the geometry straight off the `UICollectionView`. Rows are fixed-height so every number
/// below is exact, and Dynamic Type is pinned to `.large` so nothing follows the simulator.
///
/// **Red-checked** against a renderer whose scrolled-up slide takes the reset jump (the pre-fix
/// behaviour): every watched row moved ~2000pt off screen and the offset landed on the bottom,
/// so the preserve test went red on every assertion. The hold-timing and pinned-hydrate tests
/// went red against a renderer that held the anchor in the apply's completion and followed a
/// pinned slide with an animated scroll (a 60pt pull-back; a pinned reader 480pt short).
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

    let parked = parkReader(transcript) { Self.maxOffsetY(of: $0) / 2 }
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

  /// The live `tool.start` shape with the tail on screen: the head drops and a tool row lands
  /// ABOVE the thinking row, so the thinking row does not move while every row above the insert
  /// moves up by one row. Only the topmost surviving row is the right anchor.
  @MainActor
  func testLiveToolRowSlideHoldsTheTopmostVisibleRow() throws {
    let hosted = try host(rows: Self.rows(0..<50))
    let transcript = hosted.transcript

    // Just past the pin threshold, so the thinking row (row 49) is partly on screen.
    parkReader(transcript) { Self.maxOffsetY(of: $0) - TranscriptScrollMath.bottomThreshold - 15 }
    let thinkingFrame = try XCTUnwrap(transcript.layoutAttributesForItem(at: IndexPath(item: 49, section: 0))?.frame)
    XCTAssertLessThan(
      thinkingFrame.minY, transcript.bounds.maxY, "Fixture sanity: the thinking row is on screen"
    )

    let watched = Self.fullyVisibleRowIndices(in: transcript).filter { $0 < 49 }
    XCTAssertGreaterThanOrEqual(watched.count, 3, "Fixture sanity: several rows above the insert")
    let before = watched.map { Self.onScreenMinY(ofRow: $0, in: transcript) }

    hosted.update(rows: Self.rows(1..<49) + Self.rows(900..<901) + Self.rows(49..<50))

    for (index, row) in watched.enumerated() {
      XCTAssertEqual(
        Self.onScreenMinY(ofRow: row, in: transcript, firstRow: 1), before[index], accuracy: 0.5,
        "Row \(row) above the tool insert must stay where the reader saw it"
      )
    }
  }

  /// A slide that carries the reader to the window top pages older rows in, as a user scroll
  /// there would — otherwise each further slide pins them against the top and the content creeps.
  @MainActor
  func testSlideThatCarriesTheReaderToTheWindowTopPagesOlderRows() throws {
    let olderPages = OlderPageRequests()
    let hosted = try host(rows: Self.rows(0..<50), olderPages: olderPages)
    let transcript = hosted.transcript

    // Just below the load-older trigger, with row 0 scrolled off the top.
    parkReader(transcript) {
      -$0.adjustedContentInset.top + TranscriptScrollMath.loadOlderTopThreshold + 40
    }
    let watchedY = Self.onScreenMinY(ofRow: 1, in: transcript)
    let requestsBefore = olderPages.count

    hosted.update(rows: Self.rows(1..<51))

    XCTAssertEqual(
      Self.onScreenMinY(ofRow: 1, in: transcript, firstRow: 1), watchedY, accuracy: 0.5,
      "Row 1 must stay where the reader saw it"
    )
    XCTAssertEqual(olderPages.count, requestsBefore + 1, "The shift to the window top must page older rows")
  }

  /// The reader is inside a row taller than the screen when the slide drops it: no surviving row
  /// is on screen, so the nearest survivor is held — the offset clamps at the window top — and
  /// older rows are paged in. Never the jump to the bottom.
  @MainActor
  func testReaderInsideATallDroppedRowIsHeldAtTheWindowTop() throws {
    let olderPages = OlderPageRequests()
    let hosted = try host(rows: Self.rows(0..<50), tallRows: [Self.rowID(0): 2000], olderPages: olderPages)
    let transcript = hosted.transcript

    parkReader(transcript) { _ in 1000 }
    XCTAssertEqual(
      transcript.indexPathsForVisibleItems.map(\.item), [0],
      "Fixture sanity: only the tall row is on screen"
    )
    let requestsBefore = olderPages.count

    hosted.update(rows: Self.rows(1..<51))

    XCTAssertEqual(
      transcript.contentOffset.y, -transcript.adjustedContentInset.top, accuracy: 0.5,
      "The reader must be held at the window top, next to the row that dropped"
    )
    XCTAssertEqual(olderPages.count, requestsBefore + 1, "Older rows must be paged back in")
  }

  /// Two slides land before UIKit runs the first apply's completion: the second completion must
  /// not undo the first one's shift (a one-row drift), so the reader's rows stay put across both.
  @MainActor
  func testBackToBackSlidesBeforeTheApplyCompletesKeepTheReadersRows() throws {
    let hosted = try host(rows: Self.rows(0..<50))
    let transcript = hosted.transcript

    parkReader(transcript) { Self.maxOffsetY(of: $0) / 2 }
    let watched = Self.fullyVisibleRowIndices(in: transcript)
    XCTAssertGreaterThanOrEqual(watched.count, 3, "Fixture sanity: several rows must be on screen")
    let before = watched.map { Self.onScreenMinY(ofRow: $0, in: transcript) }

    hosted.deliver(rows: Self.rows(1..<51))
    hosted.deliver(rows: Self.rows(2..<52))
    hosted.settle()

    for (index, row) in watched.enumerated() {
      XCTAssertEqual(
        Self.onScreenMinY(ofRow: row, in: transcript, firstRow: 2), before[index], accuracy: 0.5,
        "Row \(row) must stay where the reader saw it across both slides"
      )
    }
  }

  /// A drag that starts before the slide's apply completes owns the offset: the completion must
  /// not overwrite where the user's finger has moved the list.
  @MainActor
  func testDragStartedBeforeTheApplyCompletesKeepsTheUsersOffset() throws {
    let hosted = try host(rows: Self.rows(0..<50))
    let transcript = hosted.transcript

    parkReader(transcript) { Self.maxOffsetY(of: $0) / 2 }

    hosted.deliver(rows: Self.rows(1..<51))
    transcript.delegate?.scrollViewWillBeginDragging?(transcript)
    let dragged = transcript.contentOffset.y - 30
    transcript.setContentOffset(CGPoint(x: 0, y: dragged), animated: false)
    hosted.settle()

    XCTAssertEqual(
      transcript.contentOffset.y, dragged, accuracy: 0.5,
      "The pending slide correction must not override the user's drag"
    )
  }

  /// The hold lands in the same update as the slide, so the slid layout is never drawn
  /// uncorrected; and a scroll that moves the list before UIKit runs the apply's completion (a
  /// fling still decelerating, no new drag) is kept, not overwritten by a pre-apply offset.
  @MainActor
  func testHoldLandsWithTheSlideAndKeepsAScrollThatFollowsIt() throws {
    let hosted = try host(rows: Self.rows(0..<50))
    let transcript = hosted.transcript

    parkReader(transcript) { Self.maxOffsetY(of: $0) / 2 }
    let watched = try XCTUnwrap(Self.fullyVisibleRowIndices(in: transcript).first)
    let watchedY = Self.onScreenMinY(ofRow: watched, in: transcript)

    hosted.deliver(rows: Self.rows(1..<51))
    XCTAssertEqual(
      Self.onScreenMinY(ofRow: watched, in: transcript, firstRow: 1), watchedY, accuracy: 0.5,
      "The hold must land in the same update as the slide, not on a later pass"
    )

    let scrolled = transcript.contentOffset.y - 30
    transcript.setContentOffset(CGPoint(x: 0, y: scrolled), animated: false)
    hosted.settle()

    XCTAssertEqual(
      transcript.contentOffset.y, scrolled, accuracy: 0.5,
      "The slide's completion must not pull back a scroll that followed the apply"
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

    // Ending the open settle makes the follow below the slide's, not the settle re-pinning on
    // layout.
    pinReaderAtBottom(transcript)
    let oldBottom = Self.maxOffsetY(of: transcript)
    let watched = try XCTUnwrap(Self.fullyVisibleRowIndices(in: transcript).first)
    let watchedY = Self.onScreenMinY(ofRow: watched, in: transcript)

    // Run single run-loop passes until the offset first moves (the hold, in the same pass as the
    // apply; the follow comes from the apply's completion on a later pass).
    hosted.deliver(rows: Self.rows(1..<51))
    let moveDeadline = Date().addingTimeInterval(1)
    while abs(transcript.contentOffset.y - oldBottom) < 0.5, Date() < moveDeadline {
      RunLoop.current.run(mode: .default, before: Date())
    }

    // Before the follow advances, the surviving rows have not jumped by the dropped head's height.
    XCTAssertEqual(
      Self.onScreenMinY(ofRow: watched, in: transcript, firstRow: 1), watchedY, accuracy: 0.5,
      "The follow must start from the rows the reader saw, not from a jump by the dropped row"
    )

    let newBottom = Self.maxOffsetY(of: transcript)
    XCTAssertGreaterThan(
      newBottom, oldBottom + 200, "Fixture sanity: the tall landing row must move the bottom"
    )
    // Wait for the follow to land.
    let deadline = Date().addingTimeInterval(2)
    while abs(transcript.contentOffset.y - newBottom) > 0.5, Date() < deadline {
      spinRunLoop()
    }
    XCTAssertEqual(
      transcript.contentOffset.y, newBottom, accuracy: 0.5,
      "A pinned reader must follow the slide to the new bottom"
    )
  }

  /// A hydrate after a finished turn rebuilds the live tail rows under new (history) ids while the
  /// older rows keep theirs — a `.slide` with nothing dropped. The rebuilt rows land on estimated
  /// heights and grow as they size, so a pinned reader must end on the bottom as it is once every
  /// row has sized, not on one computed from the estimates.
  @MainActor
  func testPinnedReaderEndsAtTheBottomAfterAHydrateReIdsTheTailRows() throws {
    let rebuilt = 1000..<1005
    let hosted = try host(
      rows: Self.rows(0..<50),
      tallRows: Dictionary(uniqueKeysWithValues: rebuilt.map { (Self.rowID($0), 300) })
    )
    let transcript = hosted.transcript

    pinReaderAtBottom(transcript)
    let contentHeightBefore = transcript.contentSize.height

    hosted.update(rows: Self.rows(0..<45) + Self.rows(rebuilt))

    let deadline = Date().addingTimeInterval(2)
    while abs(transcript.contentOffset.y - Self.maxOffsetY(of: transcript)) > 0.5, Date() < deadline {
      spinRunLoop()
      transcript.layoutIfNeeded()
    }
    XCTAssertGreaterThan(
      transcript.contentSize.height, contentHeightBefore + 300,
      "Fixture sanity: the rebuilt rows must have grown past their estimates"
    )
    XCTAssertEqual(
      transcript.contentOffset.y, Self.maxOffsetY(of: transcript), accuracy: 0.5,
      "A pinned reader must end on the current bottom after the hydrate"
    )
  }

  // MARK: - Unmeasurable view: defer, then flush (#128)

  /// Updates that reach a populated transcript while it has no window are not applied; once it
  /// is back in the window at its unchanged size, only the latest lands and a pinned reader
  /// ends on its bottom. SwiftUI runs no `updateUIView` for an off-window host, so the updates
  /// go to the coordinator directly — the same `apply` that `updateUIView` calls.
  @MainActor
  func testUpdatesWhileDetachedLandOnReattachAndAPinnedReaderFollows() throws {
    let hosted = try host(rows: Self.rows(0..<50))
    let transcript = hosted.transcript
    pinReaderAtBottom(transcript)
    let window = try XCTUnwrap(hosted.controller.view.window)
    let coordinator = try XCTUnwrap(
      transcript.delegate as? CollectionTranscriptView<FixedHeightRow>.Coordinator
    )

    window.rootViewController = nil
    XCTAssertNil(transcript.window, "Fixture sanity: the transcript is out of the window")
    // An append, then the live slide on top of it (51 rows, then 52).
    for rows in [Self.rows(0..<51), Self.rows(1..<53)] {
      coordinator.apply(items: rows.map(TranscriptItem.row), rowIDs: rows.map(\.id))
    }
    XCTAssertEqual(transcript.numberOfItems(inSection: 0), 50, "No apply may land without a window")

    window.rootViewController = hosted.controller
    assertLandedAtBottom(transcript, itemCount: 52, hosted: hosted)
  }

  /// A scrolled-up reader's slide that waited out the detach is held like a live one when it
  /// lands (the hold then runs inside the layout pass that flushes it).
  @MainActor
  func testScrolledUpReaderKeepsTheirRowsWhenADetachedSlideLands() throws {
    let hosted = try host(rows: Self.rows(0..<50))
    let transcript = hosted.transcript
    let window = try XCTUnwrap(hosted.controller.view.window)
    let coordinator = try XCTUnwrap(
      transcript.delegate as? CollectionTranscriptView<FixedHeightRow>.Coordinator
    )
    parkReader(transcript) { Self.maxOffsetY(of: $0) / 2 }
    let watched = Self.fullyVisibleRowIndices(in: transcript)
    XCTAssertGreaterThanOrEqual(watched.count, 3, "Fixture sanity: several rows must be on screen")
    let before = watched.map { Self.onScreenMinY(ofRow: $0, in: transcript) }

    window.rootViewController = nil
    for rows in [Self.rows(1..<51), Self.rows(2..<52)] {
      coordinator.apply(items: rows.map(TranscriptItem.row), rowIDs: rows.map(\.id))
    }
    window.rootViewController = hosted.controller
    hosted.settle()

    for (index, row) in watched.enumerated() {
      XCTAssertEqual(
        Self.onScreenMinY(ofRow: row, in: transcript, firstRow: 2), before[index], accuracy: 0.5,
        "Row \(row) must stay where the reader saw it once the deferred slide lands"
      )
    }
  }

  /// The same for a degenerate frame (here zero height, the gate's `height > 0` leg): updates
  /// wait, and restoring the frame lands the latest one with a pinned reader at its bottom.
  @MainActor
  func testUpdatesAtADegenerateFrameLandWhenTheFrameRecovers() throws {
    let hosted = try host(rows: Self.rows(0..<50))
    let transcript = hosted.transcript
    pinReaderAtBottom(transcript)
    let view = hosted.controller.view!

    view.frame.size.height = 0
    view.layoutIfNeeded()
    XCTAssertEqual(transcript.bounds.height, 0, "Fixture sanity: the transcript has no height")
    hosted.deliver(rows: Self.rows(0..<51))
    hosted.deliver(rows: Self.rows(1..<53))
    XCTAssertEqual(transcript.numberOfItems(inSection: 0), 50, "No apply may land at a degenerate frame")

    view.frame.size = Self.windowSize
    view.layoutIfNeeded()
    assertLandedAtBottom(transcript, itemCount: 52, hosted: hosted)
  }

  /// A touch at the bottom ends the open settle and leaves the reader pinned.
  @MainActor
  private func pinReaderAtBottom(_ transcript: UICollectionView) {
    transcript.delegate?.scrollViewWillBeginDragging?(transcript)
    transcript.delegate?.scrollViewDidScroll?(transcript)
    spinRunLoop()
    XCTAssertEqual(
      transcript.contentOffset.y, Self.maxOffsetY(of: transcript), accuracy: 0.5,
      "Fixture sanity: opens at the bottom"
    )
  }

  @MainActor
  private func assertLandedAtBottom(
    _ transcript: UICollectionView, itemCount: Int, hosted: Hosted,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(2)
    while transcript.numberOfItems(inSection: 0) != itemCount
      || abs(transcript.contentOffset.y - Self.maxOffsetY(of: transcript)) > 0.5,
      Date() < deadline {
      hosted.settle()
    }
    XCTAssertEqual(
      transcript.numberOfItems(inSection: 0), itemCount, "The latest deferred update must land",
      file: file, line: line
    )
    XCTAssertEqual(
      transcript.contentOffset.y, Self.maxOffsetY(of: transcript), accuracy: 0.5,
      "A pinned reader must end on the bottom of the flushed update", file: file, line: line
    )
  }

  // MARK: - Hosting

  /// The real `CollectionTranscriptView`, rendered into a hosting controller whose root view the
  /// test swaps to deliver a new `rows` slice — the same `updateUIView` → `apply(items:rowIDs:)` path
  /// the store drives in the app.
  @MainActor
  private struct Hosted {
    let controller: UIHostingController<TranscriptHarnessView>
    let transcript: UICollectionView
    let tallRows: [ChatRow.ID: CGFloat]
    let olderPages: OlderPageRequests?

    /// Deliver `rows` and let queued main-queue work (guard clears, a load-older request) run.
    func update(rows: [ChatRow]) {
      deliver(rows: rows)
      settle()
    }

    /// Deliver `rows` through `updateUIView` WITHOUT a run-loop pass, so the snapshot apply's
    /// completion is still pending when this returns.
    func deliver(rows: [ChatRow]) {
      controller.rootView = TranscriptHarnessView(rows: rows, tallRows: tallRows, olderPages: olderPages)
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
    }

    /// Let pending apply completions and queued main-queue work run, then lay out.
    func settle() {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      transcript.layoutIfNeeded()
    }
  }

  @MainActor
  private func host(
    rows: [ChatRow],
    tallRows: [ChatRow.ID: CGFloat] = [:],
    olderPages: OlderPageRequests? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> Hosted {
    let controller = UIHostingController(
      rootView: TranscriptHarnessView(rows: rows, tallRows: tallRows, olderPages: olderPages)
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
    return Hosted(
      controller: controller, transcript: transcript, tallRows: tallRows, olderPages: olderPages
    )
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

  /// Scroll the reader away from the open-at-bottom as a user would: a drag ends the settle, every
  /// row self-sizes, then the reader parks at `offsetY` (read after sizing) and the coordinator
  /// re-reads its pin. Returns the parked offset.
  @MainActor
  @discardableResult
  private func parkReader(
    _ view: UICollectionView, at offsetY: (UICollectionView) -> CGFloat
  ) -> CGFloat {
    view.delegate?.scrollViewWillBeginDragging?(view)
    Self.selfSizeEveryRow(in: view)
    let parked = offsetY(view)
    view.setContentOffset(CGPoint(x: 0, y: parked), animated: false)
    view.delegate?.scrollViewDidScroll?(view)
    spinRunLoop()
    // Lay the cells out at the new offset, as the next frame would during a real scroll.
    view.layoutIfNeeded()
    return parked
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
  /// When set, older history exists above the window and each request is counted here.
  let olderPages: OlderPageRequests?

  var body: some View {
    CollectionTranscriptView(
      items: rows.map(TranscriptItem.row),
      rowIDs: rows.map(\.id),
      turnState: .streaming,
      canLoadOlder: olderPages != nil,
      onLoadOlder: { olderPages?.count += 1 }
    ) { item in
      FixedHeightRow(item: item, height: tallRows[item.id] ?? Self.rowHeight)
    }
    .dynamicTypeSize(.large)
  }
}

/// Counts the transcript's `onLoadOlder` calls.
private final class OlderPageRequests {
  var count = 0
}

private struct FixedHeightRow: View {
  let item: TranscriptItem
  let height: CGFloat

  var body: some View {
    Text(label)
      .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
  }

  private var label: String {
    if case let .row(row) = item, case let .message(_, text, _) = row.kind { return text }
    return ""
  }
}
