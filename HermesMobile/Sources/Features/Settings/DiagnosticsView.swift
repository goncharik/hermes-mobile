import ComposableArchitecture
import HermesKit
import SwiftUI

/// Settings → Diagnostics: a "Copy diagnostics" button (the plain-text `DiagnosticsReport` on
/// the pasteboard, with the shared copied toast) above the live gateway event log.
struct DiagnosticsView: View {
  let store: StoreOf<DiagnosticsFeature>

  /// What the toast says here (and announces to VoiceOver).
  private static let copiedMessage = "Diagnostics copied"

  var body: some View {
    ConnectionDebugView(entries: store.log) {
      Section {
        Button {
          store.send(.copyTapped)
        } label: {
          Label("Copy diagnostics", systemImage: "doc.on.doc")
        }
      } footer: {
        Text("App, server and agent versions plus recent gateway events, for a bug report. Never includes your token or sign-in cookies.")
      }
    }
    // On the list itself, nothing below it to swallow the toast (the transient-toast idiom).
    .overlay(alignment: .bottom) {
      CopiedToastView(token: store.copiedToken, message: Self.copiedMessage)
    }
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .task { store.send(.task) }
    // Explicit cancel of the log subscription (the auto-poll idiom), not bare `.task` teardown.
    .onDisappear { store.send(.onDisappear) }
  }
}
