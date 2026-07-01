import Foundation

/// One line in the connection debug log (Task 12): a decoded `GatewayEvent` reduced to
/// a short type + summary for display. `id` is a monotonic index assigned by the
/// `DebugLogClient` buffer so SwiftUI has a stable identity.
public struct GatewayLogEntry: Equatable, Identifiable, Sendable {
  public let id: Int
  public let type: String
  public let summary: String

  public init(id: Int, type: String, summary: String) {
    self.id = id
    self.type = type
    self.summary = summary
  }

  public init(id: Int, event: GatewayEvent) {
    self.id = id
    self.type = event.debugType
    self.summary = event.debugSummary
  }
}

public extension GatewayEvent {
  /// Short wire-style label, e.g. `message.delta`.
  var debugType: String {
    switch self {
    case .ready: return "gateway.ready"
    case .sessionInfo: return "session.info"
    case .messageStart: return "message.start"
    case .messageDelta: return "message.delta"
    case .messageComplete: return "message.complete"
    case .thinkingDelta: return "thinking.delta"
    case .reasoningAvailable: return "reasoning.available"
    case .statusUpdate: return "status.update"
    case .toolStart: return "tool.start"
    case .toolComplete: return "tool.complete"
    case .approvalRequest: return "approval.request"
    case .clarifyRequest: return "clarify.request"
    case .sudoRequest: return "sudo.request"
    case .secretRequest: return "secret.request"
    case .error: return "error"
    // Client-synthesized, not a server frame (the gateway client yields it on a ws-ticket
    // 401) — labeled distinctly so it never reads as a real `auth.*` wire event in the log.
    case .authExpired: return "(client) session expired"
    case let .unknown(type, _): return type
    }
  }

  /// One-line, human-readable payload digest (truncated). Never leaks more than a
  /// preview of streamed text.
  var debugSummary: String {
    switch self {
    case .ready, .messageStart: return ""
    case let .sessionInfo(info): return info.model ?? ""
    case let .messageDelta(text): return Self.truncate(text)
    case let .messageComplete(text, _): return Self.truncate(text)
    case let .thinkingDelta(text): return Self.truncate(text)
    case let .reasoningAvailable(text): return Self.truncate(text)
    case let .statusUpdate(kind, text): return "[\(kind)] \(text)"
    case let .toolStart(_, name, _, _): return name
    case let .toolComplete(_, name, _, _, _, _, durationS):
      let d = durationS.map { String(format: " (%.1fs)", $0) } ?? ""
      return (name ?? "") + d
    case let .approvalRequest(req): return req.command ?? req.detail ?? "approval"
    case let .clarifyRequest(req): return req.question
    case let .sudoRequest(p): return p.prompt ?? p.requestID
    case let .secretRequest(p): return p.prompt ?? p.requestID
    case let .error(message): return message
    case .authExpired: return ""
    case .unknown: return ""
    }
  }

  private static func truncate(_ text: String, max: Int = 80) -> String {
    let collapsed = text.replacingOccurrences(of: "\n", with: "⏎")
    return collapsed.count <= max ? collapsed : String(collapsed.prefix(max)) + "…"
  }
}
