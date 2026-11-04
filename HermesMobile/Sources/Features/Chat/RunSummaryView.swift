import HermesKit
import SwiftUI

/// One line inside a turn's fold — a run summary, a call line, or a reasoning line: a leading
/// icon, one truncating line of secondary text, and an optional trailing chevron (the T3 Code
/// look). Layout only; the caller attaches the tap (`foldTap`).
struct FoldLine: View {
  let systemImage: String
  let text: String
  /// Trailing chevron symbol, or `nil` for none.
  var chevron: String?
  var iconTint: Color = .secondary

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.subheadline)
        .foregroundStyle(iconTint)
        .frame(width: 20)
        .accessibilityHidden(true)
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let chevron {
        Image(systemName: chevron)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 2)
  }
}

/// A run of ≥ 2 consecutive tool calls folded into one line ("Read 1 file, ran 4 commands,
/// and performed 1 other action" — `RunSummary.text`), led by the run's kind icon, or a hammer
/// when it mixes kinds. A tap lists the run's calls below it, or folds them back.
struct RunSummaryView: View {
  let summary: RunSummary
  let onTap: () -> Void

  var body: some View {
    FoldLine(
      systemImage: summary.icon.systemImage,
      text: summary.text,
      chevron: summary.isExpanded ? "chevron.up" : "chevron.down"
    )
    .foldTap(isExpanded: summary.isExpanded, action: onTap)
  }
}

/// A reasoning burst as one line: the brain icon and the burst's first sentence
/// (`TranscriptFold.reasoningPreview`); a tap discloses the full text below it. The disclosure
/// is view-local `@State` — the cell is `.id`-keyed on its row, so a reused cell starts closed.
struct ReasoningLineView: View {
  let text: String
  @State private var isExpanded: Bool

  init(text: String, initiallyExpanded: Bool = false) {
    self.text = text
    _isExpanded = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    let preview = TranscriptFold.reasoningPreview(text)
    VStack(alignment: .leading, spacing: 6) {
      FoldLine(
        systemImage: "brain",
        text: preview.isEmpty ? "Thinking" : preview,
        chevron: isExpanded ? "chevron.up" : "chevron.down"
      )
      .foldTap(isExpanded: isExpanded) { isExpanded.toggle() }
      if isExpanded {
        Text(disclosed)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 30)
      }
    }
  }

  /// The full burst with its inline markdown (the `**Heading**` reasoning models emit)
  /// rendered, line breaks kept; plain text when it doesn't parse.
  private var disclosed: AttributedString {
    (try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
  }
}
