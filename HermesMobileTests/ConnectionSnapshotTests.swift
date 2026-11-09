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
  /// Canvas for a whole screen at an accessibility text size (scrolling, so pinned).
  private static let accessibilityHeight: CGFloat = 2400

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
    assertFailure(.hostNotFound, address: "mac-mini.tail4c2e.ts.net")
  }

  func testServerFailure_hostNotFound() {
    assertFailure(.hostNotFound, address: "agent.example.com")
  }

  /// A bare http host, both candidates refused: the card names the last one tried (`:9119`).
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
    assertFailure(.offline, address: "mac-mini.tail4c2e.ts.net", tried: 1)
  }

  /// "Offline" for a same-Wi-Fi address may be a denied Local Network permission: the card
  /// says it couldn't reach the host and adds the Local Network hint.
  func testServerFailure_offline_localNetwork() {
    assertFailure(.offline, address: "192.168.1.20", tried: 1)
  }

  func testServerFailure_notHermes() {
    assertFailure(.notHermes(httpStatus: 404), address: "mac-mini.tail4c2e.ts.net:8080")
  }

  /// A 2xx that isn't Hermes status JSON: the non-404 copy, with the Details box open.
  func testServerFailure_notHermes200_detailsOpen() {
    assertFailure(
      .notHermes(httpStatus: 200), address: "mac-mini.tail4c2e.ts.net", detailsExpanded: true
    )
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
    assertFailure(.httpError("Bad gateway"), address: "https://agent.example.com")
  }

  // MARK: - Sign in step: one per layout row

  /// Password available + OAuth available: fields first, the provider under "or".
  func testSignIn_passwordAndOAuth() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, oauthProviders: [nous], supportsNativeFlow: true)
    )))
  }

  /// Password available, OAuth advertised by a gateway too old for the native flow.
  func testSignIn_passwordOAuthTooOld() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, oauthProviders: [nous], supportsNativeFlow: false)
    )))
  }

  func testSignIn_passwordOnly() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic)
    )))
  }

  /// No password, OAuth available: the provider button IS the call to action (no footer).
  func testSignIn_oauthOnly() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(oauthProviders: [nous], supportsNativeFlow: true)
    )))
  }

  /// No password, OAuth too old: the token field, with the reason.
  func testSignIn_tokenOAuthTooOld() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(oauthProviders: [nous], supportsNativeFlow: false)
    )))
  }

  /// A token-only (not gated) server.
  func testSignIn_tokenOnlyServer() {
    assertSignIn(SignInStep.State(probe: probe(.tokenOnly)))
  }

  /// "Other ways to sign in" opened under the password layout: the token field + its button.
  func testSignIn_otherWaysOpen() {
    var state = SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, oauthProviders: [nous], supportsNativeFlow: true)
    ))
    state.isShowingOtherWays = true
    assertSignIn(state)
  }

  // MARK: - Sign in step: warnings and verdicts

  /// Plain http to a public host: the cleartext warning above the fields.
  func testSignIn_cleartextWarning() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic),
      typed: "agent.example.com:9119"
    )))
  }

  /// The OAuth-only layout warns too: the bearer pair and every later request travel in plain
  /// text.
  func testSignIn_cleartextWarning_oauthOnly() {
    assertSignIn(SignInStep.State(probe: probe(
      ServerAuthCapability(oauthProviders: [nous], supportsNativeFlow: true),
      typed: "agent.example.com:9119"
    )))
  }

  func testSignIn_invalidCredentials() {
    var state = SignInStep.State(probe: probe(ServerAuthCapability(passwordProvider: basic)))
    state.username = "alice"
    state.password = "wrong-password"
    state.status = .invalidCredentials(.password)
    assertSignIn(state)
  }

  /// "Other ways" open, so the token field is on screen too: only the password fields get
  /// the red outline.
  func testSignIn_invalidCredentials_otherWaysOpen() {
    var state = SignInStep.State(probe: probe(ServerAuthCapability(passwordProvider: basic)))
    state.username = "alice"
    state.password = "wrong-password"
    state.isShowingOtherWays = true
    state.status = .invalidCredentials(.password)
    assertSignIn(state)
  }

  /// An OAuth 401 under the password layout: the verdict sits under the provider button and
  /// the password fields stay unmarked.
  func testSignIn_oauthInvalidCredentials_passwordLayout() {
    var state = SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, oauthProviders: [nous], supportsNativeFlow: true)
    ))
    state.status = .invalidCredentials(.oauth)
    assertSignIn(state)
  }

  func testSignIn_oauthInvalidCredentials_oauthOnly() {
    var state = SignInStep.State(probe: probe(
      ServerAuthCapability(oauthProviders: [nous], supportsNativeFlow: true)
    ))
    state.status = .invalidCredentials(.oauth)
    assertSignIn(state)
  }

  /// A password attempt in flight: "Signing in…" on the footer button.
  func testSignIn_validatingPassword() {
    var state = SignInStep.State(probe: probe(ServerAuthCapability(passwordProvider: basic)))
    state.username = "alice"
    state.password = "pw"
    state.status = .validating(.password)
    assertSignIn(state)
  }

  func testSignIn_invalidToken() {
    var state = SignInStep.State(probe: probe(.tokenOnly), prefilledToken: "hm_tok_stale")
    state.status = .invalidCredentials(.token)
    assertSignIn(state)
  }

  /// A wait-it-out verdict (rate limit, outage, browser-leg failure): the server copy in a
  /// notice above the methods.
  func testSignIn_failed() {
    var state = SignInStep.State(probe: probe(
      ServerAuthCapability(oauthProviders: [nous], supportsNativeFlow: true)
    ))
    state.status = .failed("Too many sign-in attempts. Wait a minute, then try again.")
    assertSignIn(state)
  }

  // MARK: - Accessibility text sizes

  /// At an accessibility size the footer scrolls as the content's last block instead of
  /// being pinned (pinned, it filled most of the phone and squeezed the body to a sliver).
  func testWelcome_accessibilitySize() {
    assertSnapshot(
      of: onboarding([]).dynamicTypeSize(.accessibility3),
      as: deviceImage(appearance: .light, height: Self.accessibilityHeight)
    )
  }

  /// The example chips wrap inside the column instead of widening it past the screen.
  func testServer_accessibilitySize() {
    assertSnapshot(
      of: server("mac-mini.tail4c2e.ts.net").dynamicTypeSize(.accessibility3),
      as: deviceImage(appearance: .light, height: Self.accessibilityHeight)
    )
  }

  /// The server card stacks: the host and summary full width, "Change" under them.
  func testSignIn_accessibilitySize() {
    let state = SignInStep.State(probe: probe(
      ServerAuthCapability(passwordProvider: basic, oauthProviders: [nous], supportsNativeFlow: true)
    ))
    assertSnapshot(
      of: step(SignInStepView(store: Store(initialState: state) { SignInStep() }))
        .dynamicTypeSize(.accessibility3),
      as: deviceImage(appearance: .light, height: Self.accessibilityHeight)
    )
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
    .tint(.hermesAccentInk)
  }

  private func server(_ text: String, phase: ServerStep.State.Phase = .idle) -> some View {
    var state = ServerStep.State(addressText: text)
    state.phase = phase
    return step(
      ServerStepView(store: Store(initialState: state) { ServerStep() }, setupGuideButtonTapped: {})
    )
  }

  /// The Server step showing `failure` for `text` after probing its first `tried` candidates
  /// (all of them by default). `detailsExpanded` renders the card alone with Details open.
  private func assertFailure(
    _ failure: ProbeFailure,
    address text: String,
    tried: Int? = nil,
    detailsExpanded: Bool = false,
    appearance: UIUserInterfaceStyle = .light,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
  ) {
    let address = ServerAddress(text)!
    let candidates = address.candidates
    let failed = FailedServerProbe(
      address: address, failure: failure,
      tried: Array(candidates.prefix(tried ?? candidates.count))
    )
    if detailsExpanded {
      let card = ProbeFailureCard(failed: failed, setupGuideButtonTapped: {}, isShowingDetails: true)
        .padding()
        .frame(width: device.size?.width ?? 390)
        .background(Color(.systemGroupedBackground))
      assertSnapshot(
        of: card, as: componentImage(appearance: appearance),
        file: file, testName: testName, line: line
      )
    } else {
      assertSnapshot(
        of: server(text, phase: .failed(failed)),
        as: deviceImage(appearance: appearance, height: Self.tallHeight),
        file: file, testName: testName, line: line
      )
    }
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
