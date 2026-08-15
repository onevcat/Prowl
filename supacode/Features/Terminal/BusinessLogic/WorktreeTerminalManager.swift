import Foundation
import Observation
import Sharing
import SwiftUI

private let terminalLogger = SupaLogger("Terminal")
private let layoutRestoreFailureMessage = "Saved terminal layout was invalid and has been reset"

@MainActor
@Observable
final class WorktreeTerminalManager {
  struct FocusChange: Equatable {
    let token: UUID
    let worktreeID: Worktree.ID
    let surfaceID: UUID
  }

  private struct InputSourceFocusRequest: Equatable {
    let token: UUID
    let worktreeID: Worktree.ID
    let surfaceID: UUID
  }

  private let runtime: GhosttyRuntime?
  private let tmuxController: TmuxTerminalController?
  private var usesAnonymousTmux: Bool
  private let usesAnonymousTmuxForWorktree: ((Worktree) -> Bool)?
  private let layoutPersistence: TerminalLayoutPersistenceClient
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  private var notificationsEnabled = true
  private var commandFinishedNotificationEnabled = true
  private var commandFinishedNotificationThreshold = 10
  private var agentDetectionEnabled = true
  private var preferredFontSize: Float32?
  private let baselineFontSize: Float32
  private let inputSourceCoordinator: TerminalInputSourceCoordinator
  private var latestInputSourceFocusRequest: InputSourceFocusRequest?
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  private var eventCoalescer = TerminalEventCoalescer()
  /// Caps the live stream and the pre-subscription backlog so a producer that
  /// outruns the single main-actor consumer can't grow memory without bound.
  private static let eventBufferCap = 2048
  private static let pendingEventCap = 1024
  var selectedWorktreeID: Worktree.ID?
  /// The worktree+tab focused in Canvas, updated by CanvasView on card tap.
  /// Used by toggleCanvas to know which worktree to return to.
  var canvasFocusedWorktreeID: Worktree.ID? {
    didSet {
      guard canvasFocusedWorktreeID != oldValue, selectedWorktreeID == nil else { return }
      reevaluateCanvasInputSource(reason: .focusChanged)
    }
  }
  var lastFocusChange: FocusChange?

  init(
    runtime: GhosttyRuntime,
    preferredFontSize: Float32? = nil,
    tmuxController: TmuxTerminalController? = nil,
    usesAnonymousTmux: Bool = false,
    usesAnonymousTmuxForWorktree: ((Worktree) -> Bool)? = nil,
    layoutPersistence: TerminalLayoutPersistenceClient = .liveValue,
    inputSourceCoordinator: TerminalInputSourceCoordinator = TerminalInputSourceCoordinator()
  ) {
    self.runtime = runtime
    self.tmuxController = tmuxController
    self.usesAnonymousTmux = usesAnonymousTmux
    self.usesAnonymousTmuxForWorktree = usesAnonymousTmuxForWorktree
    self.layoutPersistence = layoutPersistence
    self.preferredFontSize = preferredFontSize
    self.inputSourceCoordinator = inputSourceCoordinator
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
      Task { await createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew) }
    case .createTabFromCanvas(let worktree, let runSetupScriptIfNew, let inheritFromFocusedSurface):
      Task {
        await createTabAsync(
          in: worktree,
          runSetupScriptIfNew: runSetupScriptIfNew,
          inheritFromFocusedSurface: inheritFromFocusedSurface
        )
      }
    case .createTabWithInput(
      let worktree, let input, let runSetupScriptIfNew, let autoCloseOnSuccess, let customCommandName,
      let customCommandIcon):
      Task {
        await createTabAsync(
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
        await createTabAsync(in: worktree, runSetupScriptIfNew: false, workingDirectory: directory)
      }
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .runScript(let worktree, let script):
      _ = state(for: worktree).runScript(script)
    case .insertText(let worktree, let text):
      if !state(for: worktree).focusAndRunCommand(text) {
        Task {
          await createTabAsync(
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
    case .killFocusedTab(let worktree):
      Task { await killFocusedTab(in: worktree) }
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
    case .performBindingActionOnSurface(let worktree, let surfaceID, let action):
      state(for: worktree).performBindingAction(action, onSurfaceID: surfaceID)
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
    case .setAnonymousTmuxBackedTerminalsEnabled(let enabled):
      setAnonymousTmuxBackedTerminalsEnabled(enabled)
    case .refreshAnonymousTmuxConfiguration(let worktree):
      refreshAnonymousTmuxConfiguration(for: worktree)
    case .setCanvasMode(let enabled):
      if enabled {
        terminalLogger.info("[CanvasExit] enteringCanvas previousSelectedWorktree=\(selectedWorktreeID ?? "nil")")
        selectedWorktreeID = nil
        reevaluateCanvasInputSource(reason: .focusChanged)
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
      reevaluateSelectedWorktreeInputSource(reason: .focusChanged)
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
    let (stream, continuation) = AsyncStream.makeStream(
      of: TerminalClient.Event.self,
      bufferingPolicy: .bufferingNewest(Self.eventBufferCap)
    )
    eventContinuation = continuation
    lastNotificationIndicatorCount = nil
    // A new subscriber must be re-seeded with current state, so the dedup cache
    // can't suppress the next emit as a duplicate of one the old stream saw.
    eventCoalescer.reset()
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
      existing.setTmuxController(resolvedTmuxController(for: worktree))
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
      defaultFontSize: preferredFontSize,
      tmuxController: resolvedTmuxController(for: worktree)
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
    state.onFocusChanged = { [weak self, weak state] surfaceID in
      guard let self, let state else { return }
      self.lastFocusChange = FocusChange(
        token: UUID(),
        worktreeID: worktree.id,
        surfaceID: surfaceID
      )
      self.reevaluateInputSource(state: state, surfaceID: surfaceID, reason: .focusChanged)
      self.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
    }
    state.onFocusedCommandSurfaceCreated = { [weak self, weak state] surfaceID in
      guard let self, let state else { return }
      guard self.isInputSourceActiveTarget(state: state, surfaceID: surfaceID) else { return }
      self.inputSourceCoordinator.applyFocusedContext(
        .commandLike,
        targetID: .surface(surfaceID),
        reason: .focusChanged
      )
    }
    state.onInputContextMayHaveChanged = { [weak self, weak state] surfaceID in
      guard let self, let state else { return }
      guard self.isInputSourceActiveTarget(state: state, surfaceID: surfaceID) else { return }
      self.reevaluateInputSource(state: state, surfaceID: surfaceID, reason: .processContextChanged)
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

  private func resolvedTmuxController(for worktree: Worktree) -> TmuxTerminalController? {
    guard usesAnonymousTmuxEnabled(for: worktree) else { return nil }
    return tmuxController
  }

  private func usesAnonymousTmuxEnabled(for worktree: Worktree) -> Bool {
    if let usesAnonymousTmuxForWorktree {
      return usesAnonymousTmuxForWorktree(worktree)
    }
    return usesAnonymousTmux
  }

  private func refreshAnonymousTmuxConfiguration(for worktree: Worktree) {
    guard let existing = states[worktree.id] else { return }
    existing.setTmuxController(resolvedTmuxController(for: worktree))
  }

  private func setAnonymousTmuxBackedTerminalsEnabled(_ enabled: Bool) {
    usesAnonymousTmux = enabled
    for state in states.values {
      state.setTmuxController(enabled ? tmuxController : nil)
    }
  }

  func focusedDirectoryPath(for worktreeID: Worktree.ID) -> String? {
    stateIfExists(for: worktreeID)?.focusedDirectoryPathForRevealInFinder()
  }

  func visibleTmuxWindowIDs() -> Set<TmuxWindowID> {
    if let selectedWorktreeID, let state = states[selectedWorktreeID] {
      return state.visibleTmuxWindowIDs()
    }
    return states.values.reduce(into: Set<TmuxWindowID>()) { result, state in
      result.formUnion(state.visibleTmuxWindowIDs())
    }
  }

  func managedTmuxWindowIDs() -> Set<TmuxWindowID> {
    states.values.reduce(into: Set<TmuxWindowID>()) { result, state in
      result.formUnion(state.visibleTmuxWindowIDs())
    }
  }

  func detachedTmuxCardSnapshot() async -> TmuxCardRecoverySnapshot {
    guard let tmuxController, tmuxController.isAvailable else {
      return TmuxCardRecoverySnapshot(candidates: [], diagnostics: [])
    }
    do {
      return try await tmuxController.detachedCardSnapshot(visibleWindowIDs: managedTmuxWindowIDs())
    } catch {
      terminalLogger.warning("tmux recovery scan failed: \(error)")
      return TmuxCardRecoverySnapshot(candidates: [], diagnostics: [])
    }
  }

  func restoreDetachedTmuxCard(
    _ candidateID: TmuxDetachedCardCandidate.ID,
    worktrees: [Worktree]
  ) async -> Bool {
    let snapshot = await detachedTmuxCardSnapshot()
    guard let candidate = snapshot.candidates.first(where: { $0.id == candidateID }) else {
      terminalLogger.warning("tmux restore candidate vanished id=\(candidateID.rawValue)")
      return false
    }
    guard let worktree = resolveWorktree(for: candidate, worktrees: worktrees) else {
      terminalLogger.warning(
        "tmux restore missing worktree window=\(candidate.windowID.rawValue) worktreeID=\(candidate.worktreeID)"
      )
      return false
    }

    let state = state(for: worktree)
    guard await state.restoreDetachedTmuxCard(candidate) != nil else { return false }
    selectedWorktreeID = worktree.id
    return true
  }

  private func restoreDetachedTmuxCards(worktrees: [Worktree]) async -> Worktree.ID? {
    let snapshot = await detachedTmuxCardSnapshot()
    guard !snapshot.candidates.isEmpty else { return nil }

    var restoredWorktreeID: Worktree.ID?
    for candidate in snapshot.candidates {
      guard let worktree = resolveWorktree(for: candidate, worktrees: worktrees) else {
        terminalLogger.warning(
          "tmux restore missing worktree window=\(candidate.windowID.rawValue) worktreeID=\(candidate.worktreeID)"
        )
        continue
      }

      let state = state(for: worktree)
      guard await state.restoreDetachedTmuxCard(candidate) != nil else { continue }
      if restoredWorktreeID == nil {
        restoredWorktreeID = worktree.id
      }
    }

    selectedWorktreeID = restoredWorktreeID
    return restoredWorktreeID
  }

  private func resolveWorktree(
    for candidate: TmuxDetachedCardCandidate,
    worktrees: [Worktree]
  ) -> Worktree? {
    if let exact = worktrees.first(where: { normalizedPath($0.id) == normalizedPath(candidate.worktreeID) }) {
      return exact
    }
    if let pathMatch = worktrees.first(where: {
      normalizedPath($0.workingDirectory.path(percentEncoded: false)) == normalizedPath(candidate.worktreePath)
    }) {
      return pathMatch
    }
    return Worktree(
      id: candidate.worktreeID,
      name: URL(fileURLWithPath: candidate.worktreePath, isDirectory: true).lastPathComponent,
      detail: candidate.worktreePath,
      workingDirectory: URL(fileURLWithPath: candidate.worktreePath, isDirectory: true),
      repositoryRootURL: URL(fileURLWithPath: candidate.repositoryRoot, isDirectory: true)
    )
  }

  @discardableResult
  func createTabForTesting(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool
  ) async -> TerminalTabID? {
    await createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew)
  }

  @discardableResult
  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil,
    inheritFromFocusedSurface: Bool = true,
    workingDirectory: URL? = nil,
    autoCloseOnSuccess: Bool = false,
    customCommandName: String? = nil,
    customCommandIcon: String? = nil
  ) async -> TerminalTabID? {
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
    let tabId = await state.createTabAsync(
      setupScript: setupScript,
      initialInput: initialInput,
      inheritFromFocusedSurface: inheritFromFocusedSurface,
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
    return tabId
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
  func killFocusedTab(in worktree: Worktree) async -> Bool {
    let state = state(for: worktree)
    return await state.killFocusedTab()
  }

  @discardableResult
  func closeFocusedSurface(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedSurface()
  }

  func prune(keeping worktreeIDs: Set<Worktree.ID>) {
    var retainedWorktreeIDs = worktreeIDs
    if states[FreestyleTerminal.worktreeID]?.tabManager.tabs.isEmpty == false {
      retainedWorktreeIDs.insert(FreestyleTerminal.worktreeID)
    }
    var removed: [WorktreeTerminalState] = []
    var removedIDs: Set<Worktree.ID> = []
    for (id, state) in states where !retainedWorktreeIDs.contains(id) {
      removed.append(state)
      removedIDs.insert(id)
    }
    for state in removed {
      state.closeAllSurfaces()
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { retainedWorktreeIDs.contains($0.key) }
    eventCoalescer.forget(worktreeIDs: removedIDs)
    emitNotificationIndicatorCountIfNeeded()
  }

  var activeWorktreeStates: [WorktreeTerminalState] {
    states.values.filter { !$0.tabManager.tabs.isEmpty }
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  internal func reevaluateInputSourceForActiveSurface(
    reason: TerminalInputSourceCoordinator.Reason = .appBecameActive
  ) {
    if selectedWorktreeID != nil {
      reevaluateSelectedWorktreeInputSource(reason: reason)
      return
    }

    reevaluateCanvasInputSource(reason: reason)
  }

  private func reevaluateInputSource(
    state: WorktreeTerminalState,
    surfaceID: UUID,
    reason: TerminalInputSourceCoordinator.Reason
  ) {
    let request = InputSourceFocusRequest(token: UUID(), worktreeID: state.worktreeID, surfaceID: surfaceID)
    latestInputSourceFocusRequest = request
    guard let surface = state.surfaceView(for: surfaceID) else { return }
    Task { @MainActor [weak self, weak surface] in
      guard let self, let surface else { return }
      let childPID = surface.bridge.childPID()
      let processGroupID = surface.bridge.foregroundProcessGroupID()
      let job = await AgentProcessProbe.shared.foregroundJob(
        processGroupID: processGroupID,
        childPID: childPID
      )
      guard self.shouldApplyInputSourceContext(for: request) else { return }
      let viewportText = surface.bridge.readViewportText() ?? ""
      let context = TerminalInputContextClassifier.context(job: job, viewportText: viewportText)
      self.inputSourceCoordinator.applyFocusedContext(context, targetID: .surface(surfaceID), reason: reason)
    }
  }

  private func reevaluateSelectedWorktreeInputSource(reason: TerminalInputSourceCoordinator.Reason) {
    guard
      let selectedWorktreeID,
      let state = states[selectedWorktreeID],
      let surfaceID = state.activeSurfaceID
    else {
      latestInputSourceFocusRequest = nil
      return
    }
    reevaluateInputSource(state: state, surfaceID: surfaceID, reason: reason)
  }

  private func reevaluateCanvasInputSource(reason: TerminalInputSourceCoordinator.Reason) {
    guard
      selectedWorktreeID == nil,
      let canvasFocusedWorktreeID,
      let state = states[canvasFocusedWorktreeID],
      let surfaceID = state.activeSurfaceID
    else {
      latestInputSourceFocusRequest = nil
      return
    }
    reevaluateInputSource(state: state, surfaceID: surfaceID, reason: reason)
  }

  private func shouldApplyInputSourceContext(for request: InputSourceFocusRequest) -> Bool {
    guard latestInputSourceFocusRequest == request else { return false }
    guard let state = states[request.worktreeID] else { return false }
    return isInputSourceActiveTarget(state: state, surfaceID: request.surfaceID)
  }

  private func isInputSourceActiveTarget(state: WorktreeTerminalState, surfaceID: UUID) -> Bool {
    guard states[state.worktreeID] === state else { return false }
    guard state.activeSurfaceID == surfaceID else { return false }
    if let selectedWorktreeID {
      return selectedWorktreeID == state.worktreeID
    }
    return canvasFocusedWorktreeID == state.worktreeID
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
    if enabled {
      agentDetectionEnabled = true
      for state in states.values {
        state.setAgentDetectionEnabled(true)
      }
      return
    }

    guard agentDetectionEnabled else { return }
    agentDetectionEnabled = false
    for state in states.values {
      state.setAgentDetectionEnabled(false)
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
  func focusWorktreeInCanvas(worktreeID: Worktree.ID) -> Bool {
    guard selectedWorktreeID == nil,
      let state = states[worktreeID],
      let surfaceID = state.activeSurfaceID
    else {
      return false
    }
    canvasFocusedWorktreeID = worktreeID
    let previousFocusChange = lastFocusChange
    guard state.focusSurface(id: surfaceID) else {
      return false
    }
    if lastFocusChange == previousFocusChange {
      lastFocusChange = FocusChange(token: UUID(), worktreeID: worktreeID, surfaceID: surfaceID)
      reevaluateInputSource(state: state, surfaceID: surfaceID, reason: .focusChanged)
      emit(.focusChanged(worktreeID: worktreeID, surfaceID: surfaceID))
    }
    return true
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

  @discardableResult
  func performFontSizeBindingAction(_ action: String, from worktreeID: Worktree.ID) -> Bool {
    guard states[worktreeID]?.hasFocusedSurface == true else { return false }
    var didPerform = false
    for worktreeState in states.values {
      didPerform = worktreeState.performBindingActionOnAllSurfaces(action) || didPerform
    }
    syncPreferredFontSize(from: worktreeID)
    return didPerform
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
    guard eventCoalescer.shouldEmit(event) else { return }
    guard let eventContinuation else {
      if pendingEvents.count >= Self.pendingEventCap {
        pendingEvents.removeFirst()
        terminalLogger.debug("Dropped oldest pending terminal event (backlog cap reached)")
      }
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
      terminalLogger.info("[LayoutRestore] restore: no snapshot found on disk, trying tmux card recovery")
      let restoredWorktreeID = await restoreDetachedTmuxCards(worktrees: worktrees)
      terminalLogger.info(
        "[LayoutRestore] restore: no snapshot fallback selectedWorktreeID=\(restoredWorktreeID ?? "nil")"
      )
      emit(.layoutRestored(selectedWorktreeID: restoredWorktreeID))
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
    let recoveredTmuxTargetsByWorktree = await makeRecoveredTmuxTargetsByWorktree(
      for: payload,
      availableWorktrees: worktrees
    )
    let didRestore = applyLayoutSnapshotPayload(
      payload,
      availableWorktrees: worktrees,
      recoveredTmuxTargetsByWorktree: recoveredTmuxTargetsByWorktree
    )
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
    let snapshotSelectedWorktreeID = snapshotSelectedWorktreeID(from: activeStates)
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
      selectedWorktreeID: snapshotSelectedWorktreeID,
      worktrees: snapshotWorktrees
    )
  }

  private func snapshotSelectedWorktreeID(from activeStates: [WorktreeTerminalState]) -> Worktree.ID? {
    if let selectedWorktreeID,
      activeStates.contains(where: { $0.worktreeID == selectedWorktreeID })
    {
      return selectedWorktreeID
    }
    if let canvasFocusedWorktreeID,
      activeStates.contains(where: { $0.worktreeID == canvasFocusedWorktreeID })
    {
      return canvasFocusedWorktreeID
    }
    return activeStates.first?.worktreeID
  }

  private func applyLayoutSnapshotPayload(
    _ payload: TerminalLayoutSnapshotPayload,
    availableWorktrees: [Worktree],
    recoveredTmuxTargetsByWorktree: [Worktree.ID: [TerminalTabID: TmuxTerminalTarget]] = [:]
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
      guard
        state.applyLayoutSnapshot(
          snapshot,
          recoveredTmuxTargets: recoveredTmuxTargetsByWorktree[worktree.id] ?? [:]
        )
      else {
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

  private func makeRecoveredTmuxTargetsByWorktree(
    for payload: TerminalLayoutSnapshotPayload,
    availableWorktrees: [Worktree]
  ) async -> [Worktree.ID: [TerminalTabID: TmuxTerminalTarget]] {
    guard let tmuxController, tmuxController.isAvailable, let socketURL = tmuxController.defaultSocketURL else {
      return [:]
    }

    let worktreeByID = Dictionary(uniqueKeysWithValues: availableWorktrees.map { ($0.id, $0) })
    var consumedCandidateIDs: Set<TmuxDetachedCardCandidate.ID> = []
    var targetsByWorktree: [Worktree.ID: [TerminalTabID: TmuxTerminalTarget]] = [:]

    for snapshot in payload.worktrees {
      guard let worktree = worktreeByID[snapshot.worktreeID] else { continue }
      guard usesAnonymousTmuxEnabled(for: worktree) else { continue }
      await prepareSnapshotTmuxTargets(
        snapshot,
        worktree: worktree,
        socketURL: socketURL,
        targetsByWorktree: &targetsByWorktree
      )
    }

    let tmuxSnapshot = await detachedTmuxCardSnapshot()
    guard !tmuxSnapshot.candidates.isEmpty else { return targetsByWorktree }

    for snapshot in payload.worktrees {
      guard let worktree = worktreeByID[snapshot.worktreeID] else { continue }
      guard usesAnonymousTmuxEnabled(for: worktree) else { continue }
      let recoverableTabs = snapshot.tabs.filter {
        $0.tmuxTarget == nil && $0.splitRoot.kind == .leaf && UUID(uuidString: $0.tabID) != nil
      }
      let matchingCandidates = tmuxSnapshot.candidates.filter { tmuxCandidate($0, matches: worktree) }

      for snapshotTab in snapshot.tabs {
        guard snapshotTab.tmuxTarget == nil, snapshotTab.splitRoot.kind == .leaf else { continue }
        guard let tabUUID = UUID(uuidString: snapshotTab.tabID) else { continue }
        guard
          let candidate = recoveredCandidate(
            for: snapshotTab,
            matchingCandidates: matchingCandidates,
            recoverableTabCount: recoverableTabs.count,
            consumedCandidateIDs: consumedCandidateIDs
          )
        else { continue }

        guard let paneID = candidate.paneID else {
          terminalLogger.warning(
            "[LayoutRestore] tmux rehydrate: skipping \(candidate.windowID.rawValue) without pane id"
          )
          continue
        }

        consumedCandidateIDs.insert(candidate.id)
        let tabID = TerminalTabID(rawValue: tabUUID)
        let target = TmuxTerminalTarget.restored(
          socketURL: socketURL,
          tabID: tabID,
          cardID: candidate.cardID,
          windowID: candidate.windowID,
          paneID: paneID
        )

        do {
          let prepared = try await tmuxController.prepareExistingWindowForAttach(target: target)
          targetsByWorktree[worktree.id, default: [:]][tabID] = prepared
          terminalLogger.info(
            "[LayoutRestore] tmux rehydrate: worktree=\(worktree.id) tab=\(snapshotTab.tabID) "
              + "window=\(candidate.windowID.rawValue)"
          )
        } catch {
          terminalLogger.warning(
            "[LayoutRestore] tmux rehydrate: failed window=\(candidate.windowID.rawValue) error=\(error)"
          )
        }
      }
    }

    return targetsByWorktree
  }

  private func prepareSnapshotTmuxTargets(
    _ snapshot: TerminalLayoutSnapshotPayload.SnapshotWorktree,
    worktree: Worktree,
    socketURL: URL,
    targetsByWorktree: inout [Worktree.ID: [TerminalTabID: TmuxTerminalTarget]]
  ) async {
    guard let tmuxController else { return }

    for snapshotTab in snapshot.tabs {
      guard snapshotTab.tmuxTarget != nil, snapshotTab.splitRoot.kind == .leaf else { continue }
      guard let tabUUID = UUID(uuidString: snapshotTab.tabID) else { continue }
      let tabID = TerminalTabID(rawValue: tabUUID)
      guard targetsByWorktree[worktree.id]?[tabID] == nil else { continue }
      guard let target = makeSnapshotTmuxTarget(for: snapshotTab, tabID: tabID) else { continue }

      do {
        let prepared = try await tmuxController.prepareExistingWindowForAttach(target: target)
        targetsByWorktree[worktree.id, default: [:]][tabID] = prepared
        continue
      } catch {
        terminalLogger.warning(
          "[LayoutRestore] tmux snapshot target missing: worktree=\(worktree.id) tab=\(snapshotTab.tabID) "
            + "error=\(error)"
        )
      }

      do {
        let replacement = try await recreateSnapshotTmuxTarget(
          for: snapshotTab,
          tabID: tabID,
          worktree: worktree,
          socketURL: socketURL
        )
        targetsByWorktree[worktree.id, default: [:]][tabID] = replacement
        terminalLogger.info(
          "[LayoutRestore] tmux snapshot target recreated: worktree=\(worktree.id) tab=\(snapshotTab.tabID) "
            + "window=\(replacement.windowID?.rawValue ?? "nil")"
        )
      } catch {
        terminalLogger.warning(
          "[LayoutRestore] tmux snapshot target recreation failed: worktree=\(worktree.id) "
            + "tab=\(snapshotTab.tabID) error=\(error)"
        )
      }
    }
  }

  private func makeSnapshotTmuxTarget(
    for snapshotTab: TerminalLayoutSnapshotPayload.SnapshotTab,
    tabID: TerminalTabID
  ) -> TmuxTerminalTarget? {
    guard let snapshotTarget = snapshotTab.tmuxTarget else { return nil }
    guard
      let windowID = TmuxWindowID(rawValue: snapshotTarget.windowID),
      let paneID = TmuxPaneID(rawValue: snapshotTarget.paneID)
    else {
      return nil
    }

    return TmuxTerminalTarget.restored(
      socketURL: URL(fileURLWithPath: snapshotTarget.socketPath, isDirectory: false),
      tabID: tabID,
      cardID: TmuxCardID(rawValue: tabID.rawValue.uuidString),
      windowID: windowID,
      paneID: paneID
    )
  }

  private func recreateSnapshotTmuxTarget(
    for snapshotTab: TerminalLayoutSnapshotPayload.SnapshotTab,
    tabID: TerminalTabID,
    worktree: Worktree,
    socketURL: URL
  ) async throws -> TmuxTerminalTarget {
    guard let tmuxController else {
      throw TmuxTerminalControllerError.tmuxUnavailable
    }

    let workingDirectory = snapshotWorkingDirectory(for: snapshotTab, worktree: worktree)
    let socketRoot = socketURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)

    var target = TmuxTerminalTarget.make(
      appNamespace: TmuxTerminalTarget.appNamespace,
      worktreeID: worktree.id,
      tabID: tabID,
      cardID: TmuxCardID(rawValue: tabID.rawValue.uuidString),
      socketRoot: socketRoot
    )
    let metadata = TmuxWindowMetadata(
      cardID: target.cardID,
      worktreeID: worktree.id,
      worktreePath: workingDirectory.path(percentEncoded: false),
      repositoryRoot: worktree.repositoryRootURL.path(percentEncoded: false),
      createdAt: ISO8601DateFormatter().string(from: Date())
    )
    let title = snapshotTab.customTitle ?? snapshotTab.title ?? worktree.name

    try await tmuxController.ensureGroup(target: target, cwd: workingDirectory)
    target = try await tmuxController.createWindow(
      target: target,
      cwd: workingDirectory,
      title: title,
      metadata: metadata
    )
    return target
  }

  private func snapshotWorkingDirectory(
    for snapshotTab: TerminalLayoutSnapshotPayload.SnapshotTab,
    worktree: Worktree
  ) -> URL {
    WorktreeTerminalState.resolveSnapshotWorkingDirectory(
      from: snapshotTab.splitRoot.cwdPath,
      worktreeRoot: worktree.workingDirectory
    ) ?? worktree.workingDirectory
  }

  private func recoveredCandidate(
    for snapshotTab: TerminalLayoutSnapshotPayload.SnapshotTab,
    matchingCandidates: [TmuxDetachedCardCandidate],
    recoverableTabCount: Int,
    consumedCandidateIDs: Set<TmuxDetachedCardCandidate.ID>
  ) -> TmuxDetachedCardCandidate? {
    if let exact = matchingCandidates.first(where: {
      !consumedCandidateIDs.contains($0.id)
        && $0.cardID.rawValue.caseInsensitiveCompare(snapshotTab.tabID) == .orderedSame
    }) {
      return exact
    }

    let availableCandidates = matchingCandidates.filter { !consumedCandidateIDs.contains($0.id) }
    guard recoverableTabCount == 1, availableCandidates.count == 1 else {
      return nil
    }
    return availableCandidates[0]
  }

  private func tmuxCandidate(_ candidate: TmuxDetachedCardCandidate, matches worktree: Worktree) -> Bool {
    normalizedPath(candidate.worktreeID) == normalizedPath(worktree.id)
      || normalizedPath(candidate.worktreePath) == normalizedPath(worktree.workingDirectory.path(percentEncoded: false))
  }

  private func normalizedPath(_ path: String) -> String {
    var result = path
    while result.count > 1 && result.hasSuffix("/") {
      result.removeLast()
    }
    return result
  }

  #if DEBUG
    /// Inert instance for SwiftUI previews — no GhosttyRuntime, all reads return defaults.
    static let preview: WorktreeTerminalManager = {
      let manager = WorktreeTerminalManager(preview: ())
      return manager
    }()

    private init(preview: Void) {
      self.runtime = nil
      self.tmuxController = nil
      self.usesAnonymousTmux = false
      self.usesAnonymousTmuxForWorktree = nil
      self.layoutPersistence = .liveValue
      self.preferredFontSize = nil
      self.baselineFontSize = 13
      self.inputSourceCoordinator = TerminalInputSourceCoordinator()
    }
  #endif
}
