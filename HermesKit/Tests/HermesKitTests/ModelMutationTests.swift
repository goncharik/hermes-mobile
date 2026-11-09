import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// #157: a canonical session-authority host (`gateway.ready.session_authority: true`, Hermes
/// v0.22.3+) refuses `config.set model` with `use_session_mutation_model`. The pick there is
/// the revision-fenced `session.mutate {operation: "model"}`; a legacy host keeps `config.set`.
@MainActor
struct ModelMutationTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  private func options() -> ModelOptions {
    ModelOptions(
      providers: [.init(name: "Anthropic", slug: "anthropic", models: ["claude-opus-4-8", "claude-sonnet-4-6"], authenticated: true)],
      currentModel: "claude-opus-4-8"
    )
  }

  private func pickerState(authority: Bool, fences: SessionFences? = nil) -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live"
    state.storedSessionID = "stored"
    state.model = "claude-opus-4-8"
    state.isSessionAuthority = authority
    state.sessionFences = fences
    state.modelPicker = ModelPickerFeature.State(sessionID: "live", options: options())
    return state
  }

  private struct Call: Equatable { let method: String; let params: JSONValue }

  private func makeStore(
    _ initial: ChatFeature.State, calls: LockIsolated<[Call]>,
    reply: @escaping @Sendable (String, JSONValue, Int) throws -> JSONValue
  ) -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        let n = calls.withValue { $0.append(Call(method: method, params: params)); return $0.count }
        return try reply(method, params, n)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  private func pick(_ store: TestStoreOf<ChatFeature>, _ model: String = "claude-sonnet-4-6") async {
    await store.send(.modelPicker(.presented(.modelRowTapped(model: model, providerSlug: "anthropic"))))
    await store.finish()
    // Non-exhaustive: fold the effect's actions into `store.state` before asserting on it.
    await store.skipReceivedActions(strict: false)
  }

  private nonisolated static func resume(revision: Int, generation: Int) -> JSONValue {
    .object([
      "session_id": .string("live"), "stored_session_id": .string("live"), "messages": .array([]),
      "running": .bool(false), "revision": .number(Double(revision)),
      "execution_generation": .number(Double(generation)),
    ])
  }

  private nonisolated static func receipt(revision: Int, generation: Int) -> JSONValue {
    .object([
      "session_id": .string("live"), "operation": .string("model"), "model": .string("claude-sonnet-4-6"),
      "revision": .number(Double(revision)), "execution_generation": .number(Double(generation)),
    ])
  }

  @Test func legacyHostStillSendsConfigSet() async {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(pickerState(authority: false), calls: calls) { _, _, _ in .object([:]) }

    await pick(store)

    #expect(calls.value.map(\.method) == ["config.set"])
  }

  @Test func authorityHostSendsAFencedSessionMutate() async throws {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(
      pickerState(authority: true, fences: .init(revision: 7, generation: 3)), calls: calls
    ) { _, _, _ in Self.receipt(revision: 8, generation: 3) }

    await pick(store)

    #expect(calls.value.map(\.method) == ["session.mutate"])
    let params = try #require(calls.value.first?.params)
    #expect(params["session_id"]?.stringValue == "live")
    #expect(params["operation"]?.stringValue == "model")
    #expect(params["expected_revision"]?.intValue == 7)
    #expect(params["expected_generation"]?.intValue == 3)
    #expect(params["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
    #expect(params["payload"] == .object(["model": .string("claude-sonnet-4-6"), "provider": .string("anthropic")]))
    // The receipt's revision is adopted for the next mutation; nothing rolled back.
    #expect(store.state.sessionFences == SessionFences(revision: 8, generation: 3))
    #expect(store.state.model == "claude-sonnet-4-6")
    #expect(store.state.errorBanner == nil)
  }

  @Test func unknownFencesAreReadWithAMessagelessResumeFirst() async throws {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(pickerState(authority: true), calls: calls) { method, _, _ in
      method == "session.resume" ? Self.resume(revision: 4, generation: 2) : Self.receipt(revision: 5, generation: 2)
    }

    await pick(store)

    #expect(calls.value.map(\.method) == ["session.resume", "session.mutate"])
    #expect(calls.value[0].params["omit_messages"] == .bool(true))
    #expect(calls.value[1].params["expected_revision"]?.intValue == 4)
    #expect(calls.value[1].params["expected_generation"]?.intValue == 2)
  }

  @Test func staleFenceRereadsAndRetriesOnceWithANewRequestID() async throws {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(
      pickerState(authority: true, fences: .init(revision: 1, generation: 1)), calls: calls
    ) { method, _, n in
      if method == "session.resume" { return Self.resume(revision: 9, generation: 4) }
      if n == 1 { throw GatewayError.server("revision_conflict") }
      return Self.receipt(revision: 10, generation: 4)
    }

    await pick(store)

    #expect(calls.value.map(\.method) == ["session.mutate", "session.resume", "session.mutate"])
    #expect(calls.value[2].params["expected_revision"]?.intValue == 9)
    #expect(calls.value[2].params["request_id"] != calls.value[0].params["request_id"])
    #expect(store.state.errorBanner == nil)
  }

  /// A newer pick cancels the older effect, but the older pick's in-flight `session.mutate`
  /// can't observe that: when it comes back stale it must NOT re-read and retry its way past the
  /// newer pick (Codex review on #163).
  @Test func supersededPickNeverRetriesAfterAStaleFence() async throws {
    let calls = LockIsolated<[Call]>([])
    let store = TestStore(
      initialState: pickerState(authority: true, fences: .init(revision: 1, generation: 1))
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        let n = calls.withValue { $0.append(Call(method: method, params: params)); return $0.count }
        if n == 1 {
          // The first pick's write is in flight; cancellation wakes this sleep, and the
          // server's (late) answer is a stale fence.
          try? await Task.sleep(for: .seconds(30))
          throw GatewayError.server("revision_conflict")
        }
        return Self.receipt(revision: 2, generation: 1)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.modelPicker(.presented(.modelRowTapped(model: "claude-sonnet-4-6", providerSlug: "anthropic"))))
    while calls.value.isEmpty { await Task.yield() }
    await store.send(.modelPicker(.presented(.modelRowTapped(model: "claude-opus-4-8", providerSlug: "anthropic"))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    let mutates = calls.value.filter { $0.method == "session.mutate" }
    #expect(calls.value.map(\.method) == ["session.mutate", "session.mutate"])
    #expect(mutates.last?.params["payload"]?["model"]?.stringValue == "claude-opus-4-8")
    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.errorBanner == nil)
  }

  @Test func refusedPickRollsBackAndBanners() async {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(
      pickerState(authority: true, fences: .init(revision: 1, generation: 1)), calls: calls
    ) { _, _, _ in throw GatewayError.server("permission_denied") }

    await pick(store)

    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.errorBanner == "Couldn’t change model: permission_denied")
    #expect(store.state.modelPicker?.applyError == "Couldn’t change model: permission_denied")
  }

  @Test func guardedSwitchAsksAndTheSamePickConfirmsWithTheToken() async throws {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(
      pickerState(authority: true, fences: .init(revision: 1, generation: 1)), calls: calls
    ) { _, params, _ in
      if params["payload"]?["confirm"] == nil {
        return .object([
          "session_id": .string("live"), "operation": .string("model"),
          "status": .string("confirmation_required"), "confirm_required": .bool(true),
          "confirm": .string("tok-1"), "confirm_message": .string("This model costs more."),
        ])
      }
      return Self.receipt(revision: 2, generation: 1)
    }

    await pick(store)
    // Nothing applied: rolled back, and the user is told how to proceed.
    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.errorBanner == "This model costs more. Tap claude-sonnet-4-6 again to switch anyway.")

    await pick(store)
    #expect(calls.value.count == 2)
    #expect(calls.value[1].params["payload"]?["confirm"]?.stringValue == "tok-1")
    #expect(store.state.model == "claude-sonnet-4-6")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.pendingModelConfirmation == nil)
  }

  @Test func aConfirmationTokenNeverRidesADifferentPick() async throws {
    let calls = LockIsolated<[Call]>([])
    var initial = pickerState(authority: true, fences: .init(revision: 1, generation: 1))
    initial.pendingModelConfirmation = .init(model: "claude-sonnet-4-6", provider: "anthropic", token: "tok-1")
    let store = makeStore(initial, calls: calls) { _, _, _ in Self.receipt(revision: 2, generation: 1) }

    await pick(store, "claude-opus-4-8")

    #expect(calls.value.first?.params["payload"]?["confirm"] == nil)
    #expect(store.state.pendingModelConfirmation == nil)
  }

  @Test func sessionInfoFencesAreAdoptedMonotonically() async {
    let store = makeStore(
      pickerState(authority: true, fences: .init(revision: 5, generation: 2)), calls: .init([])
    ) { _, _, _ in .object([:]) }

    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(revision: 6, executionGeneration: 3))))
    #expect(store.state.sessionFences == SessionFences(revision: 6, generation: 3))
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(revision: 4, executionGeneration: 1))))
    #expect(store.state.sessionFences == SessionFences(revision: 6, generation: 3))
  }

  @Test func snapshotDecodesItsFences() throws {
    let json = #"{"session_id":"s","stored_session_id":"s","messages":[],"revision":12,"execution_generation":5}"#
    let response = try JSONDecoder().decode(ActivateResponse.self, from: Data(json.utf8))
    #expect(response.fences == SessionFences(revision: 12, generation: 5))
    let legacy = try JSONDecoder().decode(ActivateResponse.self, from: Data(#"{"session_id":"s"}"#.utf8))
    #expect(legacy.fences == nil)
  }
}
