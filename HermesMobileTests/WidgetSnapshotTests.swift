import HermesWidgetKit
import SnapshotTesting
import SwiftUI
import XCTest

/// The widget extension's plain views (#138), compiled into this target directly (an
/// extension can't be imported), rendered at the widget family sizes inside a stand-in for the
/// system's widget chrome: the default 16 pt content margins, the background, the rounded
/// corners.
///
/// The tinted / clear Home Screen rendering modes are NOT covered here: `widgetRenderingMode`
/// is a read-only environment value only WidgetKit's own host sets, so a plain view can't be
/// rendered in `.accented` — those modes are an on-device check (see the plan's
/// Post-Completion list). The glyphs are `widgetAccentable()` for them.
final class WidgetSnapshotTests: SnapshotTestCase {
  /// iPhone 13 Pro widget sizes, matching `SnapshotTestCase.device`.
  private enum Family {
    static let small = CGSize(width: 158, height: 158)
    static let medium = CGSize(width: 338, height: 158)
    static let large = CGSize(width: 338, height: 354)
    static let accessoryCircular = CGSize(width: 76, height: 76)
  }

  private func homeScreenWidget(_ content: some View, size: CGSize) -> some View {
    content
      .padding(16)
      .frame(width: size.width, height: size.height)
      .background(.background)
      .clipShape(.rect(cornerRadius: 22, style: .continuous))
  }

  // MARK: Quick actions

  func testQuickActions_small_dark() {
    let view = homeScreenWidget(QuickActionsView(layout: .small), size: Family.small)
    assertSnapshot(of: view, as: componentImage())
  }

  func testQuickActions_small_light() {
    let view = homeScreenWidget(QuickActionsView(layout: .small), size: Family.small)
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  func testQuickActions_medium_dark() {
    let view = homeScreenWidget(QuickActionsView(layout: .medium), size: Family.medium)
    assertSnapshot(of: view, as: componentImage())
  }

  func testQuickActions_medium_light() {
    let view = homeScreenWidget(QuickActionsView(layout: .medium), size: Family.medium)
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  // MARK: Sessions

  /// Every glyph and meta shape: needs input, working, idle without a workspace, idle, and a
  /// long title that truncates. `freshUntil` is an hour after the fixed `now`.
  private var sessionsSnapshot: WidgetSessionSnapshot {
    WidgetSessionSnapshot(
      freshUntil: now.addingTimeInterval(3_600),
      isSignedIn: true,
      rows: [
        WidgetSessionRow(
          id: "a", title: "Review the latest changes", workspace: "hermes",
          status: .needsInput, updatedAt: now.addingTimeInterval(-45), profile: "default"
        ),
        WidgetSessionRow(
          id: "b", title: "Polish the session list", workspace: "hermes-mobile",
          status: .working, updatedAt: now.addingTimeInterval(-12 * 60), profile: "default"
        ),
        WidgetSessionRow(
          id: "c", title: "Add keyboard shortcuts",
          status: .idle, updatedAt: now.addingTimeInterval(-(2 * 3_600 + 5 * 60))
        ),
        WidgetSessionRow(
          id: "d", title: "Update the documentation", workspace: "docs",
          status: .idle, updatedAt: now.addingTimeInterval(-86_400)
        ),
        WidgetSessionRow(
          id: "e",
          title: "Fix the search results that skip archived sessions on the second page",
          workspace: "hermes", status: .idle, updatedAt: now.addingTimeInterval(-3 * 86_400)
        ),
      ]
    )
  }

  private func sessionsWidget(
    _ layout: SessionsWidgetLayout,
    snapshot: WidgetSessionSnapshot,
    at date: Date? = nil
  ) -> some View {
    homeScreenWidget(
      SessionsWidgetView(
        layout: layout,
        snapshot: snapshot,
        date: date ?? now,
        relativeTime: .fixed(now: now)
      ),
      size: layout == .large ? Family.large : Family.medium
    )
  }

  func testSessions_medium_dark() {
    let view = sessionsWidget(.medium, snapshot: sessionsSnapshot)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessions_medium_light() {
    let view = sessionsWidget(.medium, snapshot: sessionsSnapshot)
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  func testSessions_large_dark() {
    let view = sessionsWidget(.large, snapshot: sessionsSnapshot)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessions_large_light() {
    let view = sessionsWidget(.large, snapshot: sessionsSnapshot)
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  /// The timeline's second entry, dated `freshUntil`: working / needs-input glyphs turn into
  /// the outdated clock; titles and idle rows stay.
  func testSessions_large_outdated() {
    let snapshot = sessionsSnapshot
    let view = sessionsWidget(.large, snapshot: snapshot, at: snapshot.freshUntil)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessions_medium_outdated() {
    let snapshot = sessionsSnapshot
    let view = sessionsWidget(.medium, snapshot: snapshot, at: snapshot.freshUntil)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessions_medium_signedOut() {
    let view = sessionsWidget(.medium, snapshot: .signedOut)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessions_large_signedOut() {
    let view = sessionsWidget(.large, snapshot: .signedOut)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessions_medium_empty() {
    let snapshot = WidgetSessionSnapshot(
      freshUntil: now.addingTimeInterval(3_600), isSignedIn: true, rows: []
    )
    let view = sessionsWidget(.medium, snapshot: snapshot)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessions_large_empty_light() {
    let snapshot = WidgetSessionSnapshot(
      freshUntil: now.addingTimeInterval(3_600), isSignedIn: true, rows: []
    )
    let view = sessionsWidget(.large, snapshot: snapshot)
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  // MARK: Live Activity

  /// The Lock Screen banner's width on the snapshot device (the screen less the system's
  /// margins); its height is the view's own.
  private let activityWidth: CGFloat = 358

  private func activityContent(
    _ count: Int,
    title: String? = "Model picker provider visibility",
    status: AgentActivityContent.Status = .working
  ) -> AgentActivityContent {
    AgentActivityContent(
      activeCount: count,
      headlineTitle: title,
      headlineSessionID: "s1",
      headlineProfile: "default",
      status: status
    )
  }

  /// A stand-in for the Lock Screen's activity platter: the system background, rounded. The
  /// iOS 26 glass (`activityBackgroundTint(.clear)`) only the system draws — a device check.
  private func lockScreenActivity(_ content: AgentActivityContent, isStale: Bool = false) -> some View {
    AgentsActivityView(content: content, isStale: isStale)
      .frame(width: activityWidth)
      .background(.background)
      .clipShape(.rect(cornerRadius: 22, style: .continuous))
  }

  /// One agent working; the long title truncates before the status (T3 layout).
  func testLiveActivity_working_dark() {
    assertSnapshot(of: lockScreenActivity(activityContent(1)), as: componentImage())
  }

  func testLiveActivity_working_light() {
    assertSnapshot(
      of: lockScreenActivity(activityContent(1)), as: componentImage(appearance: .light)
    )
  }

  func testLiveActivity_needsInput() {
    let content = activityContent(2, title: "Review the release notes", status: .needsInput)
    assertSnapshot(of: lockScreenActivity(content), as: componentImage())
  }

  /// The final content left on screen after the last agent finishes.
  func testLiveActivity_done() {
    let content = activityContent(0, title: "Review the release notes", status: .done)
    assertSnapshot(of: lockScreenActivity(content), as: componentImage())
  }

  /// Past the stale date (the app stopped observing): "Outdated" instead of a guess.
  func testLiveActivity_outdated() {
    assertSnapshot(of: lockScreenActivity(activityContent(3), isStale: true), as: componentImage())
  }

  /// "Show session titles" off: the row shows only the status.
  func testLiveActivity_titleOmitted() {
    assertSnapshot(of: lockScreenActivity(activityContent(1, title: nil)), as: componentImage())
  }

  /// The expanded Dynamic Island's bottom region: the same layout on the island's black,
  /// inside its margins.
  func testLiveActivity_expanded() {
    let view = AgentsActivityView(
      content: activityContent(2, status: .needsInput), isStale: false, style: .expanded
    )
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(width: 371)
    .background(Color.black)
    .clipShape(.rect(cornerRadius: 44, style: .continuous))
    assertSnapshot(of: view, as: componentImage())
  }

  /// The compact Dynamic Island's trailing side: the count while working, "?" while the
  /// headline needs input, a checkmark once done, a secondary count once stale.
  func testLiveActivity_compactTrailing() {
    let view = HStack(spacing: 16) {
      AgentsActivityCompactTrailing(content: activityContent(2), isStale: false)
      AgentsActivityCompactTrailing(content: activityContent(2, status: .needsInput), isStale: false)
      AgentsActivityCompactTrailing(content: activityContent(0, status: .done), isStale: false)
      AgentsActivityCompactTrailing(content: activityContent(2), isStale: true)
    }
    .padding(12)
    .background(Color.black)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Lock Screen accessory

  /// Over a dark wallpaper stand-in: the accessory backdrop is a translucent system material.
  func testNewChatAccessory_circular() {
    let view = NewChatAccessoryView()
      .frame(width: Family.accessoryCircular.width, height: Family.accessoryCircular.height)
      .padding(12)
      .background(Color(white: 0.15))
    assertSnapshot(of: view, as: componentImage())
  }
}
