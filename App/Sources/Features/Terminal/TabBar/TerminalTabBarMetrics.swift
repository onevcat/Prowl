import CoreGraphics

enum TerminalTabBarMetrics {
  static let barHeight: CGFloat = 31
  static let barPadding: CGFloat = 4
  // Gap between the tab bar and the terminal surface below it. The chrome
  // tint band extends across this gap so it reads as one continuous surface
  // instead of revealing the translucent window background when
  // `background-opacity` < 1.
  static let barBottomGap: CGFloat = 4
  static let tabHeight: CGFloat = 30
  static let tabMinWidth: CGFloat = 140
  static let tabCornerRadius: CGFloat = 0
  static let tabSpacing: CGFloat = 0
  static let tabDividerWidth: CGFloat = 1
  // Top/bottom inset applied to the inter-tab divider so it does not run the
  // full bar height; the shorter line is centered by the row's HStack.
  static let tabDividerVerticalInset: CGFloat = 6
  static let tabHorizontalPadding: CGFloat = 12
  static let contentSpacing: CGFloat = 6
  static let contentTrailingSpacing: CGFloat = 4
  static let activeIndicatorHeight: CGFloat = 2
  static let closeButtonSize: CGFloat = 16
  static let dirtyIndicatorSize: CGFloat = 8
  static let dropIndicatorWidth: CGFloat = 2
  static let dropIndicatorHeight: CGFloat = 20
  static let hoverAnimationDuration: Double = 0.1
  static let closeAnimationDuration: Double = 0.2
  static let selectionAnimationDuration: Double = 0.15
  static let reorderAnimationDuration: Double = 0.3
  static let reorderAnimationBounce: Double = 0.15
  static let renameFieldCornerRadius: CGFloat = 4
  static let renameFieldInset: CGFloat = 4
}
