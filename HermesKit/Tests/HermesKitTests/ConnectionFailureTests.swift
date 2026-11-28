import Foundation
import Testing

@testable import HermesKit

/// The secret-free cause lines behind the retry screen's Details and the diagnostics log (#193).
struct ConnectionFailureTests {
  @Test func urlErrorsKeepTheirCodeAndName() {
    #expect(ConnectionDiagnostics.cause(of: URLError(.cannotFindHost)) == "URLError -1003 cannotFindHost")
    #expect(ConnectionDiagnostics.cause(of: URLError(.secureConnectionFailed)) == "URLError -1200 secureConnectionFailed")
    // An unnamed code still prints its number.
    #expect(ConnectionDiagnostics.cause(of: URLError(URLError.Code(rawValue: -1234))) == "URLError -1234")
  }

  /// A URLError's failing URL is exactly where a WebSocket's `?token=` / `?ticket=` lives — it
  /// must never reach the line.
  @Test func aURLErrorsFailingURLNeverLeaks() {
    let url = URL(string: "wss://mac.tailnet/api/ws?token=SECRET")!
    let error = URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
    let line = ConnectionFailure(error, step: .webSocket).detail
    #expect(line == "WebSocket /api/ws: URLError -1011 badServerResponse")
    #expect(!line.contains("SECRET"))
  }

  @Test func restErrorsNameTheirStatus() {
    #expect(ConnectionDiagnostics.cause(of: RESTError.unauthorized) == "HTTP 401")
    #expect(ConnectionDiagnostics.cause(of: RESTError.server(status: 503, detail: nil)) == "HTTP 503")
    #expect(ConnectionDiagnostics.cause(of: RESTError.unreachable) == "no HTTP response")
  }

  /// A server detail is quoted on one line, capped, and dropped when it is markup.
  @Test func serverDetailIsSanitized() {
    #expect(ConnectionDiagnostics.httpCause(status: 400, detail: "Invalid Host header.\nmore") == "HTTP 400 Invalid Host header.")
    #expect(ConnectionDiagnostics.httpCause(status: 502, detail: "<html><body>Bad Gateway</body></html>") == "HTTP 502")
    let long = ConnectionDiagnostics.httpCause(status: 500, detail: String(repeating: "x", count: 300))
    #expect(long == "HTTP 500 " + String(repeating: "x", count: 120) + "…")
  }

  /// The WebSocket line prefers what the task knows: a close frame's code + reason, else the
  /// refused upgrade's HTTP status, else the thrown error.
  @Test func webSocketCausePrefersCloseCodeThenUpgradeStatus() {
    #expect(ConnectionDiagnostics.webSocketCause(
      closeCode: 4401, closeReason: "auth: token_mismatch", httpStatus: 101, underlying: nil
    ) == "closed 4401 auth: token_mismatch")
    #expect(ConnectionDiagnostics.webSocketCause(
      closeCode: nil, closeReason: nil, httpStatus: 403, underlying: URLError(.badServerResponse)
    ) == "upgrade refused, HTTP 403")
    #expect(ConnectionDiagnostics.webSocketCause(
      closeCode: nil, closeReason: nil, httpStatus: nil, underlying: URLError(.networkConnectionLost)
    ) == "URLError -1005 networkConnectionLost")
  }

  /// Anything else is named by type only — an arbitrary error's description may quote a URL.
  @Test func unknownErrorsAreNamedByTypeOnly() {
    struct LeakyError: Error, CustomStringConvertible {
      var description: String { "failed https://host/?token=SECRET" }
    }
    #expect(ConnectionFailure(LeakyError(), step: .sessionsProbe).detail == "GET /api/sessions: LeakyError")
  }

  /// An already-classified failure passes through untouched.
  @Test func anExistingFailureIsKept() {
    let failure = ConnectionFailure(reason: .offline, detail: "GET /api/sessions: URLError -1009")
    #expect(ConnectionFailure(failure, step: .webSocket) == failure)
  }
}
