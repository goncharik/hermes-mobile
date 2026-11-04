import HermesKit
import SwiftUI

/// A turn's fold header (tool-call display plan, Phase B): the small grey line between the
/// user's prompt and the agent's reply, with a hairline under it.
///
/// - Finished: `Worked for 4m 31s ›` — collapsed by default; a tap lists what the turn did.
/// - Running: the agent's spinner line (else "Working") with a live timer, shimmering, then the
///   latest `status.update` as a caption; collapsed, one more line names what the agent is
///   doing right now (`TurnHeader.liveLine`).
/// - The headerless live indicator (`TranscriptItem.liveIndicator`): the running look with no
///   chevron and no tap (`isExpanded == nil`).
///
/// Pure display: every value comes in from the caller (`ChatView` reads the store); the tap is
/// an `onTapGesture` with button traits, not a `Button` — a `Button` inside the transcript's
/// scroll view lost taps.
struct TurnHeaderView: View {
  /// Running: the live label (`TurnHeader.liveLabel`); finished: `Worked for …` / `Worked`.
  let label: String
  /// Running only: the turn timer, laid beside the label so a long label truncates, not it.
  let elapsedSeconds: Int?
  /// Whether the turn's folded content shows; `nil` = not foldable (the live indicator).
  let isExpanded: Bool?
  /// Running only: the latest `status.update` line.
  var status: String?
  /// A collapsed running turn only: what the agent is doing right now.
  var liveLine: String?
  /// Forces the flat (reduce-motion) label when non-nil — snapshot tests only, since
  /// `accessibilityReduceMotion` can't be injected through `.environment`.
  var reduceMotionOverride: Bool?
  var onTap: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

  private var reduceMotion: Bool { reduceMotionOverride ?? environmentReduceMotion }
  private var isRunning: Bool { elapsedSeconds != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      titleLine
      if let status = status?.nonBlank {
        Label(status, systemImage: "ellipsis.circle")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let liveLine = liveLine?.nonBlank {
        Text(liveLine)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
    }
    .contentShape(Rectangle())
    .foldTap(isExpanded: isExpanded, action: onTap)
  }

  private var titleLine: some View {
    HStack(spacing: 6) {
      Group {
        if let elapsedSeconds {
          HStack(spacing: 4) {
            Text(label)
              .lineLimit(1)
              .truncationMode(.tail)
            Text("· \(formatElapsed(elapsedSeconds))")
              .monospacedDigit()
              .fixedSize()
          }
          .shimmering(active: !reduceMotion)
        } else {
          Text(label).lineLimit(1)
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      if let isExpanded {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 0)
    }
  }
}

extension String {
  /// `nil` when blank (only whitespace / newlines).
  fileprivate var nonBlank: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}

extension View {
  /// A fold line's tap: an `onTapGesture` with button traits (a `Button` inside the
  /// transcript's scroll view lost taps), announcing the expanded state when the line folds
  /// something. No tap at all when `action` is `nil`.
  @ViewBuilder
  func foldTap(isExpanded: Bool?, action: (() -> Void)?) -> some View {
    if let action {
      self
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded.map { $0 ? "Expanded" : "Collapsed" } ?? "")
    } else {
      self.accessibilityElement(children: .combine)
    }
  }
}

/// A bright band swept across the modified content via a moving linear gradient, masked to
/// the content's own shape so only the text lights up. A no-op (flat) when `active` is false
/// (turn finished, or reduce-motion).
private struct ShimmerModifier: ViewModifier {
  let active: Bool
  @State private var phase: CGFloat = -1

  func body(content: Content) -> some View {
    content.overlay {
      if active {
        GeometryReader { geo in
          LinearGradient(
            colors: [.clear, Color.white.opacity(0.65), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: geo.size.width * 0.5)
          .offset(x: phase * geo.size.width * 1.5)
          .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .mask { content }
        .onAppear {
          withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            phase = 1
          }
        }
      }
    }
  }
}

extension View {
  /// Sweep a shimmer band across this view's content while `active`; flat otherwise.
  func shimmering(active: Bool) -> some View {
    modifier(ShimmerModifier(active: active))
  }
}
