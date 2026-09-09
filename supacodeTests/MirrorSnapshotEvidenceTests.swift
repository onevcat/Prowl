import Foundation
import Testing

@testable import supacode

struct MirrorSnapshotEvidenceTests {
  @Test func claudeSoftwareCursorRequiresTheWholeComposerToBeEmpty() throws {
    let prefix = "\u{1B}[?25l\u{1B}[?2004h───\r\n"
    let suffix = "\r\n───\u{1B}[2;3H"
    let empty = "❯\u{00A0}\u{1B}[7m \u{1B}[0m"
    let parsed = try #require(MirrorSnapshotEvidence.read(frame(prefix + empty + suffix)))
    #expect(!parsed.cursorVisible)
    #expect(parsed.hasEmptyClaudeComposer)
    for draft in [
      empty + "draft", empty + " ", "❯\u{00A0}\u{1B}[7mx\u{1B}[0m",
      "❯\u{00A0} ", empty + "\r\nsecond line", "❯\u{00A0}\u{1B}[7;8m \u{1B}[0m",
    ] {
      let evidence = try #require(MirrorSnapshotEvidence.read(frame(prefix + draft + suffix)))
      #expect(!evidence.hasEmptyClaudeComposer)
    }
    let unbordered = try #require(MirrorSnapshotEvidence.read(frame(empty + "\u{1B}[1;3H")))
    #expect(!unbordered.hasEmptyClaudeComposer)
  }

  private func frame(_ text: String) -> MirrorFrame {
    MirrorFrame(columns: 80, rows: 24, bytes: Data(text.utf8))
  }

  @Test func sameTextAndCursorStillDistinguishPlaceholderFromDraft() throws {
    // The real 0.153.4 probe typed the placeholder and used Ctrl-A; Ctrl-K
    // then restored the identical text and cursor, with SGR 2 as the difference.
    let prefix = "\u{1B}[1m›\u{1B}[22m "
    let suffix = "Ask Codex to do anything\u{1B}[0m\u{1B}[1;3H"
    let draft = try #require(MirrorSnapshotEvidence.read(frame(prefix + suffix)))
    let placeholder = try #require(
      MirrorSnapshotEvidence.read(frame(prefix + "\u{1B}[2m" + suffix)))
    #expect(draft.cursorRow == placeholder.cursorRow)
    #expect(draft.cursorColumn == placeholder.cursorColumn)
    #expect(draft.lines[0].map(\.text).joined() == placeholder.lines[0].map(\.text).joined())
    #expect(draft.lines[0].last?.style.faint == false)
    #expect(placeholder.lines[0].last?.style.faint == true)
    #expect(draft.codexPlaceholder == nil)
    #expect(placeholder.codexPlaceholder == "Ask Codex to do anything")
  }

  @Test(arguments: [
    "\u{1B}[?25l\u{1B}[1m›\u{1B}[22m \u{1B}[2mAsk\u{1B}[1;3H",
    "\u{1B}[2m› Ask\u{1B}[1;3H",
    "\u{1B}[1m›\u{1B}[22m \u{1B}[2mAsk\u{1B}[1;4H",
    "\u{1B}[1m›\u{1B}[22m \u{1B}[2;7mAsk\u{1B}[1;3H",
    "\u{1B}[1m›\u{1B}[22m \u{1B}[2;8mAsk\u{1B}[1;3H",
    "\u{1B}[1m›\u{1B}[22m \u{1B}[2mAsk\u{1B}[22m draft\u{1B}[1;3H",
    "\u{1B}[1m›\u{1B}[22m   \u{1B}[1;3H",
  ])
  func hiddenDisabledMovedOrEditedComposerHasNoPlaceholderEvidence(_ text: String) throws {
    let evidence = try #require(MirrorSnapshotEvidence.read(frame(text)))
    #expect(evidence.codexPlaceholder == nil)
  }

  @Test func colorsDoNotBecomeStyleFlagsAndUnicodeIsPreserved() throws {
    let value = try #require(
      MirrorSnapshotEvidence.read(
        frame(
          "\u{1B}]4;2;rgb:00/00/00\u{1B}\\\u{1B}[?2004h\u{1B}[?25l"
            + "\u{1B}[38;2;2;1;8m你好 e\u{301} 🌍\u{1B}[48;5;2m text\r\n"
            + "\u{1B}[2mplaceholder\u{1B}[22m normal\u{1B}[2;3H")))
    #expect(!value.cursorVisible)
    #expect(value.bracketedPaste)
    #expect(value.lines.count == 2)
    #expect(value.lines[0].map(\.text).joined() == "你好 e\u{301} 🌍 text")
    #expect(value.lines[0].allSatisfy { !$0.style.faint && !$0.style.bold && !$0.style.invisible })
    #expect(value.lines[1].first?.style.faint == true)
    #expect(value.lines[1].last?.style.faint == false)
  }

  @Test(arguments: [
    "text", "\u{1B}[1;3Htext", "text\u{1B}[1;3H\u{1B}[2;3H",
    "\u{1B}[38;2;1;2mtext\u{1B}[1;3H", "\u{1B}[38;2;1;2;256mtext\u{1B}[1;3H",
    "\u{1B}[999mtext\u{1B}[1;3H", "\u{1B}]8;;unterminated",
    "text\u{1B}[K\u{1B}[1;3H", "text\n\u{1B}[1;3H", "text\r\u{1B}[1;3H",
    "text\u{1B}[0;3H", "text\u{1B}[25;3H", "text\u{1B}[1;81H",
    "text\u{1B}[?25l\u{1B}[1;3H", "text\u{85}\u{1B}[1;3H",
  ])
  func malformedOrNonSnapshotOutputCannotAuthorizeInput(_ text: String) {
    #expect(MirrorSnapshotEvidence.read(frame(text)) == nil)
  }

  @Test func parsingHasExplicitResourceBounds() {
    #expect(MirrorSnapshotEvidence.read(frame(String(repeating: "x", count: 1_048_577))) == nil)
    #expect(
      MirrorSnapshotEvidence.read(frame(String(repeating: "\r\n", count: 24) + "\u{1B}[1;3H"))
        == nil)
    #expect(
      MirrorSnapshotEvidence.read(
        frame(String(repeating: "\u{1B}[2mx", count: 32_769) + "\u{1B}[1;3H")) == nil)
    #expect(
      MirrorSnapshotEvidence.read(MirrorFrame(columns: 80, rows: 24, bytes: Data([0xFF]))) == nil)
  }
}
