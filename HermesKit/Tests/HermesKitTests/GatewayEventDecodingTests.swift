import Foundation
import Testing

@testable import HermesKit

/// Decoding tests for the gateway wire protocol. Frame shapes mirror those captured
/// by the M0 probe (`Probe/fixtures/session-events.jsonl`), trimmed and inlined so
/// the suite is hermetic (the raw fixture is gitignored).
@Suite struct GatewayEventDecodingTests {
  private func frame(_ json: String) throws -> InboundFrame {
    try InboundFrame(data: Data(json.utf8))
  }

  // MARK: Events

  @Test func gatewayReady() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{"name":"default"}}}}"#)
    #expect(f == .event(sessionID: nil, .ready))
  }

  @Test func sessionInfoCarriesFrameSessionIDAndModel() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"8680ce37","payload":{"model":"gpt-5.5","running":true,"version":"0.16.0","cwd":"/Users/x","profile_name":"default"}}}"#)
    guard case let .event(sessionID, .sessionInfo(info)) = f else {
      Issue.record("expected sessionInfo event, got \(f)"); return
    }
    #expect(sessionID == "8680ce37")
    #expect(info.model == "gpt-5.5")
    #expect(info.running == true)
    #expect(info.profileName == "default")
  }

  @Test func messageStartHasNoPayloadKey() throws {
    // Real frames omit `payload` entirely for message.start — must not throw.
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"8680ce37"}}"#)
    #expect(f == .event(sessionID: "8680ce37", .messageStart))
  }

  @Test func messageDelta() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"8680ce37","payload":{"text":"pong"}}}"#)
    #expect(f == .event(sessionID: "8680ce37", .messageDelta(text: "pong")))
  }

  @Test func messageCompleteDecodesUsage() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"8680ce37","payload":{"text":"pong","status":"complete","usage":{"model":"gpt-5.5","input":6303,"output":31,"total":18622,"context_used":18591,"context_max":272000,"context_percent":7,"cost_usd":0.0}}}}"#)
    guard case let .event(_, .messageComplete(text, usage)) = f else {
      Issue.record("expected messageComplete, got \(f)"); return
    }
    #expect(text == "pong")
    #expect(usage?.input == 6303)
    #expect(usage?.output == 31)
    #expect(usage?.contextMax == 272_000)
  }

  @Test func thinkingDelta() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"thinking.delta","session_id":"8680ce37","payload":{"text":"(◔_◔) synthesizing..."}}}"#)
    #expect(f == .event(sessionID: "8680ce37", .thinkingDelta(text: "(◔_◔) synthesizing...")))
  }

  @Test func reasoningDeltaFoldsIntoThinking() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.delta","session_id":"8680ce37","payload":{"text":"weighing options"}}}"#)
    #expect(f == .event(sessionID: "8680ce37", .thinkingDelta(text: "weighing options")))
  }

  @Test func reasoningAvailable() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.available","session_id":"8680ce37","payload":{"text":"pong"}}}"#)
    #expect(f == .event(sessionID: "8680ce37", .reasoningAvailable(text: "pong")))
  }

  @Test func statusUpdateKindIsOpenString() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"status.update","session_id":"8680ce37","payload":{"kind":"lifecycle","text":"raised auto-compaction"}}}"#)
    #expect(f == .event(sessionID: "8680ce37", .statusUpdate(kind: "lifecycle", text: "raised auto-compaction")))
  }

  @Test func toolStartAndComplete() throws {
    let start = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"s","payload":{"tool_id":"t1","name":"read_file","context":"Reading /x","args_text":"path=/x"}}}"#)
    #expect(start == .event(sessionID: "s", .toolStart(
      toolID: "t1", name: "read_file", title: "Reading /x", argsText: "path=/x"
    )))

    let done = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"s","payload":{"tool_id":"t1","name":"read_file","summary":"Read 12 lines","args":{"path":"/x"},"result_text":"ok","duration_s":1.5}}}"#)
    #expect(done == .event(sessionID: "s", .toolComplete(
      toolID: "t1", name: "read_file", title: "Read 12 lines",
      args: .object(["path": .string("/x")]), resultText: "ok", inlineDiff: nil, durationS: 1.5
    )))
  }

  @Test func toolCompleteStringifiesObjectResultWhenNoResultText() throws {
    // No result_text (non-verbose) → result object is rendered for the detail sheet.
    let done = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"s","payload":{"tool_id":"t1","name":"grep","result":{"matches":2}}}}"#)
    guard case let .event(_, .toolComplete(_, _, _, _, resultText, _, _)) = done else {
      Issue.record("expected tool.complete event"); return
    }
    #expect(resultText?.contains("\"matches\" : 2") == true)
  }

  // MARK: Interactive requests (synthetic — shapes verified later in M2)

  @Test func approvalRequest() throws {
    // Real wire shape (hermes-agent tools/approval.py): command/description/pattern_key(s),
    // and crucially NO request_id — approvals are session-queue-resolved.
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"s","payload":{"command":"rm -rf /tmp/x","description":"Delete /tmp/x","pattern_key":"rm","pattern_keys":["rm"]}}}"#)
    #expect(f == .event(sessionID: "s", .approvalRequest(ApprovalRequest(
      command: "rm -rf /tmp/x", detail: "Delete /tmp/x", patternKey: "rm", patternKeys: ["rm"]
    ))))
  }

  // Regression (#approval-hang): a payload without `request_id` must still decode to
  // `.approvalRequest` — previously the required `request_id` made it fall through to
  // `.unknown`, so the approval card never appeared and the turn hung on "Thinking".
  @Test func approvalRequestWithoutRequestIDStillDecodes() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"s","payload":{"command":"rm foo"}}}"#)
    guard case .event(_, .approvalRequest) = f else {
      Issue.record("expected .approvalRequest, got \(f)")
      return
    }
  }

  @Test func clarifyRequestWithChoices() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"s","payload":{"request_id":"r2","question":"Which file?","choices":["a.txt","b.txt"]}}}"#)
    #expect(f == .event(sessionID: "s", .clarifyRequest(ClarifyRequest(requestID: "r2", question: "Which file?", choices: ["a.txt", "b.txt"]))))
  }

  @Test func clarifyRequestWithoutChoicesDefaultsToEmpty() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"s","payload":{"request_id":"r3","question":"Name?"}}}"#)
    #expect(f == .event(sessionID: "s", .clarifyRequest(ClarifyRequest(requestID: "r3", question: "Name?", choices: []))))
  }

  @Test func secretRequest() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"secret.request","session_id":"s","payload":{"request_id":"r4","prompt":"API key?"}}}"#)
    #expect(f == .event(sessionID: "s", .secretRequest(SecretPrompt(requestID: "r4", prompt: "API key?"))))
  }

  // MARK: Forward-compatibility

  @Test func unknownEventTypeDecodesToUnknownAndNeverThrows() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.progress","session_id":"s","payload":{"pct":42}}}"#)
    guard case let .event(sessionID, .unknown(type, raw)) = f else {
      Issue.record("expected unknown event, got \(f)"); return
    }
    #expect(sessionID == "s")
    #expect(type == "tool.progress")
    #expect(raw == .object(["pct": .number(42)]))
  }

  @Test func unknownEventWithoutPayloadStillDecodes() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"made.up.event"}}"#)
    #expect(f == .event(sessionID: nil, .unknown(type: "made.up.event", raw: .object([:]))))
  }

  // MARK: Responses

  @Test func sessionCreateResultIsResponseAndDecodesHandle() throws {
    let f = try frame(#"{"jsonrpc":"2.0","id":1,"result":{"session_id":"8680ce37","stored_session_id":"20260610_120231_afcca6","message_count":0,"messages":[]}}"#)
    guard case let .response(id, result) = f else {
      Issue.record("expected response, got \(f)"); return
    }
    #expect(id == 1)
    let handle = result.decoded(SessionHandle.self)
    #expect(handle?.sessionID == "8680ce37")
    #expect(handle?.storedSessionID == "20260610_120231_afcca6")
    #expect(handle?.messageCount == 0)
  }

  @Test func promptSubmitResult() throws {
    let f = try frame(#"{"jsonrpc":"2.0","id":2,"result":{"status":"streaming"}}"#)
    #expect(f == .response(id: 2, result: .object(["status": .string("streaming")])))
  }

  @Test func errorResponse() throws {
    let f = try frame(#"{"jsonrpc":"2.0","id":3,"error":{"message":"bad session"}}"#)
    #expect(f == .failure(id: 3, message: "bad session"))
  }

  @Test func nonEventNotificationIsIgnored() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"something.else","params":{}}"#)
    #expect(f == .ignored)
  }
}
