import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// Measured acceptance checks for the onboarding form's readable-width cap (#80).
///
/// `ConnectionView` is a `Form`, which fills whatever it is given: on an iPad in landscape that
/// is the whole window, so every row's label sits alone at the leading edge of a ~1300pt line.
/// The fix is the same cap the chat column uses — `ChatLayout.readableMaxWidth` on the form plus
/// a greedy frame around it to center the result.
///
/// A snapshot cannot prove either half: the snapshot suite renders this screen at phone widths,
/// which are below the cap, and "narrower than the window" is not the same claim as "exactly the
/// constant, centered". So these tests host the real `ConnectionView` in an iPad-sized window and
/// read the geometry off the `UICollectionView` that backs the form.
///
/// Dynamic Type is pinned to `.large`: the cap is a constant, but the rows inside it scale.
///
/// **Red-checked** against `ConnectionView` without the two frames: in the 1194pt window the form
/// measured 1194pt wide at x = 0, so the width and margin assertions went red. Note the
/// leading == trailing check passes there *trivially* (0 == 0) — centering alone is not a
/// falsifiable claim, which is why the margin assertion sits beside it. The phone-window test
/// passes either way, which is its contract (the cap must never narrow a phone).
final class ConnectionColumnLayoutTests: XCTestCase {
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

  /// In a wide window the form is exactly `readableMaxWidth` wide and sits in the middle of the
  /// window — equal margins either side. The centering half matters on its own: a cap without the
  /// greedy frame pins the form to the leading edge, which looks like a bug rather than a column.
  @MainActor
  func testWideWindowCapsTheFormAtReadableWidthAndCentersIt() throws {
    let form = try hostedForm(window: Self.wideWindow)
    let cap = ChatLayout.readableMaxWidth
    let frame = form.convert(form.bounds, to: nil)

    XCTAssertEqual(frame.width, cap, accuracy: 1, "The form is capped at the readable width")
    let leading = frame.minX
    let trailing = Self.wideWindow.width - frame.maxX
    XCTAssertEqual(leading, trailing, accuracy: 1, "…and centered, not pinned to the leading edge")
    XCTAssertGreaterThan(leading, 0, "A wide window must show margin either side of the form")
  }

  /// The other half of the contract: a phone window is never narrowed. The cap is a maximum, so
  /// below it the form still fills the window exactly as it did before the change.
  @MainActor
  func testPhoneWindowIsNeverNarrowedByTheCap() throws {
    let form = try hostedForm(window: Self.phoneWindow)
    let frame = form.convert(form.bounds, to: nil)

    XCTAssertEqual(
      frame.width, Self.phoneWindow.width, accuracy: 1,
      "A phone width is below the cap, so the form spans the window"
    )
    XCTAssertEqual(frame.minX, 0, accuracy: 1, "…with no centering margin")
  }

  // MARK: - Helpers

  /// Hosts the **real** `ConnectionView` (inside a `NavigationStack`, like the app) in a window of
  /// the given size, forces a layout pass, and returns the scroll view backing its `Form`.
  @MainActor
  private func hostedForm(
    window size: CGSize,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UIScrollView {
    let store = Store(
      initialState: ConnectionFeature.State(serverURL: "http://host:9119")
    ) {
      ConnectionFeature()
    } withDependencies: {
      // `.onAppear` probes the server to unlock sign-in; keep the layout pass off the network.
      // `ServerStatus` has no public memberwise init, so decode the reachable shape.
      let reachable = try? JSONDecoder().decode(
        ServerStatus.self, from: Data(#"{"version":"0.16.0"}"#.utf8)
      )
      $0.hermesREST.status = { _ in try XCTUnwrap(reachable) }
      $0.hermesREST.authProviders = { _ in nil }
      $0.continuousClock = ImmediateClock()
    }
    let controller = UIHostingController(
      rootView: NavigationStack { ConnectionView(store: store) }.dynamicTypeSize(.large)
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

    return try XCTUnwrap(
      Self.scrollViews(in: controller.view).first,
      "the form must be hosted", file: file, line: line
    )
  }

  /// Every scroll view in the view hierarchy, outermost first.
  private static func scrollViews(in view: UIView) -> [UIScrollView] {
    var found: [UIScrollView] = []
    if let scroll = view as? UIScrollView { found.append(scroll) }
    for sub in view.subviews { found += scrollViews(in: sub) }
    return found
  }
}
