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

  // The sequencing fields (`seq`, `replay_epoch`, `session_authority`) are pinned in
  // `JSONRPCTests`; the fixtures here carry none (except `requestCancelDecodes`), so these
  // tests compare only `session_id` + event through the two helpers at the bottom of the file.

  // MARK: Events

  @Test func gatewayReady() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{"name":"default"}}}}"#)
    #expect(f == .event(sessionID: nil, .ready))
  }

  @Test func sessionInfoCarriesFrameSessionIDAndModel() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"8680ce37","payload":{"model":"gpt-5.5","running":true,"version":"0.16.0","cwd":"/Users/x","profile_name":"default"}}}"#)
    guard case let (sessionID, .sessionInfo(info))? = f.eventParts else {
      Issue.record("expected sessionInfo event, got \(f)"); return
    }
    #expect(sessionID == "8680ce37")
    #expect(info.model == "gpt-5.5")
    #expect(info.running == true)
    #expect(info.profileName == "default")
    #expect(info.desktopContract == nil) // absent on legacy/old agents
  }

  @Test(arguments: [(#"7"#, 7), (#""8""#, 8), (#""x""#, nil)] as [(String, Int?)])
  func sessionInfoEventCarriesDesktopContract(raw: String, expected: Int?) throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"s","payload":{"model":"gpt-5.5","desktop_contract":\#(raw)}}}"#)
    guard case let (_, .sessionInfo(info))? = f.eventParts else {
      Issue.record("expected sessionInfo event, got \(f)"); return
    }
    #expect(info.desktopContract == expected)
    #expect(info.model == "gpt-5.5") // a non-numeric contract never costs the other fields
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
    guard case let (_, .messageComplete(text, usage))? = f.eventParts else {
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
    guard case let (_, .toolComplete(_, _, _, _, resultText, _, _))? = done.eventParts else {
      Issue.record("expected tool.complete event"); return
    }
    #expect(resultText?.contains("\"matches\" : 2") == true)
  }

  // MARK: Interactive requests (synthetic — shapes verified later in M2)

  @Test func approvalRequest() throws {
    // The legacy payload omits request_id and choices; the client keeps the old FIFO
    // response shape for that case.
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"s","payload":{"command":"rm -rf /tmp/x","description":"Delete /tmp/x","pattern_key":"rm","pattern_keys":["rm"]}}}"#)
    #expect(f == .event(sessionID: "s", .approvalRequest(ApprovalRequest(
      command: "rm -rf /tmp/x", detail: "Delete /tmp/x", patternKey: "rm", patternKeys: ["rm"]
    ))))
  }

  @Test func approvalRequestCarriesRequestIDAndChoices() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"s","payload":{"request_id":"approval-7","command":"rm foo","choices":["once","deny"]}}}"#)
    #expect(f == .event(sessionID: "s", .approvalRequest(ApprovalRequest(
      requestID: "approval-7", command: "rm foo", choices: ["once", "deny"]
    ))))
  }

  @Test func approvalChoicesNarrowSessionApproval() {
    let request = ApprovalRequest(command: "rm foo", choices: ["once", "deny"])
    #expect(request.allowsOnce)
    #expect(!request.allowsSessionChoice)
    #expect(!request.offersSessionApproval)
  }

  @Test func requestCancelDecodes() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","session_id":"live","seq":123,"payload":{"id":"srq-1a2b3c4d5e6f","method":"approval","reason":"timeout"}}}"#)
    #expect(f == .event(GatewayFrame(.requestCancel(RequestCancel(
      id: "srq-1a2b3c4d5e6f", method: "approval", reason: "timeout"
    )), sessionID: "live", seq: 123)))
    let bare = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","payload":{"id":"srq-x"}}}"#)
    #expect(bare == .event(sessionID: nil, .requestCancel(RequestCancel(id: "srq-x"))))
  }

  @Test func requestCancelWithoutIDIsUnknown() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","payload":{"reason":"timeout"}}}"#)
    guard case (_, .unknown(type: "request.cancel", _))? = f.eventParts else {
      Issue.record("expected .unknown, got \(f)"); return
    }
  }

  /// Rendered server requests decode into the queue entry; content-less or malformed
  /// approval params and unrendered methods do not. Only non-object params of a rendered
  /// method get an automatic skip; an undecodable object gets none.
  @Test func pendingServerRequestDecoding() {
    let approval = PendingServerRequest(
      id: "srq-1", method: "approval",
      params: .object(["session_id": .string("live"), "description": .string("Delete build")])
    )
    #expect(approval == PendingServerRequest(id: "srq-1", kind: .approval(ApprovalRequest(detail: "Delete build"))))
    #expect(approval?.method == .approval)
    #expect(PendingServerRequest(id: "srq-2", method: "approval", params: .object(["session_id": .string("live")])) == nil)
    #expect(PendingServerRequest(id: "srq-3", method: "approval", params: .null) == nil)
    #expect(PendingServerRequest(id: "srq-4", method: "vault.code", params: .object([:])) == nil)
    #expect(PendingServerRequest.malformedSkip(for: "approval", params: .null) == .object(["choice": .string("deny")]))
    #expect(PendingServerRequest.malformedSkip(for: "approval", params: .array([])) == .object(["choice": .string("deny")]))
    #expect(PendingServerRequest.malformedSkip(for: "approval", params: .object(["session_id": .string("live")])) == nil)
    #expect(PendingServerRequest.malformedSkip(for: "vault.code", params: .null) == nil)
    #expect(PendingServerRequest.malformedSkip(for: "tour", params: .null) == nil)
    #expect(Set(PromptMethod.allCases.map(\.rawValue)) == ["approval", "clarify", "sudo", "secret"])
  }

  /// The card renders only the command and the description, so a danger pattern alone, or a
  /// blank command/description, is a blind card: it does not decode and gets no automatic
  /// answer. A non-blank field beside a pattern decodes.
  @Test(arguments: [
    JSONValue.object(["pattern_key": .string("rm_rf")]),
    .object(["pattern_keys": .array([.string("rm_rf"), .string("sudo")])]),
    .object(["command": .string("  \n"), "description": .string("\t"), "pattern_key": .string("rm_rf")]),
  ])
  func approvalWithNothingVisibleIsNotRendered(params: JSONValue) {
    #expect(PendingServerRequest(id: "srq-p", method: "approval", params: params) == nil)
    #expect(PendingServerRequest.malformedSkip(for: "approval", params: params) == nil)
  }

  @Test func approvalWithAVisibleFieldBesideAPatternDecodes() throws {
    let request = try #require(PendingServerRequest(
      id: "srq-p", method: "approval",
      params: .object(["command": .string("  \n"), "description": .string("Delete build"), "pattern_key": .string("rm_rf")])
    ))
    #expect(request.kind == .approval(ApprovalRequest(command: "  \n", detail: "Delete build", patternKey: "rm_rf")))
  }

  @Test func serverRequestLogEntryNamesTheMethod() {
    let entry = GatewayLogEntry(id: 0, event: .serverRequest(PendingServerRequest(
      id: "srq-1", kind: .approval(ApprovalRequest(command: "rm foo"))
    )))
    #expect(entry.type == "approval")
    #expect(entry.summary == "rm foo")
    let cancel = GatewayLogEntry(id: 1, event: .requestCancel(RequestCancel(id: "srq-1", method: "approval", reason: "timeout")))
    #expect(cancel.type == "request.cancel")
    #expect(cancel.summary == "approval timeout srq-1")
    let bareCancel = GatewayLogEntry(id: 2, event: .requestCancel(RequestCancel(id: "srq-1")))
    #expect(bareCancel.summary == "srq-1")
  }

  @Test func approvalRequestWithoutRequestIDStillDecodes() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"s","payload":{"command":"rm foo"}}}"#)
    guard case (_, .approvalRequest)? = f.eventParts else {
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

  @Test func legacyClarifyEventKeepsItsSingleRespondShape() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"s","payload":{"request_id":"r2","question":"Which file?","choices":["a.txt","b.txt"]}}}"#)
    guard case let (_, .clarifyRequest(request))? = f.eventParts else {
      Issue.record("expected .clarifyRequest, got \(f)"); return
    }
    #expect(request.answerShape == .legacyRespond)
    #expect(request.requestID == "r2")
    #expect(request.questions == [ClarifyQuestion(qid: nil, question: "Which file?", choices: ["a.txt", "b.txt"])])
    #expect(request.lockedAnswers.isEmpty)
    #expect(!request.isMultiQuestion)
  }

  @Test func legacyClarifyEventWithoutQuestionStillDecodesAsToday() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"s","payload":{"request_id":"r9"}}}"#)
    #expect(f == .event(sessionID: "s", .clarifyRequest(ClarifyRequest(requestID: "r9", question: ""))))
  }

  /// v2026.9.11 emits a multi-question clarify as ONE legacy `clarify.request` carrying the
  /// batch's `questions` and the `request_id` (`_clarify_block`): it raises the multi-question
  /// card on the legacy answer path, instead of being dropped.
  @Test func legacyBatchClarifyEventKeepsItsQuestions() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"s","payload":{"questions":[{"qid":"q0","question":"Framework?","choices":["SwiftUI (Recommended)","UIKit"],"multi_select":false},{"qid":"q1","question":"Targets?","choices":["iOS","macOS"],"multi_select":true},{"qid":"q2","question":"Name?","choices":null,"multi_select":false}],"request_id":"rb1"}}}"#)
    #expect(f == .event(sessionID: "s", .clarifyRequest(ClarifyRequest(
      requestID: "rb1",
      questions: [
        ClarifyQuestion(qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"]),
        ClarifyQuestion(qid: "q1", question: "Targets?", choices: ["iOS", "macOS"], multiSelect: true),
        ClarifyQuestion(qid: "q2", question: "Name?"),
      ],
      answerShape: .legacyRespond
    ))))
  }

  /// The two sources never guess each other's shape: a server request with a stray
  /// `request_id` is still v7 (and its batch keeps `.answers`); a legacy event with
  /// `questions` is still legacy.
  @Test func clarifySourceDecidesTheAnswerShape() throws {
    let batch: JSONValue = .object([
      "request_id": .string("r1"),
      "questions": .array([.object(["qid": .string("q0"), "question": .string("A?")])]),
    ])
    #expect(ClarifyRequest(serverRequestParams: batch)?.answerShape == .answers)
    #expect(ClarifyRequest(serverRequestParams: batch)?.requestID == nil)
    #expect(ClarifyRequest(legacyEvent: batch)?.answerShape == .legacyRespond)
    #expect(ClarifyRequest(legacyEvent: batch)?.requestID == "r1")
    let single: JSONValue = .object(["request_id": .string("r1"), "question": .string("Q?"), "multi_select": .bool(true), "choices": .array([.string("a"), .string("b")])])
    #expect(ClarifyRequest(serverRequestParams: single) == ClarifyRequest(requestID: nil, question: "Q?", choices: ["a", "b"], multiSelect: true))
    // The legacy single form ignores `multi_select`, as it always did.
    #expect(ClarifyRequest(legacyEvent: single) == ClarifyRequest(requestID: "r1", question: "Q?", choices: ["a", "b"]))
  }

  @Test func legacyClarifyEventWithoutRequestIDIsUnknown() throws {
    // Only the `request_id` form is the legacy wire; a server-request shape on the legacy
    // event name is not presented (it has no answer path there).
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"s","payload":{"question":"Which file?"}}}"#)
    guard case (_, .unknown(type: "clarify.request", _))? = f.eventParts else {
      Issue.record("expected .unknown, got \(f)"); return
    }
  }

  // MARK: Clarify server-request params (all three wire generations)

  private func clarify(_ json: String) -> ClarifyRequest? {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))).flatMap(ClarifyRequest.init(serverRequestParams:))
  }

  @Test func clarifySingleSelectAsOneEntryQuestions() throws {
    let request = try #require(clarify(#"{"session_id":"live","questions":[{"qid":"q0","question":"Framework?","choices":["SwiftUI (Recommended)","UIKit"],"multi_select":false}]}"#))
    #expect(request.answerShape == .answers)
    #expect(request.requestID == nil)
    #expect(!request.isMultiQuestion)
    #expect(request.questions == [
      ClarifyQuestion(qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"]),
    ])
    #expect(request.question == "Framework?")
    #expect(request.questions.first?.choices == ["SwiftUI (Recommended)", "UIKit"]) // raw; split for display
    #expect(request.lockedAnswers.isEmpty)
  }

  @Test func clarifyFreeTextAsOneEntryQuestionsWithNullChoices() throws {
    let request = try #require(clarify(#"{"session_id":"live","questions":[{"qid":"q0","question":"Branch name?","choices":null,"multi_select":false}]}"#))
    #expect(request.answerShape == .answers)
    #expect(!request.isMultiQuestion)
    let question = try #require(request.questions.first)
    #expect(question.qid == "q0")
    #expect(question.isFreeText)
    #expect(!question.multiSelect)
  }

  @Test func clarifyFreeTextIsNeverMultiSelect() throws {
    let request = try #require(clarify(#"{"questions":[{"qid":"q0","question":"Name?","multi_select":true}]}"#))
    #expect(request.questions.first?.multiSelect == false)
  }

  @Test func clarifyThreeMixedQuestions() throws {
    let request = try #require(clarify(#"{"session_id":"live","questions":[{"qid":"q0","question":"Framework?","choices":["SwiftUI (Recommended)","UIKit"],"multi_select":false},{"qid":"q1","question":"Targets?","choices":["iOS","macOS","visionOS"],"multi_select":true},{"qid":"q2","question":"App name?","choices":null,"multi_select":false}],"future_key":{"x":1}}"#))
    #expect(request.answerShape == .answers)
    #expect(request.isMultiQuestion)
    #expect(request.questions == [
      ClarifyQuestion(qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"]),
      ClarifyQuestion(qid: "q1", question: "Targets?", choices: ["iOS", "macOS", "visionOS"], multiSelect: true),
      ClarifyQuestion(qid: "q2", question: "App name?"),
    ])
  }

  @Test func clarifyReplayedAnswersLockIncludingNull() throws {
    let request = try #require(clarify(#"{"session_id":"live","questions":[{"qid":"q0","question":"Framework?","choices":["SwiftUI (Recommended)","UIKit"],"multi_select":false},{"qid":"q1","question":"Targets?","choices":["iOS","macOS"],"multi_select":true},{"qid":"q2","question":"Name?","choices":null}],"answers":{"q0":"SwiftUI","q1":null,"q2":42}}"#))
    let expected: [String: String?] = ["q0": "SwiftUI", "q1": nil]
    #expect(request.lockedAnswers == expected)
    #expect(request.lockedAnswers["q1"] == .some(nil)) // a locked skip, not "absent"
    #expect(request.lockedAnswers["q2"] == nil)         // a non-string lock is ignored
  }

  @Test func clarifyMalformedQuestionEntryIsDroppedNotFatal() throws {
    let request = try #require(clarify(#"{"questions":[{"question":"No qid?"},{"qid":"q1","question":"   "},"junk",{"qid":"q2","question":"Kept?","choices":["a",1,"b"]}]}"#))
    #expect(request.questions == [ClarifyQuestion(qid: "q2", question: "Kept?", choices: ["a", "b"])])
    #expect(!request.isMultiQuestion)
  }

  @Test func clarifyIntermediateSingleWithoutMultiSelect() throws {
    let request = try #require(clarify(#"{"session_id":"live","question":"Proceed?","choices":["Yes","No"]}"#))
    #expect(request.answerShape == .singleAnswer)
    #expect(request.requestID == nil)
    #expect(request.questions == [ClarifyQuestion(qid: nil, question: "Proceed?", choices: ["Yes", "No"])])
    #expect(request == ClarifyRequest(requestID: nil, question: "Proceed?", choices: ["Yes", "No"]))
  }

  @Test func clarifyIntermediateSingleWithMultiSelect() throws {
    let request = try #require(clarify(#"{"session_id":"live","question":"Targets?","choices":["iOS","macOS"],"multi_select":true}"#))
    #expect(request.answerShape == .singleAnswer)
    #expect(request.questions == [ClarifyQuestion(qid: nil, question: "Targets?", choices: ["iOS", "macOS"], multiSelect: true)])
  }

  @Test func clarifyIntermediateSingleFreeText() throws {
    let request = try #require(clarify(#"{"session_id":"live","question":"Name?","choices":null}"#))
    #expect(request.answerShape == .singleAnswer)
    #expect(request.questions.first?.isFreeText == true)
  }

  @Test func clarifyIntermediateBatch() throws {
    let request = try #require(clarify(#"{"session_id":"live","questions":[{"qid":"q0","question":"Framework?","choices":["SwiftUI","UIKit"]},{"qid":"q1","question":"Name?"}]}"#))
    #expect(request.answerShape == .answers)
    #expect(request.isMultiQuestion)
    #expect(request.questions == [
      ClarifyQuestion(qid: "q0", question: "Framework?", choices: ["SwiftUI", "UIKit"]),
      ClarifyQuestion(qid: "q1", question: "Name?"),
    ])
  }

  @Test(arguments: [
    #"{}"#,
    #"{"session_id":"live"}"#,
    #"{"questions":[]}"#,
    #"{"questions":null}"#,
    #"{"questions":[{"question":"No qid"}]}"#,
    #"{"questions":[{"qid":"q0"}]}"#,
    #"{"question":"   "}"#,
    #"{"question":42}"#,
    #"[1,2]"#,
    #""text""#,
  ])
  func clarifyWithoutUsableQuestionFailsToDecode(json: String) {
    #expect(clarify(json) == nil)
  }

  @Test func clarifyConvenienceInitPicksShapeFromRequestID() {
    #expect(ClarifyRequest(requestID: "r", question: "Q?").answerShape == .legacyRespond)
    #expect(ClarifyRequest(requestID: nil, question: "Q?").answerShape == .singleAnswer)
    #expect(ClarifyRequest(requestID: nil, question: "Q?", multiSelect: true).questions.first?.multiSelect == false)
  }

  @Test func secretRequest() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"secret.request","session_id":"s","payload":{"request_id":"r4","prompt":"API key?"}}}"#)
    #expect(f == .event(sessionID: "s", .secretRequest(SecretPrompt(requestID: "r4", prompt: "API key?"))))
  }

  @Test func legacySudoRequest() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"sudo.request","session_id":"s","payload":{"request_id":"r5"}}}"#)
    #expect(f == .event(sessionID: "s", .sudoRequest(SecretPrompt(requestID: "r5"))))
  }

  /// The legacy events stay `request_id`-bound: without one there is nothing to answer
  /// through `sudo.respond` / `secret.respond`, so they are `.unknown` exactly as before
  /// `SecretPrompt.requestID` became optional.
  @Test(arguments: ["sudo.request", "secret.request"])
  func legacySecretEventWithoutRequestIDIsUnknown(type: String) throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"\#(type)","session_id":"s","payload":{"prompt":"Password"}}}"#)
    guard case (_, .unknown(type: type, _))? = f.eventParts else {
      Issue.record("expected .unknown, got \(f)"); return
    }
  }

  // MARK: v7 sudo / secret server requests

  /// v2026.9.21+ sudo carries the redacted `command`; v2026.9.14 sends empty params — both
  /// render. A stray legacy `request_id` is dropped (the srq id identifies a v7 prompt).
  @Test func sudoServerRequestDecodesWithAndWithoutCommand() {
    let withCommand = PendingServerRequest(id: "srq-bbbbbbbbbbbb", method: "sudo", params: .object([
      "session_id": .string("live"), "command": .string("apt install ripgrep"),
    ]))
    #expect(withCommand == PendingServerRequest(
      id: "srq-bbbbbbbbbbbb", kind: .secret(.sudo, SecretPrompt(command: "apt install ripgrep"))
    ))
    #expect(withCommand?.method == .sudo)

    let empty = PendingServerRequest(id: "srq-e", method: "sudo", params: .object(["session_id": .string("live")]))
    #expect(empty == PendingServerRequest(id: "srq-e", kind: .secret(.sudo, SecretPrompt())))

    let stray = PendingServerRequest(id: "srq-s", method: "sudo", params: .object([
      "request_id": .string("r1"), "command": .string("ls"),
    ]))
    #expect(stray == PendingServerRequest(id: "srq-s", kind: .secret(.sudo, SecretPrompt(command: "ls"))))
  }

  @Test func secretServerRequestDecodesEnvVar() {
    let request = PendingServerRequest(id: "srq-sec", method: "secret", params: .object([
      "session_id": .string("live"), "env_var": .string("OPENWEATHER_API_KEY"),
      "prompt": .string("Weather API key"), "metadata": .object(["skill": .string("weather")]),
    ]))
    #expect(request == PendingServerRequest(id: "srq-sec", kind: .secret(.secret, SecretPrompt(
      prompt: "Weather API key", envVar: "OPENWEATHER_API_KEY"
    ))))
    #expect(request?.method == .secret)
    // Either field alone names the secret.
    #expect(PendingServerRequest(id: "a", method: "secret", params: .object(["env_var": .string("K")])) != nil)
    #expect(PendingServerRequest(id: "b", method: "secret", params: .object(["prompt": .string("Key?")])) != nil)
  }

  /// The secret card's text: the prompt and the kind's detail line (sudo `command`, secret
  /// `env_var`), each trimmed and `nil` when blank; the other kind's field is never shown.
  @Test func secretPromptDisplayText() {
    let prompt = SecretPrompt(prompt: " Key? ", command: " apt install ripgrep\n", envVar: "OPENWEATHER_API_KEY")
    #expect(prompt.displayPrompt == "Key?")
    #expect(prompt.displayDetail(for: .sudo) == "$ apt install ripgrep")
    #expect(prompt.displayDetail(for: .secret) == "Saved as OPENWEATHER_API_KEY")

    let blank = SecretPrompt(prompt: "  ", command: "\n", envVar: "")
    #expect(blank.displayPrompt == nil)
    #expect(blank.displayDetail(for: .sudo) == nil)
    #expect(blank.displayDetail(for: .secret) == nil)
    #expect(SecretPrompt().displayPrompt == nil)
    #expect(SecretPrompt(command: "ls").displayDetail(for: .secret) == nil)
    #expect(SecretPrompt(envVar: "K").displayDetail(for: .sudo) == nil)
  }

  /// Malformed sudo / secret params (wrong types, not an object, a secret naming nothing)
  /// are not rendered; only the non-object ones get the automatic `{value: ""}` skip.
  @Test(arguments: [
    ("sudo", JSONValue.null), ("sudo", .array([])), ("sudo", .object(["command": .number(9)])),
    ("secret", .null), ("secret", .object(["session_id": .string("live")])),
    ("secret", .object(["env_var": .string("  "), "prompt": .string("")])),
    ("secret", .object(["env_var": .bool(true), "prompt": .string("Key?")])),
  ])
  func malformedSecretServerRequestIsNotRendered(method: String, params: JSONValue) {
    #expect(PendingServerRequest(id: "srq-bad", method: method, params: params) == nil)
    if case .object = params {
      #expect(PendingServerRequest.malformedSkip(for: method, params: params) == nil)
    } else {
      #expect(PendingServerRequest.malformedSkip(for: method, params: params) == .object(["value": .string("")]))
    }
  }

  /// The gateway log mirrors the prompt only — a request never carries the typed value, and
  /// answers (outbound) are never logged.
  @Test func secretServerRequestLogEntryShowsThePromptOnly() {
    let sudo = GatewayLogEntry(id: 0, event: .serverRequest(PendingServerRequest(
      id: "srq-1", kind: .secret(.sudo, SecretPrompt(command: "apt install ripgrep"))
    )))
    #expect(sudo.type == "sudo")
    #expect(sudo.summary == "apt install ripgrep")
    let secret = GatewayLogEntry(id: 1, event: .serverRequest(PendingServerRequest(
      id: "srq-2", kind: .secret(.secret, SecretPrompt(prompt: "Weather API key", envVar: "OPENWEATHER_API_KEY"))
    )))
    #expect(secret.type == "secret")
    #expect(secret.summary == "Weather API key")
    let bare = GatewayLogEntry(id: 2, event: .serverRequest(PendingServerRequest(
      id: "srq-3", kind: .secret(.sudo, SecretPrompt())
    )))
    #expect(bare.summary == "srq-3")
    let legacy = GatewayLogEntry(id: 3, event: .sudoRequest(SecretPrompt(requestID: "r1")))
    #expect(legacy.type == "sudo.request")
    #expect(legacy.summary == "r1")
  }

  // MARK: Review summary (issue #47 — live-only per-session emit, never in history)

  @Test func reviewSummaryDecodesTextVerbatim() throws {
    // Wire shape verified against tui_gateway/server.py: text already carries the 💾 prefix.
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"review.summary","session_id":"8680ce37","payload":{"text":"💾 Self-improvement review: tightened the retry loop."}}}"#)
    #expect(f == .event(
      sessionID: "8680ce37",
      .reviewSummary(text: "💾 Self-improvement review: tightened the retry loop.")
    ))
  }

  @Test func reviewSummaryWithoutTextDecodesToEmptyString() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"review.summary","session_id":"s","payload":{}}}"#)
    #expect(f == .event(sessionID: "s", .reviewSummary(text: "")))
  }

  @Test func reviewSummaryWithoutPayloadDecodesToEmptyString() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"review.summary","session_id":"s"}}"#)
    #expect(f == .event(sessionID: "s", .reviewSummary(text: "")))
  }

  @Test func reviewSummaryWithNonStringTextDecodesToEmptyString() throws {
    // Lenient decode: a wrong-typed `text` (`stringValue` is nil for non-strings) falls
    // back to "" — never throws, never stringifies garbage.
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"review.summary","session_id":"s","payload":{"text":42}}}"#)
    #expect(f == .event(sessionID: "s", .reviewSummary(text: "")))
  }

  // MARK: Forward-compatibility

  @Test func unknownEventTypeDecodesToUnknownAndNeverThrows() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.progress","session_id":"s","payload":{"pct":42}}}"#)
    guard case let (sessionID, .unknown(type, raw))? = f.eventParts else {
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

fileprivate extension InboundFrame {
  /// An unsequenced event frame (no `seq`, no ready fields), for `==` against the fixtures.
  static func event(sessionID: String?, _ event: GatewayEvent) -> InboundFrame {
    .event(GatewayFrame(event, sessionID: sessionID))
  }

  /// `(session_id, event)` of an event frame, for `case let (sid, .x)? = f.eventParts`.
  var eventParts: (String?, GatewayEvent)? {
    guard case let .event(frame) = self else { return nil }
    return (frame.sessionID, frame.event)
  }
}
