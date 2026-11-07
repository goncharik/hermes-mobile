import WidgetKit

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
