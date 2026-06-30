import ComposableArchitecture
import DependenciesMacros
import Foundation

// MARK: - Connection & status

/// Where and how to reach a Hermes server. `auth` carries the regime (token vs cookie);
/// the unauthenticated reachability probe (`/api/status`) goes through `status(baseURL:)`
/// without a `ServerConnection`.
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

  /// The bearer token when authenticating in `.token` mode; `nil` in `.cookie` mode (which
  /// uses the cookie jar). Drives the existing `X-Hermes-Session-Token` REST/WS paths.
  /// Setting a value switches the connection into `.token` mode (token-mode editing in
  /// Settings); setting `nil` is ignored (the cookie jar is the source of truth then).
  public var token: String? {
    get { auth.token }
    set { if let newValue { auth = .token(newValue) } }
  }
}

public enum SessionOrder: String, Sendable {
  case created
  case recent
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

  enum CodingKeys: String, CodingKey {
    case version
    case gatewayRunning = "gateway_running"
    case gatewayState = "gateway_state"
    case activeSessions = "active_sessions"
    case authRequired = "auth_required"
    case authProviders = "auth_providers"
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
  case unreachable           // transport failure / non-HTTP response
  case decoding              // 2xx body didn't match the expected shape
  case transcriptionFailed(String) // 2xx but `{ok:false}` — carries the server's reason

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
  public var sessions: @Sendable (_ connection: ServerConnection, _ limit: Int, _ offset: Int, _ order: SessionOrder) async throws -> [Session]
  /// Just the archived (soft-hidden) sessions — `GET /api/sessions?archived=only`.
  public var archivedSessions: @Sendable (_ connection: ServerConnection, _ limit: Int, _ offset: Int) async throws -> [Session]
  public var search: @Sendable (_ connection: ServerConnection, _ query: String) async throws -> [Session]
  /// Soft-hide (archive) or restore a session — `PATCH /api/sessions/{id}` `{"archived":…}`.
  /// Pass `profile` (non-default) to scope to that profile (added to both query and body);
  /// `nil` → today's exact request.
  public var archive: @Sendable (_ connection: ServerConnection, _ id: String, _ archived: Bool, _ profile: String?) async throws -> Void
  /// Rename a session — `PATCH /api/sessions/{id}` `{"title":…}`. An empty title clears it.
  /// The server may reject with 400 (too long / invalid chars / duplicate).
  /// Pass `profile` (non-default) to scope to that profile (added to both query and body);
  /// `nil` → today's exact request.
  public var rename: @Sendable (_ connection: ServerConnection, _ id: String, _ title: String, _ profile: String?) async throws -> Void
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
  /// Authoritative readiness probe for the `hermes-push` plugin — `GET /api/dashboard/plugins/hub`
  /// → `{plugins: [{name, runtime_status, …}], …}`. Matches the plugin by `name == "hermes-push"`
  /// and maps: `runtime_status == "enabled"` → `.ready`; present-but-not-enabled or absent →
  /// `.notReady`; a 404 / transport failure → `.unknown` (don't nag — caller leaves capability
  /// as-is). Used on the session list and to gate the Settings toggle.
  public var pushPluginStatus: @Sendable (_ connection: ServerConnection) async throws -> PushPluginStatus
}

public extension HermesRESTClient {
  /// Live implementation over `URLSession`. The session is injectable so tests can
  /// supply a `URLProtocol` mock.
  static func live(session: URLSession = .shared) -> HermesRESTClient {
    // A dedicated session for password login so captured cookies live in their own jar,
    // isolated from `.shared`. Inherits the injected session's `protocolClasses` so test
    // mocks still intercept; gets a fresh `HTTPCookieStorage` and accepts all cookies.
    let cookieSession = makeCookieSession(from: session)
    return HermesRESTClient(
      status: { baseURL in
        try await get(makeURL(baseURL, "/api/status"), token: nil, session: session)
      },
      authProviders: { baseURL in
        do {
          let response: AuthProvidersResponse = try await get(
            makeURL(baseURL, "/api/auth/providers"), token: nil, session: session
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
      sessions: { conn, limit, offset, order in
        let url = try makeURL(conn.baseURL, "/api/sessions", query: [
          .init(name: "limit", value: String(limit)),
          .init(name: "offset", value: String(offset)),
          .init(name: "order", value: order.rawValue),
        ])
        let response: SessionsResponse = try await get(url, token: conn.token, session: session)
        return response.sessions.map(\.asSession)
      },
      archivedSessions: { conn, limit, offset in
        let url = try makeURL(conn.baseURL, "/api/sessions", query: [
          .init(name: "limit", value: String(limit)),
          .init(name: "offset", value: String(offset)),
          .init(name: "order", value: SessionOrder.recent.rawValue),
          .init(name: "archived", value: "only"),
        ])
        let response: SessionsResponse = try await get(url, token: conn.token, session: session)
        return response.sessions.map(\.asSession)
      },
      search: { conn, query in
        let url = try makeURL(conn.baseURL, "/api/sessions/search", query: [.init(name: "q", value: query)])
        let response: SearchResponse = try await get(url, token: conn.token, session: session)
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
        try await send(url, method: "PATCH", body: body, token: conn.token, session: session)
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
        try await send(url, method: "PATCH", body: body, token: conn.token, session: session)
      },
      transcribe: { conn, dataURL, mimeType in
        let url = try makeURL(conn.baseURL, "/api/audio/transcribe")
        var payload: [String: Any] = ["data_url": dataURL]
        if let mimeType { payload["mime_type"] = mimeType }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response: TranscriptionResponse = try await postJSON(
          url, body: body, token: conn.token, session: session
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
        try await send(url, method: "POST", body: body, token: conn.token, session: session)
      },
      unregisterPush: { conn, deviceToken in
        let url = try makeURL(conn.baseURL, "/api/plugins/hermes-push/unregister")
        let body = try JSONSerialization.data(withJSONObject: ["device_token": deviceToken])
        // 404 → `RESTError.notFound` (plugin not installed); the caller capability-gates.
        try await send(url, method: "POST", body: body, token: conn.token, session: session)
      },
      sendTestPush: { conn in
        let url = try makeURL(conn.baseURL, "/api/plugins/hermes-push/test")
        // No body needed — the plugin looks up the caller's registered device(s).
        // 404 → `RESTError.notFound` (plugin not installed); the caller capability-gates.
        try await send(url, method: "POST", body: Data("{}".utf8), token: conn.token, session: session)
      },
      pushPluginStatus: { conn in
        let url = try makeURL(conn.baseURL, "/api/dashboard/plugins/hub")
        do {
          let response: PluginsHubResponse = try await get(url, token: conn.token, session: session)
          // Match our plugin by name; `runtime_status == "enabled"` is the only "ready" state.
          guard let plugin = response.plugins.first(where: { $0.name == PushSetup.pluginName })
          else { return .notReady } // absent from the list → not installed
          return plugin.runtimeStatus == "enabled" ? .ready : .notReady
        } catch RESTError.notFound {
          // Endpoint missing (old agent / no dashboard) → can't tell; don't nag.
          return .unknown
        } catch {
          // Any transport/HTTP/decode failure → unknown (leave capability as-is).
          return .unknown
        }
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
    throw RESTError.unreachable
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

func makeURL(_ base: URL, _ path: String, query: [URLQueryItem] = []) throws -> URL {
  guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
    throw RESTError.unreachable
  }
  comps.path = path
  comps.queryItems = query.isEmpty ? nil : query
  guard let url = comps.url else { throw RESTError.unreachable }
  return url
}

func get<T: Decodable>(_ url: URL, token: String?, session: URLSession) async throws -> T {
  var request = URLRequest(url: url)
  if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError.unreachable
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
  _ url: URL, body: Data, token: String?, session: URLSession
) async throws -> T {
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.httpBody = body
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError.unreachable
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
  _ url: URL, method: String, body: Data?, token: String?, session: URLSession
) async throws {
  var request = URLRequest(url: url)
  request.httpMethod = method
  if let body {
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  }
  if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError.unreachable
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
  let cwd: String?
  let isActive: Bool?
  let source: String?

  enum CodingKeys: String, CodingKey {
    case id, title, preview, cwd, source
    case lastActive = "last_active"
    case startedAt = "started_at"
    case messageCount = "message_count"
    case isActive = "is_active"
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
      isActive: isActive,
      source: source
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

/// `/api/dashboard/plugins/hub` response — `{plugins: [{name, runtime_status, …}], …}`. We
/// only read the plugin rows (and only `name` + `runtime_status` off each); everything else is
/// ignored leniently.
private struct PluginsHubResponse: Decodable {
  let plugins: [PluginHubItem]
}

private struct PluginHubItem: Decodable {
  let name: String
  let runtimeStatus: String?

  enum CodingKeys: String, CodingKey {
    case name
    case runtimeStatus = "runtime_status"
  }
}
