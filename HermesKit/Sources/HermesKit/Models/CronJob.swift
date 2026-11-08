import Foundation

/// A cron job as returned by `GET /api/cron/jobs` (present on hermes-agent v0.16+).
/// Decoded leniently — only `id` is required; unknown fields and unknown `state`
/// strings pass through untouched so a newer agent never crashes the list.
public struct CronJob: Equatable, Sendable, Identifiable, Decodable {
  public var id: String
  public var name: String?
  public var prompt: String?
  /// Human-readable schedule (`schedule_display`, e.g. "every day at 09:00").
  public var scheduleDisplay: String?
  public var enabled: Bool?
  /// Server-computed lifecycle state (`scheduled` / `running` / `paused` / `error` /
  /// `completed` / `disabled`), kept as a raw string for leniency — see `effectiveState`.
  public var state: String?
  public var nextRunAt: Date?
  public var lastRunAt: Date?
  public var lastStatus: String?
  /// Annotated by the server's cross-profile aggregation (`profile` on each job).
  public var profile: String?

  public init(
    id: String,
    name: String? = nil,
    prompt: String? = nil,
    scheduleDisplay: String? = nil,
    enabled: Bool? = nil,
    state: String? = nil,
    nextRunAt: Date? = nil,
    lastRunAt: Date? = nil,
    lastStatus: String? = nil,
    profile: String? = nil
  ) {
    self.id = id
    self.name = name
    self.prompt = prompt
    self.scheduleDisplay = scheduleDisplay
    self.enabled = enabled
    self.state = state
    self.nextRunAt = nextRunAt
    self.lastRunAt = lastRunAt
    self.lastStatus = lastStatus
    self.profile = profile
  }

  enum CodingKeys: String, CodingKey {
    case id, name, prompt, enabled, state, profile
    case scheduleDisplay = "schedule_display"
    case nextRunAt = "next_run_at"
    case lastRunAt = "last_run_at"
    case lastStatus = "last_status"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(String.self, forKey: .id)) ?? ""
    name = try? c.decodeIfPresent(String.self, forKey: .name)
    prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
    scheduleDisplay = try? c.decodeIfPresent(String.self, forKey: .scheduleDisplay)
    enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
    state = try? c.decodeIfPresent(String.self, forKey: .state)
    // Run timestamps are Python `datetime.isoformat()` strings (offset-aware, with or
    // without fractional seconds); an unparseable value degrades to nil, never throws.
    nextRunAt = Self.parseISODate((try? c.decodeIfPresent(String.self, forKey: .nextRunAt)) ?? nil)
    lastRunAt = Self.parseISODate((try? c.decodeIfPresent(String.self, forKey: .lastRunAt)) ?? nil)
    lastStatus = try? c.decodeIfPresent(String.self, forKey: .lastStatus)
    profile = try? c.decodeIfPresent(String.self, forKey: .profile)
  }

  /// Human label: name → 60-char prompt clip → id (mirrors the desktop's `jobTitle`
  /// fallback chain so the two clients never label a job differently).
  public var title: String {
    if let name = name?.trimmedNonEmpty { return name }
    if let prompt = prompt?.trimmedNonEmpty {
      return prompt.count > 60 ? String(prompt.prefix(60)) + "…" : prompt
    }
    return id
  }

  /// Effective lifecycle state: the explicit `state` wins; otherwise inferred from the
  /// `enabled` flag (mirrors the desktop's `jobState`).
  public var effectiveState: String {
    state?.trimmedNonEmpty ?? (enabled == false ? "disabled" : "scheduled")
  }

  public var isPaused: Bool { effectiveState == "paused" }

  /// Coarse relative label for a run instant: "in 7 hr." / "5 min. ago" / "in 2 days".
  /// Hand-rolled (no `RelativeDateTimeFormatter`) so tests and snapshots are
  /// locale-deterministic; picks the coarsest sensible unit like the desktop sidebar.
  public static func relativeRunLabel(for target: Date, now: Date) -> String {
    let diff = target.timeIntervalSince(now)
    let abs = Swift.abs(diff)
    let amount: String
    switch abs {
    case ..<60: amount = "\(max(1, Int(abs.rounded()))) sec."
    case ..<3600: amount = "\(Int((abs / 60).rounded())) min."
    case ..<86400: amount = "\(Int((abs / 3600).rounded())) hr."
    default:
      let days = Int((abs / 86400).rounded())
      amount = days == 1 ? "1 day" : "\(days) days"
    }
    return diff < 0 ? "\(amount) ago" : "in \(amount)"
  }

  /// A cron run row's timestamp, "Jun 10, 07:00" (no year, no seconds), like the desktop's
  /// `formatRunTime` (`fmtDayTime`): sibling runs share a title, so the instant is what tells
  /// them apart. A POSIX-locale format style in `timeZone` (English month abbreviations,
  /// 24-hour clock), so tests and snapshots never depend on the device locale; a missing
  /// instant reads "—".
  public static func runTimestampLabel(for date: Date?, timeZone: TimeZone) -> String {
    guard let date else { return "—" }
    return date.formatted(Date.VerbatimFormatStyle(
      format: """
        \(month: .abbreviated) \(day: .defaultDigits), \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
        """,
      locale: runTimestampLocale,
      timeZone: timeZone,
      calendar: runTimestampCalendar
    ))
  }

  private static let runTimestampLocale = Locale(identifier: "en_US_POSIX")
  private static let runTimestampCalendar = Calendar(identifier: .gregorian)

  /// How long a stored `next_run_at` may sit in the past before an active job reads as
  /// overdue. Mirrors hermes-agent `_OVERDUE_GRACE_SECONDS` and the desktop's
  /// `NEXT_RUN_OVERDUE_GRACE_MS` (a busy scheduler tick can dispatch a few minutes late).
  public static let overdueGrace: TimeInterval = 15 * 60

  /// The job row's status in words. Inactive states (`paused` / `error` / `completed` /
  /// `disabled`, incl. `enabled == false` without a `state`) replace the next-run caption
  /// with their word, so a paused job never reads "Next in 1 hr.". An active job (any other
  /// state, incl. `running` and unknown strings) shows "Next …", or "Overdue · … ago" once
  /// `next_run_at` is past the grace: a slot parked in the past is the only visible trace of
  /// a dead scheduler, so it must never read as an upcoming "Next" (desktop `job-state.ts`
  /// `nextRunOverdueMs`). Without a next run the schedule stands in; `nil` when there is
  /// nothing to show. `isOverdue` lets the view tint the overdue caption.
  public func statusCaption(now: Date) -> (text: String, isOverdue: Bool)? {
    switch effectiveState {
    case "paused": return ("Paused", false)
    case "error": return ("Error", false)
    case "completed": return ("Completed", false)
    case "disabled": return ("Disabled", false)
    default: break
    }
    if let next = nextRunAt {
      let label = Self.relativeRunLabel(for: next, now: now)
      if now.timeIntervalSince(next) > Self.overdueGrace {
        return ("Overdue · \(label)", true)
      }
      return ("Next \(label)", false)
    }
    return scheduleDisplay?.trimmedNonEmpty.map { ($0, false) }
  }

  private static func parseISODate(_ raw: String?) -> Date? {
    guard let raw = raw?.trimmedNonEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    return plain.date(from: raw)
  }
}
