import ComposableArchitecture
import HermesKit
import SwiftUI

/// The agent updater's rows inside the Settings Server section, directly under the Agent
/// version row. Renders nothing while the updater is hidden (unchecked, unsupported server,
/// no dashboard credential). Behavior lives in `AgentUpdateFeature`.
struct AgentUpdateRows: View {
  @Bindable var store: StoreOf<AgentUpdateFeature>

  var body: some View {
    Group {
      switch store.phase {
      case .hidden:
        EmptyView()
      case .checking:
        status("Checking for updates…", systemImage: "arrow.triangle.2.circlepath", color: .secondary)
      case .ready:
        readyRows
      case .starting, .running:
        status(
          "Updating Hermes… Sessions on this server may be interrupted.",
          systemImage: "arrow.triangle.2.circlepath", color: .secondary
        )
      case .externalRunning:
        status(
          "An update started elsewhere is running on this server.",
          systemImage: "arrow.triangle.2.circlepath", color: .secondary
        )
      case let .succeeded(version):
        status(
          version.map { "Hermes updated to \($0)." } ?? "Hermes updated.",
          systemImage: "checkmark.circle", color: .green
        )
      case let .failed(reason):
        status(reason, systemImage: "exclamationmark.triangle", color: .orange)
      case .uncertain:
        status(
          "Update result unknown. Check its status or the server's update log before trying again.",
          systemImage: "questionmark.circle", color: .orange
        )
      }
      if store.offersStatusRecheck {
        // Read-only status GET; never re-sends the update.
        Button(store.isRechecking ? "Checking status…" : "Check update status") {
          store.send(.recheckTapped)
        }
        .disabled(store.isRechecking)
      } else if store.offersCheckAgain {
        Button(store.isRechecking ? "Checking…" : "Check for updates") {
          store.send(.recheckTapped)
        }
        .disabled(store.isRechecking)
      }
    }
    // `.bottomActionSheet`, not `.confirmationDialog` — on iOS 26 the system dialog renders
    // as a title-less floating popover (FB20644893; see `BottomActionSheet.swift`).
    .bottomActionSheet($store.scope(state: \.confirmationDialog, action: \.confirmationDialog))
  }

  @ViewBuilder
  private var readyRows: some View {
    if store.offersUpdate {
      HStack {
        Label(availableLabel, systemImage: "arrow.down.circle")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Update") { store.send(.updateTapped) }
          .buttonStyle(.borderless)
      }
    } else if let guidance = store.guidance {
      // Docker, nix, apt or managed installs: the server says how they update.
      Text(guidance)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var availableLabel: String {
    switch store.check?.behind {
    case let behind? where behind > 0:
      behind == 1 ? "Update available (1 commit)" : "Update available (\(behind) commits)"
    default:
      "Update available"
    }
  }

  private func status(_ text: String, systemImage: String, color: Color) -> some View {
    Label(text, systemImage: systemImage)
      .font(.footnote)
      .foregroundStyle(color)
  }
}
