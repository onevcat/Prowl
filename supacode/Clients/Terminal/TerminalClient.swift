import ComposableArchitecture
import Foundation

struct TerminalClient {
  var send: @MainActor @Sendable (Command) -> Void
  /// Creates and selects a tab synchronously so Canvas can target its exact ID.
  var createTabInDirectory: @MainActor @Sendable (Worktree, URL) -> TerminalTabID?
  var events: @MainActor @Sendable () -> AsyncStream<Event>
  var canvasFocusedWorktreeID: @MainActor @Sendable () -> Worktree.ID?
  /// Active surface in the selected tab. Lets the reducer capture the target
  /// synchronously before an async dispatch races against AppKit focus reshuffle
  /// (e.g. when a palette dismisses and the leftmost pane reclaims first responder).
  var selectedSurfaceID: @MainActor @Sendable (Worktree.ID) -> UUID?
  /// Everything the selected pane knows about the outgoing agent, captured in
  /// one synchronous read: session context for the artifact, launch
  /// observation, and the pid-anchored native session.
  var handoffSourceContext: @MainActor @Sendable (Worktree.ID) -> HandoffSourceContext?
  /// Same capture as `handoffSourceContext`, but for an explicit pane instead of
  /// the selected one — the Active Agents context menu targets a specific row.
  var handoffSourceContextForSurface: @MainActor @Sendable (Worktree.ID, UUID) -> HandoffSourceContext?
  var handoffSessionContextForSurface: @MainActor @Sendable (Worktree.ID, UUID) -> HandoffStore.SessionContext?
  var latestUnreadNotification: @MainActor @Sendable () -> NotificationLocation?
  var focusSurface: @MainActor @Sendable (Worktree.ID, UUID) -> Bool
  /// Types a line into a specific pane and submits it. The UI handoff path
  /// injects its request to the live source agent this way.
  var sendTextToSurface: @MainActor @Sendable (Worktree.ID, UUID, String) -> Bool
  var markNotificationRead: @MainActor @Sendable (Worktree.ID, UUID) -> Void
  var markNotificationsReadForSurface: @MainActor @Sendable (Worktree.ID, UUID) -> Void

  enum Command: Equatable {
    case createTab(Worktree, runSetupScriptIfNew: Bool)
    case createTabWithInput(
      Worktree,
      input: String,
      workingDirectory: URL? = nil,
      runSetupScriptIfNew: Bool,
      autoCloseOnSuccess: Bool,
      customCommandName: String? = nil,
      customCommandIcon: String? = nil
    )
    case createSplitWithInput(
      Worktree,
      direction: UserCustomSplitDirection,
      input: String,
      autoCloseOnSuccess: Bool,
      customCommandName: String? = nil,
      customCommandIcon: String? = nil
    )
    case launchAgentProfile(Worktree, plan: AgentProfileLaunchPlan)
    case createTabInDirectory(Worktree, directory: URL)
    case focusOrCreateTabInDirectory(Worktree, directory: URL, title: String?)
    case ensureInitialTab(Worktree, runSetupScriptIfNew: Bool, focusing: Bool)
    case runScript(Worktree, script: String)
    case insertText(Worktree, text: String)
    case stopRunScript(Worktree)
    case closeFocusedTab(Worktree)
    case closeFocusedSurface(Worktree)
    case performBindingAction(Worktree, action: String)
    case performBindingActionOnSurface(Worktree, surfaceID: UUID, action: String)
    case startSearch(Worktree)
    case searchSelection(Worktree)
    case navigateSearchNext(Worktree)
    case navigateSearchPrevious(Worktree)
    case endSearch(Worktree)
    case focusSelectedTab(Worktree)
    case prune(Set<Worktree.ID>)
    case setNotificationsEnabled(Bool)
    case setCommandFinishedNotification(enabled: Bool, threshold: Int)
    case setGhosttyConfigPath(String?)
    case setCanvasMode(Bool)
    case setSelectedWorktreeID(Worktree.ID?)
    case saveLayoutSnapshot
    case restoreLayoutSnapshot(worktrees: [Worktree])
    case presentTabIconPicker(Worktree)
  }

  enum Event: Equatable {
    case customCommandSucceeded(worktreeID: Worktree.ID, name: String, durationMs: Int)
    case notificationReceived(
      worktreeID: Worktree.ID, surfaceID: UUID, title: String, body: String, isViewed: Bool)
    case notificationIndicatorChanged(count: Int)
    case tabCreated(worktreeID: Worktree.ID)
    case tabClosed(worktreeID: Worktree.ID, remainingTabs: Int)
    case focusChanged(worktreeID: Worktree.ID, surfaceID: UUID)
    case taskStatusChanged(worktreeID: Worktree.ID, status: WorktreeTaskStatus)
    case agentEntryChanged(ActiveAgentEntry)
    case agentEntryRemoved(ActiveAgentEntry.ID)
    /// A profile launch created its surface. The reducer records the per-repo
    /// launch memory on this event — not at dispatch — so a failed launch
    /// never shifts the Recommended resolution (docs-ai 053/005).
    case agentProfileLaunched(worktreeID: Worktree.ID, profileID: AgentProfile.ID)
    case agentProfileLaunchFailed(worktreeID: Worktree.ID, profileName: String)
    case runScriptStatusChanged(worktreeID: Worktree.ID, isRunning: Bool)
    case commandPaletteToggleRequested(worktreeID: Worktree.ID)
    case setupScriptConsumed(worktreeID: Worktree.ID)
    case fontSizeChanged(Float32?)
    case layoutRestored(selectedWorktreeID: Worktree.ID?)
    case layoutRestoreFailed(message: String)
  }
}

extension TerminalClient: DependencyKey {
  static let liveValue = TerminalClient(
    send: { _ in fatalError("TerminalClient.send not configured") },
    createTabInDirectory: { _, _ in fatalError("TerminalClient.createTabInDirectory not configured")
    },
    events: { fatalError("TerminalClient.events not configured") },
    canvasFocusedWorktreeID: { nil },
    selectedSurfaceID: { _ in nil },
    handoffSourceContext: { _ in nil },
    handoffSourceContextForSurface: { _, _ in nil },
    handoffSessionContextForSurface: { _, _ in nil },
    latestUnreadNotification: { nil },
    focusSurface: { _, _ in false },
    sendTextToSurface: { _, _, _ in false },
    markNotificationRead: { _, _ in },
    markNotificationsReadForSurface: { _, _ in }
  )

  static let testValue = TerminalClient(
    send: { _ in },
    createTabInDirectory: { _, _ in nil },
    events: { AsyncStream { $0.finish() } },
    canvasFocusedWorktreeID: { nil },
    selectedSurfaceID: { _ in nil },
    handoffSourceContext: { _ in nil },
    handoffSourceContextForSurface: { _, _ in nil },
    handoffSessionContextForSurface: { _, _ in nil },
    latestUnreadNotification: { nil },
    focusSurface: { _, _ in false },
    sendTextToSurface: { _, _, _ in false },
    markNotificationRead: { _, _ in },
    markNotificationsReadForSurface: { _, _ in }
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
