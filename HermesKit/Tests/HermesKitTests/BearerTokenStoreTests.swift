import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// `BearerTokenStore` is the correctness-critical piece of the OAuth regime: the portal runs
/// refresh-token REUSE DETECTION, so a second concurrent refresh with the same refresh token
/// revokes the entire session. These tests pin the single-flight rule, the persist-before-
/// publish ordering, and the 401-vs-transient split.
struct BearerTokenStoreTests {
  private static let baseURL = URL(string: "https://hermes.example")!
  /// Fixed "now" so expiry is arithmetic, not wall-clock.
  private static let nowSeconds: TimeInterval = 1_000_000
  private static let fixedNow: @Sendable () -> Date = {
    Date(timeIntervalSince1970: BearerTokenStoreTests.nowSeconds)
  }

  private static func session(
    access: String = "access-1",
    refresh: String = "refresh-1",
    userID: String = "user-1",
    expiresIn: TimeInterval
  ) -> BearerSession {
    BearerSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: nowSeconds + expiresIn,
      provider: "nous",
      userID: userID
    )
  }

  private static let rotated = session(
    access: "access-2",
    refresh: "refresh-2",
    expiresIn: 3600
  )

  // MARK: - bearerNeedsRefresh

  /// Remaining lifetime vs. the leeway; the boundary is strict, so exactly `leeway` seconds
  /// left still counts as fresh.
  @Test(arguments: [
    (600.0, false),
    (121.0, false),
    (120.0, false),
    (119.0, true),
    (1.0, true),
    (0.0, true),
    (-60.0, true),
  ])
  func needsRefreshAroundTheLeewayBoundary(remaining: TimeInterval, expected: Bool) {
    let session = Self.session(expiresIn: remaining)
    #expect(bearerNeedsRefresh(session, now: Self.fixedNow(), leeway: 120) == expected)
  }

  /// A payload with no `expires_at` (unix epoch 0) is always stale — one wasted round trip
  /// beats a 401 storm.
  @Test func needsRefreshTreatsAMissingExpiryAsStale() {
    let session = BearerSession(
      accessToken: "a", refreshToken: "r", expiresAt: 0, provider: "nous", userID: "u"
    )
    #expect(bearerNeedsRefresh(session, now: Self.fixedNow(), leeway: 120))
  }

  // MARK: - Happy path

  @Test func aFreshTokenIsReturnedWithoutRefreshing() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    await store.seed(Self.session(expiresIn: 600), baseURL: Self.baseURL, persist: { _ in })

    let token = try await store.validAccessToken { _, _ in
      Issue.record("a fresh token must not be refreshed")
      return Self.rotated
    }
    #expect(token == "access-1")
    #expect(await store.current?.accessToken == "access-1")
  }

  @Test func aRotatedPairIsPersistedBeforeAnyCallerSeesIt() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    let persisted = PersistRecorder()
    await store.seed(
      Self.session(expiresIn: 30),
      baseURL: Self.baseURL,
      persist: { try persisted.hook($0) }
    )

    let token = try await store.validAccessToken { _, _ in Self.rotated }

    // No suspension point between the return above and this read: the persist hook having
    // already run proves it ran inside the actor, before the token was published.
    #expect(token == "access-2")
    #expect(persisted.sessions == [Self.rotated])
    #expect(await store.current == Self.rotated)
  }

  // MARK: - Single flight

  /// Ten callers hit an expiring token while one slow refresh is in flight. The assertion
  /// that matters is taken WHILE the refresh is still blocked: exactly one invocation, even
  /// though all ten callers have arrived. A broken single flight would show ten by then.
  @Test func concurrentCallersAtExpiryShareExactlyOneRefresh() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    let persisted = PersistRecorder()
    await store.seed(
      Self.session(expiresIn: 30),
      baseURL: Self.baseURL,
      persist: { try persisted.hook($0) }
    )

    let refreshes = RefreshRecorder()
    let arrivals = Counter()
    let release = Gate()

    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0 ..< 10 {
        group.addTask {
          await arrivals.increment()
          return try await store.validAccessToken { url, expiring in
            await refreshes.record(baseURL: url, session: expiring)
            await release.wait()
            return Self.rotated
          }
        }
      }

      // Every caller has entered, and the one rotation is parked in the closure above.
      while await arrivals.value < 10 { await Task.yield() }
      while await refreshes.count == 0 { await Task.yield() }
      // Give any caller that would (wrongly) start its own rotation ample room to do so.
      for _ in 0 ..< 500 { await Task.yield() }
      #expect(await refreshes.count == 1)
      #expect(persisted.sessions.isEmpty) // nothing published while the rotation is open

      await release.open()

      var collected: [String] = []
      for try await token in group { collected.append(token) }
      return collected
    }

    #expect(tokens.count == 10)
    #expect(Set(tokens) == ["access-2"])
    #expect(await refreshes.count == 1)
    #expect(await refreshes.urls == [Self.baseURL])
    // The rotation must carry the OLD refresh token — replaying it twice is what trips the
    // portal's reuse detection.
    #expect(await refreshes.sessions.map(\.refreshToken) == ["refresh-1"])
    #expect(persisted.sessions == [Self.rotated])
    #expect(await store.current == Self.rotated)
  }

  // MARK: - Failure semantics

  @Test func aRejectedRefreshClearsTheStoreAndReportsExpiry() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    let persisted = PersistRecorder()
    await store.seed(
      Self.session(expiresIn: 10),
      baseURL: Self.baseURL,
      persist: { try persisted.hook($0) }
    )

    await #expect(throws: GatewayError.authExpired) {
      try await store.validAccessToken { _, _ in throw RESTError.unauthorized }
    }
    #expect(await store.current == nil)
    #expect(persisted.sessions.isEmpty)

    // Cleared for good: the next read is an expiry verdict with no network attempt.
    await #expect(throws: GatewayError.authExpired) {
      try await store.validAccessToken { _, _ in
        Issue.record("a cleared store must not refresh")
        return Self.rotated
      }
    }
  }

  @Test func aTransientRefreshFailureKeepsTheTokensAndAllowsARetry() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    let expiring = Self.session(expiresIn: 10)
    await store.seed(expiring, baseURL: Self.baseURL, persist: { _ in })

    await #expect(throws: RESTError.serviceUnavailable) {
      try await store.validAccessToken { _, _ in throw RESTError.serviceUnavailable }
    }
    #expect(await store.current == expiring) // tokens intact — backoff will retry

    let token = try await store.validAccessToken { _, _ in Self.rotated }
    #expect(token == "access-2")
  }

  @Test func clearingTheStoreExpiresSubsequentReads() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    await store.seed(Self.session(expiresIn: 600), baseURL: Self.baseURL, persist: { _ in })
    await store.clear()

    #expect(await store.current == nil)
    await #expect(throws: GatewayError.authExpired) {
      try await store.validAccessToken { _, _ in Self.rotated }
    }
  }

  /// A re-login (or a profile switch) lands while a rotation is in flight: the stale pair
  /// must never be persisted or published over the credentials the app just moved to.
  @Test func aSeedDuringARefreshDiscardsTheStaleRotation() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    let firstPersist = PersistRecorder()
    let secondPersist = PersistRecorder()
    await store.seed(
      Self.session(expiresIn: 10),
      baseURL: Self.baseURL,
      persist: { try firstPersist.hook($0) }
    )

    let started = Gate()
    let release = Gate()
    let caller = Task {
      try await store.validAccessToken { _, _ in
        await started.open()
        await release.wait()
        // The real transport is `URLSession.data(for:)`, which HONOURS cancellation — and
        // `seed` cancels the in-flight refresh task. Without this the fake would paper over
        // the very error path the supersede rule has to answer.
        try Task.checkCancellation()
        return Self.rotated
      }
    }
    await started.wait()

    let reseeded = Self.session(
      access: "access-B", refresh: "refresh-B", userID: "user-2", expiresIn: 3600
    )
    await store.seed(
      reseeded,
      baseURL: Self.baseURL,
      persist: { try secondPersist.hook($0) }
    )
    await release.open()

    // The waiting caller gets the LIVE credentials, not the superseded rotation — and not
    // the cancellation the supersede itself caused.
    #expect(try await caller.value == "access-B")
    #expect(await store.current == reseeded)
    #expect(firstPersist.sessions.isEmpty)
    #expect(secondPersist.sessions.isEmpty)
  }

  /// The other half of the supersede rule: a logout while a rotation is in flight is an
  /// EXPIRY verdict, not a transport blip. Rethrowing the cancellation would surface as
  /// `RESTError.unreachable` and put the caller into retry/backoff against a store that can
  /// never serve another token.
  @Test func aClearDuringARefreshReportsExpiryNotTheCancellation() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    await store.seed(Self.session(expiresIn: 10), baseURL: Self.baseURL, persist: { _ in })

    let started = Gate()
    let release = Gate()
    let caller = Task {
      try await store.validAccessToken { _, _ in
        await started.open()
        await release.wait()
        try Task.checkCancellation()
        return Self.rotated
      }
    }
    await started.wait()
    await store.clear()
    await release.open()

    await #expect(throws: GatewayError.authExpired) { try await caller.value }
  }

  /// Logout detaches the persist hook before its own REST hops run: those hops authenticate
  /// through this store, so a rotation they trigger would otherwise write the Keychain entry
  /// the reducer just deleted and resurrect a dead pair on the next launch.
  @Test func detachingPersistenceKeepsServingTokensWithoutWritingThem() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    let persisted = PersistRecorder()
    await store.seed(
      Self.session(expiresIn: 10),
      baseURL: Self.baseURL,
      persist: { try persisted.hook($0) }
    )

    await store.detachPersistence()
    let token = try await store.validAccessToken { _, _ in Self.rotated }

    #expect(token == "access-2") // the logout hops still authenticate
    #expect(persisted.sessions.isEmpty) // …but nothing reaches the Keychain
  }

  /// A Keychain write failure is reported, but the rotated pair stays in memory — dropping
  /// it would make the app replay the retired refresh token on the next call.
  @Test func aPersistFailureStillPublishesTheRotatedPair() async throws {
    let store = BearerTokenStore(now: Self.fixedNow, refreshLeeway: 120)
    let persisted = PersistRecorder(failure: PersistFailure())
    await store.seed(
      Self.session(expiresIn: 10),
      baseURL: Self.baseURL,
      persist: { try persisted.hook($0) }
    )

    let token = LockIsolated<String?>(nil)
    await withKnownIssue("the persist hook fails; the store reports and carries on") {
      let fresh = try await store.validAccessToken { _, _ in Self.rotated }
      token.setValue(fresh)
    }

    #expect(token.value == "access-2")
    #expect(await store.current == Self.rotated)
  }
}

// MARK: - Test doubles

private struct PersistFailure: Error {}

/// Records every persisted pair; optionally fails the write. Lock-guarded because the hook
/// is a synchronous `@Sendable` closure called from the actor.
private final class PersistRecorder: Sendable {
  private let saved = LockIsolated<[BearerSession]>([])
  private let failure: (any Error & Sendable)?

  init(failure: (any Error & Sendable)? = nil) { self.failure = failure }

  var sessions: [BearerSession] { saved.value }

  func hook(_ session: BearerSession) throws {
    saved.withValue { $0.append(session) }
    if let failure { throw failure }
  }
}

private actor RefreshRecorder {
  private(set) var urls: [URL] = []
  private(set) var sessions: [BearerSession] = []
  var count: Int { sessions.count }

  func record(baseURL: URL, session: BearerSession) {
    urls.append(baseURL)
    sessions.append(session)
  }
}

private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}

/// A one-shot gate: `wait()` suspends until some task calls `open()`.
private actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    guard !isOpen else { return }
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}
