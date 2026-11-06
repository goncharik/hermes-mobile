import ComposableArchitecture
import HermesKit
import SwiftUI

/// Settings → Diagnostics: a "Copy diagnostics" button (the plain-text `DiagnosticsReport` on
/// the pasteboard, with the shared copied toast) above the live gateway event log, in one
/// `List`.
struct DiagnosticsView: View {
  let store: StoreOf<DiagnosticsFeature>

  /// What the toast says here (and announces to VoiceOver).
  private static let copiedMessage = "Diagnostics copied"

  var body: some View {
    List {
      Section {
        Button {
          store.send(.copyTapped)
        } label: {
          Label("Copy diagnostics", systemImage: "doc.on.doc")
        }
      } footer: {
        Text("App and agent versions, your server address and sign-in method, plus recent gateway events, for a bug report. Events may include snippets of your messages and commands. Never includes your token, cookies or OAuth tokens.")
      }
      GatewayEventsSection(entries: store.log)
    }
    // On the list itself, nothing below it to swallow the toast (the transient-toast idiom).
    .overlay(alignment: .bottom) {
      CopiedToastView(token: store.copiedToken, message: Self.copiedMessage)
    }
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    // No `.onDisappear` cancel: popping the screen removes its stack element, and the stack
    // cancels that element's effects (an action sent after the pop would hit a missing one).
    .task { store.send(.task) }
  }
}

/// The live feed of decoded gateway events (newest last).
private struct GatewayEventsSection: View {
  let entries: [GatewayLogEntry]

  var body: some View {
    Section("Gateway events") {
      if entries.isEmpty {
        // A row, not a List overlay: an overlay would cover the copy button above it.
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
