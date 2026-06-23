import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Task 2 (#17): outbound RPCs self-heal a stale live session id. When `prompt.submit` (plain
/// or attach path) or `session.title` fails with "session not found" — the agent rebuilt the
/// in-memory session after a background→foreground — the reducer transparently re-resumes the
/// stored session for a fresh live id and replays the RPC ONCE, surfacing the banner only if
/// the re-resume OR the retry also fails (no infinite loop).
@MainActor
struct SelfHealTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// A ready chat with both a stale live id and a stored id to re-resume against.
  private func healableState() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "stale-live"
    state.storedSessionID = "stored123"
    return state
  }

  /// A `session.resume` ActivateResponse with a fresh live id and no in-flight turn.
  /// `nonisolated` so the `@Sendable` gateway-send mocks can build it.
  private nonisolated func resumePayload(liveID: String) -> JSONValue {
    .object([
      "session_id": .string(liveID),
      "stored_session_id": .string("stored123"),
      "messages": .array([]),
      "running": .bool(false),
    ])
  }

  // MARK: prompt.submit self-heal

  @Test func promptSubmitSelfHealsOnSessionNotFoundThenSucceeds() async {
    // The first prompt.submit (against the stale live id) fails "session not found"; the reducer
    // re-resumes for a fresh live id, applies it, and replays the submit — which now succeeds
    // with NO error banner.
    let calls = LockIsolated<[(method: String, sessionID: String?)]>([])
    var initial = healableState()
    initial.composerText = "hello"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        let sid = params["session_id"]?.stringValue
        calls.withValue { $0.append((method, sid)) }
        switch method {
        case "prompt.submit":
          if sid == "stale-live" { throw GatewayError.server("session not found") }
          return .object(["status": .string("streaming")]) // retried against fresh id
        case "session.resume":
          return self.resumePayload(liveID: "fresh-live")
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "hello", isComplete: true))]
      $0.composerText = ""
      $0.isSending = true
    }
    // Self-heal applies the fresh live id without rebuilding the transcript.
    await store.receive(\.liveSessionIDRefreshed) {
      $0.liveSessionID = "fresh-live"
    }
    await store.finish()

    let methods = calls.value.map(\.method)
    #expect(methods == ["prompt.submit", "session.resume", "prompt.submit"])
    // The retry targeted the fresh id; no error banner; still streaming.
    #expect(calls.value.last?.sessionID == "fresh-live")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.isSending)
  }

  @Test func promptSubmitSurfacesBannerWhenRetryAlsoFails() async {
    // Re-resume succeeds, but the replayed prompt.submit STILL fails — the reducer must surface
    // the banner and stop (a single retry, no loop).
    let calls = LockIsolated<[String]>([])
    var initial = healableState()
    initial.composerText = "hello"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "prompt.submit": throw GatewayError.server("session not found")
        case "session.resume": return self.resumePayload(liveID: "fresh-live")
        default: return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "hello", isComplete: true))]
      $0.composerText = ""
      $0.isSending = true
    }
    await store.receive(\.liveSessionIDRefreshed) {
      $0.liveSessionID = "fresh-live"
    }
    await store.receive(\.promptSubmitFailed) {
      $0.errorBanner = "Prompt failed: session not found"
      $0.isSending = false
    }
    await store.finish()

    // Exactly one retry: submit, resume, submit — never a third submit.
    #expect(calls.value == ["prompt.submit", "session.resume", "prompt.submit"])
  }

  @Test func promptSubmitSurfacesBannerWhenReResumeFails() async {
    // The re-resume itself fails (e.g. the stored session is also gone) — surface the banner,
    // no replay.
    let calls = LockIsolated<[String]>([])
    var initial = healableState()
    initial.composerText = "hello"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "prompt.submit": throw GatewayError.server("session not found")
        case "session.resume": throw GatewayError.server("session not found")
        default: return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "hello", isComplete: true))]
      $0.composerText = ""
      $0.isSending = true
    }
    await store.receive(\.promptSubmitFailed) {
      $0.errorBanner = "Prompt failed: session not found"
      $0.isSending = false
    }
    await store.finish()

    // No second prompt.submit after the failed resume.
    #expect(calls.value == ["prompt.submit", "session.resume"])
    #expect(store.state.liveSessionID == "stale-live") // heal never landed a fresh id
  }

  // MARK: attach-upload self-heal

  @Test func attachUploadSelfHealsOnSessionNotFoundThenSucceeds() async {
    // The upload→submit sequence runs against the stale id and fails; the reducer re-resumes
    // and replays the WHOLE sequence (uploads are idempotent) against the fresh id, succeeding.
    let calls = LockIsolated<[(method: String, sessionID: String?)]>([])
    var initial = healableState()
    initial.attachments = [
      ComposerAttachment(id: self.uuid(99), kind: .image, filename: "p.png", mimeType: "image/png", data: Data([0x1, 0x2]))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        let sid = params["session_id"]?.stringValue
        calls.withValue { $0.append((method, sid)) }
        switch method {
        case "image.attach_bytes":
          if sid == "stale-live" { throw GatewayError.server("session not found") }
          return .object([:])
        case "prompt.submit":
          return .object(["status": .string("streaming")])
        case "session.resume":
          return self.resumePayload(liveID: "fresh-live")
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.liveSessionIDRefreshed) {
      $0.liveSessionID = "fresh-live"
    }
    await store.receive(\.attachmentsSubmitted)
    await store.finish()

    let methods = calls.value.map(\.method)
    // First attach fails → resume → re-upload + submit against the fresh id.
    #expect(methods == ["image.attach_bytes", "session.resume", "image.attach_bytes", "prompt.submit"])
    #expect(calls.value.last?.sessionID == "fresh-live")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.attachments.isEmpty) // cleared on success
  }

  @Test func attachUploadSurfacesBannerWhenRetryAlsoFails() async {
    // Re-resume succeeds, the replayed upload still fails "session not found" — surface the
    // attachment-failed banner; keep attachments for retry; a single retry (no loop).
    let calls = LockIsolated<[String]>([])
    var initial = healableState()
    initial.attachments = [
      ComposerAttachment(id: self.uuid(99), kind: .image, filename: "p.png", mimeType: "image/png", data: Data([0x1, 0x2]))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "image.attach_bytes": throw GatewayError.server("session not found")
        case "session.resume": return self.resumePayload(liveID: "fresh-live")
        default: return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.liveSessionIDRefreshed) {
      $0.liveSessionID = "fresh-live"
    }
    await store.receive(\.attachmentUploadFailed) {
      $0.errorBanner = "Attachment failed: session not found"
      $0.isSending = false
    }
    await store.finish()

    // One retry only: attach, resume, attach — never a third attach.
    #expect(calls.value == ["image.attach_bytes", "session.resume", "image.attach_bytes"])
    #expect(!store.state.attachments.isEmpty) // kept for retry
  }

  // MARK: foreground session.resume "session not found" recreates

  @Test func foregroundResumeSessionNotFoundRecreatesSession() async {
    // A real server "session not found" from the foreground hydrate is NOT a benign socket
    // drop: clear the stale live id and recreate a fresh session so the chat can keep sending.
    let store = TestStore(initialState: healableState()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.create" {
          return .object(["session_id": .string("recreated-live"), "stored_session_id": .string("stored123")])
        }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.activateResult(.failure(.server("session not found")))) {
      $0.status = .reconnecting
      $0.liveSessionID = nil
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "recreated-live"
      $0.storedSessionID = "stored123"
      $0.status = .ready
    }
    await store.finish()
    #expect(store.state.errorBanner == nil)
  }

  @Test func foregroundResumeDisconnectedDoesNotRecreate() async {
    // Regression guard: a benign socket drop (`.disconnected`) must NOT recreate — it just goes
    // reconnecting and keeps the stale id (the reconnect re-resumes it).
    let store = TestStore(initialState: healableState()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.chatSnapshot = .inMemory()
    }
    await store.send(.activateResult(.failure(.disconnected))) {
      $0.status = .reconnecting
    }
    #expect(store.state.liveSessionID == "stale-live") // unchanged, no recreate
  }
}
