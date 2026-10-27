import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Steering a queued message into the RUNNING turn (#66 follow-up) — the desktop's
/// "Steer now", which delivers a correction without cancelling the turn (unlike Send-now).
///
/// The load-bearing invariant: a steered entry leaves the queue optimistically so the drain
/// cannot send it twice, but a REFUSED steer puts it back — the text is never lost.
@MainActor
struct ChatQueueSteerTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// A chat mid-turn with a queue: live session bound, turn streaming, one entry waiting.
  private func runningState(
    text: String = "actually use the other endpoint",
    attachments: [ComposerAttachment] = []
  ) -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live123"
    state.storedSessionID = "stored123"
    state.status = .ready
    state.isSending = true
    state.queuedPrompts = [
      QueuedPrompt(id: uuid(0), text: text, attachments: attachments)
    ]
    return state
  }

  /// A gateway stub that answers `session.steer` with `status`.
  private func gatewaySteer(
    status: String
  ) -> @Sendable (String, JSONValue) async throws -> JSONValue {
    { method, _ in
      #expect(method == "session.steer")
      return .object(["status": .string(status), "text": .string("x")])
    }
  }

  // MARK: Steer accepted

  @Test func steeringRemovesTheEntryFromTheQueue() async {
    let store = TestStore(initialState: runningState()) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.send = gatewaySteer(status: "steered")
    }

    await store.send(.queuedPromptSteer(id: uuid(0))) {
      $0.queuedPrompts = []
      $0.pendingSteerEntries[self.uuid(0)] = QueuedPrompt(
        id: self.uuid(0), text: "actually use the other endpoint"
      )
    }
    await store.receive(\.queuedPromptSteerResult) {
      $0.pendingSteerEntries = [:]
    }
    // Accepted: the entry is gone for good — the live turn owns the text now.
    #expect(store.state.queuedPrompts.isEmpty)
  }

  /// The server's `queued` status also means the text reached the live turn (the gateway
  /// stashes an accepted steer for the next tool result), so it must count as accepted.
  @Test func queuedStatusCountsAsAccepted() async {
    let store = TestStore(initialState: runningState()) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.send = gatewaySteer(status: "queued")
    }

    await store.send(.queuedPromptSteer(id: uuid(0))) {
      $0.queuedPrompts = []
      $0.pendingSteerEntries[self.uuid(0)] = QueuedPrompt(
        id: self.uuid(0), text: "actually use the other endpoint"
      )
    }
    await store.receive(\.queuedPromptSteerResult) {
      $0.pendingSteerEntries = [:]
    }
    #expect(store.state.queuedPrompts.isEmpty)
  }

  // MARK: Steer refused — the message must survive

  @Test func explicitRejectionPutsTheEntryBackAtTheHead() async {
    let store = TestStore(initialState: runningState()) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.send = gatewaySteer(status: "rejected")
    }

    await store.send(.queuedPromptSteer(id: uuid(0))) {
      $0.queuedPrompts = []
      $0.pendingSteerEntries[self.uuid(0)] = QueuedPrompt(
        id: self.uuid(0), text: "actually use the other endpoint"
      )
    }
    await store.receive(\.queuedPromptSteerResult) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "actually use the other endpoint")]
      $0.pendingSteerEntries = [:]
      // Parked: nothing auto-fires into whatever just refused the correction.
      $0.isQueueParked = true
    }
  }

  /// A transport error (older agent without `session.steer` → unknown method, or a dropped
  /// socket) must re-queue the entry rather than lose it.
  @Test func rpcFailureRequeuesTheEntry() async {
    let store = TestStore(initialState: runningState()) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.send = { _, _ in throw GatewayError.disconnected }
    }

    await store.send(.queuedPromptSteer(id: uuid(0))) {
      $0.queuedPrompts = []
      $0.pendingSteerEntries[self.uuid(0)] = QueuedPrompt(
        id: self.uuid(0), text: "actually use the other endpoint"
      )
    }
    await store.receive(\.queuedPromptSteerResult) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "actually use the other endpoint")]
      $0.pendingSteerEntries = [:]
      $0.isQueueParked = true
      $0.errorBanner = "Couldn't steer: \(GatewayError.disconnected.message)"
    }
  }

  @Test func abortedSteerRequeuesWithoutParkingOrBanner() async {
    var initial = runningState()
    initial.queuedPrompts = []
    initial.pendingSteerEntries = [
      uuid(0): QueuedPrompt(id: uuid(0), text: "actually use the other endpoint")
    ]
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.queuedPromptSteerAborted(id: uuid(0))) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "actually use the other endpoint")]
      $0.pendingSteerEntries = [:]
    }
    // An abort is not a refusal — no park, no banner; the normal drain still owns it.
    #expect(store.state.isQueueParked == false)
    #expect(store.state.errorBanner == nil)
  }

  // MARK: Gates

  /// No running turn → nothing to steer into. The entry must stay queued untouched.
  @Test func steerIsANoOpWhenTheTurnIsNotRunning() async {
    var initial = runningState()
    initial.isSending = false
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.queuedPromptSteer(id: uuid(0)))
    #expect(store.state.queuedPrompts.count == 1)
    #expect(store.state.pendingSteerEntries.isEmpty)
  }

  /// An entry with attachments cannot ride `session.steer` (it carries only `text`), so the
  /// reducer must refuse regardless of what the view offers.
  @Test func steerIsRefusedForAnEntryWithAttachments() async {
    let attachment = ComposerAttachment(
      id: uuid(9), kind: .image, filename: "shot.png", mimeType: "image/png", data: Data([0x1])
    )
    let store = TestStore(
      initialState: runningState(text: "look at this", attachments: [attachment])
    ) { ChatFeature() }

    await store.send(.queuedPromptSteer(id: uuid(0)))
    #expect(store.state.queuedPrompts.count == 1)
    #expect(store.state.pendingSteerEntries.isEmpty)
  }

  /// A slash command EXECUTES on its own pipeline; it never steers a running turn.
  @Test func steerIsRefusedForASlashCommand() async {
    let store = TestStore(initialState: runningState(text: "/status")) { ChatFeature() }

    await store.send(.queuedPromptSteer(id: uuid(0)))
    #expect(store.state.queuedPrompts.count == 1)
    #expect(store.state.pendingSteerEntries.isEmpty)
  }

  @Test func steerIsANoOpForAnUnknownID() async {
    let store = TestStore(initialState: runningState()) { ChatFeature() }
    await store.send(.queuedPromptSteer(id: uuid(77)))
    #expect(store.state.queuedPrompts.count == 1)
  }

  // MARK: Slot lifetime

  /// An in-flight steer is queued work: the app-level teardown must keep the slot alive
  /// until the RPC answers and either confirms or restores the entry.
  @Test func anInFlightSteerCountsAsQueuedWork() {
    var state = ChatFeature.State(connection: conn)
    #expect(!state.hasQueuedWork)
    state.pendingSteerEntries = [
      uuid(0): QueuedPrompt(id: uuid(0), text: "steer me")
    ]
    #expect(state.hasQueuedWork)
  }
}
