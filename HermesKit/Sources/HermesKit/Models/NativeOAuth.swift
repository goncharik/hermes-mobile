import CryptoKit
import Foundation

// Pure, transport-free helpers for the gateway's RFC 8252 native-app OAuth flow
// (`/auth/native/authorize|token|refresh`): PKCE generation, endpoint URLs, and loopback
// callback parsing.
//
// Everything here is deliberately OUTSIDE any `#if canImport(UIKit)` guard and free of
// `Network`/`AuthenticationServices` so `swift test` on macOS covers it. The iOS-only
// driver (`NWListener` + `ASWebAuthenticationSession`) lives in `OAuthLoginClient`.
//
// Mirrors the desktop's `apps/desktop/electron/native-oauth.ts` — that client is the
// known-good reference for the same gateway endpoints; deviating would be inventing a
// second protocol dialect.

// MARK: - base64url

/// base64url without `=` padding (RFC 7636 §4 / RFC 4648 §5).
func base64URLEncode(_ raw: Data) -> String {
  raw.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

// MARK: - PKCE

/// A PKCE verifier/challenge pair for the `S256` challenge method (RFC 7636).
struct PKCEPair: Equatable, Sendable {
  /// The high-entropy secret kept in the app and replayed on `POST /auth/native/token`.
  var verifier: String
  /// `base64url(SHA256(ascii(verifier)))` — the only half that reaches the browser.
  var challenge: String
  /// Always `S256`; the gateway rejects `plain`.
  var method: String

  init(verifier: String, challenge: String, method: String = PKCEPair.challengeMethod) {
    self.verifier = verifier
    self.challenge = challenge
    self.method = method
  }

  /// The `code_challenge_method` value sent to `/auth/native/authorize`.
  static let challengeMethod = "S256"

  /// Generate a pair: 32 random bytes → a 43-character base64url verifier (inside RFC
  /// 7636's 43–128 range), challenge = `base64url(SHA256(ascii(verifier)))`.
  ///
  /// `random` is injectable so tests can pin the RFC 7636 appendix B vector.
  static func generate(random: @Sendable (Int) -> Data = secureRandomBytes) -> PKCEPair {
    let verifier = base64URLEncode(random(32))
    // The verifier is base64url, i.e. pure ASCII — `Data(verifier.utf8)` is the ASCII
    // octet sequence RFC 7636 hashes.
    let challenge = base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    return PKCEPair(verifier: verifier, challenge: challenge)
  }
}

/// A high-entropy CSRF `state` for the loopback round trip (24 random bytes → 32 chars).
/// Verified against the callback before any code is redeemed (RFC 6749 §10.12).
func generateOAuthState(random: @Sendable (Int) -> Data = secureRandomBytes) -> String {
  base64URLEncode(random(24))
}

/// Cryptographically secure random bytes. `SystemRandomNumberGenerator` is documented as
/// a CSPRNG on Apple platforms, so this stays free of a direct `Security` dependency.
let secureRandomBytes: @Sendable (Int) -> Data = { count in
  var generator = SystemRandomNumberGenerator()
  return Data((0 ..< max(0, count)).map { _ in
    UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
  })
}

// MARK: - Endpoint URLs

/// Build the `/auth/native/authorize` URL the browser sheet opens.
///
/// `redirectURI` is the app's loopback callback (`http://127.0.0.1:<port>/callback` — the
/// gateway rejects anything that isn't a loopback literal). `provider` is omitted when
/// `nil`, which lets the gateway auto-select its single non-password session provider.
///
/// Returns `nil` only when `base` can't be decomposed into components (a caller-side
/// programming error — every call site has an already-validated server URL).
func nativeAuthorizeURL(
  base: URL,
  challenge: String,
  redirectURI: String,
  state: String,
  provider: String? = nil
) -> URL? {
  var query = [
    ("code_challenge", challenge),
    ("code_challenge_method", PKCEPair.challengeMethod),
    ("redirect_uri", redirectURI),
    ("state", state),
  ]
  // Only send `provider` when we picked one: an empty value means "auto-select" server-side
  // and a password provider would be redirected to the `/login` form instead.
  if let provider, !provider.isEmpty { query.append(("provider", provider)) }

  guard var comps = nativeComponents(base: base, suffix: "/auth/native/authorize") else {
    return nil
  }
  // Encode with a strict unreserved-only allowed set rather than `queryItems`, whose
  // default leaves `:` and `/` raw — `redirect_uri` is a full URL, and mirroring the
  // desktop's `URLSearchParams` output keeps the two clients byte-comparable.
  comps.percentEncodedQuery = query
    .map { "\(percentEncodeQueryComponent($0.0))=\(percentEncodeQueryComponent($0.1))" }
    .joined(separator: "&")
  return comps.url
}

/// `POST /auth/native/token` — redeem the authorization code with the PKCE verifier.
func nativeTokenURL(base: URL) -> URL? {
  nativeComponents(base: base, suffix: "/auth/native/token")?.url
}

/// `POST /auth/native/refresh` — rotate the token pair.
func nativeRefreshURL(base: URL) -> URL? {
  nativeComponents(base: base, suffix: "/auth/native/refresh")?.url
}

/// Components for a native-flow endpoint, PRESERVING any path prefix on the base URL (a
/// gateway can be mounted under `https://host/hermes`), and dropping any query/fragment
/// the stored server URL happens to carry.
private func nativeComponents(base: URL, suffix: String) -> URLComponents? {
  guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
  var prefix = comps.path
  while prefix.hasSuffix("/") { prefix.removeLast() }
  comps.path = prefix + suffix
  comps.percentEncodedQuery = nil
  comps.fragment = nil
  return comps
}

/// Percent-encode a query component down to the RFC 3986 unreserved set, so `:` and `/`
/// inside `redirect_uri` are escaped.
private func percentEncodeQueryComponent(_ value: String) -> String {
  var allowed = CharacterSet.alphanumerics
  allowed.insert(charactersIn: "-._~")
  return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

// MARK: - Loopback callback

/// Is this loopback request the OAuth callback, or incidental traffic?
///
/// The listener answers EVERY request with the "you can close this window" page but must
/// settle the flow on exactly one of them. The Task 1 spike saw speculative zero-byte TCP
/// connections arrive before the real `GET /callback` (and a favicon probe is the same
/// shape), so a blank/unparseable/parameter-less target is "not a callback" — never an
/// error, never a settle.
func isLoopbackCallback(requestTarget: String) -> Bool {
  guard let items = loopbackQueryItems(requestTarget) else { return false }
  return items.contains { ($0.name == "code" || $0.name == "error") && !($0.value ?? "").isEmpty }
}

/// Parse the loopback redirect the gateway sends the browser to and return the
/// authorization `code`.
///
/// Only ever call this for a target `isLoopbackCallback` accepted. Failure modes:
/// - the gateway reported `error` (+ optional `error_description`) → `.gatewayRejected`
/// - no `code` at all → `.gatewayRejected`
/// - `state` missing or ≠ `expectedState` → `.stateMismatch`, thrown BEFORE the code is
///   returned: a forged callback must never get its code redeemed (RFC 6749 §10.12).
func parseLoopbackCallback(requestTarget: String, expectedState: String) throws -> String {
  guard let items = loopbackQueryItems(requestTarget) else {
    throw OAuthLoginError.gatewayRejected("The sign-in callback was malformed.")
  }
  func value(_ name: String) -> String {
    items.last { $0.name == name }?.value ?? ""
  }

  let error = value("error")
  if !error.isEmpty {
    let description = value("error_description")
    throw OAuthLoginError.gatewayRejected(
      description.isEmpty ? error : "\(error) (\(description))"
    )
  }

  let code = value("code")
  guard !code.isEmpty else {
    throw OAuthLoginError.gatewayRejected("The sign-in callback carried no authorization code.")
  }
  guard !expectedState.isEmpty, value("state") == expectedState else {
    throw OAuthLoginError.stateMismatch
  }
  return code
}

/// Query items of a raw HTTP request target (`/callback?code=…&state=…`), resolved against
/// a dummy loopback origin. `nil` when the target is blank or can't be parsed at all.
private func loopbackQueryItems(_ requestTarget: String) -> [URLQueryItem]? {
  let trimmed = requestTarget.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  guard let url = URL(string: trimmed, relativeTo: URL(string: "http://127.0.0.1")),
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
  else { return nil }
  return comps.queryItems ?? []
}

// MARK: - Errors

/// Everything the native OAuth login leg can fail with. `RESTError` is wrapped rather than
/// flattened so the token-exchange failure keeps the server's verbatim detail.
public enum OAuthLoginError: Error, Equatable, Sendable {
  /// The user dismissed the browser sheet. Callers return to the idle state SILENTLY —
  /// this is not an error worth a banner.
  case cancelled
  /// The whole flow outran its budget (300 s) — usually an abandoned sheet.
  case timedOut
  /// The callback's `state` didn't match the one we sent; the code is never redeemed.
  case stateMismatch
  /// The gateway or the identity provider refused, carrying its own reason.
  case gatewayRejected(String)
  /// The loopback listener could not bind or died before the callback arrived.
  case listenerFailed
  /// `POST /auth/native/token` failed.
  case tokenExchange(RESTError)

  /// User-facing copy for the connection/reauth status footer.
  public var message: String {
    switch self {
    case .cancelled: "Sign-in was cancelled."
    case .timedOut: "Sign-in timed out. Try again."
    case .stateMismatch: "Couldn’t verify the sign-in response. Try again."
    case let .gatewayRejected(reason):
      reason.isEmpty ? "The server rejected the sign-in." : reason
    case .listenerFailed: "Couldn’t start the local sign-in listener. Try again."
    case let .tokenExchange(error): error.message
    }
  }
}
