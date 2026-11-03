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

/// One step of a `FilePreviewClient.download`. `progress` carries the received fraction, or
/// nil when the server sent no `Content-Length` (the UI shows an indeterminate bar);
/// `finished` is the last event and names the temp file the bytes landed in.
public enum DownloadEvent: Equatable, Sendable {
  case progress(Double?)
  case finished(URL)
}

// MARK: - Client

/// The three `/api/fs/*` routes behind the file preview sheet. Same transport rules as every
/// other REST client (`makeURL` / `resolveAuth` / `validate` / `serverDetail` from
/// `HermesRESTClient.swift`): the auth header comes from `RequestAuth`, 404 → `.notFound`,
/// every other non-2xx → `.server(status:detail:)` with the server's `detail` verbatim — the
/// reducer maps 403 (protected file) and 413 (over the data-URL limit) off that.
///
/// Deliberately NO `*Supported` capability flip: the routes are mounted unconditionally on
/// current agents, and on an older one the generic "not found" card already IS the degraded
/// state (see `docs/features/file-preview.md`).
///
/// `sessionID` is forwarded as `session_id` so a relative path resolves against the session
/// cwd and `/workspace/...` sandbox paths map to the host; nil omits the parameter.
@DependencyClient
public struct FilePreviewClient: Sendable {
  /// `GET /api/fs/read-text?path=&session_id=`.
  public var readText: @Sendable (_ connection: ServerConnection, _ path: String, _ sessionID: String?) async throws -> FileTextRead
  /// `GET /api/fs/read-data-url?path=&session_id=`; a `dataUrl` that `DataURL.parse` rejects
  /// surfaces as `RESTError.decoding`.
  public var readData: @Sendable (_ connection: ServerConnection, _ path: String, _ sessionID: String?) async throws -> FileDataRead
  /// `GET /api/fs/download?path=&session_id=` streamed into
  /// `<temporaryDirectory>/hermes-file-preview/<UUID>/<fileName>` — the per-download directory
  /// is what lets the file keep its REAL name for the share sheet. Yields `.progress` at ≥64 KB
  /// granularity, then `.finished(url)`. Cancelling the consumer, or any failure, removes the
  /// partial `<UUID>` directory. A non-throwing endpoint needs a default: this one ends the
  /// stream with `RESTError.unreachable`, and `@DependencyClient` still reports the
  /// "unimplemented" issue around it, so a reducer test that forgot to stub it fails loudly.
  public var download: @Sendable (_ connection: ServerConnection, _ path: String, _ sessionID: String?, _ fileName: String) -> AsyncThrowingStream<DownloadEvent, any Error> = { _, _, _, _ in
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
      readText: { conn, path, sessionID in
        let url = try makeURL(conn.baseURL, "/api/fs/read-text", query: fsQuery(path: path, sessionID: sessionID))
        return try await get(url, auth: authFor(conn), session: session)
      },
      readData: { conn, path, sessionID in
        let url = try makeURL(conn.baseURL, "/api/fs/read-data-url", query: fsQuery(path: path, sessionID: sessionID))
        let response: DataURLResponse = try await get(url, auth: authFor(conn), session: session)
        guard let parsed = DataURL.parse(response.dataUrl) else { throw RESTError.decoding }
        return FileDataRead(mimeType: parsed.mimeType, data: parsed.data)
      },
      download: { conn, path, sessionID, fileName in
        downloadStream(
          conn, path: path, sessionID: sessionID, fileName: fileName,
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

/// `path` always; `session_id` only when the caller has one (omitted ≠ empty string).
private func fsQuery(path: String, sessionID: String?) -> [URLQueryItem] {
  var items = [URLQueryItem(name: "path", value: path)]
  if let sessionID { items.append(.init(name: "session_id", value: sessionID)) }
  return items
}

private struct DataURLResponse: Decodable {
  let dataUrl: String
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
  _ conn: ServerConnection, path: String, sessionID: String?, fileName: String,
  root: URL,
  authFor: @escaping @Sendable (ServerConnection) async throws -> RequestAuth,
  session: URLSession
) -> AsyncThrowingStream<DownloadEvent, any Error> {
  let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
  return AsyncThrowingStream { continuation in
    let producer = Task {
      do {
        let url = try makeURL(conn.baseURL, "/api/fs/download", query: fsQuery(path: path, sessionID: sessionID))
        var request = URLRequest(url: url)
        try await authFor(conn).apply(to: &request)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
          (bytes, response) = try await session.bytes(for: request)
        } catch {
          throw RESTError(transport: error)
        }
        guard let http = response as? HTTPURLResponse else { throw RESTError.unreachable }
        if !(200..<300).contains(http.statusCode) {
          // Collect (a bounded slice of) the error body so `validate` can surface `detail`.
          var body = Data()
          do {
            for try await byte in bytes {
              body.append(byte)
              if body.count >= downloadChunkSize { break }
            }
          } catch let error as CancellationError {
            throw error
          } catch {
            throw RESTError(transport: error)
          }
          try validate(response, data: body)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(fileName)
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
          throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        let expected = expectedLength(of: http)
        var buffer = Data(capacity: downloadChunkSize)
        var received = 0
        do {
          for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= downloadChunkSize {
              try Task.checkCancellation()
              try handle.write(contentsOf: buffer)
              received += buffer.count
              buffer.removeAll(keepingCapacity: true)
              continuation.yield(.progress(fraction(received, of: expected)))
            }
          }
        } catch let error as CancellationError {
          throw error
        } catch {
          throw RESTError(transport: error)
        }
        if !buffer.isEmpty {
          try handle.write(contentsOf: buffer)
          received += buffer.count
        }
        try handle.close()
        try Task.checkCancellation()
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

/// `Content-Length` as announced by the server, or nil when absent/unparseable.
private func expectedLength(of response: HTTPURLResponse) -> Int? {
  if let header = response.value(forHTTPHeaderField: "Content-Length"),
     let length = Int(header.trimmingCharacters(in: .whitespaces)), length >= 0 {
    return length
  }
  return response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil
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
