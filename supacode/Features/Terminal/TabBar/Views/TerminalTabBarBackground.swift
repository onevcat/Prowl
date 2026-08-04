import SwiftUI

struct TerminalTabBarBackground: View {
  @Environment(\.controlActiveState)
  private var activeState
  @Environment(\.surfaceTopChromeBackgroundOpacity)
  private var surfaceTopChromeBackgroundOpacity
  @Environment(\.interfaceTextScale) private var interfaceTextScale

  var body: some View {
    Capsule()
      .fill(TerminalTabBarColors.barBackground.opacity(chromeBackgroundOpacity))
      .padding(.horizontal, TerminalTabBarMetrics.scaled(interfaceTextScale).barPadding)
  }

  private var chromeBackgroundOpacity: Double {
    let baseOpacity = surfaceTopChromeBackgroundOpacity
    if activeState == .inactive {
      return baseOpacity * 0.95
    }
    return baseOpacity
  }
}
