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

  // Exercise the real connection actor and feed its events into an exhaustive reducer.
  // Awaiting advertisement is the barrier: no scheduling guess before injecting bridges.
  @Test(arguments: [JSONValue.object([:]), .object(["declines_not_shown": .bool(false)]),
                    .object(["declines_not_shown": .bool(true)])])
  func declinesOnlyWindowBridges(capabilities: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if request["method"]?.stringValue == "client.capabilities", let id = request["id"]?.intValue {
        let result: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": capabilities])
        inbound.yield(String(decoding: try! JSONRPCRequest.wireEncoder.encode(result), as: UTF8.self))
      }
    }
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation)
    await connection.start()
    for method in windowMethods {
      await connection.handleServerRequest(id: "before/" + method, method: method, params: .object([:]))
    }
    #expect(transport.sent.isEmpty) // support is unknown until a successful advertisement
    await connection.advertiseServerRequestsIfNeeded()
    let store = TestStore(initialState: ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))) {
      ChatFeature()
    }
    let methods = windowMethods + ["vault.unlock", "vault.2fa", "vault.anything", "setup_choose",
      "display.install.sudo", "clarify", "sudo", "secret", "future.method"]
    for method in methods {
      await connection.handleServerRequest(id: "srq/" + method, method: method, params: .object([:]))
    }
    await connection.handleServerRequest(id: "approval", method: "approval", params: .object(["command": .string("rm foo")]))
    var iterator = events.makeAsyncIterator()
    let event = try #require(await iterator.next())
    await store.send(.gatewayEvent(event)) {
      $0.present(.approval(ApprovalRequest(serverRequestID: "approval", command: "rm foo")))
    }
    let frames = try transport.sent.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(frames.first?["method"]?.stringValue == "client.capabilities")
    #expect(frames.first?["params"] == .object(["server_requests": .bool(true)]))
    let replies = Array(frames.dropFirst())
    if capabilities["declines_not_shown"]?.boolValue == true {
      #expect(replies.count == windowMethods.count)
      for (method, reply) in zip(windowMethods, replies) {
        #expect(reply == .object([
          "jsonrpc": .string("2.0"), "id": .string("srq/" + method),
          "error": .object(["code": .number(4404), "message": .string("Not shown on this client")]),
        ]))
      }
    } else {
      #expect(replies.isEmpty)
    }
    #expect(transport.sent.allSatisfy { !$0.contains(#"\/"#) })
    await connection.shutdown()
    await store.finish()
  }

  @Test(arguments: [JSONValue.null, .array([]), .object(["command": .number(9)]),
                    .object(["choices": .string("once")])])
  func malformedApprovalIsDenied(payload: JSONValue) async throws {
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"ok"}}"#)
      }
    }
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation)
    await connection.start()
    await connection.handleServerRequest(id: "srq/bad", method: "approval", params: payload)
    // handleServerRequest awaits the denial RPC, but the receive loop remains free to ack it.
    let request = try #require(transport.sent.first)
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(request.utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object([
      "id": .string("srq/bad"), "result": .object(["choice": .string("deny")]),
    ]))
    await connection.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == nil) // no malformed card was presented
  }

  @Test func readyAutomaticallyRetriesAdvertisementWithoutClosingSocket() async throws {
    let clock = TestClock()
    let attempts = LockIsolated(0)
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        let attempt = attempts.withValue { $0 += 1; return $0 }
        inbound.yield(attempt == 1
          ? #"{"jsonrpc":"2.0","id":\#(id),"error":{"message":"busy"}}"#
          : #"{"jsonrpc":"2.0","id":\#(id),"result":{"declines_not_shown":true}}"#)
        if attempt == 2 {
          inbound.yield(#"{"method":"event","params":{"type":"probe.ack","payload":{}}}"#)
        }
      }
    }
    let client = HermesGatewayClient.make(clock: clock) { _ in transport }
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"))
    initial.hasRequestedSession = true // isolate protocol bootstrap from session hydration
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway = client
      $0.debugLog.append = { _ in }
    }
    await store.send(.task) { $0.hasStarted = true }
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    await store.receive(\.gatewayEvent) { $0.status = .ready }
    await store.receive(\.gatewayEvent) { $0.errorBanner = "Couldn’t enable approval requests: busy" }
    await clock.advance(by: .seconds(2))
    await store.receive(\.gatewayEvent) // probe.ack: receive loop survived and retried
    #expect(attempts.value == 2)
    transport.inject(#"{"method":"event","params":{"type":"gateway.ready"}}"#)
    await store.receive(\.gatewayEvent) { $0.errorBanner = nil }
    await clock.advance(by: .seconds(60))
    #expect(attempts.value == 2) // acknowledged advertisement does not repeat
    await store.send(.teardown)
    await store.finish()
  }

  @Test(arguments: ["tour", "approval"])
  func automaticSendFailureDoesNotEndTurn(method: String) async throws {
    let transport = FailingReplyTransport()
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation)
    await connection.start()
    await connection.advertiseServerRequestsIfNeeded()
    await connection.handleServerRequest(id: "failed", method: method, params: .null)
    var iterator = events.makeAsyncIterator()
    let failure = try #require(await iterator.next())
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), status: .ready)
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(failure)) {
      $0.errorBanner = method == "tour"
        ? "Couldn’t decline a window request: send failed"
        : "Couldn’t deny a malformed approval: send failed"
    }
    #expect(!transport.base.cancelled)
    await connection.shutdown()
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
    #expect(await iterator.next() == .approvalServerRequest(
      ApprovalRequest(serverRequestID: "approval", command: "rm foo")
    ))
    #expect(await iterator.next() == .messageComplete(text: "done", usage: nil))
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
    #expect(await iterator.next() == .unknown(type: "probe.answered", raw: .object([:])))
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(transport.sent.first).utf8))
    #expect(frame["method"]?.stringValue == "request.answer")
    #expect(frame["params"] == .object([
      "id": .string("missing/params"), "result": .object(["choice": .string("deny")]),
    ]))
    client.disconnect()
  }

  @Test func unknownAdvertisementMethodIsSilentAndNotRetried() async throws {
    let clock = TestClock()
    let attempts = LockIsolated(0)
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      guard let id = request["id"]?.intValue else { return }
      attempts.withValue { $0 += 1 }
      inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"error":{"message":"unknown method: client.capabilities"}}"#)
    }
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation, clock: clock)
    await connection.start()
    await connection.advertiseServerRequestsIfNeeded()

    // Unknown-method compatibility probes must not emit a user-facing failure event.
    #expect(attempts.value == 1)
    await clock.advance(by: .seconds(120))
    #expect(attempts.value == 1)

    await connection.shutdown()
  }

  @Test func advertisementFailureSurfacesWithoutEndingTurnAndCanRetry() async throws {
    let attempts = LockIsolated(0)
    let transport = FakeTransport { frame, inbound in
      let request = try! JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      if let id = request["id"]?.intValue {
        let attempt = attempts.withValue { $0 += 1; return $0 }
        inbound.yield(attempt == 1
          ? #"{"jsonrpc":"2.0","id":\#(id),"error":{"message":"busy"}}"#
          : #"{"jsonrpc":"2.0","id":\#(id),"result":{"declines_not_shown":true}}"#)
      }
    }
    let (events, continuation) = AsyncStream<GatewayEvent>.makeStream()
    let connection = GatewayConnection(transport: transport, events: continuation)
    await connection.start()
    await connection.advertiseServerRequestsIfNeeded()
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: url, token: "t"), status: .ready)
    initial.isSending = true
    initial.present(.approval(ApprovalRequest(command: "rm foo")))
    let store = TestStore(initialState: initial) { ChatFeature() }
    var iterator = events.makeAsyncIterator()
    let failure = try #require(await iterator.next())
    await store.send(.gatewayEvent(failure)) {
      $0.errorBanner = "Couldn’t enable approval requests: busy"
    }
    await connection.advertiseServerRequestsIfNeeded()
    await connection.advertiseServerRequestsIfNeeded() // acknowledged: no duplicate
    #expect(attempts.value == 2)
    await connection.handleServerRequest(id: "bridge", method: "tour", params: .object([:]))
    #expect(transport.sent.count == 3)
    await connection.shutdown()
    await store.finish()
  }
}
