import Testing

@testable import HermesKit

/// Ports the desktop's `speech-text.test.ts` fixtures (upstream @ `69f73ec5f1`) plus the
/// shared identifier corpus, so the phone, desktop, and server normalizer say the same thing.
struct SpeechTextTests {
  // MARK: Code, links, URLs, MEDIA tokens

  @Test func fencedCodeIsSilenceAndItsColonCloses() {
    #expect(SpeechText.sanitize("Here is code:\n```ts\nconst x = 1\n```\nDone.") == "Here is code. Done.")
  }

  @Test func inlineCodeKeepsItsContents() {
    #expect(SpeechText.sanitize("Use `git status` after the change.") == "Use git status after the change.")
  }

  @Test func unterminatedFenceRunsToTheEnd() {
    #expect(SpeechText.sanitize("Run this:\n```bash\nls -la") == "Run this.")
  }

  @Test func colonBeforeCodeBlockClosesAsPeriod() {
    #expect(
      SpeechText.sanitize("One line added to the regex list:\n```ts\nconst x = 1\n```\nBye.")
        == "One line added to the regex list. Bye.")
  }

  @Test func colonEndingTheTextCloses() {
    #expect(SpeechText.sanitize("The regex list:") == "The regex list.")
  }

  @Test func colonOrphanedByAStrippedMediaTokenCloses() {
    #expect(SpeechText.sanitize("The file is below: MEDIA:/tmp/x.py") == "The file is below.")
  }

  @Test func linkKeepsLabelAndBareURLIsSilence() {
    #expect(
      SpeechText.sanitize("Read [the docs](https://example.com/docs) or https://example.org/x now.")
        == "Read the docs or now.")
    #expect(SpeechText.sanitize("See https://example.com/a-huge-page for details") == "See for details")
  }

  @Test func mediaTokensAreSilence() {
    let text = "The files are below.\nMEDIA:/Users/ricardo/Documents/inference-server-shopping-list.xlsx\nBye."
    #expect(SpeechText.sanitize(text) == "The files are below. Bye.")
  }

  @Test func mediaTokenKeepsTheSentenceFinalPeriod() {
    #expect(SpeechText.sanitize("See MEDIA:/tmp/report-2026-q3.xlsx. Then reply.") == "See. Then reply.")
    #expect(SpeechText.sanitize("The file MEDIA:/x.py. Done.") == "The file. Done.")
  }

  // MARK: Thinking prefix, emoji, markup

  @Test func thinkingPrefixIsDropped() {
    #expect(SpeechText.sanitize("(pause) Thinking... The answer is 42.") == "The answer is 42.")
    #expect(SpeechText.sanitize("Reasoning...\nHere it is.") == "Here it is.")
  }

  @Test func emojiRunsIncludingVS16AndZWJAreDropped() {
    #expect(
      SpeechText.sanitize("Great work 👍🏽 and ❤️ plus 👨‍👩‍👧 done") == "Great work and plus done")
  }

  @Test func strikethroughKeepsItsWords() {
    #expect(SpeechText.sanitize("This ~~is~~ old.") == "This is old.")
  }

  @Test func headingMarkersAreDropped() {
    #expect(SpeechText.sanitize("## Summary") == "Summary")
  }

  /// Line breaks are flattened before the bullet rule runs, so (as on desktop) only a
  /// leading marker is stripped; inner `-`/`+` markers stay as pauses, `*` is markup.
  @Test func nestedBulletsMirrorDesktop() {
    #expect(SpeechText.sanitize("- one\n  - nested\n+ three") == "one - nested + three")
    #expect(SpeechText.sanitize("* one\n  * nested") == "one nested")
  }

  @Test func orderedListNumbersStay() {
    #expect(SpeechText.sanitize("1. First\n2. Second") == "1. First 2. Second")
  }

  @Test func pipeInProseIsNotATable() {
    let text = "Use the summary first | keep the table on screen when it matters."
    #expect(SpeechText.sanitize(text) == text)
  }

  // MARK: Line breaks

  @Test func hyphenAcrossALineBreakJoins() {
    #expect(SpeechText.sanitize("This is a long hyphen-\nated word.") == "This is a long hyphenated word.")
  }

  @Test func punctuatedParagraphBreakDoesNotDuplicatePunctuation() {
    #expect(SpeechText.sanitize("First sentence.\n\nSecond sentence.") == "First sentence. Second sentence.")
  }

  @Test func plainParagraphBreakBecomesASentenceBreak() {
    #expect(SpeechText.sanitize("First line\n\nSecond line") == "First line. Second line")
  }

  @Test func crlfIsNormalized() {
    #expect(SpeechText.sanitize("First line\r\n\r\nSecond line\r\nend") == "First line. Second line end")
  }

  @Test(arguments: [
    ("**First sentence.**\n\nSecond sentence.", "First sentence. Second sentence."),
    ("“First sentence.”\n\nSecond sentence.", "“First sentence.” Second sentence."),
    ("(First sentence.)\n\nSecond sentence.", "(First sentence.) Second sentence."),
  ])
  func punctuationIsNotDuplicatedAfterClosers(text: String, expected: String) {
    #expect(SpeechText.sanitize(text) == expected)
  }

  // MARK: Tables

  @Test func tableIsReadAsItsHeader() {
    let text = """
      Here is the quick takeaway: the totals remain unchanged.

      | Item | Value | Notes |
      | --- | ---: | --- |
      | Example A | 10 | first row |
      | Example B | 20 | second row |

      Full detail stays visible on screen.
      """
    #expect(
      SpeechText.sanitize(text)
        == "Here is the quick takeaway: the totals remain unchanged. Item, Value, Notes. Full detail stays visible on screen."
    )
  }

  @Test func nonEnglishReplyGetsNoEnglishWords() {
    let text = """
      对比如下：

      | 模型 | 价格 |
      | --- | ---: |
      | 甲 | 10 |

      代码：
      ```py
      print(1)
      ```
      详情见 https://example.com/docs
      """
    let spoken = SpeechText.sanitize(text)
    #expect(spoken.contains("模型, 价格"))
    #expect(!spoken.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) })
  }

  @Test func emptyHeaderTableIsSilence() {
    let text = """
      Before the table.

      |   |   |
      | --- | --- |
      | a | b |

      After the table.
      """
    #expect(SpeechText.sanitize(text) == "Before the table. After the table.")
  }

  @Test func tableWithoutOuterPipesIsReadAsItsHeader() {
    let text = """
      Main takeaway: total is unchanged.

      Item | Value
      --- | ---:
      Example A | 10
      Example B | 20

      Done.
      """
    #expect(SpeechText.sanitize(text) == "Main takeaway: total is unchanged. Item, Value. Done.")
  }

  @Test func tableInsideABlockquoteIsReadAsItsHeader() {
    let text = """
      Before the table.

      > | Item | Value |
      > | --- | ---: |
      > | Example A | 10 |
      > | Example B | 20 |

      After the table.
      """
    #expect(SpeechText.sanitize(text) == "Before the table. Item, Value. After the table.")
  }

  @Test func blockquoteMarkerPaddingPlusThreeSpacesIsATable() {
    let text = """
      Before the table.

      >    | Item | Value |
      >    | --- | ---: |
      >    | Example A | 10 |

      After the table.
      """
    #expect(SpeechText.sanitize(text) == "Before the table. Item, Value. After the table.")
  }

  @Test func explicitSingleColumnTable() {
    let text = """
      Before the table.

      | Item |
      | --- |
      | Example A |

      After the table.
      """
    #expect(SpeechText.sanitize(text) == "Before the table. Item. After the table.")
  }

  @Test func rowsOutsideTheTableBlockquoteStay() {
    let text = """
      > | Item | Value |
      > | --- | ---: |
      > | Example A | 10 |
      Outside | prose
      """
    #expect(SpeechText.sanitize(text) == "Item, Value. Outside | prose")
  }

  @Test func mismatchedColumnCountIsNotATable() {
    let text = """
      Heading | Detail
      --- | --- | ---
      Keep this prose.
      """
    #expect(SpeechText.sanitize(text).contains("Heading | Detail"))
  }

  @Test func bodyRowsWithOtherCellCountsAreStillSkipped() {
    let text = """
      Before the table.

      | Item | Value |
      | --- | ---: |
      | Example A |
      | Example B | 20 | ignored |

      After the table.
      """
    #expect(SpeechText.sanitize(text) == "Before the table. Item, Value. After the table.")
  }

  @Test func escapedPipeInHeader() {
    let text = """
      Before the table.

      | Item \\| detail | Value |
      | --- | ---: |
      | Example A | 10 |

      After the table.
      """
    #expect(SpeechText.sanitize(text) == "Before the table. Item detail, Value. After the table.")
  }

  @Test func indentedCodeResemblingATableStays() {
    let text = "    Item | Value\n    --- | ---\n    Example A | 10"
    #expect(SpeechText.sanitize(text).contains("Item | Value"))
  }

  // MARK: Identifier corpus (hermes-agent tests/fixtures/identifier_speech_corpus.json)

  @Test(arguments: [
    (
      "Saved peyton-sample-20260922.wav and peyton-sample-20260922.ogg.",
      ["peyton", "20260922", ".wav", ".ogg"], ["Saved", "and"]
    ),
    (
      "The digest is sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 for the file.",
      ["e3b0c442", "7852b855", "sha256:"], ["The digest is", "for the file"]
    ),
    ("Commit 73688014f78 landed.", ["73688014f78"], ["Commit", "landed"]),
    (
      "Trace id 550e8400-e29b-41d4-a716-446655440000 appears once.",
      ["550e8400", "446655440000"], ["Trace id", "appears once"]
    ),
    (
      "Model meta-llama/Llama-3.3-70B-Instruct is large.",
      ["meta-llama/Llama-3.3-70B-Instruct", "70B"], ["Model", "is large"]
    ),
    (
      "Config at ~/.config/hermes/config.yaml was read.",
      ["config.yaml", "~/.config"], ["Config at", "was read"]
    ),
    ("Version v2.1.0-beta.3 shipped.", ["v2.1.0-beta.3"], ["Version", "shipped"]),
  ])
  func identifierTokensBecomeSilence(text: String, mustNotContain: [String], mustContain: [String]) {
    let spoken = SpeechText.sanitize(text)
    for fragment in mustNotContain {
      #expect(!spoken.contains(fragment), "\(fragment) spoken in \(spoken)")
    }
    for fragment in mustContain {
      #expect(spoken.contains(fragment), "\(fragment) missing from \(spoken)")
    }
  }

  @Test(arguments: [
    ("The samples played cleanly, so listen again.", ["The samples played cleanly, so listen again"]),
    ("Use git status after the change.", ["Use git status after the change"]),
    ("Email me at user@example.com.", ["user@example.com"]),
    ("COVID-19 and well-known facts stay.", ["COVID-19", "well-known"]),
    ("Due 2026/06/02 and status N/A here.", ["2026/06/02", "N/A"]),
    ("The final score was 3:2.", ["3:2"]),
  ])
  func ordinaryTokensPassThrough(text: String, mustContain: [String]) {
    let spoken = SpeechText.sanitize(text)
    for fragment in mustContain {
      #expect(spoken.contains(fragment), "\(fragment) missing from \(spoken)")
    }
  }

  // MARK: Edge cases

  @Test(arguments: ["", "   ", " \n\t\n "])
  func blankInputIsEmpty(text: String) {
    #expect(SpeechText.sanitize(text) == "")
  }

  @Test(arguments: [
    "```swift\nlet x = 1\n```",
    "https://example.com/path",
    "MEDIA:/tmp/report.pdf",
    "🎉🎉",
  ])
  func unspeakableOnlyInputIsEmpty(text: String) {
    #expect(SpeechText.sanitize(text) == "")
  }

  @Test func mixedReplyEndToEnd() {
    let text = """
      ## Summary

      I updated **two** files in `config.yaml`. See [the guide](https://example.com/guide) for details 🎉.

      | Key | Default |
      | --- | --- |
      | port | 8080 |

      That's it!
      """
    #expect(
      SpeechText.sanitize(text)
        // `config.yaml.` is one identifier token (the class includes `.`), so its sentence
        // period goes with it — same on desktop.
        == "Summary. I updated two files in See the guide for details . Key, Default. That's it!")
  }
}
