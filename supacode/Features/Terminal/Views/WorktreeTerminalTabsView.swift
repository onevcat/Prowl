import AppKit
import SwiftUI

struct WorktreeTerminalTabsView: View {
  let worktree: Worktree
  let manager: WorktreeTerminalManager
  let shouldRunSetupScript: Bool
  let forceAutoFocus: Bool
  let createTab: () -> Void
  /// Chrome tint for the tab bar background, matching the toolbar / nav
  /// bands so the bar reads as part of the same tinted chrome. `nil` keeps
  /// the neutral system bar background.
  var barTint: WindowChromeTint.Fill?
  @State private var windowActivity = WindowActivityState.inactive
  @State private var configReloadCounter = 0

  var body: some View {
    let state = manager.state(for: worktree) { shouldRunSetupScript }
    let _ = configReloadCounter
    // The gap between the tab bar and the terminal surface lives inside the
    // tab bar (`TerminalTabBarMetrics.barBottomGap`) so the chrome tint band
    // fills it, rather than a transparent VStack seam that reveals the
    // translucent window background when `background-opacity` < 1.
    VStack(spacing: 0) {
      tabBar(state: state)
      tabContent(state: state)
    }
    .sheet(
      item: Binding(
        get: { state.iconPickerTabId },
        set: { state.iconPickerTabId = $0 }
      )
    ) { tabId in
      iconPickerSheet(state: state, tabId: tabId)
    }
    .background(
      WindowFocusObserverView { activity in
        windowActivity = activity
        state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
      }
    )
    .onAppear {
      state.ensureInitialTab(focusing: false)
      if shouldAutoFocusTerminal {
        state.focusSelectedTab()
      }
      let activity = resolvedWindowActivity
      state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
    }
    .onChange(of: state.tabManager.selectedTabId) { _, _ in
      if shouldAutoFocusTerminal {
        state.focusSelectedTab()
      }
      let activity = resolvedWindowActivity
      state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
    }
    .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
      configReloadCounter &+= 1
    }
  }

  private func tabBar(state: WorktreeTerminalState) -> some View {
    TerminalTabBarView(
      manager: state.tabManager,
      barTint: barTint,
      createTab: createTab,
      splitHorizontally: {
        _ = state.performBindingActionOnFocusedSurface("new_split:down")
      },
      splitVertically: {
        _ = state.performBindingActionOnFocusedSurface("new_split:right")
      },
      canSplit: state.tabManager.selectedTabId != nil,
      renameTab: { tabId in
        state.tabManager.beginTabRename(tabId)
      },
      changeIcon: { tabId in
        state.presentIconPicker(for: tabId)
      },
      closeTab: { tabId in
        state.closeTab(tabId)
      },
      closeOthers: { tabId in
        state.closeOtherTabs(keeping: tabId)
      },
      closeToRight: { tabId in
        state.closeTabsToRight(of: tabId)
      },
      closeAll: {
        state.closeAllTabs()
      },
      hasNotification: { tabId in
        state.hasUnseenNotification(for: tabId)
      }
    )
  }

  @ViewBuilder
  private func tabContent(state: WorktreeTerminalState) -> some View {
    let unfocusedSplitOverlay = manager.unfocusedSplitOverlay()
    let splitDivider = manager.splitDividerAppearance()
    if let selectedId = state.tabManager.selectedTabId {
      TerminalTabContentStack(tabs: state.tabManager.tabs, selectedTabId: selectedId) { tabId in
        TerminalSplitTreeAXContainer(
          tree: state.splitTree(for: tabId),
          activeSurfaceID: state.activeSurfaceID(for: tabId),
          unfocusedSplitOverlay: unfocusedSplitOverlay,
          splitDivider: splitDivider,
          hasNotification: { surfaceID in
            state.hasUnseenNotification(forSurfaceID: surfaceID)
          },
          action: { operation in
            state.performSplitOperation(operation, in: tabId)
          }
        )
      }
    } else {
      EmptyTerminalPaneView(message: String(localized: "No terminals open"))
    }
  }

  private func iconPickerSheet(state: WorktreeTerminalState, tabId: TerminalTabID) -> some View {
    let currentIcon = state.tabManager.tabs.first(where: { $0.id == tabId })?.icon
    return TabIconPickerView(
      initialIcon: currentIcon,
      defaultIcon: TabIconSource(systemSymbol: state.defaultIcon(for: tabId)),
      onApply: { newIcon in
        state.applyIconChange(tabId, icon: newIcon)
        state.dismissIconPicker()
      },
      onCancel: {
        state.dismissIconPicker()
      }
    )
  }

  private var shouldAutoFocusTerminal: Bool {
    if forceAutoFocus {
      return true
    }
    guard let responder = NSApp.keyWindow?.firstResponder else { return true }
    return !(responder is NSTableView) && !(responder is NSOutlineView)
  }

  private var resolvedWindowActivity: WindowActivityState {
    if let keyWindow = NSApp.keyWindow {
      return WindowActivityState(
        isKeyWindow: keyWindow.isKeyWindow,
        isVisible: keyWindow.occlusionState.contains(.visible)
      )
    }
    return windowActivity
  }
}
