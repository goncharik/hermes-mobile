import Clocks
import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// `ChatFeature`'s `@Presents filePreview` child: the tap that seeds it, the one-sheet-at-a-time
/// guard, the dismiss cleanup of the downloaded temp file, `.ifLet` cancellation of an in-flight
/// download, and the child's absence from the persisted snapshot.
@MainActor
struct ChatFilePreviewTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  /// A resumed chat in a named profile whose stored id is known — the fs routes' `session_id`
  /// carries the STORED id (the server resolves no other) and `profile` the chat's profile.
  private func resumedState() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    state.liveSessionID = "live"
    state.profileName = "work"
    state.status = .ready
    return state
  }

  private func presented(
    path: String, content: FilePreviewFeature.Content,
    share: FilePreviewFeature.ShareState = .idle, downloadedURL: URL? = nil
  ) -> FilePreviewFeature.State {
    FilePreviewFeature.State(
      path: path, sessionID: "stored123", profile: "work", connection: conn,
      content: content, share: share, downloadedURL: downloadedURL
    )
  }

  private func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("hermes-file-preview/test-\(name)", isDirectory: true)
      .appendingPathComponent(name)
  }

  // MARK: - Tap

  @Test func tapSeedsTheChildWithTheStoredSessionProfileAndConnection() async {
    let store = TestStore(initialState: resumedState()) { ChatFeature() }

    await store.send(.fileReferenceTapped(path: "/home/e/out/report.pdf")) {
      $0.filePreview = FilePreviewFeature.State(
        path: "/home/e/out/report.pdf", sessionID: "stored123", profile: "work", connection: self.conn
      )
    }
    #expect(store.state.filePreview?.kind == .pdf)
    #expect(store.state.filePreview?.fileName == "report.pdf")
  }

  @Test func tapOnALiveOnlyChatOmitsTheSessionIDAndProfile() async {
    // A chat that has a live handle but no stored id (an old agent's `session.create` answered
    // without one) still previews absolute paths; the server resolves stored ids only, so the
    // live handle is NOT sent — `session_id` is omitted rather than 404ing. No profile
    // selected → `profile` omitted too (the server's launch profile).
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live"
    let store = TestStore(initialState: state) { ChatFeature() }

    await store.send(.fileReferenceTapped(path: "~/notes.md")) {
      $0.filePreview = FilePreviewFeature.State(path: "~/notes.md", sessionID: nil, profile: nil, connection: self.conn)
    }
  }

  @Test func tapOnAFreshBranchSendsItsStoredIDAndLetsTheServerDecide() async {
    // A branch primed from its `session.create` (#34) has a stored id whose DB row may or may
    // not exist yet (current agents persist a seeded branch immediately; older ones on the first
    // prompt). The client has no local signal for that, so the id is sent as-is — a
    // "Session not found" 404 is the child's to retry once without it
    // (`FilePreviewFeatureTests`). The seed-only shape (an interrupted replay nilled
    // `attachLiveSessionID`) is seeded the same way.
    var attaching = ChatFeature.State(connection: conn, resumeStoredID: "branch-1")
    attaching.liveSessionID = "branch-live"
    attaching.attachLiveSessionID = "branch-live"
    attaching.branchSeed = .init(text: "seeded answer", parentSessionID: "parent")
    attaching.profileName = "work"
    attaching.status = .ready

    var seedOnly = attaching
    seedOnly.attachLiveSessionID = nil

    for state in [attaching, seedOnly] {
      let store = TestStore(initialState: state) { ChatFeature() }
      await store.send(.fileReferenceTapped(path: "/home/e/out/report.pdf")) {
        $0.filePreview = FilePreviewFeature.State(
          path: "/home/e/out/report.pdf", sessionID: "branch-1", profile: "work", connection: self.conn
        )
      }
    }
  }

  @Test func secondTapWhilePresentedIsANoOp() async {
    let store = TestStore(initialState: resumedState()) { ChatFeature() }

    await store.send(.fileReferenceTapped(path: "/home/e/out/a.txt")) {
      $0.filePreview = FilePreviewFeature.State(
        path: "/home/e/out/a.txt", sessionID: "stored123", profile: "work", connection: self.conn
      )
    }
    // A double-tap (or a tap on another link while the sheet animates in) must not swap the
    // preview under the user: no state change, no effect.
    await store.send(.fileReferenceTapped(path: "/home/e/out/b.txt"))
    #expect(store.state.filePreview?.path == "/home/e/out/a.txt")
  }

  // MARK: - Dismiss cleanup

  @Test func dismissWithADownloadedFileRemovesTheTempFile() async {
    let removed = LockIsolated<URL?>(nil)
    let url = tempURL("report.pdf")
    var initial = resumedState()
    initial.filePreview = presented(
      path: "/home/e/out/report.pdf", content: .pdf(Data("%PDF".utf8)), share: .ready(url), downloadedURL: url
    )
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.filePreview.removeTemp = { @Sendable url in removed.setValue(url) }
    }

    await store.send(.filePreview(.dismiss)) { $0.filePreview = nil }
    await store.finish()
    #expect(removed.value == url)
  }

  @Test func dismissAfterTheShareSheetClosedStillRemovesTheKeptFile() async {
    // `.shareDismissed` resets `share` to `.idle` but keeps `downloadedURL` (a second Share is
    // instant); the cleanup must read `downloadedURL`, not `share`.
    let removed = LockIsolated<URL?>(nil)
    let url = tempURL("export.zip")
    var initial = resumedState()
    initial.filePreview = presented(
      path: "/home/e/out/export.zip", content: .generic(.init(reason: .unsupported, byteSize: 10)),
      share: .idle, downloadedURL: url
    )
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.filePreview.removeTemp = { @Sendable url in removed.setValue(url) }
    }

    await store.send(.filePreview(.dismiss)) { $0.filePreview = nil }
    await store.finish()
    #expect(removed.value == url)
  }

  @Test func dismissWithoutADownloadRemovesNothing() async {
    // `removeTemp` is left unimplemented: calling it would fail the test.
    var initial = resumedState()
    initial.filePreview = presented(path: "/home/e/out/a.txt", content: .text(FileTextRead(text: "hi")))
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.filePreview(.dismiss)) { $0.filePreview = nil }
  }

  @Test func dismissDuringADownloadCancelsTheChildEffect() async {
    let terminated = LockIsolated(false)
    let held = LockIsolated<AsyncThrowingStream<DownloadEvent, any Error>.Continuation?>(nil)
    var initial = resumedState()
    initial.filePreview = presented(
      path: "/home/e/out/big.zip", content: .generic(.init(reason: .unsupported, byteSize: 50_000_000))
    )
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.filePreview.download = { @Sendable _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          held.setValue(continuation)
          continuation.onTermination = { @Sendable _ in terminated.setValue(true) }
          continuation.yield(.progress(0.25))
        }
      }
    }

    await store.send(.filePreview(.presented(.shareTapped))) {
      $0.filePreview?.share = .downloading(fraction: nil)
    }
    await store.receive(\.filePreview.presented.downloadEvent) {
      $0.filePreview?.share = .downloading(fraction: 0.25)
    }

    // Dismissing the sheet mid-download: `.ifLet` nils the child AND cancels its effects —
    // no `removeTemp` (nothing finished; the live client's `onTermination` deletes the partial
    // folder), and the producer's later yields go into a finished stream, so no trailing
    // `downloadEvent` can reach the nil child.
    await store.send(.filePreview(.dismiss)) { $0.filePreview = nil }
    await waitUntil { terminated.value }
    held.value?.yield(.progress(0.9))
    held.value?.yield(.finished(tempURL("big.zip")))
    await store.finish()
  }

  // MARK: - Persistence

  @Test func snapshotPersistIgnoresThePresentedChild() async {
    // The child is transient UI: the persisted snapshot carries the transcript + model data
    // only, and persisting leaves the presented sheet exactly where it was.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let row = ChatRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .message(role: .assistant, text: "Saved to /home/e/out/report.pdf", isComplete: true))
    var initial = resumedState()
    initial.transcript = [row]
    initial.model = "gpt-5"
    initial.filePreview = presented(path: "/home/e/out/report.pdf", content: .pdf(Data("%PDF".utf8)))
    let presented = initial.filePreview
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 123))
      $0.chatSnapshot = snapshotClient
    }

    await store.send(.persistNow)
    await store.finish()

    let saved = snapshotClient.loadSnapshot("stored123")
    #expect(saved?.rows == [row])
    #expect(saved?.model == "gpt-5")
    #expect(store.state.filePreview == presented)
  }
}
