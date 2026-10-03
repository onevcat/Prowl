import SwiftUI

struct TerminalTabLabelView: View {
  let tab: TerminalTabItem
  let isActive: Bool
  let isHoveringTab: Bool
  let isHoveringClose: Bool
  let shortcutHint: String?
  let showsShortcutHint: Bool

  var body: some View {
    HStack(spacing: 0) {
      // Leading placeholder, same width as the trailing close-button slot, so
      // the title stays truly centered in the full tab.
      Color.clear
        .frame(width: TerminalTabBarMetrics.closeButtonSize)
      HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
        if tab.isDirty || tab.icon != nil {
          TerminalTabIconBadge(tab: tab, isActive: isActive)
        }
        Text(tab.displayTitle)
          .font(.caption)
          .lineLimit(1)
          .foregroundStyle(isActive ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText)
      }
      .frame(maxWidth: .infinity)
      // Trailing slot reserved for the close button (overlaid by TerminalTabView)
      // or the shortcut hint; the centered title never runs underneath it.
      Color.clear
        .frame(width: TerminalTabBarMetrics.closeButtonSize)
    }
    .frame(maxHeight: .infinity)
    // Leading, sharing the close button's slot (they are mutually exclusive).
    .overlay(alignment: .leading) {
      if showsShortcutHint, let shortcutHint {
        ShortcutHintView(text: shortcutHint, color: TerminalTabBarColors.inactiveText)
      }
    }
    .contentShape(.rect)
    .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
  }
}

struct TerminalTabIconBadge: View {
  let tab: TerminalTabItem
  let isActive: Bool

  var body: some View {
    ZStack {
      if tab.isDirty {
        ProgressView()
          .controlSize(.small)
          .tint(isActive ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText)
      } else if let icon = tab.icon {
        TabIconImage(rawName: icon, pointSize: 12)
          .foregroundStyle(isActive ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText)
      }
    }
    .frame(
      width: TerminalTabBarMetrics.closeButtonSize,
      height: TerminalTabBarMetrics.closeButtonSize
    )
    .accessibilityHidden(true)
  }
}
