import Foundation

/// How the app authenticates against a Hermes server. The server has three distinct auth
/// **regimes**, modeled here so downstream clients adapt transport without scattering
/// regime checks:
///
/// - `.token` — loopback/`--insecure`, `auth_required=false`. REST uses the
///   `X-Hermes-Session-Token` header; WS uses `…/api/ws?token=<token>`; never expires.
/// - `.cookie` — gated (password), `auth_required=true`. REST uses session cookies
///   (HttpOnly, rotating); WS requires a single-use `?ticket=` minted per connect.
/// - `.bearer` — gated via the RFC 8252 native OAuth (PKCE) flow. REST sends
///   `Authorization: Bearer <access_token>`; the app owns the token pair and refreshes it
///   itself; WS uses the same per-connect `?ticket=` mint as `.cookie`.
public enum AuthSession: Equatable, Sendable, Codable {
  case token(String)
  case cookie(CookieSession)
  case bearer(BearerSession)

  /// The session token for `.token` sessions; `nil` for `.cookie` (which authenticates via
  /// the cookie jar) and `.bearer` (which sends an `Authorization` header carrying a token
  /// the app refreshes — never this static value). A convenience so existing token-mode
  /// call sites stay byte-identical.
  public var token: String? {
    switch self {
    case let .token(value): value
    case .cookie, .bearer: nil
    }
  }
}

/// The token set returned by the gateway's native OAuth (PKCE) flow
/// (`POST /auth/native/token` and `/auth/native/refresh`). The app owns and refreshes these
/// itself; `BearerTokenStore` is the only component allowed to read/rotate them at runtime.
public struct BearerSession: Equatable, Sendable, Codable {
  public var accessToken: String
  public var refreshToken: String
  /// Absolute expiry in unix seconds (server `expires_at`).
  public var expiresAt: Double
  /// Server provider id the tokens belong to (e.g. `nous`, `self_hosted`); echoed back on
  /// refresh.
  public var provider: String
  /// Identity used for re-auth routing (same user resumes in place, a different one pops).
  public var userID: String

  public init(
    accessToken: String,
    refreshToken: String,
    expiresAt: Double,
    provider: String,
    userID: String
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.provider = provider
    self.userID = userID
  }

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresAt = "expires_at"
    case provider
    case userID = "user_id"
  }
}

public enum BearerSessionError: Error, Equatable, Sendable {
  /// The token/refresh response carried no usable `access_token`.
  case missingAccessToken
}

public extension BearerSession {
  /// Assumed lifetime for a payload whose `expires_at` is missing or non-positive (an older
  /// or partial gateway response — e.g. one that sends `expires_in`). `BearerTokenStore`
  /// treats a non-positive expiry as already stale, so without a floor every request would
  /// rotate the pair; against the portal's refresh-token reuse detection an unbounded
  /// rotation treadmill is the worst possible reading of a lenient decode.
  static let fallbackAccessTokenTTL: TimeInterval = 300

  /// Lenient decode of a `/auth/native/token` or `/auth/native/refresh` payload.
  ///
  /// Follows the project's decode-leniently rule: unknown fields are ignored, `expires_at`
  /// is accepted as an Int or a Double (JSON numbers both decode to `Double`), a missing or
  /// non-positive `expires_at` becomes `now + fallbackAccessTokenTTL`, and the non-critical
  /// fields fall back to empty strings. Only a missing/empty `access_token` is fatal —
  /// without it there is nothing to authenticate with.
  init(tokenResponse data: Data, now: Date = Date()) throws {
    let payload = try JSONDecoder().decode(TokenResponsePayload.self, from: data)
    let accessToken = payload.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !accessToken.isEmpty else { throw BearerSessionError.missingAccessToken }
    let expiresAt = payload.expiresAt ?? 0
    self.init(
      accessToken: accessToken,
      refreshToken: payload.refreshToken ?? "",
      expiresAt: expiresAt > 0
        ? expiresAt
        : now.timeIntervalSince1970 + BearerSession.fallbackAccessTokenTTL,
      provider: payload.provider ?? "",
      userID: payload.userID ?? ""
    )
  }
}

/// Wire shape of the native-flow token payload — every field optional so an older/partial
/// response decodes and the `access_token` check above is the single failure point.
private struct TokenResponsePayload: Decodable {
  var accessToken: String?
  var refreshToken: String?
  var expiresAt: Double?
  var provider: String?
  var userID: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresAt = "expires_at"
    case provider
    case userID = "user_id"
  }
}

/// A captured cookie-based session for the gated auth regime. Carries enough to rehydrate
/// the cookie jar (`HTTPCookieStorage`) on a fresh launch plus the identity for re-auth
/// routing.
public struct CookieSession: Equatable, Sendable, Codable {
  public var cookies: [SerializedCookie]
  public var username: String
  public var provider: String

  public init(cookies: [SerializedCookie], username: String, provider: String) {
    self.cookies = cookies
    self.username = username
    self.provider = provider
  }
}

/// A `Codable` snapshot of an `HTTPCookie`. Carries the fields needed to round-trip the
/// cookie back into `HTTPCookieStorage` (`HttpOnly` only blocks JS, not native clients).
public struct SerializedCookie: Equatable, Sendable, Codable {
  public var name: String
  public var value: String
  public var domain: String
  public var path: String
  /// Absolute expiry (seconds since 1970), `nil` for a session cookie.
  public var expiresAt: Double?
  public var isSecure: Bool
  public var isHTTPOnly: Bool

  public init(
    name: String,
    value: String,
    domain: String,
    path: String,
    expiresAt: Double? = nil,
    isSecure: Bool = false,
    isHTTPOnly: Bool = false
  ) {
    self.name = name
    self.value = value
    self.domain = domain
    self.path = path
    self.expiresAt = expiresAt
    self.isSecure = isSecure
    self.isHTTPOnly = isHTTPOnly
  }
}

public extension SerializedCookie {
  /// Snapshot an `HTTPCookie` for persistence.
  init(_ cookie: HTTPCookie) {
    self.init(
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path,
      expiresAt: cookie.expiresDate?.timeIntervalSince1970,
      isSecure: cookie.isSecure,
      isHTTPOnly: cookie.isHTTPOnly
    )
  }

  /// Rehydrate into an `HTTPCookie` for `HTTPCookieStorage`.
  var httpCookie: HTTPCookie? {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: value,
      .domain: domain,
      .path: path,
    ]
    if let expiresAt { properties[.expires] = Date(timeIntervalSince1970: expiresAt) }
    if isSecure { properties[.secure] = "TRUE" }
    // `HTTPOnly` has no public property key; native clients ignore it anyway.
    return HTTPCookie(properties: properties)
  }
}
