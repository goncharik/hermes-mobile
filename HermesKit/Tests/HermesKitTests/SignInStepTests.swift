import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

private let basicProvider = AuthProvider(
  name: "basic", displayName: "Password", supportsPassword: true
)

/// The OAuth (session) provider a Nous-configured gateway advertises.
private let nousProvider = AuthProvider(
  name: "nous", displayName: "Nous Research", supportsPassword: false
)

private let keycloakProvider = AuthProvider(
  name: "self_hosted", displayName: "Keycloak", supportsPassword: false
)

private func passwordCapability(
  passwordProvider: AuthProvider = basicProvider,
  oauthProviders: [AuthProvider] = [],
  supportsNativeFlow: Bool = false
) -> ServerAuthCapability {
  ServerAuthCapability(
    passwordProvider: passwordProvider,
    oauthProviders: oauthProviders,
    supportsNativeFlow: supportsNativeFlow
  )
}

private func oauthCapability(
  providers: [AuthProvider] = [nousProvider],
  supportsNativeFlow: Bool = true
) -> ServerAuthCapability {
  ServerAuthCapability(oauthProviders: providers, supportsNativeFlow: supportsNativeFlow)
}

/// A probe of `mac:9119` (or `baseURL`, e.g. the `:9119` fallback of a bare host).
private func probe(
  _ capability: ServerAuthCapability,
  typed: String = "mac:9119",
  baseURL: String = "http://mac:9119"
) -> ServerProbe {
  ServerProbe(
    address: ServerAddress(typed)!,
    baseURL: URL(string: baseURL)!,
    capability: capability,
    version: "0.17.0"
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

private func passwordState(username: String = "alice", password: String = "pw") -> SignInStep.State {
  var state = SignInStep.State(probe: probe(passwordCapability()))
  state.username = username
  state.password = password
  return state
}

private func oauthState(providers: [AuthProvider] = [nousProvider]) -> SignInStep.State {
  SignInStep.State(probe: probe(oauthCapability(providers: providers)))
}

@MainActor
struct SignInStepTests {
  // MARK: - Layout

  /// One row per capability shape in the plan's layout table.
  @Test(arguments: [
    // password + OAuth: fields first, provider buttons under "or".
    (passwordCapability(oauthProviders: [nousProvider], supportsNativeFlow: true),
     SignInStep.State.Layout.password(oauthProviders: [nousProvider]), String?.none),
    // password + OAuth too old: no buttons, but the hint names the providers.
    (passwordCapability(oauthProviders: [nousProvider], supportsNativeFlow: false),
     .password(oauthProviders: []), "Nous Research"),
    // password only.
    (passwordCapability(), .password(oauthProviders: []), nil),
    // OAuth only.
    (oauthCapability(providers: [nousProvider, keycloakProvider]),
     .oauthOnly([nousProvider, keycloakProvider]), nil),
    // OAuth only, too old: token is the way in, and the reason names the providers.
    (oauthCapability(providers: [nousProvider, keycloakProvider], supportsNativeFlow: false),
     .token(reason: .oauthNeedsNewerAgent),
     "Nous Research or Keycloak"),
    // Not gated (token-only server).
    (.tokenOnly, .token(reason: .tokenOnlyServer), nil),
    // Native flow advertised but no OAuth provider: still no buttons (positive evidence).
    (ServerAuthCapability(supportsNativeFlow: true),
     .token(reason: .tokenOnlyServer), nil),
  ] as [(ServerAuthCapability, SignInStep.State.Layout, String?)])
  func layoutFollowsTheCapability(
    capability: ServerAuthCapability,
    layout: SignInStep.State.Layout,
    needsNewerAgentFor: String?
  ) {
    let state = SignInStep.State(probe: probe(capability))
    #expect(state.layout == layout)
    #expect(state.oauthNeedsNewerAgentFor == needsNewerAgentFor)
  }

  @Test func oauthProvidersAreOfferedOnlyWithPositiveEvidence() {
    #expect(oauthState().oauthProviders == [nousProvider])
    #expect(
      SignInStep.State(probe: probe(passwordCapability(oauthProviders: [nousProvider], supportsNativeFlow: true)))
        .oauthProviders == [nousProvider]
    )
    #expect(
      SignInStep.State(probe: probe(oauthCapability(supportsNativeFlow: false))).oauthProviders.isEmpty
    )
    #expect(SignInStep.State(probe: probe(.tokenOnly)).oauthProviders.isEmpty)
  }

  /// The server card's method summary, one row per layout shape (prototype `methodSummary`).
  @Test(arguments: [
    (passwordCapability(oauthProviders: [nousProvider], supportsNativeFlow: true),
     "Password or Nous Research"),
    (passwordCapability(oauthProviders: [nousProvider], supportsNativeFlow: false), "Password"),
    (passwordCapability(), "Password"),
    (oauthCapability(providers: [nousProvider, keycloakProvider]), "Nous Research, Keycloak"),
    (oauthCapability(supportsNativeFlow: false), "Session token"),
    (.tokenOnly, "Session token"),
  ] as [(ServerAuthCapability, String)])
  func methodSummaryFollowsTheLayout(capability: ServerAuthCapability, summary: String) {
    #expect(SignInStep.State(probe: probe(capability)).methodSummary == summary)
  }

  @Test func oauthProviderNamesJoinTheOfferedProviders() {
    #expect(oauthState(providers: [nousProvider, keycloakProvider]).oauthProviderNames == "Nous Research or Keycloak")
    #expect(SignInStep.State(probe: probe(.tokenOnly)).oauthProviderNames.isEmpty)
  }

  /// Every attempt and its 401 verdict carry the method that made it, so the view puts the
  /// copy and the red outline on that method's fields only.
  @Test func eachVerdictNamesTheMethodThatEarnedIt() async {
    var state = SignInStep.State(
      probe: probe(passwordCapability(oauthProviders: [nousProvider], supportsNativeFlow: true))
    )
    state.username = "alice"
    state.password = "wrong"
    state.isShowingOtherWays = true
    state.token = "tok"
    let store = TestStore(initialState: state) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in throw RESTError.unauthorized }
      $0.oauthLogin.signIn = { @Sendable _, _ in bearerFixture() }
      $0.bearerTokens = BearerTokenStore()
      $0.keychain = .inMemory()
    }

    await store.send(.passwordSignInButtonTapped) { $0.status = .validating(.password) }
    await store.receive(\.passwordLoginResponse.failure) { $0.status = .invalidCredentials(.password) }

    await store.send(.tokenSignInButtonTapped) { $0.status = .validating(.token) }
    await store.receive(\.tokenValidationResponse.failure) { $0.status = .invalidCredentials(.token) }

    await store.send(.oauthProviderButtonTapped(nousProvider)) { $0.status = .validating(.oauth) }
    await store.receive(\.oauthLoginResponse.failure) { $0.status = .invalidCredentials(.oauth) }
  }

  @Test func prefilledTokenSeedsTheTokenField() {
    #expect(SignInStep.State(probe: probe(.tokenOnly), prefilledToken: "tok").token == "tok")
    #expect(SignInStep.State(probe: probe(.tokenOnly), prefilledToken: nil).token.isEmpty)
    #expect(SignInStep.State(probe: probe(.tokenOnly)).token.isEmpty)
  }

  // MARK: - Submit gating

  @Test func passwordLayoutSubmitsOnceBothFieldsAreFilled() {
    var state = passwordState(username: "", password: "")
    #expect(state.canSignInWithPassword == false)
    state.username = "alice"
    #expect(state.canSignInWithPassword == false)
    state.password = "pw"
    #expect(state.canSignInWithPassword)
    state.status = .validating(.password)
    #expect(state.canSignInWithPassword == false)
    // A finished attempt never blocks a retry, whatever its verdict.
    for status: SignInStep.State.Status in [
      .invalidCredentials(.password), .failed("Too many attempts."), .idle,
    ] {
      state.status = status
      #expect(state.canSignInWithPassword)
    }
  }

  @Test func oauthOnlyLayoutSubmitsWithNothingToType() {
    var state = oauthState()
    #expect(state.canSignInWithOAuth)
    #expect(state.canSignInWithPassword == false)
    state.status = .validating(.oauth)
    #expect(state.canSignInWithOAuth == false)
    state.status = .failed("Sign-in timed out. Try again.")
    #expect(state.canSignInWithOAuth)
  }

  @Test func tokenLayoutSubmitsOnceATokenIsEntered() {
    var state = SignInStep.State(probe: probe(.tokenOnly))
    #expect(state.showsTokenField)
    #expect(state.canSignInWithToken == false)
    state.token = "tok"
    #expect(state.canSignInWithToken)
    #expect(state.canSignInWithPassword == false)
    #expect(state.canSignInWithOAuth == false)
    state.status = .validating(.token)
    #expect(state.canSignInWithToken == false)
    state.status = .invalidCredentials(.token)
    #expect(state.canSignInWithToken)
  }

  /// In the non-token layouts the token is reachable only behind "Other ways to sign in".
  @Test func theTokenIsSubmittableOnlyOnceOtherWaysIsOpen() {
    var state = passwordState()
    state.token = "tok"
    #expect(state.showsTokenField == false)
    #expect(state.canSignInWithToken == false)
    state.isShowingOtherWays = true
    #expect(state.showsTokenField)
    #expect(state.canSignInWithToken)
  }

  /// The reducer enforces its own submit rules: a tap the view's `.disabled` didn't catch (a
  /// second tap before the button disables) starts nothing. The default `testValue` clients
  /// fail the test if any request goes out.
  @Test func passwordSignInIsANoOpWhenDisabled() async {
    var inFlight = passwordState()
    inFlight.status = .validating(.password)
    var tokenLayout = SignInStep.State(probe: probe(.tokenOnly))
    tokenLayout.username = "alice"
    tokenLayout.password = "pw"
    // Empty password; an attempt already in flight; not the password layout.
    for state in [passwordState(password: ""), inFlight, tokenLayout] {
      #expect(state.canSignInWithPassword == false)
      let store = TestStore(initialState: state) { SignInStep() }
      await store.send(.passwordSignInButtonTapped)
    }
  }

  @Test func tokenSignInIsANoOpWhenDisabled() async {
    var inFlight = SignInStep.State(probe: probe(.tokenOnly), prefilledToken: "tok")
    inFlight.status = .validating(.token)
    var hiddenField = passwordState()
    hiddenField.token = "tok"
    // No token typed; an attempt already in flight; the field still behind "Other ways".
    for state in [SignInStep.State(probe: probe(.tokenOnly)), inFlight, hiddenField] {
      #expect(state.canSignInWithToken == false)
      let store = TestStore(initialState: state) { SignInStep() }
      await store.send(.tokenSignInButtonTapped)
    }
  }

  @Test func otherWaysTogglesTheTokenDisclosure() async {
    let store = TestStore(initialState: oauthState()) { SignInStep() }
    await store.send(.otherWaysButtonTapped) { $0.isShowingOtherWays = true }
    await store.send(.otherWaysButtonTapped) { $0.isShowingOtherWays = false }
  }

  @Test func changePopsBackToTheServerStep() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }
    await store.send(.changeServerButtonTapped)
    await store.finish()
    #expect(dismissed.value)
  }

  // MARK: - Token

  @Test func validTokenConnectsAndStoresToken() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(initialState: SignInStep.State(probe: probe(.tokenOnly))) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable connection, limit, _, _, _ in
        #expect(limit == 1)
        #expect(connection.token == "secret")
        return []
      }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(\.binding.token, "secret") { $0.token = "secret" }
    await store.send(.tokenSignInButtonTapped) { $0.status = .validating(.token) }
    await store.receive(\.tokenValidationResponse.success)
    await store.receive(\.delegate.connected)

    // Byte-identical to the legacy path: a bare token in the Keychain, the URL in prefs.
    #expect(keychain.loadSession(.shared) == .token("secret"))
    #expect(keychain.loadToken() == "secret")
    #expect(preferences.loadServerURL() == "http://mac:9119")
  }

  /// A bare host answered on the `:9119` fallback: the URL that answered is what's saved.
  @Test func theFallbackPortURLIsWhatGetsSaved() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let state = SignInStep.State(
      probe: probe(.tokenOnly, typed: "mac", baseURL: "http://mac:9119"),
      prefilledToken: "secret"
    )
    let store = TestStore(initialState: state) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable connection, _, _, _, _ in
        #expect(connection.baseURL.absoluteString == "http://mac:9119")
        return []
      }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.tokenSignInButtonTapped) { $0.status = .validating(.token) }
    await store.receive(\.tokenValidationResponse.success)
    await store.receive(\.delegate.connected)
    #expect(preferences.loadServerURL() == "http://mac:9119")
  }

  @Test func invalidTokenDoesNotStore() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(
      initialState: SignInStep.State(probe: probe(.tokenOnly), prefilledToken: "wrong")
    ) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in throw RESTError.unauthorized }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.tokenSignInButtonTapped) { $0.status = .validating(.token) }
    await store.receive(\.tokenValidationResponse.failure) { $0.status = .invalidCredentials(.token) }

    #expect(keychain.loadToken() == nil)
    #expect(preferences.loadServerURL() == nil)
  }

  /// Via a RAW `URLError`, proving `asRESTError` classifies through the shared
  /// `RESTError(transport:)` funnel rather than a blanket `.unreachable`.
  @Test func offlineDuringTokenSignInSurfacesTheOfflineCopy() async {
    let keychain = KeychainClient.inMemory()
    let store = TestStore(
      initialState: SignInStep.State(probe: probe(.tokenOnly), prefilledToken: "tok")
    ) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in
        throw URLError(.notConnectedToInternet)
      }
      $0.keychain = keychain
    }

    await store.send(.tokenSignInButtonTapped) { $0.status = .validating(.token) }
    await store.receive(\.tokenValidationResponse.failure) {
      $0.status = .failed(RESTError.offline.message)
    }
    #expect(keychain.loadToken() == nil)
  }

  // MARK: - Password

  @Test func passwordLoginSuccessConnectsWithCookieSession() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let activated = LockIsolated(false)
    let cookieSession = CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "mac", path: "/")],
      username: "alice",
      provider: "basic"
    )
    let store = TestStore(initialState: passwordState()) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable url, provider, username, password in
        #expect(url.absoluteString == "http://mac:9119")
        #expect(provider == "basic")
        #expect(username == "alice")
        #expect(password == "pw")
        return cookieSession
      }
      // The captured cookies must be activated into the shared jar BEFORE the validating
      // `sessions` call — otherwise the live REST transport reads an empty `.shared` and 401s.
      $0.keychain.activateCookieSession = { @Sendable session in
        #expect(session == cookieSession)
        activated.setValue(true)
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in
        #expect(activated.value, "cookies must be activated before the validating call")
        return []
      }
      $0.keychain.saveSession = { @Sendable in try keychain.saveSession($0) }
      $0.keychain.loadSession = { @Sendable in keychain.loadSession($0) }
      $0.preferences = preferences
    }

    await store.send(.passwordSignInButtonTapped) { $0.status = .validating(.password) }
    await store.receive(\.passwordLoginResponse.success)
    await store.receive(\.delegate.connected)

    #expect(activated.value)
    // Persisted as a cookie session, not a bare token.
    #expect(keychain.loadSession(.shared) == .cookie(cookieSession))
    #expect(preferences.loadServerURL() == "http://mac:9119")
  }

  @Test func passwordLoginInvalidCredentials() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(initialState: passwordState(password: "wrong")) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.passwordSignInButtonTapped) { $0.status = .validating(.password) }
    await store.receive(\.passwordLoginResponse.failure) { $0.status = .invalidCredentials(.password) }

    #expect(keychain.loadSession(.shared) == nil)
    #expect(preferences.loadServerURL() == nil)
  }

  /// The login goes to the provider the server advertised, not a hard-coded "basic".
  @Test func passwordLoginUsesTheProbedProviderName() async {
    let pam = AuthProvider(name: "pam", displayName: "System account", supportsPassword: true)
    var state = SignInStep.State(probe: probe(passwordCapability(passwordProvider: pam)))
    state.username = "alice"
    state.password = "pw"
    let usedProvider = LockIsolated<String?>(nil)
    let store = TestStore(initialState: state) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, provider, _, _ in
        usedProvider.setValue(provider)
        throw RESTError.unauthorized
      }
    }

    await store.send(.passwordSignInButtonTapped) { $0.status = .validating(.password) }
    await store.receive(\.passwordLoginResponse.failure) { $0.status = .invalidCredentials(.password) }
    #expect(usedProvider.value == "pam")
  }

  /// Cookies issued, then rejected by the validating call: same verdict, nothing persisted.
  @Test func rejectedCookiesAreInvalidCredentials() async {
    let keychain = KeychainClient.inMemory()
    let store = TestStore(initialState: passwordState()) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in
        CookieSession(cookies: [], username: "alice", provider: "basic")
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in throw RESTError.unauthorized }
      $0.keychain.activateCookieSession = { @Sendable _ in }
      $0.keychain.saveSession = { @Sendable in try keychain.saveSession($0) }
    }

    await store.send(.passwordSignInButtonTapped) { $0.status = .validating(.password) }
    await store.receive(\.passwordLoginResponse.failure) { $0.status = .invalidCredentials(.password) }
    #expect(keychain.loadSession(.shared) == nil)
  }

  @Test func passwordLoginRateLimitedSurfacesServerCopy() async {
    let store = TestStore(initialState: passwordState()) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.rateLimited }
    }

    await store.send(.passwordSignInButtonTapped) { $0.status = .validating(.password) }
    await store.receive(\.passwordLoginResponse.failure) {
      $0.status = .failed(RESTError.rateLimited.message)
    }
  }

  @Test func passwordLoginServiceUnavailableSurfacesServerCopy() async {
    let store = TestStore(initialState: passwordState()) {
      SignInStep()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.serviceUnavailable }
    }

    await store.send(.passwordSignInButtonTapped) { $0.status = .validating(.password) }
    await store.receive(\.passwordLoginResponse.failure) {
      $0.status = .failed(RESTError.serviceUnavailable.message)
    }
  }

  // MARK: - OAuth (#19)

  @Test func oauthSignInSeedsTheStoreValidatesThenPersistsTheBearerSession() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let tokenStore = BearerTokenStore()
    let bearer = bearerFixture()
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable url, provider in
        #expect(url.absoluteString == "http://mac:9119")
        #expect(provider == "nous")
        return bearer
      }
      $0.hermesREST.sessions = { @Sendable connection, _, _, _, _ in
        // The pair must be in the store BEFORE the validating call.
        let seeded = tokenStore.current
        #expect(seeded == bearer, "the bearer pair must be seeded before the validating call")
        #expect(connection.auth == .bearer(bearer))
        #expect(connection.token == nil) // never the legacy session-token path
        return []
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.success)
    await store.receive(\.delegate.connected)

    #expect(keychain.loadSession(.shared) == .bearer(bearer))
    #expect(preferences.loadServerURL() == "http://mac:9119")
    let retained = tokenStore.current
    #expect(retained == bearer)
  }

  /// Several providers: the tapped button decides which one the browser leg runs against.
  @Test func tappingAProviderSignsInWithThatProvider() async {
    let store = TestStore(initialState: oauthState(providers: [nousProvider, keycloakProvider])) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, provider in
        #expect(provider == "self_hosted")
        return bearerFixture()
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.bearerTokens = BearerTokenStore()
      $0.keychain = KeychainClient.inMemory()
      $0.preferences = PreferencesClient.inMemory()
    }

    await store.send(.oauthProviderButtonTapped(keycloakProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.success)
    await store.receive(\.delegate.connected)
  }

  /// A provider this step does not offer (a too-old gateway) never starts a browser leg.
  @Test func anUnofferedProviderIsIgnored() async {
    let state = SignInStep.State(probe: probe(oauthCapability(supportsNativeFlow: false)))
    let store = TestStore(initialState: state) { SignInStep() }
    await store.send(.oauthProviderButtonTapped(nousProvider))
  }

  /// Dismissing the browser sheet is a decision, not a failure: back to idle with NO status
  /// copy, nothing persisted, and the button immediately retryable.
  @Test func cancellingTheBrowserSheetReturnsToIdleSilently() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in throw OAuthLoginError.cancelled }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.failure) { $0.status = .idle }

    #expect(keychain.loadSession(.shared) == nil)
    #expect(preferences.loadServerURL() == nil)
    let seeded = tokenStore.current
    #expect(seeded == nil)
    #expect(store.state.canSignInWithOAuth)
  }

  @Test(arguments: [
    (OAuthLoginError.gatewayRejected("access_denied (user is not authorized)"),
     "access_denied (user is not authorized)"),
    (.timedOut, OAuthLoginError.timedOut.message),
    // The 120 s code TTL: the server's own detail, not a generic "sign-in failed".
    (.tokenExchange(.server(status: 400, detail: "invalid or expired authorization code")),
     "invalid or expired authorization code"),
  ])
  func aBrowserLegFailureSurfacesItsCopy(error: OAuthLoginError, message: String) async {
    let keychain = KeychainClient.inMemory()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in throw error }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.failure) { $0.status = .failed(message) }

    let seeded = tokenStore.current
    #expect(seeded == nil)
    #expect(keychain.loadSession(.shared) == nil)
    #expect(store.state.canSignInWithOAuth) // retryable: nothing to type
  }

  /// The pair was minted but the server rejected it on the validating call: drained, not
  /// persisted, and reported as invalid credentials.
  @Test func aRejectedBearerPairIsInvalidCredentialsAndDrained() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in bearerFixture() }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in throw RESTError.unauthorized }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.failure) { $0.status = .invalidCredentials(.oauth) }

    let seeded = tokenStore.current
    #expect(seeded == nil, "a rejected bearer pair must not stay seeded")
    #expect(keychain.loadSession(.shared) == nil)
    #expect(preferences.loadServerURL() == nil)
  }

  @Test func aValidatingCallOutageSurfacesTheServerCopyAndDrains() async {
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in bearerFixture() }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in throw RESTError.serviceUnavailable }
      $0.bearerTokens = tokenStore
      $0.keychain = KeychainClient.inMemory()
      $0.preferences = PreferencesClient.inMemory()
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.failure) {
      $0.status = .failed(RESTError.serviceUnavailable.message)
    }
    let seeded = tokenStore.current
    #expect(seeded == nil)
  }

  /// A second provider tap supersedes the first attempt. The abandoned one must neither land
  /// nor drain the store on its way out — the pair it would take down is the new attempt's.
  @Test func aSupersedingProviderTapNeitherLandsNorDrainsTheNewAttemptsPair() async {
    let keychain = KeychainClient.inMemory()
    let abandoned = bearerFixture(accessToken: "abandoned")
    let winner = bearerFixture(accessToken: "winner")
    let attempts = LockIsolated(0)
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in
        let attempt = attempts.withValue { count -> Int in
          defer { count += 1 }
          return count
        }
        return attempt == 0 ? abandoned : winner
      }
      $0.hermesREST.sessions = { @Sendable connection, _, _, _, _ in
        guard connection.auth == .bearer(abandoned) else { return [] }
        // The first attempt is still validating when the second tap arrives.
        try await Task.sleep(for: .seconds(60))
        return []
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = PreferencesClient.inMemory()
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.send(.oauthProviderButtonTapped(nousProvider)) // cancels the first
    await store.receive(\.oauthLoginResponse.success)
    await store.receive(\.delegate.connected)

    #expect(tokenStore.current == winner, "the cancelled attempt drained the live pair")
    #expect(keychain.loadSession(.shared) == .bearer(winner))
  }

  /// The validating call can rotate the pair inside the store: what lands in the Keychain is
  /// what the STORE holds, never the pre-seed local (the retired refresh token).
  @Test func aRotationDuringTheValidatingCallIsWhatGetsPersisted() async {
    let keychain = KeychainClient.inMemory()
    let minted = BearerSession(
      accessToken: "access-1", refreshToken: "refresh-1",
      expiresAt: Date().timeIntervalSince1970 + 10, provider: "nous", userID: "user-42"
    )
    let rotated = BearerSession(
      accessToken: "access-2", refreshToken: "refresh-2",
      expiresAt: 4_000_000_000, provider: "nous", userID: "user-42"
    )
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in minted }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in
        _ = try await tokenStore.validAccessToken { _, _ in rotated }
        return []
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = PreferencesClient.inMemory()
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.success)
    await store.receive(\.delegate.connected)

    #expect(keychain.loadSession(.shared) == .bearer(rotated))
    #expect(tokenStore.current == rotated)
  }

  /// A rotation during the validating call may only reach the Keychain once that call has
  /// SUCCEEDED: a rejected sign-in must not leave a restorable bearer session behind.
  @Test func aRotationBeforeARejectedValidationIsNeverPersisted() async {
    let keychain = KeychainClient.inMemory()
    let minted = BearerSession(
      accessToken: "access-1", refreshToken: "refresh-1",
      // Inside the store's 120 s leeway, so the validating call rotates it first.
      expiresAt: Date().timeIntervalSince1970 + 10, provider: "nous", userID: "user-42"
    )
    let rotated = BearerSession(
      accessToken: "access-2", refreshToken: "refresh-2",
      expiresAt: 4_000_000_000, provider: "nous", userID: "user-42"
    )
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in minted }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in
        // The live transport resolves `Authorization` through the store — which rotates —
        // and only then does the server reject the identity.
        _ = try await tokenStore.validAccessToken { _, _ in rotated }
        throw RESTError.unauthorized
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = PreferencesClient.inMemory()
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.failure) { $0.status = .invalidCredentials(.oauth) }

    #expect(
      keychain.loadSession(.shared) == nil,
      "a rejected sign-in left a restorable bearer session in the Keychain"
    )
    #expect(tokenStore.current == nil)
  }

  /// An unclassified throw from the browser leg still reads like every other transport
  /// failure — `asOAuthLoginError`'s fallback is the copy a user would actually see.
  @Test func anUnclassifiedSignInFailureFallsBackToTheRESTCopy() async {
    struct Unexpected: Error {}
    let store = TestStore(initialState: oauthState()) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in throw Unexpected() }
      $0.bearerTokens = BearerTokenStore()
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.failure) {
      $0.status = .failed(OAuthLoginError.tokenExchange(RESTError(transport: Unexpected())).message)
    }
  }

  /// Signing in against the `:9119` fallback runs the browser leg there and saves that URL.
  @Test func oauthRunsAgainstTheURLThatAnswered() async {
    let preferences = PreferencesClient.inMemory()
    let state = SignInStep.State(
      probe: probe(oauthCapability(), typed: "mac", baseURL: "http://mac:9119")
    )
    let store = TestStore(initialState: state) {
      SignInStep()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable url, _ in
        #expect(url.absoluteString == "http://mac:9119")
        return bearerFixture()
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.bearerTokens = BearerTokenStore()
      $0.keychain = KeychainClient.inMemory()
      $0.preferences = preferences
    }

    await store.send(.oauthProviderButtonTapped(nousProvider)) {
      $0.status = .validating(.oauth)
    }
    await store.receive(\.oauthLoginResponse.success)
    await store.receive(\.delegate.connected)
    #expect(preferences.loadServerURL() == "http://mac:9119")
  }
}
