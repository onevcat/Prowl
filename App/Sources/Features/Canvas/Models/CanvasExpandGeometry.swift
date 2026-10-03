import CoreGraphics

/// Geometry for the canvas "expand-in-place" interaction: a card is temporarily
/// blown up to a near-fullscreen size at scale 1 (so its terminal renders at the
/// same font size as Normal/Shelf mode), covering the viewport with a padding
/// margin and avoiding the bottom toolbar reserve. The expanded card transforms
/// on its own; the canvas pan/zoom is left untouched so the background is frozen.
enum CanvasExpandGeometry {
  /// Layout metrics for an expanded card.
  struct Metrics {
    /// Margin kept on every side of the expanded card.
    var padding: CGFloat
    /// Extra height reserved at the bottom for the help/layout toolbar.
    var bottomReserve: CGFloat
    /// Height of the card title bar, added on top of the content height.
    var titleBarHeight: CGFloat
    /// Lower bound for the content size on tiny viewports.
    var minSize: CGSize
  }

  /// The expanded card's content size (excluding the title bar): the viewport
  /// minus the padding margin, the bottom reserve, and the title bar, clamped to
  /// `minSize`.
  static func expandedSize(viewport: CGSize, metrics: Metrics) -> CGSize {
    let width = max(metrics.minSize.width, viewport.width - metrics.padding * 2)
    let totalHeight = viewport.height - metrics.padding * 2 - metrics.bottomReserve
    let height = max(metrics.minSize.height, totalHeight - metrics.titleBarHeight)
    return CGSize(width: width, height: height)
  }
}
