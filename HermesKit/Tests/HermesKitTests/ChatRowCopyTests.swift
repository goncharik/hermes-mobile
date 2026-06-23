import Foundation
import Testing

@testable import HermesKit

/// `ChatRow.copyText` is the single source of plain text the `.copyRow(id:)` context-menu
/// puts on the pasteboard (#27b — agent responses must be fully copyable). These cover the
/// message and tool branches; the thinking branch is covered by `ThinkingModelTests`.
@Suite struct ChatRowCopyTests {
  @Test func messageCopiesFullText() {
    let body = "# Heading\n\nFirst paragraph.\n\n- one\n- two\n\n> quoted line"
    let row = ChatRow(
      id: UUID(),
      kind: .message(role: .assistant, text: body, isComplete: true)
    )
    // The whole markdown source (every line, not just the first) round-trips verbatim.
    #expect(row.copyText == body)
  }

  @Test func streamingMessageStillCopiesText() {
    let row = ChatRow(
      id: UUID(),
      kind: .message(role: .assistant, text: "partial answer", isComplete: false)
    )
    #expect(row.copyText == "partial answer")
  }

  @Test func toolPrefersResultText() {
    let row = ChatRow(
      id: UUID(),
      kind: .tool(
        name: "bash",
        title: "Ran command",
        state: .complete,
        detail: ToolDetail(argsText: "ls", resultText: "file-a\nfile-b"),
        durationS: 1.2
      )
    )
    // Full multi-line result text, not just the title.
    #expect(row.copyText == "file-a\nfile-b")
  }

  @Test func toolFallsBackToTitleThenName() {
    let titleOnly = ChatRow(
      id: UUID(),
      kind: .tool(name: "bash", title: "Ran command", state: .running, detail: nil, durationS: nil)
    )
    #expect(titleOnly.copyText == "Ran command")

    let nameOnly = ChatRow(
      id: UUID(),
      kind: .tool(name: "bash", title: "", state: .running, detail: ToolDetail(), durationS: nil)
    )
    #expect(nameOnly.copyText == "bash")
  }

  @Test func statusCopiesText() {
    let row = ChatRow(id: UUID(), kind: .status(kind: "search", text: "searching the web…"))
    #expect(row.copyText == "searching the web…")
  }
}
