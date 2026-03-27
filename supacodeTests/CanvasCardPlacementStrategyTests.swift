import CoreGraphics
import Testing

@testable import supacode

struct CanvasCardPlacementStrategyTests {
  private let spacing: CGFloat = 20
  private let titleBarHeight: CGFloat = 28
  private let defaultSize = CanvasCardLayout.defaultSize

  @Test func worktreeInteriorChoosesRightmostCandidate() {
    let cards = [
      CanvasCardPlacementStrategy.CardDescriptor(key: "left", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "right", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "new", worktreeID: "w1"),
    ]
    let layouts: [String: CanvasCardLayout] = [
      "left": layout(centerX: 400, centerY: 289),
      "right": layout(centerX: 3200, centerY: 289),
    ]

    let placement = CanvasCardPlacementStrategy.nextLayout(
      for: .init(key: "new", worktreeID: "w1"),
      cards: cards,
      layouts: layouts,
      defaultSize: defaultSize,
      titleBarHeight: titleBarHeight,
      spacing: spacing
    )

    #expect(placement.position.x == 2380)
    #expect(placement.position.y == 289)
  }

  @Test func worktreeRegionIsPreferredAndSideTieBreaksToRight() {
    let cards = [
      CanvasCardPlacementStrategy.CardDescriptor(key: "w1-existing", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "w2-a", worktreeID: "w2"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "w2-b", worktreeID: "w2"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "w1-new", worktreeID: "w1"),
    ]
    let layouts: [String: CanvasCardLayout] = [
      "w1-existing": layout(centerX: 400, centerY: 289),
      "w2-a": layout(centerX: 3200, centerY: 289),
      "w2-b": layout(centerX: 3200, centerY: 887),
    ]

    let placement = CanvasCardPlacementStrategy.nextLayout(
      for: .init(key: "w1-new", worktreeID: "w1"),
      cards: cards,
      layouts: layouts,
      defaultSize: defaultSize,
      titleBarHeight: titleBarHeight,
      spacing: spacing
    )

    #expect(placement.position.x == 1220)
    #expect(placement.position.y == 289)
  }

  @Test func globalEqualBoundsTieBreaksToHorizontalGrowth() {
    let equalSize = CGSize(width: 400, height: 372) // +28 title bar => 400x400 bounding rect
    let cards = [
      CanvasCardPlacementStrategy.CardDescriptor(key: "w1-existing", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "w2-new", worktreeID: "w2"),
    ]
    let layouts: [String: CanvasCardLayout] = [
      "w1-existing": CanvasCardLayout(
        position: CGPoint(x: 200, y: 200),
        size: equalSize
      )
    ]

    let placement = CanvasCardPlacementStrategy.nextLayout(
      for: .init(key: "w2-new", worktreeID: "w2"),
      cards: cards,
      layouts: layouts,
      defaultSize: defaultSize,
      titleBarHeight: titleBarHeight,
      spacing: spacing
    )

    #expect(placement.position.x == 820)
  }

  @Test func globalGrowthUsesSmallerDimensionDirection() {
    let cards = [
      CanvasCardPlacementStrategy.CardDescriptor(key: "w1-existing", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "w2-new", worktreeID: "w2"),
    ]
    let layouts: [String: CanvasCardLayout] = [
      "w1-existing": layout(centerX: 400, centerY: 289)
    ]

    let placement = CanvasCardPlacementStrategy.nextLayout(
      for: .init(key: "w2-new", worktreeID: "w2"),
      cards: cards,
      layouts: layouts,
      defaultSize: defaultSize,
      titleBarHeight: titleBarHeight,
      spacing: spacing
    )

    #expect(placement.position.x == 400)
    #expect(placement.position.y == 1019)
  }

  @Test func singleWorktreeSequentialTabsDoesNotKeepGrowingRight() {
    let cards = [
      CanvasCardPlacementStrategy.CardDescriptor(key: "first", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "second", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "third", worktreeID: "w1"),
    ]
    var layouts: [String: CanvasCardLayout] = [
      "first": layout(centerX: 400, centerY: 289)
    ]

    let second = CanvasCardPlacementStrategy.nextLayout(
      for: .init(key: "second", worktreeID: "w1"),
      cards: cards,
      layouts: layouts,
      defaultSize: defaultSize,
      titleBarHeight: titleBarHeight,
      spacing: spacing
    )
    layouts["second"] = second

    let third = CanvasCardPlacementStrategy.nextLayout(
      for: .init(key: "third", worktreeID: "w1"),
      cards: cards,
      layouts: layouts,
      defaultSize: defaultSize,
      titleBarHeight: titleBarHeight,
      spacing: spacing
    )

    #expect(second.position.x == 1220)
    #expect(second.position.y == 289)
    #expect(third.position.x == 400)
    #expect(third.position.y == 1019)
  }

  @Test func directionalHintPlacesCardNextToAnchor() {
    let cards = [
      CanvasCardPlacementStrategy.CardDescriptor(key: "anchor", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "new", worktreeID: "w1"),
    ]
    let layouts: [String: CanvasCardLayout] = [
      "anchor": layout(centerX: 400, centerY: 289)
    ]

    let placement = CanvasCardPlacementStrategy.nextLayout(
      for: .init(key: "new", worktreeID: "w1"),
      cards: cards,
      layouts: layouts,
      defaultSize: defaultSize,
      titleBarHeight: titleBarHeight,
      spacing: spacing,
      directionalHint: .init(anchorKey: "anchor", direction: .right)
    )

    #expect(placement.position.x == 1220)
    #expect(placement.position.y == 289)
  }

  @Test func directionalHintSkipsBlockedSlotInChosenDirection() {
    let cards = [
      CanvasCardPlacementStrategy.CardDescriptor(key: "anchor", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "blocker", worktreeID: "w1"),
      CanvasCardPlacementStrategy.CardDescriptor(key: "new", worktreeID: "w1"),
    ]
    let layouts: [String: CanvasCardLayout] = [
      "anchor": layout(centerX: 400, centerY: 289),
      "blocker": layout(centerX: 1220, centerY: 289),
    ]

    let placement = CanvasCardPlacementStrategy.nextLayout(
      for: .init(key: "new", worktreeID: "w1"),
      cards: cards,
      layouts: layouts,
      defaultSize: defaultSize,
      titleBarHeight: titleBarHeight,
      spacing: spacing,
      directionalHint: .init(anchorKey: "anchor", direction: .right)
    )

    #expect(placement.position.x == 2040)
    #expect(placement.position.y == 289)
  }

  private func layout(centerX: CGFloat, centerY: CGFloat) -> CanvasCardLayout {
    CanvasCardLayout(
      position: CGPoint(x: centerX, y: centerY),
      size: defaultSize
    )
  }
}
