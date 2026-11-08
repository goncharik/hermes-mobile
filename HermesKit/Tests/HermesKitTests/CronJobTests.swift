import Foundation
import Testing

@testable import HermesKit

struct CronJobTests {
  private func decode(_ json: String) throws -> CronJob {
    try JSONDecoder().decode(CronJob.self, from: Data(json.utf8))
  }

  // MARK: Decoding

  @Test func decodesFullPayload() throws {
    let job = try decode(
      """
      {
        "id": "a1b2c3d4e5f6",
        "name": "Morning digest",
        "prompt": "Summarize my inbox",
        "schedule_display": "every day at 09:00",
        "enabled": true,
        "state": "scheduled",
        "next_run_at": "2026-07-02T09:00:00+00:00",
        "last_run_at": "2026-07-01T09:00:00.123456+00:00",
        "last_status": "success",
        "profile": "default"
      }
      """
    )

    #expect(job.id == "a1b2c3d4e5f6")
    #expect(job.name == "Morning digest")
    #expect(job.prompt == "Summarize my inbox")
    #expect(job.scheduleDisplay == "every day at 09:00")
    #expect(job.enabled == true)
    #expect(job.state == "scheduled")
    #expect(job.nextRunAt == Date(timeIntervalSince1970: 1_782_982_800))
    // Fractional-seconds variant parses too (sub-second precision retained).
    #expect(job.lastRunAt.map { Swift.abs($0.timeIntervalSince1970 - 1_782_896_400.123456) < 0.001 } == true)
    #expect(job.lastStatus == "success")
    #expect(job.profile == "default")
  }

  @Test func decodesMinimalPayloadAndIgnoresUnknowns() throws {
    let job = try decode(
      """
      {"id": "abc123", "future_field": {"nested": true}, "state": "hibernating"}
      """
    )

    #expect(job.id == "abc123")
    #expect(job.name == nil)
    #expect(job.nextRunAt == nil)
    // Unknown state strings pass through raw — never crash, never coerce.
    #expect(job.state == "hibernating")
    #expect(job.effectiveState == "hibernating")
  }

  @Test func unparseableDatesDegradeToNil() throws {
    let job = try decode(
      """
      {"id": "abc123", "next_run_at": "not-a-date", "last_run_at": ""}
      """
    )

    #expect(job.nextRunAt == nil)
    #expect(job.lastRunAt == nil)
  }

  // MARK: Title fallback chain (name → prompt clip → id)

  @Test func titlePrefersName() {
    let job = CronJob(id: "abc", name: "Digest", prompt: "Summarize")
    #expect(job.title == "Digest")
  }

  @Test func titleFallsBackToClippedPrompt() {
    let long = String(repeating: "x", count: 80)
    let job = CronJob(id: "abc", name: "  ", prompt: long)
    #expect(job.title == String(repeating: "x", count: 60) + "…")

    let short = CronJob(id: "abc", prompt: "Summarize my inbox")
    #expect(short.title == "Summarize my inbox")
  }

  @Test func titleFallsBackToID() {
    let job = CronJob(id: "abc123", name: " ", prompt: "\n")
    #expect(job.title == "abc123")
  }

  // MARK: Effective state (explicit wins, else enabled flag)

  @Test func effectiveStateInfersFromEnabledFlag() {
    #expect(CronJob(id: "a", enabled: false).effectiveState == "disabled")
    #expect(CronJob(id: "a", enabled: true).effectiveState == "scheduled")
    #expect(CronJob(id: "a").effectiveState == "scheduled")
    #expect(CronJob(id: "a", enabled: false, state: "paused").effectiveState == "paused")
    #expect(CronJob(id: "a", state: "paused").isPaused)
    #expect(!CronJob(id: "a", state: "running").isPaused)
  }

  // MARK: Relative run label

  @Test func relativeRunLabelFuture() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(CronJob.relativeRunLabel(for: now.addingTimeInterval(30), now: now) == "in 30 sec.")
    #expect(CronJob.relativeRunLabel(for: now.addingTimeInterval(5 * 60), now: now) == "in 5 min.")
    #expect(CronJob.relativeRunLabel(for: now.addingTimeInterval(7 * 3600), now: now) == "in 7 hr.")
    #expect(CronJob.relativeRunLabel(for: now.addingTimeInterval(86400), now: now) == "in 1 day")
    #expect(CronJob.relativeRunLabel(for: now.addingTimeInterval(3 * 86400), now: now) == "in 3 days")
  }

  @Test func relativeRunLabelPast() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(CronJob.relativeRunLabel(for: now.addingTimeInterval(-90), now: now) == "2 min. ago")
    #expect(CronJob.relativeRunLabel(for: now.addingTimeInterval(-2 * 3600), now: now) == "2 hr. ago")
    #expect(CronJob.relativeRunLabel(for: now.addingTimeInterval(-2 * 86400), now: now) == "2 days ago")
  }

  @Test func relativeRunLabelClampsSubSecondToOneSecond() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(CronJob.relativeRunLabel(for: now, now: now) == "in 1 sec.")
  }

  // MARK: Status caption

  private let captionNow = Date(timeIntervalSince1970: 1_000_000)

  @Test func statusCaptionNamesInactiveStates() {
    // A far-future next run must not leak into an inactive job's caption.
    let next = captionNow.addingTimeInterval(3600)
    for (state, word) in [
      ("paused", "Paused"), ("error", "Error"), ("completed", "Completed"), ("disabled", "Disabled"),
    ] {
      let caption = CronJob(id: "a", state: state, nextRunAt: next).statusCaption(now: captionNow)
      #expect(caption?.text == word)
      #expect(caption?.isOverdue == false)
    }
  }

  @Test func statusCaptionTreatsDisabledFlagWithoutStateAsDisabled() {
    let job = CronJob(id: "a", enabled: false, nextRunAt: captionNow.addingTimeInterval(3600))
    let caption = job.statusCaption(now: captionNow)
    #expect(caption?.text == "Disabled")
    #expect(caption?.isOverdue == false)
  }

  @Test func statusCaptionShowsUpcomingNextRun() {
    let job = CronJob(id: "a", state: "scheduled", nextRunAt: captionNow.addingTimeInterval(3600))
    let caption = job.statusCaption(now: captionNow)
    #expect(caption?.text == "Next in 1 hr.")
    #expect(caption?.isOverdue == false)
  }

  @Test func statusCaptionKeepsNextWithinOverdueGrace() {
    let fiveMinAgo = CronJob(id: "a", nextRunAt: captionNow.addingTimeInterval(-5 * 60))
    #expect(fiveMinAgo.statusCaption(now: captionNow)?.text == "Next 5 min. ago")
    #expect(fiveMinAgo.statusCaption(now: captionNow)?.isOverdue == false)

    // Exactly at the grace boundary is still "Next" (strictly greater flips to overdue).
    let atGrace = CronJob(id: "a", nextRunAt: captionNow.addingTimeInterval(-CronJob.overdueGrace))
    #expect(atGrace.statusCaption(now: captionNow)?.text == "Next 15 min. ago")
    #expect(atGrace.statusCaption(now: captionNow)?.isOverdue == false)
  }

  @Test func statusCaptionFlagsOverdueJustPastGrace() {
    let justPast = CronJob(
      id: "a", nextRunAt: captionNow.addingTimeInterval(-CronJob.overdueGrace - 1)
    )
    let caption = justPast.statusCaption(now: captionNow)
    #expect(caption?.text == "Overdue · 15 min. ago")
    #expect(caption?.isOverdue == true)

    let twoHours = CronJob(id: "a", nextRunAt: captionNow.addingTimeInterval(-2 * 3600))
    #expect(twoHours.statusCaption(now: captionNow)?.text == "Overdue · 2 hr. ago")
  }

  @Test func statusCaptionFallsBackToScheduleThenNone() {
    let scheduled = CronJob(id: "a", scheduleDisplay: "every day at 09:00")
    let caption = scheduled.statusCaption(now: captionNow)
    #expect(caption?.text == "every day at 09:00")
    #expect(caption?.isOverdue == false)

    let blank = CronJob(id: "a", scheduleDisplay: "  ")
    #expect(blank.statusCaption(now: captionNow) == nil)

    let bare = CronJob(id: "a")
    #expect(bare.statusCaption(now: captionNow) == nil)
  }

  @Test func statusCaptionCountsRunningEnabledAndUnknownStatesAsActive() {
    let overdueAt = captionNow.addingTimeInterval(-2 * 3600)
    let jobs = [
      CronJob(id: "a", state: "running", nextRunAt: overdueAt),
      CronJob(id: "a", enabled: true, nextRunAt: overdueAt),
      CronJob(id: "a", state: "enabled", nextRunAt: overdueAt),
      CronJob(id: "a", state: "hibernating", nextRunAt: overdueAt),
    ]
    for job in jobs {
      #expect(job.statusCaption(now: captionNow)?.isOverdue == true)
    }
    let upcoming = CronJob(id: "a", state: "running", nextRunAt: captionNow.addingTimeInterval(600))
    #expect(upcoming.statusCaption(now: captionNow)?.text == "Next in 10 min.")
  }

  // MARK: Run timestamp

  @Test func runTimestampLabelIsFixedFormatInTheGivenTimeZone() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    // 2025-06-10 21:00:00 UTC.
    let evening = Date(timeIntervalSince1970: 1_749_589_200)
    #expect(CronJob.runTimestampLabel(for: evening, timeZone: utc) == "Jun 10, 21:00")
    // Single-digit day, zero-padded clock, January.
    let newYear = Date(timeIntervalSince1970: 1_735_689_600 + 5 * 60 + 7) // 2025-01-01 00:05:07
    #expect(CronJob.runTimestampLabel(for: newYear, timeZone: utc) == "Jan 1, 00:05")
  }

  @Test func runTimestampLabelFollowsTheTimeZone() throws {
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    // 2025-06-10 21:00 UTC is the next morning in Tokyo (UTC+9).
    let evening = Date(timeIntervalSince1970: 1_749_589_200)
    #expect(CronJob.runTimestampLabel(for: evening, timeZone: tokyo) == "Jun 11, 06:00")
  }

  @Test func runTimestampLabelWithoutAnInstantIsADash() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    #expect(CronJob.runTimestampLabel(for: nil, timeZone: utc) == "—")
  }
}
