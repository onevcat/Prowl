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
  /// (expand/arrange/organize/select-all), e.g. from the command palette.
  var commandRequest: CanvasCommandRequest?
  var onFocusedWorktreeChanged: (Worktree.ID?) -> Void = { _ in }
  var onFocusRequestConsumed: (Int) -> Void = { _ in }
  var onCommandConsumed: (Int) -> Void = { _ in }
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
  let titleBarHeight: CGFloat = 28
  let cardSpacing: CGFloat = 20
  /// Tighter gap for the Tile layout. It lives in the scaled-up tile frame, so
  /// the on-screen gap shrinks further as more cards are tiled (gap × scale).
  let tileCardSpacing: CGFloat = 12
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
    let selectAllCanvasShortcut = AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.selectAllCanvasCards,
      in: resolvedKeybindings
    )
    let arrangeCanvasShortcut = AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.arrangeCanvasCards,
      in: resolvedKeybindings
    )
    let organizeCanvasShortcut = AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.organizeCanvasCards,
      in: resolvedKeybindings
    )
    let tileCanvasShortcut = AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.tileCanvasCards,
      in: resolvedKeybindings
    )
    let expandCanvasShortcut = AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.expandCanvasCard,
      in: resolvedKeybindings
    )
    let _ = configReloadCounter
    CanvasScrollContainer(
      offset: $canvasOffset,
      lastOffset: $lastCanvasOffset,
      scale: $canvasScale,
      lastScale: $lastCanvasScale,
      isInteractionEnabled: expandedTabID == nil
    ) {
      GeometryReader { _ in
        let activeStates = terminalManager.activeWorktreeStates
        let allCardKeys = collectCardKeys(from: activeStates)
        let allTabIDs = collectVisibleTabIDs(from: activeStates)

        // Background layer: handles canvas pan and tap-to-clear.
        Color.clear
          .onAppear {
            if !allCardKeys.isEmpty {
              hasSeenCanvasCards = true
            }
            ensureLayouts(for: allCardKeys)
            if !allCardKeys.isEmpty {
              layoutStore.ensureZOrder(for: allCardKeys)
            }
            pruneSelection(previousOrder: [], currentOrder: allTabIDs, states: activeStates)
            syncBroadcastCallbacks(states: activeStates)
            fulfillPendingFocusRequest(focusRequest, states: activeStates)
          }
          .onChange(of: allCardKeys) { _, newKeys in
            if newKeys.isEmpty {
              CanvasLayoutStore.hasAutoArrangedInSession = false
              if hasSeenCanvasCards {
                layoutStore.prune(to: [])
              }
            } else {
              hasSeenCanvasCards = true
            }
            ensureLayouts(for: newKeys)
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
        let currentCardKeys = collectCardKeys(from: terminalManager.activeWorktreeStates)
        if !hasPerformedInitialFit, !currentCardKeys.isEmpty {
          hasPerformedInitialFit = true
          if !CanvasLayoutStore.hasAutoArrangedInSession {
            CanvasLayoutStore.hasAutoArrangedInSession = true
            if layoutStore.shouldAutoArrangeOnInitialEntry(for: currentCardKeys) {
              switch settingsFile.global.canvasDefaultLayout {
              case .uniform:
                arrangeCards()
              case .tile:
                tileCards()
              }
            }
          }
          fitToView(canvasSize: newSize)
        }
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
    .onKeyPress(
      selectAllCanvasShortcut?.keyEquivalent ?? AppShortcuts.selectAllCanvasCards.keyEquivalent,
      phases: .down
    ) { keyPress in
      // Bail when the binding is disabled in Settings (resolved shortcut is nil);
      // otherwise the app-default key would still fire despite being unbound.
      guard let shortcut = selectAllCanvasShortcut else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      selectAllCards()
      return .handled
    }
    .onKeyPress(
      arrangeCanvasShortcut?.keyEquivalent ?? AppShortcuts.arrangeCanvasCards.keyEquivalent,
      phases: .down
    ) { keyPress in
      guard let shortcut = arrangeCanvasShortcut else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      arrangeCardsWithFit()
      return .handled
    }
    .onKeyPress(
      organizeCanvasShortcut?.keyEquivalent ?? AppShortcuts.organizeCanvasCards.keyEquivalent,
      phases: .down
    ) { keyPress in
      guard let shortcut = organizeCanvasShortcut else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      organizeCardsWithFit()
      return .handled
    }
    .onKeyPress(
      tileCanvasShortcut?.keyEquivalent ?? AppShortcuts.tileCanvasCards.keyEquivalent,
      phases: .down
    ) { keyPress in
      guard let shortcut = tileCanvasShortcut else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      tileCardsWithFit()
      return .handled
    }
    .onKeyPress(
      expandCanvasShortcut?.keyEquivalent ?? AppShortcuts.expandCanvasCard.keyEquivalent,
      phases: .down
    ) { keyPress in
      guard let shortcut = expandCanvasShortcut else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      toggleExpandFocusedCard()
      return .handled
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
          if state.surfaceView(for: tab.id) != nil {
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
    let cardKey = tab.id.rawValue.uuidString
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
    let repositoryAppearance = appearance(for: state.repositoryRootURL)
    let resolvedRepositoryName = repositoryDisplayName(for: state.repositoryRootURL)
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

  // MARK: - Layout

  /// Batch-position all cards that don't have stored layouts yet.
  /// Uses a single, consistent column count to avoid overlap between
  /// cards positioned in different passes.
  func ensureLayouts(for cardKeys: [String]) {
    let unpositioned = cardKeys.filter { layoutStore.cardLayouts[$0] == nil }
    guard !unpositioned.isEmpty else { return }

    // Count only VISIBLE cards that already have layouts (ignores stale entries).
    let positionedCount = cardKeys.count - unpositioned.count
    // For incremental adds, preserve the existing grid shape.
    // For initial layout, use total count for a balanced grid.
    let columns =
      positionedCount > 0
      ? gridColumns(for: positionedCount)
      : gridColumns(for: cardKeys.count)

    // Build locally, assign once to trigger a single save.
    let cardSize = adaptiveDefaultCardSize
    var layouts = layoutStore.cardLayouts
    for (offset, key) in unpositioned.enumerated() {
      layouts[key] = CanvasCardLayout(
        position: gridPosition(index: positionedCount + offset, columns: columns, cardSize: cardSize),
        size: cardSize
      )
    }
    layoutStore.setCardLayouts(layouts)
  }

  /// Balanced grid: columns ≈ sqrt(N). No viewport constraint — the canvas
  /// is infinite and fitToView handles zoom.
  func gridColumns(for count: Int) -> Int {
    max(1, Int(ceil(sqrt(Double(count)))))
  }

  func gridPosition(index: Int, columns: Int, cardSize: CGSize) -> CGPoint {
    let cardW = cardSize.width
    let cardH = cardSize.height + titleBarHeight
    let row = index / columns
    let col = index % columns
    return CGPoint(
      x: cardSpacing + (cardW + cardSpacing) * CGFloat(col) + cardW / 2,
      y: cardSpacing + (cardH + cardSpacing) * CGFloat(row) + cardH / 2
    )
  }

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

  // MARK: - Organize & Fit

  func collectCardKeys(from states: [WorktreeTerminalState]) -> [String] {
    states.flatMap { state in
      state.tabManager.tabs.compactMap { tab in
        state.surfaceView(for: tab.id) != nil ? tab.id.rawValue.uuidString : nil
      }
    }
  }

  func collectVisibleTabIDs(from states: [WorktreeTerminalState]) -> [TerminalTabID] {
    states.flatMap { state in
      state.tabManager.tabs.compactMap { tab in
        state.surfaceView(for: tab.id) != nil ? tab.id : nil
      }
    }
  }

  func collectFocusCandidates(from states: [WorktreeTerminalState]) -> [CanvasFocusCandidate] {
    states.flatMap { state in
      state.tabManager.tabs.compactMap { tab in
        state.surfaceView(for: tab.id) != nil
          ? CanvasFocusCandidate(worktreeID: state.worktreeID, tabID: tab.id)
          : nil
      }
    }
  }

  /// Reset all card positions to a clean grid layout (uniform sizes).
  func organizeCards() {
    let keys = collectCardKeys(from: terminalManager.activeWorktreeStates)
    let columns = gridColumns(for: keys.count)
    let cardSize = adaptiveDefaultCardSize
    var layouts = layoutStore.cardLayouts
    for (index, key) in keys.enumerated() {
      layouts[key] = CanvasCardLayout(
        position: gridPosition(index: index, columns: columns, cardSize: cardSize),
        size: cardSize
      )
    }
    layoutStore.setCardLayouts(layouts, zOrder: keys)
  }

  /// Arrange cards with `CanvasCardPacker`, which chooses between waterfall
  /// and row-break layouts. Preserves each card's current size and finds a
  /// compact layout whose aspect ratio matches the viewport.
  func arrangeCards() {
    let keys = collectCardKeys(from: terminalManager.activeWorktreeStates)
    guard !keys.isEmpty, viewportSize.width > 0, viewportSize.height > 0 else { return }

    let cards: [CanvasCardPacker.CardInfo] = keys.map { key in
      let size = layoutStore.cardLayouts[key]?.size ?? adaptiveDefaultCardSize
      return CanvasCardPacker.CardInfo(key: key, size: size)
    }

    let packer = CanvasCardPacker(spacing: cardSpacing, titleBarHeight: titleBarHeight)
    let targetRatio = viewportSize.width / viewportSize.height
    let result = packer.pack(cards: cards, targetRatio: targetRatio)

    guard !result.layouts.isEmpty else { return }
    layoutStore.setCardLayouts(result.layouts, zOrder: keys)
  }

  /// Tile cards to fill the viewport: resize every card into a balanced grid
  /// whose orientation follows the viewport (rows when wide, columns when tall).
  func tileCards() {
    let keys = collectCardKeys(from: terminalManager.activeWorktreeStates)
    guard !keys.isEmpty, viewportSize.width > 0, viewportSize.height > 0 else { return }

    // Below this card surface, scale the layout up (and the viewport back down)
    // so cards keep enough rows/columns to read at a glance. 0.6 keeps a handful
    // of cards at native scale before the gentle zoom-out begins.
    let comfortableSize = CGSize(
      width: adaptiveDefaultCardSize.width * 0.6,
      height: adaptiveDefaultCardSize.height * 0.6
    )
    let tiler = CanvasTileLayout(spacing: tileCardSpacing, titleBarHeight: titleBarHeight)
    let layouts = tiler.layout(keys: keys, viewport: viewportSize, comfortableSize: comfortableSize)
    guard !layouts.isEmpty else { return }
    layoutStore.setCardLayouts(layouts, zOrder: keys)
  }

  /// Arrange cards (preserving sizes) and refit the viewport, animated.
  /// Shared by the toolbar button and the keyboard shortcut.
  func arrangeCardsWithFit() {
    withAnimation(.easeInOut(duration: 0.2)) {
      cancelExpandForRelayout()
      arrangeCards()
      fitToView(canvasSize: viewportSize)
    }
  }

  /// Organize cards into a uniform grid and refit the viewport, animated.
  /// Shared by the toolbar button and the keyboard shortcut.
  func organizeCardsWithFit() {
    withAnimation(.easeInOut(duration: 0.2)) {
      cancelExpandForRelayout()
      organizeCards()
      fitToView(canvasSize: viewportSize)
    }
  }

  /// Tile cards to fill the viewport and refit, animated. Shared by the toolbar
  /// button and the keyboard shortcut.
  func tileCardsWithFit() {
    withAnimation(.easeInOut(duration: 0.2)) {
      cancelExpandForRelayout()
      tileCards()
      fitToView(canvasSize: viewportSize)
    }
  }

  /// Adjust scale and offset so all cards fit within the viewport.
  func fitToView(canvasSize: CGSize) {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return }

    let keys = collectCardKeys(from: terminalManager.activeWorktreeStates)
    guard !keys.isEmpty else { return }

    var bounds = CGRect.null

    for key in keys {
      guard let layout = layoutStore.cardLayouts[key] else { continue }
      bounds = bounds.union(cardRect(for: layout))
    }

    guard
      let fit = CanvasViewportMath.fit(
        bounds: bounds,
        viewport: canvasSize,
        bottomReserve: bottomToolbarReserve,
        padding: viewportFitPadding
      )
    else {
      return
    }

    canvasOffset = fit.offset
    canvasScale = fit.scale
    lastCanvasScale = fit.scale
    lastCanvasOffset = canvasOffset
  }

  /// Remove stored layouts for tabs that no longer exist.
  func cleanStaleLayouts() {
    let visibleKeys = Set(collectCardKeys(from: terminalManager.activeWorktreeStates))
    guard !visibleKeys.isEmpty || hasSeenCanvasCards else { return }
    layoutStore.prune(to: visibleKeys)
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
          .interfaceFont(.callout)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.bar, in: Capsule())
        }

        Button {
          selectAllCards()
        } label: {
          Image(systemName: "checkmark.rectangle.stack")
            .interfaceFont(.body)
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
        Button {
          arrangeCardsWithFit()
        } label: {
          Image(systemName: "rectangle.3.group")
            .interfaceFont(.body)
            .accessibilityLabel("Arrange")
        }
        .buttonStyle(.bordered)
        .help(
          AppShortcuts.helpText(
            title: "Arrange cards preserving sizes",
            commandID: AppShortcuts.CommandID.arrangeCanvasCards,
            in: resolvedKeybindings
          ))

        Button {
          organizeCardsWithFit()
        } label: {
          Image(systemName: "square.grid.2x2")
            .interfaceFont(.body)
            .accessibilityLabel("Organize")
        }
        .buttonStyle(.bordered)
        .help(
          AppShortcuts.helpText(
            title: "Organize cards in a uniform grid",
            commandID: AppShortcuts.CommandID.organizeCanvasCards,
            in: resolvedKeybindings
          ))

        Button {
          tileCardsWithFit()
        } label: {
          Image(systemName: "rectangle.split.2x1")
            .interfaceFont(.body)
            .accessibilityLabel("Tile")
        }
        .buttonStyle(.bordered)
        .help(
          AppShortcuts.helpText(
            title: "Tile cards to fill the canvas",
            commandID: AppShortcuts.CommandID.tileCanvasCards,
            in: resolvedKeybindings
          ))
      }
    }
    .padding()
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
    if var layout = layoutStore.cardLayouts[cardKey] {
      layout.position.x += translation.width
      layout.position.y += translation.height
      layoutStore.cardLayouts[cardKey] = layout
    }
  }

  // MARK: - Resize

  func commitResize(for tabID: TerminalTabID, cardKey: String, surfaces: [GhosttySurfaceView]) {
    guard activeResize[tabID] != nil else { return }
    if var layout = layoutStore.cardLayouts[cardKey] {
      let resized = resizedFrame(for: tabID, baseLayout: layout)
      // Settle the card into its committed size with a short animation (cards
      // no longer animate size on their own; the canvas drives it explicitly).
      withAnimation(.easeInOut(duration: 0.2)) {
        layout.position = resized.center
        layout.size = resized.size
        layoutStore.cardLayouts[cardKey] = layout
      }
    }
    activeResize[tabID] = nil
    for surface in surfaces {
      surface.needsLayout = true
      surface.needsDisplay = true
    }
  }

  func selectAllCards() {
    let activeStates = terminalManager.activeWorktreeStates
    let allTabIDs = collectVisibleTabIDs(from: activeStates)
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
    layoutStore.moveToFront(tabID.rawValue.uuidString)
    mutateSelection(states: states) { state in
      state.focusSingle(tabID)
    }
  }

  // MARK: - Spatial Navigation

  @discardableResult
  func navigateCard(_ direction: CanvasNavigationDirection) -> Bool {
    guard expandedTabID == nil else { return false }
    let activeStates = terminalManager.activeWorktreeStates
    guard let currentTabID = selectionState.primaryTabID else {
      let allTabIDs = collectVisibleTabIDs(from: activeStates)
      if let first = allTabIDs.first {
        focusSingleCard(first, states: activeStates)
        scrollToRevealCard(first)
      }
      return !allTabIDs.isEmpty
    }

    let entries = cardEntries(from: activeStates)
    let currentKey = currentTabID.rawValue.uuidString
    guard
      let targetKey = CanvasSpatialNavigation.nearest(
        from: currentKey,
        direction: direction,
        cards: entries
      )
    else {
      return true
    }

    let allTabIDs = collectVisibleTabIDs(from: activeStates)
    guard let targetTabID = allTabIDs.first(where: { $0.rawValue.uuidString == targetKey }) else {
      return true
    }

    focusSingleCard(targetTabID, states: activeStates)
    scrollToRevealCard(targetTabID)
    return true
  }

  private func scrollToRevealCard(_ tabID: TerminalTabID) {
    guard viewportSize.width > 0, viewportSize.height > 0 else { return }
    let cardKey = tabID.rawValue.uuidString
    guard let layout = layoutStore.cardLayouts[cardKey] else { return }

    let cardRect = screenRect(for: layout)
    let delta = CanvasViewportMath.revealDelta(
      for: cardRect,
      viewport: viewportSize,
      bottomReserve: bottomToolbarReserve,
      margin: 20
    )

    guard delta != .zero else { return }

    let target = CGSize(
      width: canvasOffset.width + delta.width,
      height: canvasOffset.height + delta.height
    )
    let start = CanvasViewportAnimator.Snapshot(offset: canvasOffset, scale: canvasScale)
    let end = CanvasViewportAnimator.Snapshot(offset: target, scale: canvasScale)
    viewportAnimator.animate(from: start, to: end) { [self] snapshot in
      canvasOffset = snapshot.offset
      lastCanvasOffset = snapshot.offset
    }
  }

  private func cardRect(for layout: CanvasCardLayout) -> CGRect {
    let width = layout.size.width
    let height = layout.size.height + titleBarHeight
    return CGRect(
      x: layout.position.x - width / 2,
      y: layout.position.y - height / 2,
      width: width,
      height: height
    )
  }

  private func screenRect(for layout: CanvasCardLayout) -> CGRect {
    let rect = cardRect(for: layout)
    return CGRect(
      x: rect.minX * canvasScale + canvasOffset.width,
      y: rect.minY * canvasScale + canvasOffset.height,
      width: rect.width * canvasScale,
      height: rect.height * canvasScale
    )
  }

  private func cardEntries(
    from states: [WorktreeTerminalState]
  ) -> [CanvasSpatialNavigation.CardEntry] {
    states.flatMap { state in
      state.tabManager.tabs.compactMap { tab -> CanvasSpatialNavigation.CardEntry? in
        guard state.surfaceView(for: tab.id) != nil else { return nil }
        let key = tab.id.rawValue.uuidString
        guard let layout = layoutStore.cardLayouts[key] else { return nil }
        return CanvasSpatialNavigation.CardEntry(id: key, center: layout.position)
      }
    }
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
