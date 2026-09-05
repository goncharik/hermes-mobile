import Foundation
import Testing

@testable import HermesKit

struct NativeOAuthTests {
  // MARK: PKCE

  /// RFC 7636 appendix B: the octet sequence below base64url-encodes to the published
  /// verifier, whose ASCII SHA-256 base64url-encodes to the published challenge. Pinning
  /// the random source turns `generate` into a vector check.
  private static let rfc7636Octets: [UInt8] = [
    116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173,
    187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88,
    83, 132, 141, 121,
  ]
  private static let rfc7636Verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  /// base64url of appendix B's published digest octets (…, 112, 249, 195).
  private static let rfc7636Challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  /// Appendix B's published SHA-256 digest of the ASCII verifier, kept alongside the
  /// encoded challenge so the vector is self-checking rather than transcribed by hand.
  private static let rfc7636DigestOctets: [UInt8] = [
    19, 211, 30, 150, 26, 26, 216, 236, 47, 22, 177, 12, 76, 152, 46, 8,
    118, 168, 120, 173, 109, 241, 68, 86, 110, 225, 137, 74, 203, 112,
    249, 195,
  ]

  @Test func pkceMatchesRFC7636AppendixBVector() {
    #expect(base64URLEncode(Data(Self.rfc7636Octets)) == Self.rfc7636Verifier)
    #expect(base64URLEncode(Data(Self.rfc7636DigestOctets)) == Self.rfc7636Challenge)

    let pair = PKCEPair.generate(random: { count in
      #expect(count == 32)
      return Data(Self.rfc7636Octets)
    })
    #expect(pair.verifier == Self.rfc7636Verifier)
    #expect(pair.challenge == Self.rfc7636Challenge)
    #expect(pair.method == "S256")
  }

  @Test func pkceVerifierIsBase64URLAndInRFCLengthRange() {
    let pair = PKCEPair.generate()
    // 32 random bytes → 43 base64url characters, inside RFC 7636's 43–128 range.
    #expect(pair.verifier.count == 43)
    #expect(pair.challenge.count == 43)
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    #expect(pair.verifier.unicodeScalars.allSatisfy(allowed.contains))
    #expect(pair.challenge.unicodeScalars.allSatisfy(allowed.contains))
    // No base64 padding or non-url-safe alphabet leaks through.
    #expect(!pair.verifier.contains("=") && !pair.verifier.contains("+") && !pair.verifier.contains("/"))
    #expect(!pair.challenge.contains("=") && !pair.challenge.contains("+") && !pair.challenge.contains("/"))
  }

  @Test func pkcePairsAreDistinctAcrossCalls() {
    #expect(PKCEPair.generate().verifier != PKCEPair.generate().verifier)
  }

  @Test func stateIs24RandomBytesBase64URLEncoded() {
    let state = generateOAuthState(random: { count in
      #expect(count == 24)
      return Data(repeating: 0xAB, count: count)
    })
    // 24 bytes → 32 base64url characters, no padding.
    #expect(state.count == 32)
    #expect(!state.contains("="))
    #expect(generateOAuthState() != generateOAuthState())
  }

  // MARK: Endpoint URLs

  private let base = URL(string: "https://mac.tailnet:8080")!

  @Test func authorizeURLCarriesEveryRequiredParameter() throws {
    let url = try #require(
      nativeAuthorizeURL(
        base: base,
        challenge: "chal",
        redirectURI: "http://127.0.0.1:52341/callback",
        state: "st8"
      )
    )
    let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(comps.scheme == "https")
    #expect(comps.host == "mac.tailnet")
    #expect(comps.port == 8080)
    #expect(comps.path == "/auth/native/authorize")

    let items = Dictionary(
      uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    #expect(items["code_challenge"] == "chal")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["redirect_uri"] == "http://127.0.0.1:52341/callback")
    #expect(items["state"] == "st8")
    // No provider was chosen: the gateway auto-selects its single session provider.
    #expect(items["provider"] == nil)
  }

  @Test func authorizeURLPercentEncodesTheLoopbackRedirect() throws {
    let url = try #require(
      nativeAuthorizeURL(
        base: base,
        challenge: "chal",
        redirectURI: "http://127.0.0.1:52341/callback",
        state: "st8"
      )
    )
    // `:` and `/` must be escaped in the value (mirrors the desktop's URLSearchParams),
    // so the redirect can never be mistaken for a new query parameter.
    #expect(url.absoluteString.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A52341%2Fcallback"))
  }

  @Test func authorizeURLIncludesProviderWhenChosen() throws {
    let url = try #require(
      nativeAuthorizeURL(
        base: base,
        challenge: "chal",
        redirectURI: "http://127.0.0.1:1/callback",
        state: "st8",
        provider: "nous"
      )
    )
    let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect((comps.queryItems ?? []).contains(URLQueryItem(name: "provider", value: "nous")))
  }

  @Test func authorizeURLOmitsAnEmptyProvider() throws {
    // An empty `provider` would be sent as `provider=` — treat it exactly like `nil`.
    let url = try #require(
      nativeAuthorizeURL(
        base: base,
        challenge: "chal",
        redirectURI: "http://127.0.0.1:1/callback",
        state: "st8",
        provider: ""
      )
    )
    #expect(!url.absoluteString.contains("provider"))
  }

  @Test func tokenAndRefreshURLs() throws {
    let token = try #require(nativeTokenURL(base: base))
    let refresh = try #require(nativeRefreshURL(base: base))
    #expect(token.absoluteString == "https://mac.tailnet:8080/auth/native/token")
    #expect(refresh.absoluteString == "https://mac.tailnet:8080/auth/native/refresh")
  }

  @Test func urlBuildersPreserveABasePathPrefix() throws {
    // A gateway can be mounted under a path prefix (reverse proxy); every native endpoint
    // hangs off it rather than the origin root.
    let mounted = URL(string: "https://example.com/hermes")!
    let token = try #require(nativeTokenURL(base: mounted))
    let refresh = try #require(nativeRefreshURL(base: mounted))
    let authorize = try #require(
      nativeAuthorizeURL(base: mounted, challenge: "c", redirectURI: "http://127.0.0.1:1/cb", state: "s")
    )
    #expect(token.absoluteString == "https://example.com/hermes/auth/native/token")
    #expect(refresh.absoluteString == "https://example.com/hermes/auth/native/refresh")
    #expect(authorize.path == "/hermes/auth/native/authorize")
  }

  @Test func urlBuildersStripTrailingSlashesAndStaleQuery() throws {
    let messy = URL(string: "https://example.com/hermes//?foo=bar#frag")!
    let token = try #require(nativeTokenURL(base: messy))
    #expect(token.absoluteString == "https://example.com/hermes/auth/native/token")
  }

  @Test func urlBuildersHandleAPlainHTTPBaseWithNoPath() throws {
    let token = try #require(nativeTokenURL(base: URL(string: "http://192.168.1.10:4000")!))
    #expect(token.absoluteString == "http://192.168.1.10:4000/auth/native/token")
  }

  // MARK: Callback classification

  @Test func callbackClassificationAcceptsOnlyRealCallbacks() {
    #expect(isLoopbackCallback(requestTarget: "/callback?code=abc&state=st8"))
    #expect(isLoopbackCallback(requestTarget: "/callback?error=access_denied&state=st8"))
    // Everything the spike saw arrive alongside the real callback is "not a callback":
    // zero-byte speculative connections, blank request lines, favicon probes, bare paths.
    #expect(!isLoopbackCallback(requestTarget: ""))
    #expect(!isLoopbackCallback(requestTarget: "   \r\n"))
    #expect(!isLoopbackCallback(requestTarget: "/favicon.ico"))
    #expect(!isLoopbackCallback(requestTarget: "/callback"))
    #expect(!isLoopbackCallback(requestTarget: "/callback?state=st8"))
    // Present-but-empty values don't settle either.
    #expect(!isLoopbackCallback(requestTarget: "/callback?code=&state=st8"))
    #expect(!isLoopbackCallback(requestTarget: "/callback?error=&state=st8"))
  }

  // MARK: Callback parsing

  @Test func parseReturnsTheCodeWhenStateMatches() throws {
    let code = try parseLoopbackCallback(
      requestTarget: "/callback?code=auth-code-123&state=st8",
      expectedState: "st8"
    )
    #expect(code == "auth-code-123")
  }

  @Test func parseAcceptsAnAbsoluteTargetAndPercentEncodedValues() throws {
    let code = try parseLoopbackCallback(
      requestTarget: "http://127.0.0.1:52341/callback?code=a%2Fb%2Bc&state=st8",
      expectedState: "st8"
    )
    #expect(code == "a/b+c")
  }

  @Test func parseSurfacesTheGatewayErrorWithItsDescription() {
    #expect(throws: OAuthLoginError.gatewayRejected("access_denied (User declined)")) {
      try parseLoopbackCallback(
        requestTarget: "/callback?error=access_denied&error_description=User%20declined&state=st8",
        expectedState: "st8"
      )
    }
  }

  @Test func parseSurfacesTheGatewayErrorAloneWhenThereIsNoDescription() {
    #expect(throws: OAuthLoginError.gatewayRejected("server_error")) {
      try parseLoopbackCallback(requestTarget: "/callback?error=server_error", expectedState: "st8")
    }
  }

  @Test func parseRejectsACallbackWithNoCode() {
    #expect(throws: OAuthLoginError.self) {
      try parseLoopbackCallback(requestTarget: "/callback?state=st8", expectedState: "st8")
    }
  }

  @Test func parseThrowsOnAStateMismatchBeforeReturningTheCode() {
    // CSRF defence: a forged callback carrying an attacker's code must never be redeemed.
    #expect(throws: OAuthLoginError.stateMismatch) {
      try parseLoopbackCallback(
        requestTarget: "/callback?code=attacker-code&state=wrong",
        expectedState: "st8"
      )
    }
    #expect(throws: OAuthLoginError.stateMismatch) {
      try parseLoopbackCallback(requestTarget: "/callback?code=attacker-code", expectedState: "st8")
    }
    // A caller that lost its own state can't be satisfied by an equally empty callback.
    #expect(throws: OAuthLoginError.stateMismatch) {
      try parseLoopbackCallback(requestTarget: "/callback?code=c&state=", expectedState: "")
    }
  }

  @Test func parseRejectsABlankTarget() {
    #expect(throws: OAuthLoginError.self) {
      try parseLoopbackCallback(requestTarget: "", expectedState: "st8")
    }
  }

  @Test func errorPrecedenceIsGatewayErrorThenCodeThenState() {
    // An `error` callback is reported as the gateway's rejection even when the state is
    // wrong — the user-visible reason is the useful one and no code is present to redeem.
    #expect(throws: OAuthLoginError.gatewayRejected("access_denied")) {
      try parseLoopbackCallback(
        requestTarget: "/callback?error=access_denied&state=wrong",
        expectedState: "st8"
      )
    }
  }

  // MARK: Error copy

  @Test func errorMessagesAreUserFacing() {
    #expect(OAuthLoginError.cancelled.message == "Sign-in was cancelled.")
    #expect(OAuthLoginError.timedOut.message == "Sign-in timed out. Try again.")
    #expect(!OAuthLoginError.stateMismatch.message.isEmpty)
    #expect(!OAuthLoginError.listenerFailed.message.isEmpty)
    #expect(OAuthLoginError.gatewayRejected("Provider is down").message == "Provider is down")
    // An empty reason falls back to generic copy rather than showing a blank banner.
    #expect(OAuthLoginError.gatewayRejected("").message == "The server rejected the sign-in.")
    // The token-exchange failure keeps the REST layer's verbatim copy.
    #expect(OAuthLoginError.tokenExchange(.server(status: 400, detail: "invalid_grant")).message
      == "invalid_grant")
    #expect(OAuthLoginError.tokenExchange(.offline).message == RESTError.offline.message)
  }

  // MARK: base64url

  @Test func base64URLEncodingDropsPaddingAndSwapsTheAlphabet() {
    // 0xFB 0xFF encodes to "+/8=" in standard base64 — every special case in one vector.
    #expect(base64URLEncode(Data([0xFB, 0xFF])) == "-_8")
    #expect(base64URLEncode(Data()) == "")
  }
}
