import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ChatInteractionTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private let request = ApprovalRequest(command: "rm -rf /tmp/x", detail: "Delete /tmp/x")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func readyState() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live"
    return state
  }

  @Test func approvalRequestPinsCardAndBlocksComposer() async {
    var initial = readyState()
    initial.composerText = "hi"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }
    #expect(store.state.canSend) // composer usable before the request

    await store.send(.gatewayEvent(.approvalRequest(request))) {
      $0.pendingInteraction = .approval(self.request)
    }
    #expect(!store.state.canSend) // blocked while a request is pending
  }

  @Test func approveClearsAppendsAndSends() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["resolved": .number(1)])
      }
    }

    await store.send(.respondToApproval(approve: true, all: false)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Approved"))]
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "approval.respond")
    // Approvals are session-queue-resolved: no request_id is sent.
    #expect(sent.value?["params"]?["request_id"] == nil)
    #expect(sent.value?["params"]?["choice"]?.stringValue == "once")
    #expect(sent.value?["params"]?["all"]?.boolValue == false)
  }

  @Test func approveAllSendsAllTrue() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        return .object(["resolved": .number(3)])
      }
    }

    await store.send(.respondToApproval(approve: true, all: true)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Approved"))]
    }
    await store.finish()

    #expect(sent.value?["all"]?.boolValue == true)
    // "Approve all in this session" persists the pattern for the session.
    #expect(sent.value?["choice"]?.stringValue == "session")
  }

  @Test func denySendsDenyChoice() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        return .object([:])
      }
    }

    await store.send(.respondToApproval(approve: false, all: false)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Denied"))]
    }
    await store.finish()

    #expect(sent.value?["choice"]?.stringValue == "deny")
  }

  // MARK: Model / reasoning picker (Task 7)

  private func sampleOptions() -> ModelOptions {
    ModelOptions(
      providers: [.init(name: "Anthropic", slug: "anthropic", models: ["claude-opus-4-8", "claude-sonnet-4-6"], authenticated: true)],
      currentModel: "claude-opus-4-8"
    )
  }

  @Test func modelChipTappedLoadsOptions() async {
    let store = TestStore(initialState: readyState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        .object([
          "providers": .array([.object([
            "name": .string("Anthropic"), "slug": .string("anthropic"),
            "models": .array([.string("claude-opus-4-8"), .string("claude-sonnet-4-6")]),
            "authenticated": .bool(true),
          ])]),
          "model": .string("claude-opus-4-8"),
        ])
      }
    }

    await store.send(.modelChipTapped) {
      $0.modelPicker = ChatFeature.State.ModelPicker(isLoading: true)
    }
    await store.receive(\.modelOptionsResponse.success) {
      $0.modelPicker?.isLoading = false
      $0.modelPicker?.options = self.sampleOptions()
    }
  }

  @Test func selectingModelSendsConfigSet() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.modelPicker = ChatFeature.State.ModelPicker(isLoading: false, options: sampleOptions())
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object([:])
      }
    }

    await store.send(.modelSelected("claude-sonnet-4-6")) {
      $0.model = "claude-sonnet-4-6" // optimistic
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "config.set")
    #expect(sent.value?["params"]?["key"]?.stringValue == "model")
    #expect(sent.value?["params"]?["value"]?.stringValue == "claude-sonnet-4-6")
    #expect(sent.value?["params"]?["session_id"]?.stringValue == "live")
  }

  @Test func selectingReasoningSendsConfigSet() async {
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: readyState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        return .object([:])
      }
    }

    await store.send(.reasoningSelected("high")) {
      $0.reasoningEffort = "high"
    }
    await store.finish()

    #expect(sent.value?["key"]?.stringValue == "reasoning")
    #expect(sent.value?["value"]?.stringValue == "high")
  }

  @Test func selectionIsBlockedWhileSending() async {
    var initial = readyState()
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    // Mid-turn switches are rejected by the server (4009) — guarded client-side.
    await store.send(.modelSelected("claude-sonnet-4-6"))
    await store.send(.reasoningSelected("high"))
  }

  // MARK: Rename via gateway session.title (Task 4)

  @Test func renameSuccessOptimisticAndSendsTitleRPC() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.title = "Old title"
    initial.errorBanner = "Stale error" // a prior error must be cleared on a fresh rename
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["pending": .bool(true), "title": .string("New title")])
      }
    }

    await store.send(.renameButtonTapped) {
      $0.renameDraft = "Old title" // pre-filled with current title
    }
    // The bound TextField edit reaches state.renameDraft.
    await store.send(.binding(.set(\.renameDraft, "New title"))) {
      $0.renameDraft = "New title"
    }
    await store.send(.confirmRename) {
      $0.title = "New title" // optimistic
      $0.renameDraft = nil
      $0.errorBanner = nil // cleared on a fresh rename attempt
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "session.title")
    #expect(sent.value?["params"]?["session_id"]?.stringValue == "live")
    #expect(sent.value?["params"]?["title"]?.stringValue == "New title")
    #expect(store.state.title == "New title") // no rollback
  }

  @Test func renameEmptyDraftIsNoOpAndDoesNotSend() async {
    // The gateway rejects an empty title (server 4021), so an empty/whitespace draft must
    // just close the alert with no RPC — never round-trip to an error + rollback.
    let sent = LockIsolated(false)
    var initial = readyState()
    initial.title = "Old title"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        sent.setValue(true)
        return .object([:])
      }
    }

    await store.send(.renameButtonTapped) {
      $0.renameDraft = "Old title"
    }
    await store.send(.binding(.set(\.renameDraft, "   "))) {
      $0.renameDraft = "   "
    }
    await store.send(.confirmRename) {
      $0.renameDraft = nil // alert closes
      // title unchanged, no errorBanner
    }
    await store.finish()

    #expect(sent.value == false) // no RPC was sent
    #expect(store.state.title == "Old title") // untouched
    #expect(store.state.errorBanner == nil)
  }

  @Test func confirmRenameWithoutLiveSessionIsNoOp() async {
    // No live session id → confirmRename can't send; it just closes the alert.
    let sent = LockIsolated(false)
    var initial = ChatFeature.State(connection: conn) // liveSessionID == nil
    initial.title = "Old title"
    initial.renameDraft = "New title"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        sent.setValue(true)
        return .object([:])
      }
    }

    await store.send(.confirmRename) {
      $0.renameDraft = nil
    }
    await store.finish()

    #expect(sent.value == false)
    #expect(store.state.title == "Old title")
  }

  @Test func renameFailureRollsBackAndSetsErrorBanner() async {
    var initial = readyState()
    initial.title = "Old title"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        throw GatewayError.server("Title too long")
      }
    }

    await store.send(.renameButtonTapped) {
      $0.renameDraft = "Old title"
    }
    await store.send(.binding(.set(\.renameDraft, "Bad title"))) {
      $0.renameDraft = "Bad title"
    }
    await store.send(.confirmRename) {
      $0.title = "Bad title" // optimistic
      $0.renameDraft = nil
    }
    await store.receive(\.renameFailed) {
      $0.title = "Old title" // rolled back
      $0.errorBanner = "Couldn’t rename the session."
    }
  }

  // MARK: Prompt submit failure (Task 7, Issue #6)

  @Test func promptSubmitFailureSurfacesBannerAndClearsSpinner() async {
    var initial = readyState()
    initial.composerText = "hello"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      // A stuck server: prompt.submit times out (Task 6's per-request timeout).
      $0.hermesGateway.send = { @Sendable _, _ in
        throw GatewayError.timedOut(method: "prompt.submit")
      }
    }

    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "hello", isComplete: true))]
      $0.composerText = ""
      $0.errorBanner = nil
      $0.isSending = true // optimistic; cleared when the failure arrives
    }
    await store.receive(\.promptSubmitFailed) {
      $0.errorBanner = "Prompt failed: request timed out: prompt.submit"
      $0.isSending = false
    }
  }

  struct PlainError: Error {}

  @Test func promptSubmitNonGatewayErrorFallsBackToDisconnectedMessage() async {
    // A non-GatewayError throw (e.g. an encoding/transport failure) takes the fallback arm,
    // surfacing GatewayError.disconnected.message ("Connection lost.").
    var initial = readyState()
    initial.composerText = "hello"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable _, _ in throw PlainError() }
    }

    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "hello", isComplete: true))]
      $0.composerText = ""
      $0.errorBanner = nil
      $0.isSending = true
    }
    await store.receive(\.promptSubmitFailed) {
      $0.errorBanner = "Prompt failed: Connection lost."
      $0.isSending = false
    }
  }

  // Interrupting mid-turn freezes the live thinking row (bakes the elapsed, isComplete=true)
  // and cancels the timer (no further ticks; TestStore fails on a leaked effect) while still
  // firing session.interrupt.
  @Test func interruptFreezesThinkingRowAndCancelsTimer() async {
    let clock = TestClock()
    let sent = LockIsolated<String?>(nil)
    let store = TestStore(initialState: readyState()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, _ in
        sent.setValue(method)
        return .object([:])
      }
    }
    // The chat persists a debounced snapshot as it updates; we don't assert its contents
    // here (covered by HydrateTests), so let the write-back tick pass non-exhaustively.
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = self.uuid(0)
    }
    await store.send(.gatewayEvent(.thinkingDelta(text: "Pondering"))) {
      $0.transcript[id: self.uuid(0)]?.kind = .thinking(reasoning: "Pondering", status: nil, elapsedSeconds: 0, isComplete: false)
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 2 }

    // Interrupt: the row freezes (2s baked in, isComplete=true), the timer is cancelled, and
    // session.interrupt is dispatched. A leaked tick loop would fail the test.
    await store.send(.interruptTapped) {
      $0.isSending = false
      $0.transcript[id: self.uuid(0)]?.kind = .thinking(reasoning: "Pondering", status: nil, elapsedSeconds: 2, isComplete: true)
      $0.thinkingRowID = nil
      $0.thinkingSeconds = 0
    }
    await clock.advance(by: .seconds(5)) // no further ticks — timer was cancelled
    await store.finish()
    #expect(sent.value == "session.interrupt")
  }
}
