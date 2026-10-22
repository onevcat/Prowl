import AppKit
import Sharing
import SwiftUI

struct CanvasView: View {
  @Environment(CommandKeyObserver.self) var commandKeyObserver
  @Environment(\.resolvedKeybindings) var resolvedKeybindings

  let terminalManager: WorktreeTerminalManager
  /// Per-repo display titles resolved by the parent reducer. Used to
  /// override the folder-derived `Repository.name` on each card title
  /// bar without subscribing to per-repo settings files on the
  /// per-frame canvas hot path.
  var repositoryCustomTitles: [Repository.ID: String] = [:]
  var focusRequest: CanvasFocusRequest?
  /// A one-shot, reducer-driven request to run a view-local canvas command
  /// (expand, layout, select-all, navigate), e.g. from the command palette.
  var commandRequest: CanvasCommandRequest?
  var onFocusedWorktreeChanged: (Worktree.ID?) -> Void = { _ in }
  var onFocusRequestConsumed: (Int) -> Void = { _ in }
  var onCommandConsumed: (Int) -> Void = { _ in }
  /// Canvas is closing with a request it never ran; it must not run later.
  var onCommandDropped: (Int) -> Void = { _ in }
  /// Reports whether a card is currently expanded in place, so the parent can
  /// give the window toolbar a matching scrim (it can't be covered from here).
  var onExpandedChange: (Bool) -> Void = { _ in }
  @State var layoutStore = CanvasLayoutStore()
  @Shared(.repositoryAppearances) var repositoryAppearances
  @Shared(.settingsFile) var settingsFile

  @State var canvasOffset: CGSize = .zero
  @State var lastCanvasOffset: CGSize = .zero
  @State var canvasScale: CGFloat = 1.0
  @State var lastCanvasScale: CGFloat = 1.0
  @State var selectionState = CanvasSelectionState()
  @State var lastTitleBarTapDate: Date = .distantPast
  @State var activeResize: [TerminalTabID: ActiveResize] = [:]
  @State var hasPerformedInitialFit = false
  /// Viewport size the current automatic layout was computed for.
  @State var automaticLayoutViewportSize: CGSize = .zero
  /// A card-set change arrived while a relayout could not run (a card was
  /// expanded or being resized); apply the automatic layout afterwards.
  @State var needsAutomaticRelayout = false
  /// The viewport of the last fit-to-view; a relayout refits only while the
  /// viewport still shows it.
  @State var fittedViewport: CanvasViewportAnimator.Snapshot?
  @State var hasSeenCanvasCards = false
  @State var viewportSize: CGSize = .zero
  @State var configReloadCounter = 0
  @State var focusViewportAnimationID = 0
  /// The tab currently expanded in place (near-fullscreen overlay) on canvas,
  /// or nil when no card is expanded.
  @State var expandedTabID: TerminalTabID?
  @State var viewportAnimator = CanvasViewportAnimator()

  let minCardWidth: CGFloat = 300
  let minCardHeight: CGFloat = 200
  let maxCardWidth: CGFloat = 2400
  let maxCardHeight: CGFloat = 1600
  let layoutMetrics = CanvasLayoutMetrics.standard
  var titleBarHeight: CGFloat { layoutMetrics.titleBarHeight }
  /// Margin kept between a revealed card and the viewport edge.
  let revealMargin: CGFloat = 20
  /// Outer margin kept when fitting the whole canvas into the visible viewport.
  let viewportFitPadding: CGFloat = 12
  /// Reserved height at the bottom of the viewport for the help button and
  /// layout toolbar so cards don't sit underneath them after auto-fit.
  /// Cards end up shifted upward by half of this amount.
  let bottomToolbarReserve: CGFloat = 40
  /// Margin kept on every side of a card temporarily expanded to near-fullscreen.
  let expandPadding: CGFloat = 40
  /// Shared animation for expand / restore / relayout. Matches the easeInOut
  /// 0.2s that `CanvasCardView` uses to animate `cardSize`, so the canvas
  /// scale/offset stays in lock-step with the card's terminal size refit.
  let expandAnimation: Animation = .easeInOut(duration: 0.2)

  /// Width of the screen hosting the canvas window, used to scale the default
  /// card size. Falls back to the large-screen reference when unknown.
  var hostScreenWidth: CGFloat {
    (NSApp.keyWindow?.screen ?? NSScreen.main)?.frame.width
      ?? CanvasCardLayout.maxDefaultScreenWidth
  }

  /// Default size for newly created and uniformly arranged cards, scaled to the
  /// host screen so small screens (14") don't zoom out into tiny text while
  /// large screens still get the roomier card.
  var adaptiveDefaultCardSize: CGSize {
    CanvasCardLayout.adaptiveDefaultSize(forScreenWidth: hostScreenWidth)
  }

  var body: some View {
    let expandCanvasShortcut = AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.expandCanvasCard,
      in: resolvedKeybindings
    )
    let selectAllCanvasShortcut = AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.selectAllCanvasCards,
      in: resolvedKeybindings
    )
    let _ = configReloadCounter
    CanvasScrollContainer(
      offset: $canvasOffset,
      lastOffset: $lastCanvasOffset,
      scale: $canvasScale,
      lastScale: $lastCanvasScale,
      isInteractionEnabled: expandedTabID == nil,
      viewportAnimator: viewportAnimator
    ) {
      GeometryReader { _ in
        let activeStates = terminalManager.activeWorktreeStates
        let cards = canvasCards(in: activeStates)
        let allCardKeys = cards.map(\.key)
        let allTabIDs = cards.map(\.tabID)

        // Background layer: handles canvas pan and tap-to-clear.
        Color.clear
          .onAppear {
            if !allCardKeys.isEmpty {
              hasSeenCanvasCards = true
            }
            // Drop layouts of tabs closed since the last visit first, so new
            // cards are not placed around them.
            cleanStaleLayouts()
            placeUnpositionedCards(allCardKeys)
            if !allCardKeys.isEmpty {
              layoutStore.ensureZOrder(for: allCardKeys)
            }
            pruneSelection(previousOrder: [], currentOrder: allTabIDs, states: activeStates)
            syncBroadcastCallbacks(states: activeStates)
            fulfillPendingFocusRequest(focusRequest, states: activeStates)
            // A request sent just before Canvas showed (e.g. `prowl canvas
            // layout --show`) produces no change event for this new view.
            fulfillCommandRequest(commandRequest)
          }
          .onChange(of: allCardKeys) { oldKeys, newKeys in
            if newKeys.isEmpty {
              if hasSeenCanvasCards {
                layoutStore.prune(to: [])
              }
            } else {
              hasSeenCanvasCards = true
            }
            handleCardSetChange(to: newKeys, appeared: Set(newKeys).subtracting(oldKeys))
            if !newKeys.isEmpty {
              layoutStore.ensureZOrder(for: newKeys)
            }
            syncBroadcastCallbacks(states: activeStates)
            fulfillPendingFocusRequest(focusRequest, states: activeStates)
          }
          .onChange(of: allTabIDs) { oldTabIDs, newTabIDs in
            pruneSelection(previousOrder: oldTabIDs, currentOrder: newTabIDs, states: activeStates)
            if let expandedTabID, !newTabIDs.contains(expandedTabID) {
              cancelExpandForRelayout()
            }
            fulfillPendingFocusRequest(focusRequest, states: activeStates)
          }
          .onChange(of: focusRequest) { _, newRequest in
            fulfillPendingFocusRequest(newRequest, states: activeStates)
          }
          .contentShape(.rect)
          .accessibilityAddTraits(.isButton)
          .onTapGesture { clearSelection(states: activeStates) }
          .gesture(canvasPanGesture, isEnabled: expandedTabID == nil)

        cardsLayer(activeStates: activeStates)
      }
      .contentShape(.rect)
      .simultaneousGesture(canvasZoomGesture, isEnabled: expandedTabID == nil)
      .animation(.easeInOut(duration: 0.22), value: focusViewportAnimationID)
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { newSize in
        viewportSize = newSize
        performEntryLayoutIfNeeded()
      }
      .task(id: viewportSize) {
        await relayoutAfterViewportChange()
      }
    }
    .overlay(alignment: .bottomTrailing) {
      canvasToolbar
    }
    .overlay(alignment: .bottomLeading) {
      CanvasHelpButton()
    }
    .onKeyPress(.escape) {
      guard selectionState.isBroadcasting else { return .ignored }
      clearSelection(states: terminalManager.activeWorktreeStates)
      return .handled
    }
    .onCanvasShortcut(selectAllCanvasShortcut, fallback: AppShortcuts.selectAllCanvasCards) {
      selectAllCards()
    }
    .onCanvasShortcut(layoutShortcut(.arrange), fallback: CanvasLayoutKind.arrange.defaultShortcut) {
      applyLayout(.arrange)
    }
    .onCanvasShortcut(layoutShortcut(.organize), fallback: CanvasLayoutKind.organize.defaultShortcut) {
      applyLayout(.organize)
    }
    .onCanvasShortcut(layoutShortcut(.tile), fallback: CanvasLayoutKind.tile.defaultShortcut) {
      applyLayout(.tile)
    }
    .onCanvasShortcut(expandCanvasShortcut, fallback: AppShortcuts.expandCanvasCard) {
      toggleExpandFocusedCard()
    }
    .onChange(of: expandedTabID) { _, newValue in
      onExpandedChange(newValue != nil)
    }
    .onChange(of: commandRequest) { _, newRequest in
      fulfillCommandRequest(newRequest)
    }
    .task { activateCanvas() }
    .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
      configReloadCounter &+= 1
    }
    .onDisappear { deactivateCanvas() }
  }

  func interactionState(
    for tabID: TerminalTabID,
    in tree: SplitTree<GhosttySurfaceView>
  ) -> (linkActivationRequested: Bool, showsSelectionShield: Bool) {
    let linkActivationRequested = CanvasInteractionPolicy.linkActivationRequested(
      hasHoveredLink: CanvasInteractionPolicy.hasHoveredLink(in: tree),
      isCommandModifierActive: NSEvent.modifierFlags.contains(.command)
    )
    let showsSelectionShield = CanvasInteractionPolicy.showsSelectionShield(
      commandSelectionActive: commandKeyObserver.isPressed,
      selectionModeActive: selectionState.isSelecting,
      broadcastFollower: selectionState.isBroadcasting && selectionState.primaryTabID != tabID,
      linkActivationRequested: linkActivationRequested
    )
    return (linkActivationRequested, showsSelectionShield)
  }

  // MARK: - Cards Layer

  /// Cards layer: one card per open tab across all worktrees.
  /// Uses .offset() (not .position()) to avoid parent size proposals
  /// reaching the NSView, keeping terminal grid stable during zoom.
  @ViewBuilder
  func cardsLayer(activeStates: [WorktreeTerminalState]) -> some View {
    // Pin to .topLeading and fill the viewport so each card's `.offset()` keeps
    // the same (0,0) origin it had under GeometryReader — otherwise the scrim's
    // full-size frame would resize the stack and shift the cards' base position.
    ZStack(alignment: .topLeading) {
      ForEach(activeStates, id: \.worktreeID) { state in
        ForEach(state.tabManager.tabs) { tab in
          if state.hasCanvasCard(tab.id) {
            cardView(for: tab, in: state, activeStates: activeStates)
          }
        }
      }

      // Dimming scrim behind the expanded card (above all other cards). Tapping
      // it — i.e. anywhere outside the expanded card, including the padding —
      // restores the layout.
      if expandedTabID != nil {
        // Material gives a GPU-efficient backdrop blur; a small black overlay
        // adds the dim. The whole scrim is kept partly transparent so the
        // background cards stay clearly visible (still running) behind it.
        Rectangle()
          .fill(.ultraThinMaterial)
          .overlay(Color.black.opacity(0.1))
          .opacity(0.7)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(.rect)
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel("Restore expanded card")
          .onTapGesture { collapseExpand() }
          .zIndex(5_000)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  func cardView(
    for tab: TerminalTabItem,
    in state: WorktreeTerminalState,
    activeStates: [WorktreeTerminalState]
  ) -> some View {
    let tree = state.splitTree(for: tab.id)
    let cardKey = tab.id.canvasCardKey
    let baseLayout = layoutStore.cardLayouts[cardKey] ?? CanvasCardLayout(position: .zero)
    let isCardExpanded = expandedTabID == tab.id
    let expandHelp = AppShortcuts.helpText(
      title: isCardExpanded ? "Restore card size" : "Expand card",
      commandID: AppShortcuts.CommandID.expandCanvasCard,
      in: resolvedKeybindings
    )
    // The expanded card magic-moves between its in-canvas frame and the full
    // viewport. AnimatedExpandableCard drives every sub-value (size, center,
    // scale) from one animatable progress, so they advance frame by frame in
    // lock-step. The canvas transform is never touched → background frozen.
    let fromGeometry = nonExpandedGeometry(for: tab.id, baseLayout: baseLayout)
    let toGeometry = expandedGeometry()
    let unfocusedSplitOverlay = terminalManager.unfocusedSplitOverlay()
    let splitDivider = terminalManager.splitDividerAppearance()
    let repositoryAppearance = appearance(for: state)
    let resolvedRepositoryName = repositoryDisplayName(for: state)
    let interaction = interactionState(for: tab.id, in: tree)

    AnimatedExpandableCard(
      progress: isCardExpanded ? 1 : 0,
      collapsed: fromGeometry,
      expanded: toGeometry,
      titleBarHeight: titleBarHeight
    ) { renderSize in
      CanvasCardView(
        repositoryName: resolvedRepositoryName,
        worktreeName: tab.displayTitle,
        repositoryIcon: repositoryAppearance.icon,
        repositoryColor: repositoryAppearance.color?.color,
        repositoryRootURL: state.repositoryRootURL,
        tree: tree,
        activeSurfaceID: state.activeSurfaceID(for: tab.id),
        unfocusedSplitOverlay: unfocusedSplitOverlay,
        splitDivider: splitDivider,
        isFocused: selectionState.primaryTabID == tab.id,
        isSelected: selectionState.selectedTabIDs.contains(tab.id),
        hasUnseenNotification: state.hasUnseenNotification(for: tab.id),
        tabIcon: tab.iconLock != .auto ? tab.icon : nil,
        tabId: tab.id,
        tabs: state.tabManager.tabs,
        tabContextMenuActions: tabContextMenuActions(for: state),
        cardSize: renderSize,
        isExpanded: isCardExpanded,
        expandHelp: expandHelp,
        canvasScale: isCardExpanded ? 1 : canvasScale,
        linkActivationRequested: interaction.linkActivationRequested,
        showsSelectionShield: interaction.showsSelectionShield,
        onTap: {
          let cmdHeld = NSEvent.modifierFlags.contains(.command)
          if cmdHeld {
            handleSelectionShieldTap(tab.id, surfaceState: state, states: activeStates)
          } else {
            focusSingleCard(tab.id, states: activeStates)
          }
        },
        onSelectionTap: {
          handleSelectionShieldTap(tab.id, surfaceState: state, states: activeStates)
        },
        onDragCommit: { translation in commitDrag(for: cardKey, translation: translation) },
        onResize: { edge, translation in
          activeResize[tab.id] = ActiveResize(
            edge: edge,
            translation: CGSize(
              width: translation.width / canvasScale,
              height: translation.height / canvasScale
            )
          )
        },
        onResizeEnd: { commitResize(for: tab.id, cardKey: cardKey, surfaces: tree.leaves()) },
        onSplitOperation: { operation in
          state.performSplitOperation(operation, in: tab.id)
          if selectionState.isBroadcasting {
            syncBroadcastCallbacks(states: activeStates)
          }
        },
        onTitleBarTap: {
          let wasAlreadyFocused =
            selectionState.primaryTabID == tab.id
            && selectionState.selectedTabIDs.count <= 1
          focusSingleCard(tab.id, states: activeStates)
          let now = Date()
          if wasAlreadyFocused,
            now.timeIntervalSince(lastTitleBarTapDate) <= NSEvent.doubleClickInterval
          {
            toggleExpand(tab.id, states: activeStates)
          }
          lastTitleBarTapDate = now
        },
        onExpand: {
          toggleExpand(tab.id, states: activeStates)
        },
        onClose: {
          state.closeTab(tab.id)
        }
      )
      .sheet(item: iconPickerBinding(for: tab.id, in: state)) { tabId in
        iconPickerSheet(state: state, tabId: tabId)
      }
    }
    // Animatable progress is interpolated by binding the animation to this
    // card's expanded state. A plain withAnimation around expandedTabID doesn't
    // reach here (the GeometryReader's value-scoped .animation swallows the
    // implicit transaction), so drive it explicitly. Only the toggled card's
    // value changes, so the rest stay put.
    .animation(expandAnimation, value: isCardExpanded)
    .hiddenUntilPlaced(layoutStore.cardLayouts[cardKey] != nil)
    .zIndex(zIndex(for: tab.id, cardKey: cardKey))
  }

  func tabContextMenuActions(for state: WorktreeTerminalState) -> TerminalTabContextMenuActions {
    TerminalTabContextMenuActions(
      renameTab: { state.promptChangeTabTitle($0) },
      changeIcon: { state.presentIconPicker(for: $0) },
      closeTab: { state.closeTab($0) },
      closeOthers: { state.closeOtherTabs(keeping: $0) },
      closeToRight: { state.closeTabsToRight(of: $0) },
      closeAll: { state.closeAllTabs() }
    )
  }

  func iconPickerBinding(for tabId: TerminalTabID, in state: WorktreeTerminalState) -> Binding<TerminalTabID?> {
    Binding(
      get: { state.iconPickerTabId == tabId ? tabId : nil },
      set: { state.iconPickerTabId = $0 }
    )
  }

  func iconPickerSheet(state: WorktreeTerminalState, tabId: TerminalTabID) -> some View {
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

  // MARK: - Canvas Gestures

  var canvasPanGesture: some Gesture {
    DragGesture()
      .onChanged { value in
        viewportAnimator.cancel()
        canvasOffset = CGSize(
          width: lastCanvasOffset.width + value.translation.width,
          height: lastCanvasOffset.height + value.translation.height
        )
      }
      .onEnded { _ in
        lastCanvasOffset = canvasOffset
      }
  }

  var canvasZoomGesture: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        viewportAnimator.cancel()
        let newScale = max(0.25, min(2.0, lastCanvasScale * value.magnification))
        let anchor = value.startLocation

        // Keep the canvas point under the pinch center fixed:
        // screenPos = canvasPoint * scale + offset
        // → canvasPoint = (anchor - lastOffset) / lastScale
        // → newOffset  = anchor - canvasPoint * newScale
        let canvasX = (anchor.x - lastCanvasOffset.width) / lastCanvasScale
        let canvasY = (anchor.y - lastCanvasOffset.height) / lastCanvasScale

        canvasOffset = CGSize(
          width: anchor.x - canvasX * newScale,
          height: anchor.y - canvasY * newScale
        )
        canvasScale = newScale
      }
      .onEnded { _ in
        lastCanvasScale = canvasScale
        lastCanvasOffset = canvasOffset
      }
  }

  // MARK: - Card Geometry

  /// Compute effective center and size accounting for resize only (not drag).
  /// Drag is applied separately via `.offset()` to avoid layout passes.
  func resizedFrame(
    for tabID: TerminalTabID,
    baseLayout: CanvasCardLayout
  ) -> (center: CGPoint, size: CGSize) {
    var centerX = baseLayout.position.x
    var centerY = baseLayout.position.y
    var width = baseLayout.size.width
    var height = baseLayout.size.height

    if let resize = activeResize[tabID] {
      let (wSign, hSign) = resize.edge.resizeSigns
      if wSign != 0 {
        let newW = clampWidth(width + CGFloat(wSign) * resize.translation.width)
        centerX += CGFloat(wSign) * (newW - width) / 2
        width = newW
      }
      if hSign != 0 {
        let newH = clampHeight(height + CGFloat(hSign) * resize.translation.height)
        centerY += CGFloat(hSign) * (newH - height) / 2
        height = newH
      }
    }

    return (CGPoint(x: centerX, y: centerY), CGSize(width: width, height: height))
  }

  func screenPosition(for canvasCenter: CGPoint) -> CGPoint {
    CGPoint(
      x: canvasCenter.x * canvasScale + canvasOffset.width,
      y: canvasCenter.y * canvasScale + canvasOffset.height
    )
  }

  func clampWidth(_ width: CGFloat) -> CGFloat {
    max(minCardWidth, min(maxCardWidth, width))
  }

  func clampHeight(_ height: CGFloat) -> CGFloat {
    max(minCardHeight, min(maxCardHeight, height))
  }

  var canvasToolbar: some View {
    // Two visual groups: selection (broadcast / select-all) and the three layout
    // actions. A wider gap separates the groups; the layout trio is tucked tight.
    HStack(spacing: 14) {
      HStack(spacing: 8) {
        if selectionState.isBroadcasting {
          Label(
            "Broadcasting to \(selectionState.selectedTabIDs.count) cards",
            systemImage: "dot.radiowaves.left.and.right"
          )
          .font(.callout)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.bar, in: Capsule())
        }

        Button {
          selectAllCards()
        } label: {
          Image(systemName: "checkmark.rectangle.stack")
            .font(.body)
            .accessibilityLabel("Select All")
        }
        .buttonStyle(.bordered)
        .help(
          AppShortcuts.helpText(
            title: "Select all cards for broadcast",
            commandID: AppShortcuts.CommandID.selectAllCanvasCards,
            in: resolvedKeybindings
          ))
      }

      HStack(spacing: 4) {
        ForEach(CanvasLayoutKind.allCases, id: \.self) { kind in
          layoutButton(kind, isActive: layoutStore.mode?.automaticKind == kind)
        }
      }
    }
    .padding()
  }

  /// A layout button. The active automatic layout is tinted, so the user can
  /// tell that new and closed cards will follow it.
  func layoutButton(_ kind: CanvasLayoutKind, isActive: Bool) -> some View {
    Button {
      applyLayout(kind)
    } label: {
      Image(systemName: kind.systemImage)
        .font(.body)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        .accessibilityLabel(Text(kind.title))
    }
    .buttonStyle(.bordered)
    .tint(isActive ? Color.accentColor : nil)
    .accessibilityAddTraits(isActive ? .isSelected : [])
    .help(
      AppShortcuts.helpText(
        title: isActive ? kind.activeHelpTitle : kind.helpTitle,
        commandID: kind.commandID,
        in: resolvedKeybindings
      ))
  }

  func zIndex(for tabID: TerminalTabID, cardKey: String) -> Double {
    let base = layoutStore.zIndex(for: cardKey)
    if selectionState.primaryTabID == tabID {
      return 10_000 + base
    }
    if selectionState.selectedTabIDs.contains(tabID) {
      return 9_000 + base
    }
    return base
  }

  // MARK: - Drag

  func commitDrag(for cardKey: String, translation: CGSize) {
    guard translation != .zero, var layout = layoutStore.cardLayouts[cardKey] else { return }
    layout.position.x += translation.width
    layout.position.y += translation.height
    layoutStore.cardLayouts[cardKey] = layout
    enterFreeformLayout()
  }

  // MARK: - Resize

  func commitResize(for tabID: TerminalTabID, cardKey: String, surfaces: [GhosttySurfaceView]) {
    guard activeResize[tabID] != nil else { return }
    if var layout = layoutStore.cardLayouts[cardKey] {
      let resized = resizedFrame(for: tabID, baseLayout: layout)
      if resized.center != layout.position || resized.size != layout.size {
        // Settle the card into its committed size with a short animation (cards
        // no longer animate size on their own; the canvas drives it explicitly).
        withAnimation(.easeInOut(duration: 0.2)) {
          layout.position = resized.center
          layout.size = resized.size
          layoutStore.cardLayouts[cardKey] = layout
        }
        enterFreeformLayout()
      }
    }
    activeResize[tabID] = nil
    // A card-set change that waited for this resize; a resize that changed
    // nothing keeps the automatic layout, so it must still run.
    relayoutIfDeferred()
    for surface in surfaces {
      surface.needsLayout = true
      surface.needsDisplay = true
    }
  }

  func selectAllCards() {
    let activeStates = terminalManager.activeWorktreeStates
    let allTabIDs = canvasCards(in: activeStates).map(\.tabID)
    guard allTabIDs.count > 1 else { return }
    mutateSelection(states: activeStates) { state in
      state.selectAll(allTabIDs)
    }
  }

  // MARK: - Selection and Focus

  func focusSingleCard(
    _ tabID: TerminalTabID,
    states: [WorktreeTerminalState]
  ) {
    layoutStore.moveToFront(tabID.canvasCardKey)
    mutateSelection(states: states) { state in
      state.focusSingle(tabID)
    }
  }

  // MARK: - Spatial Navigation

  @discardableResult
  func navigateCard(_ direction: CanvasNavigationDirection) -> Bool {
    guard expandedTabID == nil else { return false }
    let activeStates = terminalManager.activeWorktreeStates
    let cards = canvasCards(in: activeStates)
    guard let currentTabID = selectionState.primaryTabID else {
      if let first = cards.first {
        focusSingleCard(first.tabID, states: activeStates)
        revealCard(first.tabID, allowsZoomOut: false)
      }
      return !cards.isEmpty
    }

    let entries = cards.compactMap { card -> CanvasSpatialNavigation.CardEntry? in
      guard let layout = layoutStore.cardLayouts[card.key] else { return nil }
      return CanvasSpatialNavigation.CardEntry(id: card.key, center: layout.position)
    }
    guard
      let targetKey = CanvasSpatialNavigation.nearest(
        from: currentTabID.canvasCardKey,
        direction: direction,
        cards: entries
      ),
      let target = cards.first(where: { $0.key == targetKey })
    else {
      return true
    }

    focusSingleCard(target.tabID, states: activeStates)
    revealCard(target.tabID, allowsZoomOut: false)
    return true
  }

  // MARK: - Expand In Place

  var expandMetrics: CanvasExpandGeometry.Metrics {
    CanvasExpandGeometry.Metrics(
      padding: expandPadding,
      bottomReserve: bottomToolbarReserve,
      titleBarHeight: titleBarHeight,
      minSize: CGSize(width: minCardWidth, height: minCardHeight)
    )
  }

  /// Screen-space center for a fully expanded card: horizontally centered and
  /// within the toolbar-adjusted viewport. Independent of canvas pan/zoom.
  var expandedScreenCenter: CGPoint {
    CGPoint(x: viewportSize.width / 2, y: (viewportSize.height - bottomToolbarReserve) / 2)
  }

  /// A card's normal (non-expanded) on-screen frame, following the canvas
  /// pan/zoom and any in-progress resize. This is the `progress = 0` endpoint of
  /// the expand magic-move.
  func nonExpandedGeometry(
    for tabID: TerminalTabID,
    baseLayout: CanvasCardLayout
  ) -> CardScreenGeometry {
    let resized = resizedFrame(for: tabID, baseLayout: baseLayout)
    return CardScreenGeometry(
      size: resized.size,
      center: screenPosition(for: resized.center),
      scale: canvasScale
    )
  }

  /// The full-viewport expanded frame at scale 1 — the `progress = 1` endpoint.
  /// Independent of the canvas transform, so it covers the viewport regardless
  /// of the (frozen) background.
  func expandedGeometry() -> CardScreenGeometry {
    CardScreenGeometry(
      size: CanvasExpandGeometry.expandedSize(viewport: viewportSize, metrics: expandMetrics),
      center: expandedScreenCenter,
      scale: 1
    )
  }

  /// Toggle expand/restore for a card — used by the title-bar button and the
  /// title-bar double-click.
  func toggleExpand(_ tabID: TerminalTabID, states: [WorktreeTerminalState]) {
    if expandedTabID == tabID {
      collapseExpand()
    } else {
      expandCard(tabID, states: states)
    }
  }

  /// Toggle expand/restore for the focused (primary) card. Used by the keyboard
  /// shortcut and the command palette, which target whichever card is focused.
  func toggleExpandFocusedCard() {
    if expandedTabID != nil {
      collapseExpand()
    } else if let tabID = selectionState.primaryTabID {
      expandCard(tabID, states: terminalManager.activeWorktreeStates)
    }
  }
}

extension View {
  /// A new card renders once before it gets a spot. Keep it invisible (but
  /// mounted, so its terminal can take focus) until then, and let it appear at
  /// its spot rather than fly there from the canvas origin.
  fileprivate func hiddenUntilPlaced(_ isPlaced: Bool) -> some View {
    opacity(isPlaced ? 1 : 0)
      .animation(nil, value: isPlaced)
  }

  /// Run `action` when the canvas has focus and `shortcut` is pressed. The
  /// handler listens on the app-default key when the binding is disabled
  /// (`shortcut == nil`), so it must ignore the press rather than fire.
  fileprivate func onCanvasShortcut(
    _ shortcut: AppShortcut?,
    fallback: AppShortcut,
    perform action: @escaping () -> Void
  ) -> some View {
    onKeyPress(shortcut?.keyEquivalent ?? fallback.keyEquivalent, phases: .down) { keyPress in
      guard let shortcut, keyPress.modifiers == shortcut.modifiers else { return .ignored }
      action()
      return .handled
    }
  }
}
