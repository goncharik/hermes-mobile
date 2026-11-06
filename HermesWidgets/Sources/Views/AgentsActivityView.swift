import HermesWidgetKit
import SwiftUI
import WidgetKit

/// The aggregate Live Activity's lock-screen banner (#138), T3 Code style: "Hermes" and
/// "N active agent(s)" on top; the headline session's title (truncated), its workspace in
/// secondary and a coloured status label on the line below. With "Show session titles" off
/// the workspace takes the title's place. The expanded Dynamic Island shows the same layout.
///
/// Plain values only (no `ActivityViewContext`), so the snapshot tests can render it:
/// `isStale` is ActivityKit's `context.isStale` — past the stale date working / needs input
/// read "Outdated".
struct AgentsActivityView: View {
  enum Style {
    /// The Lock Screen banner: the system draws the background, the view pads itself.
    case lockScreen
    /// The expanded Dynamic Island's bottom region: the island supplies the margins.
    case expanded
  }

  let content: AgentActivityContent
  let isStale: Bool
  var style: Style = .lockScreen

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      headline
    }
    .padding(style == .lockScreen ? 16 : 0)
  }

  private var header: some View {
    ZStack {
      HStack(spacing: 6) {
        HermesGlyph()
          .frame(width: 16, height: 16)
        Text("Hermes")
          .font(.subheadline.weight(.bold))
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      Text(content.countLabel)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
    }
  }

  private var headline: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let headlineText = content.headlineText {
        Text(headlineText)
          .font(.body.weight(.semibold))
          .lineLimit(1)
      }
      if let secondaryText = content.secondaryText {
        Text(secondaryText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          // The title truncates first (T3): the workspace keeps its room.
          .layoutPriority(1)
      }
      Spacer(minLength: 8)
      AgentsActivityStatusLabel(status: content.displayStatus(isStale: isStale))
        .layoutPriority(2)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The trailing status label: Working in blue, Needs input in yellow, Done in green,
/// Outdated in secondary — the session list's status colours.
struct AgentsActivityStatusLabel: View {
  let status: AgentActivityContent.DisplayStatus

  var body: some View {
    Text(status.label)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(status.color)
      .lineLimit(1)
      .fixedSize()
  }
}

/// The compact Dynamic Island's trailing side: how many agents are active, a yellow "?" while
/// the headline needs input, a green checkmark once done; secondary once stale.
struct AgentsActivityCompactTrailing: View {
  let content: AgentActivityContent
  let isStale: Bool

  private var status: AgentActivityContent.DisplayStatus {
    content.displayStatus(isStale: isStale)
  }

  var body: some View {
    label
      .font(.subheadline.weight(.bold))
      .foregroundStyle(status.color)
      .fixedSize()
      .accessibilityLabel("\(content.countLabel), \(status.label)")
  }

  private var label: Text {
    switch status {
    case .done: Text(Image(systemName: "checkmark"))
    case .needsInput: Text(verbatim: "?")
    case .working, .outdated: Text(verbatim: "\(content.activeCount)")
    }
  }
}

extension AgentActivityContent.DisplayStatus {
  /// The one status colour table (the session list's status dots), for the activity and the
  /// sessions widget's row glyphs alike.
  var color: Color {
    switch self {
    case .working: .blue
    case .needsInput: .yellow
    case .done: .green
    case .outdated: .secondary
    }
  }
}
