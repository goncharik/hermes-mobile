import Foundation

/// One inbound event as delivered by the socket or replayed by `session.events.since` (#98).
///
/// The envelope carries the frame-level sequencing fields the reducer needs for lossless
/// reconnect; `GatewayEvent` itself stays payload-only. Client-synthesized events
/// (`.serverRequest`, `.serverRequestFailed`, `.serverRequestsUnavailable`, `.authExpired`)
/// are wrapped with no envelope data.
public struct GatewayFrame: Equatable, Sendable {
  public var event: GatewayEvent
  public var sessionID: String?
  /// Server per-session monotonic sequence (v2026.8.27+); nil on older agents, on
  /// session-less global events, and on client-synthesized events.
  public var seq: Int?
  /// `gateway.ready` only: the server process's replay epoch.
  public var replayEpoch: String?
  /// `gateway.ready` only: `session_authority: true` (canonical authority host, v0.22.3+).
  public var sessionAuthority: Bool

  public init(
    _ event: GatewayEvent, sessionID: String? = nil, seq: Int? = nil,
    replayEpoch: String? = nil, sessionAuthority: Bool = false
  ) {
    self.event = event
    self.sessionID = sessionID
    self.seq = seq
    self.replayEpoch = replayEpoch
    self.sessionAuthority = sessionAuthority
  }

  /// Decode a bare event object `{type, session_id, seq?, payload?}`: the shape shared by a
  /// live frame's `params` and each `session.events.since` element. A missing, empty, or
  /// non-string `type` → nil.
  init?(eventObject: JSONValue) {
    guard let type = eventObject["type"]?.stringValue, !type.isEmpty else { return nil }
    self.init(type: type, eventObject: eventObject)
  }

  /// Decode a live frame's `params`. A live frame with no `type` still decodes (as
  /// `.unknown`) to keep the socket lenient; only the replay path requires a type.
  init(liveEventObject eventObject: JSONValue) {
    self.init(type: eventObject["type"]?.stringValue ?? "", eventObject: eventObject)
  }

  /// The shared decode path.
  private init(type: String, eventObject: JSONValue) {
    let payload = eventObject["payload"]
    let event = GatewayEvent(type: type, payload: payload)
    var replayEpoch: String?
    var sessionAuthority = false
    // Read from the `gateway.ready` payload only: a canonical host's per-session
    // `replay_epoch` on other frames is deliberately ignored.
    if case .ready = event {
      replayEpoch = payload?["replay_epoch"]?.stringValue
      sessionAuthority = payload?["session_authority"]?.boolValue == true
    }
    self.init(
      event,
      sessionID: eventObject["session_id"]?.stringValue,
      seq: eventObject["seq"]?.sequenceNumber,
      replayEpoch: replayEpoch,
      sessionAuthority: sessionAuthority
    )
  }
}

/// The `session.events.since` result (#98). Lenient: undecodable `events` elements are
/// dropped, `truncated` defaults to `false`, and `open_requests` / `count` / any canonical
/// extras are deliberately not decoded (the hydrate that always follows reconciles prompts).
/// Only a missing or non-array `events` is malformed.
public struct ReplayBatch: Equatable, Sendable, Decodable {
  public var events: [GatewayFrame]
  public var latestSeq: Int?
  public var truncated: Bool
  public var epoch: String?

  init(events: [GatewayFrame] = [], latestSeq: Int? = nil, truncated: Bool = false, epoch: String? = nil) {
    self.events = events
    self.latestSeq = latestSeq
    self.truncated = truncated
    self.epoch = epoch
  }

  enum CodingKeys: String, CodingKey {
    case events, truncated, epoch
    case latestSeq = "latest_seq"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try c.decode([JSONValue].self, forKey: .events)
    self.events = raw.compactMap(GatewayFrame.init(eventObject:))
    self.latestSeq = (try? c.decodeIfPresent(JSONValue.self, forKey: .latestSeq))?.sequenceNumber
    self.truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
    self.epoch = try? c.decodeIfPresent(String.self, forKey: .epoch)
  }
}

extension JSONValue {
  /// A wire sequence number: a non-negative integral JSON number, else nil. Unlike
  /// `intValue` this never truncates a fraction or traps on an out-of-range double.
  var sequenceNumber: Int? {
    guard case let .number(d) = self, d >= 0, let n = Int(exactly: d) else { return nil }
    return n
  }
}

extension GatewayEvent {
  /// The four legacy (pre-v7) prompt notifications. They ride the replay ring on
  /// v2026.8.27 – v2026.9.11 agents, but the app decodes no `*.expire`, so replay skips them
  /// rather than raise a card that may have expired in the gap (#98).
  var isLegacyPrompt: Bool {
    switch self {
    case .approvalRequest, .clarifyRequest, .sudoRequest, .secretRequest: true
    default: false
    }
  }
}
