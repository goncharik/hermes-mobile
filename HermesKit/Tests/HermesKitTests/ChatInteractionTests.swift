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
      // Every presentation bumps the token — it is the card's identity in `ChatView`, so a
      // replacement always gets fresh `@State` (toggle off, command scrolled to the top).
      $0.pendingInteractionToken = 1
    }
    #expect(!store.state.canSend) // blocked while a request is pending
  }

  /// The identity has to survive the one case a value-derived `.id` cannot: a queued approval
  /// that is **equal** to the one it replaces (an agent retrying the same command), which
  /// overwrites without passing through `nil`. Only a monotonic token tells them apart.
  @Test func repeatedIdenticalApprovalStillBumpsTheIdentityToken() async {
    let store = TestStore(initialState: readyState()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.gatewayEvent(.approvalRequest(request))) {
      $0.pendingInteraction = .approval(self.request)
      $0.pendingInteractionToken = 1
    }
    // Byte-identical request, no response in between: `pendingInteraction` does not change…
    await store.send(.gatewayEvent(.approvalRequest(request))) {
      $0.pendingInteractionToken = 2 // …but the card's identity must
    }
  }

  @Test func approveClearsAppendsAndSends() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    // A lingering recovery hint (#30 workaround) is mooted by answering ANY approval —
    // it must not prime a later, unrelated hydrate to synthesize a phantom card.
    initial.expectsPendingApproval = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object(["resolved": .number(1)])
      }
    }

    await store.send(.respondToApproval(approve: true, all: false)) {
      $0.pendingInteraction = nil
      $0.expectsPendingApproval = false
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Approved"))]
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "approval.respond")
    // Approvals are session-queue-resolved: no request_id is sent.
    #expect(sent.value?["params"]?["request_id"] == nil)
    #expect(sent.value?["params"]?["choice"]?.stringValue == "once")
    #expect(sent.value?["params"]?["all"]?.boolValue == false)
    // resolved >= 1 → the optimistic row stays "Approved" (no feedback action fires —
    // an unasserted receive would fail this exhaustive store).
    #expect(store.state.transcript[id: uuid(0)]?.kind == .status(kind: "approval", text: "Approved"))
    #expect(store.state.errorBanner == nil)
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
    // A result with no "resolved" key (older agent) is lenient success: no feedback
    // action, the optimistic "Denied" row stands, no banner.
    #expect(store.state.transcript[id: uuid(0)]?.kind == .status(kind: "approval", text: "Denied"))
    #expect(store.state.errorBanner == nil)
  }

  // resolved == 0 → the server's per-session queue was already empty (handled on another
  // client / a recovered-card blind respond) — the optimistic row is patched honestly
  // instead of claiming a false "Approved".
  @Test func approveResolvedZeroPatchesRowToAlreadyHandled() async {
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable _, _ in
        .object(["resolved": .number(0)])
      }
    }

    await store.send(.respondToApproval(approve: true, all: false)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Approved"))]
    }
    await store.receive(\.approvalRespondResult) {
      $0.transcript[id: self.uuid(0)]?.kind = .status(kind: "approval", text: "Already handled elsewhere")
    }
    #expect(store.state.errorBanner == nil) // not an error — just honest feedback
  }

  // The acknowledged race: a hydrate replaced the transcript wholesale (deterministic
  // ids, server wins) before the resolved-0 feedback landed, so the optimistic row id no
  // longer exists. The patch must be a silent no-op — never a crash, never an append.
  @Test func approvalRespondResultForAbsentRowIsANoOp() async {
    let store = TestStore(initialState: readyState()) { ChatFeature() }

    // Exhaustive store, empty trailing closure: any state mutation would fail the test.
    await store.send(.approvalRespondResult(rowID: uuid(99), resolved: 0))
    #expect(store.state.transcript.isEmpty)
    #expect(store.state.errorBanner == nil)
  }

  // RPC failure → the card is already dismissed, so the failure surfaces as a banner
  // (no more silently-swallowed `try?`); the optimistic row is left as-is.
  @Test func approvalRespondFailureSetsErrorBanner() async {
    var initial = readyState()
    initial.pendingInteraction = .approval(request)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.hermesGateway.send = { @Sendable _, _ in
        throw GatewayError.timedOut(method: "approval.respond")
      }
    }

    await store.send(.respondToApproval(approve: true, all: false)) {
      $0.pendingInteraction = nil
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .status(kind: "approval", text: "Approved"))]
    }
    await store.receive(\.approvalRespondResult) {
      $0.errorBanner = "Failed to send the approval response."
    }
    // The row is untouched — whether the turn continues server-side is unknowable
    // offline; the banner is the honest signal.
    #expect(store.state.transcript[id: uuid(0)]?.kind == .status(kind: "approval", text: "Approved"))
  }

  // The "Approve all in this session" escalation is offered only when the card has real
  // content (a command or a danger pattern) — the push-tap-recovered request (#30
  // workaround) has neither, so a blind approve must not whitelist an unseen pattern.
  @Test func offersSessionApprovalIsContentDerived() {
    #expect(ChatFeature.recoveredApprovalRequest.offersSessionApproval == false)
    #expect(ApprovalRequest(detail: "detail only").offersSessionApproval == false)
    #expect(ApprovalRequest(command: "", patternKey: "").offersSessionApproval == false)
    #expect(ApprovalRequest(command: "rm -rf /tmp/x").offersSessionApproval)
    #expect(ApprovalRequest(patternKey: "rm").offersSessionApproval)
    #expect(ApprovalRequest(patternKeys: ["rm"]).offersSessionApproval)
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

    await store.send(.modelSelected(model: "claude-sonnet-4-6", provider: "anthropic")) {
      $0.model = "claude-sonnet-4-6" // optimistic
      $0.pendingConfigRollback.updateValue(nil, forKey: "model") // nothing confirmed yet
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "config.set")
    #expect(sent.value?["params"]?["key"]?.stringValue == "model")
    // Desktop parity: the value carries the picker section's provider slug so the
    // gateway routes the model to the provider the picker showed it under.
    #expect(sent.value?["params"]?["value"]?.stringValue == "claude-sonnet-4-6 --provider anthropic")
    #expect(sent.value?["params"]?["session_id"]?.stringValue == "live")
  }

  /// A selection with no section context (nil provider) stays a bare model id on the wire —
  /// the gateway's own detection ladder routes it exactly as before this change.
  @Test func selectingModelWithoutProviderSendsBareModel() async {
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: readyState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object([:])
      }
    }

    await store.send(.modelSelected(model: "claude-sonnet-4-6", provider: nil)) {
      $0.model = "claude-sonnet-4-6"
      $0.pendingConfigRollback.updateValue(nil, forKey: "model")
    }
    await store.finish()

    #expect(sent.value?["method"]?.stringValue == "config.set")
    #expect(sent.value?["params"]?["value"]?.stringValue == "claude-sonnet-4-6")
  }

  /// `selectionSlug` passes the slug only — the gateway's flag parser splits values on
  /// whitespace and its provider resolver never matches display names, so a name fallback
  /// ("Ollama Cloud") would misparse. Nil only when there is no slug.
  @Test func providerSelectionSlugPreference() {
    let slugful = ModelOptions.Provider(name: "OpenRouter", slug: "openrouter", models: ["openai/gpt-5.6-sol"])
    #expect(slugful.selectionSlug == "openrouter")

    // No slug: the display name must NOT leak onto the wire ("Ollama Cloud" would parse
    // as provider `Ollama`, model `… Cloud`); the pick goes out bare instead.
    let slugless = ModelOptions.Provider(name: "Anthropic", slug: nil, models: ["claude-opus-4-8"])
    #expect(slugless.selectionSlug == nil)

    let empty = ModelOptions.Provider(name: "", slug: nil, models: [])
    #expect(empty.selectionSlug == nil)

    let whitespace = ModelOptions.Provider(name: "  ", slug: "  ", models: [])
    #expect(whitespace.selectionSlug == nil)
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
      $0.pendingConfigRollback.updateValue(nil, forKey: "reasoning")
    }
    await store.finish()

    #expect(sent.value?["key"]?.stringValue == "reasoning")
    #expect(sent.value?["value"]?.stringValue == "high")
  }

  /// The full-ladder acceptance path (#81): `max` goes out on the wire, the chip takes it
  /// optimistically, and the authoritative `session.info` the server emits after a successful
  /// `config.set` echoes it — so the selection survives the hydrate rather than snapping back.
  @Test func selectingMaxSendsItAndSurvivesTheEchoingSessionInfo() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = readyState()
    initial.reasoningEffort = "medium"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        return .object([:])
      }
    }

    await store.send(.reasoningSelected("max")) {
      $0.reasoningEffort = "max" // optimistic
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
    }
    await store.finish() // no `.configSetFailed`: nothing to roll back

    #expect(sent.value?["key"]?.stringValue == "reasoning")
    #expect(sent.value?["value"]?.stringValue == "max")
    #expect(ModelOptions.offeredEfforts(extendedSupported: store.state.extendedReasoningSupported)
      .contains("max"))

    // Server-authoritative echo — the chip stays on `max`.
    store.exhaustivity = .off(showSkippedAssertions: false) // the snapshot-persist debounce
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(reasoningEffort: "max"))))
    await store.finish()
    #expect(store.state.reasoningEffort == "max")
  }

  /// The latch is per chat slot and unpersisted, so a fresh chat re-offers `max`/`ultra` —
  /// that is the whole recovery story for an agent upgrade (no probe, no reset action).
  @Test func freshSlotReOffersTheExtendedLevels() {
    let fresh = ChatFeature.State(connection: conn)
    #expect(fresh.extendedReasoningSupported)
    #expect(ModelOptions.offeredEfforts(extendedSupported: fresh.extendedReasoningSupported)
      == ModelOptions.reasoningEfforts)
  }

  @Test func selectionIsBlockedWhileSending() async {
    var initial = readyState()
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    // Mid-turn switches are rejected by the server (4009) — guarded client-side.
    await store.send(.modelSelected(model: "claude-sonnet-4-6", provider: nil))
    await store.send(.reasoningSelected("high"))
  }

  // MARK: config.set failures — rollback, latch, banner (#81)

  /// A chat whose model + effort are already known, so a rollback has something to restore.
  private func configuredState() -> ChatFeature.State {
    var state = readyState()
    state.model = "gpt-5"
    state.reasoningEffort = "medium"
    return state
  }

  /// A gateway stub whose `config.set` always throws `error` (everything else succeeds).
  private func failingConfigSet(_ error: any Error) -> @Sendable (String, JSONValue) async throws -> JSONValue {
    { @Sendable method, _ in
      if method == "config.set" { throw error }
      return .object([:])
    }
  }

  /// The 4002 verdict is the ONE capability statement: roll back, banner naming the level, and
  /// latch `max`/`ultra` off for the rest of the slot.
  @Test func rejectedExtendedReasoningRollsBackAndLatches() async {
    let store = TestStore(initialState: configuredState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = failingConfigSet(GatewayError.server("unknown reasoning value: max"))
    }

    await store.send(.reasoningSelected("max")) {
      $0.reasoningEffort = "max" // optimistic
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
    }
    await store.receive(\.configSetFailed) {
      $0.reasoningEffort = "medium" // rolled back
      $0.pendingConfigRollback.removeValue(forKey: "reasoning")
      $0.extendedReasoningSupported = false
      $0.errorBanner = "This agent doesn’t support \"max\" reasoning."
    }
    await store.finish()
  }

  /// A transport failure is NOT a capability verdict (#62 logic) — roll back and banner, but the
  /// levels stay on offer.
  @Test func timedOutReasoningSelectionRollsBackWithoutLatching() async {
    let store = TestStore(initialState: configuredState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = failingConfigSet(GatewayError.timedOut(method: "config.set"))
    }

    await store.send(.reasoningSelected("max")) {
      $0.reasoningEffort = "max"
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
    }
    await store.receive(\.configSetFailed) {
      $0.reasoningEffort = "medium"
      $0.pendingConfigRollback.removeValue(forKey: "reasoning")
      $0.errorBanner = "Couldn’t change reasoning: \(GatewayError.timedOut(method: "config.set").message)"
    }
    await store.finish()
    #expect(store.state.extendedReasoningSupported)
  }

  /// Any other server error on the reasoning key surfaces but never latches.
  @Test func otherServerErrorOnReasoningDoesNotLatch() async {
    let store = TestStore(initialState: configuredState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = failingConfigSet(GatewayError.server("some other error"))
    }

    await store.send(.reasoningSelected("high")) {
      $0.reasoningEffort = "high"
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
    }
    await store.receive(\.configSetFailed) {
      $0.reasoningEffort = "medium"
      $0.pendingConfigRollback.removeValue(forKey: "reasoning")
      $0.errorBanner = "Couldn’t change reasoning: some other error"
    }
    await store.finish()
    #expect(store.state.extendedReasoningSupported)
  }

  /// One failure path serves both keys: a rejected model switch rolls the chip back too.
  @Test func rejectedModelSwitchRollsBackAndBanners() async {
    let store = TestStore(initialState: configuredState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = failingConfigSet(GatewayError.server("cannot switch mid-turn"))
    }

    await store.send(.modelSelected(model: "gpt-5-mini", provider: "openai")) {
      $0.model = "gpt-5-mini"
      $0.pendingConfigRollback.updateValue("gpt-5", forKey: "model")
    }
    await store.receive(\.configSetFailed) {
      $0.model = "gpt-5"
      $0.pendingConfigRollback.removeValue(forKey: "model")
      $0.errorBanner = "Couldn’t change model: cannot switch mid-turn"
    }
    await store.finish()
    #expect(store.state.extendedReasoningSupported)
  }

  private struct UnexpectedFailure: Error {}

  /// A non-`GatewayError` throw maps to `.disconnected`, same fallback as `model.options`.
  @Test func nonGatewayErrorMapsToDisconnected() async {
    let store = TestStore(initialState: configuredState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = failingConfigSet(UnexpectedFailure())
    }

    await store.send(.reasoningSelected("high")) {
      $0.reasoningEffort = "high"
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
    }
    await store.receive(\.configSetFailed) {
      $0.reasoningEffort = "medium"
      $0.pendingConfigRollback.removeValue(forKey: "reasoning")
      $0.errorBanner = "Couldn’t change reasoning: \(GatewayError.disconnected.message)"
    }
    await store.finish()
    #expect(store.state.extendedReasoningSupported)
  }

  /// Two picks in a row: the FIRST one's late rejection must not clobber the second's value.
  /// The newer `config.set` cancels the in-flight older one, so it never reaches
  /// `.configSetFailed` — no rollback, no banner, and (worst case, since this stub answers the
  /// 4002 verdict) no latch either.
  @Test func supersededConfigSetFailureCannotClobberTheNewerPick() async {
    let clock = TestClock()
    var initial = configuredState()
    initial.modelPicker = ChatFeature.State.ModelPicker(isLoading: false)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        guard method == "config.set" else { return .object([:]) }
        if params["value"]?.stringValue == "max" {
          try await clock.sleep(for: .seconds(1)) // answers only after the second pick
          throw GatewayError.server("unknown reasoning value: max")
        }
        return .object([:])
      }
    }

    await store.send(.reasoningSelected("max")) {
      $0.reasoningEffort = "max"
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
    }
    // The second pick keeps the FIRST one's rollback target: "max" was never confirmed.
    await store.send(.reasoningSelected("xhigh")) { $0.reasoningEffort = "xhigh" }
    await clock.advance(by: .seconds(1))
    await store.finish()

    #expect(store.state.reasoningEffort == "xhigh")
    #expect(store.state.extendedReasoningSupported)
    #expect(store.state.errorBanner == nil)
    #expect(store.state.modelPicker?.applyError == nil)
  }

  /// The supersession's other half: when the SECOND pick is the one that fails, the rollback
  /// target is the last SERVER-confirmed value ("medium") — never the first pick's optimistic
  /// "max", which the server never accepted (its request was cancelled).
  @Test func supersededPickIsNotTheRollbackTargetForTheNewerFailure() async {
    let clock = TestClock()
    var initial = configuredState()
    initial.modelPicker = ChatFeature.State.ModelPicker(isLoading: false)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        guard method == "config.set" else { return .object([:]) }
        if params["value"]?.stringValue == "max" {
          try await clock.sleep(for: .seconds(1)) // never answers before it's cancelled
          return .object([:])
        }
        throw GatewayError.server("cannot switch mid-turn")
      }
    }

    await store.send(.reasoningSelected("max")) {
      $0.reasoningEffort = "max"
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
    }
    await store.send(.reasoningSelected("xhigh")) { $0.reasoningEffort = "xhigh" }
    await store.receive(\.configSetFailed) {
      $0.reasoningEffort = "medium" // NOT "max"
      $0.pendingConfigRollback.removeValue(forKey: "reasoning")
      $0.errorBanner = "Couldn’t change reasoning: cannot switch mid-turn"
      $0.modelPicker?.applyError = "Couldn’t change reasoning: cannot switch mid-turn"
    }
    await clock.advance(by: .seconds(1))
    await store.finish()
  }

  /// An authoritative `session.info` is what CONFIRMS a key: it drops the rollback target, so the
  /// next pick captures the server's own value instead of an older one.
  @Test func sessionInfoConfirmationResetsTheRollbackTarget() async {
    let failing = LockIsolated(false)
    let store = TestStore(initialState: configuredState()) { ChatFeature() } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "config.set", failing.value { throw GatewayError.server("busy") }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false) // the snapshot-persist debounce

    await store.send(.reasoningSelected("high")) // accepted; rollback target is "medium"
    await store.finish()
    #expect(store.state.pendingConfigRollback["reasoning"] == .some("medium"))

    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(reasoningEffort: "high"))))
    #expect(store.state.pendingConfigRollback["reasoning"] == nil) // confirmed, entry dropped

    failing.setValue(true)
    await store.send(.reasoningSelected("max"))
    await store.receive(\.configSetFailed)
    await store.finish()
    #expect(store.state.reasoningEffort == "high") // the confirmed value, not the pre-info one
  }

  /// The rejection is mirrored inline into the open sheet (`errorBanner` alone sits behind the
  /// modal), and a new pick clears both — nothing else does: a successful `config.set` has no
  /// action and `session.info` leaves the banner alone, so a retry would read under the stale one.
  @Test func aNewSelectionClearsThePreviousConfigError() async {
    var initial = configuredState()
    initial.modelPicker = ChatFeature.State.ModelPicker(isLoading: false)
    let failing = LockIsolated(true)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "config.set", failing.value { throw GatewayError.server("busy") }
        return .object([:])
      }
    }

    await store.send(.reasoningSelected("high")) {
      $0.reasoningEffort = "high"
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
    }
    await store.receive(\.configSetFailed) {
      $0.reasoningEffort = "medium"
      $0.pendingConfigRollback.removeValue(forKey: "reasoning")
      $0.errorBanner = "Couldn’t change reasoning: busy"
      $0.modelPicker?.applyError = "Couldn’t change reasoning: busy"
    }

    failing.setValue(false)
    await store.send(.reasoningSelected("high")) {
      $0.reasoningEffort = "high"
      $0.pendingConfigRollback.updateValue("medium", forKey: "reasoning")
      $0.errorBanner = nil
      $0.modelPicker?.applyError = nil
    }
    await store.finish()
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
    // Client-side turn end → the slot-teardown/glow delegate fires (no server event follows).
    await store.receive(\.delegate.runningChanged)
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
    // Client-side turn end → the slot-teardown/glow delegate fires (no server event follows).
    await store.receive(\.delegate.runningChanged)
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

  // MARK: Copy session ID (transient toast)

  // The stored id is the session key the rest of the app addresses this chat by, so it
  // wins over the live id — copying must hand out that same key.
  @Test func copySessionIDCopiesTheSessionKeyAndAutoDismissesToast() async {
    let copied = LockIsolated<String?>(nil)
    let clock = TestClock()
    var initial = readyState()
    initial.storedSessionID = "20260724_abc"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
      $0.continuousClock = clock
    }

    await store.send(.copySessionIDTapped) { $0.copiedIDToastToken = 1 }

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copiedIDToastExpired) { $0.copiedIDToastToken = nil }
    // Asserted after the effects have been drained — `send` alone doesn't guarantee the
    // merged copy effect has run.
    #expect(copied.value == "20260724_abc")
  }

  // A brand-new chat whose `session.create` hasn't resolved has nothing to copy: no
  // pasteboard write, no toast, no effect to leak.
  @Test func copySessionIDWithoutASessionIsANoOp() async {
    let copied = LockIsolated<String?>(nil)
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
      $0.continuousClock = TestClock()
    }

    await store.send(.copySessionIDTapped) // no state change, no effect
    #expect(copied.value == nil)
    #expect(store.state.copiedIDToastToken == nil)
  }

  @Test func recopyingTheSessionIDWhileToastVisibleRestartsTheDwellTimer() async {
    let copied = LockIsolated<[String]>([])
    let clock = TestClock()
    let store = TestStore(initialState: readyState()) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.withValue { $0.append(text) } }
      $0.continuousClock = clock
    }

    await store.send(.copySessionIDTapped) { $0.copiedIDToastToken = 1 }
    await clock.advance(by: .seconds(1)) // first dwell is 2/3 elapsed…
    // …a second copy cancels it (cancelInFlight) so the toast does NOT dismiss early. The
    // token bumps even though the toast never hid — that bump is what the view turns into
    // a second VoiceOver announcement.
    await store.send(.copySessionIDTapped) { $0.copiedIDToastToken = 2 }
    await clock.advance(by: .seconds(1)) // past the first timer's deadline — still visible
    #expect(store.state.copiedIDToastToken == 2)

    await clock.advance(by: .seconds(0.5)) // completes the restarted dwell
    await store.receive(\.copiedIDToastExpired) { $0.copiedIDToastToken = nil }
    #expect(copied.value == ["live", "live"])
  }

  // `.teardown` deliberately does NOT cancel the toast dwell (it doesn't cancel the
  // code-block `copyFeedback` one either): a 1.5s timer that only clears a transient bool
  // isn't worth teardown bookkeeping, and `AppFeature`'s `ifLet` nil-out cancels it along
  // with everything else. Pinned here so the dangling-effect contract is explicit — the
  // TestStore would fail this test if the dwell were silently dropped OR left unresolved.
  @Test func tearingDownWhileTheToastIsUpLeavesTheDwellToFinish() async {
    let clock = TestClock()
    let store = TestStore(initialState: readyState()) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable _ in }
      $0.continuousClock = clock
    }

    await store.send(.copySessionIDTapped) { $0.copiedIDToastToken = 1 }
    await store.send(.teardown)

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copiedIDToastExpired) { $0.copiedIDToastToken = nil }
  }
}
