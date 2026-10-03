import CoreGraphics
import Testing

@testable import ProwlMirror_iOS

struct MirrorReadingAnchorTests {
  private let rowTops: [MirrorDocument.Row.ID: CGFloat] = [
    .init(block: 0, chunk: 0): 16, .init(block: 1, chunk: 0): 120, .init(block: 1, chunk: 1): 400,
  ]

  @Test func anchorIsTheLastRowThatStartsAtOrAboveTheVisibleTop() {
    #expect(
      MirrorReadingAnchor(top: 250, rowTops: rowTops)
        == .init(row: .init(block: 1, chunk: 0), offset: 130))
    #expect(
      MirrorReadingAnchor(top: 400, rowTops: rowTops)
        == .init(row: .init(block: 1, chunk: 1), offset: 0))
  }

  @Test func anchorUsesTheFirstRowWhenNoRowStartsAboveTheVisibleTop() {
    #expect(
      MirrorReadingAnchor(top: 0, rowTops: rowTops)
        == .init(row: .init(block: 0, chunk: 0), offset: -16))
    #expect(MirrorReadingAnchor(top: 0, rowTops: [:]) == nil)
  }

  @Test func rowsWithTheSameTopUseTheLaterRow() {
    let empty: [MirrorDocument.Row.ID: CGFloat] = [
      .init(block: 0, chunk: 0): 16, .init(block: 1, chunk: 0): 16, .init(block: 2, chunk: 0): 16,
    ]
    #expect(
      MirrorReadingAnchor(top: 20, rowTops: empty)
        == .init(row: .init(block: 2, chunk: 0), offset: 4))
  }
}
