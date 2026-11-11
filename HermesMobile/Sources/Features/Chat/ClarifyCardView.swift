import HermesKit
import SwiftUI

/// Pinned card shown when the agent asks the user a question mid-turn — every clarify form the
/// desktop renders, in the approval card's shape: a rigid one-line title and a **pinned action
/// row** over ONE bounded, scrollable region (``BoundedHeightLayout``), never plain stacked
/// content. The region holds everything unbounded — up to five questions of server-controlled
/// text, four choices each, an "Other" row per question — so a squeezed fixed region (keyboard
/// up, accessibility sizes) is absorbed by the viewport and Skip / Submit stay on screen (#65's
/// lesson, `docs/features/approvals.md`).
///
/// The form comes from the question count and kind:
/// - **one single-select question** — a tap on a choice submits it at once;
/// - **one multi-select question** — checkmark rows, submitted with Submit;
/// - **one free-text question** — a text field, sent with Send;
/// - **several questions** — one section per question (choices select instead of submitting,
///   each section can be skipped), confirmed with Confirm once every question has an answer or
///   a skip. The title line carries an "N of M answered" caption, the desktop's copy (#169).
///   Sections are split by a divider inside the scroll region; a skipped section's inputs are
///   dimmed and disabled until the skip is toggled off.
///
/// Every question with choices also gets an "Other" free-text row (the upstream tool schema
/// tells the model the UI adds one) — except on a legacy `clarify.request`, which keeps
/// today's form. The recommended choice shows a badge and is never preselected. Skip is on
/// every form. Questions the server already locked (a replayed batch) render read-only from
/// the store; the view's `@State` holds only the user's edits to the rest (``ClarifyDraft``,
/// whose rules are unit-tested in HermesKit), and the card is keyed on
/// `pendingInteractionToken` at the call site, so a replacement card never inherits them.
struct ClarifyCardView: View {
  let request: ClarifyRequest
  /// Called with the answers keyed by qid (`""` for a single legacy/intermediate question).
  let onSubmit: ([String: ClarifyAnswer]) -> Void
  /// Skips the whole card.
  let onSkip: () -> Void

  @State private var draft: ClarifyDraft

  /// `draft` seeds the edits (snapshots render a form mid-answer); the app passes none.
  init(
    request: ClarifyRequest,
    draft: ClarifyDraft = ClarifyDraft(),
    onSubmit: @escaping ([String: ClarifyAnswer]) -> Void,
    onSkip: @escaping () -> Void
  ) {
    self.request = request
    self.onSubmit = onSubmit
    self.onSkip = onSkip
    _draft = State(initialValue: draft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Rigid and clamped, as on the approval card: every rigid point is one the region loses.
      // The multi-question progress caption shares this line (no extra rigid height) and wins
      // the width over the title: it is what says why Confirm is still disabled (#169).
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("Clarification needed", systemImage: "questionmark.circle")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity, alignment: .leading)
        if let progress = draft.progressText(for: request) {
          Text(progress)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .layoutPriority(1)
        }
      }
      .lineLimit(1)
      .dynamicTypeSize(...DynamicTypeSize.xxLarge)

      scrollableContent

      // Outside the scroll on purpose: whatever the region is squeezed to, the way out (Skip)
      // and the way forward (Submit / Send / Confirm) stay on screen and tappable.
      HStack(spacing: 12) {
        Button(action: onSkip) {
          Text("Skip").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        if let submitTitle = request.submitTitle {
          Button { onSubmit(draft.answers(for: request)) } label: {
            Text(submitTitle).frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(!draft.isComplete(for: request))
        }
      }
    }
    .promptCardChrome(tint: .blue)
  }

  /// The questions, in a ``BoundedScrollRegion``. The transcript reserve applies only to the
  /// multi-question card — the one `ChatView` gives layout priority
  /// (`isCompressibleCardPending`). Its sections are split by a hairline divider INSIDE the
  /// region (it scrolls with them, no rigid height outside), never a border per question: the
  /// card's border and the choice pills already box everything.
  private var scrollableContent: some View {
    BoundedScrollRegion(
      spacing: request.isMultiQuestion ? 12 : 10,
      reserve: request.isMultiQuestion ? PromptCardMetrics.transcriptReserve : 0
    ) {
      ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
        if index > 0 {
          Divider()
        }
        questionSection(question)
      }
    }
  }

  @ViewBuilder
  private func questionSection(_ question: ClarifyQuestion) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(question.question)
        .font(request.isMultiQuestion ? .callout.weight(.medium) : .callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let locked = request.lockedDisplayText(for: question) {
        Label(locked, systemImage: "checkmark.circle.fill")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else if question.isFreeText {
        TextField("Type a reply", text: textBinding(question), axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .skippedInput(draft.isSkipped(question))
      } else {
        ForEach(question.choices, id: \.self) { choice in
          choiceRow(choice, in: question)
            .skippedInput(draft.isSkipped(question))
        }
        if request.offersOtherRow {
          otherRow(question)
            .skippedInput(draft.isSkipped(question))
        }
      }

      if request.isMultiQuestion, !request.isLocked(question) {
        let skipped = draft.isSkipped(question)
        Button { draft.toggleSkip(question) } label: {
          Label("Skip this question", systemImage: skipped ? "checkmark.circle.fill" : "circle")
            .font(.footnote)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(skipped ? .isSelected : [])
      }
    }
  }

  /// One choice. On the one-question single-select form a tap submits it (the bare label is
  /// derived in the reducer — the raw choice goes up); everywhere else it selects, shown by a
  /// radio (single) or checkbox (multi) mark.
  private func choiceRow(_ choice: String, in question: ClarifyQuestion) -> some View {
    let split = ClarifyChoice.split(choice)
    let selected = draft.isPicked(choice, in: question)
    return Button {
      if request.submitsOnTap {
        onSubmit([question.answerKey: .choices([choice])])
      } else {
        draft.toggle(choice, in: question)
      }
    } label: {
      HStack(spacing: 8) {
        if !request.submitsOnTap {
          Image(systemName: selectionIcon(selected: selected, multiSelect: question.multiSelect))
        }
        Text(split.label)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if split.isRecommended {
          Text("Recommended")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.18), in: Capsule())
        }
      }
    }
    .buttonStyle(.bordered)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// The "Other" free-text row: typing makes the typed text the answer (clearing any pick).
  private func otherRow(_ question: ClarifyQuestion) -> some View {
    TextField("Other…", text: textBinding(question))
      .textFieldStyle(.roundedBorder)
      .submitLabel(.send)
      .onSubmit {
        if draft.sendsOnReturn(for: request) {
          onSubmit(draft.answers(for: request))
        }
      }
  }

  private func textBinding(_ question: ClarifyQuestion) -> Binding<String> {
    Binding(
      get: { draft.text(for: question) },
      set: { draft.setText($0, for: question) }
    )
  }

  private func selectionIcon(selected: Bool, multiSelect: Bool) -> String {
    switch (multiSelect, selected) {
    case (true, true): "checkmark.square.fill"
    case (true, false): "square"
    case (false, true): "checkmark.circle.fill"
    case (false, false): "circle"
    }
  }
}

private extension View {
  /// A skipped question's input (choice, Other row, text field) reads as skipped, not as an
  /// empty field the "N of M answered" caption already counts: dimmed and disabled. The draft
  /// keeps the edits under the skip, so toggling Skip off restores them. Applied per row, and
  /// only while skipped, so an unskipped card's layout tree is exactly what it was.
  @ViewBuilder
  func skippedInput(_ skipped: Bool) -> some View {
    if skipped {
      disabled(true).opacity(0.4)
    } else {
      self
    }
  }
}
