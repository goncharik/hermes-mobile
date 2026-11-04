import HermesKit
import SwiftUI

/// A tool call's full detail (tool-call display plan, Task 13), opened from an expanded body's
/// "Show all" / "Details". Read-only.
///
/// - **Header**: the call's icon (red on failure) and parsed title (`ToolPresentation`), its
///   outcome and duration.
/// - **Body**: the outcome message, then the same per-tool view the transcript shows inline
///   (`ToolBodyContent`) — here UNCAPPED.
/// - **Raw**: a collapsed disclosure with every payload the call carried, pretty-printed
///   (`ToolCall.rawSections`), so a presentation that misreads a call never hides its data.
struct ToolDetailSheet: View {
  let call: ToolCall
  @State private var showsRaw: Bool

  @Environment(\.dismiss) private var dismiss

  /// `rawExpanded` opens the "Raw" disclosure up front — for snapshots of the raw sections.
  init(call: ToolCall, rawExpanded: Bool = false) {
    self.call = call
    _showsRaw = State(initialValue: rawExpanded)
  }

  var body: some View {
    let presentation = ToolPresentation(call: call)
    let isRunning = call.state == .running
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header(presentation, isRunning: isRunning)
          OutcomeMessageView(outcome: presentation.outcome)
          ToolBodyContent(presentation.body, isRunning: isRunning)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
          rawDisclosure
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      // The wire name: the header already carries the parsed title.
      .navigationTitle(call.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  // MARK: - Header

  private func header(_ presentation: ToolPresentation, isRunning: Bool) -> some View {
    let failed = presentation.outcome.isFailure
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: presentation.icon.systemImage)
        .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(presentation.title(live: isRunning))
          .font(.headline)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          OutcomeBadge(outcome: presentation.outcome, isRunning: isRunning)
          if let durationS = call.durationS {
            Label(ToolPresentation.durationLabel(durationS), systemImage: "clock")
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
    }
    .font(.headline)
    .accessibilityElement(children: .combine)
  }

  // MARK: - Raw

  private var rawDisclosure: some View {
    let sections = call.rawSections
    return DisclosureGroup(isExpanded: $showsRaw) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
          RawSectionView(section: section)
        }
        if sections.isEmpty {
          Text("The call carried no arguments or result.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.top, 8)
    } label: {
      Text("Raw")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }
  }
}

/// The call's verdict as a small capsule: "Succeeded" green, "Failed" red, "Notice" grey,
/// "Running" while in flight. A settled call with nothing to judge (a reloaded call whose
/// output isn't kept) shows no badge.
private struct OutcomeBadge: View {
  let outcome: ToolPresentation.Outcome
  let isRunning: Bool

  var body: some View {
    if let style {
      Label(style.text, systemImage: style.symbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(style.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(style.tint.opacity(0.15), in: .capsule)
        .fixedSize()
    }
  }

  private var style: (text: String, symbol: String, tint: Color)? {
    switch outcome {
    case .success: ("Succeeded", "checkmark.circle.fill", .green)
    case .failure: ("Failed", "xmark.octagon.fill", .red)
    case .notice: ("Notice", "info.circle.fill", .gray)
    case .unknown: isRunning ? ("Running", "ellipsis.circle", .gray) : nil
    }
  }
}

/// One labelled block of the raw payload: monospaced, selectable, wrapping.
private struct RawSectionView: View {
  let section: ToolCall.RawSection

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(section.label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(section.text)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
    }
  }
}
