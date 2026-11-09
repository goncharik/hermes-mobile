import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// The onboarding flow (#136): Welcome, the Server step (idle, probing, every failure card)
/// and the Sign in step (every capability layout, the cleartext warning and the verdicts).
///
/// Welcome renders through the real `ConnectionView` stack host; each step renders in its own
/// `NavigationStack` with the flow's tint, so its navigation bar ("Step 1 of 2") is in the
/// picture but the Liquid Glass back button is not (see `step(_:)`). Light is the
/// baseline appearance here; Welcome and one failure card add dark variants for the colours
/// this flow introduces (the amber ink and the tinted cards).
final class ConnectionSnapshotTests: SnapshotTestCase {
  /// Tall canvas for a screen whose card or fields run past one phone screen.
  private static let tallHeight: CGFloat = 1100

  private let basic = AuthProvider(name: "basic", displayName: "Password", supportsPassword: true)
  private let nous = AuthProvider(name: "nous", displayName: "Nous Research", supportsPassword: false)

  // MARK: - Welcome

  func testWelcome() {
    assertSnapshot(of: onboarding([]), as: deviceImage(appearance: .light))
  }

  func testWelcome_dark() {
    assertSnapshot(of: onboarding([]), as: deviceImage(appearance: .dark))
  }

  // MARK: - Server step

  func testServer_empty() {
    assertSnapshot(of: server(""), as: deviceImage(appearance: .light))
  }

  /// A bare http name: the live line names the as-typed URL and the `:9119` fallback.
  func testServer_typedBareHost() {
    assertSnapshot(of: server("mac-mini.tail4c2e.ts.net"), as: deviceImage(appearance: .light))
  }

  /// An https address has no fallback, so the line names only the typed URL.
  func testServer_typedHTTPS() {
    assertSnapshot(of: server("https://agent.example.com"), as: deviceImage(appearance: .light))
  }

  func testServer_invalidAddress() {
    assertSnapshot(of: server("http://"), as: deviceImage(appearance: .light))
  }

  /// First stage: reaching the host (spinner), the other two checks pending.
  func testServer_probingReaching() {
    assertSnapshot(
      of: server("mac-mini.tail4c2e.ts.net", phase: .probing(.reaching)),
      as: deviceImage(appearance: .light)
    )
  }

  /// `/api/status` answered: reached + Hermes checked, reading the sign-in options.
  func testServer_probingReadingSignInOptions() {
    assertSnapshot(
      of: server("mac-mini.tail4c2e.ts.net", phase: .probing(.readingSignInOptions)),
      as: deviceImage(appearance: .light)
    )
  }

  // MARK: - Server step: failure cards

  func testServerFailure_tailscaleNameNotFound() {
    assertFailure(.hostNotFound(tailnetName: true), address: "mac-mini.tail4c2e.ts.net")
  }

  func testServerFailure_hostNotFound() {
    assertFailure(.hostNotFound(tailnetName: false), address: "agent.example.com")
  }

  /// A bare http host: the card names both the as-typed URL and port 9119.
  func testServerFailure_refused() {
    assertFailure(.refused, address: "mac-mini.tail4c2e.ts.net")
  }

  func testServerFailure_refused_dark() {
    assertFailure(.refused, address: "mac-mini.tail4c2e.ts.net", appearance: .dark)
  }

  func testServerFailure_timedOut() {
    assertFailure(.timedOut, address: "100.101.102.103:9119")
  }

  /// A same-Wi-Fi address: the Wi-Fi fixes plus the Local Network hint line (TN3179).
  func testServerFailure_timedOut_localNetworkHint() {
    assertFailure(.timedOut, address: "192.168.1.20")
  }

  func testServerFailure_untrustedCertificate() {
    assertFailure(.untrustedCertificate, address: "https://mac-mini.tail4c2e.ts.net")
  }

  func testServerFailure_offline() {
    assertFailure(.offline, address: "mac-mini.tail4c2e.ts.net")
  }

  func testServerFailure_notHermes() {
    assertFailure(.notHermes(httpStatus: 404), address: "mac-mini.tail4c2e.ts.net:8080")
  }

  func testServerFailure_hostRejected() {
    assertFailure(
      .hostRejected(detail: """
      Invalid Host header. Dashboard requests must use the bound hostname or the configured \
      public hostname.
      """),
      address: "mac-mini.tail4c2e.ts.net:9119"
    )
  }

  func testServerFailure_other() {
    assertFailure(.other("Bad gateway"), address: "https://agent.example.com")
  }

  // MARK: - Sign in step: one per layout row

  /// Password available + OAuth available: fields first, the provider under "or".
  func testSignIn_passwordAndOAuth() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, oauthProviders: [nous], supportsNativeFlow: true, isGated: true)
    )))
  }

  /// Password available, OAuth advertised by a gateway too old for the native flow.
  func testSignIn_passwordOAuthTooOld() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, oauthProviders: [nous], supportsNativeFlow: false, isGated: true)
    )))
  }

  func testSignIn_passwordOnly() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, isGated: true)
    )))
  }

  /// No password, OAuth available: the provider button IS the call to action (no footer).
  func testSignIn_oauthOnly() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(oauthProviders: [nous], supportsNativeFlow: true, isGated: true)
    )))
  }

  /// No password, OAuth too old: the token field, with the reason.
  func testSignIn_tokenOAuthTooOld() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(oauthProviders: [nous], supportsNativeFlow: false, isGated: true)
    )))
  }

  /// A token-only (not gated) server.
  func testSignIn_tokenOnlyServer() {
    assertSignIn(SignInStep.State(probe: probe(.tokenOnly)))
  }

  /// "Other ways to sign in" opened under the password layout: the token field + its button.
  func testSignIn_otherWaysOpen() {
    var state = SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, oauthProviders: [nous], supportsNativeFlow: true, isGated: true)
    ))
    state.isShowingOtherWays = true
    assertSignIn(state)
  }

  // MARK: - Sign in step: warnings and verdicts

  /// Plain http to a public host: the cleartext warning above the fields.
  func testSignIn_cleartextWarning() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, isGated: true),
      typed: "agent.example.com:9119"
    )))
  }

  func testSignIn_invalidCredentials() {
    var state = SignInStep.State(probe: probe(ServerAuthCapability(passwordProvider: basic, isGated: true)))
    state.username = "alice"
    state.password = "wrong-password"
    state.status = .invalidCredentials
    assertSignIn(state)
  }

  func testSignIn_invalidToken() {
    var state = SignInStep.State(probe: probe(.tokenOnly), prefilledToken: "hm_tok_stale")
    state.status = .invalidToken
    assertSignIn(state)
  }

  /// A wait-it-out verdict (rate limit, outage, browser-leg failure): the server copy in a
  /// notice above the methods.
  func testSignIn_failed() {
    var state = SignInStep.State(probe: probe(
      ServerAuthCapability(oauthProviders: [nous], supportsNativeFlow: true, isGated: true)
    ))
    state.selectedOAuthProviderName = "nous"
    state.status = .failed("Too many sign-in attempts. Wait a minute, then try again.")
    assertSignIn(state)
  }

  // MARK: - Helpers

  private func onboarding(_ path: [ConnectionPath.State]) -> ConnectionView {
    var state = ConnectionFeature.State()
    for element in path { state.path.append(element) }
    return ConnectionView(store: Store(initialState: state) { ConnectionFeature() })
  }

  /// A step in its own stack with the flow's tint, back button hidden. Pushed through
  /// `ConnectionView` it carries the Liquid Glass back button, whose light-mode compositing
  /// flips between two renders across runs by more than the shared 2% budget (measured: a
  /// ≤2/255 shimmer confined to the back-button circle, reported as a 5.7% mismatch) — and the
  /// key-window host shows one even for a root stack — so the steps are pinned without it.
  /// Welcome and the measured layout test still go through the real stack host.
  private func step(_ content: some View) -> some View {
    NavigationStack {
      content.navigationBarBackButtonHidden()
    }
    .tint(OnboardingLayout.accentInk)
  }

  private func server(_ text: String, phase: ServerStep.State.Phase = .idle) -> some View {
    var state = ServerStep.State(addressText: text)
    state.phase = phase
    return step(
      ServerStepView(store: Store(initialState: state) { ServerStep() }, setupGuideButtonTapped: {})
    )
  }

  private func assertFailure(
    _ failure: ProbeFailure,
    address text: String,
    appearance: UIUserInterfaceStyle = .light,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
  ) {
    let address = ServerAddress(text)!
    assertSnapshot(
      of: server(text, phase: .failed(failure, address)),
      as: deviceImage(appearance: appearance, height: Self.tallHeight),
      file: file, testName: testName, line: line
    )
  }

  private func assertSignIn(
    _ state: SignInStep.State,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
  ) {
    let view = step(SignInStepView(store: Store(initialState: state) { SignInStep() }))
    assertSnapshot(
      of: view,
      as: deviceImage(appearance: .light, height: Self.tallHeight),
      file: file, testName: testName, line: line
    )
  }

  private func probe(
    _ capability: ServerAuthCapability,
    typed: String = "mac-mini.tail4c2e.ts.net"
  ) -> ServerProbe {
    let address = ServerAddress(typed)!
    return ServerProbe(
      address: address,
      baseURL: address.candidates.last!,
      capability: capability,
      version: "0.19.2"
    )
  }
}
