import Foundation
import Testing

@testable import HermesKit

/// Raw-JSON decoding of the re-hydration payloads (`ActivateResponse` / `SessionMessage`).
/// Upholds "decode leniently, never crash": reasoning arrives under any of
/// `reasoning` / `reasoning_content` / `reasoning_details`, and `reasoning_details` may be a
/// provider-shaped non-string array — which must be tolerated (decoded via `try?`) without
/// throwing, with `reasoningText` resolving to the string variants. Also covers the
/// `/api/sessions` row's optional `model` (`SessionListDTO`), which older agents omit.
struct SessionDecodingTests {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }

  @Test func activateResponseDecodesReasoningStringVariants() throws {
    // `reasoning` is the preferred field; assert it resolves through `reasoningText`.
    let json = """
    {
      "session_id": "live1",
      "stored_session_id": "stored1",
      "running": true,
      "messages": [
        { "id": 1, "role": "assistant", "content": "answer", "reasoning": "step one" }
      ]
    }
    """
    let response = try decode(ActivateResponse.self, json)
    #expect(response.sessionID == "live1")
    #expect(response.storedSessionID == "stored1")
    #expect(response.running == true)
    #expect(response.messages.first?.reasoningText == "step one")
  }

  @Test(arguments: [
    (#""started_at": 1700000000.5"#, Date(timeIntervalSince1970: 1_700_000_000.5)),
    (#""started_at": 0"#, nil),
    (#""started_at": "soon""#, nil),
    (#""updated_at": 1"#, nil),
  ] as [(String, Date?)])
  func inflightStartedAtIsLenient(field: String, expected: Date?) throws {
    let json = """
    { "session_id": "s", "inflight": { "user": "hi", "assistant": "", "streaming": true, \(field) } }
    """
    let inflight = try #require(try decode(ActivateResponse.self, json).inflight)
    #expect(inflight == SessionInflight(user: "hi", assistant: "", streaming: true, startedAt: expected))
  }

  @Test func reasoningFallsBackToContentVariant() throws {
    // No `reasoning`, but `reasoning_content` present → that wins.
    let json = """
    { "id": 2, "role": "assistant", "content": "x", "reasoning_content": "from content" }
    """
    let message = try decode(SessionMessage.self, json)
    #expect(message.reasoningText == "from content")
  }

  @Test func nonStringReasoningDetailsArrayIsIgnoredAndDoesNotThrow() throws {
    // `reasoning_details` arrives as a provider-shaped ARRAY (not a string). The decoder must
    // NOT throw on it (decoded via `try?`); it's simply ignored, and `reasoningText` resolves
    // from the string variants instead.
    let json = """
    {
      "session_id": "live2",
      "messages": [
        {
          "id": 3,
          "role": "assistant",
          "content": "y",
          "reasoning": "wins",
          "reasoning_details": [
            { "type": "reasoning.text", "text": "block" }
          ]
        }
      ]
    }
    """
    // The whole payload must decode without throwing despite the non-string array.
    let response = try decode(ActivateResponse.self, json)
    let message = try #require(response.messages.first)
    #expect(message.reasoningDetails == nil)  // array form ignored, never crashes
    #expect(message.reasoningText == "wins")  // string variant resolves
  }

  @Test func reasoningDetailsStringFormIsSurfaced() throws {
    // When `reasoning_details` *is* a plain string (and the others absent), surface it.
    let json = """
    { "id": 4, "role": "assistant", "content": "z", "reasoning_details": "plain string detail" }
    """
    let message = try decode(SessionMessage.self, json)
    #expect(message.reasoningText == "plain string detail")
  }

  @Test func toolCallsAndCallIDDecode() throws {
    // The assistant `tool_calls` entry (raw `arguments` string) and the linked `tool`
    // result's `tool_call_id` — both feed `reconstructTranscript` on resume hydration.
    let assistant = """
    {
      "id": 1, "role": "assistant", "content": "",
      "tool_calls": [
        { "id": "call_1", "type": "function",
          "function": { "name": "terminal", "arguments": "{\\"command\\":\\"git status\\"}" } }
      ]
    }
    """
    let assistantMessage = try decode(SessionMessage.self, assistant)
    let call = try #require(assistantMessage.toolCalls?.first)
    #expect(call.id == "call_1")
    #expect(call.name == "terminal")
    #expect(call.arguments == #"{"command":"git status"}"#)

    let result = """
    { "id": 2, "role": "tool", "content": "clean", "tool_name": "terminal", "tool_call_id": "call_1" }
    """
    let resultMessage = try decode(SessionMessage.self, result)
    #expect(resultMessage.toolCallID == "call_1")
  }

  // MARK: - Cooked tool rows (tool-call display)

  /// The cooked `session.resume` edit row (`tui_gateway/session_history.py`): structured
  /// `args`, the raw stored `content`, `timestamp`, and the persisted inline diff.
  @Test func cookedEditToolRowDecodesArgsContentAndInlineDiff() throws {
    let json = """
    {
      "role": "tool", "name": "patch", "context": "ChatFeature.swift",
      "tool_call_id": "call_9", "timestamp": 1730700000.5,
      "args": { "path": "/repo/ChatFeature.swift", "old_string": "a", "new_string": "b" },
      "content": "{\\"success\\": true, \\"path\\": \\"/repo/ChatFeature.swift\\"}",
      "display_metadata": { "tool_result_metadata": { "inline_diff": "- a\\n+ b" } },
      "labels": [{ "text": "edit" }]
    }
    """
    let message = try decode(SessionMessage.self, json)
    #expect(message.toolDisplayName == "patch")
    #expect(message.context == "ChatFeature.swift")
    #expect(message.toolCallID == "call_9")
    #expect(message.timestamp == 1_730_700_000.5)
    #expect(message.args == .object([
      "path": .string("/repo/ChatFeature.swift"), "old_string": .string("a"), "new_string": .string("b"),
    ]))
    #expect(message.content == #"{"success": true, "path": "/repo/ChatFeature.swift"}"#)
    #expect(message.inlineDiff == "- a\n+ b")
  }

  /// An older agent's cooked row is `{role, name, context}` only — every new field is nil.
  @Test func oldAgentToolRowHasNoNewFields() throws {
    let message = try decode(SessionMessage.self, #"{ "role": "tool", "name": "terminal", "context": "ls" }"#)
    #expect(message.toolDisplayName == "terminal")
    #expect(message.context == "ls")
    #expect(message.args == nil)
    #expect(message.content == nil)
    #expect(message.inlineDiff == nil)
    #expect(message.timestamp == nil)
  }

  /// Odd shapes degrade field-by-field and never throw: non-object `args` is kept as-is,
  /// `null` args read as absent, and `display_metadata` without the diff (or not an object)
  /// yields no diff.
  @Test(arguments: [
    (#"{ "role": "tool", "name": "t", "args": "raw string args", "display_metadata": { "tool_result_metadata": { "lines": 1000 } } }"#,
     JSONValue.string("raw string args") as JSONValue?),
    (#"{ "role": "tool", "name": "t", "args": null, "display_metadata": { "other": 1 } }"#, nil),
    (#"{ "role": "tool", "name": "t", "args": [1, 2], "display_metadata": "nope" }"#,
     JSONValue.array([.number(1), .number(2)]) as JSONValue?),
    (#"{ "role": "tool", "name": "t", "display_metadata": { "tool_result_metadata": { "inline_diff": 42 } } }"#, nil),
    (#"{ "role": "tool", "name": "t", "display_metadata": { "tool_result_metadata": { "inline_diff": "" } } }"#, nil),
  ] as [(String, JSONValue?)])
  func oddToolRowShapesDecodeLeniently(json: String, expectedArgs: JSONValue?) throws {
    let message = try decode(SessionMessage.self, json)
    #expect(message.toolDisplayName == "t")
    #expect(message.args == expectedArgs)
    #expect(message.inlineDiff == nil)
  }

  /// A tool row's raw `content` is not always a string (multimodal parts) — keep it as its
  /// display rendering rather than dropping it. Other roles keep the string-only read.
  @Test func nonStringToolContentIsKeptAsDisplayText() throws {
    let tool = try decode(
      SessionMessage.self, #"{ "role": "tool", "name": "skill_manage", "content": [{ "type": "text", "text": "ok" }] }"#
    )
    #expect(tool.content?.contains("\"text\" : \"ok\"") == true)

    let user = try decode(
      SessionMessage.self, #"{ "role": "user", "content": [{ "type": "text", "text": "hi" }] }"#
    )
    #expect(user.content == nil)
  }

  /// The resume payload keeps the new fields through `ActivateResponse`.
  @Test func activateResponseCarriesToolRowFields() throws {
    let json = """
    {
      "session_id": "live1",
      "messages": [
        { "role": "user", "text": "fix it", "timestamp": 1730700000 },
        { "role": "tool", "name": "terminal", "context": "pytest -q", "args": { "command": "pytest -q" } }
      ]
    }
    """
    let response = try decode(ActivateResponse.self, json)
    #expect(response.messages.count == 2)
    #expect(response.messages[0].timestamp == 1_730_700_000)
    #expect(response.messages[1].args == .object(["command": .string("pytest -q")]))
  }

  // MARK: - Session list row `model` (inbox card footer)

  @Test func listRowModelDecodesWhenPresent() throws {
    let row = try decode(
      SessionListDTO.self,
      #"{ "id": "s1", "model": "anthropic/claude-sonnet-4.5", "message_count": 3 }"#
    )
    #expect(row.asSession.model == "anthropic/claude-sonnet-4.5")
    #expect(row.asSession.messageCount == 3)
  }

  @Test func listRowModelIsNilWhenAbsent() throws {
    // Older agents omit the key entirely; the row must still decode.
    let row = try decode(SessionListDTO.self, #"{ "id": "s1" }"#)
    #expect(row.asSession.model == nil)
  }

  @Test func listRowModelIsNilWhenEmpty() throws {
    let row = try decode(SessionListDTO.self, #"{ "id": "s1", "model": "" }"#)
    #expect(row.asSession.model == nil)
  }

  @Test func listRowModelIsNilWhenNull() throws {
    let row = try decode(SessionListDTO.self, #"{ "id": "s1", "model": null }"#)
    #expect(row.asSession.model == nil)
  }

  // MARK: Wire-generation signal + open requests (#97)

  /// `desktop_contract` is typed `int | str | None` upstream: an Int and a numeric String
  /// both decode; anything else is nil — and never throws, because `ActivateResponse`
  /// decodes `info` with `try?` and a throw would drop the model/usage fields with it.
  @Test(arguments: [
    (#""desktop_contract": 7,"#, 7),
    (#""desktop_contract": "8","#, 8),
    (#""desktop_contract": "x","#, nil),
    (#""desktop_contract": null,"#, nil),
    (#""desktop_contract": [7],"#, nil),
    ("", nil),
  ] as [(String, Int?)])
  func desktopContractDecodesLenientlyAndKeepsTheRestOfInfo(field: String, expected: Int?) throws {
    let json = """
    {
      "session_id": "live1",
      "info": {
        \(field)
        "model": "claude-opus-4-8",
        "usage": { "context_used": 42, "context_max": 200000, "context_percent": 0 }
      }
    }
    """
    let response = try decode(ActivateResponse.self, json)
    let info = try #require(response.info)
    #expect(info.desktopContract == expected)
    #expect(info.model == "claude-opus-4-8")
    #expect(info.usage == Usage(contextUsed: 42, contextMax: 200_000, contextPercent: 0))
  }

  @Test func openRequestsDecodeInOrderWithRawParams() throws {
    let json = """
    {
      "session_id": "live1",
      "running": false,
      "open_requests": [
        { "id": "srq-1a2b3c4d5e6f", "method": "approval",
          "params": { "session_id": "live1", "request_id": "ab12", "command": "rm -rf build" } },
        { "id": "srq-0f0e0d0c0b0a", "method": "clarify",
          "params": { "questions": [{ "qid": "q0", "question": "Framework?", "choices": null }],
                      "answers": { "q0": null } } },
        { "id": "srq-bbbbbbbbbbbb", "method": "sudo" }
      ]
    }
    """
    let response = try decode(ActivateResponse.self, json)
    #expect(response.openRequests.map(\.id) == ["srq-1a2b3c4d5e6f", "srq-0f0e0d0c0b0a", "srq-bbbbbbbbbbbb"])
    #expect(response.openRequests.map(\.method) == ["approval", "clarify", "sudo"])
    #expect(response.openRequests[0].params["command"] == .string("rm -rf build"))
    #expect(response.openRequests[1].params["answers"] == .object(["q0": .null]))
    #expect(response.openRequests[2].params == .null) // missing params → malformed later, not dropped here
  }

  @Test func absentOpenRequestsDecodeAsEmpty() throws {
    let response = try decode(ActivateResponse.self, #"{ "session_id": "live1", "running": true }"#)
    #expect(response.openRequests.isEmpty)
    #expect(response.running == true)
  }

  /// One bad entry must not cost the others (the reconcile treats absence as authoritative,
  /// so dropping the whole list would clear real cards); a non-array is empty; neither throws.
  @Test func malformedOpenRequestsAreDroppedPerEntryWithoutFailingTheResponse() throws {
    let json = """
    {
      "session_id": "live1",
      "running": true,
      "open_requests": [
        { "id": 7, "method": "approval", "params": {} },
        { "method": "clarify", "params": {} },
        "srq-loose",
        null,
        { "id": "srq-ok", "method": "secret", "params": { "env_var": "TOKEN" } }
      ]
    }
    """
    let response = try decode(ActivateResponse.self, json)
    #expect(response.openRequests == [
      OpenRequest(id: "srq-ok", method: "secret", params: .object(["env_var": .string("TOKEN")])),
    ])
    #expect(response.running == true)

    let notAnArray = try decode(
      ActivateResponse.self, #"{ "session_id": "live1", "open_requests": { "id": "srq-x" } }"#
    )
    #expect(notAnArray.openRequests.isEmpty)
    #expect(notAnArray.sessionID == "live1")
  }
}
