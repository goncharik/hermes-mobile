import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured (not eyeballed) acceptance checks for the chat column's readable-width cap (#80).
///
/// The cap is `ChatLayout.readableMaxWidth` applied to `ChatView`'s OUTER container and centered
/// by a greedy frame around it. A snapshot cannot prove the two halves that matter — that the
/// column is *exactly* the constant wide (not "narrower than the window"), and that it is
/// centered rather than pinned to the leading edge — and every snapshot suite renders at phone
/// widths, which are below the cap. So these tests host the real `ChatView` in a window the size
/// of an iPad detail pane, force a layout pass, and read the geometry straight off the UIKit
/// views SwiftUI lays out inside it: the transcript's `UICollectionView` (greedy, so it is the
/// container's width) and the composer's `UITextView`.
///
/// The other half of the contract is what the cap must **not** do: a phone-width window is never
/// narrowed below the window, and a table inside the capped column still pans — the cap is on the
/// outer container, never on the table's cells (`MarkdownTableLayoutTests` owns the cell rule).
///
/// Dynamic Type is pinned to `.large`: the cap is a constant, but the transcript rows and the
/// composer around it scale, and a measurement should not follow the simulator's text size.
///
/// **Red-checked** against `ChatView` without the two frames: in the 1024pt window the column
/// measured 1024pt wide at x = 0, the composer spanned 28…996pt, and the table's viewport was
/// 992pt — every wide-window assertion below went red; only the phone-window test (the "no cap
/// below the constant" half) passes both ways, which is its contract.
final class ChatColumnLayoutTests: XCTestCase {
  /// An iPad detail pane in landscape — comfortably wider than the cap.
  private static let wideWindow = CGSize(width: 1024, height: 768)

  /// iPhone 13 Pro width — the same viewport the snapshot suite pins.
  private static let phoneWindow = CGSize(width: 390, height: 700)

  /// Kept alive for the duration of a test: a hosted view only lays out for real while its
  /// window exists, and SwiftUI won't materialise the collection view otherwise.
  private var windows: [UIWindow] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    super.tearDown()
  }

  // MARK: - The cap (wide windows)

  /// In a wide window the chat column is exactly `readableMaxWidth` wide and sits in the middle
  /// of the window — equal margins either side. Asserted on the transcript (the container's own
  /// width, being greedy) and on the composer (which must be under the transcript, not under the
  /// window's edge: a cap without the centering frame pins the column to the leading edge).
  @MainActor
  func testWideWindowCapsTheColumnAtReadableWidthAndCentersIt() throws {
    let chat = try hostedChat(window: Self.wideWindow)
    let cap = ChatLayout.readableMaxWidth
    XCTAssertLessThan(cap, Self.wideWindow.width, "Fixture sanity: the window must be wider than the cap")

    let transcript = chat.transcript.convert(chat.transcript.bounds, to: nil)
    XCTAssertEqual(
      transcript.width, cap, accuracy: 1,
      "The chat column must be exactly the readable width — not the window, not something narrower"
    )
    let expectedMargin = (Self.wideWindow.width - cap) / 2
    XCTAssertEqual(
      transcript.minX, expectedMargin, accuracy: 1,
      "The column must be centered: equal margins either side, not pinned to the leading edge"
    )
    XCTAssertEqual(transcript.maxX, Self.wideWindow.width - expectedMargin, accuracy: 1)

    let composer = chat.composer.convert(chat.composer.bounds, to: nil)
    XCTAssertEqual(
      composer.midX, Self.wideWindow.width / 2, accuracy: 1,
      "The composer must be centered under the transcript it belongs to"
    )
    XCTAssertLessThanOrEqual(
      composer.width, cap, "The composer must live inside the capped column, not span the window"
    )
    XCTAssertGreaterThanOrEqual(
      composer.minX, expectedMargin - 1, "…and it must not leak past the column's leading edge"
    )
    XCTAssertLessThanOrEqual(
      composer.maxX, Self.wideWindow.width - expectedMargin + 1,
      "…nor past its trailing edge"
    )
  }

  /// The cap is a boundary, so it is asserted from both sides: a window exactly the cap's width
  /// is filled edge to edge, and a window one point wider gives up exactly that point (half a
  /// point each side).
  @MainActor
  func testTheCapBoundaryFromBothSides() throws {
    let cap = ChatLayout.readableMaxWidth

    let atCap = try hostedChat(window: CGSize(width: cap, height: 700))
    XCTAssertEqual(atCap.transcript.bounds.width, cap, accuracy: 1, "At the cap the column fills the window")
    XCTAssertEqual(atCap.transcript.convert(atCap.transcript.bounds, to: nil).minX, 0, accuracy: 1)

    let overCap = try hostedChat(window: CGSize(width: cap + 40, height: 700))
    XCTAssertEqual(
      overCap.transcript.bounds.width, cap, accuracy: 1,
      "Past the cap the column must stop growing at exactly the cap"
    )
    XCTAssertEqual(
      overCap.transcript.convert(overCap.transcript.bounds, to: nil).minX, 20, accuracy: 1,
      "…and the slack is split evenly"
    )
  }

  // MARK: - No cap below the constant (phone widths)

  /// The rule that keeps compact rendering byte-identical: below the cap the column IS the
  /// window. A `.frame(maxWidth:)` on the outer container must not narrow a phone.
  @MainActor
  func testPhoneWindowIsNeverNarrowedBelowTheWindow() throws {
    let chat = try hostedChat(window: Self.phoneWindow)

    let transcript = chat.transcript.convert(chat.transcript.bounds, to: nil)
    XCTAssertEqual(
      transcript.width, Self.phoneWindow.width, accuracy: 1,
      "Below the cap the chat column must equal the window width"
    )
    XCTAssertEqual(transcript.minX, 0, accuracy: 1, "…flush with the window's leading edge")

    let composer = chat.composer.convert(chat.composer.bounds, to: nil)
    XCTAssertEqual(composer.midX, Self.phoneWindow.width / 2, accuracy: 1)
  }

  // MARK: - The cap is on the OUTER container (tables still pan inside it)

  /// A table wider than the capped column must pan inside it, exactly as it does on a phone:
  /// `MarkdownTableView`'s horizontal `UIScrollView` is laid out within the column (never
  /// spilling into the window's margins) with pannable content past its trailing edge. This is
  /// what "the cap is on the outer container, not on the cells" means when measured — a cap that
  /// reached the cells would either clip the columns away or stretch them to the window.
  @MainActor
  func testATableInsideTheCappedColumnStillPans() throws {
    let chat = try hostedChat(window: Self.wideWindow, markdown: Self.veryWideTableMarkdown)
    let table = try XCTUnwrap(
      chat.plainScrollViews.first, "the table's horizontal scroll view must be hosted in a transcript row"
    )
    let cap = ChatLayout.readableMaxWidth
    let margin = (Self.wideWindow.width - cap) / 2

    let frame = table.convert(table.bounds, to: nil)
    XCTAssertGreaterThanOrEqual(frame.minX, margin - 1, "The table must be laid out inside the column")
    XCTAssertLessThanOrEqual(frame.maxX, Self.wideWindow.width - margin + 1, "…not into the window's margin")
    XCTAssertLessThanOrEqual(
      table.bounds.width, cap - 2 * TranscriptLayout.horizontalSectionInset + 1,
      "The table's viewport is a transcript row inside the capped column"
    )
    XCTAssertGreaterThan(
      table.contentSize.width, table.bounds.width + 20,
      "A table wider than the column must have pannable content, not clipped-away columns"
    )
  }

  // MARK: - Fixtures

  /// Five columns of prose: each cell wraps at `MarkdownTableView.columnMaxWidth` (260pt), so the
  /// grid is ~1300pt wide — far past the 728pt row a capped column offers.
  private static let veryWideTableMarkdown: String = {
    let prose = "Identifies the live runtime session. It rides on the event frame, never inside the message body."
    return """
      | One | Two | Three | Four | Five |
      | --- | --- | --- | --- | --- |
      | \(prose) | \(prose) | \(prose) | \(prose) | \(prose) |
      """
  }()

  // MARK: - Helpers

  /// What a hosted `ChatView` gives back: the transcript's collection view and the composer's
  /// input, both live, plus the plain scroll views (`MarkdownTableView` regions) in the rows.
  private struct HostedChat {
    var transcript: UICollectionView
    var composer: ComposerInputTextView
    var plainScrollViews: [UIScrollView]
  }

  /// Hosts the **real** `ChatView` (inside a `NavigationStack`, like the app) in a window of the
  /// given size and forces a layout pass. The transcript is seeded with rows so the
  /// `UICollectionView` — not the empty-chat hero — is what fills the transcript region.
  @MainActor
  private func hostedChat(
    window size: CGSize,
    markdown: String = "row",
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> HostedChat {
    let state = ChatFeature.State(
      connection: ServerConnection(
        baseURL: URL(string: "http://127.0.0.1:8787")!, auth: .token("t")
      ),
      resumeStoredID: "column-session",
      title: "Column",
      transcript: IdentifiedArray(
        uniqueElements: (1...3).map { i in
          ChatRow(id: UUID(), kind: .message(role: .assistant, text: "\(markdown) \(i)", isComplete: true))
        }
      ),
      status: .ready
    )
    let store = Store(initialState: state) { ChatFeature() } withDependencies: {
      // Don't open a real socket during layout.
      $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
      $0.continuousClock = ImmediateClock()
    }
    let controller = UIHostingController(
      rootView: NavigationStack { ChatView(store: store) }.dynamicTypeSize(.large)
    )
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = controller
    window.isHidden = false
    windows.append(window)
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    // The transcript is a `UIViewRepresentable`; let its first collection-view layout settle
    // (self-sizing cells need a pass of their own) before reading frames.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    let scrolls = Self.scrollViews(in: controller.view)
    let transcript = try XCTUnwrap(
      scrolls.compactMap { $0 as? UICollectionView }.first,
      "the transcript must be hosted", file: file, line: line
    )
    let composer = try XCTUnwrap(
      scrolls.compactMap { $0 as? ComposerInputTextView }.first,
      "the composer's input view must be hosted", file: file, line: line
    )
    // The transcript is a `UICollectionView` and both the composer's input and a `SelectableText`
    // row are `UITextView`s; with no card standing, what is left is the tables' scroll views.
    let plain = scrolls.filter { !($0 is UICollectionView) && !($0 is UITextView) }
    return HostedChat(transcript: transcript, composer: composer, plainScrollViews: plain)
  }

  /// Every scroll view in the view hierarchy.
  private static func scrollViews(in view: UIView) -> [UIScrollView] {
    var found: [UIScrollView] = []
    if let scroll = view as? UIScrollView { found.append(scroll) }
    for sub in view.subviews { found += scrollViews(in: sub) }
    return found
  }
}
