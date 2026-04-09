import CoreGraphics
import Foundation

enum CanvasViewportMath {
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
}
