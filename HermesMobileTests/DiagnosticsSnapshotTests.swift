import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Settings → Diagnostics: the copy button above the live gateway log. `.task` is swallowed so
/// the seeded log renders instead of the debug-log stream.
final class DiagnosticsSnapshotTests: SnapshotTestCase {
  private let entries = [
    GatewayLogEntry(id: 0, type: "gateway.ready", summary: ""),
    GatewayLogEntry(id: 1, type: "tool.start", summary: "read_file"),
    GatewayLogEntry(id: 2, type: "message.delta", summary: "WebSocket JSON-RPC at /api/ws"),
    GatewayLogEntry(id: 3, type: "status.update", summary: "[lifecycle] thinking…"),
  ]

  private func diagnosticsView(
    log: [GatewayLogEntry],
    copiedToken: Int? = nil
  ) -> some View {
    let state = DiagnosticsFeature.State(
      serverURL: connection.baseURL,
      authLabel: "Token",
      agentVersion: "0.12.0",
      log: log,
      copiedToken: copiedToken
    )
    return NavigationStack {
      DiagnosticsView(
        store: Store(initialState: state) { DiagnosticsFeature().ignoring(\.task) }
      )
    }
  }

  func testDiagnosticsView() {
    assertSnapshot(of: diagnosticsView(log: entries), as: deviceImage())
  }

  /// Just copied: the "Diagnostics copied" toast over the bottom of the log.
  func testDiagnosticsView_copied() {
    assertSnapshot(of: diagnosticsView(log: entries, copiedToken: 1), as: deviceImage())
  }

  /// No gateway events yet: the empty state is a row under the copy button, not an overlay
  /// hiding it.
  func testDiagnosticsView_empty() {
    assertSnapshot(of: diagnosticsView(log: []), as: deviceImage())
  }
}
