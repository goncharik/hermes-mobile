import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// The OAuth (session) provider a Nous-configured gateway advertises.
private let nousProvider = AuthProvider(
  name: "nous", displayName: "Nous Research", supportsPassword: false
)

private let tokenOnlyStatus = ServerStatus(version: "0.17.0")

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

/// What the Server step reports for `typed` on a token-only server that answered at `baseURL`.
private func tokenOnlyProbe(
  typed: String = "mac:9119",
  baseURL: String = "http://mac:9119"
) -> ServerProbe {
  ServerProbe(
    address: ServerAddress(typed)!,
    baseURL: URL(string: baseURL)!,
    capability: .tokenOnly,
    version: "0.17.0"
  )
}

/// A probe of a Nous-only gateway that serves the native PKCE endpoints.
private func oauthProbe() -> ServerProbe {
  ServerProbe(
    address: ServerAddress("mac:9119")!,
    baseURL: URL(string: "http://mac:9119")!,
    capability: ServerAuthCapability(oauthProviders: [nousProvider], supportsNativeFlow: true),
    version: "0.17.0"
  )
}

/// Welcome → Server (`mac:9119`, id 0) → Sign in for a Nous-only gateway (id 1).
private func oauthSignInState() -> ConnectionFeature.State {
  var state = ConnectionFeature.State()
  state.path.append(.server(ServerStep.State(addressText: "mac:9119")))
  state.path.append(.signIn(SignInStep.State(probe: oauthProbe())))
  return state
}

/// The onboarding flow parent: the stack pushes, the delegate hand-offs between the steps
/// and up to `AppFeature`, and the two entry points. Per-step behaviour lives in
/// `ServerStepTests` and `SignInStepTests`.
@MainActor
struct ConnectionFeatureTests {
  @Test func freshOnboardingIsWelcome() {
    let state = ConnectionFeature.State()
    #expect(state.path.isEmpty)
    #expect(state.prefilledToken == nil)
    #expect(state.lastProbedCapability == nil)
  }

  @Test func welcomeToServerToSignInToConnected() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in .success(tokenOnlyStatus) }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(.connectButtonTapped) {
      $0.path.append(.server(ServerStep.State()))
    }
    await store.send(\.path[id: 0].server.binding.addressText, "mac:9119") {
      $0.path[id: 0, case: \.server]?.addressText = "mac:9119"
    }
    await store.send(\.path[id: 0].server.continueButtonTapped) {
      $0.path[id: 0, case: \.server]?.phase = .probing(.reaching)
    }
    await store.receive(\.path[id: 0].server.statusReceived) {
      $0.path[id: 0, case: \.server]?.phase = .probing(.readingSignInOptions)
    }
    await store.receive(\.path[id: 0].server.probeResponse.success) {
      $0.path[id: 0, case: \.server]?.phase = .idle
    }
    await store.receive(\.path[id: 0].server.delegate.probeSucceeded, tokenOnlyProbe()) {
      $0.lastProbedCapability = .tokenOnly
      $0.path[id: 1] = .signIn(SignInStep.State(probe: tokenOnlyProbe()))
    }

    await store.send(\.path[id: 1].signIn.binding.token, "secret") {
      $0.path[id: 1, case: \.signIn]?.token = "secret"
    }
    await store.send(\.path[id: 1].signIn.tokenSignInButtonTapped) {
      $0.path[id: 1, case: \.signIn]?.status = .validating(.token)
    }
    await store.receive(\.path[id: 1].signIn.tokenValidationResponse.success)
    await store.receive(\.path[id: 1].signIn.delegate.connected)
    await store.receive(\.delegate.connected)

    #expect(keychain.loadToken() == "secret")
    #expect(preferences.loadServerURL() == "http://mac:9119")
  }

  /// Welcome is the root, so its button only ever pushes onto an empty stack — a second tap
  /// landing before the push animation must not stack a second Server step.
  @Test func aSecondConnectTapDoesNotStackAnotherServerStep() async {
    let store = TestStore(initialState: ConnectionFeature.State()) { ConnectionFeature() }
    await store.send(.connectButtonTapped) {
      $0.path.append(.server(ServerStep.State()))
    }
    await store.send(.connectButtonTapped)
  }

  /// Popping Sign in while the OAuth attempt is mid-validation (the pair already seeded)
  /// cancels the element's effect: nothing lands — no response, no delegate, no Keychain
  /// write, no server URL — and the shared store is NOT drained, because cancellation is not
  /// a verdict on the credentials (`performNativeOAuthLogin`, rule 4).
  @Test func poppingSignInMidOAuthCancelsTheAttemptWithoutDrainingTheStore() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let tokenStore = BearerTokenStore()
    let minted = bearerFixture()
    let (validating, signalValidating) = AsyncStream<Void>.makeStream()
    let cancelled = LockIsolated(false)
    let store = TestStore(initialState: oauthSignInState()) {
      ConnectionFeature()
    } withDependencies: {
      $0.oauthLogin.signIn = { @Sendable _, _ in minted }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in
        try await withTaskCancellationHandler {
          signalValidating.yield() // the pair is seeded by now
          try await Task.sleep(for: .seconds(60))
        } onCancel: {
          cancelled.setValue(true)
        }
        return []
      }
      $0.bearerTokens = tokenStore
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(\.path[id: 1].signIn.oauthProviderButtonTapped, nousProvider) {
      $0.path[id: 1, case: \.signIn]?.status = .validating(.oauth)
    }
    var started = validating.makeAsyncIterator()
    await started.next()

    await store.send(.path(.popFrom(id: 1))) {
      $0.path.pop(from: 1)
    }
    await store.finish()

    #expect(cancelled.value, "popping Sign in left the OAuth attempt running")
    #expect(tokenStore.current == minted, "a cancelled attempt drained the shared token store")
    #expect(keychain.loadSession(.shared) == nil)
    #expect(preferences.loadServerURL() == nil)
  }

  /// The credentials-verdict landing (#62): the Server step for the stored URL probes on its
  /// own as it appears, then pushes Sign in with the stored token prefilled.
  @Test func theRecoveringInitializerAutoProbesAndPassesTheToken() async {
    let probed = LockIsolated<[URL]>([])
    let store = TestStore(
      initialState: ConnectionFeature.State(
        recovering: URL(string: "http://mac.tailnet:9119")!, token: "tok"
      )
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.probeStatus = { url in
        probed.withValue { $0.append(url) }
        return .success(tokenOnlyStatus)
      }
    }
    #expect(store.state.prefilledToken == "tok")
    #expect(
      store.state.path[id: 0, case: \.server]
        == ServerStep.State(addressText: "http://mac.tailnet:9119", autoProbe: true)
    )

    let probe = tokenOnlyProbe(
      typed: "http://mac.tailnet:9119", baseURL: "http://mac.tailnet:9119"
    )
    await store.send(\.path[id: 0].server.onAppear) {
      $0.path[id: 0, case: \.server]?.autoProbe = false
      $0.path[id: 0, case: \.server]?.phase = .probing(.reaching)
    }
    await store.receive(\.path[id: 0].server.statusReceived) {
      $0.path[id: 0, case: \.server]?.phase = .probing(.readingSignInOptions)
    }
    await store.receive(\.path[id: 0].server.probeResponse.success) {
      $0.path[id: 0, case: \.server]?.phase = .idle
    }
    await store.receive(\.path[id: 0].server.delegate.probeSucceeded, probe) {
      $0.lastProbedCapability = .tokenOnly
      $0.path[id: 1] = .signIn(SignInStep.State(probe: probe, prefilledToken: "tok"))
    }

    #expect(store.state.path[id: 1, case: \.signIn]?.token == "tok")
    #expect(probed.value == [URL(string: "http://mac.tailnet:9119")!])
  }

  /// The stored token belongs to the stored server: a Sign in for another host (the user
  /// edited the address) starts with an empty token field.
  @Test func theStoredTokenIsPrefilledOnlyForTheStoredHost() async {
    let store = TestStore(
      initialState: ConnectionFeature.State(
        recovering: URL(string: "http://mac.tailnet:9119")!, token: "tok"
      )
    ) {
      ConnectionFeature()
    }
    let otherHost = tokenOnlyProbe(typed: "other-box:9119", baseURL: "http://other-box:9119")
    await store.send(\.path[id: 0].server.delegate.probeSucceeded, otherHost) {
      $0.lastProbedCapability = .tokenOnly
      $0.path[id: 1] = .signIn(SignInStep.State(probe: otherHost))
    }

    // Back on the stored host (another port, same machine): the token comes back.
    let storedHost = tokenOnlyProbe(typed: "mac.tailnet", baseURL: "http://mac.tailnet:9119")
    await store.send(\.path[id: 0].server.delegate.probeSucceeded, storedHost) {
      $0.path.pop(from: 1)
      $0.path[id: 2] = .signIn(SignInStep.State(probe: storedHost, prefilledToken: "tok"))
    }
  }

  /// Popping Sign in after the token's validating call succeeded (but before its response
  /// lands) drops the response — so nothing may have been persisted either: no Keychain
  /// entry, no server URL for the next launch to auto-connect to.
  @Test func poppingSignInAfterAValidatedTokenPersistsNothing() async {
    let keychain = KeychainClient.inMemory()
    let preferences = PreferencesClient.inMemory()
    let (validating, signalValidating) = AsyncStream<Void>.makeStream()
    let release = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    var initial = ConnectionFeature.State()
    initial.path.append(.server(ServerStep.State(addressText: "mac:9119")))
    initial.path.append(.signIn(SignInStep.State(probe: tokenOnlyProbe(), prefilledToken: "secret")))
    let store = TestStore(initialState: initial) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in
        // Not cancellation-aware: the call SUCCEEDS, just after Sign in was popped.
        await withCheckedContinuation { continuation in
          release.setValue(continuation)
          signalValidating.yield()
        }
        return []
      }
      $0.keychain = keychain
      $0.preferences = preferences
    }

    await store.send(\.path[id: 1].signIn.tokenSignInButtonTapped) {
      $0.path[id: 1, case: \.signIn]?.status = .validating(.token)
    }
    var started = validating.makeAsyncIterator()
    await started.next()
    await store.send(.path(.popFrom(id: 1))) {
      $0.path.pop(from: 1)
    }
    release.value?.resume()
    await store.finish()

    #expect(keychain.loadSession(.shared) == nil)
    #expect(preferences.loadServerURL() == nil)
  }

  /// `AppFeature`'s re-sign-in label reads the last probe, so popping Sign in (back to edit
  /// the address) keeps it; the next successful probe replaces it and pushes Sign in again.
  @Test func lastProbedCapabilitySurvivesAPop() async {
    let store = TestStore(
      initialState: {
        var state = ConnectionFeature.State()
        state.path.append(.server(ServerStep.State(addressText: "mac:9119")))
        return state
      }()
    ) {
      ConnectionFeature()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in .success(tokenOnlyStatus) }
    }

    await store.send(\.path[id: 0].server.continueButtonTapped) {
      $0.path[id: 0, case: \.server]?.phase = .probing(.reaching)
    }
    await store.receive(\.path[id: 0].server.statusReceived) {
      $0.path[id: 0, case: \.server]?.phase = .probing(.readingSignInOptions)
    }
    await store.receive(\.path[id: 0].server.probeResponse.success) {
      $0.path[id: 0, case: \.server]?.phase = .idle
    }
    await store.receive(\.path[id: 0].server.delegate.probeSucceeded) {
      $0.lastProbedCapability = .tokenOnly
      $0.path[id: 1] = .signIn(SignInStep.State(probe: tokenOnlyProbe()))
    }

    await store.send(.path(.popFrom(id: 1))) {
      $0.path.pop(from: 1)
    }
    #expect(store.state.lastProbedCapability == .tokenOnly)
  }

  /// Sign in always sits directly above the Server step that probed for it: a probe success
  /// arriving while a stale Sign in is still stacked replaces it rather than stacking a
  /// second one.
  @Test func aProbeSuccessReplacesAStaleSignInStep() async {
    let store = TestStore(initialState: oauthSignInState()) { ConnectionFeature() }

    await store.send(\.path[id: 0].server.delegate.probeSucceeded, tokenOnlyProbe()) {
      $0.lastProbedCapability = .tokenOnly
      $0.path.pop(from: 1)
      $0.path.append(.signIn(SignInStep.State(probe: tokenOnlyProbe())))
    }
    #expect(store.state.path.ids == [0, 2])
  }
}

/// The native PKCE login leg shared by `SignInStep` and `ReauthFeature`
/// (`performNativeOAuthLogin`): its cancellation and ownership rules, exercised on the
/// function directly rather than through a reducer.
@MainActor
struct NativeOAuthLoginTests {
  /// Cancelling the shared login leg must touch NOTHING. The store and the Keychain entry are
  /// process-wide, so an abandoned attempt that drained them on its way out would take down
  /// whatever superseded it — and a logout that cancels this effect while its own hops still
  /// need the store would silently skip `unregisterPush` and `logout` (both resolve their auth
  /// through it). Parking the validating call makes the cancellation land exactly there.
  @Test func aCancelledValidatingCallLeavesTheSharedStoreAlone() async {
    let tokenStore = BearerTokenStore()
    let keychain = KeychainClient.inMemory()
    let minted = bearerFixture()
    let (validating, signalValidating) = AsyncStream<Void>.makeStream()
    var rest = HermesRESTClient.testValue
    rest.sessions = { @Sendable _, _, _, _, _ in
      signalValidating.yield() // the pair is seeded by now
      try await Task.sleep(for: .seconds(60))
      return []
    }
    var oauthLogin = OAuthLoginClient.testValue
    oauthLogin.signIn = { @Sendable _, _ in minted }

    let attempt = Task {
      await performNativeOAuthLogin(
        baseURL: URL(string: "http://mac:9119")!,
        provider: "nous",
        rest: rest,
        keychain: keychain,
        oauthLogin: oauthLogin,
        bearerTokens: tokenStore
      )
    }
    var started = validating.makeAsyncIterator()
    await started.next()
    attempt.cancel()

    #expect(await attempt.value == .failure(.login(.cancelled)))
    #expect(
      tokenStore.current == minted,
      "a cancelled attempt drained the shared token store"
    )
    #expect(keychain.loadSession(.shared) == nil)
  }

  /// The same rule on the other side of the response: an attempt cancelled after its
  /// validating call succeeded must not persist either. That write would land on an entry a
  /// logout has just deleted (resurrecting it) or on a newer attempt's credentials.
  @Test func aCancelledAttemptWhoseValidationSucceededPersistsNothing() async {
    let tokenStore = BearerTokenStore()
    let keychain = KeychainClient.inMemory()
    let minted = bearerFixture()
    let (validating, signalValidating) = AsyncStream<Void>.makeStream()
    let release = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    var rest = HermesRESTClient.testValue
    rest.sessions = { @Sendable _, _, _, _, _ in
      // Not cancellation-aware: the call SUCCEEDS, just after the task was cancelled.
      await withCheckedContinuation { continuation in
        release.setValue(continuation)
        signalValidating.yield()
      }
      return []
    }
    var oauthLogin = OAuthLoginClient.testValue
    oauthLogin.signIn = { @Sendable _, _ in minted }

    let attempt = Task {
      await performNativeOAuthLogin(
        baseURL: URL(string: "http://mac:9119")!,
        provider: "nous",
        rest: rest,
        keychain: keychain,
        oauthLogin: oauthLogin,
        bearerTokens: tokenStore
      )
    }
    var started = validating.makeAsyncIterator()
    await started.next()
    attempt.cancel()
    release.value?.resume()

    #expect(await attempt.value == .failure(.login(.cancelled)))
    #expect(
      keychain.loadSession(.shared) == nil,
      "an abandoned attempt wrote its pair to the Keychain"
    )
  }

  /// Supersede is decided by OWNERSHIP, not by cancellation: a browser leg that returns after
  /// a newer attempt has already landed must not seed its pair, and this test never cancels it
  /// to prove the point (in the app `cancelInFlight` does cancel, but a task that is already
  /// past a `Task.isCancelled` check is not stopped by it). A seed here would leave every
  /// later bearer request carrying the abandoned account's token.
  @Test func aSupersededBrowserLegNeverSeedsOverTheWinner() async {
    let baseURL = URL(string: "http://mac:9119")!
    let tokenStore = BearerTokenStore()
    let keychain = KeychainClient.inMemory()
    let abandoned = bearerFixture(accessToken: "abandoned")
    let winner = bearerFixture(accessToken: "winner")
    let (browserOpen, signalBrowserOpen) = AsyncStream<Void>.makeStream()
    let release = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    var rest = HermesRESTClient.testValue
    rest.sessions = { @Sendable _, _, _, _, _ in [] }
    var slowLogin = OAuthLoginClient.testValue
    slowLogin.signIn = { @Sendable _, _ in
      await withCheckedContinuation { continuation in
        release.setValue(continuation)
        signalBrowserOpen.yield()
      }
      return abandoned // the sheet finally answers, long after it was superseded
    }
    var fastLogin = OAuthLoginClient.testValue
    fastLogin.signIn = { @Sendable _, _ in winner }

    let first = Task {
      await performNativeOAuthLogin(
        baseURL: baseURL, provider: "nous", rest: rest,
        keychain: keychain, oauthLogin: slowLogin, bearerTokens: tokenStore
      )
    }
    var opened = browserOpen.makeAsyncIterator()
    await opened.next()

    // A second provider tap runs start to finish and takes the store with it.
    let second = await performNativeOAuthLogin(
      baseURL: baseURL, provider: "nous", rest: rest,
      keychain: keychain, oauthLogin: fastLogin, bearerTokens: tokenStore
    )
    #expect(second.map(\.bearer) == .success(winner))

    release.value?.resume()

    #expect(await first.value == .failure(.login(.cancelled)))
    #expect(
      tokenStore.current == winner,
      "a superseded attempt installed its pair over the winner's"
    )
    #expect(keychain.loadSession(.shared) == .bearer(winner))
  }

  /// A logout that lands mid-sign-in must stay logged out. `detachPersistence()` +
  /// `deleteSession()` is the reducer's synchronous half; the attempt then comes back from a
  /// validating call the server did answer, and must not be able to re-arm the hook and write
  /// the entry back. Again no cancellation is involved — the rule is ownership.
  @Test func aLogoutMidSignInIsNotUndoneByALateAttach() async {
    let baseURL = URL(string: "http://mac:9119")!
    let tokenStore = BearerTokenStore()
    let keychain = KeychainClient.inMemory()
    let minted = bearerFixture()
    try? keychain.saveSession(.bearer(bearerFixture(accessToken: "restored")))
    let (validating, signalValidating) = AsyncStream<Void>.makeStream()
    let release = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    var rest = HermesRESTClient.testValue
    rest.sessions = { @Sendable _, _, _, _, _ in
      await withCheckedContinuation { continuation in
        release.setValue(continuation)
        signalValidating.yield()
      }
      return [] // the server answers, just after the user quit to start
    }
    var oauthLogin = OAuthLoginClient.testValue
    oauthLogin.signIn = { @Sendable _, _ in minted }

    let attempt = Task {
      await performNativeOAuthLogin(
        baseURL: baseURL, provider: "nous", rest: rest,
        keychain: keychain, oauthLogin: oauthLogin, bearerTokens: tokenStore
      )
    }
    var started = validating.makeAsyncIterator()
    await started.next()

    tokenStore.detachPersistence() // BEFORE the delete, as every logout path does
    try? keychain.deleteSession()
    release.value?.resume()

    #expect(await attempt.value == .failure(.login(.cancelled)))
    #expect(
      keychain.loadSession(.shared) == nil,
      "a late attach rewrote the Keychain entry the logout deleted"
    )
  }
}
