import CoreGraphics
import Testing

@testable import supacode

struct CanvasSpatialNavigationTests {
  private typealias Entry = CanvasSpatialNavigation.CardEntry

  // Layout used by most tests:
  //
  //   A(0,0)   B(200,0)
  //   C(0,200) D(200,200)
  //
  private let grid = [
    Entry(id: "A", center: CGPoint(x: 0, y: 0)),
    Entry(id: "B", center: CGPoint(x: 200, y: 0)),
    Entry(id: "C", center: CGPoint(x: 0, y: 200)),
    Entry(id: "D", center: CGPoint(x: 200, y: 200)),
  ]

  // MARK: - Basic directional movement

  @Test func rightFromTopLeft() {
    let result = CanvasSpatialNavigation.nearest(from: "A", direction: .moveRight, cards: grid)
    #expect(result == "B")
  }

  @Test func leftFromTopRight() {
    let result = CanvasSpatialNavigation.nearest(from: "B", direction: .moveLeft, cards: grid)
    #expect(result == "A")
  }

  @Test func downFromTopLeft() {
    let result = CanvasSpatialNavigation.nearest(from: "A", direction: .moveDown, cards: grid)
    #expect(result == "C")
  }

  @Test func upFromBottomLeft() {
    let result = CanvasSpatialNavigation.nearest(from: "C", direction: .moveUp, cards: grid)
    #expect(result == "A")
  }

  @Test func downFromTopRight() {
    let result = CanvasSpatialNavigation.nearest(from: "B", direction: .moveDown, cards: grid)
    #expect(result == "D")
  }

  @Test func upFromBottomRight() {
    let result = CanvasSpatialNavigation.nearest(from: "D", direction: .moveUp, cards: grid)
    #expect(result == "B")
  }

  // MARK: - No candidate in direction

  @Test func leftFromLeftmostReturnsNil() {
    let result = CanvasSpatialNavigation.nearest(from: "A", direction: .moveLeft, cards: grid)
    #expect(result == nil)
  }

  @Test func upFromTopmostReturnsNil() {
    let result = CanvasSpatialNavigation.nearest(from: "A", direction: .moveUp, cards: grid)
    #expect(result == nil)
  }

  @Test func rightFromRightmostReturnsNil() {
    let result = CanvasSpatialNavigation.nearest(from: "D", direction: .moveRight, cards: grid)
    #expect(result == nil)
  }

  @Test func downFromBottommostReturnsNil() {
    let result = CanvasSpatialNavigation.nearest(from: "D", direction: .moveDown, cards: grid)
    #expect(result == nil)
  }

  // MARK: - Weighted distance favors primary axis

  @Test func rightPrefersAlignedOverDiagonal() {
    // E is directly right, F is far right but also far down.
    let cards = [
      Entry(id: "O", center: CGPoint(x: 0, y: 0)),
      Entry(id: "E", center: CGPoint(x: 100, y: 10)),
      Entry(id: "F", center: CGPoint(x: 110, y: 300)),
    ]
    let result = CanvasSpatialNavigation.nearest(from: "O", direction: .moveRight, cards: cards)
    #expect(result == "E")
  }

  @Test func downPrefersAlignedOverDiagonal() {
    let cards = [
      Entry(id: "O", center: CGPoint(x: 0, y: 0)),
      Entry(id: "E", center: CGPoint(x: 10, y: 100)),
      Entry(id: "F", center: CGPoint(x: 300, y: 110)),
    ]
    let result = CanvasSpatialNavigation.nearest(from: "O", direction: .moveDown, cards: cards)
    #expect(result == "E")
  }

  // MARK: - Single card

  @Test func singleCardReturnsNilForAllDirections() {
    let cards = [Entry(id: "X", center: CGPoint(x: 50, y: 50))]
    for direction: CanvasNavigationDirection in [.moveUp, .moveDown, .moveLeft, .moveRight] {
      let result = CanvasSpatialNavigation.nearest(from: "X", direction: direction, cards: cards)
      #expect(result == nil)
    }
  }

  // MARK: - Unknown current ID

  @Test func unknownCurrentIDReturnsNil() {
    let result = CanvasSpatialNavigation.nearest(from: "MISSING", direction: .moveRight, cards: grid)
    #expect(result == nil)
  }

  // MARK: - Empty cards

  @Test func emptyCardsReturnsNil() {
    let result = CanvasSpatialNavigation.nearest(from: "A", direction: .moveRight, cards: [])
    #expect(result == nil)
  }

  // MARK: - Three-in-a-row (horizontal strip)

  @Test func horizontalStripNavigatesCorrectly() {
    let cards = [
      Entry(id: "L", center: CGPoint(x: 0, y: 0)),
      Entry(id: "M", center: CGPoint(x: 200, y: 0)),
      Entry(id: "R", center: CGPoint(x: 400, y: 0)),
    ]
    #expect(CanvasSpatialNavigation.nearest(from: "L", direction: .moveRight, cards: cards) == "M")
    #expect(CanvasSpatialNavigation.nearest(from: "M", direction: .moveRight, cards: cards) == "R")
    #expect(CanvasSpatialNavigation.nearest(from: "R", direction: .moveLeft, cards: cards) == "M")
    #expect(CanvasSpatialNavigation.nearest(from: "M", direction: .moveLeft, cards: cards) == "L")
    #expect(CanvasSpatialNavigation.nearest(from: "L", direction: .moveUp, cards: cards) == nil)
    #expect(CanvasSpatialNavigation.nearest(from: "L", direction: .moveDown, cards: cards) == nil)
  }

  // MARK: - Three-in-a-column (vertical strip)

  @Test func verticalStripNavigatesCorrectly() {
    let cards = [
      Entry(id: "T", center: CGPoint(x: 0, y: 0)),
      Entry(id: "M", center: CGPoint(x: 0, y: 200)),
      Entry(id: "B", center: CGPoint(x: 0, y: 400)),
    ]
    #expect(CanvasSpatialNavigation.nearest(from: "T", direction: .moveDown, cards: cards) == "M")
    #expect(CanvasSpatialNavigation.nearest(from: "M", direction: .moveDown, cards: cards) == "B")
    #expect(CanvasSpatialNavigation.nearest(from: "B", direction: .moveUp, cards: cards) == "M")
    #expect(CanvasSpatialNavigation.nearest(from: "M", direction: .moveUp, cards: cards) == "T")
    #expect(CanvasSpatialNavigation.nearest(from: "T", direction: .moveLeft, cards: cards) == nil)
    #expect(CanvasSpatialNavigation.nearest(from: "T", direction: .moveRight, cards: cards) == nil)
  }

  // MARK: - Asymmetric grid (3 columns, 2 rows)

  @Test func wideGridNavigation() {
    //   A(0,0)   B(200,0)   C(400,0)
    //   D(0,200) E(200,200) F(400,200)
    let cards = [
      Entry(id: "A", center: CGPoint(x: 0, y: 0)),
      Entry(id: "B", center: CGPoint(x: 200, y: 0)),
      Entry(id: "C", center: CGPoint(x: 400, y: 0)),
      Entry(id: "D", center: CGPoint(x: 0, y: 200)),
      Entry(id: "E", center: CGPoint(x: 200, y: 200)),
      Entry(id: "F", center: CGPoint(x: 400, y: 200)),
    ]
    #expect(CanvasSpatialNavigation.nearest(from: "B", direction: .moveDown, cards: cards) == "E")
    #expect(CanvasSpatialNavigation.nearest(from: "E", direction: .moveUp, cards: cards) == "B")
    #expect(CanvasSpatialNavigation.nearest(from: "A", direction: .moveRight, cards: cards) == "B")
    #expect(CanvasSpatialNavigation.nearest(from: "C", direction: .moveLeft, cards: cards) == "B")
    #expect(CanvasSpatialNavigation.nearest(from: "D", direction: .moveRight, cards: cards) == "E")
    #expect(CanvasSpatialNavigation.nearest(from: "F", direction: .moveLeft, cards: cards) == "E")
  }

  // MARK: - Cards at same primary-axis position

  @Test func twoCardsDirectlyBelowPicksNearest() {
    let cards = [
      Entry(id: "O", center: CGPoint(x: 100, y: 0)),
      Entry(id: "N", center: CGPoint(x: 100, y: 100)),
      Entry(id: "F", center: CGPoint(x: 100, y: 300)),
    ]
    let result = CanvasSpatialNavigation.nearest(from: "O", direction: .moveDown, cards: cards)
    #expect(result == "N")
  }

  // MARK: - Slight offset (waterfall-like layout)

  @Test func waterfallLayoutNavigatesDown() {
    // Waterfall: second column is slightly offset vertically.
    let cards = [
      Entry(id: "A", center: CGPoint(x: 0, y: 0)),
      Entry(id: "B", center: CGPoint(x: 200, y: 30)),
      Entry(id: "C", center: CGPoint(x: 0, y: 250)),
      Entry(id: "D", center: CGPoint(x: 200, y: 220)),
    ]
    #expect(CanvasSpatialNavigation.nearest(from: "A", direction: .moveRight, cards: cards) == "B")
    #expect(CanvasSpatialNavigation.nearest(from: "A", direction: .moveDown, cards: cards) == "C")
    #expect(CanvasSpatialNavigation.nearest(from: "B", direction: .moveDown, cards: cards) == "D")
  }
}
