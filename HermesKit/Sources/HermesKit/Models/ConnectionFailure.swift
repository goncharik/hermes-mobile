import Foundation

/// A failed connection step together with its raw cause, for the diagnostics log and the
/// retry screen's Details (#193). The user-facing copy stays keyed on `reason` (the same
/// `RESTError` routing as before, #62); `detail` is the one line a bug report needs and the
/// flattened `RESTError` lost: which step failed and the `URLError` code, HTTP status or
/// WebSocket close code behind it.
///
/// **No secrets, ever** (the `DiagnosticsReport` invariant): `detail` never carries a URL, a
/// query string (`?token=` / `?ticket=` ride on the WebSocket URL), a header, a cookie or an
/// error's `localizedDescription` / `userInfo` (which can quote the failing URL). It is built
/// only from a step label, numeric codes, symbolic code names and a sanitized server `detail`.
public struct ConnectionFailure: Error, Equatable, Sendable {
  /// The `RESTError` the routing and the reason line read (`ConnectionFailedFeature.isRetryable`).
  public var reason: RESTError
  /// `"<step>: <cause>"`, e.g. `GET /api/sessions: URLError -1001 timedOut`.
  public var detail: String

  /// The diagnostics-log entry type every connection failure is recorded under.
  public static let logType = "connect.failed"

  public init(reason: RESTError, detail: String) {
    self.reason = reason
    self.detail = detail
  }

  /// Classify whatever a connection step threw. A raw `URLError` keeps its code (and maps to
  /// the same `RESTError` the shared transport funnel would); an already-typed `RESTError`
  /// keeps its status; anything else is named by type only.
  public init(_ error: any Error, step: ConnectionStep) {
    if let failure = error as? ConnectionFailure {
      self = failure
      return
    }
    reason = asRESTError(error)
    detail = "\(step.label): \(ConnectionDiagnostics.cause(of: error))"
  }
}

/// The connection steps a failure can be pinned to. Labels name the method and path only —
/// never the query, which is where the WebSocket credential travels.
public enum ConnectionStep: String, Equatable, Sendable {
  /// The launch / retry-screen check that the stored sign-in still works.
  case sessionsProbe
  /// `POST /api/auth/ws-ticket` (gated sign-ins mint one per connect).
  case ticketMint
  /// The chat WebSocket: its upgrade, or a close after it opened.
  case webSocket

  public var label: String {
    switch self {
    case .sessionsProbe: "GET /api/sessions"
    case .ticketMint: "POST /api/auth/ws-ticket"
    case .webSocket: "WebSocket /api/ws"
    }
  }
}

/// Pure, secret-free descriptions of connection failures.
public enum ConnectionDiagnostics {
  /// Longest server-supplied `detail` quoted in a diagnostic line.
  static let maxDetailLength = 120

  /// One-line cause for an error thrown by a connection step.
  public static func cause(of error: any Error) -> String {
    if let urlError = error as? URLError {
      return urlErrorCause(urlError.code)
    }
    if let rest = error as? RESTError {
      return restCause(rest)
    }
    if let gateway = error as? GatewayError {
      return gatewayCause(gateway)
    }
    if error is DecodingError {
      return "response did not decode"
    }
    if error is CancellationError {
      return "cancelled"
    }
    // The type name only: an arbitrary error's description may quote a URL.
    return String(describing: type(of: error))
  }

  /// `URLError -1001 timedOut`: the numeric code is what Apple's docs and forums key on; the
  /// name makes the log readable without a lookup.
  public static func urlErrorCause(_ code: URLError.Code) -> String {
    let name = urlErrorNames[code.rawValue].map { " \($0)" } ?? ""
    return "URLError \(code.rawValue)\(name)"
  }

  /// `HTTP 403`, plus the server's sanitized `detail` when it sent a readable one.
  public static func httpCause(status: Int, detail: String?) -> String {
    guard let detail = sanitized(detail) else { return "HTTP \(status)" }
    return "HTTP \(status) \(detail)"
  }

  /// A WebSocket that closed (or never opened). `closeCode` is the RFC 6455 code when a close
  /// frame arrived (`nil` otherwise); `httpStatus` is the upgrade response's status when the
  /// handshake was refused (Starlette answers a pre-accept close with an HTTP 403, so a
  /// refused credential, Host or Origin all read as `HTTP 403` here and only the server log
  /// says which); `underlying` is the error `receive()` threw.
  public static func webSocketCause(
    closeCode: Int?, closeReason: String?, httpStatus: Int?, underlying: (any Error)?
  ) -> String {
    if let closeCode {
      let reason = sanitized(closeReason).map { " \($0)" } ?? ""
      return "closed \(closeCode)\(reason)"
    }
    if let httpStatus, !(101..<200).contains(httpStatus) {
      return "upgrade refused, HTTP \(httpStatus)"
    }
    return underlying.map(cause(of:)) ?? "closed"
  }

  static func restCause(_ error: RESTError) -> String {
    switch error {
    case .unauthorized: "HTTP 401"
    case .notFound: "HTTP 404"
    case .rateLimited: "HTTP 429"
    case .serviceUnavailable: "HTTP 503"
    case let .server(status, detail): httpCause(status: status, detail: detail)
    case .offline: "device offline"
    case .unreachable: "no HTTP response"
    case .decoding: "response did not decode"
    case .transcriptionFailed: "transcription failed"
    }
  }

  static func gatewayCause(_ error: GatewayError) -> String {
    switch error {
    case .authExpired: "HTTP 401"
    case let .ticketUnavailable(cause): cause
    case .notConnected: "not connected"
    case .disconnected: "disconnected"
    case let .timedOut(method): "timed out (\(method))"
    case let .server(message): sanitized(message) ?? "server error"
    }
  }

  /// First line of `text`, markup dropped, capped — the same rule as the retry screen's
  /// quoted server detail, at a log-line length.
  static func sanitized(_ text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, !trimmed.hasPrefix("<"),
          let line = trimmed.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespaces),
          !line.isEmpty
    else { return nil }
    guard line.count > maxDetailLength else { return line }
    return line.prefix(maxDetailLength).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// Names for the codes a connection realistically fails with. Anything else prints its
  /// number alone.
  static let urlErrorNames: [Int: String] = [
    URLError.Code.cancelled.rawValue: "cancelled",
    URLError.Code.badURL.rawValue: "badURL",
    URLError.Code.timedOut.rawValue: "timedOut",
    URLError.Code.unsupportedURL.rawValue: "unsupportedURL",
    URLError.Code.cannotFindHost.rawValue: "cannotFindHost",
    URLError.Code.cannotConnectToHost.rawValue: "cannotConnectToHost",
    URLError.Code.networkConnectionLost.rawValue: "networkConnectionLost",
    URLError.Code.dnsLookupFailed.rawValue: "dnsLookupFailed",
    URLError.Code.httpTooManyRedirects.rawValue: "httpTooManyRedirects",
    URLError.Code.resourceUnavailable.rawValue: "resourceUnavailable",
    URLError.Code.notConnectedToInternet.rawValue: "notConnectedToInternet",
    URLError.Code.redirectToNonExistentLocation.rawValue: "redirectToNonExistentLocation",
    URLError.Code.badServerResponse.rawValue: "badServerResponse",
    URLError.Code.userCancelledAuthentication.rawValue: "userCancelledAuthentication",
    URLError.Code.userAuthenticationRequired.rawValue: "userAuthenticationRequired",
    URLError.Code.zeroByteResource.rawValue: "zeroByteResource",
    URLError.Code.cannotDecodeRawData.rawValue: "cannotDecodeRawData",
    URLError.Code.cannotDecodeContentData.rawValue: "cannotDecodeContentData",
    URLError.Code.cannotParseResponse.rawValue: "cannotParseResponse",
    URLError.Code.appTransportSecurityRequiresSecureConnection.rawValue:
      "appTransportSecurityRequiresSecureConnection",
    URLError.Code.internationalRoamingOff.rawValue: "internationalRoamingOff",
    URLError.Code.callIsActive.rawValue: "callIsActive",
    URLError.Code.dataNotAllowed.rawValue: "dataNotAllowed",
    URLError.Code.requestBodyStreamExhausted.rawValue: "requestBodyStreamExhausted",
    URLError.Code.secureConnectionFailed.rawValue: "secureConnectionFailed",
    URLError.Code.serverCertificateHasBadDate.rawValue: "serverCertificateHasBadDate",
    URLError.Code.serverCertificateUntrusted.rawValue: "serverCertificateUntrusted",
    URLError.Code.serverCertificateHasUnknownRoot.rawValue: "serverCertificateHasUnknownRoot",
    URLError.Code.serverCertificateNotYetValid.rawValue: "serverCertificateNotYetValid",
    URLError.Code.clientCertificateRejected.rawValue: "clientCertificateRejected",
    URLError.Code.clientCertificateRequired.rawValue: "clientCertificateRequired",
    URLError.Code.backgroundSessionWasDisconnected.rawValue: "backgroundSessionWasDisconnected",
  ]
}
