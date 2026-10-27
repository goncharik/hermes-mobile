import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// The queued-prompt panel (#66): compact rows above the composer with per-row context
/// menus. Snapshots pin the queued vs held (parked) presentations, the two-line clamp,
/// the paperclip badge, and the >3-entry fixed-height scroll shape. The context menu
/// itself can't be snapshotted (it's a system presentation) — its wiring is reducer-
/// tested in `ChatQueueTests`.
final class QueuedPromptsPanelSnapshotTests: SnapshotTestCase {
  private func panel(
    entries: [QueuedPrompt], isParked: Bool = false, composerHasDraft: Bool = false,
    isTurnRunning: Bool = true
  ) -> some View {
    QueuedPromptsPanel(
      entries: entries,
      isParked: isParked,
      composerHasDraft: composerHasDraft,
      isTurnRunning: isTurnRunning,
      onSteer: { _ in }, onSendNow: { _ in }, onEdit: { _ in }, onDelete: { _ in }
    )
    .frame(width: device.size?.width ?? 390)
    .background(Color(uiColor: .systemBackground))
  }

  func testQueuedPanel_entriesClampAndBadge() {
    let entries = [
      QueuedPrompt(id: id(1), text: "Also check the reconnect backoff while you're at it"),
      QueuedPrompt(
        id: id(2),
        text: """
        And after that, take the whole streaming fold apart for me — I want to know exactly \
        how the thinking row is created, when the elapsed timer starts, and what happens to \
        it when the socket drops halfway through a turn.
        """
      ),
      QueuedPrompt(
        id: id(3),
        text: "What's in this file?",
        attachments: [
          ComposerAttachment(
            id: id(9), kind: .image, filename: "sunset.png", mimeType: "image/png",
            data: solidPNG(.systemOrange)
          )
        ]
      ),
    ]
    assertSnapshot(of: panel(entries: entries), as: componentImage())
  }

  func testQueuedPanel_parkedShowsHeldHeaderAndPauseIcons() {
    let entries = [
      QueuedPrompt(id: id(1), text: "Held after the stop"),
      QueuedPrompt(id: id(2), text: "Me too"),
    ]
    assertSnapshot(of: panel(entries: entries, isParked: true), as: componentImage())
  }

  func testQueuedPanel_manyEntriesScrollAtFixedHeight() {
    // Beyond `inlineRowLimit` the panel stops hugging and scrolls at a fixed height —
    // the snapshot's render HEIGHT is the load-bearing assertion (an unbounded panel
    // would grow past it and squeeze the transcript, the #65 failure mode).
    let entries = (1...6).map {
      QueuedPrompt(id: id($0), text: "Queued thought number \($0)")
    }
    assertSnapshot(of: panel(entries: entries), as: componentImage())
  }
}
