import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Shared scaffolding for the feature snapshot suites. Renders the feature views to PNGs
/// (under `__Snapshots__/<suite file name>/`). On first run there's no baseline, so each
/// assertion records the image and reports a failure — that's expected; the PNGs are the
/// deliverable.
///
/// Two render paths:
/// - **Whole-screen views** (`.device` layout) use `drawHierarchyInKeyWindow: true` so the
///   iOS 26 system chrome composites — bottom search field, Liquid Glass toolbar/buttons.
///   That requires the host app (this target has one) and isn't pixel-exact, so they run at
///   `perceptualPrecision: 0.98`.
/// - **Singular components** (`.sizeThatFits`) keep the fast, deterministic layer render.
///
/// Subclass this in each feature suite so the shared fixtures (`device`, `now`,
/// `connection`, `id`, `solidPNG`) stay in one place.
class SnapshotTestCase: XCTestCase {
  let device = ViewImageConfig.iPhone13Pro
  /// Fixed reference "now" so relative timestamps are deterministic.
  let now = Date(timeIntervalSince1970: 1_749_600_000)
  let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  func id(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// Dark appearance is pinned (the app is designed dark-first) so renders don't drift
  /// with the simulator's appearance setting. Without this the baselines flip to light
  /// mode on a light-mode simulator and every pixel mismatches.
  private static let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

  /// Whole-screen snapshot: composites the iOS 26 system chrome (`drawHierarchyInKeyWindow`),
  /// so it needs the host app and isn't pixel-exact — runs at `perceptualPrecision: 0.98`.
  ///
  /// `precision` (the fraction of pixels that must clear that perceptual bar) defaults to
  /// `0.98`, NOT a strict 1: the Liquid Glass chrome (the nav `Done` capsule, glass circle
  /// buttons, the nav bar's scroll-edge pocket) composites **bimodally across test
  /// processes** — each process renders one of two states, so a baseline recorded in the
  /// other state fails at full strictness even though nothing changed. Measured cross-mode
  /// drift: 0.82% of pixels (Δ ≤ 10/255, the `Done` capsule alone,
  /// `testSettingsPluginUpdate*`) up to 1.66% (capsule + scroll-edge pocket,
  /// `testSettingsNotifications*`) — the 2% budget absorbs exactly that class of drift and
  /// nothing bigger. Lower it further ONLY for a genuinely non-deterministic region —
  /// an indeterminate `ProgressView` spinner is captured at whatever rotation the render
  /// server happens to be at. Measure the drift before picking a number, and record the
  /// measurement at the call site: with `perceptualPrecision < 1` the check is a float area
  /// average over millions of pixels, whose noise floor sits well above a small real drift, so
  /// the value you end up needing says more about the estimator than about the view (see
  /// `ConnectionFailedSnapshotTests.testConnectionFailedView_retrying`). A budget is fungible
  /// — it can absorb a small regression ANYWHERE on the screen, not only in the region it was
  /// sized for — so pair it with a structural assertion of whatever it could hide.
  ///
  /// Dark by default (see `darkTraits`); `appearance: .light` only for a screen whose light
  /// rendering is itself under test (the sidebar's accent highlight over a light list).
  func deviceImage<V: SwiftUI.View>(
    precision: Float = 0.98,
    appearance: UIUserInterfaceStyle = .dark
  ) -> Snapshotting<V, UIImage> {
    .image(
      drawHierarchyInKeyWindow: true,
      precision: precision,
      perceptualPrecision: 0.98,
      layout: .device(config: device),
      traits: appearance == .dark ? Self.darkTraits : UITraitCollection(userInterfaceStyle: appearance)
    )
  }

  /// Singular component snapshot: fast, deterministic layer render at `.sizeThatFits`.
  /// Dark by default (see `darkTraits`); pass `.light` only for a view whose light
  /// appearance is itself under test (the hero, brand colours over a light background).
  func componentImage<V: SwiftUI.View>(
    appearance: UIUserInterfaceStyle = .dark
  ) -> Snapshotting<V, UIImage> {
    .image(
      layout: .sizeThatFits,
      traits: appearance == .dark ? Self.darkTraits : UITraitCollection(userInterfaceStyle: appearance)
    )
  }

  /// Solid-color PNG so image-chip thumbnails render deterministically.
  func solidPNG(_ color: UIColor, _ side: CGFloat = 40) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).pngData { ctx in
      color.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
  }
}

extension Reducer where Action: CasePathable {
  /// Snapshot fixtures must render EXACTLY the seeded state. `deviceImage()` hosts the view
  /// in the real key window (`drawHierarchyInKeyWindow`), so the view's `.task` modifier
  /// fires and the feature's startup effects — prefs reload, fetches, poll loops — race the
  /// capture. Whether they land before or after the draw is a run-loop scheduling accident
  /// that shifts across simulator runtimes: one re-record captured post-`.task` state and
  /// silently wiped seeded pins, unread badges, and the archived empty state from the
  /// baselines. Swallowing the startup action pins the render to the seeded state; the
  /// behavior behind the startup action stays covered by the `TestStore` suites.
  func ignoring<V>(_ startupAction: CaseKeyPath<Action, V>) -> some Reducer<State, Action> {
    Reduce { state, action in
      guard action[case: startupAction] == nil else { return .none }
      return self.reduce(into: &state, action: action)
    }
  }
}
