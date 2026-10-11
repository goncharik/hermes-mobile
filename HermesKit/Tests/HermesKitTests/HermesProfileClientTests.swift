import Foundation
import Testing

@testable import HermesKit

/// Reuses `MockURLProtocol` (defined in `HermesRESTClientTests.swift`) so profile REST
/// tests run fully offline. Nested under `RESTTransportSuite` so its `.serialized` trait
/// serializes these against the REST tests too (they share the process-global stub).
extension RESTTransportSuite {
struct HermesProfileClientTests {
  private let baseURL = URL(string: "http://test.local:9119")!
  private var connection: ServerConnection { ServerConnection(baseURL: baseURL, token: "tok") }

  private func makeClient() -> HermesProfileClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return .live(session: URLSession(configuration: config))
  }

  /// Reads the PATCH/POST/PUT body back from the request (URLProtocol streams httpBody).
  private func body(of req: URLRequest) -> Data {
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

  // MARK: list

  @Test func listDecodesProfilesAndHitsEndpoint() async throws {
    MockURLProtocol.set(json: #"""
    {"profiles":[
      {"name":"default","is_default":true,"model":"gpt-5.5","provider":"openai","skill_count":3,"has_env":true},
      {"name":"work","is_default":false,"skill_count":0,"has_env":false}
    ]}
    """#)
    let profiles = try await makeClient().list(connection)
    #expect(profiles.count == 2)
    #expect(profiles.first?.name == "default")
    #expect(profiles.first?.isDefault == true)
    #expect(profiles.first?.model == "gpt-5.5")
    #expect(profiles.first?.skillCount == 3)
    #expect(profiles.last?.name == "work")
    #expect(profiles.last?.isDefault == false)
    #expect(profiles.last?.model == nil)

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/profiles")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
  }

  @Test func listNotFoundSurfacesAsRESTError() async throws {
    // Gating: an agent without the profiles API returns 404 → `RESTError.notFound`.
    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.notFound) {
      _ = try await makeClient().list(connection)
    }
  }

  // MARK: create

  @Test func createPostsNameAndCloneFlag() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"name":"work","path":"/h/work"}"#)
    try await makeClient().create(connection, "work", true)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/profiles")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    let json = try JSONSerialization.jsonObject(with: body(of: req)) as? [String: Any]
    #expect(json?["name"] as? String == "work")
    #expect(json?["clone_from_default"] as? Bool == true)
  }

  @Test func createServer400SurfacesDetailVerbatim() async throws {
    // The Add-profile banner must show the server's `detail` field verbatim.
    let detail = "Profile name 'test' is reserved — pick a different name."
    MockURLProtocol.set(status: 400, json: #"{"detail":"\#(detail)"}"#)
    let error = await #expect(throws: RESTError.self) {
      try await makeClient().create(connection, "test", false)
    }
    #expect(error == .server(status: 400, detail: detail))
    #expect(error?.message == detail)
  }

  @Test func createServer400EmptyBodyFallsBackToGenericMessage() async throws {
    // No body → no detail → the generic status message.
    MockURLProtocol.set(status: 400)
    let error = await #expect(throws: RESTError.self) {
      try await makeClient().create(connection, "test", false)
    }
    #expect(error == .server(status: 400, detail: nil))
    #expect(error?.message == "Server error (400).")
  }

  @Test func createServer400NonJSONBodySurfacesTrimmedText() async throws {
    // A plain-text (non-JSON) body falls back to the trimmed body text.
    MockURLProtocol.set(status: 400, json: "  Bad Request  ")
    let error = await #expect(throws: RESTError.self) {
      try await makeClient().create(connection, "test", false)
    }
    #expect(error == .server(status: 400, detail: "Bad Request"))
    #expect(error?.message == "Bad Request")
  }

  // MARK: updateSoul

  @Test func updateSoulPutsContentToSoulEndpoint() async throws {
    MockURLProtocol.set(json: #"{"ok":true}"#)
    try await makeClient().updateSoul(connection, "work", "You are helpful.")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "PUT")
    #expect(req.url?.path == "/api/profiles/work/soul")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    let json = try JSONSerialization.jsonObject(with: body(of: req)) as? [String: String]
    #expect(json == ["content": "You are helpful."])
  }

  // MARK: rename

  @Test func renamePatchesNewName() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"name":"work-2","path":"/h/work-2"}"#)
    try await makeClient().rename(connection, "work", "work-2")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "PATCH")
    #expect(req.url?.path == "/api/profiles/work")
    let json = try JSONSerialization.jsonObject(with: body(of: req)) as? [String: String]
    #expect(json == ["new_name": "work-2"])
  }

  // MARK: delete

  @Test func deleteHitsProfileEndpointWithDELETE() async throws {
    MockURLProtocol.set(json: #"{"ok":true,"path":"/h/work"}"#)
    try await makeClient().delete(connection, "work")
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "DELETE")
    #expect(req.url?.path == "/api/profiles/work")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
  }

  // MARK: sessions

  @Test func sessionsBuildsScopedQueryAndDecodesRows() async throws {
    MockURLProtocol.set(json: #"""
    {"sessions":[{"id":"20260610_120231_afcca6","title":"Work chat","preview":"hi","last_active":1749556800.0,"started_at":1749550000.0,"message_count":2,"cwd":"/w","is_active":false,"pinned":true}],"profile_totals":{"total":1}}
    """#)
    let sessions = try await makeClient().sessions(connection, "work", .exclude, .recent, 20, 0)
    #expect(sessions.count == 1)
    let s = try #require(sessions.first)
    #expect(s.id == "20260610_120231_afcca6")
    #expect(s.title == "Work chat")
    #expect(s.preview == "hi")
    #expect(s.cwd == "/w")
    #expect(s.pinned == true)

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/profiles/sessions")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "profile", value: "work")))
    #expect(query.contains(URLQueryItem(name: "archived", value: "exclude")))
    #expect(query.contains(URLQueryItem(name: "order", value: "recent")))
    #expect(query.contains(URLQueryItem(name: "limit", value: "20")))
    #expect(query.contains(URLQueryItem(name: "offset", value: "0")))
  }

  @Test func sessionsArchivedOnlyMapsToOnlyQuery() async throws {
    MockURLProtocol.set(json: #"{"sessions":[],"profile_totals":{}}"#)
    _ = try await makeClient().sessions(connection, "work", .only, .recent, 50, 0)
    let req = try #require(MockURLProtocol.lastRequest)
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "archived", value: "only")))
  }

  // MARK: in-memory variant

  @Test func inMemoryCreateRenameDeleteRoundTrip() async throws {
    let client = HermesProfileClient.inMemory()
    let conn = connection
    #expect(try await client.list(conn).map(\.name) == ["default"])

    try await client.create(conn, "work", true)
    #expect(try await client.list(conn).map(\.name) == ["default", "work"])

    try await client.rename(conn, "work", "work-2")
    #expect(try await client.list(conn).map(\.name) == ["default", "work-2"])

    try await client.delete(conn, "work-2")
    #expect(try await client.list(conn).map(\.name) == ["default"])

    // Soul + sessions are no-ops in the in-memory variant.
    try await client.updateSoul(conn, "default", "hi")
    #expect(try await client.sessions(conn, "default", .exclude, .recent, 20, 0).isEmpty)
  }
}
} // extension RESTTransportSuite
