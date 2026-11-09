import SwiftUI
import UIKit

/// Sheet-presented onboarding guide teaching the blessed remote-access recipe for a Hermes
/// Agent: **password ("basic") auth over Tailscale/LAN**, with `--insecure` + token demoted
/// to a collapsed last-resort advanced section. Presented from the onboarding flow (Welcome,
/// the Server step and its failure cards share one local `@State` flag in `ConnectionView`)
/// and from `ConnectionFailedView` — a reference card you consult and dismiss, not a
/// navigation destination.
///
/// Two tabs on a segmented control: **On my computer** (the self-hosted recipe below) and
/// **Hermes Cloud** (desktop's terms — open the agent in the Nous portal, paste its
/// address). The Cloud copy is kept verbatim with the README quick-start.
///
/// Scope: static copy, copy affordances on the commands, and external `Link`s. No
/// network detection, no reducer involvement — the selected tab is view-local `@State`.
/// The card stack is the visual language carried over from the old
/// `SecureConnectionInfoView` (which this guide replaces).
struct AgentSetupGuideView: View {
  enum Tab: Hashable {
    case cloud
    case computer
  }

  @Environment(\.dismiss) private var dismiss

  /// Whether the "Advanced: token mode" disclosure starts open. Defaults to collapsed;
  /// seeded only so snapshot tests can capture the expanded variant.
  @State private var advancedExpanded: Bool
  /// The selected tab. Defaults to "On my computer"; seeded only so snapshot tests can
  /// capture the Hermes Cloud tab.
  @State private var tab: Tab

  init(advancedExpanded: Bool = false, tab: Tab = .computer) {
    _advancedExpanded = State(initialValue: advancedExpanded)
    _tab = State(initialValue: tab)
  }

  /// Desktop's `FALLBACK_PORTAL_URL` — where Hermes Cloud agents are created and opened.
  private static let portalURL = URL(string: "https://portal.nousresearch.com")!
  private static let tailscaleURL = URL(string: "https://tailscale.com")!
  private static let docsURL = URL(
    string: "https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard"
  )!

  private static let brand = LinearGradient(
    colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing
  )
  private static let tailscaleBrand = LinearGradient(
    colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing
  )

  // NOTE: this must be a command RUN IN A SHELL, not text pasted into `.env` — Hermes
  // parses `.env` itself with no shell evaluation, so a pasted `$(openssl …)` would
  // become a literal (and publicly known) signing secret. The QUOTED heredoc delimiter
  // (<<'EOF') keeps the user-edited credentials literal — a password containing `$`,
  // backticks, or backslashes must not be shell-expanded — while the separate
  // double-quoted `echo` line still expands `$(openssl …)` into a real random secret
  // at paste time.
  private static let envCommand = """
  cat >> ~/.hermes/.env <<'EOF'
  HERMES_DASHBOARD_BASIC_AUTH_USERNAME=you
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=…
  EOF
  echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32)" >> ~/.hermes/.env
  """
  private static let dashboardCommand = "hermes dashboard --host 0.0.0.0 --port 9119 --no-open"
  private static let verifyCommand = "curl http://<host>:9119/api/status"
  private static let insecureCommand = "hermes dashboard --host 0.0.0.0 --insecure"
  // Generated in-shell — unlike the `.env` file, this export DOES run in a shell, so
  // `$(openssl …)` expands to a real random token at paste time (no literal `…`
  // placeholder to forget). Hex, not base64: the token rides the `?token=` WS query,
  // where base64's `+` is a footgun. The `echo` prints the token so the user can
  // paste it into the app.
  private static let tokenExportCommand = """
  export HERMES_DASHBOARD_SESSION_TOKEN=$(openssl rand -hex 32)
  echo "$HERMES_DASHBOARD_SESSION_TOKEN"
  """

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("Where the agent runs", selection: $tab) {
          Text("On my computer").tag(Tab.computer)
          Text("Hermes Cloud").tag(Tab.cloud)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        ScrollView {
          VStack(spacing: 20) {
            switch tab {
            case .cloud:
              cloudCard
              portalLink
            case .computer:
              hero
              loginCard
              dashboardCard
              reachCard
              tailscaleLink
              portForwardWarning
              verifyCard
              advancedCard
              docsLink
            }
          }
          .padding(20)
          .frame(maxWidth: .infinity)
        }
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Set Up Your Agent")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
  }

  // MARK: - Hermes Cloud

  // Copy kept verbatim with the README quick-start's Hermes Cloud line.
  private var cloudCard: some View {
    card {
      cardHeader(icon: "cloud.fill", title: "Hermes Cloud runs your agent for you.", tint: .blue)
      Text("""
      Open your agent in the Nous portal, copy its address, and paste it into Hermes Mobile's \
      agent address field. You'll sign in with your Nous Research account.
      """)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      footnote("No agent yet? Create one in the Nous portal.")
    }
  }

  private var portalLink: some View {
    externalLinkRow(
      url: Self.portalURL,
      icon: "cloud.fill",
      fill: Self.brand,
      title: "Open the Nous portal",
      subtitle: "portal.nousresearch.com"
    )
  }

  // MARK: - On my computer

  private var hero: some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(Self.brand)
          .frame(width: 76, height: 76)
          .shadow(color: .blue.opacity(0.3), radius: 12, y: 6)
        Image(systemName: "desktopcomputer.and.arrow.down")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(.white)
      }
      VStack(spacing: 6) {
        Text("Connect to your own agent")
          .font(.title2.weight(.bold))
          .multilineTextAlignment(.center)
        Text("""
        Hermes Mobile connects to a Hermes Agent running on your computer. Three things to \
        set up: your login, the dashboard, and network access.
        """)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }
    }
    .padding(.top, 8)
    .padding(.horizontal, 4)
  }

  private var loginCard: some View {
    card {
      cardHeader(icon: "person.badge.key.fill", title: "Create your login", tint: .blue)
      stepRow(number: 1, text: """
      On the computer running Hermes, run this in a terminal to add your credentials to \
      ~/.hermes/.env (edit the username and password first):
      """)
      CommandCard(command: Self.envCommand, showsPrompt: false)
      footnote("The secret is generated for you — it keeps you signed in across agent restarts.")
      // Honest about the agent-side parser: Hermes loads `.env` with python-dotenv,
      // which interpolates `${…}`, strips a `#` comment after whitespace, and peels
      // surrounding quotes — an absolute "kept exactly as typed" would overclaim.
      footnote("""
      Most special characters are fine in the password — but the agent's .env parser \
      treats a few specially: avoid ${…}, quotes around the whole value, and # after a space.
      """)
    }
  }

  private var dashboardCard: some View {
    card {
      cardHeader(icon: "terminal.fill", title: "Start the dashboard", tint: .green)
      stepRow(number: 2, text: "Launch the dashboard so other devices can reach it:")
      CommandCard(command: Self.dashboardCommand)
      footnote("""
      Password login switches on automatically when the dashboard is reachable beyond the \
      machine itself.
      """)
    }
  }

  private var reachCard: some View {
    card {
      cardHeader(icon: "iphone.radiowaves.left.and.right", title: "Reach it from your phone", tint: .indigo)
      stepRow(number: 3, text: """
      Put your phone on the same private network as the agent. Tailscale is the recommended \
      way — it gives every device a private address only your own devices can reach.
      """)
      footnote("On the same Wi-Fi, your Mac's local IP works for a quick try.")
    }
  }

  private var tailscaleLink: some View {
    externalLinkRow(
      url: Self.tailscaleURL,
      icon: "network",
      fill: Self.tailscaleBrand,
      title: "Set up Tailscale",
      subtitle: "Private addresses reachable only by your tailnet"
    )
  }

  private var portForwardWarning: some View {
    calloutCard(
      tint: .orange,
      icon: "exclamationmark.shield.fill",
      title: "Keep it off the open internet",
      message: """
      Never port-forward the dashboard to the open internet. Password login is meant for \
      trusted networks and VPNs only.
      """
    )
  }

  private var verifyCard: some View {
    card {
      cardHeader(icon: "checkmark.circle.fill", title: "Check it works", tint: .teal)
      stepRow(number: 4, text: """
      From another device on the same network as your phone, confirm the agent answers (or \
      open the URL in your phone's browser):
      """)
      CommandCard(command: Self.verifyCommand)
      footnote("You should see auth_required: true.")
      footnote("Then enter the address and sign in with your username and password.")
    }
  }

  private var advancedCard: some View {
    card {
      DisclosureGroup(isExpanded: $advancedExpanded) {
        VStack(alignment: .leading, spacing: 12) {
          Text("""
          A session token is a master key to your agent: anyone holding it can act as you — \
          indefinitely. Use it only as a last resort, on a network where every device is one \
          you've explicitly added.
          """)
          .fixedSize(horizontal: false, vertical: true)
          // The dashboard reads the token once at launch — export must come first.
          stepRow(number: 1, text: """
          Generate the shared token the dashboard and this app will use — the echo line \
          prints it so you can paste it into the token field when you sign in (under "Other \
          ways to sign in" when the agent also offers a password):
          """)
          CommandCard(command: Self.tokenExportCommand, showsPrompt: false)
          stepRow(number: 2, text: """
          Then, in the same shell, bind the agent beyond loopback with auth disabled — only \
          inside a network you control:
          """)
          CommandCard(command: Self.insecureCommand)
          // Upstream June-2026 hardening: `--insecure` is accepted but IGNORED on a
          // non-loopback bind (auth always required; no provider → fail closed). The
          // recipe still works on the 0.16.0-era agents beta users run, so hedge —
          // don't delete.
          (Text("Recent Hermes releases ignore ")
            + Text("--insecure").font(.system(.subheadline, design: .monospaced)).foregroundStyle(.primary)
            + Text("""
             and always require a login beyond the machine itself — if the dashboard \
            refuses to start or still asks you to sign in, use the password setup above.
            """))
            .fixedSize(horizontal: false, vertical: true)
          (Text("Never expose ")
            + Text("--insecure").font(.system(.subheadline, design: .monospaced)).foregroundStyle(.primary)
            + Text(" to the public internet."))
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.top, 12)
      } label: {
        cardHeader(icon: "key.fill", title: "Advanced: token mode", tint: .orange)
      }
      .tint(.secondary)
    }
  }

  private var docsLink: some View {
    Link(destination: Self.docsURL) {
      Label("Full setup guide", systemImage: "book")
        .font(.subheadline.weight(.medium))
    }
    .padding(.top, 4)
  }

  // MARK: - Building blocks

  /// A plain rounded "surface" card.
  @ViewBuilder
  private func card(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  /// A tappable card that opens `url` outside the app: a filled icon tile, a title and a
  /// caption, and an outbound arrow.
  private func externalLinkRow(
    url: URL,
    icon: String,
    fill: LinearGradient,
    title: String,
    subtitle: String
  ) -> some View {
    Link(destination: url) {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(fill)
            .frame(width: 44, height: 44)
          Image(systemName: icon)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: title)
            .font(.headline)
            .foregroundStyle(.primary)
          Text(verbatim: subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Image(systemName: "arrow.up.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(16)
      .frame(maxWidth: .infinity)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
      )
    }
  }

  private func cardHeader(icon: String, title: String, tint: Color) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 28, height: 28)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      Text(title)
        .font(.headline)
        .foregroundStyle(.primary)
      Spacer()
    }
  }

  /// A tinted, bordered callout: leading glyph chip + bold title + secondary body.
  private func calloutCard(
    tint: Color, icon: String, title: String, message: String
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.headline)
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
    )
  }

  private func stepRow(number: Int, text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Color.blue, in: Circle())
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private func footnote(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// A monospaced, copy-friendly command chip with an optional `$` prompt and a copy button.
  /// Multi-line commands (the env-file block) hide the prompt and copy verbatim.
  private struct CommandCard: View {
    let command: String
    var showsPrompt: Bool = true
    @State private var copied = false
    /// Bumped on every copy so `.task(id:)` restarts the checkmark-reset delay.
    @State private var copyCount = 0

    var body: some View {
      HStack(alignment: .top, spacing: 10) {
        if showsPrompt {
          Text(verbatim: "$")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        Text(command)
          .font(.system(.footnote, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          UIPasteboard.general.string = command
          copyCount += 1
          withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.footnote.weight(.medium))
            .foregroundStyle(copied ? Color.green : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy command")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .task(id: copyCount) {
        guard copyCount > 0 else { return } // initial appearance — nothing to reset
        do {
          try await Task.sleep(for: .seconds(1.5))
        } catch {
          return // cancelled by a newer copy — the restarted task owns the reset
        }
        withAnimation(.easeInOut(duration: 0.15)) { copied = false }
      }
    }
  }
}

#Preview("Collapsed") {
  AgentSetupGuideView()
}

#Preview("Advanced expanded") {
  AgentSetupGuideView(advancedExpanded: true)
}

#Preview("Hermes Cloud") {
  AgentSetupGuideView(tab: .cloud)
}
