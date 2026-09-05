import ComposableArchitecture
import Foundation

/// Re-authentication modal raised when a live (gated) session dies mid-use
/// (`ChatFeature` → `delegate(.sessionExpired)`). The server URL is fixed (the user is
/// already onboarded), the username is prefilled from the dead session's identity, and the
/// user re-enters their password (or token in token-mode) to mint a fresh `AuthSession`.
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
    /// expired cookie session so re-login hits the same provider.
    public var provider: String
    /// The identity of the expired session — prefilled, and the baseline for the
    /// same-user vs user-switch decision (cookie/password mode only).
    public var previousUsername: String
    public var username: String
    public var password: String
    public var token: String
    public var status: Status

    public init(
      serverURL: URL,
      method: AuthMethod,
      provider: String = "basic",
      previousUsername: String = "",
      username: String? = nil,
      password: String = "",
      token: String = "",
      status: Status = .idle
    ) {
      self.serverURL = serverURL
      self.method = method
      self.provider = provider
      self.previousUsername = previousUsername
      // Default the editable username to the expired session's identity (re-login prefill).
      self.username = username ?? previousUsername
      self.password = password
      self.token = token
      self.status = status
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
    case delegate(Delegate)

    public struct Outcome: Equatable, Sendable {
      public var connection: ServerConnection
      /// `true` when the re-authenticated identity matches the expired session's username
      /// (normalized). Token-mode is always `true` (identity compare skipped).
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
          // Placeholder until the OAuth re-login lands (#19, Task 11). Unreachable today:
          // `AppFeature.makeReauthState` never builds an `.oauth` state yet, and returning
          // to `.idle` keeps a stray tap from stranding the sheet on a spinner.
          state.status = .idle
          return .none
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

      case .delegate:
        return .none
      }
    }
  }
}

/// Pure same-user test for re-auth routing: case-/whitespace-insensitive username equality.
/// Empty-vs-empty counts as the same user (token-mode callers skip this entirely). Used to
/// decide whether a successful re-auth resumes the current chat (same user) or switches
/// accounts (different user → pop + reload + clear identity-scoped prefs).
public func isSameUser(_ lhs: String, _ rhs: String) -> Bool {
  func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
  return normalize(lhs) == normalize(rhs)
}
