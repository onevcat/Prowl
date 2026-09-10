import Foundation
import Sharing

enum CommandPaletteItemID {
  static let ghosttyPrefix = "ghostty."
  static let globalCheckForUpdates = "global.check-for-updates"
  static let globalOpenSettings = "global.open-settings"
  static let globalOpenRepository = "global.open-repository"
  static let globalNewWorkspace = "global.new-workspace"
  static let globalNewWorktree = "global.new-worktree"
  static let globalRefreshWorktrees = "global.refresh-worktrees"
  static let globalJumpToLatestUnread = "global.jump-to-latest-unread"
  static let globalViewArchivedWorktrees = "global.view-archived-worktrees"
  static let globalInstallCLI = "global.install-cli"
  static let globalToggleLeftSidebar = "global.toggle-left-sidebar"
  static let globalToggleActiveAgentsPanel = "global.toggle-active-agents-panel"
  static let globalToggleCanvas = "global.toggle-canvas"
  static let globalExpandCanvasCard = "global.expand-canvas-card"
  static let globalArrangeCanvasCards = "global.arrange-canvas-cards"
  static let globalOrganizeCanvasCards = "global.organize-canvas-cards"
  static let globalTileCanvasCards = "global.tile-canvas-cards"
  static let globalSelectAllCanvasCards = "global.select-all-canvas-cards"
  static let globalToggleShelf = "global.toggle-shelf"
  static let globalShowDiff = "global.show-diff"
  static let globalOutgoingChanges = "global.outgoing-changes"
  static let globalRevealInFinder = "global.reveal-in-finder"
  static let globalCopyPath = "global.copy-path"
  static let globalRevealInSidebar = "global.reveal-in-sidebar"
  static let globalRunScript = "global.run-script"
  static let globalStopRunScript = "global.stop-run-script"
  static let globalTogglePinWorktree = "global.toggle-pin-worktree"
  static let globalRenameBranch = "global.rename-branch"
  static let globalDeleteWorktree = "global.delete-worktree"

  static func openRepositorySettings(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "repo.\(repositoryID).open-settings"
  }

  static func customCommand(_ command: EffectiveCustomCommand) -> CommandPaletteItem.ID {
    command.paletteID
  }

  static func launchAgentProfile(_ id: AgentProfile.ID) -> String {
    "agent-profile.launch.\(id.uuidString)"
  }

  static func runWorkflow(_ key: String) -> String {
    "workflow.run.\(key)"
  }

  static var globalIDs: [CommandPaletteItem.ID] {
    [
      globalCheckForUpdates,
      globalOpenSettings,
      globalOpenRepository,
      globalNewWorkspace,
      globalNewWorktree,
      globalRefreshWorktrees,
      globalJumpToLatestUnread,
      globalViewArchivedWorktrees,
      globalInstallCLI,
      globalToggleLeftSidebar,
      globalToggleActiveAgentsPanel,
      globalToggleCanvas,
      globalExpandCanvasCard,
      globalArrangeCanvasCards,
      globalOrganizeCanvasCards,
      globalSelectAllCanvasCards,
      globalToggleShelf,
      globalShowDiff,
      globalOutgoingChanges,
      globalRevealInFinder,
      globalCopyPath,
      globalRevealInSidebar,
      globalRunScript,
      globalStopRunScript,
      globalTogglePinWorktree,
      globalRenameBranch,
      globalDeleteWorktree,
    ]
  }

  static func worktreeSelect(_ worktreeID: Worktree.ID) -> CommandPaletteItem.ID {
    "worktree.\(worktreeID).select"
  }

  static func changeFocusedTabIcon(_ worktreeID: Worktree.ID) -> CommandPaletteItem.ID {
    "terminal.\(worktreeID).change-focused-tab-icon"
  }

  static func ghosttyCommand(_ command: GhosttyCommand) -> CommandPaletteItem.ID {
    "\(ghosttyPrefix)\(command.action)|\(command.title)"
  }

  static func pullRequestIDs(repositoryID: Repository.ID) -> [CommandPaletteItem.ID] {
    [
      pullRequestOpen(repositoryID),
      pullRequestReady(repositoryID),
      pullRequestCopyFailingJobURL(repositoryID),
      pullRequestCopyCiLogs(repositoryID),
      pullRequestRerunFailedJobs(repositoryID),
      pullRequestOpenFailingCheck(repositoryID),
      pullRequestMerge(repositoryID),
      pullRequestClose(repositoryID),
    ]
  }

  static func pullRequestOpen(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).open"
  }

  static func pullRequestReady(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).ready"
  }

  static func pullRequestCopyFailingJobURL(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).copy-failing-job-url"
  }

  static func pullRequestCopyCiLogs(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).copy-ci-logs"
  }

  static func pullRequestRerunFailedJobs(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).rerun-failed-jobs"
  }

  static func pullRequestOpenFailingCheck(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).open-failing-check"
  }

  static func pullRequestMerge(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).merge"
  }

  static func pullRequestClose(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).close"
  }
}

func commandPaletteRecencyScore(
  _ item: CommandPaletteItem,
  recencyByID: [CommandPaletteItem.ID: TimeInterval],
  now: Date
) -> Double {
  guard let lastActivated = recencyByID[item.id] else { return 0 }
  let ageSeconds = max(0, now.timeIntervalSince1970 - lastActivated)
  let ageDays = ageSeconds / 86_400
  let cappedAgeDays = min(ageDays, 30)
  return pow(0.5, cappedAgeDays / 7)
}

func delegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate {
  if let appAction = appDelegateAction(for: kind) {
    return appAction
  }
  if let agentAction = agentDelegateAction(for: kind) {
    return agentAction
  }
  switch kind {
  case .worktreeSelect(let id):
    return .selectWorktree(id)
  case .deleteWorktree(let worktreeID, let repositoryID):
    return .deleteWorktree(worktreeID, repositoryID)
  case .ghosttyCommand(let action):
    return .ghosttyCommand(action)
  case .changeFocusedTabIcon(let worktreeID):
    return .changeFocusedTabIcon(worktreeID)
  case .togglePinWorktree(let worktreeID, let isCurrentlyPinned):
    return .togglePinWorktree(worktreeID, isCurrentlyPinned: isCurrentlyPinned)
  case .openRepositorySettings(let repositoryID):
    return .openRepositorySettings(repositoryID)
  case .runCustomCommand(let id, _):
    return .runCustomCommand(id)
  case .openPullRequest,
    .openRepositoryOnCodeHost,
    .markPullRequestReady,
    .mergePullRequest,
    .closePullRequest,
    .copyFailingJobURL,
    .copyCiFailureLogs,
    .rerunFailedJobs,
    .openFailingCheckDetails:
    return pullRequestDelegateAction(for: kind)!
  #if DEBUG
    case .debugTestToast(let toast):
      return .debugTestToast(toast)
    case .debugSimulateUpdateFound:
      return .debugSimulateUpdateFound
    case .debugLightDockNotificationDot:
      return .debugLightDockNotificationDot
  #endif
  case .checkForUpdates,
    .openSettings,
    .newWorktree,
    .openRepository,
    .newWorkspace,
    .viewArchivedWorktrees,
    .refreshWorktrees,
    .jumpToLatestUnread,
    .installCLI,
    .toggleLeftSidebar,
    .toggleActiveAgentsPanel,
    .toggleCanvas,
    .expandCanvasCard,
    .arrangeCanvasCards,
    .organizeCanvasCards,
    .tileCanvasCards,
    .selectAllCanvasCards,
    .toggleShelf,
    .showDiff,
    .outgoingChanges,
    .revealInFinder,
    .copyPath,
    .revealInSidebar,
    .runScript,
    .stopRunScript,
    .renameBranch:
    fatalError("appDelegateAction should handle app-level command palette actions")
  case .launchAgentProfile, .runWorkflow:
    fatalError("agentDelegateAction should handle agent-scoped command palette actions")
  }
}

/// The agent-scoped kinds, split out to keep `delegateAction`'s switch within the
/// complexity budget.
func agentDelegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .launchAgentProfile(let profileID):
    return .launchAgentProfile(profileID)
  case .runWorkflow(let key):
    return .runWorkflow(key)
  default:
    return nil
  }
}

func appDelegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate? {
  if let delegate = navigationDelegateAction(for: kind) {
    return delegate
  }
  if let delegate = viewDelegateAction(for: kind) {
    return delegate
  }
  switch kind {
  case .checkForUpdates:
    return .checkForUpdates
  case .openSettings:
    return .openSettings
  case .newWorktree:
    return .newWorktree
  case .openRepository:
    return .openRepository
  case .newWorkspace:
    return .newWorkspace
  case .viewArchivedWorktrees:
    return .viewArchivedWorktrees
  case .refreshWorktrees:
    return .refreshWorktrees
  case .jumpToLatestUnread:
    return .jumpToLatestUnread
  case .installCLI:
    return .installCLI
  case .runScript:
    return .runScript
  case .stopRunScript:
    return .stopRunScript
  case .renameBranch:
    return .renameBranch
  default:
    return nil
  }
}

func navigationDelegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .revealInFinder:
    return .revealInFinder
  case .copyPath:
    return .copyPath
  case .revealInSidebar:
    return .revealInSidebar
  default:
    return nil
  }
}

func viewDelegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .toggleLeftSidebar:
    return .toggleLeftSidebar
  case .toggleActiveAgentsPanel:
    return .toggleActiveAgentsPanel
  case .toggleCanvas:
    return .toggleCanvas
  case .expandCanvasCard:
    return .expandCanvasCard
  case .arrangeCanvasCards:
    return .arrangeCanvasCards
  case .organizeCanvasCards:
    return .organizeCanvasCards
  case .tileCanvasCards:
    return .tileCanvasCards
  case .selectAllCanvasCards:
    return .selectAllCanvasCards
  case .toggleShelf:
    return .toggleShelf
  case .showDiff:
    return .showDiff
  case .outgoingChanges:
    return .showOutgoingChanges
  default:
    return nil
  }
}

func pullRequestDelegateAction(
  for kind: CommandPaletteItem.Kind
) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .openPullRequest(let worktreeID),
    .openRepositoryOnCodeHost(let worktreeID):
    return .openPullRequest(worktreeID)
  case .markPullRequestReady(let worktreeID):
    return .markPullRequestReady(worktreeID)
  case .mergePullRequest(let worktreeID):
    return .mergePullRequest(worktreeID)
  case .closePullRequest(let worktreeID):
    return .closePullRequest(worktreeID)
  case .copyFailingJobURL(let worktreeID):
    return .copyFailingJobURL(worktreeID)
  case .copyCiFailureLogs(let worktreeID):
    return .copyCiFailureLogs(worktreeID)
  case .rerunFailedJobs(let worktreeID):
    return .rerunFailedJobs(worktreeID)
  case .openFailingCheckDetails(let worktreeID):
    return .openFailingCheckDetails(worktreeID)
  case .worktreeSelect,
    .checkForUpdates,
    .openSettings,
    .newWorktree,
    .openRepository,
    .newWorkspace,
    .viewArchivedWorktrees,
    .refreshWorktrees,
    .jumpToLatestUnread,
    .installCLI,
    .ghosttyCommand,
    .changeFocusedTabIcon,
    .toggleLeftSidebar,
    .toggleActiveAgentsPanel,
    .toggleCanvas,
    .expandCanvasCard,
    .arrangeCanvasCards,
    .organizeCanvasCards,
    .tileCanvasCards,
    .selectAllCanvasCards,
    .toggleShelf,
    .showDiff,
    .outgoingChanges,
    .revealInFinder,
    .copyPath,
    .revealInSidebar,
    .runScript,
    .stopRunScript,
    .togglePinWorktree,
    .renameBranch,
    .deleteWorktree,
    .openRepositorySettings,
    .runCustomCommand,
    .launchAgentProfile,
    .runWorkflow:
    return nil
  #if DEBUG
    case .debugTestToast, .debugSimulateUpdateFound, .debugLightDockNotificationDot:
      return nil
  #endif
  }
}

/// Ghostty action keys that should be hidden from Prowl's command palette.
///
/// Includes:
/// - actions Prowl already exposes natively (`check_for_updates`)
/// - Ghostty actions intentionally unsupported by Prowl's architecture/platform
let filteredGhosttyActionKeys: Set<String> = [
  "check_for_updates",
  "new_window",
  "close_all_windows",
  "goto_window",
  "toggle_tab_overview",
  "toggle_window_decorations",
  "inspector",
  "show_gtk_inspector",
  "show_on_screen_keyboard",
]

func ghosttyCommandItems(_ commands: [GhosttyCommand]) -> [CommandPaletteItem] {
  commands.compactMap { command in
    guard !filteredGhosttyActionKeys.contains(command.actionKey) else { return nil }
    return .ghosttyCommand(command)
  }
}

extension CommandPaletteItem {
  /// Build a top-level command backed by an `AppShortcuts` hotkey. Defaults to
  /// `defaultSuggestion: true` (since these are the kinds of actions worth
  /// listing when the palette opens with no query) and uses no subtitle (the
  /// hotkey hint and title already do the work).
  static func appShortcut(
    id: String,
    title: String,
    category: Category,
    kind: Kind,
    keywords: [String] = [],
    priorityTier: Int = defaultPriorityTier
  ) -> CommandPaletteItem {
    CommandPaletteItem(
      id: id,
      title: title,
      subtitle: nil,
      kind: kind,
      category: category,
      defaultSuggestion: true,
      keywords: keywords,
      priorityTier: priorityTier
    )
  }

  /// Build an item wrapping a Ghostty command exposed via the runtime.
  /// Lives in `.terminal`, ranks below regular suggestions (priority +100),
  /// and is search-only (never surfaces on empty query).
  static func ghosttyCommand(_ command: GhosttyCommand) -> CommandPaletteItem {
    let subtitle = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return CommandPaletteItem(
      id: CommandPaletteItemID.ghosttyCommand(command),
      title: command.title,
      subtitle: subtitle.isEmpty ? nil : subtitle,
      kind: .ghosttyCommand(command.action),
      category: .terminal,
      defaultSuggestion: false,
      priorityTier: CommandPaletteItem.defaultPriorityTier + 100
    )
  }
}

func loadRecency(into state: inout CommandPaletteFeature.State) {
  @Shared(.appStorage("commandPaletteItemRecency")) var recency: [String: Double] = [:]
  state.recencyByItemID = recency
}

func saveRecency(_ recencyByItemID: [CommandPaletteItem.ID: TimeInterval]) {
  @Shared(.appStorage("commandPaletteItemRecency")) var recency: [String: Double] = [:]
  $recency.withLock {
    $0 = recencyByItemID
  }
}
