import ComposableArchitecture
import Foundation

struct TerminalClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>
  var canvasFocusedWorktreeID: @MainActor @Sendable () -> Worktree.ID?
  /// Active surface in the selected tab. Lets the reducer capture the target
  /// synchronously before an async dispatch races against AppKit focus reshuffle
  /// (e.g. when a palette dismisses and the leftmost pane reclaims first responder).
  var selectedSurfaceID: @MainActor @Sendable (Worktree.ID) -> UUID?
  var latestUnreadNotification: @MainActor @Sendable () -> NotificationLocation?
  var focusWorktreeInCanvas: @MainActor @Sendable (Worktree.ID) -> Bool
  var focusSurface: @MainActor @Sendable (Worktree.ID, UUID) -> Bool
  var markNotificationRead: @MainActor @Sendable (Worktree.ID, UUID) -> Void
  var markNotificationsReadForSurface: @MainActor @Sendable (Worktree.ID, UUID) -> Void
  var focusedDirectoryPath: @MainActor @Sendable (_ worktreeID: Worktree.ID) -> String?
  var detachedTmuxCards: @MainActor @Sendable () async -> TmuxCardRecoverySnapshot
  var restoreDetachedTmuxCard: @MainActor @Sendable (TmuxDetachedCardCandidate.ID, [Worktree]) async -> Bool

  enum Command: Equatable {
    case createTab(Worktree, runSetupScriptIfNew: Bool)
    case createTabFromCanvas(Worktree, runSetupScriptIfNew: Bool, inheritFromFocusedSurface: Bool)
    case createTabWithInput(
      Worktree,
      input: String,
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
    case createTabInDirectory(Worktree, directory: URL)
    case ensureInitialTab(Worktree, runSetupScriptIfNew: Bool, focusing: Bool)
    case runScript(Worktree, script: String)
    case insertText(Worktree, text: String)
    case stopRunScript(Worktree)
    case closeFocusedTab(Worktree)
    case killFocusedTab(Worktree)
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
    case setAgentDetectionEnabled(Bool)
    case setAnonymousTmuxBackedTerminalsEnabled(Bool)
    case refreshAnonymousTmuxConfiguration(Worktree)
    case setCanvasMode(Bool)
    case setSelectedWorktreeID(Worktree.ID?)
    case saveLayoutSnapshot
    case restoreLayoutSnapshot(worktrees: [Worktree])
    case presentTabIconPicker(Worktree)
  }

  enum Event: Equatable {
    case customCommandSucceeded(worktreeID: Worktree.ID, name: String, durationMs: Int)
    case notificationReceived(worktreeID: Worktree.ID, surfaceID: UUID, title: String, body: String)
    case notificationIndicatorChanged(count: Int)
    case tabCreated(worktreeID: Worktree.ID)
    case tabClosed(worktreeID: Worktree.ID, remainingTabs: Int)
    case focusChanged(worktreeID: Worktree.ID, surfaceID: UUID)
    case taskStatusChanged(worktreeID: Worktree.ID, status: WorktreeTaskStatus)
    case agentEntryChanged(ActiveAgentEntry)
    case agentEntryRemoved(ActiveAgentEntry.ID)
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
    events: { fatalError("TerminalClient.events not configured") },
    canvasFocusedWorktreeID: { nil },
    selectedSurfaceID: { _ in nil },
    latestUnreadNotification: { nil },
    focusWorktreeInCanvas: { _ in false },
    focusSurface: { _, _ in false },
    markNotificationRead: { _, _ in },
    markNotificationsReadForSurface: { _, _ in },
    focusedDirectoryPath: { _ in nil },
    detachedTmuxCards: { TmuxCardRecoverySnapshot(candidates: [], diagnostics: []) },
    restoreDetachedTmuxCard: { _, _ in false }
  )

  static let testValue = TerminalClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } },
    canvasFocusedWorktreeID: { nil },
    selectedSurfaceID: { _ in nil },
    latestUnreadNotification: { nil },
    focusWorktreeInCanvas: { _ in false },
    focusSurface: { _, _ in false },
    markNotificationRead: { _, _ in },
    markNotificationsReadForSurface: { _, _ in },
    focusedDirectoryPath: { _ in nil },
    detachedTmuxCards: { TmuxCardRecoverySnapshot(candidates: [], diagnostics: []) },
    restoreDetachedTmuxCard: { _, _ in false }
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
