import ComposableArchitecture
import HermesKit
import SwiftUI

/// Re-authentication sheet raised when a live (gated) session dies mid-use. The server URL
/// is fixed and the username is prefilled — the user just re-enters their password (or a
/// fresh token in token-mode) to resume. "Quit to start" performs a full logout.
struct ReauthView: View {
  @Bindable var store: StoreOf<ReauthFeature>

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Server", value: store.serverURL.absoluteString)
            .foregroundStyle(.secondary)
        } footer: {
          Text("Your session expired. Sign in again to continue.")
        }

        Section {
          switch store.method {
          case .password:
            TextField("Username", text: $store.username)
              .textContentType(.username)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            SecureField("Password", text: $store.password)
              .textContentType(.password)
              .submitLabel(.go)
              .onSubmit { if store.canSubmit { store.send(.signInTapped) } }
          case .token:
            SecureField("Session token", text: $store.token)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.go)
              .onSubmit { if store.canSubmit { store.send(.signInTapped) } }
          case .oauth:
            // Placeholder so the switch stays exhaustive now that `AuthMethod` has a third
            // case (#19). UNREACHABLE today: `AppFeature.makeReauthState` never builds an
            // `.oauth` state, and `ReauthFeature`'s own `.oauth` branches are stubs. The
            // real single-button variant lands with the reducer work.
            EmptyView()
          }

          Button("Sign in") { store.send(.signInTapped) }
            .disabled(!store.canSubmit)
        } header: {
          Text("Sign in")
        } footer: {
          statusFooter
        }

        Section {
          Button("Quit to start", role: .destructive) { store.send(.quitTapped) }
        } footer: {
          Text("Signs out completely and returns to the connection screen.")
        }
      }
      .navigationTitle("Session expired")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled()
    }
  }

  @ViewBuilder
  private var statusFooter: some View {
    switch store.status {
    case .idle:
      EmptyView()
    case .validating:
      Label("Signing in…", systemImage: "ellipsis.circle")
    case .invalidCredentials:
      Label(
        store.method == .token ? "Invalid token." : "Invalid username or password.",
        systemImage: "xmark.octagon"
      )
      .foregroundStyle(.red)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
    }
  }
}

#Preview {
  ReauthView(
    store: Store(
      initialState: ReauthFeature.State(
        serverURL: URL(string: "http://mac.tailnet:9119")!,
        method: .password,
        previousUsername: "alice"
      )
    ) {
      ReauthFeature()
    }
  )
}
