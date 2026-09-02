import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshots for the empty-chat hero (#80) — the wordmark + tagline that replaces the
/// transcript region while `ChatFeature.State.showsEmptyHero` is true.
///
/// Every component render pins BOTH width and height: the hero fills the greedy slot the
/// transcript (a scrollable region) would occupy, and `componentImage()` renders at
/// `.sizeThatFits`, which offers a greedy view nothing along either axis — an unpinned hero
/// would record its text's natural size, not the centered region it actually paints.
/// `.dynamicTypeSize(.large)` is pinned so the render doesn't follow the simulator's text
/// size; the accessibility variant varies it deliberately.
final class ChatEmptyHeroSnapshotTests: SnapshotTestCase {
  /// The 760pt column the readable-width cap gives the hero on iPad regular width
  /// (`ChatLayout.readableMaxWidth`) — read from HermesKit so the two never drift.
  private let columnWidth = ChatLayout.readableMaxWidth
  /// Tall enough that the hero's vertical centering is visible, short enough to read.
  private let regionHeight: CGFloat = 480
  /// The simulator's own width (the column below the cap), with the iPhone 17 Pro's as the
  /// fallback when the runtime doesn't report one.
  private var phoneWidth: CGFloat { device.size?.width ?? 390 }

  private func host(width: CGFloat, dynamicType: DynamicTypeSize = .large) -> some View {
    ChatEmptyHeroView()
      .frame(width: width, height: regionHeight)
      .background(Color(uiColor: .systemBackground))
      .dynamicTypeSize(dynamicType)
  }

  // MARK: Phone width (the column below the cap)

  func testHero_phoneWidth_dark() {
    assertSnapshot(of: host(width: phoneWidth), as: componentImage())
  }

  func testHero_phoneWidth_light() {
    assertSnapshot(of: host(width: phoneWidth), as: componentImage(appearance: .light))
  }

  // MARK: 760pt column (the readable-width cap on iPad)

  func testHero_readableColumn_dark() {
    assertSnapshot(of: host(width: columnWidth), as: componentImage())
  }

  func testHero_readableColumn_light() {
    assertSnapshot(of: host(width: columnWidth), as: componentImage(appearance: .light))
  }

  // MARK: Dynamic Type

  /// `.accessibility3` at phone width: the wordmark wraps onto a second line rather than
  /// truncating, and the tagline stays legible and centered under it.
  func testHero_phoneWidth_accessibility3() {
    assertSnapshot(
      of: host(width: phoneWidth, dynamicType: .accessibility3),
      as: componentImage()
    )
  }

  // MARK: Region swap in `ChatView`

  /// A brand-new chat (no stored id, empty transcript) renders the hero in the transcript's
  /// region with the composer pinned below — the swap `ChatView.transcript` performs on
  /// `showsEmptyHero`. The fixed `phoneWidth`×700 frame stands in for the device: `deviceImage()`
  /// hosts in the key window and would fire `.task` (a real connect attempt) — this stays a
  /// deterministic layer render. The state is seeded `.ready` so no banner shares the frame.
  func testChatView_newChat_showsHero() {
    let view = NavigationStack {
      ChatView(
        store: Store(initialState: ChatFeature.State(connection: connection, status: .ready)) {
          ChatFeature()
        } withDependencies: {
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
        }
      )
    }
    .frame(width: phoneWidth, height: 700)
    .dynamicTypeSize(.large)
    assertSnapshot(of: view, as: componentImage())
  }
}
