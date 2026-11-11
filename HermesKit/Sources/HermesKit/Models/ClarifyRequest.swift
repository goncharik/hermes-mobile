import Foundation

/// One question of a clarify prompt. A v0.21.6+ request always carries a `questions` list
/// (one entry for a single question); the intermediate (v2026.9.14–.24) single form and the
/// legacy `clarify.request` event carry one top-level question, decoded into one of these
/// with a `nil` `qid`.
public struct ClarifyQuestion: Equatable, Sendable {
  /// Stable wire id the answer is keyed by (`q0`…`q4`). `nil` only for the intermediate and
  /// legacy single forms, whose answer is not keyed.
  public var qid: String?
  public var question: String
  /// Raw choices, best first; the first of two or more may carry the server's
  /// `" (Recommended)"` suffix — split it with ``ClarifyChoice/split(_:)`` for display and
  /// for the answer (the bare label is what gets sent). Empty = free text.
  public var choices: [String]
  /// Several choices may be picked (the answer is then a JSON-array string). Always `false`
  /// for a free-text question, as upstream normalizes it.
  public var multiSelect: Bool

  public var isFreeText: Bool { choices.isEmpty }

  /// The key this question's answer travels under in `submitClarify(token:answers:)`: its `qid`,
  /// or `""` for the `nil`-qid question of the intermediate and legacy single forms.
  public var answerKey: String { qid ?? "" }

  /// This question's line in the multi-question transcript echo: `"Name: Atlas"`, but
  /// `"What type of site? php"` when the question already ends in terminal punctuation — a
  /// colon after it read as `"site?: php"`.
  func echoLine(answer: String) -> String {
    let label = question.trimmingCharacters(in: .whitespacesAndNewlines)
    if let last = label.last, Self.echoTerminators.contains(last) {
      return "\(label) \(answer)"
    }
    return "\(label): \(answer)"
  }

  /// Punctuation a question can end in that already separates it from its answer (ASCII and
  /// the full-width forms). Closing brackets and quotes are deliberately absent: `Which (optional)`
  /// still reads best with the colon.
  private static let echoTerminators: Set<Character> = [
    "?", ":", ".", "!", ";", "…", "？", "：", "。", "！", "；",
  ]

  public init(qid: String? = nil, question: String, choices: [String] = [], multiSelect: Bool = false) {
    self.qid = qid
    self.question = question
    self.choices = choices
    self.multiSelect = multiSelect && !choices.isEmpty
  }
}

/// A clarify prompt in any of its three wire generations, as one model: the layout comes
/// from the question count, the answer's wire shape from ``answerShape``. Decoded by where it
/// arrived — ``init(serverRequestParams:)`` or ``init(legacyEvent:)`` — never guessed from the
/// payload.
///
/// Lenient within a shape: `choices: null` (or a non-array) is free text, non-string choices
/// are dropped, `multi_select` defaults to `false`, an unusable `questions` entry (no `qid`,
/// blank `question`) is dropped (the rest still render), and unknown keys are ignored.
///
/// Deliberately only `Equatable` (no value-derived card identity) — see `ApprovalRequest`.
public struct ClarifyRequest: Equatable, Sendable {
  /// The legacy event's `request_id` (answered through `clarify.respond`). `nil` for a v7
  /// server request, which is identified by its `srq-…` id on `PendingServerRequest`.
  public var requestID: String?
  /// At least one after decoding.
  public var questions: [ClarifyQuestion]
  /// Answers the server already locked for a batch (replayed `params.answers`), keyed by
  /// qid; a `nil` value is a locked skip. Shown as locked and re-sent with the final set.
  public var lockedAnswers: [String: String?]
  public var answerShape: AnswerShape

  /// How the answer goes back on the wire.
  public enum AnswerShape: Equatable, Sendable {
    /// `request.answer {id, result: {answers: {qid: text|null}}}`; cancel-all is `{}`.
    case answers
    /// Intermediate single server request: `request.answer {id, result: {answer}}`;
    /// skip is `{answer: ""}`.
    case singleAnswer
    /// Legacy event: `clarify.respond {session_id, request_id, answer}`; a legacy batch sends
    /// one `clarify.respond` per question with its `question_id`, and its skip is the
    /// question-less cancel-all.
    case legacyRespond
  }

  /// Layout only: several questions render as sections with a pinned Confirm/Skip row.
  public var isMultiQuestion: Bool { questions.count > 1 }

  /// Wire shape only: it arrived as a `questions` list, so every answer is keyed by its qid —
  /// even a list with one usable question.
  public var isBatch: Bool { questions.first?.qid != nil }

  /// The first question's text — the gateway-log summary.
  public var question: String { questions.first?.question ?? "" }

  /// The one-question single-select form, where a tapped choice is the whole answer.
  public var submitsOnTap: Bool {
    guard !isMultiQuestion, let question = questions.first else { return false }
    return !question.isFreeText && !question.multiSelect
  }

  /// Every question with choices gets an "Other" free-text row (the upstream tool schema tells
  /// the model the UI adds one) — a v7 form; a legacy `clarify.request` keeps its choices-only
  /// card.
  public var offersOtherRow: Bool { answerShape != .legacyRespond }

  /// The card's pinned primary button title: "Confirm" for several questions, "Send" for free
  /// text (or a single-select question with an Other row), "Submit" for multi-select. `nil`
  /// where a tap on a choice is the only way to answer (a legacy single-select card).
  public var submitTitle: String? {
    if isMultiQuestion { return "Confirm" }
    guard let question = questions.first else { return nil }
    if question.isFreeText { return "Send" }
    if question.multiSelect { return "Submit" }
    return offersOtherRow ? "Send" : nil
  }

  /// Did the server already lock this question's answer (a replayed batch)? A locked question
  /// renders read-only and its lock is re-sent with the final set.
  public func isLocked(_ question: ClarifyQuestion) -> Bool {
    guard let qid = question.qid else { return false }
    return lockedAnswers.keys.contains(qid)
  }

  /// What a locked answer reads as — "Skipped" for a locked skip, a multi-select's JSON-array
  /// wire string as its comma-joined choices, anything else as sent. `nil` when the question
  /// is not locked. Shared by the card's locked rows and the transcript echo.
  public func lockedDisplayText(for question: ClarifyQuestion) -> String? {
    guard let qid = question.qid, let locked = lockedAnswers[qid] else { return nil }
    guard let locked else { return "Skipped" }
    if question.multiSelect,
       let picked = try? JSONDecoder().decode([String].self, from: Data(locked.utf8)) {
      return picked.joined(separator: ", ")
    }
    return locked
  }

  public init(
    requestID: String?,
    questions: [ClarifyQuestion],
    lockedAnswers: [String: String?] = [:],
    answerShape: AnswerShape
  ) {
    self.requestID = requestID
    self.questions = questions
    self.lockedAnswers = lockedAnswers
    self.answerShape = answerShape
  }

  /// The single-question form: a `requestID` makes it the legacy event, none the
  /// intermediate single server request.
  public init(requestID: String?, question: String, choices: [String] = [], multiSelect: Bool = false) {
    self.init(
      requestID: requestID,
      questions: [ClarifyQuestion(question: question, choices: choices, multiSelect: multiSelect)],
      answerShape: requestID == nil ? .singleAnswer : .legacyRespond
    )
  }

  /// A v7 `clarify` server request's params, answered through `request.answer`:
  /// - a `questions` list with at least one usable entry → ``AnswerShape/answers`` (v0.21.6+,
  ///   and the intermediate batch); replayed `answers` become ``lockedAnswers``;
  /// - else a top-level non-blank `question` → ``AnswerShape/singleAnswer`` (the intermediate
  ///   single form, `multi_select` honoured);
  /// - anything else is `nil`. A stray `request_id` is ignored — it never makes it legacy.
  public init?(serverRequestParams payload: JSONValue) {
    guard case .object = payload else { return nil }
    let questions = Self.batchQuestions(payload["questions"])
    if !questions.isEmpty {
      self.init(
        requestID: nil,
        questions: questions,
        lockedAnswers: Self.lockedAnswers(payload["answers"]),
        answerShape: .answers
      )
    } else if let question = payload["question"]?.stringValue, question.trimmedNonEmpty != nil {
      self.init(
        requestID: nil,
        question: question,
        choices: Self.choices(payload["choices"]),
        multiSelect: payload["multi_select"]?.boolValue ?? false
      )
    } else {
      return nil
    }
  }

  /// A legacy `clarify.request` event's payload (≤ v2026.9.11), answered through
  /// `clarify.respond` (``AnswerShape/legacyRespond``). Needs a `request_id` — without one
  /// there is no answer path, so it is `nil`. A usable `questions` list is the legacy batch
  /// (one `clarify.respond` per question); otherwise it is the single form decoded exactly as
  /// before: `question` defaults to `""` and `multi_select` is ignored.
  public init?(legacyEvent payload: JSONValue) {
    guard let requestID = payload["request_id"]?.stringValue else { return nil }
    let questions = Self.batchQuestions(payload["questions"])
    if !questions.isEmpty {
      self.init(requestID: requestID, questions: questions, answerShape: .legacyRespond)
    } else {
      self.init(
        requestID: requestID,
        question: payload["question"]?.stringValue ?? "",
        choices: Self.choices(payload["choices"])
      )
    }
  }

  private static func batchQuestions(_ value: JSONValue?) -> [ClarifyQuestion] {
    (value?.arrayValue ?? []).compactMap(batchQuestion)
  }

  private static func batchQuestion(_ entry: JSONValue) -> ClarifyQuestion? {
    guard let qid = entry["qid"]?.stringValue, !qid.isEmpty,
          let question = entry["question"]?.stringValue, question.trimmedNonEmpty != nil
    else { return nil }
    return ClarifyQuestion(
      qid: qid,
      question: question,
      choices: choices(entry["choices"]),
      multiSelect: entry["multi_select"]?.boolValue ?? false
    )
  }

  private static func choices(_ value: JSONValue?) -> [String] {
    (value?.arrayValue ?? []).compactMap(\.stringValue)
  }

  /// String values lock an answer, `null` locks a skip; any other value is ignored (the
  /// question stays open rather than showing a lock the app cannot render).
  private static func lockedAnswers(_ value: JSONValue?) -> [String: String?] {
    guard case let .object(entries)? = value else { return [:] }
    var locked: [String: String?] = [:]
    for (qid, answer) in entries {
      switch answer {
      case let .string(text): locked[qid] = .some(text)
      case .null: locked[qid] = .some(nil)
      default: continue
      }
    }
    return locked
  }
}

/// The user's answer to one clarify question, as the card hands it to the reducer (keyed by
/// qid; `""` for the `nil`-qid question of the intermediate and legacy single forms). The
/// reducer — not the view — turns it into wire text per the request's
/// ``ClarifyRequest/AnswerShape``.
public enum ClarifyAnswer: Equatable, Sendable {
  /// Picked choices, as the raw strings of ``ClarifyQuestion/choices`` (exactly one for a
  /// single-select question). Sent as the bare label (the `" (Recommended)"` marker
  /// stripped); a multi-select question sends a JSON-array string (`"[\"A\",\"B\"]"`).
  case choices([String])
  /// Typed text — a free-text question, or the "Other" row of a question with choices
  /// (multi-select included). Sent as typed: a plain string, never wrapped in an array.
  case other(String)
  /// Skip this one question (`null` in a v0.21.6+ `answers` map).
  case skipped

  /// The wire text for `question`, `nil` for a skip. `stripsRecommended: false` keeps a
  /// legacy `clarify.respond` byte-identical to what the app sent before (the raw choice).
  func wireText(for question: ClarifyQuestion, stripsRecommended: Bool = true) -> String? {
    switch self {
    case .skipped:
      return nil
    case let .other(text):
      return text
    case let .choices(raw):
      let labels = stripsRecommended ? raw.map { ClarifyChoice.split($0).label } : raw
      guard question.multiSelect else { return labels.first ?? "" }
      return Self.jsonArrayString(labels)
    }
  }

  /// What the transcript echo shows for this answer (never wire syntax).
  var displayText: String {
    switch self {
    case .skipped: "Skipped"
    case let .other(text): text
    case let .choices(raw): raw.map { ClarifyChoice.split($0).label }.joined(separator: ", ")
    }
  }

  /// `["A","B"]` — compact, with `wireEncoder`'s settings so a choice containing `/` is never
  /// `\/`-escaped. Encoding `[String]` cannot fail; the fallback only satisfies the type.
  private static func jsonArrayString(_ labels: [String]) -> String {
    guard let data = try? JSONRPCRequest.wireEncoder.encode(labels) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }
}

/// The clarify card's answers in progress: the user's edits to the questions the server has
/// not locked. Held by the card as view state (keyed on `pendingInteractionToken`, so a
/// replacement card never inherits it — and a refreshed replay keeps it while new locks come
/// from the store) and handed to `submitClarify(token:answers:)` as ``answers(for:)``. Pure, so the
/// form's rules are unit-tested here instead of living in the view:
/// - a picked choice and typed "Other" text are exclusive — picking clears the text, typing
///   (non-blank) clears the picks — because an answer is one or the other on the wire;
/// - a single-select question holds one pick (tapping it again keeps it, radio-style); a
///   multi-select one toggles, kept in the server's choice order;
/// - a pick or non-blank text un-skips a question; a skip is the answer while it stands (the
///   edits survive it, so un-skipping brings them back);
/// - nothing is preselected — the recommended choice is a badge, never a default.
public struct ClarifyDraft: Equatable, Sendable {
  private var picked: [String: [String]] = [:]
  private var typed: [String: String] = [:]
  private var skipped: Set<String> = []

  public init() {}

  public func isPicked(_ choice: String, in question: ClarifyQuestion) -> Bool {
    picked[question.answerKey]?.contains(choice) ?? false
  }

  /// The typed text — the free-text answer, or the "Other" row of a question with choices.
  public func text(for question: ClarifyQuestion) -> String {
    typed[question.answerKey] ?? ""
  }

  public func isSkipped(_ question: ClarifyQuestion) -> Bool {
    skipped.contains(question.answerKey)
  }

  /// Pick (single-select) or toggle (multi-select) a raw choice of `question`.
  public mutating func toggle(_ choice: String, in question: ClarifyQuestion) {
    let key = question.answerKey
    guard question.choices.contains(choice) else { return }
    skipped.remove(key)
    typed[key] = nil
    guard question.multiSelect else {
      picked[key] = [choice]
      return
    }
    var current = picked[key] ?? []
    if current.contains(choice) {
      current.removeAll { $0 == choice }
    } else {
      current.append(choice)
    }
    picked[key] = question.choices.filter(current.contains)
  }

  public mutating func setText(_ text: String, for question: ClarifyQuestion) {
    let key = question.answerKey
    typed[key] = text
    guard text.trimmedNonEmpty != nil else { return }
    picked[key] = nil
    skipped.remove(key)
  }

  public mutating func toggleSkip(_ question: ClarifyQuestion) {
    let key = question.answerKey
    if skipped.contains(key) {
      skipped.remove(key)
    } else {
      skipped.insert(key)
    }
  }

  /// This question's answer, `nil` while it has none. Typed text goes out trimmed.
  public func answer(for question: ClarifyQuestion) -> ClarifyAnswer? {
    let key = question.answerKey
    if skipped.contains(key) { return .skipped }
    if let text = typed[key]?.trimmedNonEmpty { return .other(text) }
    if let picks = picked[key], !picks.isEmpty { return .choices(picks) }
    return nil
  }

  /// The answers to submit: every unlocked question that has one (the reducer adds the locks
  /// and sends a missing question as a skip).
  public func answers(for request: ClarifyRequest) -> [String: ClarifyAnswer] {
    var answers: [String: ClarifyAnswer] = [:]
    for question in request.questions where !request.isLocked(question) {
      answers[question.answerKey] = answer(for: question)
    }
    return answers
  }

  /// Is this question settled: locked, answered or skipped?
  public func isSettled(_ question: ClarifyQuestion, in request: ClarifyRequest) -> Bool {
    request.isLocked(question) || answer(for: question) != nil
  }

  /// Can the form be submitted? Every question is settled.
  public func isComplete(for request: ClarifyRequest) -> Bool {
    request.questions.allSatisfy { isSettled($0, in: request) }
  }

  /// The multi-question card's progress caption, "1 of 2 answered" (the desktop's copy), or
  /// `nil` for a one-question card. It counts what ``isComplete(for:)`` counts (a skip or a lock
  /// is settled too), so it reads "N of N" exactly when Confirm enables. Without it, a question
  /// below the fold of the card's scroll region left Confirm looking broken (#169).
  public func progressText(for request: ClarifyRequest) -> String? {
    guard request.isMultiQuestion else { return nil }
    let settled = request.questions.filter { isSettled($0, in: request) }.count
    return "\(settled) of \(request.questions.count) answered"
  }

  /// Does Return in the "Other" row submit the card? Only where a single answer is all the
  /// card needs (one question) and that answer is there.
  public func sendsOnReturn(for request: ClarifyRequest) -> Bool {
    !request.isMultiQuestion && isComplete(for: request)
  }
}

/// Presentation helpers for a clarify choice.
public enum ClarifyChoice {
  /// The server's marker on the first of two or more choices (upstream `RECOMMENDED_LABEL`).
  public static let recommendedLabel = "(Recommended)"

  /// `("Use SwiftUI", isRecommended: true)` for `"Use SwiftUI (Recommended)"`. Mirrors
  /// upstream `strip_recommended`: trimmed, case-insensitive suffix match, the label trimmed
  /// again. The label is the text to display AND to send (the server strips it anyway; the
  /// desktop sends the bare text). A choice that is nothing but the marker keeps it as its
  /// label (never an empty row) and is not marked recommended.
  public static func split(_ raw: String) -> (label: String, isRecommended: Bool) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let suffix = trimmed.range(
      of: recommendedLabel, options: [.caseInsensitive, .anchored, .backwards]
    ) else {
      return (trimmed, false)
    }
    let label = String(trimmed[..<suffix.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? (trimmed, false) : (label, true)
  }
}
