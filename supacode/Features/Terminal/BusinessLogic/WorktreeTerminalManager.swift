import Foundation
import Observation
import Sharing
import SwiftUI

private let terminalLogger = SupaLogger("Terminal")
private let layoutRestoreFailureMessage = "Saved terminal layout was invalid and has been reset"

@MainActor
@Observable
final class WorktreeTerminalManager {
  private let runtime: GhosttyRuntime?
  private let layoutPersistence: TerminalLayoutPersistenceClient
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  private var notificationsEnabled = true
  private var commandFinishedNotificationEnabled = true
  private var commandFinishedNotificationThreshold = 10
  private var agentDetectionEnabled = true
  private var preferredFontSize: Float32?
  private let baselineFontSize: Float32
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  var selectedWorktreeID: Worktree.ID?
  /// The worktree+tab focused in Canvas, updated by CanvasView on card tap.
  /// Used by toggleCanvas to know which worktree to return to.
  var canvasFocusedWorktreeID: Worktree.ID?

  init(
    runtime: GhosttyRuntime,
    preferredFontSize: Float32? = nil,
    layoutPersistence: TerminalLayoutPersistenceClient = .liveValue
  ) {
    self.runtime = runtime
    self.layoutPersistence = layoutPersistence
    self.preferredFontSize = preferredFontSize
    baselineFontSize = runtime.defaultFontSize()
  }

  func handleCommand(_ command: TerminalClient.Command) {
    if handleTabCommand(command) {
      return
    }
    if handleBindingActionCommand(command) {
      return
    }
    if handleSearchCommand(command) {
      return
    }
    handleManagementCommand(command)
  }

  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew):
      Task { createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew) }
    case .createTabWithInput(
      let worktree, let input, let runSetupScriptIfNew, let autoCloseOnSuccess, let customCommandName,
      let customCommandIcon):
      Task {
        createTabAsync(
          in: worktree,
          runSetupScriptIfNew: runSetupScriptIfNew,
          initialInput: input,
          autoCloseOnSuccess: autoCloseOnSuccess,
          customCommandName: customCommandName,
          customCommandIcon: customCommandIcon
        )
      }
    case .createSplitWithInput(
      let worktree, let direction, let input, let autoCloseOnSuccess, let customCommandName, let customCommandIcon):
      Task {
        createSplitAsync(
          in: worktree,
          direction: direction,
          initialInput: input,
          autoCloseOnSuccess: autoCloseOnSuccess,
          customCommandName: customCommandName,
          customCommandIcon: customCommandIcon
        )
      }
    case .createTabInDirectory(let worktree, let directory):
      Task {
        createTabAsync(in: worktree, runSetupScriptIfNew: false, workingDirectory: directory)
      }
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .runScript(let worktree, let script):
      _ = state(for: worktree).runScript(script)
    case .insertText(let worktree, let text):
      if !state(for: worktree).focusAndRunCommand(text) {
        Task {
          createTabAsync(
            in: worktree,
            runSetupScriptIfNew: false,
            initialInput: text,
            autoCloseOnSuccess: false
          )
        }
      }
    case .stopRunScript(let worktree):
      _ = state(for: worktree).stopRunScript()
    case .closeFocusedTab(let worktree):
      _ = closeFocusedTab(in: worktree)
    case .closeFocusedSurface(let worktree):
      _ = closeFocusedSurface(in: worktree)
    case .focusSelectedTab(let worktree):
      state(for: worktree).focusSelectedTab()
    default:
      return false
    }
    return true
  }

  private func handleSearchCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .startSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("start_search")
    case .searchSelection(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("search_selection")
    case .navigateSearchNext(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.previous)
    case .endSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("end_search")
    default:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      state(for: worktree).performBindingActionOnFocusedSurface(action)
    default:
      return false
    }
    return true
  }

  private func handleManagementCommand(_ command: TerminalClient.Command) {
    switch command {
    case .prune(let ids):
      prune(keeping: ids)
    case .setNotificationsEnabled(let enabled):
      setNotificationsEnabled(enabled)
    case .setCommandFinishedNotification(let enabled, let threshold):
      setCommandFinishedNotification(enabled: enabled, threshold: threshold)
    case .setAgentDetectionEnabled(let enabled):
      setAgentDetectionEnabled(enabled)
    case .setCanvasMode(let enabled):
      if enabled {
        terminalLogger.info("[CanvasExit] enteringCanvas previousSelectedWorktree=\(selectedWorktreeID ?? "nil")")
        selectedWorktreeID = nil
      }
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      let previousSelectedWorktreeID = selectedWorktreeID
      let leavingCanvas = previousSelectedWorktreeID == nil
      if let previousID = previousSelectedWorktreeID, let previousState = states[previousID] {
        previousState.setAllSurfacesOccluded()
      } else if leavingCanvas {
        // Leaving canvas mode: occlude all worktrees except the newly selected one.
        for (wid, state) in states where wid != id {
          state.setAllSurfacesOccluded()
        }
      }
      selectedWorktreeID = id
      terminalLogger.info(
        "[CanvasExit] setSelectedWorktreeID previous=\(previousSelectedWorktreeID ?? "nil") "
          + "next=\(id ?? "nil") leavingCanvas=\(leavingCanvas) states=\(states.count)"
      )
      terminalLogger.info("Selected worktree \(id ?? "nil")")
    case .saveLayoutSnapshot:
      terminalLogger.info("[LayoutRestore] received saveLayoutSnapshot command")
      Task { await persistLayoutSnapshot() }
    case .restoreLayoutSnapshot(let worktrees):
      terminalLogger.info("[LayoutRestore] received restoreLayoutSnapshot command, worktrees=\(worktrees.count)")
      Task { await restoreLayoutSnapshot(from: worktrees) }
    case .presentTabIconPicker(let worktree):
      state(for: worktree).presentIconPickerForFocusedTab()
    default:
      return
    }
  }

  func eventStream() -> AsyncStream<TerminalClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: TerminalClient.Event.self)
    eventContinuation = continuation
    lastNotificationIndicatorCount = nil
    if !pendingEvents.isEmpty {
      let bufferedEvents = pendingEvents
      pendingEvents.removeAll()
      for event in bufferedEvents {
        if case .notificationIndicatorChanged = event {
          continue
        }
        continuation.yield(event)
      }
    }
    emitNotificationIndicatorCountIfNeeded()
    return stream
  }

  func state(
    for worktree: Worktree,
    runSetupScriptIfNew: () -> Bool = { false }
  ) -> WorktreeTerminalState {
    if let existing = states[worktree.id] {
      existing.setDefaultFontSize(preferredFontSize)
      if runSetupScriptIfNew() {
        existing.enableSetupScriptIfNeeded()
      }
      return existing
    }
    let runSetupScript = runSetupScriptIfNew()
    let state = WorktreeTerminalState(
      runtime: runtime!,
      worktree: worktree,
      runSetupScript: runSetupScript,
      defaultFontSize: preferredFontSize
    )
    state.setNotificationsEnabled(notificationsEnabled)
    state.setCommandFinishedNotification(
      enabled: commandFinishedNotificationEnabled,
      threshold: commandFinishedNotificationThreshold
    )
    state.setAgentDetectionEnabled(agentDetectionEnabled)
    state.isSelected = { [weak self] in
      self?.selectedWorktreeID == worktree.id
    }
    state.onNotificationReceived = { [weak self] surfaceID, title, body in
      self?.emit(.notificationReceived(worktreeID: worktree.id, surfaceID: surfaceID, title: title, body: body))
    }
    state.onNotificationIndicatorChanged = { [weak self] in
      self?.emitNotificationIndicatorCountIfNeeded()
    }
    state.onTabCreated = { [weak self] in
      self?.emit(.tabCreated(worktreeID: worktree.id))
    }
    state.onTabClosed = { [weak self, weak state] in
      guard let self else { return }
      let remaining = state?.tabManager.tabs.count ?? 0
      emit(.tabClosed(worktreeID: worktree.id, remainingTabs: remaining))
    }
    state.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
    }
    state.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
    }
    state.onAgentEntryChanged = { [weak self] entry in
      self?.emit(.agentEntryChanged(entry))
    }
    state.onAgentEntryRemoved = { [weak self] id in
      self?.emit(.agentEntryRemoved(id))
    }
    state.onRunScriptStatusChanged = { [weak self] isRunning in
      self?.emit(.runScriptStatusChanged(worktreeID: worktree.id, isRunning: isRunning))
    }
    state.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    state.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    state.onFontSizeAdjusted = { [weak self] in
      self?.syncPreferredFontSize(from: worktree.id)
    }
    state.onCustomCommandSucceeded = { [weak self] name, durationMs in
      self?.emit(.customCommandSucceeded(worktreeID: worktree.id, name: name, durationMs: durationMs))
    }
    states[worktree.id] = state
    terminalLogger.info("Created terminal state for worktree \(worktree.id)")
    return state
  }

  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil,
    workingDirectory: URL? = nil,
    autoCloseOnSuccess: Bool = false,
    customCommandName: String? = nil,
    customCommandIcon: String? = nil
  ) {
    let state = state(for: worktree) { runSetupScriptIfNew }
    let setupScript: String?
    // Skip setup injection when auto-close is requested so the setup script's
    // own exit code cannot trigger the close before the user's command runs.
    if !autoCloseOnSuccess, state.needsSetupScript() {
      @SharedReader(.repositorySettings(worktree.repositoryRootURL))
      var settings = RepositorySettings.default
      setupScript = settings.setupScript
    } else {
      setupScript = nil
    }
    let tabId = state.createTab(
      setupScript: setupScript,
      initialInput: initialInput,
      workingDirectoryOverride: workingDirectory
    )
    if let tabId, let surfaceId = state.focusedSurfaceId(in: tabId) {
      if autoCloseOnSuccess {
        state.markSurfaceForAutoClose(surfaceId)
      }
      if let customCommandName {
        state.markSurfaceForCustomCommand(surfaceId, name: customCommandName)
      }
      if let customCommandIcon {
        state.applyCustomCommandIcon(customCommandIcon, surfaceId: surfaceId)
      }
    }
  }

  private func createSplitAsync(
    in worktree: Worktree,
    direction: UserCustomSplitDirection,
    initialInput: String,
    autoCloseOnSuccess: Bool,
    customCommandName: String? = nil,
    customCommandIcon: String? = nil
  ) {
    let state = state(for: worktree)
    guard
      let newSurfaceId = state.createSplitOnFocusedSurface(
        direction: direction,
        initialInput: initialInput
      )
    else {
      return
    }
    if autoCloseOnSuccess {
      state.markSurfaceForAutoClose(newSurfaceId)
    }
    if let customCommandName {
      state.markSurfaceForCustomCommand(newSurfaceId, name: customCommandName)
    }
    if let customCommandIcon {
      state.applyCustomCommandIcon(customCommandIcon, surfaceId: newSurfaceId)
    }
  }

  @discardableResult
  func closeFocusedTab(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedTab()
  }

  @discardableResult
  func closeFocusedSurface(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedSurface()
  }

  func prune(keeping worktreeIDs: Set<Worktree.ID>) {
    var removed: [WorktreeTerminalState] = []
    for (id, state) in states where !worktreeIDs.contains(id) {
      removed.append(state)
    }
    for state in removed {
      state.closeAllSurfaces()
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    emitNotificationIndicatorCountIfNeeded()
  }

  var activeWorktreeStates: [WorktreeTerminalState] {
    states.values.filter { !$0.tabManager.tabs.isEmpty }
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  func stateContaining(tabId: TerminalTabID) -> WorktreeTerminalState? {
    activeWorktreeStates.first { $0.surfaceView(for: tabId) != nil }
  }

  @discardableResult
  func broadcastCommittedText(
    _ text: String,
    from primaryTabID: TerminalTabID,
    to selectedTabIDs: Set<TerminalTabID>
  ) -> Int {
    var mirrored = 0
    for tabId in selectedTabIDs where tabId != primaryTabID {
      if stateContaining(tabId: tabId)?.insertCommittedText(text, in: tabId) == true {
        mirrored += 1
      } else {
        terminalLogger.debug("Broadcast text failed for tab \(tabId)")
      }
    }
    return mirrored
  }

  @discardableResult
  func broadcastMirroredKey(
    _ key: MirroredTerminalKey,
    from primaryTabID: TerminalTabID,
    to selectedTabIDs: Set<TerminalTabID>
  ) -> Int {
    var mirrored = 0
    for tabId in selectedTabIDs where tabId != primaryTabID {
      if stateContaining(tabId: tabId)?.applyMirroredKey(key, in: tabId) == true {
        mirrored += 1
      } else {
        terminalLogger.debug("Broadcast key failed for tab \(tabId)")
      }
    }
    return mirrored
  }

  func taskStatus(for worktreeID: Worktree.ID) -> WorktreeTaskStatus? {
    states[worktreeID]?.taskStatus
  }

  func isRunScriptRunning(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.isRunScriptRunning == true
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    for state in states.values {
      state.setNotificationsEnabled(enabled)
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  func setCommandFinishedNotification(enabled: Bool, threshold: Int) {
    commandFinishedNotificationEnabled = enabled
    commandFinishedNotificationThreshold = threshold
    for state in states.values {
      state.setCommandFinishedNotification(enabled: enabled, threshold: threshold)
    }
  }

  func setAgentDetectionEnabled(_ enabled: Bool) {
    guard agentDetectionEnabled != enabled else { return }
    agentDetectionEnabled = enabled
    for state in states.values {
      state.setAgentDetectionEnabled(enabled)
    }
  }

  func hasUnseenNotifications(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.hasUnseenNotification == true
  }

  func latestUnreadNotificationLocation() -> NotificationLocation? {
    var bestLocation: NotificationLocation?
    var bestCreatedAt: Date?
    for (worktreeID, state) in states {
      for notification in state.unreadNotifications() {
        if let bestCreatedAt, bestCreatedAt >= notification.createdAt {
          break
        }
        guard let tabID = state.tabID(containing: notification.surfaceId) else {
          continue
        }
        bestLocation = NotificationLocation(
          worktreeID: worktreeID,
          tabID: tabID,
          surfaceID: notification.surfaceId,
          notificationID: notification.id
        )
        bestCreatedAt = notification.createdAt
        break
      }
    }
    return bestLocation
  }

  @discardableResult
  func focusSurface(worktreeID: Worktree.ID, surfaceID: UUID) -> Bool {
    states[worktreeID]?.focusSurface(id: surfaceID) == true
  }

  func markNotificationRead(worktreeID: Worktree.ID, notificationID: UUID) {
    states[worktreeID]?.markNotificationRead(id: notificationID)
  }

  func markNotificationsRead(worktreeID: Worktree.ID, surfaceID: UUID) {
    states[worktreeID]?.markNotificationsRead(forSurfaceID: surfaceID)
  }

  func surfaceBackgroundOpacity() -> Double {
    runtime?.backgroundOpacity() ?? 1.0
  }

  func unfocusedSplitOverlay() -> (fill: Color?, opacity: Double) {
    guard let runtime else { return (nil, 0) }
    return (runtime.unfocusedSplitFill(), runtime.unfocusedSplitOverlayOpacity())
  }

  func splitDividerAppearance() -> (color: Color?, width: CGFloat?) {
    guard let runtime else { return (nil, nil) }
    return (runtime.splitDividerColor(), runtime.splitDividerWidth())
  }

  func syncPreferredFontSize(from worktreeID: Worktree.ID) {
    guard let state = states[worktreeID] else { return }
    let fontSize = state.focusedFontSize()
    let normalized = normalizedFontSize(fontSize)
    guard preferredFontSize != normalized else { return }
    preferredFontSize = normalized
    for worktreeState in states.values {
      worktreeState.setDefaultFontSize(normalized)
    }
    emit(.fontSizeChanged(normalized))
  }

  private func normalizedFontSize(_ fontSize: Float32?) -> Float32? {
    guard let fontSize else { return nil }
    let epsilon: Float32 = 0.01
    if abs(fontSize - baselineFontSize) <= epsilon {
      return nil
    }
    return fontSize
  }

  private func emit(_ event: TerminalClient.Event) {
    guard let eventContinuation else {
      pendingEvents.append(event)
      return
    }
    eventContinuation.yield(event)
  }

  private func emitNotificationIndicatorCountIfNeeded() {
    let count = states.values.reduce(0) { count, state in
      count + (state.hasUnseenNotification ? 1 : 0)
    }
    if count != lastNotificationIndicatorCount {
      lastNotificationIndicatorCount = count
      emit(.notificationIndicatorChanged(count: count))
    }
  }

  func persistLayoutSnapshot() async {
    guard let payload = makeLayoutSnapshotPayload() else {
      terminalLogger.info("[LayoutRestore] persist: no active states, clearing snapshot")
      _ = await layoutPersistence.clearSnapshot()
      return
    }
    terminalLogger.info("[LayoutRestore] persist: saving \(payload.worktrees.count) worktree(s)")
    let saved = await layoutPersistence.saveSnapshot(payload)
    terminalLogger.info("[LayoutRestore] persist: save result=\(saved)")
  }

  func persistLayoutSnapshotSync() {
    guard let payload = makeLayoutSnapshotPayload() else {
      terminalLogger.info("[LayoutRestore] persistSync: no active states, clearing snapshot")
      discardTerminalLayoutSnapshot(at: SupacodePaths.terminalLayoutSnapshotURL, fileManager: .default)
      return
    }
    terminalLogger.info("[LayoutRestore] persistSync: saving \(payload.worktrees.count) worktree(s)")
    let saved = saveTerminalLayoutSnapshot(
      payload,
      at: SupacodePaths.terminalLayoutSnapshotURL,
      cacheDirectory: SupacodePaths.cacheDirectory,
      fileManager: .default
    )
    terminalLogger.info("[LayoutRestore] persistSync: save result=\(saved)")
  }

  func restoreLayoutSnapshot(from worktrees: [Worktree]) async {
    terminalLogger.info("[LayoutRestore] restore: loading snapshot from disk")
    guard let payload = await layoutPersistence.loadSnapshot() else {
      terminalLogger.info("[LayoutRestore] restore: no snapshot found on disk, skipping")
      emit(.layoutRestored(selectedWorktreeID: nil))
      return
    }
    terminalLogger.info(
      "[LayoutRestore] restore: loaded snapshot with \(payload.worktrees.count) worktree(s),"
        + " available worktrees=\(worktrees.count)"
    )
    for (index, snapshot) in payload.worktrees.enumerated() {
      terminalLogger.info(
        "[LayoutRestore] restore: snapshot[\(index)] worktreeID=\(snapshot.worktreeID)"
          + " tabs=\(snapshot.tabs.count) selectedTab=\(snapshot.selectedTabID ?? "nil")"
      )
    }
    for (index, worktree) in worktrees.enumerated() {
      terminalLogger.info("[LayoutRestore] restore: available[\(index)] id=\(worktree.id) name=\(worktree.name)")
    }
    let didRestore = applyLayoutSnapshotPayload(payload, availableWorktrees: worktrees)
    terminalLogger.info("[LayoutRestore] restore: applyResult=\(didRestore)")
    if didRestore {
      terminalLogger.info(
        "[LayoutRestore] restore: emitting layoutRestored selectedWorktreeID=\(payload.selectedWorktreeID ?? "nil")"
      )
      emit(.layoutRestored(selectedWorktreeID: payload.selectedWorktreeID))
    } else {
      terminalLogger.warning("[LayoutRestore] restore: clearing invalid snapshot and emitting failure toast")
      _ = await layoutPersistence.clearSnapshot()
      emit(.layoutRestoreFailed(message: layoutRestoreFailureMessage))
    }
  }

  private func makeLayoutSnapshotPayload() -> TerminalLayoutSnapshotPayload? {
    let activeStates = activeWorktreeStates.sorted { $0.worktreeID < $1.worktreeID }
    terminalLogger.info(
      "[LayoutRestore] makePayload: activeWorktreeStates=\(activeStates.count)"
        + " totalStates=\(states.count)"
    )
    guard !activeStates.isEmpty else {
      return nil
    }

    var snapshotWorktrees: [TerminalLayoutSnapshotPayload.SnapshotWorktree] = []
    snapshotWorktrees.reserveCapacity(activeStates.count)
    for state in activeStates {
      guard let snapshot = state.makeLayoutSnapshotWorktree() else {
        terminalLogger.warning(
          "[LayoutRestore] makePayload: failed to snapshot worktree \(state.worktreeID)"
        )
        return nil
      }
      snapshotWorktrees.append(snapshot)
    }
    return TerminalLayoutSnapshotPayload(
      selectedWorktreeID: selectedWorktreeID,
      worktrees: snapshotWorktrees
    )
  }

  private func applyLayoutSnapshotPayload(
    _ payload: TerminalLayoutSnapshotPayload,
    availableWorktrees: [Worktree]
  ) -> Bool {
    let worktreeByID = Dictionary(uniqueKeysWithValues: availableWorktrees.map { ($0.id, $0) })
    var restoredStates: [WorktreeTerminalState] = []
    restoredStates.reserveCapacity(payload.worktrees.count)

    for snapshot in payload.worktrees {
      guard let worktree = worktreeByID[snapshot.worktreeID] else {
        terminalLogger.warning(
          "[LayoutRestore] apply: worktreeID \(snapshot.worktreeID) not found in available worktrees"
        )
        for state in restoredStates {
          state.closeAllSurfaces()
        }
        return false
      }
      terminalLogger.info("[LayoutRestore] apply: restoring worktree \(worktree.id)")
      let state = state(for: worktree)
      guard state.applyLayoutSnapshot(snapshot) else {
        terminalLogger.warning("[LayoutRestore] apply: applyLayoutSnapshot failed for \(worktree.id)")
        state.closeAllSurfaces()
        for restored in restoredStates {
          restored.closeAllSurfaces()
        }
        return false
      }
      restoredStates.append(state)
    }

    terminalLogger.info("[LayoutRestore] apply: successfully restored \(restoredStates.count) worktree(s)")
    return true
  }

  #if DEBUG
    /// Inert instance for SwiftUI previews — no GhosttyRuntime, all reads return defaults.
    static let preview: WorktreeTerminalManager = {
      let manager = WorktreeTerminalManager(preview: ())
      return manager
    }()

    private init(preview: Void) {
      self.runtime = nil
      self.layoutPersistence = .liveValue
      self.preferredFontSize = nil
      self.baselineFontSize = 13
    }
  #endif
}
