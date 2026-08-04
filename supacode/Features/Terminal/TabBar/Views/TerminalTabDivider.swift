import SwiftUI

struct TerminalTabDivider: View {
  @Environment(\.interfaceTextScale) private var interfaceTextScale

  var body: some View {
    let metrics = TerminalTabBarMetrics.scaled(interfaceTextScale)
    Rectangle()
      .frame(width: metrics.tabDividerWidth)
      .frame(height: metrics.tabHeight - metrics.tabDividerVerticalInset * 2)
      .foregroundStyle(TerminalTabBarColors.separator)
  }
}
