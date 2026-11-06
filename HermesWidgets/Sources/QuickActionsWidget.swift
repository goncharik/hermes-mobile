import HermesWidgetKit
import SwiftUI
import WidgetKit

/// The quick-actions widget (#138), `systemSmall` + `systemMedium`: "Ask Hermes" plus round
/// buttons that open a new chat with a one-shot action. Static: one entry, never reloaded.
struct QuickActionsWidget: Widget {
  static let kind = "me.honcharenko.HermesMobile.Widgets.QuickActions"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: StaticEntryProvider()) { _ in
      QuickActionsEntryView()
        .containerBackground(.background, for: .widget)
    }
    .configurationDisplayName("Hermes")
    .description("Quickly start a new chat with Hermes.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

private struct QuickActionsEntryView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    if family == .systemSmall {
      // A small widget can't host a `Link` (only one `widgetURL`), so each button runs an
      // intent that opens the deep link.
      QuickActionsView(layout: .small) { intent, label in
        Button(intent: OpenHermesURLIntent(intent)) { label }
          .buttonStyle(.plain)
      }
    } else {
      QuickActionsView(layout: .medium) { intent, label in
        Link(destination: WidgetDeepLink.url(for: intent)) { label }
      }
    }
  }
}

/// The one entry of a widget whose content never changes (quick actions, the Lock Screen
/// accessory): no data, no refresh.
struct StaticEntry: TimelineEntry {
  let date: Date
}

struct StaticEntryProvider: TimelineProvider {
  func placeholder(in context: Context) -> StaticEntry {
    StaticEntry(date: .now)
  }

  func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) {
    completion(StaticEntry(date: .now))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
    completion(Timeline(entries: [StaticEntry(date: .now)], policy: .never))
  }
}
