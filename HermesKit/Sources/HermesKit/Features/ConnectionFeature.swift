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

/// What a completed native OAuth login hands back: the validated connection and the bearer
/// pair AS PERSISTED (which is not necessarily the freshly minted one — see below).
struct NativeOAuthLoginSuccess: Equatable, Sendable {
  var connection: ServerConnection
  var bearer: BearerSession
}

/// The native PKCE login leg (#19), shared by onboarding (`ConnectionFeature`) and re-auth
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
///    writes that pair in one actor-isolated step, so a rotation cannot slip between them.
/// 4. A CANCELLED attempt touches NOTHING — it neither drains nor persists. The store and the
///    Keychain entry are process-wide, so an abandoned attempt (a second provider tap, an
///    edited server URL, a logout tearing the screen down) that cleaned up after itself would
///    be cleaning up after whatever superseded it.
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
  let minted: BearerSession
  do {
    minted = try await oauthLogin.signIn(baseURL, provider)
  } catch {
    // Nothing was seeded yet — no store to clean up.
    return .failure(.login(asOAuthLoginError(error)))
  }
  await bearerTokens.seed(minted, baseURL: baseURL)
  do {
    let probe = ServerConnection(baseURL: baseURL, auth: .bearer(minted))
    _ = try await rest.sessions(probe, 1, 0, .recent)
  } catch {
    // Cancellation is not a verdict on these credentials, and the store is SHARED: this
    // attempt was superseded (a second provider tap) or the whole screen is going away (a
    // logout, which needs the store seeded for its own authenticated hops). Draining here
    // would take out a newer attempt's pair, or silently turn `unregisterPush`/`logout` into
    // no-ops. Leave the store as it is and report the silent-cancel verdict.
    guard !isCancellation(error) else { return .failure(.login(.cancelled)) }
    await bearerTokens.clear()
    return .failure(.validation(asRESTError(error)))
  }
  // Validated — but for an attempt nobody is waiting on any more (the effect was cancelled
  // between the response and here), arming the hook and writing the Keychain would overwrite
  // whatever superseded it, up to and including an entry a logout has just deleted.
  guard !Task.isCancelled else { return .failure(.login(.cancelled)) }
  let persisted = await bearerTokens.attachPersistence { session in
    try keychain.saveSession(.bearer(session))
  }
  // `nil` means the store was drained mid-flight (a concurrent logout) — nothing to persist.
  let bearer = persisted ?? minted
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
      return providers.first { $0.name == name }
    }

    /// The OAuth segment's label: the provider's own display name when the server advertises
    /// exactly one (the common case — "Nous Research"), a neutral "OAuth" when several would
    /// not fit a segment. Server-supplied text only, never a brand asset (App Store 5.2.1).
    public var oauthSegmentLabel: String {
      let providers = oauthProviders
      return providers.count == 1 ? providers[0].displayName : "OAuth"
    }

    /// The server advertises OAuth providers but this gateway doesn't serve the native
    /// sign-in endpoints (`native_pkce` missing from `auth_flows`), so `isOAuthEnabled` hides
    /// the segment. The footer has to say why — otherwise the token-only hint would claim the
    /// server "only supports token sign-in", which isn't true of the server, only of what
    /// this app can drive.
    public var hasUnsupportedOAuthProviders: Bool {
      guard let capability else { return false }
      return !capability.oauthProviders.isEmpty && !capability.supportsNativeFlow
    }

    /// Display names of the providers this app can't drive, for the too-old-gateway hint.
    public var unsupportedOAuthProviderNames: String {
      (capability?.oauthProviders ?? []).map(\.displayName).joined(separator: " or ")
    }

    /// True on a gated server where the token path is a poor fit (UI may de-emphasize it).
    public var isTokenDeemphasized: Bool { capability?.isGated ?? false }

    /// Whether the auth picker renders a Password segment at all.
    ///
    /// On a token-only server WITHOUT OAuth the segment stays visible-but-inert and
    /// `locksMethodPicker` disables the whole control — the long-standing way to express
    /// "you may not pick this" in a segmented picker. That trick can't be used once OAuth is
    /// on screen (the control has to stay live so Token ↔ provider switching works), so
    /// there the unavailable Password segment is omitted instead: a visible segment that
    /// silently does nothing would be worse than an absent one.
    public var showsPasswordSegment: Bool { isPasswordEnabled || !isOAuthEnabled }

    /// Whether the auth picker is disabled outright — see `showsPasswordSegment`. With OAuth
    /// available the same lock would trap the user in whichever segment they landed on.
    public var locksMethodPicker: Bool {
      !isPasswordEnabled && method == .token && !isOAuthEnabled
    }

    /// Which capability hint belongs under the sign-in section. The copy lives in the view;
    /// only the choice between them is policy.
    public enum MethodHint: Equatable, Sendable {
      case none
      /// Reassurance that the browser leg uses the dashboard account.
      case oauth
      /// Providers exist, but the gateway is too old for the native flow — so token really
      /// is the only way in here, and the reason is actionable (update the agent).
      case oauthNeedsNewerAgent
      /// Token-only server: Password is disabled — explain why.
      case tokenOnly
      /// Gated server: token is a poor fit — nudge toward password.
      case tokenDeemphasized
    }

    public var methodHint: MethodHint {
      if method == .oauth { return .oauth }
      guard method == .token else { return .none }
      if !isPasswordEnabled, hasUnsupportedOAuthProviders { return .oauthNeedsNewerAgent }
      if !isPasswordEnabled, capability != nil { return .tokenOnly }
      if isTokenDeemphasized { return .tokenDeemphasized }
      return .none
    }

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

  private enum CancelID { case urlDebounce, statusCheck, oauthLogin }

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
        // …and so does it invalidate an OAuth attempt still running against the OLD URL: the
        // browser leg can take minutes while this field stays editable, and its tail persists
        // credentials, saves the server URL and connects. Retype the URL and that attempt
        // must not be able to land. (Cancelling never drains the store — see
        // `performNativeOAuthLogin`.)
        let dropStaleSignIn: Effect<Action> = .cancel(id: CancelID.oauthLogin)
        guard !state.serverURL.trimmingCharacters(in: .whitespaces).isEmpty else {
          return .merge(dropStaleSignIn, .cancel(id: CancelID.urlDebounce))
        }
        // Auto-check after the user stops typing (covers paste too).
        return .merge(
          dropStaleSignIn,
          .run { [clock] send in
            try await clock.sleep(for: .milliseconds(600))
            await send(.checkServer)
          }
          .cancellable(id: CancelID.urlDebounce, cancelInFlight: true)
        )

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
        // A cleared capability hides the OAuth segment, so a selection left on `.oauth`
        // would render a picker with no matching tag, no provider buttons and no Connect
        // button — unrecoverable except by tapping another segment. Fall back to the
        // default, mirroring the success branch's preselect.
        if state.method == .oauth { state.method = .token }
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
          // Native PKCE path (#19) — the shared login leg, plus this screen's own tail: the
          // server URL is saved only once a sign-in actually succeeded.
          let provider = state.activeOAuthProvider?.name
          return .run { [rest, keychain, preferences, oauthLogin, bearerTokens] send in
            let outcome = await performNativeOAuthLogin(
              baseURL: url,
              provider: provider,
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
          // browser sheet by minutes, and its tail persists credentials and connects. A
          // second provider tap supersedes the first (`cancelInFlight`), and editing the
          // server URL cancels it outright.
          .cancellable(id: CancelID.oauthLogin, cancelInFlight: true)
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
