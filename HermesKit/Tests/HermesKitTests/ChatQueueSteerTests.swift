import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Steer now: a queued entry delivered INTO the running turn via `session.steer`. The entry
/// stays queued under `steeringEntryID` until the server answers; only `status == "queued"`
/// removes it.
@MainActor
struct ChatQueueSteerTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func runningState(_ entries: [QueuedPrompt]) -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live123"
    state.storedSessionID = "stored123"
    state.status = .ready
    state.isSending = true
    state.queuedPrompts = entries
    return state
  }

  private func makeStore(
    _ initial: ChatFeature.State,
    send: @escaping @Sendable (String, JSONValue) async throws -> JSONValue
  ) -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = send
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  /// Records every RPC method and answers `session.steer` with `steer`.
  private func recorder(
    _ calls: LockIsolated<[String]>, steer: @escaping @Sendable () throws -> JSONValue
  ) -> @Sendable (String, JSONValue) async throws -> JSONValue {
    { method, _ in
      calls.withValue { $0.append(method) }
      if method == "session.steer" { return try steer() }
      return .object(["status": .string("streaming")])
    }
  }

  // MARK: Accept / undelivered

  @Test func acceptedSteerLeavesTheQueueAndEchoesAUserRow() async {
    let calls = LockIsolated<[String]>([])
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "use tabs"), QueuedPrompt(id: uuid(91), text: "B")])
    initial.isQueueParked = true
    let store = makeStore(initial, send: recorder(calls) { .object(["status": .string("queued")]) })

    await store.send(.gatewayEvent(.messageDelta(text: "Writing spaces")))
    let streamingID = store.state.streamingRowID
    await store.send(.queuedPromptSteer(id: uuid(90))) {
      $0.steeringEntryID = self.uuid(90)
      $0.isQueueParked = false
    }
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.steeringEntryID == nil)
    #expect(store.state.queuedPrompts.map(\.text) == ["B"], "B waits for the turn end")
    #expect(!store.state.isQueueParked)
    // The streamed output is sealed above the correction; the next delta opens a new row.
    let rows = store.state.transcript.map(\.kind)
    #expect(rows == [
      .message(role: .assistant, text: "Writing spaces", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
    ])
    #expect(store.state.streamingRowID == nil)
    #expect(store.state.liveCommentaryRowIDs.contains(streamingID!))
    await store.send(.gatewayEvent(.messageDelta(text: "Switching to tabs")))
    #expect(store.state.transcript.count == 3)
    #expect(store.state.transcript.last?.kind == .message(role: .assistant, text: "Switching to tabs", isComplete: false))
    #expect(calls.value == ["session.steer"])
    await store.send(.teardown)
    await store.finish()
  }

  @Test func rejectedSteerKeepsTheEntryInPlaceUnparked() async {
    let calls = LockIsolated<[String]>([])
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "A"), QueuedPrompt(id: uuid(91), text: "B")])
    initial.isQueueParked = true
    let store = makeStore(initial, send: recorder(calls) { .object(["status": .string("rejected")]) })

    await store.send(.queuedPromptSteer(id: uuid(91)))
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.queuedPrompts.map(\.text) == ["A", "B"])
    #expect(!store.state.isQueueParked)
    #expect(store.state.steeringEntryID == nil)
    #expect(store.state.errorBanner == nil)
    #expect(store.state.transcript.isEmpty)
    await store.send(.teardown)
    await store.finish()
  }

  @Test(arguments: [
    JSONValue.object(["voice_stopped": .bool(true)]),
    .object([:]),
    .object(["status": .string("steered")]),
    .object(["status": .string("redirected")]),
    .null,
  ])
  func onlyQueuedStatusIsAcceptance(result: JSONValue) async {
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A")])) { method, _ in
      method == "session.steer" ? result : .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.queuedPrompts.map(\.text) == ["A"], "an unrecognised answer never drops the entry")
    #expect(store.state.steerSupported)
    #expect(store.state.transcript.isEmpty)
    await store.send(.teardown)
    await store.finish()
  }

  // MARK: Turn-end race

  @Test func turnEndDuringTheSteerHoldsTheDrainThenDrainsTheRejectedHeadFirst() async {
    let calls = LockIsolated<[String]>([])
    let submitted = LockIsolated<[String]>([])
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A"), QueuedPrompt(id: uuid(91), text: "B")])) {
      method, params in
      calls.withValue { $0.append(method) }
      if method == "session.steer" {
        for await _ in gate.stream { break }
        return .object(["status": .string("rejected")])
      }
      if method == "prompt.submit" { submitted.withValue { $0.append(params["text"]?.stringValue ?? "") } }
      return .object(["status": .string("streaming")])
    }

    await store.send(.queuedPromptSteer(id: uuid(90)))
    // The turn ends before the steer answers: the drain must not fire B past A.
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    #expect(store.state.drainingEntry == nil)
    #expect(store.state.queuedPrompts.map(\.text) == ["A", "B"])
    gate.continuation.yield()
    await store.receive(\.queuedPromptSteerResult)
    // `rejected` → A drains as the next prompt, B still waits behind it.
    #expect(store.state.drainingEntry?.text == "A")
    #expect(store.state.queuedPrompts.map(\.text) == ["B"])
    #expect(!store.state.isQueueParked)
    await store.send(.teardown)
    await store.finish()
    #expect(calls.value.first == "session.steer")
    #expect(submitted.value == ["A"])
  }

  // MARK: Drain after an accepted steer (PR #109 review)

  /// An accepted steer the turn ended before delivering becomes the SERVER's next turn right
  /// after `message.complete`, the edge the drain fires on. B's submit must carry `queued: true`
  /// so the busy path holds it instead of redirecting/interrupting that turn; the `queued`
  /// receipt consumes B (the server owns it) and nothing is re-parked or re-drained.
  @Test func drainAfterAnAcceptedSteerIsSentQueuedAndAHeldReceiptConsumesIt() async {
    let submits = LockIsolated<[JSONValue]>([])
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A"), QueuedPrompt(id: uuid(91), text: "B")])) {
      method, params in
      if method == "session.steer" { return .object(["status": .string("queued")]) }
      if method == "prompt.submit" {
        submits.withValue { $0.append(params) }
        // The server is already running A's follow-up turn: B is held for the one after.
        return .object(["status": .string("queued")])
      }
      return .object([:])
    }

    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.queuedPrompts.map(\.text) == ["B"])

    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    #expect(store.state.drainingEntry?.text == "B")
    await store.receive(\.drainedEntryHeld)

    #expect(submits.value.count == 1)
    #expect(submits.value.first?["text"]?.stringValue == "B")
    #expect(submits.value.first?["queued"] == .bool(true))
    #expect(store.state.drainingEntry == nil, "consumed: the server holds it")
    #expect(store.state.queuedPrompts.isEmpty)
    #expect(!store.state.isQueueParked)
    #expect(store.state.isSending, "a turn is running server-side")
    #expect(store.state.transcript.contains { $0.kind == .message(role: .user, text: "B", isComplete: true) })
    await store.send(.teardown)
    await store.finish()
  }

  /// A drain that starts the next turn as usual (`streaming`) is still flagged, and a composer
  /// submit never is: legacy frames stay byte-identical.
  @Test func onlyDrainSubmitsCarryQueued() async {
    let submits = LockIsolated<[JSONValue]>([])
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "B")])
    initial.composerText = "typed"
    let store = makeStore(initial) { method, params in
      if method == "prompt.submit" { submits.withValue { $0.append(params) } }
      return .object(["status": .string("streaming")])
    }
    // The running turn ends: B drains.
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.messageComplete(text: "done B", usage: nil)))
    // Idle: a plain composer send.
    await store.send(.composerSubmitted)
    await store.send(.teardown)
    await store.finish()

    #expect(submits.value.map { $0["text"]?.stringValue } == ["B", "typed"])
    #expect(submits.value[0]["queued"] == .bool(true))
    #expect(submits.value[1]["queued"] == nil)
  }

  // MARK: Capability

  @Test(arguments: ["unknown method: session.steer", "agent does not support steer"])
  func unsupportedFlipsTheFlagSilentlyAndKeepsTheEntry(message: String) async {
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "A")])
    initial.isQueueParked = true
    let store = makeStore(initial) { method, _ in
      if method == "session.steer" { throw GatewayError.server(message) }
      return .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult) {
      $0.steeringEntryID = nil
      $0.steerSupported = false
    }
    #expect(store.state.errorBanner == nil)
    #expect(store.state.queuedPrompts.map(\.text) == ["A"])
    #expect(!store.state.isQueueParked)
    #expect(!store.state.canSteerQueued, "the action hides")
    // A tap that slips through is a no-op.
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.send(.teardown)
    await store.finish()
  }

  @Test func otherFailureBannersAndKeepsTheEntry() async {
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A")])) { method, _ in
      if method == "session.steer" { throw GatewayError.server("steer failed: boom") }
      return .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.errorBanner == "Couldn't steer: steer failed: boom")
    #expect(store.state.queuedPrompts.map(\.text) == ["A"])
    #expect(store.state.steerSupported)
    await store.send(.teardown)
    await store.finish()
  }

  // MARK: Heal

  @Test func staleLiveIDHealsByResumingTheStoredSessionOnly() async {
    let calls = LockIsolated<[String]>([])
    let steerTargets = LockIsolated<[String]>([])
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A")])) { method, params in
      calls.withValue { $0.append(method) }
      switch method {
      case "session.steer":
        let target = params["session_id"]?.stringValue ?? ""
        steerTargets.withValue { $0.append(target) }
        if target == "live123" { throw GatewayError.server("session not found") }
        return .object(["status": .string("queued")])
      case "session.resume":
        steerTargets.withValue { $0.append("resume:" + (params["session_id"]?.stringValue ?? "")) }
        return .object(["session_id": .string("live456"), "resumed": .string("stored123")])
      default:
        return .object([:])
      }
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.liveSessionIDRefreshed)
    await store.receive(\.queuedPromptSteerResult)
    #expect(calls.value == ["session.steer", "session.resume", "session.steer"])
    #expect(steerTargets.value == ["live123", "resume:stored123", "live456"])
    #expect(store.state.liveSessionID == "live456")
    #expect(store.state.queuedPrompts.isEmpty)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func staleIDWithNoStoredIDIsUndeliveredNeverACreate() async {
    let calls = LockIsolated<[String]>([])
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "A")])
    initial.storedSessionID = nil
    initial.awaitsFirstPersist = true
    let store = makeStore(initial) { method, _ in
      calls.withValue { $0.append(method) }
      if method == "session.steer" { throw GatewayError.server("session not found") }
      return .object(["session_id": .string("fresh"), "stored_session_id": .string("fresh-stored")])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    #expect(calls.value == ["session.steer"])
    #expect(store.state.liveSessionID == "live123")
    #expect(store.state.queuedPrompts.map(\.text) == ["A"])
    #expect(store.state.errorBanner == nil)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func attachedBranchDoesNotHealEither() async {
    let calls = LockIsolated<[String]>([])
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "A")])
    initial.attachLiveSessionID = "live123"
    initial.branchSeed = ChatFeature.State.BranchSeed(text: "seed", parentSessionID: "parent")
    let store = makeStore(initial) { method, _ in
      calls.withValue { $0.append(method) }
      if method == "session.steer" { throw GatewayError.server("session not found") }
      return .object(["session_id": .string("fresh")])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    #expect(calls.value == ["session.steer"], "no resume, no seeded create")
    #expect(store.state.liveSessionID == "live123")
    #expect(store.state.queuedPrompts.map(\.text) == ["A"])
    await store.send(.teardown)
    await store.finish()
  }

  // MARK: Gates

  @Test func steerIsRefusedWithoutARunningTurnOrDuringASlashExec() async {
    var idle = runningState([QueuedPrompt(id: uuid(90), text: "A")])
    idle.isSending = false
    #expect(!idle.canSteerQueued)
    var slash = runningState([QueuedPrompt(id: uuid(90), text: "A")])
    slash.slashExecInFlight = true
    #expect(!slash.canSteerQueued)
    var card = runningState([QueuedPrompt(id: uuid(90), text: "A")])
    card.present(.approval(ApprovalRequest(command: "rm -rf /tmp/x")))
    #expect(!card.canSteerQueued)
    #expect(runningState([]).canSteerQueued)

    let store = makeStore(slash) { _, _ in .object(["status": .string("queued")]) }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    #expect(store.state.steeringEntryID == nil)
    await store.finish()
  }

  @Test func ineligibleEntriesAreRefused() async {
    let attachment = ComposerAttachment(
      id: uuid(9), kind: .image, filename: "photo.jpg", mimeType: "image/jpeg",
      data: Data([0x1]), uploadState: .pending
    )
    let store = makeStore(runningState([
      QueuedPrompt(id: uuid(90), text: "/status"),
      QueuedPrompt(id: uuid(91), text: "look", attachments: [attachment]),
    ])) { _, _ in .object(["status": .string("queued")]) }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.send(.queuedPromptSteer(id: uuid(91)))
    await store.send(.queuedPromptSteer(id: uuid(99)))
    #expect(store.state.steeringEntryID == nil)
    #expect(store.state.queuedPrompts.count == 2)
    await store.finish()
  }

  @Test func theSteeredEntryIgnoresDeleteEditAndSendNowWhileInFlight() async {
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A")])) { method, _ in
      if method == "session.steer" {
        for await _ in gate.stream { break }
        return .object(["status": .string("rejected")])
      }
      return .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.send(.queuedPromptDeleted(id: uuid(90)))
    await store.send(.queuedPromptEditTapped(id: uuid(90)))
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    #expect(store.state.queuedPrompts.map(\.text) == ["A"])
    #expect(store.state.composerText.isEmpty)
    #expect(!store.state.sendNowArmed)
    gate.continuation.yield()
    await store.receive(\.queuedPromptSteerResult)
    await store.send(.teardown)
    await store.finish()
  }

  // MARK: Stop, hydrate, replay fold

  @Test func stopDuringTheSteerKeepsTheParkAndALaterAcceptStillEchoes() async {
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A"), QueuedPrompt(id: uuid(91), text: "B")])) {
      method, _ in
      if method == "session.steer" {
        for await _ in gate.stream { break }
        return .object(["status": .string("queued")])
      }
      return .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.send(.interruptTapped)
    #expect(store.state.isQueueParked)
    gate.continuation.yield()
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.queuedPrompts.map(\.text) == ["B"])
    #expect(store.state.isQueueParked, "stop intent wins over the steer's unpark")
    #expect(store.state.drainingEntry == nil)
    #expect(store.state.transcript.last?.kind == .message(role: .user, text: "A", isComplete: true))
    await store.send(.teardown)
    await store.finish()
  }

  @Test func stopThenRejectedLeavesTheEntryParkedAtItsPlace() async {
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A")])) { method, _ in
      if method == "session.steer" {
        for await _ in gate.stream { break }
        return .object(["status": .string("rejected")])
      }
      return .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.send(.interruptTapped)
    gate.continuation.yield()
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.queuedPrompts.map(\.text) == ["A"])
    #expect(store.state.isQueueParked)
    #expect(store.state.drainingEntry == nil)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func idleHydrateWhileSteeringHoldsTheDrainUntilTheAnswer() async {
    let gate = AsyncStream<Void>.makeStream()
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "A"), QueuedPrompt(id: uuid(91), text: "B")])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { method, _ in
      if method == "session.steer" {
        for await _ in gate.stream { break }
        return .object(["status": .string("rejected")])
      }
      return .object(["status": .string("streaming")])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.send(.activateResult(.success(
      ActivateResponse(sessionID: "live123", storedSessionID: "stored123", running: false)
    )))
    #expect(store.state.drainingEntry == nil, "the hydrate's idle edge waits on the steer")
    #expect(store.state.steeringEntryID == uuid(90))
    gate.continuation.yield()
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.drainingEntry?.text == "A")
    await store.send(.teardown)
    await store.finish()
  }

  @Test func resultDuringAReplayFoldDoesNotDrain() async {
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "A")])
    initial.isSending = false
    initial.steeringEntryID = uuid(90)
    initial.isFoldingReplay = true
    let store = makeStore(initial) { _, _ in .object([:]) }
    await store.send(.queuedPromptSteerResult(id: uuid(90), outcome: .undelivered)) {
      $0.steeringEntryID = nil
    }
    #expect(store.state.drainingEntry == nil)
    await store.finish()
  }

  @Test func runningHydrateKeepsTheCorrectionBubbleAndSealedOutput() async {
    var initial = runningState([])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "use tabs")]
    let store = makeStore(initial) { method, _ in
      method == "session.steer" ? .object(["status": .string("queued")]) : .object([:])
    }
    await store.send(.gatewayEvent(.messageDelta(text: "Writing spaces")))
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    await store.send(.gatewayEvent(.messageDelta(text: "Tabs now")))

    // A mid-turn foreground hydrate: the server's flat snapshot plus the correction record.
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123",
      running: true,
      inflight: SessionInflight(
        user: "write it", assistant: "Writing spacesTabs now", streaming: true,
        corrections: ["use tabs"], correctionOffsets: [14]
      )
    ))))
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "write it", isComplete: true),
      .message(role: .assistant, text: "Writing spaces", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
      .message(role: .assistant, text: "Tabs now", isComplete: false),
    ])
    await store.send(.teardown)
    await store.finish()
  }

  @Test func coldRunningHydrateRebuildsCorrectionsAtTheirOffsets() async {
    var initial = runningState([])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { _, _ in .object([:]) }
    let response = ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123",
      running: true,
      inflight: SessionInflight(
        user: "write it", assistant: "Writing spaces Tabs now", streaming: true,
        corrections: ["use tabs"], correctionOffsets: [15]
      )
    )
    let expected: [ChatRow.Kind] = [
      .message(role: .user, text: "write it", isComplete: true),
      .message(role: .assistant, text: "Writing spaces ", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
      .message(role: .assistant, text: "Tabs now", isComplete: false),
    ]
    await store.send(.activateResult(.success(response)))
    #expect(store.state.transcript.map(\.kind) == expected)
    let ids = store.state.transcript.ids
    // A repeat hydrate keeps one bubble per correction, under the same ids.
    await store.send(.activateResult(.success(response)))
    #expect(store.state.transcript.map(\.kind) == expected)
    #expect(store.state.transcript.ids == ids)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func persistedSteerRowIsNotShownTwice() async {
    var initial = runningState([])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "use tabs")]
    let store = makeStore(initial) { method, _ in
      method == "session.steer" ? .object(["status": .string("queued")]) : .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123",
      messages: [
        SessionMessage(id: 1, role: "user", content: "write it"),
        SessionMessage(id: 2, role: "assistant", content: "Writing spaces"),
        SessionMessage(id: 3, role: "user", content: "use tabs", displayKind: "steer"),
      ],
      running: true,
      inflight: SessionInflight(
        assistant: "", streaming: true, corrections: ["use tabs"]
      )
    ))))
    let userTexts = store.state.transcript.compactMap { row -> String? in
      if case let .message(.user, text, _) = row.kind { return text }
      return nil
    }
    #expect(userTexts == ["write it", "use tabs"])
    await store.send(.teardown)
    await store.finish()
  }

  // MARK: The segment an accept split (review 2, blocker 1)

  /// Delta "Let me check" → accept → delta " the file": the seal and the next row.
  private func acceptMidSegment(_ store: TestStoreOf<ChatFeature>) async {
    await store.send(.gatewayEvent(.messageDelta(text: "Let me check")))
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    await store.send(.gatewayEvent(.messageDelta(text: " the file")))
  }

  private func steerStore() -> TestStoreOf<ChatFeature> {
    makeStore(runningState([QueuedPrompt(id: uuid(90), text: "use tabs")])) { method, _ in
      method == "session.steer" ? .object(["status": .string("queued")]) : .object([:])
    }
  }

  @Test func interimAfterAnAcceptedSteerKeepsOnlyTheTextBelowTheBubble() async {
    let store = steerStore()
    await acceptMidSegment(store)
    await store.send(.gatewayEvent(.messageInterim(
      text: "Let me check the file", alreadyStreamed: true, turnID: "t1", segment: 0
    )))
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .assistant, text: "Let me check", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
      .message(role: .assistant, text: "the file", isComplete: true),
    ])
    #expect(store.state.streamingRowID == nil)
    // The cut is one-shot: the next segment's seal is whole.
    await store.send(.gatewayEvent(.messageDelta(text: "Next")))
    await store.send(.gatewayEvent(.messageInterim(
      text: "Let me check again", alreadyStreamed: true, turnID: "t1", segment: 1
    )))
    #expect(store.state.transcript.last?.kind == .message(role: .assistant, text: "Let me check again", isComplete: true))
    await store.send(.teardown)
    await store.finish()
  }

  @Test func completeAfterAnAcceptedSteerKeepsOnlyTheTextBelowTheBubble() async {
    let store = steerStore()
    await acceptMidSegment(store)
    await store.send(.gatewayEvent(.messageComplete(text: "Let me check the file", usage: nil)))
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .assistant, text: "Let me check", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
      .message(role: .assistant, text: "the file", isComplete: true),
    ])
    await store.send(.teardown)
    await store.finish()
  }

  @Test func sealOrFinalWithNothingAfterTheSteerAddsNoRow() async {
    for terminal in [
      GatewayEvent.messageInterim(text: "Let me check", alreadyStreamed: true, turnID: "t1", segment: 0),
      .messageComplete(text: "Let me check", usage: nil),
    ] {
      let store = steerStore()
      await store.send(.gatewayEvent(.messageDelta(text: "Let me check")))
      await store.send(.queuedPromptSteer(id: uuid(90)))
      await store.receive(\.queuedPromptSteerResult)
      await store.send(.gatewayEvent(terminal))
      #expect(store.state.transcript.map(\.kind) == [
        .message(role: .assistant, text: "Let me check", isComplete: true),
        .message(role: .user, text: "use tabs", isComplete: true),
      ])
      await store.send(.teardown)
      await store.finish()
    }
  }

  @Test func runningHydrateBetweenAcceptAndCompleteStillCuts() async {
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "use tabs")])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { method, _ in
      method == "session.steer" ? .object(["status": .string("queued")]) : .object([:])
    }
    await acceptMidSegment(store)
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", running: true,
      inflight: SessionInflight(
        user: "fix it", assistant: "Let me check the file", streaming: true,
        corrections: ["use tabs"], correctionOffsets: [12]
      )
    ))))
    await store.send(.gatewayEvent(.messageComplete(text: "Let me check the file", usage: nil)))
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "fix it", isComplete: true),
      .message(role: .assistant, text: "Let me check", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
      .message(role: .assistant, text: "the file", isComplete: true),
    ])
    await store.send(.teardown)
    await store.finish()
  }

  @Test func coldHydrateSplitAlsoCutsTheSegmentFinal() async {
    var initial = runningState([])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { _, _ in .object([:]) }
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", running: true,
      inflight: SessionInflight(
        user: "fix it", assistant: "Let me check the", streaming: true,
        corrections: ["use tabs"], correctionOffsets: [12]
      )
    ))))
    await store.send(.gatewayEvent(.messageDelta(text: " file")))
    await store.send(.gatewayEvent(.messageComplete(text: "Let me check the file", usage: nil)))
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "fix it", isComplete: true),
      .message(role: .assistant, text: "Let me check", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
      .message(role: .assistant, text: "the file", isComplete: true),
    ])
    await store.send(.teardown)
    await store.finish()
  }

  // MARK: Lost accept (review 2, should-fix 2)

  @Test func lostAcceptIsDroppedFromTheQueueByTheRunningHydrate() async {
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "use tabs"), QueuedPrompt(id: uuid(91), text: "B")])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { method, _ in
      if method == "session.steer" { throw GatewayError.timedOut(method: "session.steer") }
      return .object([:])
    }
    await store.send(.gatewayEvent(.messageDelta(text: "Writing spaces")))
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.queuedPrompts.map(\.text) == ["use tabs", "B"])
    #expect(store.state.errorBanner?.hasPrefix("Couldn't steer") == true)

    // The server did take it: the turn's record lists it, and this client holds no bubble.
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", running: true,
      inflight: SessionInflight(
        user: "write it", assistant: "Writing spaces", streaming: true,
        corrections: ["use tabs"], correctionOffsets: [14]
      )
    ))))
    #expect(store.state.queuedPrompts.map(\.text) == ["B"], "never drained a second time")
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "write it", isComplete: true),
      .message(role: .assistant, text: "Writing spaces", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
    ])
    #expect(store.state.errorBanner == nil)
    // The turn ends: B drains, the steered text does not.
    await store.send(.gatewayEvent(.messageComplete(text: "Writing tabs", usage: nil)))
    #expect(store.state.drainingEntry?.text == "B")
    await store.send(.teardown)
    await store.finish()
  }

  @Test func aQueuedEntryNeverSteeredIsNotTakenForAnotherClientsCorrection() async {
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "use tabs")])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { _, _ in .object([:]) }
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", running: true,
      inflight: SessionInflight(
        user: "write it", assistant: "", streaming: true, corrections: ["use tabs"]
      )
    ))))
    #expect(store.state.queuedPrompts.map(\.text) == ["use tabs"])
    await store.send(.teardown)
    await store.finish()
  }

  @Test func aRejectedSteerIsNotDroppedByALaterHydrate() async {
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "use tabs")])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { method, _ in
      method == "session.steer" ? .object(["status": .string("rejected")]) : .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", running: true,
      inflight: SessionInflight(user: "write it", streaming: true, corrections: ["use tabs"])
    ))))
    #expect(store.state.queuedPrompts.map(\.text) == ["use tabs"])
    await store.send(.teardown)
    await store.finish()
  }

  // MARK: Placement and matching (review 2 nits)

  @Test func anotherClientsCorrectionIsPlacedByOffsetAmongLiveRows() async {
    var initial = runningState([])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { _, _ in .object([:]) }
    // A live row the server snapshot lacks (#26), so the hydrate holds live rows.
    await store.send(.gatewayEvent(.reasoningDelta(text: "Thinking")))
    await store.send(.gatewayEvent(.messageDelta(text: "Writing spacesTabs now")))
    let response = ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", running: true,
      inflight: SessionInflight(
        user: "write it", assistant: "Writing spacesTabs now", streaming: true,
        corrections: ["use tabs"], correctionOffsets: [14]
      )
    )
    let expected: [ChatRow.Kind] = [
      .message(role: .user, text: "write it", isComplete: true),
      .reasoning(text: "Thinking"),
      .message(role: .assistant, text: "Writing spaces", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
      .message(role: .assistant, text: "Tabs now", isComplete: false),
    ]
    await store.send(.activateResult(.success(response)))
    #expect(store.state.transcript.map(\.kind) == expected)
    // Later deltas grow the row BELOW the bubble.
    await store.send(.gatewayEvent(.messageDelta(text: "!")))
    #expect(store.state.transcript.last?.kind == .message(role: .assistant, text: "Tabs now!", isComplete: false))
    let ids = store.state.transcript.ids
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", running: true,
      inflight: SessionInflight(
        user: "write it", assistant: "Writing spacesTabs now!", streaming: true,
        corrections: ["use tabs"], correctionOffsets: [14]
      )
    ))))
    #expect(store.state.transcript.count == 5)
    #expect(store.state.transcript.ids == ids, "a repeat hydrate keeps one bubble, same ids")
    await store.send(.teardown)
    await store.finish()
  }

  @Test func anEarlierIdenticalPromptDoesNotHideAHeldSteerBubble() async {
    // The running prompt "continue" repeats an older one; a later turn's user row is the same
    // text as the held steer. Neither may make the steer look persisted.
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "use tabs")])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { method, _ in
      method == "session.steer" ? .object(["status": .string("queued")]) : .object([:])
    }
    await store.send(.gatewayEvent(.messageDelta(text: "Working")))
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.receive(\.queuedPromptSteerResult)
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123",
      messages: [
        SessionMessage(id: 1, role: "user", content: "continue"),
        SessionMessage(id: 2, role: "assistant", content: "Done before"),
        SessionMessage(id: 3, role: "user", content: "use tabs"),
        SessionMessage(id: 4, role: "assistant", content: "Done again"),
      ],
      running: true,
      inflight: SessionInflight(
        user: "continue", assistant: "Working", streaming: true,
        corrections: ["use tabs"], correctionOffsets: [7]
      )
    ))))
    let userTexts = store.state.transcript.compactMap { row -> String? in
      if case let .message(.user, text, _) = row.kind { return text }
      return nil
    }
    #expect(userTexts == ["continue", "use tabs", "continue", "use tabs"])
    await store.send(.teardown)
    await store.finish()
  }

  @Test func aHydrateBeforeTheAcceptAnswerShowsOneBubble() async {
    let gate = AsyncStream<Void>.makeStream()
    var initial = runningState([QueuedPrompt(id: uuid(90), text: "use tabs")])
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(commands: [SlashCommand(name: "/status", description: "")])
    let store = makeStore(initial) { method, _ in
      if method == "session.steer" {
        for await _ in gate.stream { break }
        return .object(["status": .string("queued")])
      }
      return .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", running: true,
      inflight: SessionInflight(user: "write it", streaming: true, corrections: ["use tabs"], correctionOffsets: [0])
    ))))
    #expect(store.state.queuedPrompts.isEmpty)
    gate.continuation.yield()
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "write it", isComplete: true),
      .message(role: .user, text: "use tabs", isComplete: true),
    ])
    #expect(store.state.steeringEntryID == nil)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func theSteeringRowStateFollowsTheRPC() async {
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(runningState([QueuedPrompt(id: uuid(90), text: "A")])) { method, _ in
      if method == "session.steer" {
        for await _ in gate.stream { break }
        return .object(["status": .string("rejected")])
      }
      return .object([:])
    }
    await store.send(.queuedPromptSteer(id: uuid(90)))
    #expect(store.state.steeringEntryID == uuid(90), "the panel shows Steering… on this row")
    gate.continuation.yield()
    await store.receive(\.queuedPromptSteerResult)
    #expect(store.state.steeringEntryID == nil)
    await store.send(.teardown)
    await store.finish()
  }
}

/// `SteerEligibility` (desktop `isSteerableEntry`) and the `session.steer` answer mapping.
struct SteerEligibilityTests {
  private let id = UUID()

  @Test func plainTextIsSteerable() {
    #expect(SteerEligibility.isSteerable(QueuedPrompt(id: id, text: "use tabs, not spaces")))
  }

  @Test(arguments: ["", "   ", "\n\t "])
  func blankTextIsNot(text: String) {
    #expect(!SteerEligibility.isSteerable(QueuedPrompt(id: id, text: text)))
  }

  @Test(arguments: ["/status", "  /model gpt", "/"])
  func slashCommandsAreNot(text: String) {
    #expect(!SteerEligibility.isSteerable(QueuedPrompt(id: id, text: text)))
  }

  @Test func aPathIsStillText() {
    #expect(SteerEligibility.isSteerable(QueuedPrompt(id: id, text: "/usr/local/bin is wrong")))
  }

  @Test func attachmentsAreNot() {
    let attachment = ComposerAttachment(
      id: UUID(), kind: .image, filename: "a.jpg", mimeType: "image/jpeg",
      data: Data([0x1]), uploadState: .pending
    )
    #expect(!SteerEligibility.isSteerable(QueuedPrompt(id: id, text: "look", attachments: [attachment])))
  }

  @Test func onlyQueuedIsAccepted() {
    #expect(SteerOutcome(result: .object(["status": .string("queued")])) == .accepted)
    #expect(SteerOutcome(result: .object(["status": .string("rejected")])) == .undelivered)
    #expect(SteerOutcome(result: .object(["voice_stopped": .bool(true)])) == .undelivered)
    #expect(SteerOutcome(result: .null) == .undelivered)
  }

  @Test func capabilityErrors() {
    #expect(SteerOutcome(error: .server("unknown method: session.steer")) == .unsupported)
    #expect(SteerOutcome(error: .server("agent does not support steer")) == .unsupported)
    #expect(SteerOutcome(error: .server("boom")) == .failed(.server("boom")))
    #expect(SteerOutcome(error: .disconnected) == .failed(.disconnected))
  }

  @Test func inflightDecodesCorrectionsLeniently() throws {
    func decode(_ json: String) throws -> SessionInflight {
      try JSONDecoder().decode(SessionInflight.self, from: Data(json.utf8))
    }
    let full = try decode(#"{"user":"u","corrections":["a"," ","b"],"correction_offsets":[3,5,9]}"#)
    #expect(full.corrections == ["a", "b"])
    #expect(full.correctionOffsets == [3, 9])
    let partial = try decode(#"{"corrections":["a","b"],"correction_offsets":[3]}"#)
    #expect(partial.corrections == ["a", "b"])
    #expect(partial.correctionOffsets == nil, "offsets only when every correction has one")
    let malformed = try decode(#"{"user":"u","corrections":"oops"}"#)
    #expect(malformed.corrections.isEmpty)
    #expect(malformed.user == "u")
  }
}
