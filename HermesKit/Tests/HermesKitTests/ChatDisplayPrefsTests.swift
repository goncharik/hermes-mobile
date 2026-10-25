import Foundation
import Testing

@testable import HermesKit

/// Display prefs (#55): which transcript row kinds the chat renders, and whether arriving
/// content may move the viewport.
///
/// The load-bearing rule is that these govern agent ACTIVITY reporting only — an answer can
/// never be hidden by a display toggle, or a readability pref becomes silent data loss.
struct ChatDisplayPrefsTests {
  private func row(_ kind: ChatRow.Kind) -> ChatRow {
    ChatRow(id: UUID(), kind: kind)
  }

  private func messageRow(_ role: ChatRow.Role = .assistant) -> ChatRow {
    row(.message(role: role, text: "text", isComplete: true))
  }

  // MARK: Defaults

  @Test func defaultsShowEverything() {
    let prefs = ChatDisplayPrefs.default
    #expect(prefs.showToolRows)
    #expect(prefs.showThinkingRows)
    #expect(prefs.autoFollowEnabled)
    #expect(prefs.showsEverything)
  }

  /// The initializer's defaults must equal `.default` — the app relies on "absent pref means
  /// pre-feature behavior", so a drifted default would silently change what users see.
  @Test func bareInitMatchesDefault() {
    #expect(ChatDisplayPrefs() == ChatDisplayPrefs.default)
  }

  // MARK: shows(_:)

  @Test func toolRowsFollowTheirPref() {
    let toolRow = row(.tool(name: "read_file", title: "Read", state: .complete, detail: nil, durationS: 1))
    #expect(ChatDisplayPrefs(showToolRows: true).shows(toolRow))
    #expect(!ChatDisplayPrefs(showToolRows: false).shows(toolRow))
  }

  @Test func thinkingRowsFollowTheirPref() {
    let thinking = row(.thinking(reasoning: "hmm", status: nil, elapsedSeconds: 3, isComplete: true))
    #expect(ChatDisplayPrefs(showThinkingRows: true).shows(thinking))
    #expect(!ChatDisplayPrefs(showThinkingRows: false).shows(thinking))
  }

  /// Both user and assistant messages survive EVERY combination — including the most
  /// aggressive one. This is the invariant that keeps a display pref from becoming data loss.
  @Test func messagesAreNeverHidden() {
    let allOff = ChatDisplayPrefs(
      showToolRows: false, showThinkingRows: false, autoFollowEnabled: false
    )
    #expect(allOff.shows(messageRow(.assistant)))
    #expect(allOff.shows(messageRow(.user)))
  }

  /// Status lines and slash-command output are never hidden either: approvals/decisions and
  /// command results are surfaced content, not activity noise.
  @Test func statusAndCommandOutputAreNeverHidden() {
    let allOff = ChatDisplayPrefs(showToolRows: false, showThinkingRows: false)
    #expect(allOff.shows(row(.status(kind: "approval", text: "Approved"))))
    #expect(allOff.shows(row(.status(kind: ChatRow.Kind.reviewStatusKind, text: "review"))))
    #expect(allOff.shows(row(.commandOutput(text: "/status output"))))
  }

  // MARK: apply(to:)

  @Test func applyHidesOnlyToolRowsWhenOnlyToolsOff() {
    let rows = [
      messageRow(.user),
      row(.tool(name: "t", title: "T", state: .complete, detail: nil, durationS: nil)),
      messageRow(.assistant),
      row(.thinking(reasoning: "r", status: nil, elapsedSeconds: 1, isComplete: true)),
    ]
    let kept = ChatDisplayPrefs(showToolRows: false).apply(to: rows)
    #expect(kept.count == 3)
    #expect(!kept.contains { if case .tool = $0.kind { return true } else { return false } })
    // The thinking row and both messages survive.
    #expect(kept.contains { if case .thinking = $0.kind { return true } else { return false } })
  }

  @Test func applyHidesBothActivityKindsWhenBothOff() {
    let rows = [
      messageRow(.user),
      row(.tool(name: "t", title: "T", state: .complete, detail: nil, durationS: nil)),
      row(.thinking(reasoning: "r", status: nil, elapsedSeconds: 1, isComplete: true)),
      messageRow(.assistant),
    ]
    let kept = ChatDisplayPrefs(showToolRows: false, showThinkingRows: false).apply(to: rows)
    #expect(kept.count == 2)
    #expect(kept.allSatisfy { if case .message = $0.kind { return true } else { return false } })
    // Order is preserved — the answer stays below the question.
    #expect(kept.first?.id == rows.first?.id)
    #expect(kept.last?.id == rows.last?.id)
  }

  /// Following is a scroll behavior, not a row filter — it must never drop rows.
  @Test func autoFollowAloneNeverFiltersRows() {
    let rows = [
      messageRow(.user),
      row(.tool(name: "t", title: "T", state: .complete, detail: nil, durationS: nil)),
      row(.thinking(reasoning: "r", status: nil, elapsedSeconds: 1, isComplete: true)),
      messageRow(.assistant),
    ]
    let kept = ChatDisplayPrefs(autoFollowEnabled: false).apply(to: rows)
    #expect(kept.count == 4)
  }

  @Test func applyIsIdentityWhenEverythingShown() {
    let rows = [
      messageRow(.user),
      row(.tool(name: "t", title: "T", state: .complete, detail: nil, durationS: nil)),
      messageRow(.assistant),
    ]
    let kept = ChatDisplayPrefs.default.apply(to: rows)
    #expect(kept.map(\.id) == rows.map(\.id))
  }

  @Test func applyOnEmptyInputIsEmpty() {
    #expect(ChatDisplayPrefs(showToolRows: false).apply(to: [ChatRow]()).isEmpty)
  }

  /// A transcript of nothing but activity rows collapses to empty rather than crashing or
  /// leaving a stale row.
  @Test func applyCanProduceEmptyFromActivityOnlyTranscript() {
    let rows = [
      row(.tool(name: "t", title: "T", state: .complete, detail: nil, durationS: nil)),
      row(.thinking(reasoning: "r", status: nil, elapsedSeconds: 1, isComplete: true)),
    ]
    let kept = ChatDisplayPrefs(showToolRows: false, showThinkingRows: false).apply(to: rows)
    #expect(kept.isEmpty)
  }
}

/// The follow decision (#55): "may arriving content move the viewport?" — the pin rule from
/// `TranscriptScrollMath.isPinnedToBottom` combined with the user's follow pref.
struct TranscriptScrollFollowTests {
  @Test func followsOnlyWhenPinnedAndEnabled() {
    #expect(TranscriptScrollMath.shouldFollow(isPinnedToBottom: true, autoFollowEnabled: true))
    #expect(!TranscriptScrollMath.shouldFollow(isPinnedToBottom: true, autoFollowEnabled: false))
    #expect(!TranscriptScrollMath.shouldFollow(isPinnedToBottom: false, autoFollowEnabled: true))
    #expect(!TranscriptScrollMath.shouldFollow(isPinnedToBottom: false, autoFollowEnabled: false))
  }

  /// The exact reported complaint: parked at the bottom with following disabled, a long turn's
  /// tool calls must NOT scroll the text out from under the reader.
  @Test func parkedAtBottomWithFollowingOffDoesNotFollow() {
    let pinned = TranscriptScrollMath.isPinnedToBottom(
      contentHeight: 2_000, viewportHeight: 800, bottomInset: 0, offsetY: 1_200
    )
    #expect(pinned) // geometry says "at the bottom"
    #expect(
      !TranscriptScrollMath.shouldFollow(isPinnedToBottom: pinned, autoFollowEnabled: false)
    ) // the pref overrides it
  }
}
