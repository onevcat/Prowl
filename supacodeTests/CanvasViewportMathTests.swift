import CoreGraphics
import Testing

@testable import supacode

struct CanvasViewportMathTests {
  @Test func clampedScaleRespectsBounds() {
    #expect(CanvasViewportMath.clampedScale(0.1) == 0.25)
    #expect(CanvasViewportMath.clampedScale(1.0) == 1.0)
    #expect(CanvasViewportMath.clampedScale(3.0) == 2.0)
  }

  @Test func percentageStringRoundsScale() {
    #expect(CanvasViewportMath.percentageString(for: 1.0) == "100%")
    #expect(CanvasViewportMath.percentageString(for: 0.995) == "100%")
    #expect(CanvasViewportMath.percentageString(for: 1.234) == "123%")
  }

  @Test func scaleFromPercentageInputAcceptsNumberWithOptionalPercentSign() {
    #expect(CanvasViewportMath.scaleFromPercentageInput("67") == 0.67)
    #expect(CanvasViewportMath.scaleFromPercentageInput("67%") == 0.67)
    #expect(CanvasViewportMath.scaleFromPercentageInput("  75 % ") == 0.75)
  }

  @Test func scaleFromPercentageInputRejectsUnsupportedText() {
    #expect(CanvasViewportMath.scaleFromPercentageInput("") == nil)
    #expect(CanvasViewportMath.scaleFromPercentageInput("67 percent") == nil)
    #expect(CanvasViewportMath.scaleFromPercentageInput("%") == nil)
    #expect(CanvasViewportMath.scaleFromPercentageInput("-10") == nil)
  }

  @Test func nextDoubleClickScaleAlternatesBetweenFullAndCompactZoom() {
    #expect(CanvasViewportMath.nextDoubleClickScale(after: nil) == 1.0)
    #expect(CanvasViewportMath.nextDoubleClickScale(after: 1.0) == 0.67)
    #expect(CanvasViewportMath.nextDoubleClickScale(after: 0.67) == 1.0)
  }

  @Test func scaledOffsetKeepsAnchorPointStable() {
    let currentOffset = CGSize(width: 120, height: 80)
    let anchor = CGPoint(x: 500, y: 320)
    let currentScale: CGFloat = 0.8
    let newScale: CGFloat = 1.0

    let newOffset = CanvasViewportMath.offsetKeepingAnchorStable(
      currentOffset: currentOffset,
      currentScale: currentScale,
      newScale: newScale,
      anchor: anchor
    )

    let canvasX = (anchor.x - currentOffset.width) / currentScale
    let canvasY = (anchor.y - currentOffset.height) / currentScale
    let projectedX = canvasX * newScale + newOffset.width
    let projectedY = canvasY * newScale + newOffset.height

    #expect(abs(projectedX - anchor.x) < 0.001)
    #expect(abs(projectedY - anchor.y) < 0.001)
  }

  @Test func centeredViewportMovesCanvasPointToViewportCenterAtScaleOne() {
    let result = CanvasViewportMath.centeredViewport(
      viewportSize: CGSize(width: 1_000, height: 700),
      canvasPoint: CGPoint(x: 400, y: 200)
    )

    #expect(result.scale == 1.0)
    #expect(result.offset == CGSize(width: 100, height: 150))
  }

  @Test func maximizedCardFrameUsesWindowMarginOutsideTitleBarAndContent() {
    let frame = CanvasViewportMath.maximizedCardFrame(
      viewportSize: CGSize(width: 1_200, height: 800),
      margin: 50,
      titleBarHeight: 28
    )

    #expect(frame?.cardSize == CGSize(width: 1_100, height: 672))
    #expect(frame?.screenCenter == CGPoint(x: 600, y: 400))
  }

  @Test func maximizedCardFrameAccountsForTransformScale() {
    let frame = CanvasViewportMath.maximizedCardFrame(
      viewportSize: CGSize(width: 1_220, height: 890),
      margin: 60,
      titleBarHeight: 28,
      transformScale: 1.1
    )

    #expect(abs((frame?.cardSize.width ?? 0) - 1_000) < 0.001)
    #expect(abs((frame?.cardSize.height ?? 0) - 672) < 0.001)
    #expect(frame?.screenCenter == CGPoint(x: 610, y: 445))
  }

  @Test func maximizedCardFrameReturnsNilWhenViewportCannotFitMarginsAndTitleBar() {
    let frame = CanvasViewportMath.maximizedCardFrame(
      viewportSize: CGSize(width: 90, height: 120),
      margin: 50,
      titleBarHeight: 28
    )

    #expect(frame == nil)
  }

  @Test func compactZoomPlacementKeepsBottomRightFocusedCardVisibleAndMaximizesContext() {
    let viewportBounds = CGRect(x: 0, y: 0, width: 500, height: 350)
    let entries = gridVisibilityEntries(columns: 2, rows: 3)
    let offset = CanvasViewportMath.offsetMaximizingCardVisibility(
      viewportBounds: viewportBounds,
      entries: entries,
      focusedID: "card-5",
      scale: CanvasViewportMath.compactDoubleClickScale
    )

    expectSize(offset, equals: CGSize(width: 77.9, height: -92.2))
    let focusedFrame = screenFrame(
      for: entries[5].frame,
      offset: offset,
      scale: CanvasViewportMath.compactDoubleClickScale
    )
    #expect(focusedFrame.maxX == viewportBounds.maxX)
    #expect(focusedFrame.maxY == viewportBounds.maxY)
    #expect(viewportBounds.contains(focusedFrame))
  }

  @Test func compactZoomPlacementKeepsTopLeftFocusedCardVisibleAndMaximizesContext() {
    let viewportBounds = CGRect(x: 0, y: 0, width: 500, height: 350)
    let entries = gridVisibilityEntries(columns: 2, rows: 3)
    let offset = CanvasViewportMath.offsetMaximizingCardVisibility(
      viewportBounds: viewportBounds,
      entries: entries,
      focusedID: "card-0",
      scale: CanvasViewportMath.compactDoubleClickScale
    )

    expectSize(offset, equals: .zero)
    let focusedFrame = screenFrame(
      for: entries[0].frame,
      offset: offset,
      scale: CanvasViewportMath.compactDoubleClickScale
    )
    #expect(focusedFrame.minX == viewportBounds.minX)
    #expect(focusedFrame.minY == viewportBounds.minY)
    #expect(viewportBounds.contains(focusedFrame))
  }

  @Test func compactZoomPlacementCentersAllCardsWhenTheyFitInViewport() {
    let viewportBounds = CGRect(x: 0, y: 0, width: 500, height: 350)
    let entries = gridVisibilityEntries(columns: 2, rows: 1)
    let offset = CanvasViewportMath.offsetMaximizingCardVisibility(
      viewportBounds: viewportBounds,
      entries: entries,
      focusedID: "card-1",
      scale: CanvasViewportMath.compactDoubleClickScale
    )

    expectSize(offset, equals: CGSize(width: 38.95, height: 108))
    for entry in entries {
      #expect(
        viewportBounds.contains(
          screenFrame(
            for: entry.frame,
            offset: offset,
            scale: CanvasViewportMath.compactDoubleClickScale
          )
        )
      )
    }
  }

  @Test func compactZoomPlacementCentersInVisibleViewportBeforeUsingFocusBounds() {
    let visibleViewportBounds = CGRect(x: 0, y: 0, width: 1_990, height: 1_240)
    let focusBounds = CGRect(x: 44, y: 20, width: 1_902, height: 1_080)
    let entries = [
      largeVisibilityEntry(id: "card-0", x: 20, y: 20),
      largeVisibilityEntry(id: "card-1", x: 960, y: 20),
      largeVisibilityEntry(id: "card-2", x: 20, y: 860),
    ]

    let offset = CanvasViewportMath.offsetMaximizingCardVisibility(
      viewportBounds: focusBounds,
      centeringBounds: visibleViewportBounds,
      entries: entries,
      focusedID: "card-0",
      scale: CanvasViewportMath.compactDoubleClickScale
    )

    expectSize(offset, equals: CGSize(width: 358.5, height: 50.5))
    for entry in entries {
      #expect(
        visibleViewportBounds.contains(
          screenFrame(
            for: entry.frame,
            offset: offset,
            scale: CanvasViewportMath.compactDoubleClickScale
          )
        )
      )
    }
  }

  @Test func focusVisibilityBoundsCanReserveWiderHorizontalGutter() {
    let baselineBounds = canvasFocusVisibilityBounds(
      viewportSize: CGSize(width: 1_000, height: 700),
      horizontalInset: 20,
      verticalInset: 20,
      bottomReservedInset: 36
    )
    let widenedBounds = canvasFocusVisibilityBounds(
      viewportSize: CGSize(width: 1_000, height: 700),
      horizontalInset: 44,
      verticalInset: 20,
      bottomReservedInset: 36
    )

    #expect(widenedBounds.minX == 44)
    #expect(widenedBounds.maxX == 956)
    #expect(widenedBounds.minX > baselineBounds.minX)
    #expect(widenedBounds.maxX < baselineBounds.maxX)
    #expect(widenedBounds.minY == baselineBounds.minY)
    #expect(widenedBounds.maxY == baselineBounds.maxY)
  }

  private func gridVisibilityEntries(
    columns: Int,
    rows: Int
  ) -> [CanvasViewportMath.CardVisibilityEntry<String>] {
    let cardSize = CGSize(width: 300, height: 200)
    let spacing: CGFloat = 30
    return (0..<(columns * rows)).map { index in
      let column = index % columns
      let row = index / columns
      let origin = CGPoint(
        x: CGFloat(column) * (cardSize.width + spacing),
        y: CGFloat(row) * (cardSize.height + spacing)
      )
      return CanvasViewportMath.CardVisibilityEntry(
        id: "card-\(index)",
        frame: CGRect(origin: origin, size: cardSize)
      )
    }
  }

  private func largeVisibilityEntry(
    id: String,
    x: CGFloat,
    y: CGFloat
  ) -> CanvasViewportMath.CardVisibilityEntry<String> {
    CanvasViewportMath.CardVisibilityEntry(
      id: id,
      frame: CGRect(x: x, y: y, width: 920, height: 820)
    )
  }

  private func screenFrame(
    for frame: CGRect,
    offset: CGSize?,
    scale: CGFloat
  ) -> CGRect {
    guard let offset else { return .null }
    return CGRect(
      x: frame.minX * scale + offset.width,
      y: frame.minY * scale + offset.height,
      width: frame.width * scale,
      height: frame.height * scale
    )
  }

  private func expectSize(
    _ size: CGSize?,
    equals expectedSize: CGSize
  ) {
    guard let size else {
      Issue.record("Expected \(expectedSize), got nil")
      return
    }
    #expect(abs(size.width - expectedSize.width) < 0.001)
    #expect(abs(size.height - expectedSize.height) < 0.001)
  }
}
