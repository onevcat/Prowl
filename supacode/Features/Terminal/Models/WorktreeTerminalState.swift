import AppKit
import CoreGraphics
import Foundation
import GhosttyKit
import Observation
import Sharing

let terminalStateLogger = SupaLogger("TerminalState")
let activeAgentDetectionInterval: Duration = .milliseconds(300)
let idleAgentDetectionInterval: Duration = .seconds(2)

enum TerminalCloseConfirmationMode {
  case prompt(TerminalCloseConfirmationTarget)
  case skip
}

enum TerminalCloseConfirmationTarget {
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

struct AgentDetectionDiagnostic {
  let tabId: TerminalTabID
  let childPID: pid_t?
  let processGroupID: pid_t?
  let job: ForegroundJob?
  let identified: (agent: DetectedAgent, name: String)?
  let retainedAgent: DetectedAgent?
  let raw: AgentRawState?
  let stabilized: AgentRawState?
}

struct AgentDetectionProcessProbe {
  let childPID: pid_t?
  let processGroupID: pid_t?
  let job: ForegroundJob?
}

@MainActor
@Observable
final class WorktreeTerminalState {
  enum TmuxTabCreation {
    static let appNamespace = TmuxTerminalTarget.appNamespace
    static let socketRoot = SupacodePaths.cacheDirectory.appending(path: "tmux", directoryHint: .isDirectory)
  }

  struct SurfaceActivity: Equatable {
    let isVisible: Bool
    let isFocused: Bool
  }

  let tabManager: TerminalTabManager
  let runtime: GhosttyRuntime
  let worktree: Worktree
  var tmuxController: TmuxTerminalController?
  var tmuxBackedTabCreationEnabled: Bool
  @ObservationIgnored
  @SharedReader private var repositorySettings: RepositorySettings
  var trees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
  var tmuxTargetsByTabId: [TerminalTabID: TmuxTerminalTarget] = [:]
  var surfaces: [UUID: GhosttySurfaceView] = [:]
  var focusedSurfaceIdByTab: [TerminalTabID: UUID] = [:]
  var surfaceAgentStates: [UUID: PaneAgentState] = [:]
  var agentDetectionSchedules: [UUID: AgentDetectionSchedule] = [:]
  var agentDetectionTasks: [UUID: Task<Void, Never>] = [:]
  var agentDetectionPresenceBySurface: [UUID: AgentDetectionPresence] = [:]
  var lastWorkingAtBySurface: [UUID: Date] = [:]
  var lastAgentDetectionDiagnosticsBySurface: [UUID: String] = [:]
  var tabIsRunningById: [TerminalTabID: Bool] = [:]
  var surfaceRunningStartedAtById: [UUID: Date] = [:]
  var runScriptTabId: TerminalTabID?
  var pendingSetupScript: Bool
  var defaultFontSize: Float32?
  var isEnsuringInitialTab = false
  var lastReportedTaskStatus: WorktreeTaskStatus?
  var lastEmittedFocusSurfaceId: UUID?
  var lastWindowIsKey: Bool?
  var lastWindowIsVisible: Bool?
  /// When `true`, Canvas owns occlusion management for this state's surfaces.
  /// `syncFocusIfNeeded` skips `applySurfaceActivity` to avoid overriding
  /// Canvas-set occlusion with stale normal-mode window activity values.
  var isCanvasManaged = false
  /// Tab whose icon picker should be presented. `nil` hides the picker.
  var iconPickerTabId: TerminalTabID?
  var notifications: [WorktreeTerminalNotification] = []
  var notificationsEnabled = true
  var commandFinishedNotificationEnabled = true
  var commandFinishedNotificationThreshold = 10
  var agentDetectionEnabled = true
  var lastKeyInputTimeBySurface: [UUID: ContinuousClock.Instant] = [:]
  var commandFinishedWaiters: [UUID: AsyncStream<(exitCode: Int?, durationMs: Int)>.Continuation] = [:]
  /// Surfaces that should auto-close on the next `command_finished` event with exit code 0.
  /// Populated by `markSurfaceForAutoClose` and consumed (one-shot) in `handleCommandFinished`.
  var autoCloseSurfaceIds: Set<UUID> = []
  /// Surfaces running a tracked Custom Command. The stored name is surfaced as a success
  /// toast when the command exits with code 0. One-shot: removed on the first finish event.
  var pendingCustomCommands: [UUID: String] = [:]
  /// Per-surface set of titles known to be the shell's idle prompt
  /// (the title `precmd` restores between commands). Populated by
  /// observing the first title that arrives after each
  /// `command_finished` — reliably the precmd-set prompt. Subsequent
  /// occurrences are skipped so they can't clobber the icon set by a
  /// real command.
  var learnedIdleTitlesBySurface: [UUID: Set<String>] = [:]
  /// Surfaces whose next title-change should be added to
  /// `learnedIdleTitlesBySurface`. Armed by `command_finished`,
  /// consumed by the next title arrival.
  var awaitingIdleTitleLearningBySurface: Set<UUID> = []
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
  var onFocusedCommandSurfaceCreated: ((UUID) -> Void)?
  internal var onInputContextMayHaveChanged: ((UUID) -> Void)?
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
    defaultFontSize: Float32? = nil,
    tmuxController: TmuxTerminalController? = nil
  ) {
    self.runtime = runtime
    self.worktree = worktree
    self.tmuxController = tmuxController
    tmuxBackedTabCreationEnabled = tmuxController != nil
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

  func tmuxTargetForTesting(_ tabId: TerminalTabID) -> TmuxTerminalTarget? {
    tmuxTargetsByTabId[tabId]
  }

  func isTmuxBacked(_ tabId: TerminalTabID) -> Bool {
    tmuxTargetsByTabId[tabId] != nil
  }

  func visibleTmuxWindowIDs() -> Set<TmuxWindowID> {
    Set(tmuxTargetsByTabId.values.compactMap(\.windowID))
  }

  var canCreateTmuxBackedPlainTab: Bool {
    guard tmuxBackedTabCreationEnabled else { return false }
    guard let tmuxController else { return false }
    return tmuxController.isAvailable
  }

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

  static func preferredRevealInFinderPath(
    runtimePWD: String?,
    inheritedWorkingDirectory: String?,
    worktreeDirectory: String
  ) -> String {
    if let runtimePath = runtimePWD?.trimmingCharacters(in: .whitespacesAndNewlines),
      !runtimePath.isEmpty
    {
      return runtimePath
    }
    if let inheritedWorkingDirectory,
      !inheritedWorkingDirectory.isEmpty
    {
      return inheritedWorkingDirectory
    }
    return worktreeDirectory
  }

  func focusedDirectoryPathForRevealInFinder() -> String {
    let worktreeDirectory = worktree.workingDirectory.path(percentEncoded: false)
    guard let surface = revealInFinderSurface() else {
      return worktreeDirectory
    }
    let inheritedWorkingDirectory = inheritedSurfaceConfig(
      fromSurfaceId: surface.id,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    ).workingDirectory?.path(percentEncoded: false)
    return Self.preferredRevealInFinderPath(
      runtimePWD: surface.bridge.state.pwd,
      inheritedWorkingDirectory: inheritedWorkingDirectory,
      worktreeDirectory: worktreeDirectory
    )
  }

  private func revealInFinderSurface() -> GhosttySurfaceView? {
    if let activeSurfaceView {
      return activeSurfaceView
    }
    guard let selectedTabId = tabManager.selectedTabId else { return nil }
    if let focusedSurfaceId = focusedSurfaceIdByTab[selectedTabId],
      let focusedSurface = surfaces[focusedSurfaceId]
    {
      return focusedSurface
    }
    return trees[selectedTabId]?.root?.leftmostLeaf()
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
    wakeAgentDetection(forSurfaceID: surface.id)
    return true
  }

  @discardableResult
  func insertCommittedText(_ text: String, in surfaceID: UUID) -> Bool {
    guard let surface = surfaceView(for: surfaceID) else { return false }
    surface.insertCommittedTextForBroadcast(text)
    wakeAgentDetection(forSurfaceID: surface.id)
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
    let submitted = surface.submitLine()
    if submitted {
      wakeAgentDetection(forSurfaceID: surface.id)
    }
    return submitted
  }

  @discardableResult
  func sendKeyToken(_ token: String, in surfaceID: UUID) -> Bool {
    guard let surface = surfaceView(for: surfaceID) else { return false }
    let sent = surface.sendCLIKeyToken(token)
    if sent {
      wakeAgentDetection(forSurfaceID: surface.id)
    }
    return sent
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

  func setTmuxController(_ tmuxController: TmuxTerminalController?) {
    if let tmuxController {
      self.tmuxController = tmuxController
    }
    tmuxBackedTabCreationEnabled = tmuxController != nil
  }

  func setAgentDetectionEnabled(_ enabled: Bool) {
    if enabled {
      agentDetectionEnabled = true
      wakeAgentDetectionForAllSurfaces()
      return
    }

    guard agentDetectionEnabled else { return }
    agentDetectionEnabled = false
    cleanupAllAgentDetectionState()
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
      if tabManager.tabs.isEmpty {
        _ = await createTabAsync(focusing: focusing, setupScript: setupScript)
      }
      await MainActor.run {
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
    inheritFromFocusedSurface: Bool = true,
    workingDirectoryOverride: URL? = nil
  ) -> TerminalTabID? {
    let context: ghostty_surface_context_e =
      tabManager.tabs.isEmpty
      ? GHOSTTY_SURFACE_CONTEXT_WINDOW
      : GHOSTTY_SURFACE_CONTEXT_TAB
    let resolvedInheritanceSurfaceId = Self.resolveInheritanceSurfaceID(
      inheritingFromSurfaceId: inheritingFromSurfaceId,
      focusedSurfaceId: currentFocusedSurfaceId(),
      inheritFromFocusedSurface: inheritFromFocusedSurface
    )
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
        workingDirectoryOverride: workingDirectoryOverride,
        launchCommandOverride: nil
      )
    )
    if shouldConsumeSetupScript, tabId != nil {
      onSetupScriptConsumed?()
    }
    return tabId
  }

  @discardableResult
  func createTabAsync(
    focusing: Bool = true,
    setupScript: String? = nil,
    initialInput: String? = nil,
    inheritingFromSurfaceId: UUID? = nil,
    inheritFromFocusedSurface: Bool = true,
    workingDirectoryOverride: URL? = nil
  ) async -> TerminalTabID? {
    guard setupScript == nil, initialInput == nil, workingDirectoryOverride == nil else {
      return createTab(
        focusing: focusing,
        setupScript: setupScript,
        initialInput: initialInput,
        inheritingFromSurfaceId: inheritingFromSurfaceId,
        inheritFromFocusedSurface: inheritFromFocusedSurface,
        workingDirectoryOverride: workingDirectoryOverride
      )
    }
    guard tmuxBackedTabCreationEnabled, let tmuxController, tmuxController.isAvailable else {
      return createTab(
        focusing: focusing,
        setupScript: setupScript,
        initialInput: initialInput,
        inheritingFromSurfaceId: inheritingFromSurfaceId,
        inheritFromFocusedSurface: inheritFromFocusedSurface,
        workingDirectoryOverride: workingDirectoryOverride
      )
    }

    let context: ghostty_surface_context_e =
      tabManager.tabs.isEmpty
      ? GHOSTTY_SURFACE_CONTEXT_WINDOW
      : GHOSTTY_SURFACE_CONTEXT_TAB
    let resolvedInheritanceSurfaceId = Self.resolveInheritanceSurfaceID(
      inheritingFromSurfaceId: inheritingFromSurfaceId,
      focusedSurfaceId: currentFocusedSurfaceId(),
      inheritFromFocusedSurface: inheritFromFocusedSurface
    )
    let inherited = inheritedSurfaceConfig(fromSurfaceId: resolvedInheritanceSurfaceId, context: context)
    let tmuxWorkingDirectory = inherited.workingDirectory ?? worktree.workingDirectory
    let title = "\(worktree.name) \(nextTabIndex())"
    let tabId = TerminalTabID(rawValue: UUID())
    let cardID = TmuxCardID(rawValue: tabId.rawValue.uuidString)
    let metadata = TmuxWindowMetadata(
      cardID: cardID,
      worktreeID: worktree.id,
      worktreePath: tmuxWorkingDirectory.path(percentEncoded: false),
      repositoryRoot: worktree.repositoryRootURL.path(percentEncoded: false),
      createdAt: ISO8601DateFormatter().string(from: Date())
    )
    var target = TmuxTerminalTarget.make(
      appNamespace: TmuxTabCreation.appNamespace,
      worktreeID: worktree.id,
      tabID: tabId,
      cardID: cardID,
      socketRoot: TmuxTabCreation.socketRoot
    )

    do {
      try FileManager.default.createDirectory(
        at: TmuxTabCreation.socketRoot,
        withIntermediateDirectories: true
      )
      try await tmuxController.ensureGroup(target: target, cwd: tmuxWorkingDirectory)
      target = try await tmuxController.createWindow(
        target: target,
        cwd: tmuxWorkingDirectory,
        title: title,
        metadata: metadata
      )
    } catch {
      if error is CancellationError || Task.isCancelled {
        return nil
      }
      terminalStateLogger.warning("tmux tab creation failed for worktree=\(worktree.id) tab=\(tabId): \(error)")
      return createTab(
        focusing: focusing,
        setupScript: setupScript,
        initialInput: initialInput,
        inheritingFromSurfaceId: inheritingFromSurfaceId,
        inheritFromFocusedSurface: inheritFromFocusedSurface,
        workingDirectoryOverride: workingDirectoryOverride
      )
    }

    guard !Task.isCancelled else {
      try? await tmuxController.killWindow(target: target)
      return nil
    }

    let createdTabId = tabManager.createTab(
      id: tabId,
      title: title,
      icon: "terminal",
      isTitleLocked: false
    )
    guard createdTabId == tabId else {
      try? await tmuxController.killWindow(target: target)
      return nil
    }

    let tree = splitTree(
      for: tabId,
      inheritingFromSurfaceId: resolvedInheritanceSurfaceId,
      initialInput: nil,
      workingDirectoryOverride: tmuxWorkingDirectory,
      launchCommandOverride: tmuxController.attachCommand(for: target),
      context: context
    )
    tmuxTargetsByTabId[tabId] = target
    tabIsRunningById[tabId] = false
    if focusing, let surface = tree.root?.leftmostLeaf() {
      focusSurface(surface, in: tabId)
      onFocusedCommandSurfaceCreated?(surface.id)
    }
    onTabCreated?()
    return tabId
  }

  @discardableResult
  func restoreDetachedTmuxCard(_ candidate: TmuxDetachedCardCandidate) async -> TerminalTabID? {
    guard let tmuxController, tmuxController.isAvailable else { return nil }

    let tabID = TerminalTabID(rawValue: UUID())
    let target = TmuxTerminalTarget.restored(
      socketURL: TmuxTabCreation.socketRoot.appending(path: "\(TmuxTabCreation.appNamespace).sock"),
      tabID: tabID,
      cardID: candidate.cardID,
      windowID: candidate.windowID,
      paneID: candidate.paneID
    )
    do {
      let preparedTarget = try await tmuxController.prepareExistingWindowForAttach(target: target)
      let title = candidate.runtimeTitle ?? worktree.name
      let context: ghostty_surface_context_e =
        tabManager.tabs.isEmpty
        ? GHOSTTY_SURFACE_CONTEXT_WINDOW
        : GHOSTTY_SURFACE_CONTEXT_TAB
      let createdTabID = tabManager.createTab(
        id: tabID,
        title: title,
        icon: "terminal",
        isTitleLocked: false
      )
      guard createdTabID == tabID else {
        terminalStateLogger.warning("tmux restore tab id drifted expected=\(tabID) actual=\(createdTabID)")
        return nil
      }
      let workingDirectory = URL(fileURLWithPath: candidate.activePath ?? candidate.worktreePath, isDirectory: true)
      let tree = splitTree(
        for: tabID,
        initialInput: nil,
        workingDirectoryOverride: workingDirectory,
        launchCommandOverride: tmuxController.attachCommand(for: preparedTarget),
        context: context
      )
      tmuxTargetsByTabId[tabID] = preparedTarget
      tabIsRunningById[tabID] = false
      tabManager.selectTab(tabID)
      if let surface = tree.root?.leftmostLeaf() {
        wakeAgentDetection(for: surface, tabId: tabID)
        focusSurface(surface, in: tabID)
        onFocusedCommandSurfaceCreated?(surface.id)
      }
      onTabCreated?()
      return tabID
    } catch {
      terminalStateLogger.warning(
        "tmux restore failed window=\(candidate.windowID.rawValue) card=\(candidate.cardID.rawValue): \(error)"
      )
      return nil
    }
  }

  func tabExists(_ tabId: TerminalTabID) -> Bool {
    tabManager.tabs.contains { $0.id == tabId }
  }

  static func resolveInheritanceSurfaceID(
    inheritingFromSurfaceId: UUID?,
    focusedSurfaceId: UUID?,
    inheritFromFocusedSurface: Bool
  ) -> UUID? {
    if let inheritingFromSurfaceId {
      return inheritingFromSurfaceId
    }
    return inheritFromFocusedSurface ? focusedSurfaceId : nil
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
        workingDirectoryOverride: nil,
        launchCommandOverride: nil
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
    let launchCommandOverride: String?
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
      launchCommandOverride: creation.launchCommandOverride,
      context: creation.context
    )
    tabIsRunningById[tabId] = false
    if creation.focusing, let surface = tree.root?.leftmostLeaf() {
      focusSurface(surface, in: tabId)
      onFocusedCommandSurfaceCreated?(surface.id)
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

  func applySurfaceActivity() {
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
  func killFocusedTab() async -> Bool {
    guard let tabId = tabManager.selectedTabId else { return false }
    if let target = tmuxTargetsByTabId[tabId], let tmuxController {
      try? await tmuxController.killWindow(target: target)
      tmuxTargetsByTabId[tabId] = nil
    }
    closeTab(tabId)
    return true
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
  func performBindingActionOnAllSurfaces(_ action: String) -> Bool {
    guard !surfaces.isEmpty else { return false }
    for surface in surfaces.values {
      surface.performBindingAction(action)
    }
    return true
  }

  var hasFocusedSurface: Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId]
    else {
      return false
    }
    return surfaces[focusedId] != nil
  }

  @discardableResult
  func performBindingAction(_ action: String, onSurfaceID surfaceID: UUID) -> Bool {
    guard let surface = surfaces[surfaceID] else { return false }
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
  func closeTab(_ tabId: TerminalTabID, confirmation: TerminalCloseConfirmationMode) -> Bool {
    guard confirmCloseIfNeeded(tabIds: [tabId], mode: confirmation) else { return false }
    let wasRunScriptTab = tabId == runScriptTabId
    detachTmuxClientSession(for: tabId)
    tabIsRunningById.removeValue(forKey: tabId)
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

  func runScriptInput(_ script: String) -> String? {
    formatCommandInput(script)
  }

  // Appends a bare `exit`, which preserves the most recent command status in
  // bash, zsh, and fish while remaining portable across those shells.
  // Without this, the interactive shell stays alive after the script finishes
  // and GHOSTTY_ACTION_SHOW_CHILD_EXITED never fires for completion detection.
  private func blockingScriptInput(_ script: String) -> String? {
    makeBlockingScriptInput(script: script)
  }

  func setRunScriptTabId(_ tabId: TerminalTabID?) {
    let wasRunning = runScriptTabId != nil
    runScriptTabId = tabId
    let isRunning = tabId != nil
    if wasRunning != isRunning {
      onRunScriptStatusChanged?(isRunning)
    }
  }

  func userFacingTitle(from rawTitle: String, tabId: TerminalTabID) -> String? {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    guard let target = tmuxTargetsByTabId[tabId] else { return title }
    return Self.userFacingTmuxTitle(
      from: title,
      target: target,
      worktreeName: worktree.name
    )
  }

  static func userFacingTmuxTitle(
    from title: String,
    target: TmuxTerminalTarget,
    worktreeName: String
  ) -> String? {
    let sessionPrefix = "\(target.clientSession):"
    guard title.hasPrefix(sessionPrefix) else { return title }

    let remainder = title.dropFirst(sessionPrefix.count)
    guard let separatorIndex = remainder.firstIndex(where: \.isWhitespace) else {
      return nil
    }

    let coordinate = remainder[..<separatorIndex]
    guard isTmuxTitleCoordinate(coordinate) else { return title }

    let windowTitle = remainder[separatorIndex...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !windowTitle.isEmpty else { return nil }

    if let generatedTitle = strippedGeneratedTabIndex(from: windowTitle, worktreeName: worktreeName) {
      return generatedTitle
    }

    return windowTitle
  }

  static func isTmuxTitleCoordinate(_ value: Substring) -> Bool {
    let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    return parts.allSatisfy { part in
      !part.isEmpty && part.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
  }

  static func strippedGeneratedTabIndex(from title: String, worktreeName: String) -> String? {
    let prefix = "\(worktreeName) "
    guard title.hasPrefix(prefix) else { return nil }
    let suffix = title.dropFirst(prefix.count)
    guard Int(suffix) != nil else { return nil }
    return worktreeName
  }

}
