import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// #158: a canonical session-authority host (`gateway.ready.session_authority: true`, Hermes
/// v0.22.3+) admits identified input only, so every `prompt.submit` there carries a
/// `submission_id`: minted once per user send, reused by that send's heal replay. A legacy
/// host refuses unknown params, so its frames stay byte-identical (no key).
@MainActor
struct SubmissionIDTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  private func readyState(authority: Bool, liveID: String = "live1", text: String = "hello") -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = liveID
    state.storedSessionID = "stored1"
    state.awaitsFirstPersist = false
    state.isSessionAuthority = authority
    state.composerText = text
    return state
  }

  private nonisolated static let resumePayload: JSONValue = .object([
    "session_id": .string("live1"), "stored_session_id": .string("stored1"),
    "messages": .array([]), "running": .bool(false),
  ])

  /// A store whose gateway records every `prompt.submit`; a submit to `stale-live` answers
  /// "session not found" so the #17 heal replays it against `live1`.
  private func makeStore(
    _ initial: ChatFeature.State, submits: LockIsolated<[JSONValue]>
  ) -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        switch method {
        case "prompt.submit":
          submits.withValue { $0.append(params) }
          if params["session_id"]?.stringValue == "stale-live" {
            throw GatewayError.server("session not found")
          }
          return .object(["status": .string("queued")])
        case "session.resume":
          return Self.resumePayload
        case "file.attach":
          return .object(["ref": .string("@file:notes.txt")])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  @Test func legacyHostSubmitCarriesNoSubmissionID() async {
    let submits = LockIsolated<[JSONValue]>([])
    let store = makeStore(readyState(authority: false), submits: submits)

    await store.send(.composerSubmitted)
    await store.finish()

    #expect(submits.value == [.object(["session_id": .string("live1"), "text": .string("hello")])])
  }

  @Test func authorityHostSubmitCarriesALowercaseUUID() async throws {
    let submits = LockIsolated<[JSONValue]>([])
    let store = makeStore(readyState(authority: true), submits: submits)

    await store.send(.composerSubmitted)
    await store.finish()

    let params = try #require(submits.value.first)
    let id = try #require(params["submission_id"]?.stringValue)
    #expect(UUID(uuidString: id) != nil)
    #expect(id == id.lowercased())
    #expect(params["session_id"]?.stringValue == "live1")
    #expect(params["text"]?.stringValue == "hello")
    #expect(store.state.errorBanner == nil)
  }

  @Test func healReplayReusesTheSendsSubmissionID() async throws {
    // The replay is the SAME send, so the gateway can de-duplicate it by id.
    let submits = LockIsolated<[JSONValue]>([])
    let store = makeStore(readyState(authority: true, liveID: "stale-live"), submits: submits)

    await store.send(.composerSubmitted)
    await store.receive(\.liveSessionIDRefreshed)
    await store.finish()

    #expect(submits.value.map { $0["session_id"]?.stringValue } == ["stale-live", "live1"])
    let first = try #require(submits.value.first?["submission_id"]?.stringValue)
    #expect(submits.value.last?["submission_id"]?.stringValue == first)
  }

  @Test func eachSendGetsAFreshSubmissionID() async throws {
    let submits = LockIsolated<[JSONValue]>([])
    let store = makeStore(readyState(authority: true), submits: submits)

    await store.send(.composerSubmitted)
    await store.send(.gatewayEvent(.messageComplete(text: "ok", usage: nil)))
    await store.send(.binding(.set(\.composerText, "again")))
    await store.send(.composerSubmitted)
    await store.finish()

    let ids = submits.value.compactMap { $0["submission_id"]?.stringValue }
    #expect(ids.count == 2)
    #expect(Set(ids).count == 2)
  }

  @Test func attachmentSubmitCarriesSubmissionIDOnAuthorityHost() async throws {
    let submits = LockIsolated<[JSONValue]>([])
    var initial = readyState(authority: true)
    initial.attachments = [ComposerAttachment(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!, kind: .file,
      filename: "notes.txt", mimeType: "text/plain", data: Data([1])
    )]
    let store = makeStore(initial, submits: submits)

    await store.send(.composerSubmitted)
    await store.finish()

    let params = try #require(submits.value.first)
    #expect(params["submission_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
  }
}
