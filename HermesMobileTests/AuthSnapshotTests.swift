import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshot coverage for the capability-aware auth screen (Password / Token segments,
/// token disclaimer, the "Set Up Your Agent" guide sheet, capability-disabled segment
/// states) and the re-auth sheet (password vs token variants). Mirrors the host / setup
/// pattern in `ConnectionSnapshotTests` / `AddProfileSnapshotTests`: dark traits,
/// `deviceImage()` whole-screen render. Views wrap in a `NavigationStack` (the re-auth
/// sheet and the guide bring their own).
final class AuthSnapshotTests: SnapshotTestCase {
  /// A tall fixed-size whole-screen render (device width, extra-tall height) so a long
  /// scrolling `Form` is captured in full rather than clipped at the device fold. Same dark
  /// traits + key-window compositing as `deviceImage()`.
  private func tallImage<V: SwiftUI.View>(height: CGFloat = 1400) -> Snapshotting<V, UIImage> {
    .image(
      drawHierarchyInKeyWindow: true,
      perceptualPrecision: 0.98,
      layout: .fixed(width: device.size!.width, height: height),
      traits: UITraitCollection(userInterfaceStyle: .dark)
    )
  }

  private func connectionView(_ state: ConnectionFeature.State) -> some View {
    NavigationStack {
      ConnectionView(
        store: Store(initialState: state) { ConnectionFeature() }
      )
    }
  }

  // MARK: - Auth screen: segments

  /// Password segment on a gated server with a password-capable provider: username +
  /// password fields, both segments enabled, Password preselected.
  func testAuthScreen_passwordSegment() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          username: "alice",
          password: "••••••••",
          method: .password,
          capability: ServerAuthCapability(
            passwordProvider: AuthProvider(name: "basic", displayName: "Basic", supportsPassword: true),
            isGated: true
          ),
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  /// Token segment with no capability probed yet: session-token field plus the always-on
  /// disclaimer + "Learn how to connect securely" link.
  func testAuthScreen_tokenSegment() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••",
          method: .token,
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  // MARK: - Token disclaimer

  /// The token disclaimer in context on a token-only server: the inline honesty note and
  /// the "This server only supports token sign-in." hint footer.
  func testAuthScreen_tokenDisclaimer_tokenOnly() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••",
          method: .token,
          capability: .tokenOnly,
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  // MARK: - Agent setup guide sheet

  /// The "Set Up Your Agent" guide sheet in its default state: hero + the four numbered
  /// password-first setup cards, the Tailscale link row, the no-port-forward warning, the
  /// COLLAPSED "Advanced: token mode" disclosure, and the docs footer link. Tall fixed
  /// canvas so the whole scrollable stack is captured.
  func testAgentSetupGuide_collapsed() {
    assertSnapshot(
      of: AgentSetupGuideView(),
      as: tallImage(height: 2050)
    )
  }

  /// Same guide with the "Advanced: token mode" disclosure expanded (seeded via the init
  /// flag): master-key warning, `--insecure` + token-export command cards, trust-boundary
  /// note. Extra-tall canvas so the expanded section fits below the main recipe.
  func testAgentSetupGuide_advancedExpanded() {
    assertSnapshot(
      of: AgentSetupGuideView(advancedExpanded: true),
      // 2700pt is the practical ceiling: at @3x that is 8100px, just under the 8192px
      // Metal texture limit — 2800pt recorded a blank image.
      as: tallImage(height: 2700)
    )
  }

  // MARK: - Capability-disabled segment states

  /// Gated server (password available) but the user is on the Token segment: the de-emphasis
  /// hint nudges back to password ("This server uses password login…").
  func testAuthScreen_gated_tokenDeemphasized() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••",
          method: .token,
          capability: ServerAuthCapability(
            passwordProvider: AuthProvider(name: "basic", displayName: "Basic", supportsPassword: true),
            isGated: true
          ),
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  /// Token-only server with the Password segment selected: Password is disabled (the segment
  /// stays usable for Token), and the footer explains the server only supports token sign-in.
  func testAuthScreen_tokenOnly_passwordDisabled() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          method: .token,
          capability: .tokenOnly,
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  // MARK: - Re-auth sheet

  /// Re-auth sheet, password variant: fixed server, prefilled username, password field,
  /// Sign in + "Quit to start".
  func testReauthSheet_password() {
    assertSnapshot(
      of: ReauthView(
        store: Store(
          initialState: ReauthFeature.State(
            serverURL: URL(string: "http://mac.tailnet:9119")!,
            method: .password,
            previousUsername: "alice",
            password: "••••••••"
          )
        ) { ReauthFeature() }
      ),
      as: deviceImage()
    )
  }

  /// Re-auth sheet, token variant: fixed server, session-token field, no username.
  func testReauthSheet_token() {
    assertSnapshot(
      of: ReauthView(
        store: Store(
          initialState: ReauthFeature.State(
            serverURL: URL(string: "http://mac.tailnet:9119")!,
            method: .token,
            token: "••••••••"
          )
        ) { ReauthFeature() }
      ),
      as: deviceImage()
    )
  }
}
