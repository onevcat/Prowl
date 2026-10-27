import AppKit
import SwiftUI

extension CanvasView {
  /// Run a reducer-driven canvas command (from the command palette) and clear
  /// the one-shot request.
  func fulfillCommandRequest(_ request: CanvasCommandRequest?) {
    guard let request else { return }
    switch request.command {
    case .toggleExpand:
      toggleExpandFocusedCard()
    case .layout(let kind):
      applyLayout(kind)
    case .fit:
      animateFitToView()
    case .selectAll:
      selectAllCards()
    case .navigate(let direction):
      navigateCard(direction)
    }
    onCommandConsumed(request.id)
  }

  /// Expand a card in place: raise it to the top, then flip `expandedTabID`
  /// inside one `withAnimation` so the card's size, center, and scale all
  /// interpolate together from its in-canvas frame to the full viewport at
  /// scale 1 — a magic-move from where the card actually sits. The canvas
  /// transform is left untouched, so every other card stays exactly where it
  /// was, behind a dimming scrim.
  func expandCard(_ tabID: TerminalTabID, states: [WorktreeTerminalState]) {
    guard viewportSize.width > 0, viewportSize.height > 0,
      layoutStore.cardLayouts[tabID.canvasCardKey] != nil
    else { return }
    focusSingleCard(tabID, states: states)
    withAnimation(expandAnimation) {
      expandedTabID = tabID
    }
  }

  /// Restore the expanded card back into the (unchanged) canvas.
  func collapseExpand() {
    guard expandedTabID != nil else { return }
    withAnimation(expandAnimation) {
      expandedTabID = nil
    }
    relayoutIfDeferred()
  }

  /// Drop expand state without animation — used right before a relayout takes
  /// over the canvas, or when the expanded card closed.
  func cancelExpandForRelayout() {
    expandedTabID = nil
  }

  func fulfillPendingFocusRequest(
    _ request: CanvasFocusRequest?,
    states: [WorktreeTerminalState]
  ) {
    guard let request else { return }
    let tabID = CanvasFocusResolver.resolve(
      request: request,
      candidates: canvasCards(in: states),
      currentPrimaryTabID: selectionState.primaryTabID
    )
    guard let tabID else { return }
    focusSingleCard(tabID, states: states)
    switch request.viewport {
    case .center:
      focusViewport(on: tabID)
    case .reveal:
      revealCard(tabID, allowsZoomOut: true)
    }
    onFocusRequestConsumed(request.id)
  }

  func focusViewport(on tabID: TerminalTabID) {
    guard viewportSize.width > 0, viewportSize.height > 0 else { return }
    guard let layout = layoutStore.cardLayouts[tabID.canvasCardKey] else { return }

    let horizontalPadding: CGFloat = 80
    let verticalPadding: CGFloat = 80 + bottomToolbarReserve
    let availableWidth = max(1, viewportSize.width - horizontalPadding)
    let availableHeight = max(1, viewportSize.height - verticalPadding)
    let targetScale = max(
      0.25,
      min(
        1.25,
        min(
          availableWidth / layout.size.width,
          availableHeight / (layout.size.height + titleBarHeight)
        )
      )
    )
    let targetOffset = CGSize(
      width: viewportSize.width / 2 - layout.position.x * targetScale,
      height: (viewportSize.height - bottomToolbarReserve) / 2 - layout.position.y * targetScale
    )
    animateViewport(to: CanvasViewportAnimator.Snapshot(offset: targetOffset, scale: targetScale))
  }

  /// Bring a card into view with the least change: pan if it fits at the
  /// current zoom. A card that does not fit is zoomed out to fit when
  /// `allowsZoomOut` (new cards); otherwise the zoom the user chose is kept
  /// (spatial navigation).
  func revealCard(_ tabID: TerminalTabID, allowsZoomOut: Bool) {
    // Reveal relative to where a running viewport animation (e.g. a refit) is
    // heading, so a card the refit already shows does not cancel it.
    let base =
      viewportAnimator.activeTarget
      ?? CanvasViewportAnimator.Snapshot(offset: canvasOffset, scale: canvasScale)
    guard let layout = layoutStore.cardLayouts[tabID.canvasCardKey],
      let target = CanvasViewportMath.reveal(
        cardFrame: layout.frame(titleBarHeight: titleBarHeight),
        in: CanvasViewportMath.Viewport(
          size: viewportSize,
          scale: base.scale,
          offset: base.offset,
          bottomReserve: bottomToolbarReserve
        ),
        margin: revealMargin,
        allowsZoomOut: allowsZoomOut
      )
    else { return }
    animateViewport(to: CanvasViewportAnimator.Snapshot(offset: target.offset, scale: target.scale))
  }

  func handleSelectionShieldTap(
    _ tabID: TerminalTabID,
    surfaceState _: WorktreeTerminalState,
    states: [WorktreeTerminalState]
  ) {
    let cmdHeld = NSEvent.modifierFlags.contains(.command)
    mutateSelection(states: states) { state in
      if cmdHeld {
        state.toggleSelection(tabID)
      } else if state.isBroadcasting, state.selectedTabIDs.contains(tabID) {
        state.setPrimary(tabID)
      } else {
        state.focusSingle(tabID)
      }
    }
  }

  func clearSelection(states: [WorktreeTerminalState]) {
    mutateSelection(states: states) { state in
      state.clear()
    }
  }

  func pruneSelection(
    previousOrder: [TerminalTabID],
    currentOrder: [TerminalTabID],
    states: [WorktreeTerminalState]
  ) {
    let previousPrimaryTabID = selectionState.primaryTabID
    selectionState.pruneAutoAdvancingPrimary(previousOrder: previousOrder, currentOrder: currentOrder)
    syncPrimaryFocus(from: previousPrimaryTabID, to: selectionState.primaryTabID, states: states)
    syncBroadcastCallbacks(states: states)
  }

  func mutateSelection(
    states: [WorktreeTerminalState],
    mutation: (inout CanvasSelectionState) -> Void
  ) {
    let previousPrimaryTabID = selectionState.primaryTabID
    mutation(&selectionState)
    selectionState.prune(to: Set(canvasCards(in: states).map(\.tabID)))
    syncPrimaryFocus(from: previousPrimaryTabID, to: selectionState.primaryTabID, states: states)
    syncBroadcastCallbacks(states: states)
  }

  func syncPrimaryFocus(
    from previousTabID: TerminalTabID?,
    to newTabID: TerminalTabID?,
    states: [WorktreeTerminalState]
  ) {
    if let previousTabID, previousTabID != newTabID {
      unfocusTab(previousTabID, states: states)
    }

    guard let newTabID,
      let ownerState = states.first(where: { $0.surfaceView(for: newTabID) != nil }),
      let surfaceView = ownerState.surfaceView(for: newTabID)
    else {
      terminalManager.canvasFocusedWorktreeID = nil
      onFocusedWorktreeChanged(nil)
      return
    }

    layoutStore.moveToFront(newTabID.canvasCardKey)
    ownerState.tabManager.selectTab(newTabID)
    terminalManager.canvasFocusedWorktreeID = ownerState.worktreeID
    onFocusedWorktreeChanged(ownerState.worktreeID)
    surfaceView.focusDidChange(true)
    surfaceView.requestFocus()
  }

  func unfocusTab(_ tabID: TerminalTabID, states: [WorktreeTerminalState]) {
    guard let state = states.first(where: { $0.surfaceView(for: tabID) != nil }) else { return }
    for surface in state.splitTree(for: tabID).leaves() {
      surface.focusDidChange(false)
    }
  }

  func syncBroadcastCallbacks(states: [WorktreeTerminalState]) {
    clearBroadcastCallbacks(states: states)

    guard selectionState.isBroadcasting,
      let primaryTabID = selectionState.primaryTabID,
      let primaryState = terminalManager.stateContaining(tabId: primaryTabID)
    else {
      return
    }

    let selectedTabIDs = selectionState.selectedTabIDs
    let beginBroadcast = { selectionState.beginBroadcastInteractionIfNeeded() }
    for primarySurface in primaryState.splitTree(for: primaryTabID).leaves() {
      primarySurface.onCommittedText = { [terminalManager, selectedTabIDs, primaryTabID, beginBroadcast] text in
        Task { @MainActor in
          beginBroadcast()
          terminalManager.broadcastCommittedText(text, from: primaryTabID, to: selectedTabIDs)
        }
      }
      primarySurface.onMirroredKey = {
        [terminalManager, selectedTabIDs, primaryTabID, beginBroadcast] mirroredKey in
        Task { @MainActor in
          beginBroadcast()
          terminalManager.broadcastMirroredKey(mirroredKey, from: primaryTabID, to: selectedTabIDs)
        }
      }
    }
  }

  func clearBroadcastCallbacks(states: [WorktreeTerminalState]) {
    for state in states {
      for tab in state.tabManager.tabs {
        for surface in state.splitTree(for: tab.id).leaves() {
          surface.onCommittedText = nil
          surface.onMirroredKey = nil
        }
      }
    }
  }

  // MARK: - Occlusion

  func activateCanvas() {
    cleanStaleLayouts()

    let activeStates = terminalManager.activeWorktreeStates
    // Tabs created before Canvas showed are not new cards to follow.
    for state in activeStates {
      state.lastForegroundCreatedTabID = nil
    }

    // Mark all states as canvas-managed so that tree updates (e.g. split
    // creation) don't trigger applySurfaceActivity with stale normal-mode
    // window visibility, which would occlude every surface.
    for state in activeStates {
      state.isCanvasManaged = true
    }

    // A focus request can run in onAppear before this activation task.
    // Keep that card selected instead of clearing its restored terminal focus.
    if let tabID = selectionState.primaryTabID,
      activeStates.contains(where: { $0.surfaceView(for: tabID) != nil })
    {
      syncPrimaryFocus(from: nil, to: tabID, states: activeStates)
    } else if let selectedID = terminalManager.selectedWorktreeID,
      let state = activeStates.first(where: { $0.worktreeID == selectedID }),
      let tabID = state.tabManager.selectedTabId
    {
      selectionState.focusSingle(tabID)
      syncPrimaryFocus(from: nil, to: tabID, states: activeStates)
    } else {
      selectionState.clear()
      syncBroadcastCallbacks(states: activeStates)
    }

    for state in activeStates {
      state.setAllSurfacesOccluded()
    }
    // Un-occlude all surfaces visible on canvas (including split panes)
    for state in activeStates {
      for tab in state.tabManager.tabs {
        for surface in state.splitTree(for: tab.id).leaves() {
          surface.setOcclusion(true)
        }
      }
    }
  }

  func deactivateCanvas() {
    if let commandRequest {
      onCommandDropped(commandRequest.id)
    }
    viewportAnimator.cancel()
    expandedTabID = nil
    let activeStates = terminalManager.activeWorktreeStates
    for state in activeStates {
      state.isCanvasManaged = false
    }
    clearBroadcastCallbacks(states: activeStates)
    selectionState.clear()
    // Don't occlude surfaces here. In SwiftUI's if/else view swap,
    // onAppear fires before onDisappear, so occluding here would undo
    // WorktreeTerminalTabsView.onAppear's syncFocus() and cause blank
    // surfaces. Cleanup of non-selected worktrees is handled by
    // setSelectedWorktreeID in the async exit flow.
  }

  /// The user-pinned `RepositoryAppearance` of a terminal's repository. Returns `.empty`
  /// when no entry exists, which keeps cards visually identical to before the
  /// appearance feature shipped.
  func appearance(for state: WorktreeTerminalState) -> RepositoryAppearance {
    repositoryAppearances[state.repositoryID] ?? .empty
  }

  /// Resolves the user-defined display title of a repository, falling back
  /// to `Repository.name(for:)` (folder name) when no custom title was set.
  /// Reads from the static dictionary populated by the parent reducer — no
  /// per-call `@Shared` subscription on the canvas hot path.
  func repositoryDisplayName(for state: WorktreeTerminalState) -> String {
    repositoryCustomTitles[state.repositoryID] ?? Repository.name(for: state.worktree.repositoryLocation)
  }
}
