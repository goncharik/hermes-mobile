import ComposableArchitecture
import Foundation

/// An auth regime. `ReauthFeature` derives the one a re-sign-in collects from the stored
/// connection's regime; `SignInStep.State.Status` tags each attempt with the one it used
/// (the onboarding layout comes from the probed capability — `SignInStep.State.Layout`).
public enum AuthMethod: String, Equatable, Sendable {
  case password
  case token
  case oauth
}

/// How an OAuth sign-in attempt failed. Two distinct legs fail differently and must route
/// differently, so they stay distinguishable instead of being flattened into `RESTError`:
/// the browser/PKCE leg (`OAuthLoginError`, whose `.cancelled` is SILENT) and the
/// authenticated call that validates the fresh bearer pair (a 401 there means the server
/// rejected the identity, i.e. `.invalidCredentials`).
public enum OAuthFlowError: Error, Equatable, Sendable {
  case login(OAuthLoginError)
  case validation(RESTError)

  /// User-facing copy for the Sign in step's notice and the reauth status footer.
  public var message: String {
    switch self {
    case let .login(error): error.message
    case let .validation(error): error.message
    }
  }
}

/// Normalize a thrown error from `OAuthLoginClient.signIn` to an `OAuthLoginError` — the
/// client's own error domain passes through verbatim; anything unexpected goes through the
/// shared REST classifier so its copy still reads like every other transport failure.
func asOAuthLoginError(_ error: any Error) -> OAuthLoginError {
  error as? OAuthLoginError ?? .tokenExchange(asRESTError(error))
}

/// What a completed native OAuth login hands back: the validated connection and the bearer
/// pair AS PERSISTED (which is not necessarily the freshly minted one — see below).
struct NativeOAuthLoginSuccess: Equatable, Sendable {
  var connection: ServerConnection
  var bearer: BearerSession
}

/// The native PKCE login leg (#19), shared by onboarding (`SignInStep`) and re-auth
/// (`ReauthFeature`): browser leg → seed the store → validate with one authenticated call →
/// persist. Four rules are load-bearing, so they live in ONE place:
///
/// 1. The pair is seeded BEFORE the validating call — a `.bearer` request resolves its
///    `Authorization` header through `BearerTokenStore`, so an unseeded (or, at re-auth, a
///    still-dead) store would send exactly the wrong credentials — but WITHOUT a Keychain
///    hook: an unproven pair may not reach disk, and the validating call can rotate it, so an
///    armed hook would leave a restorable session behind after a sign-in that then failed.
/// 2. A failed validation DRAINS the store rather than leaving credentials the server just
///    rejected wired up for the next request.
/// 3. What gets persisted is what the STORE holds afterwards, never the pre-seed local: the
///    validating call can rotate the pair, and saving the local copy would put the retired
///    refresh token back in the Keychain — which the portal's reuse detection answers by
///    revoking the whole session on the next launch. `attachPersistence` arms the hook and
///    writes that pair in ONE critical section, so a rotation cannot slip between them.
/// 4. A SUPERSEDED OR CANCELLED attempt touches NOTHING — it neither seeds, drains nor
///    persists. The store and the Keychain entry are process-wide, so an abandoned attempt (a
///    second provider tap, a popped Sign in step, a logout tearing the screen down) that wrote
///    to either would be writing over whatever replaced it. That is not enforced by checking
///    `Task.isCancelled` before each hop — every such check is a window — but by claiming the
///    store for THIS attempt up front and letting the store itself reject every late arrival:
///    see ``BearerStoreClaim``.
///
/// Each caller adds only its own tail (the server-URL save / the identity compare).
func performNativeOAuthLogin(
  baseURL: URL,
  provider: String?,
  rest: HermesRESTClient,
  keychain: KeychainClient,
  oauthLogin: OAuthLoginClient,
  bearerTokens: BearerTokenStore
) async -> Result<NativeOAuthLoginSuccess, OAuthFlowError> {
  // Claimed BEFORE the browser leg: everything below is applied only while this attempt is
  // still the one the user is waiting on (rule 4).
  let claim = bearerTokens.claimOwnership()
  let minted: BearerSession
  do {
    minted = try await oauthLogin.signIn(baseURL, provider)
  } catch {
    // Nothing was seeded yet — no store to clean up.
    return .failure(.login(asOAuthLoginError(error)))
  }
  // Refused → this attempt lost the store while the browser was up. Bail BEFORE validating:
  // a `.bearer` request resolves its header through the store, so validating now would send
  // the winner's credentials (possibly to a different server) and report the verdict as ours.
  guard bearerTokens.seed(minted, baseURL: baseURL, claim: claim) else {
    return .failure(.login(.cancelled))
  }
  do {
    let probe = ServerConnection(baseURL: baseURL, auth: .bearer(minted))
    _ = try await rest.sessions(probe, 1, 0, .recent, .all)
  } catch {
    // Cancellation is not a verdict on these credentials, and the store is SHARED: this
    // attempt was superseded (a second provider tap) or the whole screen is going away (a
    // logout, which needs the store seeded for its own authenticated hops). Draining here
    // would take out a newer attempt's pair, or silently turn `unregisterPush`/`logout` into
    // no-ops. Leave the store as it is and report the silent-cancel verdict.
    guard !isCancellation(error) else { return .failure(.login(.cancelled)) }
    bearerTokens.clear(claim: claim)
    return .failure(.validation(asRESTError(error)))
  }
  // Validated — so arm the hook and persist whatever the store holds. `nil` means this attempt
  // is no longer the one that should land: it was cancelled, superseded, or a logout drained
  // and revoked the store mid-flight. Writing then would overwrite the winner's credentials or
  // resurrect an entry the logout just deleted, and reporting success would land a connection
  // whose pair the store does not have. Same silent verdict as any other abandoned attempt.
  guard let bearer = bearerTokens.attachPersistence(
    { session in try keychain.saveSession(.bearer(session)) },
    claim: claim
  ) else {
    return .failure(.login(.cancelled))
  }
  return .success(NativeOAuthLoginSuccess(
    connection: ServerConnection(baseURL: baseURL, auth: .bearer(bearer)),
    bearer: bearer
  ))
}

/// Was this error the task being cancelled rather than a real verdict? Cooperative
/// cancellation surfaces as `CancellationError` from Swift concurrency and as
/// `URLError.cancelled` from `URLSession`; a cancelled task can also fail some other way on
/// its way out, which `Task.isCancelled` catches.
func isCancellation(_ error: any Error) -> Bool {
  if error is CancellationError { return true }
  if let url = error as? URLError, url.code == .cancelled { return true }
  return Task.isCancelled
}

/// Onboarding (#136): the flow parent of a three-step stack — **Welcome → Server → Sign in**.
///
/// - **Welcome** is the stack root `ConnectionView` renders; it has no reducer of its own, and
///   its one action (`connectButtonTapped`) lives here.
/// - **Server** (`ServerStep`) probes the typed address and reports `.probeSucceeded`; this
///   reducer records the capability and pushes Sign in for that probe.
/// - **Sign in** (`SignInStep`) owns the token/password/OAuth effects and reports
///   `.connected`, which goes up to `AppFeature` unchanged.
///
/// Popping Sign in (swipe-back or "Change") removes its stack element, and TCA cancels that
/// element's effects — that is what abandons an in-flight OAuth attempt; cancellation never
/// drains the shared token store (`performNativeOAuthLogin`, rule 4).
@Reducer
public struct ConnectionFeature {
  @ObservableState
  public struct State: Equatable {
    /// The capability the most recent successful probe reported. Survives popping Sign in;
    /// `AppFeature`'s re-sign-in modal reads its OAuth providers for the provider label.
    public var lastProbedCapability: ServerAuthCapability?
    public var path = StackState<ConnectionPath.State>()
    /// The token the credentials-verdict fallback prefills into Sign in (#62). `nil` for a
    /// fresh onboarding and for the cookie/bearer regimes, which have nothing persistable.
    public var prefilledToken: String?
    /// The stored server's host: only a Sign in for that host gets `prefilledToken`, so an
    /// edited address never receives another server's token.
    public var prefilledTokenHost: String?

    /// A fresh onboarding: Welcome, nothing prefilled (first launch, every logout).
    public init() {}

    /// The credentials-verdict landing (#62 fallback): the Server step for the stored URL,
    /// probing on its own as it appears, then Sign in with `token` prefilled.
    public init(recovering url: URL, token: String?) {
      self.path = StackState([
        .server(ServerStep.State(addressText: url.absoluteString, autoProbe: true)),
      ])
      self.prefilledToken = token
      self.prefilledTokenHost = ServerAddress(url.absoluteString)?.host
    }
  }

  public enum Action {
    /// Welcome's primary call to action.
    case connectButtonTapped
    case delegate(Delegate)
    case path(StackActionOf<ConnectionPath>)

    @CasePathable
    public enum Delegate {
      case connected(ServerConnection)
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .connectButtonTapped:
        // Welcome is the root, so this only ever pushes onto an empty stack; a double tap
        // landing before the push animation must not stack a second Server step.
        guard state.path.isEmpty else { return .none }
        state.path.append(.server(ServerStep.State()))
        return .none

      case .delegate:
        return .none

      case let .path(.element(id, .server(.delegate(.probeSucceeded(probe))))):
        state.lastProbedCapability = probe.capability
        // Sign in always sits directly above the Server step that probed for it.
        state.path.pop(to: id)
        let token = probe.address.host == state.prefilledTokenHost ? state.prefilledToken : nil
        state.path.append(.signIn(SignInStep.State(probe: probe, prefilledToken: token)))
        return .none

      case let .path(.element(_, .signIn(.delegate(.connected(connection))))):
        return .send(.delegate(.connected(connection)))

      case .path:
        return .none
      }
    }
    .forEach(\.path, action: \.path) {
      ConnectionPath.body
    }
  }
}

/// Normalize a thrown error from a REST call to a `RESTError` — the shared funnel the auth
/// reducers (`SignInStep`, `ReauthFeature`, `ConnectionFailedFeature`, `AppFeature`)
/// use after every `rest.*` call: a typed `RESTError` passes through verbatim; anything else
/// goes through `RESTError(transport:)`, the same classifier the live client's own transport
/// catches use, so the offline/unreachable split survives a raw `URLError`.
func asRESTError(_ error: any Error) -> RESTError {
  error as? RESTError ?? RESTError(transport: error)
}
