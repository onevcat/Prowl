import AppKit
import CoreGraphics
import Foundation
import GhosttyKit
import Observation
import Sharing

private let terminalStateLogger = SupaLogger("TerminalState")
private let activeAgentDetectionInterval: Duration = .milliseconds(300)
private let idleAgentDetectionInterval: Duration = .seconds(2)

private enum TerminalCloseConfirmationMode {
  case prompt(TerminalCloseConfirmationTarget)
  case skip
}

private enum TerminalCloseConfirmationTarget {
  case pane
  case tab
  case tabs(count: Int)

  var messageText: String {
    switch self {
    case .pane:
      return "Close Terminal Pane?"
    case .tab:
      return "Close Terminal Tab?"
    case .tabs(let count):
      return count == 1 ? "Close Terminal Tab?" : "Close Terminal Tabs?"
    }
  }

  var confirmButtonTitle: String {
    switch self {
    case .pane:
      return "Close Pane"
    case .tab:
      return "Close Tab"
    case .tabs(let count):
      return count == 1 ? "Close Tab" : "Close Tabs"
    }
  }
}

private struct AgentDetectionDiagnostic {
  let tabId: TerminalTabID
  let childPID: pid_t?
  let processGroupID: pid_t?
  let job: ForegroundJob?
  let identified: (agent: DetectedAgent, name: String)?
  let retainedAgent: DetectedAgent?
  let raw: AgentRawState?
  let stabilized: AgentRawState?
}

@MainActor
@Observable
final class WorktreeTerminalState {
  struct SurfaceActivity: Equatable {
    let isVisible: Bool
    let isFocused: Bool
  }

  let tabManager: TerminalTabManager
  private let runtime: GhosttyRuntime
  private let worktree: Worktree
  @ObservationIgnored
  @SharedReader private var repositorySettings: RepositorySettings
  private var trees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
  private var surfaces: [UUID: GhosttySurfaceView] = [:]
  private var focusedSurfaceIdByTab: [TerminalTabID: UUID] = [:]
  private(set) var surfaceAgentStates: [UUID: PaneAgentState] = [:]
  private var agentDetectionTasks: [UUID: Task<Void, Never>] = [:]
  private var agentDetectionPresenceBySurface: [UUID: AgentDetectionPresence] = [:]
  private var lastAgentWorkingAtBySurface: [UUID: Date] = [:]
  private var lastAgentDetectionDiagnosticsBySurface: [UUID: String] = [:]
  private var agentDetectionEnabled = true
  var tabIsRunningById: [TerminalTabID: Bool] = [:]
  private var surfaceRunningStartedAtById: [UUID: Date] = [:]
  private var runScriptTabId: TerminalTabID?
  private var pendingSetupScript: Bool
  private var defaultFontSize: Float32?
  private var isEnsuringInitialTab = false
  private var lastReportedTaskStatus: WorktreeTaskStatus?
  private var lastEmittedFocusSurfaceId: UUID?
  private var lastWindowIsKey: Bool?
  private var lastWindowIsVisible: Bool?
  /// When `true`, Canvas owns occlusion management for this state's surfaces.
  /// `syncFocusIfNeeded` skips `applySurfaceActivity` to avoid overriding
  /// Canvas-set occlusion with stale normal-mode window activity values.
  var isCanvasManaged = false
  /// Tab whose icon picker should be presented. `nil` hides the picker.
  var iconPickerTabId: TerminalTabID?
  var notifications: [WorktreeTerminalNotification] = []
  var notificationsEnabled = true
  private var commandFinishedNotificationEnabled = true
  private var commandFinishedNotificationThreshold = 10
  private var lastKeyInputTimeBySurface: [UUID: ContinuousClock.Instant] = [:]
  private var commandFinishedWaiters: [UUID: AsyncStream<(exitCode: Int?, durationMs: Int)>.Continuation] = [:]
  /// Surfaces that should auto-close on the next `command_finished` event with exit code 0.
  /// Populated by `markSurfaceForAutoClose` and consumed (one-shot) in `handleCommandFinished`.
  private var autoCloseSurfaceIds: Set<UUID> = []
  /// Surfaces running a tracked Custom Command. The stored name is surfaced as a success
  /// toast when the command exits with code 0. One-shot: removed on the first finish event.
  private var pendingCustomCommands: [UUID: String] = [:]
  /// Per-surface set of titles known to be the shell's idle prompt
  /// (the title `precmd` restores between commands). Populated by
  /// observing the first title that arrives after each
  /// `command_finished` — reliably the precmd-set prompt. Subsequent
  /// occurrences are skipped so they can't clobber the icon set by a
  /// real command.
  private var learnedIdleTitlesBySurface: [UUID: Set<String>] = [:]
  /// Surfaces whose next title-change should be added to
  /// `learnedIdleTitlesBySurface`. Armed by `command_finished`,
  /// consumed by the next title arrival.
  private var awaitingIdleTitleLearningBySurface: Set<UUID> = []
  var hasUnseenNotification: Bool {
    notifications.contains { !$0.isRead }
  }

  func hasUnseenNotification(forSurfaceID surfaceID: UUID) -> Bool {
    notifications.contains { !$0.isRead && $0.surfaceId == surfaceID }
  }

  func hasUnseenNotification(for tabId: TerminalTabID) -> Bool {
    let surfaceIds = trees[tabId]?.leaves().map(\.id) ?? []
    return notifications.contains { !$0.isRead && surfaceIds.contains($0.surfaceId) }
  }

  func unreadNotifications() -> [WorktreeTerminalNotification] {
    notifications.filter { !$0.isRead }.sorted { left, right in
      if left.createdAt != right.createdAt {
        return left.createdAt > right.createdAt
      }
      return left.id.uuidString > right.id.uuidString
    }
  }

  var canCloseFocusedTab: Bool {
    tabManager.selectedTabId != nil
  }

  var canCloseFocusedSurface: Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId]
    else {
      return false
    }
    return surfaces[focusedId] != nil
  }

  var isSelected: () -> Bool = { false }
  var onNotificationReceived: ((UUID, String, String) -> Void)?
  var onNotificationIndicatorChanged: (() -> Void)?
  var onTabCreated: (() -> Void)?
  var onTabClosed: (() -> Void)?
  var onFocusChanged: ((UUID) -> Void)?
  var onTaskStatusChanged: ((WorktreeTaskStatus) -> Void)?
  var onAgentEntryChanged: ((ActiveAgentEntry) -> Void)?
  var onAgentEntryRemoved: ((ActiveAgentEntry.ID) -> Void)?
  var onRunScriptStatusChanged: ((Bool) -> Void)?
  var onCommandPaletteToggle: (() -> Void)?
  var onSetupScriptConsumed: (() -> Void)?
  var onFontSizeAdjusted: (() -> Void)?
  /// Emitted when a tracked Custom Command finishes with exit code 0.
  /// Payload carries the user-facing command name and run duration in milliseconds.
  var onCustomCommandSucceeded: ((String, Int) -> Void)?

  init(
    runtime: GhosttyRuntime,
    worktree: Worktree,
    runSetupScript: Bool = false,
    defaultFontSize: Float32? = nil
  ) {
    self.runtime = runtime
    self.worktree = worktree
    self.pendingSetupScript = runSetupScript
    self.defaultFontSize = defaultFontSize
    self.tabManager = TerminalTabManager()
    _repositorySettings = SharedReader(
      wrappedValue: RepositorySettings.default,
      .repositorySettings(worktree.repositoryRootURL)
    )
  }

  var worktreeID: Worktree.ID { worktree.id }
  var worktreeName: String { worktree.name }
  var repositoryRootURL: URL { worktree.repositoryRootURL }

  var activeSurfaceView: GhosttySurfaceView? {
    guard let selectedTabId = tabManager.selectedTabId,
      let surfaceId = focusedSurfaceIdByTab[selectedTabId]
    else {
      return nil
    }
    return surfaces[surfaceId]
  }

  var activeSurfaceID: UUID? {
    currentFocusedSurfaceId()
  }

  func surfaceView(for tabId: TerminalTabID) -> GhosttySurfaceView? {
    guard let surfaceId = focusedSurfaceIdByTab[tabId] else { return nil }
    return surfaces[surfaceId]
  }

  func surfaceView(for surfaceID: UUID) -> GhosttySurfaceView? {
    surfaces[surfaceID]
  }

  @discardableResult
  func insertCommittedText(_ text: String, in tabId: TerminalTabID) -> Bool {
    guard let surface = surfaceView(for: tabId) else { return false }
    surface.insertCommittedTextForBroadcast(text)
    return true
  }

  @discardableResult
  func insertCommittedText(_ text: String, in surfaceID: UUID) -> Bool {
    guard let surface = surfaceView(for: surfaceID) else { return false }
    surface.insertCommittedTextForBroadcast(text)
    return true
  }

  @discardableResult
  func applyMirroredKey(_ key: MirroredTerminalKey, in tabId: TerminalTabID) -> Bool {
    guard let surface = surfaceView(for: tabId) else { return false }
    return surface.applyMirroredKeyForBroadcast(key)
  }

  @discardableResult
  func submitLine(in surfaceID: UUID) -> Bool {
    guard let surface = surfaceView(for: surfaceID) else { return false }
    return surface.submitLine()
  }

  @discardableResult
  func sendKeyToken(_ token: String, in surfaceID: UUID) -> Bool {
    guard let surface = surfaceView(for: surfaceID) else { return false }
    return surface.sendCLIKeyToken(token)
  }

  var taskStatus: WorktreeTaskStatus {
    tabIsRunningById.values.contains(true) ? .running : .idle
  }

  var isRunScriptRunning: Bool {
    runScriptTabId != nil
  }

  func setDefaultFontSize(_ fontSize: Float32?) {
    defaultFontSize = fontSize
  }

  func focusedFontSize() -> Float32? {
    guard let surfaceId = currentFocusedSurfaceId() else { return nil }
    return inheritedSurfaceConfig(fromSurfaceId: surfaceId, context: GHOSTTY_SURFACE_CONTEXT_TAB).fontSize
  }

  func ensureInitialTab(focusing: Bool) {
    guard tabManager.tabs.isEmpty else { return }
    guard !isEnsuringInitialTab else { return }
    isEnsuringInitialTab = true
    Task {
      let setupScript: String?
      if pendingSetupScript {
        setupScript = repositorySettings.setupScript
      } else {
        setupScript = nil
      }
      await MainActor.run {
        if tabManager.tabs.isEmpty {
          _ = createTab(focusing: focusing, setupScript: setupScript)
        }
        isEnsuringInitialTab = false
      }
    }
  }

  @discardableResult
  func createTab(
    focusing: Bool = true,
    setupScript: String? = nil,
    initialInput: String? = nil,
    inheritingFromSurfaceId: UUID? = nil,
    workingDirectoryOverride: URL? = nil
  ) -> TerminalTabID? {
    let context = GHOSTTY_SURFACE_CONTEXT_TAB
    let resolvedInheritanceSurfaceId = inheritingFromSurfaceId ?? currentFocusedSurfaceId()
    let title = "\(worktree.name) \(nextTabIndex())"
    let setupInput = setupScriptInput(setupScript: setupScript)
    let commandInput = initialInput.flatMap { runScriptInput($0) }
    let resolvedInput: String?
    switch (setupInput, commandInput) {
    case (nil, nil):
      resolvedInput = nil
    case (let setupInput?, nil):
      resolvedInput = setupInput
    case (nil, let commandInput?):
      resolvedInput = commandInput
    case (let setupInput?, let commandInput?):
      resolvedInput = setupInput + commandInput
    }
    let shouldConsumeSetupScript = pendingSetupScript && setupScript != nil
    if shouldConsumeSetupScript {
      pendingSetupScript = false
    }
    let tabId = createTab(
      TabCreation(
        title: title,
        icon: "terminal",
        isTitleLocked: false,
        initialInput: resolvedInput,
        focusing: focusing,
        inheritingFromSurfaceId: resolvedInheritanceSurfaceId,
        context: context,
        workingDirectoryOverride: workingDirectoryOverride
      )
    )
    if shouldConsumeSetupScript, tabId != nil {
      onSetupScriptConsumed?()
    }
    return tabId
  }

  @discardableResult
  func runScript(_ script: String) -> TerminalTabID? {
    guard let input = runScriptInput(script) else { return nil }
    if let existing = runScriptTabId {
      closeTab(existing, confirmation: .skip)
    }
    let tabId = createTab(
      TabCreation(
        title: "RUN SCRIPT",
        icon: "play.fill",
        isTitleLocked: true,
        initialInput: input,
        focusing: true,
        inheritingFromSurfaceId: currentFocusedSurfaceId(),
        context: GHOSTTY_SURFACE_CONTEXT_TAB,
        workingDirectoryOverride: nil
      )
    )
    if let tabId {
      // Lock in the play glyph as a script-level override so OSC-2
      // titles emitted by the script (e.g. `npm run dev`) can't swap
      // the icon out from under it.
      tabManager.setScriptIcon(tabId, icon: "play.fill")
    }
    setRunScriptTabId(tabId)
    return tabId
  }

  @discardableResult
  func stopRunScript() -> Bool {
    guard let runScriptTabId else { return false }
    return closeTab(runScriptTabId, confirmation: .skip)
  }

  private struct TabCreation: Equatable {
    let title: String
    let icon: String?
    let isTitleLocked: Bool
    let initialInput: String?
    let focusing: Bool
    let inheritingFromSurfaceId: UUID?
    let context: ghostty_surface_context_e
    let workingDirectoryOverride: URL?
  }

  private func createTab(_ creation: TabCreation) -> TerminalTabID? {
    let tabId = tabManager.createTab(
      title: creation.title,
      icon: creation.icon,
      isTitleLocked: creation.isTitleLocked
    )
    let tree = splitTree(
      for: tabId,
      inheritingFromSurfaceId: creation.inheritingFromSurfaceId,
      initialInput: creation.initialInput,
      workingDirectoryOverride: creation.workingDirectoryOverride,
      context: creation.context
    )
    tabIsRunningById[tabId] = false
    if creation.focusing, let surface = tree.root?.leftmostLeaf() {
      focusSurface(surface, in: tabId)
    }
    onTabCreated?()
    return tabId
  }

  func selectTab(_ tabId: TerminalTabID) {
    tabManager.selectTab(tabId)
    focusSurface(in: tabId)
    emitTaskStatusIfChanged()
  }

  func focusSelectedTab() {
    terminalStateLogger.interval("focusSelectedTab") {
      guard let tabId = tabManager.selectedTabId else { return }
      focusSurface(in: tabId)
    }
  }

  @discardableResult
  func focusAndInsertText(_ text: String) -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else { return false }
    surface.requestFocus()
    surface.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    return true
  }

  @discardableResult
  func focusAndRunCommand(_ text: String) -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let command = text.trimmingCharacters(in: .newlines)
    surface.requestFocus()
    surface.insertText(command, replacementRange: NSRange(location: 0, length: 0))
    return surface.submitLine()
  }

  func syncFocus(windowIsKey: Bool, windowIsVisible: Bool) {
    terminalStateLogger.interval("syncFocus") {
      lastWindowIsKey = windowIsKey
      lastWindowIsVisible = windowIsVisible
      applySurfaceActivity()
    }
  }

  private func applySurfaceActivity() {
    terminalStateLogger.interval("applySurfaceActivity") {
      applySurfaceActivityImpl()
    }
  }

  private func applySurfaceActivityImpl() {
    let selectedTabId = tabManager.selectedTabId
    var surfaceToFocus: GhosttySurfaceView?
    for (tabId, tree) in trees {
      let focusedId = focusedSurfaceIdByTab[tabId]
      let isSelectedTab = (tabId == selectedTabId)
      let visibleSurfaceIDs = Set(tree.visibleLeaves().map(\.id))
      for surface in tree.leaves() {
        let activity = Self.surfaceActivity(
          isSurfaceVisibleInTree: visibleSurfaceIDs.contains(surface.id),
          isSelectedTab: isSelectedTab,
          windowIsVisible: lastWindowIsVisible == true,
          windowIsKey: lastWindowIsKey == true,
          focusedSurfaceID: focusedId,
          surfaceID: surface.id
        )
        surface.setOcclusion(activity.isVisible)
        surface.focusDidChange(activity.isFocused)
        if activity.isFocused {
          surfaceToFocus = surface
        }
      }
    }
    if let surfaceToFocus, surfaceToFocus.window?.firstResponder is GhosttySurfaceView {
      surfaceToFocus.window?.makeFirstResponder(surfaceToFocus)
    }
  }

  static func surfaceActivity(
    isSurfaceVisibleInTree: Bool = true,
    isSelectedTab: Bool,
    windowIsVisible: Bool,
    windowIsKey: Bool,
    focusedSurfaceID: UUID?,
    surfaceID: UUID
  ) -> SurfaceActivity {
    let isVisible = isSurfaceVisibleInTree && isSelectedTab && windowIsVisible
    let isFocused = isVisible && windowIsKey && focusedSurfaceID == surfaceID
    return SurfaceActivity(isVisible: isVisible, isFocused: isFocused)
  }

  @discardableResult
  func focusSurface(id: UUID) -> Bool {
    guard let tabId = tabId(containing: id),
      let surface = surfaces[id]
    else {
      return false
    }
    tabManager.selectTab(tabId)
    focusSurface(surface, in: tabId)
    return true
  }

  @discardableResult
  func closeFocusedTab() -> Bool {
    guard let tabId = tabManager.selectedTabId else { return false }
    return closeTab(tabId)
  }

  @discardableResult
  func closeFocusedSurface() -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else {
      return false
    }
    surface.performBindingAction("close_surface")
    return true
  }

  @discardableResult
  func performBindingActionOnFocusedSurface(_ action: String) -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else {
      return false
    }
    surface.performBindingAction(action)
    return true
  }

  @discardableResult
  func navigateSearchOnFocusedSurface(_ direction: GhosttySearchDirection) -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else {
      return false
    }
    surface.navigateSearch(direction)
    return true
  }

  @discardableResult
  func closeTab(_ tabId: TerminalTabID) -> Bool {
    closeTab(tabId, confirmation: .prompt(.tab))
  }

  @discardableResult
  private func closeTab(_ tabId: TerminalTabID, confirmation: TerminalCloseConfirmationMode) -> Bool {
    guard confirmCloseIfNeeded(tabIds: [tabId], mode: confirmation) else { return false }
    let wasRunScriptTab = tabId == runScriptTabId
    removeTree(for: tabId)
    tabManager.closeTab(tabId)
    if let selected = tabManager.selectedTabId {
      focusSurface(in: selected)
    } else {
      lastEmittedFocusSurfaceId = nil
    }
    emitTaskStatusIfChanged()
    if wasRunScriptTab {
      setRunScriptTabId(nil)
    }
    onTabClosed?()
    return true
  }

  func closeOtherTabs(keeping tabId: TerminalTabID) {
    let ids = tabManager.tabs.map(\.id).filter { $0 != tabId }
    guard confirmCloseIfNeeded(tabIds: ids, mode: .prompt(.tabs(count: ids.count))) else { return }
    for id in ids {
      closeTab(id, confirmation: .skip)
    }
  }

  func closeTabsToRight(of tabId: TerminalTabID) {
    guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
    let ids = tabManager.tabs.dropFirst(index + 1).map(\.id)
    guard confirmCloseIfNeeded(tabIds: ids, mode: .prompt(.tabs(count: ids.count))) else { return }
    for id in ids {
      closeTab(id, confirmation: .skip)
    }
  }

  func closeAllTabs() {
    let ids = tabManager.tabs.map(\.id)
    guard confirmCloseIfNeeded(tabIds: ids, mode: .prompt(.tabs(count: ids.count))) else { return }
    for id in ids {
      closeTab(id, confirmation: .skip)
    }
  }

  private func confirmCloseIfNeeded(
    tabIds: [TerminalTabID],
    mode: TerminalCloseConfirmationMode
  ) -> Bool {
    let surfaceIDs = tabIds.flatMap { tabId in
      trees[tabId]?.leaves().map(\.id) ?? []
    }
    return confirmCloseIfNeeded(surfaceIDs: surfaceIDs, mode: mode)
  }

  private func confirmCloseIfNeeded(
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

  private func closeProtectionCandidates(surfaceIDs: [UUID]) -> [TerminalCloseProtectionCandidate] {
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

  private func presentCloseConfirmation(
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

  private func closeConfirmationMessage(for decision: TerminalCloseConfirmationDecision) -> String {
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
  private static let autoCloseDelay: Duration = .milliseconds(800)

  private func scheduleAutoClose(surfaceId: UUID) {
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
    }
  }

  func setAllSurfacesOccluded() {
    for surface in surfaces.values {
      surface.setOcclusion(false)
      surface.focusDidChange(false)
    }
  }

  func closeAllSurfaces() {
    for surface in surfaces.values {
      surface.closeSurface()
    }
    surfaces.removeAll()
    trees.removeAll()
    focusedSurfaceIdByTab.removeAll()
    cleanupAllAgentDetectionState()
    tabIsRunningById.removeAll()
    autoCloseSurfaceIds.removeAll()
    pendingCustomCommands.removeAll()
    setRunScriptTabId(nil)
    tabManager.closeAll()
  }

  func makeLayoutSnapshotWorktree() -> TerminalLayoutSnapshotPayload.SnapshotWorktree? {
    terminalStateLogger.info(
      "[LayoutRestore] makeSnapshot: worktree=\(worktree.id) tabs=\(tabManager.tabs.count)"
    )
    guard !tabManager.tabs.isEmpty else {
      terminalStateLogger.info("[LayoutRestore] makeSnapshot: no tabs, returning nil")
      return nil
    }

    var snapshotTabs: [TerminalLayoutSnapshotPayload.SnapshotTab] = []
    snapshotTabs.reserveCapacity(tabManager.tabs.count)
    for tab in tabManager.tabs {
      guard let tree = trees[tab.id], let root = tree.root else {
        terminalStateLogger.warning(
          "[LayoutRestore] makeSnapshot: no tree/root for tab \(tab.id.rawValue.uuidString)"
        )
        return nil
      }
      guard let splitRoot = makeLayoutSnapshotNode(from: root) else {
        terminalStateLogger.warning(
          "[LayoutRestore] makeSnapshot: failed to snapshot split tree for tab \(tab.id.rawValue.uuidString)"
        )
        return nil
      }
      // Skip title/icon for blocking-script tabs as they are transient.
      // Persist the icon only when the user has explicitly overridden it; otherwise
      // restore should pick up the current default ("terminal") or auto-detection.
      let isBlockingScriptTab = tab.id == runScriptTabId
      let snapshotIcon: String? = (isBlockingScriptTab || tab.iconLock != .user) ? nil : tab.icon
      snapshotTabs.append(
        TerminalLayoutSnapshotPayload.SnapshotTab(
          tabID: tab.id.rawValue.uuidString,
          title: isBlockingScriptTab ? nil : tab.title,
          customTitle: isBlockingScriptTab ? nil : tab.customTitle,
          icon: snapshotIcon,
          splitRoot: splitRoot
        )
      )
    }

    let result = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: worktree.id,
      selectedTabID: tabManager.selectedTabId?.rawValue.uuidString,
      tabs: snapshotTabs
    )
    terminalStateLogger.info(
      "[LayoutRestore] makeSnapshot: success, \(snapshotTabs.count) tab(s) captured"
    )
    return result
  }

  func applyLayoutSnapshot(_ snapshot: TerminalLayoutSnapshotPayload.SnapshotWorktree) -> Bool {
    terminalStateLogger.info(
      "[LayoutRestore] applySnapshot: worktree=\(worktree.id)"
        + " snapshotWorktreeID=\(snapshot.worktreeID) tabs=\(snapshot.tabs.count)"
    )
    guard snapshot.worktreeID == worktree.id else {
      terminalStateLogger.warning("[LayoutRestore] applySnapshot: worktreeID mismatch")
      return false
    }

    // Validate snapshot structure before creating any surfaces.
    var validatedTabs: [(tabID: TerminalTabID, snapshotTab: TerminalLayoutSnapshotPayload.SnapshotTab)] = []
    var seenTabIDs: Set<TerminalTabID> = []
    for snapshotTab in snapshot.tabs {
      guard let tabUUID = UUID(uuidString: snapshotTab.tabID) else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: invalid tab UUID \(snapshotTab.tabID)")
        return false
      }
      let tabID = TerminalTabID(rawValue: tabUUID)
      guard seenTabIDs.insert(tabID).inserted else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: duplicate tab ID \(snapshotTab.tabID)")
        return false
      }
      validatedTabs.append((tabID: tabID, snapshotTab: snapshotTab))
    }

    let selectedTabID: TerminalTabID?
    if let selectedTabRaw = snapshot.selectedTabID {
      guard let selectedUUID = UUID(uuidString: selectedTabRaw) else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: invalid selectedTab UUID \(selectedTabRaw)")
        return false
      }
      let candidate = TerminalTabID(rawValue: selectedUUID)
      guard seenTabIDs.contains(candidate) else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: selectedTab not in restored tabs")
        return false
      }
      selectedTabID = candidate
    } else {
      selectedTabID = validatedTabs.first?.tabID
    }

    // Close existing surfaces BEFORE creating new ones so new surfaces
    // don't get destroyed by closeAllSurfaces().
    terminalStateLogger.info("[LayoutRestore] applySnapshot: closing existing surfaces before restore")
    closeAllSurfaces()

    // Now create new surfaces into the clean state.
    var restoredTabs: [TerminalTabItem] = []
    var restoredTrees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
    var restoredFocusedSurfaceIDs: [TerminalTabID: UUID] = [:]

    for (index, entry) in validatedTabs.enumerated() {
      terminalStateLogger.info(
        "[LayoutRestore] applySnapshot: restoring tab[\(index)] id=\(entry.snapshotTab.tabID)"
      )
      guard
        let rootNode = restoreSplitNode(from: entry.snapshotTab.splitRoot, tabID: entry.tabID, isRoot: true)
      else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: restoreSplitNode failed for tab[\(index)]")
        closeAllSurfaces()
        return false
      }
      let tree = SplitTree<GhosttySurfaceView>.restored(root: rootNode)
      restoredTrees[entry.tabID] = tree
      restoredFocusedSurfaceIDs[entry.tabID] = rootNode.leftmostLeaf().id
      restoredTabs.append(
        TerminalTabItem(
          id: entry.tabID,
          title: entry.snapshotTab.title ?? "\(worktree.name) \(index + 1)",
          customTitle: entry.snapshotTab.customTitle,
          icon: entry.snapshotTab.icon ?? "terminal",
          isTitleLocked: false,
          iconLock: entry.snapshotTab.icon != nil ? .user : .auto
        )
      )
    }

    trees = restoredTrees
    focusedSurfaceIdByTab = restoredFocusedSurfaceIDs
    tabIsRunningById = Dictionary(uniqueKeysWithValues: restoredTabs.map { ($0.id, false) })
    tabManager.tabs = restoredTabs
    tabManager.selectedTabId = selectedTabID
    setRunScriptTabId(nil)

    // Explicitly unfocus all restored surfaces so only the focused one blinks.
    for surface in surfaces.values {
      surface.focusDidChange(false)
    }
    if let selectedTabID {
      focusSurface(in: selectedTabID)
    } else {
      lastEmittedFocusSurfaceId = nil
    }
    emitTaskStatusIfChanged()
    // Signal "this worktree now has tabs" so downstream Shelf
    // bookkeeping (`markWorktreeOpened` via `terminalEvent(.tabCreated)`)
    // adds the restored worktree to `openedWorktreeIDs`. Without this
    // emit, only the active worktree (which goes through
    // `.selectWorktree` on `.layoutRestored`) shows as a book on the
    // Shelf — every other restored worktree is missing, even though
    // the sidebar lists it and its terminal state is live.
    if !restoredTabs.isEmpty {
      onTabCreated?()
    }
    terminalStateLogger.info(
      "[LayoutRestore] applySnapshot: success, restored \(restoredTabs.count) tab(s)"
        + " selectedTab=\(selectedTabID?.rawValue.uuidString ?? "nil")"
    )
    return true
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    if !enabled {
      markAllNotificationsRead()
    }
  }

  func setCommandFinishedNotification(enabled: Bool, threshold: Int) {
    commandFinishedNotificationEnabled = enabled
    commandFinishedNotificationThreshold = threshold
  }

  func setAgentDetectionEnabled(_ enabled: Bool) {
    guard agentDetectionEnabled != enabled else { return }
    agentDetectionEnabled = enabled

    if enabled {
      for (surfaceID, view) in surfaces {
        guard let tabId = tabId(containing: surfaceID) else { continue }
        startAgentDetection(for: view, tabId: tabId)
      }
    } else {
      cleanupAllAgentDetectionState()
    }
  }

  func clearNotificationIndicator() {
    markAllNotificationsRead()
  }

  func markAllNotificationsRead() {
    let previousHasUnseen = hasUnseenNotification
    for index in notifications.indices {
      notifications[index].isRead = true
    }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func markNotificationsRead(forSurfaceID surfaceID: UUID) {
    let previousHasUnseen = hasUnseenNotification
    for index in notifications.indices where notifications[index].surfaceId == surfaceID {
      notifications[index].isRead = true
    }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func markNotificationRead(id notificationID: WorktreeTerminalNotification.ID) {
    let previousHasUnseen = hasUnseenNotification
    guard let index = notifications.firstIndex(where: { $0.id == notificationID }) else {
      return
    }
    notifications[index].isRead = true
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func dismissNotification(_ notificationID: WorktreeTerminalNotification.ID) {
    let previousHasUnseen = hasUnseenNotification
    notifications.removeAll { $0.id == notificationID }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func dismissAllNotifications() {
    let previousHasUnseen = hasUnseenNotification
    notifications.removeAll()
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func needsSetupScript() -> Bool {
    pendingSetupScript
  }

  func enableSetupScriptIfNeeded() {
    if pendingSetupScript {
      return
    }
    if tabManager.tabs.isEmpty {
      pendingSetupScript = true
    }
  }

  private func setupScriptInput(setupScript: String?) -> String? {
    guard pendingSetupScript, let script = setupScript else { return nil }
    return formatCommandInput(script)
  }

  // Env vars are injected into the surface's shell process via
  // `GhosttySurfaceView(environment:)`, so scripts no longer need a shell
  // export prefix.
  private func formatCommandInput(_ script: String) -> String? {
    makeCommandInput(script: script)
  }

  private func runScriptInput(_ script: String) -> String? {
    formatCommandInput(script)
  }

  // Appends a bare `exit`, which preserves the most recent command status in
  // bash, zsh, and fish while remaining portable across those shells.
  // Without this, the interactive shell stays alive after the script finishes
  // and GHOSTTY_ACTION_SHOW_CHILD_EXITED never fires for completion detection.
  private func blockingScriptInput(_ script: String) -> String? {
    makeBlockingScriptInput(script: script)
  }

  private func setRunScriptTabId(_ tabId: TerminalTabID?) {
    let wasRunning = runScriptTabId != nil
    runScriptTabId = tabId
    let isRunning = tabId != nil
    if wasRunning != isRunning {
      onRunScriptStatusChanged?(isRunning)
    }
  }

  private func createSurface(
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
      environment: worktree.scriptEnvironment
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
    startAgentDetection(for: view, tabId: tabId)
    return view
  }

  private func configureBridgeCallbacks(for view: GhosttySurfaceView, tabId: TerminalTabID) {
    view.bridge.onTitleChange = { [weak self, weak view] title in
      guard let self, let view else { return }
      if self.focusedSurfaceIdByTab[tabId] == view.id {
        self.tabManager.updateTitle(tabId, title: title)
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

  private func configureSurfaceCallbacks(for view: GhosttySurfaceView, tabId: TerminalTabID) {
    view.onFocusChange = { [weak self, weak view] focused in
      guard let self, let view, focused else { return }
      self.recordActiveSurface(view, in: tabId)
      self.emitTaskStatusIfChanged()
    }
    view.onKeyInput = { [weak self, weak view] in
      guard let self, let view else { return }
      self.recordKeyInput(forSurfaceID: view.id)
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

  static func resolveSnapshotWorkingDirectory(
    from snapshotPath: String?,
    worktreeRoot: URL,
    fileManager: FileManager = .default
  ) -> URL? {
    guard let snapshotPath,
      let normalizedPath = PathPolicy.normalizePath(snapshotPath, relativeTo: worktreeRoot)
    else {
      return nil
    }

    let normalizedURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
      return nil
    }
    guard PathPolicy.contains(normalizedURL, in: worktreeRoot) else {
      return nil
    }
    return normalizedURL
  }

  private struct InheritedSurfaceConfig: Equatable {
    let workingDirectory: URL?
    let fontSize: Float32?
  }

  private func inheritedSurfaceConfig(
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

  private func currentFocusedSurfaceId() -> UUID? {
    guard let selectedTabId = tabManager.selectedTabId else { return nil }
    return focusedSurfaceIdByTab[selectedTabId]
  }

  private func handlePromptTitle(
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

  private func promptTabTitle(for tabId: TerminalTabID, in window: NSWindow) {
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
        self.tabManager.setCustomTitle(tabId, title: newTitle)
      }
    }
  }

  private func updateTabTitle(for tabId: TerminalTabID) {
    guard let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId],
      let title = surface.bridge.state.title
    else { return }
    tabManager.updateTitle(tabId, title: title)
  }

  private func focusSurface(in tabId: TerminalTabID) {
    if let focusedId = focusedSurfaceIdByTab[tabId], let surface = surfaces[focusedId] {
      focusSurface(surface, in: tabId)
      return
    }
    let tree = splitTree(for: tabId)
    if let surface = tree.visibleLeaves().first {
      focusSurface(surface, in: tabId)
    }
  }

  private func focusSurface(_ surface: GhosttySurfaceView, in tabId: TerminalTabID) {
    let previousSurface = focusedSurfaceIdByTab[tabId].flatMap { surfaces[$0] }
    recordActiveSurface(surface, in: tabId)
    guard tabId == tabManager.selectedTabId else { return }
    let fromSurface = (previousSurface === surface) ? nil : previousSurface
    GhosttySurfaceView.moveFocus(to: surface, from: fromSurface)
  }

  private func recordActiveSurface(_ surface: GhosttySurfaceView, in tabId: TerminalTabID) {
    focusedSurfaceIdByTab[tabId] = surface.id
    markAgentSeen(surfaceID: surface.id)
    markNotificationsRead(forSurfaceID: surface.id)
    updateTabTitle(for: tabId)
    emitFocusChangedIfNeeded(surface.id)
  }

  private func appendNotification(title: String, body: String, surfaceId: UUID) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(trimmedTitle.isEmpty && trimmedBody.isEmpty) else { return }
    if notificationsEnabled {
      let previousHasUnseen = hasUnseenNotification
      let isRead = isSelected() && isFocusedSurface(surfaceId)
      notifications.insert(
        WorktreeTerminalNotification(
          surfaceId: surfaceId,
          title: trimmedTitle,
          body: trimmedBody,
          createdAt: Date(),
          isRead: isRead
        ),
        at: 0
      )
      emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
    }
    onNotificationReceived?(surfaceId, trimmedTitle, trimmedBody)
  }

  /// How recently the user must have typed for us to consider the exit user-initiated.
  static let recentInteractionWindow: Duration = .seconds(3)

  private func makeLayoutSnapshotNode(
    from node: SplitTree<GhosttySurfaceView>.Node
  ) -> TerminalLayoutSnapshotPayload.SnapshotSplitNode? {
    switch node {
    case .leaf(let view):
      let cwdPath = inheritedSurfaceConfig(
        fromSurfaceId: view.id,
        context: GHOSTTY_SURFACE_CONTEXT_TAB
      ).workingDirectory?.path(percentEncoded: false)
      return .leaf(surfaceID: view.id.uuidString, cwdPath: cwdPath)
    case .split(let split):
      guard let left = makeLayoutSnapshotNode(from: split.left) else {
        return nil
      }
      guard let right = makeLayoutSnapshotNode(from: split.right) else {
        return nil
      }
      return .split(
        direction: snapshotSplitDirection(from: split.direction),
        ratio: split.ratio,
        children: [left, right]
      )
    }
  }

  private func restoreSplitNode(
    from snapshotNode: TerminalLayoutSnapshotPayload.SnapshotSplitNode,
    tabID: TerminalTabID,
    isRoot: Bool
  ) -> SplitTree<GhosttySurfaceView>.Node? {
    switch snapshotNode.kind {
    case .leaf:
      guard let surfaceID = snapshotNode.surfaceID,
        !surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      let context: ghostty_surface_context_e = isRoot ? GHOSTTY_SURFACE_CONTEXT_TAB : GHOSTTY_SURFACE_CONTEXT_SPLIT
      let restoredWorkingDirectory = Self.resolveSnapshotWorkingDirectory(
        from: snapshotNode.cwdPath,
        worktreeRoot: worktree.workingDirectory
      )
      let view = createSurface(
        tabId: tabID,
        initialInput: nil,
        inheritingFromSurfaceId: nil,
        workingDirectoryOverride: restoredWorkingDirectory,
        context: context
      )
      return .leaf(view: view)
    case .split:
      guard let direction = snapshotNode.direction else {
        return nil
      }
      guard let ratio = snapshotNode.ratio, ratio > 0, ratio < 1 else {
        return nil
      }
      let clampedRatio = max(0.1, min(0.9, ratio))
      guard let children = snapshotNode.children, children.count == 2 else {
        return nil
      }
      guard let left = restoreSplitNode(from: children[0], tabID: tabID, isRoot: false) else {
        return nil
      }
      guard let right = restoreSplitNode(from: children[1], tabID: tabID, isRoot: false) else {
        return nil
      }
      return .split(
        .init(
          direction: splitDirection(from: direction),
          ratio: clampedRatio,
          left: left,
          right: right
        )
      )
    }
  }

  private func snapshotSplitDirection(
    from direction: SplitTree<GhosttySurfaceView>.Direction
  ) -> TerminalLayoutSnapshotSplitDirection {
    switch direction {
    case .horizontal:
      .horizontal
    case .vertical:
      .vertical
    }
  }

  private func splitDirection(
    from direction: TerminalLayoutSnapshotSplitDirection
  ) -> SplitTree<GhosttySurfaceView>.Direction {
    switch direction {
    case .horizontal:
      .horizontal
    case .vertical:
      .vertical
    }
  }

  func recordKeyInput(forSurfaceID surfaceId: UUID) {
    lastKeyInputTimeBySurface[surfaceId] = .now
  }

  func handleCommandFinished(exitCode: Int?, durationNs: UInt64, surfaceId: UUID) {
    // Notify CLI waiters unconditionally before applying notification filters.
    if let continuation = commandFinishedWaiters.removeValue(forKey: surfaceId) {
      let durationMs = Int(durationNs / 1_000_000)
      continuation.yield((exitCode: exitCode, durationMs: durationMs))
      continuation.finish()
    }

    surfaceRunningStartedAtById.removeValue(forKey: surfaceId)
    noteCommandFinishedForCommandDetection(surfaceId: surfaceId)

    // Custom command success toast. One-shot: removed regardless of outcome.
    if let commandName = pendingCustomCommands.removeValue(forKey: surfaceId), exitCode == 0 {
      let durationMs = Int(durationNs / 1_000_000)
      onCustomCommandSucceeded?(commandName, durationMs)
    }

    // Auto-close on success (exit 0). One-shot: the id is removed regardless of outcome.
    if autoCloseSurfaceIds.remove(surfaceId) != nil {
      if exitCode == 0, surfaces[surfaceId] != nil {
        scheduleAutoClose(surfaceId: surfaceId)
        return
      }
    }

    guard commandFinishedNotificationEnabled else { return }
    let durationSeconds = Int(durationNs / 1_000_000_000)
    guard durationSeconds >= commandFinishedNotificationThreshold else { return }
    // Skip user-initiated termination (Ctrl+C / kill signal)
    if let code = exitCode, code == 130 || code == 143 { return }
    // Skip if the user was recently typing in this surface (e.g. /exit, quit)
    if let lastInput = lastKeyInputTimeBySurface[surfaceId],
      ContinuousClock.now - lastInput < Self.recentInteractionWindow
    {
      return
    }

    let title = (exitCode == nil || exitCode == 0) ? "Command finished" : "Command failed"
    let formattedDuration = Self.formatDuration(durationSeconds)
    let body: String
    if let code = exitCode, code != 0 {
      body = "Failed (exit code \(code)) after \(formattedDuration)"
    } else {
      body = "Completed in \(formattedDuration)"
    }
    appendNotification(title: title, body: body, surfaceId: surfaceId)
  }

  // MARK: - Tab Icon Auto-Detection
  //
  // Strategy: each OSC 2 title change is matched against
  // `CommandIconMap` (substring rules first, then first-token). A hit
  // applies the icon immediately — no debounce. Rationale: the
  // mapping is a curated allow-list, so a hit is by definition a
  // command we're happy to brand the tab with; a miss leaves the
  // existing icon untouched (selection-2 semantics).
  //
  // Idle-prompt suppression keeps the lookup focused on real
  // commands: the first title after each `command_finished` is the
  // shell's `precmd`-set prompt, and gets memorised into a learned-
  // idle set so we never reach the mapping with a `user@host`-style
  // string. Shape heuristics (`isLikelyIdleTitleByShape`) cover the
  // bootstrap window before the learner has seen anything.
  //
  // The mapping-hit-equals-apply rule also unblocks short-lived
  // commands (`git status`, `cd foo`) and TUIs that immediately
  // overwrite their preexec title (`codex` → repo name) — both used
  // to slip past a debounce-based detector.

  func noteTitleForCommandDetection(_ rawTitle: String, surfaceId: UUID, tabId: TerminalTabID) {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    // Learn this surface's idle prompt: the first title after
    // `command_finished` is reliably the precmd-set one.
    if awaitingIdleTitleLearningBySurface.remove(surfaceId) != nil {
      learnedIdleTitlesBySurface[surfaceId, default: []].insert(title)
    }
    // Drop idle prompts so they can't reach the mapping lookup.
    if Self.isLikelyIdleTitleByShape(title) { return }
    if learnedIdleTitlesBySurface[surfaceId]?.contains(title) == true { return }
    guard let icon = CommandIconMap.iconForFirstToken(title) else { return }
    applyResolvedIcon(icon, surfaceId: surfaceId, tabId: tabId)
  }

  func noteCommandFinishedForCommandDetection(surfaceId: UUID) {
    // Arm the idle-prompt learner: the next title arrival is the
    // precmd-set prompt and should join the learned-idle set.
    awaitingIdleTitleLearningBySurface.insert(surfaceId)
  }

  /// Drop the per-surface detector state. Called when a surface is
  /// closed or its parent tab is torn down so we don't retain
  /// learned-idle sets keyed by ids that will never emit again.
  func cleanupCommandDetectorState(forSurfaceId surfaceId: UUID) {
    learnedIdleTitlesBySurface.removeValue(forKey: surfaceId)
    awaitingIdleTitleLearningBySurface.remove(surfaceId)
  }

  private func startAgentDetection(for view: GhosttySurfaceView, tabId: TerminalTabID) {
    guard agentDetectionEnabled else { return }
    agentDetectionTasks[view.id]?.cancel()
    surfaceAgentStates[view.id] = PaneAgentState(lastChangedAt: Date())
    agentDetectionTasks[view.id] = Task { @MainActor [weak self, weak view] in
      while !Task.isCancelled {
        guard let self, let view, self.surfaces[view.id] != nil else { return }
        await self.detectAgentState(for: view, tabId: tabId)
        let hasAgent = self.surfaceAgentStates[view.id]?.detectedAgent != nil
        try? await Task.sleep(for: hasAgent ? activeAgentDetectionInterval : idleAgentDetectionInterval)
      }
    }
  }

  private func detectAgentState(for view: GhosttySurfaceView, tabId: TerminalTabID) async {
    let surfaceID = view.id
    let childPID = view.bridge.childPID()
    let processGroupID = view.bridge.foregroundProcessGroupID()
    let job = await AgentProcessProbe.shared.foregroundJob(processGroupID: processGroupID, childPID: childPID)
    guard surfaces[surfaceID] != nil else { return }

    let identified = job.flatMap { identifyAgentInJob($0) }
    let probedAgent = identified?.agent

    var presence = agentDetectionPresenceBySurface[surfaceID] ?? AgentDetectionPresence()
    let agent = presence.update(detectedAgent: probedAgent)
    agentDetectionPresenceBySurface[surfaceID] = presence

    guard let agent else {
      // Only log the moment we lose a previously detected agent; pre-agent
      // shells churn process lists every command and would otherwise spam.
      if surfaceAgentStates[surfaceID]?.detectedAgent != nil {
        logAgentDetectionDiagnostic(
          surfaceID: surfaceID,
          diagnostic: AgentDetectionDiagnostic(
            tabId: tabId,
            childPID: childPID,
            processGroupID: processGroupID,
            job: job,
            identified: identified,
            retainedAgent: nil,
            raw: nil,
            stabilized: nil
          )
        )
      }
      removeAgentEntryIfNeeded(surfaceID: surfaceID)
      return
    }

    let now = Date()
    let previous = surfaceAgentStates[surfaceID] ?? PaneAgentState(lastChangedAt: now)
    let detectionText = view.bridge.readAgentDetectionText() ?? ""
    // `detectState` is a `nonisolated` pure function that first trims to the
    // recent terminal tail, so the prior `Task.detached` hop
    // bought nothing but allocator churn. In long sessions, each detection
    // tick (300 ms or 2 s per surface) was leaving a task stack + closure
    // capture behind that never reached ARC; over a 24 h session this added
    // up to hundreds of MB of unreferenced allocations.
    let raw = agent.detectState(in: detectionText)
    guard surfaces[surfaceID] != nil else { return }

    var lastAgentWorkingAt = lastAgentWorkingAtBySurface[surfaceID]
    let stabilized = stabilizeAgentState(
      agent: agent,
      previousAgent: previous.detectedAgent,
      previous: previous.state,
      raw: raw,
      now: now,
      lastWorkingAt: &lastAgentWorkingAt
    )
    lastAgentWorkingAtBySurface[surfaceID] = lastAgentWorkingAt

    let isForeground = isSelected() && isFocusedSurface(surfaceID)
    let becameIdleFromActive =
      (previous.state == .working || previous.state == .blocked)
      && stabilized == .idle
    let seen: Bool
    if isForeground || stabilized == .blocked {
      seen = true
    } else if becameIdleFromActive {
      seen = false
    } else {
      seen = previous.seen
    }
    let lastChangedAt = (previous.detectedAgent != agent || previous.state != stabilized) ? now : previous.lastChangedAt
    let next = PaneAgentState(
      detectedAgent: agent,
      fallbackState: raw,
      state: stabilized,
      seen: seen,
      lastChangedAt: lastChangedAt
    )
    // Limit logging to meaningful transitions — agent identity or
    // stabilized state changes. Raw oscillation and `seen` flips are
    // routine and would otherwise dominate the log stream.
    if previous.detectedAgent != agent || previous.state != stabilized {
      logAgentDetectionDiagnostic(
        surfaceID: surfaceID,
        diagnostic: AgentDetectionDiagnostic(
          tabId: tabId,
          childPID: childPID,
          processGroupID: processGroupID,
          job: job,
          identified: identified,
          retainedAgent: agent,
          raw: raw,
          stabilized: stabilized
        )
      )
    }
    guard next != previous else { return }
    surfaceAgentStates[surfaceID] = next
    emitAgentEntry(surfaceID: surfaceID, tabId: tabId, state: next)
  }

  private func markAgentSeen(surfaceID: UUID) {
    guard var state = surfaceAgentStates[surfaceID], !state.seen else { return }
    state.seen = true
    state.lastChangedAt = Date()
    surfaceAgentStates[surfaceID] = state
    guard let tabId = tabId(containing: surfaceID) else { return }
    emitAgentEntry(surfaceID: surfaceID, tabId: tabId, state: state)
  }

  private func removeAgentEntryIfNeeded(surfaceID: UUID) {
    guard surfaceAgentStates[surfaceID]?.detectedAgent != nil else { return }
    surfaceAgentStates[surfaceID] = PaneAgentState(lastChangedAt: Date())
    lastAgentWorkingAtBySurface.removeValue(forKey: surfaceID)
    onAgentEntryRemoved?(surfaceID)
  }

  private func emitAgentEntry(surfaceID: UUID, tabId: TerminalTabID, state: PaneAgentState) {
    guard let entry = activeAgentEntry(surfaceID: surfaceID, tabId: tabId, state: state) else {
      onAgentEntryRemoved?(surfaceID)
      return
    }
    onAgentEntryChanged?(entry)
  }

  private func activeAgentEntry(surfaceID: UUID, tabId: TerminalTabID, state: PaneAgentState) -> ActiveAgentEntry? {
    guard let agent = state.detectedAgent, state.state != .unknown else { return nil }
    let paneIDs = trees[tabId]?.leaves().map(\.id) ?? []
    let paneIndex = paneIDs.firstIndex(of: surfaceID).map { $0 + 1 } ?? 1
    let tabTitle = tabManager.tabs.first(where: { $0.id == tabId })?.displayTitle ?? "?"
    // Resolve the displayed repository/branch from where the agent actually runs, not the tab's
    // owning worktree: a user may `cd` into a different repo before launching the agent. Falls
    // back to the surface's launch directory when the shell hasn't reported a pwd.
    let workingDirectory = inheritedSurfaceConfig(
      fromSurfaceId: surfaceID,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    ).workingDirectory
    return ActiveAgentEntry(
      id: surfaceID,
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      workingDirectory: workingDirectory,
      tabID: tabId,
      tabTitle: tabTitle,
      surfaceID: surfaceID,
      paneIndex: paneIndex,
      agent: agent,
      rawState: state.fallbackState,
      displayState: state.displayState,
      lastChangedAt: state.lastChangedAt
    )
  }

  private func cleanupAgentDetectionState(forSurfaceId surfaceId: UUID) {
    agentDetectionTasks[surfaceId]?.cancel()
    agentDetectionTasks.removeValue(forKey: surfaceId)
    surfaceAgentStates.removeValue(forKey: surfaceId)
    agentDetectionPresenceBySurface.removeValue(forKey: surfaceId)
    lastAgentWorkingAtBySurface.removeValue(forKey: surfaceId)
    lastAgentDetectionDiagnosticsBySurface.removeValue(forKey: surfaceId)
    onAgentEntryRemoved?(surfaceId)
  }

  private func cleanupAllAgentDetectionState() {
    for task in agentDetectionTasks.values {
      task.cancel()
    }
    let removedIDs = Array(surfaceAgentStates.keys)
    agentDetectionTasks.removeAll()
    surfaceAgentStates.removeAll()
    agentDetectionPresenceBySurface.removeAll()
    lastAgentWorkingAtBySurface.removeAll()
    lastAgentDetectionDiagnosticsBySurface.removeAll()
    for id in removedIDs {
      onAgentEntryRemoved?(id)
    }
  }

  private func agentDetectionDiagnosticMessage(_ diagnostic: AgentDetectionDiagnostic) -> String {
    let processSummary =
      diagnostic.job?.processes
      .map { "\($0.pid):\($0.argv0 ?? $0.name)" }
      .joined(separator: ",") ?? "none"
    return [
      "tab=\(diagnostic.tabId.rawValue.uuidString.prefix(8))",
      "childPID=\(diagnostic.childPID.map(String.init) ?? "nil")",
      "ptyPGID=\(diagnostic.processGroupID.map(String.init) ?? "nil")",
      "fgPGID=\(diagnostic.job.map { String($0.processGroupID) } ?? "nil")",
      "processes=\(processSummary)",
      "identified=\(diagnostic.identified.map { "\($0.agent.rawValue)(\($0.name))" } ?? "nil")",
      "retained=\(diagnostic.retainedAgent?.rawValue ?? "nil")",
      "raw=\(diagnostic.raw?.rawValue ?? "nil")",
      "state=\(diagnostic.stabilized?.rawValue ?? "nil")",
    ].joined(separator: " ")
  }

  private func logAgentDetectionDiagnostic(surfaceID: UUID, diagnostic: AgentDetectionDiagnostic) {
    #if DEBUG
      let message = agentDetectionDiagnosticMessage(diagnostic)
      guard lastAgentDetectionDiagnosticsBySurface[surfaceID] != message else { return }
      lastAgentDetectionDiagnosticsBySurface[surfaceID] = message
      terminalStateLogger.debug(
        "agent detection worktree=\(worktree.name) surface=\(surfaceID.uuidString.prefix(8)) \(message)"
      )
    #endif
  }

  /// Heuristic shape-only detection for shell idle prompts. The
  /// bootstrap filter — before `awaitingIdleTitleLearning` has caught
  /// the precmd-set prompt at least once on this surface — for two
  /// common forms:
  ///   1. `user@host[:path]` — contains `@` plus `:` or `/`, no spaces.
  ///   2. Pure path — starts with `~`, `/`, or `…`, no spaces.
  /// Real commands typically contain a space (program + args) or a
  /// short single token (`ls`, `claude`, `vim`) that doesn't match
  /// either shape, so the false-negative risk is small.
  ///
  /// Exposed (`internal static`) for direct unit testing — does not
  /// touch instance state.
  static func isLikelyIdleTitleByShape(_ title: String) -> Bool {
    guard !title.contains(" ") else { return false }
    if title.contains("@"), title.contains(":") || title.contains("/") {
      return true
    }
    if title.hasPrefix("~") || title.hasPrefix("/") || title.hasPrefix("…") {
      return true
    }
    return false
  }

  /// Apply an already-resolved icon to the tab. Honours focus, the user
  /// icon lock, and the Run Script / Custom Command override; encodes
  /// the icon through `storageString` so `assetName`-bearing entries
  /// pick up the `@asset:` marker the renderers parse via
  /// `ResolvedTabIcon`.
  private func applyResolvedIcon(
    _ icon: TabIconSource,
    surfaceId: UUID,
    tabId: TerminalTabID
  ) {
    // Per-tab UI is single-headed: only the focused surface in a
    // multi-split tab gets to drive its tab's icon. Stops a
    // background split's command from silently overriding what the
    // user is currently looking at.
    guard focusedSurfaceIdByTab[tabId] == surfaceId else { return }
    guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
    guard tab.iconLock == .auto else { return }
    let serialised = icon.storageString
    guard tab.icon != serialised else { return }
    tabManager.updateIcon(tabId, icon: serialised)
  }

  static func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 {
      return "\(seconds)s"
    }
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    if minutes < 60 {
      return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
    }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
  }

  /// Drops all per-surface bookkeeping for a surface that has been torn down,
  /// including any notifications it produced. A notification is keyed by its
  /// originating surface and is only cleared when that surface is focused or
  /// typed into; once the surface is gone there is no way to mark it read, so
  /// without dropping them here the worktree's unseen indicator (bell + Dock
  /// badge) would stay lit until the user manually dismisses everything.
  private func forgetSurface(_ surfaceID: UUID) {
    surfaces.removeValue(forKey: surfaceID)
    surfaceRunningStartedAtById.removeValue(forKey: surfaceID)
    autoCloseSurfaceIds.remove(surfaceID)
    pendingCustomCommands.removeValue(forKey: surfaceID)
    cleanupCommandDetectorState(forSurfaceId: surfaceID)
    cleanupAgentDetectionState(forSurfaceId: surfaceID)
    let previousHasUnseen = hasUnseenNotification
    notifications = Self.prunedNotifications(from: notifications, removingSurfaceID: surfaceID)
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  /// Removes every notification that originated from `surfaceID`, regardless of
  /// read state. Pure so the teardown behavior can be unit-tested without a
  /// live Ghostty surface.
  static func prunedNotifications(
    from notifications: [WorktreeTerminalNotification],
    removingSurfaceID surfaceID: UUID
  ) -> [WorktreeTerminalNotification] {
    notifications.filter { $0.surfaceId != surfaceID }
  }

  private func removeTree(for tabId: TerminalTabID) {
    guard let tree = trees.removeValue(forKey: tabId) else { return }
    for surface in tree.leaves() {
      surface.closeSurface()
      forgetSurface(surface.id)
    }
    focusedSurfaceIdByTab.removeValue(forKey: tabId)
    tabIsRunningById.removeValue(forKey: tabId)
  }

  func tabID(containing surfaceId: UUID) -> TerminalTabID? {
    for (tabId, tree) in trees where tree.find(id: surfaceId) != nil {
      return tabId
    }
    return nil
  }

  private func tabId(containing surfaceId: UUID) -> TerminalTabID? {
    tabID(containing: surfaceId)
  }

  private func isFocusedSurface(_ surfaceId: UUID) -> Bool {
    guard let selectedTabId = tabManager.selectedTabId else {
      return false
    }
    return focusedSurfaceIdByTab[selectedTabId] == surfaceId
  }

  private func updateRunningState(for tabId: TerminalTabID) {
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

  private func emitTaskStatusIfChanged() {
    let newStatus = taskStatus
    if newStatus != lastReportedTaskStatus {
      lastReportedTaskStatus = newStatus
      onTaskStatusChanged?(newStatus)
    }
  }

  private func emitFocusChangedIfNeeded(_ surfaceId: UUID) {
    guard surfaceId != lastEmittedFocusSurfaceId else { return }
    lastEmittedFocusSurfaceId = surfaceId
    onFocusChanged?(surfaceId)
  }

  private func emitNotificationIndicatorIfNeeded(previousHasUnseen: Bool) {
    if previousHasUnseen != hasUnseenNotification {
      onNotificationIndicatorChanged?()
    }
  }

  private func syncFocusIfNeeded() {
    guard !isCanvasManaged else { return }
    guard lastWindowIsKey != nil, lastWindowIsVisible != nil else { return }
    applySurfaceActivity()
  }

  private func updateTree(_ tree: SplitTree<GhosttySurfaceView>, for tabId: TerminalTabID) {
    trees[tabId] = tree
    syncFocusIfNeeded()
  }

  private func isRunningProgressState(_ state: ghostty_action_progress_report_state_e?) -> Bool {
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

  private func mapSplitDirection(_ direction: GhosttySplitAction.NewDirection)
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

  private func mapUserSplitDirection(_ direction: UserCustomSplitDirection)
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

  private func mapFocusDirection(_ direction: GhosttySplitAction.FocusDirection)
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

  private func mapResizeDirection(_ direction: GhosttySplitAction.ResizeDirection)
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

  private func handleCloseRequest(for view: GhosttySurfaceView, processAlive: Bool) {
    guard surfaces[view.id] != nil else { return }
    if processAlive {
      guard confirmCloseIfNeeded(surfaceIDs: [view.id], mode: .prompt(.pane)) else { return }
    }
    guard let tabId = tabId(containing: view.id), let tree = trees[tabId] else {
      view.closeSurface()
      forgetSurface(view.id)
      return
    }
    guard let node = tree.find(id: view.id) else {
      view.closeSurface()
      forgetSurface(view.id)
      return
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
      tabManager.closeTab(tabId)
      if tabId == runScriptTabId {
        setRunScriptTabId(nil)
      }
      // Mirror `state.closeTab(_:)`'s `onTabClosed` emit: this path
      // fires when the shell process exits (ghostty-driven close)
      // and historically skipped the callback, which meant the
      // Shelf's "retire the book when its last tab closes" logic
      // never saw this very common path.
      onTabClosed?()
      return
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
  }

  private func handleGotoTabRequest(_ target: ghostty_action_goto_tab_e) -> Bool {
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

  private func mapDropZone(_ zone: TerminalSplitTreeView.DropZone)
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

  private func nextTabIndex() -> Int {
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

struct CLIWorktreeTerminalSnapshot: Sendable {
  let tabs: [CLITerminalTabSnapshot]
  let taskStatus: ListCommandTask.Status?
}

struct CLITerminalTabSnapshot: Sendable {
  let id: UUID
  let title: String
  let selected: Bool
  let focusedPaneID: UUID?
  let panes: [CLITerminalPaneSnapshot]
}

struct CLITerminalPaneSnapshot: Sendable {
  let id: UUID
  let title: String
  let cwd: String?
}

extension WorktreeTerminalState {
  func makeCLIListSnapshot() -> CLIWorktreeTerminalSnapshot {
    let selectedTabID = tabManager.selectedTabId

    let tabs: [CLITerminalTabSnapshot] = tabManager.tabs.map { tab in
      let paneIDs = trees[tab.id]?.leaves().map(\.id) ?? []
      let panes = paneIDs.map { paneID in
        let cwd = inheritedSurfaceConfig(
          fromSurfaceId: paneID,
          context: GHOSTTY_SURFACE_CONTEXT_TAB
        ).workingDirectory?.path(percentEncoded: false)

        let title = paneTitle(surfaceID: paneID, fallbackTabTitle: tab.displayTitle)
        return CLITerminalPaneSnapshot(id: paneID, title: title, cwd: cwd)
      }

      return CLITerminalTabSnapshot(
        id: tab.id.rawValue,
        title: tab.displayTitle,
        selected: tab.id == selectedTabID,
        focusedPaneID: focusedSurfaceIdByTab[tab.id],
        panes: panes
      )
    }

    return CLIWorktreeTerminalSnapshot(
      tabs: tabs,
      taskStatus: taskStatus == .running ? .running : .idle
    )
  }

  private func paneTitle(surfaceID: UUID, fallbackTabTitle: String) -> String {
    let rawTitle = surfaces[surfaceID]?.bridge.state.title?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )

    if let rawTitle, !rawTitle.isEmpty {
      return rawTitle
    }

    return fallbackTabTitle
  }
}

// MARK: - CLI Command Finished Waiting

extension WorktreeTerminalState {
  /// Returns an `AsyncStream` that yields exactly once when the command finishes
  /// on the given surface. The caller should race this against a timeout.
  func waitForCommandFinished(surfaceID: UUID) -> AsyncStream<(exitCode: Int?, durationMs: Int)> {
    // Cancel any existing waiter for this surface.
    commandFinishedWaiters[surfaceID]?.finish()
    commandFinishedWaiters.removeValue(forKey: surfaceID)

    return AsyncStream { continuation in
      commandFinishedWaiters[surfaceID] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          self?.commandFinishedWaiters.removeValue(forKey: surfaceID)
        }
      }
    }
  }
}

// MARK: - CLI Send Snapshot

struct CLISendTabSnapshot {
  let focusedPaneID: UUID?
  let panes: [TargetResolutionSnapshot.Pane]
}

extension WorktreeTerminalState {
  func makeCLISendSnapshot(for tabId: TerminalTabID) -> CLISendTabSnapshot? {
    let paneIDs = trees[tabId]?.leaves().map(\.id) ?? []
    guard !paneIDs.isEmpty else { return nil }

    let focusedPaneID = focusedSurfaceIdByTab[tabId]
    let panes: [TargetResolutionSnapshot.Pane] = paneIDs.compactMap { paneID in
      guard let surfaceView = surfaces[paneID] else { return nil }
      let cwd = inheritedSurfaceConfig(
        fromSurfaceId: paneID,
        context: GHOSTTY_SURFACE_CONTEXT_TAB
      ).workingDirectory?.path(percentEncoded: false)
      let title = paneTitle(surfaceID: paneID, fallbackTabTitle: "")
      return TargetResolutionSnapshot.Pane(
        id: paneID,
        title: title,
        cwd: cwd,
        isFocusedInTab: paneID == focusedPaneID,
        surfaceView: surfaceView
      )
    }

    return CLISendTabSnapshot(focusedPaneID: focusedPaneID, panes: panes)
  }
}

nonisolated func makeCommandInput(script: String) -> String? {
  let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  return trimmed + "\n"
}

nonisolated func makeBlockingScriptInput(script: String) -> String? {
  guard let input = makeCommandInput(script: script) else { return nil }
  return input + "exit\n"
}
