import Foundation
import Testing

@testable import HermesKit

/// A `URLProtocol` stub so REST tests run fully offline. Serialized because the stub
/// state is process-global.
final class MockURLProtocol: URLProtocol {
  struct Stub: Sendable {
    /// How the stubbed transfer ends — one value, so no two endings can be set at once.
    enum Completion: Sendable {
      /// Deliver the response and `body`, then finish normally.
      case finish
      /// Fail with `failCode` before any response — the server didn't answer.
      case failBeforeResponse
      /// Deliver the response and `body` first, THEN fail with `failCode` — a connection that
      /// drops mid-transfer. Lets the streaming download tests prove a partial file is
      /// cleaned up.
      case failAfterBody
      /// Deliver the response and `body`, then never finish: the request stays in flight
      /// until its task is cancelled. Lets the download-cancel test hold the producer
      /// mid-transfer instead of racing it to the end of the body.
      case holdAfterBody
    }

    var statusCode = 200
    var body = Data()
    var completion: Completion = .finish
    /// Which `URLError` a failing stub raises. Defaults to a *generic* transport
    /// failure (server didn't answer) — the offline codes are opt-in, since
    /// `RESTError(transport:)` maps only those to `.offline`.
    var failCode: URLError.Code = .cannotConnectToHost
    var headers: [String: String] = [:]
  }

  nonisolated(unsafe) static var stub = Stub()
  nonisolated(unsafe) static var lastRequest: URLRequest?
  /// Every request the stub served, in order — the bearer tests assert that a refresh POST
  /// precedes the API call it unblocked, which `lastRequest` alone can't show.
  nonisolated(unsafe) static var requests: [URLRequest] = []
  /// Stubs consumed one per request (first-in-first-out) before falling back to `stub`.
  /// Set via `setSequence` for the multi-hop bearer flows.
  nonisolated(unsafe) static var queue: [Stub] = []

  static func set(
    status: Int = 200, json: String = "", fail: Bool = false,
    failCode: URLError.Code = .cannotConnectToHost, headers: [String: String] = [:]
  ) {
    stub = Stub(
      statusCode: status, body: Data(json.utf8), completion: fail ? .failBeforeResponse : .finish,
      failCode: failCode, headers: headers
    )
    lastRequest = nil
    requests = []
    queue = []
  }

  /// Serve `stubs` in order, one per request. A request past the end falls back to a plain
  /// 200 with an empty body, which surfaces as a decoding failure rather than a hang.
  static func setSequence(_ stubs: [Stub]) {
    stub = Stub()
    queue = stubs
    lastRequest = nil
    requests = []
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    MockURLProtocol.lastRequest = request
    MockURLProtocol.requests.append(request)
    let stub = MockURLProtocol.queue.isEmpty
      ? MockURLProtocol.stub
      : MockURLProtocol.queue.removeFirst()
    if case .failBeforeResponse = stub.completion {
      client?.urlProtocol(self, didFailWithError: URLError(stub.failCode))
      return
    }
    let http = HTTPURLResponse(
      url: request.url!, statusCode: stub.statusCode,
      httpVersion: nil, headerFields: stub.headers
    )!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: stub.body)
    switch stub.completion {
    case .finish:
      client?.urlProtocolDidFinishLoading(self)
    case .failAfterBody:
      client?.urlProtocol(self, didFailWithError: URLError(stub.failCode))
    case .holdAfterBody, .failBeforeResponse:
      break
    }
  }
}

/// Answers every request with a plain `URLResponse` (not HTTP) and an empty body.
private final class NonHTTPURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let response = URLResponse(
      url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil
    )
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }
}

/// Read a (possibly streamed) request body back as `Data` — `URLProtocol` turns `httpBody`
/// into a stream. Shared by the REST/profile/native-flow suites.
func mockRequestBody(_ req: URLRequest) -> Data {
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

  // MARK: probeStatus (#136)

  @Test func probeStatusDecodesA2xx() async throws {
    MockURLProtocol.set(json: #"{"version":"0.16.0","auth_required":true,"auth_providers":["basic"]}"#)
    let status = try await makeClient().probeStatus(baseURL).get()
    #expect(status.version == "0.16.0")
    #expect(status.authRequired == true)
    #expect(status.authProviders == ["basic"])
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.absoluteString == "http://test.local:9119/api/status")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    // Short, so an unreachable host fails per candidate in seconds, not the default minute.
    #expect(req.timeoutInterval == 10)
  }

  /// Every Hermes `/api/status` reports its `version`; another service's JSON (an empty
  /// object, a generic health check) is not Hermes.
  @Test(arguments: ["{}", #"{"status":"ok"}"#, #"{"gateway_running":true}"#])
  func probeStatusJSONWithoutAVersionIsNotHermes(body: String) async {
    MockURLProtocol.set(json: body, headers: ["Content-Type": "application/json"])
    #expect(await makeClient().probeStatus(baseURL) == .failure(.notHermes(httpStatus: 200)))
  }

  @Test func probeStatusHTMLOn2xxIsNotHermes() async {
    MockURLProtocol.set(
      json: "<!doctype html><html><body>Welcome to nginx!</body></html>",
      headers: ["Content-Type": "text/html; charset=utf-8"]
    )
    #expect(await makeClient().probeStatus(baseURL) == .failure(.notHermes(httpStatus: 200)))
  }

  @Test func probeStatus404IsNotHermes() async {
    MockURLProtocol.set(
      status: 404, json: #"{"detail":"Not Found"}"#, headers: ["Content-Type": "application/json"]
    )
    #expect(await makeClient().probeStatus(baseURL) == .failure(.notHermes(httpStatus: 404)))
  }

  @Test func probeStatus400InvalidHostIsHostRejected() async {
    let detail = "Invalid Host header. Dashboard requests must use the hostname the server was bound to."
    MockURLProtocol.set(
      status: 400, json: #"{"detail":"\#(detail)"}"#, headers: ["Content-Type": "application/json"]
    )
    #expect(await makeClient().probeStatus(baseURL) == .failure(.hostRejected(detail: detail)))
  }

  @Test func probeStatusOther400KeepsTheServerCopy() async {
    MockURLProtocol.set(status: 400, json: #"{"detail":"Bad request"}"#)
    #expect(await makeClient().probeStatus(baseURL) == .failure(.httpError("Bad request")))
  }

  @Test(arguments: [
    (URLError.Code.cannotFindHost, ProbeFailure.hostNotFound),
    (.cannotConnectToHost, .refused),
    (.timedOut, .timedOut),
    (.serverCertificateUntrusted, .untrustedCertificate),
    (.notConnectedToInternet, .offline),
  ])
  func probeStatusClassifiesTransportErrors(code: URLError.Code, expected: ProbeFailure) async {
    MockURLProtocol.set(fail: true, failCode: code)
    #expect(await makeClient().probeStatus(baseURL) == .failure(expected))
  }

  @Test func probeStatusNonHTTPResponseIsRequestFailed() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NonHTTPURLProtocol.self]
    let client = HermesRESTClient.live(session: URLSession(configuration: config))
    #expect(
      await client.probeStatus(baseURL)
        == .failure(.requestFailed("The server sent a response that isn’t HTTP."))
    )
  }

  @Test func sessionsMapsListToDomain() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","preview":"hello there","last_active":1749556800.0,"started_at":1749550000.0,"message_count":4,"unread":true,"pinned":true,"cwd":"/Users/me/dev/hermes-mobile","is_active":true,"archived":false}],"total":1,"limit":20,"offset":0}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    #expect(sessions.count == 1)
    let s = try #require(sessions.first)
    #expect(s.id == "20260610_120231_afcca6")
    #expect(s.title == "My chat")
    #expect(s.preview == "hello there")
    #expect(s.updatedAt == Date(timeIntervalSince1970: 1749556800.0))
    #expect(s.cwd == "/Users/me/dev/hermes-mobile")
    #expect(s.startedAt == Date(timeIntervalSince1970: 1749550000.0))
    #expect(s.unread == true)
    #expect(s.pinned == true)
  }

  /// The profile-scoped list and the legacy list share this row mapping.
  @Test func sessionsDecodesExplicitUnpinnedFlag() async throws {
    MockURLProtocol.set(json: #"{"sessions":[{"id":"sid","pinned":false}]}"#)
    let session = try #require(try await makeClient().sessions(connection, 20, 0, .recent, .interactive).first)
    #expect(session.pinned == false)
  }

  @Test func sessionsDecodesAbsentPinnedAsNil() async throws {
    MockURLProtocol.set(json: #"{"sessions":[{"id":"sid"}]}"#)
    let session = try #require(try await makeClient().sessions(connection, 20, 0, .recent, .interactive).first)
    #expect(session.pinned == nil)
  }

  @Test func sessionsDecodesNullPinnedAsNil() async throws {
    MockURLProtocol.set(json: #"{"sessions":[{"id":"sid","pinned":null}]}"#)
    let session = try #require(try await makeClient().sessions(connection, 20, 0, .recent, .interactive).first)
    #expect(session.pinned == nil)
  }

  @Test func sessionsDecodesCronSource() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"Nightly job","last_active":1749556800.0,"source":"cron"}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let s = try #require(sessions.first)
    #expect(s.source == "cron")
    #expect(s.isCron == true)
  }

  @Test func sessionsDecodesAbsentSourceAsNil() async throws {
    // Backward-compat: older agents omit `source` entirely → nil, not cron.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let s = try #require(sessions.first)
    #expect(s.source == nil)
    #expect(s.isCron == false)
  }

  @Test func sessionsDecodesNullSourceAsNil() async throws {
    // Leniency: a local interactive session reports `source: null` → nil, not cron.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0,"source":null}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let s = try #require(sessions.first)
    #expect(s.source == nil)
    #expect(s.isCron == false)
  }

  @Test func sessionsDecodesParentSessionID() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260724_101500_bbbb22","title":"Branch","last_active":1749556800.0,"parent_session_id":"20260610_120231_afcca6"}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let s = try #require(sessions.first)
    #expect(s.parentSessionID == "20260610_120231_afcca6")
  }

  @Test func sessionsDecodesAbsentParentSessionIDAsNil() async throws {
    // Backward-compat: older agents omit `parent_session_id` entirely → nil, decode succeeds.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let s = try #require(sessions.first)
    #expect(s.parentSessionID == nil)
  }

  @Test func sessionsDecodesNullParentSessionIDAsNil() async throws {
    // Regular (non-branch) sessions report `parent_session_id: null` → nil.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0,"parent_session_id":null}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let s = try #require(sessions.first)
    #expect(s.parentSessionID == nil)
  }

  @Test func sessionsDecodesEmptyParentSessionIDAsNil() async throws {
    // Leniency: an empty (or whitespace-only) `parent_session_id` is no parent link —
    // normalized to nil at decode so the branch flatten never sees a junk key.
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"a","last_active":1.0,"parent_session_id":""},{"id":"b","last_active":1.0,"parent_session_id":"  "}],"total":2}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
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
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let s = try #require(sessions.first)
    #expect(s.lineageRootID == "root_id")
  }

  @Test func sessionsDecodesAbsentLineageRootIDAsNil() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"My chat","last_active":1749556800.0}],"total":1}
    """#)
    let sessions = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let s = try #require(sessions.first)
    #expect(s.lineageRootID == nil)
  }

  @Test func sessionsAttachesSessionTokenHeaderAndQuery() async throws {
    MockURLProtocol.set(json: #"{"sessions":[],"total":0}"#)
    _ = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.url?.path == "/api/sessions")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "order", value: "recent")))
    #expect(query.contains(URLQueryItem(name: "limit", value: "20")))
    #expect(!query.contains { $0.name == "source" || $0.name == "exclude_sources" })
  }

  @Test func sessionsInteractiveSliceExcludesCronSource() async throws {
    MockURLProtocol.set(json: #"{"sessions":[],"total":0}"#)
    _ = try await makeClient().sessions(connection, 50, 0, .recent, .interactive)
    let req = try #require(MockURLProtocol.lastRequest)
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "exclude_sources", value: "cron")))
    #expect(!query.contains { $0.name == "source" })
  }

  @Test func sessionsCronSliceRequestsOnlyCronSource() async throws {
    MockURLProtocol.set(json: #"{"sessions":[],"total":0}"#)
    _ = try await makeClient().sessions(connection, 50, 0, .recent, .cron)
    let req = try #require(MockURLProtocol.lastRequest)
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "source", value: "cron")))
    #expect(!query.contains { $0.name == "exclude_sources" })
  }

  // MARK: Auth-regime header guards (`RequestAuth`)

  /// THE backward-compatibility guard for the bearer work: threading `RequestAuth` through
  /// the transport helpers touched every existing call site, so token mode is pinned here
  /// down to the exact header name, its verbatim value, and the ABSENCE of `Authorization`.
  @Test func tokenModeSendsOnlyTheSessionTokenHeader() async throws {
    MockURLProtocol.set(json: #"{"sessions":[],"total":0}"#)
    _ = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
  }

  /// Same guard for a write: PATCH keeps the legacy header and grows no `Authorization`.
  @Test func tokenModeWriteSendsOnlyTheSessionTokenHeader() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().archive(connection, "sid", true, nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
  }

  /// A `.cookie` connection is authenticated by the URLSession cookie jar, so the request
  /// itself carries NEITHER auth header — unchanged by the `RequestAuth` refactor.
  @Test func cookieModeSendsNeitherAuthHeader() async throws {
    let cookieConnection = ServerConnection(
      baseURL: baseURL,
      auth: .cookie(CookieSession(cookies: [], username: "ada", provider: "basic"))
    )
    MockURLProtocol.set(json: #"{"sessions":[],"total":0}"#)
    _ = try await makeClient().sessions(cookieConnection, 20, 0, .recent, .all)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
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
    let results = try await makeClient().search(connection, "matched", nil)
    let s = try #require(results.first)
    #expect(s.id == "20260610_120231_afcca6")
    #expect(s.title == nil)
    #expect(s.preview == "matched text")
    #expect(s.updatedAt == Date(timeIntervalSince1970: 1749550000.0))
    let req = try #require(MockURLProtocol.lastRequest)
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query == [URLQueryItem(name: "q", value: "matched")])
  }

  @Test(arguments: ["true", "false", "null", "omitted"])
  func searchDecodesOptionalPinnedField(value: String) async throws {
    let field = value == "omitted" ? "" : ",\"pinned\":\(value)"
    MockURLProtocol.set(json: "{\"results\":[{\"session_id\":\"sid\"\(field)}]}")
    let results = try await makeClient().search(connection, "matched", "default")
    let session = try #require(results.first)
    let expected: Bool? = value == "true" ? true : value == "false" ? false : nil
    #expect(results.count == 1)
    #expect(session.id == "sid")
    #expect(session.pinned == expected)
  }

  @Test func searchThreadsLiteralProfileIntoQuery() async throws {
    MockURLProtocol.set(json: #"{"results":[]}"#)
    _ = try await makeClient().search(connection, "matched", "default")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/sessions/search")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query == [
      URLQueryItem(name: "q", value: "matched"), URLQueryItem(name: "profile", value: "default"),
    ])
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

  @Test(arguments: [true, false])
  func setPinnedSendsProfileScopedPatchWithBooleanBody(pinned: Bool) async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().setPinned(connection, "sid", pinned, "work")

    let request = try #require(MockURLProtocol.lastRequest)
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.path == "/api/sessions/sid")
    #expect(request.url?.query == "profile=work")
    let body = try #require(JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any])
    #expect(body["pinned"] as? Bool == pinned)
    #expect(body["profile"] as? String == "work")
  }

  @Test func setPinnedWithOmittedProfileSendsFalse() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().setPinned(connection, "sid", false, nil)

    let request = try #require(MockURLProtocol.lastRequest)
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.path == "/api/sessions/sid")
    #expect(request.url?.query == nil)
    let body = try #require(JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any])
    #expect(body["pinned"] as? Bool == false)
    #expect(body["profile"] == nil)
  }

  @Test func setPinnedWithExplicitDefaultProfileIncludesProfileInBody() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().setPinned(connection, "sid", true, "default")

    let request = try #require(MockURLProtocol.lastRequest)
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.path == "/api/sessions/sid")
    #expect(request.url?.query == "profile=default")
    let body = try #require(JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any])
    #expect(body["pinned"] as? Bool == true)
    #expect(body["profile"] as? String == "default")
  }

  @Test func setPinnedMapsUnsupportedEndpointStatus() async throws {
    MockURLProtocol.set(status: 405)
    await #expect(throws: RESTError.server(status: 405)) {
      try await makeClient().setPinned(connection, "sid", true, nil)
    }
  }

  @Test func setUnreadSendsSharedReadStatePatchWithProfileScope() async throws {
    MockURLProtocol.set(status: 200)
    try await makeClient().setUnread(connection, "sid", false, "work")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "PATCH")
    #expect(req.url?.path == "/api/sessions/sid")
    #expect(req.url?.query == "profile=work")
    let body = req.httpBody ?? req.httpBodyStream.map { stream -> Data in
      stream.open()
      defer { stream.close() }
      var data = Data()
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 1024)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      return data
    } ?? Data()
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["unread"] as? Bool == false)
    #expect(json["profile"] as? String == "work")
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

  // MARK: Fenced session mutations (Hermes v0.22.1+)

  private static let snapshotJSON =
    #"{"session_id":"sid","exists":true,"runtime_revision":7,"runtime_generation":2}"#

  private func stub(_ status: Int, _ json: String = "") -> MockURLProtocol.Stub {
    MockURLProtocol.Stub(statusCode: status, body: Data(json.utf8))
  }

  private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any])
  }

  private func queryItems(_ request: URLRequest) -> [URLQueryItem] {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
  }

  /// The snapshot read goes first, profile-scoped and authenticated; the PATCH then carries a
  /// fresh lowercase `request_id` and the snapshot's fences in its body.
  @Test func fencedArchiveReadsTheSnapshotThenSendsTheIdentityInTheBody() async throws {
    MockURLProtocol.setSequence([stub(200, Self.snapshotJSON), stub(200, #"{"ok":true}"#)])
    try await makeClient().archive(connection, "sid", true, "work")

    let requests = MockURLProtocol.requests
    #expect(requests.count == 2)
    let snapshot = try #require(requests.first)
    #expect(snapshot.httpMethod == "GET")
    #expect(snapshot.url?.path == "/api/sessions/sid/mutation-snapshot")
    #expect(snapshot.url?.query == "profile=work")
    #expect(snapshot.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")

    let write = try #require(requests.last)
    #expect(write.httpMethod == "PATCH")
    #expect(write.url?.path == "/api/sessions/sid")
    #expect(write.url?.query == "profile=work")
    let body = try bodyJSON(write)
    #expect(body["archived"] as? Bool == true)
    #expect(body["profile"] as? String == "work")
    #expect(body["expected_revision"] as? Int == 7)
    #expect(body["expected_generation"] as? Int == 2)
    let requestID = try #require(body["request_id"] as? String)
    #expect(UUID(uuidString: requestID) != nil)
    #expect(requestID == requestID.lowercased())
  }

  /// Every PATCH-based write is fenced, not just archive.
  @Test(arguments: ["unread", "pinned", "title"])
  func everySessionPatchIsFenced(field: String) async throws {
    MockURLProtocol.setSequence([stub(200, Self.snapshotJSON), stub(200)])
    let client = makeClient()
    switch field {
    case "unread": try await client.setUnread(connection, "sid", false, nil)
    case "pinned": try await client.setPinned(connection, "sid", true, nil)
    default: try await client.rename(connection, "sid", "New", nil)
    }
    let write = try #require(MockURLProtocol.requests.last)
    #expect(write.httpMethod == "PATCH")
    let body = try bodyJSON(write)
    #expect(body[field] != nil)
    #expect(body["expected_revision"] as? Int == 7)
    #expect(body["request_id"] is String)
    #expect(body["profile"] == nil)
  }

  /// DELETE has no body: the identity rides in the query, after the profile.
  @Test func fencedDeleteSendsTheIdentityInTheQuery() async throws {
    MockURLProtocol.setSequence([stub(200, Self.snapshotJSON), stub(200, #"{"ok":true}"#)])
    try await makeClient().deleteSession(connection, "sid", "default")

    let write = try #require(MockURLProtocol.requests.last)
    #expect(write.httpMethod == "DELETE")
    #expect(write.url?.path == "/api/sessions/sid")
    #expect(mockRequestBody(write).isEmpty)
    let query = queryItems(write)
    #expect(query.map(\.name) == ["profile", "request_id", "expected_revision", "expected_generation"])
    #expect(query.first?.value == "default")
    #expect(query.first { $0.name == "expected_revision" }?.value == "7")
    #expect(query.first { $0.name == "expected_generation" }?.value == "2")
  }

  @Test func fencedWriteOmitsANullGeneration() async throws {
    MockURLProtocol.setSequence([
      stub(200, #"{"session_id":"sid","exists":true,"runtime_revision":0,"runtime_generation":null}"#),
      stub(200),
    ])
    try await makeClient().archive(connection, "sid", true, nil)
    let body = try bodyJSON(try #require(MockURLProtocol.requests.last))
    #expect(body["expected_revision"] as? Int == 0)
    #expect(body["expected_generation"] == nil)
  }

  /// An agent without the snapshot route gets today's unfenced request, byte for byte.
  @Test(arguments: [
    #"{"detail":"Not Found"}"#,
    #"{"detail":"No such API endpoint: /api/sessions/sid/mutation-snapshot"}"#,
    #"{"detail":"Headless backend (hermes serve): web UI disabled — use `hermes dashboard` for the browser UI."}"#,
    "",
  ])
  func unroutedSnapshotFallsBackToTheUnfencedWrite(notFoundBody: String) async throws {
    MockURLProtocol.setSequence([stub(404, notFoundBody), stub(200)])
    try await makeClient().archive(connection, "sid", true, nil)
    #expect(MockURLProtocol.requests.count == 2)
    let body = try #require(
      JSONSerialization.jsonObject(with: mockRequestBody(MockURLProtocol.requests[1])) as? [String: Bool]
    )
    #expect(body == ["archived": true])
  }

  /// A pre-guard agent's SPA answers an unknown GET with index.html: also unfenced.
  @Test func htmlSnapshotFallsBackToTheUnfencedWrite() async throws {
    MockURLProtocol.setSequence([stub(200, "<!doctype html><html></html>"), stub(200)])
    try await makeClient().deleteSession(connection, "sid", nil)
    let write = try #require(MockURLProtocol.requests.last)
    #expect(write.httpMethod == "DELETE")
    #expect(write.url?.query == nil)
  }

  /// A handler's own 404 on the snapshot (e.g. an unknown profile) is an error, never a
  /// reason to send the write unfenced.
  @Test func handlerNotFoundOnTheSnapshotThrowsWithoutWriting() async throws {
    MockURLProtocol.setSequence([stub(404, #"{"detail":"Profile 'x' does not exist."}"#)])
    await #expect(throws: RESTError.server(status: 404, detail: "Profile 'x' does not exist.")) {
      try await makeClient().archive(connection, "sid", true, "x")
    }
    #expect(MockURLProtocol.requests.count == 1)
  }

  /// A session the fencing agent no longer has: DELETE is done (the server's own
  /// `already_absent` contract), a PATCH fails — neither sends the write.
  @Test func absentSessionDeleteSucceedsWithoutWriting() async throws {
    MockURLProtocol.setSequence([
      stub(200, #"{"session_id":"sid","exists":false,"runtime_revision":0,"runtime_generation":null}"#),
    ])
    try await makeClient().deleteSession(connection, "sid", nil)
    #expect(MockURLProtocol.requests.count == 1)
  }

  @Test func absentSessionPatchThrowsWithoutWriting() async throws {
    MockURLProtocol.setSequence([
      stub(200, #"{"session_id":"sid","exists":false,"runtime_revision":0,"runtime_generation":null}"#),
    ])
    await #expect(throws: RESTError.server(status: 404, detail: "Session not found.")) {
      try await makeClient().archive(connection, "sid", true, nil)
    }
    #expect(MockURLProtocol.requests.count == 1)
  }

  /// The owner's `not_found` refusal on a fenced DELETE is not a missing-endpoint verdict —
  /// it must never hide Delete.
  @Test func fencedDeleteNotFoundRefusalIsNoMissingEndpointVerdict() async throws {
    MockURLProtocol.setSequence([stub(200, Self.snapshotJSON), stub(404, #"{"detail":"not_found"}"#)])
    let error = await #expect(throws: RESTError.self) {
      try await makeClient().deleteSession(connection, "sid", nil)
    }
    #expect(error == .server(status: 404, detail: "not_found"))
    #expect(error?.isMissingEndpointVerdict == false)
  }

  /// An older agent's 405 on the unfenced DELETE keeps its missing-endpoint verdict.
  @Test func unfencedDelete405KeepsTheMissingEndpointVerdict() async throws {
    MockURLProtocol.setSequence([stub(404, #"{"detail":"Not Found"}"#), stub(405)])
    let error = await #expect(throws: RESTError.self) {
      try await makeClient().deleteSession(connection, "sid", nil)
    }
    #expect(error?.isMissingEndpointVerdict == true)
  }

  @Test func fencedWriteRefusalCarriesTheServerReason() async throws {
    MockURLProtocol.setSequence([stub(200, Self.snapshotJSON), stub(409, #"{"detail":"session_busy"}"#)])
    await #expect(throws: RESTError.server(status: 409, detail: "session_busy")) {
      try await makeClient().archive(connection, "sid", true, nil)
    }
  }

  @Test func sessionMutationRefusalsReadAsSentences() {
    #expect(RESTError.server(status: 409, detail: "revision_conflict").sessionMutationBanner("Couldn’t archive the session.")
      == "Couldn’t archive the session. It changed on another device. Try again.")
    #expect(RESTError.server(status: 409, detail: "client_upgrade_required: this app is out of sync").sessionMutationRefusal
      == "This agent needs a newer version of the app.")
    #expect(RESTError.server(status: 503, detail: "storage_unavailable").sessionMutationRefusal != nil)
    // Anything else keeps the plain banner.
    #expect(RESTError.server(status: 400, detail: "Title too long").sessionMutationRefusal == nil)
    #expect(RESTError.unreachable.sessionMutationBanner("Couldn’t delete the session.")
      == "Couldn’t delete the session.")
  }

  @Test func unauthorizedMapsToTypedError() async throws {
    MockURLProtocol.set(status: 401, json: #"{"detail":"Unauthorized"}"#)
    await #expect(throws: RESTError.unauthorized) {
      _ = try await makeClient().sessions(connection, 20, 0, .recent, .all)
    }
  }

  /// Regression (review finding #5): a transient 429/503 on a non-login call must NOT surface
  /// the login-specific `.rateLimited`/`.serviceUnavailable` copy — it stays a generic
  /// `.server(status:)`. The login-specific mapping is scoped to `passwordLogin` only.
  @Test func nonLoginRateLimitedMapsToGenericServerError() async throws {
    MockURLProtocol.set(status: 429, json: #"{"detail":"slow down"}"#)
    await #expect(throws: RESTError.server(status: 429, detail: "slow down")) {
      _ = try await makeClient().sessions(connection, 20, 0, .recent, .all)
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
      _ = try await makeClient().sessions(connection, 1, 0, .recent, .all)
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

  // MARK: Speech synthesis (#74)

  /// Three raw bytes wrapped in a server-shaped `/api/audio/speak` success body.
  private static let speakPayload = Data([0x49, 0x44, 0x33])
  private static var speakJSON: String {
    let b64 = speakPayload.base64EncodedString()
    return #"{"ok":true,"data_url":"data:audio/mpeg;base64,"# + b64
      + #"","mime_type":"audio/mpeg","provider":"edge"}"#
  }

  @Test func speakDecodesDataURLAndPostsTextBody() async throws {
    MockURLProtocol.set(json: Self.speakJSON)
    let audio = try await makeClient().speak(connection, "Hello there.", nil)
    #expect(audio == TTSAudio(data: Self.speakPayload, mimeType: "audio/mpeg"))

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/audio/speak")
    #expect(req.url?.query == nil)
    // Token regime: the legacy header verbatim and no `Authorization` (`RequestAuth`).
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let json = try #require(
      JSONSerialization.jsonObject(with: bodyData(req)) as? [String: Any]
    )
    // `text` is the ONLY field `TTSSpeakRequest` accepts.
    #expect(json.count == 1)
    #expect(json["text"] as? String == "Hello there.")
  }

  /// Cookie regime: `speak` resolves auth through the same `RequestAuth` path as every other
  /// REST call, so a `.cookie` connection carries neither auth header — the URLSession cookie
  /// jar authenticates it (the bearer regime is pinned in `NativeOAuthClientTests`).
  @Test func speakInCookieModeSendsNeitherAuthHeader() async throws {
    let cookieConnection = ServerConnection(
      baseURL: baseURL,
      auth: .cookie(CookieSession(cookies: [], username: "ada", provider: "basic"))
    )
    MockURLProtocol.set(json: Self.speakJSON)
    _ = try await makeClient().speak(cookieConnection, "Hi", "work")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/audio/speak")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test(arguments: ["work", "default"])
  func speakWithProfileAddsProfileQueryOnly(profile: String) async throws {
    // #114: the literal name rides in the query, `"default"` included; the body stays `{text}`.
    MockURLProtocol.set(json: Self.speakJSON)
    _ = try await makeClient().speak(connection, "Hi", profile)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/audio/speak")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query == [URLQueryItem(name: "profile", value: profile)])
    let json = try #require(
      JSONSerialization.jsonObject(with: bodyData(req)) as? [String: Any]
    )
    #expect(json.keys.sorted() == ["text"])
  }

  @Test func speakNotFoundIsMissingEndpointVerdict() async throws {
    MockURLProtocol.set(status: 404)
    let error = await #expect(throws: RESTError.self) {
      _ = try await makeClient().speak(connection, "Hi", nil)
    }
    #expect(error == .notFound)
    #expect(error?.isMissingEndpointVerdict == true)
  }

  /// FastAPI's own unmatched-route body is the same verdict.
  @Test func speakRouteNotFoundBodyIsMissingEndpointVerdict() async throws {
    MockURLProtocol.set(status: 404, json: #"{"detail":"Not Found"}"#)
    let error = await #expect(throws: RESTError.self) {
      _ = try await makeClient().speak(connection, "Hi", "work")
    }
    #expect(error == .notFound)
  }

  /// The handler's own 404 — an unknown `?profile=` (`_config_profile_scope`) — is NOT a
  /// missing route: it keeps its detail for the banner.
  @Test func speakUnknownProfileIsNotAMissingEndpointVerdict() async throws {
    MockURLProtocol.set(status: 404, json: #"{"detail":"Profile 'gone' does not exist."}"#)
    let error = await #expect(throws: RESTError.self) {
      _ = try await makeClient().speak(connection, "Hi", "gone")
    }
    #expect(error == .server(status: 404, detail: "Profile 'gone' does not exist."))
    #expect(error?.isMissingEndpointVerdict == false)
    #expect(error?.message == "Profile 'gone' does not exist.")
  }

  /// A pre-desktop agent's SPA catch-all is `GET /{full_path:path}`, so a POST answers 405 —
  /// the same capability verdict as a 404.
  @Test func speakMethodNotAllowedIsMissingEndpointVerdict() async throws {
    MockURLProtocol.set(status: 405, json: #"{"detail":"Method Not Allowed"}"#)
    let error = await #expect(throws: RESTError.self) {
      _ = try await makeClient().speak(connection, "Hi", nil)
    }
    #expect(error == .server(status: 405, detail: "Method Not Allowed"))
    #expect(error?.isMissingEndpointVerdict == true)
  }

  @Test func speakBadRequestCarriesServerDetail() async throws {
    MockURLProtocol.set(status: 400, json: #"{"detail":"Text is empty after TTS cleanup"}"#)
    let error = await #expect(throws: RESTError.self) {
      _ = try await makeClient().speak(connection, "```code```", nil)
    }
    #expect(error == .server(status: 400, detail: "Text is empty after TTS cleanup"))
    #expect(error?.isMissingEndpointVerdict == false)
    #expect(error?.message == "Text is empty after TTS cleanup")
  }

  @Test func speakServerErrorCarriesDetail() async throws {
    MockURLProtocol.set(status: 500, json: #"{"detail":"Audio file missing"}"#)
    await #expect(throws: RESTError.server(status: 500, detail: "Audio file missing")) {
      _ = try await makeClient().speak(connection, "Hi", nil)
    }
  }

  @Test func speakMalformedDataURLMapsToDecoding() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"data_url":"not-a-data-url","mime_type":"audio/mpeg"}"#)
    await #expect(throws: RESTError.decoding) {
      _ = try await makeClient().speak(connection, "Hi", nil)
    }
  }

  @Test func speakMissingDataURLMapsToDecoding() async throws {
    MockURLProtocol.set(json: #"{"ok":true}"#)
    await #expect(throws: RESTError.decoding) {
      _ = try await makeClient().speak(connection, "Hi", nil)
    }
  }

  /// Defensive: the server never answers a 2xx `ok:false`, but if one arrives it must fail
  /// rather than play nothing.
  @Test func speakOkFalseMapsToServerError() async throws {
    MockURLProtocol.set(json: #"{"ok":false}"#)
    await #expect(throws: RESTError.server(status: 200, detail: nil)) {
      _ = try await makeClient().speak(connection, "Hi", nil)
    }
  }

  @Test func speakRequestCarriesScaledTimeout() async throws {
    MockURLProtocol.set(json: Self.speakJSON)
    let text = String(repeating: "a", count: 10_000)
    _ = try await makeClient().speak(connection, text, nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.timeoutInterval == HermesRESTClient.speakTimeout(forCharacterCount: 10_000))
    #expect(req.timeoutInterval == 350)
  }

  @Test(arguments: [
    (0, 180.0), (12, 180.0), (5_142, 180.0), (10_000, 350.0), (17_142, 599.97), (20_000, 600.0),
    (1_000_000, 600.0),
  ])
  func speakTimeoutScalesWithText(count: Int, expected: TimeInterval) {
    #expect(abs(HermesRESTClient.speakTimeout(forCharacterCount: count) - expected) < 0.000_1)
  }

  @Test func transcribeKeepsDefaultTimeout() async throws {
    // `postJSON`'s new `timeout:` is opt-in — the transcribe request keeps URLRequest's 60 s.
    MockURLProtocol.set(json: #"{"ok":true,"transcript":"hi"}"#)
    _ = try await makeClient().transcribe(connection, "data:audio/m4a;base64,AAA=", nil)
    #expect(MockURLProtocol.lastRequest?.timeoutInterval == 60)
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

  @Test func triggerStillPostsAnEmptyObjectBody() async throws {
    // Regression for the method-aware `cronJobAction`: the POST actions keep their `{}` body.
    MockURLProtocol.set(json: "{}")
    try await makeClient().triggerCronJob(connection, "abc", "work")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/cron/jobs/abc/trigger")
    #expect(req.url?.query == "profile=work")
    #expect(mockRequestBody(req) == Data("{}".utf8))
  }

  // MARK: Cron job delete

  @Test func deleteCronJobSendsDeleteWithoutBody() async throws {
    MockURLProtocol.set(json: #"{"ok":true}"#)
    try await makeClient().deleteCronJob(connection, "a1b2c3d4e5f6", nil)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "DELETE")
    #expect(req.url?.path == "/api/cron/jobs/a1b2c3d4e5f6")
    #expect(req.url?.query == nil)
    #expect(mockRequestBody(req).isEmpty)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
  }

  @Test func deleteCronJobThreadsProfileInQuery() async throws {
    MockURLProtocol.set(json: #"{"ok":true}"#)
    try await makeClient().deleteCronJob(connection, "abc", "default")
    #expect(MockURLProtocol.lastRequest?.url?.path == "/api/cron/jobs/abc")
    #expect(MockURLProtocol.lastRequest?.url?.query == "profile=default")
  }

  @Test func deleteCronJobNotFoundThrows() async throws {
    MockURLProtocol.set(status: 404, json: #"{"detail":"Job not found"}"#)
    await #expect(throws: RESTError.notFound) {
      try await makeClient().deleteCronJob(connection, "gone", nil)
    }
  }

  @Test func deleteCronJobBadIDSurfacesDetail() async throws {
    MockURLProtocol.set(status: 400, json: #"{"detail":"Invalid job id"}"#)
    await #expect(throws: RESTError.server(status: 400, detail: "Invalid job id")) {
      try await makeClient().deleteCronJob(connection, "../x", nil)
    }
  }

  // MARK: Cron job runs

  @Test func cronJobRunsRequestsRunsPathWithLimit() async throws {
    MockURLProtocol.set(json: #"{"runs":[],"limit":5}"#)
    let runs = try await makeClient().cronJobRuns(connection, "a1b2c3d4e5f6", nil, 5)
    #expect(runs.isEmpty)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.path == "/api/cron/jobs/a1b2c3d4e5f6/runs")
    // nil profile → only `limit`, no `profile` param.
    #expect(req.url?.query == "limit=5")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
  }

  @Test func cronJobRunsThreadsProfileAndLimit() async throws {
    MockURLProtocol.set(json: #"{"runs":[],"limit":20}"#)
    _ = try await makeClient().cronJobRuns(connection, "abc", "work", 20)
    let items = URLComponents(
      url: try #require(MockURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
    )?.queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "limit", value: "20")))
    #expect(items.contains(URLQueryItem(name: "profile", value: "work")))
    #expect(items.count == 2)
  }

  @Test func cronJobRunsDecodesSessionAndScriptRows() async throws {
    MockURLProtocol.set(json: #"""
    {"runs":[
      {"id":"local-1a2b3c","title":"Morning digest","source":"cron","started_at":1762588800.0,"last_active":1762588860.0,"message_count":4,"unread":true},
      {"id":"cron_output:abc:2026-11-08_08-00-00","title":"OK","preview":"done","source":"cron_output","started_at":1762502400.0,"last_active":1762502400.0,"message_count":0,"is_active":false,"model":null,"cwd":null}
    ],"limit":5}
    """#)
    let runs = try await makeClient().cronJobRuns(connection, "abc", nil, 5)
    #expect(runs.map(\.id) == ["local-1a2b3c", "cron_output:abc:2026-11-08_08-00-00"])
    #expect(runs[0].isCron == true)
    #expect(runs[0].unread == true)
    #expect(runs[0].updatedAt == Date(timeIntervalSince1970: 1762588860))
    #expect(runs[1].source == "cron_output")
    #expect(runs[1].isCron == false)
    #expect(runs[1].startedAt == Date(timeIntervalSince1970: 1762502400))
  }

  @Test func cronJobRunsDropsRowWithoutID() async throws {
    MockURLProtocol.set(json: #"""
    {"runs":[
      {"id":"local-1","source":"cron","started_at":1762588800.0},
      {"title":"OK","source":"cron_output","started_at":1762502400.0},
      {"id":"local-2","source":"cron","started_at":1762416000.0}
    ],"limit":5}
    """#)
    let runs = try await makeClient().cronJobRuns(connection, "abc", nil, 5)
    #expect(runs.map(\.id) == ["local-1", "local-2"])
  }

  @Test func cronJobRunsMissingRunsKeyYieldsEmpty() async throws {
    MockURLProtocol.set(json: #"{"limit":5}"#)
    let runs = try await makeClient().cronJobRuns(connection, "abc", nil, 5)
    #expect(runs.isEmpty)
  }

  @Test func cronJobRunsNullRunsYieldsEmpty() async throws {
    MockURLProtocol.set(json: #"{"runs":null}"#)
    let runs = try await makeClient().cronJobRuns(connection, "abc", nil, 5)
    #expect(runs.isEmpty)
  }

  @Test func cronJobRunsNotFoundThrows() async throws {
    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.notFound) {
      _ = try await makeClient().cronJobRuns(connection, "gone", nil, 5)
    }
  }
}
} // extension RESTTransportSuite
