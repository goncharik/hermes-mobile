import Testing

@testable import HermesKit

struct MarkdownSegmentTests {
  @Test func plainProseIsOneSegment() {
    #expect(MarkdownSegment.parse("hello world") == [.prose("hello world")])
  }

  @Test func fencedCodeSplitsFromProse() {
    let text = """
    Here is code:
    ```
    let x = 1
    print(x)
    ```
    Done.
    """
    #expect(MarkdownSegment.parse(text) == [
      .prose("Here is code:"),
      .code(text: "let x = 1\nprint(x)", language: nil),
      .prose("Done."),
    ])
  }

  @Test func languageHintOnFenceIsCaptured() {
    let text = "```swift\nlet x = 1\n```"
    #expect(MarkdownSegment.parse(text) == [.code(text: "let x = 1", language: "swift")])
  }

  @Test func unterminatedFenceTreatsRemainderAsCode() {
    let text = "intro\n```\nstreaming code"
    #expect(MarkdownSegment.parse(text) == [
      .prose("intro"),
      .code(text: "streaming code", language: nil),
    ])
  }

  @Test func emptyProseSegmentsAreOmitted() {
    // Blank lines around a fence shouldn't yield empty prose segments.
    let text = "\n\n```\ncode\n```\n\n"
    #expect(MarkdownSegment.parse(text) == [.code(text: "code", language: nil)])
  }

  @Test func multipleCodeBlocksKeepRawTextAndLanguages() {
    let text = """
    one
    ```bash
    echo hi
    ```
    two
    ```
    plain
    ```
    """
    #expect(MarkdownSegment.parse(text) == [
      .prose("one"),
      .code(text: "echo hi", language: "bash"),
      .prose("two"),
      .code(text: "plain", language: nil),
    ])
  }

  @Test func codeWhitespaceIsPreservedExactly() {
    // Indentation and blank lines inside a fence must round-trip for copy fidelity.
    let text = "```\n  indented\n\n    deeper\n```"
    #expect(MarkdownSegment.parse(text) == [
      .code(text: "  indented\n\n    deeper", language: nil),
    ])
  }

  // MARK: - Headers

  @Test func headersOfEachLevelParse() {
    let text = """
    # H1
    ## H2
    ### H3
    #### H4
    ##### H5
    ###### H6
    """
    #expect(MarkdownSegment.parse(text) == [
      .heading(level: 1, text: "H1"),
      .heading(level: 2, text: "H2"),
      .heading(level: 3, text: "H3"),
      .heading(level: 4, text: "H4"),
      .heading(level: 5, text: "H5"),
      .heading(level: 6, text: "H6"),
    ])
  }

  @Test func headerWithTrailingHashesAndExtraSpacesIsStripped() {
    #expect(MarkdownSegment.parse("##   Title  ##  ") == [.heading(level: 2, text: "Title")])
  }

  @Test func sevenHashesIsNotAHeader() {
    #expect(MarkdownSegment.parse("####### too deep") == [.prose("####### too deep")])
  }

  @Test func hashWithoutSpaceIsProse() {
    #expect(MarkdownSegment.parse("#nospace") == [.prose("#nospace")])
  }

  @Test func headerInlineMarkdownTextIsKept() {
    #expect(MarkdownSegment.parse("## A **bold** title") == [.heading(level: 2, text: "A **bold** title")])
  }

  // MARK: - Blockquotes

  @Test func multiLineBlockquoteIsOneBlock() {
    let text = """
    > first
    > second
    > third
    """
    #expect(MarkdownSegment.parse(text) == [.blockquote(text: "first\nsecond\nthird")])
  }

  @Test func blockquoteSeparatedByBlankLineSplitsIntoTwo() {
    // A blank line breaks the consecutive `>` run; lazy continuation is not supported.
    let text = """
    > one

    > two
    """
    #expect(MarkdownSegment.parse(text) == [
      .blockquote(text: "one"),
      .blockquote(text: "two"),
    ])
  }

  @Test func blockquoteMarkerWithoutSpaceStillStrips() {
    #expect(MarkdownSegment.parse(">tight") == [.blockquote(text: "tight")])
  }

  @Test func blockquoteSurroundedByProse() {
    let text = """
    intro
    > quoted
    outro
    """
    #expect(MarkdownSegment.parse(text) == [
      .prose("intro"),
      .blockquote(text: "quoted"),
      .prose("outro"),
    ])
  }

  // MARK: - Tables

  @Test func fullTableParsesHeadersAndRows() {
    let text = """
    | Name | Age |
    | --- | --- |
    | Alice | 30 |
    | Bob | 25 |
    """
    #expect(MarkdownSegment.parse(text) == [
      .table(headers: ["Name", "Age"], rows: [["Alice", "30"], ["Bob", "25"]]),
    ])
  }

  @Test func tableWithAlignmentColonsInSeparator() {
    let text = """
    | a | b |
    | :-- | --: |
    | 1 | 2 |
    """
    #expect(MarkdownSegment.parse(text) == [
      .table(headers: ["a", "b"], rows: [["1", "2"]]),
    ])
  }

  @Test func pipeRowWithoutSeparatorIsProse() {
    let text = """
    | a | b |
    | 1 | 2 |
    """
    #expect(MarkdownSegment.parse(text) == [.prose("| a | b |\n| 1 | 2 |")])
  }

  @Test func tableWithSurroundingProse() {
    let text = """
    Results:
    | k | v |
    | - | - |
    | x | 1 |
    Done.
    """
    #expect(MarkdownSegment.parse(text) == [
      .prose("Results:"),
      .table(headers: ["k", "v"], rows: [["x", "1"]]),
      .prose("Done."),
    ])
  }

  @Test func tableWithNoBodyRows() {
    let text = """
    | h1 | h2 |
    | --- | --- |
    """
    #expect(MarkdownSegment.parse(text) == [
      .table(headers: ["h1", "h2"], rows: []),
    ])
  }

  // MARK: - Precedence and mixed documents

  @Test func fencedCodeWithSpecialCharsStaysCode() {
    let text = """
    ```
    # not a heading
    > not a quote
    | not | a table |
    ```
    """
    #expect(MarkdownSegment.parse(text) == [
      .code(text: "# not a heading\n> not a quote\n| not | a table |", language: nil),
    ])
  }

  @Test func mixedDocumentParsesInOrder() {
    let text = """
    Intro paragraph.
    ## Section
    | col | val |
    | --- | --- |
    | a | 1 |
    ```swift
    let x = 1
    ```
    - item one
    - item two
    > a quote
    """
    #expect(MarkdownSegment.parse(text) == [
      .prose("Intro paragraph."),
      .heading(level: 2, text: "Section"),
      .table(headers: ["col", "val"], rows: [["a", "1"]]),
      .code(text: "let x = 1", language: "swift"),
      .prose("- item one\n- item two"),
      .blockquote(text: "a quote"),
    ])
  }
}
