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

  @Test func rowsKeepShortBlocksWholeAndSplitLongTextIntoChunks() {
    let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
    let document = MirrorDocument("intro\n```\ncode\n```\n" + long)
    #expect(
      document.rows.map(\.id) == [
        .init(block: 0, chunk: 0), .init(block: 1, chunk: 0), .init(block: 2, chunk: 0),
        .init(block: 2, chunk: 1),
      ])
    #expect(document.rows[0].chunk == nil)
    #expect(document.rows[1].chunk == nil)
    #expect(document.rows[2...].map { $0.chunk?.raw ?? "" }.joined() == long)
    #expect(document.rows[2...].allSatisfy { $0.block == document.blocks[2] })
  }
}
