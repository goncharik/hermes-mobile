import HermesKit
import SwiftUI

/// The Server step's failure card (#136): what went wrong for THIS address, what to try, and a
/// way into the setup guide — one card per `ProbeFailure` case, copy from the prototype.
///
/// The Local Network hint line follows `ProbeFailure.showsLocalNetworkHint`: a same-network
/// address that nothing answered may be iOS's Local Network alert (still up, or denied), so the
/// card says how to allow it instead of the app detecting it (TN3179).
struct ProbeFailureCard: View {
  let failed: FailedServerProbe
  let setupGuideButtonTapped: () -> Void
  @State private var isShowingDetails: Bool

  init(
    failed: FailedServerProbe,
    setupGuideButtonTapped: @escaping () -> Void,
    isShowingDetails: Bool = false
  ) {
    self.failed = failed
    self.setupGuideButtonTapped = setupGuideButtonTapped
    self._isShowingDetails = State(initialValue: isShowingDetails)
  }

  var body: some View {
    let content = Content(failed)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: content.systemImage)
          .font(.title3)
          .foregroundStyle(content.tint)
          .accessibilityHidden(true)
        Text(verbatim: content.title)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      }

      Text(verbatim: content.message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(content.fixes.enumerated()), id: \.offset) { index, fix in
          FixRow(number: index + 1, text: fix, tint: content.tint)
        }
      }

      if failed.failure.showsLocalNetworkHint(for: failed.address) {
        OnboardingNotice {
          Text("""
          If iOS asked about Local Network access, allow it and try again. You can change it \
          in Settings › Privacy & Security › Local Network.
          """)
        }
      }

      Button("Setup guide", action: setupGuideButtonTapped)
        .onboardingTonalButton()
        .controlSize(.small)

      DisclosureGroup(isExpanded: $isShowingDetails) {
        Text(verbatim: content.detail)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .padding(.top, 6)
      } label: {
        Text("Details")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .tint(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      content.tint.opacity(0.12),
      in: RoundedRectangle(cornerRadius: OnboardingLayout.cardCornerRadius, style: .continuous)
    )
    .accessibilityElement(children: .contain)
  }

  /// A numbered "try this" line. The copy may carry inline `code` markdown.
  private struct FixRow: View {
    let number: Int
    let text: String
    let tint: Color

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("\(number)")
          .font(.caption.weight(.bold))
          .foregroundStyle(tint)
          .frame(minWidth: 20, minHeight: 20)
          .background(tint.opacity(0.18), in: Circle())
          .accessibilityHidden(true)
        Text(LocalizedStringKey(text))
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
    }
  }

  /// The copy for one failure against one address.
  private struct Content {
    let systemImage: String
    let title: String
    let message: String
    /// No interpolated host: rendered as markdown for inline `code`.
    let fixes: [String]
    let detail: String
    let tint: Color

    init(_ failed: FailedServerProbe) {
      let address = failed.address
      let host = address.host
      let port = ServerAddress.fallbackPort
      // The candidate whose failure this card reports (for a bare host, the :9119 fallback).
      let url = failed.reportedURL.absoluteString
      let tried = failed.triedDetail

      switch failed.failure {
      case .hostNotFound where address.kind == .tailnet:
        systemImage = "network"
        title = "Is Tailscale on?"
        message = """
        This phone can’t look up \(host). Tailscale names only resolve while Tailscale is \
        connected on this phone.
        """
        fixes = [
          "Open Tailscale and connect.",
          "Check that this phone and the agent’s computer are on the same tailnet.",
          "Check the spelling of the machine name.",
        ]
        detail = "\(tried)\nDNS lookup failed: cannot find host"
        tint = .red

      case .hostNotFound:
        systemImage = "magnifyingglass"
        title = "Can’t find \(host)"
        message = "No address exists for \(host)."
        fixes = [
          "Check the spelling.",
          "If it’s a name on your home network, try the computer’s IP address instead.",
        ]
        detail = "\(tried)\nDNS lookup failed: cannot find host"
        tint = .red

      case .refused:
        systemImage = "server.rack"
        title = "The computer is there, but the dashboard isn’t"
        message = "\(host) refused the connection at \(url)."
        fixes = [
          "Check that `hermes dashboard` is running.",
          "Start it with `--host 0.0.0.0`. A dashboard on 127.0.0.1 only answers on that computer.",
          "Check the port. The dashboard uses \(port) unless you changed it.",
        ]
        detail = "\(tried)\nConnection refused"
        tint = .red

      case .timedOut:
        systemImage = "wifi.exclamationmark"
        title = "No answer from \(host)"
        message = "Nothing answered at \(url)."
        fixes = address.kind == .localNetwork
          ? [
            "Check that this phone is on the same Wi-Fi as the agent’s computer.",
            "Check the computer’s firewall allows port \(port).",
          ]
          : [
            "Turn on Tailscale or your VPN on this phone.",
            "Check that the agent’s computer is awake and online.",
            "Check its firewall allows port \(port).",
          ]
        detail = "\(tried)\nThe request timed out"
        tint = .red

      case .untrustedCertificate:
        systemImage = "lock.trianglebadge.exclamationmark"
        title = "The certificate isn’t trusted"
        message = """
        \(host) uses a self-signed or expired HTTPS certificate, so iOS refused the connection.
        """
        fixes = [
          "On a private network, use the http:// address instead.",
          "Or turn on Tailscale HTTPS certificates to get a trusted one.",
        ]
        detail = "\(tried)\nTLS: the server certificate isn’t trusted"
        tint = .red

      case .offline where address.kind == .localNetwork:
        systemImage = "wifi.slash"
        title = "Can’t reach \(host)"
        message = "iOS reported no network connection for \(host)."
        fixes = [
          "Check that this phone is on the same Wi-Fi as the agent’s computer.",
          "Turn off Airplane Mode.",
        ]
        detail = "\(tried)\nNot connected to the internet"
        tint = .red

      case .offline:
        systemImage = "wifi.slash"
        title = "This phone is offline"
        message = "It isn’t connected to Wi-Fi or mobile data, so it can’t reach \(host)."
        fixes = [
          "Join a Wi-Fi network, or turn off Airplane Mode.",
          "If you use mobile data, check it’s allowed for Hermes in Settings.",
        ]
        detail = "\(tried)\nNot connected to the internet"
        tint = .red

      case let .notHermes(httpStatus):
        systemImage = "exclamationmark.triangle"
        title = "This isn’t a Hermes agent"
        message = httpStatus == 404
          ? "\(host) answered, but /api/status returned 404."
          : "\(host) answered, but /api/status didn’t return a Hermes status."
        fixes = [
          "Check the port. The dashboard uses \(port) unless you changed it.",
          "Behind a reverse proxy, use the address that serves the dashboard itself.",
        ]
        detail = "\(tried)\nHTTP \(httpStatus) on /api/status"
        tint = .orange

      case let .hostRejected(serverDetail):
        systemImage = "shield"
        title = "Your agent rejected this address"
        message = """
        The dashboard only accepts the address it was started with. This protects it from \
        DNS-rebinding attacks.
        """
        fixes = [
          "Use the exact address you passed to `--host`.",
          """
          Or restart the dashboard with `--host 0.0.0.0`, which accepts any address on your \
          network.
          """,
          """
          Behind Tailscale Serve or a reverse proxy, set `dashboard.public_url` (or \
          `HERMES_DASHBOARD_PUBLIC_URL`) to this address.
          """,
        ]
        detail = "\(tried)\nHTTP 400 · \"\(serverDetail)\""
        tint = .orange

      case let .httpError(text), let .requestFailed(text):
        systemImage = "exclamationmark.triangle"
        title = "Couldn’t connect to \(host)"
        message = ProbeFailure.headline(of: text)
        fixes = ["Check the address, then try again."]
        detail = "\(url)\n\(text)"
        tint = .red
      }
    }
  }
}
