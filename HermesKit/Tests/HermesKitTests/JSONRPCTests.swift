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
}
