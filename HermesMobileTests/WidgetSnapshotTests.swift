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
