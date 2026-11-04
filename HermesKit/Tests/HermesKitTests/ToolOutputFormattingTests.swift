import Foundation
import Testing

@testable import HermesKit

/// `ToolOutputFormatting` (tool-call display plan, Task 10): output cleaning (ANSI, `\r`
/// rewrites, blank edges), the inline 12-line / 2 000-character cap with its truncated flag,
/// and the edit-diff parser over both shapes the server sends — the rendered `inline_diff`
/// (`agent/display.py` `_render_inline_unified_diff`) and a raw unified diff.
struct ToolOutputFormattingTests {
  private let esc = "\u{1B}"

  // MARK: - clean

  @Test func cleanStripsANSIAndKeepsIndentation() {
    let raw = "\(esc)[32m  ok\(esc)[0m line\n    indented\n"
    #expect(ToolOutputFormatting.clean(raw) == "  ok line\n    indented")
  }

  @Test func cleanCollapsesCarriageReturnRewrites() {
    // A progress bar rewrites its line with `\r`; a terminal ends up showing the last frame.
    let raw = "Downloading 10%\rDownloading 55%\rDownloading 100%\ndone\r\n"
    #expect(ToolOutputFormatting.clean(raw) == "Downloading 100%\ndone")
  }

  @Test func cleanDropsBlankLeadingLinesAndTrailingWhitespace() {
    #expect(ToolOutputFormatting.clean("\n  \n\tfirst\nlast  \n\n") == "\tfirst\nlast")
  }

  @Test(arguments: [nil, "", "   ", "\n\n", "\u{1B}[0m\u{1B}[2K"])
  func cleanReturnsNilWhenNothingVisible(_ raw: String?) {
    #expect(ToolOutputFormatting.clean(raw) == nil)
  }

  @Test func cleanHandlesANSIHeavyOutput() {
    let line = "\(esc)[1;38;2;255;215;0m█\(esc)[0m\(esc)[2K\(esc)[1G"
    let raw = String(repeating: line, count: 500) + "\n\(esc)]0;title\u{07}tail"
    let cleaned = ToolOutputFormatting.clean(raw)
    #expect(cleaned == String(repeating: "█", count: 500) + "\ntail")
  }

  // MARK: - cap

  @Test func capKeepsShortTextWhole() {
    let capped = ToolOutputFormatting.cap("a\nb\nc")
    #expect(capped == CappedText(text: "a\nb\nc", isTruncated: false))
  }

  @Test func capCutsAtTwelveLines() {
    let text = (1...40).map { "line \($0)" }.joined(separator: "\n")
    let capped = ToolOutputFormatting.cap(text)
    #expect(capped.isTruncated)
    #expect(capped.text == (1...12).map { "line \($0)" }.joined(separator: "\n"))
  }

  @Test func capExactlyTwelveLinesIsNotTruncated() {
    let text = (1...12).map { "line \($0)" }.joined(separator: "\n")
    #expect(ToolOutputFormatting.cap(text) == CappedText(text: text, isTruncated: false))
    // Trailing blank lines past the cap are not "more" output.
    #expect(ToolOutputFormatting.cap(text + "\n\n  \n").isTruncated == false)
  }

  @Test func capCutsALongSingleLineAtTwoThousandCharacters() {
    let text = String(repeating: "x", count: 50_000)
    let capped = ToolOutputFormatting.cap(text)
    #expect(capped.isTruncated)
    #expect(capped.text.count == 2_000)
  }

  @Test func capOnHugeOutputReturnsOnlyTheHead() {
    let text = (1...200_000).map { "row \($0) " + String(repeating: "-", count: 40) }.joined(separator: "\n")
    let capped = ToolOutputFormatting.cap(text)
    #expect(capped.isTruncated)
    #expect(capped.text.split(separator: "\n").count <= ToolOutputFormatting.inlineLineLimit)
    #expect(capped.text.count <= ToolOutputFormatting.inlineCharacterLimit)
    #expect(capped.text.hasPrefix("row 1 "))
  }

  @Test func capHonoursCustomLimits() {
    #expect(ToolOutputFormatting.cap("a\nb\nc", lines: 2) == CappedText(text: "a\nb", isTruncated: true))
    #expect(ToolOutputFormatting.cap("abcdef", characters: 3) == CappedText(text: "abc", isTruncated: true))
    #expect(ToolOutputFormatting.cap("abc", lines: 0) == CappedText(text: "", isTruncated: true))
    #expect(ToolOutputFormatting.cap("", lines: 0) == CappedText(text: "", isTruncated: false))
  }

  @Test func capCountsCRLFAsOneLineBreak() {
    let capped = ToolOutputFormatting.cap("a\r\nb\r\nc", lines: 2)
    #expect(capped.isTruncated)
    #expect(capped.text == "a\r\nb")
  }

  // MARK: - diffLines

  @Test func parsesTheRenderedInlineDiff() {
    // `tool_progress._prepare_tool_result_metadata` → `render_edit_diff_with_delta`: the
    // review header, an ANSI `a/x → b/x` file line, colored hunk / -/+ / context lines.
    let diff = [
      "  ┊ review diff",
      "\(esc)[38;5;250ma/src/App.swift → b/src/App.swift\(esc)[0m",
      "\(esc)[36m@@ -1,3 +1,3 @@\(esc)[0m",
      "\(esc)[2m import Foundation\(esc)[0m",
      "\(esc)[31m-let a = 1\(esc)[0m",
      "\(esc)[32m+let a = 2\(esc)[0m",
      "\(esc)[2m \(esc)[0m",
      "\(esc)[36m… 40 diff line(s) omitted\(esc)[0m",
    ].joined(separator: "\n")
    #expect(ToolOutputFormatting.diffLines(diff) == [
      DiffLine(kind: .file, text: "src/App.swift"),
      DiffLine(kind: .hunk, text: "@@ -1,3 +1,3 @@"),
      DiffLine(kind: .context, text: "import Foundation"),
      DiffLine(kind: .removed, text: "let a = 1"),
      DiffLine(kind: .added, text: "let a = 2"),
      DiffLine(kind: .context, text: ""),
      DiffLine(kind: .note, text: "… 40 diff line(s) omitted"),
    ])
  }

  @Test func parsesALocalizedReviewHeader() {
    let diff = "  ┊ Review-Diff\na/x.py → b/x.py\n+print(1)"
    #expect(ToolOutputFormatting.diffLines(diff) == [
      DiffLine(kind: .file, text: "x.py"),
      DiffLine(kind: .added, text: "print(1)"),
    ])
  }

  @Test func parsesARawUnifiedDiff() {
    let diff = """
      --- a/repo/main.py\t2026-11-04 10:00:00
      +++ b/repo/main.py\t2026-11-04 10:00:01
      @@ -1 +1 @@
      -old
      +new
      \\ No newline at end of file
      """
    #expect(ToolOutputFormatting.diffLines(diff) == [
      DiffLine(kind: .file, text: "repo/main.py"),
      DiffLine(kind: .hunk, text: "@@ -1 +1 @@"),
      DiffLine(kind: .removed, text: "old"),
      DiffLine(kind: .added, text: "new"),
      DiffLine(kind: .note, text: "\\ No newline at end of file"),
    ])
  }

  @Test func newAndDeletedFilesNameTheRealSide() {
    let created = "--- /dev/null\n+++ b/new.txt\n+hello"
    #expect(ToolOutputFormatting.diffLines(created).first == DiffLine(kind: .file, text: "new.txt"))
    let deleted = "--- a/gone.txt\n+++ /dev/null\n-bye"
    #expect(ToolOutputFormatting.diffLines(deleted).first == DiffLine(kind: .file, text: "gone.txt"))
    let renderedDeletion = "a/gone.txt → b/?\n-bye"
    #expect(ToolOutputFormatting.diffLines(renderedDeletion).first == DiffLine(kind: .file, text: "gone.txt"))
  }

  @Test func multiFileDiffKeepsEveryHeader() {
    let diff = "a/one.swift → b/one.swift\n+1\na/two.swift → b/two.swift\n-2"
    #expect(ToolOutputFormatting.diffLines(diff).filter { $0.kind == .file }.map(\.text) == ["one.swift", "two.swift"])
  }

  @Test func emptyDiffHasNoLines() {
    #expect(ToolOutputFormatting.diffLines("").isEmpty)
    #expect(ToolOutputFormatting.diffLines("  ┊ review diff\n").isEmpty)
  }

  @Test func diffPathReadsEitherShape() {
    #expect(ToolOutputFormatting.diffPath("  ┊ review diff\na/s/q.swift → b/s/q.swift\n@@") == "s/q.swift")
    #expect(ToolOutputFormatting.diffPath("--- a/s/q.swift\n+++ b/s/q.swift") == "s/q.swift")
    #expect(ToolOutputFormatting.diffPath("@@ -1 +1 @@\n-a\n+b") == nil)
    #expect(ToolOutputFormatting.diffPath(nil) == nil)
  }
}
