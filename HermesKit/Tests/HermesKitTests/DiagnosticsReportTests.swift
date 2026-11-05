import Foundation
import Testing

@testable import HermesKit

struct DiagnosticsReportTests {
  private static let serverURL = URL(string: "https://mac.tailnet:9119")!

  private static let log = [
    GatewayLogEntry(id: 0, type: "gateway.ready", summary: "ready"),
    GatewayLogEntry(id: 1, type: "message.delta", summary: "\"Hello\""),
  ]

  @Test func rendersFactsAndLogLines() {
    let report = DiagnosticsReport.render(
      bundleInfo: .test,
      serverURL: Self.serverURL,
      authLabel: "Password · alice",
      agentVersion: "0.12.0",
      log: Self.log
    )
    #expect(
      report == """
      Hermes Mobile diagnostics
      App: 1.0 (79)
      iOS: 18.0
      Device: iPhone
      Server: https://mac.tailnet:9119
      Auth: Password · alice
      Agent: 0.12.0

      Recent events (last 2 of 2):
      gateway.ready — ready
      message.delta — "Hello"
      """
    )
  }

  @Test func unknownAgentVersionAndEmptyLog() {
    let report = DiagnosticsReport.render(
      bundleInfo: .test,
      serverURL: Self.serverURL,
      authLabel: "Token",
      agentVersion: nil,
      log: []
    )
    #expect(report.contains("Agent: unknown"))
    #expect(report.contains("Recent events: none"))

    let blank = DiagnosticsReport.render(
      bundleInfo: .test, serverURL: Self.serverURL, authLabel: "Token", agentVersion: "  ", log: []
    )
    #expect(blank.contains("Agent: unknown"))
  }

  @Test func includesOnlyTheLastNLogEntries() {
    let log = (0..<10).map { GatewayLogEntry(id: $0, type: "t\($0)", summary: "s\($0)") }
    let report = DiagnosticsReport.render(
      bundleInfo: .test,
      serverURL: Self.serverURL,
      authLabel: "Token",
      agentVersion: nil,
      log: log,
      logLimit: 3
    )
    #expect(report.contains("Recent events (last 3 of 10):"))
    #expect(report.hasSuffix("t7 — s7\nt8 — s8\nt9 — s9"))
    #expect(!report.contains("t6 — s6"))
  }

  /// Every event summary is capped at 80 characters (+ ellipsis) whatever fed the log —
  /// `debugSummary` passes an approval command through at full length.
  @Test func capsEveryEventSummary() {
    let command = "curl -H 'Authorization: Bearer " + String(repeating: "k", count: 200) + "' x"
    let approval = GatewayEvent.approvalRequest(ApprovalRequest(command: command))
    let log = [
      GatewayLogEntry(id: 0, event: approval),
      GatewayLogEntry(id: 1, type: "error", summary: String(repeating: "e", count: 200)),
      GatewayLogEntry(id: 2, type: "status.update", summary: "line one\nline two"),
    ]
    #expect(log[0].summary == command) // the cap is the report's, not the log's
    let report = DiagnosticsReport.render(
      bundleInfo: .test, serverURL: Self.serverURL, authLabel: "Token", agentVersion: nil, log: log
    )
    let eventLines = report.components(separatedBy: "\n").suffix(log.count)
    for (line, entry) in zip(eventLines, log) {
      let summary = String(line.dropFirst("\(entry.type) — ".count))
      #expect(summary.count <= 81, "uncapped summary: \(line)")
    }
    #expect(!report.contains(String(repeating: "k", count: 81)))
    #expect(report.hasSuffix("status.update — line one⏎line two"))
  }

  @Test func neverContainsSecrets() {
    let tokenSecret = "TOKEN-SECRET-123"
    let cookieSecret = "COOKIE-SECRET-456"
    let accessSecret = "ACCESS-SECRET-789"
    let refreshSecret = "REFRESH-SECRET-000"
    let sessions: [AuthSession] = [
      .token(tokenSecret),
      .cookie(
        CookieSession(
          cookies: [
            SerializedCookie(name: "hermes_session_at", value: cookieSecret, domain: "d", path: "/"),
          ],
          username: "alice",
          provider: "basic"
        )
      ),
      .bearer(
        BearerSession(
          accessToken: accessSecret,
          refreshToken: refreshSecret,
          expiresAt: 1_800_000_000,
          provider: "nous",
          userID: "user-42"
        )
      ),
    ]
    // A URL that itself smuggles credentials: userinfo and a `?token=` query.
    let leakyURL = URL(string: "https://bob:\(tokenSecret)@mac.tailnet:9119/?token=\(tokenSecret)#\(tokenSecret)")!
    for session in sessions {
      let report = DiagnosticsReport.render(
        bundleInfo: .test,
        serverURL: leakyURL,
        authLabel: session.settingsLabel,
        agentVersion: "0.12.0",
        log: Self.log
      )
      for secret in [tokenSecret, cookieSecret, accessSecret, refreshSecret] {
        #expect(!report.contains(secret), "report leaked \(secret) for \(session.settingsLabel)")
      }
      #expect(report.contains("Server: https://mac.tailnet:9119/"))
      #expect(!report.contains("bob"))
    }
  }
}
