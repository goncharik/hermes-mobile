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
    var headers: [String: String] = [:]
  }

  nonisolated(unsafe) static var stub = Stub()
  nonisolated(unsafe) static var lastRequest: URLRequest?

  static func set(
    status: Int = 200, json: String = "", fail: Bool = false, headers: [String: String] = [:]
  ) {
    stub = Stub(statusCode: status, body: Data(json.utf8), failWithError: fail, headers: headers)
    lastRequest = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    MockURLProtocol.lastRequest = request
    if MockURLProtocol.stub.failWithError {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
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
}
} // extension RESTTransportSuite
