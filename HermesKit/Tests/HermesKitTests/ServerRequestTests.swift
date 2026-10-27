import Clocks
import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

private struct FailingReplyTransport: WebSocketTransport {
  let base = FakeTransport { frame, inbound in
    let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
    if let id = request["id"]?.intValue {
      inbound.yield(#"{"id":\#(id),"result":{"declines_not_shown":true}}"#)
    }
  }
  func send(_ text: String) async throws {
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    guard frame["method"]?.stringValue == "client.capabilities" else {
      throw GatewayError.server("send failed")
    }
    try await base.send(text)
  }
  func receive() async throws -> String { try await base.receive() }
  func cancel() { base.cancel() }
}

@MainActor
struct ServerRequestTests {
  private let url = URL(string: "http://test.local:9119")!
  private let windowMethods = ["terminal.read", "preview.read", "window.read", "preview.act", "tour"]

  private func wire(_ value: JSONValue) -> String {
    String(decoding: try! JSONRPCRequest.wireEncoder.encode(value), as: UTF8.self)
  }

  private func serverRequestFrame(id: String, method: String, params: JSONValue) -> String {
    wire(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params]))
  }

  private func probe(_ type: String) -> String {
    #"{"method":"event","params":{"type":"\#(type)","payload":{}}}"#
  }

  /// The decline matrix, driven end to end through injected frames (the receive loop's real
  /// routing) and fed into an exhaustive reducer: before the advertisement nothing is
  /// declined (support unknown); after it, window-owned bridges get a 4404 only when
  /// `declines_not_shown` was acknowledged; every unrendered prompt — `vault.code` included —
  /// gets nothing on every backend; a rendered approval is queued and presented. Routing is
  /// synchronous on the receive loop, so a probe event read back is the "nothing more" barrier.
  @Test(arguments: [JSONValue.object([:]), .object(["declines_not_shown": .bool(false)]),
                    .object(["declines_not_shown": .bool(true)])])
  func declineMatrixThroughInjectedFrames(capabilities: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if request["method"]?.stringValue == "client.capabilities", let id = request["id"]?.intValue {
        let result: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": capabilities])
        inbound.yield(String(decoding: try! JSONRPCRequest.wireEncoder.encode(result), as: UTF8.self))
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    for method in windowMethods {
      transport.inject(serverRequestFrame(id: "before/" + method, method: method, params: .object([:])))
    }
    transport.inject(probe("probe.before"))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.before", raw: .object([:])))
    #expect(transport.sent.isEmpty) // support is unknown until a successful advertisement

    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    #expect(await iterator.nextEvent() == .ready)
    let methods = windowMethods + ["vault.unlock_prompt", "vault.save_login", "vault.code", "setup_choose",
      "display.install.sudo", "future.method"]
    for method in methods {
      transport.inject(serverRequestFrame(
        id: "srq/" + method, method: method,
        params: .object(["session_id": .string("live"), "path": .string("/tmp/a")])
      ))
    }
    transport.inject(serverRequestFrame(
      id: "srq-approval", method: "approval",
      params: .object(["session_id": .string("live"), "command": .string("rm /tmp/foo")])
    ))
    transport.inject(probe("probe.after"))
    let event = try #require(await iterator.nextEvent())
    #expect(await iterator.nextEvent() == .unknown(type: "probe.after", raw: .object([:])))

    let declines = capabilities["declines_not_shown"]?.boolValue == true
    await waitUntil { transport.sent.count == 1 + (declines ? windowMethods.count : 0) }
    for _ in 0..<200 { await Task.yield() } // a stray extra reply would land meanwhile
    let frames = try transport.sent.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(frames.first?["method"]?.stringValue == "client.capabilities")
    #expect(frames.first?["params"] == .object(["server_requests": .bool(true)]))
    let replies = Array(frames.dropFirst())
    if declines {
      #expect(Set(replies.compactMap { $0["id"]?.stringValue }) == Set(windowMethods.map { "srq/" + $0 }))
      for reply in replies {
        #expect(reply["error"] == .object(["code": .number(4404), "message": .string("Not shown on this client")]))
        #expect(reply["jsonrpc"] == .string("2.0"))
      }
    } else {
      #expect(replies.isEmpty)
    }
    #expect(transport.sent.allSatisfy { !$0.contains(#"\/"#) }) // every frame via `wireEncoder`

    let store = TestStore(initialState: ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))) {
      ChatFeature()
    }
    let expected = PendingServerRequest(id: "srq-approval", kind: .approval(ApprovalRequest(command: "rm /tmp/foo")))
    await store.send(.gatewayEvent(event)) {
      $0.serverRequests = [expected]
      $0.present(expected.kind)
    }
    client.disconnect()
    await store.finish()
  }

  /// A clarify server request reaches the reducer as a queued, presented card, ahead of the
  /// turn terminal that follows it on the wire.
  @Test func clarifyServerRequestIsQueuedAndPresented() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    transport.inject(
      #"{"jsonrpc":"2.0","id":"srq-0f0e0d0c0b0a","method":"clarify","params":{"session_id":"live","questions":[{"qid":"q0","question":"Framework?","choices":["SwiftUI (Recommended)","UIKit"],"multi_select":false},{"qid":"q1","question":"Targets?","choices":["iOS","macOS"],"multi_select":true}],"answers":{"q0":"SwiftUI"}}}"#
        + "\n" + #"{"method":"event","params":{"type":"message.complete","payload":{"text":"done"}}}"#
    )
    var iterator = events.makeAsyncIterator()
    let expected = PendingServerRequest(id: "srq-0f0e0d0c0b0a", kind: .clarify(ClarifyRequest(
      requestID: nil,
      questions: [
        ClarifyQuestion(qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"]),
        ClarifyQuestion(qid: "q1", question: "Targets?", choices: ["iOS", "macOS"], multiSelect: true),
      ],
      lockedAnswers: ["q0": "SwiftUI"],
      answerShape: .answers
    )))
    let event = try #require(await iterator.nextEvent())
    #expect(event == .serverRequest(expected))
    #expect(await iterator.nextEvent() == .messageComplete(text: "done", usage: nil))
    client.disconnect()

    let store = TestStore(initialState: ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))) {
      ChatFeature()
    }
    await store.send(.gatewayEvent(event)) {
      $0.serverRequests = [expected]
      $0.present(expected.kind)
    }
  }

  /// A rendered clarify whose params are not an object is cancelled with `{}` through
  /// `request.answer`, never presented.
  @Test(arguments: [JSONValue.null, .array([]), .string("q")])
  func malformedClarifyIsCancelled(payload: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"ok"}}"#)
        inbound.yield(#"{"method":"event","params":{"type":"probe.answered","payload":{}}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(serverRequestFrame(id: "srq/bad", method: "clarify", params: payload))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.answered", raw: .object([:])))
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.first).utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object(["id": .string("srq/bad"), "result": .object([:])]))
    #expect(transport.sent.count == 1)
    client.disconnect()
  }

  /// Sudo and secret server requests reach the reducer as queued, presented cards, ahead of
  /// the turn terminal that follows them on the wire; the second queues behind the first.
  @Test func sudoAndSecretServerRequestsAreQueuedAndPresented() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    transport.inject(
      #"{"jsonrpc":"2.0","id":"srq-bbbbbbbbbbbb","method":"sudo","params":{"session_id":"live","command":"apt install ripgrep"}}"#
        + "\n" + #"{"jsonrpc":"2.0","id":"srq-dddddddddddd","method":"secret","params":{"session_id":"live","env_var":"OPENWEATHER_API_KEY","prompt":"Weather API key"}}"#
        + "\n" + #"{"method":"event","params":{"type":"message.complete","payload":{"text":"done"}}}"#
    )
    var iterator = events.makeAsyncIterator()
    let sudo = PendingServerRequest(
      id: "srq-bbbbbbbbbbbb", kind: .secret(.sudo, SecretPrompt(command: "apt install ripgrep"))
    )
    let secret = PendingServerRequest(
      id: "srq-dddddddddddd",
      kind: .secret(.secret, SecretPrompt(prompt: "Weather API key", envVar: "OPENWEATHER_API_KEY"))
    )
    #expect(await iterator.nextEvent() == .serverRequest(sudo))
    #expect(await iterator.nextEvent() == .serverRequest(secret))
    #expect(await iterator.nextEvent() == .messageComplete(text: "done", usage: nil))
    #expect(transport.sent.isEmpty) // rendered, so nothing is answered automatically
    client.disconnect()

    let store = TestStore(initialState: ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))) {
      ChatFeature()
    }
    await store.send(.gatewayEvent(.serverRequest(sudo))) {
      $0.serverRequests = [sudo]
      $0.present(sudo.kind)
    }
    await store.send(.gatewayEvent(.serverRequest(secret))) {
      $0.serverRequests = [sudo, secret]
    }
  }

  /// A rendered sudo / secret whose params are not an object is skipped with `{value: ""}`
  /// through `request.answer`, never presented.
  @Test(arguments: [("sudo", JSONValue.null), ("sudo", .number(1)), ("secret", .null), ("secret", .array([]))])
  func malformedSecretIsSkipped(method: String, payload: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"ok"}}"#)
        inbound.yield(#"{"method":"event","params":{"type":"probe.answered","payload":{}}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(serverRequestFrame(id: "srq/bad", method: method, params: payload))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.answered", raw: .object([:])))
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.first).utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object(["id": .string("srq/bad"), "result": .object(["value": .string("")])]))
    #expect(transport.sent.count == 1)
    client.disconnect()
  }

  /// A rendered approval whose params are not an object is denied through `request.answer`,
  /// never presented. The probe yielded by the fake on the answer arrives FIRST, so no card
  /// event preceded it.
  @Test(arguments: [JSONValue.null, .array([]), .bool(true)])
  func malformedApprovalIsDenied(payload: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"ok"}}"#)
        inbound.yield(#"{"method":"event","params":{"type":"probe.answered","payload":{}}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(serverRequestFrame(id: "srq/bad", method: "approval", params: payload))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.answered", raw: .object([:])))
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.first).utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object([
      "id": .string("srq/bad"), "result": .object(["choice": .string("deny")]),
    ]))
    #expect(transport.sent.count == 1)
    client.disconnect()
  }

  /// A rendered method whose OBJECT params the phone cannot decode — a newer shape a desktop
  /// sharing the session may render, or a content-less approval / secret — is never answered
  /// (no deny, no cancel for everyone) and never presented; the phone banners instead,
  /// without ending the turn.
  @Test(arguments: [
    (PromptMethod.approval, JSONValue.object(["session_id": .string("live")])),
    (.approval, .object(["command": .number(9)])),
    (.approval, .object(["choices": .string("once")])),
    (.clarify, .object(["session_id": .string("live")])),
    (.clarify, .object(["question": .string("  ")])),
    (.clarify, .object(["request_id": .string("r1")])),
    (.clarify, .object(["prompts": .array([.object(["id": .string("q0"), "text": .string("New shape?")])])])),
    (.sudo, .object(["command": .number(1)])),
    (.secret, .object(["session_id": .string("live")])),
  ])
  func undecodableObjectParamsAreLeftUnansweredWithABanner(method: PromptMethod, payload: JSONValue) async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(serverRequestFrame(id: "srq/new", method: method.rawValue, params: payload))
    transport.inject(probe("probe.after"))
    let banner = try #require(await iterator.nextEvent())
    #expect(banner == .serverRequestFailed(message: method.unreadableMessage))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.after", raw: .object([:])))
    for _ in 0..<200 { await Task.yield() } // a stray automatic answer would land meanwhile
    #expect(transport.sent.isEmpty)
    client.disconnect()

    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), status: .ready)
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(banner)) {
      $0.errorBanner = method.unreadableMessage
    }
  }

  @Test func unreadablePromptMessageNamesEachKind() {
    #expect(PromptMethod.approval.unreadableMessage
      == "Couldn’t show an approval request from the agent. Answer it on another device, or stop the turn.")
    #expect(PromptMethod.clarify.unreadableMessage.hasPrefix("Couldn’t show a question from the agent."))
    #expect(PromptMethod.sudo.unreadableMessage.hasPrefix("Couldn’t show a password request"))
    #expect(PromptMethod.secret.unreadableMessage.hasPrefix("Couldn’t show a secret request"))
  }

  /// A failed advertisement opens the ready gate first and only then surfaces, so the
  /// `.ready` reset can't wipe it; the socket and the running turn stay up, nothing retries
  /// on this connection (the next connect re-advertises — no background retry loop), and
  /// with `declines_not_shown` never confirmed a window bridge gets no 4404.
  @Test func advertisementFailureSurfacesAfterReadyAndIsNotRetried() async throws {
    let clock = TestClock()
    let attempts = LockIsolated(0)
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        attempts.withValue { $0 += 1 }
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"error":{"message":"busy"}}"#)
      }
    }
    let client = HermesGatewayClient.make(clock: clock) { _ in transport }
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))
    initial.hasRequestedSession = true // isolate protocol bootstrap from session hydration
    initial.isSending = true // a running turn: the failure must not end it
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway = client
      $0.debugLog.append = { _ in }
    }
    let message = "Couldn’t enable approvals and other prompts: busy"
    await store.send(.task) {
      $0.isOnScreen = true
      $0.hasStarted = true
    }
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    await store.receive(\.gatewayFrame) { $0.status = .ready }
    await store.receive(\.gatewayFrame) {
      $0.serverRequestsUnavailable = message
      $0.errorBanner = message
    }
    await clock.advance(by: .seconds(120))
    transport.inject(serverRequestFrame(id: "bridge", method: "tour", params: .object([:])))
    transport.inject(#"{"method":"event","params":{"type":"probe.ack","payload":{}}}"#)
    await store.receive(\.gatewayFrame) // probe.ack: the receive loop survived the failure
    #expect(attempts.value == 1)
    #expect(transport.sent.count == 1) // the one advertisement; no 4404 for the tour
    #expect(store.state.isSending)
    await store.send(.teardown)
    await store.finish()
  }

  /// The ready gate holds `.ready` until the advertisement is acknowledged, so the
  /// reducer's first `session.resume` (sent on `.ready`) always follows it on the wire.
  /// Frames read meanwhile are yielded at once, and the acknowledged `declines_not_shown`
  /// is what later licenses a 4404.
  @Test func readyWaitsForTheAdvertisementWhichPrecedesSessionResume() async throws {
    let capabilitiesID = LockIsolated<Int?>(nil)
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      guard let id = request["id"]?.intValue else { return }
      if request["method"]?.stringValue == "client.capabilities" {
        capabilitiesID.setValue(id) // acknowledged by the test, below
      } else {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live"}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    transport.inject(#"{"method":"event","params":{"type":"probe.window","payload":{}}}"#)
    #expect(await iterator.nextEvent() == .unknown(type: "probe.window", raw: .object([:])))
    await waitUntil { capabilitiesID.value != nil }
    let id = try #require(capabilitiesID.value)
    transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"server_requests":["approval"],"declines_not_shown":true}}"#)
    #expect(await iterator.nextEvent() == .ready)

    _ = try await client.send("session.resume", .object(["session_id": .string("stored")]))
    let methods = transport.sent.compactMap {
      (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?["method"]?.stringValue
    }
    #expect(methods == ["client.capabilities", "session.resume"])

    transport.inject(#"{"jsonrpc":"2.0","id":"srq-tour","method":"tour","params":{}}"#)
    await waitUntil { transport.sent.count == 3 }
    let decline = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.last).utf8))
    #expect(decline["error"]?["code"] == .number(4404)) // declines_not_shown was stored
    client.disconnect()
  }

  /// A hung `client.capabilities` must not strand the chat: the 5 s cap releases `.ready`,
  /// and the advertisement's own late failure (the 30 s request timeout) still surfaces.
  @Test func hungAdvertisementReachesReadyAfterTheCap() async throws {
    let clock = TestClock()
    let transport = FakeTransport() // never answers
    let client = HermesGatewayClient.make(clock: clock) { _ in transport }
    let events = client.connect(url, .token("t"))
    // Events are collected off the test task, and the clock is advanced in bounded steps
    // until each one lands: a sleeper that registers late still fires, and a missing event
    // fails the wait instead of hanging the suite.
    let received = LockIsolated<[GatewayEvent]>([])
    let consumer = Task { for await frame in events { received.withValue { $0.append(frame.event) } } }
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    await waitUntil { transport.sent.count == 1 }

    let start = clock.now
    await advanceUntil(clock, step: .seconds(1), limit: 30) { received.value.contains(.ready) }
    #expect(start.duration(to: clock.now) >= GatewayConnection.advertisementReadyCap)
    let failure = GatewayEvent.serverRequestsUnavailable(
      message: "Couldn’t enable approvals and other prompts: request timed out: client.capabilities"
    )
    await advanceUntil(clock, step: .seconds(1), limit: 60) { received.value.contains(failure) }
    #expect(received.value == [.ready, failure])
    client.disconnect()
    consumer.cancel()
  }

  /// A failed automatic send (a 4404 decline, a malformed approval's deny) banners without
  /// ending the turn or the socket. Driven through injected frames.
  @Test(arguments: ["tour", "approval", "clarify", "sudo", "secret"])
  func automaticSendFailureDoesNotEndTurn(method: String) async throws {
    let transport = FailingReplyTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.base.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    #expect(await iterator.nextEvent() == .ready) // declines_not_shown acknowledged
    transport.base.inject(serverRequestFrame(id: "failed", method: method, params: .null))
    let failure = try #require(await iterator.nextEvent())
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), status: .ready)
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(failure)) {
      $0.errorBanner = switch method {
      case "tour": "Couldn’t decline a window request: send failed"
      case "approval": "Couldn’t deny a malformed approval: send failed"
      default: "Couldn’t skip a malformed \(method) prompt: send failed"
      }
    }
    #expect(!transport.base.cancelled)
    client.disconnect()
    await store.finish()
  }

  @Test func approvalPresentationPreservesWireEventOrder() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    transport.inject(
      #"{"id":"approval","method":"approval","params":{"command":"rm foo"}}"#
        + "\n" + #"{"method":"event","params":{"type":"message.complete","payload":{"text":"done"}}}"#
    )
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.nextEvent() == .serverRequest(
      PendingServerRequest(id: "approval", kind: .approval(ApprovalRequest(command: "rm foo")))
    ))
    #expect(await iterator.nextEvent() == .messageComplete(text: "done", usage: nil))
    client.disconnect()
  }

  @Test func missingApprovalParamsAreStillAnswered() async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"id":\#(id),"result":{"status":"expired"}}"#)
        inbound.yield(#"{"method":"event","params":{"type":"probe.answered","payload":{}}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    transport.inject(#"{"jsonrpc":"2.0","id":"missing/params","method":"approval"}"#)
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.nextEvent() == .unknown(type: "probe.answered", raw: .object([:])))
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.first).utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object([
      "id": .string("missing/params"), "result": .object(["choice": .string("deny")]),
    ]))
    client.disconnect()
  }

  /// v2026.9.14 speaks v7 without `client.capabilities`: its `-32601` opens the ready gate
  /// at once (no cap wait — the clock never moves before `.ready`), raises nothing, and is
  /// never re-sent. Driven through an injected `gateway.ready` frame, the real trigger.
  @Test func unknownAdvertisementMethodIsSilentAndNotRetried() async throws {
    let clock = TestClock()
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      guard let id = request["id"]?.intValue else { return }
      inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown method: client.capabilities"}}"#)
    }
    let (events, continuation) = AsyncStream<GatewayFrame>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation, clock: clock)
    await connection.start()
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    #expect(await iterator.nextEvent() == .ready)

    await clock.advance(by: .seconds(120))
    transport.inject(#"{"method":"event","params":{"type":"probe.ack","payload":{}}}"#)
    // The next event is the probe: no `.serverRequestsUnavailable` / `.serverRequestFailed`.
    #expect(await iterator.nextEvent() == .unknown(type: "probe.ack", raw: .object([:])))
    let methods = transport.sent.compactMap {
      (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?["method"]?.stringValue
    }
    #expect(methods == ["client.capabilities"])
    await connection.shutdown()
  }

  // MARK: The ready gate

  /// A second `gateway.ready` while the gate is closed releases ONE `.ready` (the reducer's
  /// handling is idempotent), and a `gateway.ready` after the gate opened passes straight
  /// through.
  @Test func readyFramesAroundTheGate() async throws {
    let capabilitiesID = LockIsolated<Int?>(nil)
    let transport = FakeTransport { frame, _ in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if request["method"]?.stringValue == "client.capabilities" {
        capabilitiesID.setValue(request["id"]?.intValue)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    transport.inject(probe("probe.closed"))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.closed", raw: .object([:])))
    await waitUntil { capabilitiesID.value != nil }
    let id = try #require(capabilitiesID.value)
    transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
    #expect(await iterator.nextEvent() == .ready)
    transport.inject(probe("probe.opened"))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.opened", raw: .object([:]))) // one .ready only

    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    #expect(await iterator.nextEvent() == .ready) // the open gate passes it through
    #expect(transport.sent.count == 1) // and it never re-advertises
    client.disconnect()
  }

  /// The held `gateway.ready` is released as the frame that arrived (#98): the epoch and the
  /// authority flag survive the advertisement wait, and a ready passing the open gate keeps
  /// its own fields.
  @Test func heldReadyKeepsItsEpochThroughTheAcknowledgement() async throws {
    let capabilitiesID = LockIsolated<Int?>(nil)
    let transport = FakeTransport { frame, _ in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if request["method"]?.stringValue == "client.capabilities" {
        capabilitiesID.setValue(request["id"]?.intValue)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"e1","session_authority":true}}}"#)
    transport.inject(probe("probe.closed"))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.closed", raw: .object([:])))
    await waitUntil { capabilitiesID.value != nil }
    let id = try #require(capabilitiesID.value)
    transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
    #expect(await iterator.next() == GatewayFrame(.ready, replayEpoch: "e1", sessionAuthority: true))

    transport.inject(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"e2"}}}"#)
    #expect(await iterator.next() == GatewayFrame(.ready, replayEpoch: "e2"))
    client.disconnect()
  }

  /// Several `gateway.ready` frames while the gate is closed: the LATEST is held and released,
  /// once, with its own epoch (#98).
  @Test func heldReadiesReleaseTheLatestFrame() async throws {
    let capabilitiesID = LockIsolated<Int?>(nil)
    let transport = FakeTransport { frame, _ in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if request["method"]?.stringValue == "client.capabilities" {
        capabilitiesID.setValue(request["id"]?.intValue)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"e1"}}}"#)
    transport.inject(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"e2"}}}"#)
    transport.inject(probe("probe.closed"))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.closed", raw: .object([:])))
    await waitUntil { capabilitiesID.value != nil }
    let id = try #require(capabilitiesID.value)
    transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
    #expect(await iterator.next() == GatewayFrame(.ready, replayEpoch: "e2"))
    transport.inject(probe("probe.opened"))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.opened", raw: .object([:]))) // one .ready only
    client.disconnect()
  }

  /// A hung advertisement: the 5 s cap releases the held ready frame, epoch intact (#98).
  @Test func heldReadyKeepsItsEpochThroughTheCap() async throws {
    let clock = TestClock()
    let transport = FakeTransport() // never answers
    let client = HermesGatewayClient.make(clock: clock) { _ in transport }
    let events = client.connect(url, .token("t"))
    let received = LockIsolated<[GatewayFrame]>([])
    let consumer = Task { for await frame in events { received.withValue { $0.append(frame) } } }
    transport.inject(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"e1"}}}"#)
    await waitUntil { transport.sent.count == 1 }

    await advanceUntil(clock, step: .seconds(1), limit: 30) { !received.value.isEmpty }
    #expect(received.value == [GatewayFrame(.ready, replayEpoch: "e1")])
    client.disconnect()
    consumer.cancel()
  }

  /// Shutting down while the gate is closed releases no `.ready`: the stream just ends.
  @Test func shutdownWhileTheGateIsClosedYieldsNoReady() async throws {
    let clock = TestClock()
    let transport = FakeTransport() // never acknowledges the advertisement
    let (events, continuation) = AsyncStream<GatewayFrame>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation, clock: clock)
    await connection.start()
    var iterator = events.makeAsyncIterator()
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    transport.inject(probe("probe.closed"))
    #expect(await iterator.nextEvent() == .unknown(type: "probe.closed", raw: .object([:])))
    await connection.shutdown()
    await clock.advance(by: .seconds(60)) // a surviving cap task would release `.ready` here
    #expect(await iterator.nextEvent() == nil)
  }

  /// An advertisement that succeeds AFTER the cap released `.ready` still counts: its
  /// `declines_not_shown` licenses the 4404.
  @Test func lateAdvertisementSuccessStillStoresDeclines() async throws {
    let clock = TestClock()
    let capabilitiesID = LockIsolated<Int?>(nil)
    let transport = FakeTransport { frame, _ in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if request["method"]?.stringValue == "client.capabilities" {
        capabilitiesID.setValue(request["id"]?.intValue)
      }
    }
    let received = LockIsolated<[GatewayEvent]>([])
    let client = HermesGatewayClient.make(clock: clock) { _ in transport }
    let events = client.connect(url, .token("t"))
    let consumer = Task { for await frame in events { received.withValue { $0.append(frame.event) } } }
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    await waitUntil { capabilitiesID.value != nil }
    await advanceUntil(clock, step: .seconds(1), limit: 30) { received.value.contains(.ready) }

    let id = try #require(capabilitiesID.value)
    transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"declines_not_shown":true}}"#)
    transport.inject(probe("probe.acked"))
    await waitUntil { received.value.contains(.unknown(type: "probe.acked", raw: .object([:]))) }
    transport.inject(serverRequestFrame(id: "srq-tour", method: "tour", params: .object([:])))
    await waitUntil { transport.sent.count == 2 }
    let decline = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.last).utf8))
    #expect(decline["error"]?["code"] == .number(4404))
    client.disconnect()
    consumer.cancel()
  }

  /// An automatic skip whose `request.answer` comes back with a status other than `ok` /
  /// `expired` is a failure, bannered like a throw.
  @Test func automaticSkipWithAnUnknownStatusBanners() async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"weird"}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let events = client.connect(url, .token("t"))
    var iterator = events.makeAsyncIterator()
    transport.inject(serverRequestFrame(id: "srq/bad", method: "approval", params: .null))
    #expect(await iterator.nextEvent() == .serverRequestFailed(
      message: "Couldn’t deny a malformed approval: Malformed request.answer result"
    ))
    client.disconnect()
  }

  // MARK: Reducer: wire generation + the standing advertisement failure

  @Test func readyResetsTheStandingAdvertisementFailure() async {
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))
    initial.hasRequestedSession = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(.serverRequestsUnavailable(message: "Couldn’t enable approvals and other prompts: busy"))) {
      $0.serverRequestsUnavailable = "Couldn’t enable approvals and other prompts: busy"
      $0.errorBanner = "Couldn’t enable approvals and other prompts: busy"
    }
    // A (re)connected socket re-advertises: the old connection's failure is moot.
    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.serverRequestsUnavailable = nil
      $0.errorBanner = nil
    }
  }

  /// The hydrate that lands right after `.ready` clears stale connection banners — but this
  /// connection's advertisement failure is not stale, so it stays up. The hydrate's `info`
  /// also records the wire generation (a string contract included).
  @Test func hydrateKeepsTheAdvertisementFailureAndRecordsTheContract() async throws {
    let message = "Couldn’t enable approvals and other prompts: busy"
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), resumeStoredID: "stored")
    initial.status = .ready
    initial.hasRequestedSession = true
    initial.serverRequestsUnavailable = message
    initial.errorBanner = "Connection lost."
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) } // post-hydrate fetches
    }
    store.exhaustivity = .off(showSkippedAssertions: false) // the post-hydrate fetch effects
    let response = try JSONDecoder().decode(ActivateResponse.self, from: Data(#"""
      {"session_id":"live","resumed":"stored","running":false,"messages":[],
       "info":{"model":"m","desktop_contract":"8"}}
      """#.utf8))
    await store.send(.activateResult(.success(response))) {
      $0.liveSessionID = "live"
      $0.hasHydrated = true
      $0.model = "m"
      $0.desktopContract = 8
      $0.errorBanner = message
    }
    #expect(store.state.serverRequestsUnavailable == message)
    await store.send(.teardown)
  }

  @Test func sessionInfoRecordsTheContractOnlyWhenPresent() async {
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), status: .ready)
    initial.model = "m"
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(desktopContract: 7)))) {
      $0.desktopContract = 7
    }
    // A partial `session.info` without the field leaves the recorded generation alone.
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "m"))))
  }
}
