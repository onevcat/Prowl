import CoreGraphics
import Foundation

enum CanvasViewportMath {
  struct CardVisibilityEntry<ID: Hashable>: Equatable {
    let id: ID
    let frame: CGRect
  }

  struct MaximizedCardFrame: Equatable {
    let cardSize: CGSize
    let screenCenter: CGPoint
  }

  static let compactDoubleClickScale: CGFloat = 0.67
  static let fullDoubleClickScale: CGFloat = 1.0
  static let zoomPresetScales: [CGFloat] = [
    0.5,
    compactDoubleClickScale,
    0.75,
    fullDoubleClickScale,
  ]

  static func clampedScale(
    _ scale: CGFloat,
    min minimumScale: CGFloat = 0.25,
    max maximumScale: CGFloat = 2.0
  ) -> CGFloat {
    max(minimumScale, min(maximumScale, scale))
  }

  static func percentageString(for scale: CGFloat) -> String {
    "\(Int((scale * 100).rounded()))%"
  }

  static func scaleFromPercentageInput(_ input: String) -> CGFloat? {
    var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("%") {
      trimmed.removeLast()
      trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !trimmed.isEmpty, let percentage = Double(trimmed), percentage.isFinite, percentage > 0 else {
      return nil
    }
    return clampedScale(CGFloat(percentage / 100))
  }

  static func nextDoubleClickScale(after previousScale: CGFloat?) -> CGFloat {
    guard previousScale == fullDoubleClickScale else {
      return fullDoubleClickScale
    }
    return compactDoubleClickScale
  }

  static func centeredViewport(
    viewportSize: CGSize,
    canvasPoint: CGPoint,
    scale targetScale: CGFloat = 1.0
  ) -> (offset: CGSize, scale: CGFloat) {
    let scale = clampedScale(targetScale)
    return (
      offset: CGSize(
        width: viewportSize.width / 2 - canvasPoint.x * scale,
        height: viewportSize.height / 2 - canvasPoint.y * scale
      ),
      scale: scale
    )
  }

  static func maximizedCardFrame(
    viewportSize: CGSize,
    margin: CGFloat,
    titleBarHeight: CGFloat,
    transformScale: CGFloat = 1
  ) -> MaximizedCardFrame? {
    guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
    guard transformScale > 0 else { return nil }
    let outerWidth = viewportSize.width - margin * 2
    let outerHeight = viewportSize.height - margin * 2
    let untransformedOuterWidth = outerWidth / transformScale
    let untransformedOuterHeight = outerHeight / transformScale
    guard untransformedOuterWidth > 0, untransformedOuterHeight > titleBarHeight else { return nil }
    return MaximizedCardFrame(
      cardSize: CGSize(
        width: untransformedOuterWidth,
        height: untransformedOuterHeight - titleBarHeight
      ),
      screenCenter: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    )
  }

  static func offsetKeepingAnchorStable(
    currentOffset: CGSize,
    currentScale: CGFloat,
    newScale: CGFloat,
    anchor: CGPoint
  ) -> CGSize {
    let canvasX = (anchor.x - currentOffset.width) / currentScale
    let canvasY = (anchor.y - currentOffset.height) / currentScale
    return CGSize(
      width: anchor.x - canvasX * newScale,
      height: anchor.y - canvasY * newScale
    )
  }

  static func offsetMaximizingCardVisibility<ID: Hashable>(
    viewportBounds: CGRect,
    centeringBounds: CGRect? = nil,
    entries: [CardVisibilityEntry<ID>],
    focusedID: ID,
    scale targetScale: CGFloat
  ) -> CGSize? {
    guard viewportBounds.width > 0, viewportBounds.height > 0 else { return nil }
    guard let focusedEntry = entries.first(where: { $0.id == focusedID }) else { return nil }

    let scale = clampedScale(targetScale)
    let contentBounds = entries.map(\.frame).reduce(focusedEntry.frame) { partialResult, frame in
      partialResult.union(frame)
    }
    if let centeredOffset = offsetCenteringContentIfFullyVisible(
      contentBounds: contentBounds,
      viewportBounds: centeringBounds ?? viewportBounds,
      scale: scale
    ) {
      return centeredOffset
    }

    let xRange = offsetRange(
      focusedMin: focusedEntry.frame.minX,
      focusedMax: focusedEntry.frame.maxX,
      viewportMin: viewportBounds.minX,
      viewportMax: viewportBounds.maxX,
      scale: scale
    )
    let yRange = offsetRange(
      focusedMin: focusedEntry.frame.minY,
      focusedMax: focusedEntry.frame.maxY,
      viewportMin: viewportBounds.minY,
      viewportMax: viewportBounds.maxY,
      scale: scale
    )
    let xCandidates = candidateOffsets(
      entries: entries,
      range: xRange,
      viewportMin: viewportBounds.minX,
      viewportMax: viewportBounds.maxX,
      scale: scale,
      axisMin: \.minX,
      axisMax: \.maxX
    )
    let yCandidates = candidateOffsets(
      entries: entries,
      range: yRange,
      viewportMin: viewportBounds.minY,
      viewportMax: viewportBounds.maxY,
      scale: scale,
      axisMin: \.minY,
      axisMax: \.maxY
    )
    return bestOffset(
      xCandidates: xCandidates,
      yCandidates: yCandidates,
      entries: entries,
      focusedEntry: focusedEntry,
      contentBounds: contentBounds,
      viewportBounds: viewportBounds,
      scale: scale
    )
  }

  private static func offsetRange(
    focusedMin: CGFloat,
    focusedMax: CGFloat,
    viewportMin: CGFloat,
    viewportMax: CGFloat,
    scale: CGFloat
  ) -> ClosedRange<CGFloat> {
    let lowerBound = viewportMin - focusedMin * scale
    let upperBound = viewportMax - focusedMax * scale
    guard lowerBound <= upperBound else {
      let focusedCenter = (focusedMin + focusedMax) / 2
      let viewportCenter = (viewportMin + viewportMax) / 2
      let offset = viewportCenter - focusedCenter * scale
      return offset...offset
    }
    return lowerBound...upperBound
  }

  private static func offsetCenteringContentIfFullyVisible(
    contentBounds: CGRect,
    viewportBounds: CGRect,
    scale: CGFloat
  ) -> CGSize? {
    let epsilon: CGFloat = 0.001
    guard
      contentBounds.width * scale <= viewportBounds.width + epsilon,
      contentBounds.height * scale <= viewportBounds.height + epsilon
    else { return nil }

    return CGSize(
      width: viewportBounds.midX - contentBounds.midX * scale,
      height: viewportBounds.midY - contentBounds.midY * scale
    )
  }

  private static func candidateOffsets<ID: Hashable>(
    entries: [CardVisibilityEntry<ID>],
    range: ClosedRange<CGFloat>,
    viewportMin: CGFloat,
    viewportMax: CGFloat,
    scale: CGFloat,
    axisMin: KeyPath<CGRect, CGFloat>,
    axisMax: KeyPath<CGRect, CGFloat>
  ) -> [CGFloat] {
    let breakpoints = entries.flatMap { entry in
      let frameMin = entry.frame[keyPath: axisMin]
      let frameMax = entry.frame[keyPath: axisMax]
      return [
        viewportMin - frameMax * scale,
        viewportMin - frameMin * scale,
        viewportMax - frameMax * scale,
        viewportMax - frameMin * scale,
      ]
    }
    let sorted = ([range.lowerBound, range.upperBound] + breakpoints.map { clampedOffset($0, to: range) })
      .sorted()
      .reduce(into: [CGFloat]()) { result, value in
        guard result.last.map({ abs($0 - value) <= 0.001 }) != true else { return }
        result.append(value)
      }
    let midpoints = zip(sorted, sorted.dropFirst()).map { ($0 + $1) / 2 }
    return sorted + midpoints
  }

  private static func clampedOffset(
    _ offset: CGFloat,
    to range: ClosedRange<CGFloat>
  ) -> CGFloat {
    min(max(offset, range.lowerBound), range.upperBound)
  }

  private static func bestOffset<ID: Hashable>(
    xCandidates: [CGFloat],
    yCandidates: [CGFloat],
    entries: [CardVisibilityEntry<ID>],
    focusedEntry: CardVisibilityEntry<ID>,
    contentBounds: CGRect,
    viewportBounds: CGRect,
    scale: CGFloat
  ) -> CGSize? {
    var best: (offset: CGSize, totalVisibleArea: CGFloat, focusedVisibleArea: CGFloat, cornerScore: CGFloat)?
    let preferredXDirection: CGFloat = focusedEntry.frame.midX >= contentBounds.midX ? 1 : -1
    let preferredYDirection: CGFloat = focusedEntry.frame.midY >= contentBounds.midY ? 1 : -1

    for x in xCandidates {
      for y in yCandidates {
        let offset = CGSize(width: x, height: y)
        let totalVisibleArea = entries.reduce(CGFloat.zero) { partialResult, entry in
          partialResult + visibleArea(
            frame: entry.frame,
            offset: offset,
            scale: scale,
            viewportBounds: viewportBounds
          )
        }
        let focusedVisibleArea = visibleArea(
          frame: focusedEntry.frame,
          offset: offset,
          scale: scale,
          viewportBounds: viewportBounds
        )
        let cornerScore = x * preferredXDirection + y * preferredYDirection
        let candidate = (offset, totalVisibleArea, focusedVisibleArea, cornerScore)
        if isBetterVisibilityCandidate(candidate, than: best) {
          best = candidate
        }
      }
    }
    return best?.offset
  }

  private static func isBetterVisibilityCandidate(
    _ candidate: (offset: CGSize, totalVisibleArea: CGFloat, focusedVisibleArea: CGFloat, cornerScore: CGFloat),
    than best: (offset: CGSize, totalVisibleArea: CGFloat, focusedVisibleArea: CGFloat, cornerScore: CGFloat)?
  ) -> Bool {
    guard let best else { return true }
    if abs(candidate.totalVisibleArea - best.totalVisibleArea) > 0.001 {
      return candidate.totalVisibleArea > best.totalVisibleArea
    }
    if abs(candidate.focusedVisibleArea - best.focusedVisibleArea) > 0.001 {
      return candidate.focusedVisibleArea > best.focusedVisibleArea
    }
    return candidate.cornerScore > best.cornerScore
  }

  private static func visibleArea(
    frame: CGRect,
    offset: CGSize,
    scale: CGFloat,
    viewportBounds: CGRect
  ) -> CGFloat {
    let screenFrame = CGRect(
      x: frame.minX * scale + offset.width,
      y: frame.minY * scale + offset.height,
      width: frame.width * scale,
      height: frame.height * scale
    )
    let visibleFrame = screenFrame.intersection(viewportBounds)
    guard !visibleFrame.isNull else { return 0 }
    return max(0, visibleFrame.width) * max(0, visibleFrame.height)
  }
}
