import Testing

@testable import ProwlMirror_iOS

struct MirrorDocumentTests {
  @Test func parsesCodeAndTablesButKeepsAmbiguousTerminalText() {
    let document = MirrorDocument(
      "Thinking…\n```swift\nlet value = 1\n```\n| A | B |\n| --- | --- |\n| 1 | 2 |")
    #expect(document.blocks.count == 3)
    #expect(document.blocks[1] == .code(1, "swift", "let value = 1"))
    if case .table(_, _, let rows) = document.blocks[2] {
      #expect(rows == [["A", "B"], ["1", "2"]])
    } else {
      Issue.record("Expected a table")
    }
    let ambiguous = "| escaped \\| pipe | other |\n| --- | --- |"
    #expect(MirrorDocument(ambiguous).blocks == [.text(0, ambiguous)])
  }

  @Test func unfinishedFenceAndDeletionDoNotAccumulateOldBlocks() {
    #expect(MirrorDocument("```\npartial").blocks == [.code(0, "", "partial")])
    #expect(MirrorDocument("").blocks == [.text(0, "")])
    #expect(MirrorDocument("done").blocks == [.text(0, "done")])
  }
}
