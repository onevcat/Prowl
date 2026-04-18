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
}
