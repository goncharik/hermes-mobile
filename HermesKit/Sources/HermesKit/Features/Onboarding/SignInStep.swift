import ComposableArchitecture
import Foundation

/// The onboarding Sign in step (#136): the server already answered the Server step's probe,
/// so this step only collects credentials for the regime that server offers and connects.
///
/// It cannot exist without a `ServerProbe`, so "sign-in UI with no capability" is
/// unrepresentable. The three auth effects are moved verbatim from the old one-screen
/// `ConnectionFeature.connectTapped`, against `probe.baseURL` — the candidate that actually
/// answered, so a `:9119` fallback is what gets saved:
/// - **token** — validate the pasted token with one authenticated call, then persist the
///   token + server URL (byte-identical to the legacy single-token path).
/// - **password** — `POST /auth/password-login` for a cookie session, activate the cookies,
///   validate them with the same authenticated call, then persist.
/// - **OAuth** — the shared native PKCE leg (`performNativeOAuthLogin`, #19), then save the
///   server URL. Popping this step (swipe-back or Change) cancels the attempt with the
///   element's effects; cancellation never drains the shared token store.
@Reducer
public struct SignInStep {
  @ObservableState
  public struct State: Equatable {
    /// "Other ways to sign in" — reveals the token field under the two non-token layouts.
    public var isShowingOtherWays = false
    public var password = ""
    public let probe: ServerProbe
    public var status: Status = .idle
    public var token: String
    public var username = ""

    public init(probe: ServerProbe, prefilledToken: String? = nil) {
      self.probe = probe
      self.token = prefilledToken ?? ""
    }

    public enum Status: Equatable, Sendable {
      /// A wait-it-out verdict or a browser-leg failure, server/REST copy verbatim.
      case failed(String)
      case idle
      /// A 401 for the attempt made with that method: the password login or its validating
      /// call, the token's validating call, or an OAuth validating call.
      case invalidCredentials(AuthMethod)
      case validating(AuthMethod)

      public var isValidating: Bool {
        if case .validating = self { return true }
        return false
      }
    }

    /// What the step renders, derived purely from the probed capability. Mirrors the old
    /// one-screen preselect (password → OAuth → token) and its OAuth positive-evidence rule:
    /// provider buttons need an OAuth provider AND `native_pkce`.
    public enum Layout: Equatable, Sendable {
      /// Username + password first; provider buttons (possibly none) under "or".
      case password(oauthProviders: [AuthProvider])
      /// Provider buttons only — the browser leg collects the credentials.
      case oauthOnly([AuthProvider])
      /// The token field is the way in, with the reason the view explains.
      case token(reason: TokenReason)
    }

    public enum TokenReason: Equatable, Sendable {
      /// OAuth providers exist but the gateway is too old for the native flow
      /// (`oauthNeedsNewerAgentFor` names them).
      case oauthNeedsNewerAgent
      /// The server is not gated (or gated with no providers): token is its only regime.
      case tokenOnlyServer
    }

    public var layout: Layout {
      let capability = probe.capability
      let offered = capability.isOAuthAvailable ? capability.oauthProviders : []
      if capability.isPasswordAvailable { return .password(oauthProviders: offered) }
      if !offered.isEmpty { return .oauthOnly(offered) }
      if oauthNeedsNewerAgentFor != nil { return .token(reason: .oauthNeedsNewerAgent) }
      return .token(reason: .tokenOnlyServer)
    }

    /// Display names of the OAuth providers this gateway advertises but cannot drive (no
    /// `native_pkce`), joined with " or "; `nil` when there are none. Both the password and
    /// the token layout show it as a notice.
    public var oauthNeedsNewerAgentFor: String? {
      let capability = probe.capability
      guard !capability.oauthProviders.isEmpty, !capability.supportsNativeFlow else { return nil }
      return capability.oauthProviders.map(\.displayName).joined(separator: " or ")
    }

    /// The server card's one-line summary of how this agent signs in: "Session token", or
    /// "Password" and/or the offered providers' display names (prototype `methodSummary`).
    public var methodSummary: String {
      switch layout {
      case .token:
        return "Session token"
      case let .oauthOnly(providers):
        return providers.map(\.displayName).joined(separator: ", ")
      case let .password(providers):
        guard !providers.isEmpty else { return "Password" }
        return "Password or " + providers.map(\.displayName).joined(separator: ", ")
      }
    }

    /// The offered providers' display names joined with " or " — the Sign in subtitle's
    /// "This agent uses your … account."
    public var oauthProviderNames: String {
      oauthProviders.map(\.displayName).joined(separator: " or ")
    }

    /// The OAuth providers this step offers buttons for (empty without positive evidence).
    public var oauthProviders: [AuthProvider] {
      switch layout {
      case let .password(providers), let .oauthOnly(providers): providers
      case .token: []
      }
    }

    /// Whether the token field is on screen: always in the token layout, behind "Other ways
    /// to sign in" otherwise.
    public var showsTokenField: Bool {
      if case .token = layout { return true }
      return isShowingOtherWays
    }

    // Only an attempt in flight blocks a retry — this step has no URL field whose edit used
    // to reset a `.failed` status.

    public var canSignInWithOAuth: Bool { !status.isValidating && !oauthProviders.isEmpty }

    public var canSignInWithPassword: Bool {
      guard !status.isValidating, case .password = layout else { return false }
      return !username.isEmpty && !password.isEmpty
    }

    public var canSignInWithToken: Bool {
      !status.isValidating && showsTokenField && !token.isEmpty
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    /// "Change" on the server card — pops back to the Server step.
    case changeServerButtonTapped
    case delegate(Delegate)
    /// Native OAuth login → bearer pair seeded + validated → ready to connect.
    case oauthLoginResponse(Result<ServerConnection, OAuthFlowError>)
    /// "Continue with <provider>" — the provider button IS the sign-in action.
    case oauthProviderButtonTapped(AuthProvider)
    case otherWaysButtonTapped
    /// Password login → cookie session validated → ready to connect.
    case passwordLoginResponse(Result<ServerConnection, RESTError>)
    case passwordSignInButtonTapped
    case tokenSignInButtonTapped
    case tokenValidationResponse(Result<ServerConnection, RESTError>)

    @CasePathable
    public enum Delegate {
      case connected(ServerConnection)
    }
  }

  private enum CancelID { case oauthLogin }

  @Dependency(\.bearerTokens) var bearerTokens
  @Dependency(\.dismiss) var dismiss
  @Dependency(\.hermesREST) var rest
  @Dependency(\.keychain) var keychain
  @Dependency(\.oauthLogin) var oauthLogin
  @Dependency(\.preferences) var preferences

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .changeServerButtonTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .delegate:
        return .none

      case let .oauthLoginResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .oauthLoginResponse(.failure(error)):
        switch error {
        // Dismissing the browser sheet is a decision, not a failure: back to idle with no
        // banner and no status copy.
        case .login(.cancelled):
          state.status = .idle
        // The bearer pair was minted but the server rejected it on the validating call.
        case .validation(.unauthorized):
          state.status = .invalidCredentials(.oauth)
        // Everything else surfaces verbatim — the gateway's reason, the timeout, a state
        // mismatch, or the REST copy from a failed validating call.
        default:
          state.status = .failed(error.message)
        }
        return .none

      case let .oauthProviderButtonTapped(provider):
        // Positive evidence only: a provider this step doesn't offer never starts a sign-in.
        guard state.oauthProviders.contains(provider) else { return .none }
        state.status = .validating(.oauth)
        // Native PKCE path (#19) — the shared login leg, plus this step's own tail: the
        // server URL is saved only once a sign-in actually succeeded.
        let url = state.probe.baseURL
        let providerName = provider.name
        return .run { [bearerTokens, keychain, oauthLogin, preferences, rest] send in
          let outcome = await performNativeOAuthLogin(
            baseURL: url,
            provider: providerName,
            rest: rest,
            keychain: keychain,
            oauthLogin: oauthLogin,
            bearerTokens: bearerTokens
          )
          switch outcome {
          case let .success(success):
            preferences.saveServerURL(success.connection.baseURL.absoluteString)
            await send(.oauthLoginResponse(.success(success.connection)))
          case let .failure(error):
            await send(.oauthLoginResponse(.failure(error)))
          }
        }
        // ONE attempt at a time, and only ever the current one: this effect outlives the
        // browser sheet by minutes, and its tail persists credentials and connects. A second
        // provider tap supersedes the first (`cancelInFlight`); popping the step cancels it.
        .cancellable(id: CancelID.oauthLogin, cancelInFlight: true)

      case .otherWaysButtonTapped:
        state.isShowingOtherWays.toggle()
        return .none

      case let .passwordLoginResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .passwordLoginResponse(.failure(error)):
        switch error {
        // 401 from login (bad creds) or from the validating call (cookies rejected).
        case .unauthorized: state.status = .invalidCredentials(.password)
        // Surface server copy verbatim for the rest (429 rate-limit, 503 unreachable,
        // 404 unsupported provider, other) via `RESTError.message`.
        default: state.status = .failed(error.message)
        }
        return .none

      case .passwordSignInButtonTapped:
        // Password path: log in for cookies, validate them with one authenticated call,
        // then persist the cookie session + server URL and signal the parent.
        guard state.canSignInWithPassword else { return .none }
        state.status = .validating(.password)
        let url = state.probe.baseURL
        let provider = state.probe.capability.passwordProviderName ?? "basic"
        let username = state.username
        let password = state.password
        return .run { [keychain, preferences, rest] send in
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
            _ = try await rest.sessions(connection, 1, 0, .recent, .all)
          } catch {
            await send(.passwordLoginResponse(.failure(asRESTError(error))))
            return
          }
          // Popped (Sign in abandoned) while validating: the success would be dropped, so
          // nothing may land on disk either.
          guard !Task.isCancelled else { return }
          try? keychain.saveSession(.cookie(cookieSession))
          preferences.saveServerURL(connection.baseURL.absoluteString)
          await send(.passwordLoginResponse(.success(connection)))
        }

      case .tokenSignInButtonTapped:
        // Token path — byte-identical to the legacy one: validate with one authenticated
        // call, then persist the token + server URL and signal the parent.
        guard state.canSignInWithToken else { return .none }
        state.status = .validating(.token)
        let connection = ServerConnection(baseURL: state.probe.baseURL, token: state.token)
        return .run { [keychain, preferences, rest] send in
          do {
            _ = try await rest.sessions(connection, 1, 0, .recent, .all)
          } catch {
            await send(.tokenValidationResponse(.failure(asRESTError(error))))
            return
          }
          guard !Task.isCancelled else { return }  // popped: see the password path
          try? keychain.saveSession(.token(connection.token ?? ""))
          preferences.saveServerURL(connection.baseURL.absoluteString)
          await send(.tokenValidationResponse(.success(connection)))
        }

      case let .tokenValidationResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .tokenValidationResponse(.failure(error)):
        switch error {
        case .unauthorized: state.status = .invalidCredentials(.token)
        default: state.status = .failed(error.message)
        }
        return .none
      }
    }
  }
}
