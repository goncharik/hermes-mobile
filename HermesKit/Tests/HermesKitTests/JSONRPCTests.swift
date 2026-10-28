import Foundation
import Testing

@testable import HermesKit

/// Direct tests for the JSON-RPC plumbing: outbound request encoding and the
/// `JSONValue` Codable/accessor logic that the rest of the protocol layer relies on.
@Suite struct JSONRPCTests {
  // MARK: Outbound request encoding

  @Test func requestEncodesToWireShape() throws {
    let req = JSONRPCRequest(
      id: 7,
      method: "prompt.submit",
      params: .object(["session_id": .string("s"), "text": .string("hi")])
    )
    // Decode back to JSONValue to compare structurally (key order isn't guaranteed).
    let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(req))
    #expect(decoded == .object([
      "jsonrpc": .string("2.0"),
      "id": .number(7),
      "method": .string("prompt.submit"),
      "params": .object(["session_id": .string("s"), "text": .string("hi")]),
    ]))
  }

  @Test func requestRoundTripsThroughInboundResponseClassifierAsUnrelated() throws {
    // A request frame is not a response/event — sanity that the classifier ignores it.
    let data = try JSONEncoder().encode(
      JSONRPCRequest(id: 1, method: "session.create", params: .object([:]))
    )
    #expect(try InboundFrame(data: data) == .ignored)
  }

  @Test func serverApprovalRequestIsClassifiedWithStringID() throws {
    let data = Data(#"{"jsonrpc":"2.0","id":"srq-abc123","method":"approval","params":{"session_id":"s","request_id":"approval-7","command":"rm foo","choices":["once","deny"]}}"#.utf8)
    #expect(try InboundFrame(data: data) == .serverRequest(
      id: "srq-abc123",
      method: "approval",
      params: .object([
        "session_id": .string("s"),
        "request_id": .string("approval-7"),
        "command": .string("rm foo"),
        "choices": .array([.string("once"), .string("deny")]),
      ])
    ))
  }

  // MARK: JSONValue Codable

  @Test func roundTripsEveryKind() throws {
    let values: [JSONValue] = [
      .null,
      .bool(true),
      .bool(false),
      .number(0),
      .number(-3.5),
      .string("héllo"),
      .array([.number(1), .string("a"), .null]),
      .object(["a": .null, "b": .array([.bool(true)]), "c": .object(["d": .number(2)])]),
    ]
    for v in values {
      let back = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
      #expect(back == v)
    }
  }

  @Test func disambiguatesBoolNumberNullAndString() throws {
    // The decoder must try Bool before Double, else `true` would decode as a number
    // (and `1` must stay a number, not a bool).
    let arr = try JSONDecoder().decode(
      [JSONValue].self,
      from: Data(#"[true, false, 1, 2.5, null, "s"]"#.utf8)
    )
    #expect(arr == [.bool(true), .bool(false), .number(1), .number(2.5), .null, .string("s")])
  }

  // MARK: JSONValue accessors

  @Test func typedAccessorsReturnValuesAndNilOnMismatch() {
    let obj: JSONValue = .object([
      "n": .number(42),
      "b": .bool(true),
      "s": .string("x"),
      "a": .array([.number(1)]),
    ])
    #expect(obj["n"]?.intValue == 42)
    #expect(obj["n"]?.doubleValue == 42)
    #expect(obj["b"]?.boolValue == true)
    #expect(obj["s"]?.stringValue == "x")
    #expect(obj["a"]?.arrayValue == [.number(1)])

    #expect(obj["missing"] == nil)
    #expect(obj["s"]?.intValue == nil) // wrong type → nil, not a crash
    #expect(obj["n"]?.stringValue == nil)
    #expect(obj["n"]?.boolValue == nil)
  }

  @Test func subscriptOnNonObjectIsNil() {
    #expect(JSONValue.string("x")["key"] == nil)
    #expect(JSONValue.array([])["key"] == nil)
  }

  @Test func decodedReturnsNilOnTypeMismatch() {
    // `decoded` re-decodes into a concrete type; a shape mismatch yields nil, not throw.
    let notAHandle: JSONValue = .object(["unrelated": .string("x")])
    #expect(notAHandle.decoded(SessionHandle.self) == nil)
  }

  // MARK: Malformed input

  @Test func malformedFrameThrows() {
    #expect(throws: (any Error).self) {
      try InboundFrame(data: Data("not json".utf8))
    }
  }

  // MARK: Event sequencing (#98)

  private func inbound(_ json: String) throws -> InboundFrame {
    try InboundFrame(data: Data(json.utf8))
  }

  @Test func liveFrameCarriesSessionIDAndSeq() throws {
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"live1","seq":42,"payload":{"name":"terminal"}}}"#)
    #expect(f == .event(GatewayFrame(
      .toolStart(toolID: nil, name: "terminal", title: nil, argsText: nil),
      sessionID: "live1", seq: 42
    )))
  }

  @Test func frameWithoutSeqFromAnOlderAgentHasNilSeq() throws {
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"live1","payload":{"text":"hi"}}}"#)
    #expect(f == .event(GatewayFrame(.messageDelta(text: "hi"), sessionID: "live1")))
  }

  @Test(arguments: [#""42""#, "4.5", "-1", "true", "null", "1e300"])
  func nonIntegerOrNegativeSeqIsAbsent(_ raw: String) throws {
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"live1","seq":\#(raw)}}"#)
    #expect(f == .event(GatewayFrame(.messageStart, sessionID: "live1", seq: nil)))
  }

  @Test func gatewayReadyCarriesReplayEpoch() throws {
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"e1"}}}"#)
    #expect(f == .event(GatewayFrame(.ready, replayEpoch: "e1")))
  }

  @Test func gatewayReadyWithoutReplayEpochFromAnOlderAgent() throws {
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{"name":"default"}}}}"#)
    #expect(f == .event(GatewayFrame(.ready)))
  }

  @Test func gatewayReadyOnASessionAuthorityHost() throws {
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"replay_epoch":"e1","session_authority":true}}}"#)
    #expect(f == .event(GatewayFrame(.ready, replayEpoch: "e1", sessionAuthority: true)))
  }

  @Test func replayFieldsOnANonReadyFrameAreIgnored() throws {
    // A canonical host's per-session `replay_epoch` is not the process epoch.
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"s","seq":3,"replay_epoch":"x","payload":{"replay_epoch":"y","session_authority":true}}}"#)
    #expect(f == .event(GatewayFrame(.messageStart, sessionID: "s", seq: 3)))
  }

  @Test func sessionlessGlobalEventHasNoSessionOrSeq() throws {
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"skin.changed","payload":{}}}"#)
    #expect(f == .event(GatewayFrame(.unknown(type: "skin.changed", raw: .object([:])))))
  }

  @Test func stampedRequestCancelDecodesWithItsSeq() throws {
    let f = try inbound(#"{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","session_id":"live1","seq":45,"payload":{"id":"srq-0123456789ab","method":"approval","reason":"timeout"}}}"#)
    #expect(f == .event(GatewayFrame(
      .requestCancel(RequestCancel(id: "srq-0123456789ab", method: "approval", reason: "timeout")),
      sessionID: "live1", seq: 45
    )))
  }

  @Test func eventObjectRequiresAType() throws {
    let missing = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"session_id":"s","seq":1}"#.utf8))
    let empty = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"","seq":1}"#.utf8))
    let numeric = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":7,"seq":1}"#.utf8))
    #expect(GatewayFrame(eventObject: missing) == nil)
    #expect(GatewayFrame(eventObject: empty) == nil)
    #expect(GatewayFrame(eventObject: numeric) == nil)
    #expect(GatewayFrame(eventObject: .string("tool.start")) == nil)
    #expect(GatewayFrame(eventObject: .object(["type": .string("message.start")])) == GatewayFrame(.messageStart))
  }

  @Test func eventsSinceReplyDecodesLeniently() throws {
    let json = #"""
    {"events":[
      {"type":"tool.start","session_id":"live1","seq":43,"payload":{"name":"terminal"}},
      {"session_id":"live1","seq":44},
      {"type":"tool.complete","session_id":"live1","seq":45,"payload":{"name":"terminal","result_text":"ok"}}
    ],"latest_seq":45,"truncated":false,"count":3,"epoch":"e1",
    "open_requests":[{"id":"srq-0123456789ab","method":"approval","params":{"command":"rm"}}]}
    """#
    let batch = try JSONDecoder().decode(ReplayBatch.self, from: Data(json.utf8))
    #expect(batch == ReplayBatch(
      events: [
        GatewayFrame(.toolStart(toolID: nil, name: "terminal", title: nil, argsText: nil), sessionID: "live1", seq: 43),
        GatewayFrame(.toolComplete(
          toolID: nil, name: "terminal", title: nil, args: nil, resultText: "ok", inlineDiff: nil, durationS: nil
        ), sessionID: "live1", seq: 45),
      ],
      latestSeq: 45, truncated: false, epoch: "e1"
    ))
  }

  @Test func eventsSinceReplyDefaultsTruncatedAndOptionalFields() throws {
    let batch = try JSONDecoder().decode(ReplayBatch.self, from: Data(#"{"events":[]}"#.utf8))
    #expect(batch == ReplayBatch(events: [], latestSeq: nil, truncated: false, epoch: nil))
    let truncated = try JSONDecoder().decode(
      ReplayBatch.self, from: Data(#"{"events":[],"latest_seq":90,"truncated":true,"epoch":"e1"}"#.utf8)
    )
    #expect(truncated == ReplayBatch(events: [], latestSeq: 90, truncated: true, epoch: "e1"))
  }

  @Test func eventsSinceReplyWithoutEventsIsMalformed() {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ReplayBatch.self, from: Data(#"{"latest_seq":3}"#.utf8))
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ReplayBatch.self, from: Data(#"{"events":"nope"}"#.utf8))
    }
  }

  @Test func legacyPromptEventsAreFlagged() {
    #expect(GatewayEvent.approvalRequest(ApprovalRequest(command: "rm")).isLegacyPrompt)
    #expect(GatewayEvent.clarifyRequest(ClarifyRequest(requestID: "r", question: "Q?")).isLegacyPrompt)
    #expect(GatewayEvent.sudoRequest(SecretPrompt(requestID: "r")).isLegacyPrompt)
    #expect(GatewayEvent.secretRequest(SecretPrompt(requestID: "r")).isLegacyPrompt)
    #expect(!GatewayEvent.requestCancel(RequestCancel(id: "srq-x")).isLegacyPrompt)
    #expect(!GatewayEvent.messageStart.isLegacyPrompt)
    #expect(!GatewayEvent.ready.isLegacyPrompt)
  }
}
