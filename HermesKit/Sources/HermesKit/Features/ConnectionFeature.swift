import ComposableArchitecture
import Foundation

/// Onboarding: a staged, capability-aware connection flow.
/// 1. Check the server URL is reachable (`GET /api/status`, unauthenticated) —
///    distinguishing unreachable from "reachable but not Hermes" — and probe its auth
///    capability (`/api/auth/providers` on a gated server) to preselect the segment.
/// 2. Authenticate in the chosen regime:
///    - **token** — validate the pasted token with one authenticated call
///      (`GET /api/sessions?limit=1`).
///    - **password** — `POST /auth/password-login` for a cookie session, then validate the
///      cookies with the same authenticated call.
///    - **oauth** — the native PKCE browser leg (`OAuthLoginClient`) for a bearer pair,
///      seeded into `BearerTokenStore` and validated with the same authenticated call (#19).
/// 3. Persist the resulting `AuthSession` (token, cookie, or bearer) in the Keychain and
///    signal `.delegate(.connected)`.

/// Which auth regime the user is entering credentials for. Driven by the server's
/// capability probe (see `ServerAuthCapability`) but ultimately the user's segment choice.
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

  /// User-facing copy for the status footer.
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

@Reducer
public struct ConnectionFeature {
  @ObservableState
  public struct State: Equatable {
    public var serverURL: String
    public var token: String
    public var username: String
    public var password: String
    /// The user's selected auth segment. Preselected from the capability probe; the user
    /// may still switch to whichever segment is enabled.
    public var method: AuthMethod
    /// The server's advertised auth capability (probed alongside `/api/status`). `nil` until
    /// the reachability check completes. Drives segment enable/preselect.
    public var capability: ServerAuthCapability?
    /// Which OAuth provider the user tapped, when the server advertises several. `nil` falls
    /// back to the first advertised one (the common single-provider case).
    public var selectedOAuthProviderName: String?
    /// The version `/api/status` reported on the last successful check. Kept out of `status`
    /// so a sign-in attempt that returns to `.reachable` (a cancelled OAuth sheet) can
    /// restore the version it displayed before.
    public var serverVersion: String?
    public var status: Status

    public init(
      serverURL: String = "",
      token: String = "",
      username: String = "",
      password: String = "",
      method: AuthMethod = .token,
      capability: ServerAuthCapability? = nil,
      selectedOAuthProviderName: String? = nil,
      serverVersion: String? = nil,
      status: Status = .idle
    ) {
      self.serverURL = serverURL
      self.token = token
      self.username = username
      self.password = password
      self.method = method
      self.capability = capability
      self.selectedOAuthProviderName = selectedOAuthProviderName
      self.serverVersion = serverVersion
      self.status = status
    }

    public enum Status: Equatable, Sendable {
      case idle
      case checking
      case invalidURL
      case unreachable
      case notHermes
      case reachable(version: String?)
      case validating
      case invalidToken
      case invalidCredentials
      case failed(String)
    }

    /// Whether the Password segment may be selected. The probe says password is available;
    /// before the probe completes we optimistically allow it (`?? true` — capability gating
    /// must not be stricter than reality on unknowns).
    public var isPasswordEnabled: Bool { capability?.isPasswordAvailable ?? true }

    /// Whether the Token segment may be selected. Always available — token mode is the
    /// universal fallback — but de-emphasized when the server is gated (password preferred).
    public var isTokenEnabled: Bool { true }

    /// Whether the OAuth segment is offered at all.
    ///
    /// Deliberately STRICTER than the project's `?? true` unknown-capability idiom: that rule
    /// exists so an unknown capability never HIDES functionality the server already has,
    /// which is not this case. OAuth is a NEW affordance that only works when the gateway
    /// serves `/auth/native/authorize`, so it needs positive evidence (an OAuth provider AND
    /// `native_pkce` in `auth_flows`) — offering a sign-in the gateway cannot complete is
    /// worse than not offering it. An unprobed server (`nil`) shows no OAuth segment.
    public var isOAuthEnabled: Bool { capability?.isOAuthAvailable ?? false }

    /// The OAuth providers to render buttons for (empty unless `isOAuthEnabled`).
    public var oauthProviders: [AuthProvider] {
      isOAuthEnabled ? capability?.oauthProviders ?? [] : []
    }

    /// The provider an OAuth sign-in would run against: the user's pick, else the first
    /// advertised one (a single-provider server needs no pick).
    public var activeOAuthProvider: AuthProvider? {
      let providers = oauthProviders
      guard let name = selectedOAuthProviderName else { return providers.first }
      return providers.first { $0.name == name } ?? providers.first
    }

    /// True on a gated server where the token path is a poor fit (UI may de-emphasize it).
    public var isTokenDeemphasized: Bool { capability?.isGated ?? false }

    public var canConnect: Bool {
      guard status != .validating else { return false }
      switch status {
      case .reachable, .invalidToken, .invalidCredentials: break // allow a retry
      // `.oauth` ALSO retries from `.failed` (#19). Password and Token reach `.failed`
      // only for wait-it-out verdicts (rate limit, provider outage) and both have a field
      // whose edit is the natural next move; the browser leg's failures — a dawdled-past
      // 120 s code TTL, the 300 s sheet budget, a state mismatch — are one-tap
      // recoverable, and the copy literally says "Try again." With no field to edit,
      // omitting this left that button permanently disabled until the URL was retyped.
      // Safe because a FAILED PROBE clears `capability`, so `isOAuthEnabled` is false and
      // the switch below still returns false. Password/token gating is unchanged.
      case .failed where method == .oauth: break
      default: return false
      }
      switch method {
      case .password: return !username.isEmpty && !password.isEmpty
      case .token: return !token.isEmpty
      // Nothing to type: the browser leg collects the credentials.
      case .oauth: return isOAuthEnabled
      }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    /// The screen appeared — auto-check a pre-filled URL (#38).
    case onAppear
    /// Reachability check (debounced after typing, or fired on submit/focus-loss).
    case checkServer
    /// The URL field was submitted or lost focus — check immediately.
    case serverFieldCommitted
    case connectTapped
    /// "Continue with <provider>" — the provider button IS the connect action, so it records
    /// the pick (servers may advertise several) and runs the same `connectTapped` path.
    case oauthProviderTapped(AuthProvider)
    /// `/api/status` result plus the (optional) `/api/auth/providers` probe, folded so the
    /// capability is computed in one place.
    case serverStatusResponse(Result<ServerStatus, RESTError>, providers: [AuthProvider]?)
    case tokenValidationResponse(Result<ServerConnection, RESTError>)
    /// Password login → cookie session validated → ready to persist + connect.
    case passwordLoginResponse(Result<ServerConnection, RESTError>)
    /// Native OAuth login → bearer pair seeded + validated → ready to connect.
    case oauthLoginResponse(Result<ServerConnection, OAuthFlowError>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case connected(ServerConnection)
    }
  }

  private enum CancelID { case urlDebounce, statusCheck }

  @Dependency(\.hermesREST) var rest
  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.oauthLogin) var oauthLogin
  @Dependency(\.bearerTokens) var bearerTokens
  @Dependency(\.continuousClock) var clock

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.serverURL):
        state.status = .idle // a new URL invalidates any prior reachability result
        guard !state.serverURL.trimmingCharacters(in: .whitespaces).isEmpty else {
          return .cancel(id: CancelID.urlDebounce)
        }
        // Auto-check after the user stops typing (covers paste too).
        return .run { [clock] send in
          try await clock.sleep(for: .milliseconds(600))
          await send(.checkServer)
        }
        .cancellable(id: CancelID.urlDebounce, cancelInFlight: true)

      case .binding:
        return .none

      case .onAppear:
        // A pre-filled URL (launch auto-connect fallback / logout) is validated immediately
        // so the sign-in step unlocks without the user having to focus the field first (#38).
        // Reuses the field-driven check path — no duplicated validation logic. Only fires
        // from a pristine `.idle` so a re-appear (e.g. popping back from the secure-connect
        // details screen) never clobbers a completed or in-flight check.
        guard state.status == .idle,
              !state.serverURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return .none }
        return .send(.checkServer)

      case .serverFieldCommitted:
        // Submit / focus-loss → check now, pre-empting the debounce.
        return .merge(.cancel(id: CancelID.urlDebounce), .send(.checkServer))

      case .checkServer:
        guard let url = parseServerURL(state.serverURL) else {
          state.status = .invalidURL
          return .none
        }
        state.status = .checking
        return .run { [rest] send in
          do {
            let status = try await rest.status(url)
            // Only a gated server has providers worth probing; token-only servers (and
            // older builds) skip the extra round-trip and keep today's exact behaviour.
            // A providers failure (404/transport) is swallowed → treated as no providers.
            var providers: [AuthProvider]?
            if status.authRequired == true {
              providers = (try? await rest.authProviders(url)) ?? nil
            }
            await send(.serverStatusResponse(.success(status), providers: providers))
          } catch {
            await send(.serverStatusResponse(.failure(asRESTError(error)), providers: nil))
          }
        }
        .cancellable(id: CancelID.statusCheck, cancelInFlight: true)

      case let .serverStatusResponse(.success(status), providers):
        let capability = ServerAuthCapability(from: status, providers: providers)
        state.capability = capability
        state.serverVersion = status.version
        state.status = .reachable(version: status.version)
        state.selectedOAuthProviderName = nil // a new server invalidates the old pick
        // Preselect the segment the server actually supports, password → oauth → token: a
        // mixed basic+nous server keeps password preselected (it is the lower-friction path
        // and mirrors the desktop), and token stays the fallback nobody is nudged toward.
        if capability.isPasswordAvailable {
          state.method = .password
        } else if capability.isOAuthAvailable {
          state.method = .oauth
        } else {
          state.method = .token
        }
        return .none

      case let .serverStatusResponse(.failure(error), _):
        state.capability = nil
        state.serverVersion = nil
        switch error {
        case .decoding: state.status = .notHermes
        // `.offline` is a transport failure like `.unreachable` — same footer (its
        // "trouble connecting to your agent?" help link is what's wanted here too).
        case .offline, .unreachable: state.status = .unreachable
        default: state.status = .failed(error.message)
        }
        return .none

      case let .oauthProviderTapped(provider):
        state.selectedOAuthProviderName = provider.name
        state.method = .oauth
        return .send(.connectTapped)

      case .connectTapped:
        guard let url = parseServerURL(state.serverURL) else {
          state.status = .invalidURL
          return .none
        }
        state.status = .validating
        switch state.method {
        case .token:
          // Token path — byte-identical to today: validate with one authenticated call,
          // then persist the token + server URL and signal the parent.
          let connection = ServerConnection(baseURL: url, token: state.token)
          return .run { [rest, keychain, preferences] send in
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
            } catch {
              await send(.tokenValidationResponse(.failure(asRESTError(error))))
              return
            }
            try? keychain.saveSession(.token(connection.token ?? ""))
            preferences.saveServerURL(connection.baseURL.absoluteString)
            await send(.tokenValidationResponse(.success(connection)))
          }

        case .password:
          // Password path: log in for cookies, validate them with one authenticated call,
          // then persist the cookie session + server URL and signal the parent.
          let provider = state.capability?.passwordProviderName ?? "basic"
          let username = state.username
          let password = state.password
          return .run { [rest, keychain, preferences] send in
            let cookieSession: CookieSession
            do {
              cookieSession = try await rest.passwordLogin(url, provider, username, password)
            } catch {
              await send(.passwordLoginResponse(.failure(asRESTError(error))))
              return
            }
            // Activate the captured cookies into the shared jar BEFORE the validating call —
            // otherwise the live REST transport reads an empty `.shared` and 401s.
            keychain.activateCookieSession(cookieSession)
            let connection = ServerConnection(baseURL: url, auth: .cookie(cookieSession))
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
            } catch {
              await send(.passwordLoginResponse(.failure(asRESTError(error))))
              return
            }
            try? keychain.saveSession(.cookie(cookieSession))
            preferences.saveServerURL(connection.baseURL.absoluteString)
            await send(.passwordLoginResponse(.success(connection)))
          }

        case .oauth:
          // Native PKCE path (#19): the browser leg returns a bearer pair, which is seeded
          // into the token store, validated with the same authenticated call the other two
          // regimes use, then persisted.
          let provider = state.activeOAuthProvider?.name
          return .run { [rest, keychain, preferences, oauthLogin, bearerTokens] send in
            let bearer: BearerSession
            do {
              bearer = try await oauthLogin.signIn(url, provider)
            } catch {
              // Nothing was seeded yet — no store to clean up.
              await send(.oauthLoginResponse(.failure(.login(asOAuthLoginError(error)))))
              return
            }
            // Seed BEFORE the validating call: a `.bearer` connection resolves its
            // `Authorization` header through the store, so an unseeded store would 401.
            await bearerTokens.seed(bearer, baseURL: url) { session in
              try keychain.saveSession(.bearer(session))
            }
            let connection = ServerConnection(baseURL: url, auth: .bearer(bearer))
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
            } catch {
              // Drain the half-built session: leaving it seeded would authenticate a later
              // request with credentials this screen never accepted.
              await bearerTokens.clear()
              await send(.oauthLoginResponse(.failure(.validation(asRESTError(error)))))
              return
            }
            try? keychain.saveSession(.bearer(bearer))
            preferences.saveServerURL(connection.baseURL.absoluteString)
            await send(.oauthLoginResponse(.success(connection)))
          }
        }

      case let .tokenValidationResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .tokenValidationResponse(.failure(error)):
        switch error {
        case .unauthorized: state.status = .invalidToken
        default: state.status = .failed(error.message)
        }
        return .none

      case let .passwordLoginResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .passwordLoginResponse(.failure(error)):
        switch error {
        // 401 from login (bad creds) or from the validating call (cookies rejected).
        case .unauthorized: state.status = .invalidCredentials
        // Surface server copy verbatim for the rest (429 rate-limit, 503 unreachable,
        // 404 unsupported provider, other) via `RESTError.message`.
        default: state.status = .failed(error.message)
        }
        return .none

      case let .oauthLoginResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .oauthLoginResponse(.failure(error)):
        switch error {
        // Dismissing the browser sheet is a decision, not a failure: back to the reachable
        // state exactly as it was, with no banner and no status copy.
        case .login(.cancelled):
          state.status = .reachable(version: state.serverVersion)
        // The bearer pair was minted but the server rejected it on the validating call.
        case .validation(.unauthorized):
          state.status = .invalidCredentials
        // Everything else surfaces verbatim — the gateway's reason, the timeout, a state
        // mismatch, or the REST copy from a failed validating call.
        default:
          state.status = .failed(error.message)
        }
        return .none

      case .delegate:
        return .none
      }
    }
  }
}

/// Normalize a thrown error from a REST call to a `RESTError` — the shared funnel the auth
/// reducers (`ConnectionFeature`, `ReauthFeature`, `ConnectionFailedFeature`, `AppFeature`)
/// use after every `rest.*` call: a typed `RESTError` passes through verbatim; anything else
/// goes through `RESTError(transport:)`, the same classifier the live client's own transport
/// catches use, so the offline/unreachable split survives a raw `URLError`.
func asRESTError(_ error: any Error) -> RESTError {
  error as? RESTError ?? RESTError(transport: error)
}

/// Lenient URL parsing: accept `host:port` by defaulting to `http://`.
func parseServerURL(_ string: String) -> URL? {
  let trimmed = string.trimmingCharacters(in: .whitespaces)
  guard !trimmed.isEmpty else { return nil }
  let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
  guard let url = URL(string: withScheme), url.host?.isEmpty == false else { return nil }
  return url
}
