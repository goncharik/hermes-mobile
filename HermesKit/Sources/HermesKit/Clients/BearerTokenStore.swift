import ComposableArchitecture
import Dependencies
import Foundation
import IssueReporting

/// Does this token set need refreshing at `now`?
///
/// Pure and unit-tested at fixed dates so the store's timing rule is checkable without a
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

/// An exclusive claim on ``BearerTokenStore``, held by ONE sign-in attempt.
///
/// The store is process-wide, so which caller is entitled to mutate it cannot be read off the
/// call site: a browser leg runs for minutes, and by the time it returns the attempt that
/// started it may have been superseded (a second provider tap, an edited server URL) or torn
/// down (a logout that already deleted the Keychain entry). Every "am I still cancelled?"
/// check made *before* the hop into the store is a time-of-check/time-of-use window, and each
/// one closed so far simply moved the window somewhere else.
///
/// The rule instead: an attempt claims the store up front (``BearerTokenStore/claimOwnership()``)
/// and passes that claim to every mutation it makes. The store applies one only while the
/// claim is still the current owner and the calling task is alive, decided INSIDE the store's
/// one critical section together with the mutation. Anything else — a superseded attempt, a
/// cancelled one, one that a logout has already revoked — is a late arrival and is dropped,
/// whatever shape it arrives in.
public struct BearerStoreClaim: Hashable, Sendable {
  fileprivate let id: Int
}

/// The single owner of the OAuth (bearer) token pair at runtime.
///
/// Every REST call and every WS ticket mint in the `.bearer` regime asks this store for a
/// token via ``validAccessToken(refresh:)``; nothing else reads the Keychain or inspects
/// `expiresAt`. Three invariants make that worth a dedicated type:
///
/// 1. **Single-flight refresh.** The portal runs refresh-token REUSE DETECTION: two
///    concurrent refreshes with the same refresh token revoke the whole session and log the
///    user out. Concurrent callers at expiry therefore join ONE in-flight `Task` instead of
///    each starting their own.
/// 2. **Persist before publish.** The rotated pair is written through the persist hook
///    (Keychain — whenever one is armed, see ``seed(_:baseURL:persist:claim:)``) BEFORE any
///    caller observes the new token, so a crash between "server rotated" and "app saved" can't
///    strand the app holding a refresh token the server has already retired.
/// 3. **One expiry verdict.** A refresh 401 clears the store and throws
///    `GatewayError.authExpired` — the existing `.sessionExpired` → `ReauthFeature` route.
///    Anything else (503, transport) rethrows with the tokens INTACT so backoff can retry.
///
/// Lifecycle: launch restore and a successful (re)login `seed` it, logout `clear`s it.
///
/// ## One synchronization domain — the normative rule
///
/// **Every** mutable thing the store owns — the pair, its server, the persist hook, ownership,
/// the in-flight refresh handle and the supersede generation — lives in ONE lock-isolated
/// ``State``, and **every** entry point decides and mutates inside a SINGLE
/// `state.withValue` critical section. The invariant that buys:
///
/// > No approved check is ever followed by a mutation that a concurrent `detachPersistence()`,
/// > `clear()` or newer `claimOwnership()` could have invalidated in between. A revocation
/// > either lands wholly before a mutation (which is then refused) or wholly after it (and
/// > then it is the revocation that decides) — never in the middle.
///
/// This is the fix for a defect that recurred four times: while ownership lived in a lock and
/// the pair lived in actor-isolated storage there was no critical section spanning both, so
/// every "check, then mutate" straddled the seam and each guard added merely moved the window.
/// The type is therefore a `Sendable` **class**, not an actor: with no isolation domain of its
/// own it cannot hold mutable stored state outside the lock — the compiler enforces the rule
/// that prose failed to.
///
/// Two disciplines keep that safe, and both are load-bearing:
///
/// - **Never `await` inside `withValue`.** The refresh transport runs OUTSIDE the lock and its
///   result is re-validated against `generation` under the lock before it is published —
///   compare-and-swap, which is also what makes single-flight and the supersede rule work.
/// - **Never run caller code inside `withValue` that can re-enter the store.** `LockIsolated`
///   is recursive AND copy-on-write-back, so a re-entrant mutation is silently clobbered by
///   the outer critical section. `Task.cancel()` runs cancellation handlers synchronously on
///   the calling thread, so discarding an in-flight refresh happens AFTER the section. The one
///   deliberate exception is the persist hook, which MUST run inside the section (arming it
///   and writing through it have to be indivisible with the ownership verdict); it is only
///   ever `KeychainClient.saveSession` and must never call back into the store.
///
/// Because the store is process-wide, "may this caller mutate it?" cannot be inferred from the
/// call site — see ``BearerStoreClaim``.
public final class BearerTokenStore: Sendable {
  /// The Keychain write-through hook (`AuthSession.bearer` → `KeychainClient.saveSession`).
  public typealias PersistHook = @Sendable (BearerSession) throws -> Void

  /// Process-wide instance the live REST and gateway clients share, mirroring the single
  /// cookie jar of the `.cookie` regime — the "single owner" invariant is only true if
  /// there is one store.
  public static let shared = BearerTokenStore()

  private let now: @Sendable () -> Date
  private let refreshLeeway: TimeInterval
  /// The store's ONE synchronization domain. See the type doc: nothing mutable lives outside
  /// it, and no entry point spans two acquisitions of it.
  private let state = LockIsolated(State())

  public init(
    now: @escaping @Sendable () -> Date = { Date() },
    refreshLeeway: TimeInterval = 120
  ) {
    self.now = now
    self.refreshLeeway = refreshLeeway
  }

  /// The pair as last stored, for tests to observe. No production code reads it: a token's
  /// usability is ``validAccessToken(refresh:)``'s verdict, and the pair a sign-in attempt
  /// should act on is the one ``attachPersistence(_:claim:)`` hands back — reading it here
  /// instead would race whatever else holds the store.
  public var current: BearerSession? { state.session }

  /// Claim the store for ONE sign-in attempt, revoking every claim issued before it: the
  /// newest attempt is the owner. Called before the attempt's first `await` — the claim must
  /// exist before the browser leg starts, not after it returns, or the window this whole
  /// mechanism closes is simply moved.
  public func claimOwnership() -> BearerStoreClaim {
    state.withValue { state in
      Self.takeOwnership(&state)
      return BearerStoreClaim(id: state.owner)
    }
  }

  /// Install a token set and the server it belongs to, discarding any in-flight refresh (it
  /// belongs to the credentials being replaced). Returns whether it was applied — see
  /// ``BearerStoreClaim`` for when it is not.
  ///
  /// `persist` is the Keychain write-through hook, and it is OPTIONAL because a pair is not
  /// always allowed to reach the Keychain yet: a freshly minted one has not been validated,
  /// so a rotation performed by the validating call must stay in memory until that call
  /// succeeds (`performNativeOAuthLogin` seeds hookless, then
  /// ``attachPersistence(_:claim:)``). A pair restored FROM the Keychain seeds with its hook
  /// straight away.
  @discardableResult
  public func seed(
    _ session: BearerSession,
    baseURL: URL,
    persist: PersistHook? = nil,
    claim: BearerStoreClaim? = nil
  ) -> Bool {
    let (applied, discarded) = state.withValue { state -> (Bool, RefreshTask?) in
      guard Self.adopt(&state, claim) else { return (false, nil) }
      let doomed = Self.supersedeInFlightRefresh(&state)
      state.session = session
      state.baseURL = baseURL
      state.hook = persist
      return (true, doomed)
    }
    // Outside the section on purpose: `cancel()` runs the refresh's cancellation handlers
    // synchronously on THIS thread, and a handler that re-entered the store would be clobbered.
    discarded?.cancel()
    return applied
  }

  /// Arm the Keychain hook and write the live pair through it, atomically: whatever the store
  /// holds RIGHT NOW is what lands on disk (a rotation performed while the pair was still
  /// unproven included), and any rotation after this point is written by the hook. Returns
  /// the pair that was written, or `nil` when this attempt no longer owns the store (see
  /// ``BearerStoreClaim``) or the store has since been drained — a logout or an expiry, and
  /// nothing may be persisted for either.
  ///
  /// The claim is REQUIRED, not defaulted: arming the hook is what can resurrect a deleted
  /// Keychain entry, so there is no such thing as an anonymous attach.
  @discardableResult
  public func attachPersistence(
    _ persist: @escaping PersistHook,
    claim: BearerStoreClaim
  ) -> BearerSession? {
    let (attached, failure) = state.withValue { state -> (BearerSession?, String?) in
      guard Self.adopt(&state, claim), let session = state.session else { return (nil, nil) }
      state.hook = persist
      return (session, Self.writeThrough(session, using: &state))
    }
    if let failure { reportIssue(failure) }
    return attached
  }

  /// Stop writing rotations to the Keychain while keeping the pair usable, and revoke every
  /// outstanding claim.
  ///
  /// The rule it exists for: **detach before deleting the Keychain session.** Logout deletes
  /// that entry while a refresh may already be in flight (the logout's own
  /// `unregisterPush`/`logout` hops authenticate through this store, and any pair inside its
  /// leeway rotates), and an armed hook writes the entry straight back — resurrecting a dead
  /// pair for the next launch. It is synchronous so a reducer body can close that window
  /// before its own `keychain.deleteSession()`, and it blocks on a write already in progress.
  ///
  /// Revoking is the other half: disarming alone would leave an outstanding sign-in attempt
  /// free to re-arm the hook (and rewrite the just-deleted entry) the moment it came back.
  public func detachPersistence() {
    state.withValue { Self.revoke(&$0) }
  }

  /// Abandon the credentials — logout, or a sign-in attempt cleaning up after a rejected
  /// pair. Subsequent reads throw `.authExpired`, and every outstanding claim is revoked.
  ///
  /// The claim is REQUIRED, not defaulted: this is the deliberate-abandonment entry point (see
  /// ``revoke(_:)``), and a caller with no established entitlement has no business declaring
  /// it. Logout is not exempt — its own drain sits behind two best-effort network hops that an
  /// unreachable server can stall for a minute, by which time the user may have completed a
  /// NEWER sign-in; a claim minted at the logout site lets that sign-in supersede the stale
  /// drain through the same verdict that already protects `seed`/`attachPersistence`.
  public func clear(claim: BearerStoreClaim) {
    let discarded = state.withValue { state -> RefreshTask? in
      guard Self.adopt(&state, claim) else { return nil }
      let doomed = Self.supersedeInFlightRefresh(&state)
      Self.discardPair(&state)
      Self.revoke(&state)
      return doomed
    }
    discarded?.cancel() // outside the section — see `seed`
  }

  /// A usable access token: the current one when it still has more than `refreshLeeway`
  /// left, otherwise the result of the ONE refresh all concurrent callers share.
  ///
  /// `refresh` is the transport (`POST /auth/native/refresh`), injected so this type stays
  /// network-free and testable. Throws `GatewayError.authExpired` when there is nothing to
  /// authenticate with or the refresh was rejected (401); any other refresh failure is
  /// rethrown unchanged with the tokens kept.
  public func validAccessToken(
    refresh: @escaping @Sendable (URL, BearerSession) async throws -> BearerSession
  ) async throws -> String {
    switch nextStep(refresh: refresh) {
    case .expired: throw GatewayError.authExpired
    case let .use(token): return token
    case let .join(task): return try await task.value.accessToken
    }
  }

  // MARK: - Internals

  private typealias RefreshTask = Task<BearerSession, any Error>

  /// Everything mutable the store owns, in one place so one lock covers all of it.
  ///
  /// `owner` is the only claim id that may mutate; `issued` mints the next one, so bumping
  /// both revokes everything outstanding. `generation` is bumped by every seed/clear: a
  /// refresh that started under an older generation was superseded and must never publish or
  /// persist its (now stale) result.
  private struct State {
    var session: BearerSession?
    var baseURL: URL?
    var hook: PersistHook?
    var refreshTask: RefreshTask?
    var generation = 0
    var owner = 0
    var issued = 0
  }

  /// What ``validAccessToken(refresh:)`` decided under the lock, so the (possibly long) await
  /// happens outside it.
  private enum Step: Sendable {
    case expired
    case use(String)
    case join(RefreshTask)
  }

  /// How a failed refresh settles, decided under the lock together with the generation check.
  private enum Settlement: Sendable {
    case publish(BearerSession)
    case expired
    case rethrow
  }

  private func nextStep(
    refresh: @escaping @Sendable (URL, BearerSession) async throws -> BearerSession
  ) -> Step {
    state.withValue { state in
      guard let session = state.session, let baseURL = state.baseURL else { return .expired }
      guard bearerNeedsRefresh(session, now: now(), leeway: refreshLeeway) else {
        return .use(session.accessToken)
      }
      // Join an in-flight rotation rather than starting a second one (invariant 1). Deciding
      // and recording the winner in one section is what makes that a real single flight.
      if let inFlight = state.refreshTask { return .join(inFlight) }
      let startGeneration = state.generation
      let task = RefreshTask { [self] in
        try await performRefresh(
          generation: startGeneration,
          baseURL: baseURL,
          expiring: session,
          refresh: refresh
        )
      }
      state.refreshTask = task
      return .join(task)
    }
  }

  private func performRefresh(
    generation startGeneration: Int,
    baseURL: URL,
    expiring: BearerSession,
    refresh: @Sendable (URL, BearerSession) async throws -> BearerSession
  ) async throws -> BearerSession {
    let rotated: BearerSession
    do {
      // The one network hop, deliberately OUTSIDE the lock.
      rotated = try await refresh(baseURL, expiring)
    } catch {
      switch settle(startGeneration: startGeneration, isExpiry: isSessionExpiredVerdict(error)) {
      case let .publish(session): return session
      case .expired: throw GatewayError.authExpired
      case .rethrow: throw error // tokens intact, retryable
      }
    }
    // Compare-and-swap: the supersede verdict, the publish and the write-through are one
    // section, so a seed/clear/detach cannot land between them.
    let (published, failure) = state.withValue { state -> (BearerSession?, String?) in
      guard startGeneration == state.generation else {
        // Seeded or cleared while the rotation was in flight: publishing this pair would
        // resurrect credentials the app has deliberately moved off (a different account, or
        // a logout). Hand back whatever is current instead — never persist the stale pair.
        return (state.session, nil)
      }
      state.refreshTask = nil
      state.session = rotated
      return (rotated, Self.writeThrough(rotated, using: &state))
    }
    if let failure { reportIssue(failure) }
    guard let published else { throw GatewayError.authExpired }
    return published
  }

  /// A superseding seed/clear cancels the refresh task, so a thrown error is almost always
  /// that cancellation — never a verdict on the credentials. Answer exactly like the success
  /// path: hand back whatever is live, or report expiry when the store was drained. Rethrowing
  /// would surface `URLError.cancelled` (→ a retryable transport failure) where a `clear()`
  /// means the session is over.
  private func settle(startGeneration: Int, isExpiry: Bool) -> Settlement {
    state.withValue { state in
      guard startGeneration == state.generation else {
        return state.session.map(Settlement.publish) ?? .expired
      }
      state.refreshTask = nil
      guard isExpiry else { return .rethrow }
      // The one expiry verdict, atomic with the check above. It discards WITHOUT revoking —
      // see `revoke`: the pair died, the app did not abandon it, and a sign-in already in
      // flight is the remedy, not a late arrival.
      Self.discardPair(&state)
      return .expired
    }
  }

  /// May a mutation carrying `claim` be applied? Called only from inside the lock, so its
  /// verdict and the mutation it guards are indivisible.
  ///
  /// `nil` is an UNCLAIMED caller — launch restore, logout, a test seeding a fixture — which
  /// is unconditional and takes ownership itself, superseding any attempt in flight. A claim
  /// wins only while it is still the current owner AND its task has not been cancelled:
  /// `Task.isCancelled` reads the CALLING task, which is why it is checked here rather than at
  /// the call site. (Cancellation is cooperative, so it can still be requested a moment after
  /// this read — what protects a deleted Keychain entry is the ownership half, which a logout
  /// revokes through the same lock.)
  private static func adopt(_ state: inout State, _ claim: BearerStoreClaim?) -> Bool {
    guard let claim else {
      takeOwnership(&state)
      return true
    }
    guard !Task.isCancelled else { return false }
    return state.owner == claim.id
  }

  private static func takeOwnership(_ state: inout State) {
    state.issued &+= 1
    state.owner = state.issued
  }

  /// Disarm the persist hook and invalidate every outstanding claim.
  ///
  /// **The normative rule this type is built around.** Revoking means "the app has
  /// DELIBERATELY moved off these credentials" — a logout, or a newer attempt superseding an
  /// older one. It must never be spelled by anything else, and the two temptations are named
  /// because both have shipped as bugs:
  ///
  /// - *Something incidental happened to the pair* — a refresh 401, i.e. the credentials
  ///   dying under an unrelated caller (a list poll, a foreground refresh). That is
  ///   ``discardPair(_:)``, which leaves ownership alone: an expiry is precisely what the
  ///   user is signing in to fix, so an attempt already in flight is still the attempt they
  ///   are waiting on and its `seed` must land.
  /// - *A caller with no established entitlement said so* — hence ``clear(claim:)`` takes a
  ///   claim rather than defaulting to an unconditional drain.
  private static func revoke(_ state: inout State) {
    state.hook = nil
    takeOwnership(&state)
  }

  /// Forget the pair, its server and the persist hook: nothing left to authenticate with and
  /// nothing left to write. Ownership is deliberately untouched — see ``revoke(_:)``.
  private static func discardPair(_ state: inout State) {
    state.session = nil
    state.baseURL = nil
    state.hook = nil
  }

  /// Detach the in-flight refresh and mark everything it might publish as superseded. The
  /// returned task must be cancelled OUTSIDE the critical section.
  private static func supersedeInFlightRefresh(_ state: inout State) -> RefreshTask? {
    let doomed = state.refreshTask
    state.refreshTask = nil
    state.generation &+= 1
    return doomed
  }

  /// Hand a pair to the persist hook, if one is armed, and return the message to report when
  /// the write fails. Failures are reported, never thrown: the in-memory copy is the one the
  /// server now expects, so keeping it lets THIS process carry on. It does not rescue the next
  /// launch — the Keychain still holds the retired pair, and seeding that trips reuse detection
  /// whatever we do here.
  private static func writeThrough(_ session: BearerSession, using state: inout State) -> String? {
    guard let hook = state.hook else { return nil }
    do {
      try hook(session)
      return nil
    } catch {
      return "BearerTokenStore: persisting the rotated bearer pair failed: \(error)"
    }
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
