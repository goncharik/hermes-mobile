import HermesKit
import SwiftUI

/// Presentation-only info sheet explaining how push notifications work and offering to ask
/// the agent to install — or update — the `hermes-push` plugin (pre-fills a new chat). A small
/// text link opens the plugin's GitHub page.
///
/// It deliberately talks about the **plugin only** — the relay/gateway is publisher infra
/// the user never has to know about. The actions are surfaced as closures; Settings is the
/// only call site (the session list shows an inline `PushCardView` instead of auto-presenting
/// this sheet).
struct PushSetupGuideView: View {
  @Environment(\.dismiss) private var dismiss

  /// Whether the plugin is already installed and enabled on the agent. It switches the action
  /// from install to UPDATE.
  ///
  /// The action is deliberately NOT hidden in this case: `PushSetup.installPrompt` covers
  /// install-or-update, and an installed-but-outdated plugin is precisely the situation where
  /// the user opens this sheet looking for something to do. Hiding it here left the only
  /// people who needed an update with no way to ask for one.
  let pluginInstalled: Bool
  /// Open a new chat with the install/update prompt pre-filled (the caller dismisses + routes).
  let onAskAgent: () -> Void

  private static let pluginURL = URL(string: PushSetup.pluginURLString)!

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          header

          point(
            "How it works",
            icon: "bell.badge",
            text: "Hermes can ping you when your agent needs you — like an approval request — even while the app is closed."
          )

          point(
            "It runs on your own agent",
            icon: "lock.shield",
            text: "Notifications come from a small plugin on your own Hermes agent, relayed to Apple. Only a generic alert (e.g. “Approval needed”) leaves your server — your messages and data never do."
          )

          Button {
            onAskAgent()
          } label: {
            Label(
              pluginInstalled ? "Ask agent to update plugin" : "Ask agent to install plugin",
              systemImage: "sparkles"
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .padding(.top, 4)

          Link("View the plugin on GitHub", destination: Self.pluginURL)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle("Push notifications")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "bell.badge.fill")
        .font(.largeTitle)
        .foregroundStyle(.tint)
      Text("Get pinged when your agent needs you.")
        .font(.title3.weight(.semibold))
    }
  }

  private func point(_ title: String, icon: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon).font(.headline)
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }
}

#Preview("Not installed") {
  PushSetupGuideView(pluginInstalled: false, onAskAgent: {})
}

#Preview("Installed") {
  PushSetupGuideView(pluginInstalled: true, onAskAgent: {})
}
