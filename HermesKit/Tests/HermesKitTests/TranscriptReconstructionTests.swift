import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Pure `reconstructTranscript` over the **cooked** `session.resume` history shape
/// (`_history_to_messages`): text rows carry `text`; tool calls are pre-flattened into
/// `{role:"tool", name, context}` rows (the server already matched call → result); reasoning
/// rides on the assistant text row. Mirrors the desktop TUI `toTranscriptMessages`.
@MainActor
struct TranscriptReconstructionTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  /// A cooked-shape history message: text rows use `text`; tool rows use `name`/`context`.
  private func msg(
    _ id: Int, _ role: String, text: String? = nil,
    name: String? = nil, context: String? = nil,
    reasoning: String? = nil, reasoningContent: String? = nil, reasoningDetails: String? = nil
  ) -> SessionMessage {
    SessionMessage(
      id: id, role: role,
      text: text, name: name, context: context,
      reasoning: reasoning, reasoningContent: reasoningContent, reasoningDetails: reasoningDetails
    )
  }

  // MARK: - Reasoning rows

  @Test func reasoningRowEmittedCollapsedAndComplete() {
    let rows = reconstructTranscript([
      msg(1, "user", text: "hi"),
      msg(2, "assistant", text: "hello", reasoning: "let me think"),
    ])

    #expect(rows.map(\.kind) == [ChatRow.Kind]([
      .message(role: .user, text: "hi", isComplete: true),
      .reasoning(text: "let me think", isComplete: true),
      .message(role: .assistant, text: "hello", isComplete: true),
    ]))
  }

  @Test func reasoningFallsBackThroughVariants() {
    let fromContent = reconstructTranscript(
      [msg(1, "assistant", text: "x", reasoningContent: "via content")]
    )
    #expect(fromContent.first?.kind == .reasoning(text: "via content", isComplete: true))

    let fromDetails = reconstructTranscript(
      [msg(1, "assistant", text: "x", reasoningDetails: "via details")]
    )
    #expect(fromDetails.first?.kind == .reasoning(text: "via details", isComplete: true))

    // First-non-empty wins.
    let priority = reconstructTranscript(
      [msg(1, "assistant", text: "x", reasoning: "primary", reasoningContent: "secondary")]
    )
    #expect(priority.first?.kind == .reasoning(text: "primary", isComplete: true))
  }

  @Test func reasoningRowIsAlwaysAClosedBurst() {
    // A reconstructed burst is history — never an open (live) one.
    let rows = reconstructTranscript([msg(1, "assistant", text: "x", reasoning: "r")])
    guard case let .reasoning(text, isComplete) = rows.first?.kind else {
      Issue.record("expected a reasoning row"); return
    }
    #expect(text == "r")
    #expect(isComplete)
  }

  @Test func userReasoningIsIgnored() {
    // Only assistant messages emit reasoning rows.
    let rows = reconstructTranscript([msg(1, "user", text: "hi", reasoning: "ignored")])
    #expect(rows.map(\.kind) == [.message(role: .user, text: "hi", isComplete: true)])
  }

  // MARK: - Tool rows (cooked, pre-flattened)

  @Test func toolRowFromCookedShape() {
    // The gateway already matched the call → result and flattened it into one row with a
    // display `name` and a short `context` preview.
    let rows = reconstructTranscript([
      msg(1, "tool", name: "read_file", context: "/etc/hosts"),
    ])

    // The title is the context (the live `tool.start` shape), so the presentation reads a
    // reloaded call's target the same way it reads a live one.
    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(
      name: "read_file", title: "/etc/hosts", state: .complete,
      detail: ToolDetail(argsText: "/etc/hosts"), durationS: nil
    ))
    guard case let .tool(call) = rows[0].kind else { return }
    #expect(ToolPresentation(call: call).settledTitle == "Read hosts")
  }

  @Test func aBlankContextLeavesTheNameAsTheTitle() {
    let rows = reconstructTranscript([msg(1, "tool", name: "grep", context: "  ")])
    #expect(rows.map(\.kind) == [.tool(
      name: "grep", title: "grep", state: .complete, detail: ToolDetail(argsText: "  "), durationS: nil
    )])
  }

  @Test func toolRowWithoutContextHasNoDetail() {
    let rows = reconstructTranscript([msg(1, "tool", name: "grep")])
    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(name: "grep", title: "grep", state: .complete, detail: nil, durationS: nil))
  }

  @Test func toolRowWithoutNameFallsBackToToolLabel() {
    let rows = reconstructTranscript([msg(1, "tool", context: "x")])
    #expect(rows.count == 1)
    #expect(rows[0].kind == .tool(name: "tool", title: "x", state: .complete, detail: ToolDetail(argsText: "x"), durationS: nil))
  }

  // MARK: - Empty / blank rows

  @Test func emptyTextRowsAreNotEmittedAsBlankBubbles() {
    let rows = reconstructTranscript([
      msg(1, "assistant", text: nil),
      msg(2, "user", text: ""),
    ])
    #expect(rows.isEmpty)
  }

  // MARK: - Ordering (cooked stream order is preserved)

  @Test func fullTurnPreservesCookedOrder() {
    // Cooked order for a tool-using turn: user → tool(s) → assistant(reasoning + answer).
    let rows = reconstructTranscript([
      msg(1, "user", text: "What's in /etc/hosts?"),
      msg(2, "tool", name: "read_file", context: "/etc/hosts"),
      msg(3, "assistant", text: "It maps localhost.", reasoning: "thinking…"),
    ])

    #expect(rows.map(\.kind) == [ChatRow.Kind]([
      .message(role: .user, text: "What's in /etc/hosts?", isComplete: true),
      .tool(name: "read_file", title: "/etc/hosts", state: .complete, detail: ToolDetail(argsText: "/etc/hosts"), durationS: nil),
      .reasoning(text: "thinking…", isComplete: true),
      .message(role: .assistant, text: "It maps localhost.", isComplete: true),
    ]))
  }

  @Test func systemAndUnknownRolesAreSkipped() {
    let rows = reconstructTranscript([
      msg(1, "system", text: "you are helpful"),
      msg(2, "weird", text: "??"),
      msg(3, "user", text: "hi"),
    ])
    #expect(rows.map(\.kind) == [.message(role: .user, text: "hi", isComplete: true)])
  }

  // MARK: - `content` fallback (raw shape tolerance)

  @Test func contentIsUsedWhenTextAbsent() {
    // Robustness: if a payload ever carries `content` instead of the cooked `text`, the
    // body still renders (`displayText` falls back to `content`).
    let rows = reconstructTranscript([
      SessionMessage(id: 1, role: "user", content: "from content"),
    ])
    #expect(rows.map(\.kind) == [.message(role: .user, text: "from content", isComplete: true)])
  }

  // MARK: - Decode parity with the real wire shape

  @Test func decodesCookedResumeShapeAndReconstructs() {
    // Decode a raw `session.resume`-shaped messages array (text/name/context) and confirm
    // reconstruction yields the expected rows — guards the SessionMessage CodingKeys.
    let json = """
    [
      {"role": "user", "text": "hi"},
      {"role": "tool", "name": "read_file", "context": "/x"},
      {"role": "assistant", "text": "done", "reasoning": "ponder"}
    ]
    """.data(using: .utf8)!
    let messages = try! JSONDecoder().decode([SessionMessage].self, from: json)
    let rows = reconstructTranscript(messages)

    #expect(rows.map(\.kind) == [ChatRow.Kind]([
      .message(role: .user, text: "hi", isComplete: true),
      .tool(name: "read_file", title: "/x", state: .complete, detail: ToolDetail(argsText: "/x"), durationS: nil),
      .reasoning(text: "ponder", isComplete: true),
      .message(role: .assistant, text: "done", isComplete: true),
    ]))
    // An old agent sends no timestamps: every row stays unstamped.
    #expect(rows.allSatisfy { $0.timestamp == nil })
  }

  // MARK: - Rich cooked tool rows + timestamps

  /// A newer agent's resume payload: an edit row with `args`, raw JSON `content`, a
  /// `display_metadata` inline diff and a timestamp; a terminal row with `args` but no
  /// `content` (live-only output); a non-JSON `content`.
  private static let richHistoryJSON = """
  [
    {"role": "user", "text": "fix it", "timestamp": 1700000000.5},
    {"role": "assistant", "text": "on it", "reasoning": "plan", "timestamp": 1700000001},
    {"role": "tool", "name": "patch", "context": "Sources/A.swift",
     "args": {"path": "Sources/A.swift", "old_string": "a", "new_string": "b"},
     "content": "{\\"success\\": true, \\"files_modified\\": [\\"Sources/A.swift\\"]}",
     "tool_call_id": "call_1", "timestamp": 1700000002,
     "display_metadata": {"tool_result_metadata": {"inline_diff": "--- a\\n+++ b\\n-a\\n+b"}}},
    {"role": "tool", "name": "terminal", "context": "pytest -q",
     "args": {"command": "pytest -q"}, "timestamp": 1700000003},
    {"role": "tool", "name": "skill_manage", "content": "Skill saved.", "timestamp": 0},
    {"role": "assistant", "text": "done", "timestamp": 1700000004}
  ]
  """

  @Test func richCookedToolRowsCarryArgsResultDiffAndTimestamps() throws {
    let messages = try JSONDecoder().decode([SessionMessage].self, from: Data(Self.richHistoryJSON.utf8))
    let rows = reconstructTranscript(messages)

    #expect(rows.map(\.kind) == [ChatRow.Kind]([
      .message(role: .user, text: "fix it", isComplete: true),
      .reasoning(text: "plan", isComplete: true),
      .message(role: .assistant, text: "on it", isComplete: true),
      .tool(name: "patch", title: "Sources/A.swift", state: .complete, detail: ToolDetail(
        argsText: "Sources/A.swift",
        args: .object([
          "path": .string("Sources/A.swift"), "old_string": .string("a"), "new_string": .string("b"),
        ]),
        result: .object(["success": .bool(true), "files_modified": .array([.string("Sources/A.swift")])]),
        resultText: #"{"success": true, "files_modified": ["Sources/A.swift"]}"#,
        inlineDiff: "--- a\n+++ b\n-a\n+b"
      ), durationS: nil),
      // Terminal output is live-only: args survive, no result.
      .tool(name: "terminal", title: "pytest -q", state: .complete, detail: ToolDetail(
        argsText: "pytest -q", args: .object(["command": .string("pytest -q")])
      ), durationS: nil),
      // Non-JSON content stays text-only (no structured result invented).
      .tool(name: "skill_manage", title: "skill_manage", state: .complete,
            detail: ToolDetail(resultText: "Skill saved."), durationS: nil),
      .message(role: .assistant, text: "done", isComplete: true),
    ]))
    // Every row carries its message's timestamp (the reasoning row shares its message's);
    // a non-positive timestamp is no timestamp.
    #expect(rows.map(\.timestamp) == [
      Date(timeIntervalSince1970: 1_700_000_000.5),
      Date(timeIntervalSince1970: 1_700_000_001),
      Date(timeIntervalSince1970: 1_700_000_001),
      Date(timeIntervalSince1970: 1_700_000_002),
      Date(timeIntervalSince1970: 1_700_000_003),
      nil,
      Date(timeIntervalSince1970: 1_700_000_004),
    ])
  }

  @Test func richRowsKeepTheSameDeterministicIDsAsTheirOldAgentShape() throws {
    // Ids derive from (index, role, discriminator) only — the new args/content/diff/timestamp
    // fields never move an id, so an agent upgrade (or a re-hydrate) reconciles row identity.
    let rich = reconstructTranscript(
      try JSONDecoder().decode([SessionMessage].self, from: Data(Self.richHistoryJSON.utf8))
    )
    let bare = reconstructTranscript([
      msg(1, "user", text: "fix it"),
      msg(2, "assistant", text: "on it", reasoning: "plan"),
      msg(3, "tool", name: "patch", context: "Sources/A.swift"),
      msg(4, "tool", name: "terminal", context: "pytest -q"),
      msg(5, "tool", name: "skill_manage"),
      msg(6, "assistant", text: "done"),
    ])
    #expect(rich.map(\.id) == bare.map(\.id))
    #expect(rich.map(\.id) == reconstructTranscript(
      try JSONDecoder().decode([SessionMessage].self, from: Data(Self.richHistoryJSON.utf8))
    ).map(\.id))
  }

  @Test(arguments: [
    ("[1, 2]", JSONValue.array([.number(1), .number(2)]) as JSONValue?),
    ("  {\"ok\": false}\n", .object(["ok": .bool(false)])),
    ("42", nil), // a bare scalar is text, not a structured result
    ("\"quoted\"", nil),
    ("{not json", nil),
    ("plain words", nil),
  ])
  func toolContentParsesOnlyJSONContainers(content: String, expected: JSONValue?) {
    let rows = reconstructTranscript([
      SessionMessage(id: 1, role: "tool", content: content, name: "write_file"),
    ])
    guard case let .tool(call) = rows.first?.kind else {
      Issue.record("expected a tool row")
      return
    }
    #expect(call.detail?.result == expected)
    // The raw text is kept regardless — never hidden.
    #expect(call.detail?.resultText == content)
  }

  // MARK: - Deterministic, content-derived identity

  @Test func sameHistoryInYieldsByteIdenticalIDsOut() {
    // Re-running reconstruction over identical history produces identical ids — the property
    // a diffing engine relies on to preserve scroll / animate inserts across a hydrate.
    let history = [
      msg(1, "user", text: "What's in /etc/hosts?"),
      msg(2, "tool", name: "read_file", context: "/etc/hosts"),
      msg(3, "assistant", text: "It maps localhost.", reasoning: "thinking…"),
    ]
    let first = reconstructTranscript(history)
    let second = reconstructTranscript(history)
    #expect(first.map(\.id) == second.map(\.id))
    #expect(!first.isEmpty)
  }

  @Test func identicalConsecutiveRowsGetDistinctIDs() {
    // Two identical user messages back-to-back must still get distinct ids (the sequence
    // index disambiguates), or they'd collide in an IdentifiedArray.
    let rows = reconstructTranscript([
      msg(1, "user", text: "ping"),
      msg(2, "user", text: "ping"),
    ])
    #expect(rows.count == 2)
    #expect(rows[0].kind == rows[1].kind)
    #expect(rows[0].id != rows[1].id)
  }

  @Test func messageAndItsReasoningRowGetDistinctIDs() {
    // An assistant turn emits a reasoning row then a text row — distinct indices AND distinct
    // kind discriminators, so distinct ids.
    let rows = reconstructTranscript([
      msg(1, "assistant", text: "answer", reasoning: "ponder"),
    ])
    #expect(rows.count == 2)
    #expect(rows[0].kindDiscriminator == "reasoning")
    #expect(rows[1].kindDiscriminator == "message")
    #expect(rows[0].id != rows[1].id)
  }

  @Test func idsAreUniqueAcrossTheWholeTranscript() {
    // No collisions anywhere — every reconstructed row has a unique id (precondition for
    // IdentifiedArrayOf(uniqueElements:)).
    let rows = reconstructTranscript([
      msg(1, "user", text: "a"),
      msg(2, "tool", name: "grep", context: "x"),
      msg(3, "assistant", text: "b", reasoning: "r"),
      msg(4, "user", text: "a"),
      msg(5, "assistant", text: "b", reasoning: "r"),
    ])
    let ids = Set(rows.map(\.id))
    #expect(ids.count == rows.count)
  }

  // MARK: - Edge cases

  @Test func emptyHistoryYieldsNoRows() {
    #expect(reconstructTranscript([]).isEmpty)
  }

  @Test func singleRowGetsAStableID() {
    let a = reconstructTranscript([msg(1, "user", text: "solo")])
    let b = reconstructTranscript([msg(1, "user", text: "solo")])
    #expect(a.count == 1)
    #expect(a.map(\.id) == b.map(\.id))
  }

  @Test func allSameRoleRunStaysDistinctAndReproducible() {
    let history = (0..<5).map { msg($0, "user", text: "same") }
    let first = reconstructTranscript(history)
    let second = reconstructTranscript(history)
    #expect(first.count == 5)
    #expect(Set(first.map(\.id)).count == 5)
    #expect(first.map(\.id) == second.map(\.id))
  }

  @Test func deterministicIDHelperMatchesSeedComponents() {
    // The id is a pure function of (sequenceIndex, role, kindDiscriminator); varying any one
    // component changes the id, so reorders / role-flips / kind-flips all diff.
    let base = ChatRow.deterministicID(sequenceIndex: 0, role: .user, kindDiscriminator: "message")
    #expect(base == ChatRow.deterministicID(sequenceIndex: 0, role: .user, kindDiscriminator: "message"))
    #expect(base != ChatRow.deterministicID(sequenceIndex: 1, role: .user, kindDiscriminator: "message"))
    #expect(base != ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "message"))
    #expect(base != ChatRow.deterministicID(sequenceIndex: 0, role: .user, kindDiscriminator: "tool"))
  }

  @Test func deterministicIDUniqueAcrossRealisticRange() {
    // The FNV-1a-derived UUID is not collision-resistant in the cryptographic sense, but it
    // MUST be collision-free over the realistic transcript space, or two distinct rows would
    // silently merge in the diffable data source. Enumerate every (sequenceIndex, role,
    // kindDiscriminator) combination a long session could produce and assert all ids are
    // distinct — 1000 indices × 3 roles × 5 discriminators = 15000 seeds.
    let roles: [ChatRow.Role?] = [.user, .assistant, nil]
    let discriminators = ["message", "tool", "reasoning", "status", "commandOutput"]
    var ids = Set<UUID>()
    var count = 0
    for index in 0..<1000 {
      for role in roles {
        for discriminator in discriminators {
          ids.insert(
            ChatRow.deterministicID(
              sequenceIndex: index, role: role, kindDiscriminator: discriminator
            )
          )
          count += 1
        }
      }
    }
    #expect(count == 15000)
    #expect(ids.count == count)  // zero collisions across the realistic range
  }

  @Test func deterministicIDStableAcrossRecomputation() {
    // Re-running the same seed yields the byte-identical UUID (no per-call randomness).
    for index in 0..<200 {
      let a = ChatRow.deterministicID(sequenceIndex: index, role: .assistant, kindDiscriminator: "reasoning")
      let b = ChatRow.deterministicID(sequenceIndex: index, role: .assistant, kindDiscriminator: "reasoning")
      #expect(a == b)
    }
  }

  @Test func commandOutputRowIDDeterministicAndDistinctFromOtherKinds() {
    // The slash-command output row (#36) has its own stable discriminator feeding the
    // deterministic id: rebuilt ids are byte-identical, and at the same ordinal it never
    // collides with any other kind.
    let kind = ChatRow.Kind.commandOutput(text: "compressed 12 messages")
    #expect(kind.discriminator == "commandOutput")
    // The discriminator excludes the mutable payload — different output text, same token.
    #expect(kind.discriminator == ChatRow.Kind.commandOutput(text: "other").discriminator)
    // commandOutput is not a message — no role component in its id.
    #expect(kind.role == nil)

    let id = ChatRow.deterministicID(
      sequenceIndex: 3, role: kind.role, kindDiscriminator: kind.discriminator
    )
    // Deterministic across rebuilds.
    #expect(id == ChatRow.deterministicID(sequenceIndex: 3, role: nil, kindDiscriminator: "commandOutput"))
    // Distinct from every other kind at the same ordinal.
    for other in ["message", "tool", "reasoning", "status"] {
      #expect(id != ChatRow.deterministicID(sequenceIndex: 3, role: nil, kindDiscriminator: other))
    }
    #expect(id != ChatRow.deterministicID(sequenceIndex: 3, role: .user, kindDiscriminator: "message"))
    #expect(id != ChatRow.deterministicID(sequenceIndex: 3, role: .assistant, kindDiscriminator: "message"))
    // And distinct from itself at a different ordinal.
    #expect(id != ChatRow.deterministicID(sequenceIndex: 4, role: nil, kindDiscriminator: "commandOutput"))
  }

  @Test func reconstructionNeverEmitsCommandOutput() {
    // slash.exec output is ephemeral and never written to persisted history (verified in the
    // Hermes source) — reconstructTranscript must be unaffected by the new kind: no server
    // role maps to it, and ids of the kinds it does emit are unchanged.
    let rows = reconstructTranscript([
      msg(1, "user", text: "hi"),
      msg(2, "assistant", text: "hello", reasoning: "hmm"),
      msg(3, "tool", name: "search", context: "q"),
      msg(4, "command", text: "not a real server role"),
    ])
    #expect(rows.allSatisfy { $0.kind.discriminator != "commandOutput" })
    // Same ids as before the kind existed — derived only from the emitted kinds.
    #expect(rows.map(\.id) == [
      ChatRow.deterministicID(sequenceIndex: 0, role: .user, kindDiscriminator: "message"),
      ChatRow.deterministicID(sequenceIndex: 1, role: nil, kindDiscriminator: "reasoning"),
      ChatRow.deterministicID(sequenceIndex: 2, role: .assistant, kindDiscriminator: "message"),
      ChatRow.deterministicID(sequenceIndex: 3, role: nil, kindDiscriminator: "tool"),
    ])
  }

  @Test func kindDiscriminatorSingleSourceMatchesReconstruction() {
    // ChatRow.kindDiscriminator/rowRole and Kind.discriminator/role are the same source;
    // a reconstructed row's id therefore equals one derived from the row's own components.
    let history = [
      msg(0, "user", text: "hi"),
      msg(1, "assistant", text: "answer", reasoning: "hmm"),
      msg(2, "tool", name: "search", context: "q"),
    ]
    let rows = reconstructTranscript(history)
    for (index, row) in rows.enumerated() {
      let expected = ChatRow.deterministicID(
        sequenceIndex: index, role: row.kind.role, kindDiscriminator: row.kind.discriminator
      )
      #expect(row.id == expected)
      #expect(row.kind.discriminator == row.kindDiscriminator)
      #expect(row.kind.role == row.rowRole)
    }
  }
}
