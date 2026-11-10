import HermesKit
import SwiftUI

/// The queued-prompt panel (#66): compact rows pinned between the transcript and the
/// composer (above the slash-suggestion panel — deliberately NOT in the transcript, so
/// wholesale hydrates can never touch it). Each row is a frozen draft waiting for the
/// running turn to end; the context menu offers Steer Now / Send Now / Edit / Delete.
///
/// Sizing: this sits in the same non-scrolling, compressible region #65 mapped out, so
/// the panel must never grow unbounded and squeeze the transcript. Up to
/// `inlineRowLimit` rows it hugs its content (a plain `VStack`); beyond that it becomes
/// a `ScrollView` at a fixed capped height — fixed rather than `min(content, cap)`
/// because a `ScrollView` handed a concrete height proposal swallows it whole (the
/// repo-gotcha `BoundedHeightLayout` exists to work around), and at >3 rows the content
/// provably exceeds any reasonable cap anyway, so the general layout machinery buys
/// nothing here.
struct QueuedPromptsPanel: View {
  let entries: [QueuedPrompt]
  /// Parked (#66): a manual Stop or a turn error suspended auto-drain — the rows wait
  /// for an explicit Send Now. Swaps the row icon and adds the "held" header.
  let isParked: Bool
  /// Mirrors the reducer's Edit guard (`.queuedPromptEditTapped` requires an empty
  /// composer): the menu item is disabled while a draft is mid-typing so the two can't
  /// disagree — the reducer stays authoritative.
  let composerHasDraft: Bool
  /// The reducer's `canSteerQueued` (a turn running, steer supported, none in flight). Steer
  /// Now shows only with it and for `SteerEligibility.isSteerable` entries; the reducer
  /// re-checks both.
  var canSteer: Bool = false
  var onSteer: (UUID) -> Void = { _ in }
  /// The entry whose steer is in flight: it shows a spinner and "Steering…", and its menu is
  /// inert until the server answers (the reducer ignores those taps too).
  var steeringID: UUID?
  let onSendNow: (UUID) -> Void
  let onEdit: (UUID) -> Void
  let onDelete: (UUID) -> Void

  /// Rows beyond which the panel stops hugging and scrolls internally.
  private static let inlineRowLimit = 3
  /// The scrolling panel's fixed height — roughly three two-line rows, scaled with
  /// Dynamic Type so the row count it shows stays stable across text sizes.
  @ScaledMetric(relativeTo: .callout) private var scrollingPanelHeight: CGFloat = 172

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if isParked {
        // Held rows look identical to queued ones at a glance — say why nothing is
        // sending. (Queued rows need no header: the turn spinner right above them
        // already explains the wait.)
        Label("Held — not sent automatically", systemImage: "pause.circle")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      }
      if entries.count > Self.inlineRowLimit {
        ScrollView {
          rowsStack
        }
        .frame(height: scrollingPanelHeight)
        .scrollIndicators(.visible)
      } else {
        rowsStack
      }
    }
    .padding(.horizontal)
    .padding(.top, 6)
  }

  private var rowsStack: some View {
    VStack(spacing: 6) {
      ForEach(entries) { entry in
        row(entry)
      }
    }
  }

  private func row(_ entry: QueuedPrompt) -> some View {
    let isSteering = entry.id == steeringID
    return HStack(spacing: 8) {
      if isSteering {
        // `session.steer` can take up to the 30s RPC timeout: say the entry is on its way
        // instead of leaving a row whose menu just went empty.
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: isParked ? "pause.circle" : "clock")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Text(displayText(entry))
        .font(.callout)
        .lineLimit(2)
        // Without this the HStack's ideal-height pass hands the Text a one-line
        // proposal and it TRUNCATES at one line instead of wrapping to the two
        // `lineLimit` allows (verified in the first recorded baseline).
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !entry.attachments.isEmpty {
        Label("\(entry.attachments.count)", systemImage: "paperclip")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if isSteering {
        Text("Steering…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
    .contentShape(.rect(cornerRadius: 14))
    .contextMenu {
      if !isSteering {
        menuItems(entry)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(isSteering ? "Steering" : isParked ? "Held" : "Queued") message: \(displayText(entry))"
    )
  }

  @ViewBuilder
  private func menuItems(_ entry: QueuedPrompt) -> some View {
    if canSteer, SteerEligibility.isSteerable(entry) {
      Button { onSteer(entry.id) } label: {
        Label("Steer Now", systemImage: "arrow.turn.down.right")
      }
    }
    Button { onSendNow(entry.id) } label: {
      Label("Send Now", systemImage: "paperplane")
    }
    Button { onEdit(entry.id) } label: {
      Label("Edit", systemImage: "pencil")
    }
    .disabled(composerHasDraft)
    Button(role: .destructive) { onDelete(entry.id) } label: {
      Label("Delete", systemImage: "trash")
    }
  }

  /// An attachment-only draft has no text to show — fall back to its filenames.
  private func displayText(_ entry: QueuedPrompt) -> String {
    entry.text.isEmpty
      ? entry.attachments.map(\.filename).joined(separator: ", ")
      : entry.text
  }
}
