import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Settings → App Icon. The grid is a vertical `ScrollView`, so every fixture renders at the
/// pinned device size (`deviceImage()` fixes width AND height) inside the navigation stack the
/// Settings sheet pushes it onto. `.task` is swallowed so the seeded selection is what renders
/// (the in-memory client would otherwise reload the primary as current).
final class AppIconPickerSnapshotTests: SnapshotTestCase {
  private func pickerView(_ state: AppIconPickerFeature.State) -> some View {
    NavigationStack {
      AppIconPickerView(
        store: Store(initialState: state) { AppIconPickerFeature().ignoring(\.task) }
      )
    }
  }

  /// An ALTERNATE is current: the checkmark and tint ring sit on "Hermes", not on the
  /// primary "Gold" tile — the primary is checked only when `selected == nil`.
  private let alternateSelected = AppIconPickerFeature.State(
    catalog: .testCatalog,
    selected: "AppIconHermes"
  )

  func testAppIconPicker_alternateSelected() {
    assertSnapshot(of: pickerView(alternateSelected), as: deviceImage())
  }

  func testAppIconPicker_alternateSelected_light() {
    assertSnapshot(of: pickerView(alternateSelected), as: deviceImage(appearance: .light))
  }

  /// iOS refused the change: rolled back to the primary, banner under the grid.
  func testAppIconPicker_errorBanner() {
    let state = AppIconPickerFeature.State(
      catalog: .testCatalog,
      selected: nil,
      errorBanner: AppIconPickerFeature.setFailedBanner
    )
    assertSnapshot(of: pickerView(state), as: deviceImage())
  }
}
