import Foundation
import ProwlCLIShared

/// Undo for pane and tab closes (docs-ai 069).
///
/// A close detaches its surfaces instead of freeing them: every observer sees
/// the close as before (`forgetSurface` still runs), but the
/// `GhosttySurfaceView`s stay alive inside a `TerminalCloseRecord` until the
/// owner restores or frees them. Restore re-runs the adoption steps of tab
/// creation, so a restored pane is a new pane to the CLI (fresh handle) and
/// to agent detection, while its process, scrollback, split position, and
/// Profile launch identity are the original ones.
extension WorktreeTerminalState {
  /// Captures what `closeTab` is about to destroy. `nil` when undo is off or
  /// the tab has no tree to keep.
  func makeClosedTabRecord(for tabId: TerminalTabID) -> TerminalClosedTabRecord? {
    guard undoCloseTimeout > .zero,
      let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
      let tree = trees[tabId]
    else { return nil }
    var contexts: [UUID: TerminalRetainedSurfaceContext] = [:]
    for leaf in tree.leaves() {
      contexts[leaf.id] = retainedContext(for: leaf.id)
    }
    var record: TerminalClosedTabRecord? = TerminalClosedTabRecord(
      item: tabManager.tabs[index],
      index: index,
      wasSelected: tabManager.selectedTabId == tabId,
      tree: tree,
      focusedSurfaceID: focusedSurfaceIdByTab[tabId],
      wasRunScriptTab: tabId == runScriptTabId,
      boundDirectoryKey: boundDirectoryTabIDs.first { $0.value == tabId }?.key,
      contexts: contexts
    )
    // A pane whose process already ended has nothing to bring back; it is
    // freed with the close and the record keeps only the living panes.
    for leaf in tree.leaves() where leaf.childProcessHasExited {
      record = record?.removingSurface(id: leaf.id)
    }
    return record
  }

  /// Read before `forgetSurface` drops it.
  func retainedContext(for surfaceID: UUID) -> TerminalRetainedSurfaceContext {
    TerminalRetainedSurfaceContext(
      launchProfile: launchProfilesBySurface[surfaceID],
      hookRegistration: launchHookRegistrationsBySurface[surfaceID]
    )
  }

  /// True while `forgetSurface` runs for a surface that stays alive for undo,
  /// so the close-time observers can defer what a living process still needs
  /// (its Codex forwarding record).
  func isRetainedForUndo(_ surfaceID: UUID) -> Bool {
    retainedForUndoSurfaceIDs.contains(surfaceID)
  }

  /// Detaches and forgets in one step; the retained marker lives only for the
  /// duration of the observer callbacks.
  func detachAndForgetSurface(_ view: GhosttySurfaceView) {
    detachSurface(view)
    retainedForUndoSurfaceIDs.insert(view.id)
    forgetSurface(view.id)
    retainedForUndoSurfaceIDs.remove(view.id)
  }

  /// `removeTree(for:)` with the living leaves detached instead of freed.
  func detachTree(for tabId: TerminalTabID) {
    guard let tree = trees.removeValue(forKey: tabId) else { return }
    for surface in tree.leaves() {
      if surface.childProcessHasExited {
        surface.closeSurface()
        forgetSurface(surface.id)
      } else {
        detachAndForgetSurface(surface)
      }
    }
    focusedSurfaceIdByTab.removeValue(forKey: tabId)
    tabIsRunningById.removeValue(forKey: tabId)
    tabAgentBusyById.removeValue(forKey: tabId)
    tabAgentBlockedById.removeValue(forKey: tabId)
  }

  /// Suspends the view and disconnects it from this state. Only a process
  /// exit still reaches us, so the record can drop a surface that died.
  func detachSurface(_ view: GhosttySurfaceView) {
    view.suspendForPendingClose()
    let bridge = view.bridge
    bridge.onUndo = nil
    bridge.onRedo = nil
    bridge.onTitleChange = nil
    bridge.onSplitAction = nil
    bridge.onNewTab = nil
    bridge.onCloseTab = nil
    bridge.onGotoTab = nil
    bridge.onCommandPaletteToggle = nil
    bridge.onProgressReport = nil
    bridge.onDesktopNotification = nil
    bridge.onCommandFinished = nil
    bridge.onPromptTitle = nil
    bridge.onCloseRequest = { [weak self, weak view] _ in
      guard let self, let view else { return }
      onRetainedSurfaceExited?(view.id)
    }
    bridge.onChildExited = { [weak self, weak view] in
      guard let self, let view else { return }
      onRetainedSurfaceExited?(view.id)
    }
    view.onFocusChange = nil
    view.onKeyInput = nil
    view.onFontSizeShortcut = nil
  }

  func recordClosedTab(_ record: TerminalClosedTabRecord) {
    if pendingCloseGroup != nil {
      pendingCloseGroup?.append(record)
    } else {
      onCloseRecorded?(.tabs(worktreeID: worktreeID, [record]))
    }
  }

  /// Puts a closed tab back at its index with its tree. `select` reveals it;
  /// a batch restore passes the tab's original selection instead. Returns
  /// `false` when the tab is somehow present again; the caller then frees the
  /// record.
  @discardableResult
  func restore(tab record: TerminalClosedTabRecord, select: Bool) -> Bool {
    let tabId = record.tabID
    guard !tabManager.tabs.contains(where: { $0.id == tabId }) else { return false }
    tabManager.insertTab(record.item, at: record.index, select: select)
    trees[tabId] = record.tree
    for leaf in record.tree.leaves() {
      adoptRetainedSurface(leaf, tabId: tabId, context: record.contexts[leaf.id])
    }
    _ = registerTargetHandle(for: tabId)
    tabIsRunningById[tabId] = false
    if let key = record.boundDirectoryKey {
      boundDirectoryTabIDs[key] = tabId
    }
    if record.wasRunScriptTab {
      setRunScriptTabId(tabId)
    }
    let focusTarget =
      record.focusedSurfaceID.flatMap { surfaces[$0] } ?? record.tree.root?.leftmostLeaf()
    if let focusTarget {
      focusedSurfaceIdByTab[tabId] = focusTarget.id
    }
    updateRunningState(for: tabId)
    updateTabAgentBusyState(for: tabId)
    if tabManager.selectedTabId == tabId, let focusTarget {
      focusSurface(focusTarget, in: tabId)
    }
    syncFocusIfNeeded()
    emitTaskStatusIfChanged()
    onTabCreated?()
    return true
  }

  /// Puts a closed pane back by reinstating the tab's pre-close tree and
  /// selects that tab so the user sees it. Returns `false` when the tab
  /// changed shape since the close (a new split, a moved pane); the caller
  /// then frees the record.
  @discardableResult
  func restore(pane record: TerminalClosedPaneRecord) -> Bool {
    let tabId = record.tabID
    guard tabManager.tabs.contains(where: { $0.id == tabId }),
      let current = trees[tabId],
      let closedNode = record.previousTree.find(id: record.view.id)
    else { return false }
    // Leaf identity plus split direction and nesting; ratios and zoom may
    // drift within the grace window without voiding the record.
    let expected = record.previousTree.removing(closedNode).settingZoomed(nil)
    guard current.settingZoomed(nil).structuralIdentity == expected.structuralIdentity else {
      return false
    }
    adoptRetainedSurface(record.view, tabId: tabId, context: record.context)
    updateTree(record.previousTree, for: tabId)
    updateRunningState(for: tabId)
    updateTabAgentBusyState(for: tabId)
    if tabManager.selectedTabId != tabId {
      tabManager.selectTab(tabId)
    }
    if record.wasFocused {
      focusSurface(record.view, in: tabId)
    } else {
      focusSurface(in: tabId)
    }
    emitTaskStatusIfChanged()
    return true
  }

  /// The surface-level half of `createTab`'s adoption for a retained view.
  private func adoptRetainedSurface(
    _ view: GhosttySurfaceView,
    tabId: TerminalTabID,
    context: TerminalRetainedSurfaceContext?
  ) {
    view.resumeFromPendingClose()
    configureBridgeCallbacks(for: view, tabId: tabId)
    configureSurfaceCallbacks(for: view, tabId: tabId)
    surfaces[view.id] = view
    _ = registerTargetHandle(for: view.id)
    // Canvas owns occlusion and never runs the tree-change activity sync, so
    // ask for visibility here as `createSplit` does; the deferred-attachment
    // path delivers it once the card hosts the view again.
    if isCanvasManaged {
      view.setOcclusion(true)
    }
    if let profile = context?.launchProfile {
      launchProfilesBySurface[view.id] = profile
    }
    if let registration = context?.hookRegistration {
      launchHookRegistrationsBySurface[view.id] = registration
      onManagedHookReadopted?(view.id, registration)
    }
    wakeAgentDetection(for: view, tabId: tabId)
  }
}
