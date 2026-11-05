import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit

/// Settings sheet: one `Form` in six groups (Server, App, Notifications, Feedback, About,
/// Sign out). Three rows push sub-screens through the reducer-owned `path` — the view owns
/// the `NavigationStack`, so the presenting sheet must not wrap it in another one.
struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  /// Presentation-only: the "how push works / install the plugin" info sheet. Pure view
  /// state — there's no reducer behavior behind it.
  @State private var showingPushGuide = false

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      form
    } destination: { pathStore in
      switch pathStore.case {
      case let .appIcon(store):
        AppIconPickerView(store: store)
      case let .diagnostics(store):
        DiagnosticsView(store: store)
      case .acknowledgements:
        AcknowledgementsView()
      }
    }
    .sheet(isPresented: $showingPushGuide) {
      PushSetupGuideView(
        // Installed → the sheet drops the "Later" snooze and asks the agent to UPDATE rather
        // than install. It is never purely informational: an installed-but-outdated plugin is
        // exactly the case that needs an action here.
        pluginInstalled: store.pushAvailable,
        onAskAgent: {
          showingPushGuide = false
          store.send(.askAgentToInstallTapped)
        },
        onLater: { showingPushGuide = false }
      )
    }
    // On the stack, not the Form: the root's `.task` would re-fire on every pop back from a
    // sub-screen and re-probe the agent.
    .task { store.send(.task) }
  }

  private var form: some View {
    Form {
      serverSection
      appSection
      notificationsSection
      feedbackSection
      aboutSection
      signOutSection
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { store.send(.doneTapped) }
      }
    }
  }

  // MARK: Server

  private var serverSection: some View {
    Section {
      LabeledContent("URL", value: store.serverURLString)
      LabeledContent("Auth", value: store.authLabel)
      if let profileName = store.profileName {
        LabeledContent("Profile", value: profileName)
      }
      if let agentVersion = store.agentVersion {
        LabeledContent("Agent", value: agentVersion)
      }
      // Only the token regime has a credential the user can re-paste; a password / OAuth
      // session re-authenticates through sign-in instead.
      if store.showsTokenField {
        SecureField("Session token", text: $store.token)
          .textContentType(.password)
        Button("Save token") { store.send(.saveTokenTapped) }
          .disabled(!store.canSaveToken)
        if store.savedConfirmation {
          Label("Token saved", systemImage: "checkmark.circle")
            .foregroundStyle(.green).font(.footnote)
        }
      }
      Button("Reconnect") { store.send(.reconnectTapped) }
    } header: {
      Text("Server")
    } footer: {
      if store.showsTokenField {
        Text("Re-paste the stable token if it changed on the server.")
      }
    }
  }

  // MARK: App

  private var appSection: some View {
    Section("App") {
      SettingsNavigationRow(
        title: "App Icon",
        value: store.selectedAppIconLabel,
        thumbnail: store.selectedAppIconOption?.previewAsset
      ) {
        store.send(.appIconRowTapped)
      }
      // Only offered when the agent supports session deletion — otherwise Archive is the
      // only destructive action and the choice would be meaningless.
      if store.deleteSupported {
        Picker(
          "Default swipe action",
          selection: Binding(
            get: { store.defaultSwipeAction },
            set: { store.send(.defaultSwipeActionChanged($0)) }
          )
        ) {
          Text("Archive").tag(SessionSwipeAction.archive)
          Text("Delete").tag(SessionSwipeAction.delete)
        }
      }
    }
  }

  // MARK: Notifications

  private var notificationsSection: some View {
    Section {
      // Plugin update, offered above the toggle because an out-of-date plugin sends pushes
      // the user is actively complaining about. Shown whether or not push is currently
      // available — an installed-but-disabled plugin is still worth updating.
      if store.pluginUpdateAvailable {
        VStack(alignment: .leading, spacing: 4) {
          Label("Plugin update available", systemImage: "arrow.down.circle")
            .font(.subheadline.weight(.semibold))
          Text(pluginUpdateExplanation)
            .font(.footnote).foregroundStyle(.secondary)
        }
        Button("Update plugin") { store.send(.updatePluginTapped) }
          .disabled(store.pluginUpdate == .updating)
      } else if store.pluginUpdateNeedsManualSteps {
        // Out of date but the agent can't pull it (pip install / hand-copied directory), so
        // a button here would only 400. Route to the guide, which offers the chat prompt.
        VStack(alignment: .leading, spacing: 4) {
          Label("Plugin update available", systemImage: "arrow.down.circle")
            .font(.subheadline.weight(.semibold))
          Text("\(pluginUpdateExplanation) This copy can't be updated from the app — ask your agent to update it.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Button("How to update the plugin") { showingPushGuide = true }
          .font(.footnote)
      }
      switch store.pluginUpdate {
      case .idle:
        EmptyView()
      case .updating:
        Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
          .foregroundStyle(.secondary).font(.footnote)
      case .updated:
        // A pull only changes files on disk — the running agent keeps the old code loaded.
        // This restart notice is the whole point of the success state; don't soften it.
        Label(
          "Plugin updated. Restart your Hermes agent to apply it.",
          systemImage: "exclamationmark.arrow.triangle.2.circlepath"
        )
        .foregroundStyle(.orange).font(.footnote)
      case .alreadyCurrent:
        Label("Plugin is already up to date", systemImage: "checkmark.circle")
          .foregroundStyle(.green).font(.footnote)
      case let .failed(reason):
        Label(reason, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange).font(.footnote)
      }

      if store.pushAvailable {
        Toggle(
          "Notify me about approvals",
          isOn: Binding(
            get: { store.notificationsEnabled },
            set: { store.send(.notificationsToggled($0)) }
          )
        )
        if store.notificationsDenied {
          VStack(alignment: .leading, spacing: 4) {
            Label("Notifications are turned off", systemImage: "bell.slash")
              .foregroundStyle(.orange).font(.footnote)
            if let url = URL(string: UIApplication.openSettingsURLString) {
              Link("Enable in iOS Settings", destination: url)
                .font(.footnote)
            }
          }
        }
        Button("Send test notification") { store.send(.sendTestPushTapped) }
          .disabled(store.testPushStatus == .sending)
        switch store.testPushStatus {
        case .idle:
          EmptyView()
        case .sending:
          Label("Sending…", systemImage: "paperplane")
            .foregroundStyle(.secondary).font(.footnote)
        case .sent:
          Label("Test notification sent", systemImage: "checkmark.circle")
            .foregroundStyle(.green).font(.footnote)
        case .failed:
          Label("Couldn't send test notification", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange).font(.footnote)
        }
        Button("How push notifications work") { showingPushGuide = true }
          .font(.footnote)
      } else {
        Label("Notifications aren't available on this server", systemImage: "bell.slash")
          .foregroundStyle(.secondary).font(.footnote)
        Button("How to enable push notifications") { showingPushGuide = true }
      }
    } header: {
      Text("Notifications")
    } footer: {
      if store.pushAvailable {
        Text("Get a push when Hermes needs your approval, even while the app is closed.")
      } else {
        Text("Needs the hermes-push plugin running on your agent.")
      }
    }
  }

  // MARK: Feedback

  private var feedbackSection: some View {
    Section("Feedback") {
      ExternalLinkRow(title: "Report a bug", destination: store.reportBugURL)
      ExternalLinkRow(title: "Request a feature", destination: store.requestFeatureURL)
      // Hidden until the app is live on the App Store (`AppStoreIdentity.appID`).
      if let rateApp = FeedbackLinks.rateApp {
        ExternalLinkRow(title: "Rate Hermes Mobile", destination: rateApp)
      }
      ExternalLinkRow(title: "All issues on GitHub", destination: FeedbackLinks.allIssues)
    }
  }

  // MARK: About

  private var aboutSection: some View {
    Section("About") {
      if let versionLabel = store.versionLabel {
        Text(versionLabel)
      }
      ExternalLinkRow(title: "GitHub repository", destination: FeedbackLinks.repository)
      ExternalLinkRow(title: "Hermes Agent", destination: FeedbackLinks.hermesAgent)
      ExternalLinkRow(title: "Privacy policy", destination: FeedbackLinks.privacyPolicy)
      SettingsNavigationRow(title: "Acknowledgements") {
        store.send(.acknowledgementsRowTapped)
      }
      SettingsNavigationRow(title: "Diagnostics") {
        store.send(.diagnosticsRowTapped)
      }
    }
  }

  // MARK: Sign out

  private var signOutSection: some View {
    Section {
      Button("Sign out", role: .destructive) {
        store.send(.clearTokenTapped)
      }
    } footer: {
      Text("Removes this server's credentials and cached chats from this device and returns to the connection screen.")
    }
  }

  /// Why the update matters, naming both versions when the agent reported one. Kept in the
  /// view because it is pure display copy — the decision to show it lives in the reducer.
  private var pluginUpdateExplanation: String {
    let latest = PushSetup.minimumPluginVersion
    let reason = "Older versions send a “Turn complete” push each time a delegated subagent finishes."
    guard let installed = store.pushPlugin?.version else {
      return "Update to \(latest). \(reason)"
    }
    return "Installed \(installed), latest \(latest). \(reason)"
  }
}
