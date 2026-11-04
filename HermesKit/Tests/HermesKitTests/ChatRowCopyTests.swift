import Foundation
import Testing

@testable import HermesKit

/// `ChatRow.copyText` is the single source of plain text the `.copyRow(id:)` context-menu
/// puts on the pasteboard (#27b — agent responses must be fully copyable). These cover the
/// message and tool branches; the reasoning branch is covered by `TurnTimerAndReasoningRowTests`.
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

  /// File references are linkified RENDER-side only (a `MEDIA:/a/b.png` tag shows as `b.png`
  /// in the transcript): the row's copy text and a fenced block's copy source stay the raw
  /// markdown, tag and path included.
  @Test func fileReferencesCopyRawSource() {
    let body = "Saved to /home/e/out/report.pdf and MEDIA:/a/b.png\n\n```sh\nopen MEDIA:/a/b.png\n```"
    let row = ChatRow(
      id: UUID(),
      kind: .message(role: .assistant, text: body, isComplete: true)
    )
    #expect(row.copyText == body)
    // The code-block copy button hands `CodeBlockView` the parsed segment's text verbatim.
    #expect(MarkdownSegment.parse(body).contains(.code(text: "open MEDIA:/a/b.png", language: "sh")))
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

  @Test func commandOutputCopiesText() {
    let row = ChatRow(
      id: UUID(),
      kind: .commandOutput(text: "Session compressed.\n12 messages → 3 summaries")
    )
    #expect(row.copyText == "Session compressed.\n12 messages → 3 summaries")
  }
}
