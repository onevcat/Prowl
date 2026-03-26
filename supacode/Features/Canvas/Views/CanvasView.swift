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
  @State var showsCanvasHelp = false
  @State var configReloadCounter = 0
  @State var focusViewportAnimationID = 0
  @State var wrapToastDismissTask: Task<Void, Never>?
  @State var canvasWrapToastMessage: String?
  @State var directoryDisplayCache: [TerminalTabID: CanvasDirectoryDisplayCacheEntry] = [:]
  @State var directoryLatestTokens: [TerminalTabID: CanvasDirectoryShorteningCoordinator.Token] = [:]
  @State var directoryInFlightTasks: [TerminalTabID: Task<Void, Never>] = [:]
  @State var directoryLastRequestedPath: [TerminalTabID: String] = [:]
  @State var directoryShorteningService = CanvasDirectoryShorteningService(
    fileSystem: LiveCanvasDirectoryFileSystem(),
    policy: CanvasDirectoryShorteningPolicy(),
    homePath: ProcessInfo.processInfo.environment["HOME"] ?? "/"
  )
  /// The tab currently expanded in place (near-fullscreen overlay) on canvas,
  /// or nil when no card is expanded.
  @State var expandedTabID: TerminalTabID?

  let focusVisibleInset: CGFloat = 20
  let focusBottomReservedInset: CGFloat = 36
  let minCardWidth: CGFloat = 300
  let minCardHeight: CGFloat = 200
  let maxCardWidth: CGFloat = 2400
  let maxCardHeight: CGFloat = 1600
  let titleBarHeight: CGFloat = 28
  let cardSpacing: CGFloat = 20
  /// Reserved height at the bottom of the viewport for the help button and
  /// layout toolbar so cards don't sit underneath them after auto-fit.
  /// Cards end up shifted upward by half of this amount.
  let bottomToolbarReserve: CGFloat = 50
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
          .onChange(of: allCardKeys) { _, _ in
            let latestStates = terminalManager.activeWorktreeStates
            let latestKeys = collectCardKeys(from: latestStates)
            if latestKeys.isEmpty {
              CanvasLayoutStore.hasAutoArrangedInSession = false
              if hasSeenCanvasCards {
                layoutStore.prune(to: [])
              }
            } else {
              hasSeenCanvasCards = true
            }
            ensureLayouts(for: latestKeys)
            if !latestKeys.isEmpty {
              layoutStore.ensureZOrder(for: latestKeys)
            }
            syncBroadcastCallbacks(states: latestStates)
            recoverCanvasFocusIfNeeded(states: latestStates)
            fulfillPendingFocusRequest(focusRequest, states: latestStates)
          }
          .onChange(of: allTabIDs) { oldTabIDs, _ in
            let latestStates = terminalManager.activeWorktreeStates
            ensureLayouts(for: collectCardKeys(from: latestStates))
            let latestTabIDs = collectVisibleTabIDs(from: latestStates)
            pruneSelection(previousOrder: oldTabIDs, currentOrder: latestTabIDs, states: latestStates)
            if let expandedTabID, !latestTabIDs.contains(expandedTabID) {
              cancelExpandForRelayout()
            }
            pruneDirectoryShorteningState(keeping: latestStates)
            recoverCanvasFocusIfNeeded(states: latestStates)
            fulfillPendingFocusRequest(focusRequest, states: latestStates)
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
              arrangeCards()
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
      canvasHelpButton
    }
    .overlay {
      canvasWrapToast
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .visualEffect { content, proxy in
          content.offset(y: proxy.size.height / 3)
        }
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
    .onDisappear {
      deactivateCanvas()
      cancelWrapToastTask()
      cancelAllDirectoryShorteningRequests()
    }
    .focusedSceneValue(\.canvasMoveLeftAction) { focusAdjacentCanvasTab(direction: .left) }
    .focusedSceneValue(\.canvasMoveDownAction) { focusAdjacentCanvasTab(direction: .down) }
    .focusedSceneValue(\.canvasMoveUpAction) { focusAdjacentCanvasTab(direction: .up) }
    .focusedSceneValue(\.canvasMoveRightAction) { focusAdjacentCanvasTab(direction: .right) }
  }

  func showsSelectionShield(for tabID: TerminalTabID) -> Bool {
    if commandKeyObserver.isPressed { return true }
    if selectionState.isSelecting { return true }
    if selectionState.isBroadcasting, selectionState.primaryTabID != tabID { return true }
    return false
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
        Group {
          ForEach(state.tabManager.tabs) { tab in
            if state.surfaceView(for: tab.id) != nil {
              cardView(for: tab, in: state, activeStates: activeStates)
            }
          }
        }
        .onChange(of: state.tabManager.selectedTabId) { _, _ in
          syncFocusToSelectedTab(in: state, states: terminalManager.activeWorktreeStates)
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
    let currentDirectoryPath = state.surfaceView(for: tab.id)?.bridge.state.pwd
      ?? state.repositoryRootURL.path(percentEncoded: false)
    let normalizedDisplayPath = CanvasCurrentDirectoryFormatter.displayPath(for: currentDirectoryPath)
    let titleSegments = canvasCardTitleSegments(
      currentDirectoryPath: currentDirectoryPath,
      tabTitle: tab.displayTitle,
      fallbackWorktreeName: state.worktreeName,
      cachedDirectoryEntry: directoryDisplayCache[tab.id]
    )

    AnimatedExpandableCard(
      progress: isCardExpanded ? 1 : 0,
      collapsed: fromGeometry,
      expanded: toGeometry,
      titleBarHeight: titleBarHeight
    ) { renderSize in
      CanvasCardView(
        repositoryName: resolvedRepositoryName,
        currentDirectory: titleSegments.currentDirectory,
        worktreeName: titleSegments.worktreeName,
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
        cardSize: renderSize,
        isExpanded: isCardExpanded,
        expandHelp: expandHelp,
        canvasScale: isCardExpanded ? 1 : canvasScale,
        showsSelectionShield: showsSelectionShield(for: tab.id),
        onTap: {
          let cmdHeld = NSEvent.modifierFlags.contains(.command)
          if cmdHeld {
            handleSelectionShieldTap(tab.id, surfaceState: state, states: activeStates)
          } else {
            focusSingleCard(tab.id, states: activeStates, ensureVisibleInViewport: true)
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
    }
    // Animatable progress is interpolated by binding the animation to this
    // card's expanded state. A plain withAnimation around expandedTabID doesn't
    // reach here (the GeometryReader's value-scoped .animation swallows the
    // implicit transaction), so drive it explicitly. Only the toggled card's
    // value changes, so the rest stay put.
    .animation(expandAnimation, value: isCardExpanded)
    .zIndex(zIndex(for: tab.id, cardKey: cardKey))
    .onAppear {
      requestDirectoryShortening(for: tab.id, normalizedDisplayPath: normalizedDisplayPath)
    }
    .onChange(of: normalizedDisplayPath) { _, newDisplayPath in
      requestDirectoryShortening(for: tab.id, normalizedDisplayPath: newDisplayPath)
    }
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

  /// Arrange cards using MaxRects-BSSF bin packing. Preserves each card's
  /// current size and finds a compact layout whose aspect ratio matches
  /// the viewport.
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

  /// Adjust scale and offset so all cards fit within the viewport.
  func fitToView(canvasSize: CGSize) {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return }

    let keys = collectCardKeys(from: terminalManager.activeWorktreeStates)
    guard !keys.isEmpty else { return }

    // Bounding box of all cards in canvas coordinates
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity

    for key in keys {
      guard let layout = layoutStore.cardLayouts[key] else { continue }
      let halfW = layout.size.width / 2
      let halfH = (layout.size.height + titleBarHeight) / 2
      minX = min(minX, layout.position.x - halfW)
      minY = min(minY, layout.position.y - halfH)
      maxX = max(maxX, layout.position.x + halfW)
      maxY = max(maxY, layout.position.y + halfH)
    }

    guard minX.isFinite else { return }

    let padding: CGFloat = 30
    let bboxW = maxX - minX + padding * 2
    let bboxH = maxY - minY + padding * 2
    let bboxCenterX = (minX + maxX) / 2
    let bboxCenterY = (minY + maxY) / 2

    let newScale = max(0.25, min(1.0, min(canvasSize.width / bboxW, canvasSize.height / bboxH)))

    canvasOffset = CGSize(
      width: canvasSize.width / 2 - bboxCenterX * newScale,
      height: (canvasSize.height - bottomToolbarReserve) / 2 - bboxCenterY * newScale
    )
    canvasScale = newScale
    lastCanvasScale = newScale
    lastCanvasOffset = canvasOffset
  }

  /// Remove stored layouts for tabs that no longer exist.
  func cleanStaleLayouts() {
    let visibleKeys = Set(collectCardKeys(from: terminalManager.activeWorktreeStates))
    guard !visibleKeys.isEmpty || hasSeenCanvasCards else { return }
    layoutStore.prune(to: visibleKeys)
  }

  var canvasHelpButton: some View {
    Button {
      showsCanvasHelp.toggle()
    } label: {
      Image(systemName: "questionmark.circle")
        .font(.body)
        .accessibilityLabel("Canvas navigation help")
    }
    .buttonStyle(.bordered)
    .help("Canvas navigation help")
    .popover(isPresented: $showsCanvasHelp, arrowEdge: .bottom) {
      canvasHelpContent
    }
    .padding()
  }

  var canvasHelpContent: some View {
    let expandShortcut = AppShortcuts.display(
      for: AppShortcuts.CommandID.expandCanvasCard,
      in: resolvedKeybindings
    )
    return VStack(alignment: .leading, spacing: 14) {
      Text("Canvas Navigation")
        .font(.headline)

      VStack(alignment: .leading, spacing: 12) {
        canvasHelpRow(
          icon: "plus.magnifyingglass",
          title: "Zoom in/out",
          detail: "⌘ + scroll, or pinch gesture"
        )
        canvasHelpRow(
          icon: "hand.draw",
          title: "Pan canvas",
          detail: "Drag empty area, middle-click drag, or two-finger swipe"
        )
        canvasHelpRow(
          icon: "arrow.up.left.and.arrow.down.right",
          title: "Expand / restore card",
          detail: expandShortcut.map { "\($0), or the card's title-bar button" }
            ?? "Use the card's title-bar button"
        )
      }
    }
    .padding()
    .frame(width: 320, alignment: .leading)
  }

  func canvasHelpRow(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout).fontWeight(.medium)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  var canvasToolbar: some View {
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

      Button {
        arrangeCardsWithFit()
      } label: {
        Image(systemName: "rectangle.3.group")
          .font(.body)
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
          .font(.body)
          .accessibilityLabel("Organize")
      }
      .buttonStyle(.bordered)
      .help(
        AppShortcuts.helpText(
          title: "Organize cards in a uniform grid",
          commandID: AppShortcuts.CommandID.organizeCanvasCards,
          in: resolvedKeybindings
        ))
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

  func requestDirectoryShortening(for tabID: TerminalTabID, normalizedDisplayPath: String?) {
    guard let normalizedDisplayPath else {
      if let existing = directoryInFlightTasks.removeValue(forKey: tabID) {
        existing.cancel()
      }
      directoryLatestTokens.removeValue(forKey: tabID)
      directoryLastRequestedPath.removeValue(forKey: tabID)
      directoryDisplayCache.removeValue(forKey: tabID)
      return
    }

    guard directoryLastRequestedPath[tabID] != normalizedDisplayPath else { return }
    directoryLastRequestedPath[tabID] = normalizedDisplayPath
    directoryDisplayCache.removeValue(forKey: tabID)

    let token = CanvasDirectoryShorteningCoordinator.nextToken(for: tabID, tokens: &directoryLatestTokens)
    let service = directoryShorteningService
    let task = Task {
      let shortened = await service.shortenedDisplayPath(for: normalizedDisplayPath) ?? normalizedDisplayPath
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard
          CanvasDirectoryShorteningCoordinator.shouldApply(
            token: token,
            for: tabID,
            latestTokens: directoryLatestTokens
          )
        else { return }
        directoryDisplayCache[tabID] = CanvasDirectoryDisplayCacheEntry(
          normalizedDisplayPath: normalizedDisplayPath,
          shortenedDisplayPath: shortened
        )
        directoryInFlightTasks.removeValue(forKey: tabID)
      }
    }

    let previousTask = CanvasDirectoryShorteningCoordinator.replaceInFlightRequest(
      for: tabID,
      with: task,
      requests: &directoryInFlightTasks
    )
    previousTask?.cancel()
  }

  func pruneDirectoryShorteningState(keeping states: [WorktreeTerminalState]) {
    let activeTabIDs = activeCanvasTabIDs(from: states)
    let cancelled = CanvasDirectoryShorteningCoordinator.pruneRequests(
      keeping: activeTabIDs,
      requests: &directoryInFlightTasks
    )
    for task in cancelled {
      task.cancel()
    }
    pruneDictionary(keeping: activeTabIDs, dictionary: &directoryLatestTokens)
    pruneDictionary(keeping: activeTabIDs, dictionary: &directoryLastRequestedPath)
    pruneDictionary(keeping: activeTabIDs, dictionary: &directoryDisplayCache)
  }

  func activeCanvasTabIDs(from states: [WorktreeTerminalState]) -> Set<TerminalTabID> {
    Set(
      states.flatMap { state in
        state.tabManager.tabs.compactMap { tab in
          state.surfaceView(for: tab.id) != nil ? tab.id : nil
        }
      }
    )
  }

  func pruneDictionary<Value>(
    keeping activeTabIDs: Set<TerminalTabID>,
    dictionary: inout [TerminalTabID: Value]
  ) {
    let staleIDs = dictionary.keys.filter { !activeTabIDs.contains($0) }
    for staleID in staleIDs {
      dictionary.removeValue(forKey: staleID)
    }
  }

  func cancelAllDirectoryShorteningRequests() {
    for task in directoryInFlightTasks.values {
      task.cancel()
    }
    directoryInFlightTasks.removeAll()
    directoryLatestTokens.removeAll()
    directoryLastRequestedPath.removeAll()
    directoryDisplayCache.removeAll()
  }

  var canvasWrapToast: some View {
    Group {
      if let message = canvasWrapToastMessage {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.headline.weight(.semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
          Text(message)
            .font(.body)
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
          Capsule()
            .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(radius: 8, y: 2)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: canvasWrapToastMessage)
  }

  func showWrapToast(for direction: CanvasNavigationDirection) {
    cancelWrapToastTask()
    withAnimation(.easeInOut(duration: 0.2)) {
      canvasWrapToastMessage = wrapToastMessage(for: direction)
    }
    wrapToastDismissTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        canvasWrapToastMessage = nil
      }
      wrapToastDismissTask = nil
    }
  }

  func wrapToastMessage(for direction: CanvasNavigationDirection) -> String {
    switch direction {
    case .left:
      "Right"
    case .right:
      "Left"
    case .up:
      "Bottom"
    case .down:
      "Top"
    }
  }

  func cancelWrapToastTask() {
    wrapToastDismissTask?.cancel()
    wrapToastDismissTask = nil
  }

  // MARK: - Drag

  func commitDrag(for cardKey: String, translation: CGSize) {
    if var layout = layoutStore.cardLayouts[cardKey] {
      layout.position.x += translation.width
      layout.position.y += translation.height
      layoutStore.cardLayouts[cardKey] = layout
    }
  }

  // MARK: - Keyboard Navigation

  typealias CanvasNavigationDirection = CanvasTabNavigator.Direction

  struct CanvasTabTarget {
    let state: WorktreeTerminalState
    let tabID: TerminalTabID
    let center: CGPoint
    let size: CGSize
  }

  struct CanvasTabNavigationTarget {
    let tab: CanvasTabTarget
    let didWrap: Bool
  }

  func focusAdjacentCanvasTab(direction: CanvasNavigationDirection) {
    let states = terminalManager.activeWorktreeStates
    ensureLayouts(for: collectCardKeys(from: states))
    let tabs = visibleCanvasTabs(from: states)
    guard !tabs.isEmpty else { return }
    guard let current = currentCanvasTab(from: tabs) else { return }
    guard let navigationTarget = candidateCanvasTab(from: current, direction: direction, tabs: tabs) else {
      return
    }
    focusCanvasTab(navigationTarget.tab, states: states, animatesViewport: false)
    let navigationEntries = tabs.map { tab in
      CanvasTabNavigator.Entry(
        id: tab.tabID,
        center: tab.center,
        size: tab.size
      )
    }
    if shouldShowCanvasWrapToast(
      direction: direction,
      didWrap: navigationTarget.didWrap,
      viewportSize: viewportSize,
      canvasOffset: canvasOffset,
      canvasScale: canvasScale,
      entries: navigationEntries
    ) {
      showWrapToast(for: direction)
    }
  }

  func visibleCanvasTabs(from states: [WorktreeTerminalState]) -> [CanvasTabTarget] {
    states.flatMap { state in
      state.tabManager.tabs.compactMap { tab in
        guard state.surfaceView(for: tab.id) != nil else { return nil }
        let key = tab.id.rawValue.uuidString
        let baseLayout = layoutStore.cardLayouts[key] ?? CanvasCardLayout(position: .zero)
        let resized = resizedFrame(for: tab.id, baseLayout: baseLayout)
        return CanvasTabTarget(
          state: state,
          tabID: tab.id,
          center: resized.center,
          size: CGSize(width: resized.size.width, height: resized.size.height + titleBarHeight)
        )
      }
    }
  }

  func currentCanvasTab(from tabs: [CanvasTabTarget]) -> CanvasTabTarget? {
    if let primaryTabID = selectionState.primaryTabID,
      let focused = tabs.first(where: { $0.tabID == primaryTabID })
    {
      return focused
    }
    if let selected = tabs.first(where: { $0.state.tabManager.selectedTabId == $0.tabID }) {
      return selected
    }
    return tabs.first
  }

  func candidateCanvasTab(
    from current: CanvasTabTarget,
    direction: CanvasNavigationDirection,
    tabs: [CanvasTabTarget]
  ) -> CanvasTabNavigationTarget? {
    let entries = tabs.map { tab in
      CanvasTabNavigator.Entry(
        id: tab.tabID,
        center: tab.center,
        size: tab.size
      )
    }
    guard
      let nextTarget = CanvasTabNavigator.nextTarget(
        from: current.tabID,
        direction: direction,
        entries: entries
      )
    else { return nil }
    guard let tab = tabs.first(where: { $0.tabID == nextTarget.id }) else { return nil }
    return CanvasTabNavigationTarget(tab: tab, didWrap: nextTarget.didWrap)
  }

  func focusCanvasTab(
    _ target: CanvasTabTarget,
    states: [WorktreeTerminalState],
    animatesViewport: Bool = true
  ) {
    focusSingleCard(
      target.tabID,
      states: states,
      ensureVisibleInViewport: true,
      animatesViewport: animatesViewport
    )
  }

  func syncFocusToSelectedTab(in state: WorktreeTerminalState, states: [WorktreeTerminalState]) {
    guard let selectedTabID = state.tabManager.selectedTabId else {
      recoverCanvasFocusIfNeeded(states: states)
      return
    }
    guard selectionState.primaryTabID != selectedTabID else { return }
    mutateSelection(states: states) { currentState in
      if currentState.isBroadcasting, currentState.selectedTabIDs.contains(selectedTabID) {
        currentState.setPrimary(selectedTabID)
      } else {
        currentState.focusSingle(selectedTabID)
      }
    }
    ensureTabVisibleInViewport(selectedTabID, minimumInset: focusVisibleInset)
  }

  func recoverCanvasFocusIfNeeded(states: [WorktreeTerminalState]) {
    let tabs = visibleCanvasTabs(from: states)
    let candidates = tabs.map { tab in
      CanvasFocusFallbackCandidate(
        id: tab.tabID,
        center: tab.center,
        size: tab.size,
        isSelected: tab.state.tabManager.selectedTabId == tab.tabID
      )
    }
    guard let targetTabID = canvasFallbackFocusID(
      focusedID: selectionState.primaryTabID,
      viewportSize: viewportSize,
      canvasOffset: canvasOffset,
      canvasScale: canvasScale,
      candidates: candidates
    ) else {
      if selectionState.primaryTabID != nil {
        clearSelection(states: states)
      }
      return
    }
    guard selectionState.primaryTabID != targetTabID else { return }
    guard let target = tabs.first(where: { $0.tabID == targetTabID }) else { return }
    focusCanvasTab(target, states: states)
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
    states: [WorktreeTerminalState],
    ensureVisibleInViewport: Bool = false,
    animatesViewport: Bool = true
  ) {
    layoutStore.moveToFront(tabID.rawValue.uuidString)
    mutateSelection(states: states) { state in
      state.focusSingle(tabID)
    }
    if ensureVisibleInViewport {
      ensureTabVisibleInViewport(
        tabID,
        minimumInset: focusVisibleInset,
        animatesViewport: animatesViewport
      )
    }
  }

  func ensureTabVisibleInViewport(
    _ tabID: TerminalTabID,
    minimumInset: CGFloat,
    animatesViewport: Bool = true
  ) {
    guard viewportSize.width > 0, viewportSize.height > 0 else { return }
    let key = tabID.rawValue.uuidString
    guard let layout = layoutStore.cardLayouts[key] else { return }

    let resized = resizedFrame(for: tabID, baseLayout: layout)
    let screenCenter = screenPosition(for: resized.center)
    let scaledHalfWidth = (resized.size.width * canvasScale) / 2
    let scaledHalfHeight = ((resized.size.height + titleBarHeight) * canvasScale) / 2
    let cardMinX = screenCenter.x - scaledHalfWidth
    let cardMaxX = screenCenter.x + scaledHalfWidth
    let cardMinY = screenCenter.y - scaledHalfHeight
    let cardMaxY = screenCenter.y + scaledHalfHeight

    let insetX = min(max(0, minimumInset), viewportSize.width / 2)
    let insetY = min(max(0, minimumInset), viewportSize.height / 2)
    let targetMinX = insetX
    let targetMaxX = viewportSize.width - insetX
    let targetMinY = insetY
    let targetMaxY = max(
      targetMinY,
      viewportSize.height - insetY - focusBottomReservedInset
    )

    let deltaX = visibilityAdjustment(
      min: cardMinX,
      max: cardMaxX,
      targetMin: targetMinX,
      targetMax: targetMaxX
    )
    let deltaY = visibilityAdjustment(
      min: cardMinY,
      max: cardMaxY,
      targetMin: targetMinY,
      targetMax: targetMaxY
    )

    guard deltaX != 0 || deltaY != 0 else { return }
    canvasOffset = CGSize(
      width: canvasOffset.width + deltaX,
      height: canvasOffset.height + deltaY
    )
    lastCanvasOffset = canvasOffset
    if animatesViewport {
      focusViewportAnimationID &+= 1
    }
  }

  func visibilityAdjustment(
    min valueMin: CGFloat,
    max valueMax: CGFloat,
    targetMin: CGFloat,
    targetMax: CGFloat
  ) -> CGFloat {
    let lowerBound = targetMin - valueMin
    let upperBound = targetMax - valueMax

    if lowerBound <= upperBound {
      if 0 < lowerBound { return lowerBound }
      if 0 > upperBound { return upperBound }
      return 0
    }

    if valueMin >= targetMin, valueMax >= targetMax {
      return targetMin - valueMin
    }
    if valueMin <= targetMin, valueMax <= targetMax {
      return targetMax - valueMax
    }

    let alignMinDelta = targetMin - valueMin
    let alignMaxDelta = targetMax - valueMax
    return abs(alignMinDelta) <= abs(alignMaxDelta) ? alignMinDelta : alignMaxDelta
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

struct CanvasDirectoryDisplayCacheEntry: Equatable, Sendable {
  let normalizedDisplayPath: String
  let shortenedDisplayPath: String
}

struct CanvasCardTitleSegments: Equatable, Sendable {
  let currentDirectory: String?
  let worktreeName: String?
}

func canvasDisplayedDirectory(
  normalizedDisplayPath: String?,
  cachedEntry: CanvasDirectoryDisplayCacheEntry?
) -> String? {
  guard let normalizedDisplayPath else { return nil }
  guard
    let cachedEntry,
    cachedEntry.normalizedDisplayPath == normalizedDisplayPath
  else {
    return normalizedDisplayPath
  }
  return cachedEntry.shortenedDisplayPath
}

func canvasCardTitleSegments(
  currentDirectoryPath: String?,
  tabTitle: String?,
  fallbackWorktreeName: String? = nil,
  cachedDirectoryEntry: CanvasDirectoryDisplayCacheEntry?
) -> CanvasCardTitleSegments {
  let normalizedDisplayPath = CanvasCurrentDirectoryFormatter.displayPath(for: currentDirectoryPath)
  return CanvasCardTitleSegments(
    currentDirectory: canvasDisplayedDirectory(
      normalizedDisplayPath: normalizedDisplayPath,
      cachedEntry: cachedDirectoryEntry
    ),
    worktreeName: canvasCardWorktreeNameSegment(
      tabTitle: tabTitle,
      fallbackWorktreeName: fallbackWorktreeName,
      currentDirectoryPath: currentDirectoryPath
    )
  )
}

private func canvasCardWorktreeNameSegment(
  tabTitle: String?,
  fallbackWorktreeName: String?,
  currentDirectoryPath: String?
) -> String? {
  let fallback = trimmedNonEmpty(fallbackWorktreeName)
  guard let title = trimmedNonEmpty(tabTitle) else { return fallback }
  if CanvasCurrentDirectoryFormatter.isDuplicateDirectoryTitle(title, currentDirectoryPath: currentDirectoryPath) {
    return nil
  }
  if isHostnameLikeCanvasTitle(title) {
    return fallback
  }
  return title
}

private func isHostnameLikeCanvasTitle(_ title: String) -> Bool {
  let normalized = title.lowercased()
  return normalized.hasSuffix(CanvasTitleHostnamePattern.localSuffix)
    || normalized.hasSuffix(CanvasTitleHostnamePattern.computeInternalSuffix)
    || (normalized.hasPrefix(CanvasTitleHostnamePattern.ipHostnamePrefix)
      && normalized.contains(CanvasTitleHostnamePattern.domainSeparator))
}

private func trimmedNonEmpty(_ value: String?) -> String? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private enum CanvasTitleHostnamePattern {
  static let localSuffix = ".local"
  static let computeInternalSuffix = ".compute.internal"
  static let ipHostnamePrefix = "ip-"
  static let domainSeparator = "."
}

func shouldShowCanvasSelectionShield(
  selectionModifierPressed: Bool,
  isSelecting: Bool,
  isBroadcasting: Bool,
  isPrimaryTab: Bool
) -> Bool {
  if isSelecting { return true }
  if isBroadcasting && !isPrimaryTab { return true }
  if selectionModifierPressed { return true }
  return false
}

func canvasCurrentVisibleTabID(
  focusedTabID: TerminalTabID?,
  visibleTabIDs: [TerminalTabID],
  selectedTabIDs: [TerminalTabID]
) -> TerminalTabID? {
  guard !visibleTabIDs.isEmpty else { return nil }
  if let focusedTabID, visibleTabIDs.contains(focusedTabID) {
    return focusedTabID
  }
  if let selectedTabID = selectedTabIDs.first(where: { visibleTabIDs.contains($0) }) {
    return selectedTabID
  }
  return visibleTabIDs.first
}

func canvasRestoredFocusTabID(
  wasSuspended: Bool,
  isSuspended: Bool,
  focusedTabID: TerminalTabID?
) -> TerminalTabID? {
  guard wasSuspended, !isSuspended else { return nil }
  return focusedTabID
}

struct CanvasActivationFocusCandidate: Equatable {
  let worktreeID: Worktree.ID
  let selectedTabID: TerminalTabID
}

func canvasActivationFocusTarget(
  selectedWorktreeID: Worktree.ID?,
  canvasReturnWorktreeID: Worktree.ID?,
  candidates: [CanvasActivationFocusCandidate]
) -> CanvasRestoreFocusTarget? {
  let targetWorktreeIDs = [selectedWorktreeID, canvasReturnWorktreeID]
  for targetWorktreeID in targetWorktreeIDs.compactMap(\.self) {
    guard let candidate = candidates.first(where: { $0.worktreeID == targetWorktreeID }) else {
      continue
    }
    return CanvasRestoreFocusTarget(worktreeID: candidate.worktreeID, tabID: candidate.selectedTabID)
  }
  return nil
}

func canvasFocusVisibilityBounds(
  viewportSize: CGSize,
  horizontalInset: CGFloat,
  verticalInset: CGFloat,
  bottomReservedInset: CGFloat
) -> CGRect {
  let clampedHorizontalInset = min(max(0, horizontalInset), viewportSize.width / 2)
  let clampedVerticalInset = min(max(0, verticalInset), viewportSize.height / 2)
  let minX = clampedHorizontalInset
  let maxX = max(minX, viewportSize.width - clampedHorizontalInset)
  let minY = clampedVerticalInset
  let maxY = max(
    minY,
    viewportSize.height - clampedVerticalInset - bottomReservedInset
  )
  return CGRect(
    x: minX,
    y: minY,
    width: max(0, maxX - minX),
    height: max(0, maxY - minY)
  )
}
