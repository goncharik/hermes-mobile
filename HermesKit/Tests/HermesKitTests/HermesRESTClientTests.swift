import Foundation
import Testing

@testable import HermesKit

/// A `URLProtocol` stub so REST tests run fully offline. Serialized because the stub
/// state is process-global.
final class MockURLProtocol: URLProtocol {
  struct Stub: Sendable {
    var statusCode = 200
    var body = Data()
    var failWithError = false
    /// Which `URLError` a `fail: true` stub raises. Defaults to a *generic* transport
    /// failure (server didn't answer) — the offline codes are opt-in, since
    /// `RESTError(transport:)` maps only those to `.offline`.
    var failCode: URLError.Code = .cannotConnectToHost
    var headers: [String: String] = [:]
  }

  nonisolated(unsafe) static var stub = Stub()
  nonisolated(unsafe) static var lastRequest: URLRequest?

  static func set(
    status: Int = 200, json: String = "", fail: Bool = false,
    failCode: URLError.Code = .cannotConnectToHost, headers: [String: String] = [:]
  ) {
    stub = Stub(
      statusCode: status, body: Data(json.utf8), failWithError: fail, failCode: failCode,
      headers: headers
    )
    lastRequest = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    MockURLProtocol.lastRequest = request
    if MockURLProtocol.stub.failWithError {
      client?.urlProtocol(self, didFailWithError: URLError(MockURLProtocol.stub.failCode))
      return
    }
    let http = HTTPURLResponse(
      url: request.url!, statusCode: MockURLProtocol.stub.statusCode,
      httpVersion: nil, headerFields: MockURLProtocol.stub.headers
    )!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: MockURLProtocol.stub.body)
    client?.urlProtocolDidFinishLoading(self)
  }
}

/// Parent suite for everything that drives the process-global `MockURLProtocol` stub.
/// `.serialized` on the parent serializes its nested suites too, so the REST and profile
/// client tests never clobber each other's shared stub by running concurrently.
@Suite(.serialized)
struct RESTTransportSuite {}

extension RESTTransportSuite {
struct HermesRESTClientTests {
  private let baseURL = URL(string: "http://test.local:9119")!
  private var connection: ServerConnection { ServerConnection(baseURL: baseURL, token: "tok") }

  private func makeClient() -> HermesRESTClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return .live(session: URLSession(configuration: config))
  }

  @Test func statusDecodes() async throws {
    MockURLProtocol.set(json: #"{"version":"0.16.0","gateway_running":true,"gateway_state":"running","active_sessions":2}"#)
    let status = try await makeClient().status(baseURL)
    #expect(status.version == "0.16.0")
    #expect(status.gatewayRunning == true)
    #expect(status.activeSessions == 2)
    // Older gateways omit `auth_flows` entirely — lenient optional, no throw.
    #expect(status.authFlows == nil)
  }

  @Test func statusDecodesAuthFlows() async throws {
    // Gated gateway with an interactive session provider registered.
    MockURLProtocol.set(json: #"""
    {"version":"0.17.0","auth_required":true,"auth_providers":["basic","nous"],"auth_flows":["cookie","native_pkce"]}
    """#)
    let status = try await makeClient().status(baseURL)
    #expect(status.authRequired == true)
    #expect(status.authFlows == ["cookie", "native_pkce"])
  }

  @Test func statusToleratesAuthFlowsAbsentOnGatedServer() async throws {
    // Gated but pre-native-flow gateway: `auth_flows` missing → nil, never a decode failure.
    MockURLProtocol.set(json: #"{"version":"0.16.0","auth_required":true,"auth_providers":["basic"]}"#)
    let status = try await makeClient().status(baseURL)
    #expect(status.authRequired == true)
    #expect(status.authFlows == nil)
  }

  @Test func authProvidersDecodesList() async throws {
    // The real server wraps the list in an object (`{"providers":[…]}`).
    MockURLProtocol.set(json: #"""
    {"providers":[{"name":"basic","display_name":"Username & password","supports_password":true},{"name":"google","display_name":"Google","supports_password":false}]}
    """#)
    let providers = try await makeClient().authProviders(baseURL)
    #expect(providers == [
      AuthProvider(name: "basic", displayName: "Username & password", supportsPassword: true),
      AuthProvider(name: "google", displayName: "Google", supportsPassword: false),
    ])
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/auth/providers")
    // Public probe — no auth header.
    #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
  }

  @Test func authProvidersDecodesBareArray() async throws {
    // Tolerate a bare top-level array too (defensive against server variations).
    MockURLProtocol.set(json: #"""
    [{"name":"basic","display_name":"Username & password","supports_password":true}]
    """#)
    let providers = try await makeClient().authProviders(baseURL)
    #expect(providers == [
      AuthProvider(name: "basic", displayName: "Username & password", supportsPassword: true),
    ])
  }

  @Test func authProvidersReturnsNilOnNotFound() async throws {
    // Older servers 404 this endpoint → nil (capability falls back to token-only).
    MockURLProtocol.set(status: 404)
    let providers = try await makeClient().authProviders(baseURL)
    #expect(providers == nil)
  }

  @Test func authProvidersTransportFailureStillThrows() async throws {
    MockURLProtocol.set(fail: true)
    await #expect(throws: RESTError.unreachable) {
      _ = try await makeClient().authProviders(baseURL)
    }
  }

  @Test func statusProbeSendsNoToken() async throws {
    MockURLProtocol.set(json: #"{"version":"0.16.0"}"#)
    _ = try await makeClient().status(baseURL)
    #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/status")
  }

  @Test func sessionsMapsListToDomain() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","preview":"hello there","last_active":1749556800.0,"started_at":1749550000.0,"message_count":4,"cwd":"/Users/me/dev/hermes-mobile","is_active":true,"archived":false}],"total":1,"limit":20,"offset":0}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    #expect(sessions.count == 1)
    let s = try #require(sessions.first)
    #expect(s.id == "20260610_120231_afcca6")
    #expect(s.title == "My chat")
    #expect(s.preview == "hello there")
    #expect(s.updatedAt == Date(timeIntervalSince1970: 1749556800.0))
    #expect(s.cwd == "/Users/me/dev/hermes-mobile")
    #expect(s.startedAt == Date(timeIntervalSince1970: 1749550000.0))
  }

  @Test func sessionsDecodesCronSource() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"Nightly job","last_active":1749556800.0,"source":"cron"}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    let s = try #require(sessions.first)
    #expect(s.source == "cron")
    #expect(s.isCron == true)
  }

  @Test func sessionsDecodesAbsentSourceAsNil() async throws {
    // Backward-compat: older agents omit `source` entirely → nil, not cron.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    let s = try #require(sessions.first)
    #expect(s.source == nil)
    #expect(s.isCron == false)
  }

  @Test func sessionsDecodesNullSourceAsNil() async throws {
    // Leniency: a local interactive session reports `source: null` → nil, not cron.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0,"source":null}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    let s = try #require(sessions.first)
    #expect(s.source == nil)
    #expect(s.isCron == false)
  }

  @Test func sessionsDecodesParentSessionID() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260724_101500_bbbb22","title":"Branch","last_active":1749556800.0,"parent_session_id":"20260610_120231_afcca6"}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    let s = try #require(sessions.first)
    #expect(s.parentSessionID == "20260610_120231_afcca6")
  }

  @Test func sessionsDecodesAbsentParentSessionIDAsNil() async throws {
    // Backward-compat: older agents omit `parent_session_id` entirely → nil, decode succeeds.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    let s = try #require(sessions.first)
    #expect(s.parentSessionID == nil)
  }

  @Test func sessionsDecodesNullParentSessionIDAsNil() async throws {
    // Regular (non-branch) sessions report `parent_session_id: null` → nil.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0,"parent_session_id":null}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    let s = try #require(sessions.first)
    #expect(s.parentSessionID == nil)
  }

  @Test func sessionsDecodesEmptyParentSessionIDAsNil() async throws {
    // Leniency: an empty (or whitespace-only) `parent_session_id` is no parent link —
    // normalized to nil at decode so the branch flatten never sees a junk key.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"a","last_active":1.0,"parent_session_id":""},{"id":"b","last_active":1.0,"parent_session_id":"  "}],"total":2}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    #expect(sessions.count == 2)
    #expect(sessions.allSatisfy { $0.parentSessionID == nil })
  }

  @Test func sessionsDecodesLineageRootID() async throws {
    // A compression-projected row: the id rotated to the continuation tip while
    // `_lineage_root_id` kept the original id (branch nesting aliases on it). It is NOT
    // stripped by the server's session-list heavy-field filter.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"tip_id","title":"Long chat","last_active":1749556800.0,"_lineage_root_id":"root_id"}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    let s = try #require(sessions.first)
    #expect(s.lineageRootID == "root_id")
  }

  @Test func sessionsDecodesAbsentLineageRootIDAsNil() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent)
    let s = try #require(sessions.first)
    #expect(s.lineageRootID == nil)
  }

  @Test func sessionsAttachesSessionTokenHeaderAndQuery() async throws {
    MockURLProtocol.set(json: #"{"sessions":[],"total":0}"#)
    _ = try await makeClient().sessions(connection, 20, 0, .recent)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.url?.path == "/api/sessions")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "order", value: "recent")))
    #expect(query.contains(URLQueryItem(name: "limit", value: "20")))
  }

  @Test func archivedSessionsSendsArchivedOnlyQueryAndMaps() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"Old chat","preview":"bye","last_active":1749556800.0,"cwd":"/Users/me/dev/x","archived":true}],"total":1}
    """#)
    let sessions = try await makeClient().archivedSessions(connection, 50, 0)
    #expect(sessions.map(\.id) == ["20260610_120231_afcca6"])
    #expect(sessions.first?.title == "Old chat")

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.url?.path == "/api/sessions")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "archived", value: "only")))
    #expect(query.contains(URLQueryItem(name: "order", value: "recent")))
    #expect(query.contains(URLQueryItem(name: "limit", value: "50")))
  }

  @Test func archivedSessionsUnauthorizedMapsToTypedError() async throws {
    MockURLProtocol.set(status: 401)
    await #expect(throws: RESTError.unauthorized) {
      _ = try await makeClient().archivedSessions(connection, 50, 0)
    }
  }

  @Test func searchMapsSnippetToPreviewWithNoTitle() async throws {
    MockURLProtocol.set(json: #"""
    {"results":[{"session_id":"20260610_120231_afcca6","snippet":"matched text","role":"user","model":"gpt-5.5","session_started":1749550000.0}]}
    """#)
    let results = try await makeClient().search(connection, "matched")
    let s = try #require(results.first)
    #expect(s.id == "20260610_120231_afcca6")
    #expect(s.title == nil)
    #expect(s.preview == "matched text")
    #expect(s.updatedAt == Date(timeIntervalSince1970: 1749550000.0))
  }

  @Test func archiveSendsPatchWithBodyAndAuthHeader() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().archive(connection, "20260610_120231_afcca6", true, nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "PATCH")
    #expect(req.url?.path == "/api/sessions/20260610_120231_afcca6")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    // URLProtocol strips httpBody into a stream, so read it back from the stream.
    let body = req.httpBody ?? req.httpBodyStream.map { stream -> Data in
      stream.open()
      defer { stream.close() }
      var data = Data()
      let bufSize = 1024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      return data
    } ?? Data()
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Bool]
    #expect(json == ["archived": true])
  }

  @Test func renameSendsPatchWithTitleBodyAndAuthHeader() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().rename(connection, "20260610_120231_afcca6", "New title", nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "PATCH")
    #expect(req.url?.path == "/api/sessions/20260610_120231_afcca6")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    // URLProtocol strips httpBody into a stream, so read it back from the stream.
    let body = req.httpBody ?? req.httpBodyStream.map { stream -> Data in
      stream.open()
      defer { stream.close() }
      var data = Data()
      let bufSize = 1024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      return data
    } ?? Data()
    let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
    #expect(json == ["title": "New title"])
  }

  @Test func renameWithEmptyTitleSendsEmptyStringBody() async throws {
    // The clear contract: an empty title round-trips as {"title": ""} (server clears it).
    MockURLProtocol.set(status: 200)
    try await makeClient().rename(connection, "20260610_120231_afcca6", "", nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "PATCH")
    #expect(req.url?.path == "/api/sessions/20260610_120231_afcca6")
    let body = req.httpBody ?? req.httpBodyStream.map { stream -> Data in
      stream.open()
      defer { stream.close() }
      var data = Data()
      let bufSize = 1024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      return data
    } ?? Data()
    let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
    #expect(json == ["title": ""])
  }

  @Test func renameRejectionMapsToServerError() async throws {
    MockURLProtocol.set(status: 400)
    await #expect(throws: RESTError.server(status: 400)) {
      try await makeClient().rename(connection, "sid", "too long", nil)
    }
  }

  @Test func archiveUnauthorizedMapsToTypedError() async throws {
    MockURLProtocol.set(status: 401)
    await #expect(throws: RESTError.unauthorized) {
      try await makeClient().archive(connection, "sid", true, nil)
    }
  }

  @Test func unauthorizedMapsToTypedError() async throws {
    MockURLProtocol.set(status: 401, json: #"{"detail":"Unauthorized"}"#)
    await #expect(throws: RESTError.unauthorized) {
      _ = try await makeClient().sessions(connection, 20, 0, .recent)
    }
  }

  /// Regression (review finding #5): a transient 429/503 on a non-login call must NOT surface
  /// the login-specific `.rateLimited`/`.serviceUnavailable` copy — it stays a generic
  /// `.server(status:)`. The login-specific mapping is scoped to `passwordLogin` only.
  @Test func nonLoginRateLimitedMapsToGenericServerError() async throws {
    MockURLProtocol.set(status: 429, json: #"{"detail":"slow down"}"#)
    await #expect(throws: RESTError.server(status: 429, detail: "slow down")) {
      _ = try await makeClient().sessions(connection, 20, 0, .recent)
    }
  }

  @Test func nonLoginServiceUnavailableMapsToGenericServerError() async throws {
    MockURLProtocol.set(status: 503, json: #"{"detail":"down"}"#)
    await #expect(throws: RESTError.server(status: 503, detail: "down")) {
      try await makeClient().archive(connection, "sid", true, nil)
    }
  }

  @Test func transportFailureMapsToUnreachable() async throws {
    MockURLProtocol.set(fail: true)
    await #expect(throws: RESTError.unreachable) {
      _ = try await makeClient().status(baseURL)
    }
  }

  // MARK: Offline vs unreachable (#62)

  /// Only the "this device has no network" codes become `.offline`.
  @Test(arguments: [
    URLError.Code.notConnectedToInternet,
    .dataNotAllowed,
    .internationalRoamingOff,
  ])
  func offlineURLErrorCodesMapToOffline(code: URLError.Code) async throws {
    #expect(RESTError(transport: URLError(code)) == .offline)
  }

  /// A reachable network whose server didn't answer stays `.unreachable` — retrying
  /// (rather than "you're offline" copy) is the right advice there. Two representative codes
  /// are enough: they all exercise the one `default:` arm (the *offline* codes above are the
  /// enumerated branch, so those stay fully parameterized).
  @Test(arguments: [URLError.Code.cannotConnectToHost, .timedOut])
  func nonOfflineURLErrorCodesMapToUnreachable(code: URLError.Code) async throws {
    #expect(RESTError(transport: URLError(code)) == .unreachable)
  }

  /// A non-`URLError` (anything `URLSession` or a wrapper could surface) is unreachable.
  @Test func nonURLErrorMapsToUnreachable() async throws {
    struct Boom: Error {}
    #expect(RESTError(transport: Boom()) == .unreachable)
    #expect(RESTError(transport: CocoaError(.fileNoSuchFile)) == .unreachable)
  }

  @Test func offlineHasItsOwnMessage() async throws {
    #expect(RESTError.offline.message == "No internet connection.")
    #expect(RESTError.unreachable.message == "Couldn’t reach the server.")
  }

  /// End-to-end through the live transport: every request helper (`get`, `postJSON`,
  /// `send`) funnels its catch through the shared mapping.
  @Test func getTransportOfflineMapsToOffline() async throws {
    MockURLProtocol.set(fail: true, failCode: .notConnectedToInternet)
    await #expect(throws: RESTError.offline) {
      _ = try await makeClient().sessions(connection, 1, 0, .recent)
    }
  }

  @Test func writeTransportOfflineMapsToOffline() async throws {
    MockURLProtocol.set(fail: true, failCode: .notConnectedToInternet)
    await #expect(throws: RESTError.offline) {
      try await makeClient().archive(connection, "sid", true, nil)
    }
  }

  @Test func postJSONTransportOfflineMapsToOffline() async throws {
    MockURLProtocol.set(fail: true, failCode: .dataNotAllowed)
    await #expect(throws: RESTError.offline) {
      _ = try await makeClient().transcribe(connection, "data:audio/m4a;base64,AAA", nil)
    }
  }

  @Test func malformedBodyMapsToDecodingError() async throws {
    MockURLProtocol.set(json: "not json")
    await #expect(throws: RESTError.decoding) {
      _ = try await makeClient().status(baseURL)
    }
  }

  // MARK: Profile scoping (#1 multi-profile)

  /// Read the (possibly streamed) request body back as `Data`.
  private func bodyData(_ req: URLRequest) -> Data {
    req.httpBody ?? req.httpBodyStream.map { stream -> Data in
      stream.open()
      defer { stream.close() }
      var data = Data()
      let bufSize = 1024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      return data
    } ?? Data()
  }

  @Test func archiveWithNilProfileIsUnchanged() async throws {
    // Regression guard: nil profile → no `profile` in query or body.
    MockURLProtocol.set(status: 200)
    try await makeClient().archive(connection, "sid", true, nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/sessions/sid")
    #expect(req.url?.query == nil)
    let json = try JSONSerialization.jsonObject(with: bodyData(req)) as? [String: Bool]
    #expect(json == ["archived": true])
  }

  @Test func archiveWithProfileAddsProfileToQueryAndBody() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().archive(connection, "sid", true, "work")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/sessions/sid")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query == [URLQueryItem(name: "profile", value: "work")])
    let json = try JSONSerialization.jsonObject(with: bodyData(req)) as? [String: AnyHashable]
    #expect(json == ["archived": true, "profile": "work"])
  }

  @Test func renameWithNilProfileIsUnchanged() async throws {
    // Regression guard: nil profile → no `profile` in query or body.
    MockURLProtocol.set(status: 200)
    try await makeClient().rename(connection, "sid", "New title", nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/sessions/sid")
    #expect(req.url?.query == nil)
    let json = try JSONSerialization.jsonObject(with: bodyData(req)) as? [String: String]
    #expect(json == ["title": "New title"])
  }

  @Test func renameWithProfileAddsProfileToQueryAndBody() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().rename(connection, "sid", "New title", "work")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/sessions/sid")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query == [URLQueryItem(name: "profile", value: "work")])
    let json = try JSONSerialization.jsonObject(with: bodyData(req)) as? [String: String]
    #expect(json == ["title": "New title", "profile": "work"])
  }

  // MARK: Session deletion (#73)

  @Test func deleteSessionSendsDeleteWithAuthHeaderAndNoBody() async throws {
    // Server answers the idempotent success body; we discard it — 2xx is enough.
    MockURLProtocol.set(json: #"{"ok":true,"already_absent":false}"#)
    try await makeClient().deleteSession(connection, "20260610_120231_afcca6", nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "DELETE")
    #expect(req.url?.path == "/api/sessions/20260610_120231_afcca6")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    // Default profile → no query; DELETE carries no body.
    #expect(req.url?.query == nil)
    #expect(bodyData(req).isEmpty)
  }

  @Test func deleteSessionWithProfileAddsProfileQueryOnly() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().deleteSession(connection, "sid", "work")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/sessions/sid")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query == [URLQueryItem(name: "profile", value: "work")])
    // No body even when scoped — the profile rides in the query alone.
    #expect(bodyData(req).isEmpty)
  }

  @Test func deleteSessionNotFoundMapsToTypedError() async throws {
    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.notFound) {
      try await makeClient().deleteSession(connection, "sid", nil)
    }
  }

  /// Older agents route `/api/sessions/{id}` for PATCH/GET only, so an unsupported
  /// DELETE answers 405 — it must surface as `.server(status: 405)` (capability flip),
  /// not get swallowed or mapped elsewhere.
  @Test func deleteSessionMethodNotAllowedMapsToServerError() async throws {
    MockURLProtocol.set(status: 405, json: #"{"detail":"Method Not Allowed"}"#)
    await #expect(throws: RESTError.server(status: 405, detail: "Method Not Allowed")) {
      try await makeClient().deleteSession(connection, "sid", nil)
    }
  }

  // MARK: Transcription (#7)

  @Test func transcribeReturnsTranscriptAndPostsToEndpoint() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"transcript":"hello there","provider":"local"}"#)
    let text = try await makeClient().transcribe(connection, "data:audio/m4a;base64,AAA=", "audio/m4a")
    #expect(text == "hello there")
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/audio/transcribe")
    #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
    #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
  }

  @Test func transcribeOkFalseThrowsServerReason() async throws {
    MockURLProtocol.set(json: #"{"ok":false,"error":"no speech detected"}"#)
    await #expect(throws: RESTError.transcriptionFailed("no speech detected")) {
      _ = try await makeClient().transcribe(connection, "data:audio/m4a;base64,AAA=", "audio/m4a")
    }
  }

  @Test func transcribeHTTPErrorMapsToTypedError() async throws {
    MockURLProtocol.set(status: 401)
    await #expect(throws: RESTError.unauthorized) {
      _ = try await makeClient().transcribe(connection, "data:audio/m4a;base64,AAA=", nil)
    }
  }

  // MARK: Push registration (C3 — hermes-push plugin)

  @Test func registerPushPostsSnakeCaseBody() async throws {
    // The app never signs pushes, so registration returns nothing the app must persist.
    MockURLProtocol.set(json: #"{"ok":true,"device_token":"abc123","apns_env":"sandbox"}"#)
    try await makeClient().registerPush(connection, "abc123", "sandbox", "1.2.3")

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/plugins/hermes-push/register")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let json = try JSONSerialization.jsonObject(with: bodyData(req)) as? [String: String]
    #expect(json == [
      "device_token": "abc123",
      "apns_env": "sandbox",
      "app_version": "1.2.3",
    ])
  }

  @Test func registerPushNotFoundSurfacesCapabilityGate() async throws {
    // Plugin not installed → 404 → `RESTError.notFound` (mirrors profiles/attach gating).
    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.notFound) {
      _ = try await makeClient().registerPush(connection, "abc123", "sandbox", "1.2.3")
    }
  }

  @Test func registerPushServerErrorMapsToTypedError() async throws {
    MockURLProtocol.set(status: 500, json: #"{"detail":"boom"}"#)
    await #expect(throws: RESTError.server(status: 500, detail: "boom")) {
      _ = try await makeClient().registerPush(connection, "abc123", "sandbox", "1.2.3")
    }
  }

  @Test func unregisterPushPostsDeviceTokenBody() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().unregisterPush(connection, "abc123")

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/plugins/hermes-push/unregister")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    let json = try JSONSerialization.jsonObject(with: bodyData(req)) as? [String: String]
    #expect(json == ["device_token": "abc123"])
  }

  @Test func unregisterPushNotFoundSurfacesCapabilityGate() async throws {
    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.notFound) {
      try await makeClient().unregisterPush(connection, "abc123")
    }
  }

  @Test func sendTestPushPostsToTestRoute() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().sendTestPush(connection)

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/plugins/hermes-push/test")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
  }

  @Test func sendTestPushNotFoundSurfacesCapabilityGate() async throws {
    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.notFound) {
      try await makeClient().sendTestPush(connection)
    }
  }

  @Test func sendTestPushServerErrorMapsToTypedError() async throws {
    MockURLProtocol.set(status: 500, json: #"{"detail":"boom"}"#)
    await #expect(throws: RESTError.server(status: 500, detail: "boom")) {
      try await makeClient().sendTestPush(connection)
    }
  }

  // MARK: - Push plugin readiness (GET /api/dashboard/plugins/hub)

  @Test func pushPluginStatusEnabledIsReady() async throws {
    MockURLProtocol.set(json: #"""
      {"plugins":[{"name":"other","runtime_status":"inactive"},
                  {"name":"hermes-push","runtime_status":"enabled","version":"1.0"}]}
      """#)
    let status = try await makeClient().pushPluginStatus(connection)
    #expect(status == .ready)

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/dashboard/plugins/hub")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
  }

  @Test func pushPluginStatusDisabledIsNotReady() async throws {
    MockURLProtocol.set(json: #"{"plugins":[{"name":"hermes-push","runtime_status":"disabled"}]}"#)
    #expect(try await makeClient().pushPluginStatus(connection) == .notReady)
  }

  @Test func pushPluginStatusInactiveIsNotReady() async throws {
    MockURLProtocol.set(json: #"{"plugins":[{"name":"hermes-push","runtime_status":"inactive"}]}"#)
    #expect(try await makeClient().pushPluginStatus(connection) == .notReady)
  }

  @Test func pushPluginStatusAbsentIsNotReady() async throws {
    MockURLProtocol.set(json: #"{"plugins":[{"name":"something-else","runtime_status":"enabled"}]}"#)
    #expect(try await makeClient().pushPluginStatus(connection) == .notReady)
  }

  @Test func pushPluginStatusNotFoundIsUnknown() async throws {
    MockURLProtocol.set(status: 404)
    #expect(try await makeClient().pushPluginStatus(connection) == .unknown)
  }

  @Test func pushPluginStatusTransportErrorIsUnknown() async throws {
    MockURLProtocol.set(fail: true)
    #expect(try await makeClient().pushPluginStatus(connection) == .unknown)
  }

  @Test func pushPluginStatusServerErrorIsUnknown() async throws {
    MockURLProtocol.set(status: 500)
    #expect(try await makeClient().pushPluginStatus(connection) == .unknown)
  }

  // MARK: - Push plugin info (version + updatability, same hub endpoint)

  @Test func pushPluginInfoReadsVersionAndUpdatability() async throws {
    MockURLProtocol.set(json: #"""
      {"plugins":[{"name":"other","runtime_status":"enabled","version":"9.9.9","can_update_git":true},
                  {"name":"hermes-push","runtime_status":"enabled","version":"0.1.0","can_update_git":true}]}
      """#)
    let info = await makeClient().pushPluginInfo(connection)
    #expect(info.status == .ready)
    #expect(info.version == "0.1.0")
    #expect(info.canUpdateGit)
    #expect(info.isOutdated) // 0.1.0 < the shipped minimum

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/dashboard/plugins/hub")
  }

  @Test func pushPluginInfoCurrentVersionIsNotOutdated() async throws {
    MockURLProtocol.set(json: """
      {"plugins":[{"name":"hermes-push","runtime_status":"enabled",\
      "version":"\(PushSetup.minimumPluginVersion)","can_update_git":true}]}
      """)
    let info = await makeClient().pushPluginInfo(connection)
    #expect(info.version == PushSetup.minimumPluginVersion)
    #expect(!info.isOutdated)
  }

  // Older agents omit both fields — decode leniently and offer no update rather than failing.
  @Test func pushPluginInfoToleratesMissingVersionAndFlag() async throws {
    MockURLProtocol.set(json: #"{"plugins":[{"name":"hermes-push","runtime_status":"enabled"}]}"#)
    let info = await makeClient().pushPluginInfo(connection)
    #expect(info.status == .ready)
    #expect(info.version == nil)
    #expect(!info.canUpdateGit)
    #expect(!info.isOutdated)
  }

  // The agent emits `""` when the manifest carries no version — that is absence, not a version.
  @Test func pushPluginInfoNormalizesBlankVersionToNil() async throws {
    MockURLProtocol.set(json: #"""
      {"plugins":[{"name":"hermes-push","runtime_status":"enabled","version":"  ","can_update_git":true}]}
      """#)
    let info = await makeClient().pushPluginInfo(connection)
    #expect(info.version == nil)
    #expect(!info.isOutdated)
  }

  @Test func pushPluginInfoUnreachableIsUnknownAndOffersNothing() async throws {
    MockURLProtocol.set(fail: true)
    let info = await makeClient().pushPluginInfo(connection)
    #expect(info.status == .unknown)
    #expect(info.version == nil)
    #expect(!info.canUpdateGit)
    #expect(!info.isOutdated)
  }

  // MARK: - Push plugin update (POST /api/dashboard/agent-plugins/{name}/update)

  @Test func updatePushPluginPostsToTheAgentPluginEndpoint() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"name":"hermes-push","output":"Updating 2f1b1ea..b462f0a","unchanged":false}"#)
    let result = try await makeClient().updatePushPlugin(connection)
    #expect(!result.unchanged) // pulled something → the caller must ask for a restart

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/dashboard/agent-plugins/hermes-push/update")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
  }

  @Test func updatePushPluginReportsAnUnchangedPull() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"name":"hermes-push","output":"Already up to date.","unchanged":true}"#)
    #expect(try await makeClient().updatePushPlugin(connection).unchanged)
  }

  // An agent too old to report `unchanged` is treated as CHANGED, so we prompt for the restart
  // rather than telling the user nothing happened when something might have.
  @Test func updatePushPluginAssumesChangedWhenUnchangedIsAbsent() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"name":"hermes-push"}"#)
    #expect(try await makeClient().updatePushPlugin(connection).unchanged == false)
  }

  // The agent answers 400 with a `detail` the user has to act on (not a git checkout, no
  // remote, non-fast-forward, git missing) — it must reach the UI verbatim.
  @Test func updatePushPluginSurfacesTheServerDetail() async throws {
    MockURLProtocol.set(
      status: 400,
      json: #"{"detail":"Plugin 'hermes-push' is not a git checkout; cannot pull updates."}"#
    )
    await #expect(
      throws: RESTError.server(
        status: 400,
        detail: "Plugin 'hermes-push' is not a git checkout; cannot pull updates."
      )
    ) {
      try await makeClient().updatePushPlugin(connection)
    }
  }

  // A 2xx `{"ok": false}` shouldn't happen (the agent 400s on failure) but must not be read as
  // a success — that would show "restart to apply" for an update that never ran.
  @Test func updatePushPluginTreatsOkFalseAsFailure() async throws {
    MockURLProtocol.set(json: #"{"ok":false,"error":"pull failed"}"#)
    await #expect(throws: RESTError.server(status: 200, detail: "pull failed")) {
      try await makeClient().updatePushPlugin(connection)
    }
  }

  @Test func updatePushPluginPropagatesTransportFailure() async throws {
    MockURLProtocol.set(fail: true)
    await #expect(throws: RESTError.unreachable) {
      try await makeClient().updatePushPlugin(connection)
    }
  }

  // MARK: Cron jobs

  @Test func cronJobsDecodesListWithoutProfileParam() async throws {
    MockURLProtocol.set(json: #"""
    [{"id":"a1b2c3d4e5f6","name":"Morning digest","state":"scheduled","enabled":true,"next_run_at":"2026-07-02T09:00:00+00:00","profile":"default"}]
    """#)
    let jobs = try await makeClient().cronJobs(connection, nil)
    #expect(jobs.count == 1)
    #expect(jobs.first?.id == "a1b2c3d4e5f6")
    #expect(jobs.first?.name == "Morning digest")
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/cron/jobs")
    // nil profile → no query at all (server defaults to aggregating all profiles).
    #expect(MockURLProtocol.lastRequest?.url?.query == nil)
    #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
  }

  @Test func cronJobsThreadsScopedProfile() async throws {
    MockURLProtocol.set(json: "[]")
    _ = try await makeClient().cronJobs(connection, "work")
    #expect(MockURLProtocol.lastRequest?.url?.query == "profile=work")
  }

  @Test func cronJobsNotFoundThrowsForCapabilityGate() async throws {
    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.notFound) {
      _ = try await makeClient().cronJobs(connection, nil)
    }
  }

  @Test func cronJobsServerErrorThrows() async throws {
    MockURLProtocol.set(status: 500)
    await #expect(throws: RESTError.server(status: 500)) {
      _ = try await makeClient().cronJobs(connection, nil)
    }
  }

  @Test func triggerCronJobPostsToTriggerPath() async throws {
    MockURLProtocol.set(json: #"{"id":"a1b2c3d4e5f6"}"#)
    try await makeClient().triggerCronJob(connection, "a1b2c3d4e5f6", nil)
    #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/cron/jobs/a1b2c3d4e5f6/trigger")
    #expect(MockURLProtocol.lastRequest?.url?.query == nil)
  }

  @Test func pauseAndResumePostToTheirPathsWithProfile() async throws {
    MockURLProtocol.set(json: "{}")
    try await makeClient().pauseCronJob(connection, "abc", "work")
    #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/cron/jobs/abc/pause")
    #expect(MockURLProtocol.lastRequest?.url?.query == "profile=work")

    MockURLProtocol.set(json: "{}")
    try await makeClient().resumeCronJob(connection, "abc", "work")
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/cron/jobs/abc/resume")
  }

  @Test func cronActionNotFoundThrows() async throws {
    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.notFound) {
      try await makeClient().triggerCronJob(connection, "gone", nil)
    }
  }
}
} // extension RESTTransportSuite
