import SwiftUI

struct TerminalTabCloseButtonBackground: View {
  let isPressing: Bool
  let isHoveringClose: Bool

  var body: some View {
    Circle()
      .fill(backgroundColor)
  }

  // A clear circular fill on hover/press, like the standard macOS close-button
  // affordance. Uses system label colors so it reads on any bar background
  // (the brightness-ladder tab fills are too faint to show as a circle).
  private var backgroundColor: Color {
    if isPressing {
      return Color(nsColor: .tertiaryLabelColor)
    }
    if isHoveringClose {
      return Color(nsColor: .quaternaryLabelColor)
    }
    return .clear
  }
}
