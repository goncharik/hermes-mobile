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
/// 3. Persist the resulting `AuthSession` (token or cookie) in the Keychain and signal
///    `.delegate(.connected)`.

/// Which auth regime the user is entering credentials for. Driven by the server's
/// capability probe (see `ServerAuthCapability`) but ultimately the user's segment choice.
public enum AuthMethod: String, Equatable, Sendable {
  case password
  case token
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
    public var status: Status

    public init(
      serverURL: String = "",
      token: String = "",
      username: String = "",
      password: String = "",
      method: AuthMethod = .token,
      capability: ServerAuthCapability? = nil,
      status: Status = .idle
    ) {
      self.serverURL = serverURL
      self.token = token
      self.username = username
      self.password = password
      self.method = method
      self.capability = capability
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

    /// True on a gated server where the token path is a poor fit (UI may de-emphasize it).
    public var isTokenDeemphasized: Bool { capability?.isGated ?? false }

    public var canConnect: Bool {
      guard status != .validating else { return false }
      switch status {
      case .reachable, .invalidToken, .invalidCredentials: break // allow a retry
      default: return false
      }
      switch method {
      case .password: return !username.isEmpty && !password.isEmpty
      case .token: return !token.isEmpty
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
    /// `/api/status` result plus the (optional) `/api/auth/providers` probe, folded so the
    /// capability is computed in one place.
    case serverStatusResponse(Result<ServerStatus, RESTError>, providers: [AuthProvider]?)
    case tokenValidationResponse(Result<ServerConnection, RESTError>)
    /// Password login → cookie session validated → ready to persist + connect.
    case passwordLoginResponse(Result<ServerConnection, RESTError>)
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
        state.status = .reachable(version: status.version)
        // Preselect the segment the server actually supports: password when available,
        // token otherwise. Don't override a token-only server's disabled Password.
        // (The OAuth segment joins this order in a later step — #19.)
        state.method = capability.isPasswordAvailable ? .password : .token
        return .none

      case let .serverStatusResponse(.failure(error), _):
        state.capability = nil
        switch error {
        case .decoding: state.status = .notHermes
        // `.offline` is a transport failure like `.unreachable` — same footer (its
        // "trouble connecting to your agent?" help link is what's wanted here too).
        case .offline, .unreachable: state.status = .unreachable
        default: state.status = .failed(error.message)
        }
        return .none

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
