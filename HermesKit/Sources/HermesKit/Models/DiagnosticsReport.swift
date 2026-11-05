import Foundation

/// The plain-text block Settings → Diagnostics copies to the pasteboard for a bug report.
///
/// **No-secrets invariant:** the report is built only from the arguments below, none of
/// which carry a credential — the auth row arrives pre-rendered as `AuthSession.settingsLabel`
/// (identity only), and the server URL is stripped of userinfo, query and fragment so a
/// `?token=`-style URL or `user:pass@host` can never leak. Never add an `AuthSession`
/// parameter here. Every event summary is capped with `GatewayEvent.truncate` (80 characters
/// plus an ellipsis), whatever fed the log.
public enum DiagnosticsReport {
  /// How many of the most recent log entries the report includes by default.
  public static let defaultLogLimit = 50

  public static func render(
    bundleInfo: BundleInfo,
    serverURL: URL,
    authLabel: String,
    agentVersion: String?,
    log: [GatewayLogEntry],
    logLimit: Int = defaultLogLimit
  ) -> String {
    var lines = ["Hermes Mobile diagnostics"]
    lines.append("App: \(bundleInfo.marketingVersion) (\(bundleInfo.build))")
    lines.append("iOS: \(bundleInfo.osVersion)")
    lines.append("Device: \(bundleInfo.deviceModel)")
    lines.append("Server: \(redacted(serverURL))")
    lines.append("Auth: \(authLabel)")
    lines.append("Agent: \(agentVersion?.nonEmptyTrimmed ?? "unknown")")
    lines.append("")

    let recent = log.suffix(max(logLimit, 0))
    if recent.isEmpty {
      lines.append("Recent events: none")
    } else {
      lines.append("Recent events (last \(recent.count) of \(log.count)):")
      lines.append(contentsOf: recent.map { "\($0.type) — \(GatewayEvent.truncate($0.summary))" })
    }
    return lines.joined(separator: "\n")
  }

  /// The server URL without userinfo, query or fragment — the only parts that could carry a
  /// credential.
  static func redacted(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.host ?? ""
    }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? url.host ?? ""
  }
}

private extension String {
  var nonEmptyTrimmed: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
