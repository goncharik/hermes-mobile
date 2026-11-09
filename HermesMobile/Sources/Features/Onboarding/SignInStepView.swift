import ComposableArchitecture
import HermesKit
import SwiftUI

/// Onboarding step 2 (#136): sign in the way THIS server asks. Thin over `SignInStep` — the
/// layout (password first / OAuth only / token) is `SignInStep.State.Layout`, derived from the
/// probed capability, so the view never decides which methods exist.
///
/// Provider buttons are PLAIN TEXT ("Continue with <display name>"): no logo, no brand colour
/// and no imitation of a vendor's own sign-in button (App Store guideline 5.2.1).
struct SignInStepView: View {
  @Bindable var store: StoreOf<SignInStep>

  var body: some View {
    Group {
      switch store.layout {
      case .oauthOnly:
        OnboardingScreen { content }
      case .password:
        OnboardingScreen { content } footer: {
          submitButton("Sign in", isEnabled: store.canSignInWithPassword) {
            store.send(.signInButtonTapped)
          }
        }
      case .token:
        OnboardingScreen { content } footer: {
          submitButton("Sign in", isEnabled: store.canSignInWithToken) {
            store.send(.tokenSignInButtonTapped)
          }
        }
      }
    }
    .navigationTitle("Step 2 of 2")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 20) {
      ServerCard(
        host: store.probe.address.host,
        summary: serverSummary,
        changeButtonTapped: { store.send(.changeServerButtonTapped) }
      )
      .padding(.top, 8)

      OnboardingHeading(title: "Sign in", subtitle: subtitle)

      if case let .failed(message) = store.status {
        OnboardingNotice(systemImage: "exclamationmark.triangle.fill", tint: .red, warningTint: .red) {
          Text(verbatim: message)
        }
      }

      switch store.layout {
      case let .password(providers):
        passwordLayout(providers: providers)
      case let .oauthOnly(providers):
        providerButtons(providers, prominent: true)
        otherWays
      case let .token(reason):
        tokenLayout(reason: reason)
      }
    }
  }

  private var serverSummary: String {
    [store.probe.version.map { "Hermes \($0)" }, store.methodSummary]
      .compactMap(\.self)
      .joined(separator: " · ")
  }

  private var subtitle: String {
    switch store.layout {
    case .password:
      "Use the username and password set in ~/.hermes/.env on your agent."
    case .oauthOnly:
      "This agent uses your \(store.oauthProviderNames) account."
    case .token:
      """
      This agent signs in with a session token. It’s the value of \
      HERMES_DASHBOARD_SESSION_TOKEN on the computer running Hermes.
      """
    }
  }

  // MARK: - Layouts

  @ViewBuilder
  private func passwordLayout(providers: [AuthProvider]) -> some View {
    cleartextWarning(credential: "password")
    if let names = store.oauthNeedsNewerAgentFor {
      OnboardingNotice {
        Text(verbatim: """
        \(names) sign-in needs a newer Hermes agent. Update the agent to use it, or sign in \
        with your password.
        """)
      }
    }
    VStack(alignment: .leading, spacing: 8) {
      fieldGroup {
        TextField("Username", text: $store.username)
          .textContentType(.username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .padding(.horizontal, 14)
          .padding(.vertical, 13)
        Divider()
          .padding(.leading, 14)
        RevealableSecureField("Password", text: $store.password, textContentType: .password)
          .padding(.horizontal, 14)
          .padding(.vertical, 13)
      }
      if store.status == .invalidCredentials, store.selectedOAuthProviderName == nil {
        errorLine("""
        That username and password didn’t work. They’re set by \
        `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` and `_PASSWORD` in `~/.hermes/.env`.
        """)
      }
    }
    if !providers.isEmpty {
      OnboardingLabeledDivider(label: "or")
      providerButtons(providers, prominent: false)
    }
    otherWays
  }

  @ViewBuilder
  private func tokenLayout(reason: SignInStep.State.TokenReason) -> some View {
    cleartextWarning(credential: "token")
    if case let .oauthNeedsNewerAgent(names) = reason {
      OnboardingNotice {
        Text(verbatim: """
        \(names) sign-in needs a newer Hermes agent. Update the agent to use it, or sign in \
        with a session token.
        """)
      }
    }
    VStack(alignment: .leading, spacing: 8) {
      tokenField
      warningLine("A token never expires and gives full access. Use it only on a private network.")
      invalidTokenLine
    }
    if reason == .tokenOnlyServer {
      OnboardingNotice {
        Text("""
        Newer Hermes agents support password sign-in, which is safer. Update the agent to \
        switch.
        """)
      }
    }
  }

  /// The token field behind "Other ways to sign in" under the two non-token layouts.
  @ViewBuilder
  private var otherWays: some View {
    if store.isShowingOtherWays {
      OnboardingLabeledDivider(label: "session token")
      VStack(alignment: .leading, spacing: 8) {
        tokenField
        warningLine("For private-network setups only. A token never expires and gives full access.")
        invalidTokenLine
        Button {
          store.send(.tokenSignInButtonTapped)
        } label: {
          Text("Sign in with token")
            .frame(maxWidth: .infinity)
        }
        .onboardingTonalButton()
        .controlSize(.large)
        .disabled(!store.canSignInWithToken)
        .padding(.top, 4)
      }
    } else {
      Button("Other ways to sign in") {
        store.send(.otherWaysButtonTapped)
      }
      .onboardingPlainButton()
      .frame(maxWidth: .infinity)
    }
  }

  // MARK: - Building blocks

  private func providerButtons(_ providers: [AuthProvider], prominent: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(providers, id: \.name) { provider in
        let button = Button {
          store.send(.oauthProviderButtonTapped(provider))
        } label: {
          Text(verbatim: "Continue with \(provider.displayName)")
            .frame(maxWidth: .infinity)
        }
        .disabled(!store.canSignInWithOAuth)
        if prominent {
          button.onboardingPrimaryButton()
        } else {
          button.onboardingTonalButton().controlSize(.large)
        }
      }
      Text(verbatim: """
      Opens \(providers.first?.displayName ?? "your identity provider") in a secure browser. \
      Nothing is saved until sign-in completes.
      """)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if store.status == .invalidCredentials, store.selectedOAuthProviderName != nil {
        errorLine(
          store.state.layout == .oauthOnly(providers)
            ? "The agent rejected that sign-in. Try again."
            : "The agent rejected that sign-in. Try again, or use your password."
        )
      }
    }
  }

  private var tokenField: some View {
    fieldGroup {
      RevealableSecureField("Session token", text: $store.token)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
  }

  @ViewBuilder
  private var invalidTokenLine: some View {
    if store.status == .invalidToken {
      errorLine("""
      The agent didn’t accept that token. Check it matches `HERMES_DASHBOARD_SESSION_TOKEN`, \
      then try again.
      """)
    }
  }

  /// Plain http to a public host: whatever is typed here crosses the internet unencrypted.
  @ViewBuilder
  private func cleartextWarning(credential: String) -> some View {
    if store.probe.address.isPublicCleartext {
      OnboardingNotice(
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange,
        warningTint: .orange
      ) {
        Text("""
        **This connection isn’t encrypted.** \(store.probe.address.host) looks like a public \
        address, so your \(credential) would cross the internet in plain text. Use Tailscale \
        or an https:// address.
        """)
      }
    }
  }

  private func fieldGroup(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(spacing: 0) {
      content()
    }
    .background(
      Color(.secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(hasFieldError ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
    }
  }

  private var hasFieldError: Bool {
    switch store.status {
    case .invalidToken: true
    case .invalidCredentials: store.selectedOAuthProviderName == nil
    case .failed, .idle, .validating: false
    }
  }

  /// A red verdict line under the fields it is about. Static copy with inline `code`.
  private func errorLine(_ text: LocalizedStringKey) -> some View {
    Label {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "xmark.octagon.fill")
    }
    .font(.footnote)
    .foregroundStyle(.red)
  }

  private func warningLine(_ text: String) -> some View {
    Label {
      Text(verbatim: text)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.shield")
        .foregroundStyle(.orange)
    }
    .font(.footnote)
  }

  private func submitButton(
    _ title: String,
    isEnabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(isValidatingHere ? "Signing in…" : title)
        .frame(maxWidth: .infinity)
    }
    .onboardingPrimaryButton()
    .disabled(!isEnabled)
  }

  /// A non-OAuth attempt is in flight (the OAuth leg shows in the browser sheet instead).
  private var isValidatingHere: Bool {
    store.status == .validating && store.selectedOAuthProviderName == nil
  }
}

/// The server Sign in is for: host, version and how it signs in, with "Change" to go back to
/// the Server step (`SignInStep.changeServerButtonTapped` → pop).
struct ServerCard: View {
  let host: String
  let summary: String
  let changeButtonTapped: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "server.rack")
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 38, height: 38)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
          Circle()
            .fill(.green)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2))
            .offset(x: 2, y: 2)
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: host)
          .font(.headline)
          .lineLimit(2)
          .truncationMode(.middle)
        Text(verbatim: summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Agent \(host), \(summary)")
      Spacer(minLength: 8)
      Button("Change", action: changeButtonTapped)
        .buttonStyle(.borderless)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(OnboardingLayout.accentInk)
        .accessibilityHint("Goes back to the agent address")
    }
    .padding(.vertical, 12)
    .padding(.leading, 14)
    .padding(.trailing, 12)
    .background(
      Color(.secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: OnboardingLayout.cardCornerRadius, style: .continuous)
    )
  }
}

#Preview {
  NavigationStack {
    SignInStepView(
      store: Store(
        initialState: SignInStep.State(
          probe: ServerProbe(
            address: ServerAddress("mac-mini.tail4c2e.ts.net")!,
            baseURL: URL(string: "http://mac-mini.tail4c2e.ts.net:9119")!,
            capability: ServerAuthCapability(
              passwordProvider: AuthProvider(name: "basic", displayName: "Password", supportsPassword: true),
              isGated: true
            ),
            version: "0.19.2"
          )
        )
      ) {
        SignInStep()
      }
    )
  }
}
