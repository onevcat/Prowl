import CoreGraphics
import Foundation

struct CanvasCardLayout: Codable, Equatable, Hashable, Sendable {
  var positionX: CGFloat
  var positionY: CGFloat
  var width: CGFloat
  var height: CGFloat

  var position: CGPoint {
    get { CGPoint(x: positionX, y: positionY) }
    set {
      positionX = newValue.x
      positionY = newValue.y
    }
  }

  var size: CGSize {
    get { CGSize(width: width, height: height) }
    set {
      width = newValue.width
      height = newValue.height
    }
  }

  /// Card size used on small screens (≈14" MacBook Pro). On a small viewport
  /// the canvas must zoom out to fit a multi-card grid, which shrinks rendered
  /// text; smaller cards keep the fit-to-view scale — and thus text — larger.
  static let minDefaultSize = CGSize(width: 800, height: 550)
  /// Card size used on large screens (≈27" display and up), where fit-to-view
  /// caps at 1.0 so a larger card simply shows more content at native size.
  static let maxDefaultSize = CGSize(width: 1000, height: 680)
  /// Reference screen widths (logical points, default scaling) mapped to the
  /// interpolation endpoints above.
  static let minDefaultScreenWidth: CGFloat = 1512  // 14" MacBook Pro
  static let maxDefaultScreenWidth: CGFloat = 2560  // 27" / Studio Display

  /// Size new cards adopt when no explicit size is given. Equal to
  /// `maxDefaultSize`, used only for transient fallbacks; creation paths pass
  /// an explicit `adaptiveDefaultSize(forScreenWidth:)` instead.
  static let defaultSize = maxDefaultSize

  /// Linearly interpolate the default card size between `minDefaultSize`
  /// (14"-class screens) and `maxDefaultSize` (27"-class and larger) by screen
  /// width, clamped at both ends.
  static func adaptiveDefaultSize(forScreenWidth screenWidth: CGFloat) -> CGSize {
    let span = maxDefaultScreenWidth - minDefaultScreenWidth
    let fraction = span > 0 ? min(max((screenWidth - minDefaultScreenWidth) / span, 0), 1) : 1
    return CGSize(
      width: minDefaultSize.width + (maxDefaultSize.width - minDefaultSize.width) * fraction,
      height: minDefaultSize.height + (maxDefaultSize.height - minDefaultSize.height) * fraction
    )
  }

  init(position: CGPoint, size: CGSize = Self.defaultSize) {
    self.positionX = position.x
    self.positionY = position.y
    self.width = size.width
    self.height = size.height
  }
}

// MARK: - Card Packing

struct CanvasCardPacker {
  var spacing: CGFloat
  var titleBarHeight: CGFloat

  struct CardInfo {
    var key: String
    var size: CGSize
  }

  struct PackResult {
    var layouts: [String: CanvasCardLayout]
    var boundingSize: CGSize
  }

  /// The maximum card count for exhaustive row-break enumeration.
  private static let exhaustiveLimit = 20
  /// Permit a bounded scale tradeoff for more balanced overall layout shapes.
  private static let balanceScaleSlack: CGFloat = 0.30
  /// Only apply balance preference when card heights are relatively uniform.
  private static let balanceHeightSpreadLimit: CGFloat = 0.20
  private static let floatEpsilon: CGFloat = 0.000_001

  /// Pack cards to maximize fit while avoiding overly long single-row layouts.
  ///
  /// Two strategies compete: **waterfall** (equal-width columns, cards drop
  /// into the shortest column — great for varying heights) and **row-break**
  /// (cards flow left-to-right with centered rows — great for varying widths).
  ///
  /// Selection policy:
  /// 1) Find global best scale `min(vW/bW, vH/bH)`.
  /// 2) Keep candidates within a bounded scale slack.
  /// 3) Prefer the most balanced (closest to square) bounding box.
  /// 4) Tie-break by scale, then area.
  func pack(cards: [CardInfo], targetRatio: CGFloat) -> PackResult {
    guard !cards.isEmpty, targetRatio > 0 else {
      return PackResult(layouts: [:], boundingSize: .zero)
    }

    let columnWidth = cards.map(\.size.width).max()!
    // Positive = waterfall column count, negative = row-break mask (offset by -1).
    let enumerateCandidates: (@escaping (_ tag: Int, _ boxW: CGFloat, _ boxH: CGFloat, _ scale: CGFloat, _ area: CGFloat) ->
      Void) -> Void = { visit in
      // Strategy 1: Waterfall — try all column counts.
      for cols in 1...cards.count {
        let (boxW, boxH) = waterfallBoundingSize(cards: cards, columns: cols, columnWidth: columnWidth)
        let scale = min(targetRatio / boxW, 1.0 / boxH)
        visit(cols, boxW, boxH, scale, boxW * boxH)
      }

      // Strategy 2: Row-break — try all row configurations (exhaustive for small N).
      if cards.count <= Self.exhaustiveLimit {
        for mask in 0..<(1 << (cards.count - 1)) {
          let (boxW, boxH) = rowBreakBoundingSize(cards: cards, breakMask: mask)
          let scale = min(targetRatio / boxW, 1.0 / boxH)
          visit(-(mask + 1), boxW, boxH, scale, boxW * boxH)
        }
      }
    }

    var maxScale: CGFloat = 0
    enumerateCandidates { _, _, _, scale, _ in
      maxScale = max(maxScale, scale)
    }

    let cardHeights = cards.map { $0.size.height + titleBarHeight }
    let heightSpread: CGFloat
    if let maxHeight = cardHeights.max(), let minHeight = cardHeights.min(), maxHeight > 0 {
      heightSpread = (maxHeight - minHeight) / maxHeight
    } else {
      heightSpread = 0
    }

    let balanceScaleSlack = heightSpread <= Self.balanceHeightSpreadLimit ? Self.balanceScaleSlack : 0
    let minAcceptedScale = maxScale * (1.0 - balanceScaleSlack)

    var bestTag = 1
    var bestScale: CGFloat = -1
    var bestArea = CGFloat.infinity
    var bestImbalance = CGFloat.infinity
    enumerateCandidates { tag, boxW, boxH, scale, area in
      guard scale + Self.floatEpsilon >= minAcceptedScale else {
        return
      }

      let imbalance = abs(CGFloat(log(Double(boxW / boxH))))
      let isBetterBalance = imbalance < bestImbalance - Self.floatEpsilon
      let isSameBalance = abs(imbalance - bestImbalance) <= Self.floatEpsilon
      let isBetterScale = scale > bestScale + Self.floatEpsilon
      let isSameScale = abs(scale - bestScale) <= Self.floatEpsilon
      let isBetterArea = area < bestArea - Self.floatEpsilon

      if isBetterBalance
        || (isSameBalance && isBetterScale)
        || (isSameBalance && isSameScale && isBetterArea)
      {
        bestTag = tag
        bestScale = scale
        bestArea = area
        bestImbalance = imbalance
      }
    }

    if bestTag > 0 {
      return waterfallPack(cards: cards, columns: bestTag, columnWidth: columnWidth)
    } else {
      return rowBreakLayout(cards: cards, breakMask: -(bestTag + 1))
    }
  }

  // MARK: - Waterfall layout

  /// Compute bounding size for a waterfall layout without building layouts.
  private func waterfallBoundingSize(
    cards: [CardInfo],
    columns: Int,
    columnWidth: CGFloat
  ) -> (CGFloat, CGFloat) {
    var colHeights = Array(repeating: spacing, count: columns)
    for card in cards {
      let col = colHeights.enumerated().min(by: { $0.element < $1.element })!.offset
      colHeights[col] += card.size.height + titleBarHeight + spacing
    }
    let totalWidth = spacing + CGFloat(columns) * (columnWidth + spacing)
    let totalHeight = colHeights.max() ?? spacing
    return (totalWidth, totalHeight)
  }

  /// Place cards into equal-width columns, each card going to the shortest
  /// column. Cards are horizontally centered within their column.
  private func waterfallPack(
    cards: [CardInfo],
    columns: Int,
    columnWidth: CGFloat
  ) -> PackResult {
    var colHeights = Array(repeating: spacing, count: columns)
    var layouts: [String: CanvasCardLayout] = [:]

    for card in cards {
      let col = colHeights.enumerated().min(by: { $0.element < $1.element })!.offset
      let cardHeight = card.size.height + titleBarHeight
      let colLeft = spacing + CGFloat(col) * (columnWidth + spacing)

      layouts[card.key] = CanvasCardLayout(
        position: CGPoint(
          x: colLeft + columnWidth / 2,
          y: colHeights[col] + cardHeight / 2
        ),
        size: card.size
      )

      colHeights[col] += cardHeight + spacing
    }

    let totalWidth = spacing + CGFloat(columns) * (columnWidth + spacing)
    let totalHeight = colHeights.max() ?? spacing

    return PackResult(
      layouts: layouts,
      boundingSize: CGSize(width: totalWidth, height: totalHeight)
    )
  }

  // MARK: - Row-break layout

  /// Compute bounding size for a row-break configuration without allocating.
  private func rowBreakBoundingSize(cards: [CardInfo], breakMask: Int) -> (CGFloat, CGFloat) {
    var maxWidth = spacing
    var totalHeight = spacing
    var rowWidth = spacing
    var rowHeight: CGFloat = 0

    for idx in 0..<cards.count {
      if idx > 0 && (breakMask & (1 << (idx - 1))) != 0 {
        maxWidth = max(maxWidth, rowWidth)
        totalHeight += rowHeight + spacing
        rowWidth = spacing
        rowHeight = 0
      }
      rowWidth += cards[idx].size.width + spacing
      rowHeight = max(rowHeight, cards[idx].size.height + titleBarHeight)
    }

    maxWidth = max(maxWidth, rowWidth)
    totalHeight += rowHeight + spacing
    return (maxWidth, totalHeight)
  }

  /// Build card layouts from a row-break mask. Rows are centered horizontally.
  private func rowBreakLayout(cards: [CardInfo], breakMask: Int) -> PackResult {
    var rows: [[Int]] = [[0]]
    for idx in 1..<cards.count {
      if breakMask & (1 << (idx - 1)) != 0 {
        rows.append([idx])
      } else {
        rows[rows.count - 1].append(idx)
      }
    }

    let rowWidths = rows.map { row -> CGFloat in
      row.reduce(spacing) { $0 + cards[$1].size.width + spacing }
    }
    let maxRowWidth = rowWidths.max() ?? 0

    var layouts: [String: CanvasCardLayout] = [:]
    var posY = spacing

    for (rowIndex, row) in rows.enumerated() {
      let rowHeight = row.map { cards[$0].size.height + titleBarHeight }.max() ?? 0
      let xOffset = (maxRowWidth - rowWidths[rowIndex]) / 2
      var posX = spacing + xOffset

      for idx in row {
        let card = cards[idx]
        let cardHeight = card.size.height + titleBarHeight
        layouts[card.key] = CanvasCardLayout(
          position: CGPoint(
            x: posX + card.size.width / 2,
            y: posY + cardHeight / 2
          ),
          size: card.size
        )
        posX += card.size.width + spacing
      }

      posY += rowHeight + spacing
    }

    return PackResult(
      layouts: layouts,
      boundingSize: CGSize(width: maxRowWidth, height: posY)
    )
  }
}

@MainActor
@Observable
final class CanvasLayoutStore {
  private static let storageKey = "canvasCardLayouts"

  /// Whether auto-arrange has run in this app session. Resets on app launch.
  static var hasAutoArrangedInSession = false

  private let defaults: UserDefaults
  private let initiallyLoadedCardKeys: Set<String>

  var cardLayouts: [String: CanvasCardLayout] {
    didSet { save() }
  }

  var zOrder: [String] {
    didSet { save() }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = Self.load(from: defaults)
    cardLayouts = stored.cardLayouts
    zOrder = stored.zOrder
    initiallyLoadedCardKeys = Set(stored.cardLayouts.keys)
  }

  func shouldAutoArrangeOnInitialEntry(for cardKeys: [String]) -> Bool {
    guard !cardKeys.isEmpty else { return false }
    return !cardKeys.contains { initiallyLoadedCardKeys.contains($0) }
  }

  func setCardLayouts(_ layouts: [String: CanvasCardLayout], zOrder newZOrder: [String]? = nil) {
    cardLayouts = layouts
    zOrder = normalizedZOrder(newZOrder ?? zOrder, visibleKeys: Array(layouts.keys))
  }

  func ensureZOrder(for visibleKeys: [String]) {
    zOrder = normalizedZOrder(zOrder, visibleKeys: visibleKeys)
  }

  func prune(to visibleKeys: Set<String>) {
    cardLayouts = cardLayouts.filter { visibleKeys.contains($0.key) }
    zOrder = zOrder.filter { visibleKeys.contains($0) }
  }

  func moveToFront(_ cardKey: String) {
    guard cardLayouts[cardKey] != nil else { return }
    zOrder.removeAll { $0 == cardKey }
    zOrder.append(cardKey)
  }

  func zIndex(for cardKey: String) -> Double {
    guard let index = zOrder.firstIndex(of: cardKey) else { return 0 }
    return Double(index)
  }

  private static func load(from defaults: UserDefaults) -> CanvasLayoutStoragePayload {
    guard let data = defaults.data(forKey: storageKey) else {
      return CanvasLayoutStoragePayload(cardLayouts: [:], zOrder: [])
    }

    if let payload = try? JSONDecoder().decode(CanvasLayoutStoragePayload.self, from: data) {
      return CanvasLayoutStoragePayload(
        cardLayouts: payload.cardLayouts,
        zOrder: normalizedZOrder(payload.zOrder, visibleKeys: Array(payload.cardLayouts.keys))
      )
    }

    if let layouts = try? JSONDecoder().decode([String: CanvasCardLayout].self, from: data) {
      return CanvasLayoutStoragePayload(cardLayouts: layouts, zOrder: Array(layouts.keys).sorted())
    }

    return CanvasLayoutStoragePayload(cardLayouts: [:], zOrder: [])
  }

  private func save() {
    let payload = CanvasLayoutStoragePayload(
      cardLayouts: cardLayouts,
      zOrder: Self.normalizedZOrder(zOrder, visibleKeys: Array(cardLayouts.keys))
    )
    if let data = try? JSONEncoder().encode(payload) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }

  private func normalizedZOrder(_ order: [String], visibleKeys: [String]) -> [String] {
    Self.normalizedZOrder(order, visibleKeys: visibleKeys)
  }

  private static func normalizedZOrder(_ order: [String], visibleKeys: [String]) -> [String] {
    let visibleKeySet = Set(visibleKeys)
    var seen: Set<String> = []
    var normalized: [String] = []
    for key in order where visibleKeySet.contains(key) && seen.insert(key).inserted {
      normalized.append(key)
    }
    for key in visibleKeys.sorted() where seen.insert(key).inserted {
      normalized.append(key)
    }
    return normalized
  }
}

private struct CanvasLayoutStoragePayload: Codable, Equatable {
  var cardLayouts: [String: CanvasCardLayout]
  var zOrder: [String]
}
