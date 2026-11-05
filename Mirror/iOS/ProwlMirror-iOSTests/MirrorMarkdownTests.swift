import Testing

@testable import ProwlMirror_iOS

struct MirrorMarkdownTests {
  @Test func headingsListsAndParagraphsBecomeBlocks() {
    let blocks = MirrorMarkdown.parse(
      """
      ## Day 1 — Higashiyama
      - 7:00 Kiyomizu-dera
      - Walk down **Sannenzaka**
        - nested stop
      1. first
      2) second
      - [x] done task

      Want me to add train times?
      """)
    #expect(blocks.count == 3)
    #expect(blocks[0] == .heading(level: 2, text: "Day 1 — Higashiyama"))
    guard case .list(let items) = blocks[1] else {
      Issue.record("expected a list, got \(blocks[1])")
      return
    }
    #expect(
      items.map(\.text) == [
        "7:00 Kiyomizu-dera", "Walk down **Sannenzaka**", "nested stop", "first", "second", "done task",
      ])
    #expect(items[2].depth == 1 && items[0].depth == 0)
    #expect(items[0].marker == .bullet)
    #expect(items[3].marker == .ordered(1) && items[4].marker == .ordered(2))
    #expect(items[5].marker == .task(done: true))
    #expect(blocks[2] == .paragraph("Want me to add train times?"))
  }

  @Test func fencedCodeKeepsItsTextAndLanguage() {
    let blocks = MirrorMarkdown.parse(
      """
      Run this:
      ```swift
      let a = 1
        - not a list
      ```
      """)
    #expect(blocks == [.paragraph("Run this:"), .code(language: "swift", text: "let a = 1\n  - not a list")])
  }

  @Test func unterminatedFenceRunsToTheEnd() {
    #expect(MirrorMarkdown.parse("```\nopen") == [.code(language: nil, text: "open")])
  }

  @Test func tablesQuotesAndRules() {
    let blocks = MirrorMarkdown.parse(
      """
      | Day | Area |
      | --- | :--- |
      | 1 | Higashiyama |
      | 2 | Arashiyama \\| west |

      > quoted
      > still quoted

      ---
      after
      """)
    #expect(
      blocks == [
        .table(header: ["Day", "Area"], rows: [["1", "Higashiyama"], ["2", "Arashiyama | west"]]),
        .quote("quoted\nstill quoted"),
        .rule,
        .paragraph("after"),
      ])
  }

  @Test func softLineBreaksStayInOneParagraph() {
    #expect(MirrorMarkdown.parse("one\ntwo\n\nthree") == [.paragraph("one\ntwo"), .paragraph("three")])
  }

  @Test func inlineTripleBackticksAreNotAFence() {
    #expect(
      MirrorMarkdown.parse("```swift build``` failed.\n\n- fix X")
        == [.paragraph("```swift build``` failed."), .list([.init(marker: .bullet, depth: 0, text: "fix X")])])
  }

  @Test func headingKeepsHashesThatBelongToTheText() {
    #expect(MirrorMarkdown.parse("## Migrating to C#") == [.heading(level: 2, text: "Migrating to C#")])
    #expect(MirrorMarkdown.parse("# #1 priority ##") == [.heading(level: 1, text: "#1 priority")])
  }

  @Test func fenceInsideAListItemIsACodeBlock() {
    let blocks = MirrorMarkdown.parse("1. Run:\n   ```bash\n   make test\n   ```\n2. Check")
    #expect(
      blocks == [
        .list([.init(marker: .ordered(1), depth: 0, text: "Run:")]),
        .code(language: "bash", text: "make test"),
        .list([.init(marker: .ordered(2), depth: 0, text: "Check")]),
      ])
  }

  @Test func onlyALongEnoughBareFenceCloses() {
    let blocks = MirrorMarkdown.parse("````md\n```swift\nlet a = 1\n```\n````\nafter")
    #expect(blocks == [.code(language: "md", text: "```swift\nlet a = 1\n```"), .paragraph("after")])
  }

  @Test func proseWithAPipeBeforeARuleIsNotATable() {
    #expect(MirrorMarkdown.parse("Use foo | bar to pipe output\n---") == [.paragraph("Use foo | bar to pipe output"), .rule])
  }

  @Test func delimiterMustMatchTheHeaderColumns() {
    #expect(MirrorMarkdown.parse("| a | b |\n| --- |") == [.paragraph("| a | b |\n| --- |")])
  }

  @Test func aPipeLineWithoutDelimiterRowIsAParagraph() {
    #expect(MirrorMarkdown.parse("a | b") == [.paragraph("a | b")])
  }
}

struct MirrorInjectedTextTests {
  @Test func launchProtocolIsSplitFromTheMessage() {
    let text = """
      Pick a color.

      ---
      Prowl dispatch completion protocol v1:
      Before ending this task, choose exactly one terminal outcome.
      """
    let split = MirrorInjectedText.split(text)
    #expect(split.message == "Pick a color.")
    #expect(split.injected?.hasPrefix("Prowl dispatch completion protocol v1:") == true)
  }

  @Test func truncatedLaunchProtocolIsStillFolded() {
    let split = MirrorInjectedText.split("Pick a color.\n\n---\nProwl dispatch compl")
    #expect(split.message == "Pick a color.")
    #expect(split.injected == "Prowl dispatch compl")
  }

  @Test func ordinaryRulesAreNotInjectedText() {
    let text = "Intro\n\n---\nMy own section"
    #expect(MirrorInjectedText.split(text).message == text)
    #expect(MirrorInjectedText.split(text).injected == nil)
  }
}
