import Clocks
import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// `FilePreviewFeature` over stubbed `FilePreviewClient` endpoints: one test per content
/// outcome, the Share download lifecycle, and the Copy-path toast. Every endpoint the test
/// does not stub stays unimplemented, so a load that reaches the wrong route fails loudly.
@MainActor
struct FilePreviewFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  private func makeStore(
    path: String,
    sessionID: String? = "sess-1",
    profile: String? = "work",
    configure: @escaping (inout DependencyValues) -> Void = { _ in }
  ) -> TestStoreOf<FilePreviewFeature> {
    TestStore(
      initialState: FilePreviewFeature.State(path: path, sessionID: sessionID, profile: profile, connection: connection),
      reducer: { FilePreviewFeature() },
      withDependencies: configure
    )
  }

  private func state(path: String, sessionID: String? = "sess-1", profile: String? = "work") -> FilePreviewFeature.State {
    FilePreviewFeature.State(path: path, sessionID: sessionID, profile: profile, connection: connection)
  }

  private var tinyPNG: Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }

  // MARK: - State seeding

  @Test func initDerivesFileNameAndKindFromThePath() {
    let image = state(path: "/home/e/out/shot.PNG", sessionID: nil, profile: nil)
    #expect(image.fileName == "shot.PNG")
    #expect(image.kind == .image)
    #expect(image.content == .loading)
    #expect(image.share == .idle)

    let other = state(path: "~/Downloads/notes.md", sessionID: "s")
    #expect(other.fileName == "notes.md")
    #expect(other.kind == .other)
    #expect(other.profile == "work")
  }

  // MARK: - Loading by kind

  @Test func imageLoadsThroughTheDataRouteWithPathSessionAndProfile() async {
    let seen = LockIsolated<(path: String, session: String?, profile: String?)?>(nil)
    let png = tinyPNG
    let store = makeStore(path: "/home/e/out/shot.png") {
      $0.filePreview.readData = { @Sendable _, path, session, profile in
        seen.setValue((path, session, profile))
        return FileDataRead(mimeType: "image/png", data: png)
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.success) { $0.content = .image(png) }
    #expect(seen.value?.path == "/home/e/out/shot.png")
    #expect(seen.value?.session == "sess-1")
    #expect(seen.value?.profile == "work")
  }

  @Test func pdfLoadsThroughTheDataRoute() async {
    let bytes = Data("%PDF-1.4".utf8)
    let store = makeStore(path: "/home/e/out/report.pdf", sessionID: nil, profile: nil) {
      $0.filePreview.readData = { @Sendable _, _, session, profile in
        #expect(session == nil, "a nil session key is forwarded as nil, not an empty string")
        #expect(profile == nil, "a nil profile is forwarded as nil (omitted), not an empty string")
        return FileDataRead(mimeType: "application/pdf", data: bytes)
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.success) { $0.content = .pdf(bytes) }
  }

  @Test func textLoadsThroughReadTextAndKeepsTheTruncatedFlag() async {
    let read = FileTextRead(binary: false, byteSize: 900_000, language: "swift", mimeType: "text/x-swift", text: "let x = 1", truncated: true)
    let store = makeStore(path: "/home/e/src/App.swift") {
      $0.filePreview.readText = { @Sendable _, _, _, _ in read }
    }

    await store.send(.task)
    await store.receive(\.loaded.success) { $0.content = .text(read) }
  }

  @Test func binaryVerdictShowsTheGenericCardWithByteSize() async {
    let read = FileTextRead(binary: true, byteSize: 4096, mimeType: "application/octet-stream", text: "")
    let store = makeStore(path: "/home/e/out/archive.zip") {
      $0.filePreview.readText = { @Sendable _, _, _, _ in read }
    }

    await store.send(.task)
    await store.receive(\.loaded.success) {
      $0.content = .generic(.init(reason: .unsupported, byteSize: 4096))
    }
  }

  @Test func dataRouteBytesForAnOtherKindFallBackToTheGenericCard() async {
    // Only image/pdf take the data route, so this fold is reachable by action alone; it must
    // still land somewhere sensible — the generic card with the byte count it has.
    let store = makeStore(path: "/home/e/out/archive.zip")
    await store.send(.loaded(.success(.data(FileDataRead(mimeType: nil, data: Data(count: 12)))))) {
      $0.content = .generic(.init(reason: .unsupported, byteSize: 12))
    }
  }

  @Test func taskIsIdempotentOnceContentIsLoaded() async {
    // A re-appearance of the sheet must not throw a loaded preview away; no endpoint is
    // stubbed, so hitting one would fail the test.
    var initial = state(path: "/a/b.txt", sessionID: nil)
    initial.content = .text(FileTextRead(text: "hi"))
    let store = TestStore(initialState: initial) { FilePreviewFeature() }
    await store.send(.task)
  }

  // MARK: - Error mapping

  @Test func notFoundShowsTheNotFoundCard() async {
    let store = makeStore(path: "/home/e/out/missing.txt") {
      $0.filePreview.readText = { @Sendable _, _, _, _ in throw RESTError.notFound }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .notFound))
    }
  }

  @Test func notFoundWithServerDetailKeepsTheDetail() async {
    // The fs client surfaces a 404 as `.server(404, detail)`: the sandbox hint reaches the card.
    let store = makeStore(path: "/workspace/out/missing.png") {
      $0.filePreview.readData = { @Sendable _, _, _, _ in
        throw RESTError.server(status: 404, detail: "File exists only inside the sandbox")
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .notFound, serverDetail: "File exists only inside the sandbox"))
    }
  }

  // MARK: - "Session not found" single retry

  private var sessionNotFound: RESTError { .server(status: 404, detail: "Session not found") }

  @Test func sessionNotFoundOnLoadRetriesOnceWithoutTheSessionID() async {
    // The server has no row for the stored id yet (a fresh draft; a seeded branch on an older
    // agent): the verdict comes back as the sessions router's 404 and the read is replayed once
    // with `session_id` omitted. Both routes.
    let read = FileTextRead(text: "hello")
    let textSessions = LockIsolated<[String?]>([])
    let text = makeStore(path: "/home/e/out/notes.txt") {
      $0.filePreview.readText = { @Sendable _, _, session, profile in
        textSessions.withValue { $0.append(session) }
        #expect(profile == "work", "the profile is kept on the retry")
        if session != nil { throw RESTError.server(status: 404, detail: "Session not found") }
        return read
      }
    }
    await text.send(.task)
    await text.receive(\.loaded.success) { $0.content = .text(read) }
    #expect(textSessions.value == ["sess-1", nil])

    let png = tinyPNG
    let dataSessions = LockIsolated<[String?]>([])
    let image = makeStore(path: "/home/e/out/shot.png") {
      $0.filePreview.readData = { @Sendable _, _, session, _ in
        dataSessions.withValue { $0.append(session) }
        if session != nil { throw RESTError.server(status: 404, detail: "Session not found") }
        return FileDataRead(mimeType: "image/png", data: png)
      }
    }
    await image.send(.task)
    await image.receive(\.loaded.success) { $0.content = .image(png) }
    #expect(dataSessions.value == ["sess-1", nil])
  }

  @Test func aFileNotFound404DoesNotRetry() async {
    // Any other 404 is a verdict about the FILE: one request, the not-found card with the detail.
    let attempts = LockIsolated(0)
    let hint = "File not found on the gateway host: the path may live inside the agent sandbox"
    let store = makeStore(path: "/workspace/out/report.txt") {
      $0.filePreview.readText = { @Sendable _, _, _, _ in
        attempts.withValue { $0 += 1 }
        throw RESTError.server(status: 404, detail: hint)
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .notFound, serverDetail: hint))
    }
    #expect(attempts.value == 1)
  }

  @Test func aRetryThatAlsoFailsSurfacesTheSecondError() async {
    // Single retry, no loop: the replay's own failure is what the card shows.
    let sessions = LockIsolated<[String?]>([])
    let store = makeStore(path: "/workspace/out/report.txt") {
      $0.filePreview.readText = { @Sendable _, _, session, _ in
        sessions.withValue { $0.append(session) }
        if session != nil { throw RESTError.server(status: 404, detail: "Session not found") }
        throw RESTError.server(status: 404, detail: "File not found")
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .notFound, serverDetail: "File not found"))
    }
    #expect(sessions.value == ["sess-1", nil])
  }

  @Test func sessionNotFoundWithoutASessionIDIsNotRetried() async {
    // Nothing to drop: the request already carried no `session_id`, so the 404 is final.
    let attempts = LockIsolated(0)
    let store = makeStore(path: "/home/e/out/notes.txt", sessionID: nil) {
      $0.filePreview.readText = { @Sendable _, _, _, _ in
        attempts.withValue { $0 += 1 }
        throw RESTError.server(status: 404, detail: "Session not found")
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .notFound, serverDetail: "Session not found"))
    }
    #expect(attempts.value == 1)
  }

  @Test func sessionNotFoundOnDownloadRetriesOnceWithoutTheSessionID() async {
    // The download stream throws before its first event (the status is validated before the
    // folder is created), so the replay without `session_id` is the only download that yields.
    let url = fileURL("report.pdf")
    let sessions = LockIsolated<[String?]>([])
    let store = makeStore(path: "/home/e/out/report.pdf") {
      $0.filePreview.download = { @Sendable _, _, session, profile, _ in
        sessions.withValue { $0.append(session) }
        #expect(profile == "work", "the profile is kept on the retry")
        return AsyncThrowingStream { continuation in
          guard session == nil else {
            continuation.finish(throwing: RESTError.server(status: 404, detail: "Session not found"))
            return
          }
          continuation.yield(.progress(0.5))
          continuation.yield(.finished(url))
          continuation.finish()
        }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.progress(0.5))) { $0.share = .downloading(fraction: 0.5) }
    await store.receive(.downloadEvent(.finished(url))) {
      $0.share = .ready(url)
      $0.downloadedURL = url
    }
    #expect(sessions.value == ["sess-1", nil])
  }

  @Test func aDownloadRetryThatAlsoFailsSurfacesTheSecondError() async {
    let sessions = LockIsolated<[String?]>([])
    let store = makeStore(path: "/home/e/out/report.pdf") {
      $0.filePreview.download = { @Sendable _, _, session, _, _ in
        sessions.withValue { $0.append(session) }
        return AsyncThrowingStream { continuation in
          continuation.finish(
            throwing: session != nil
              ? RESTError.server(status: 404, detail: "Session not found")
              : RESTError.server(status: 404, detail: "File not found")
          )
        }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadFailed("File not found")) {
      $0.share = .idle
      $0.shareError = "File not found"
    }
    #expect(sessions.value == ["sess-1", nil])
  }

  @Test func isSessionNotFoundMatchesOnlyTheSessionsRouterVerdict() {
    #expect(FilePreviewFeature.isSessionNotFound(sessionNotFound))
    #expect(FilePreviewFeature.isSessionNotFound(RESTError.server(status: 404, detail: "Session not found\n")))
    #expect(!FilePreviewFeature.isSessionNotFound(RESTError.server(status: 404, detail: "File not found")))
    #expect(!FilePreviewFeature.isSessionNotFound(RESTError.server(status: 404, detail: nil)))
    #expect(!FilePreviewFeature.isSessionNotFound(RESTError.notFound))
    #expect(!FilePreviewFeature.isSessionNotFound(RESTError.server(status: 403, detail: "Session not found")))
    #expect(!FilePreviewFeature.isSessionNotFound(URLError(.timedOut)))
  }

  @Test func forbiddenShowsTheProtectedCard() async {
    let store = makeStore(path: "/home/e/.env") {
      $0.filePreview.readText = { @Sendable _, _, _, _ in
        throw RESTError.server(status: 403, detail: "Access to this file is not allowed")
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .protected, serverDetail: "Access to this file is not allowed"))
    }
  }

  @Test func payloadTooLargeShowsTheTooLargeCard() async {
    let store = makeStore(path: "/home/e/out/huge.png") {
      $0.filePreview.readData = { @Sendable _, _, _, _ in
        throw RESTError.server(status: 413, detail: nil)
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .tooLarge))
    }
  }

  @Test func transportErrorFailsThenRetrySucceeds() async {
    let attempts = LockIsolated(0)
    let read = FileTextRead(text: "second time lucky")
    let store = makeStore(path: "/home/e/out/log.txt") {
      $0.filePreview.readText = { @Sendable _, _, _, _ in
        attempts.withValue { $0 += 1 }
        if attempts.value == 1 { throw URLError(.timedOut) }
        return read
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .failed(message: RESTError.unreachable.message)
    }

    await store.send(.retry) { $0.content = .loading }
    await store.receive(\.loaded.success) { $0.content = .text(read) }
    #expect(attempts.value == 2)
  }

  @Test func otherServerErrorsFailWithTheServerDetail() async {
    let store = makeStore(path: "/home/e/out/log.txt") {
      $0.filePreview.readText = { @Sendable _, _, _, _ in
        throw RESTError.server(status: 500, detail: "disk on fire")
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) { $0.content = .failed(message: "disk on fire") }
  }

  // MARK: - Share download lifecycle

  private func fileURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/hermes-file-preview/ABC/\(name)")
  }

  @Test func shareDownloadsWithProgressThenBecomesReady() async {
    let url = fileURL("report.pdf")
    let seen = LockIsolated<(path: String, session: String?, profile: String?, fileName: String)?>(nil)
    let store = makeStore(path: "/home/e/out/report.pdf") {
      $0.filePreview.download = { @Sendable _, path, session, profile, fileName in
        seen.setValue((path, session, profile, fileName))
        return AsyncThrowingStream { continuation in
          continuation.yield(.progress(nil))
          continuation.yield(.progress(0.5))
          continuation.yield(.progress(1.0))
          continuation.yield(.finished(url))
          continuation.finish()
        }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.progress(nil)))
    await store.receive(.downloadEvent(.progress(0.5))) { $0.share = .downloading(fraction: 0.5) }
    await store.receive(.downloadEvent(.progress(1.0))) { $0.share = .downloading(fraction: 1.0) }
    await store.receive(.downloadEvent(.finished(url))) {
      $0.share = .ready(url)
      $0.downloadedURL = url
    }
    #expect(seen.value?.path == "/home/e/out/report.pdf")
    #expect(seen.value?.session == "sess-1")
    #expect(seen.value?.profile == "work")
    #expect(seen.value?.fileName == "report.pdf")
  }

  @Test func shareOnTheTooLargeCardStillDownloads() async {
    // An image over the 16 MB data-URL cap lands on the too-large card, but `/api/fs/download`
    // has no cap: Share must still work there — the reducer gates on `share`, never on
    // `content`, and the view's Share button is disabled only while `.downloading`.
    let url = fileURL("huge.png")
    var initial = state(path: "/home/e/out/huge.png")
    initial.content = .generic(.init(reason: .tooLarge))
    let store = TestStore(initialState: initial) { FilePreviewFeature() } withDependencies: {
      $0.filePreview.download = { @Sendable _, path, _, _, fileName in
        #expect(path == "/home/e/out/huge.png")
        #expect(fileName == "huge.png")
        return AsyncThrowingStream { continuation in
          continuation.yield(.progress(0.5))
          continuation.yield(.finished(url))
          continuation.finish()
        }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.progress(0.5))) { $0.share = .downloading(fraction: 0.5) }
    await store.receive(.downloadEvent(.finished(url))) {
      $0.share = .ready(url)
      $0.downloadedURL = url
    }
    #expect(store.state.content == .generic(.init(reason: .tooLarge)))
  }

  @Test func cancelMidDownloadReturnsToIdleAndCancelsTheEffect() async {
    let terminated = LockIsolated(false)
    let held = LockIsolated<AsyncThrowingStream<DownloadEvent, any Error>.Continuation?>(nil)
    let store = makeStore(path: "/home/e/out/big.zip") {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          held.setValue(continuation)
          continuation.onTermination = { @Sendable _ in terminated.setValue(true) }
          continuation.yield(.progress(0.25))
        }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.progress(0.25))) { $0.share = .downloading(fraction: 0.25) }

    await store.send(.cancelDownload) { $0.share = .idle }
    // The consumer stopped iterating: the stream is torn down (the live client deletes the
    // partial folder off exactly this signal)...
    await waitUntil { terminated.value }
    // ...and the producer's later yields go into a finished stream — the TestStore would flag
    // an unreceived action otherwise. (The reducer-side guard for an event that DID land is
    // `lateDownloadEventsAreIgnoredOnceTheShareLeftDownloading`.)
    held.value?.yield(.progress(0.9))
    held.value?.yield(.finished(fileURL("big.zip")))
    await store.finish()
  }

  @Test func lateDownloadEventsAreIgnoredOnceTheShareLeftDownloading() async {
    // Driven directly: a progress or finished event that reaches the reducer while no download
    // is in flight changes nothing — the bar must not come back, the share sheet must not pop.
    let idle = TestStore(initialState: state(path: "/home/e/out/big.zip")) { FilePreviewFeature() }
    await idle.send(.downloadEvent(.progress(0.9)))
    await idle.send(.downloadEvent(.finished(fileURL("big.zip"))))
    #expect(idle.state.downloadedURL == nil)

    var presented = state(path: "/home/e/out/big.zip")
    presented.share = .ready(fileURL("big.zip"))
    presented.downloadedURL = fileURL("big.zip")
    let ready = TestStore(initialState: presented) { FilePreviewFeature() }
    await ready.send(.downloadEvent(.progress(0.9)))
    await ready.send(.downloadEvent(.finished(fileURL("other.zip"))))
    #expect(ready.state.downloadedURL == fileURL("big.zip"))
  }

  @Test func cancelWhenNotDownloadingIsANoOp() async {
    let store = makeStore(path: "/home/e/out/a.txt")
    await store.send(.cancelDownload)
  }

  @Test func downloadFailureReturnsToIdleWithAnInlineError() async {
    let read = FileTextRead(text: "content")
    var initial = state(path: "/home/e/out/a.txt", sessionID: nil)
    initial.content = .text(read)
    let store = TestStore(initialState: initial) { FilePreviewFeature() } withDependencies: {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.progress(0.1))
          continuation.finish(throwing: RESTError.server(status: 500, detail: "disk on fire"))
        }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.progress(0.1))) { $0.share = .downloading(fraction: 0.1) }
    await store.receive(.downloadFailed("disk on fire")) {
      $0.share = .idle
      $0.shareError = "disk on fire"
    }
    // The preview itself is untouched by a failed share.
    #expect(store.state.content == .text(read))
  }

  @Test func rawTransportFailureIsNormalisedToARESTMessage() async {
    let store = makeStore(path: "/home/e/out/a.txt") {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadFailed(RESTError.offline.message)) {
      $0.share = .idle
      $0.shareError = RESTError.offline.message
    }
  }

  @Test func localWriteFailureKeepsItsOwnMessage() async {
    // The temp file could not be written (disk full): not a transport failure, so the strip
    // must not claim the server was unreachable.
    let failure = CocoaError(.fileWriteOutOfSpace)
    let store = makeStore(path: "/home/e/out/a.txt") {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        AsyncThrowingStream { $0.finish(throwing: failure) }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadFailed(failure.localizedDescription)) {
      $0.share = .idle
      $0.shareError = failure.localizedDescription
    }
    #expect(failure.localizedDescription != RESTError.unreachable.message)
  }

  @Test func aFinishedEventDeliveredToACancelledEffectRemovesTheFile() async {
    // The stream buffers `.finished` ahead of the consumer, so a cancel can land after the
    // producer finished (the client's `onTermination` cleanup is over) but before the reducer
    // saw the URL (a cancelled effect's send is dropped). The effect removes the file itself —
    // otherwise nothing ever would.
    let removed = LockIsolated<URL?>(nil)
    let url = fileURL("big.zip")
    let pulls = LockIsolated(0)
    let store = makeStore(path: "/home/e/out/big.zip") {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        AsyncThrowingStream {
          switch pulls.withValue({ $0 += 1; return $0 }) {
          case 1:
            return .progress(0.5)
          case 2:
            // Hand `.finished` over only once the consuming effect has been cancelled.
            while !Task.isCancelled { await Task.yield() }
            return .finished(url)
          default:
            return nil
          }
        }
      }
      $0.filePreview.removeTemp = { @Sendable url in removed.setValue(url) }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.progress(0.5))) { $0.share = .downloading(fraction: 0.5) }

    await store.send(.cancelDownload) { $0.share = .idle }
    await waitUntil({ removed.value != nil }, "the cancelled effect never removed the finished file")
    #expect(removed.value == url)
    #expect(store.state.downloadedURL == nil)
    await store.finish()
  }

  @Test func shareDismissedReturnsToIdleAndASecondShareIsInstant() async {
    let url = fileURL("report.pdf")
    let downloads = LockIsolated(0)
    let store = makeStore(path: "/home/e/out/report.pdf") {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        downloads.withValue { $0 += 1 }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(url))
          continuation.finish()
        }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.finished(url))) {
      $0.share = .ready(url)
      $0.downloadedURL = url
    }
    // The share sheet closes: the share state carries no URL, but the temp file is kept
    // (it is `ChatFeature`'s to remove when the preview goes away).
    await store.send(.shareDismissed) { $0.share = .idle }
    #expect(store.state.downloadedURL == url)

    // A second Share re-presents the file without another round-trip.
    await store.send(.shareTapped) { $0.share = .ready(url) }
    #expect(downloads.value == 1)
  }

  @Test func shareDismissedWhenNoShareSheetIsUpIsANoOp() async {
    // The view can send one `.shareDismissed` from the activity controller's completion AND one
    // from the sheet binding's nil-set for the same dismissal; the second finds the share
    // already `.idle` — or `.downloading`, if the user restarted Share in between — and must
    // not touch it.
    let idle = makeStore(path: "/home/e/out/a.txt")
    await idle.send(.shareDismissed)

    var restarted = state(path: "/home/e/out/a.txt")
    restarted.share = .downloading(fraction: 0.4)
    let downloading = TestStore(initialState: restarted) { FilePreviewFeature() }
    await downloading.send(.shareDismissed)
  }

  @Test func shareAfterCancelRestartsTheDownloadCleanly() async {
    let url = fileURL("big.zip")
    let downloads = LockIsolated(0)
    let store = makeStore(path: "/home/e/out/big.zip") {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        let attempt = downloads.withValue { $0 += 1; return $0 }
        return AsyncThrowingStream { continuation in
          if attempt == 1 {
            continuation.yield(.progress(0.2))   // then hangs until cancelled
          } else {
            continuation.yield(.finished(url))
            continuation.finish()
          }
        }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.progress(0.2))) { $0.share = .downloading(fraction: 0.2) }
    await store.send(.cancelDownload) { $0.share = .idle }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadEvent(.finished(url))) {
      $0.share = .ready(url)
      $0.downloadedURL = url
    }
    #expect(downloads.value == 2)
  }

  @Test func shareTappedWhileDownloadingOrReadyIsANoOp() async {
    let url = fileURL("a.txt")
    var downloading = state(path: "/home/e/out/a.txt", sessionID: nil)
    downloading.share = .downloading(fraction: 0.5)
    let busy = TestStore(initialState: downloading) { FilePreviewFeature() }
    await busy.send(.shareTapped)

    var ready = downloading
    ready.share = .ready(url)
    let presented = TestStore(initialState: ready) { FilePreviewFeature() }
    await presented.send(.shareTapped)
  }

  @Test func aNewShareClearsThePreviousShareError() async {
    let url = fileURL("a.txt")
    var initial = state(path: "/home/e/out/a.txt", sessionID: nil)
    initial.shareError = "disk on fire"
    let store = TestStore(initialState: initial) { FilePreviewFeature() } withDependencies: {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(url))
          continuation.finish()
        }
      }
    }

    await store.send(.shareTapped) {
      $0.share = .downloading(fraction: nil)
      $0.shareError = nil
    }
    await store.receive(.downloadEvent(.finished(url))) {
      $0.share = .ready(url)
      $0.downloadedURL = url
    }
  }

  // MARK: - Copy path toast

  @Test func copyPathPutsThePathOnThePasteboardAndClearsAfterTheDwell() async {
    let copied = LockIsolated<String?>(nil)
    let clock = TestClock()
    let store = makeStore(path: "/home/e/out/report.pdf") {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
      $0.continuousClock = clock
    }

    await store.send(.copyPath) { $0.copiedToken = 1 }
    #expect(copied.value == "/home/e/out/report.pdf")

    await clock.advance(by: .seconds(1.5))
    await store.receive(.copiedFeedbackElapsed) { $0.copiedToken = nil }
  }

  @Test func copyingAgainInsideTheDwellBumpsTheTokenAndRestartsTheTimer() async {
    let clock = TestClock()
    let store = makeStore(path: "/home/e/out/report.pdf") {
      $0.pasteboard.copy = { @Sendable _ in }
      $0.continuousClock = clock
    }

    await store.send(.copyPath) { $0.copiedToken = 1 }
    await clock.advance(by: .seconds(1.0))
    // Every copy bumps the token (a `Bool` could not re-trigger the toast) and the first
    // timer dies with it (cancelInFlight).
    await store.send(.copyPath) { $0.copiedToken = 2 }
    await clock.advance(by: .seconds(1.0)) // 2.0 s after the first copy — nothing fires
    await clock.advance(by: .seconds(0.5)) // 1.5 s after the second copy
    await store.receive(.copiedFeedbackElapsed) { $0.copiedToken = nil }
  }
}
