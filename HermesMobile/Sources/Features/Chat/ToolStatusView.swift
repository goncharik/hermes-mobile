import HermesKit
import SwiftUI

/// A tool/skill activity row: icon + human title (with the raw tool name beneath when
/// they differ), running spinner / duration, and a chevron that opens the detail sheet.
struct ToolStatusView: View {
  let name: String
  let title: String
  let state: ChatRow.ToolState
  let durationS: Double?
  let hasDetail: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 10) {
        Image(systemName: state == .running ? "wrench.and.screwdriver" : "checkmark.seal")
          .foregroundStyle(state == .running ? Color.secondary : Color.green)
        VStack(alignment: .leading, spacing: 1) {
          Text(title.isEmpty ? name : title)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
          if !title.isEmpty, title != name {
            Text(name).font(.caption2.monospaced()).foregroundStyle(.secondary)
          }
        }
        if state == .running { ProgressView().controlSize(.mini) }
        if let durationS {
          Text(String(format: "%.1fs", durationS)).font(.caption).foregroundStyle(.secondary)
        }
        if hasDetail {
          Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
      }
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .disabled(!hasDetail)
  }
}
