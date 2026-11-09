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
    (.cannotFindHost, .hostNotFound(tailnetName: false)),
    (.dnsLookupFailed, .hostNotFound(tailnetName: false)),
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
    expectNoDifference(
      ProbeFailure.classify(URLError(code), address: Self.publicAddress),
      expected
    )
  }

  @Test func hostNotFoundFlagsTailnetNames() {
    expectNoDifference(
      ProbeFailure.classify(URLError(.cannotFindHost), address: Self.tailnetAddress),
      .hostNotFound(tailnetName: true)
    )
    expectNoDifference(
      ProbeFailure.classify(URLError(.dnsLookupFailed), address: Self.shortNameAddress),
      .hostNotFound(tailnetName: true)
    )
    expectNoDifference(
      ProbeFailure.classify(URLError(.cannotFindHost), address: Self.publicAddress),
      .hostNotFound(tailnetName: false)
    )
    expectNoDifference(
      ProbeFailure.classify(URLError(.cannotFindHost), address: Self.localAddress),
      .hostNotFound(tailnetName: false)
    )
  }

  @Test(arguments: [URLError.Code.cancelled, .badServerResponse, .unknown])
  func unlistedURLErrorIsOther(_ code: URLError.Code) {
    let failure = ProbeFailure.classify(URLError(code), address: Self.publicAddress)
    guard case .other = failure else {
      Issue.record("Expected .other, got \(failure)")
      return
    }
  }

  @Test func nonURLErrorIsOther() {
    struct Boom: Error {}
    let failure = ProbeFailure.classify(Boom(), address: Self.publicAddress)
    guard case .other = failure else {
      Issue.record("Expected .other, got \(failure)")
      return
    }
  }

  @Test func alreadyClassifiedFailurePassesThrough() {
    expectNoDifference(
      ProbeFailure.classify(ProbeFailure.refused, address: Self.publicAddress),
      .refused
    )
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

  @Test func otherBadRequestDetailIsOther() {
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 400, contentType: "application/json", detail: "Bad profile name"),
      .other("Bad profile name")
    )
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 400, contentType: "application/json", detail: nil),
      .other("HTTP 400")
    )
  }

  @Test func otherStatusesCarryServerCopyVerbatim() {
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 503, contentType: "text/plain", detail: "Gateway starting"),
      .other("Gateway starting")
    )
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 500, contentType: nil, detail: nil),
      .other("HTTP 500")
    )
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 401, contentType: "application/json", detail: ""),
      .other("HTTP 401")
    )
  }

  @Test func htmlBodyIsNotUsedAsCopy() {
    expectNoDifference(
      ProbeFailure.classify(
        httpStatus: 502, contentType: "text/html", detail: "<html><body>Bad Gateway</body></html>"),
      .other("HTTP 502")
    )
    // Even an HTML page that happens to start with the Host message is not Hermes' JSON reply.
    expectNoDifference(
      ProbeFailure.classify(httpStatus: 400, contentType: "TEXT/HTML", detail: "Invalid Host header"),
      .other("HTTP 400")
    )
  }

  // MARK: - isTransport

  @Test(arguments: [
    (ProbeFailure.offline, false),
    (.hostNotFound(tailnetName: false), true),
    (.hostNotFound(tailnetName: true), true),
    (.refused, true),
    (.timedOut, true),
    (.untrustedCertificate, false),
    (.notHermes(httpStatus: 404), false),
    (.notHermes(httpStatus: nil), false),
    (.hostRejected(detail: "Invalid Host header."), false),
    (.other("HTTP 500"), false),
  ])
  func isTransport(_ failure: ProbeFailure, expected: Bool) {
    #expect(failure.isTransport == expected)
  }

  // MARK: - ServerProbe

  @Test func serverProbeKeepsTheAnsweringCandidate() throws {
    let address = try #require(ServerAddress("mac-studio"))
    let fallback = try #require(address.candidates.last)
    let probe = ServerProbe(
      address: address, baseURL: fallback, capability: .tokenOnly, version: "0.9.0")
    #expect(probe.baseURL == URL(string: "http://mac-studio:9119"))
    #expect(probe.address == address)
    #expect(probe.version == "0.9.0")
  }
}
