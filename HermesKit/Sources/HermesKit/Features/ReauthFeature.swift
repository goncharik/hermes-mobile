import ComposableArchitecture
import Foundation

/// Re-authentication modal raised when a live (gated) session dies mid-use
/// (`ChatFeature` → `delegate(.sessionExpired)`). The server URL is fixed (the user is
/// already onboarded), the username is prefilled from the dead session's identity, and the
/// user re-enters their password (or token in token-mode) to mint a fresh `AuthSession`.
/// In the OAuth regime there is nothing to type at all: one button re-runs the native PKCE
/// browser leg and the fresh token payload's `user_id` decides same-user vs switch (#19).
///
/// Unlike onboarding there is **no URL probe / capability toggle** — the auth method is
/// fixed to whatever regime the expired session used. The reducer reuses the same
/// `passwordLogin` → validate effect as `ConnectionFeature`, then bubbles the outcome up so
/// `AppFeature` can route it (same user → resume in place; different user → switch).
@Reducer
public struct ReauthFeature {
  @ObservableState
  public struct State: Equatable {
    /// The server we re-authenticate against (fixed — the user is already onboarded).
    public var serverURL: URL
    /// The auth regime to re-authenticate with (mirrors the expired session's regime).
    public var method: AuthMethod
    /// The wire provider name for password login (e.g. `"basic"`) — carried from the
    /// expired cookie session so re-login hits the same provider. In OAuth mode it is the
    /// session provider the dead bearer pair came from (e.g. `"nous"`).
    public var provider: String
    /// The human label for `provider`, when the last capability probe supplied one. Empty
    /// falls back to the wire name (see `providerLabel`).
    public var providerDisplayName: String
    /// The identity of the expired session — prefilled, and the baseline for the
    /// same-user vs user-switch decision (cookie/password mode only).
    public var previousUsername: String
    /// The `user_id` carried by the expired bearer session — the OAuth regime's identity
    /// baseline. OAuth has no username to prefill: the browser leg collects the credentials
    /// and the fresh token payload reports who signed in, so this (NOT `previousUsername`)
    /// is what decides same-user vs user-switch for `.oauth` (#19).
    public var previousUserID: String
    public var username: String
    public var password: String
    public var token: String
    public var status: Status

    public init(
      serverURL: URL,
      method: AuthMethod,
      provider: String = "basic",
      providerDisplayName: String = "",
      previousUsername: String = "",
      previousUserID: String = "",
      username: String? = nil,
      password: String = "",
      token: String = "",
      status: Status = .idle
    ) {
      self.serverURL = serverURL
      self.method = method
      self.provider = provider
      self.providerDisplayName = providerDisplayName
      self.previousUsername = previousUsername
      self.previousUserID = previousUserID
      // Default the editable username to the expired session's identity (re-login prefill).
      self.username = username ?? previousUsername
      self.password = password
      self.token = token
      self.status = status
    }

    /// What to call the identity provider in the OAuth button ("Continue with …"). The
    /// server's display name when the probe supplied one, else the wire provider name.
    public var providerLabel: String {
      providerDisplayName.isEmpty ? provider : providerDisplayName
    }

    public enum Status: Equatable, Sendable {
      case idle
      case validating
      case invalidCredentials
      case failed(String)
    }

    public var canSubmit: Bool {
      guard status != .validating else { return false }
      switch method {
      case .password: return !username.isEmpty && !password.isEmpty
      case .token: return !token.isEmpty
      // Nothing to type — the browser leg collects the credentials (#19).
      case .oauth: return true
      }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case signInTapped
    case quitTapped
    /// Re-login succeeded: carries the fresh connection and whether the identity is unchanged
    /// (always `true` in token-mode, where identity compare is skipped).
    case reauthResponse(Result<Outcome, RESTError>)
    /// Native OAuth re-login outcome (#19). Kept separate from `reauthResponse` because its
    /// failure needs the two-leg split `OAuthFlowError` carries: a dismissed browser sheet
    /// is SILENT (no status, no delegate), which no `RESTError` can express. Success funnels
    /// straight back into `reauthResponse` so there is one success path.
    case oauthResponse(Result<Outcome, OAuthFlowError>)
    case delegate(Delegate)

    public struct Outcome: Equatable, Sendable {
      public var connection: ServerConnection
      /// `true` when the re-authenticated identity matches the expired session's (normalized
      /// username in cookie mode, `user_id` in bearer mode). Token-mode is always `true`
      /// (identity compare skipped).
      public var sameUser: Bool
    }

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// Re-auth succeeded — `AppFeature` resumes (same user) or switches (different user).
      case reauthenticated(connection: ServerConnection, sameUser: Bool)
      /// "Quit to start" — `AppFeature` performs a full logout back to onboarding.
      case quit
    }
  }

  @Dependency(\.hermesREST) var rest
  @Dependency(\.keychain) var keychain
  @Dependency(\.oauthLogin) var oauthLogin
  @Dependency(\.bearerTokens) var bearerTokens

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .quitTapped:
        return .send(.delegate(.quit))

      case .signInTapped:
        state.status = .validating
        let url = state.serverURL
        switch state.method {
        case .token:
          // Token re-auth: validate the new token with one authenticated call, persist it,
          // then bubble up. Identity compare is skipped (token mode has no username).
          let connection = ServerConnection(baseURL: url, token: state.token)
          return .run { [rest, keychain] send in
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
            } catch {
              await send(.reauthResponse(.failure(asRESTError(error))))
              return
            }
            try? keychain.saveSession(.token(connection.token ?? ""))
            await send(.reauthResponse(.success(.init(connection: connection, sameUser: true))))
          }

        case .password:
          // Password re-auth: log in for fresh cookies, validate them, persist the cookie
          // session, then decide same-user vs switch via the pure identity compare.
          let provider = state.provider
          let username = state.username
          let password = state.password
          let previous = state.previousUsername
          return .run { [rest, keychain] send in
            let cookieSession: CookieSession
            do {
              cookieSession = try await rest.passwordLogin(url, provider, username, password)
            } catch {
              await send(.reauthResponse(.failure(asRESTError(error))))
              return
            }
            // Swap the new rotated cookies into the shared jar BEFORE validating — otherwise
            // the validating call would send the stale (dead) cookies that triggered expiry.
            keychain.activateCookieSession(cookieSession)
            let connection = ServerConnection(baseURL: url, auth: .cookie(cookieSession))
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
            } catch {
              await send(.reauthResponse(.failure(asRESTError(error))))
              return
            }
            try? keychain.saveSession(.cookie(cookieSession))
            let sameUser = isSameUser(previous, cookieSession.username)
            await send(.reauthResponse(.success(.init(connection: connection, sameUser: sameUser))))
          }

        case .oauth:
          // Native PKCE re-login (#19) — the same three steps as `ConnectionFeature`'s OAuth
          // connect (browser leg → seed the store → validate), minus the server-URL save
          // (the user is already onboarded). Identity comes from the fresh token payload's
          // `user_id`, compared against the DEAD session's — never a username, which the
          // OAuth regime does not have.
          let provider = state.provider.isEmpty ? nil : state.provider
          let previous = state.previousUserID
          return .run { [rest, keychain, oauthLogin, bearerTokens] send in
            let bearer: BearerSession
            do {
              bearer = try await oauthLogin.signIn(url, provider)
            } catch {
              // Nothing was seeded yet — no store to clean up.
              await send(.oauthResponse(.failure(.login(asOAuthLoginError(error)))))
              return
            }
            // Seed BEFORE validating: the dead pair is still in the store, and a `.bearer`
            // request resolves its `Authorization` header through it — validating without
            // this swap would re-send the very credentials that expired.
            await bearerTokens.seed(bearer, baseURL: url) { session in
              try keychain.saveSession(.bearer(session))
            }
            let connection = ServerConnection(baseURL: url, auth: .bearer(bearer))
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
            } catch {
              // Drain the half-built session rather than leaving credentials the server
              // just rejected wired up for the next request.
              await bearerTokens.clear()
              await send(.oauthResponse(.failure(.validation(asRESTError(error)))))
              return
            }
            try? keychain.saveSession(.bearer(bearer))
            let sameUser = isSameUser(previous, bearer.userID)
            await send(.oauthResponse(.success(.init(connection: connection, sameUser: sameUser))))
          }
        }

      case let .reauthResponse(.success(outcome)):
        return .send(.delegate(.reauthenticated(
          connection: outcome.connection, sameUser: outcome.sameUser
        )))

      case let .reauthResponse(.failure(error)):
        switch error {
        // 401 from login (bad creds) or from the validating call (token/cookies rejected).
        case .unauthorized: state.status = .invalidCredentials
        // Surface server copy verbatim for the rest (429 / 503 / 404 / other).
        default: state.status = .failed(error.message)
        }
        return .none

      case let .oauthResponse(.success(outcome)):
        // One success funnel — the delegate hand-off is identical for every regime.
        return .send(.reauthResponse(.success(outcome)))

      case let .oauthResponse(.failure(error)):
        switch error {
        // The user dismissed the browser sheet: not a failure, and not a verdict on the
        // dead session either. Back to `.idle` with NO status copy and NO delegate — the
        // sheet stays up so they can retry or take "Quit to start".
        case .login(.cancelled):
          state.status = .idle
        // A fresh pair the server refused on the validating call — the identity itself was
        // rejected (view copy branches on `.oauth`).
        case .validation(.unauthorized):
          state.status = .invalidCredentials
        // Everything else verbatim: the gateway's reason, a timeout, a state mismatch, or
        // the REST copy from a failed validating call.
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

/// Pure same-user test for re-auth routing: case-/whitespace-insensitive identity equality —
/// a username in the cookie regime, the token payload's `user_id` in the bearer one.
/// Empty-vs-empty counts as the same user (token-mode callers skip this entirely). Used to
/// decide whether a successful re-auth resumes the current chat (same user) or switches
/// accounts (different user → pop + reload + clear identity-scoped prefs).
public func isSameUser(_ lhs: String, _ rhs: String) -> Bool {
  func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
  return normalize(lhs) == normalize(rhs)
}
