import Foundation
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

  @Test func deeplyNestedFenceKeepsItsRelativeIndentation() {
    let text = "- Deploy\n    - Check the flag\n        ```python\n        if enabled:\n            print(\"ready\")\n        ```"
    let blocks = MirrorMarkdown.parse(text)
    #expect(
      blocks == [
        .list([
          .init(marker: .bullet, depth: 0, text: "Deploy"),
          .init(marker: .bullet, depth: 2, text: "Check the flag"),
        ]),
        .code(language: "python", text: "if enabled:\n    print(\"ready\")"),
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

  @MainActor private func links(in text: String) -> [(text: String, url: String)] {
    let attributed = MirrorMarkdownCache.shared.inline(for: text)
    return attributed.runs.compactMap { run in
      run.link.map { (String(attributed[run.range].characters), $0.absoluteString.removingPercentEncoding ?? "") }
    }
  }

  @Test @MainActor func autolinksEndAtCJKPunctuation() {
    let found = links(in: "改动都在 PR #1183（https://github.com/onevcat/Prowl/pull/1183）里，标题已经更新。")
    #expect(found.count == 1)
    #expect(found.first?.text == "https://github.com/onevcat/Prowl/pull/1183")
    #expect(found.first?.url == "https://github.com/onevcat/Prowl/pull/1183")

    let www = links(in: "见 www.example.com/a。下一步")
    #expect(www.first?.text == "www.example.com/a")
    #expect(www.first?.url == "http://www.example.com/a")
  }

  @Test @MainActor func explicitLinksAndNonPunctuationAutolinksStay() {
    let explicit = links(in: "看 [这里（全文）](https://example.com/a)。")
    #expect(explicit.first?.text == "这里（全文）")
    #expect(explicit.first?.url == "https://example.com/a")

    let wiki = links(in: "见 https://zh.wikipedia.org/wiki/猫 吧")
    #expect(wiki.first?.text == "https://zh.wikipedia.org/wiki/猫")
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
