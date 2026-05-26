import CoreGraphics

/// Geometry for the canvas "expand-in-place" interaction: a card is temporarily
/// blown up to a near-fullscreen size at scale 1 (so its terminal renders at the
/// same font size as Normal/Shelf mode), covering the viewport with a padding
/// margin and avoiding the bottom toolbar reserve. The expanded card transforms
/// on its own; the canvas pan/zoom is left untouched so the background is frozen.
enum CanvasExpandGeometry {
  /// Layout metrics for an expanded card.
  struct Metrics {
    /// Horizontal margin kept on both sides of the expanded card.
    var horizontalPadding: CGFloat
    /// Top margin measured from the top of the full window, including the
    /// titlebar safe-area inset.
    var topPadding: CGFloat
    /// Extra height reserved at the bottom for the help/layout toolbar.
    var bottomReserve: CGFloat
    /// Top safe-area inset occupied by the window titlebar.
    var topSafeAreaInset: CGFloat
    /// Height of the card title bar, added on top of the content height.
    var titleBarHeight: CGFloat
    /// Lower bound for the content size on tiny viewports.
    var minSize: CGSize

    init(
      padding: CGFloat,
      bottomReserve: CGFloat,
      titleBarHeight: CGFloat,
      minSize: CGSize
    ) {
      self.init(
        horizontalPadding: padding,
        topPadding: padding,
        bottomReserve: bottomReserve,
        topSafeAreaInset: 0,
        titleBarHeight: titleBarHeight,
        minSize: minSize
      )
    }

    init(
      horizontalPadding: CGFloat,
      topPadding: CGFloat,
      bottomReserve: CGFloat,
      topSafeAreaInset: CGFloat = 0,
      titleBarHeight: CGFloat,
      minSize: CGSize
    ) {
      self.horizontalPadding = horizontalPadding
      self.topPadding = topPadding
      self.bottomReserve = bottomReserve
      self.topSafeAreaInset = topSafeAreaInset
      self.titleBarHeight = titleBarHeight
      self.minSize = minSize
    }
  }

  /// The expanded card's content size (excluding the title bar): the viewport
  /// minus horizontal margins, top margin, bottom reserve, and the title bar,
  /// clamped to `minSize`.
  static func expandedSize(viewport: CGSize, metrics: Metrics) -> CGSize {
    let safeAreaInset = max(0, metrics.topSafeAreaInset)
    let windowHeight = viewport.height + safeAreaInset
    let width = max(metrics.minSize.width, viewport.width - metrics.horizontalPadding * 2)
    let totalHeight = windowHeight - metrics.topPadding - metrics.bottomReserve
    let height = max(metrics.minSize.height, totalHeight - metrics.titleBarHeight)
    return CGSize(width: width, height: height)
  }

  /// Screen-space center for the expanded card inside the SwiftUI viewport.
  static func expandedCenter(viewport: CGSize, metrics: Metrics) -> CGPoint {
    let safeAreaInset = max(0, metrics.topSafeAreaInset)
    let windowHeight = viewport.height + safeAreaInset
    let totalHeight = windowHeight - metrics.topPadding - metrics.bottomReserve
    return CGPoint(
      x: viewport.width / 2,
      y: metrics.topPadding + totalHeight / 2 - safeAreaInset
    )
  }
}
