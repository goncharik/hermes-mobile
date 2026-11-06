import Foundation
import HermesWidgetKit
import WidgetKit

/// One moment of the sessions widget: the mirror as read, shown at `date`. An entry dated at
/// or past `snapshot.freshUntil` renders its working / needs-input rows as "outdated".
struct SessionsEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSessionSnapshot
}

/// Feeds the sessions widget from the App Group mirror the app writes — its only data source
/// (never the network or the Keychain). The timeline is the entry for now plus an "outdated"
/// entry at `freshUntil`, with policy `.never`: the app reloads it after every write.
struct SessionsTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> SessionsEntry {
    SessionsEntry(date: .now, snapshot: .demo(now: .now))
  }

  /// The widget gallery shows demo rows; a real snapshot request shows the mirror.
  func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
    let now = Date.now
    let snapshot = context.isPreview ? .demo(now: now) : Self.readMirror()
    completion(SessionsEntry(date: now, snapshot: snapshot))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
    let snapshot = Self.readMirror()
    let entries = WidgetStaleness.timelineDates(for: snapshot, at: .now)
      .map { SessionsEntry(date: $0, snapshot: snapshot) }
    completion(Timeline(entries: entries, policy: .never))
  }

  /// The mirror, or the signed-out state when there is none (never signed in, or no App
  /// Group container) or it can't be read.
  private static func readMirror() -> WidgetSessionSnapshot {
    WidgetSessionSnapshot.read(from: AppGroup.snapshotFileURL()) ?? .signedOut
  }
}

extension WidgetSessionSnapshot {
  /// The placeholder / widget-gallery rows: illustrative, never real data.
  static func demo(now: Date) -> WidgetSessionSnapshot {
    WidgetSessionSnapshot(
      freshUntil: .distantFuture,
      isSignedIn: true,
      rows: [
        WidgetSessionRow(
          id: "demo-1", title: "Review the latest changes", workspace: "hermes",
          status: .needsInput, updatedAt: now.addingTimeInterval(-60)
        ),
        WidgetSessionRow(
          id: "demo-2", title: "Polish the session list", workspace: "hermes-mobile",
          status: .working, updatedAt: now.addingTimeInterval(-120)
        ),
        WidgetSessionRow(
          id: "demo-3", title: "Add keyboard shortcuts", workspace: "hermes-desktop",
          status: .idle, updatedAt: now.addingTimeInterval(-3_600)
        ),
        WidgetSessionRow(
          id: "demo-4", title: "Update the documentation", workspace: "docs",
          status: .idle, updatedAt: now.addingTimeInterval(-7_200)
        ),
        WidgetSessionRow(
          id: "demo-5", title: "Fix the search results", workspace: "hermes",
          status: .idle, updatedAt: now.addingTimeInterval(-86_400)
        ),
      ]
    )
  }
}
