import CustomDump
import Foundation
import Testing

@testable import HermesKit

struct ProbeFailureTests {
  private static let publicAddress = ServerAddress("https://hermes.example.com")!
  private static let tailnetAddress = ServerAddress("https://box.tail1234.ts.net")!
  private static let shortNameAddress = ServerAddress("mac-studio")!
  private static let localAddress = ServerAddress("192.168.1.20")!

  // MARK: - URLError

  @Test(arguments: [
    (URLError.Code.notConnectedToInternet, ProbeFailure.offline),
    (.dataNotAllowed, .offline),
    (.internationalRoamingOff, .offline),
    (.cannotFindHost, .hostNotFound),
    (.dnsLookupFailed, .hostNotFound),
    (.cannotConnectToHost, .refused),
    (.timedOut, .timedOut),
    (.networkConnectionLost, .timedOut),
    (.serverCertificateHasBadDate, .untrustedCertificate),
    (.serverCertificateUntrusted, .untrustedCertificate),
    (.serverCertificateHasUnknownRoot, .untrustedCertificate),
    (.serverCertificateNotYetValid, .untrustedCertificate),
    (.secureConnectionFailed, .untrustedCertificate),
    (.clientCertificateRejected, .untrustedCertificate),
    (.clientCertificateRequired, .untrustedCertificate),
  ])
  func classifiesURLErrorCode(_ code: URLError.Code, expected: ProbeFailure) {
    expectNoDifference(ProbeFailure.classify(URLError(code)), expected)
  }

  /// A request that failed with no HTTP answer, for a reason not listed, fails the
  /// "Reaching" check — nothing was reached.
  @Test(arguments: [URLError.Code.cancelled, .badServerResponse, .unsupportedURL, .unknown])
  func unlistedURLErrorIsRequestFailed(_ code: URLError.Code) {
    let failure = ProbeFailure.classify(URLError(code))
    guard case .requestFailed = failure else {
      Issue.record("Expected .requestFailed, got \(failure)")
      return
    }
    #expect(failure.failedCheck == .reaching)
  }

  @Test func nonURLErrorIsRequestFailed() {
    struct Boom: Error {}
    let failure = ProbeFailure.classify(Boom())
    guard case .requestFailed = failure else {
      Issue.record("Expected .requestFailed, got \(failure)")
      return
    }
  }

  // MARK: - HTTP

  @Test func notFoundIsNotHermes() {
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 404, contentType: "application/json", detail: "Not Found"),
      .notHermes(httpStatus: 404)
    )
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 404, contentType: "text/html", detail: nil),
      .notHermes(httpStatus: 404)
    )
  }

  @Test(arguments: [200, 204, 299])
  func undecodable2xxIsNotHermes(_ status: Int) {
    expectNoDifference(
      ProbeFailure.classify(httpStatus: status, contentType: "text/html; charset=utf-8", detail: nil),
      .notHermes(httpStatus: status)
    )
  }

  @Test func invalidHostDetailIsHostRejected() {
    let detail =
      "Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 400, contentType: "application/json", detail: detail),
      .hostRejected(detail: detail)
    )
  }

  @Test func otherBadRequestDetailIsHTTPError() {
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 400, contentType: "application/json", detail: "Bad profile name"),
      .httpError("Bad profile name")
    )
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 400, contentType: "application/json", detail: nil),
      .httpError("HTTP 400")
    )
  }

  @Test func otherStatusesCarryServerCopyVerbatim() {
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 503, contentType: "text/plain", detail: "Gateway starting"),
      .httpError("Gateway starting")
    )
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 500, contentType: nil, detail: nil),
      .httpError("HTTP 500")
    )
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 401, contentType: "application/json", detail: ""),
      .httpError("HTTP 401")
    )
  }

  @Test func htmlBodyIsNotUsedAsCopy() {
    expectNoDifference(
      ProbeFailure.classify(
        httpStatus: 502, contentType: "text/html", detail: "<html><body>Bad Gateway</body></html>"),
      .httpError("HTTP 502")
    )
    // Even an HTML page that happens to start with the Host message is not Hermes' JSON reply.
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 400, contentType: "TEXT/HTML", detail: "Invalid Host header"),
      .httpError("HTTP 400")
    )
  }

  // MARK: - Headline

  /// A text/plain error body (a traceback, a proxy dump) is cut to its first line on the card.
  @Test func headlineIsTheFirstNonEmptyLine() {
    let traceback = """

      Traceback (most recent call last):
        File "web_server.py", line 12, in status
      RuntimeError: boom
      """
    #expect(ProbeFailure.headline(of: traceback) == "Traceback (most recent call last):")
    #expect(ProbeFailure.headline(of: "Gateway starting") == "Gateway starting")
    #expect(ProbeFailure.headline(of: "") == "")
  }

  @Test func headlineCapsALongLine() {
    let line = String(repeating: "x", count: 250)
    #expect(ProbeFailure.headline(of: line) == String(repeating: "x", count: 200) + "…")
    #expect(ProbeFailure.headline(of: line, limit: 300) == line)
  }

  // MARK: - isTransport / triesNextCandidate

  @Test(arguments: [
    (ProbeFailure.offline, false, false),
    (.hostNotFound, true, true),
    (.refused, true, true),
    (.timedOut, true, true),
    (.untrustedCertificate, false, false),
    (.notHermes(httpStatus: 404), false, true),
    (.notHermes(httpStatus: 200), false, true),
    (.hostRejected(detail: "Invalid Host header."), false, false),
    (.httpError("HTTP 500"), false, false),
    (.requestFailed("unsupported URL"), false, false),
  ])
  func transportAndFallback(_ failure: ProbeFailure, isTransport: Bool, triesNext: Bool) {
    #expect(failure.isTransport == isTransport)
    #expect(failure.triesNextCandidate == triesNext)
  }

  // MARK: - Local Network hint

  /// The hint line rides on a same-network address that nothing answered, or that iOS
  /// reported as offline (how a denied Local Network permission fails).
  @Test(arguments: [
    (ProbeFailure.hostNotFound, true),
    (.refused, true),
    (.timedOut, true),
    (.offline, true),
    (.untrustedCertificate, false),
    (.notHermes(httpStatus: 404), false),
    (.hostRejected(detail: "Invalid Host header."), false),
    (.httpError("HTTP 500"), false),
    (.requestFailed("unsupported URL"), false),
  ])
  func localNetworkHint(_ failure: ProbeFailure, onLocalNetwork: Bool) {
    #expect(failure.showsLocalNetworkHint(for: Self.localAddress) == onLocalNetwork)
    #expect(failure.showsLocalNetworkHint(for: ServerAddress("mac.local")!) == onLocalNetwork)
    // Tailscale, public and loopback addresses never trigger the iOS alert (TN3179).
    for address in [Self.tailnetAddress, Self.shortNameAddress, Self.publicAddress, ServerAddress("localhost")!] {
      #expect(failure.showsLocalNetworkHint(for: address) == false)
    }
  }

  // MARK: - Failed check

  @Test(arguments: [
    (ProbeFailure.offline, ServerStep.State.Check.reaching),
    (.hostNotFound, .reaching),
    (.refused, .reaching),
    (.timedOut, .reaching),
    (.untrustedCertificate, .reaching),
    (.requestFailed("unsupported URL"), .reaching),
    (.notHermes(httpStatus: 404), .hermes),
    (.hostRejected(detail: "Invalid Host header."), .hermes),
    (.httpError("HTTP 500"), .hermes),
  ])
  func failedCheck(_ failure: ProbeFailure, check: ServerStep.State.Check) {
    #expect(failure.failedCheck == check)
  }

  // MARK: - FailedServerProbe

  /// The card's Details lists every `/api/status` URL the probe walked, and its copy names the
  /// last one — the candidate whose failure is reported.
  @Test func failedProbeNamesWhatWasTried() throws {
    let address = try #require(ServerAddress("mac"))
    let both = FailedServerProbe(address: address, failure: .refused, tried: address.candidates)
    #expect(both.reportedURL == URL(string: "http://mac:9119"))
    #expect(both.triedDetail == "Tried http://mac/api/status, then http://mac:9119/api/status")

    let first = FailedServerProbe(
      address: address, failure: .hostRejected(detail: "Invalid Host header."),
      tried: [address.url]
    )
    #expect(first.reportedURL == URL(string: "http://mac"))
    #expect(first.triedDetail == "Tried http://mac/api/status")
  }
}
