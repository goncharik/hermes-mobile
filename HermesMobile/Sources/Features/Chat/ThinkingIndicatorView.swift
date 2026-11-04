import HermesKit
import SwiftUI

/// The live "Thinking" indicator that owns a turn's reasoning + status line.
///
/// While the turn is in flight (`isComplete == false`) it shows a shimmering live label
/// (`store.turnActivityLabel ?? "Thinking"` — the agent's spinner line) with a live
/// `1h 1m 1s` elapsed timer (read from `store.turnSeconds` via `liveSeconds`); its disclosed
/// area accumulates the reasoning text and the latest `status.update` line and shimmers
/// alongside the label. On completion it freezes into a static, collapsed
/// `Thought · <elapsed>` disclosure kept in the transcript so past reasoning stays reviewable.
struct ThinkingIndicatorView: View {
  /// The live header text while active; ignored once complete.
  let liveLabel: String
  /// Live elapsed seconds while active (`store.turnSeconds`); ignored once complete.
  let liveSeconds: Int
  /// Accumulated reasoning/thinking text (may be empty while only status has arrived).
  let reasoning: String
  /// Latest `status.update` text (context-size / compaction line), shown in the body.
  let status: String?
  /// Frozen elapsed, written at completion; read instead of `liveSeconds` when complete.
  let elapsedSeconds: Int
  /// `false` while the turn runs (live timer + shimmer), `true` once frozen.
  let isComplete: Bool

  /// Forces the reduce-motion (flat) shimmer variant when non-nil; `nil` reads the
  /// `accessibilityReduceMotion` environment value (production default). Only set in
  /// snapshot tests: `accessibilityReduceMotion` is a read-only `KeyPath`, not a
  /// `WritableKeyPath`, so `.environment(\.accessibilityReduceMotion, …)` does not compile
  /// and the value can't be injected into the snapshot host.
  let reduceMotionOverride: Bool?

  @State private var isExpanded: Bool
  @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

  init(
    liveLabel: String = "Thinking",
    liveSeconds: Int,
    reasoning: String,
    status: String?,
    elapsedSeconds: Int,
    isComplete: Bool,
    initiallyExpanded: Bool = false,
    reduceMotionOverride: Bool? = nil
  ) {
    self.liveLabel = liveLabel
    self.liveSeconds = liveSeconds
    self.reasoning = reasoning
    self.status = status
    self.elapsedSeconds = elapsedSeconds
    self.isComplete = isComplete
    self.reduceMotionOverride = reduceMotionOverride
    _isExpanded = State(initialValue: initiallyExpanded)
  }

  private var reduceMotion: Bool { reduceMotionOverride ?? environmentReduceMotion }
  /// The disclosed area shimmers in lock-step with the header while the turn is live.
  private var isShimmering: Bool { !isComplete && !reduceMotion }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      disclosedBody
        .shimmering(active: isShimmering)
    } label: {
      label
    }
    .font(.caption)
    // Default disclosure styling tints the label + chevron with the accent colour, which
    // reads as a low-contrast dark blue on black. Force the primary colour so the row stays
    // legible in dark mode (the active label manages its own colour + shimmer).
    .tint(.primary)
  }

  /// Header label: the live shimmering "Thinking …" while running, a static high-contrast
  /// "Thought · <elapsed>" once frozen.
  @ViewBuilder
  private var label: some View {
    if isComplete {
      // Show the elapsed time only when we actually know it. A turn re-hydrated from
      // history has no client-measured duration (elapsedSeconds == 0) — show a bare
      // "Thought" rather than a misleading "Thought · 0s".
      Text(elapsedSeconds > 0 ? "Thought · \(formatElapsed(elapsedSeconds))" : "Thought")
        .font(.caption)
        .foregroundStyle(.primary)
    } else {
      ThinkingLabel(text: liveLabel, elapsed: liveSeconds, reduceMotionOverride: reduceMotionOverride)
    }
  }

  /// Shared disclosed body: reasoning then the latest status line.
  @ViewBuilder
  private var disclosedBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !reasoning.isEmpty {
        Text(reasoning)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let status, !status.isEmpty {
        Label(status, systemImage: "ellipsis.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The active label: the live text ("Thinking" or the agent's spinner line) + a live elapsed
/// timer, with a shimmer that sweeps the text while the turn runs. Held flat under
/// reduce-motion. One line: a long provider-wait line truncates, the timer stays visible.
private struct ThinkingLabel: View {
  let text: String
  let elapsed: Int
  /// When non-nil, overrides the environment reduce-motion value (snapshot tests only).
  var reduceMotionOverride: Bool?

  @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

  private var reduceMotion: Bool { reduceMotionOverride ?? environmentReduceMotion }

  var body: some View {
    HStack(spacing: 6) {
      Text(text)
        .font(.caption.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
      Text(formatElapsed(elapsed))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .shimmering(active: !reduceMotion)
  }
}

/// A bright band swept across the modified content via a moving linear gradient, masked to
/// the content's own shape so only the text (label or reasoning/status) lights up. Shared by
/// the header label and the disclosed body so they shimmer identically; a no-op (flat) when
/// `active` is false (turn complete or reduce-motion).
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
