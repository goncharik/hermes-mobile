import HermesWidgetKit
import SwiftUI
import WidgetKit

/// The sessions widget (#138), `systemMedium` (the headline session) + `systemLarge` (the top
/// five): what the app last mirrored into the App Group, with working / needs-input glyphs
/// that turn "outdated" once the app can no longer vouch for them.
struct SessionsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: AppGroup.sessionsWidgetKind,
      provider: SessionsTimelineProvider()
    ) { entry in
      SessionsEntryView(entry: entry)
        .containerBackground(.background, for: .widget)
    }
    .configurationDisplayName("Sessions")
    .description("Keep up with your latest Hermes sessions.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

private struct SessionsEntryView: View {
  let entry: SessionsEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    SessionsWidgetView(
      layout: family == .systemLarge ? .large : .medium,
      snapshot: entry.snapshot,
      date: entry.date
    )
  }
}
