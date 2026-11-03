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
    configure: @escaping (inout DependencyValues) -> Void = { _ in }
  ) -> TestStoreOf<FilePreviewFeature> {
    TestStore(
      initialState: FilePreviewFeature.State(path: path, sessionID: sessionID, connection: connection),
      reducer: { FilePreviewFeature() },
      withDependencies: configure
    )
  }

  private var tinyPNG: Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }

  // MARK: - State seeding

  @Test func initDerivesFileNameAndKindFromThePath() {
    let image = FilePreviewFeature.State(path: "/home/e/out/shot.PNG", sessionID: nil, connection: connection)
    #expect(image.fileName == "shot.PNG")
    #expect(image.kind == .image)
    #expect(image.content == .loading)
    #expect(image.share == .idle)

    let other = FilePreviewFeature.State(path: "~/Downloads/notes.md", sessionID: "s", connection: connection)
    #expect(other.fileName == "notes.md")
    #expect(other.kind == .other)
  }

  // MARK: - Loading by kind

  @Test func imageLoadsThroughTheDataRouteWithPathAndSession() async {
    let seen = LockIsolated<(path: String, session: String?)?>(nil)
    let png = tinyPNG
    let store = makeStore(path: "/home/e/out/shot.png") {
      $0.filePreview.readData = { @Sendable _, path, session in
        seen.setValue((path, session))
        return FileDataRead(mimeType: "image/png", data: png)
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.success) { $0.content = .image(png) }
    #expect(seen.value?.path == "/home/e/out/shot.png")
    #expect(seen.value?.session == "sess-1")
  }

  @Test func pdfLoadsThroughTheDataRoute() async {
    let bytes = Data("%PDF-1.4".utf8)
    let store = makeStore(path: "/home/e/out/report.pdf", sessionID: nil) {
      $0.filePreview.readData = { @Sendable _, _, session in
        #expect(session == nil, "a nil session key is forwarded as nil, not an empty string")
        return FileDataRead(mimeType: "application/pdf", data: bytes)
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.success) { $0.content = .pdf(bytes) }
  }

  @Test func textLoadsThroughReadTextAndKeepsTheTruncatedFlag() async {
    let read = FileTextRead(binary: false, byteSize: 900_000, language: "swift", mimeType: "text/x-swift", text: "let x = 1", truncated: true)
    let store = makeStore(path: "/home/e/src/App.swift") {
      $0.filePreview.readText = { @Sendable _, _, _ in read }
    }

    await store.send(.task)
    await store.receive(\.loaded.success) { $0.content = .text(read) }
  }

  @Test func binaryVerdictShowsTheGenericCardWithByteSize() async {
    let read = FileTextRead(binary: true, byteSize: 4096, mimeType: "application/octet-stream", text: "")
    let store = makeStore(path: "/home/e/out/archive.zip") {
      $0.filePreview.readText = { @Sendable _, _, _ in read }
    }

    await store.send(.task)
    await store.receive(\.loaded.success) {
      $0.content = .generic(.init(reason: .unsupported, byteSize: 4096))
    }
  }

  @Test func taskIsIdempotentOnceContentIsLoaded() async {
    // A re-appearance of the sheet must not throw a loaded preview away; no endpoint is
    // stubbed, so hitting one would fail the test.
    var initial = FilePreviewFeature.State(path: "/a/b.txt", sessionID: nil, connection: connection)
    initial.content = .text(FileTextRead(text: "hi"))
    let store = TestStore(initialState: initial) { FilePreviewFeature() }
    await store.send(.task)
  }

  // MARK: - Error mapping

  @Test func notFoundShowsTheNotFoundCard() async {
    let store = makeStore(path: "/home/e/out/missing.txt") {
      $0.filePreview.readText = { @Sendable _, _, _ in throw RESTError.notFound }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .notFound))
    }
  }

  @Test func notFoundWithServerDetailKeepsTheDetail() async {
    // A 404 that reaches the reducer as `.server(404, detail)` keeps the sandbox hint.
    let store = makeStore(path: "/workspace/out/missing.png") {
      $0.filePreview.readData = { @Sendable _, _, _ in
        throw RESTError.server(status: 404, detail: "File exists only inside the sandbox")
      }
    }

    await store.send(.task)
    await store.receive(\.loaded.failure) {
      $0.content = .generic(.init(reason: .notFound, serverDetail: "File exists only inside the sandbox"))
    }
  }

  @Test func forbiddenShowsTheProtectedCard() async {
    let store = makeStore(path: "/home/e/.env") {
      $0.filePreview.readText = { @Sendable _, _, _ in
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
      $0.filePreview.readData = { @Sendable _, _, _ in
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
      $0.filePreview.readText = { @Sendable _, _, _ in
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
      $0.filePreview.readText = { @Sendable _, _, _ in
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
    let seen = LockIsolated<(path: String, session: String?, fileName: String)?>(nil)
    let store = makeStore(path: "/home/e/out/report.pdf") {
      $0.filePreview.download = { @Sendable _, path, session, fileName in
        seen.setValue((path, session, fileName))
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
    #expect(seen.value?.fileName == "report.pdf")
  }

  @Test func cancelMidDownloadReturnsToIdleAndCancelsTheEffect() async {
    let terminated = LockIsolated(false)
    let held = LockIsolated<AsyncThrowingStream<DownloadEvent, any Error>.Continuation?>(nil)
    let store = makeStore(path: "/home/e/out/big.zip") {
      $0.filePreview.download = { @Sendable _, _, _, _ in
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
    // ...and a late event from the producer lands nowhere — the TestStore would flag an
    // unreceived action otherwise.
    held.value?.yield(.progress(0.9))
    held.value?.yield(.finished(fileURL("big.zip")))
    await store.finish()
  }

  @Test func cancelWhenNotDownloadingIsANoOp() async {
    let store = makeStore(path: "/home/e/out/a.txt")
    await store.send(.cancelDownload)
  }

  @Test func downloadFailureReturnsToIdleWithAnInlineError() async {
    let read = FileTextRead(text: "content")
    var initial = FilePreviewFeature.State(path: "/home/e/out/a.txt", sessionID: nil, connection: connection)
    initial.content = .text(read)
    let store = TestStore(initialState: initial) { FilePreviewFeature() } withDependencies: {
      $0.filePreview.download = { @Sendable _, _, _, _ in
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
      $0.filePreview.download = { @Sendable _, _, _, _ in
        AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
      }
    }

    await store.send(.shareTapped) { $0.share = .downloading(fraction: nil) }
    await store.receive(.downloadFailed(RESTError.offline.message)) {
      $0.share = .idle
      $0.shareError = RESTError.offline.message
    }
  }

  @Test func shareDismissedReturnsToIdleAndASecondShareIsInstant() async {
    let url = fileURL("report.pdf")
    let downloads = LockIsolated(0)
    let store = makeStore(path: "/home/e/out/report.pdf") {
      $0.filePreview.download = { @Sendable _, _, _, _ in
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

  @Test func shareAfterCancelRestartsTheDownloadCleanly() async {
    let url = fileURL("big.zip")
    let downloads = LockIsolated(0)
    let store = makeStore(path: "/home/e/out/big.zip") {
      $0.filePreview.download = { @Sendable _, _, _, _ in
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
    var downloading = FilePreviewFeature.State(path: "/home/e/out/a.txt", sessionID: nil, connection: connection)
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
    var initial = FilePreviewFeature.State(path: "/home/e/out/a.txt", sessionID: nil, connection: connection)
    initial.shareError = "disk on fire"
    let store = TestStore(initialState: initial) { FilePreviewFeature() } withDependencies: {
      $0.filePreview.download = { @Sendable _, _, _, _ in
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
