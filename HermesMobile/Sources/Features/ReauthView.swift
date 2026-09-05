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
            // Nothing to type — the browser leg collects the credentials (#19). PLAIN TEXT
            // with the default tint, deliberately no logo, no brand colour and no imitation
            // of a vendor's own sign-in button (App Store guideline 5.2.1); the label is the
            // server-supplied display name, falling back to the wire provider name.
            Button("Continue with \(store.providerLabel)") { store.send(.signInTapped) }
              .disabled(!store.canSubmit)
          }

          // The provider button IS the submit action for the OAuth regime (there is nothing
          // to type first), so the generic "Sign in" button would be a second submit path.
          if store.method != .oauth {
            Button("Sign in") { store.send(.signInTapped) }
              .disabled(!store.canSubmit)
          }
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
      Label(invalidCredentialsMessage, systemImage: "xmark.octagon")
        .foregroundStyle(.red)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
    }
  }

  /// What a 401 means per regime. The OAuth wording deliberately blames neither a username
  /// nor a password: the identity was collected in the browser and the server refused the
  /// resulting token pair, so there is nothing for the user to retype here (#19).
  private var invalidCredentialsMessage: String {
    switch store.method {
    case .password: "Invalid username or password."
    case .token: "Invalid token."
    case .oauth: "Sign-in was rejected by the server."
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
