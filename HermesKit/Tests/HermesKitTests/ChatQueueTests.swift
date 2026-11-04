import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Prompt queuing while a turn runs (#66): mid-turn `.composerSubmitted` freezes the
/// draft into `queuedPrompts` (no wire traffic), and the queue drains head-first through
/// the normal submit pipeline once the session goes idle.
@MainActor
struct ChatQueueTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }
  /// The pinned `date` the stores use — what the fold stamps on echoed user rows.
  private let t0 = Date(timeIntervalSince1970: 0)

  /// A chat mid-turn: live session bound, turn streaming (`isSending`).
  private func runningState(composerText: String = "") -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live123"
    state.storedSessionID = "stored123"
    state.status = .ready
    state.isSending = true
    state.composerText = composerText
    return state
  }

  // MARK: Enqueue

  @Test func submittingMidTurnQueuesTheDraftAndClearsComposer() async {
    let store = TestStore(initialState: runningState(composerText: "  next thought  ")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "next thought")]
      $0.composerText = ""
    }
  }

  @Test func submittingDuringSlashExecQueues() async {
    var initial = runningState(composerText: "follow-up")
    initial.isSending = false
    initial.slashExecInFlight = true
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "follow-up")]
      $0.composerText = ""
    }
  }

  @Test func twoEnqueuesStaySeparateOrderedEntries() async {
    let store = TestStore(initialState: runningState(composerText: "first")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "first")]
      $0.composerText = ""
    }
    await store.send(.binding(.set(\.composerText, "second"))) {
      $0.composerText = "second"
    }
    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [
        QueuedPrompt(id: self.uuid(0), text: "first"),
        QueuedPrompt(id: self.uuid(1), text: "second"),
      ]
      $0.composerText = ""
    }
  }

  @Test func enqueueFreezesStagedAttachments() async {
    let attachment = ComposerAttachment(
      id: uuid(9), kind: .image, filename: "photo.jpg", mimeType: "image/jpeg",
      data: Data([0x1]), uploadState: .pending
    )
    var initial = runningState(composerText: "with a photo")
    initial.attachments = [attachment]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [
        QueuedPrompt(id: self.uuid(0), text: "with a photo", attachments: [attachment])
      ]
      $0.composerText = ""
      $0.attachments = []
    }
  }

  // MARK: Enqueue gates

  @Test func pendingApprovalBlocksQueuing() async {
    var initial = runningState(composerText: "queued behind a card")
    initial.present(.approval(ApprovalRequest(command: "rm -rf /tmp/x")))
    let store = TestStore(initialState: initial) { ChatFeature() }

    // A blocking card locks queuing exactly like sending — decide the card first.
    await store.send(.composerSubmitted)
  }

  @Test func branchInFlightBlocksQueuing() async {
    var initial = runningState(composerText: "text")
    initial.isBranching = true
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.composerSubmitted)
  }

  @Test func pendingPasteBlocksQueuing() async {
    var initial = runningState(composerText: "text")
    initial.pendingPasteCount = 1
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.composerSubmitted)
  }

  @Test func whitespaceOnlyDraftDoesNotQueue() async {
    let store = TestStore(initialState: runningState(composerText: "   \n  ")) { ChatFeature() }

    await store.send(.composerSubmitted)
  }

  // MARK: Drain

  @Test func drainOnMessageCompleteFiresHeadOnlyThenSecondWaits() async {
    let clock = TestClock()
    let submitted = LockIsolated<[JSONValue]>([])
    var initial = runningState()
    initial.queuedPrompts = [
      QueuedPrompt(id: uuid(90), text: "first"),
      QueuedPrompt(id: uuid(91), text: "second"),
    ]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = clock
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "prompt.submit" { submitted.withValue { $0.append(params) } }
        return .object(["status": .string("streaming")])
      }
    }

    // Turn ends → the HEAD fires immediately as the next turn; the second entry waits
    // for that turn's own completion (one turn per entry).
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil))) {
      $0.isSending = true
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(91), text: "second")]
      $0.drainingEntry = QueuedPrompt(id: self.uuid(90), text: "first")
      $0.drainingRowID = self.uuid(0)
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "first", isComplete: true), timestamp: self.t0)
      ]
    }
    await store.receive(\.delegate.runningChanged)
    await clock.advance(by: .seconds(1))
    await store.receive(\.persistSnapshotTick)
    await store.finish()
    #expect(submitted.value.count == 1, "head only — one submit per turn end")
  }

  @Test func drainedTurnStartConsumesTheEntry() async {
    let clock = TestClock()
    var initial = runningState()
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "first")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = clock
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object(["status": .string("streaming")]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    #expect(store.state.drainingEntry != nil)
    // The drained turn's `message.start` proves the submit reached the server — the
    // entry is consumed, its echo row now the turn's real user row.
    await store.send(.gatewayEvent(.messageStart))
    #expect(store.state.drainingEntry == nil)
    #expect(store.state.drainingRowID == nil)
    #expect(store.state.queuedPrompts.isEmpty)
    // Ends the ticker/persist effects `message.start` spun up.
    await store.send(.teardown)
    await store.finish()
  }

  @Test func failedDrainReparksAtHeadWithBannerAndNoEchoRow() async {
    let clock = TestClock()
    var initial = runningState()
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "doomed")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = clock
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "prompt.submit" { throw GatewayError.server("boom") }
        return .object([:])
      }
    }

    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil))) {
      $0.isSending = true
      $0.queuedPrompts = []
      $0.drainingEntry = QueuedPrompt(id: self.uuid(90), text: "doomed")
      $0.drainingRowID = self.uuid(0)
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "doomed", isComplete: true), timestamp: self.t0)
      ]
    }
    await store.receive(\.delegate.runningChanged)
    // The submit failed before reaching the server: entry back at the HEAD, parked, echo
    // row removed — the message is never silently lost, and never shows twice.
    await store.receive(\.promptSubmitFailed) {
      $0.errorBanner = "Prompt failed: boom"
      $0.isSending = false
      $0.drainingEntry = nil
      $0.drainingRowID = nil
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(90), text: "doomed")]
      $0.isQueueParked = true
      $0.transcript = []
    }
    await store.receive(\.delegate.runningChanged)
    await clock.advance(by: .seconds(1))
    await store.receive(\.persistSnapshotTick)
    await store.finish()
  }

  @Test func idleHydrateDrainsAndHydrateLeavesQueueIntact() async {
    // Covers the `.gatewayClosed` finalization: no `message.complete` ever arrives on a
    // socket drop, so the reconnect hydrate reporting `running == false` is the drain edge.
    let clock = TestClock()
    let submitted = LockIsolated<Int>(0)
    var initial = runningState()
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(
      commands: [SlashCommand(name: "/status", description: "")]
    )
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "after reconnect")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = clock
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "prompt.submit" { submitted.withValue { $0 += 1 } }
        return .object(["status": .string("streaming")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // The idle-confirming hydrate is a drain edge; the queue itself is never wiped by
    // the wholesale replace (it lives outside the transcript).
    await store.send(.activateResult(.success(
      ActivateResponse(sessionID: "live123", storedSessionID: "stored123", running: false)
    )))
    #expect(store.state.queuedPrompts.isEmpty)
    #expect(store.state.drainingEntry?.text == "after reconnect")
    await clock.advance(by: .seconds(1)) // the hydrate's debounced persist
    await store.finish()
    #expect(submitted.value == 1)
  }

  @Test func stillRunningHydrateLeavesQueueUntouched() async {
    let submitted = LockIsolated<Int>(0)
    var initial = runningState()
    initial.usage = Usage(contextUsed: 1, contextMax: 100)
    initial.commandCatalog = CommandCatalog(
      commands: [SlashCommand(name: "/status", description: "")]
    )
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "waiting")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "prompt.submit" { submitted.withValue { $0 += 1 } }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.activateResult(.success(
      ActivateResponse(sessionID: "live123", storedSessionID: "stored123", running: true)
    )))
    #expect(store.state.queuedPrompts.count == 1, "hydrate never touches the queue")
    #expect(store.state.isSending)
    #expect(submitted.value == 0)
    // Ends the running-turn ticker the hydrate resumed.
    await store.send(.teardown)
    await store.finish()
  }

  // MARK: Parking

  @Test func manualStopParksTheQueueAndCompleteDoesNotDrain() async {
    let clock = TestClock()
    let submitted = LockIsolated<Int>(0)
    var initial = runningState()
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "held")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = clock
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "prompt.submit" { submitted.withValue { $0 += 1 } }
        return .object([:])
      }
    }

    // Stop parks: auto-firing a queued prompt right after would un-stop the agent.
    await store.send(.interruptTapped) {
      $0.isSending = false
      $0.isQueueParked = true
    }
    // The interrupted turn's terminal must NOT drain a parked queue.
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    await store.receive(\.delegate.runningChanged)
    await clock.advance(by: .seconds(1))
    await store.receive(\.persistSnapshotTick)
    await store.finish()
    #expect(submitted.value == 0)
    #expect(store.state.queuedPrompts.count == 1)
  }

  @Test func turnErrorParksTheQueue() async {
    var initial = runningState()
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "held")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
    }

    await store.send(.gatewayEvent(.error(message: "boom"))) {
      $0.errorBanner = "boom"
      $0.isSending = false
      $0.isQueueParked = true
    }
    await store.receive(\.delegate.runningChanged)
  }

  @Test func idleComposerSendJumpsAheadOfParkedQueue() async {
    let submitted = LockIsolated<[String]>([])
    var initial = runningState(composerText: "fresh message")
    initial.isSending = false
    initial.isQueueParked = true
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "held")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "prompt.submit", case let .object(fields) = params,
           case let .string(text)? = fields["text"] {
          submitted.withValue { $0.append(text) }
        }
        return .object(["status": .string("streaming")])
      }
    }

    // Parked means "waiting for you", not "blocking you": an idle send goes out
    // normally, ahead of the held entries, which stay put.
    await store.send(.composerSubmitted) {
      $0.composerText = ""
      $0.isSending = true
      $0.errorBanner = nil
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "fresh message", isComplete: true), timestamp: self.t0)
      ]
    }
    await store.finish()
    #expect(submitted.value == ["fresh message"])
    #expect(store.state.queuedPrompts.count == 1)
  }

  // MARK: Panel interactions — delete / edit / send now

  @Test func deleteRemovesTheEntry() async {
    var initial = runningState()
    initial.queuedPrompts = [
      QueuedPrompt(id: uuid(90), text: "keep"),
      QueuedPrompt(id: uuid(91), text: "drop"),
    ]
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.queuedPromptDeleted(id: self.uuid(91))) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(90), text: "keep")]
    }
  }

  @Test func editLiftsEntryIntoEmptyComposer() async {
    let attachment = ComposerAttachment(
      id: uuid(9), kind: .image, filename: "photo.jpg", mimeType: "image/jpeg",
      data: Data([0x1])
    )
    var initial = runningState()
    initial.queuedPrompts = [
      QueuedPrompt(id: uuid(90), text: "edit me", attachments: [attachment])
    ]
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.queuedPromptEditTapped(id: self.uuid(90))) {
      $0.queuedPrompts = []
      $0.composerText = "edit me"
      $0.attachments = [attachment]
    }
  }

  @Test func editIsANoOpWhileComposerHoldsADraft() async {
    var initial = runningState(composerText: "half-typed draft")
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "edit me")]
    let store = TestStore(initialState: initial) { ChatFeature() }

    // The reducer guard is authoritative (the panel's disabled item just mirrors it):
    // an edit must never clobber what the user is typing.
    await store.send(.queuedPromptEditTapped(id: self.uuid(90)))
  }

  @Test func sendNowWhileIdleSubmitsAheadOfParkedEntries() async {
    let submitted = LockIsolated<[String]>([])
    var initial = runningState()
    initial.isSending = false
    initial.isQueueParked = true
    initial.queuedPrompts = [
      QueuedPrompt(id: uuid(90), text: "still held"),
      QueuedPrompt(id: uuid(91), text: "send me now"),
    ]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "prompt.submit", case let .object(fields) = params,
           case let .string(text)? = fields["text"] {
          submitted.withValue { $0.append(text) }
        }
        return .object(["status": .string("streaming")])
      }
    }

    await store.send(.queuedPromptSendNow(id: self.uuid(91))) {
      $0.isQueueParked = false
      $0.isSending = true
      $0.errorBanner = nil
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(90), text: "still held")]
      $0.drainingEntry = QueuedPrompt(id: self.uuid(91), text: "send me now")
      $0.drainingRowID = self.uuid(0)
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "send me now", isComplete: true), timestamp: self.t0)
      ]
    }
    await store.finish()
    #expect(submitted.value == ["send me now"])
  }

  @Test func sendNowMidTurnInterruptsThenSends() async {
    let calls = LockIsolated<[String]>([])
    var initial = runningState()
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "urgent")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        return .object([:])
      }
    }

    // Interrupt-then-send: the current turn is stopped optimistically and the arm makes
    // the follow-up drain ignore any park.
    await store.send(.queuedPromptSendNow(id: self.uuid(90))) {
      $0.isSending = false
      $0.sendNowArmed = true
    }
    // The deterministic re-check after the interrupt RPC resolves drains the head even
    // though no terminal event ever arrived.
    await store.receive(\.maybeDrainQueue) {
      $0.sendNowArmed = false
      $0.isSending = true
      $0.errorBanner = nil
      $0.queuedPrompts = []
      $0.drainingEntry = QueuedPrompt(id: self.uuid(90), text: "urgent")
      $0.drainingRowID = self.uuid(0)
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "urgent", isComplete: true), timestamp: self.t0)
      ]
    }
    await store.finish()
    #expect(calls.value == ["session.interrupt", "prompt.submit"])
  }

  @Test func sendNowArmSurvivesTheInterruptedTurnsErrorTerminal() async {
    // Some agents answer an interrupt with the turn's `.error` terminal BEFORE the
    // interrupt RPC resolves — the arm must make that terminal drain instead of park.
    let calls = LockIsolated<[String]>([])
    let gate = AsyncStream<Void>.makeStream()
    var initial = runningState()
    initial.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "urgent")]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        if method == "session.interrupt" {
          // Hold the interrupt RPC open until the error terminal has been folded.
          for await _ in gate.stream { }
        }
        return .object([:])
      }
    }

    await store.send(.queuedPromptSendNow(id: self.uuid(90))) {
      $0.isSending = false
      $0.sendNowArmed = true
    }
    // The interrupted turn errors out; the armed drain fires from the terminal itself.
    await store.send(.gatewayEvent(.error(message: "interrupted"))) {
      $0.errorBanner = nil // the drain's submit clears the banner the error just set
      $0.sendNowArmed = false
      $0.isSending = true
      $0.queuedPrompts = []
      $0.drainingEntry = QueuedPrompt(id: self.uuid(90), text: "urgent")
      $0.drainingRowID = self.uuid(0)
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "urgent", isComplete: true), timestamp: self.t0)
      ]
    }
    await store.receive(\.delegate.runningChanged)
    gate.continuation.finish()
    // The late interrupt-RPC re-check is a no-op (the entry is already draining).
    await store.receive(\.maybeDrainQueue)
    await store.finish()
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1, "one submit, not two")
  }

  @Test func degenerateSlashMidTurnFailsLocallyKeepingComposer() async {
    // Same local check the idle path runs: "/" with an empty parsed name must not be
    // queued (it would only fail at drain time) and must not destroy the payload.
    var initial = runningState(composerText: "/ payload after the slash")
    initial.commandCatalog = CommandCatalog(
      commands: [SlashCommand(name: "/status", description: "")]
    )
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.composerSubmitted) {
      $0.errorBanner = "Command failed: empty command"
    }
  }
}
