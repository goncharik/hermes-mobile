import ComposableArchitecture
import DependenciesMacros
import Foundation
import os

// MARK: - Connection & status

/// Where and how to reach a Hermes server. `auth` carries the regime (token, cookie, or
/// bearer); the unauthenticated reachability probe (`/api/status`) goes through
/// `status(baseURL:)` without a `ServerConnection`.
public struct ServerConnection: Equatable, Sendable {
  public var baseURL: URL
  public var auth: AuthSession

  public init(baseURL: URL, auth: AuthSession) {
    self.baseURL = baseURL
    self.auth = auth
  }

  /// Convenience for the common token-mode case so existing call sites stay byte-identical.
  public init(baseURL: URL, token: String) {
    self.init(baseURL: baseURL, auth: .token(token))
  }

  /// The session token when authenticating in `.token` mode; `nil` in `.cookie` mode (which
  /// uses the cookie jar) and `.bearer` mode (whose access token is owned and rotated by
  /// `BearerTokenStore`, never read from here). Drives the existing `X-Hermes-Session-Token`
  /// REST/WS paths. Setting a value switches the connection into `.token` mode (token-mode
  /// editing in Settings); setting `nil` is ignored (the other regime is the source of
  /// truth then).
  public var token: String? {
    get { auth.token }
    set { if let newValue { auth = .token(newValue) } }
  }
}

public enum SessionOrder: String, Sendable {
  case created
  case recent
}

/// How ONE outgoing REST request authenticates.
///
/// The transport helpers (`get`/`postJSON`/`send`) take this instead of an optional token
/// string, so the auth regime is resolved exactly once per request — by
/// ``resolveAuth(for:session:tokenStore:)`` — and the header-setting code below is the only
/// place either auth header is written.
///
/// **Backward-compatibility guard:** `.sessionToken` must stay byte-identical to the legacy
/// single-token path (`X-Hermes-Session-Token`, value verbatim, no `Authorization`), and
/// `.none` must send neither header — a `.cookie` request is authenticated by the URLSession
/// cookie jar. Both are pinned by tests in `HermesRESTClientTests`.
public enum RequestAuth: Equatable, Sendable {
  /// No auth header at all: the public probes (`/api/status`, `/api/auth/providers`), the
  /// native-flow token endpoints, and every `.cookie` request (the jar carries it).
  case none
  /// `.token` regime — `X-Hermes-Session-Token: <token>`.
  case sessionToken(String)
  /// `.bearer` regime — `Authorization: Bearer <access_token>`, where the token came from
  /// `BearerTokenStore.validAccessToken` and is therefore known-fresh.
  case bearer(String)

  /// The single place an auth header is attached to a request.
  func apply(to request: inout URLRequest) {
    switch self {
    case .none:
      break
    case let .sessionToken(token):
      request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
    case let .bearer(token):
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
  }
}

/// Subset of `/api/status` we use for the reachability/health check (lenient).
public struct ServerStatus: Equatable, Sendable, Decodable {
  public var version: String?
  public var gatewayRunning: Bool?
  public var gatewayState: String?
  public var activeSessions: Int?
  /// `true` when the server is in the gated (password/OAuth) regime; absent on older
  /// servers (treat absent/`false` as token-only).
  public var authRequired: Bool?
  /// Provider names advertised by the server (e.g. `["basic"]`); absent on older servers.
  public var authProviders: [String]?
  /// Interactive login flows the gate supports — gated servers report `["cookie"]`, plus
  /// `"native_pkce"` once any interactive session provider is registered. Absent on older
  /// gateways (treat absent as "no native flow": the OAuth segment needs positive evidence).
  public var authFlows: [String]?

  enum CodingKeys: String, CodingKey {
    case version
    case gatewayRunning = "gateway_running"
    case gatewayState = "gateway_state"
    case activeSessions = "active_sessions"
    case authRequired = "auth_required"
    case authProviders = "auth_providers"
    case authFlows = "auth_flows"
  }
}

public enum RESTError: Error, Equatable, Sendable {
  case unauthorized          // 401 — token missing/invalid, or bad password-login creds
  case notFound              // 404 — also an unknown/unsupported password provider
  case rateLimited           // 429 — too many login attempts (10/min/IP)
  case serviceUnavailable    // 503 — auth provider unreachable
  /// Other non-2xx. `detail` carries the server's body verbatim when present (JSON
  /// `{"detail": …}`, else trimmed plain-text body) so callers can surface it.
  case server(status: Int, detail: String? = nil)
  /// The device itself has no usable network (airplane mode, Wi-Fi/cellular off, data
  /// disallowed). Split out of `.unreachable` so the launch connection-failed screen can
  /// tell "you're offline" from "the server didn't answer" — see `init(transport:)`.
  case offline
  case unreachable           // transport failure / non-HTTP response
  case decoding              // 2xx body didn't match the expected shape
  case transcriptionFailed(String) // 2xx but `{ok:false}` — carries the server's reason

  /// Map a raw transport failure (what `URLSession` throws) to a `RESTError`. Only the
  /// URLError codes that mean *this device has no network at all* become `.offline`;
  /// everything else — timeout, DNS failure, connection refused, TLS, cancellation, a
  /// non-`URLError` — stays `.unreachable`, because from the client's point of view the
  /// network was usable and the server simply didn't answer.
  ///
  /// Only ever hand this a RAW transport failure: an already-typed `RESTError` is not a
  /// `URLError`, so it would be flattened to `.unreachable`. Reducers normalise via
  /// `asRESTError`, which checks the typed case first and then defers here.
  public init(transport error: any Error) {
    guard let urlError = error as? URLError else {
      self = .unreachable
      return
    }
    switch urlError.code {
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
      self = .offline
    default:
      self = .unreachable
    }
  }

  /// The definitive "this agent lacks the endpoint" verdict for capability gating —
  /// usually a plain 404, with one wrinkle: when the path exists for other verbs (e.g.
  /// `/api/sessions/{id}` serves `PATCH`/`GET` on older agents), an unsupported method
  /// answers **405 Method Not Allowed** instead, so both count. Callers flip their
  /// `*Supported` flag off this SILENTLY (no banner), like the other capability gates.
  public var isMissingEndpointVerdict: Bool {
    switch self {
    case .notFound, .server(status: 405, detail: _): true
    default: false
    }
  }

  public var message: String {
    switch self {
    case .unauthorized: "Invalid or missing token."
    case .notFound: "Not found."
    case .rateLimited: "Too many login attempts. Try again shortly."
    case .serviceUnavailable: "The auth provider is unreachable. Try again later."
    // Prefer the server's detail verbatim (e.g. an Add-profile 400 reason); fall back
    // to the generic status message when the body was empty/unparseable.
    case let .server(status, detail):
      if let detail, !detail.isEmpty { detail } else { "Server error (\(status))." }
    case .offline: "No internet connection."
    case .unreachable: "Couldn’t reach the server."
    case .decoding: "Unexpected response — is this a Hermes server?"
    case let .transcriptionFailed(reason): reason.isEmpty ? "Couldn’t transcribe the audio." : reason
    }
  }
}

// MARK: - Client

@DependencyClient
public struct HermesRESTClient: Sendable {
  /// Unauthenticated reachability/health probe.
  public var status: @Sendable (_ baseURL: URL) async throws -> ServerStatus
  /// Public capability probe — `GET /api/auth/providers` → `[{name, display_name,
  /// supports_password}]`. Returns `nil` on older servers that 404 this endpoint (treat as
  /// token-only); other transport/HTTP errors still throw.
  public var authProviders: @Sendable (_ baseURL: URL) async throws -> [AuthProvider]?
  /// Username/password login — `POST /auth/password-login` JSON `{provider, username,
  /// password}`. On `200` captures the `Set-Cookie` jar into a `CookieSession` (cookies +
  /// username + provider) and returns it. Errors map to `RESTError`: `401` invalid creds,
  /// `429` rate-limited, `503` provider unreachable, `404` unknown/unsupported provider.
  public var passwordLogin: @Sendable (_ baseURL: URL, _ provider: String, _ username: String, _ password: String) async throws -> CookieSession
  /// Redeem a native-flow authorization code — `POST /auth/native/token` `{code,
  /// code_verifier}` → the bearer token set. Unauthenticated (the verifier IS the
  /// credential). Any gateway rejection is a generic 400 → `RESTError.server(400, detail)`.
  public var nativeTokenExchange: @Sendable (_ baseURL: URL, _ code: String, _ verifier: String) async throws -> BearerSession
  /// Rotate the bearer token pair — `POST /auth/native/refresh` `{refresh_token, provider}`.
  /// 401 → `.unauthorized` (the refresh token is dead), 503 → `.serviceUnavailable` (keep
  /// the tokens and retry). Callers do NOT invoke this directly: `BearerTokenStore` owns the
  /// rotation and this is the transport it is handed.
  public var nativeRefresh: @Sendable (_ baseURL: URL, _ session: BearerSession) async throws -> BearerSession
  /// Best-effort `POST /auth/logout`, called only for the `.bearer` regime
  /// (`AppFeature.serverSideLogout`). Non-throwing BY DESIGN — see
  /// the live implementation for why this is the one call that swallows its failure.
  ///
  /// Call it BEFORE `BearerTokenStore.clear()`: once the store is drained the request has
  /// nothing to authenticate with and is skipped (silently, like any other failure).
  public var logout: @Sendable (_ connection: ServerConnection) async -> Void = { _ in }
  public var sessions: @Sendable (_ connection: ServerConnection, _ limit: Int, _ offset: Int, _ order: SessionOrder) async throws -> [Session]
  /// Just the archived (soft-hidden) sessions — `GET /api/sessions?archived=only`.
  public var archivedSessions: @Sendable (_ connection: ServerConnection, _ limit: Int, _ offset: Int) async throws -> [Session]
  public var search: @Sendable (_ connection: ServerConnection, _ query: String) async throws -> [Session]
  /// Soft-hide (archive) or restore a session — `PATCH /api/sessions/{id}` `{"archived":…}`.
  /// Pass `profile` (non-default) to scope to that profile (added to both query and body);
  /// `nil` → today's exact request.
  public var archive: @Sendable (_ connection: ServerConnection, _ id: String, _ archived: Bool, _ profile: String?) async throws -> Void
  /// Set the shared unread flag — `PATCH /api/sessions/{id}` `{"unread":…}`. Sending
  /// `false` on every open both acknowledges current activity and starts tracking a legacy
  /// row whose server watermark is still nil. `profile` follows the archive/rename rule.
  public var setUnread: @Sendable (_ connection: ServerConnection, _ id: String, _ unread: Bool, _ profile: String?) async throws -> Void
  /// Rename a session — `PATCH /api/sessions/{id}` `{"title":…}`. An empty title clears it.
  /// The server may reject with 400 (too long / invalid chars / duplicate).
  /// Pass `profile` (non-default) to scope to that profile (added to both query and body);
  /// `nil` → today's exact request.
  public var rename: @Sendable (_ connection: ServerConnection, _ id: String, _ title: String, _ profile: String?) async throws -> Void
  /// Permanently delete a session — `DELETE /api/sessions/{id}`. Pass `profile`
  /// (non-default) to scope to that profile (query param only — DELETE has no body);
  /// `nil` omits it entirely, same threading rule as `archive`. The endpoint is
  /// idempotent: deleting an already-absent session still answers 2xx
  /// (`{ok, already_absent}`), so any 2xx is success and the body is discarded.
  ///
  /// Callers flip their `deleteSupported` gate on `RESTError.isMissingEndpointVerdict`
  /// (404 OR 405 — see that property for the older-agent wrinkle).
  public var deleteSession: @Sendable (_ connection: ServerConnection, _ id: String, _ profile: String?) async throws -> Void
  /// Transcribe recorded audio — `POST /api/audio/transcribe` `{data_url, mime_type?}` →
  /// `{ok, transcript}`. Returns the transcript text; throws `.transcriptionFailed` on `ok:false`.
  public var transcribe: @Sendable (_ connection: ServerConnection, _ dataURL: String, _ mimeType: String?) async throws -> String
  /// Register this device's APNs token with the `hermes-push` plugin —
  /// `POST /api/plugins/hermes-push/register` `{device_token, apns_env, app_version}`. The app
  /// never signs pushes (the plugin signs with a single shared secret), so registration returns
  /// nothing the app must persist. A missing plugin surfaces as `RESTError.notFound` (404) so
  /// the caller can capability-gate (mirrors the profiles/attach pattern).
  public var registerPush: @Sendable (_ connection: ServerConnection, _ deviceToken: String, _ apnsEnv: String, _ appVersion: String) async throws -> Void
  /// Unregister this device's APNs token — `POST /api/plugins/hermes-push/unregister`
  /// `{device_token}`. A missing plugin surfaces as `RESTError.notFound` (404).
  public var unregisterPush: @Sendable (_ connection: ServerConnection, _ deviceToken: String) async throws -> Void
  /// Ask the plugin to deliver a sample push to this caller's registered device(s) —
  /// `POST /api/plugins/hermes-push/test`. Used by the Settings "Send test notification"
  /// button to verify the end-to-end pipeline. A missing plugin surfaces as
  /// `RESTError.notFound` (404).
  public var sendTestPush: @Sendable (_ connection: ServerConnection) async throws -> Void
  /// Cron jobs on the connected agent — `GET /api/cron/jobs` (hermes-agent v0.16+). Pass
  /// `profile` (non-default) to scope to that profile's jobs; `nil` omits the param and the
  /// server aggregates every profile (each job carries its `profile` annotation). A missing
  /// endpoint (older agent) surfaces as `RESTError.notFound` so the caller can
  /// capability-gate back to the flat cron section.
  public var cronJobs: @Sendable (_ connection: ServerConnection, _ profile: String?) async throws -> [CronJob]
  /// Fire a cron job immediately — `POST /api/cron/jobs/{id}/trigger`. `profile` as above.
  public var triggerCronJob: @Sendable (_ connection: ServerConnection, _ id: String, _ profile: String?) async throws -> Void
  /// Pause a cron job — `POST /api/cron/jobs/{id}/pause`. `profile` as above.
  public var pauseCronJob: @Sendable (_ connection: ServerConnection, _ id: String, _ profile: String?) async throws -> Void
  /// Resume a paused cron job — `POST /api/cron/jobs/{id}/resume`. `profile` as above.
  public var resumeCronJob: @Sendable (_ connection: ServerConnection, _ id: String, _ profile: String?) async throws -> Void
  /// Authoritative readiness probe for the `hermes-push` plugin — `GET /api/dashboard/plugins/hub`
  /// → `{plugins: [{name, runtime_status, …}], …}`. Matches the plugin by `name == "hermes-push"`
  /// and maps: `runtime_status == "enabled"` → `.ready`; present-but-not-enabled or absent →
  /// `.notReady`; a 404 / transport failure → `.unknown` (don't nag — caller leaves capability
  /// as-is). Used on the session list and to gate the Settings toggle.
  public var pushPluginStatus: @Sendable (_ connection: ServerConnection) async throws -> PushPluginStatus
  /// The same probe as `pushPluginStatus`, but keeping the plugin's reported `version` and
  /// `can_update_git` — Settings uses them to offer an in-app update when the installed
  /// plugin is older than `PushSetup.minimumPluginVersion`. Never throws: an unreachable or
  /// unparseable hub maps to `.unknown` (offer nothing) exactly like the status probe.
  public var pushPluginInfo: @Sendable (_ connection: ServerConnection) async -> PushPluginInfo = { _ in
    // `@DependencyClient` needs a default for a non-throwing closure. `.unknown` is also the
    // right unimplemented behaviour: a test that forgets to stub this offers no update.
    PushPluginInfo(status: .unknown)
  }
  /// Ask the agent to update the plugin in place —
  /// `POST /api/dashboard/agent-plugins/hermes-push/update`, which runs `git pull --ff-only`
  /// in `~/.hermes/plugins/hermes-push`.
  ///
  /// This only changes files on disk; the running agent keeps the OLD code loaded until it is
  /// restarted, so callers MUST surface the restart requirement on success. Failure throws
  /// `RESTError` — the agent answers 400 with a `detail` (not a git checkout, no remote,
  /// non-fast-forward, git missing) that `RESTError.server` carries verbatim.
  public var updatePushPlugin: @Sendable (_ connection: ServerConnection) async throws -> PushPluginUpdateResult
}

public extension HermesRESTClient {
  /// Live implementation over `URLSession`. The session is injectable so tests can
  /// supply a `URLProtocol` mock; `tokenStore` is injectable so bearer tests get their own
  /// store instead of the process-wide one.
  static func live(
    session: URLSession = .shared,
    tokenStore: BearerTokenStore = .shared
  ) -> HermesRESTClient {
    // A dedicated session for password login so captured cookies live in their own jar,
    // isolated from `.shared`. Inherits the injected session's `protocolClasses` so test
    // mocks still intercept; gets a fresh `HTTPCookieStorage` and accepts all cookies.
    let cookieSession = makeCookieSession(from: session)
    // One resolution point for the regime → header mapping. For `.bearer` this is where a
    // near-expiry token gets refreshed (single-flight, inside the store) before the call.
    let authFor: @Sendable (ServerConnection) async throws -> RequestAuth = { conn in
      try await resolveAuth(for: conn, session: session, tokenStore: tokenStore)
    }
    return HermesRESTClient(
      status: { baseURL in
        try await get(makeURL(baseURL, "/api/status"), auth: .none, session: session)
      },
      authProviders: { baseURL in
        do {
          let response: AuthProvidersResponse = try await get(
            makeURL(baseURL, "/api/auth/providers"), auth: .none, session: session
          )
          return response.providers
        } catch RESTError.notFound {
          // Older servers don't expose this endpoint — capability falls back to token-only.
          return nil
        }
      },
      passwordLogin: { baseURL, provider, username, password in
        try await login(
          baseURL: baseURL, provider: provider, username: username, password: password,
          session: cookieSession
        )
      },
      nativeTokenExchange: { baseURL, code, verifier in
        // `HermesKit.` disambiguates the free function from the property being initialized.
        try await HermesKit.nativeTokenExchange(
          baseURL: baseURL, code: code, verifier: verifier, session: session
        )
      },
      nativeRefresh: { baseURL, expiring in
        try await HermesKit.nativeRefresh(
          baseURL: baseURL, expiring: expiring, session: session
        )
      },
      logout: { conn in
        // THE ONE DELIBERATE EXCEPTION to the project's "surface RPC failures, never
        // swallow them" rule (CLAUDE.md → Core rules). Logout is a courtesy call that asks
        // a gated server to drop its side of the session; by the time it fires the app has
        // already discarded its own credentials and is on its way to the login screen, so a
        // failure changes nothing the user could see or act on — a banner would be noise on
        // a screen that is about to disappear. It is logged, never surfaced, and never
        // rethrown (the closure is non-throwing so no call site can accidentally depend on
        // the result). Do not "fix" this into a throwing call.
        do {
          let url = try makeURL(conn.baseURL, "/auth/logout")
          try await send(
            url, method: "POST", body: Data("{}".utf8), auth: authFor(conn), session: session
          )
        } catch {
          authLog.info("POST /auth/logout failed (best-effort, ignored): \(error)")
        }
      },
      sessions: { conn, limit, offset, order in
        let url = try makeURL(conn.baseURL, "/api/sessions", query: [
          .init(name: "limit", value: String(limit)),
          .init(name: "offset", value: String(offset)),
          .init(name: "order", value: order.rawValue),
        ])
        let response: SessionsResponse = try await get(url, auth: authFor(conn), session: session)
        return response.sessions.map(\.asSession)
      },
      archivedSessions: { conn, limit, offset in
        let url = try makeURL(conn.baseURL, "/api/sessions", query: [
          .init(name: "limit", value: String(limit)),
          .init(name: "offset", value: String(offset)),
          .init(name: "order", value: SessionOrder.recent.rawValue),
          .init(name: "archived", value: "only"),
        ])
        let response: SessionsResponse = try await get(url, auth: authFor(conn), session: session)
        return response.sessions.map(\.asSession)
      },
      search: { conn, query in
        let url = try makeURL(conn.baseURL, "/api/sessions/search", query: [.init(name: "q", value: query)])
        let response: SearchResponse = try await get(url, auth: authFor(conn), session: session)
        return response.results.map(\.asSession)
      },
      archive: { conn, id, archived, profile in
        // `makeURL` percent-encodes `comps.path`, so interpolate the RAW id — pre-encoding
        // here would double-encode reserved chars.
        // A non-nil profile is mirrored into both the query and the body (matches desktop);
        // `nil` → no `profile` anywhere, byte-identical to today's request.
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let url = try makeURL(conn.baseURL, "/api/sessions/\(id)", query: query)
        var payload: [String: Any] = ["archived": archived]
        if let profile { payload["profile"] = profile }
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(url, method: "PATCH", body: body, auth: authFor(conn), session: session)
      },
      setUnread: { conn, id, unread, profile in
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let url = try makeURL(conn.baseURL, "/api/sessions/\(id)", query: query)
        var payload: [String: Any] = ["unread": unread]
        if let profile { payload["profile"] = profile }
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(url, method: "PATCH", body: body, auth: authFor(conn), session: session)
      },
      rename: { conn, id, title, profile in
        // Same endpoint/shape as `archive`: interpolate the RAW id (`makeURL` percent-encodes
        // the path), send `{"title": …}` — an empty string clears the title server-side.
        // A non-nil profile is mirrored into both the query and the body (matches desktop);
        // `nil` → no `profile` anywhere, byte-identical to today's request.
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let url = try makeURL(conn.baseURL, "/api/sessions/\(id)", query: query)
        var payload: [String: Any] = ["title": title]
        if let profile { payload["profile"] = profile }
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(url, method: "PATCH", body: body, auth: authFor(conn), session: session)
      },
      deleteSession: { conn, id, profile in
        // Same URL shape as `archive`/`rename`: interpolate the RAW id (`makeURL`
        // percent-encodes the path). A non-nil profile rides in the query only — DELETE
        // carries no body; `nil` → no `profile` anywhere (default-profile rule).
        // Any 2xx is success (`{ok, already_absent}` included); the body is discarded.
        // 404 → `.notFound`, 405 (older agent, path exists for PATCH/GET only) →
        // `.server(status: 405, …)` via the shared `validate` mapping.
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let url = try makeURL(conn.baseURL, "/api/sessions/\(id)", query: query)
        try await send(url, method: "DELETE", body: nil, auth: authFor(conn), session: session)
      },
      transcribe: { conn, dataURL, mimeType in
        let url = try makeURL(conn.baseURL, "/api/audio/transcribe")
        var payload: [String: Any] = ["data_url": dataURL]
        if let mimeType { payload["mime_type"] = mimeType }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response: TranscriptionResponse = try await postJSON(
          url, body: body, auth: authFor(conn), session: session
        )
        guard response.ok, let transcript = response.transcript else {
          throw RESTError.transcriptionFailed(response.error ?? "")
        }
        return transcript
      },
      registerPush: { conn, deviceToken, apnsEnv, appVersion in
        let url = try makeURL(conn.baseURL, "/api/plugins/hermes-push/register")
        let body = try JSONSerialization.data(withJSONObject: [
          "device_token": deviceToken,
          "apns_env": apnsEnv,
          "app_version": appVersion,
        ] as [String: Any])
        // 404 → `RESTError.notFound` (plugin not installed); the caller capability-gates.
        // The response body carries nothing the app needs (no secret), so we discard it.
        try await send(url, method: "POST", body: body, auth: authFor(conn), session: session)
      },
      unregisterPush: { conn, deviceToken in
        let url = try makeURL(conn.baseURL, "/api/plugins/hermes-push/unregister")
        let body = try JSONSerialization.data(withJSONObject: ["device_token": deviceToken])
        // 404 → `RESTError.notFound` (plugin not installed); the caller capability-gates.
        try await send(url, method: "POST", body: body, auth: authFor(conn), session: session)
      },
      sendTestPush: { conn in
        let url = try makeURL(conn.baseURL, "/api/plugins/hermes-push/test")
        // No body needed — the plugin looks up the caller's registered device(s).
        // 404 → `RESTError.notFound` (plugin not installed); the caller capability-gates.
        try await send(url, method: "POST", body: Data("{}".utf8), auth: authFor(conn), session: session)
      },
      cronJobs: { conn, profile in
        // `nil` profile omits the param entirely — the server then aggregates all profiles
        // (its default `all`), matching how the unscoped session list behaves.
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let url = try makeURL(conn.baseURL, "/api/cron/jobs", query: query)
        return try await get(url, auth: authFor(conn), session: session)
      },
      triggerCronJob: { conn, id, profile in
        try await cronJobAction(
          conn, id: id, action: "trigger", profile: profile,
          auth: authFor(conn), session: session
        )
      },
      pauseCronJob: { conn, id, profile in
        try await cronJobAction(
          conn, id: id, action: "pause", profile: profile,
          auth: authFor(conn), session: session
        )
      },
      resumeCronJob: { conn, id, profile in
        try await cronJobAction(
          conn, id: id, action: "resume", profile: profile,
          auth: authFor(conn), session: session
        )
      },
      pushPluginStatus: { conn in
        await fetchPushPluginInfo(conn, authFor: authFor, session: session).status
      },
      pushPluginInfo: { conn in
        await fetchPushPluginInfo(conn, authFor: authFor, session: session)
      },
      updatePushPlugin: { conn in
        // The plugin name is a fixed literal, but it still rides in the path — percent-encode
        // it rather than interpolating raw, so this can't be the place a future rename breaks.
        let encoded = PushSetup.pluginName
          .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? PushSetup.pluginName
        let url = try makeURL(conn.baseURL, "/api/dashboard/agent-plugins/\(encoded)/update")
        let response: PluginUpdateResponse = try await postJSON(
          url, body: Data("{}".utf8), auth: authFor(conn), session: session
        )
        // The agent answers 400 (→ `RESTError.server` with `detail`) for a real failure, so a
        // 2xx `{"ok": false}` shouldn't happen. Treat it as a failure anyway rather than
        // reporting a success that never occurred.
        guard response.ok != false else {
          throw RESTError.server(status: 200, detail: response.error)
        }
        // Absent `unchanged` (older agent) → assume something changed and ask for the restart.
        return PushPluginUpdateResult(unchanged: response.unchanged ?? false)
      }
    )
  }
}

extension HermesRESTClient: DependencyKey {
  public static var liveValue: HermesRESTClient { .live() }
  // Unimplemented by default — REST calls in tests must be stubbed explicitly.
  public static var testValue: HermesRESTClient { HermesRESTClient() }
}

public extension DependencyValues {
  var hermesREST: HermesRESTClient {
    get { self[HermesRESTClient.self] }
    set { self[HermesRESTClient.self] = newValue }
  }
}

/// Shared POST for the cron job actions (`trigger` / `pause` / `resume`) — same
/// URL/query/body shape, only the trailing path segment differs. Interpolates the RAW id
/// (`makeURL` percent-encodes the path). 404 → `RESTError.notFound` (job gone or old agent).
private func cronJobAction(
  _ conn: ServerConnection, id: String, action: String, profile: String?,
  auth: RequestAuth, session: URLSession
) async throws {
  let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
  let url = try makeURL(conn.baseURL, "/api/cron/jobs/\(id)/\(action)", query: query)
  try await send(url, method: "POST", body: Data("{}".utf8), auth: auth, session: session)
}

/// Where the best-effort logout failure goes instead of a banner (see `logout` above).
private let authLog = Logger(subsystem: "me.honcharenko.HermesKit", category: "auth")

// MARK: - Transport helpers
//
// These are `internal` (not `private`) so sibling clients in the package
// (e.g. `HermesProfileClient`) can reuse the exact same request/decoding/validation
// path rather than duplicating it.

/// Build a dedicated `URLSession` for password login with its own cookie jar so captured
/// cookies never bleed into `.shared`. Inherits the source session's `protocolClasses`
/// (so test mocks still intercept) and accepts all cookies.
func makeCookieSession(from source: URLSession) -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = source.configuration.protocolClasses
  config.httpCookieStorage = HTTPCookieStorage()
  config.httpCookieAcceptPolicy = .always
  config.httpShouldSetCookies = true
  return URLSession(configuration: config)
}

/// POST `/auth/password-login` and capture the `Set-Cookie` jar into a `CookieSession`.
/// Cookies are parsed directly from the response headers (independent of the session's
/// cookie storage) so the capture is deterministic and fully testable. Maps non-2xx
/// statuses to `RESTError` (401/404/429/503 carry login-specific copy).
func login(
  baseURL: URL, provider: String, username: String, password: String, session: URLSession
) async throws -> CookieSession {
  let url = try makeURL(baseURL, "/auth/password-login")
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  let payload: [String: Any] = ["provider": provider, "username": username, "password": password]
  request.httpBody = try JSONSerialization.data(withJSONObject: payload)

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError(transport: error)
  }

  // Login-specific 429/503 copy is scoped here only (see `validate`'s `loginSpecific`).
  try validate(response, data: data, loginSpecific: true)

  guard let http = response as? HTTPURLResponse else { throw RESTError.unreachable }
  // Parse Set-Cookie straight from the response headers — `allHeaderFields` is
  // `[AnyHashable: Any]`; map to `[String: String]` for `HTTPCookie`.
  let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
    if let key = pair.key as? String, let value = pair.value as? String { acc[key] = value }
  }
  let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
    .map(SerializedCookie.init)
  return CookieSession(cookies: cookies, username: username, provider: provider)
}

/// Resolve a connection's auth regime into the header for ONE request.
///
/// - `.token` → `.sessionToken` (the legacy `X-Hermes-Session-Token` path, unchanged).
/// - `.cookie` → `.none` (the session's cookie jar authenticates it).
/// - `.bearer` → a known-fresh access token from `BearerTokenStore`, which refreshes it
///   first when it is inside the leeway. That is the ONLY bearer read in the app.
///
/// The store's expiry verdict (`GatewayError.authExpired`) is re-thrown as
/// `RESTError.unauthorized` so it lands in the same error domain as a real 401 and every
/// existing `asRESTError` → re-auth route keeps working unchanged.
func resolveAuth(
  for connection: ServerConnection,
  session: URLSession,
  tokenStore: BearerTokenStore
) async throws -> RequestAuth {
  switch connection.auth {
  case let .token(token):
    return .sessionToken(token)
  case .cookie:
    return .none
  case .bearer:
    do {
      let token = try await tokenStore.validAccessToken(refresh: { baseURL, expiring in
        try await nativeRefresh(baseURL: baseURL, expiring: expiring, session: session)
      })
      return .bearer(token)
    } catch GatewayError.authExpired {
      throw RESTError.unauthorized
    }
  }
}

/// Budget for the two native-flow token endpoints. Short on purpose: they are interactive
/// (the user is watching a spinner) and the desktop uses the same 15 s.
let nativeTokenTimeout: TimeInterval = 15

/// `POST /auth/native/token` — redeem the authorization code with the PKCE verifier.
/// Every failure the gateway can produce here is a generic 400, surfaced as
/// `RESTError.server(status: 400, detail:)` with its body verbatim.
func nativeTokenExchange(
  baseURL: URL, code: String, verifier: String, session: URLSession
) async throws -> BearerSession {
  guard let url = nativeTokenURL(base: baseURL) else { throw RESTError.unreachable }
  return try await nativeTokenPost(
    url: url,
    payload: ["code": code, "code_verifier": verifier],
    session: session,
    mapServiceUnavailable: false
  )
}

/// `POST /auth/native/refresh` — rotate the token pair.
///
/// 401 (`{"error":"session_expired"}` — every provider rejected the refresh token) →
/// `.unauthorized`, which `BearerTokenStore` turns into its one expiry verdict. 503 (a
/// provider is momentarily unreachable) → `.serviceUnavailable`, which the store rethrows
/// with the tokens INTACT so backoff can retry.
func nativeRefresh(
  baseURL: URL, expiring: BearerSession, session: URLSession
) async throws -> BearerSession {
  guard let url = nativeRefreshURL(base: baseURL) else { throw RESTError.unreachable }
  var payload: [String: Any] = ["refresh_token": expiring.refreshToken]
  // Omit an empty provider rather than sending `""`: the gateway then tries every
  // registered provider, which is also what a partial stored payload wants.
  if !expiring.provider.isEmpty { payload["provider"] = expiring.provider }
  return try await nativeTokenPost(
    url: url, payload: payload, session: session, mapServiceUnavailable: true
  )
}

/// Shared POST for the two native-flow token endpoints. Deliberately UNAUTHENTICATED: each
/// authenticates with what is in its body (the PKCE verifier / the refresh token), and the
/// access token they mint is the thing we don't have yet.
private func nativeTokenPost(
  url: URL, payload: [String: Any], session: URLSession, mapServiceUnavailable: Bool
) async throws -> BearerSession {
  var request = URLRequest(url: url, timeoutInterval: nativeTokenTimeout)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = try JSONSerialization.data(withJSONObject: payload)

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError(transport: error)
  }

  // The refresh endpoint's 503 is "the provider is unreachable, keep your tokens" — a
  // distinct verdict from the generic `.server(503)` every other route gets. Handled here
  // rather than via `validate`'s `loginSpecific`, which also remaps 429 to login copy.
  if mapServiceUnavailable, (response as? HTTPURLResponse)?.statusCode == 503 {
    throw RESTError.serviceUnavailable
  }
  try validate(response, data: data)

  do {
    return try BearerSession(tokenResponse: data)
  } catch {
    throw RESTError.decoding
  }
}

func makeURL(_ base: URL, _ path: String, query: [URLQueryItem] = []) throws -> URL {
  guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
    throw RESTError.unreachable
  }
  comps.path = path
  comps.queryItems = query.isEmpty ? nil : query
  guard let url = comps.url else { throw RESTError.unreachable }
  return url
}

func get<T: Decodable>(_ url: URL, auth: RequestAuth, session: URLSession) async throws -> T {
  var request = URLRequest(url: url)
  auth.apply(to: &request)

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError(transport: error)
  }

  try validate(response, data: data)

  do {
    return try JSONDecoder().decode(T.self, from: data)
  } catch {
    throw RESTError.decoding
  }
}

/// Validate an HTTP response status, mapping non-success codes to `RESTError`. The
/// response `data` is read on failure so the server's error `detail` is surfaced
/// verbatim (see `serverDetail`).
///
/// `loginSpecific` opts into the password-login copy for 429/503 (`.rateLimited` /
/// `.serviceUnavailable`). It is **only** set on the `POST /auth/password-login` path —
/// for every other (authenticated) REST call a transient 429/503 stays a generic
/// `.server(status:)`, so it never surfaces misleading "too many login attempts" /
/// "auth provider unreachable" copy mid-session.
func validate(_ response: URLResponse, data: Data, loginSpecific: Bool = false) throws {
  guard let http = response as? HTTPURLResponse else { throw RESTError.unreachable }
  switch http.statusCode {
  case 200..<300: break
  case 401: throw RESTError.unauthorized
  case 404: throw RESTError.notFound
  case 429 where loginSpecific: throw RESTError.rateLimited
  case 503 where loginSpecific: throw RESTError.serviceUnavailable
  default: throw RESTError.server(status: http.statusCode, detail: serverDetail(from: data))
  }
}

/// Lenient extraction of a human-readable error reason from a non-2xx body: prefer the
/// JSON `{"detail": …}` field, else the trimmed plain-text body, else `nil` (empty body).
func serverDetail(from data: Data) -> String? {
  if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
     let detail = object["detail"] as? String,
     !detail.isEmpty {
    return detail
  }
  let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  return text.isEmpty ? nil : text
}

/// POST a JSON body and decode the response (used by `transcribe`).
func postJSON<T: Decodable>(
  _ url: URL, body: Data, auth: RequestAuth, session: URLSession
) async throws -> T {
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.httpBody = body
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  auth.apply(to: &request)

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError(transport: error)
  }

  try validate(response, data: data)

  do {
    return try JSONDecoder().decode(T.self, from: data)
  } catch {
    throw RESTError.decoding
  }
}

/// Fire a write request (e.g. PATCH) and validate the status, discarding the body.
func send(
  _ url: URL, method: String, body: Data?, auth: RequestAuth, session: URLSession
) async throws {
  var request = URLRequest(url: url)
  request.httpMethod = method
  if let body {
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  }
  auth.apply(to: &request)

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError(transport: error)
  }

  try validate(response, data: data)
}

// MARK: - DTOs (verified against hermes_cli/web_server.py + hermes_state.py)

private struct SessionsResponse: Decodable {
  let sessions: [SessionListDTO]
  let total: Int?
}

/// `GET /api/auth/providers`. The server wraps the list in an object
/// (`{"providers":[…]}`); we also tolerate a bare top-level array for safety.
private struct AuthProvidersResponse: Decodable {
  let providers: [AuthProvider]

  init(from decoder: Decoder) throws {
    if let array = try? [AuthProvider](from: decoder) {
      providers = array
      return
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    providers = try c.decodeIfPresent([AuthProvider].self, forKey: .providers) ?? []
  }

  enum CodingKeys: String, CodingKey { case providers }
}

// `internal` so sibling clients (e.g. `HermesProfileClient`'s scoped-session list,
// which returns rows in the same shape) can reuse the decoding.
struct SessionListDTO: Decodable {
  let id: String
  let title: String?
  let preview: String?
  let lastActive: Double?
  let startedAt: Double?
  let messageCount: Int?
  let unread: Bool?
  let cwd: String?
  let isActive: Bool?
  let source: String?
  let parentSessionID: String?
  let lineageRootID: String?

  enum CodingKeys: String, CodingKey {
    case id, title, preview, cwd, source
    case lastActive = "last_active"
    case startedAt = "started_at"
    case messageCount = "message_count"
    case unread
    case isActive = "is_active"
    case parentSessionID = "parent_session_id"
    // Present only on compression-projected rows: the ORIGINAL id the row had before the
    // server projected it forward to its continuation tip (branch nesting aliases on it).
    case lineageRootID = "_lineage_root_id"
  }

  var asSession: Session {
    Session(
      id: id,
      title: title?.nonEmpty,
      updatedAt: (lastActive ?? startedAt).map { Date(timeIntervalSince1970: $0) },
      preview: preview?.nonEmpty,
      cwd: cwd?.nonEmpty,
      startedAt: startedAt.map { Date(timeIntervalSince1970: $0) },
      messageCount: messageCount,
      unread: unread,
      isActive: isActive,
      source: source,
      parentSessionID: parentSessionID?.trimmedNonEmpty,
      lineageRootID: lineageRootID?.trimmedNonEmpty
    )
  }
}

private struct SearchResponse: Decodable {
  let results: [SearchResultDTO]
}

/// Search results carry a `snippet`, not a `title` (different shape from the list).
private struct SearchResultDTO: Decodable {
  let sessionID: String
  let snippet: String?
  let sessionStarted: Double?

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case snippet
    case sessionStarted = "session_started"
  }

  var asSession: Session {
    Session(
      id: sessionID,
      title: nil,
      updatedAt: sessionStarted.map { Date(timeIntervalSince1970: $0) },
      preview: snippet?.nonEmpty
    )
  }
}

/// `/api/audio/transcribe` response — `{ok, transcript, provider?}`; `error` on failure.
private struct TranscriptionResponse: Decodable {
  let ok: Bool
  let transcript: String?
  let provider: String?
  let error: String?
}

/// `/api/dashboard/plugins/hub` response — `{plugins: [{name, runtime_status, version,
/// can_update_git, …}], …}`. We read only the four fields below off each row; everything else
/// is ignored leniently.
private struct PluginsHubResponse: Decodable {
  let plugins: [PluginHubItem]
}

private struct PluginHubItem: Decodable {
  let name: String
  let runtimeStatus: String?
  /// The plugin's own manifest version. The agent emits `""` when the manifest carries none,
  /// so blank is normalized to `nil` at the mapping site rather than treated as a version.
  let version: String?
  /// `true` when the plugin is a git checkout under `~/.hermes/plugins/` — i.e. the agent's
  /// update endpoint can `git pull` it. Absent on older agents → `false` (no update offered).
  let canUpdateGit: Bool?

  enum CodingKeys: String, CodingKey {
    case name
    case runtimeStatus = "runtime_status"
    case version
    case canUpdateGit = "can_update_git"
  }
}

/// `POST /api/dashboard/agent-plugins/{name}/update` response —
/// `{ok, name, output, unchanged}`. `unchanged` is the agent's own read of git's
/// "Already up to date"; absent on older agents → treated as changed, so we prompt for the
/// restart rather than claiming nothing happened.
private struct PluginUpdateResponse: Decodable {
  let ok: Bool?
  let unchanged: Bool?
  let error: String?
}

/// Fetch the plugin hub and map our row onto `PushPluginInfo`. Shared by `pushPluginStatus`
/// (which discards everything but the status) and `pushPluginInfo`, so there is exactly one
/// decode + mapping path and the two can never disagree about readiness.
private func fetchPushPluginInfo(
  _ conn: ServerConnection,
  authFor: @Sendable (ServerConnection) async throws -> RequestAuth,
  session: URLSession
) async -> PushPluginInfo {
  do {
    let url = try makeURL(conn.baseURL, "/api/dashboard/plugins/hub")
    // A bearer refresh failure lands in the same `catch` as everything else → `.unknown`,
    // which is the right "we can't tell" answer for a probe that must never nag.
    let response: PluginsHubResponse = try await get(
      url, auth: authFor(conn), session: session
    )
    // Match our plugin by name; `runtime_status == "enabled"` is the only "ready" state.
    guard let plugin = response.plugins.first(where: { $0.name == PushSetup.pluginName })
    else { return PushPluginInfo(status: .notReady) } // absent from the list → not installed
    let version = plugin.version?.trimmingCharacters(in: .whitespacesAndNewlines)
    return PushPluginInfo(
      status: plugin.runtimeStatus == "enabled" ? .ready : .notReady,
      version: (version?.isEmpty ?? true) ? nil : version,
      canUpdateGit: plugin.canUpdateGit ?? false
    )
  } catch {
    // Endpoint missing (old agent / no dashboard), transport, HTTP or decode failure → we
    // can't tell. `.unknown` leaves the capability as-is and offers no update.
    return PushPluginInfo(status: .unknown)
  }
}
