import ComposableArchitecture
import HermesKit
import SwiftUI

/// Onboarding screen: type a server URL (validated automatically), pick an auth method
/// (Password / Token / OAuth, gated by the server's advertised capability), then connect.
struct ConnectionView: View {
  @Bindable var store: StoreOf<ConnectionFeature>
  @FocusState private var urlFocused: Bool
  /// Presents the "Set Up Your Agent" guide sheet. Pure view state (display-only) —
  /// deliberately kept out of `ConnectionFeature`, matching the context-pill precedent.
  @State private var showsSetupGuide = false

  var body: some View {
    Form {
      // Entry point (a): unmissable top row for first-timers — this screen's beta job is
      // half "log in", half "teach setup".
      Section {
        Button {
          showsSetupGuide = true
        } label: {
          Label("How to prepare your Hermes agent", systemImage: "info.circle")
        }
      }

      Section {
        TextField("http://host:9119", text: $store.serverURL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($urlFocused)
          .submitLabel(.go)
          .onSubmit { store.send(.serverFieldCommitted) }
          .onChange(of: urlFocused) { _, focused in
            if !focused { store.send(.serverFieldCommitted) } // check on focus-loss
          }
      } header: {
        Text("Server")
      } footer: {
        statusFooter
      }

      Section {
        Picker("Auth method", selection: $store.method) {
          // Password stays VISIBLE-but-inert on a token-only server — the whole control is
          // disabled below, which is the long-standing way to express "you may not pick
          // this" in a segmented picker. That trick can't be used once OAuth is on screen
          // (the control has to stay live so Token ↔ provider switching works), so there
          // the unavailable Password segment is omitted instead: a visible segment that
          // silently does nothing would be worse than an absent one.
          if store.isPasswordEnabled || !store.isOAuthEnabled {
            Text("Password")
              .tag(AuthMethod.password)
          }
          Text("Token")
            .tag(AuthMethod.token)
          if store.isOAuthEnabled {
            Text(oauthSegmentLabel)
              .tag(AuthMethod.oauth)
          }
        }
        .pickerStyle(.segmented)
        // Unchanged for every server WITHOUT OAuth (i.e. all of today's): a token-only
        // server locks the control so Password can't be selected. With OAuth available the
        // same lock would trap the user in whichever segment they landed on, so the
        // omitted-segment rule above covers Password there instead.
        .disabled(!store.isPasswordEnabled && store.method == .token && !store.isOAuthEnabled)

        switch store.method {
        case .password:
          TextField("Username", text: $store.username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Password", text: $store.password)
            .textContentType(.password)
        case .token:
          SecureField("Session token", text: $store.token)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          tokenDisclaimer
        case .oauth:
          oauthProviderButtons
        }

        // The provider button IS the connect action for the OAuth segment (there is nothing
        // to type first), so the generic Connect button would be a second submit path.
        if store.method != .oauth {
          Button("Connect") { store.send(.connectTapped) }
            .disabled(!store.canConnect)
        }
      } header: {
        Text("Sign in")
      } footer: {
        methodHint
      }
    }
    // Same readable-width cap the chat column uses (#80): a full-width form on an iPad in
    // landscape stretches every row edge to edge, leaving each label alone on one long line.
    // Phone widths are below the cap, so compact rendering is unchanged.
    .frame(maxWidth: ChatLayout.readableMaxWidth)
    .frame(maxWidth: .infinity)
    // Auto-validate a pre-filled server URL (after logout / a failed launch auto-connect)
    // so the user doesn't have to focus the field to unlock sign-in (#38).
    .onAppear { store.send(.onAppear) }
    .sheet(isPresented: $showsSetupGuide) {
      AgentSetupGuideView()
    }
  }

  /// Always-visible honesty note under the token field: what a token grants, where it's
  /// safe, and a button opening the setup guide sheet. Static copy + one button.
  @ViewBuilder
  private var tokenDisclaimer: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text("Never expires · private network only · full access")
      } icon: {
        Image(systemName: "exclamationmark.shield")
          .foregroundStyle(.orange)
      }
      .font(.footnote)

      // Entry point (c): opens the same guide sheet the top row does.
      Button {
        showsSetupGuide = true
      } label: {
        Text("Learn how to connect securely")
          .font(.footnote)
      }
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 2)
  }

  /// The OAuth segment's label: the provider's own display name when the server advertises
  /// exactly one (the common case — "Nous Research"), a neutral "OAuth" when several would
  /// not fit a segment. Server-supplied text only, never a brand asset (App Store 5.2.1).
  private var oauthSegmentLabel: String {
    let providers = store.oauthProviders
    return providers.count == 1 ? providers[0].displayName : "OAuth"
  }

  /// The OAuth segment's content: one plain-text button per advertised provider — PLAIN
  /// TEXT with the default tint, deliberately no logo, no brand colour and no imitation of
  /// a vendor's own sign-in button (App Store guideline 5.2.1) — plus a note about where
  /// the sign-in happens. Each button is the connect action for its provider; they disable
  /// together while `.validating` (the "Signing in…" status footer is the progress cue).
  @ViewBuilder
  private var oauthProviderButtons: some View {
    ForEach(store.oauthProviders, id: \.name) { provider in
      Button("Continue with \(provider.displayName)") {
        store.send(.oauthProviderTapped(provider))
      }
      .disabled(!store.canConnect)
    }

    Text("Opens your identity provider in Safari. Nothing is stored until sign-in completes.")
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.vertical, 2)
  }

  /// The server advertises OAuth providers but this gateway doesn't serve the native
  /// sign-in endpoints (`native_pkce` missing from `auth_flows`), so `isOAuthEnabled` hides
  /// the segment. The footer has to say why — otherwise the token-only hint below would
  /// claim the server "only supports token sign-in", which isn't true of the server, only
  /// of what this app can drive.
  private var hasUnsupportedOAuthProviders: Bool {
    guard let capability = store.capability else { return false }
    return !capability.oauthProviders.isEmpty && !capability.supportsNativeFlow
  }

  /// Display names of the providers this app can't drive, for the too-old-gateway hint.
  private var unsupportedOAuthProviderNames: String {
    (store.capability?.oauthProviders ?? []).map(\.displayName).joined(separator: " or ")
  }

  /// Capability-driven hint under the auth section.
  @ViewBuilder
  private var methodHint: some View {
    if store.method == .oauth {
      Text("Sign in with the same account you use on the Hermes dashboard.")
        .foregroundStyle(.secondary)
    } else if !store.isPasswordEnabled, hasUnsupportedOAuthProviders, store.method == .token {
      // Providers exist, but the gateway is too old for the native flow — so token really
      // is the only way in here, and the reason is actionable (update the agent).
      Text("\(unsupportedOAuthProviderNames) sign-in needs a newer Hermes agent. "
        + "Update it, or sign in with a session token.")
        .foregroundStyle(.secondary)
    } else if !store.isPasswordEnabled, store.method == .token, store.capability != nil {
      // Token-only server: Password is disabled — explain why.
      Text("This server only supports token sign-in.")
        .foregroundStyle(.secondary)
    } else if store.isTokenDeemphasized, store.method == .token {
      // Gated server: token is a poor fit — nudge toward password.
      Text("This server uses password login. Token sign-in is for private-network setups only.")
        .foregroundStyle(.secondary)
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var statusFooter: some View {
    switch store.status {
    case .idle:
      EmptyView()
    case .checking:
      Label("Checking…", systemImage: "ellipsis.circle")
    case .invalidURL:
      Label("Enter a valid server URL.", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
    case .unreachable:
      VStack(alignment: .leading, spacing: 6) {
        Label("Couldn’t reach the server.", systemImage: "xmark.octagon")
          .foregroundStyle(.red)
        setupHelpLink
      }
    case .notHermes:
      VStack(alignment: .leading, spacing: 6) {
        Label("Reachable, but doesn’t look like Hermes.", systemImage: "questionmark.diamond")
          .foregroundStyle(.orange)
        setupHelpLink
      }
    case let .reachable(version):
      Label("Reachable — Hermes \(version ?? "?")", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
    case .validating:
      Label("Signing in…", systemImage: "ellipsis.circle")
    case .invalidToken:
      Label("Invalid token.", systemImage: "xmark.octagon")
        .foregroundStyle(.red)
    case .invalidCredentials:
      Label("Invalid username or password.", systemImage: "xmark.octagon")
        .foregroundStyle(.red)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
    }
  }

  /// Entry point (b): contextual help for the stuck moment — only shown when the server
  /// can't be reached or doesn't look like Hermes (auth failures mean the user is past
  /// setup, so those statuses don't get it).
  private var setupHelpLink: some View {
    Button("Need help setting up your agent?") {
      showsSetupGuide = true
    }
    .buttonStyle(.borderless)
    .font(.footnote)
  }
}

#Preview {
  ConnectionView(
    store: Store(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    }
  )
}
