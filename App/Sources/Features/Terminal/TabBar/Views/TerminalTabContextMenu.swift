import SwiftUI

enum TerminalTabContextMenuVariant {
  /// Horizontal tab bar — shows all items; "Close Tabs to the Right".
  case tabBar
  /// Vertical shelf spine — shows all items; "Close Tabs Below".
  case shelf
  /// 2D canvas cards — worktree-scoped labels; hides "Close Tabs to the Right".
  case canvas
}

extension View {
  func terminalTabContextMenu(
    tabId: TerminalTabID,
    tabs: [TerminalTabItem],
    actions: TerminalTabContextMenuActions,
    variant: TerminalTabContextMenuVariant = .tabBar
  ) -> some View {
    modifier(
      TerminalTabContextMenu(
        tabId: tabId,
        tabs: tabs,
        actions: actions,
        variant: variant
      )
    )
  }
}

struct TerminalTabContextMenu: ViewModifier {
  let tabId: TerminalTabID
  let tabs: [TerminalTabItem]
  let actions: TerminalTabContextMenuActions
  let variant: TerminalTabContextMenuVariant

  func body(content: Content) -> some View {
    content.contextMenu {
      if let currentTab, !currentTab.isTitleLocked {
        Button("Rename Tab") {
          actions.renameTab(tabId)
        }
      }

      Button("Change Tab Icon...") {
        actions.changeIcon(tabId)
      }

      Divider()

      Button("Close Tab") {
        actions.closeTab(tabId)
      }

      Button(variant == .canvas ? "Close Other Tabs in This Worktree" : "Close Other Tabs") {
        actions.closeOthers(tabId)
      }
      .disabled(tabs.count <= 1)

      if variant != .canvas {
        Button(closeToTrailingLabel) {
          actions.closeToRight(tabId)
        }
        .disabled(isLastTab)
      }

      Button(variant == .canvas ? "Close All Tabs in This Worktree" : "Close All") {
        actions.closeAll()
      }
    }
  }

  private var closeToTrailingLabel: LocalizedStringKey {
    switch variant {
    case .shelf: "Close Tabs Below"
    case .tabBar, .canvas: "Close Tabs to the Right"
    }
  }

  private var isLastTab: Bool {
    guard let last = tabs.last else { return true }
    return last.id == tabId
  }

  private var currentTab: TerminalTabItem? {
    tabs.first { $0.id == tabId }
  }
}
