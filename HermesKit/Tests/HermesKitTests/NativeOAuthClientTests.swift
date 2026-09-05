import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// REST-side coverage of the `.bearer` regime: the `Authorization` header, the
/// refresh-before-use hop `BearerTokenStore` drives through `resolveAuth`, the two
/// native-flow token endpoints, and the deliberately best-effort logout.
///
/// Nested in `RESTTransportSuite` so it serializes against the other suites that drive the
/// process-global `MockURLProtocol` stub.
extension RESTTransportSuite {
struct NativeOAuthClientTests {
  private let baseURL = URL(string: "http://test.local:9119")!

  /// A rotated pair as the gateway returns it (`expires_at` far in the future, extra
  /// `token_type` field the decoder ignores).
  private let rotatedJSON = #"""
  {"access_token":"AT2","refresh_token":"RT2","token_type":"Bearer","expires_at":4000000000,"provider":"nous","user_id":"u-1"}
  """#

  private func makeClient(tokenStore: BearerTokenStore) -> HermesRESTClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return .live(session: URLSession(configuration: config), tokenStore: tokenStore)
  }

  private func stored(expiresAt: Double, accessToken: String = "AT1") -> BearerSession {
    BearerSession(
      accessToken: accessToken, refreshToken: "RT1", expiresAt: expiresAt,
      provider: "nous", userID: "u-1"
    )
  }

  /// A `.bearer` connection. Its payload is deliberately a STALE token: the store is the
  /// only source of truth for what actually goes on the wire.
  private func bearerConnection() -> ServerConnection {
    ServerConnection(baseURL: baseURL, auth: .bearer(stored(expiresAt: 0, accessToken: "stale")))
  }

  private func jsonBody(_ req: URLRequest) throws -> [String: String] {
    let object = try JSONSerialization.jsonObject(with: mockRequestBody(req))
    return (object as? [String: String]) ?? [:]
  }

  // MARK: - Authorization header

  @Test func bearerSendsAuthorizationHeaderAndNoSessionToken() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = BearerTokenStore(now: { now }, refreshLeeway: 120)
    // Comfortably fresh — no refresh should happen.
    await store.seed(stored(expiresAt: 1_000_600), baseURL: baseURL, persist: { _ in })

    MockURLProtocol.set(json: #"{"sessions":[],"total":0}"#)
    _ = try await makeClient(tokenStore: store).sessions(bearerConnection(), 20, 0, .recent)

    #expect(MockURLProtocol.requests.count == 1) // no refresh hop
    let req = try #require(MockURLProtocol.lastRequest)
    // The store's token, NOT the (stale) one embedded in the connection.
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer AT1")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
  }

  // MARK: - Refresh before use

  @Test func nearExpiryRefreshesOnceBeforeTheAPICall() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = BearerTokenStore(now: { now }, refreshLeeway: 120)
    let persisted = LockIsolated<[BearerSession]>([])
    // 10 s left, inside the 120 s leeway → one rotation, then the real call.
    await store.seed(stored(expiresAt: 1_000_010), baseURL: baseURL) { rotated in
      persisted.withValue { $0.append(rotated) }
    }

    MockURLProtocol.setSequence([
      .init(statusCode: 200, body: Data(rotatedJSON.utf8)),
      .init(statusCode: 200, body: Data(#"{"sessions":[],"total":0}"#.utf8)),
    ])
    _ = try await makeClient(tokenStore: store).sessions(bearerConnection(), 20, 0, .recent)

    #expect(MockURLProtocol.requests.count == 2)
    let refresh = try #require(MockURLProtocol.requests.first)
    #expect(refresh.httpMethod == "POST")
    #expect(refresh.url?.path == "/auth/native/refresh")
    // The body carries the OLD refresh token and the provider — the exact input the
    // portal's reuse detection keys on.
    #expect(try jsonBody(refresh) == ["refresh_token": "RT1", "provider": "nous"])
    // The refresh endpoint authenticates with the body, never with a header.
    #expect(refresh.value(forHTTPHeaderField: "Authorization") == nil)

    let api = try #require(MockURLProtocol.requests.last)
    #expect(api.url?.path == "/api/sessions")
    #expect(api.value(forHTTPHeaderField: "Authorization") == "Bearer AT2")

    #expect(persisted.value.map(\.accessToken) == ["AT2"]) // persisted exactly once
    #expect(await store.current?.refreshToken == "RT2")
  }

  @Test func refreshUnauthorizedClearsTheStoreAndSurfacesAsA401() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = BearerTokenStore(now: { now }, refreshLeeway: 120)
    await store.seed(stored(expiresAt: 1_000_010), baseURL: baseURL, persist: { _ in })

    // `{"error":"session_expired"}` — every provider rejected the refresh token.
    MockURLProtocol.set(status: 401, json: #"{"error":"session_expired"}"#)
    // The store's `GatewayError.authExpired` verdict re-enters the REST domain as a 401 so
    // the existing `asRESTError` → re-auth routing sees what it already knows how to route.
    await #expect(throws: RESTError.unauthorized) {
      _ = try await makeClient(tokenStore: store).sessions(bearerConnection(), 20, 0, .recent)
    }
    #expect(await store.current == nil)
    #expect(MockURLProtocol.requests.count == 1) // the API call never went out
  }

  @Test func refreshServiceUnavailableKeepsTheTokens() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = BearerTokenStore(now: { now }, refreshLeeway: 120)
    await store.seed(stored(expiresAt: 1_000_010), baseURL: baseURL, persist: { _ in })

    // 503 = a provider is momentarily unreachable. Retryable, so the pair must survive.
    MockURLProtocol.set(status: 503)
    await #expect(throws: RESTError.serviceUnavailable) {
      _ = try await makeClient(tokenStore: store).sessions(bearerConnection(), 20, 0, .recent)
    }
    #expect(await store.current?.accessToken == "AT1")
  }

  // MARK: - Token endpoints

  @Test func tokenExchangeDecodesThePayload() async throws {
    MockURLProtocol.set(json: rotatedJSON)
    let session = try await makeClient(tokenStore: BearerTokenStore())
      .nativeTokenExchange(baseURL, "the-code", "the-verifier")
    #expect(session == BearerSession(
      accessToken: "AT2", refreshToken: "RT2", expiresAt: 4_000_000_000,
      provider: "nous", userID: "u-1"
    ))

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/auth/native/token")
    #expect(try jsonBody(req) == ["code": "the-code", "code_verifier": "the-verifier"])
    // The PKCE verifier IS the credential — no auth header on this leg.
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
  }

  @Test func tokenExchangeRejectionCarriesTheServerDetail() async throws {
    // Every gateway-side failure on this route is a generic 400 with a `detail` body.
    MockURLProtocol.set(status: 400, json: #"{"detail":"invalid or expired code"}"#)
    await #expect(throws: RESTError.server(status: 400, detail: "invalid or expired code")) {
      _ = try await makeClient(tokenStore: BearerTokenStore())
        .nativeTokenExchange(baseURL, "stale-code", "verifier")
    }
  }

  @Test func tokenExchangeWithoutAnAccessTokenIsADecodeFailure() async throws {
    MockURLProtocol.set(json: #"{"token_type":"Bearer","expires_at":4000000000}"#)
    await #expect(throws: RESTError.decoding) {
      _ = try await makeClient(tokenStore: BearerTokenStore())
        .nativeTokenExchange(baseURL, "code", "verifier")
    }
  }

  @Test func directRefreshMapsItsTwoVerdicts() async throws {
    let client = makeClient(tokenStore: BearerTokenStore())
    let expiring = stored(expiresAt: 1_000_010)

    MockURLProtocol.set(status: 401, json: #"{"error":"session_expired"}"#)
    await #expect(throws: RESTError.unauthorized) {
      _ = try await client.nativeRefresh(baseURL, expiring)
    }

    MockURLProtocol.set(status: 503)
    await #expect(throws: RESTError.serviceUnavailable) {
      _ = try await client.nativeRefresh(baseURL, expiring)
    }
  }

  @Test func refreshOmitsAnEmptyProvider() async throws {
    // A partial stored payload (no `provider`) must not send `provider: ""` — an empty
    // value would narrow the gateway's search instead of letting it try every provider.
    MockURLProtocol.set(json: rotatedJSON)
    _ = try await makeClient(tokenStore: BearerTokenStore()).nativeRefresh(
      baseURL,
      BearerSession(
        accessToken: "AT1", refreshToken: "RT1", expiresAt: 0, provider: "", userID: "u-1"
      )
    )
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(try jsonBody(req) == ["refresh_token": "RT1"])
  }

  // MARK: - Logout (best-effort by design)

  @Test func logoutSwallowsAServerError() async throws {
    // The one deliberate exception to "never swallow RPC failures": a 500 must not throw,
    // because the caller is already on its way to the login screen.
    MockURLProtocol.set(status: 500, json: #"{"detail":"boom"}"#)
    await makeClient(tokenStore: BearerTokenStore())
      .logout(ServerConnection(baseURL: baseURL, token: "tok"))
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/auth/logout")
  }

  @Test func logoutAuthenticatesWithTheConnectionsRegime() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = BearerTokenStore(now: { now }, refreshLeeway: 120)
    await store.seed(stored(expiresAt: 1_000_600), baseURL: baseURL, persist: { _ in })

    MockURLProtocol.set(status: 200, json: "{}")
    await makeClient(tokenStore: store).logout(bearerConnection())
    #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer AT1")

    // Token mode keeps the legacy header — logout is not a special-cased request.
    MockURLProtocol.set(status: 200, json: "{}")
    await makeClient(tokenStore: store).logout(ServerConnection(baseURL: baseURL, token: "tok"))
    let tokenReq = try #require(MockURLProtocol.lastRequest)
    #expect(tokenReq.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(tokenReq.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func logoutAfterTheStoreIsDrainedSendsNothing() async throws {
    // Ordering contract: `clear()` before `logout` means there is nothing to authenticate
    // with, so the request is skipped rather than sent unauthenticated.
    let store = BearerTokenStore()
    MockURLProtocol.set(status: 200, json: "{}")
    await makeClient(tokenStore: store).logout(bearerConnection())
    #expect(MockURLProtocol.requests.isEmpty)
  }
}
} // extension RESTTransportSuite
