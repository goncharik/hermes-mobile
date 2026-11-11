import Foundation
import Testing

@testable import HermesKit

/// The clarify card's form rules (`ClarifyDraft`), the locked-answer display, and which cards
/// `ChatView` gives layout priority (`isCompressibleCardPending`) — the logic behind the
/// rebuilt `ClarifyCardView`, kept in HermesKit so the view stays declarative.
@Suite struct ClarifyDraftTests {
  private let pickOne = ClarifyQuestion(
    qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"])
  private let pickMany = ClarifyQuestion(
    qid: "q1", question: "Targets?", choices: ["iOS", "macOS", "visionOS"], multiSelect: true)
  private let freeText = ClarifyQuestion(qid: "q2", question: "Name?")

  private var batch: ClarifyRequest {
    ClarifyRequest(requestID: nil, questions: [pickOne, pickMany, freeText], answerShape: .answers)
  }

  // MARK: - Picking

  @Test func nothingIsPreselected() {
    let draft = ClarifyDraft()
    #expect(!draft.isPicked("SwiftUI (Recommended)", in: pickOne))
    #expect(draft.answer(for: pickOne) == nil)
    #expect(draft.answers(for: batch).isEmpty)
    #expect(!draft.isComplete(for: batch))
  }

  @Test func singleSelectHoldsOnePickRadioStyle() {
    var draft = ClarifyDraft()
    draft.toggle("UIKit", in: pickOne)
    draft.toggle("SwiftUI (Recommended)", in: pickOne)
    #expect(draft.answer(for: pickOne) == .choices(["SwiftUI (Recommended)"]))
    draft.toggle("SwiftUI (Recommended)", in: pickOne)
    #expect(draft.answer(for: pickOne) == .choices(["SwiftUI (Recommended)"]), "tapping the pick again keeps it")
  }

  @Test func multiSelectTogglesInTheServersOrder() {
    var draft = ClarifyDraft()
    draft.toggle("visionOS", in: pickMany)
    draft.toggle("iOS", in: pickMany)
    #expect(draft.answer(for: pickMany) == .choices(["iOS", "visionOS"]))
    draft.toggle("visionOS", in: pickMany)
    #expect(draft.answer(for: pickMany) == .choices(["iOS"]))
    draft.toggle("iOS", in: pickMany)
    #expect(draft.answer(for: pickMany) == nil, "un-picking everything leaves no answer")
  }

  @Test func aChoiceTheQuestionDoesNotOfferIsIgnored() {
    var draft = ClarifyDraft()
    draft.toggle("Android", in: pickMany)
    #expect(draft.answer(for: pickMany) == nil)
  }

  // MARK: - Other / free text

  @Test func typingOtherReplacesThePicksAndPickingClearsTheText() {
    var draft = ClarifyDraft()
    draft.toggle("iOS", in: pickMany)
    draft.setText("  watchOS  ", for: pickMany)
    #expect(draft.answer(for: pickMany) == .other("watchOS"), "typed text goes out trimmed")
    #expect(!draft.isPicked("iOS", in: pickMany))

    draft.toggle("macOS", in: pickMany)
    #expect(draft.text(for: pickMany).isEmpty)
    #expect(draft.answer(for: pickMany) == .choices(["macOS"]))
  }

  @Test func blankTextIsNoAnswerAndKeepsThePicks() {
    var draft = ClarifyDraft()
    draft.toggle("UIKit", in: pickOne)
    draft.setText("   ", for: pickOne)
    #expect(draft.answer(for: pickOne) == .choices(["UIKit"]))
    draft.setText(" \n", for: freeText)
    #expect(draft.answer(for: freeText) == nil)
  }

  @Test func freeTextAnswersAsOther() {
    var draft = ClarifyDraft()
    draft.setText("feature/clarify", for: freeText)
    #expect(draft.answer(for: freeText) == .other("feature/clarify"))
  }

  // MARK: - Skip

  @Test func skipIsTheAnswerWhileItStandsAndAnyEditUnskips() {
    var draft = ClarifyDraft()
    draft.setText("draft", for: freeText)
    draft.toggleSkip(freeText)
    #expect(draft.isSkipped(freeText))
    #expect(draft.answer(for: freeText) == .skipped)
    draft.toggleSkip(freeText)
    #expect(draft.answer(for: freeText) == .other("draft"), "un-skipping brings the edit back")

    draft.toggleSkip(pickOne)
    draft.toggle("UIKit", in: pickOne)
    #expect(!draft.isSkipped(pickOne))
    #expect(draft.answer(for: pickOne) == .choices(["UIKit"]))
  }

  @Test func unskippingRestoresPicksAndOtherText() {
    // The card disables a skipped question's inputs; toggling Skip off must bring back
    // exactly what was there.
    var draft = ClarifyDraft()
    draft.toggle("iOS", in: pickMany)
    draft.toggle("visionOS", in: pickMany)
    draft.toggleSkip(pickMany)
    #expect(draft.isPicked("iOS", in: pickMany), "the picks stay visible under the skip")
    #expect(draft.answer(for: pickMany) == .skipped)
    draft.toggleSkip(pickMany)
    #expect(draft.answer(for: pickMany) == .choices(["iOS", "visionOS"]))

    draft.setText("Flutter", for: pickOne)
    draft.toggleSkip(pickOne)
    #expect(draft.text(for: pickOne) == "Flutter")
    draft.toggleSkip(pickOne)
    #expect(draft.answer(for: pickOne) == .other("Flutter"))
  }

  @Test func blankTextKeepsTheSkip() {
    var draft = ClarifyDraft()
    draft.toggleSkip(freeText)
    draft.setText("  ", for: freeText)
    #expect(draft.isSkipped(freeText))
    #expect(draft.answer(for: freeText) == .skipped)
  }

  // MARK: - Form routing (what the card renders and how it submits)

  @Test func singleSelectSubmitsOnTapWithAnOtherRowOnV7Only() {
    let v7 = ClarifyRequest(requestID: nil, questions: [pickOne], answerShape: .answers)
    #expect(v7.submitsOnTap)
    #expect(v7.offersOtherRow)
    #expect(v7.submitTitle == "Send") // for the Other row's typed answer

    let legacy = ClarifyRequest(requestID: "r1", question: "Framework?", choices: ["SwiftUI", "UIKit"])
    #expect(legacy.submitsOnTap)
    #expect(!legacy.offersOtherRow)
    #expect(legacy.submitTitle == nil) // a tap on a choice is the only way to answer
  }

  @Test func multiSelectFreeTextAndBatchFormsHaveTheirButtons() {
    let multi = ClarifyRequest(requestID: nil, questions: [pickMany], answerShape: .answers)
    #expect(!multi.submitsOnTap)
    #expect(multi.submitTitle == "Submit")

    let free = ClarifyRequest(requestID: nil, questions: [freeText], answerShape: .answers)
    #expect(!free.submitsOnTap)
    #expect(free.submitTitle == "Send")

    #expect(!batch.submitsOnTap) // choices select; Confirm submits
    #expect(batch.submitTitle == "Confirm")
    let legacyBatch = ClarifyRequest(requestID: "r1", questions: [pickOne, freeText], answerShape: .legacyRespond)
    #expect(legacyBatch.submitTitle == "Confirm")
    #expect(!legacyBatch.offersOtherRow)
  }

  @Test func returnSendsOnlyACompleteSingleQuestionCard() {
    let single = ClarifyRequest(requestID: nil, questions: [pickOne], answerShape: .answers)
    var draft = ClarifyDraft()
    #expect(!draft.sendsOnReturn(for: single))
    draft.setText("Flutter", for: pickOne)
    #expect(draft.sendsOnReturn(for: single))

    var batchDraft = ClarifyDraft()
    batchDraft.toggle("UIKit", in: pickOne)
    batchDraft.toggle("iOS", in: pickMany)
    batchDraft.setText("app", for: freeText)
    #expect(batchDraft.isComplete(for: batch))
    #expect(!batchDraft.sendsOnReturn(for: batch), "a batch submits only with Confirm")
  }

  // MARK: - The form as a whole

  @Test func completeOnlyWhenEveryQuestionIsAnsweredOrSkipped() {
    var draft = ClarifyDraft()
    draft.toggle("UIKit", in: pickOne)
    draft.toggle("iOS", in: pickMany)
    #expect(!draft.isComplete(for: batch))
    draft.toggleSkip(freeText)
    #expect(draft.isComplete(for: batch))
    #expect(draft.answers(for: batch) == [
      "q0": .choices(["UIKit"]), "q1": .choices(["iOS"]), "q2": .skipped,
    ])
  }

  @Test func lockedQuestionsCountAsAnsweredAndAreNotResubmittedByTheDraft() {
    var request = batch
    request.lockedAnswers = ["q0": "SwiftUI", "q1": String?.none]
    var draft = ClarifyDraft()
    // An edit to a question that is now locked (a replay landed mid-edit) is not submitted:
    // the reducer re-sends the lock instead.
    draft.toggle("UIKit", in: pickOne)
    #expect(!draft.isComplete(for: request))
    draft.setText("app", for: freeText)
    #expect(draft.isComplete(for: request))
    #expect(draft.answers(for: request) == ["q2": .other("app")])
  }

  @Test func progressCountsSettledQuestionsAndReadsNOfNExactlyWhenComplete() {
    var draft = ClarifyDraft()
    #expect(draft.progressText(for: batch) == "0 of 3 answered")
    draft.toggle("UIKit", in: pickOne)
    #expect(draft.progressText(for: batch) == "1 of 3 answered")
    draft.toggleSkip(freeText)
    #expect(draft.progressText(for: batch) == "2 of 3 answered", "a skip settles a question")
    #expect(!draft.isComplete(for: batch))
    draft.toggle("iOS", in: pickMany)
    #expect(draft.progressText(for: batch) == "3 of 3 answered")
    #expect(draft.isComplete(for: batch))
    draft.toggle("iOS", in: pickMany)
    #expect(draft.progressText(for: batch) == "2 of 3 answered", "un-picking unsettles it again")
  }

  @Test func progressCountsLocksAndBlankTextIsNotAnAnswer() {
    var request = batch
    request.lockedAnswers = ["q1": String?.none]
    var draft = ClarifyDraft()
    #expect(draft.progressText(for: request) == "1 of 3 answered")
    draft.setText("  ", for: freeText)
    #expect(draft.progressText(for: request) == "1 of 3 answered")
    #expect(draft.isSettled(pickMany, in: request))
    #expect(!draft.isSettled(freeText, in: request))
  }

  @Test func aOneQuestionCardHasNoProgressCaption() {
    let single = ClarifyRequest(requestID: nil, questions: [pickMany], answerShape: .answers)
    var draft = ClarifyDraft()
    draft.toggle("iOS", in: pickMany)
    #expect(draft.progressText(for: single) == nil)
    let legacy = ClarifyRequest(requestID: "r1", question: "Proceed?", choices: ["Yes", "No"])
    #expect(ClarifyDraft().progressText(for: legacy) == nil)
  }

  @Test func singleFormsKeyTheirAnswerOnTheEmptyKey() {
    let single = ClarifyRequest(requestID: nil, question: "Proceed?", choices: ["Yes", "No"])
    let question = single.questions[0]
    #expect(question.answerKey == "")
    var draft = ClarifyDraft()
    draft.toggle("Yes", in: question)
    #expect(draft.answers(for: single) == ["": .choices(["Yes"])])
  }

  // MARK: - Locked display

  @Test func lockedDisplayText() {
    var request = batch
    request.lockedAnswers = ["q0": "SwiftUI", "q1": #"["iOS","macOS"]"#, "q2": String?.none]
    #expect(request.isLocked(pickOne))
    #expect(request.lockedDisplayText(for: pickOne) == "SwiftUI")
    #expect(request.lockedDisplayText(for: pickMany) == "iOS, macOS")
    #expect(request.lockedDisplayText(for: freeText) == "Skipped")

    let open = batch
    #expect(!open.isLocked(pickOne))
    #expect(open.lockedDisplayText(for: pickOne) == nil)
    // The nil-qid single form can never be locked.
    let single = ClarifyRequest(requestID: nil, question: "Proceed?")
    #expect(!single.isLocked(single.questions[0]))
  }

  // MARK: - Echo

  @Test(arguments: [
    ("What type of site?", "What type of site? php"),
    ("Pick one:", "Pick one: php"),
    ("Describe the site.", "Describe the site. php"),
    ("Ready!", "Ready! php"),
    ("Wait…", "Wait… php"),
    ("どのサイト？", "どのサイト？ php"),
    ("  Name?  ", "Name? php"),
    ("Name", "Name: php"),
    ("Which (optional)", "Which (optional): php"),
    ("Use \"strict\"", "Use \"strict\": php"),
  ])
  func echoLineAddsAColonOnlyWithoutTerminalPunctuation(question: String, line: String) {
    #expect(ClarifyQuestion(qid: "q0", question: question).echoLine(answer: "php") == line)
  }

  @Test func aLockedMultiSelectThatIsNotAnArrayShowsAsSent() {
    var request = batch
    request.lockedAnswers = ["q1": "typed other"]
    #expect(request.lockedDisplayText(for: pickMany) == "typed other")
  }

  // MARK: - Layout priority

  @Test @MainActor func onlyApprovalsAndMultiQuestionClarifyAreCompressible() {
    var state = ChatFeature.State(
      connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"))
    #expect(!state.isCompressibleCardPending, "no card")

    state.present(.approval(ApprovalRequest(command: "rm -rf build", detail: nil)))
    #expect(state.isCompressibleCardPending)

    state.present(.clarify(batch))
    #expect(state.isCompressibleCardPending, "a multi-question clarify absorbs the squeeze")

    state.present(.clarify(ClarifyRequest(requestID: nil, question: "Proceed?", choices: ["Yes", "No"])))
    #expect(!state.isCompressibleCardPending, "a single question hugs its form")

    state.present(.secret(.sudo, SecretPrompt(command: "apt install ripgrep")))
    #expect(!state.isCompressibleCardPending)
  }
}
