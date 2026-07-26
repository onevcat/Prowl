import AppKit
import CoreGraphics
import Foundation
import GhosttyKit

extension WorktreeTerminalState {
  func confirmCloseIfNeeded(
    tabIds: [TerminalTabID],
    mode: TerminalCloseConfirmationMode
  ) -> Bool {
    let surfaceIDs = tabIds.flatMap { tabId in
      trees[tabId]?.leaves().map(\.id) ?? []
    }
    return confirmCloseIfNeeded(surfaceIDs: surfaceIDs, mode: mode)
  }

  func confirmCloseIfNeeded(
    surfaceIDs: [UUID],
    mode: TerminalCloseConfirmationMode
  ) -> Bool {
    guard !surfaceIDs.isEmpty else { return true }
    switch mode {
    case .skip:
      return true
    case .prompt(let target):
      let candidates = closeProtectionCandidates(surfaceIDs: surfaceIDs)
      let decision = TerminalCloseConfirmationPolicy.decision(for: candidates)
      guard decision.requiresConfirmation else { return true }
      return presentCloseConfirmation(target: target, decision: decision)
    }
  }

  func closeProtectionCandidates(surfaceIDs: [UUID]) -> [TerminalCloseProtectionCandidate] {
    let now = Date()
    return surfaceIDs.map { surfaceID in
      let agentState = surfaceAgentStates[surfaceID]
      let runningDuration = surfaceRunningStartedAtById[surfaceID].map { now.timeIntervalSince($0) }
      return TerminalCloseProtectionCandidate(
        hasAgent: agentState?.detectedAgent != nil,
        agentDisplayState: agentState?.displayState,
        commandRunningDuration: runningDuration
      )
    }
  }

  func presentCloseConfirmation(
    target: TerminalCloseConfirmationTarget,
    decision: TerminalCloseConfirmationDecision
  ) -> Bool {
    let alert = NSAlert()
    alert.messageText = target.messageText
    alert.informativeText = closeConfirmationMessage(for: decision)
    alert.alertStyle = .warning
    alert.addButton(withTitle: target.confirmButtonTitle)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  func closeConfirmationMessage(for decision: TerminalCloseConfirmationDecision) -> String {
    let paneText = decision.protectedPaneCount == 1 ? "pane" : "panes"
    let reasonText: String
    if decision.reasons == Set([.agentActive]) {
      reasonText = "active agent work or an unseen agent result"
    } else if decision.reasons == Set([.longRunningCommand]) {
      reasonText = "a command that has been running for at least 10 seconds"
    } else {
      reasonText = "active agent work, unseen agent results, or long-running commands"
    }
    return "This will close \(decision.protectedPaneCount) \(paneText) with \(reasonText)."
  }

  func splitTree(
    for tabId: TerminalTabID,
    inheritingFromSurfaceId: UUID? = nil,
    initialInput: String? = nil,
    workingDirectoryOverride: URL? = nil,
    context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_TAB
  ) -> SplitTree<GhosttySurfaceView> {
    guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
      return SplitTree()
    }
    if let existing = trees[tabId] {
      return existing
    }
    let surface = createSurface(
      tabId: tabId,
      initialInput: initialInput,
      inheritingFromSurfaceId: inheritingFromSurfaceId,
      workingDirectoryOverride: workingDirectoryOverride,
      context: context
    )
    let tree = SplitTree(view: surface)
    trees[tabId] = tree
    focusedSurfaceIdByTab[tabId] = surface.id
    return tree
  }

  /// Splits the currently focused surface and seeds the new pane with `initialInput`.
  /// Returns the new surface id, or nil if the split could not be created.
  @discardableResult
  func createSplitOnFocusedSurface(
    direction: UserCustomSplitDirection,
    initialInput: String
  ) -> UUID? {
    guard let tabId = tabManager.selectedTabId,
      let parentSurfaceId = focusedSurfaceIdByTab[tabId],
      let tree = trees[tabId],
      let parentSurface = surfaces[parentSurfaceId]
    else {
      return nil
    }
    let newSurface = createSurface(
      tabId: tabId,
      initialInput: runScriptInput(initialInput),
      inheritingFromSurfaceId: parentSurfaceId,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT
    )
    do {
      let newTree = try tree.inserting(
        view: newSurface,
        at: parentSurface,
        direction: mapUserSplitDirection(direction)
      )
      updateTree(newTree, for: tabId)
      if isCanvasManaged {
        newSurface.setOcclusion(true)
      }
      focusSurface(newSurface, in: tabId)
      _ = registerTargetHandle(for: newSurface.id)
      return newSurface.id
    } catch {
      newSurface.closeSurface()
      surfaces.removeValue(forKey: newSurface.id)
      surfaceRunningStartedAtById.removeValue(forKey: newSurface.id)
      cleanupCommandDetectorState(forSurfaceId: newSurface.id)
      cleanupAgentDetectionState(forSurfaceId: newSurface.id)
      return nil
    }
  }

  /// Returns the focused surface id for a given tab, if any.
  func focusedSurfaceId(in tabId: TerminalTabID) -> UUID? {
    focusedSurfaceIdByTab[tabId]
  }

  func activeSurfaceID(for tabId: TerminalTabID) -> UUID? {
    focusedSurfaceIdByTab[tabId]
  }

  /// Marks a surface so that its next successful `command_finished` event (exit 0)
  /// will trigger a one-shot close of that surface.
  func markSurfaceForAutoClose(_ surfaceId: UUID) {
    autoCloseSurfaceIds.insert(surfaceId)
  }

  func isMarkedForAutoClose(_ surfaceId: UUID) -> Bool {
    autoCloseSurfaceIds.contains(surfaceId)
  }

  /// Records the user-facing Custom Command name associated with a freshly created surface,
  /// so a success toast can be emitted when that surface's next command exits with code 0.
  func markSurfaceForCustomCommand(_ surfaceId: UUID, name: String) {
    pendingCustomCommands[surfaceId] = name
  }

  /// Pin a Custom Command's configured icon onto its host tab so the
  /// auto-detector can't swap it out when the script's OSC-2 title
  /// matches a known command. Yields to a user-set icon lock — manual
  /// picker selections always win.
  func applyCustomCommandIcon(_ icon: String, surfaceId: UUID) {
    let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let tabId = tabId(containing: surfaceId) else { return }
    tabManager.setScriptIcon(tabId, icon: trimmed)
  }

  // Short delay lets the user see the final output before the pane disappears.
  static let autoCloseDelay: Duration = .milliseconds(800)

  func scheduleAutoClose(surfaceId: UUID) {
    Task { [weak self] in
      try? await Task.sleep(for: Self.autoCloseDelay)
      guard let self else { return }
      guard let view = self.surfaces[surfaceId] else { return }
      self.handleCloseRequest(for: view, processAlive: false)
    }
  }

  func performSplitAction(_ action: GhosttySplitAction, for surfaceId: UUID) -> Bool {
    guard let tabId = tabId(containing: surfaceId), var tree = trees[tabId] else {
      return false
    }
    guard let targetNode = tree.find(id: surfaceId) else { return false }
    guard let targetSurface = surfaces[surfaceId] else { return false }

    switch action {
    case .newSplit(let direction):
      let newSurface = createSurface(
        tabId: tabId,
        initialInput: nil,
        inheritingFromSurfaceId: surfaceId,
        context: GHOSTTY_SURFACE_CONTEXT_SPLIT
      )
      do {
        let newTree = try tree.inserting(
          view: newSurface,
          at: targetSurface,
          direction: mapSplitDirection(direction)
        )
        updateTree(newTree, for: tabId)
        // Canvas manages occlusion directly; ensure the new pane renders.
        if isCanvasManaged {
          newSurface.setOcclusion(true)
        }
        focusSurface(newSurface, in: tabId)
        _ = registerTargetHandle(for: newSurface.id)
        return true
      } catch {
        newSurface.closeSurface()
        surfaces.removeValue(forKey: newSurface.id)
        surfaceRunningStartedAtById.removeValue(forKey: newSurface.id)
        cleanupCommandDetectorState(forSurfaceId: newSurface.id)
        cleanupAgentDetectionState(forSurfaceId: newSurface.id)

        return false
      }

    case .gotoSplit(let direction):
      let focusDirection = mapFocusDirection(direction)
      guard let nextSurface = tree.focusTarget(for: focusDirection, from: targetNode) else {
        return false
      }
      if tree.zoomed != nil {
        tree = tree.settingZoomed(nil)
        trees[tabId] = tree
      }
      focusSurface(nextSurface, in: tabId)
      syncFocusIfNeeded()
      return true

    case .resizeSplit(let direction, let amount):
      let spatialDirection = mapResizeDirection(direction)
      do {
        let newTree = try tree.resizing(
          node: targetNode,
          by: amount,
          in: spatialDirection,
          with: CGRect(origin: .zero, size: tree.viewBounds())
        )
        updateTree(newTree, for: tabId)
        return true
      } catch {
        return false
      }

    case .equalizeSplits:
      updateTree(tree.equalized(), for: tabId)
      return true

    case .toggleSplitZoom:
      guard tree.isSplit else { return false }
      let newZoomed = (tree.zoomed == targetNode) ? nil : targetNode
      updateTree(tree.settingZoomed(newZoomed), for: tabId)
      focusSurface(targetSurface, in: tabId)
      return true
    }
  }

  func performSplitOperation(_ operation: TerminalSplitTreeView.Operation, in tabId: TerminalTabID) {
    guard var tree = trees[tabId] else { return }

    switch operation {
    case .resize(let node, let ratio):
      let resizedNode = node.resizing(to: ratio)
      do {
        tree = try tree.replacing(node: node, with: resizedNode)
        updateTree(tree, for: tabId)
      } catch {
        return
      }

    case .drop(let payloadId, let destinationId, let zone):
      guard let payload = surfaces[payloadId] else { return }
      guard let destination = surfaces[destinationId] else { return }
      if payload === destination { return }
      guard let sourceNode = tree.root?.node(view: payload) else { return }
      let treeWithoutSource = tree.removing(sourceNode)
      if treeWithoutSource.isEmpty { return }
      do {
        let newTree = try treeWithoutSource.inserting(
          view: payload,
          at: destination,
          direction: mapDropZone(zone)
        )
        updateTree(newTree, for: tabId)
        focusSurface(payload, in: tabId)
      } catch {
        return
      }

    case .equalize:
      updateTree(tree.equalized(), for: tabId)

    case .toggleZoom(let surfaceId):
      _ = performSplitAction(.toggleSplitZoom, for: surfaceId)
    }
  }

  func setAllSurfacesOccluded() {
    for surface in surfaces.values {
      surface.setOcclusion(false)
      surface.focusDidChange(false)
    }
  }

  func closeAllSurfaces() {
    for tab in tabManager.tabs {
      unregisterTargetHandle(for: tab.id)
    }
    for surface in surfaces.values {
      unregisterTargetHandle(for: surface.id)
      surface.closeSurface()
    }
    surfaces.removeAll()
    trees.removeAll()
    focusedSurfaceIdByTab.removeAll()
    cleanupAllAgentDetectionState()
    tabIsRunningById.removeAll()
    tabAgentBusyById.removeAll()
    boundDirectoryTabIDs.removeAll()
    autoCloseSurfaceIds.removeAll()
    pendingCustomCommands.removeAll()
    setRunScriptTabId(nil)
    tabManager.closeAll()
  }

  func createSurface(
    tabId: TerminalTabID,
    initialInput: String?,
    inheritingFromSurfaceId: UUID?,
    workingDirectoryOverride: URL? = nil,
    context: ghostty_surface_context_e
  ) -> GhosttySurfaceView {
    let inherited = inheritedSurfaceConfig(fromSurfaceId: inheritingFromSurfaceId, context: context)
    let resolvedFontSize = Self.resolvedFontSizeForNewSurface(
      defaultFontSize: defaultFontSize,
      inheritedFontSize: inherited.fontSize,
      context: context
    )
    let view = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: workingDirectoryOverride ?? inherited.workingDirectory ?? worktree.workingDirectory,
      initialInput: initialInput,
      fontSize: resolvedFontSize,
      context: context,
      environment: makeSurfaceEnvironment()
    )
    // Sending a no-op font size action marks the Ghostty surface as
    // "font_size_adjusted", which prevents config reloads (triggered by
    // keybind changes on worktree switch) from resetting the font to the
    // config default.
    if resolvedFontSize != nil {
      view.performBindingAction("increase_font_size:0")
    }
    configureBridgeCallbacks(for: view, tabId: tabId)
    configureSurfaceCallbacks(for: view, tabId: tabId)
    surfaces[view.id] = view
    if initialInput?.isEmpty == false {
      wakeAgentDetection(for: view, tabId: tabId)
    }
    return view
  }

  func configureBridgeCallbacks(for view: GhosttySurfaceView, tabId: TerminalTabID) {
    view.bridge.onTitleChange = { [weak self, weak view] title in
      guard let self, let view else { return }
      if self.focusedSurfaceIdByTab[tabId] == view.id,
        self.tabManager.updateTitle(tabId, title: title)
      {
        // The tab's display title moved: refresh the whole tab because it is
        // the title fallback for panes without their own title.
        self.refreshAgentEntriesForTitleChange(in: tabId)
      } else {
        // Unfocused pane, or the tab title didn't visibly change (custom title
        // mask / no-op): only this pane's own title moved.
        self.refreshAgentEntryForTitleChange(surfaceID: view.id, in: tabId)
      }
      self.noteTitleForCommandDetection(title, surfaceId: view.id, tabId: tabId)
    }
    view.bridge.onSplitAction = { [weak self, weak view] action in
      guard let self, let view else { return false }
      return self.performSplitAction(action, for: view.id)
    }
    view.bridge.onNewTab = { [weak self, weak view] in
      guard let self, let view else { return false }
      return self.createTab(inheritingFromSurfaceId: view.id) != nil
    }
    view.bridge.onCloseTab = { [weak self] _ in
      guard let self else { return false }
      return self.closeTab(tabId)
    }
    view.bridge.onGotoTab = { [weak self] target in
      guard let self else { return false }
      return self.handleGotoTabRequest(target)
    }
    view.bridge.onCommandPaletteToggle = { [weak self] in
      guard let self else { return false }
      self.onCommandPaletteToggle?()
      return true
    }
    view.bridge.onProgressReport = { [weak self] _ in
      guard let self else { return }
      self.updateRunningState(for: tabId)
    }
    view.bridge.onDesktopNotification = { [weak self, weak view] title, body in
      guard let self, let view else { return }
      self.appendNotification(title: title, body: body, surfaceId: view.id)
    }
    view.bridge.onCommandFinished = { [weak self, weak view] exitCode, durationNs in
      guard let self, let view else { return }
      self.handleCommandFinished(exitCode: exitCode, durationNs: durationNs, surfaceId: view.id)
    }
    view.bridge.onCloseRequest = { [weak self, weak view] processAlive in
      guard let self, let view else { return }
      self.handleCloseRequest(for: view, processAlive: processAlive)
    }
    view.bridge.onPromptTitle = { [weak self] promptType in
      guard let self else { return }
      self.handlePromptTitle(promptType, tabId: tabId)
    }
  }

  func configureSurfaceCallbacks(for view: GhosttySurfaceView, tabId: TerminalTabID) {
    view.onFocusChange = { [weak self, weak view] focused in
      guard let self, let view, focused else { return }
      self.recordActiveSurface(view, in: tabId)
      self.emitTaskStatusIfChanged()
    }
    view.onKeyInput = { [weak self, weak view] in
      guard let self, let view else { return }
      self.recordKeyInput(forSurfaceID: view.id)
      self.wakeAgentDetection(for: view, tabId: tabId)
      self.markNotificationsRead(forSurfaceID: view.id)
    }
    view.onFontSizeShortcut = { [weak self] in
      guard let self else { return }
      self.onFontSizeAdjusted?()
    }
  }

  static func resolvedFontSizeForNewSurface(
    defaultFontSize: Float32?,
    inheritedFontSize: Float32?,
    context: ghostty_surface_context_e
  ) -> Float32? {
    if context == GHOSTTY_SURFACE_CONTEXT_SPLIT {
      return inheritedFontSize ?? defaultFontSize
    }
    return defaultFontSize
  }

  struct InheritedSurfaceConfig: Equatable {
    let workingDirectory: URL?
    let fontSize: Float32?
  }

  func inheritedSurfaceConfig(
    fromSurfaceId surfaceId: UUID?,
    context: ghostty_surface_context_e
  ) -> InheritedSurfaceConfig {
    guard let surfaceId,
      let view = surfaces[surfaceId],
      let sourceSurface = view.surface
    else {
      return InheritedSurfaceConfig(workingDirectory: nil, fontSize: nil)
    }

    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    let fontSize = inherited.font_size == 0 ? nil : inherited.font_size
    let workingDirectory = inherited.working_directory.flatMap { ptr -> URL? in
      let path = String(cString: ptr)
      if path.isEmpty {
        return nil
      }
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return InheritedSurfaceConfig(workingDirectory: workingDirectory, fontSize: fontSize)
  }

  func currentFocusedSurfaceId() -> UUID? {
    guard let selectedTabId = tabManager.selectedTabId else { return nil }
    return focusedSurfaceIdByTab[selectedTabId]
  }

  func handlePromptTitle(
    _ promptType: ghostty_action_prompt_title_e,
    tabId: TerminalTabID
  ) {
    guard let surfaceId = focusedSurfaceIdByTab[tabId],
      let window = surfaces[surfaceId]?.window
    else { return }
    switch promptType {
    case GHOSTTY_PROMPT_TITLE_SURFACE, GHOSTTY_PROMPT_TITLE_TAB:
      // Prowl is a single-window app so there is no per-surface window title to set.
      // Both surface and tab title prompts are treated as tab title changes for now.
      // Consider removing GHOSTTY_PROMPT_TITLE_SURFACE support entirely.
      promptTabTitle(for: tabId, in: window)
    default:
      break
    }
  }

  func promptChangeTabTitle(_ tabId: TerminalTabID) {
    let surfaceWindow = focusedSurfaceIdByTab[tabId].flatMap { surfaces[$0]?.window }
    guard let window = surfaceWindow ?? NSApp.keyWindow else { return }
    promptTabTitle(for: tabId, in: window)
  }

  func presentIconPicker(for tabId: TerminalTabID) {
    guard tabManager.tabs.contains(where: { $0.id == tabId }) else { return }
    iconPickerTabId = tabId
  }

  func presentIconPickerForFocusedTab() {
    guard let tabId = tabManager.selectedTabId else { return }
    presentIconPicker(for: tabId)
  }

  func dismissIconPicker() {
    iconPickerTabId = nil
  }

  /// Default SF Symbol used for a tab when the user has not set an override.
  func defaultIcon(for tabId: TerminalTabID) -> String {
    tabId == runScriptTabId ? "play.fill" : "terminal"
  }

  /// Apply an icon change for `tabId`. Pass `nil` to clear the override and
  /// restore the tab's default icon.
  func applyIconChange(_ tabId: TerminalTabID, icon newIcon: String?) {
    if let newIcon, !newIcon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      tabManager.overrideIcon(tabId, icon: newIcon)
    } else {
      tabManager.clearIconOverride(tabId)
      tabManager.updateIcon(tabId, icon: defaultIcon(for: tabId))
    }
  }

  func promptTabTitle(for tabId: TerminalTabID, in window: NSWindow) {
    guard let tabIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

    let alert = NSAlert()
    alert.messageText = "Change Tab Title"
    alert.informativeText = "Leave blank to restore the default."
    alert.alertStyle = .informational

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
    textField.stringValue = tabManager.tabs[tabIndex].displayTitle
    alert.accessoryView = textField

    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = textField

    alert.beginSheetModal(for: window) { [weak self] response in
      MainActor.assumeIsolated {
        guard response == .alertFirstButtonReturn else { return }
        guard let self else { return }
        let newTitle = textField.stringValue
        if self.tabManager.setCustomTitle(tabId, title: newTitle) {
          self.refreshAgentEntriesForTitleChange(in: tabId)
        }
      }
    }
  }

  func updateTabTitle(for tabId: TerminalTabID) {
    guard let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId],
      let title = surface.bridge.state.title
    else { return }
    if tabManager.updateTitle(tabId, title: title) {
      refreshAgentEntriesForTitleChange(in: tabId)
    }
  }

  func focusSurface(in tabId: TerminalTabID) {
    if let focusedId = focusedSurfaceIdByTab[tabId], let surface = surfaces[focusedId] {
      focusSurface(surface, in: tabId)
      return
    }
    let tree = splitTree(for: tabId)
    if let surface = tree.visibleLeaves().first {
      focusSurface(surface, in: tabId)
    }
  }

  func focusSurface(_ surface: GhosttySurfaceView, in tabId: TerminalTabID) {
    let previousSurface = focusedSurfaceIdByTab[tabId].flatMap { surfaces[$0] }
    recordActiveSurface(surface, in: tabId)
    guard tabId == tabManager.selectedTabId else { return }
    let fromSurface = (previousSurface === surface) ? nil : previousSurface
    GhosttySurfaceView.moveFocus(to: surface, from: fromSurface)
  }

  func recordActiveSurface(_ surface: GhosttySurfaceView, in tabId: TerminalTabID) {
    focusedSurfaceIdByTab[tabId] = surface.id
    markAgentSeen(surfaceID: surface.id)
    markNotificationsRead(forSurfaceID: surface.id)
    updateTabTitle(for: tabId)
    emitFocusChangedIfNeeded(surface.id)
  }

  /// Drops all per-surface bookkeeping for a surface that has been torn down,
  /// including any notifications it produced. A notification is keyed by its
  /// originating surface and is only cleared when that surface is focused or
  /// typed into; once the surface is gone there is no way to mark it read, so
  /// without dropping them here the worktree's unseen indicator (bell + Dock
  /// badge) would stay lit until the user manually dismisses everything.
  func forgetSurface(_ surfaceID: UUID) {
    unregisterTargetHandle(for: surfaceID)
    surfaces.removeValue(forKey: surfaceID)
    surfaceRunningStartedAtById.removeValue(forKey: surfaceID)
    autoCloseSurfaceIds.remove(surfaceID)
    pendingCustomCommands.removeValue(forKey: surfaceID)
    cleanupCommandDetectorState(forSurfaceId: surfaceID)
    cleanupAgentDetectionState(forSurfaceId: surfaceID)
    if let tabId = tabId(containing: surfaceID) {
      updateTabAgentBusyState(for: tabId)
    }
    let previousHasUnseen = hasUnseenNotification
    notifications = Self.prunedNotifications(from: notifications, removingSurfaceID: surfaceID)
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func removeTree(for tabId: TerminalTabID) {
    guard let tree = trees.removeValue(forKey: tabId) else { return }
    for surface in tree.leaves() {
      surface.closeSurface()
      forgetSurface(surface.id)
    }
    focusedSurfaceIdByTab.removeValue(forKey: tabId)
    tabIsRunningById.removeValue(forKey: tabId)
    tabAgentBusyById.removeValue(forKey: tabId)
  }

  func tabID(containing surfaceId: UUID) -> TerminalTabID? {
    for (tabId, tree) in trees where tree.find(id: surfaceId) != nil {
      return tabId
    }
    return nil
  }

  func tabId(containing surfaceId: UUID) -> TerminalTabID? {
    tabID(containing: surfaceId)
  }

  func isFocusedSurface(_ surfaceId: UUID) -> Bool {
    guard let selectedTabId = tabManager.selectedTabId else {
      return false
    }
    return focusedSurfaceIdByTab[selectedTabId] == surfaceId
  }

  /// Whether the user is actively looking at `surfaceId` right now: its worktree
  /// is selected, it is the focused pane of the selected tab (`isFocusedSurface`
  /// already implies both), and the app window is key and visible. Unknown window
  /// state (`nil`) is treated as not-viewed so a notification is never silently
  /// dropped. Canvas mode is also treated as not-viewed: the normal-mode window
  /// observers are torn down there, so `lastWindowIsKey`/`lastWindowIsVisible`
  /// freeze at their pre-canvas values and a backgrounded app would keep muting.
  func isViewedSurface(_ surfaceId: UUID) -> Bool {
    guard !isCanvasManaged else { return false }
    return isSelected() && isFocusedSurface(surfaceId) && lastWindowIsKey == true && lastWindowIsVisible == true
  }

  func updateRunningState(for tabId: TerminalTabID) {
    guard let tree = trees[tabId] else { return }
    let now = Date()
    var isRunningNow = false
    for surface in tree.leaves() {
      if isRunningProgressState(surface.bridge.state.progressState) {
        isRunningNow = true
        if surfaceRunningStartedAtById[surface.id] == nil {
          surfaceRunningStartedAtById[surface.id] = now
        }
      } else {
        surfaceRunningStartedAtById.removeValue(forKey: surface.id)
      }
    }
    tabIsRunningById[tabId] = isRunningNow
    tabManager.updateDirty(tabId, isDirty: isRunningNow)
    emitTaskStatusIfChanged()
  }

  func emitTaskStatusIfChanged() {
    let newStatus = taskStatus
    if newStatus != lastReportedTaskStatus {
      lastReportedTaskStatus = newStatus
      onTaskStatusChanged?(newStatus)
    }
  }

  func emitFocusChangedIfNeeded(_ surfaceId: UUID) {
    guard surfaceId != lastEmittedFocusSurfaceId else { return }
    lastEmittedFocusSurfaceId = surfaceId
    onFocusChanged?(surfaceId)
  }

  func emitNotificationIndicatorIfNeeded(previousHasUnseen: Bool) {
    if previousHasUnseen != hasUnseenNotification {
      onNotificationIndicatorChanged?()
    }
  }

  func syncFocusIfNeeded() {
    guard !isCanvasManaged else { return }
    guard lastWindowIsKey != nil, lastWindowIsVisible != nil else { return }
    applySurfaceActivity()
  }

  func updateTree(_ tree: SplitTree<GhosttySurfaceView>, for tabId: TerminalTabID) {
    trees[tabId] = tree
    syncFocusIfNeeded()
  }

  func isRunningProgressState(_ state: ghostty_action_progress_report_state_e?) -> Bool {
    switch state {
    case .some(GHOSTTY_PROGRESS_STATE_SET),
      .some(GHOSTTY_PROGRESS_STATE_INDETERMINATE),
      .some(GHOSTTY_PROGRESS_STATE_PAUSE),
      .some(GHOSTTY_PROGRESS_STATE_ERROR):
      return true
    default:
      return false
    }
  }

  func mapSplitDirection(_ direction: GhosttySplitAction.NewDirection)
    -> SplitTree<GhosttySurfaceView>.NewDirection
  {
    switch direction {
    case .left:
      return .left
    case .right:
      return .right
    case .top:
      return .top
    case .down:
      return .down
    }
  }

  func mapUserSplitDirection(_ direction: UserCustomSplitDirection)
    -> SplitTree<GhosttySurfaceView>.NewDirection
  {
    switch direction {
    case .left:
      return .left
    case .right:
      return .right
    case .top:
      return .top
    case .down:
      return .down
    }
  }

  func mapFocusDirection(_ direction: GhosttySplitAction.FocusDirection)
    -> SplitTree<GhosttySurfaceView>.FocusDirection
  {
    switch direction {
    case .previous:
      return .previous
    case .next:
      return .next
    case .left:
      return .spatial(.left)
    case .right:
      return .spatial(.right)
    case .top:
      return .spatial(.top)
    case .down:
      return .spatial(.down)
    }
  }

  func mapResizeDirection(_ direction: GhosttySplitAction.ResizeDirection)
    -> SplitTree<GhosttySurfaceView>.SpatialDirection
  {
    switch direction {
    case .left:
      return .left
    case .right:
      return .right
    case .top:
      return .top
    case .down:
      return .down
    }
  }

  @discardableResult
  func closeSurface(id surfaceID: UUID, confirmation: TerminalCloseConfirmationMode = .prompt(.pane)) -> Bool {
    guard let view = surfaces[surfaceID] else { return false }
    return closeSurface(view, confirmation: confirmation)
  }

  @discardableResult
  func handleCloseRequest(for view: GhosttySurfaceView, processAlive: Bool) -> Bool {
    let confirmation: TerminalCloseConfirmationMode = processAlive ? .prompt(.pane) : .skip
    return closeSurface(view, confirmation: confirmation)
  }

  @discardableResult
  private func closeSurface(_ view: GhosttySurfaceView, confirmation: TerminalCloseConfirmationMode) -> Bool {
    guard surfaces[view.id] != nil else { return false }
    guard confirmCloseIfNeeded(surfaceIDs: [view.id], mode: confirmation) else { return false }
    guard let tabId = tabId(containing: view.id), let tree = trees[tabId] else {
      view.closeSurface()
      forgetSurface(view.id)
      return true
    }
    guard let node = tree.find(id: view.id) else {
      view.closeSurface()
      forgetSurface(view.id)
      return true
    }
    let nextSurface =
      focusedSurfaceIdByTab[tabId] == view.id
      ? tree.focusTargetAfterClosing(node)
      : nil
    let newTree = tree.removing(node)
    view.closeSurface()
    forgetSurface(view.id)
    if newTree.isEmpty {
      trees.removeValue(forKey: tabId)
      focusedSurfaceIdByTab.removeValue(forKey: tabId)
      removeBoundDirectoryTab(tabId)
      tabManager.closeTab(tabId)
      unregisterTargetHandle(for: tabId)
      if tabId == runScriptTabId {
        setRunScriptTabId(nil)
      }
      // Mirror `state.closeTab(_:)`'s `onTabClosed` emit: this path
      // fires when the shell process exits (ghostty-driven close)
      // and historically skipped the callback, which meant the
      // Shelf's "retire the book when its last tab closes" logic
      // never saw this very common path.
      onTabClosed?()
      return true
    }
    updateTree(newTree, for: tabId)
    updateRunningState(for: tabId)
    if focusedSurfaceIdByTab[tabId] == view.id {
      if let nextSurface {
        focusSurface(nextSurface, in: tabId)
      } else {
        focusedSurfaceIdByTab.removeValue(forKey: tabId)
      }
    }
    return true
  }

  func handleGotoTabRequest(_ target: ghostty_action_goto_tab_e) -> Bool {
    let tabs = tabManager.tabs
    guard !tabs.isEmpty else { return false }
    let raw = Int(target.rawValue)
    let selectedIndex = tabManager.selectedTabId.flatMap { selected in
      tabs.firstIndex { $0.id == selected }
    }
    let targetIndex: Int
    if raw <= 0 {
      switch raw {
      case Int(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue):
        let current = selectedIndex ?? 0
        targetIndex = (current - 1 + tabs.count) % tabs.count
      case Int(GHOSTTY_GOTO_TAB_NEXT.rawValue):
        let current = selectedIndex ?? 0
        targetIndex = (current + 1) % tabs.count
      case Int(GHOSTTY_GOTO_TAB_LAST.rawValue):
        targetIndex = tabs.count - 1
      default:
        return false
      }
    } else {
      targetIndex = min(raw - 1, tabs.count - 1)
    }
    selectTab(tabs[targetIndex].id)
    return true
  }

  func mapDropZone(_ zone: TerminalSplitTreeView.DropZone)
    -> SplitTree<GhosttySurfaceView>.NewDirection
  {
    switch zone {
    case .top:
      return .top
    case .bottom:
      return .down
    case .left:
      return .left
    case .right:
      return .right
    }
  }

  func nextTabIndex() -> Int {
    let prefix = "\(worktree.name) "
    var maxIndex = 0
    for tab in tabManager.tabs {
      guard tab.title.hasPrefix(prefix) else { continue }
      let suffix = tab.title.dropFirst(prefix.count)
      guard let value = Int(suffix) else { continue }
      maxIndex = max(maxIndex, value)
    }
    return maxIndex + 1
  }
}
