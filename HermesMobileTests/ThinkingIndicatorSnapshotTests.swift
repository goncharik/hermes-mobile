import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshots for the live "Thinking" indicator. `liveSeconds`/`elapsedSeconds` are pinned so
/// the timer text is deterministic; the expanded variants seed `initiallyExpanded` so the
/// disclosed body (reasoning + status) renders without driving the DisclosureGroup.
final class ThinkingIndicatorSnapshotTests: SnapshotTestCase {
  private static let reasoning = """
  The user wants a summary of the streaming protocol. Let me trace the gateway socket: \
  every event funnels through one `.gatewayEvent` action, and message deltas accumulate into \
  a single in-flight assistant row.
  """
  private static let status = "Context: 42% used (84k / 200k tokens)"

  private func host<V: View>(_ view: V) -> some View {
    view
      .padding()
      .frame(width: device.size?.width ?? 390)
      .background(Color(uiColor: .systemBackground))
  }

  /// Active, no reasoning yet — just "Thinking 2s" (timer pinned via `liveSeconds`).
  func testThinking_active_noReasoning() {
    let view = host(
      ThinkingIndicatorView(
        liveSeconds: 2,
        reasoning: "",
        status: nil,
        elapsedSeconds: 0,
        isComplete: false
      )
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// Active with the agent's spinner line as the live label (`turnActivityLabel`) — a long
  /// provider-wait line truncates to one line so the timer stays visible.
  func testThinking_active_spinnerLabel() {
    let view = host(
      ThinkingIndicatorView(
        liveLabel: "ಠ_ಠ waiting for the provider to respond (retry 2 of 5, rate limited)…",
        liveSeconds: 19,
        reasoning: "",
        status: nil,
        elapsedSeconds: 0,
        isComplete: false,
        reduceMotionOverride: true
      )
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// Active, expanded — reasoning + status in the disclosed area at 1m 5s.
  func testThinking_active_reasoningAndStatus_expanded() {
    let view = host(
      ThinkingIndicatorView(
        liveSeconds: 65,
        reasoning: Self.reasoning,
        status: Self.status,
        elapsedSeconds: 0,
        isComplete: false,
        initiallyExpanded: true
      )
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// Completed, collapsed — static "Thinking · 1m 3s" disclosure.
  func testThinking_completed_collapsed() {
    let view = host(
      ThinkingIndicatorView(
        liveSeconds: 0,
        reasoning: Self.reasoning,
        status: Self.status,
        elapsedSeconds: 63,
        isComplete: true
      )
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// Completed, expanded — frozen "Thinking · 1m 3s" with reasoning + status revealed.
  func testThinking_completed_expanded() {
    let view = host(
      ThinkingIndicatorView(
        liveSeconds: 0,
        reasoning: Self.reasoning,
        status: Self.status,
        elapsedSeconds: 63,
        isComplete: true,
        initiallyExpanded: true
      )
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// Active under reduce-motion — the shimmer is held flat. `accessibilityReduceMotion` is a
  /// read-only `KeyPath` (not `WritableKeyPath`), so it can't be injected via `.environment`;
  /// the view exposes a test-only override instead.
  func testThinking_active_reduceMotion() {
    let view = host(
      ThinkingIndicatorView(
        liveSeconds: 2,
        reasoning: "",
        status: nil,
        elapsedSeconds: 0,
        isComplete: false,
        reduceMotionOverride: true
      )
    )
    assertSnapshot(of: view, as: componentImage())
  }
}
