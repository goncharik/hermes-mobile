import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

private func okStatus() -> ServerStatus {
  ServerStatus(version: "0.16.0", gatewayRunning: true, gatewayState: "running", activeSessions: 0)
}

/// A gated server offering a password provider — the `ServerAuthCapability` the probe builds
/// for `auth_required: true` + `[{basic, supports_password: true}]`.
private func passwordCapability(
  provider: String = "basic",
  displayName: String = "Password",
  oauthProviders: [AuthProvider] = [],
  supportsNativeFlow: Bool = false
) -> ServerAuthCapability {
  ServerAuthCapability(
    passwordProvider: AuthProvider(name: provider, displayName: displayName, supportsPassword: true),
    oauthProviders: oauthProviders,
    supportsNativeFlow: supportsNativeFlow,
    isGated: true
  )
}

/// The OAuth (session) provider a Nous-configured gateway advertises.
private let nousProvider = AuthProvider(
  name: "nous", displayName: "Nous Research", supportsPassword: false
)

/// A gated server that serves the native PKCE endpoints.
private func nousStatus(providers: [String] = ["nous"]) -> ServerStatus {
  var status = ServerStatus(version: "0.17.0", authRequired: true, authProviders: providers)
  status.authFlows = ["cookie", "native_pkce"]
  return status
}

private func oauthCapability(
  providers: [AuthProvider] = [nousProvider],
  supportsNativeFlow: Bool = true
) -> ServerAuthCapability {
  ServerAuthCapability(
    oauthProviders: providers,
    supportsNativeFlow: supportsNativeFlow,
    isGated: true
  )
}

private func bearerFixture(
  accessToken: String = "access-1",
  userID: String = "user-42"
) -> BearerSession {
  BearerSession(
    accessToken: accessToken,
    refreshToken: "refresh-1",
    expiresAt: 4_000_000_000,
    provider: "nous",
    userID: userID
  )
}

/// State as it stands right after a successful probe of a Nous-only gateway.
private func oauthReadyState(providers: [AuthProvider] = [nousProvider]) -> ConnectionFeature.State {
  ConnectionFeature.State(
    serverURL: "http://mac:9119",
    method: .oauth,
    capability: oauthCapability(providers: providers),
    serverVersion: "0.17.0",
    status: .reachable(version: "0.17.0")
  )
}

@MainActor
struct ConnectionFeatureTests {
  @Test func reachableThenValidTokenConnectsAndStoresToken() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac.tailnet:9119")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in okStatus() }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    // Submit/focus-loss checks immediately, pre-empting the typing debounce.
    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = .tokenOnly
      $0.serverVersion = "0.16.0"
      $0.status = .reachable(version: "0.16.0")
    }

    await store.send(\.binding.token, "secret") { $0.token = "secret" }
    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.tokenValidationResponse.success)
    await store.receive(\.delegate.connected)

    #expect(keychain.loadToken() == "secret")
    #expect(preferences.loadServerURL() == "http://mac.tailnet:9119")
  }

  @Test func unreachableServer() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "http://nope.local:1")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.unreachable }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) { $0.status = .unreachable }
  }

  /// `.offline` is a transport failure too — it lands on the same footer as `.unreachable`
  /// (which is the one that offers the setup-guide link), never a generic `.failed` (#62).
  @Test func offlineDeviceUsesTheUnreachableFooter() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "http://nope.local:1")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.offline }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) { $0.status = .unreachable }
  }

  @Test func reachableButNotHermes() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "http://something.local:80")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.decoding }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) { $0.status = .notHermes }
  }

  @Test func invalidTokenDoesNotStore() async {
    let keychain = KeychainClient.inMemory()
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac.tailnet:9119",
        token: "wrong",
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
      $0.keychain = keychain
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.tokenValidationResponse.failure) { $0.status = .invalidToken }

    #expect(keychain.loadToken() == nil)
  }

  @Test func emptyURLIsInvalid() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "   ")) {
      ConnectionFeature()
    }
    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .invalidURL }
  }

  // MARK: Auto-validation on appear (#38)

  // Onboarding appears with a pre-filled URL (logout / failed launch auto-connect): the
  // status check fires immediately — no focus/commit event needed — and the capability
  // resolves so the sign-in step unlocks.
  @Test func appearWithPrefilledURLAutoChecks() async {
    let store = TestStore(
      initialState: ConnectionFeature.State(serverURL: "http://mac.tailnet:9119")
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in okStatus() }
    }

    await store.send(.onAppear)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = .tokenOnly
      $0.serverVersion = "0.16.0"
      $0.status = .reachable(version: "0.16.0")
    }
  }

  // First launch: nothing pre-filled, nothing to check — appear is a no-op.
  @Test func appearWithEmptyURLDoesNotCheck() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "  ")) {
      ConnectionFeature()
    }
    await store.send(.onAppear)
  }

  // A re-appear (popping back from the details screen) with a completed check must not
  // re-fire and clobber the resolved status.
  @Test func appearAfterCompletedCheckDoesNotRecheck() async {
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac.tailnet:9119",
        capability: .tokenOnly,
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    }
    await store.send(.onAppear)
  }

  // MARK: Auto-validation (Task 2 — no Check button)

  @Test func editingURLResetsToIdleThenDebouncesAutoCheck() async {
    let clock = TestClock()
    let store = TestStore(
      initialState: ConnectionFeature.State(status: .reachable(version: "0.16.0"))
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.hermesREST.status = { @Sendable _ in okStatus() }
    }

    // Typing resets to idle immediately…
    await store.send(\.binding.serverURL, "mac.tailnet:9119") {
      $0.serverURL = "mac.tailnet:9119"
      $0.status = .idle
    }
    // …then auto-checks once typing pauses (debounced).
    await clock.advance(by: .milliseconds(600))
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = .tokenOnly
      $0.serverVersion = "0.16.0"
      $0.status = .reachable(version: "0.16.0")
    }
  }

  @Test func clearingURLCancelsCheckAndStaysIdle() async {
    let clock = TestClock()
    let store = TestStore(
      initialState: ConnectionFeature.State(serverURL: "x", status: .reachable(version: "0.16.0"))
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    // Emptying the field cancels any pending debounced check; no request fires.
    await store.send(\.binding.serverURL, "") {
      $0.serverURL = ""
      $0.status = .idle
    }
  }

  // MARK: Capability gating (Task 4)

  @Test func tokenOnlyServerDisablesPasswordAndPreselectsToken() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac:9119")) {
      ConnectionFeature()
    } withDependencies: {
      // No `auth_required` → token-only; providers should not even be probed.
      $0.hermesREST.status = { @Sendable _ in okStatus() }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = .tokenOnly
      $0.serverVersion = "0.16.0"
      $0.status = .reachable(version: "0.16.0")
    }

    #expect(store.state.method == .token)
    #expect(store.state.isPasswordEnabled == false)
    #expect(store.state.isTokenEnabled == true)
    #expect(store.state.isTokenDeemphasized == false)
  }

  @Test func gatedServerEnablesAndPreselectsPassword() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac:9119")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in
        ServerStatus(version: "0.16.0", authRequired: true, authProviders: ["basic"])
      }
      $0.hermesREST.authProviders = { @Sendable _ in
        [AuthProvider(name: "basic", displayName: "Username & Password", supportsPassword: true)]
      }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = passwordCapability(displayName: "Username & Password")
      $0.method = .password
      $0.serverVersion = "0.16.0"
      $0.status = .reachable(version: "0.16.0")
    }

    #expect(store.state.isPasswordEnabled == true)
    #expect(store.state.isTokenDeemphasized == true)
  }

  /// A gated server whose only providers are OAuth (and which advertises `native_pkce`)
  /// preselects the OAuth segment — the whole point of #19: this deployment was previously
  /// unreachable from mobile.
  @Test func gatedOAuthOnlyServerPreselectsOAuth() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac:9119")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in nousStatus() }
      $0.hermesREST.authProviders = { @Sendable _ in [nousProvider] }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = oauthCapability()
      $0.method = .oauth
      $0.serverVersion = "0.17.0"
      $0.status = .reachable(version: "0.17.0")
    }

    #expect(store.state.isOAuthEnabled == true)
    #expect(store.state.oauthProviders == [nousProvider])
    #expect(store.state.activeOAuthProvider == nousProvider)
    #expect(store.state.isPasswordEnabled == false)
    #expect(store.state.isTokenDeemphasized == true)
    #expect(store.state.canConnect == true) // nothing to type — the browser leg collects it
  }

  /// Mixed deployment: both segments are offered, but password stays preselected (lower
  /// friction, and it mirrors the desktop).
  @Test func mixedPasswordAndOAuthServerPreselectsPassword() async {
    let basic = AuthProvider(name: "basic", displayName: "Password", supportsPassword: true)
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac:9119")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in nousStatus(providers: ["basic", "nous"]) }
      $0.hermesREST.authProviders = { @Sendable _ in [basic, nousProvider] }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = passwordCapability(
        oauthProviders: [nousProvider],
        supportsNativeFlow: true
      )
      $0.method = .password
      $0.serverVersion = "0.17.0"
      $0.status = .reachable(version: "0.17.0")
    }

    #expect(store.state.isPasswordEnabled == true)
    #expect(store.state.isOAuthEnabled == true)
  }

  /// OAuth providers but no `native_pkce` in `auth_flows` — the gateway is too old to serve
  /// `/auth/native/authorize`, so the NEW affordance stays hidden (positive evidence only,
  /// deliberately stricter than the `?? true` unknown-capability idiom) and the screen falls
  /// back to exactly today's token-only UI.
  @Test func oauthProvidersWithoutNativeFlowKeepTheSegmentHidden() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac:9119")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in
        ServerStatus(version: "0.16.0", authRequired: true, authProviders: ["nous"])
      }
      $0.hermesREST.authProviders = { @Sendable _ in [nousProvider] }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = ServerAuthCapability(oauthProviders: [nousProvider], isGated: true)
      $0.serverVersion = "0.16.0"
      $0.status = .reachable(version: "0.16.0")
    }

    #expect(store.state.method == .token)
    #expect(store.state.isOAuthEnabled == false)
    #expect(store.state.oauthProviders.isEmpty)
    #expect(store.state.isPasswordEnabled == false)
    #expect(store.state.isTokenDeemphasized == true)
  }

  /// An unprobed server offers no OAuth segment: `nil` capability is not evidence.
  @Test func unprobedServerOffersNoOAuthSegment() {
    #expect(ConnectionFeature.State().isOAuthEnabled == false)
    #expect(ConnectionFeature.State().oauthProviders.isEmpty)
  }

  /// Gated but the providers endpoint 404s: token stays the only way in, so it must NOT be
  /// de-emphasized (the `.tokenOnly` fallback, unchanged by the struct refactor).
  @Test func gatedServerWithNoProvidersKeepsTokenUndeemphasized() async {
    let store = TestStore(initialState: ConnectionFeature.State(serverURL: "mac:9119")) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in
        ServerStatus(version: "0.16.0", authRequired: true)
      }
      $0.hermesREST.authProviders = { @Sendable _ in nil }
    }

    await store.send(.serverFieldCommitted)
    await store.receive(\.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = .tokenOnly
      $0.serverVersion = "0.16.0"
      $0.status = .reachable(version: "0.16.0")
    }

    #expect(store.state.method == .token)
    #expect(store.state.isPasswordEnabled == false)
    #expect(store.state.isTokenDeemphasized == false)
    // …and the new affordance stays off: this screen renders exactly today's token-only UI.
    #expect(store.state.isOAuthEnabled == false)
    #expect(store.state.oauthProviders.isEmpty)
  }

  @Test func passwordLoginSuccessConnectsWithCookieSession() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let activated = LockIsolated(false)
    let cookieSession = CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "mac", path: "/")],
      username: "alice",
      provider: "basic"
    )
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac:9119",
        username: "alice",
        password: "pw",
        method: .password,
        capability: passwordCapability(),
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, provider, username, _ in
        #expect(provider == "basic")
        #expect(username == "alice")
        return cookieSession
      }
      // The captured cookies must be activated into the shared jar BEFORE the validating
      // `sessions` call — otherwise the live REST transport reads an empty `.shared` and 401s.
      $0.keychain.activateCookieSession = { @Sendable session in
        #expect(session == cookieSession)
        activated.setValue(true)
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        #expect(activated.value, "cookies must be activated before the validating call")
        return []
      }
      $0.keychain.saveSession = { @Sendable in try keychain.saveSession($0) }
      $0.keychain.loadSession = { @Sendable in keychain.loadSession($0) }
      $0.preferences = preferences
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.passwordLoginResponse.success)
    await store.receive(\.delegate.connected)

    #expect(activated.value) // cookies activated into the shared jar
    // Persisted as a cookie session, not a bare token.
    #expect(keychain.loadSession(.shared) == .cookie(cookieSession))
    #expect(preferences.loadServerURL() == "http://mac:9119")
  }

  @Test func passwordLoginInvalidCredentials() async {
    let keychain = KeychainClient.inMemory()
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac:9119",
        username: "alice",
        password: "wrong",
        method: .password,
        capability: passwordCapability(),
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
      $0.keychain = keychain
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.passwordLoginResponse.failure) { $0.status = .invalidCredentials }

    #expect(keychain.loadSession(.shared) == nil)
  }

  /// Same on the token path — and via a RAW `URLError`, proving `asRESTError` classifies
  /// through the shared `RESTError(transport:)` funnel rather than a blanket `.unreachable`.
  @Test func offlineDuringTokenLoginSurfacesTheOfflineCopy() async {
    let keychain = KeychainClient.inMemory()
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac.tailnet:9119",
        token: "tok",
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        throw URLError(.notConnectedToInternet)
      }
      $0.keychain = keychain
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.tokenValidationResponse.failure) {
      $0.status = .failed(RESTError.offline.message)
    }
    #expect(keychain.loadToken() == nil)
  }

  @Test func passwordLoginRateLimitedSurfacesServerCopy() async {
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac:9119",
        username: "alice",
        password: "pw",
        method: .password,
        capability: passwordCapability(),
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.rateLimited }
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.passwordLoginResponse.failure) {
      $0.status = .failed(RESTError.rateLimited.message)
    }
  }

  @Test func passwordLoginServiceUnavailableSurfacesServerCopy() async {
    let store = TestStore(
      initialState: ConnectionFeature.State(
        serverURL: "http://mac:9119",
        username: "alice",
        password: "pw",
        method: .password,
        capability: passwordCapability(),
        status: .reachable(version: "0.16.0")
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.serviceUnavailable }
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.passwordLoginResponse.failure) {
      $0.status = .failed(RESTError.serviceUnavailable.message)
    }
  }

  // MARK: Native OAuth sign-in (#19)

  @Test func oauthSignInSeedsTheStoreValidatesThenPersistsTheBearerSession() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let tokenStore = BearerTokenStore()
    let bearer = bearerFixture()
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable url, provider in
        #expect(url.absoluteString == "http://mac:9119")
        #expect(provider == "nous")
        return bearer
      }
      $0.hermesREST.sessions = { @Sendable connection, _, _, _ in
        // The pair must be in the store BEFORE the validating call — a `.bearer` request
        // resolves its `Authorization` header through it, so an unseeded store 401s.
        let seeded = await tokenStore.current
        #expect(seeded == bearer, "the bearer pair must be seeded before the validating call")
        #expect(connection.auth == .bearer(bearer))
        #expect(connection.token == nil) // never the legacy session-token path
        return []
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.success)
    await store.receive(\.delegate.connected)

    #expect(keychain.loadSession(.shared) == .bearer(bearer))
    #expect(preferences.loadServerURL() == "http://mac:9119")
    let retained = await tokenStore.current
    #expect(retained == bearer)
  }

  /// Several providers: the tapped button decides which one the browser leg runs against.
  @Test func tappingAProviderSignsInWithThatProvider() async {
    let selfHosted = AuthProvider(
      name: "self_hosted", displayName: "Keycloak", supportsPassword: false
    )
    let bearer = bearerFixture()
    let store = TestStore(initialState: oauthReadyState(providers: [nousProvider, selfHosted])) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, provider in
        #expect(provider == "self_hosted")
        return bearer
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.keychain = KeychainClient.inMemory()
      $0.preferences = PreferencesClient.inMemory()
    }

    await store.send(.oauthProviderTapped(selfHosted)) {
      $0.selectedOAuthProviderName = "self_hosted"
    }
    await store.receive(\.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.success)
    await store.receive(\.delegate.connected)
  }

  /// Dismissing the browser sheet is a decision, not a failure: back to the reachable state
  /// (version intact) with NO status copy, and nothing persisted.
  @Test func cancellingTheBrowserSheetReturnsToReachableSilently() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in throw OAuthLoginError.cancelled }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.failure) {
      $0.status = .reachable(version: "0.17.0")
    }

    #expect(keychain.loadSession(.shared) == nil)
    #expect(preferences.loadServerURL() == nil)
    let seeded = await tokenStore.current
    #expect(seeded == nil)
    #expect(store.state.canConnect) // the segment is immediately retryable
  }

  /// Every other browser-leg failure surfaces the reason verbatim.
  @Test func aGatewayRejectionSurfacesItsReason() async {
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in
        throw OAuthLoginError.gatewayRejected("access_denied (user is not authorized)")
      }
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.failure) {
      $0.status = .failed("access_denied (user is not authorized)")
    }
  }

  @Test func aTimedOutSignInSurfacesItsCopy() async {
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in throw OAuthLoginError.timedOut }
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.failure) {
      $0.status = .failed(OAuthLoginError.timedOut.message)
    }
  }

  /// The gateway's issued code has a 120 s TTL: a user who leaves the Safari sheet parked on
  /// the consent screen long enough comes back to a `400` on `/auth/native/token`. The
  /// server's own detail is what the footer must show — not a generic "sign-in failed" —
  /// and nothing may be seeded, since the exchange never produced a pair.
  @Test func anExpiredAuthorizationCodeSurfacesTheServerCopy() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in
        throw OAuthLoginError.tokenExchange(
          .server(status: 400, detail: "invalid or expired authorization code")
        )
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.failure) {
      $0.status = .failed("invalid or expired authorization code")
    }

    let seeded = await tokenStore.current
    #expect(seeded == nil)
    #expect(keychain.loadSession(.shared) == nil)
    #expect(preferences.loadServerURL() == nil)
    #expect(store.state.canConnect) // retryable: a new code is one tap away
  }

  /// Regression guard for the retry dead-end found verifying Task 14: `.failed` is a
  /// terminal, button-disabling status for Password and Token — both have a field whose edit
  /// is the natural next move — but the OAuth segment has NOTHING to type, so a failed
  /// browser leg used to disable its provider button until the user retyped the server URL,
  /// while the footer said "Try again." Only `.oauth` may retry from `.failed`; Password and
  /// Token keep exactly their old gating, and a FAILED PROBE (which clears `capability`)
  /// still blocks every method.
  @Test func onlyTheOAuthSegmentRetriesFromAFailedStatus() {
    var oauth = oauthReadyState()
    oauth.status = .failed("Sign-in timed out. Try again.")
    #expect(oauth.canConnect)

    var password = ConnectionFeature.State(
      serverURL: "http://mac:9119",
      username: "ada",
      password: "hunter2",
      method: .password,
      capability: passwordCapability(),
      status: .failed("Too many login attempts. Try again shortly.")
    )
    #expect(password.canConnect == false)
    password.status = .invalidCredentials
    #expect(password.canConnect) // …the pre-existing retry status is untouched

    var token = ConnectionFeature.State(
      serverURL: "http://mac:9119",
      token: "tok",
      method: .token,
      capability: .tokenOnly,
      status: .failed("Server error (500).")
    )
    #expect(token.canConnect == false)
    token.status = .invalidToken
    #expect(token.canConnect)

    // A probe failure lands on `.failed` too, but it nils out `capability` — so the OAuth
    // carve-out cannot resurrect a button for a server we no longer know anything about.
    var unprobed = ConnectionFeature.State(serverURL: "http://mac:9119", method: .oauth)
    unprobed.status = .failed("Server error (500).")
    #expect(unprobed.canConnect == false)
  }

  /// The pair was minted but the server rejected it on the validating call: the half-built
  /// session must be drained from the store, or a later request would authenticate with
  /// credentials this screen never accepted.
  @Test func aRejectedBearerPairIsDrainedAndNotPersisted() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in bearerFixture() }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.failure) { $0.status = .invalidCredentials }

    let seeded = await tokenStore.current
    #expect(seeded == nil, "a rejected bearer pair must not stay seeded")
    #expect(keychain.loadSession(.shared) == nil)
    #expect(preferences.loadServerURL() == nil)
  }

  /// A non-401 failure on the validating call surfaces the REST copy and still drains.
  @Test func aValidatingCallOutageSurfacesTheServerCopyAndDrains() async {
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in bearerFixture() }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.serviceUnavailable }
      $0.bearerTokens = tokenStore
      $0.keychain = KeychainClient.inMemory()
      $0.preferences = PreferencesClient.inMemory()
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.failure) {
      $0.status = .failed(RESTError.serviceUnavailable.message)
    }

    let seeded = await tokenStore.current
    #expect(seeded == nil)
  }

  /// The validating call can rotate the pair inside the store (any gateway whose access-token
  /// lifetime is under the 120 s refresh leeway). What lands in the Keychain must be what the
  /// STORE holds, never the pre-seed local: saving the local copy would put the RETIRED
  /// refresh token back on disk, and the next launch would replay it straight into the
  /// portal's reuse detection, which revokes the whole session.
  @Test func aRotationDuringTheValidatingCallIsWhatGetsPersisted() async {
    let keychain = KeychainClient.inMemory()
    let minted = BearerSession(
      accessToken: "access-1", refreshToken: "refresh-1",
      // Already inside the store's 120 s leeway, so the validating call rotates it.
      expiresAt: Date().timeIntervalSince1970 + 10, provider: "nous", userID: "user-42"
    )
    let rotated = BearerSession(
      accessToken: "access-2", refreshToken: "refresh-2",
      expiresAt: 4_000_000_000, provider: "nous", userID: "user-42"
    )
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in minted }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        // Stands in for the live transport, which resolves `Authorization` through the store.
        _ = try await tokenStore.validAccessToken { _, _ in rotated }
        return []
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = PreferencesClient.inMemory()
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.success)
    await store.receive(\.delegate.connected)

    #expect(keychain.loadSession(.shared) == .bearer(rotated))
    #expect(await tokenStore.current == rotated)
  }

  /// An unclassified throw from the browser leg still reads like every other transport
  /// failure — `asOAuthLoginError`'s fallback is the copy a user would actually see.
  @Test func anUnclassifiedSignInFailureFallsBackToTheRESTCopy() async {
    struct Unexpected: Error {}
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in throw Unexpected() }
    }

    await store.send(.connectTapped) { $0.status = .validating }
    await store.receive(\.oauthLoginResponse.failure) {
      $0.status = .failed(OAuthLoginError.tokenExchange(RESTError(transport: Unexpected())).message)
    }
  }

  /// Editing the URL after a successful OAuth probe used to strand onboarding: the failure
  /// nils `capability`, which hides the OAuth segment AND empties the provider list, while
  /// the generic Connect button is suppressed for `.oauth` — leaving a picker with no
  /// selected tag and no way to submit. The selection has to come back off `.oauth`.
  @Test func aFailedReprobeMovesTheSelectionOffTheHiddenOAuthSegment() async {
    let store = TestStore(initialState: oauthReadyState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.unreachable }
    }

    await store.send(.checkServer) { $0.status = .checking }
    await store.receive(\.serverStatusResponse) {
      $0.capability = nil
      $0.serverVersion = nil
      $0.method = .token
      $0.status = .unreachable
    }
    #expect(store.state.isOAuthEnabled == false)
  }

  // MARK: - OAuth display predicates

  /// A single advertised provider labels the segment with its own display name; several fall
  /// back to a neutral "OAuth" that fits a segment.
  @Test func theOAuthSegmentIsLabelledWithTheProviderNameOnlyWhenThereIsExactlyOne() {
    let keycloak = AuthProvider(name: "self_hosted", displayName: "Keycloak", supportsPassword: false)
    #expect(oauthReadyState().oauthSegmentLabel == "Nous Research")
    #expect(oauthReadyState(providers: [nousProvider, keycloak]).oauthSegmentLabel == "OAuth")
    // No capability at all → no segment is rendered, but the label must stay well-defined.
    #expect(ConnectionFeature.State().oauthSegmentLabel == "OAuth")
  }

  /// The too-old-gateway hint: providers exist but `native_pkce` doesn't, so the segment is
  /// hidden and the footer has to name the providers it can't drive.
  @Test func unsupportedOAuthProvidersAreNamedOnlyWhenTheGatewayLacksTheNativeFlow() {
    let keycloak = AuthProvider(name: "self_hosted", displayName: "Keycloak", supportsPassword: false)
    var tooOld = ConnectionFeature.State(method: .token)
    tooOld.capability = oauthCapability(providers: [nousProvider], supportsNativeFlow: false)
    #expect(tooOld.hasUnsupportedOAuthProviders)
    #expect(tooOld.unsupportedOAuthProviderNames == "Nous Research")

    tooOld.capability = oauthCapability(providers: [nousProvider, keycloak], supportsNativeFlow: false)
    #expect(tooOld.unsupportedOAuthProviderNames == "Nous Research or Keycloak")

    // A gateway that DOES serve the native flow shows the segment, not the hint.
    #expect(oauthReadyState().hasUnsupportedOAuthProviders == false)
    // An unprobed server knows nothing and claims nothing.
    #expect(ConnectionFeature.State().hasUnsupportedOAuthProviders == false)
    #expect(ConnectionFeature.State().unsupportedOAuthProviderNames.isEmpty)
  }

  // MARK: - Auth picker policy

  /// The two ways "Password is unavailable" is expressed: visible-but-inert (with the whole
  /// picker disabled) when there is no OAuth segment, omitted once there is one.
  @Test func passwordIsInertWithoutOAuthAndOmittedWithIt() {
    // Unprobed: password is optimistically allowed (`?? true`), nothing is locked.
    let unprobed = ConnectionFeature.State(method: .token)
    #expect(unprobed.showsPasswordSegment)
    #expect(unprobed.locksMethodPicker == false)

    // Token-only server, no OAuth: the segment stays, the control is locked on `.token`.
    var tokenOnly = ConnectionFeature.State(method: .token)
    tokenOnly.capability = .tokenOnly
    #expect(tokenOnly.showsPasswordSegment)
    #expect(tokenOnly.locksMethodPicker)
    // …but only while `.token` is the selection — the lock exists to pin it there.
    tokenOnly.method = .password
    #expect(tokenOnly.locksMethodPicker == false)

    // OAuth available without password: the segment is omitted and the picker stays live so
    // Token ↔ provider switching works.
    let oauthOnly = ConnectionFeature.State(method: .token, capability: oauthCapability())
    #expect(oauthOnly.showsPasswordSegment == false)
    #expect(oauthOnly.locksMethodPicker == false)

    // Mixed server: every segment is offered, nothing is locked.
    var mixed = ConnectionFeature.State(method: .token)
    mixed.capability = ServerAuthCapability(
      passwordProvider: AuthProvider(name: "basic", displayName: "Basic", supportsPassword: true),
      oauthProviders: [nousProvider],
      supportsNativeFlow: true,
      isGated: true
    )
    #expect(mixed.showsPasswordSegment)
    #expect(mixed.locksMethodPicker == false)
  }

  /// The footer hint is a single capability verdict, not four overlapping view conditions.
  @Test func theMethodHintPicksOneVerdictPerCapabilityShape() {
    // The OAuth segment always reassures, whatever the capability says.
    #expect(oauthReadyState().methodHint == .oauth)
    // Password has its own fields; nothing to explain.
    var password = ConnectionFeature.State(method: .password)
    password.capability = .tokenOnly
    #expect(password.methodHint == .none)

    // Providers exist but the gateway can't drive the native flow — name them.
    var tooOld = ConnectionFeature.State(method: .token)
    tooOld.capability = oauthCapability(providers: [nousProvider], supportsNativeFlow: false)
    #expect(tooOld.methodHint == .oauthNeedsNewerAgent)

    // Token-only server: say so.
    var tokenOnly = ConnectionFeature.State(method: .token)
    tokenOnly.capability = .tokenOnly
    #expect(tokenOnly.methodHint == .tokenOnly)

    // Gated server that DOES offer password: nudge toward it.
    var gated = ConnectionFeature.State(method: .token)
    gated.capability = ServerAuthCapability(
      passwordProvider: AuthProvider(name: "basic", displayName: "Basic", supportsPassword: true),
      isGated: true
    )
    #expect(gated.methodHint == .tokenDeemphasized)

    // Unprobed server: claim nothing.
    #expect(ConnectionFeature.State(method: .token).methodHint == .none)
  }
}
