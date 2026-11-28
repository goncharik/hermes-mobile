import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// The launch-time "can't reach the server" screen (#62). The three baselines pin the two
/// reason variants (which drive different copy) and the in-flight retry state (which swaps
/// the button label for a spinner).
final class ConnectionFailedSnapshotTests: SnapshotTestCase {
  private func store(
    url: String = "http://mac.tailnet:9119",
    reason: RESTError,
    details: String? = nil,
    isRetrying: Bool = false
  ) -> StoreOf<ConnectionFailedFeature> {
    Store(
      initialState: ConnectionFailedFeature.State(
        connection: ServerConnection(baseURL: URL(string: url)!, token: "t"),
        reason: reason,
        details: details,
        isRetrying: isRetrying
      )
    ) { ConnectionFailedFeature() }
  }

  /// The Details disclosure open (#193): the failed step and its raw cause under the reason
  /// line, above the escape routes.
  func testConnectionFailedView_detailsExpanded() {
    let view = ConnectionFailedView(
      store: store(reason: .unreachable, details: "GET /api/sessions: URLError -1001 timedOut"),
      isShowingDetails: true
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Offline: "check Wi-Fi/cellular" copy — no point pointing the user at their VPN.
  func testConnectionFailedView_offline() {
    let view = ConnectionFailedView(store: store(reason: .offline))
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Unreachable, with a long URL: the VPN/Tailscale hint, and the URL wrapped rather than
  /// truncated — naming the server is the screen's whole job. The guarantee is structural
  /// (the `Text` carries no `lineLimit`, so it can only grow); this baseline records what
  /// that looks like, and the fixture's hyphens mean it wraps on word boundaries.
  func testConnectionFailedView_unreachableLongURL() {
    let view = ConnectionFailedView(
      store: store(
        url: "http://very-long-machine-name.tail9f3c2b.ts.net:9119",
        reason: .unreachable
      )
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Retry in flight: the button swaps to a spinner and is disabled — while "Log Out", the
  /// way OFF this screen, stays enabled (a probe can run to URLSession's 60s default, and the
  /// foreground auto-retry arms it unasked).
  ///
  /// The indeterminate spinner is captured at whatever rotation the render server is at, so
  /// this one baseline needs a pixel budget — and the budget does **not** mean what its number
  /// suggests, so don't read it as "1% of this screen is unasserted". Measured against a
  /// failing render (1170×2532): exactly **1,682 pixels differ at all (0.06%)**, every one of
  /// them inside a 93×93px box around the spinner glyph — a hard ceiling of 0.29% whatever
  /// phase it is caught in. But `precision` is evaluated by SnapshotTesting's Metal fast path
  /// as `1 - areaAverage(threshold(deltaE))`, and that float average over ~3M pixels has a
  /// noise floor far above a 0.06% signal: **0.995 fails, 0.993 passes**. The budget is
  /// therefore set by the estimator, not by the drift, and tightening it further buys nothing
  /// but a flaky test.
  ///
  /// What a fungible budget genuinely cannot rule out is a *small* regression elsewhere
  /// (a vanished control) passing inside it. That hole is closed structurally, not by pixels:
  /// see `ConnectionFailedControlsTests` below, which pins **every** control on the screen —
  /// the help link included, since a footnote-sized link is precisely the kind of disappearance
  /// a fungible pixel budget absorbs without noticing.
  func testConnectionFailedView_retrying() {
    let view = ConnectionFailedView(store: store(reason: .unreachable, isRetrying: true))
    assertSnapshot(of: view, as: deviceImage(precision: 0.99))
  }
}

/// The deterministic half of the retrying assertion (see `testConnectionFailedView_retrying`).
/// A snapshot of this state can only be asserted with a pixel budget the size of the
/// indeterminate spinner, and a budget cannot tell "the spinner rotated" from "a control the
/// same size vanished". So the controls are pinned here instead — hosted in a real `UIWindow`
/// and read back through the accessibility tree, which has no tolerance to spend.
final class ConnectionFailedControlsTests: XCTestCase {
  /// Every control that is not the retry button itself — the way OFF the screen plus the
  /// connection-help link. Both must survive a retry, so they are asserted in both states
  /// rather than only at rest.
  private static let secondaryControls = ["Need help setting up your agent?", "Log Out"]

  /// While a probe is in flight the primary control must be the disabled "Retrying" one, and
  /// everything else must stay tappable: a probe can run to `URLSession`'s 60s default and the
  /// foreground auto-retry arms it without the user asking, so greying them out would strand
  /// the user on a screen of dead buttons. The help link counts — this screen shows exactly the
  /// failures the setup guide explains, and it is the app's single connection-help surface.
  func testRetryingDisablesOnlyTheRetryControl() {
    let elements = hostedElements(isRetrying: true)

    XCTAssertTrue(elements["Retrying"]?.contains(.notEnabled) == true, "\(elements.keys)")
    XCTAssertNil(elements["Retry"], "the idle label must be gone while retrying")
    for label in Self.secondaryControls {
      XCTAssertEqual(elements[label]?.contains(.notEnabled), false, "\(label) — \(elements.keys)")
    }
  }

  /// The idle counterpart, so the test above can't pass by the screen simply never rendering
  /// its buttons: at rest every control is present and tappable.
  func testIdleScreenOffersAllControlsEnabled() {
    let elements = hostedElements(isRetrying: false)

    for label in ["Retry"] + Self.secondaryControls {
      XCTAssertEqual(elements[label]?.contains(.notEnabled), false, "\(label) — \(elements.keys)")
    }
  }

  /// Host the real view in a key window and collect every accessibility element's label →
  /// traits. SwiftUI only builds the accessibility tree for a view that is in a window and
  /// laid out, hence the window rather than a bare `sizeThatFits`.
  private func hostedElements(isRetrying: Bool) -> [String: UIAccessibilityTraits] {
    let store = Store(
      initialState: ConnectionFailedFeature.State(
        connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
        reason: .unreachable,
        isRetrying: isRetrying
      )
    ) { ConnectionFailedFeature() }
    let host = UIHostingController(rootView: ConnectionFailedView(store: store))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    var found: [String: UIAccessibilityTraits] = [:]
    collect(host.view, into: &found)
    return found
  }

  private func collect(_ node: NSObject, into found: inout [String: UIAccessibilityTraits]) {
    if let label = node.accessibilityLabel, !label.isEmpty {
      found[label] = node.accessibilityTraits
    }
    for child in (node.accessibilityElements as? [NSObject]) ?? [] {
      collect(child, into: &found)
    }
    if let view = node as? UIView {
      for subview in view.subviews { collect(subview, into: &found) }
    }
  }
}
