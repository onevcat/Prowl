import CoreGraphics

/// Layout constants for the terminal tab bar. Lengths live on `Scaled` and
/// are resolved through `scaled(_:)` with the interface text scale so the
/// bar tracks the text size setting; only text-coupled lengths multiply,
/// the rest pass through unchanged. Durations stay scale-independent.
enum TerminalTabBarMetrics {
  static let hoverAnimationDuration: Double = 0.1
  static let closeAnimationDuration: Double = 0.2
  static let selectionAnimationDuration: Double = 0.15
  static let reorderAnimationDuration: Double = 0.3
  static let reorderAnimationBounce: Double = 0.15

  static func scaled(_ scale: Double) -> Scaled {
    Scaled(scale: CGFloat(scale))
  }

  struct Scaled {
    let scale: CGFloat

    var barHeight: CGFloat { 31 * scale }
    var tabHeight: CGFloat { 30 * scale }
    var tabMinWidth: CGFloat { 140 * scale }
    var closeButtonSize: CGFloat { 16 * scale }
    var dropIndicatorHeight: CGFloat { 20 * scale }

    let barPadding: CGFloat = 4
    // Gap between the tab bar and the terminal surface below it. The chrome
    // tint band extends across this gap so it reads as one continuous surface
    // instead of revealing the translucent window background when
    // `background-opacity` < 1.
    let barBottomGap: CGFloat = 4
    let tabCornerRadius: CGFloat = 0
    let tabSpacing: CGFloat = 0
    let tabDividerWidth: CGFloat = 1
    // Top/bottom inset applied to the inter-tab divider so it does not run the
    // full bar height; the shorter line is centered by the row's HStack.
    let tabDividerVerticalInset: CGFloat = 6
    let tabHorizontalPadding: CGFloat = 12
    let contentSpacing: CGFloat = 6
    let contentTrailingSpacing: CGFloat = 4
    let activeIndicatorHeight: CGFloat = 2
    let dirtyIndicatorSize: CGFloat = 8
    let dropIndicatorWidth: CGFloat = 2
    let renameFieldCornerRadius: CGFloat = 4
    let renameFieldInset: CGFloat = 4
  }
}
