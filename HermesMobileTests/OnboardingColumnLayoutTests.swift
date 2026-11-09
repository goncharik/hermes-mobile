import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured acceptance checks for the onboarding column cap (#136, replacing the old one-screen
/// form's #80 check).
///
/// Every onboarding screen is an `OnboardingScreen`: a scroll view that would fill whatever it
/// is given — on an iPad in landscape, the whole ~1200pt window, leaving each line of copy alone
/// across the screen. The fix is `OnboardingLayout.maxWidth` on the screen's outer container plus
/// a greedy frame around it to centre the result.
///
/// A snapshot cannot prove either half: the snapshot suite renders at phone widths, which are
/// below the cap, and "narrower than the window" is not the same claim as "exactly the constant,
/// centred". So these tests host the real `ConnectionView` in an iPad-sized window and read the
/// geometry off the `UIScrollView` that backs the screen on top of the stack.
///
/// Dynamic Type is pinned to `.large`: the cap is a constant, but the rows inside it scale.
///
/// The leading == trailing check alone would pass trivially on an uncapped screen (0 == 0), so
/// the margin assertion sits beside it. The phone-window tests pass either way, which is their
/// contract (the cap must never narrow a phone).
final class OnboardingColumnLayoutTests: XCTestCase {
  /// An iPad Pro 11" in landscape — comfortably wider than the cap.
  private static let wideWindow = CGSize(width: 1194, height: 834)

  /// iPhone 13 Pro width — the same viewport the snapshot suite pins.
  private static let phoneWindow = CGSize(width: 390, height: 700)

  /// Kept alive for the duration of a test: a hosted view only lays out for real while its
  /// window exists.
  private var windows: [UIWindow] = []

  override func tearDown() {
    for window in windows {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    super.tearDown()
  }

  /// Welcome in a wide window: exactly `maxWidth` wide, centred with a margin either side.
  @MainActor
  func testWideWindowCapsWelcomeAndCentersIt() throws {
    try assertCappedAndCentered(try hostedScrollView(path: [], window: Self.wideWindow))
  }

  /// The pushed Server step gets the same column — the cap lives in the shared screen
  /// scaffold, not on Welcome alone.
  @MainActor
  func testWideWindowCapsTheServerStepAndCentersIt() throws {
    let path: [ConnectionPath.State] = [.server(ServerStep.State(addressText: "mac"))]
    try assertCappedAndCentered(try hostedScrollView(path: path, window: Self.wideWindow))
  }

  /// The other half of the contract: a phone window is never narrowed. The cap is a maximum,
  /// so below it the screen still fills the window.
  @MainActor
  func testPhoneWindowIsNeverNarrowedByTheCap() throws {
    for path: [ConnectionPath.State] in [[], [.server(ServerStep.State(addressText: "mac"))]] {
      let scroll = try hostedScrollView(path: path, window: Self.phoneWindow)
      let frame = scroll.convert(scroll.bounds, to: nil)
      XCTAssertEqual(
        frame.width, Self.phoneWindow.width, accuracy: 1,
        "A phone width is below the cap, so the screen spans the window"
      )
      XCTAssertEqual(frame.minX, 0, accuracy: 1, "…with no centering margin")
    }
  }

  /// The Server step's example chips at an accessibility text size: a chip wider than the
  /// line wraps its label instead of widening the layout. Before the fix the flow layout
  /// reported the widest chip's ideal width, the onboarding column grew past the phone and its
  /// copy clipped on both edges.
  @MainActor
  func testFlowLayoutNeverReportsMoreWidthThanItIsOffered() {
    let lineWidth: CGFloat = 350
    let chips = OnboardingFlowLayout(spacing: 8) {
      ForEach(["Tailscale name", "Local IP", "https:// address"], id: \.self) { label in
        Button {} label: {
          Label(label, systemImage: "cloud").font(.subheadline)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
      }
    }
    for size: DynamicTypeSize in [.large, .accessibility5] {
      let controller = UIHostingController(rootView: chips.dynamicTypeSize(size))
      let fitted = controller.sizeThatFits(
        in: CGSize(width: lineWidth, height: .greatestFiniteMagnitude)
      )
      XCTAssertLessThanOrEqual(fitted.width, lineWidth + 0.5, "\(size): chips overflow the line")
    }
  }

  // MARK: - Helpers

  private func assertCappedAndCentered(
    _ scroll: UIScrollView,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let frame = scroll.convert(scroll.bounds, to: nil)
    XCTAssertEqual(
      frame.width, OnboardingLayout.maxWidth, accuracy: 1,
      "The column is capped at the onboarding width", file: file, line: line
    )
    let leading = frame.minX
    let trailing = Self.wideWindow.width - frame.maxX
    XCTAssertEqual(leading, trailing, accuracy: 1, "…and centred, not pinned to the leading edge", file: file, line: line)
    XCTAssertGreaterThan(leading, 0, "A wide window must show margin either side of the column", file: file, line: line)
  }

  /// Hosts the **real** `ConnectionView` with `path` seeded in a window of the given size,
  /// forces a layout pass, and returns the scroll view backing the screen on top of the stack.
  @MainActor
  private func hostedScrollView(
    path: [ConnectionPath.State],
    window size: CGSize,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UIScrollView {
    var state = ConnectionFeature.State()
    for element in path { state.path.append(element) }
    let store = Store(initialState: state) { ConnectionFeature() }
    let controller = UIHostingController(
      rootView: ConnectionView(store: store).dynamicTypeSize(.large)
    )
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = controller
    window.isHidden = false
    windows.append(window)
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    // Only the top screen's scroll view is in a window-visible position; a covered root is
    // either detached from the hierarchy or offscreen, so take the visible one.
    let visible = Self.scrollViews(in: controller.view).filter { scroll in
      scroll.window != nil && !scroll.isHidden
        && scroll.convert(scroll.bounds, to: nil).intersects(window.bounds)
    }
    return try XCTUnwrap(visible.last, "the screen must be hosted", file: file, line: line)
  }

  /// Every scroll view in the view hierarchy, outermost first.
  private static func scrollViews(in view: UIView) -> [UIScrollView] {
    var found: [UIScrollView] = []
    if let scroll = view as? UIScrollView { found.append(scroll) }
    for sub in view.subviews { found += scrollViews(in: sub) }
    return found
  }
}
