import Foundation
import GRDB
import Testing

@testable import HermesKit

struct ChatSnapshotClientTests {
  // MARK: - Helpers

  private func messageRow(_ text: String, complete: Bool = true) -> ChatRow {
    ChatRow(id: UUID(), kind: .message(role: .assistant, text: text, isComplete: complete))
  }

  // MARK: - Snapshot round-trip

  @Test func snapshotWriteReadRoundTrip() {
    let client = ChatSnapshotClient.inMemory()
    #expect(client.loadSnapshot("s1") == nil)

    let usage = Usage(model: "gpt-5", total: 1234, contextUsed: 1000, contextMax: 8000, contextPercent: 12)
    let rows = [messageRow("hello"), messageRow("world", complete: false)]
    let snapshot = ChatSnapshot(
      model: "gpt-5",
      reasoningEffort: "high",
      usage: usage,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      rows: rows
    )
    client.saveSnapshot("s1", snapshot)

    let loaded = client.loadSnapshot("s1")
    #expect(loaded?.model == "gpt-5")
    #expect(loaded?.reasoningEffort == "high")
    #expect(loaded?.usage == usage)
    #expect(loaded?.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(loaded?.rows == rows)
  }

  @Test func snapshotOverwriteReplacesWholesale() {
    let client = ChatSnapshotClient.inMemory()
    client.saveSnapshot("s1", ChatSnapshot(model: "a", rows: [messageRow("one"), messageRow("two")]))
    client.saveSnapshot("s1", ChatSnapshot(model: "b", rows: [messageRow("three")]))

    let loaded = client.loadSnapshot("s1")
    #expect(loaded?.model == "b")
    #expect(loaded?.rows.count == 1)
    if case let .message(_, text, _)? = loaded?.rows.first?.kind {
      #expect(text == "three")
    } else {
      Issue.record("expected single message row")
    }
  }

  @Test func snapshotRoundTripsToolRowsWithDetail() {
    let client = ChatSnapshotClient.inMemory()
    let toolRow = ChatRow(
      id: UUID(),
      kind: .tool(
        name: "bash",
        title: "Run command",
        state: .complete,
        detail: ToolDetail(argsText: "ls", args: .object(["cmd": .string("ls")]), resultText: "file.txt"),
        durationS: 1.5
      )
    )
    client.saveSnapshot("s1", ChatSnapshot(rows: [toolRow]))
    #expect(client.loadSnapshot("s1")?.rows == [toolRow])
  }

  @Test func snapshotRoundTripsCommandOutputRows() {
    // The ephemeral slash-output kind (#36) survives the cache round-trip like any other
    // row — a silent decode miss here would drop it from the instant-paint snapshot.
    let client = ChatSnapshotClient.inMemory()
    let rows = [
      messageRow("ran /status"),
      ChatRow(id: UUID(), kind: .commandOutput(text: "Session: all good")),
    ]
    client.saveSnapshot("s1", ChatSnapshot(rows: rows))
    #expect(client.loadSnapshot("s1")?.rows == rows)
  }

  @Test func snapshotRoundTripsReviewStatusRows() {
    // Review-summary system lines (#47) are `.status(kind: "review")` rows appended live;
    // they must survive the snapshot cache so the instant paint shows them until the next
    // (authoritative) hydrate replaces the transcript wholesale.
    let client = ChatSnapshotClient.inMemory()
    let statusRow = ChatRow(
      id: UUID(),
      kind: .status(kind: "review", text: "💾 Self-improvement review: tightened the retry loop.")
    )
    client.saveSnapshot("s1", ChatSnapshot(rows: [statusRow]))
    #expect(client.loadSnapshot("s1")?.rows == [statusRow])
  }

  @Test func snapshotRoundTripsReasoningRows() {
    let client = ChatSnapshotClient.inMemory()
    let rows = [
      ChatRow(id: UUID(), kind: .reasoning(text: "weighing options", isComplete: true)),
      ChatRow(id: UUID(), kind: .reasoning(text: "still going", isComplete: false)),
    ]
    client.saveSnapshot("s1", ChatSnapshot(rows: rows))
    #expect(client.loadSnapshot("s1")?.rows == rows)
  }

  @Test func legacyThinkingRowInACachedSnapshotIsSkippedNotACrash() throws {
    // A snapshot written before the tool-call display plan holds the retired `.thinking`
    // kind. It no longer decodes — that row is a cache miss (the cache is non-authoritative;
    // the next hydrate rebuilds the transcript), every other row still paints, and nothing
    // crashes.
    let store = try ChatSnapshotStore.inMemory()
    let before = messageRow("before")
    let after = messageRow("after")
    try store.saveSnapshot("s1", ChatSnapshot(model: "m", rows: [before, messageRow("placeholder"), after]))
    let legacyJSON = #"""
      {"id":"00000000-0000-0000-0000-0000000000AA","kind":{"thinking":{"reasoning":"old","status":"Context: 42% used","elapsedSeconds":12,"isComplete":true}}}
      """#
    try store.queue.write { db in
      try db.execute(
        sql: #"UPDATE "snapshot_rows" SET "row_json" = ? WHERE "session_id" = ? AND "idx" = 1"#,
        arguments: [legacyJSON, "s1"]
      )
    }

    let loaded = try #require(try store.loadSnapshot("s1"))
    #expect(loaded.model == "m")
    #expect(loaded.rows == [before, after])
  }

  @Test func attachmentImagesDoNotRoundTrip() throws {
    // Attachment BYTES are stripped by `ChatRow`'s `Codable` (omitted from `CodingKeys`),
    // so they never reach — or come back from — the cache, regardless of the reducer.
    let withBytes = ChatRow(
      id: UUID(),
      kind: .message(role: .user, text: "hi", isComplete: true),
      attachmentImages: [Data([0x01, 0x02, 0x03])]
    )

    // Direct Codable round-trip: bytes drop out.
    let encoded = try JSONEncoder().encode(withBytes)
    let decoded = try JSONDecoder().decode(ChatRow.self, from: encoded)
    #expect(decoded.attachmentImages.isEmpty)
    #expect(decoded == ChatRow(id: withBytes.id, kind: withBytes.kind))

    // And through the store: the loaded row equals the byte-free original.
    let client = ChatSnapshotClient.inMemory()
    client.saveSnapshot("s1", ChatSnapshot(rows: [withBytes]))
    let loaded = try #require(client.loadSnapshot("s1")?.rows.first)
    #expect(loaded.attachmentImages.isEmpty)
    #expect(loaded == ChatRow(id: withBytes.id, kind: withBytes.kind))
  }

  // MARK: - Turn anchor

  @Test func turnAnchorSetGetClear() {
    let client = ChatSnapshotClient.inMemory()
    #expect(client.turnAnchor("s1") == nil)

    let anchor = Date(timeIntervalSince1970: 1_700_000_500)
    client.setTurnAnchor("s1", anchor)
    #expect(client.turnAnchor("s1") == anchor)

    // Resetting overwrites.
    let anchor2 = Date(timeIntervalSince1970: 1_700_000_999)
    client.setTurnAnchor("s1", anchor2)
    #expect(client.turnAnchor("s1") == anchor2)

    client.clearTurnAnchor("s1")
    #expect(client.turnAnchor("s1") == nil)
  }

  @Test func turnAnchorIsPerSession() {
    let client = ChatSnapshotClient.inMemory()
    client.setTurnAnchor("s1", Date(timeIntervalSince1970: 1))
    client.setTurnAnchor("s2", Date(timeIntervalSince1970: 2))
    #expect(client.turnAnchor("s1") == Date(timeIntervalSince1970: 1))
    #expect(client.turnAnchor("s2") == Date(timeIntervalSince1970: 2))
  }

  // MARK: - deleteSnapshot

  @Test func deleteSnapshotClearsOnlyThatSession() {
    // Permanent session deletion (#73): the deleted session's snapshot AND turn anchor go;
    // every other session's cache entry is untouched.
    let client = ChatSnapshotClient.inMemory()
    client.saveSnapshot("gone", ChatSnapshot(model: "a", rows: [messageRow("bye")]))
    client.setTurnAnchor("gone", Date(timeIntervalSince1970: 1))
    client.saveSnapshot("kept", ChatSnapshot(model: "b", rows: [messageRow("hi")]))
    client.setTurnAnchor("kept", Date(timeIntervalSince1970: 2))

    client.deleteSnapshot("gone")

    #expect(client.loadSnapshot("gone") == nil)
    #expect(client.turnAnchor("gone") == nil)
    #expect(client.loadSnapshot("kept")?.model == "b")
    #expect(client.turnAnchor("kept") == Date(timeIntervalSince1970: 2))
  }

  @Test func deleteSnapshotOfUnknownSessionIsNoOp() {
    // Deleting a session that was never cached must not throw or disturb others.
    let client = ChatSnapshotClient.inMemory()
    client.saveSnapshot("kept", ChatSnapshot(model: "b", rows: [messageRow("hi")]))

    client.deleteSnapshot("ghost")

    #expect(client.loadSnapshot("kept") != nil)
  }

  // MARK: - wipeAll

  @Test func wipeAllClearsSnapshotsAndAnchors() {
    let client = ChatSnapshotClient.inMemory()
    client.saveSnapshot("s1", ChatSnapshot(model: "a", rows: [messageRow("hi")]))
    client.setTurnAnchor("s1", Date(timeIntervalSince1970: 1))

    client.wipeAll()

    #expect(client.loadSnapshot("s1") == nil)
    #expect(client.turnAnchor("s1") == nil)
  }

  // MARK: - Caps

  @Test func rowsAreCappedToTail() throws {
    let store = try ChatSnapshotStore.inMemory()
    let n = ChatSnapshotStore.maxRowsPerSession + 30
    let rows = (0..<n).map { messageRow("row\($0)") }
    try store.saveSnapshot("s1", ChatSnapshot(rows: rows))

    let loaded = try #require(try store.loadSnapshot("s1"))
    #expect(loaded.rows.count == ChatSnapshotStore.maxRowsPerSession)
    // The kept window is the *newest* rows.
    #expect(loaded.rows == Array(rows.suffix(ChatSnapshotStore.maxRowsPerSession)))
  }

  @Test func sessionsAreCappedByLRU() throws {
    let store = try ChatSnapshotStore.inMemory()
    let total = ChatSnapshotStore.maxSessions + 5
    for i in 0..<total {
      try store.saveSnapshot(
        "s\(i)",
        ChatSnapshot(model: "m\(i)", updatedAt: Date(timeIntervalSince1970: Double(i)), rows: [messageRow("x")])
      )
    }
    // The 5 oldest (lowest updated_at) should have been evicted.
    for i in 0..<5 {
      #expect(try store.loadSnapshot("s\(i)") == nil)
    }
    for i in 5..<total {
      #expect(try store.loadSnapshot("s\(i)") != nil)
    }
  }

  @Test func sessionsCapStaysBoundedWithEqualTimestamps() throws {
    // All sessions share the same `updated_at` — the LRU sort has no strict ordering to lean
    // on, so this pins that the cap is still enforced (the store never exceeds `maxSessions`)
    // and eviction is deterministic for a fixed write order (SQLite's stable sort keeps the
    // earlier-inserted rows last in a DESC tie, so the last-written survive).
    let store = try ChatSnapshotStore.inMemory()
    let total = ChatSnapshotStore.maxSessions + 5
    let sameTime = Date(timeIntervalSince1970: 1_000)
    for i in 0..<total {
      try store.saveSnapshot(
        "s\(i)",
        ChatSnapshot(model: "m\(i)", updatedAt: sameTime, rows: [messageRow("x")])
      )
    }
    // The cap is enforced regardless of the timestamp tie.
    let surviving = try (0..<total).filter { try store.loadSnapshot("s\($0)") != nil }.count
    #expect(surviving == ChatSnapshotStore.maxSessions)
  }

  // MARK: - Migration

  @Test func freshDatabaseHasSchema() throws {
    let store = try ChatSnapshotStore.inMemory()
    let tables = try store.queue.read { db in
      try String.fetchAll(
        db,
        sql: #"SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"#
      )
    }
    #expect(tables.contains("sessions"))
    #expect(tables.contains("turn_anchors"))
    #expect(tables.contains("snapshot_rows"))
  }

  @Test func migrationIsIdempotent() throws {
    // Running the migrator twice on the same DB must not throw or duplicate tables.
    let store = try ChatSnapshotStore.inMemory()
    try ChatSnapshotStore.migrator.migrate(store.queue)
    let applied = try store.queue.read { db in
      try ChatSnapshotStore.migrator.appliedMigrations(db)
    }
    #expect(applied == ["v1: snapshot tables"])
  }
}
