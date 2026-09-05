import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ReauthFeatureTests {
  private let url = URL(string: "http://mac.tailnet:9119")!

  private func cookieSession(username: String) -> CookieSession {
    CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "mac.tailnet", path: "/")],
      username: username,
      provider: "basic"
    )
  }

  // MARK: - Pure identity-compare helper

  @Test func identityCompareNormalizesCaseAndWhitespace() {
    #expect(isSameUser("alice", "alice"))
    #expect(isSameUser("Alice", "alice"))
    #expect(isSameUser("  alice ", "alice"))
    #expect(isSameUser("", ""))
    #expect(!isSameUser("alice", "bob"))
    #expect(!isSameUser("alice", ""))
  }

  // MARK: - Password re-auth → same user

  @Test func passwordReauthSameUserBubblesReauthenticated() async {
    let session = cookieSession(username: "alice")
    let activated = LockIsolated(false)
    let store = TestStore(
      initialState: ReauthFeature.State(
        serverURL: url, method: .password, provider: "basic", previousUsername: "alice"
      )
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in session }
      // The fresh rotated cookies must be activated into the shared jar BEFORE validating —
      // otherwise the validating call would send the stale (expired) cookies.
      $0.keychain.activateCookieSession = { @Sendable s in
        #expect(s == session)
        activated.setValue(true)
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        #expect(activated.value, "cookies must be activated before the validating call")
        return []
      }
    }

    await store.send(.binding(.set(\.password, "pw"))) { $0.password = "pw" }
    await store.send(.signInTapped) { $0.status = .validating }

    let expected = ServerConnection(baseURL: url, auth: .cookie(session))
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: true))
    #expect(activated.value)
  }

  @Test func passwordReauthDifferentUserReportsNotSameUser() async {
    // The re-login authenticated as "bob", not the expired "alice" — sameUser must be false.
    let session = cookieSession(username: "bob")
    let store = TestStore(
      initialState: ReauthFeature.State(
        serverURL: url, method: .password, provider: "basic",
        previousUsername: "alice", username: "bob", password: "pw"
      )
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in session }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    let expected = ServerConnection(baseURL: url, auth: .cookie(session))
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: false))
  }

  @Test func badCredentialsSurfaceInvalidCredentials() async {
    let store = TestStore(
      initialState: ReauthFeature.State(
        serverURL: url, method: .password, provider: "basic",
        previousUsername: "alice", username: "alice", password: "wrong"
      )
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    await store.receive(\.reauthResponse.failure) { $0.status = .invalidCredentials }
  }

  @Test func rateLimitedSurfacesServerCopy() async {
    let store = TestStore(
      initialState: ReauthFeature.State(
        serverURL: url, method: .password, provider: "basic",
        previousUsername: "alice", username: "alice", password: "pw"
      )
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.passwordLogin = { @Sendable _, _, _, _ in throw RESTError.rateLimited }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    await store.receive(\.reauthResponse.failure) {
      $0.status = .failed(RESTError.rateLimited.message)
    }
  }

  // MARK: - Token re-auth parity (identity compare skipped)

  @Test func tokenReauthValidatesAndReportsSameUser() async {
    let store = TestStore(
      initialState: ReauthFeature.State(serverURL: url, method: .token, token: "newtok")
    ) {
      ReauthFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    let expected = ServerConnection(baseURL: url, token: "newtok")
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: true))
  }

  // MARK: - Native OAuth re-auth (#19)

  private func bearer(userID: String, accessToken: String = "access-2") -> BearerSession {
    BearerSession(
      accessToken: accessToken,
      refreshToken: "refresh-2",
      expiresAt: 4_000_000_000,
      provider: "nous",
      userID: userID
    )
  }

  private func oauthState(
    previousUserID: String = "user-42",
    status: ReauthFeature.State.Status = .idle
  ) -> ReauthFeature.State {
    ReauthFeature.State(
      serverURL: url,
      method: .oauth,
      provider: "nous",
      providerDisplayName: "Nous Research",
      previousUserID: previousUserID,
      status: status
    )
  }

  /// The whole point of the bearer re-auth path: the browser leg mints a fresh pair, it is
  /// seeded BEFORE the validating call (the dead pair is still in the store), persisted, and
  /// the token payload's `user_id` — not a username — decides that this is the same user.
  @Test func oauthReauthSeedsValidatesAndReportsSameUser() async {
    let keychain = KeychainClient.inMemory()
    let tokenStore = BearerTokenStore()
    let fresh = bearer(userID: "user-42")
    let serverURL = url
    // The dead pair the expired session left behind.
    await tokenStore.seed(
      bearer(userID: "user-42", accessToken: "expired"), baseURL: url, persist: { _ in }
    )
    let store = TestStore(initialState: oauthState()) {
      ReauthFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable signInURL, provider in
        #expect(signInURL == serverURL)
        #expect(provider == "nous")
        return fresh
      }
      $0.hermesREST.sessions = { @Sendable connection, _, _, _ in
        let seeded = await tokenStore.current
        #expect(seeded == fresh, "the fresh pair must replace the dead one before validating")
        #expect(connection.auth == .bearer(fresh))
        #expect(connection.token == nil) // never the legacy session-token path
        return []
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
    }

    await store.send(.signInTapped) { $0.status = .validating }
    let expected = ServerConnection(baseURL: url, auth: .bearer(fresh))
    await store.receive(\.oauthResponse.success)
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: true))

    #expect(keychain.loadSession(.shared) == .bearer(fresh))
    let retained = await tokenStore.current
    #expect(retained == fresh)
  }

  /// A different `user_id` in the fresh token payload is an account switch — getting this
  /// wrong would cross-contaminate two accounts' sessions.
  @Test func oauthReauthWithADifferentUserIDReportsNotSameUser() async {
    let fresh = bearer(userID: "user-99")
    let store = TestStore(initialState: oauthState(previousUserID: "user-42")) {
      ReauthFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in fresh }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.bearerTokens = BearerTokenStore()
      $0.keychain = KeychainClient.inMemory()
    }

    await store.send(.signInTapped) { $0.status = .validating }
    let expected = ServerConnection(baseURL: url, auth: .bearer(fresh))
    await store.receive(\.oauthResponse.success)
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: false))
  }

  /// `user_id` is one of the fields the lenient token decode lets a gateway omit. Two unknown
  /// identities are NOT a match: reading empty-vs-empty as "same user" would resume the
  /// previous account's chat in place — pins, seen counts and selected profile intact — after
  /// someone signed in as a different account. Unknown routes as a switch, which is the
  /// recoverable direction.
  @Test func oauthReauthWithNoUserIDOnEitherSideRoutesAsAUserSwitch() async {
    let fresh = bearer(userID: "")
    let store = TestStore(initialState: oauthState(previousUserID: "")) {
      ReauthFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in fresh }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
      $0.bearerTokens = BearerTokenStore()
      $0.keychain = KeychainClient.inMemory()
    }

    await store.send(.signInTapped) { $0.status = .validating }
    let expected = ServerConnection(baseURL: url, auth: .bearer(fresh))
    await store.receive(\.oauthResponse.success)
    await store.receive(\.reauthResponse.success)
    await store.receive(\.delegate, .reauthenticated(connection: expected, sameUser: false))
  }

  /// The identity compare is per-regime: a cookie session's username is typed and never
  /// empty, so it keeps the plain equality; the bearer `user_id` may be absent.
  @Test func theBearerIdentityCompareTreatsAnEmptyIDAsUnknown() {
    #expect(isSameBearerUser(previous: "user-42", fresh: "USER-42 "))
    #expect(isSameBearerUser(previous: "user-42", fresh: "user-99") == false)
    #expect(isSameBearerUser(previous: "", fresh: "") == false)
    #expect(isSameBearerUser(previous: "user-42", fresh: "") == false)
    #expect(isSameBearerUser(previous: "  ", fresh: "user-42") == false)
    // Unchanged for the cookie regime.
    #expect(isSameUser("Ada", "ada "))
  }

  /// Dismissing the browser sheet is a decision, not a failure: no status copy, no delegate —
  /// the re-auth sheet stays up so the user can retry or take "Quit to start".
  @Test func cancellingTheBrowserSheetReturnsToIdleSilently() async {
    let keychain = KeychainClient.inMemory()
    let tokenStore = BearerTokenStore()
    let store = TestStore(initialState: oauthState()) {
      ReauthFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in throw OAuthLoginError.cancelled }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
    }

    await store.send(.signInTapped) { $0.status = .validating }
    await store.receive(\.oauthResponse.failure) { $0.status = .idle }

    #expect(keychain.loadSession(.shared) == nil)
    let seeded = await tokenStore.current
    #expect(seeded == nil)
    #expect(store.state.canSubmit) // immediately retryable
  }

  @Test func oauthGatewayRejectionSurfacesItsReason() async {
    let store = TestStore(initialState: oauthState()) {
      ReauthFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in
        throw OAuthLoginError.gatewayRejected("access_denied (user is not authorized)")
      }
    }

    await store.send(.signInTapped) { $0.status = .validating }
    await store.receive(\.oauthResponse.failure) {
      $0.status = .failed("access_denied (user is not authorized)")
    }
  }

  /// A fresh pair the server refuses on the validating call: `.invalidCredentials`, and the
  /// half-built session must not stay seeded.
  @Test func aRejectedFreshBearerPairIsDrainedAndNotPersisted() async {
    let keychain = KeychainClient.inMemory()
    let tokenStore = BearerTokenStore()
    let fresh = bearer(userID: "user-42")
    let store = TestStore(initialState: oauthState()) {
      ReauthFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in fresh }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
    }

    await store.send(.signInTapped) { $0.status = .validating }
    await store.receive(\.oauthResponse.failure) { $0.status = .invalidCredentials }

    let seeded = await tokenStore.current
    #expect(seeded == nil, "a rejected bearer pair must not stay seeded")
    #expect(keychain.loadSession(.shared) == nil)
  }

  @Test func aValidatingOutageDuringOAuthReauthSurfacesTheServerCopy() async {
    let tokenStore = BearerTokenStore()
    let fresh = bearer(userID: "user-42")
    let store = TestStore(initialState: oauthState()) {
      ReauthFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in fresh }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.serviceUnavailable }
      $0.bearerTokens = tokenStore
      $0.keychain = KeychainClient.inMemory()
    }

    await store.send(.signInTapped) { $0.status = .validating }
    await store.receive(\.oauthResponse.failure) {
      $0.status = .failed(RESTError.serviceUnavailable.message)
    }

    let seeded = await tokenStore.current
    #expect(seeded == nil)
  }

  /// Nothing to type, so the OAuth button is enabled whenever a sign-in is not already
  /// running — and the label falls back to the wire provider name without a display name.
  @Test func oauthSubmitGatingAndProviderLabel() {
    #expect(oauthState().canSubmit)
    #expect(!oauthState(status: .validating).canSubmit)
    #expect(oauthState(status: .invalidCredentials).canSubmit)
    #expect(oauthState().providerLabel == "Nous Research")
    #expect(
      ReauthFeature.State(serverURL: url, method: .oauth, provider: "nous").providerLabel == "nous"
    )
  }

  // MARK: - Quit

  @Test func quitBubblesQuitDelegate() async {
    let store = TestStore(
      initialState: ReauthFeature.State(serverURL: url, method: .password, previousUsername: "alice")
    ) {
      ReauthFeature()
    }

    await store.send(.quitTapped)
    await store.receive(\.delegate.quit)
  }
}
