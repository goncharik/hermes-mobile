import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured (not eyeballed) acceptance checks for the table renderer (#59).
///
/// A snapshot proves what a table *looks* like inside one viewport, but it cannot
/// distinguish "the grid pans" from "the grid was clipped and its content thrown away" —
/// both produce the same first screenful. These tests host the real view, force a layout
/// pass, and read the numbers straight off the resulting `UIScrollView`:
///
/// - a table wider than the viewport has `contentSize.width > bounds.width` (it pans, and
///   the off-screen columns still exist) and can actually be scrolled to its end;
/// - a table that fits has a *non-zero* content size no wider than the viewport (the
///   upper bound alone is satisfied by a collapsed 0×0 grid, which is a real failure mode
///   of a horizontal `ScrollView` under a compressed-fit proposal);
/// - the hosted height hugs the content and does not vary with the offered width — the
///   phantom gap the issue reported, measured in a real `UICollectionView` row;
/// - long cells *wrap* at the column cap instead of being clipped to one line — asserted
///   **through `MarkdownTableView` itself**, so reverting the cell recipe to the
///   `.frame(maxWidth: 260)` the fix replaced turns this suite red.
///
/// Dynamic Type is pinned to `.large` except in the two tests that vary it: the cap scales
/// with the content size category, so every numeric threshold below would otherwise depend
/// on the simulator's text-size setting.
final class MarkdownTableLayoutTests: XCTestCase {
  /// iPhone 13 Pro width — the same viewport the snapshot suite pins.
  private static let viewportWidth: CGFloat = 390

  /// What a transcript row actually gets on that device: the collection view's section
  /// insets take `TranscriptLayout.horizontalSectionInset` off each edge — read from the
  /// production metric, not re-typed, so a change there moves these widths with it.
  private static let usableTranscriptWidth: CGFloat =
    viewportWidth - 2 * TranscriptLayout.horizontalSectionInset

  /// A row on the **narrowest** layout the app can be rendered at (288pt). This — not 358 —
  /// is the width ``MarkdownTableView/columnMaxWidthCeiling`` claims to cover, so it is the
  /// width the ceiling's guard test has to measure at.
  private static let narrowestTranscriptWidth = TranscriptLayout.narrowestRowWidth

  /// The collection-view width that produces ``narrowestTranscriptWidth`` of row.
  private static let narrowestCollectionWidth = TranscriptLayout.narrowestLayoutWidth

  /// Kept alive for the duration of a test: a hosted view only lays out for real while its
  /// window exists, and SwiftUI won't materialise the `UIScrollView` otherwise.
  private var windows: [UIWindow] = []

  /// Collection-view harnesses stay owned by the test: a `UICollectionView` holds its data
  /// source weakly, so dropping one mid-test would empty the list.
  private var harnesses: [TranscriptCellHarness] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    harnesses = []
    super.tearDown()
  }

  // MARK: - Panning

  func testWideTablePansHorizontallyInsteadOfClipping() throws {
    let scroll = try scrollView(for: wideTable)
    XCTAssertEqual(scroll.bounds.width, Self.viewportWidth, accuracy: 1)
    XCTAssertGreaterThan(
      scroll.contentSize.width, scroll.bounds.width,
      "A table wider than the screen must have pannable content, not clipped-away columns"
    )
    // The off-screen columns are reachable: pan to the trailing edge and it sticks.
    let end = scroll.contentSize.width - scroll.bounds.width
    scroll.setContentOffset(CGPoint(x: end, y: 0), animated: false)
    XCTAssertEqual(scroll.contentOffset.x, end, accuracy: 1, "The hidden columns must be scrollable into view")
  }

  func testFittingTableDoesNotPan() throws {
    let table = MarkdownTableView(headers: ["Key", "Value"], rows: [["on", "true"], ["off", "false"]])
    let scroll = try scrollView(for: table)
    XCTAssertLessThanOrEqual(
      scroll.contentSize.width, scroll.bounds.width + 1,
      "A small table must render inline at natural column widths with nothing to pan"
    )
    // An upper bound alone also holds for a table that collapsed to nothing, and a
    // horizontal `ScrollView` really can collapse (it is flexible on its scroll axis).
    // Four short words + one gap measure ~86pt; anything near the viewport means the
    // columns stretched again, anything near zero means the grid vanished.
    XCTAssertGreaterThan(scroll.contentSize.width, 40, "The grid must actually be laid out, not collapsed")
    XCTAssertLessThan(scroll.contentSize.width, 200, "Columns must keep their natural width, not stretch")
    XCTAssertGreaterThan(scroll.contentSize.height, 0)
  }

  // MARK: - Wrapping (the cap half of the fix)

  /// The guard that fails if the cell recipe regresses to `.frame(maxWidth: 260)`: a framed
  /// cell reports its full single-line width and is merely *clipped* to 260pt, so the prose
  /// table would be exactly as tall as the all-short one (measured: 260×20pt for a sentence
  /// that genuinely needs 260×64pt). Asserted on the issue's own four-column shape.
  func testWideTableWithProseIsTallerThanTheSameShapeWithShortCells() throws {
    let prose = try scrollView(for: wideTable)
    let terse = try scrollView(for: wideTableShortCells)
    XCTAssertGreaterThan(
      prose.contentSize.height, terse.contentSize.height * 1.4,
      "Prose cells must wrap at the cap; a clipped single line would match the terse table's height"
    )
  }

  /// The one input that could plausibly defeat wrapping — a token with no break
  /// opportunities. Measured: `Text` falls back to character wrapping (259.7×64pt for an
  /// 80-character run), so it must never come back as one ellipsised line.
  func testUnbreakableTokenWrapsInsteadOfTruncating() throws {
    let token = String(repeating: "a", count: 80)
    let scroll = try scrollView(for: MarkdownTableView(headers: ["Hash"], rows: [[token]]))
    XCTAssertLessThanOrEqual(scroll.contentSize.width, MarkdownTableView.columnMaxWidth + 1)
    XCTAssertGreaterThan(
      scroll.contentSize.height, 60,
      "An unbreakable run must wrap across lines rather than being truncated to one"
    )
  }

  // MARK: - Height hugging (the phantom gap)

  /// The hosted row must be exactly as tall as the grid it contains: any slack is the blank
  /// band #59 reported. Asserted in a plain hosting controller *and* in the real transcript
  /// cell, at the width a transcript row actually gets.
  @MainActor
  func testTableHeightHugsItsContent() throws {
    let fitted = hostedSize(of: wideTable, width: Self.viewportWidth)
    let scroll = try scrollView(for: wideTable)
    XCTAssertEqual(
      fitted.height, scroll.contentSize.height, accuracy: 2,
      "The hosted height must equal the grid's own height — extra slack is the blank gap #59 reported"
    )
    XCTAssertGreaterThan(fitted.height, 0)

    let row = try rowHeights(for: Self.wideTableMarkdown)
    let rowScroll = try scrollView(for: wideTable, width: Self.usableTranscriptWidth)
    XCTAssertEqual(
      row.wide, rowScroll.contentSize.height, accuracy: 2,
      "The collection-view cell must hug the grid too — the difference is the phantom gap"
    )
  }

  // MARK: - The real hosting path (the phantom gap where it actually happens)

  /// The gap half of #59 *in the host it was reported on*: a transcript row is a self-sizing
  /// `UIHostingConfiguration` cell in a compositional layout whose item height is
  /// `.estimated(60)` (`CollectionTranscriptView`), so the row is measured, laid out, and —
  /// on a relayout or a `reconfigureItems` — measured again, potentially at another width. A
  /// height that answers differently across those passes *is* the blank band above/below the
  /// table.
  ///
  /// This drives the real thing: a `UICollectionView` with that layout and a
  /// `UIHostingConfiguration` cell registration, in a window, and reads the laid-out frame
  /// the layout produced (390pt-wide collection → the 358pt usable row; 320pt → the 288pt
  /// Display-Zoom row). `testHarnessDetectsWidthDependentRows` is what makes the equality a
  /// measurement rather than a property of the harness.
  @MainActor
  func testTableRowKeepsOneHeightAcrossRelayouts() throws {
    let table = try rowHeights(for: Self.wideTableMarkdown)
    XCTAssertGreaterThan(table.wide, 0)
    XCTAssertEqual(
      table.narrow, table.wide, accuracy: 1,
      "Re-laid out at 288pt the table row must keep the height it measured at 358pt — the difference is the gap"
    )
    XCTAssertEqual(
      table.reconfigured, table.wide, accuracy: 1,
      "Reconfiguring the item must re-measure to the same height, not a stale/re-wrapped one"
    )
  }

  /// A `UIHostingConfiguration` cell can carry SwiftUI state across recycling, so a table panned
  /// in one row could in principle re-appear mid-scroll in the unrelated row that reuses the
  /// cell — leading columns hidden, no fade, and nothing on screen saying so.
  ///
  /// Measured: it does not. The same `UICollectionViewCell` (and the very same `UIScrollView`
  /// inside it) re-opens the new table at the leading edge. The first half of the test is the
  /// control that makes that a measurement rather than an artifact of the harness — an
  /// **un-recycled** row keeps its pan across the same relayout, so a reset can only be the
  /// recycling. Both halves matter: drop the control and the assertion below is satisfied by a
  /// harness that silently resets everything.
  @MainActor
  func testRecycledRowShowsItsTableFromTheLeadingEdge() throws {
    let harness = TranscriptCellHarness(
      markdowns: [Self.wideTableMarkdown, Self.otherWideTableMarkdown], width: Self.viewportWidth
    )
    harnesses.append(harness)
    windows.append(harness.window)
    _ = harness.rowHeight(atCollectionWidth: Self.viewportWidth)

    let cellBefore = try XCTUnwrap(harness.visibleCell, "the row must be laid out")
    let scrollBefore = try XCTUnwrap(harness.tableScrollView, "the row must host the table's scroll view")
    let end = scrollBefore.contentSize.width - scrollBefore.bounds.width
    XCTAssertGreaterThan(end, 20, "Fixture sanity: the table must genuinely overflow the row")
    scrollBefore.setContentOffset(CGPoint(x: end, y: 0), animated: false)

    _ = harness.rowHeight(atCollectionWidth: Self.viewportWidth)
    XCTAssertEqual(
      scrollBefore.contentOffset.x, end, accuracy: 1,
      "Control: a row that is not recycled keeps its pan across a relayout"
    )

    harness.showRow(1)
    let cellAfter = try XCTUnwrap(harness.visibleCell)
    XCTAssertTrue(
      cellBefore === cellAfter,
      "Fixture sanity: UIKit must actually reuse the cell, otherwise this proves nothing"
    )
    let scrollAfter = try XCTUnwrap(harness.tableScrollView)
    XCTAssertEqual(
      scrollAfter.contentOffset.x, 0, accuracy: 1,
      "A recycled row must show its table from the leading edge, never mid-pan from the row before"
    )
  }

  /// The harness has teeth: content that really does depend on the offered width — ordinary
  /// prose — reports different heights at the two widths (measured 264pt vs 352pt), so the
  /// table's equality above is not something every row would satisfy.
  @MainActor
  func testHarnessDetectsWidthDependentRows() throws {
    let prose = try rowHeights(for: Self.proseMarkdown)
    XCTAssertNotEqual(
      prose.narrow, prose.wide, accuracy: 10,
      "A prose row re-wraps, so this harness can tell width-dependent rows apart"
    )
  }

  // MARK: - Cell capping

  /// The whole point of ``CappedWidthLayout``: handed an effectively unbounded proposal
  /// (what a horizontal `ScrollView` gives its content), a long cell reports a *wrapped*
  /// size — capped in width, multi-line in height — rather than a full-width single line
  /// that the frame would then merely clip.
  func testLongCellWrapsAtColumnCapRatherThanReportingOneLongLine() {
    let capped = hostedSize(
      of: CappedWidthLayout(maxWidth: MarkdownTableView.columnMaxWidth) { Text(Self.longSentence) },
      width: .greatestFiniteMagnitude
    )
    let uncapped = hostedSize(of: Text(Self.longSentence), width: .greatestFiniteMagnitude)

    XCTAssertLessThanOrEqual(capped.width, MarkdownTableView.columnMaxWidth + 1)
    XCTAssertGreaterThan(
      uncapped.width, MarkdownTableView.columnMaxWidth,
      "Fixture sanity: the sample must genuinely exceed the cap when unconstrained"
    )
    XCTAssertGreaterThan(
      capped.height, uncapped.height * 1.5,
      "Capping must make the text wrap onto more lines, not truncate it to one"
    )
  }

  /// The other half of the contract: a short cell keeps its *natural* width, which is what
  /// lets a small table stay inline and pan-free instead of every column claiming the cap.
  func testShortCellKeepsNaturalWidth() {
    let capped = hostedSize(
      of: CappedWidthLayout(maxWidth: MarkdownTableView.columnMaxWidth) { Text("yes") },
      width: .greatestFiniteMagnitude
    )
    XCTAssertLessThan(capped.width, 80)
  }

  /// `CappedWidthLayout` reports a size derived only from its content, never from the
  /// proposal. That is what keeps the hosting cell's height stable, and it is why a `.zero`
  /// probe cannot extract the dishonest "0pt wide and 1780pt tall" answer `Text` gives to a
  /// zero-width proposal (measured).
  func testCappedLayoutReportsTheSameSizeForEveryProposal() {
    let host = UIHostingController(rootView: CappedWidthLayout(maxWidth: MarkdownTableView.columnMaxWidth) {
      Text(Self.longSentence)
    })
    let unbounded = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    let zero = host.sizeThatFits(in: .zero)
    let tiny = host.sizeThatFits(in: CGSize(width: 40, height: CGFloat.greatestFiniteMagnitude))

    XCTAssertEqual(zero.width, unbounded.width, accuracy: 1)
    XCTAssertEqual(zero.height, unbounded.height, accuracy: 1)
    XCTAssertEqual(tiny.width, unbounded.width, accuracy: 1)
    XCTAssertEqual(tiny.height, unbounded.height, accuracy: 1)
    XCTAssertGreaterThan(unbounded.width, 200, "Sanity: the sample wraps at the cap, not below it")
  }

  // MARK: - Dynamic Type

  /// The cap is a *readable measure* (~35–40 characters), so it has to scale with the text it
  /// measures — but only up to ``MarkdownTableView/columnMaxWidthCeiling``, whose doc comment
  /// records the measured scale and why an unclamped one has to be panned to read a line of
  /// prose (see also `testSingleColumnTableNeverPansAtAccessibilitySizes`).
  func testColumnCapGrowsWithDynamicTypeButNeverPastTheCeiling() throws {
    let standard = try scrollView(for: singleColumnTable(long: true))
    let ax1 = try scrollView(for: singleColumnTable(long: true), dynamicType: .accessibility1)
    let ax5 = try scrollView(for: singleColumnTable(long: true), dynamicType: .accessibility5)

    XCTAssertLessThanOrEqual(standard.contentSize.width, MarkdownTableView.columnMaxWidth + 1)
    XCTAssertGreaterThan(
      ax1.contentSize.width, standard.contentSize.width + 10,
      "At an accessibility size the column must widen with the glyphs, not stay at the base cap"
    )
    for (name, scroll) in [("accessibility1", ax1), ("accessibility5", ax5)] {
      XCTAssertLessThanOrEqual(
        scroll.contentSize.width, MarkdownTableView.columnMaxWidthCeiling + 1,
        "\(name): the scaled cap must never exceed the narrowest usable transcript width"
      )
    }
  }

  /// The regression the ceiling exists to prevent: a single-column table cannot overflow by
  /// construction, so it must never demand horizontal panning — at *any* text size, on the
  /// **narrowest** layout the ceiling claims to cover.
  ///
  /// Measuring only at 358pt (a 390pt device) is what let a 343pt ceiling through once, so
  /// every text size is measured at *both* widths here. The lower bound is the other half of
  /// the contract: the long cell must fill out towards the cap rather than collapse.
  func testSingleColumnTableNeverPansAtAccessibilitySizes() throws {
    let widths = [Self.narrowestTranscriptWidth, Self.usableTranscriptWidth]
    let sizes: [DynamicTypeSize] = [.large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
    for width in widths {
      for size in sizes {
        let scroll = try scrollView(
          for: singleColumnTable(long: true), width: width, dynamicType: size
        )
        XCTAssertLessThanOrEqual(
          scroll.contentSize.width, scroll.bounds.width + 1,
          "\(size) at \(width)pt: a one-column table must fit the transcript, not force the user to pan to read a line"
        )
        XCTAssertGreaterThan(
          scroll.contentSize.width, 200,
          "\(size) at \(width)pt: the long cell must fill out towards the cap, not collapse"
        )
      }
    }
  }

  // MARK: - Degenerate tables

  /// `MarkdownSegment` legitimately emits a table with headers and zero body rows
  /// (`MarkdownSegmentTests.tableWithNoBodyRows`), so the renderer must survive it.
  func testHeaderOnlyTableStillRenders() throws {
    let scroll = try scrollView(for: MarkdownTableView(headers: ["h1", "h2"], rows: []))
    XCTAssertGreaterThan(scroll.contentSize.width, 0)
    XCTAssertGreaterThan(scroll.contentSize.height, 0)
  }

  /// `| A | | C |` parses to an all-empty middle column. An empty cell measures 0pt wide, but
  /// the `Grid`'s own `columnSpacing` still sits on both sides of it, so the neighbours stay
  /// visibly separated instead of merging into one column.
  func testAllEmptyColumnKeepsItsSlot() throws {
    let withEmpty = try scrollView(for: MarkdownTableView(headers: ["A", "", "C"], rows: [["1", "", "3"]]))
    let withoutEmpty = try scrollView(for: MarkdownTableView(headers: ["A", "C"], rows: [["1", "3"]]))
    XCTAssertEqual(
      withEmpty.contentSize.width - withoutEmpty.contentSize.width,
      MarkdownTableView.columnSpacing, accuracy: 1,
      "The empty column contributes no width of its own but keeps its grid gap"
    )
  }

  // MARK: - Trailing-fade rule

  /// Pure rule behind the "there is more table past the trailing edge" fade. The view's own
  /// flag is private `@State`, so the decision lives in a testable static.
  func testTrailingOverflowRule() {
    // Content wider than the viewport, parked at the leading edge.
    XCTAssertTrue(overflow(visibleFrom: 0, width: 390, contentWidth: 520))
    // Panned to the very end — nothing left to reveal, so no fade.
    XCTAssertFalse(overflow(visibleFrom: 130, width: 390, contentWidth: 520))
    // Mid-pan.
    XCTAssertTrue(overflow(visibleFrom: 60, width: 390, contentWidth: 520))
    // A table that fits never fades.
    XCTAssertFalse(overflow(visibleFrom: 0, width: 390, contentWidth: 86))
    // Fractional layout slack must not switch it on.
    XCTAssertFalse(overflow(visibleFrom: 0, width: 390, contentWidth: 390.4))
    // Overscrolled past the trailing edge (rubber-band): still nothing left to reveal.
    XCTAssertFalse(overflow(visibleFrom: -52, width: 390, contentWidth: 330))
  }

  /// The same six cases mirrored. Under `.rightToLeft` the logical trailing edge is at **x = 0**
  /// (SwiftUI mirrors the scroll view — see `testRightToLeftTableFadesAtItsLogicalTrailingEdge`
  /// for the measurement), so a rule written as "trailing means larger x" answers every one of
  /// them backwards.
  func testTrailingOverflowRuleMirrorsUnderRightToLeft() {
    // Opens parked at the logical leading edge, which in RTL is the *right*: everything still
    // to reveal sits to the left.
    XCTAssertTrue(overflow(visibleFrom: 130, width: 390, contentWidth: 520, .rightToLeft))
    // Panned to the logical end — the physical left.
    XCTAssertFalse(overflow(visibleFrom: 0, width: 390, contentWidth: 520, .rightToLeft))
    // Mid-pan.
    XCTAssertTrue(overflow(visibleFrom: 60, width: 390, contentWidth: 520, .rightToLeft))
    // A table that fits never fades.
    XCTAssertFalse(overflow(visibleFrom: 0, width: 390, contentWidth: 86, .rightToLeft))
    // Fractional layout slack must not switch it on.
    XCTAssertFalse(overflow(visibleFrom: 0.4, width: 390, contentWidth: 390.4, .rightToLeft))
    // Overscrolled past the logical trailing edge (rubber-band).
    XCTAssertFalse(overflow(visibleFrom: -20, width: 390, contentWidth: 330, .rightToLeft))
  }

  /// The measurement the rule above is derived from, taken off a real mirrored `UIScrollView`:
  /// SwiftUI lays a horizontal `ScrollView` out right-to-left, so the table **opens** already
  /// scrolled to `contentSize − bounds` with its hidden columns to the left. The pre-fix rule
  /// (`visibleRect.maxX < contentWidth − 1`) is exactly inverted here: no fade while the table
  /// is untouched, a fade once there is nothing left to reveal.
  @MainActor
  func testRightToLeftTableFadesAtItsLogicalTrailingEdge() throws {
    let scroll = try scrollView(for: wideTable, layoutDirection: .rightToLeft)
    let end = scroll.contentSize.width - scroll.bounds.width
    XCTAssertGreaterThan(end, 20, "Fixture sanity: the table must genuinely overflow the viewport")
    XCTAssertEqual(
      scroll.contentOffset.x, end, accuracy: 1,
      "SwiftUI mirrors a horizontal ScrollView in RTL: it must open at the logical leading edge, i.e. the right"
    )
    XCTAssertTrue(
      Self.rule(for: scroll, .rightToLeft),
      "Untouched RTL table: every hidden column is to the left, so the trailing fade must be on"
    )

    scroll.setContentOffset(.zero, animated: false)
    XCTAssertFalse(
      Self.rule(for: scroll, .rightToLeft),
      "Panned to the logical end there is nothing left to reveal, so the fade must be off"
    )

    // The LTR half of the same fixture, to prove the mirroring is what differs and not the table.
    let ltr = try scrollView(for: wideTable, layoutDirection: .leftToRight)
    XCTAssertEqual(ltr.contentOffset.x, 0, accuracy: 1)
    XCTAssertTrue(Self.rule(for: ltr, .leftToRight))
  }

  /// The `.mask` half. Only the `HStack` mirrors on its own; `LinearGradient`'s `.leading` /
  /// `.trailing` unit points do not, so without the explicit reversal the RTL ramp ran opaque at
  /// the table's edge and transparent 24pt inside it — a hard cut plus a see-through band across
  /// the columns. Asserted on alpha sampled from the rendered mask, in both directions.
  @MainActor
  func testFadeMaskSitsAtTheLogicalTrailingEdge() throws {
    // x = 1 is the outermost pixel of the fade in RTL; x = 98 is its counterpart in LTR.
    for (direction, fadeEdge, oppositeEdge) in [
      (LayoutDirection.leftToRight, 98, 1), (.rightToLeft, 1, 98),
    ] {
      let faded = try Self.maskAlphas(isFaded: true, direction: direction)
      XCTAssertLessThan(
        faded[fadeEdge], 40,
        "\(direction): the mask must be nearly transparent at the logical TRAILING edge"
      )
      XCTAssertGreaterThan(
        faded[oppositeEdge], 240,
        "\(direction): the logical LEADING edge must stay opaque — a fade there is the un-mirrored gradient"
      )
      XCTAssertGreaterThan(faded[50], 240, "\(direction): the middle of the table is never faded")

      // Nothing to reveal ⇒ the mask is a no-op everywhere, in both directions.
      let plain = try Self.maskAlphas(isFaded: false, direction: direction)
      for x in [1, 12, 50, 88, 98] {
        XCTAssertGreaterThan(plain[x], 240, "\(direction): an unfaded mask must be opaque at x=\(x)")
      }
    }
  }

  private func overflow(
    visibleFrom minX: CGFloat,
    width: CGFloat,
    contentWidth: CGFloat,
    _ layoutDirection: LayoutDirection = .leftToRight
  ) -> Bool {
    MarkdownTableView.hasTrailingOverflow(
      visibleRect: CGRect(x: minX, y: 0, width: width, height: 100),
      contentWidth: contentWidth,
      layoutDirection: layoutDirection
    )
  }

  /// The production rule asked about a live scroll view.
  private static func rule(for scroll: UIScrollView, _ direction: LayoutDirection) -> Bool {
    MarkdownTableView.hasTrailingOverflow(
      visibleRect: scroll.bounds, contentWidth: scroll.contentSize.width, layoutDirection: direction
    )
  }

  /// Alpha (0–255) per x of the fade mask, rendered 100×20 at scale 1 over an opaque fill.
  @MainActor
  private static func maskAlphas(isFaded: Bool, direction: LayoutDirection) throws -> [Int] {
    let renderer = ImageRenderer(
      content: Color.black
        .frame(width: 100, height: 20)
        .mask { MarkdownTableView.trailingFadeMask(isFaded: isFaded, layoutDirection: direction) }
        .environment(\.layoutDirection, direction)
    )
    renderer.scale = 1
    let image = try XCTUnwrap(renderer.uiImage, "the mask must render")
    let cg = try XCTUnwrap(image.cgImage)
    var pixels = [UInt8](repeating: 0, count: cg.width * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: cg.width, height: 1, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    // Draw the image shifted up so the sampled row is the vertical middle of the mask.
    context.translateBy(x: 0, y: CGFloat(-cg.height / 2))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return (0..<cg.width).map { Int(pixels[$0 * 4 + 3]) }
  }

  // MARK: - Fixtures

  private static let longSentence =
    "Identifies the live runtime session. It rides on the event frame, never inside the message body."

  /// The issue's repro shape: four columns, one holding multi-sentence prose.
  private var wideTable: MarkdownTableView {
    MarkdownTableView(
      headers: ["Field", "Type", "Required", "Notes"],
      rows: [
        ["`session_id`", "string", "yes", Self.longSentence],
        ["`reasoning`", "string", "no",
         "Present only when the selected model advertises reasoning support in `model.options`."],
        ["`usage`", "object", "no", "Token counts for the turn."],
      ]
    )
  }

  /// The same shape with nothing that needs wrapping — the control for the cap tests.
  private var wideTableShortCells: MarkdownTableView {
    MarkdownTableView(
      headers: ["Field", "Type", "Required", "Notes"],
      rows: [
        ["`session_id`", "string", "yes", "Short."],
        ["`reasoning`", "string", "no", "Short."],
        ["`usage`", "object", "no", "Short."],
      ]
    )
  }

  /// The same shape as ``wideTable``, as the pipe Markdown an assistant message carries —
  /// so the hosting-path test goes through `MessageBubbleView` → `MarkdownText` → the
  /// `.table` segment, not straight at `MarkdownTableView`.
  private static let wideTableMarkdown = """
    | Field | Type | Required | Notes |
    | --- | --- | --- | --- |
    | `session_id` | string | yes | \(longSentence) |
    | `reasoning` | string | no | Present only when the selected model advertises reasoning support in `model.options`. |
    | `usage` | object | no | Token counts for the turn. |
    """

  /// A second wide table for the recycling test: different words, same overflowing shape, so a
  /// carried-over pan offset would be plainly visible rather than clamped away.
  private static let otherWideTableMarkdown = """
    | Column | Kind | Optional | Description |
    | --- | --- | --- | --- |
    | `queue_depth` | integer | yes | Counts the prompts waiting behind the running turn, refreshed on every status update. |
    | `worker` | string | no | Names the subprocess the gateway routed this slash command to. |
    | `elapsed` | number | no | Seconds since the turn started. |
    """

  /// The control for the collection-view harness: ordinary prose, which genuinely re-wraps
  /// at every offered width, so a harness that cannot tell widths apart fails on it.
  private static let proseMarkdown = String(
    repeating: "The quick brown fox jumps over the lazy dog. ", count: 12
  )

  private func singleColumnTable(long: Bool) -> MarkdownTableView {
    MarkdownTableView(headers: ["Note"], rows: [[long ? Self.longSentence : "Short."], ["Short."]])
  }

  // MARK: - Helpers

  /// Hosts `view` in a real window at `width`, forces a layout pass, and hands back the
  /// `UIScrollView` the table renders into.
  private func scrollView(
    for view: some View,
    width: CGFloat? = nil,
    dynamicType: DynamicTypeSize = .large,
    layoutDirection: LayoutDirection = .leftToRight,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UIScrollView {
    let width = width ?? Self.viewportWidth
    let host = UIHostingController(
      rootView: view.dynamicTypeSize(dynamicType).environment(\.layoutDirection, layoutDirection)
    )
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1400))
    window.rootViewController = host
    window.isHidden = false
    windows.append(window)
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    return try XCTUnwrap(
      Self.firstScrollView(in: host.view),
      "MarkdownTableView must host a horizontal UIScrollView", file: file, line: line
    )
  }

  /// The height a self-sizing host (the transcript's `UIHostingConfiguration` cell) would
  /// measure for this table at a given offered width.
  private func hostedSize(of view: some View, width: CGFloat) -> CGSize {
    UIHostingController(rootView: view.dynamicTypeSize(.large))
      .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
  }

  /// Lays one assistant message row out in the real transcript collection view at the device
  /// width (a 358pt row), then at the narrowest layout (a 288pt row), then reconfigures the
  /// item back at the device width — the three passes a self-sizing `.estimated(60)` cell
  /// really goes through — and hands back the frame height the layout produced each time.
  @MainActor
  private func rowHeights(for markdown: String) throws -> (wide: CGFloat, narrow: CGFloat, reconfigured: CGFloat) {
    let harness = TranscriptCellHarness(markdown: markdown, width: Self.viewportWidth)
    harnesses.append(harness)
    windows.append(harness.window)
    let wide = try XCTUnwrap(
      harness.rowHeight(atCollectionWidth: Self.viewportWidth), "The row must be laid out"
    )
    let narrow = try XCTUnwrap(harness.rowHeight(atCollectionWidth: Self.narrowestCollectionWidth))
    harness.reconfigureRow()
    let reconfigured = try XCTUnwrap(harness.rowHeight(atCollectionWidth: Self.viewportWidth))
    return (wide, narrow, reconfigured)
  }

  private static func firstScrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    for sub in view.subviews {
      if let found = firstScrollView(in: sub) { return found }
    }
    return nil
  }
}

/// One assistant message row in a stand-in for the transcript: the **production**
/// `TranscriptLayout.makeLayout()` (`.estimated(60)` self-sizing items, the section's
/// own horizontal insets) driving the production `TranscriptLayout.cellConfiguration` (the
/// #191 sizing guard over a margin-less `UIHostingConfiguration`), in a real window.
///
/// The layout and the cell configuration are the real ones rather than hand-copied recipes so the harness cannot drift
/// from the transcript it stands in for. Only the *hosting* is a stand-in: the real
/// `CollectionTranscriptView` needs a `ChatFeature` store and a `ChatRow`, neither of which
/// affects the measurement under test (cell height for hosted SwiftUI content at a width).
@MainActor
private final class TranscriptCellHarness {
  /// Tall enough that the single row is never height-constrained.
  private static let hostHeight: CGFloat = 900

  /// Handed to the test so its `tearDown` hides it with the others.
  let window: UIWindow
  private let collectionView: UICollectionView
  private let dataSource: UICollectionViewDiffableDataSource<Int, Int>

  convenience init(markdown: String, width: CGFloat) {
    self.init(markdowns: [markdown], width: width)
  }

  /// `markdowns` is indexed by item id; the first one is shown initially and ``showRow(_:)``
  /// swaps in another.
  init(markdowns: [String], width: CGFloat) {
    let bounds = CGRect(x: 0, y: 0, width: width, height: Self.hostHeight)
    collectionView = UICollectionView(
      frame: bounds, collectionViewLayout: TranscriptLayout.makeLayout()
    )
    let registration = UICollectionView.CellRegistration<UICollectionViewCell, Int> { cell, _, id in
      cell.contentConfiguration = TranscriptLayout.cellConfiguration {
        MessageBubbleView(role: .assistant, text: markdowns[id], isComplete: true)
          .dynamicTypeSize(.large)
      }
      cell.backgroundConfiguration = .clear()
    }
    dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) { view, indexPath, id in
      view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
    }
    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0])
    dataSource.apply(snapshot, animatingDifferences: false)

    let controller = UIViewController()
    controller.view.addSubview(collectionView)
    window = UIWindow(frame: bounds)
    window.rootViewController = controller
    window.isHidden = false
  }

  /// Resize the collection view, let the self-sizing layout settle, and read the row's frame.
  func rowHeight(atCollectionWidth width: CGFloat) -> CGFloat? {
    let bounds = CGRect(x: 0, y: 0, width: width, height: Self.hostHeight)
    window.frame = bounds
    window.rootViewController?.view.frame = bounds
    collectionView.frame = bounds
    collectionView.collectionViewLayout.invalidateLayout()
    // Two passes: the first invalidates the estimate, the second lays out at the real height.
    collectionView.layoutIfNeeded()
    collectionView.layoutIfNeeded()
    return collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.height
  }

  /// The transcript's in-place update path: same identity, content re-applied to the cell.
  func reconfigureRow() {
    var snapshot = dataSource.snapshot()
    snapshot.reconfigureItems([0])
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  /// Replace the displayed row with a *different* item id — the wholesale-hydrate shape, and
  /// the deterministic way to make UIKit hand the outgoing cell straight back for the new row.
  func showRow(_ id: Int) {
    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([id])
    dataSource.apply(snapshot, animatingDifferences: false)
    collectionView.layoutIfNeeded()
    collectionView.layoutIfNeeded()
  }

  /// The single laid-out row's cell, and the table's horizontal scroll view inside it.
  var visibleCell: UICollectionViewCell? {
    collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
  }

  var tableScrollView: UIScrollView? {
    visibleCell.flatMap(Self.firstScrollView(in:))
  }

  private static func firstScrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView, !(scroll is UICollectionView) { return scroll }
    for sub in view.subviews {
      if let found = firstScrollView(in: sub) { return found }
    }
    return nil
  }
}


