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
  let identified: IdentifiedAgentProcess?
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

  /// One memoized agent-screen scan: the `raw` state `detectState` produced for
  /// `text` under `agent`. Cached per surface so an unchanged screen is not
  /// re-parsed on the next poll.
  struct AgentScreenScan: Equatable {
    let agent: DetectedAgent
    let text: String
    let raw: AgentRawState
  }

  let tabManager: TerminalTabManager
  let runtime: GhosttyRuntime
  let worktree: Worktree
  private let targetHandleRegistry: TerminalTargetHandleRegistry
  @ObservationIgnored
  @SharedReader private var repositorySettings: RepositorySettings
  var trees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
  var surfaces: [UUID: GhosttySurfaceView] = [:]
  var focusedSurfaceIdByTab: [TerminalTabID: UUID] = [:]
  struct SurfaceLaunchProfile: Equatable {
    let profileID: UUID
    /// Display name recorded at launch. Deliberately frozen: later profile
    /// renames or deletions never relabel a live pane.
    let name: String
    /// The runtime this profile launched. The config root only applies to
    /// detections of the same runtime: after the launched agent exits, a
    /// manually started *different* agent in the same pane uses its default
    /// home, and handing it the profile home would break its session
    /// attribution.
    let runtime: AgentProfileRuntime
    /// Relocated runtime home for account-bound profiles; the session
    /// resolver uses it as the config root for this surface. Nil for pure
    /// presets (default home layout).
    let dedicatedHome: URL?
    /// The native session layout may be nested below the provisioned home
    /// (Gemini: `.gemini`, Cline: `data`). Keep provisioning and attribution
    /// roots distinct instead of teaching the resolver launch semantics.
    let sessionConfigRoot: URL?

    init(
      profileID: UUID,
      name: String,
      runtime: AgentProfileRuntime,
      dedicatedHome: URL?,
      sessionConfigRoot: URL? = nil
    ) {
      self.profileID = profileID
      self.name = name
      self.runtime = runtime
      self.dedicatedHome = dedicatedHome
      self.sessionConfigRoot = sessionConfigRoot ?? dedicatedHome
    }

    func configRoot(forDetected agent: DetectedAgent) -> URL? {
      runtime.agent == agent ? sessionConfigRoot : nil
    }
  }

  var surfaceAgentStates: [UUID: PaneAgentState] = [:]
  /// Launch identity recorded at surface creation for Prowl-launched agent
  /// profiles (docs-ai 053). Never rewritten: recommendation or designation
  /// edits must not relabel a live pane. Detected-but-not-launched agents
  /// have no entry here.
  var launchProfilesBySurface: [UUID: SurfaceLaunchProfile] = [:]
  var agentDetectionSchedules: [UUID: AgentDetectionSchedule] = [:]
  var agentDetectionTasks: [UUID: Task<Void, Never>] = [:]
  var agentDetectionPresenceBySurface: [UUID: AgentDetectionPresence] = [:]
  var lastWorkingAtBySurface: [UUID: Date] = [:]
  var lastAgentDetectionDiagnosticsBySurface: [UUID: String] = [:]
  /// Memoizes the last agent-screen scan per surface so `detectAgentState` can
  /// reuse it while the terminal text and detected agent are unchanged. A
  /// live-but-idle agent is polled every 300 ms; without this each poll re-ran
  /// `DetectedAgent.detectState` — line splitting, lowercasing, and heuristic
  /// scans over identical text. Observation-ignored: a pure cache that never
  /// drives the UI.
  @ObservationIgnored
  var lastAgentScreenScanBySurface: [UUID: AgentScreenScan] = [:]
  /// Last `ActiveAgentEntry` emitted per surface. `detectAgentState` re-emits
  /// whenever any `PaneAgentState` field changes, including internal
  /// bookkeeping (raw-state oscillation, session miss streaks, presence
  /// holds); comparing against the consumer-visible entry here keeps that
  /// churn out of the terminal event stream and the TCA action log.
  var lastEmittedAgentEntriesBySurface: [UUID: ActiveAgentEntry] = [:]
  /// When each surface last emitted, used to space out title-only emissions.
  /// Pure bookkeeping for `emitAgentEntry`; no view reads it.
  @ObservationIgnored var lastAgentEntryEmitAtBySurface: [UUID: Date] = [:]
  /// The most recent title-only entry held back by coalescing. A spinner that
  /// stops animating produces no further title change, so without a trailing
  /// flush the last frame would stay on screen until some unrelated state
  /// change happened to carry the current title along.
  @ObservationIgnored var pendingAgentEntryBySurface: [UUID: ActiveAgentEntry] = [:]
  var tabIsRunningById: [TerminalTabID: Bool] = [:]
  /// Per-tab aggregate of agent busy-state: `true` when at least one surface in
  /// the tab has a detected agent whose stabilized `displayState` is `.working`
  /// or `.blocked`. OR-ed into `taskStatus` alongside `tabIsRunningById` so the
  /// sidebar spinner and `prowl list` reflect agent activity, not just OSC 9;4
  /// command progress (which Claude Code does not emit while it works).
  var tabAgentBusyById: [TerminalTabID: Bool] = [:]
  /// Per-tab aggregate of the `.blocked` slice of `tabAgentBusyById`: `true`
  /// when a surface in the tab holds an agent awaiting an answer (permission
  /// prompt, AskUserQuestion). Kept separate rather than folded into
  /// `taskStatus` because the two states call for opposite affordances — a
  /// spinner tells you to wait, a blocked agent is waiting on you — and
  /// `WorktreeTaskStatus` has no case to carry the difference.
  var tabAgentBlockedById: [TerminalTabID: Bool] = [:]
  var boundDirectoryTabIDs: [String: TerminalTabID] = [:]
  var surfaceRunningStartedAtById: [UUID: Date] = [:]
  var lastDefocusedAt: Date?
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
  /// `isViewed` is true when the notification's surface is the one the user is
  /// actively looking at (selected worktree, focused pane, key + visible window),
  /// so the reducer can suppress a redundant banner/sound for it.
  var onNotificationReceived: ((_ surfaceId: UUID, _ title: String, _ body: String, _ isViewed: Bool) -> Void)?
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
    defaultFontSize: Float32? = nil,
    targetHandleRegistry: TerminalTargetHandleRegistry? = nil,
    titleFlushClock: any Clock<Duration> = ContinuousClock()
  ) {
    self.runtime = runtime
    self.worktree = worktree
    self.targetHandleRegistry = targetHandleRegistry ?? TerminalTargetHandleRegistry()
    self.pendingSetupScript = runSetupScript
    self.defaultFontSize = defaultFontSize
    self.tabManager = TerminalTabManager(titleFlushClock: titleFlushClock)
    _repositorySettings = SharedReader(
      wrappedValue: RepositorySettings.default,
      .repositorySettings(worktree.repositoryRootURL)
    )
    self.tabManager.onCoalescedTitlesFlushed = { [weak self] tabIDs in
      for tabID in tabIDs {
        self?.refreshAgentEntriesForTitleChange(in: tabID)
      }
    }
  }

  var worktreeID: Worktree.ID { worktree.id }
  var worktreeName: String { worktree.name }
  var repositoryRootURL: URL { worktree.repositoryRootURL }

  func registerTargetHandle(for tabID: TerminalTabID) -> Int {
    targetHandleRegistry.register(tabID: tabID)
  }

  func registerTargetHandle(for paneID: UUID) -> Int {
    targetHandleRegistry.register(paneID: paneID)
  }

  func tabHandle(for tabID: TerminalTabID) -> Int? {
    targetHandleRegistry.handle(for: tabID)
  }

  func paneHandle(for paneID: UUID) -> Int? {
    targetHandleRegistry.handle(for: paneID)
  }

  func unregisterTargetHandle(for tabID: TerminalTabID) {
    targetHandleRegistry.unregister(tabID: tabID)
  }

  func unregisterTargetHandle(for paneID: UUID) {
    targetHandleRegistry.unregister(paneID: paneID)
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
    let hasRunningCommand = tabIsRunningById.values.contains(true)
    let hasBusyAgent = tabAgentBusyById.values.contains(true)
    return (hasRunningCommand || hasBusyAgent) ? .running : .idle
  }

  /// Whether any tab holds an agent awaiting an answer. Read alongside
  /// `taskStatus` by the sidebar so a blocked worktree shows an attention
  /// affordance instead of the running spinner. `taskStatus` itself is
  /// unchanged, so `prowl list` keeps reporting `running` for these.
  var hasBlockedAgent: Bool {
    tabAgentBlockedById.values.contains(true)
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
    selecting: Bool = true,
    title: String? = nil,
    setupScript: String? = nil,
    initialInput: String? = nil,
    inheritingFromSurfaceId: UUID? = nil,
    workingDirectoryOverride: URL? = nil
  ) -> TerminalTabID? {
    let context = GHOSTTY_SURFACE_CONTEXT_TAB
    let resolvedInheritanceSurfaceId = inheritingFromSurfaceId ?? currentFocusedSurfaceId()
    let title = title ?? "\(worktree.name) \(nextTabIndex())"
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
        selecting: selecting,
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

  /// Launches an agent profile per its compiled plan (docs-ai 053): provisions
  /// the dedicated home when bound, creates the placement surface with the
  /// environment patch, and records the profile identity on the new surface.
  /// Split placement degrades to a new tab when nothing is splittable.
  @discardableResult
  func launchAgentProfile(_ plan: AgentProfileLaunchPlan) -> UUID? {
    if let home = plan.dedicatedHome {
      do {
        try AgentProfileHomeProvisioner.provision(
          home: home,
          base: SupacodePaths.agentProfileHomesDirectory
        )
      } catch {
        terminalStateLogger.warning("Agent profile home provisioning failed: \(error)")
        return nil
      }
    }
    let identity = SurfaceLaunchProfile(
      profileID: plan.profileID,
      name: plan.profileName,
      runtime: plan.runtime,
      dedicatedHome: plan.dedicatedHome,
      sessionConfigRoot: plan.sessionConfigRoot
    )
    if plan.placement == .split,
      let surfaceID = createSplitOnFocusedSurface(
        direction: plan.splitDirection,
        initialInput: plan.terminalInput,
        additionalEnvironment: plan.surfaceEnvironment
      )
    {
      launchProfilesBySurface[surfaceID] = identity
      if let icon = Self.launchTabIcon(for: plan.runtime), let tabID = tabID(containing: surfaceID) {
        applyResolvedIcon(icon, surfaceId: surfaceID, tabId: tabID)
      }
      return surfaceID
    }
    let tabId = createTab(
      TabCreation(
        title: plan.profileName,
        icon: Self.launchTabIcon(for: plan.runtime)?.storageString ?? "terminal",
        isTitleLocked: false,
        initialInput: runScriptInput(plan.terminalInput),
        focusing: true,
        inheritingFromSurfaceId: currentFocusedSurfaceId(),
        context: GHOSTTY_SURFACE_CONTEXT_TAB,
        workingDirectoryOverride: nil,
        additionalEnvironment: plan.surfaceEnvironment
      )
    )
    guard let tabId, let surfaceID = trees[tabId]?.root?.leftmostLeaf().id else { return nil }
    launchProfilesBySurface[surfaceID] = identity
    return surfaceID
  }

  /// Icon for a profile launch. The launch path knows its runtime, so it
  /// resolves the brand icon directly instead of waiting for `CommandIconMap`
  /// to recognise the shell title: a profile that sets launch-scoped
  /// environment variables runs as `env VAR=… claude`, whose first token is
  /// `env`, and an unmatched token leaves the icon untouched. The lock stays
  /// `.auto`, so a later recognised command in the same tab can still take the
  /// slot, exactly as it does for a hand-typed agent. `nil` means the runtime
  /// has no mapping, in which case the tab keeps whatever icon it has.
  static func launchTabIcon(for runtime: AgentProfileRuntime) -> TabIconSource? {
    CommandIconMap.iconForFirstToken(runtime.agent.iconLookupToken)
  }

  @discardableResult
  func focusOrCreateTab(
    boundToDirectory directory: URL,
    title: String?
  ) -> TerminalTabID? {
    let directoryKey = boundDirectoryKey(for: directory)
    if let tabId = boundDirectoryTabIDs[directoryKey],
      tabManager.tabs.contains(where: { $0.id == tabId })
    {
      selectTab(tabId)
      return tabId
    }
    boundDirectoryTabIDs.removeValue(forKey: directoryKey)

    if let tabId = tabID(withWorkingDirectoryKey: directoryKey) {
      boundDirectoryTabIDs[directoryKey] = tabId
      selectTab(tabId)
      return tabId
    }

    let tabId = createTab(
      title: title,
      workingDirectoryOverride: directory
    )
    if let tabId {
      boundDirectoryTabIDs[directoryKey] = tabId
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
    var selecting: Bool = true
    let inheritingFromSurfaceId: UUID?
    let context: ghostty_surface_context_e
    let workingDirectoryOverride: URL?
    var additionalEnvironment: [String: String] = [:]
  }

  private func createTab(_ creation: TabCreation) -> TerminalTabID? {
    let tabId = tabManager.createTab(
      title: creation.title,
      icon: creation.icon,
      isTitleLocked: creation.isTitleLocked,
      select: creation.selecting
    )
    let tree = splitTree(
      for: tabId,
      inheritingFromSurfaceId: creation.inheritingFromSurfaceId,
      initialInput: creation.initialInput,
      workingDirectoryOverride: creation.workingDirectoryOverride,
      context: creation.context,
      additionalEnvironment: creation.additionalEnvironment
    )
    _ = registerTargetHandle(for: tabId)
    for surface in tree.leaves() {
      _ = registerTargetHandle(for: surface.id)
    }
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
    removeTree(for: tabId)
    unregisterTargetHandle(for: tabId)
    removeBoundDirectoryTab(tabId)
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

  func removeBoundDirectoryTab(_ tabId: TerminalTabID) {
    boundDirectoryTabIDs = boundDirectoryTabIDs.filter { $0.value != tabId }
  }

  private func tabID(withWorkingDirectoryKey directoryKey: String) -> TerminalTabID? {
    for tab in tabManager.tabs {
      let paneIDs = trees[tab.id]?.leaves().map(\.id) ?? []
      let hasMatchingPane = paneIDs.contains { paneID in
        guard
          let workingDirectory = inheritedSurfaceConfig(
            fromSurfaceId: paneID,
            context: GHOSTTY_SURFACE_CONTEXT_TAB
          ).workingDirectory
        else {
          return false
        }
        return boundDirectoryKey(for: workingDirectory) == directoryKey
      }
      if hasMatchingPane {
        return tab.id
      }
    }
    return nil
  }

  private func boundDirectoryKey(for url: URL) -> String {
    url.standardizedFileURL.path(percentEncoded: false)
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

}
