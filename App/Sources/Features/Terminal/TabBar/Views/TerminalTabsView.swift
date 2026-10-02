import SwiftUI

struct TerminalTabsView: View {
  @Bindable var manager: TerminalTabManager
  let renameTab: (TerminalTabID) -> Void
  let changeIcon: (TerminalTabID) -> Void
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
  let hasNotification: (TerminalTabID) -> Bool

  @State private var draggingTabId: TerminalTabID?
  @State private var draggingStartLocation: CGFloat?
  @State private var openedTabs: [TerminalTabID] = []
  @State private var tabLocations: [TerminalTabID: CGRect] = [:]
  @State private var closeButtonGestureActive = false
  @State private var containerWidth: CGFloat = 0

  var body: some View {
    GeometryReader { geometryProxy in
      ScrollViewReader { scrollReader in
        ScrollView(.horizontal) {
          TerminalTabsRowView(
            manager: manager,
            openedTabs: $openedTabs,
            tabLocations: $tabLocations,
            draggingTabId: $draggingTabId,
            draggingStartLocation: $draggingStartLocation,
            closeButtonGestureActive: $closeButtonGestureActive,
            fixedTabWidth: effectiveTabWidth,
            hasNotification: hasNotification,
            renameTab: renameTab,
            changeIcon: changeIcon,
            closeTab: closeTab,
            closeOthers: closeOthers,
            closeToRight: closeToRight,
            closeAll: closeAll,
            scrollReader: scrollReader
          )
          .padding(.horizontal, TerminalTabBarMetrics.barPadding)
        }
        .scrollIndicators(.never)
        .onAppear {
          containerWidth = geometryProxy.size.width
          if let selectedId = manager.selectedTabId {
            scrollReader.scrollTo(selectedId, anchor: .center)
          }
        }
        .onChange(of: geometryProxy.size.width) { _, newWidth in
          containerWidth = newWidth
        }
        .onChange(of: manager.selectedTabId) { _, newTabId in
          if let tabId = newTabId {
            withAnimation(.easeInOut(duration: TerminalTabBarMetrics.selectionAnimationDuration)) {
              scrollReader.scrollTo(tabId, anchor: .center)
            }
          }
        }
      }
    }
  }

  private var effectiveTabWidth: CGFloat? {
    let count = manager.tabs.count
    guard containerWidth > 0, count > 0 else { return nil }
    // Tabs split the bar equally and fill it (no max cap). Once the equal share
    // would dip below the minimum (too many tabs), pin to the minimum so the
    // row overflows and scrolls instead. Account for the row's horizontal
    // padding, inter-tab spacing, and the always-present dividers so a filled
    // row fits exactly — otherwise the leftover overflow lets selection-driven
    // scrollTo(.center) nudge the whole row when picking a middle tab.
    let interTabCount = CGFloat(count - 1)
    let available =
      containerWidth
      - TerminalTabBarMetrics.barPadding * 2
      - TerminalTabBarMetrics.tabSpacing * interTabCount
      - TerminalTabBarMetrics.tabDividerWidth * interTabCount
    let perTab = available / CGFloat(count)
    return max(TerminalTabBarMetrics.tabMinWidth, perTab)
  }
}
