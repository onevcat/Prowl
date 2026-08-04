import SwiftUI

struct TerminalTabsRowView: View {
  @Bindable var manager: TerminalTabManager
  @Binding var openedTabs: [TerminalTabID]
  @Binding var tabLocations: [TerminalTabID: CGRect]
  @Binding var draggingTabId: TerminalTabID?
  @Binding var draggingStartLocation: CGFloat?
  @Binding var closeButtonGestureActive: Bool
  let fixedTabWidth: CGFloat?
  let hasNotification: (TerminalTabID) -> Bool
  let renameTab: (TerminalTabID) -> Void
  let changeIcon: (TerminalTabID) -> Void
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
  let scrollReader: ScrollViewProxy

  @State private var dropTargetIndex: Int?
  @State private var rowFrame: CGRect = .zero
  @Environment(\.interfaceTextScale) private var interfaceTextScale

  var body: some View {
    let metrics = TerminalTabBarMetrics.scaled(interfaceTextScale)
    // Read `tabs` once and index it: the lookup below runs inside a `ForEach`
    // over the same collection, so scanning it per row made each rebuild
    // quadratic — and a rebuild happens whenever any one tab's title changes.
    let tabs = manager.tabs
    let tabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    ZStack(alignment: .topLeading) {
      HStack(alignment: .center, spacing: metrics.tabSpacing) {
        ForEach(Array(openedTabs.enumerated()), id: \.element) { index, id in
          if let item = tabsByID[id] {
            TerminalTabView(
              tab: item,
              isActive: manager.selectedTabId == id,
              isDragging: draggingTabId == id,
              tabIndex: index,
              fixedWidth: fixedTabWidth,
              hasNotification: hasNotification(id),
              onSelect: {
                manager.selectTab(id)
              },
              onClose: {
                closeTab(id)
              },
              onRename: { newTitle in
                manager.setCustomTitle(id, title: newTitle)
              },
              onChangeIcon: {
                changeIcon(id)
              },
              closeButtonGestureActive: $closeButtonGestureActive,
              isEditing: manager.editingTabID == id,
              onBeginRename: {
                manager.beginTabRename(id)
              },
              onEndRename: {
                guard manager.editingTabID == id else { return }
                manager.endTabRename()
              }
            )
            .background(
              TerminalTabMeasurementView(
                tabId: id,
                onFrameChange: { tabId, rect in
                  tabLocations[tabId] = rect
                }
              )
            )
            .simultaneousGesture(makeTabDragGesture(id: id))
            .terminalTabContextMenu(
              tabId: id,
              tabs: tabs,
              actions: TerminalTabContextMenuActions(
                renameTab: renameTab,
                changeIcon: changeIcon,
                closeTab: closeTab,
                closeOthers: closeOthers,
                closeToRight: closeToRight,
                closeAll: closeAll
              )
            )
            .id(id)

            if index < openedTabs.count - 1 {
              // Always keep the divider in the layout and only toggle its
              // opacity, so changing selection never shifts tab positions.
              // Hidden on both sides of the selected tab so it reads as floating.
              let selectedId = manager.selectedTabId
              let touchesSelection = openedTabs[index] == selectedId || openedTabs[index + 1] == selectedId
              TerminalTabDivider()
                .opacity(touchesSelection ? 0 : 1)
            }
          }
        }
      }
      if let offsetX = dropIndicatorOffsetX() {
        Capsule()
          .fill(TerminalTabBarColors.dropIndicator)
          .frame(
            width: metrics.dropIndicatorWidth,
            height: metrics.dropIndicatorHeight
          )
          .offset(
            x: offsetX - (metrics.dropIndicatorWidth / 2),
            y: (metrics.tabHeight - metrics.dropIndicatorHeight) / 2
          )
          .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: offsetX)
      }
    }
    .background(
      GeometryReader { proxy in
        Color.clear
          .onAppear {
            rowFrame = proxy.frame(in: .global)
          }
          .onChange(of: proxy.frame(in: .global)) { _, newFrame in
            rowFrame = newFrame
          }
      }
    )
    .onAppear {
      openedTabs = manager.tabs.map(\.id)
      if let selectedId = manager.selectedTabId {
        scrollReader.scrollTo(selectedId)
      }
    }
    .onChange(of: manager.tabs) { _, newValue in
      let newIds = newValue.map(\.id)
      if openedTabs.count == newIds.count {
        openedTabs = newIds
      } else {
        withAnimation(.easeOut(duration: TerminalTabBarMetrics.closeAnimationDuration)) {
          openedTabs = newIds
        }
      }
      Task { @MainActor in
        try? await ContinuousClock().sleep(for: .seconds(TerminalTabBarMetrics.closeAnimationDuration))
        if let selectedId = manager.selectedTabId {
          withAnimation {
            scrollReader.scrollTo(selectedId)
          }
        }
      }
    }
    .onChange(of: manager.selectedTabId) { _, newValue in
      if let newValue {
        withAnimation {
          scrollReader.scrollTo(newValue)
        }
      }
    }
    .frame(height: metrics.barHeight)
  }

  private func makeTabDragGesture(id: TerminalTabID) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .global)
      .onChanged { value in
        if closeButtonGestureActive {
          return
        }

        if draggingTabId != id {
          draggingTabId = id
          draggingStartLocation = value.startLocation.x
        }

        guard draggingStartLocation != nil,
          openedTabs.contains(id)
        else { return }

        let currentLocation = value.location.x
        updateDropTarget(at: currentLocation)
      }
      .onEnded { _ in
        let draggedId = draggingTabId
        let targetIndex = dropTargetIndex
        draggingStartLocation = nil
        dropTargetIndex = nil
        draggingTabId = nil
        guard let draggedId,
          let targetIndex,
          let sourceIndex = openedTabs.firstIndex(of: draggedId)
        else { return }
        var newOrder = openedTabs
        newOrder.remove(at: sourceIndex)
        let adjustedIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        let safeIndex = min(max(0, adjustedIndex), newOrder.count)
        newOrder.insert(draggedId, at: safeIndex)
        withAnimation(
          .spring(
            duration: TerminalTabBarMetrics.reorderAnimationDuration,
            bounce: TerminalTabBarMetrics.reorderAnimationBounce
          )
        ) {
          openedTabs = newOrder
        }
        manager.reorderTabs(newOrder)
      }
  }

  private func updateDropTarget(at locationX: CGFloat) {
    guard draggingTabId != nil else {
      dropTargetIndex = nil
      return
    }
    let orderedFrames: [(index: Int, frame: CGRect)] = openedTabs.enumerated().compactMap {
      guard let frame = tabLocations[$0.element] else { return nil }
      return (index: $0.offset, frame: frame)
    }
    guard !orderedFrames.isEmpty else {
      dropTargetIndex = nil
      return
    }
    for entry in orderedFrames where locationX < entry.frame.midX {
      dropTargetIndex = entry.index
      return
    }
    dropTargetIndex = orderedFrames.count
  }

  private func dropIndicatorOffsetX() -> CGFloat? {
    guard let dropTargetIndex, !openedTabs.isEmpty else { return nil }
    let lastIndex = openedTabs.count - 1
    if dropTargetIndex <= 0 {
      guard let firstFrame = tabLocations[openedTabs[0]] else { return nil }
      return firstFrame.minX - rowFrame.minX
    }
    if dropTargetIndex > lastIndex {
      guard let lastFrame = tabLocations[openedTabs[lastIndex]] else { return nil }
      return lastFrame.maxX - rowFrame.minX
    }
    guard let frame = tabLocations[openedTabs[dropTargetIndex]] else { return nil }
    return frame.minX - rowFrame.minX
  }
}
