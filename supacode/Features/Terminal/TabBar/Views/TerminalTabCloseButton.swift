import SwiftUI

struct TerminalTabCloseButton: View {
  var isHoveringTab: Bool
  var isDragging: Bool
  var isShowingShortcutHint: Bool
  var closeAction: () -> Void
  @Binding var closeButtonGestureActive: Bool
  @Binding var isHoveringClose: Bool

  @Environment(GhosttyShortcutManager.self)
  private var ghosttyShortcuts
  @Environment(\.interfaceTextScale) private var interfaceTextScale

  @State private var isPressing = false

  var body: some View {
    let closeButtonSize = TerminalTabBarMetrics.scaled(interfaceTextScale).closeButtonSize
    let showClose = (isHoveringTab || isHoveringClose) && !isDragging && !isShowingShortcutHint
    Button("Close Tab", systemImage: "xmark") {
      closeAction()
    }
    .labelStyle(.iconOnly)
    .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
    .interfaceFont(.caption2, weight: .bold)
    .foregroundStyle(
      isHoveringClose ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText
    )
    .frame(width: closeButtonSize, height: closeButtonSize)
    .background(
      TerminalTabCloseButtonBackground(isPressing: isPressing, isHoveringClose: isHoveringClose)
    )
    .clipShape(.circle)
    .contentShape(.rect)
    .onHover { hovering in
      isHoveringClose = hovering
    }
    .onChange(of: isPressing) { _, pressed in
      closeButtonGestureActive = pressed
    }
    .help(helpText("Close Tab", shortcut: ghosttyShortcuts.display(for: "close_tab")))
    .opacity(showClose ? 1 : 0)
    .allowsHitTesting(showClose)
    .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isHoveringTab)
  }

  private func helpText(_ title: String, shortcut: String?) -> String {
    guard let shortcut else { return title }
    return "\(title) (\(shortcut))"
  }
}
