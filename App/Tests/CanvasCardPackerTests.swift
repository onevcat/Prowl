import CoreGraphics
import Testing

@testable import supacode

struct CanvasCardPackerTests {
  private let packer = CanvasCardPacker(spacing: 20, titleBarHeight: 28)

  private func card(_ key: String, width: CGFloat = 800, height: CGFloat = 550) -> CanvasCardPacker.CardInfo {
    CanvasCardPacker.CardInfo(key: key, size: CGSize(width: width, height: height))
  }

  // MARK: - Basic packing

  @Test func singleCardPacks() throws {
    let result = packer.pack(cards: [card("a")], targetRatio: 16.0 / 9.0)

    let layout = try #require(result.layouts["a"])
    #expect(layout.size == CGSize(width: 800, height: 550))
    #expect(result.boundingSize.width > 0)
    #expect(result.boundingSize.height > 0)
  }

  @Test func preservesOriginalCardSizes() {
    let cards = [
      card("a", width: 600, height: 400),
      card("b", width: 800, height: 300),
    ]
    let result = packer.pack(cards: cards, targetRatio: 1.5)

    #expect(result.layouts["a"]?.size == CGSize(width: 600, height: 400))
    #expect(result.layouts["b"]?.size == CGSize(width: 800, height: 300))
  }

  @Test func allCardsArePlaced() {
    let cards = (0..<5).map { card("card\($0)") }
    let result = packer.pack(cards: cards, targetRatio: 16.0 / 9.0)
    #expect(result.layouts.count == 5)
  }

  // MARK: - Scale maximization

  @Test func threeEqualCardsUseTwoColumns() throws {
    // 3 equal default-size cards on 16:9 viewport.
    // 2 columns gives the best scale; waterfall distributes them 2+1.
    let cards = (0..<3).map { card("card\($0)") }
    let result = packer.pack(cards: cards, targetRatio: 16.0 / 9.0)

    let card0 = try #require(result.layouts["card0"])
    let card1 = try #require(result.layouts["card1"])
    let card2 = try #require(result.layouts["card2"])

    // Waterfall: card0 → col0, card1 → col1, card2 → col0 (shortest).
    #expect(card0.position.y == card1.position.y)
    #expect(card0.position.x != card1.position.x)
    #expect(card2.position.y > card0.position.y)
  }

  @Test func fourUniformCardsFormTwoByTwo() throws {
    // 4 equal cards, square target → 2 columns, 2 per column.
    let cards = (0..<4).map { card("card\($0)", width: 400, height: 400) }
    let result = packer.pack(cards: cards, targetRatio: 1.0)

    let card0 = try #require(result.layouts["card0"])
    let card1 = try #require(result.layouts["card1"])
    let card2 = try #require(result.layouts["card2"])
    let card3 = try #require(result.layouts["card3"])

    // Waterfall: card0→col0, card1→col1, card2→col0, card3→col1
    #expect(card0.position.x == card2.position.x)
    #expect(card1.position.x == card3.position.x)
    #expect(card0.position.y < card2.position.y)
    #expect(card1.position.y < card3.position.y)
  }

  // MARK: - Waterfall gap filling

  @Test func shortCardFillsGapBesideTallCard() throws {
    // One tall card + two short cards. Waterfall should place short cards
    // beside the tall card instead of waiting for the "row" to finish.
    let cards = [
      card("tall", width: 800, height: 800),
      card("short1", width: 800, height: 300),
      card("short2", width: 800, height: 300),
    ]
    let result = packer.pack(cards: cards, targetRatio: 16.0 / 9.0)

    let tall = try #require(result.layouts["tall"])
    let short2 = try #require(result.layouts["short2"])

    // With 2 columns: tall→col0, short1→col1, short2→col1 (stacks in col1).
    // short2 should end within the tall card's height range, not below it.
    let tallBottom = tall.position.y + (tall.size.height + 28) / 2
    let short2Bottom = short2.position.y + (short2.size.height + 28) / 2
    #expect(short2Bottom <= tallBottom + 1, "short2 should fill gap beside tall card")
  }

  // MARK: - Mixed widths (row-break strategy)

  @Test func wideAndNarrowCardsUseRowBreak() throws {
    // 1 wide + 2 narrow cards with enough total width that single-row is
    // too wide. Row-break [wide][n1+n2] gives best scale by using the
    // narrow cards' actual width instead of max-width columns.
    let cards = [
      card("wide", width: 1000, height: 550),
      card("narrow1", width: 600, height: 550),
      card("narrow2", width: 600, height: 550),
    ]
    let result = packer.pack(cards: cards, targetRatio: 16.0 / 9.0)

    let narrow1 = try #require(result.layouts["narrow1"])
    let narrow2 = try #require(result.layouts["narrow2"])

    // Row-break should place narrow cards side by side on their own row.
    #expect(narrow1.position.y == narrow2.position.y)
    #expect(narrow1.position.x != narrow2.position.x)
    // Bounding width should use actual card widths, not max-width columns.
    #expect(result.boundingSize.width < 1500)
  }

  // MARK: - No overlap

  @Test func cardsDoNotOverlap() {
    let cards = [
      card("a", width: 600, height: 400),
      card("b", width: 800, height: 300),
      card("c", width: 500, height: 500),
      card("d", width: 700, height: 350),
    ]
    let result = packer.pack(cards: cards, targetRatio: 1.5)

    let rects = result.layouts.map { (_, layout) -> CGRect in
      CGRect(
        x: layout.position.x - layout.size.width / 2,
        y: layout.position.y - (layout.size.height + 28) / 2,
        width: layout.size.width,
        height: layout.size.height + 28
      )
    }

    for outer in 0..<rects.count {
      for inner in (outer + 1)..<rects.count {
        let insetA = rects[outer].insetBy(dx: 1, dy: 1)
        let insetB = rects[inner].insetBy(dx: 1, dy: 1)
        #expect(!insetA.intersects(insetB), "Cards \(outer) and \(inner) overlap")
      }
    }
  }

  // MARK: - Edge cases

  @Test func emptyCardsReturnsEmptyResult() {
    let result = packer.pack(cards: [], targetRatio: 1.5)
    #expect(result.layouts.isEmpty)
    #expect(result.boundingSize == .zero)
  }

  // MARK: - Spacing

  @Test func columnsHaveMinimumSpacing() throws {
    let cards = [
      card("a", width: 600, height: 400),
      card("b", width: 600, height: 400),
    ]
    // Wide target → 2 columns.
    let result = packer.pack(cards: cards, targetRatio: 3.0)

    let layoutA = try #require(result.layouts["a"])
    let layoutB = try #require(result.layouts["b"])

    // Cards in different columns should have spacing between column edges.
    #expect(layoutA.position.x != layoutB.position.x)
    let colWidth: CGFloat = 600
    let aRight = layoutA.position.x + colWidth / 2
    let bLeft = layoutB.position.x - colWidth / 2
    #expect(bLeft - aRight >= 20 - 1, "Column gap too small: \(bLeft - aRight)")
  }

  @Test func cardsInSameColumnHaveMinimumSpacing() throws {
    let cards = [
      card("a", width: 800, height: 400),
      card("b", width: 800, height: 400),
    ]
    // Narrow target → 1 column, stacked.
    let result = packer.pack(cards: cards, targetRatio: 0.5)

    let layoutA = try #require(result.layouts["a"])
    let layoutB = try #require(result.layouts["b"])

    let aBottom = layoutA.position.y + (layoutA.size.height + 28) / 2
    let bTop = layoutB.position.y - (layoutB.size.height + 28) / 2
    #expect(bTop - aBottom >= 20 - 1, "Vertical gap too small: \(bTop - aBottom)")
  }
}
