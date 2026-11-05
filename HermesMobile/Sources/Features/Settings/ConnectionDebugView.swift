import HermesKit
import SwiftUI

/// A live feed of decoded gateway events (newest last) for connection debugging. Embedded by
/// `DiagnosticsView`, which supplies the leading `header` rows (the copy button) and the
/// navigation title.
struct ConnectionDebugView<Header: View>: View {
  let entries: [GatewayLogEntry]
  @ViewBuilder var header: Header

  var body: some View {
    List {
      header
      Section("Gateway events") {
        if entries.isEmpty {
          // A row, not a List overlay: an overlay would cover the header rows above it.
          ContentUnavailableView(
            "No events yet",
            systemImage: "dot.radiowaves.left.and.right",
            description: Text("Open a chat to see gateway events stream in.")
          )
        }
        ForEach(entries) { entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.type)
              .font(.caption.monospaced().weight(.semibold))
              .foregroundStyle(.tint)
            if !entry.summary.isEmpty {
              Text(entry.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
          }
        }
      }
    }
  }
}
