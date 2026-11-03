import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// `FilePreviewClient.live` over `MockURLProtocol`: request shape + auth header for the
/// `/api/fs/*` routes, the status → `RESTError` mapping the reducer relies on, the data-URL
/// decode, and the streaming download's temp-file lifecycle.
///
/// Nested in `RESTTransportSuite` so it serializes against the other suites that drive the
/// process-global `MockURLProtocol` stub.
extension RESTTransportSuite {
struct FilePreviewClientTests {
  private let baseURL = URL(string: "http://test.local:9119")!
  private var connection: ServerConnection { ServerConnection(baseURL: baseURL, token: "tok") }

  /// A scratch root per test so a leftover directory can be asserted against exactly.
  private let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("FilePreviewClientTests-\(UUID().uuidString)", isDirectory: true)

  private var downloadsRoot: URL {
    scratch.appendingPathComponent(downloadsDirectoryName, isDirectory: true)
  }

  private func makeClient(tokenStore: BearerTokenStore = BearerTokenStore()) -> FilePreviewClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return .live(
      session: URLSession(configuration: config), tokenStore: tokenStore, temporaryDirectory: scratch
    )
  }

  private func removeScratch() {
    try? FileManager.default.removeItem(at: scratch)
  }

  /// Names of the per-download `<UUID>` folders currently under the root (empty = clean).
  private func downloadFolders() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: downloadsRoot.path)) ?? []
  }

  /// The query as the server decodes it (`URLComponents` percent-decodes the values).
  private func queryItems(_ request: URLRequest?) -> [String: String] {
    let items = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
    return items.reduce(into: [:]) { $0[$1.name] = $1.value }
  }

  private func collect(_ stream: AsyncThrowingStream<DownloadEvent, any Error>) async throws -> [DownloadEvent] {
    var events: [DownloadEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private func fractions(_ events: [DownloadEvent]) -> [Double?] {
    events.compactMap { if case let .progress(fraction) = $0 { fraction } else { nil } }
  }

  private func finishedURL(_ events: [DownloadEvent]) -> URL? {
    events.compactMap { if case let .finished(url) = $0 { url } else { nil } }.last
  }

  private func stored(expiresAt: Double) -> BearerSession {
    BearerSession(accessToken: "AT1", refreshToken: "RT1", expiresAt: expiresAt, provider: "nous", userID: "u-1")
  }

  private static let textJSON = #"""
  {"binary":false,"byteSize":42,"language":"swift","mimeType":"text/x-swift","path":"/home/e/a.swift","text":"let x = 1\n","truncated":false}
  """#

  private static let sandboxDetail = "File not found on the gateway host: the path may live inside the agent sandbox"

  // MARK: - read-text

  @Test func readTextSendsPathSessionAndTokenHeader() async throws {
    MockURLProtocol.set(json: Self.textJSON)
    let read = try await makeClient().readText(connection, "/home/e/a.swift", "sess-1", nil)

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.path == "/api/fs/read-text")
    #expect(queryItems(req) == ["path": "/home/e/a.swift", "session_id": "sess-1"])
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)

    #expect(read == FileTextRead(
      binary: false, byteSize: 42, language: "swift", mimeType: "text/x-swift",
      text: "let x = 1\n", truncated: false
    ))
  }

  @Test func readTextSendsTheProfileWhenScoped() async throws {
    // The multi-profile rule: the literal name (`"default"` included) rides as `profile`, so
    // the server looks `session_id` up in that profile's DB instead of its launch profile's.
    MockURLProtocol.set(json: Self.textJSON)
    _ = try await makeClient().readText(connection, "/home/e/a.swift", "sess-1", "work")
    #expect(queryItems(MockURLProtocol.lastRequest) == [
      "path": "/home/e/a.swift", "session_id": "sess-1", "profile": "work",
    ])
  }

  @Test func readTextOmitsSessionIDAndProfileWhenNil() async throws {
    MockURLProtocol.set(json: Self.textJSON)
    _ = try await makeClient().readText(connection, "~/notes.md", nil, nil)
    let items = queryItems(MockURLProtocol.lastRequest)
    #expect(items == ["path": "~/notes.md"])
    #expect(items["session_id"] == nil)
    #expect(items["profile"] == nil)
  }

  @Test func fsQueryPercentEncodesEveryReservedCharacter() async throws {
    // `URLComponents.queryItems` would leave `+` bare, and the server's form decoding reads a
    // bare `+` as a space — so the RAW query is asserted, not its decoded form.
    MockURLProtocol.set(json: Self.textJSON)
    let path = "/a/b+c&d=e f%g?h#i~@.pdf"
    _ = try await makeClient().readText(connection, path, "s+1", "p+q")

    let url = try #require(MockURLProtocol.lastRequest?.url)
    let raw = try #require(url.query)
    #expect(raw == "path=%2Fa%2Fb%2Bc%26d%3De%20f%25g%3Fh%23i~%40.pdf&session_id=s%2B1&profile=p%2Bq")
    #expect(!raw.contains("+"))
    // ...and the server-side decode gives the path back byte-for-byte.
    #expect(queryItems(MockURLProtocol.lastRequest) == ["path": path, "session_id": "s+1", "profile": "p+q"])
  }

  @Test func readTextBearerSendsAuthorizationHeader() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = BearerTokenStore(now: { now }, refreshLeeway: 120)
    store.seed(stored(expiresAt: 1_000_600), baseURL: baseURL, persist: { _ in }) // fresh → no refresh hop
    let bearer = ServerConnection(baseURL: baseURL, auth: .bearer(stored(expiresAt: 0)))

    MockURLProtocol.set(json: Self.textJSON)
    _ = try await makeClient(tokenStore: store).readText(bearer, "/a/b.txt", nil, nil)

    #expect(MockURLProtocol.requests.count == 1)
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer AT1")
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
  }

  @Test func readTextDecodesLenientlyAndKeepsTheBinaryVerdict() async throws {
    // Minimal body: a binary verdict with nothing else — flags default, text is empty.
    MockURLProtocol.set(json: #"{"binary":true,"byteSize":2048}"#)
    let read = try await makeClient().readText(connection, "/a/b.bin", nil, nil)
    #expect(read.binary == true)
    #expect(read.byteSize == 2048)
    #expect(read.text == "")
    #expect(read.truncated == false)
    #expect(read.language == nil)
  }

  @Test func readTextTruncatedFlagSurvives() async throws {
    MockURLProtocol.set(json: #"{"binary":false,"text":"abc","truncated":true}"#)
    let read = try await makeClient().readText(connection, "/a/big.log", nil, nil)
    #expect(read.truncated == true)
  }

  // MARK: - read-data-url

  @Test func readDataDecodesAPNGDataURL() async throws {
    MockURLProtocol.set(json: #"{"dataUrl":"data:image/png;base64,\#(DataURLTests.pngBase64)"}"#)
    let read = try await makeClient().readData(connection, "/shots/a.png", "sess-1", "work")

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/fs/read-data-url")
    #expect(queryItems(req) == ["path": "/shots/a.png", "session_id": "sess-1", "profile": "work"])
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")

    #expect(read.mimeType == "image/png")
    #expect(read.data == Data(base64Encoded: DataURLTests.pngBase64))
  }

  @Test func readDataMalformedDataURLIsADecodingError() async {
    MockURLProtocol.set(json: #"{"dataUrl":"data:image/png,not-base64"}"#)
    await #expect(throws: RESTError.decoding) {
      _ = try await makeClient().readData(connection, "/shots/a.png", nil, nil)
    }
  }

  @Test func readDataMissingKeyIsADecodingError() async {
    MockURLProtocol.set(json: #"{"path":"/shots/a.png"}"#)
    await #expect(throws: RESTError.decoding) {
      _ = try await makeClient().readData(connection, "/shots/a.png", nil, nil)
    }
  }

  // MARK: - Status mapping

  @Test func notFoundCarriesTheServerDetail() async {
    // Unlike the shared `validate` (detail-less `.notFound`), the fs routes keep the 404 body:
    // its `detail` is the sandbox hint the generic card shows.
    MockURLProtocol.set(status: 404, json: #"{"detail":"\#(Self.sandboxDetail)"}"#)
    await #expect(throws: RESTError.server(status: 404, detail: Self.sandboxDetail)) {
      _ = try await makeClient().readText(connection, "/workspace/out/b.txt", nil, nil)
    }
    await #expect(throws: RESTError.server(status: 404, detail: Self.sandboxDetail)) {
      _ = try await makeClient().readData(connection, "/workspace/out/b.png", nil, nil)
    }

    MockURLProtocol.set(status: 404)
    await #expect(throws: RESTError.server(status: 404, detail: nil)) {
      _ = try await makeClient().readText(connection, "/a/b.txt", nil, nil)
    }
  }

  @Test func forbiddenCarriesTheServerDetail() async {
    MockURLProtocol.set(status: 403, json: #"{"detail":"Access to this file is not allowed"}"#)
    await #expect(throws: RESTError.server(status: 403, detail: "Access to this file is not allowed")) {
      _ = try await makeClient().readText(connection, "/home/e/.env", nil, nil)
    }
  }

  @Test func payloadTooLargeCarriesTheServerDetail() async {
    MockURLProtocol.set(status: 413, json: #"{"detail":"File too large for preview (max 16 MB)"}"#)
    await #expect(throws: RESTError.server(status: 413, detail: "File too large for preview (max 16 MB)")) {
      _ = try await makeClient().readData(connection, "/home/e/huge.png", nil, nil)
    }
  }

  @Test func unauthorizedKeepsItsTypedVerdict() async {
    MockURLProtocol.set(status: 401, json: #"{"detail":"Unauthorized"}"#)
    await #expect(throws: RESTError.unauthorized) {
      _ = try await makeClient().readText(connection, "/a/b.txt", nil, nil)
    }
  }

  @Test func transportFailureIsUnreachable() async {
    MockURLProtocol.set(fail: true)
    await #expect(throws: RESTError.unreachable) {
      _ = try await makeClient().readText(connection, "/a/b.txt", nil, nil)
    }
  }

  // MARK: - download

  @Test func downloadWritesTheFileAndReportsDeterminateProgress() async throws {
    defer { removeScratch() }
    let body = Data(repeating: 0xAB, count: 200 * 1024) // 3 full 64 KB chunks + a tail
    MockURLProtocol.set(status: 200, headers: ["Content-Length": String(body.count)])
    MockURLProtocol.stub.body = body

    let events = try await collect(makeClient().download(connection, "/home/e/out/report.pdf", "sess-1", "work", "report.pdf"))

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.url?.path == "/api/fs/download")
    #expect(queryItems(req) == ["path": "/home/e/out/report.pdf", "session_id": "sess-1", "profile": "work"])
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")

    // One progress per flushed chunk, then the final 1.0, then `finished` last.
    let expected: [Double] = [64.0 / 200, 128.0 / 200, 192.0 / 200, 1.0]
    let reported = fractions(events)
    let got = reported.compactMap { $0 }
    #expect(got.count == reported.count, "every fraction is known when Content-Length is announced")
    #expect(got.count == expected.count)
    for (a, b) in zip(got, expected) { #expect(abs(a - b) < 1e-9) }
    guard case .finished(let url)? = events.last else {
      Issue.record("expected .finished last, got \(events)")
      return
    }

    #expect(url.lastPathComponent == "report.pdf")
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == downloadsDirectoryName)
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() == scratch)
    #expect(try Data(contentsOf: url) == body)
    #expect(downloadFolders().count == 1)
  }

  @Test func downloadWithoutContentLengthReportsNilFractions() async throws {
    defer { removeScratch() }
    let body = Data(repeating: 0x01, count: 130 * 1024)
    MockURLProtocol.set(status: 200)
    MockURLProtocol.stub.body = body

    let events = try await collect(makeClient().download(connection, "/a/b.zip", nil, nil, "b.zip"))

    #expect(queryItems(MockURLProtocol.lastRequest) == ["path": "/a/b.zip"])
    let progress = fractions(events)
    #expect(!progress.isEmpty)
    #expect(progress.allSatisfy { $0 == nil })
    let url = try #require(finishedURL(events))
    #expect(try Data(contentsOf: url) == body)
  }

  @Test func downloadOfAnEmptyFileLandsFullThenFinishes() async throws {
    defer { removeScratch() }
    // `Content-Length: 0`: no chunk ever flushes, so the only progress is the final full bar.
    MockURLProtocol.set(status: 200, headers: ["Content-Length": "0"])
    MockURLProtocol.stub.body = Data()

    let events = try await collect(makeClient().download(connection, "/a/empty.txt", nil, nil, "empty.txt"))

    let url = try #require(finishedURL(events))
    #expect(events == [.progress(1.0), .finished(url)])
    #expect(try Data(contentsOf: url).isEmpty)
  }

  @Test func downloadNonSuccessStatusThrowsAndLeavesNoDirectory() async throws {
    defer { removeScratch() }
    MockURLProtocol.set(status: 404, json: #"{"detail":"File not found"}"#)
    await #expect(throws: RESTError.server(status: 404, detail: "File not found")) {
      _ = try await collect(makeClient().download(connection, "/a/missing.pdf", nil, nil, "missing.pdf"))
    }
    MockURLProtocol.set(status: 403, json: #"{"detail":"Access to this file is not allowed"}"#)
    await #expect(throws: RESTError.server(status: 403, detail: "Access to this file is not allowed")) {
      _ = try await collect(makeClient().download(connection, "/a/.env", nil, nil, ".env"))
    }
    #expect(downloadFolders().isEmpty)
  }

  @Test func downloadMidTransferFailureRemovesThePartialDirectory() async throws {
    defer { removeScratch() }
    // 200 KB arrive, then the connection drops.
    MockURLProtocol.set(status: 200, headers: ["Content-Length": "4000000"])
    MockURLProtocol.stub.completion = .failAfterBody
    MockURLProtocol.stub.body = Data(repeating: 0x02, count: 200 * 1024)

    await #expect(throws: RESTError.unreachable) {
      _ = try await collect(makeClient().download(connection, "/a/b.bin", nil, nil, "b.bin"))
    }
    #expect(downloadFolders().isEmpty)
  }

  @Test func downloadCancelledByTheConsumerRemovesThePartialDirectory() async throws {
    defer { removeScratch() }
    // The server announces 1 MB, delivers 128 KB, then the transfer stalls (`holdAfterBody`),
    // so the producer can never reach `.finished` before the consumer cancels.
    let body = Data(repeating: 0x03, count: 128 * 1024)
    MockURLProtocol.set(status: 200, headers: ["Content-Length": String(1024 * 1024)])
    MockURLProtocol.stub.completion = .holdAfterBody
    MockURLProtocol.stub.body = body

    let stream = makeClient().download(connection, "/a/big.bin", nil, nil, "big.bin")
    // The shape of a TCA effect: a task iterating the stream that gets cancelled mid-way
    // (`.cancelDownload`, or `.ifLet` tearing the sheet down) while it awaits the next event.
    let first = LockIsolated<DownloadEvent?>(nil)
    let consumer = Task {
      for try await event in stream {
        first.withValue { if $0 == nil { $0 = event } }
      }
    }
    await waitUntil({ first.value != nil }, "no progress event arrived")
    #expect(downloadFolders().count == 1, "the partial folder exists while the transfer is stalled")
    consumer.cancel()
    _ = try? await consumer.value

    #expect(first.value == .progress(Double(downloadChunkSize) / Double(1024 * 1024)))
    #expect(downloadFolders().isEmpty, "a cancelled consumer removes the partial directory")
  }

  // MARK: - removeTemp

  @Test func removeTempDeletesTheWholeDownloadDirectory() async throws {
    defer { removeScratch() }
    MockURLProtocol.set(status: 200, headers: ["Content-Length": "3"])
    MockURLProtocol.stub.body = Data("abc".utf8)
    let client = makeClient()
    let url = try #require(finishedURL(try await collect(client.download(connection, "/a/b.txt", nil, nil, "b.txt"))))
    #expect(FileManager.default.fileExists(atPath: url.path))

    await client.removeTemp(url)

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    #expect(downloadFolders().isEmpty)
    // The shared root survives for the next download.
    #expect(FileManager.default.fileExists(atPath: downloadsRoot.path))
  }

  @Test func removeTempOutsideTheDownloadsRootDeletesOnlyTheFile() async throws {
    defer { removeScratch() }
    let folder = scratch.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stray = folder.appendingPathComponent("x.txt")
    try Data("x".utf8).write(to: stray)

    await makeClient().removeTemp(stray)

    #expect(!FileManager.default.fileExists(atPath: stray.path))
    #expect(FileManager.default.fileExists(atPath: folder.path))
  }

  // MARK: - Dependency defaults

  @Test func unimplementedDownloadFailsLoudly() async throws {
    let client = FilePreviewClient.testValue
    // Only the CALL is the known issue (`@DependencyClient`'s "unimplemented" report); the
    // stream's failure is asserted outside it, so a wrong error can't pass as a second issue.
    var stream: AsyncThrowingStream<DownloadEvent, any Error>?
    withKnownIssue { stream = client.download(connection, "/a/b.txt", nil, nil, "b.txt") }
    let unimplemented = try #require(stream)
    await #expect(throws: RESTError.unreachable) { _ = try await collect(unimplemented) }
  }
}
} // extension RESTTransportSuite
