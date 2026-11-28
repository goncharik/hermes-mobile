import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured checks for the transcript cell sizing guard (#191).
///
/// The crash: UIKit's `_UIContentViewAssertValidFittingSize` aborts when a self-sizing cell's
/// content answers a fitting size that is non-finite, negative or too tall — measured on iOS
/// 27.2, a 2.5M pt height passes and a 3M pt height asserts. Prose answers a degenerate width
/// with an absurd height (one glyph per line), so a long reply laid out in a collection view a
/// few points wide crashed through a plain `layoutSubviews` — the #128 apply gate allows a 33pt
/// view (it leaves a 1pt row) and gates no layout pass at all.
///
/// **Red-checked**: ``testALongReplyInADegenerateRowLaysOutWithoutAsserting`` with the bare
/// `UIHostingConfiguration { … }.margins(.all, 0)` cell (the pre-#191 registration) fails with
/// "Content view returned an invalid size {1, 3168000}" raised from
/// `_UIContentViewAssertValidFittingSize`, reached through `-[UICollectionView layoutSubviews]` —
/// the build 96 trace.
@MainActor
final class TranscriptCellSizingLayoutTests: XCTestCase {
  /// A reply long enough to cross the assert at a 1pt row (3.17M pt measured unguarded), and
  /// still an ordinary ~100k pt row at the narrowest real width.
  private static let longReply = String(
    repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing. ", count: 3200
  )

  private var windows: [UIWindow] = []
  private var harnesses: [CellHarness] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    harnesses = []
    super.tearDown()
  }

  // MARK: - The crash

  /// The reproduction: a long reply in the production layout and cell configuration, in a
  /// collection view so narrow its row is 1pt (and narrower still). It lays out without the
  /// assert, and the row is finite and capped — measured at the narrowest real row.
  func testALongReplyInADegenerateRowLaysOutWithoutAsserting() throws {
    let harness = harness(text: Self.longReply, width: TranscriptLayout.narrowestLayoutWidth)
    let narrowest = try XCTUnwrap(harness.rowHeight(atCollectionWidth: TranscriptLayout.narrowestLayoutWidth))
    for width: CGFloat in [33, 40, 100, 33] {
      let height = try XCTUnwrap(harness.rowHeight(atCollectionWidth: width), "width \(width)")
      XCTAssertTrue(height.isFinite && height > 0, "width \(width): \(height)")
      XCTAssertLessThanOrEqual(height, TranscriptCellSizing.maximumCellHeight, "width \(width)")
      XCTAssertEqual(
        height, narrowest, accuracy: 1,
        "A degenerate row measures as the narrowest real row (width \(width))"
      )
    }
  }

  /// The guard is size-neutral wherever a row is real: at the narrowest layout, a phone and a
  /// landscape width, the guarded row is exactly as tall as the bare hosted content.
  func testRealRowsMeasureExactlyAsTheBareContent() throws {
    let text = "A reply with **bold**, `code` and a list:\n\n- one\n- two\n\n" + String(
      repeating: "Some ordinary prose that wraps across several lines. ", count: 12
    )
    let guarded = harness(text: text, width: 390)
    let bare = harness(text: text, width: 390, guarded: false)
    for width: CGFloat in [TranscriptLayout.narrowestLayoutWidth, 375, 390, 693] {
      let expected = try XCTUnwrap(bare.rowHeight(atCollectionWidth: width))
      let actual = try XCTUnwrap(guarded.rowHeight(atCollectionWidth: width))
      XCTAssertEqual(actual, expected, accuracy: 0.5, "width \(width)")
    }
  }

  // MARK: - Every proposal answers a finite size

  /// The cell root answers every proposal SwiftUI or UIKit can make — unspecified, zero,
  /// infinite, negative, a glyph's width — with a finite, non-negative, capped size, for the
  /// item kinds with the most text.
  func testTheCellRootAnswersEveryProposalFinitely() {
    let contents: [(String, AnyView)] = [
      ("assistant", AnyView(MessageBubbleView(role: .assistant, text: Self.longReply, isComplete: true))),
      ("user", AnyView(MessageBubbleView(role: .user, text: Self.longReply, isComplete: true))),
      ("code", AnyView(MarkdownText(text: "```\n\(Self.longReply)\n```"))),
    ]
    for (name, content) in contents {
      for proposal in Self.proposals {
        let size = measure(TranscriptCellLayout { content }, proposal)
        assertFinite(size, "\(name) at \(proposal)")
        if let size {
          XCTAssertLessThanOrEqual(size.height, TranscriptCellSizing.maximumCellHeight, "\(name) at \(proposal)")
        }
      }
    }
  }

  /// `SelectableText` (every assistant prose block) on its own: an unspecified or infinite width
  /// answers the text's natural size — not `0`, and not an infinite width — and a negative width
  /// answers `0` wide. A real width is taken whole.
  func testSelectableTextAnswersEveryProposalFinitely() throws {
    let view = SelectableText(attributed: ProseAttributedBuilder.make("A short line of prose"))
    for proposal in Self.proposals {
      assertFinite(measure(view, proposal), "\(proposal)")
    }
    let ideal = try XCTUnwrap(measure(view, .unspecified))
    XCTAssertGreaterThan(ideal.width, 0, "An ideal-size probe answers the natural width")
    let infinite = try XCTUnwrap(measure(view, .infinity))
    XCTAssertEqual(infinite.width, ideal.width, accuracy: 0.5, "An infinite probe answers the natural width")
    XCTAssertEqual(infinite.height, ideal.height, accuracy: 0.5)
    let negative = try XCTUnwrap(measure(view, ProposedViewSize(width: -10, height: nil)))
    XCTAssertEqual(negative.width, 0)
    let real = try XCTUnwrap(measure(view, ProposedViewSize(width: 288, height: nil)))
    XCTAssertEqual(real.width, 288)
  }

  // MARK: - Helpers

  private static let proposals: [ProposedViewSize] = [
    .unspecified, .zero, .infinity,
    ProposedViewSize(width: .infinity, height: nil),
    ProposedViewSize(width: 288, height: .infinity),
    ProposedViewSize(width: 288, height: 0),
    ProposedViewSize(width: 1, height: nil),
    ProposedViewSize(width: -10, height: nil),
  ]

  private func assertFinite(_ size: CGSize?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let size else { return XCTFail("No measurement: \(message)", file: file, line: line) }
    XCTAssertTrue(
      size.width.isFinite && size.height.isFinite && size.width >= 0 && size.height >= 0,
      "\(message) answered \(size)", file: file, line: line
    )
  }

  private func harness(text: String, width: CGFloat, guarded: Bool = true) -> CellHarness {
    let harness = CellHarness(text: text, width: width, guarded: guarded)
    harnesses.append(harness)
    windows.append(harness.window)
    return harness
  }

  /// What `content` answers for `proposal`, read through a probing parent `Layout` in a real
  /// window (a `UIViewRepresentable` only measures once it is hosted).
  private func measure(_ content: some View, _ proposal: ProposedViewSize) -> CGSize? {
    let box = ProbeResult()
    let host = UIHostingController(
      rootView: ProbingLayout(proposal: proposal, result: box) { content }.dynamicTypeSize(.large)
    )
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
    window.rootViewController = host
    window.isHidden = false
    windows.append(window)
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    return box.size
  }
}

private final class ProbeResult { var size: CGSize? }

/// Proposes a fixed `proposal` to its child and records the answer; sizes itself to a constant
/// so the probe never depends on what it measured.
private struct ProbingLayout: Layout {
  let proposal: ProposedViewSize
  let result: ProbeResult

  func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    result.size = subviews.first?.sizeThatFits(proposal)
    return CGSize(width: 100, height: 100)
  }

  func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: 100, height: 100))
  }
}

/// One assistant reply in the production `TranscriptLayout.makeLayout()`, configured through
/// the production `TranscriptLayout.cellConfiguration` (or, for the size-neutrality control,
/// the bare hosting configuration it wraps), in a real window.
@MainActor
private final class CellHarness {
  private static let hostHeight: CGFloat = 900

  let window: UIWindow
  private let collectionView: UICollectionView
  private let dataSource: UICollectionViewDiffableDataSource<Int, Int>

  init(text: String, width: CGFloat, guarded: Bool) {
    let bounds = CGRect(x: 0, y: 0, width: width, height: Self.hostHeight)
    collectionView = UICollectionView(frame: bounds, collectionViewLayout: TranscriptLayout.makeLayout())
    let registration = UICollectionView.CellRegistration<UICollectionViewCell, Int> { cell, _, _ in
      let content = MessageBubbleView(role: .assistant, text: text, isComplete: true)
        .dynamicTypeSize(.large)
      if guarded {
        cell.contentConfiguration = TranscriptLayout.cellConfiguration { content }
      } else {
        cell.contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0)
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

  /// Resize the collection view, let the self-sizing layout settle, and read the row's height.
  func rowHeight(atCollectionWidth width: CGFloat) -> CGFloat? {
    let bounds = CGRect(x: 0, y: 0, width: width, height: Self.hostHeight)
    window.frame = bounds
    window.rootViewController?.view.frame = bounds
    collectionView.frame = bounds
    collectionView.collectionViewLayout.invalidateLayout()
    collectionView.layoutIfNeeded()
    collectionView.layoutIfNeeded()
    return collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.height
  }
}
