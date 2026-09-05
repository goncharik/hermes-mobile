import Dependencies
import Foundation
import IssueReporting

/// Does this token set need refreshing at `now`?
///
/// Pure and unit-tested at fixed dates so the actor's timing rule is checkable without a
/// clock. `leeway` is the head start we take on the server's absolute `expires_at` (unix
/// seconds) so a request never leaves with a token that dies in flight. Exactly `leeway`
/// seconds left is still fresh — the boundary is strict (`<`).
///
/// A token set with no/zero `expires_at` (an older or partial payload) is treated as
/// needing a refresh: better one wasted round trip than a silent 401 storm.
func bearerNeedsRefresh(
  _ session: BearerSession,
  now: Date,
  leeway: TimeInterval
) -> Bool {
  session.expiresAt - now.timeIntervalSince1970 < leeway
}

/// The single owner of the OAuth (bearer) token pair at runtime.
///
/// Every REST call and every WS ticket mint in the `.bearer` regime asks this actor for a
/// token via ``validAccessToken(refresh:)``; nothing else reads the Keychain or inspects
/// `expiresAt`. Three invariants make that worth an actor:
///
/// 1. **Single-flight refresh.** The portal runs refresh-token REUSE DETECTION: two
///    concurrent refreshes with the same refresh token revoke the whole session and log the
///    user out. Concurrent callers at expiry therefore join ONE in-flight `Task` instead of
///    each starting their own.
/// 2. **Persist before publish.** The rotated pair is written through the `persist` hook
///    (Keychain) from inside the actor BEFORE any caller observes the new token, so a crash
///    between "server rotated" and "app saved" can't strand the app holding a refresh token
///    the server has already retired.
/// 3. **One expiry verdict.** A refresh 401 clears the store and throws
///    `GatewayError.authExpired` — the existing `.sessionExpired` → `ReauthFeature` route.
///    Anything else (503, transport) rethrows with the tokens INTACT so backoff can retry.
///
/// Lifecycle: launch restore and a successful (re)login `seed` it, logout `clear`s it.
public actor BearerTokenStore {
  /// Process-wide instance the live REST and gateway clients share, mirroring the single
  /// cookie jar of the `.cookie` regime — the "single owner" invariant is only true if
  /// there is one store.
  public static let shared = BearerTokenStore()

  private let now: @Sendable () -> Date
  private let refreshLeeway: TimeInterval

  private var session: BearerSession?
  private var baseURL: URL?
  private var persist: (@Sendable (BearerSession) throws -> Void)?
  private var refreshTask: Task<BearerSession, any Error>?
  /// Bumped by every `seed`/`clear`. A refresh that started under an older generation was
  /// superseded, so it must never publish or persist its (now stale) result.
  private var generation = 0

  public init(
    now: @escaping @Sendable () -> Date = { Date() },
    refreshLeeway: TimeInterval = 120
  ) {
    self.now = now
    self.refreshLeeway = refreshLeeway
  }

  /// The token set as last stored. Read for identity (`userID`) and persistence — never to
  /// decide whether a token is usable; that is ``validAccessToken(refresh:)``'s job.
  public var current: BearerSession? { session }

  /// Install a token set, the server it belongs to, and the persistence hook, discarding
  /// any in-flight refresh (it belongs to the credentials being replaced).
  public func seed(
    _ session: BearerSession,
    baseURL: URL,
    persist: @escaping @Sendable (BearerSession) throws -> Void
  ) {
    invalidateInFlightRefresh()
    self.session = session
    self.baseURL = baseURL
    self.persist = persist
  }

  /// Stop writing rotations to the Keychain while keeping the pair usable.
  ///
  /// The logout effect's own hops (`unregisterPush`, `logout`) authenticate through this
  /// store, so a pair inside its leeway rotates mid-logout and the persist hook writes the
  /// Keychain entry the reducer already deleted — resurrecting a dead pair for the next
  /// launch. Detaching first keeps the hops authenticated and leaves the Keychain alone.
  public func detachPersistence() {
    persist = nil
  }

  /// Drop everything (logout / session expiry). Subsequent reads throw `.authExpired`.
  public func clear() {
    invalidateInFlightRefresh()
    session = nil
    baseURL = nil
    persist = nil
  }

  /// A usable access token: the current one when it still has more than `refreshLeeway`
  /// left, otherwise the result of the ONE refresh all concurrent callers share.
  ///
  /// `refresh` is the transport (`POST /auth/native/refresh`), injected so this actor stays
  /// network-free and testable. Throws `GatewayError.authExpired` when there is nothing to
  /// authenticate with or the refresh was rejected (401); any other refresh failure is
  /// rethrown unchanged with the tokens kept.
  public func validAccessToken(
    refresh: @escaping @Sendable (URL, BearerSession) async throws -> BearerSession
  ) async throws -> String {
    guard let session, let baseURL else { throw GatewayError.authExpired }
    guard bearerNeedsRefresh(session, now: now(), leeway: refreshLeeway) else {
      return session.accessToken
    }
    // Join an in-flight rotation rather than starting a second one (invariant 1).
    if let refreshTask { return try await refreshTask.value.accessToken }

    let startGeneration = generation
    // `Task` created in an actor-isolated context inherits this actor, so `performRefresh`
    // resumes here after the network hop: the store mutation and the persist below cannot
    // interleave with another caller.
    let task = Task<BearerSession, any Error> {
      try await self.performRefresh(
        generation: startGeneration,
        baseURL: baseURL,
        expiring: session,
        refresh: refresh
      )
    }
    refreshTask = task
    return try await task.value.accessToken
  }

  // MARK: - Internals

  private func performRefresh(
    generation startGeneration: Int,
    baseURL: URL,
    expiring: BearerSession,
    refresh: @Sendable (URL, BearerSession) async throws -> BearerSession
  ) async throws -> BearerSession {
    let rotated: BearerSession
    do {
      rotated = try await refresh(baseURL, expiring)
    } catch {
      // A superseding seed/clear cancelled this task, so `error` is almost always the
      // cancellation — never a verdict on the credentials. Answer exactly like the success
      // path below: hand back whatever is live, or report expiry when the store was drained.
      // Rethrowing here would surface `URLError.cancelled` (→ a retryable transport failure)
      // where a `clear()` means the session is over.
      guard startGeneration == generation else {
        guard let session else { throw GatewayError.authExpired }
        return session
      }
      refreshTask = nil
      guard isSessionExpiredVerdict(error) else { throw error } // tokens intact, retryable
      clear()
      throw GatewayError.authExpired
    }

    guard startGeneration == generation else {
      // Seeded or cleared while the rotation was in flight: publishing this pair would
      // resurrect credentials the app has deliberately moved off (a different account, or
      // a logout). Hand back whatever is current instead — never persist the stale pair.
      guard let session else { throw GatewayError.authExpired }
      return session
    }
    refreshTask = nil
    session = rotated
    do {
      try persist?(rotated)
    } catch {
      // Keychain failures must not lose the rotated pair: the in-memory copy is the one
      // the server now expects, and dropping it would trigger reuse detection on relaunch.
      reportIssue("BearerTokenStore: persisting the rotated bearer pair failed: \(error)")
    }
    return rotated
  }

  private func invalidateInFlightRefresh() {
    refreshTask?.cancel()
    refreshTask = nil
    generation &+= 1
  }

  /// "The refresh token is dead" — a 401 from the refresh endpoint, or the gateway verdict
  /// already normalized upstream.
  private func isSessionExpiredVerdict(_ error: any Error) -> Bool {
    if let rest = error as? RESTError { return rest == .unauthorized }
    if let gateway = error as? GatewayError { return gateway == .authExpired }
    return false
  }
}

extension BearerTokenStore: DependencyKey {
  public static var liveValue: BearerTokenStore { .shared }
  // A fresh, empty store per test context — never the process-wide one.
  public static var testValue: BearerTokenStore { BearerTokenStore() }
}

public extension DependencyValues {
  var bearerTokens: BearerTokenStore {
    get { self[BearerTokenStore.self] }
    set { self[BearerTokenStore.self] = newValue }
  }
}
