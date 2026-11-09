import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshot coverage for the auth surfaces outside the onboarding flow: the "Set Up Your
/// Agent" guide sheet, the show/hide credential field, and the re-auth sheet (password, token
/// and OAuth variants). The onboarding Sign in step itself lives in `ConnectionSnapshotTests`.
/// Dark traits, `deviceImage()` whole-screen render (the re-auth sheet and the guide bring
/// their own `NavigationStack`).
final class AuthSnapshotTests: SnapshotTestCase {
  /// A tall fixed-size whole-screen render (device width, extra-tall height) so a long
  /// scrolling sheet is captured in full rather than clipped at the device fold. Same dark
  /// traits + key-window compositing as `deviceImage()`.
  private func tallImage<V: SwiftUI.View>(height: CGFloat = 1400) -> Snapshotting<V, UIImage> {
    .image(
      drawHierarchyInKeyWindow: true,
      perceptualPrecision: 0.98,
      layout: .fixed(width: device.size!.width, height: height),
      traits: UITraitCollection(userInterfaceStyle: .dark)
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
      // 2100pt: the tab picker above the scroll pushed the docs link to the old 2050 edge.
      as: tallImage(height: 2100)
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

  /// The guide's "Hermes Cloud" tab (seeded via the init): the segmented control on Cloud,
  /// the copy card (desktop's "Hermes Cloud" / "Nous portal" terms, verbatim with the README
  /// quick-start) and the "Open the Nous portal" link row. Short enough for one phone screen.
  func testAgentSetupGuide_cloud() {
    assertSnapshot(of: AgentSetupGuideView(tab: .cloud), as: deviceImage())
  }

  func testAgentSetupGuide_cloud_light() {
    assertSnapshot(of: AgentSetupGuideView(tab: .cloud), as: deviceImage(appearance: .light))
  }

  // MARK: - Show/hide credential toggle (#129)

  /// The credential field rendered on its own at a phone row width, both states side by side
  /// in one image: masked with the `eye` button, then revealed (plain text) with `eye.slash`.
  /// The whole-screen Sign in, re-auth and Settings baselines show the masked state in
  /// context; this one pins the revealed state, which a snapshot can only reach via
  /// `initiallyRevealed`.
  func testRevealableSecureField_maskedAndRevealed() {
    assertSnapshot(
      of: VStack(spacing: 16) {
        RevealableSecureField("Password", text: .constant("hunter2-correct-horse"), textContentType: .password)
        RevealableSecureField(
          "Session token",
          text: .constant("hm_tok_9f2c41e7a0b84d55"),
          initiallyRevealed: true
        )
      }
      .padding()
      .frame(width: 358)
      .background(Color(.secondarySystemGroupedBackground)),
      as: componentImage()
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

  /// Re-auth sheet, OAuth variant (#19): no fields at all — the single plain-text "Continue
  /// with <display name>" button REPLACES the generic "Sign in" button (never both), and
  /// "Quit to start" is still the escape hatch.
  func testReauthSheet_oauth() {
    assertSnapshot(of: ReauthView(store: oauthReauthStore()), as: deviceImage())
  }

  /// Same sheet in light appearance — the provider button must read as an ordinary tinted
  /// row in both, which is the whole point of the plain-text treatment (App Store 5.2.1).
  func testReauthSheet_oauth_light() {
    assertSnapshot(of: ReauthView(store: oauthReauthStore()), as: deviceImage(appearance: .light))
  }

  /// Bearer session expired against the `nous` provider, whose display name the last
  /// capability probe supplied.
  private func oauthReauthStore() -> StoreOf<ReauthFeature> {
    Store(
      initialState: ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!,
        method: .oauth,
        provider: "nous",
        providerDisplayName: "Nous Research",
        previousUserID: "user_42"
      )
    ) { ReauthFeature() }
  }
}
