import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// The "Reading aloud" pill (#74), pinned above the composer while a read-aloud clip is
/// preparing or playing. Each baseline stacks both states top to bottom — PREPARING (spinner +
/// "Preparing audio") and SPEAKING (accent speaker + "Reading aloud") — with the Stop button
/// trailing; the render HEIGHT pins the pill to one fixed line (#65's non-scrolling region).
/// The Stop wiring is reducer-tested (`.stopReadAloud` in `ChatReadAloudTests`).
final class ReadAloudPillSnapshotTests: SnapshotTestCase {
  func testReadAloudPill() {
    assertSnapshot(of: pillStack(), as: componentImage())
  }

  /// Light rendering: the secondary-background capsule and the accent glyph against a light
  /// background are what is under test.
  func testReadAloudPill_light() {
    assertSnapshot(of: pillStack(), as: componentImage(appearance: .light))
  }

  private func pillStack() -> some View {
    VStack(spacing: 0) {
      ReadAloudPill(state: .preparing(id(1)), onStop: {})
      ReadAloudPill(state: .speaking(id(1)), onStop: {})
    }
    .padding(.bottom, 6)
    .frame(width: device.size?.width ?? 390)
    .background(Color(uiColor: .systemBackground))
  }
}
