import Foundation
import HermesWidgetKit
import Testing

struct WidgetSnapshotTests {
  static let freshUntil = Date(timeIntervalSinceReferenceDate: 800_000_000)

  static func row(_ id: String, _ status: SessionStatus) -> WidgetSessionRow {
    WidgetSessionRow(
      id: id,
      title: "Session \(id)",
      workspace: "~/code/hermes",
      status: status,
      updatedAt: Date(timeIntervalSinceReferenceDate: 799_999_000.5),
      profile: "default"
    )
  }

  static let snapshot = WidgetSessionSnapshot(
    freshUntil: freshUntil,
    isSignedIn: true,
    rows: [row("a", .needsInput), row("b", .working), row("c", .unread), row("d", .idle)]
  )

  // MARK: Coding

  @Test func encodeDecodeRoundTrips() throws {
    let data = try Self.snapshot.encoded()
    #expect(WidgetSessionSnapshot.decodeLeniently(data) == Self.snapshot)
    #expect(Self.snapshot.version == WidgetSessionSnapshot.currentVersion)
  }

  @Test func optionalFieldsRoundTrip() throws {
    let bare = WidgetSessionSnapshot(
      freshUntil: Self.freshUntil,
      isSignedIn: true,
      rows: [WidgetSessionRow(id: "x", title: "Untitled", status: .working)]
    )
    #expect(WidgetSessionSnapshot.decodeLeniently(try bare.encoded()) == bare)
  }

  @Test func signedOutRoundTrips() throws {
    let data = try WidgetSessionSnapshot.signedOut.encoded()
    let decoded = try #require(WidgetSessionSnapshot.decodeLeniently(data))
    #expect(decoded.isSignedIn == false)
    #expect(decoded.rows.isEmpty)
  }

  @Test func rowsAreCappedAtFive() {
    let rows = (0..<8).map { Self.row("\($0)", .idle) }
    let snapshot = WidgetSessionSnapshot(freshUntil: Self.freshUntil, isSignedIn: true, rows: rows)
    #expect(snapshot.rows.map(\.id) == ["0", "1", "2", "3", "4"])
  }

  @Test(arguments: [
    Data(),
    Data("not json".utf8),
    Data("{}".utf8),
    Data(#"{"version":1}"#.utf8),
    Data(#"{"version":"1","freshUntil":0,"isSignedIn":true,"rows":[]}"#.utf8),
    Data(#"{"version":1,"freshUntil":0,"isSignedIn":true,"rows":[{"id":"a"}]}"#.utf8),
    Data(#"{"version":1,"freshUntil":0,"isSignedIn":true,"rows":[{"id":"a","title":"t","status":"bogus"}]}"#.utf8),
  ])
  func corruptBytesDecodeToNil(_ data: Data) {
    #expect(WidgetSessionSnapshot.decodeLeniently(data) == nil)
  }

  @Test func missingFileDecodesToNil() {
    #expect(WidgetSessionSnapshot.decodeLeniently(nil) == nil)
  }

  @Test func newerVersionDecodesToNil() throws {
    var newer = Self.snapshot
    newer.version = WidgetSessionSnapshot.currentVersion + 1
    #expect(WidgetSessionSnapshot.decodeLeniently(try newer.encoded()) == nil)
  }

  /// A newer writer may change the shape entirely; the header check alone rejects it.
  @Test func newerVersionWithUnknownShapeDecodesToNil() {
    let data = Data(#"{"version":2,"entries":{"a":1}}"#.utf8)
    #expect(WidgetSessionSnapshot.decodeLeniently(data) == nil)
  }

  // MARK: Staleness

  @Test func outdatedBoundaries() {
    let before = Self.freshUntil.addingTimeInterval(-0.001)
    let after = Self.freshUntil.addingTimeInterval(1)
    #expect(WidgetStaleness.isOutdated(Self.snapshot, at: before) == false)
    #expect(WidgetStaleness.isOutdated(Self.snapshot, at: Self.freshUntil) == true)
    #expect(WidgetStaleness.isOutdated(Self.snapshot, at: after) == true)
  }

  @Test(arguments: [
    (
      SessionStatus.needsInput,
      AgentActivityContent.DisplayStatus?.some(.needsInput),
      AgentActivityContent.DisplayStatus?.some(.outdated)
    ),
    (.working, .working, .outdated),
    (.unread, nil, nil),
    (.idle, nil, nil),
  ])
  func rowGlyphMapping(
    status: SessionStatus,
    fresh: AgentActivityContent.DisplayStatus?,
    stale: AgentActivityContent.DisplayStatus?
  ) {
    let row = Self.row("a", status)
    let before = Self.freshUntil.addingTimeInterval(-60)
    #expect(WidgetStaleness.glyph(for: row, snapshot: Self.snapshot, at: before) == fresh)
    #expect(WidgetStaleness.glyph(for: row, snapshot: Self.snapshot, at: Self.freshUntil) == stale)
    #expect(
      WidgetStaleness.glyph(for: row, snapshot: Self.snapshot, at: Self.freshUntil + 60) == stale
    )
  }

  // MARK: Timeline

  @Test func timelineSchedulesOutdatedEntryWhileFresh() {
    let now = Self.freshUntil.addingTimeInterval(-30)
    #expect(WidgetStaleness.timelineDates(for: Self.snapshot, at: now) == [now, Self.freshUntil])
  }

  @Test func timelineHasOneEntryOnceOutdated() {
    #expect(
      WidgetStaleness.timelineDates(for: Self.snapshot, at: Self.freshUntil) == [Self.freshUntil]
    )
    let later = Self.freshUntil.addingTimeInterval(60)
    #expect(WidgetStaleness.timelineDates(for: Self.snapshot, at: later) == [later])
    let signedOut = Date(timeIntervalSinceReferenceDate: 1)
    #expect(WidgetStaleness.timelineDates(for: .signedOut, at: signedOut) == [signedOut])
  }

  // MARK: Reading the mirror

  @Test func readsTheMirrorFile() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("widget-sessions-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Self.snapshot.encoded().write(to: url)
    #expect(WidgetSessionSnapshot.read(from: url) == Self.snapshot)
  }

  @Test func readingNoContainerOrNoFileIsNil() {
    #expect(WidgetSessionSnapshot.read(from: nil) == nil)
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-\(UUID().uuidString).json")
    #expect(WidgetSessionSnapshot.read(from: missing) == nil)
  }

  // MARK: Activity content and App Group

  @Test func activityContentCodesStableStatus() throws {
    let content = AgentActivityContent(
      activeCount: 2,
      headlineTitle: "Fix the build",
      headlineSessionID: "a",
      headlineProfile: "default",
      status: .needsInput
    )
    let data = try JSONEncoder().encode(content)
    #expect(try JSONDecoder().decode(AgentActivityContent.self, from: data) == content)
    let statuses: [AgentActivityContent.Status] = [.working, .needsInput, .done]
    #expect(statuses.map(\.rawValue) == ["working", "needsInput", "done"])
  }

  @Test func appGroupIsPinned() {
    #expect(AppGroup.identifier == "group.me.honcharenko.HermesMobile")
    #expect(AppGroup.snapshotFileName == "widget-sessions.json")
  }

  @Test func launchActionRawValuesArePinned() {
    let all: [LaunchAction] = [.dictation, .camera, .photos]
    #expect(all.map(\.rawValue) == ["dictation", "camera", "photos"])
  }
}
