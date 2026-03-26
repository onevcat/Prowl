import CoreGraphics
import Foundation

enum CanvasCardPlacementStrategy {
  struct CardDescriptor: Equatable, Sendable {
    let key: String
    let worktreeID: String
  }

  static func nextLayout(
    for target: CardDescriptor,
    cards: [CardDescriptor],
    layouts: [String: CanvasCardLayout],
    defaultSize: CGSize,
    titleBarHeight: CGFloat,
    spacing: CGFloat
  ) -> CanvasCardLayout {
    let visibleKeys = Set(cards.map(\.key))
    let positionedKeys = visibleKeys.filter { layouts[$0] != nil }
    let positionedLayouts = positionedKeys.reduce(into: [String: CanvasCardLayout]()) { partial, key in
      if let layout = layouts[key] {
        partial[key] = layout
      }
    }
    let occupiedRects = positionedLayouts.values.map {
      cardRect(layout: $0, titleBarHeight: titleBarHeight)
    }

    let targetSize = CGSize(width: defaultSize.width, height: defaultSize.height + titleBarHeight)
    if let placement = placeInWorktreeRegion(
      target: target,
      cards: cards,
      positionedLayouts: positionedLayouts,
      occupiedRects: occupiedRects,
      titleBarHeight: titleBarHeight,
      targetSize: targetSize,
      spacing: spacing
    ) {
      return CanvasCardLayout(position: placement, size: defaultSize)
    }

    if let globalBounds = bounds(
      for: cards.map(\.key),
      layouts: positionedLayouts,
      titleBarHeight: titleBarHeight
    ) {
      if let center = findInteriorSlot(
        in: globalBounds,
        occupiedRects: occupiedRects,
        targetSize: targetSize,
        spacing: spacing
      ) {
        return CanvasCardLayout(position: center, size: defaultSize)
      }

      if let center = placeByGlobalGrowthDirection(
        from: globalBounds,
        occupiedRects: occupiedRects,
        targetSize: targetSize,
        spacing: spacing
      ) {
        return CanvasCardLayout(position: center, size: defaultSize)
      }
    }

    return CanvasCardLayout(
      position: CGPoint(
        x: spacing + defaultSize.width / 2,
        y: spacing + targetSize.height / 2
      ),
      size: defaultSize
    )
  }

  private static func placeInWorktreeRegion(
    target: CardDescriptor,
    cards: [CardDescriptor],
    positionedLayouts: [String: CanvasCardLayout],
    occupiedRects: [CGRect],
    titleBarHeight: CGFloat,
    targetSize: CGSize,
    spacing: CGFloat
  ) -> CGPoint? {
    let worktreeKeys = cards
      .filter { $0.worktreeID == target.worktreeID }
      .map(\.key)
    let positionedWorktreeCount = worktreeKeys.reduce(into: 0) { count, key in
      if positionedLayouts[key] != nil {
        count += 1
      }
    }

    guard let worktreeBounds = bounds(
      for: worktreeKeys,
      layouts: positionedLayouts,
      titleBarHeight: titleBarHeight
    )
    else { return nil }

    if let center = findInteriorSlot(
      in: worktreeBounds,
      occupiedRects: occupiedRects,
      targetSize: targetSize,
      spacing: spacing
    ) {
      return center
    }

    return findWorktreeSideSlot(
      around: worktreeBounds,
      positionedWorktreeCount: positionedWorktreeCount,
      occupiedRects: occupiedRects,
      targetSize: targetSize,
      spacing: spacing
    )
  }

  private static func bounds(
    for keys: [String],
    layouts: [String: CanvasCardLayout],
    titleBarHeight: CGFloat
  ) -> CGRect? {
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity

    for key in keys {
      guard let layout = layouts[key] else { continue }
      let rect = cardRect(layout: layout, titleBarHeight: titleBarHeight)
      minX = min(minX, rect.minX)
      minY = min(minY, rect.minY)
      maxX = max(maxX, rect.maxX)
      maxY = max(maxY, rect.maxY)
    }

    guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private static func cardRect(layout: CanvasCardLayout, titleBarHeight: CGFloat) -> CGRect {
    let totalSize = CGSize(width: layout.size.width, height: layout.size.height + titleBarHeight)
    return CGRect(
      x: layout.position.x - totalSize.width / 2,
      y: layout.position.y - totalSize.height / 2,
      width: totalSize.width,
      height: totalSize.height
    )
  }

  private static func findInteriorSlot(
    in bounds: CGRect,
    occupiedRects: [CGRect],
    targetSize: CGSize,
    spacing: CGFloat
  ) -> CGPoint? {
    let halfW = targetSize.width / 2
    let halfH = targetSize.height / 2
    let minX = bounds.minX + halfW
    let maxX = bounds.maxX - halfW
    let minY = bounds.minY + halfH
    let maxY = bounds.maxY - halfH
    guard minX <= maxX, minY <= maxY else { return nil }

    let xCandidates = candidateAxisValues(
      occupiedRects: occupiedRects,
      min: minX,
      max: maxX,
      half: halfW,
      spacing: spacing,
      useX: true
    ).sorted(by: >)
    let yCandidates = candidateAxisValues(
      occupiedRects: occupiedRects,
      min: minY,
      max: maxY,
      half: halfH,
      spacing: spacing,
      useX: false
    ).sorted()

    let paddedOccupied = occupiedRects.map { $0.insetBy(dx: -spacing, dy: -spacing) }
    for x in xCandidates {
      for y in yCandidates {
        let rect = CGRect(
          x: x - halfW,
          y: y - halfH,
          width: targetSize.width,
          height: targetSize.height
        )
        guard bounds.contains(rect) else { continue }
        if paddedOccupied.allSatisfy({ !$0.intersects(rect) }) {
          return CGPoint(x: x, y: y)
        }
      }
    }
    return nil
  }

  private static func findWorktreeSideSlot(
    around bounds: CGRect,
    positionedWorktreeCount: Int,
    occupiedRects: [CGRect],
    targetSize: CGSize,
    spacing: CGFloat
  ) -> CGPoint? {
    let halfW = targetSize.width / 2
    let halfH = targetSize.height / 2
    let paddedOccupied = occupiedRects.map { $0.insetBy(dx: -spacing, dy: -spacing) }

    let growHorizontally = bounds.width <= bounds.height
    let sidePriority: [Side] =
      if positionedWorktreeCount <= 1 {
        [.right, .down, .up, .left]
      } else if growHorizontally {
        [.right, .left, .down, .up]
      } else {
        [.down, .up, .right, .left]
      }

    let yPrimary =
      if positionedWorktreeCount <= 1 {
        bounds.midY
      } else if growHorizontally {
        bounds.minY + halfH
      } else {
        bounds.midY
      }
    let xPrimary =
      if positionedWorktreeCount <= 1 {
        bounds.midX
      } else if growHorizontally {
        bounds.midX
      } else {
        bounds.minX + halfW
      }

    let yCandidates = sideAxisCandidates(
      occupiedRects: occupiedRects,
      primary: yPrimary,
      half: halfH,
      spacing: spacing,
      useX: false
    )
    let xCandidates = sideAxisCandidates(
      occupiedRects: occupiedRects,
      primary: xPrimary,
      half: halfW,
      spacing: spacing,
      useX: true
    )

    let sideCenters: [(side: Side, center: CGPoint)] = {
      var result: [(Side, CGPoint)] = []
      for y in yCandidates {
        result.append((.right, CGPoint(x: bounds.maxX + spacing + halfW, y: y)))
      }
      for x in xCandidates {
        result.append((.down, CGPoint(x: x, y: bounds.maxY + spacing + halfH)))
      }
      for x in xCandidates {
        result.append((.up, CGPoint(x: x, y: bounds.minY - spacing - halfH)))
      }
      for y in yCandidates {
        result.append((.left, CGPoint(x: bounds.minX - spacing - halfW, y: y)))
      }
      return result
    }()

    for side in sidePriority {
      for entry in sideCenters where entry.side == side {
        let center = entry.center
        let rect = CGRect(
          x: center.x - halfW,
          y: center.y - halfH,
          width: targetSize.width,
          height: targetSize.height
        )
        if paddedOccupied.allSatisfy({ !$0.intersects(rect) }) {
          return center
        }
      }
    }
    return nil
  }

  private static func placeByGlobalGrowthDirection(
    from globalBounds: CGRect,
    occupiedRects: [CGRect],
    targetSize: CGSize,
    spacing: CGFloat
  ) -> CGPoint? {
    let growHorizontally = globalBounds.width <= globalBounds.height
    let halfW = targetSize.width / 2
    let halfH = targetSize.height / 2
    let paddedOccupied = occupiedRects.map { $0.insetBy(dx: -spacing, dy: -spacing) }

    if growHorizontally {
      let yCandidates = sideAxisCandidates(
        occupiedRects: occupiedRects,
        primary: globalBounds.minY + halfH,
        half: halfH,
        spacing: spacing,
        useX: false
      )
      let xCandidates = [
        globalBounds.maxX + spacing + halfW,
        globalBounds.minX - spacing - halfW,
      ]
      for x in xCandidates {
        for y in yCandidates {
          let rect = CGRect(
            x: x - halfW,
            y: y - halfH,
            width: targetSize.width,
            height: targetSize.height
          )
          if paddedOccupied.allSatisfy({ !$0.intersects(rect) }) {
            return CGPoint(x: x, y: y)
          }
        }
      }
    } else {
      let xCandidates = sideAxisCandidates(
        occupiedRects: occupiedRects,
        primary: globalBounds.minX + halfW,
        half: halfW,
        spacing: spacing,
        useX: true
      )
      let yCandidates = [
        globalBounds.maxY + spacing + halfH,
        globalBounds.minY - spacing - halfH,
      ]
      for y in yCandidates {
        for x in xCandidates {
          let rect = CGRect(
            x: x - halfW,
            y: y - halfH,
            width: targetSize.width,
            height: targetSize.height
          )
          if paddedOccupied.allSatisfy({ !$0.intersects(rect) }) {
            return CGPoint(x: x, y: y)
          }
        }
      }
    }

    return nil
  }

  private static func candidateAxisValues(
    occupiedRects: [CGRect],
    min: CGFloat,
    max: CGFloat,
    half: CGFloat,
    spacing: CGFloat,
    useX: Bool
  ) -> [CGFloat] {
    var values: [CGFloat] = [min, max, (min + max) / 2]
    for rect in occupiedRects {
      if useX {
        values.append(rect.minX - spacing - half)
        values.append(rect.maxX + spacing + half)
      } else {
        values.append(rect.minY - spacing - half)
        values.append(rect.maxY + spacing + half)
      }
    }
    return deduplicatedClamped(values, min: min, max: max)
  }

  private static func sideAxisCandidates(
    occupiedRects: [CGRect],
    primary: CGFloat,
    half: CGFloat,
    spacing: CGFloat,
    useX: Bool
  ) -> [CGFloat] {
    var values: [CGFloat] = [primary]
    for rect in occupiedRects {
      if useX {
        values.append(rect.minX - spacing - half)
        values.append(rect.maxX + spacing + half)
        values.append(rect.midX)
      } else {
        values.append(rect.minY - spacing - half)
        values.append(rect.maxY + spacing + half)
        values.append(rect.midY)
      }
    }
    return deduplicated(values)
      .sorted { abs($0 - primary) < abs($1 - primary) }
  }

  private static func deduplicatedClamped(
    _ values: [CGFloat],
    min: CGFloat,
    max: CGFloat
  ) -> [CGFloat] {
    deduplicated(values.map { Swift.max(min, Swift.min(max, $0)) })
  }

  private static func deduplicated(_ values: [CGFloat], tolerance: CGFloat = 0.5) -> [CGFloat] {
    var result: [CGFloat] = []
    for value in values {
      if result.contains(where: { abs($0 - value) <= tolerance }) {
        continue
      }
      result.append(value)
    }
    return result
  }

  private enum Side: Equatable {
    case right
    case down
    case up
    case left
  }
}
