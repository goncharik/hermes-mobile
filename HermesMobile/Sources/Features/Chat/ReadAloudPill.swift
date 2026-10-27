import HermesKit
import SwiftUI

/// The "Reading aloud" pill (#74): one fixed line pinned above the composer while a
/// read-aloud clip is preparing or playing — the desktop's `VoicePlaybackActivity`. Preparing
/// shows a spinner + "Preparing audio" (`POST /api/audio/speak` is synthesizing), speaking a
/// speaker glyph + "Reading aloud"; the trailing Stop silences the clip (`.stopReadAloud`).
///
/// Mounted by `ChatView` only while `ttsPlayback` is active, so `.idle` is never rendered.
/// It sits in the same non-scrolling region as the cards and the queued-prompt panel (#65): a
/// single line of fixed height, never a growing block, so it cannot squeeze the transcript or
/// out-bid a pending card's `layoutPriority`.
struct ReadAloudPill: View {
  let state: ChatFeature.State.TTSPlayback
  let onStop: () -> Void

  private var isPreparing: Bool {
    if case .preparing = state { true } else { false }
  }

  private var title: String { isPreparing ? "Preparing audio" : "Reading aloud" }

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if isPreparing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "speaker.wave.2")
            .foregroundStyle(Color.hermesAccent)
        }
      }
      // One slot for both leading glyphs, so the label doesn't shift on preparing → speaking.
      .frame(width: 22)
      Text(title)
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: onStop) {
        Label("Stop", systemImage: "speaker.slash")
          .font(.footnote.weight(.semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .contentShape(.capsule)
      }
      .buttonStyle(.borderless)
      .tint(Color.hermesAccent)
    }
    .padding(.leading, 12)
    .padding(.trailing, 4)
    .padding(.vertical, 4)
    // Styled like a `QueuedPromptsPanel` row (secondary background, same insets) so the two
    // pinned panels read as one family when both stand.
    .background(Color(uiColor: .secondarySystemBackground), in: .capsule)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.updatesFrequently)
    .padding(.horizontal)
    .padding(.top, 6)
    // VoiceOver focus stays wherever it was (the composer, a row), so rendering alone tells a
    // VoiceOver user nothing about the clip that is about to talk over them. Announce the
    // pill's appearance and the preparing → speaking change.
    .onChange(of: title, initial: true) { _, title in
      AccessibilityNotification.Announcement(title).post()
    }
  }
}
