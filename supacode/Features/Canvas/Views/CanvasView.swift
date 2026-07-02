import AppKit
import Carbon.HIToolbox
import Sharing
import SwiftUI

struct CanvasView: View {
  struct ViewportState: Equatable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1.0
    var hasPerformedInitialFit = false
  }

  struct CanvasShortcuts {
    let selectAll: AppShortcut?
    let arrange: AppShortcut?
    let organize: AppShortcut?
    let expand: AppShortcut?
  }

  enum DirectionalNewTerminalDirectoryMode: Equatable {
    case currentDirectory
    case worktreeDirectory
  }

  enum CanvasToastStyle: Equatable {
    case wrap
    case directional
    case zoomBlocked

    var iconSystemName: String {
      switch self {
      case .wrap:
        "arrow.triangle.2.circlepath"
      case .directional:
        "arrow.up.and.down.and.arrow.left.and.right"
      case .zoomBlocked:
        "magnifyingglass"
      }
    }
  }

  struct DirectionalNewTerminalInput: Equatable {
    let direction: CanvasCardPlacementStrategy.Direction
    let directoryMode: DirectionalNewTerminalDirectoryMode
  }

  @Environment(\.resolvedKeybindings) var resolvedKeybindings
  @Environment(\.canvasMaxModeActive) var canvasMaxModeActive
  @Shared(.settingsFile) private var settingsFile

  let terminalManager: WorktreeTerminalManager
  let initialFocusWorktreeID: Worktree.ID?
  /// Per-repo display titles resolved by the parent reducer. Used to
  /// override the folder-derived `Repository.name` on each card title
  /// bar without subscribing to per-repo settings files on the
  /// per-frame canvas hot path.
  var repositoryCustomTitles: [Repository.ID: String] = [:]
  var focusRequest: CanvasFocusRequest?
  /// A one-shot, reducer-driven request to run a view-local canvas command
  /// (expand/arrange/organize/select-all), e.g. from the command palette.
  var commandRequest: CanvasCommandRequest?
  var suspendTerminalFocus = false
  var onFocusedWorktreeChanged: (Worktree.ID?) -> Void = { _ in }
  var onFocusedTabChanged: (TerminalTabID?) -> Void = { _ in }
  var onFocusRequestConsumed: (Int) -> Void = { _ in }
  var onCommandConsumed: (Int) -> Void = { _ in }
  var onViewportStateChanged: ((ViewportState) -> Void)?
  var centerInitialSoloCard = false
  var centerInitialSoloCardScale: CGFloat?
  var onInitialSoloCardCenteringConsumed: () -> Void = {}
  /// Reports whether a card is currently expanded in place, so the parent can
  /// give the window toolbar a matching scrim (it can't be covered from here).
  var onExpandedChange: (Bool) -> Void = { _ in }
  var onDirectionalNewTerminalRequested: ((Worktree.ID?, DirectionalNewTerminalDirectoryMode) -> Void)?
  @State var layoutStore = CanvasLayoutStore()
  @State var cardDebugStyleStore = CanvasCardDebugStyleStore()
  @Shared(.repositoryAppearances) var repositoryAppearances

  @State var canvasOffset: CGSize = .zero
  @State var lastCanvasOffset: CGSize = .zero
  @State var canvasScale: CGFloat = 1.0
  @State var lastCanvasScale: CGFloat = 1.0
  @State var selectionState = CanvasSelectionState()
  @State var isCanvasSelectionModifierPressed = false
  @State var pendingCreatedTabID: TerminalTabID?
  @State var lastTitleBarTapDate: Date = .distantPast
  @State var activeResize: [TerminalTabID: ActiveResize] = [:]
  @State var hasPerformedInitialFit = false
  @State var hasSeenCanvasCards = false
  @State var viewportSize: CGSize = .zero
  @State var viewportTopSafeAreaInset: CGFloat = 0
  @State var showsCanvasHelp = false
  @State var configReloadCounter = 0
  @State var focusViewportAnimationID = 0
  @State var pendingCenterRequest: PendingCenterRequest?
  @State var arrangeAutoScaleTask: Task<Void, Never>?
  @State var overviewRestoreTask: Task<Void, Never>?
  @State var activeOverviewRestoreSnapshot: CanvasOverviewRestoreSnapshot?
  @State var wrapToastDismissTask: Task<Void, Never>?
  @State var canvasWrapToastMessage: String?
  @State var canvasWrapToastStyle: CanvasToastStyle = .wrap
  @State var isZoomPopoverPresented = false
  @State var isCustomZoomInputPresented = false
  @State var customZoomText = ""
  @State var customZoomErrorMessage: String?
  @State var directionalPlacementHint: PendingDirectionalPlacement?
  @State var isAwaitingDirectionalNewTerminalKey = false
  @State var directionalChordPreviousFocusedTabID: TerminalTabID?
  @State var directionalNewTerminalTimeoutTask: Task<Void, Never>?
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
  @State var expandedFontBoostedSurfaceIDs: Set<UUID> = []
  @FocusState var isCustomZoomFieldFocused: Bool

  let focusVisibleInset: CGFloat = 20
  let focusVisibleHorizontalInset: CGFloat = 44
  let focusVisibleVerticalInset: CGFloat = 20
  let focusBottomReservedInset: CGFloat = 36
  let expandHorizontalPadding: CGFloat = 200
  let expandTopPadding: CGFloat = 20
  let expandFontSizeDelta = 2
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
  /// Bottom margin kept for a card temporarily expanded to near-fullscreen.
  let expandBottomPadding: CGFloat = 50
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

  /// Default size for newly created and uniformly arranged cards.
  var defaultCanvasCardSize: CGSize {
    CanvasCardLayout.resolvedDefaultSize(
      useAdaptiveCardSize: settingsFile.global.useAdaptiveCanvasCardSize,
      forScreenWidth: hostScreenWidth
    )
  }

  let directionalNewTerminalTimeout: Duration = .seconds(2)
  let overviewPreviewDuration: Duration = .seconds(3)
  let unsupportedZoomInputMessage = "Unsupported zoom value. Enter a number like 67 or 67%."
  let maxModeZoomBlockedMessage = "Exit max mode to zoom."
  let maxModeSwitchBlockedMessage = "Exit max mode to switch modes."
  let directionalNewTerminalChordCoordinator = CanvasDirectionalNewTerminalChordCoordinator.shared

  init(
    terminalManager: WorktreeTerminalManager,
    initialFocusWorktreeID: Worktree.ID? = nil,
    repositoryCustomTitles: [Repository.ID: String] = [:],
    focusRequest: CanvasFocusRequest? = nil,
    commandRequest: CanvasCommandRequest? = nil,
    suspendTerminalFocus: Bool = false,
    onFocusedWorktreeChanged: @escaping (Worktree.ID?) -> Void = { _ in },
    onFocusedTabChanged: @escaping (TerminalTabID?) -> Void = { _ in },
    onFocusRequestConsumed: @escaping (Int) -> Void = { _ in },
    onCommandConsumed: @escaping (Int) -> Void = { _ in },
    viewportState: ViewportState = .init(),
    onViewportStateChanged: ((ViewportState) -> Void)? = nil,
    centerInitialSoloCard: Bool = false,
    centerInitialSoloCardScale: CGFloat? = nil,
    onInitialSoloCardCenteringConsumed: @escaping () -> Void = {},
    onExpandedChange: @escaping (Bool) -> Void = { _ in },
    onDirectionalNewTerminalRequested: ((Worktree.ID?, DirectionalNewTerminalDirectoryMode) -> Void)? = nil
  ) {
    self.terminalManager = terminalManager
    self.initialFocusWorktreeID = initialFocusWorktreeID
    self.repositoryCustomTitles = repositoryCustomTitles
    self.focusRequest = focusRequest
    self.commandRequest = commandRequest
    self.suspendTerminalFocus = suspendTerminalFocus
    self.onFocusedWorktreeChanged = onFocusedWorktreeChanged
    self.onFocusedTabChanged = onFocusedTabChanged
    self.onFocusRequestConsumed = onFocusRequestConsumed
    self.onCommandConsumed = onCommandConsumed
    self.onViewportStateChanged = onViewportStateChanged
    self.centerInitialSoloCard = centerInitialSoloCard
    self.centerInitialSoloCardScale = centerInitialSoloCardScale
    self.onInitialSoloCardCenteringConsumed = onInitialSoloCardCenteringConsumed
    self.onExpandedChange = onExpandedChange
    self.onDirectionalNewTerminalRequested = onDirectionalNewTerminalRequested
    _canvasOffset = State(initialValue: viewportState.offset)
    _lastCanvasOffset = State(initialValue: viewportState.offset)
    _canvasScale = State(initialValue: viewportState.scale)
    _lastCanvasScale = State(initialValue: viewportState.scale)
    _hasPerformedInitialFit = State(initialValue: viewportState.hasPerformedInitialFit)
  }

  var canvasShortcuts: CanvasShortcuts {
    CanvasShortcuts(
      selectAll: AppShortcuts.resolvedShortcut(
        for: AppShortcuts.CommandID.selectAllCanvasCards,
        in: resolvedKeybindings
      ),
      arrange: AppShortcuts.resolvedShortcut(
        for: AppShortcuts.CommandID.arrangeCanvasCards,
        in: resolvedKeybindings
      ),
      organize: AppShortcuts.resolvedShortcut(
        for: AppShortcuts.CommandID.organizeCanvasCards,
        in: resolvedKeybindings
      ),
      expand: AppShortcuts.resolvedShortcut(
        for: AppShortcuts.CommandID.expandCanvasCard,
        in: resolvedKeybindings
      )
    )
  }

  var body: some View {
    let _ = configReloadCounter
    canvasLifecycle(
      canvasKeyboardShortcuts(
        canvasOverlays(canvasScrollContent),
        shortcuts: canvasShortcuts
      )
    )
  }

  var canvasScrollContent: some View {
    CanvasScrollContainer(
      offset: $canvasOffset,
      lastOffset: $lastCanvasOffset,
      scale: $canvasScale,
      lastScale: $lastCanvasScale,
      isInteractionEnabled: expandedTabID == nil,
      onKeyDown: handleDirectionalNewTerminalKeyDown,
      canZoom: { expandedTabID == nil },
      onZoomBlocked: showMaxModeZoomBlockedToast
    ) {
      canvasGeometryContent
    }
  }

  var canvasGeometryContent: some View {
    GeometryReader { _ in
      canvasGeometryLayers
    }
    .contentShape(.rect)
    .simultaneousGesture(canvasZoomGesture, isEnabled: expandedTabID == nil)
    .animation(.easeInOut(duration: 0.22), value: focusViewportAnimationID)
    .onGeometryChange(for: CGSize.self) { proxy in
      proxy.size
    } action: { newSize in
      viewportSize = newSize
      let states = terminalManager.activeWorktreeStates
      performInitialFitIfNeeded(cards: collectCanvasCards(from: states))
      centerInitialSoloCardIfNeeded(tabIDs: collectVisibleTabIDs(from: states))
      fulfillPendingCenterRequestIfPossible()
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.safeAreaInsets.top
    } action: { newInset in
      viewportTopSafeAreaInset = newInset
    }
  }

  @ViewBuilder
  var canvasGeometryLayers: some View {
    let activeStates = terminalManager.activeWorktreeStates
    let canvasCards = collectCanvasCards(from: activeStates)
    let allCardKeys = canvasCards.map(\.key)
    let allTabIDs = collectVisibleTabIDs(from: activeStates)

    canvasBackgroundLayer(
      activeStates: activeStates,
      canvasCards: canvasCards,
      allCardKeys: allCardKeys,
      allTabIDs: allTabIDs
    )
    cardsLayer(activeStates: activeStates)
  }

  func canvasBackgroundLayer(
    activeStates: [WorktreeTerminalState],
    canvasCards: [CanvasCardDescriptor],
    allCardKeys: [String],
    allTabIDs: [TerminalTabID]
  ) -> some View {
    Color.clear
      .onAppear {
        if !allCardKeys.isEmpty {
          hasSeenCanvasCards = true
        }
        ensureLayouts(for: canvasCards)
        performInitialFitIfNeeded(cards: canvasCards)
        fulfillPendingCenterRequestIfPossible()
        if !allCardKeys.isEmpty {
          layoutStore.ensureZOrder(for: allCardKeys)
        }
        pruneSelection(previousOrder: [], currentOrder: allTabIDs, states: activeStates)
        syncBroadcastCallbacks(states: activeStates)
        fulfillPendingFocusRequest(focusRequest, states: activeStates)
        centerInitialSoloCardIfNeeded(tabIDs: allTabIDs)
      }
      .onChange(of: allCardKeys) { _, _ in
        let latestStates = terminalManager.activeWorktreeStates
        let latestCards = collectCanvasCards(from: latestStates)
        let latestKeys = latestCards.map(\.key)
        if latestKeys.isEmpty {
          CanvasLayoutStore.hasAutoArrangedInSession = false
          if hasSeenCanvasCards {
            layoutStore.prune(to: [])
          }
        } else {
          hasSeenCanvasCards = true
        }
        ensureLayouts(for: latestCards)
        performInitialFitIfNeeded(cards: latestCards)
        fulfillPendingCenterRequestIfPossible()
        if !latestKeys.isEmpty {
          layoutStore.ensureZOrder(for: latestKeys)
        }
        syncBroadcastCallbacks(states: latestStates)
        recoverCanvasFocusIfNeeded(states: latestStates)
        fulfillPendingFocusRequest(focusRequest, states: latestStates)
        centerInitialSoloCardIfNeeded(tabIDs: collectVisibleTabIDs(from: latestStates))
      }
      .onChange(of: allTabIDs) { oldTabIDs, newTabIDs in
        if let createdTabID = newlyCreatedCanvasTabID(
          previousTabIDs: oldTabIDs,
          currentTabIDs: newTabIDs
        ) {
          pendingCreatedTabID = createdTabID
        } else if let pendingCreatedTabID, !newTabIDs.contains(pendingCreatedTabID) {
          self.pendingCreatedTabID = nil
        }
        let latestStates = terminalManager.activeWorktreeStates
        let latestCards = collectCanvasCards(from: latestStates)
        ensureLayouts(for: latestCards)
        performInitialFitIfNeeded(cards: latestCards)
        fulfillPendingCenterRequestIfPossible()
        let latestTabIDs = collectVisibleTabIDs(from: latestStates)
        pruneSelection(previousOrder: oldTabIDs, currentOrder: latestTabIDs, states: latestStates)
        if let expandedTabID, !latestTabIDs.contains(expandedTabID) {
          cancelExpandForRelayout()
        }
        pruneDirectoryShorteningState(keeping: latestStates)
        recoverCanvasFocusIfNeeded(states: latestStates)
        fulfillPendingFocusRequest(focusRequest, states: latestStates)
        centerInitialSoloCardIfNeeded(tabIDs: latestTabIDs)
      }
      .onChange(of: focusRequest) { _, newRequest in
        fulfillPendingFocusRequest(newRequest, states: activeStates)
        fulfillPendingCenterRequestIfPossible()
      }
      .contentShape(.rect)
      .accessibilityAddTraits(.isButton)
      .onTapGesture { clearSelection(states: activeStates) }
      .gesture(canvasPanGesture, isEnabled: expandedTabID == nil)
  }

  func canvasOverlays<Content: View>(_ content: Content) -> some View {
    content
    .overlay(alignment: .bottomTrailing) {
      canvasBottomTrailingOverlay
    }
    .background(selectionModifierObserver)
    .overlay(alignment: .bottomLeading) {
      canvasBottomLeadingOverlay
    }
    .overlay {
      canvasWrapToast
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .visualEffect { content, proxy in
          content.offset(y: proxy.size.height / 3)
        }
    }
  }

  func canvasKeyboardShortcuts<Content: View>(
    _ content: Content,
    shortcuts: CanvasShortcuts
  ) -> some View {
    content
    .onKeyPress(.escape) {
      guard selectionState.isBroadcasting else { return .ignored }
      clearSelection(states: terminalManager.activeWorktreeStates)
      return .handled
    }
    .onKeyPress(
      shortcuts.selectAll?.keyEquivalent ?? AppShortcuts.selectAllCanvasCards.keyEquivalent,
      phases: .down
    ) { keyPress in
      // Bail when the binding is disabled in Settings (resolved shortcut is nil);
      // otherwise the app-default key would still fire despite being unbound.
      guard let shortcut = shortcuts.selectAll else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      selectAllCards()
      return .handled
    }
    .onKeyPress(
      shortcuts.arrange?.keyEquivalent ?? AppShortcuts.arrangeCanvasCards.keyEquivalent,
      phases: .down
    ) { keyPress in
      guard let shortcut = shortcuts.arrange else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      arrangeCardsWithFit()
      return .handled
    }
    .onKeyPress(
      shortcuts.organize?.keyEquivalent ?? AppShortcuts.organizeCanvasCards.keyEquivalent,
      phases: .down
    ) { keyPress in
      guard let shortcut = shortcuts.organize else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      organizeCardsWithFit()
      return .handled
    }
    .onKeyPress(
      shortcuts.expand?.keyEquivalent ?? AppShortcuts.expandCanvasCard.keyEquivalent,
      phases: .down
    ) { keyPress in
      guard let shortcut = shortcuts.expand else { return .ignored }
      guard keyPress.modifiers == shortcut.modifiers else { return .ignored }
      toggleExpandFocusedCard()
      return .handled
    }
  }

  func canvasLifecycle<Content: View>(_ content: Content) -> some View {
    content
    .modifier(
      CanvasMaxModeStateModifier(
        isActive: expandedTabID != nil,
        externalIsActive: canvasMaxModeActive,
        onExit: collapseExpand,
        onBlockedModeSwitch: showMaxModeSwitchBlockedToast
      ))
    .onChange(of: expandedTabID) { _, newValue in
      onExpandedChange(newValue != nil)
    }
    .onChange(of: canvasOffset) { _, _ in
      notifyViewportStateChanged()
    }
    .onChange(of: canvasScale) { _, _ in
      notifyViewportStateChanged()
    }
    .onChange(of: hasPerformedInitialFit) { _, _ in
      notifyViewportStateChanged()
    }
    .onChange(of: commandRequest) { _, newRequest in
      fulfillCommandRequest(newRequest)
    }
    .onChange(of: suspendTerminalFocus) { wasSuspended, isSuspended in
      handleTerminalFocusSuspensionChange(
        from: wasSuspended,
        to: isSuspended,
        states: terminalManager.activeWorktreeStates
      )
    }
    .task {
      cardDebugStyleStore.startWatching()
      activateCanvas()
      fulfillCommandRequest(commandRequest)
    }
    .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
      configReloadCounter &+= 1
    }
    .onDisappear {
      cardDebugStyleStore.stopWatching()
      restoreExpandedFontBoost()
      deactivateCanvas()
      cancelArrangeAutoScaleTask()
      cancelOverviewRestoreTask()
      activeOverviewRestoreSnapshot = nil
      cancelWrapToastTask()
      cancelDirectionalNewTerminalTimeoutTask()
      isAwaitingDirectionalNewTerminalKey = false
      directionalChordPreviousFocusedTabID = nil
      directionalPlacementHint = nil
      canvasMaxModeActive.wrappedValue = false
      resetCustomZoomInput()
      cancelAllDirectoryShorteningRequests()
    }
    .focusedSceneValue(\.canvasMoveLeftAction) { focusAdjacentCanvasTab(direction: .left) }
    .focusedSceneValue(\.canvasMoveDownAction) { focusAdjacentCanvasTab(direction: .down) }
    .focusedSceneValue(\.canvasMoveUpAction) { focusAdjacentCanvasTab(direction: .up) }
    .focusedSceneValue(\.canvasMoveRightAction) { focusAdjacentCanvasTab(direction: .right) }
    .focusedSceneValue(\.canvasDirectionalNewTerminalLeaderAction) {
      armDirectionalNewTerminalChord()
    }
    .focusedSceneValue(\.toggleCanvasMaxModeAction) {
      toggleCanvasMaxMode()
    }
  }

  var selectionModifierObserver: some View {
    CanvasSelectionModifierObserver(isPressed: $isCanvasSelectionModifierPressed)
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)
  }

  func showsSelectionShield(for tabID: TerminalTabID) -> Bool {
    shouldShowCanvasSelectionShield(
      selectionModifierPressed: isCanvasSelectionModifierPressed,
      isSelecting: selectionState.isSelecting,
      isBroadcasting: selectionState.isBroadcasting,
      isPrimaryTab: selectionState.primaryTabID == tabID
    )
  }

  static func shouldRenderCard(
    _ tabID: TerminalTabID,
    expandedTabID: TerminalTabID?
  ) -> Bool {
    guard let expandedTabID else { return true }
    return tabID == expandedTabID
  }

  // MARK: - Cards Layer

  /// Cards layer: one card per open tab across all worktrees.
  /// Uses .offset() (not .position()) to avoid parent size proposals
  /// reaching the NSView, keeping terminal grid stable during zoom.
  @ViewBuilder
  func cardsLayer(activeStates: [WorktreeTerminalState]) -> some View {
    // Pin to .topLeading and fill the viewport so each card's `.offset()` keeps
    // the same (0,0) origin it had under GeometryReader.
    ZStack(alignment: .topLeading) {
      ForEach(activeStates, id: \.worktreeID) { state in
        Group {
          ForEach(state.tabManager.tabs) { tab in
            if state.surfaceView(for: tab.id) != nil,
              Self.shouldRenderCard(tab.id, expandedTabID: expandedTabID)
            {
              cardView(for: tab, in: state, activeStates: activeStates)
            }
          }
        }
        .onChange(of: state.tabManager.selectedTabId) { _, _ in
          syncFocusToSelectedTab(in: state, states: terminalManager.activeWorktreeStates)
        }
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
    // Reuse main's expand geometry, but without an animation modifier or scrim.
    let fromGeometry = nonExpandedGeometry(for: tab.id, baseLayout: baseLayout)
    let toGeometry = expandedGeometry()
    let unfocusedSplitOverlay = terminalManager.unfocusedSplitOverlay()
    let splitDivider = terminalManager.splitDividerAppearance()
    let repositoryAppearance = appearance(for: state.repositoryRootURL)
    let resolvedRepositoryName = repositoryDisplayName(for: state.repositoryRootURL)
    let currentDirectoryPath = canvasCurrentDirectoryPath(
      reportedPath: state.surfaceView(for: tab.id)?.bridge.state.pwd,
      fallbackWorktreeDirectory: state.worktree.workingDirectory.path(percentEncoded: false)
    )
    let activeSurfaceID = state.activeSurfaceID(for: tab.id)
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
        repositoryName: state.worktreeID == FreestyleTerminal.worktreeID
          ? FreestyleTerminal.repositoryName
          : resolvedRepositoryName,
        currentDirectory: titleSegments.currentDirectory,
        isTmuxBacked: state.isTmuxBacked(tab.id),
        worktreeName: titleSegments.worktreeName,
        agentIdentity: canvasCardAgentIdentity(in: state, surfaceID: activeSurfaceID),
        repositoryIcon: repositoryAppearance.icon,
        repositoryColor: repositoryAppearance.color?.color,
        repositoryRootURL: state.repositoryRootURL,
        tree: tree,
        activeSurfaceID: activeSurfaceID,
        unfocusedSplitOverlay: unfocusedSplitOverlay,
        splitDivider: splitDivider,
        isFocused: selectionState.primaryTabID == tab.id,
        isSelected: selectionState.selectedTabIDs.contains(tab.id),
        hasUnseenNotification: state.hasUnseenNotification(for: tab.id),
        debugStyle: cardDebugStyleStore.configuration,
        configReloadGeneration: configReloadCounter,
        cardSize: renderSize,
        isExpanded: isCardExpanded,
        expandHelp: expandHelp,
        canvasScale: isCardExpanded ? 1 : canvasScale,
        showsSelectionShield: showsSelectionShield(for: tab.id),
        onTap: {
          let selectionModifierHeld = NSEvent.modifierFlags.contains(.option)
          if selectionModifierHeld {
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
    .zIndex(zIndex(for: tab.id, cardKey: cardKey))
    .onAppear {
      requestDirectoryShortening(for: tab.id, normalizedDisplayPath: normalizedDisplayPath)
    }
    .onChange(of: normalizedDisplayPath) { _, newDisplayPath in
      requestDirectoryShortening(for: tab.id, normalizedDisplayPath: newDisplayPath)
    }
  }

  private func canvasCardAgentIdentity(
    in state: WorktreeTerminalState,
    surfaceID: UUID?
  ) -> CanvasCardView.AgentIdentity? {
    guard let surfaceID,
      let paneState = state.surfaceAgentStates[surfaceID],
      let agent = paneState.detectedAgent,
      paneState.state != .unknown
    else {
      return nil
    }
    let iconToken = paneState.iconLookupToken ?? agent.iconLookupToken
    return CanvasCardView.AgentIdentity(
      agent: agent,
      icon: CommandIconMap.iconForFirstToken(iconToken)
        ?? CommandIconMap.iconForFirstToken(agent.iconLookupToken),
      accessibilityLabel: agent.displayName
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
        let newScale = CanvasViewportMath.clampedScale(lastCanvasScale * value.magnification)
        let anchor = value.startLocation

        canvasOffset = CanvasViewportMath.offsetKeepingAnchorStable(
          currentOffset: lastCanvasOffset,
          currentScale: lastCanvasScale,
          newScale: newScale,
          anchor: anchor
        )
        canvasScale = newScale
      }
      .onEnded { _ in
        lastCanvasScale = canvasScale
        lastCanvasOffset = canvasOffset
      }
  }

  // MARK: - Layout

  struct CanvasCardDescriptor: Equatable {
    let key: String
    let worktreeID: Worktree.ID
  }

  struct PendingDirectionalPlacement: Equatable {
    let anchorKey: String
    let worktreeID: Worktree.ID
    let direction: CanvasCardPlacementStrategy.Direction
  }

  struct PendingCenterRequest: Equatable {
    let tabID: TerminalTabID
    let scale: CGFloat?
  }

  /// Batch-position cards that don't have stored layouts yet.
  /// Placement order:
  /// 1) Current worktree region
  /// 2) Global bounding rectangle interior
  /// 3) Global growth by the smaller dimension
  func ensureLayouts(for cards: [CanvasCardDescriptor]) {
    let unpositioned = cards.filter { layoutStore.cardLayouts[$0.key] == nil }
    guard !unpositioned.isEmpty else { return }

    let cardSize = defaultCanvasCardSize
    var layouts = layoutStore.cardLayouts
    var remainingDirectionalHint = directionalPlacementHint
    let placementCards = cards.map {
      CanvasCardPlacementStrategy.CardDescriptor(
        key: $0.key,
        worktreeID: $0.worktreeID
      )
    }
    for card in unpositioned {
      let target = CanvasCardPlacementStrategy.CardDescriptor(
        key: card.key,
        worktreeID: card.worktreeID
      )
      var directionalHint: CanvasCardPlacementStrategy.DirectionalHint?
      if let hint = remainingDirectionalHint, hint.worktreeID == card.worktreeID {
        directionalHint = CanvasCardPlacementStrategy.DirectionalHint(
          anchorKey: hint.anchorKey,
          direction: hint.direction
        )
        remainingDirectionalHint = nil
      }
      layouts[card.key] = CanvasCardPlacementStrategy.nextLayout(
        for: target,
        cards: placementCards,
        layouts: layouts,
        defaultSize: cardSize,
        titleBarHeight: titleBarHeight,
        spacing: cardSpacing,
        directionalHint: directionalHint
      )
    }
    layoutStore.setCardLayouts(layouts)
    directionalPlacementHint = remainingDirectionalHint
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
    collectCanvasCards(from: states).map(\.key)
  }

  func collectCanvasCards(from states: [WorktreeTerminalState]) -> [CanvasCardDescriptor] {
    states.flatMap { state in
      state.tabManager.tabs.compactMap { tab in
        state.surfaceView(for: tab.id) != nil
          ? CanvasCardDescriptor(key: tab.id.rawValue.uuidString, worktreeID: state.worktreeID)
          : nil
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

  func newlyCreatedCanvasTabID(
    previousTabIDs: [TerminalTabID],
    currentTabIDs: [TerminalTabID]
  ) -> TerminalTabID? {
    let previousTabIDSet = Set(previousTabIDs)
    return currentTabIDs.first(where: { !previousTabIDSet.contains($0) })
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
    let cardSize = defaultCanvasCardSize
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
      let size = layoutStore.cardLayouts[key]?.size ?? defaultCanvasCardSize
      return CanvasCardPacker.CardInfo(key: key, size: size)
    }

    let packer = CanvasCardPacker(spacing: cardSpacing, titleBarHeight: titleBarHeight)
    let targetRatio = viewportSize.width / viewportSize.height
    let result = packer.pack(cards: cards, currentLayouts: layoutStore.cardLayouts, targetRatio: targetRatio)

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

    let newScale = CanvasViewportMath.clampedScale(
      min(canvasSize.width / bboxW, canvasSize.height / bboxH),
      max: 1.0
    )

    canvasOffset = CGSize(
      width: canvasSize.width / 2 - bboxCenterX * newScale,
      height: (canvasSize.height - bottomToolbarReserve) / 2 - bboxCenterY * newScale
    )
    canvasScale = newScale
    lastCanvasScale = newScale
    lastCanvasOffset = canvasOffset
  }

  func centerCanvas(
    on tabID: TerminalTabID,
    scale targetScale: CGFloat? = nil
  ) -> Bool {
    guard viewportSize.width > 0, viewportSize.height > 0 else { return false }
    let key = tabID.rawValue.uuidString
    guard let layout = layoutStore.cardLayouts[key] else { return false }
    let centered = CanvasViewportMath.centeredViewport(
      viewportSize: viewportSize,
      canvasPoint: layout.position,
      scale: targetScale ?? canvasScale
    )
    canvasScale = centered.scale
    lastCanvasScale = centered.scale
    canvasOffset = centered.offset
    lastCanvasOffset = canvasOffset
    return true
  }

  func notifyViewportStateChanged() {
    onViewportStateChanged?(
      ViewportState(
        offset: canvasOffset,
        scale: canvasScale,
        hasPerformedInitialFit: hasPerformedInitialFit
      )
    )
  }

  func performInitialFitIfNeeded(cards: [CanvasCardDescriptor]) {
    guard !hasPerformedInitialFit, !cards.isEmpty else { return }
    guard viewportSize.width > 0, viewportSize.height > 0 else { return }

    ensureLayouts(for: cards)
    hasPerformedInitialFit = true
    let cardKeys = cards.map(\.key)
    if !CanvasLayoutStore.hasAutoArrangedInSession {
      CanvasLayoutStore.hasAutoArrangedInSession = true
      if layoutStore.shouldAutoArrangeOnInitialEntry(for: cardKeys) {
        arrangeCards()
      }
    }
    fitToView(canvasSize: viewportSize)
  }

  func fulfillPendingCenterRequestIfPossible() {
    guard let pendingCenterRequest else { return }
    if centerCanvas(on: pendingCenterRequest.tabID, scale: pendingCenterRequest.scale) {
      self.pendingCenterRequest = nil
    }
  }

  func centerInitialSoloCardIfNeeded(tabIDs: [TerminalTabID]) {
    guard centerInitialSoloCard else { return }
    guard hasPerformedInitialFit else { return }
    guard tabIDs.count == 1, let tabID = tabIDs.first else {
      if !tabIDs.isEmpty {
        onInitialSoloCardCenteringConsumed()
      }
      return
    }
    if !centerCanvas(on: tabID, scale: centerInitialSoloCardScale) {
      pendingCenterRequest = PendingCenterRequest(tabID: tabID, scale: centerInitialSoloCardScale)
    } else {
      pendingCenterRequest = nil
    }
    onInitialSoloCardCenteringConsumed()
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
        resetCustomZoomInput()
        isZoomPopoverPresented.toggle()
      } label: {
        Text(CanvasViewportMath.percentageString(for: canvasScale))
          .font(.caption.monospacedDigit())
          .multilineTextAlignment(.center)
          .accessibilityLabel("Canvas zoom \(CanvasViewportMath.percentageString(for: canvasScale))")
      }
      .buttonStyle(.bordered)
      .simultaneousGesture(
        TapGesture(count: 2).onEnded {
          isZoomPopoverPresented = false
          toggleFocusedCanvasZoom()
        }
      )
      .popover(isPresented: $isZoomPopoverPresented, arrowEdge: .bottom) {
        canvasZoomPopover
      }
      .help("Click to choose canvas zoom. Double-click toggles 100% and 67%")

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
      .simultaneousGesture(
        TapGesture(count: 2).onEnded {
          scheduleArrangeAutoScaleTo100Percent()
        }
      )

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

  @ViewBuilder
  var canvasBottomTrailingOverlay: some View {
    if expandedTabID == nil {
      canvasToolbar
    }
  }

  @ViewBuilder
  var canvasBottomLeadingOverlay: some View {
    if expandedTabID == nil {
      canvasHelpButton
    }
  }

  var canvasZoomPopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Canvas Zoom")
        .font(.headline)

      HStack(spacing: 6) {
        ForEach(CanvasViewportMath.zoomPresetScales, id: \.self) { scale in
          Button {
            setCanvasScale(to: scale)
            isZoomPopoverPresented = false
          } label: {
            Text(CanvasViewportMath.percentageString(for: scale))
              .font(.callout.monospacedDigit())
          }
          .help("Set canvas zoom to \(CanvasViewportMath.percentageString(for: scale))")
        }
      }

      Divider()

      Button {
        isCustomZoomInputPresented = true
        customZoomText = CanvasViewportMath.percentageString(for: canvasScale)
        customZoomErrorMessage = nil
        isCustomZoomFieldFocused = true
      } label: {
        Label("Custom", systemImage: "number")
      }
      .help("Enter a custom canvas zoom percentage")

      if isCustomZoomInputPresented {
        VStack(alignment: .leading, spacing: 6) {
          TextField("67 or 67%", text: $customZoomText)
            .textFieldStyle(.roundedBorder)
            .focused($isCustomZoomFieldFocused)
            .onSubmit {
              applyCustomZoomInput()
            }

          if let customZoomErrorMessage {
            Label(customZoomErrorMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .padding()
    .frame(width: 280, alignment: .leading)
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
    Set(collectVisibleTabIDs(from: states))
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
          Image(systemName: canvasWrapToastStyle.iconSystemName)
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
    showCanvasToast(message: wrapToastMessage(for: direction), style: .wrap)
  }

  func showMaxModeZoomBlockedToast() {
    showCanvasToast(message: maxModeZoomBlockedMessage, style: .zoomBlocked)
  }

  func showMaxModeSwitchBlockedToast() {
    showCanvasToast(message: maxModeSwitchBlockedMessage, style: .zoomBlocked)
  }

  func showCanvasToast(message: String, style: CanvasToastStyle) {
    cancelWrapToastTask()
    canvasWrapToastStyle = style
    withAnimation(.easeInOut(duration: 0.2)) {
      canvasWrapToastMessage = message
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

  func applyCustomZoomInput() {
    guard let scale = CanvasViewportMath.scaleFromPercentageInput(customZoomText) else {
      customZoomErrorMessage = unsupportedZoomInputMessage
      return
    }
    customZoomErrorMessage = nil
    setCanvasScale(to: scale)
    isZoomPopoverPresented = false
    resetCustomZoomInput()
  }

  func resetCustomZoomInput() {
    isCustomZoomInputPresented = false
    customZoomText = ""
    customZoomErrorMessage = nil
  }

  func setCanvasScale(to targetScale: CGFloat) {
    guard expandedTabID == nil else {
      showMaxModeZoomBlockedToast()
      return
    }
    let newScale = CanvasViewportMath.clampedScale(targetScale)
    guard newScale != canvasScale else { return }

    guard viewportSize.width > 0, viewportSize.height > 0 else {
      canvasScale = newScale
      lastCanvasScale = newScale
      return
    }

    let anchor = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    let targetOffset = CanvasViewportMath.offsetKeepingAnchorStable(
      currentOffset: canvasOffset,
      currentScale: canvasScale,
      newScale: newScale,
      anchor: anchor
    )
    canvasScale = newScale
    lastCanvasScale = newScale
    canvasOffset = targetOffset
    lastCanvasOffset = targetOffset
  }

  func setCanvasScaleTo100Percent() {
    setCanvasScale(to: CanvasViewportMath.fullDoubleClickScale)
  }

  func toggleFocusedCanvasZoom() {
    guard expandedTabID == nil else {
      showMaxModeZoomBlockedToast()
      return
    }
    if abs(canvasScale - CanvasViewportMath.fullDoubleClickScale) < 0.001 {
      focusCurrentCanvasTabAtCompactScale()
    } else {
      focusCurrentCanvasTabAtScaleOne()
    }
  }

  func toggleCanvasMaxMode() {
    if expandedTabID != nil {
      collapseExpand()
      return
    }

    let states = terminalManager.activeWorktreeStates
    let tabs = visibleCanvasTabs(from: states)
    guard let current = currentCanvasTab(from: tabs) else { return }
    focusSingleCard(current.tabID, states: states)
    showsCanvasHelp = false
    isZoomPopoverPresented = false
    resetCustomZoomInput()
    expandCard(current.tabID, states: states)
  }

  func focusCurrentCanvasTabAtScaleOne() {
    let states = terminalManager.activeWorktreeStates
    let tabs = visibleCanvasTabs(from: states)
    guard let current = currentCanvasTab(from: tabs) else {
      setCanvasScale(to: CanvasViewportMath.fullDoubleClickScale)
      return
    }
    focusSingleCard(current.tabID, states: states)
    setCanvasScale(to: CanvasViewportMath.fullDoubleClickScale)
    ensureTabVisibleInViewport(current.tabID, minimumInset: focusVisibleInset)
  }

  func focusCurrentCanvasTabAtCompactScale() {
    let states = terminalManager.activeWorktreeStates
    let tabs = visibleCanvasTabs(from: states)
    guard let current = currentCanvasTab(from: tabs) else {
      setCanvasScale(to: CanvasViewportMath.compactDoubleClickScale)
      return
    }

    focusSingleCard(current.tabID, states: states)

    let targetScale = CanvasViewportMath.compactDoubleClickScale
    let viewportBounds = canvasFocusVisibilityBounds(
      viewportSize: viewportSize,
      horizontalInset: focusVisibleHorizontalInset,
      verticalInset: focusVisibleVerticalInset,
      bottomReservedInset: focusBottomReservedInset
    )
    let entries = tabs.map { tab in
      CanvasViewportMath.CardVisibilityEntry(
        id: tab.tabID,
        frame: CGRect(
          x: tab.center.x - tab.size.width / 2,
          y: tab.center.y - tab.size.height / 2,
          width: tab.size.width,
          height: tab.size.height
        )
      )
    }
    guard
      let targetOffset = CanvasViewportMath.offsetMaximizingCardVisibility(
        viewportBounds: viewportBounds,
        centeringBounds: CGRect(origin: .zero, size: viewportSize),
        entries: entries,
        focusedID: current.tabID,
        scale: targetScale
      )
    else {
      setCanvasScale(to: targetScale)
      return
    }

    canvasScale = targetScale
    lastCanvasScale = targetScale
    canvasOffset = targetOffset
    lastCanvasOffset = targetOffset
  }

  func scheduleArrangeAutoScaleTo100Percent() {
    cancelArrangeAutoScaleTask()
    arrangeAutoScaleTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        setCanvasScaleTo100Percent()
        ensureCurrentCanvasTabVisible()
      }
      arrangeAutoScaleTask = nil
    }
  }

  func cancelArrangeAutoScaleTask() {
    arrangeAutoScaleTask?.cancel()
    arrangeAutoScaleTask = nil
  }

  // MARK: - Directional New Terminal

  func armDirectionalNewTerminalChord() {
    cancelWrapToastTask()
    cancelDirectionalNewTerminalTimeoutTask()
    isAwaitingDirectionalNewTerminalKey = true
    directionalNewTerminalChordCoordinator.setAwaitingDirectionalChordKey(true)
    directionalChordPreviousFocusedTabID = selectionState.primaryTabID
    suspendCanvasTerminalFirstResponderForDirectionalChord()
    canvasWrapToastStyle = .directional
    withAnimation(.easeInOut(duration: 0.2)) {
      canvasWrapToastMessage = "Directional new terminal: h/j/k/l current dir, H/J/K/L worktree dir, n freestyle"
    }
    directionalNewTerminalTimeoutTask = Task { @MainActor in
      do {
        try await Task.sleep(for: directionalNewTerminalTimeout)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      cancelDirectionalNewTerminalChord()
    }
  }

  func handleDirectionalNewTerminalKeyDown(_ event: NSEvent) -> NSEvent? {
    if matchesDirectionalNewTerminalLeaderShortcut(event) {
      armDirectionalNewTerminalChord()
      return nil
    }
    guard directionalNewTerminalChordCoordinator.isAwaitingDirectionalChordKey else { return event }
    if event.keyCode == kVK_Escape {
      cancelDirectionalNewTerminalChord()
      return nil
    }
    if matchesFreestyleNewTerminalShortcut(event) {
      completeFreestyleNewTerminalChord()
      return nil
    }
    guard let input = directionalNewTerminalInput(for: event) else { return nil }
    completeDirectionalNewTerminalChord(input)
    return nil
  }

  func matchesDirectionalNewTerminalLeaderShortcut(_ event: NSEvent) -> Bool {
    Self.isDirectionalNewTerminalLeaderShortcut(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      modifierFlags: event.modifierFlags
    )
  }

  func directionalNewTerminalInput(for event: NSEvent) -> DirectionalNewTerminalInput? {
    Self.directionalNewTerminalInput(
      keyCode: event.keyCode,
      characters: event.characters,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      modifierFlags: event.modifierFlags
    )
  }

  func matchesFreestyleNewTerminalShortcut(_ event: NSEvent) -> Bool {
    Self.matchesFreestyleNewTerminalShortcut(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers
    )
  }

  static func isDirectionalNewTerminalLeaderShortcut(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    let relevantModifiers = modifierFlags.intersection([.command, .shift, .option, .control])
    guard relevantModifiers == [.command, .control] else { return false }
    if Int(keyCode) == kVK_ANSI_T { return true }
    guard let charactersIgnoringModifiers else { return false }
    let normalized = charactersIgnoringModifiers.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 1 else { return false }
    return normalized == "t"
  }

  static func directionalNewTerminalInput(
    keyCode: UInt16,
    characters: String?,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> DirectionalNewTerminalInput? {
    guard let direction = directionalPlacementDirection(
      keyCode: keyCode,
      charactersIgnoringModifiers: charactersIgnoringModifiers
    )
    else {
      return nil
    }
    let usesWorktreeDirectory = usesWorktreeDirectory(
      characters: characters,
      modifierFlags: modifierFlags
    )
    return DirectionalNewTerminalInput(
      direction: direction,
      directoryMode: usesWorktreeDirectory ? .worktreeDirectory : .currentDirectory
    )
  }

  static func matchesFreestyleNewTerminalShortcut(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?
  ) -> Bool {
    if Int(keyCode) == kVK_ANSI_N { return true }
    guard let charactersIgnoringModifiers else { return false }
    let normalized = charactersIgnoringModifiers.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 1 else { return false }
    return normalized == "n"
  }

  private static func directionalPlacementDirection(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?
  ) -> CanvasCardPlacementStrategy.Direction? {
    switch Int(keyCode) {
    case kVK_ANSI_H:
      return .left
    case kVK_ANSI_J:
      return .down
    case kVK_ANSI_K:
      return .up
    case kVK_ANSI_L:
      return .right
    default:
      break
    }
    guard let charactersIgnoringModifiers else { return nil }
    let normalized = charactersIgnoringModifiers.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 1 else { return nil }
    return switch normalized {
    case "h":
      .left
    case "j":
      .down
    case "k":
      .up
    case "l":
      .right
    default:
      nil
    }
  }

  private static func usesWorktreeDirectory(
    characters: String?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    if let characters, characters.rangeOfCharacter(from: .uppercaseLetters) != nil {
      return true
    }
    return modifierFlags.contains(.shift)
  }

  func completeDirectionalNewTerminalChord(_ input: DirectionalNewTerminalInput) {
    let states = terminalManager.activeWorktreeStates
    ensureLayouts(for: collectCanvasCards(from: states))
    if let anchorTab = currentCanvasTab(from: visibleCanvasTabs(from: states)) {
      directionalPlacementHint = PendingDirectionalPlacement(
        anchorKey: anchorTab.tabID.rawValue.uuidString,
        worktreeID: anchorTab.state.worktreeID,
        direction: input.direction
      )
      onDirectionalNewTerminalRequested?(anchorTab.state.worktreeID, input.directoryMode)
    } else {
      onDirectionalNewTerminalRequested?(terminalManager.canvasFocusedWorktreeID, input.directoryMode)
    }
    cancelDirectionalNewTerminalChord(restoreFocus: false)
  }

  func completeFreestyleNewTerminalChord() {
    directionalPlacementHint = nil
    onDirectionalNewTerminalRequested?(FreestyleTerminal.worktreeID, .worktreeDirectory)
    cancelDirectionalNewTerminalChord(restoreFocus: false)
  }

  func cancelDirectionalNewTerminalChord(restoreFocus: Bool = true) {
    let tabIDToRestore = directionalChordPreviousFocusedTabID
    directionalChordPreviousFocusedTabID = nil
    isAwaitingDirectionalNewTerminalKey = false
    directionalNewTerminalChordCoordinator.setAwaitingDirectionalChordKey(false)
    cancelDirectionalNewTerminalTimeoutTask()
    withAnimation(.easeInOut(duration: 0.2)) {
      canvasWrapToastMessage = nil
    }
    guard restoreFocus else { return }
    restoreCanvasTerminalFocusAfterDirectionalChord(to: tabIDToRestore)
  }

  func suspendCanvasTerminalFirstResponderForDirectionalChord() {
    guard let keyWindow = NSApp.keyWindow else { return }
    guard keyWindow.firstResponder is GhosttySurfaceView else { return }
    _ = keyWindow.makeFirstResponder(nil)
  }

  func restoreCanvasTerminalFocusAfterDirectionalChord(to tabID: TerminalTabID?) {
    restoreCanvasTerminalFocus(to: tabID, states: terminalManager.activeWorktreeStates)
  }

  func cancelDirectionalNewTerminalTimeoutTask() {
    directionalNewTerminalTimeoutTask?.cancel()
    directionalNewTerminalTimeoutTask = nil
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
    ensureLayouts(for: collectCanvasCards(from: states))
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
    let focusedTabID = selectionState.primaryTabID
    let visibleTabIDs = tabs.map(\.tabID)
    let selectedTabIDs = tabs.compactMap { tab in
      tab.state.tabManager.selectedTabId == tab.tabID ? tab.tabID : nil
    }
    guard
      let currentTabID = canvasCurrentVisibleTabID(
        focusedTabID: focusedTabID,
        visibleTabIDs: visibleTabIDs,
        selectedTabIDs: selectedTabIDs
      )
    else { return nil }
    return tabs.first { $0.tabID == currentTabID }
  }

  func ensureCurrentCanvasTabVisible() {
    let tabs = visibleCanvasTabs(from: terminalManager.activeWorktreeStates)
    guard let current = currentCanvasTab(from: tabs) else { return }
    ensureTabVisibleInViewport(current.tabID, minimumInset: focusVisibleInset)
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
      pendingCreatedID: pendingCreatedTabID,
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
    if pendingCreatedTabID == targetTabID {
      pendingCreatedTabID = nil
    }
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
    if pendingCreatedTabID == tabID {
      pendingCreatedTabID = nil
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
      horizontalPadding: expandHorizontalPadding,
      topPadding: expandTopPadding,
      bottomReserve: expandBottomPadding,
      topSafeAreaInset: viewportTopSafeAreaInset,
      titleBarHeight: titleBarHeight,
      minSize: CGSize(width: minCardWidth, height: minCardHeight)
    )
  }

  /// Screen-space center for a fully expanded card: horizontally centered and
  /// within the toolbar-adjusted viewport. Independent of canvas pan/zoom.
  var expandedScreenCenter: CGPoint {
    CanvasExpandGeometry.expandedCenter(viewport: viewportSize, metrics: expandMetrics)
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

private struct CanvasMaxModeStateModifier: ViewModifier {
  let isActive: Bool
  @Binding var externalIsActive: Bool
  let onExit: () -> Void
  let onBlockedModeSwitch: () -> Void

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.canvasModeSwitchBlockedAction, isActive ? onBlockedModeSwitch : nil)
      .onAppear {
        externalIsActive = isActive
      }
      .onChange(of: isActive) { _, newValue in
        externalIsActive = newValue
      }
      .onChange(of: externalIsActive) { _, newValue in
        guard !newValue, isActive else { return }
        onExit()
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

func canvasCurrentDirectoryPath(
  reportedPath: String?,
  fallbackWorktreeDirectory: String
) -> String {
  guard let reportedPath = reportedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
    !reportedPath.isEmpty
  else {
    return fallbackWorktreeDirectory
  }
  return reportedPath
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
