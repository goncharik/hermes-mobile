import ComposableArchitecture
import DependenciesMacros
import Foundation

// MARK: - DTOs

/// `GET /api/fs/read-text` — the first 512 KB of a file plus the server's text-vs-binary
/// verdict (null bytes / control-character ratio, decided server-side so the client carries no
/// MIME table). Decoded leniently: only the verdict flags and `text` matter, and an absent flag
/// reads as `false` rather than failing the whole preview.
public struct FileTextRead: Decodable, Equatable, Sendable {
  /// `true` → the bytes are not text; the preview shows the generic card instead.
  public var binary: Bool
  public var byteSize: Int?
  /// Server-guessed syntax name (`swift`, `json`, …) for the caption row; nil when unknown.
  public var language: String?
  public var mimeType: String?
  public var text: String
  /// `true` when the server stopped at its 512 KB read limit.
  public var truncated: Bool

  public init(
    binary: Bool = false,
    byteSize: Int? = nil,
    language: String? = nil,
    mimeType: String? = nil,
    text: String = "",
    truncated: Bool = false
  ) {
    self.binary = binary
    self.byteSize = byteSize
    self.language = language
    self.mimeType = mimeType
    self.text = text
    self.truncated = truncated
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
    byteSize = try c.decodeIfPresent(Int.self, forKey: .byteSize)
    language = try c.decodeIfPresent(String.self, forKey: .language)
    mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
    text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
  }

  private enum CodingKeys: String, CodingKey {
    case binary, byteSize, language, mimeType, text, truncated
  }
}

/// `GET /api/fs/read-data-url` — the whole file (≤ 16 MB; 413 above) decoded out of its
/// `dataUrl` by `DataURL.parse`.
public struct FileDataRead: Equatable, Sendable {
  public var mimeType: String?
  public var data: Data

  public init(mimeType: String?, data: Data) {
    self.mimeType = mimeType
    self.data = data
  }
}

/// The raw `GET /api/fs/read-data-url` body; `readData` decodes its `dataUrl` into a
/// `FileDataRead`.
private struct DataURLResponse: Decodable {
  let dataUrl: String
}

/// One step of a `FilePreviewClient.download`. `progress` carries the received fraction, or
/// nil when the server sent no `Content-Length` (the UI shows an indeterminate bar);
/// `finished` is the last event and names the temp file the bytes landed in.
public enum DownloadEvent: Equatable, Sendable {
  case progress(Double?)
  case finished(URL)
}

// MARK: - Client

/// The three `/api/fs/*` routes behind the file preview sheet. Same transport rules as every
/// other REST client (`resolveAuth` / `serverDetail` from `HermesRESTClient.swift`): the auth
/// header comes from `RequestAuth`, every non-2xx → `.server(status:detail:)` with the
/// server's `detail` verbatim — INCLUDING 404 (`validateFS`), because the fs routes' 404 detail
/// is the sandbox hint the card shows; the reducer maps 404 / 403 (protected file) / 413 (over
/// a size limit) off that.
///
/// Deliberately NO `*Supported` capability flip: the routes are mounted unconditionally on
/// current agents, and on an older one the generic "not found" card already IS the degraded
/// state (see `docs/features/file-preview.md`).
///
/// `sessionID` is forwarded as `session_id` so a relative path resolves against the session
/// cwd and `/workspace/...` sandbox paths map to the host; `profile` as `profile`, the DB the
/// server looks that session up in (the multi-profile rule: omitted = the server's launch
/// profile, so a chat in any other profile 404s without it). nil omits either parameter.
@DependencyClient
public struct FilePreviewClient: Sendable {
  /// `GET /api/fs/read-text?path=&session_id=&profile=`.
  public var readText: @Sendable (_ connection: ServerConnection, _ path: String, _ sessionID: String?, _ profile: String?) async throws -> FileTextRead
  /// `GET /api/fs/read-data-url?path=&session_id=&profile=`; a `dataUrl` that `DataURL.parse`
  /// rejects surfaces as `RESTError.decoding`.
  public var readData: @Sendable (_ connection: ServerConnection, _ path: String, _ sessionID: String?, _ profile: String?) async throws -> FileDataRead
  /// `GET /api/fs/download?path=&session_id=&profile=` streamed into
  /// `<temporaryDirectory>/hermes-file-preview/<UUID>/<fileName>` — the per-download directory
  /// is what lets the file keep its REAL name for the share sheet. Yields `.progress` at ≥64 KB
  /// granularity, then `.finished(url)`. Cancelling the consumer, or any failure, removes the
  /// partial `<UUID>` directory. A non-throwing endpoint needs a default: this one ends the
  /// stream with `RESTError.unreachable`, and `@DependencyClient` still reports the
  /// "unimplemented" issue around it, so a reducer test that forgot to stub it fails loudly.
  public var download: @Sendable (_ connection: ServerConnection, _ path: String, _ sessionID: String?, _ profile: String?, _ fileName: String) -> AsyncThrowingStream<DownloadEvent, any Error> = { _, _, _, _, _ in
    AsyncThrowingStream { $0.finish(throwing: RESTError.unreachable) }
  }
  /// Delete a finished download: removes the file's parent `<UUID>` directory (the whole
  /// per-download folder), never anything above it. Best-effort — nothing can act on a failed
  /// delete of a temp file.
  public var removeTemp: @Sendable (_ url: URL) async -> Void = { _ in }
}

public extension FilePreviewClient {
  /// Live implementation over `URLSession`. The session and token store are injectable like
  /// `HermesRESTClient.live`; `temporaryDirectory` is the root the per-download folders go
  /// under (tests point it at their own scratch directory).
  static func live(
    session: URLSession = .shared,
    tokenStore: BearerTokenStore = .shared,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) -> FilePreviewClient {
    let authFor: @Sendable (ServerConnection) async throws -> RequestAuth = { conn in
      try await resolveAuth(for: conn, session: session, tokenStore: tokenStore)
    }
    let downloadsRoot = temporaryDirectory
      .appendingPathComponent(downloadsDirectoryName, isDirectory: true)
    return FilePreviewClient(
      readText: { conn, path, sessionID, profile in
        let url = try fsURL(conn.baseURL, "/api/fs/read-text", path: path, sessionID: sessionID, profile: profile)
        return try await fsGet(url, auth: authFor(conn), session: session)
      },
      readData: { conn, path, sessionID, profile in
        let url = try fsURL(conn.baseURL, "/api/fs/read-data-url", path: path, sessionID: sessionID, profile: profile)
        let response: DataURLResponse = try await fsGet(url, auth: authFor(conn), session: session)
        guard let parsed = DataURL.parse(response.dataUrl) else { throw RESTError.decoding }
        return FileDataRead(mimeType: parsed.mimeType, data: parsed.data)
      },
      download: { conn, path, sessionID, profile, fileName in
        downloadStream(
          conn, path: path, sessionID: sessionID, profile: profile, fileName: fileName,
          root: downloadsRoot, authFor: authFor, session: session
        )
      },
      removeTemp: { url in
        removeDownload(at: url)
      }
    )
  }
}

extension FilePreviewClient: DependencyKey {
  public static var liveValue: FilePreviewClient { .live() }
  /// Every endpoint unimplemented: a reducer test that reaches one it didn't stub fails.
  public static var testValue: FilePreviewClient { FilePreviewClient() }
}

public extension DependencyValues {
  var filePreview: FilePreviewClient {
    get { self[FilePreviewClient.self] }
    set { self[FilePreviewClient.self] = newValue }
  }
}

// MARK: - Live helpers

/// The folder under the temporary directory every per-download `<UUID>` folder lives in.
/// `removeDownload` only ever deletes a directory whose parent is named this.
let downloadsDirectoryName = "hermes-file-preview"

/// Bytes written to disk (and reported) at a time while streaming a download.
let downloadChunkSize = 64 * 1024

/// The fs route URL: `path` always; `session_id` and `profile` only when the caller has one
/// (omitted ≠ empty string). Values are percent-encoded by hand against the same unreserved
/// set `FileReference.url(for:)` uses: `URLComponents.queryItems` leaves `+` bare, which the
/// server's form decoding reads as a space, and the scanner deliberately links `+` paths.
private func fsURL(_ base: URL, _ route: String, path: String, sessionID: String?, profile: String?) throws -> URL {
  var items = [("path", path)]
  if let sessionID { items.append(("session_id", sessionID)) }
  if let profile { items.append(("profile", profile)) }
  guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
    throw RESTError.unreachable
  }
  comps.path = route
  comps.percentEncodedQueryItems = items.map { name, value in
    URLQueryItem(name: name, value: value.addingPercentEncoding(withAllowedCharacters: .fileReferenceUnreserved))
  }
  guard let url = comps.url else { throw RESTError.unreachable }
  return url
}

/// `get` for the fs routes: the shared `validate` types a 404 as a detail-less `.notFound`,
/// but here the 404 body carries the sandbox hint the card shows, so every non-2xx — 404
/// included — is `.server(status:detail:)`. 401 keeps its typed verdict.
private func validateFS(_ response: URLResponse, data: Data) throws {
  guard let http = response as? HTTPURLResponse else { throw RESTError.unreachable }
  if http.statusCode == 404 {
    throw RESTError.server(status: 404, detail: serverDetail(from: data))
  }
  try validate(response, data: data)
}

private func fsGet<T: Decodable>(_ url: URL, auth: RequestAuth, session: URLSession) async throws -> T {
  var request = URLRequest(url: url)
  auth.apply(to: &request)
  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw RESTError(transport: error)
  }
  try validateFS(response, data: data)
  do {
    return try JSONDecoder().decode(T.self, from: data)
  } catch {
    throw RESTError.decoding
  }
}

/// Stream `GET /api/fs/download` into `<root>/<UUID>/<fileName>`.
///
/// Lifecycle: the per-download directory is created only after the response status has been
/// validated (a 404/403 never leaves a folder behind). Any failure in the producer removes
/// the directory before the stream fails. A consumer that stops iterating early — the
/// reducer's `.cancelDownload`, or `.ifLet` tearing the sheet down — terminates the stream
/// with `.cancelled`, which cancels the producer AND removes the directory right there, so
/// the cleanup is not racing a producer that may still be writing.
private func downloadStream(
  _ conn: ServerConnection, path: String, sessionID: String?, profile: String?, fileName: String,
  root: URL,
  authFor: @escaping @Sendable (ServerConnection) async throws -> RequestAuth,
  session: URLSession
) -> AsyncThrowingStream<DownloadEvent, any Error> {
  let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
  return AsyncThrowingStream { continuation in
    let producer = Task {
      do {
        let url = try fsURL(conn.baseURL, "/api/fs/download", path: path, sessionID: sessionID, profile: profile)
        let (bytes, http) = try await openDownload(url, auth: authFor(conn), session: session)
        if !(200..<300).contains(http.statusCode) {
          try validateFS(http, data: try await errorBody(from: bytes))
        }
        let fileURL = try createDownloadFile(in: directory, named: fileName)
        let expected = expectedLength(of: http)
        try await writeDownload(bytes, to: fileURL) { received in
          continuation.yield(.progress(fraction(received, of: expected)))
        }
        // The final progress reports 1.0 when a length was announced (even if the server
        // undershot it) so a determinate bar always lands full before the share sheet opens.
        continuation.yield(.progress(expected == nil ? nil : 1.0))
        continuation.yield(.finished(fileURL))
        continuation.finish()
      } catch {
        try? FileManager.default.removeItem(at: directory)
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { reason in
      producer.cancel()
      if case .cancelled = reason {
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }
}

/// Open the download response as a byte stream; a transport failure is typed `RESTError`.
private func openDownload(
  _ url: URL, auth: RequestAuth, session: URLSession
) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
  var request = URLRequest(url: url)
  auth.apply(to: &request)
  let bytes: URLSession.AsyncBytes
  let response: URLResponse
  do {
    (bytes, response) = try await session.bytes(for: request)
  } catch {
    throw RESTError(transport: error)
  }
  guard let http = response as? HTTPURLResponse else { throw RESTError.unreachable }
  return (bytes, http)
}

/// A bounded slice (one chunk) of a non-2xx body, enough for `validateFS` to surface `detail`.
private func errorBody(from bytes: URLSession.AsyncBytes) async throws -> Data {
  try await mappingTransportErrors {
    var body = Data()
    for try await byte in bytes {
      body.append(byte)
      if body.count >= downloadChunkSize { break }
    }
    return body
  }
}

/// Create `<directory>/<fileName>` empty (and the directory itself) for `writeDownload`.
private func createDownloadFile(in directory: URL, named fileName: String) throws -> URL {
  let fileManager = FileManager.default
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  let fileURL = directory.appendingPathComponent(fileName)
  guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
    throw CocoaError(.fileWriteUnknown)
  }
  return fileURL
}

/// Stream `bytes` into `fileURL` in `downloadChunkSize` writes, reporting the running byte
/// count after each full chunk; the trailing partial chunk is written without a report.
/// Only the network read is typed as a transport failure: a local write error (`FileHandle`,
/// disk full) keeps its own error so the strip does not blame the connection.
private func writeDownload(
  _ bytes: URLSession.AsyncBytes, to fileURL: URL, onChunk: (Int) -> Void
) async throws {
  let handle = try FileHandle(forWritingTo: fileURL)
  defer { try? handle.close() }
  var iterator = bytes.makeAsyncIterator()
  var buffer = Data(capacity: downloadChunkSize)
  var received = 0
  while try await mappingTransportErrors({ try await readChunk(into: &buffer, from: &iterator) }) {
    try Task.checkCancellation()
    try handle.write(contentsOf: buffer)
    received += buffer.count
    buffer.removeAll(keepingCapacity: true)
    onChunk(received)
  }
  if !buffer.isEmpty {
    try handle.write(contentsOf: buffer)
  }
  try handle.close()
  try Task.checkCancellation()
}

/// Append bytes to `buffer` until it holds one full chunk (true) or the stream ends (false,
/// with the partial tail left in `buffer`).
private func readChunk(
  into buffer: inout Data, from iterator: inout URLSession.AsyncBytes.Iterator
) async throws -> Bool {
  while buffer.count < downloadChunkSize {
    guard let byte = try await iterator.next() else { return false }
    buffer.append(byte)
  }
  return true
}

/// Run a byte-stream read: a `CancellationError` (the consumer went away) passes through,
/// every other failure is typed as a transport `RESTError`.
private func mappingTransportErrors<T>(_ read: () async throws -> T) async throws -> T {
  do {
    return try await read()
  } catch let error as CancellationError {
    throw error
  } catch {
    throw RESTError(transport: error)
  }
}

/// The byte count the transport expects to deliver (`Content-Length`, as URLSession reads
/// it — unknown under a content encoding it decodes on the fly), or nil when absent.
private func expectedLength(of response: HTTPURLResponse) -> Int? {
  response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil
}

private func fraction(_ received: Int, of expected: Int?) -> Double? {
  guard let expected, expected > 0 else { return nil }
  return min(1, Double(received) / Double(expected))
}

/// Remove a finished download's whole `<UUID>` folder — but ONLY when it really is one of ours
/// (its parent is the `hermes-file-preview` root); any other URL loses just the file itself,
/// never a directory the caller did not mean to hand us.
private func removeDownload(at url: URL) {
  let folder = url.deletingLastPathComponent()
  let target = folder.deletingLastPathComponent().lastPathComponent == downloadsDirectoryName
    ? folder : url
  try? FileManager.default.removeItem(at: target)
}
