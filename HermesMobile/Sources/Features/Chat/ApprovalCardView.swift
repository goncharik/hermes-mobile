import HermesKit
import SwiftUI

/// Pinned card shown when the agent requests approval for an action. Approve/Deny,
/// with an "approve all" toggle for the rest of the session.
struct ApprovalCardView: View {
  let request: ApprovalRequest
  let onApprove: (_ all: Bool) -> Void
  let onDeny: () -> Void

  @State private var approveAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Approval requested", systemImage: "lock.shield")
        .font(.subheadline.weight(.semibold))

      if let detail = request.detail, !detail.isEmpty {
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let command = request.command, !command.isEmpty {
        Text(command)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 8))
      }

      Toggle("Approve all in this session", isOn: $approveAll)
        .font(.footnote)

      HStack(spacing: 12) {
        Button(role: .destructive, action: onDeny) {
          Text("Deny").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        Button { onApprove(approveAll) } label: {
          Text("Approve").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding()
    .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.5)))
    .padding(.horizontal)
  }
}
