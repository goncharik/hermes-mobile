import ComposableArchitecture
import HermesKit
import SwiftUI

/// Settings sheet: server info, token re-paste/clear, manual reconnect, and a link to
/// the live connection debug log.
struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section("Server") {
        LabeledContent("URL", value: store.serverURLString)
      }

      Section {
        SecureField("Session token", text: $store.token)
          .textContentType(.password)
        Button("Save token") { store.send(.saveTokenTapped) }
          .disabled(!store.canSaveToken)
        if store.savedConfirmation {
          Label("Token saved", systemImage: "checkmark.circle")
            .foregroundStyle(.green).font(.footnote)
        }
      } header: {
        Text("Token")
      } footer: {
        Text("Re-paste the stable token if it changed on the server.")
      }

      Section("Connection") {
        Button("Reconnect") { store.send(.reconnectTapped) }
        NavigationLink {
          ConnectionDebugView(entries: store.log)
        } label: {
          LabeledContent("Debug log", value: "\(store.log.count)")
        }
      }

      Section {
        Picker("Chat transcript engine", selection: $store.chatRenderer) {
          ForEach(ChatRendererKind.allCases, id: \.self) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
      } header: {
        Text("Experimental")
      } footer: {
        Text("Switches the chat transcript rendering engine. Experimental — reopen a chat to compare.")
      }

      Section {
        Button("Clear token & disconnect", role: .destructive) {
          store.send(.clearTokenTapped)
        }
      } footer: {
        Text("Removes the token from the Keychain and returns to the connection screen.")
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { store.send(.doneTapped) }
      }
    }
    .task { store.send(.task) }
  }
}
