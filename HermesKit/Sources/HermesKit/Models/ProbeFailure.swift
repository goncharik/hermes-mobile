import Foundation

/// Why the onboarding Server step's `/api/status` probe failed (#136), classified from the RAW
/// `URLError` / HTTP response before anything is flattened to `RESTError`, so each failure card
/// can say what actually went wrong (and what to try next).
///
/// Only the onboarding probe uses this; the launch path (#62) keeps `RESTError`.
public enum ProbeFailure: Error, Equatable, Sendable {
  /// The device has no usable network (`.notConnectedToInternet` / `.dataNotAllowed` /
  /// `.internationalRoamingOff`).
  case offline
  /// DNS could not resolve the host (`.cannotFindHost` / `.dnsLookupFailed`). `tailnetName`
  /// is set for a tailnet-looking name (`*.ts.net`, single-label MagicDNS) — the card then
  /// asks "Is Tailscale on?".
  case hostNotFound(tailnetName: Bool)
  /// Nothing listens on that port (`.cannotConnectToHost`).
  case refused
  /// The host never answered (`.timedOut` / `.networkConnectionLost`).
  case timedOut
  /// TLS failed (`.serverCertificate*` / `.secureConnectionFailed` / `.clientCertificate*`).
  case untrustedCertificate
  /// Something answered, but not a Hermes dashboard: a 404, a non-JSON 2xx, or a 2xx body
  /// that did not decode as `/api/status`.
  case notHermes(httpStatus: Int?)
  /// Hermes rejected the `Host` header (dashboard bound to a specific address and reached by
  /// another name): a 400 whose detail starts "Invalid Host header". Carries the server copy.
  case hostRejected(detail: String)
  /// Anything else — the server's copy verbatim, or a generic description.
  case other(String)

  /// The server's 400 `detail` prefix for a Host header that is neither the bound hostname nor
  /// `dashboard.public_url` (`hermes_cli/web_server.py`, `host_header_middleware`).
  static let invalidHostDetailPrefix = "Invalid Host header"

  /// A transport failure where another candidate URL (the `:9119` fallback) may still answer,
  /// and where a local-network address gets the Local Network hint line.
  public var isTransport: Bool {
    switch self {
    case .hostNotFound, .refused, .timedOut: true
    case .offline, .untrustedCertificate, .notHermes, .hostRejected, .other: false
    }
  }

  /// Classifies a transport failure thrown by `URLSession` while probing `address`. An
  /// already-classified `ProbeFailure` passes through unchanged; a non-`URLError` is `.other`.
  public static func classify(_ error: any Error, address: ServerAddress) -> ProbeFailure {
    if let failure = error as? ProbeFailure { return failure }
    guard let urlError = error as? URLError else { return .other(error.localizedDescription) }
    switch urlError.code {
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
      return .offline
    case .cannotFindHost, .dnsLookupFailed:
      return .hostNotFound(tailnetName: address.kind == .tailnet)
    case .cannotConnectToHost:
      return .refused
    case .timedOut, .networkConnectionLost:
      return .timedOut
    case .serverCertificateHasBadDate, .serverCertificateUntrusted,
      .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
      .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
      return .untrustedCertificate
    default:
      return .other(urlError.localizedDescription)
    }
  }

  /// Classifies an HTTP answer to `GET /api/status` that did not yield a `ServerStatus`: a
  /// non-2xx, or a 2xx whose body was not decodable (callers only hand a 2xx here when
  /// decoding failed). `detail` is the server's error text (JSON `detail` or plain body).
  ///
  /// An HTML `contentType` drops `detail` (a reverse proxy's error page is markup, not copy).
  public static func classify(httpStatus: Int, contentType: String?, detail: String?) -> ProbeFailure {
    let isHTML = contentType?.lowercased().contains("text/html") ?? false
    let detail = detail.flatMap { isHTML || $0.isEmpty ? nil : $0 }
    switch httpStatus {
    case 200..<300, 404:
      return .notHermes(httpStatus: httpStatus)
    case 400:
      if let detail, detail.hasPrefix(invalidHostDetailPrefix) {
        return .hostRejected(detail: detail)
      }
      return .other(detail ?? "HTTP \(httpStatus)")
    default:
      return .other(detail ?? "HTTP \(httpStatus)")
    }
  }
}
