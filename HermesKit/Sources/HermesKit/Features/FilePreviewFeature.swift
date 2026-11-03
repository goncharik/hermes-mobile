import ComposableArchitecture
import Foundation

/// The file preview sheet raised when a `hermes-file:` link in the transcript is tapped
/// (`ChatFeature.fileReferenceTapped` → `@Presents filePreview`). Owns loading over
/// `FilePreviewClient`, the text/image/pdf/generic resolution, the Share download and the
/// Copy-path toast. Platform-free on purpose: whether the bytes in `.image` actually decode
/// is the VIEW's call (`UIImage(data:) == nil` → generic card), never the reducer's.
///
/// Load rule: only images and PDFs are chosen by extension (they need the data-URL route);
/// everything else asks `read-text` and lets the server's `binary` verdict pick the text view
/// or the generic card — no client MIME table. Nothing is swallowed: every failure lands in
/// `content` as a reasoned generic card or `.failed` with Retry.
///
/// Lifecycle: the sheet is an `.ifLet` child, so dismissing it auto-cancels an in-flight read
/// or a multi-megabyte download. The downloaded temp file outlives the share sheet (a second
/// Share is instant) but not the preview — `ChatFeature` reads `downloadedURL` on dismiss and
/// calls `removeTemp`, and `AppFeature` does the same when it drops the whole chat slot.
@Reducer
public struct FilePreviewFeature {
  @ObservableState
  public struct State: Equatable {
    /// The host path as it appeared in the transcript (the `read-text` / `read-data-url`
    /// `path` parameter and what Copy path puts on the pasteboard).
    public var path: String
    /// Last path component — the sheet title and the share sheet's file name.
    public var fileName: String { FilePreviewKind.displayName(for: path) }
    public var kind: FilePreviewKind { FilePreviewKind.infer(path: path) }
    /// `session_id` for the fs routes — the STORED id only (`ChatFeature.storedSessionID`:
    /// the server resolves stored ids, never the live handle), so relative and
    /// `/workspace/...` sandbox paths resolve against the session; nil omits it. Whether the
    /// id has a DB row yet is the SERVER's call (a fresh draft's row is lazy, a seeded branch's
    /// is not, and that rule has moved between agent versions): its "Session not found" 404
    /// makes the effect retry once without the id (`isSessionNotFound`).
    public var sessionID: String?
    /// `profile` for the fs routes (`ChatFeature.profileName`): the DB the server looks
    /// `sessionID` up in. nil omits it (= the server's launch profile).
    public var profile: String?
    public var connection: ServerConnection
    public var content: Content
    public var share: ShareState
    /// A failed Share download, shown as a banner in the sheet; cleared on the next Share.
    public var shareError: String?
    /// Bumped on every Copy path (never a `Bool` — a re-copy inside the dwell must restart
    /// the toast); nil once the dwell elapses.
    public var copiedToken: Int?
    /// The finished download, kept across `.shareDismissed` so a second Share is instant.
    /// `ChatFeature` removes it when the preview is dismissed.
    public var downloadedURL: URL?

    public init(
      path: String,
      sessionID: String?,
      profile: String?,
      connection: ServerConnection,
      content: Content = .loading,
      share: ShareState = .idle,
      shareError: String? = nil,
      copiedToken: Int? = nil,
      downloadedURL: URL? = nil
    ) {
      self.path = path
      self.sessionID = sessionID
      self.profile = profile
      self.connection = connection
      self.content = content
      self.share = share
      self.shareError = shareError
      self.copiedToken = copiedToken
      self.downloadedURL = downloadedURL
    }
  }

  /// What the sheet body renders.
  public enum Content: Equatable, Sendable {
    case loading
    case text(FileTextRead)
    /// Raw bytes — the view decodes them and falls back to the generic card when it can't.
    case image(Data)
    case pdf(Data)
    case generic(GenericInfo)
    /// A transport or unexpected server failure, with Retry.
    case failed(message: String)
  }

  /// Why the generic card is shown instead of a preview.
  public enum Reason: Equatable, Sendable {
    /// The server called the bytes binary (or an image/PDF route returned something the view
    /// cannot decode).
    case unsupported
    /// 413 from either read route (`read-data-url` above 16 MB, `read-text` above 64 MB of
    /// source). Share still works (the download route has no cap).
    case tooLarge
    /// 404 — missing on the host (the detail may say the path lives only inside the sandbox).
    case notFound
    /// 403 — a sensitive file the server refuses to serve (`.env*`, credentials, config).
    case protected
  }

  public struct GenericInfo: Equatable, Sendable {
    public var reason: Reason
    public var byteSize: Int?
    /// The server's `detail` verbatim, when it sent one.
    public var serverDetail: String?

    public init(reason: Reason, byteSize: Int? = nil, serverDetail: String? = nil) {
      self.reason = reason
      self.byteSize = byteSize
      self.serverDetail = serverDetail
    }
  }

  public enum ShareState: Equatable, Sendable {
    case idle
    /// `fraction` is nil while the server has announced no `Content-Length` (indeterminate bar).
    case downloading(fraction: Double?)
    /// The temp file is on disk; the view presents the system share sheet for it.
    case ready(URL)
  }

  /// The successful outcome of a load, by route.
  public enum Loaded: Equatable, Sendable {
    case text(FileTextRead)
    case data(FileDataRead)
  }

  public enum Action: Equatable {
    /// The sheet appeared. Loads only while `content` is still `.loading`, so a re-appearance
    /// never throws away a loaded preview; `retry` is the explicit reload.
    case task
    case retry
    case loaded(Result<Loaded, RESTError>)
    case copyPath
    case copiedFeedbackElapsed
    case shareTapped
    case cancelDownload
    case downloadEvent(DownloadEvent)
    case downloadFailed(String)
    /// The system share sheet was dismissed (shared or not). The temp file stays.
    case shareDismissed
  }

  private enum CancelID: Hashable {
    case load, download, copyFeedback
  }

  /// How long the "Path copied" toast stays up — duplicated per feature (the toast idiom) rather
  /// than shared, so a chat tweak can't silently restyle the sheet.
  static let copiedFeedbackDuration: Duration = .seconds(1.5)

  @Dependency(\.filePreview) var filePreview
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.continuousClock) var clock

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        guard case .loading = state.content else { return .none }
        return load(state)

      case .retry:
        state.content = .loading
        return load(state)

      case let .loaded(.success(.text(read))):
        // The server decided: binary bytes get the generic card with the size it reported.
        state.content = read.binary
          ? .generic(GenericInfo(reason: .unsupported, byteSize: read.byteSize))
          : .text(read)
        return .none

      case let .loaded(.success(.data(read))):
        switch state.kind {
        case .image: state.content = .image(read.data)
        case .pdf: state.content = .pdf(read.data)
        // Only image/pdf ever take the data route; anything else landing here has no renderer.
        case .other: state.content = .generic(GenericInfo(reason: .unsupported, byteSize: read.data.count))
        }
        return .none

      case let .loaded(.failure(error)):
        state.content = Self.content(for: error)
        return .none

      case .copyPath:
        state.copiedToken = (state.copiedToken ?? 0) + 1
        let path = state.path
        return .merge(
          .run { [pasteboard] _ in pasteboard.copy(path) },
          .run { [clock] send in
            try await clock.sleep(for: Self.copiedFeedbackDuration)
            await send(.copiedFeedbackElapsed)
          }
          .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
        )

      case .copiedFeedbackElapsed:
        state.copiedToken = nil
        return .none

      case .shareTapped:
        // One download at a time, and nothing to do while the share sheet is already up.
        guard case .idle = state.share else { return .none }
        state.shareError = nil
        // A finished download survives `.shareDismissed`: re-present it without a round-trip.
        if let url = state.downloadedURL {
          state.share = .ready(url)
          return .none
        }
        state.share = .downloading(fraction: nil)
        let connection = state.connection
        let path = state.path
        let sessionID = state.sessionID
        let profile = state.profile
        let fileName = state.fileName
        return .run { [filePreview] send in
          @Sendable func consume(_ sessionID: String?) async throws {
            for try await event in filePreview.download(connection, path, sessionID, profile, fileName) {
              await send(.downloadEvent(event))
              // The stream buffers `.finished` ahead of the consumer; a cancel landing in that
              // gap (`.cancelDownload`, the sheet or the slot going away) is too late for the
              // client's `onTermination` cleanup and too early for the reducer — a cancelled
              // effect's `send` is dropped — so nothing would ever record or remove the file.
              if case let .finished(url) = event, Task.isCancelled {
                await filePreview.removeTemp(url)
              }
            }
          }
          do {
            do {
              try await consume(sessionID)
            } catch where sessionID != nil && Self.isSessionNotFound(error) {
              // The status is validated before the first event, so nothing was yielded yet.
              try await consume(nil)
            }
          } catch {
            // A cancelled consumer ends the stream quietly; only a real failure is reported.
            guard !Task.isCancelled else { return }
            await send(.downloadFailed(Self.downloadFailureMessage(error)))
          }
        }
        .cancellable(id: CancelID.download, cancelInFlight: true)

      case let .downloadEvent(.progress(fraction)):
        // Only a download in flight owns these events: a cancelled effect's late event (the
        // belt — the effect's own cancellation already drops them) must neither resurrect
        // the bar nor pop the share sheet.
        guard case .downloading = state.share else { return .none }
        state.share = .downloading(fraction: fraction)
        return .none

      case let .downloadEvent(.finished(url)):
        guard case .downloading = state.share else { return .none }
        state.downloadedURL = url
        state.share = .ready(url)
        return .none

      case let .downloadFailed(message):
        state.share = .idle
        state.shareError = message
        return .none

      case .cancelDownload:
        guard case .downloading = state.share else { return .none }
        state.share = .idle
        return .cancel(id: CancelID.download)

      case .shareDismissed:
        // One dismissal per presentation: the activity controller's completion and the
        // sheet binding's nil-set can both fire for the same dismissal, and a stale second
        // must not reset a Share the user has since restarted.
        guard case .ready = state.share else { return .none }
        state.share = .idle
        return .none
      }
    }
  }

  /// The load effect for the current kind: images and PDFs take the data-URL route,
  /// everything else `read-text`. A "Session not found" 404 against a `sessionID` is retried
  /// ONCE without it (the #17 single-retry shape — no loop); any other error is normalised to
  /// `RESTError` and folded by `.loaded(.failure)`.
  private func load(_ state: State) -> Effect<Action> {
    let connection = state.connection
    let path = state.path
    let sessionID = state.sessionID
    let profile = state.profile
    let kind = state.kind
    return .run { [filePreview] send in
      @Sendable func read(_ sessionID: String?) async throws -> Loaded {
        switch kind {
        case .image, .pdf: .data(try await filePreview.readData(connection, path, sessionID, profile))
        case .other: .text(try await filePreview.readText(connection, path, sessionID, profile))
        }
      }
      do {
        do {
          await send(.loaded(.success(try await read(sessionID))))
        } catch where sessionID != nil && Self.isSessionNotFound(error) {
          await send(.loaded(.success(try await read(nil))))
        }
      } catch {
        await send(.loaded(.failure(asRESTError(error))))
      }
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }

  /// The sessions router's 404 `detail` for an id the profile's DB holds no row for
  /// (`_NOT_FOUND` in `hermes_cli/web_routers/sessions.py`, raised by `_fs_owned_session`
  /// before the path is even looked at). Matched exactly: every other 404 — "File not found",
  /// the sandbox hint — is a verdict about the FILE and lands on the not-found card unretried.
  static let sessionNotFoundDetail = "Session not found"

  static func isSessionNotFound(_ error: any Error) -> Bool {
    guard case .server(status: 404, detail: let detail?) = error as? RESTError else { return false }
    return detail.trimmingCharacters(in: .whitespacesAndNewlines) == sessionNotFoundDetail
  }

  /// The Share strip's message for a failed download. A typed `RESTError` or a raw transport
  /// `URLError` reads as its REST message; a local failure — the temp file could not be written
  /// (`FileHandle`, disk full) — keeps its own description rather than blaming the connection.
  static func downloadFailureMessage(_ error: any Error) -> String {
    switch error {
    case let rest as RESTError: rest.message
    case let transport as URLError: RESTError(transport: transport).message
    default: error.localizedDescription
    }
  }

  /// Error → content mapping, identical for both routes. 404 / 403 / 413 are expected
  /// verdicts and get a reasoned generic card; anything else is a failure with Retry.
  /// `FilePreviewClient` surfaces a 404 as `.server(404, detail)` so the server's sandbox hint
  /// reaches the card; the typed `.notFound` is still accepted (detail-less card).
  static func content(for error: RESTError) -> Content {
    switch error {
    case .notFound:
      return .generic(GenericInfo(reason: .notFound))
    case let .server(status, detail):
      switch status {
      case 404: return .generic(GenericInfo(reason: .notFound, serverDetail: detail))
      case 403: return .generic(GenericInfo(reason: .protected, serverDetail: detail))
      case 413: return .generic(GenericInfo(reason: .tooLarge, serverDetail: detail))
      default: return .failed(message: error.message)
      }
    default:
      return .failed(message: error.message)
    }
  }
}
