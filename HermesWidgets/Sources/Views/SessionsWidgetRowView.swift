import HermesWidgetKit
import SwiftUI
import WidgetKit

/// How a row's "updated" time reads. The widget keeps it live (`Text(_, style: .relative)`
/// ticks on its own, so a `.never` timeline stays truthful); snapshot tests pin `now` and get
/// the same wording, rendered deterministically.
enum WidgetRelativeTime {
  case live
  case fixed(now: Date)

  func text(for date: Date) -> Text {
    switch self {
    case .live:
      Text("\(Text(date, style: .relative)) ago")
    case let .fixed(now):
      // The `.relative` style's own wording: up to two units, short names ("2 hr, 5 min").
      Text("\(Self.formatter.string(from: max(0, now.timeIntervalSince(date))) ?? "") ago")
    }
  }

  private static let formatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute, .second]
    formatter.unitsStyle = .short
    formatter.maximumUnitCount = 2
    return formatter
  }()
}

/// One session in the sessions widget (#138), Codex-task style: the title over a meta line
/// (folder + workspace, updated time) with a trailing status glyph. Plain values only, so the
/// snapshot tests can render it; the caller wraps it in the row's `Link`.
struct SessionsWidgetRowView: View {
  let row: WidgetSessionRow
  /// `nil` for an idle or unread row (no glyph).
  let status: AgentActivityContent.DisplayStatus?
  let relativeTime: WidgetRelativeTime

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .font(.subheadline.weight(.medium))
          // `Color`, not the hierarchical `.primary`: inside the row's `Link` that would
          // resolve to the link tint.
          .foregroundStyle(Color.primary)
          .lineLimit(1)
        meta
      }
      Spacer(minLength: 0)
      if let status {
        SessionsWidgetStatusGlyph(status: status)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var meta: some View {
    if row.workspace != nil || row.updatedAt != nil {
      HStack(spacing: 4) {
        if let workspace = row.workspace {
          Image(systemName: "folder")
            .imageScale(.small)
            .accessibilityHidden(true)
          Text(workspace)
            .layoutPriority(1)
        }
        if row.workspace != nil, row.updatedAt != nil {
          Text("·")
            .accessibilityHidden(true)
        }
        if let updatedAt = row.updatedAt {
          relativeTime.text(for: updatedAt)
        }
      }
      .font(.caption)
      .foregroundStyle(Color.secondary)
      .lineLimit(1)
    }
  }
}

/// A row's trailing status: a static spinner-style glyph while working, a question mark when
/// the turn needs input, a clock once the app can no longer vouch for either. Label and colour
/// are the Live Activity's (`DisplayStatus.label` / `.color`).
struct SessionsWidgetStatusGlyph: View {
  let status: AgentActivityContent.DisplayStatus

  var body: some View {
    Image(systemName: symbol)
      .font(.body.weight(.medium))
      .foregroundStyle(status.color)
      .widgetAccentable()
      .accessibilityLabel(status.label)
  }

  private var symbol: String {
    switch status {
    case .working: "progress.indicator"
    case .needsInput: "questionmark.circle"
    case .outdated: "clock"
    // Rows never read "Done"; the compact Dynamic Island's checkmark, for totality.
    case .done: "checkmark"
    }
  }
}
