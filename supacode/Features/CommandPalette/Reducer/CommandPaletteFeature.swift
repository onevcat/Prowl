import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Sharing

@Reducer
struct CommandPaletteFeature {
  @ObservableState
  struct State: Equatable {
    var isPresented = false
    var query = ""
    var selectedIndex: Int?
    var recencyByItemID: [CommandPaletteItem.ID: TimeInterval] = [:]
  }

  enum SelectionMove: Equatable {
    case upSelection
    case downSelection
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case setPresented(Bool)
    case togglePresented
    case activateItem(CommandPaletteItem)
    case updateSelection(itemsCount: Int)
    case resetSelection(itemsCount: Int)
    case moveSelection(SelectionMove, itemsCount: Int)
    case pruneRecency([CommandPaletteItem.ID])
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case selectWorktree(Worktree.ID)
    case checkForUpdates
    case openSettings
    case newWorktree
    case openRepository
    case newWorkspace
    case deleteWorktree(Worktree.ID, Repository.ID)
    case viewArchivedWorktrees
    case refreshWorktrees
    case jumpToLatestUnread
    case ghosttyCommand(String)
    case openPullRequest(Worktree.ID)
    case markPullRequestReady(Worktree.ID)
    case mergePullRequest(Worktree.ID)
    case closePullRequest(Worktree.ID)
    case copyFailingJobURL(Worktree.ID)
    case copyCiFailureLogs(Worktree.ID)
    case rerunFailedJobs(Worktree.ID)
    case openFailingCheckDetails(Worktree.ID)
    case installCLI
    case changeFocusedTabIcon(Worktree.ID)
    case toggleLeftSidebar
    case toggleActiveAgentsPanel
    case toggleCanvas
    case expandCanvasCard
    case arrangeCanvasCards
    case organizeCanvasCards
    case tileCanvasCards
    case selectAllCanvasCards
    case toggleShelf
    case showDiff
    case showOutgoingChanges
    case revealInFinder
    case copyPath
    case revealInSidebar
    case runScript
    case stopRunScript
    case togglePinWorktree(Worktree.ID, isCurrentlyPinned: Bool)
    case renameBranch
    case openRepositorySettings(Repository.ID)
    case runCustomCommand(EffectiveCustomCommand.Identifier)
    case handOff
    case launchAgentProfile(AgentProfile.ID)
    case runWorkflow(String)
    #if DEBUG
      case debugTestToast(RepositoriesFeature.StatusToast)
      case debugSimulateUpdateFound
      case debugLightDockNotificationDot
    #endif
  }

  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .setPresented(let isPresented):
        state.isPresented = isPresented
        if isPresented {
          loadRecency(into: &state)
          state.selectedIndex = nil
        } else {
          state.query = ""
          state.selectedIndex = nil
        }
        return .none

      case .togglePresented:
        state.isPresented.toggle()
        if state.isPresented {
          loadRecency(into: &state)
          state.selectedIndex = nil
        } else {
          state.query = ""
          state.selectedIndex = nil
        }
        return .none

      case .activateItem(let item):
        state.isPresented = false
        state.query = ""
        state.selectedIndex = nil
        state.recencyByItemID[item.id] = now.timeIntervalSince1970
        saveRecency(state.recencyByItemID)
        return .send(.delegate(delegateAction(for: item.kind)))

      case .updateSelection(let itemsCount):
        if itemsCount == 0 {
          state.selectedIndex = nil
          return .none
        }
        if let selectedIndex = state.selectedIndex, selectedIndex >= itemsCount {
          state.selectedIndex = itemsCount - 1
        } else if state.selectedIndex == nil {
          state.selectedIndex = 0
        }
        return .none

      case .resetSelection(let itemsCount):
        state.selectedIndex = itemsCount == 0 ? nil : 0
        return .none

      case .moveSelection(let direction, let itemsCount):
        guard itemsCount > 0 else {
          state.selectedIndex = nil
          return .none
        }
        let maxIndex = itemsCount - 1
        switch direction {
        case .upSelection:
          if let selectedIndex = state.selectedIndex {
            state.selectedIndex = selectedIndex == 0 ? maxIndex : selectedIndex - 1
          } else {
            state.selectedIndex = maxIndex
          }
        case .downSelection:
          if let selectedIndex = state.selectedIndex {
            state.selectedIndex = selectedIndex == maxIndex ? 0 : selectedIndex + 1
          } else {
            state.selectedIndex = 0
          }
        }
        return .none

      case .pruneRecency(let ids):
        let idSet = Set(ids)
        let pruned = state.recencyByItemID.filter { idSet.contains($0.key) }
        guard pruned != state.recencyByItemID else { return .none }
        state.recencyByItemID = pruned
        saveRecency(pruned)
        return .none

      case .delegate:
        return .none
      }
    }
  }

  static func suggestions(
    items: [CommandPaletteItem],
    recencyByID: [CommandPaletteItem.ID: TimeInterval] = [:],
    now: Date = .now
  ) -> CommandPaletteSuggestions {
    let recencyScored: [(item: CommandPaletteItem, score: Double)] = items.compactMap { item in
      let score = commandPaletteRecencyScore(item, recencyByID: recencyByID, now: now)
      return score > 0 ? (item, score) : nil
    }
    let recent = Array(
      recencyScored
        .sorted { $0.score > $1.score }
        .prefix(CommandPaletteSuggestions.maxItems)
        .map(\.item)
    )

    let recentIDs = Set(recent.map(\.id))
    let suggestedCandidates = items.enumerated().compactMap { idx, item -> (item: CommandPaletteItem, idx: Int)? in
      guard item.defaultSuggestion, !recentIDs.contains(item.id) else { return nil }
      return (item, idx)
    }
    let suggested = Array(
      suggestedCandidates
        .sorted { left, right in
          if left.item.priorityTier != right.item.priorityTier {
            return left.item.priorityTier < right.item.priorityTier
          }
          return left.idx < right.idx
        }
        .prefix(CommandPaletteSuggestions.maxItems - recent.count)
        .map(\.item)
    )

    return CommandPaletteSuggestions(recent: recent, suggested: suggested)
  }

  static func filterItems(
    items: [CommandPaletteItem],
    query: String,
    recencyByID: [CommandPaletteItem.ID: TimeInterval] = [:],
    now: Date = .now
  ) -> [CommandPaletteItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return suggestions(items: items, recencyByID: recencyByID, now: now).allItems
    }
    let scorer = CommandPaletteFuzzyScorer(query: trimmed, recencyByID: recencyByID, now: now)
    return scorer.rankedItems(from: items)
  }

  static func commandPaletteItems(
    from repositories: RepositoriesFeature.State,
    customCommands: [EffectiveCustomCommand] = [],
    runScriptStatusByWorktreeID: [Worktree.ID: Bool] = [:],
    actionTargetWorktreeID: Worktree.ID? = nil,
    ghosttyCommands: [GhosttyCommand] = [],
    workflowItems: [WorkflowStartCatalogItem] = []
  ) -> [CommandPaletteItem] {
    let showsNewWorktreeAction =
      repositories.repositories.isEmpty
      || repositories.repositories.contains { $0.capabilities.supportsWorktrees }
    var items = globalCommandItems(
      showsNewWorktreeAction: showsNewWorktreeAction,
      isShowingArchivedWorktrees: repositories.isShowingArchivedWorktrees
    )
    if repositories.isShowingCanvas {
      items.append(contentsOf: canvasCommandItems())
    }
    let worktreeActionTargetID = actionTargetWorktreeID ?? repositories.selectedWorktreeID
    // Diff view items follow the broader diff target (worktree or workspace
    // child); the navigation/action items below stay worktree-scoped.
    if repositories.selectedDiffTargetID != nil {
      items.append(contentsOf: selectedWorktreeViewCommandItems())
    }
    if repositories.selectedWorktreeID != nil {
      items.append(contentsOf: worktreeNavigationCommandItems())
      items.append(
        contentsOf: worktreeActionCommandItems(
          repositories: repositories,
          worktreeID: worktreeActionTargetID,
          runScriptStatusByWorktreeID: runScriptStatusByWorktreeID
        )
      )
    } else if worktreeActionTargetID != nil {
      items.append(
        contentsOf: worktreeActionCommandItems(
          repositories: repositories,
          worktreeID: worktreeActionTargetID,
          runScriptStatusByWorktreeID: runScriptStatusByWorktreeID,
          includeSelectionScopedItems: false
        )
      )
    }
    items.append(contentsOf: customCommandItems(customCommands))
    items.append(contentsOf: handoffCommandItems(repositories))
    items.append(
      contentsOf: workflowCommandItems(
        workflowItems, repositories: repositories, actionTargetWorktreeID: worktreeActionTargetID))
    items.append(
      contentsOf: agentProfileLaunchItems(
        repositories,
        actionTargetWorktreeID: worktreeActionTargetID
      )
    )
    if let terminalWorktree = repositories.selectedTerminalWorktree {
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.changeFocusedTabIcon(terminalWorktree.id),
          title: "Change Tab Icon...",
          subtitle: terminalWorktree.name,
          kind: .changeFocusedTabIcon(terminalWorktree.id),
          category: .worktree,
          defaultSuggestion: false
        )
      )
      items.append(contentsOf: ghosttyCommandItems(ghosttyCommands))
    } else if worktreeActionTargetID != nil {
      items.append(contentsOf: ghosttyCommandItems(ghosttyCommands))
    }
    if let repository = activeRepository(in: repositories) {
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.openRepositorySettings(repository.id),
          title: "Repo Settings",
          subtitle: repository.name,
          kind: .openRepositorySettings(repository.id),
          category: .app,
          defaultSuggestion: true,
          keywords: ["repo", "settings", "configure", "preferences"]
        )
      )
    }
    items.append(
      contentsOf: selectedCodeHostItems(
        from: repositories,
        actionTargetWorktreeID: worktreeActionTargetID
      )
    )
    #if DEBUG
      items.append(contentsOf: debugToastItems())
    #endif
    for row in repositories.orderedWorktreeRows() {
      guard !row.isPending, !row.isDeleting else { continue }
      let repositoryName = repositories.repositoryName(for: row.repositoryID) ?? "Repository"
      let title = "\(repositoryName) / \(row.name)"
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.worktreeSelect(row.id),
          title: title,
          subtitle: nil,
          kind: .worktreeSelect(row.id),
          category: .navigation,
          defaultSuggestion: false
        )
      )
    }
    return items
  }

  static func recencyRetentionIDs(
    from repositories: IdentifiedArrayOf<Repository>,
    customCommands: [EffectiveCustomCommand] = []
  ) -> [CommandPaletteItem.ID] {
    var ids = CommandPaletteItemID.globalIDs
    ids.append(contentsOf: customCommands.map(CommandPaletteItemID.customCommand))
    for repository in repositories {
      ids.append(contentsOf: CommandPaletteItemID.pullRequestIDs(repositoryID: repository.id))
      ids.append(CommandPaletteItemID.openRepositorySettings(repository.id))
      for worktree in repository.worktrees {
        ids.append(CommandPaletteItemID.worktreeSelect(worktree.id))
        ids.append(CommandPaletteItemID.changeFocusedTabIcon(worktree.id))
      }
    }
    return ids
  }
}

private func globalCommandItems(
  showsNewWorktreeAction: Bool,
  isShowingArchivedWorktrees: Bool
) -> [CommandPaletteItem] {
  var items: [CommandPaletteItem] = [
    .appShortcut(
      id: CommandPaletteItemID.globalCheckForUpdates,
      title: "Check for Updates",
      category: .app,
      kind: .checkForUpdates,
      keywords: ["update", "version"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalOpenSettings,
      title: "Open Settings",
      category: .app,
      kind: .openSettings,
      keywords: ["preferences", "config"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalOpenRepository,
      title: "Open Repository",
      category: .app,
      kind: .openRepository,
      keywords: ["repo", "add repo"]
    ),
    CommandPaletteItem(
      id: CommandPaletteItemID.globalNewWorkspace,
      title: "New Workspace",
      subtitle: nil,
      kind: .newWorkspace,
      category: .app,
      defaultSuggestion: true,
      keywords: ["workspace", "multi repo", "many repos"]
    ),
  ]
  if showsNewWorktreeAction {
    items.append(
      .appShortcut(
        id: CommandPaletteItemID.globalNewWorktree,
        title: "New Worktree",
        category: .worktree,
        kind: .newWorktree,
        keywords: ["worktree", "branch"]
      )
    )
  }
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalRefreshWorktrees,
      title: "Refresh Worktrees",
      category: .worktree,
      kind: .refreshWorktrees,
      keywords: ["reload", "rescan"]
    )
  )
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalJumpToLatestUnread,
      title: "Jump to Latest Unread",
      category: .navigation,
      kind: .jumpToLatestUnread,
      keywords: ["unread", "bell", "notification"]
    )
  )
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalViewArchivedWorktrees,
      title: isShowingArchivedWorktrees ? "Exit Archived Worktrees" : "View Archived Worktrees",
      category: .worktree,
      kind: .viewArchivedWorktrees,
      keywords: ["archive", "history"]
    )
  )
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalInstallCLI,
      title: "Install Command Line Tool",
      category: .app,
      kind: .installCLI,
      keywords: ["cli", "command line", "terminal", "prowl"]
    )
  )
  items.append(contentsOf: viewToggleCommandItems())
  return items
}

private func worktreeActionCommandItems(
  repositories: RepositoriesFeature.State,
  worktreeID: Worktree.ID?,
  runScriptStatusByWorktreeID: [Worktree.ID: Bool],
  includeSelectionScopedItems: Bool = true
) -> [CommandPaletteItem] {
  guard let worktreeID else { return [] }
  var items: [CommandPaletteItem] = []
  let isRunScriptRunning = runScriptStatusByWorktreeID[worktreeID] ?? false
  if isRunScriptRunning {
    items.append(
      .appShortcut(
        id: CommandPaletteItemID.globalStopRunScript,
        title: "Stop Script",
        category: .worktree,
        kind: .stopRunScript,
        keywords: ["stop", "kill", "cancel", "script"]
      )
    )
  } else {
    items.append(
      .appShortcut(
        id: CommandPaletteItemID.globalRunScript,
        title: "Run Script",
        category: .worktree,
        kind: .runScript,
        keywords: ["run", "script", "execute"]
      )
    )
  }
  guard includeSelectionScopedItems else { return items }
  guard let row = repositories.selectedRow(for: worktreeID) else { return items }
  // Rename Branch works on any worktree (main included).
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalRenameBranch,
      title: "Rename Branch",
      category: .worktree,
      kind: .renameBranch,
      keywords: ["rename", "branch", "name"]
    )
  )
  // Pin / Unpin / Delete only apply to non-main worktrees.
  guard !row.isMainWorktree else { return items }
  let pinTitle = row.isPinned ? "Unpin Worktree" : "Pin Worktree"
  let pinKeywords =
    row.isPinned ? ["unpin", "favorite"] : ["pin", "favorite", "top"]
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalTogglePinWorktree,
      title: pinTitle,
      category: .worktree,
      kind: .togglePinWorktree(worktreeID, isCurrentlyPinned: row.isPinned),
      keywords: pinKeywords
    )
  )
  if let repositoryID = repositories.repositoryID(containing: worktreeID) {
    items.append(
      CommandPaletteItem(
        id: CommandPaletteItemID.globalDeleteWorktree,
        title: "Delete Worktree",
        subtitle: row.name,
        kind: .deleteWorktree(worktreeID, repositoryID),
        category: .worktree,
        defaultSuggestion: false,
        keywords: ["delete", "remove", "destroy"]
      )
    )
  }
  return items
}

/// Resolves the "active" repository for repo-scoped palette commands:
/// prefers an explicitly selected repo, then falls back to the repo that
/// owns the currently-selected worktree. Returns nil when nothing relevant
/// is selected (e.g., archived view, empty palette).
private func activeRepository(
  in repositories: RepositoriesFeature.State
) -> Repository? {
  if let repository = repositories.selectedRepository {
    return repository
  }
  guard let worktreeID = repositories.selectedWorktreeID,
    let repositoryID = repositories.repositoryID(containing: worktreeID)
  else {
    return nil
  }
  return repositories.repositories[id: repositoryID]
}

private func customCommandItems(_ commands: [EffectiveCustomCommand]) -> [CommandPaletteItem] {
  commands.compactMap { effectiveCommand in
    let command = effectiveCommand.command
    guard command.hasRunnableCommand else { return nil }
    return CommandPaletteItem(
      id: CommandPaletteItemID.customCommand(effectiveCommand),
      title: command.resolvedTitle,
      subtitle: customCommandSubtitle(for: effectiveCommand),
      kind: .runCustomCommand(
        effectiveCommand.id,
        systemImage: command.resolvedSystemImage
      ),
      category: .worktree,
      defaultSuggestion: false,
      keywords: ["custom", "command", "script"]
    )
  }
}

/// Launch rows for enabled agent profiles: the target worktree's Recommended
/// profile first, then list order. Dispatches the same single profile-launch
/// action as the toolbar Agents menu (docs-ai 053) — the palette is an entry
/// point, never a second launch path. The target mirrors the launch action's
/// resolution: the selected terminal worktree in Normal mode, the focused
/// Canvas card otherwise. Internal for tests.
func agentProfileLaunchItems(
  _ repositories: RepositoriesFeature.State,
  actionTargetWorktreeID: Worktree.ID? = nil,
  launchWarning: @MainActor (AgentProfile) -> String? = AgentProfileAvailability.launchWarning(for:)
) -> [CommandPaletteItem] {
  guard
    let worktree = repositories.actionTargetTerminalWorktree(
      explicitTargetID: actionTargetWorktreeID
    )
  else { return [] }
  @Shared(.userGlobalSettings) var globalSettings
  let profiles = globalSettings.agentProfiles
  let enabled = profiles.filter(\.isEnabled)
  guard !enabled.isEmpty else { return [] }
  @Shared(.userRepositorySettings(worktree.repositoryRootURL)) var repositorySettings
  let recommendedID = AgentProfileRecommendation.recommendedProfile(
    profiles: profiles,
    designatedID: repositorySettings.defaultAgentProfileID,
    lastLaunchedID: repositorySettings.lastLaunchedAgentProfileID
  )?.id
  let ordered = enabled.sorted { lhs, rhs in
    (lhs.id == recommendedID ? 0 : 1) < (rhs.id == recommendedID ? 0 : 1)
  }
  return ordered.map { profile in
    let runtimeName = AgentRuntimeAdapterRegistry.displayName(for: profile.runtime)
    let placement = profile.id == recommendedID ? "Recommended · " : ""
    // Same soft availability judgment as the Agents popover — surfaced in the
    // subtitle, never blocking activation (docs-ai 053/005).
    let warning = launchWarning(profile)
    let detail = warning.map { "\($0) · \(worktree.name)" } ?? "New \(runtimeName) in \(worktree.name)"
    return CommandPaletteItem(
      id: CommandPaletteItemID.launchAgentProfile(profile.id),
      title: "Launch Agent: \(profile.name)",
      subtitle: "\(placement)\(detail)",
      kind: .launchAgentProfile(profile.id),
      category: .terminal,
      defaultSuggestion: false,
      keywords: ["launch", "agent", "profile", "start", profile.name],
      agentProfileIconSource: profile.iconSource
    )
  }
}

/// One `Run Workflow:` row per runnable workflow visible to the action-target
/// worktree (docs-ai 063 C2). The list is refreshed when the palette opens;
/// validation-failing files stay out of the palette (the Agents popover is the
/// diagnostic surface, 011 decision 3).
func workflowCommandItems(
  _ workflows: [WorkflowStartCatalogItem],
  repositories: RepositoriesFeature.State,
  actionTargetWorktreeID: Worktree.ID? = nil
) -> [CommandPaletteItem] {
  guard
    let worktree = repositories.actionTargetTerminalWorktree(
      explicitTargetID: actionTargetWorktreeID
    )
  else { return [] }
  return workflows.filter(\.isRunnable).map { item in
    CommandPaletteItem(
      id: CommandPaletteItemID.runWorkflow(item.key),
      title: "Run Workflow: \(item.name)",
      subtitle: item.workflowDescription ?? "Start this workflow in \(worktree.name)",
      kind: .runWorkflow(item.key),
      category: .terminal,
      defaultSuggestion: false,
      keywords: ["workflow", "run", item.name, item.workflowID]
    )
  }
}

/// The single hand-off entry: opens the staged HUD where the receiving
/// agent is chosen (docs-ai 049).
private func handoffCommandItems(_ repositories: RepositoriesFeature.State) -> [CommandPaletteItem] {
  guard repositories.selectedTerminalWorktree != nil else { return [] }
  return [
    CommandPaletteItem(
      id: CommandPaletteItemID.handOff,
      title: "Hand Off…",
      subtitle: "Choose an agent to take over this task",
      kind: .handOff,
      category: .terminal,
      defaultSuggestion: false,
      keywords: ["handoff", "hand off", "switch agent", "takeover", "agents"]
    )
  ]
}

private func customCommandSubtitle(for effectiveCommand: EffectiveCustomCommand) -> String {
  "\(effectiveCommand.source.displayTitle) custom command · "
    + customCommandExecutionDescription(for: effectiveCommand.command)
}

private func customCommandExecutionDescription(for command: UserCustomCommand) -> String {
  switch command.execution {
  case .shellScript:
    return "Opens in a new tab"
  case .terminalInput:
    return "Runs in the focused terminal"
  case .split:
    return "Opens in a new split (\(command.splitDirection.title.lowercased()))"
  }
}

private func worktreeNavigationCommandItems() -> [CommandPaletteItem] {
  [
    .appShortcut(
      id: CommandPaletteItemID.globalRevealInFinder,
      title: "Reveal in Finder",
      category: .navigation,
      kind: .revealInFinder,
      keywords: ["finder", "open", "show"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalCopyPath,
      title: "Copy Path",
      category: .navigation,
      kind: .copyPath,
      keywords: ["copy", "path", "clipboard"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalRevealInSidebar,
      title: "Reveal in Sidebar",
      category: .navigation,
      kind: .revealInSidebar,
      keywords: ["reveal", "locate", "find worktree"]
    ),
  ]
}

private func selectedWorktreeViewCommandItems() -> [CommandPaletteItem] {
  [
    .appShortcut(
      id: CommandPaletteItemID.globalShowDiff,
      title: "Show Diff",
      category: .view,
      kind: .showDiff,
      keywords: ["diff", "changes", "git"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalOutgoingChanges,
      title: "Show Outgoing Changes",
      category: .view,
      kind: .outgoingChanges,
      keywords: ["diff", "changes", "outgoing", "pull request", "git"]
    ),
  ]
}

private func viewToggleCommandItems() -> [CommandPaletteItem] {
  [
    .appShortcut(
      id: CommandPaletteItemID.globalToggleLeftSidebar,
      title: "Toggle Sidebar",
      category: .view,
      kind: .toggleLeftSidebar,
      keywords: ["sidebar", "hide", "left panel"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalToggleActiveAgentsPanel,
      title: "Toggle Active Agents Panel",
      category: .view,
      kind: .toggleActiveAgentsPanel,
      keywords: ["agents", "panel"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalToggleCanvas,
      title: "Toggle Canvas",
      category: .view,
      kind: .toggleCanvas,
      keywords: ["canvas", "overview", "grid"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalToggleShelf,
      title: "Toggle Shelf",
      category: .view,
      kind: .toggleShelf,
      keywords: ["shelf", "books"]
    ),
  ]
}

private func canvasCommandItems() -> [CommandPaletteItem] {
  [
    .appShortcut(
      id: CommandPaletteItemID.globalExpandCanvasCard,
      title: "Expand / Restore Canvas Card",
      category: .view,
      kind: .expandCanvasCard,
      keywords: ["canvas", "expand", "restore", "focus", "fullscreen", "card"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalArrangeCanvasCards,
      title: "Arrange Canvas Cards",
      category: .view,
      kind: .arrangeCanvasCards,
      keywords: ["canvas", "arrange", "layout", "pack", "fit"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalOrganizeCanvasCards,
      title: "Organize Canvas Cards",
      category: .view,
      kind: .organizeCanvasCards,
      keywords: ["canvas", "organize", "grid", "tidy", "uniform"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalTileCanvasCards,
      title: "Tile Canvas Cards",
      category: .view,
      kind: .tileCanvasCards,
      keywords: ["canvas", "tile", "fill", "layout", "window", "split"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalSelectAllCanvasCards,
      title: "Select All Canvas Cards",
      category: .view,
      kind: .selectAllCanvasCards,
      keywords: ["canvas", "select all", "broadcast"]
    ),
  ]
}

private func selectedCodeHostItems(
  from repositories: RepositoriesFeature.State,
  actionTargetWorktreeID: Worktree.ID? = nil
) -> [CommandPaletteItem] {
  guard
    let worktreeID = actionTargetWorktreeID ?? repositories.selectedWorktreeID,
    let repositoryID = repositories.repositoryID(containing: worktreeID),
    let repository = repositories.repositories[id: repositoryID]
  else {
    return []
  }

  let codeHost = repositories.codeHost(for: repositoryID)
  let pullRequest = repositories.worktreeInfo(for: worktreeID)?.pullRequest
  if repository.capabilities.supportsPullRequests,
    let pullRequest,
    pullRequest.number > 0,
    pullRequest.state.uppercased() != "CLOSED"
  {
    return pullRequestItems(
      pullRequest: pullRequest,
      worktreeID: worktreeID,
      repositoryID: repositoryID,
      codeHost: codeHost
    )
  }

  guard repository.capabilities.supportsCodeHost else {
    return []
  }

  return [
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestOpen(repositoryID),
      title: "Open Repository on \(codeHost.displayName)",
      subtitle: repository.name,
      kind: .openRepositoryOnCodeHost(worktreeID),
      category: .pullRequest,
      defaultSuggestion: false,
      priorityTier: 2
    )
  ]
}

private func pullRequestItems(
  pullRequest: GithubPullRequest,
  worktreeID: Worktree.ID,
  repositoryID: Repository.ID,
  codeHost: CodeHost
) -> [CommandPaletteItem] {
  let isOpen = pullRequest.state.uppercased() == "OPEN"
  let mergeReadiness = PullRequestMergeReadiness(pullRequest: pullRequest)
  let breakdown = PullRequestCheckBreakdown(checks: pullRequest.statusCheckRollup?.checks ?? [])
  let canMerge = isOpen && !pullRequest.isDraft && !mergeReadiness.isBlocking

  var items: [CommandPaletteItem] = [
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestOpen(repositoryID),
      title: "Open Pull Request on \(codeHost.displayName)",
      subtitle: pullRequest.title,
      kind: .openPullRequest(worktreeID),
      category: .pullRequest,
      defaultSuggestion: true,
      priorityTier: 2
    )
  ]

  if let readyItem = makeReadyPullRequestItem(
    pullRequest: pullRequest,
    repositoryID: repositoryID,
    worktreeID: worktreeID
  ) {
    items.append(readyItem)
  }

  items.append(
    contentsOf: makeFailingPullRequestItems(
      pullRequest: pullRequest,
      repositoryID: repositoryID,
      worktreeID: worktreeID
    )
  )

  if let mergeItem = makeMergePullRequestItem(
    canMerge: canMerge,
    breakdown: breakdown,
    repositoryID: repositoryID,
    worktreeID: worktreeID
  ) {
    items.append(mergeItem)
  }

  if let closeItem = makeClosePullRequestItem(
    isOpen: isOpen,
    repositoryID: repositoryID,
    worktreeID: worktreeID,
    pullRequestTitle: pullRequest.title
  ) {
    items.append(closeItem)
  }

  return items
}

private func makeReadyPullRequestItem(
  pullRequest: GithubPullRequest,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID
) -> CommandPaletteItem? {
  let isOpen = pullRequest.state.uppercased() == "OPEN"
  guard isOpen && pullRequest.isDraft else { return nil }
  return CommandPaletteItem(
    id: CommandPaletteItemID.pullRequestReady(repositoryID),
    title: "Mark PR Ready for Review",
    subtitle: pullRequest.title,
    kind: .markPullRequestReady(worktreeID),
    category: .pullRequest,
    defaultSuggestion: true,
    priorityTier: 0
  )
}

private func makeFailingPullRequestItems(
  pullRequest: GithubPullRequest,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID
) -> [CommandPaletteItem] {
  let isOpen = pullRequest.state.uppercased() == "OPEN"
  let checks = pullRequest.statusCheckRollup?.checks ?? []
  let hasFailingChecks = PullRequestCheckBreakdown(checks: checks).failed > 0
  guard isOpen && hasFailingChecks else { return [] }
  let hasFailingCheckWithDetails = checks.contains { $0.checkState == .failure && $0.detailsUrl != nil }
  let leadingTier = pullRequest.isDraft ? 1 : 0
  let followupTier = leadingTier + 1
  var failingItems: [CommandPaletteItem] = []
  if hasFailingCheckWithDetails {
    failingItems.append(
      CommandPaletteItem(
        id: CommandPaletteItemID.pullRequestCopyFailingJobURL(repositoryID),
        title: "Copy failing job URL",
        subtitle: pullRequest.title,
        kind: .copyFailingJobURL(worktreeID),
        category: .pullRequest,
        defaultSuggestion: true,
        priorityTier: leadingTier
      )
    )
  }
  failingItems.append(
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestCopyCiLogs(repositoryID),
      title: "Copy CI Failure Logs",
      subtitle: pullRequest.title,
      kind: .copyCiFailureLogs(worktreeID),
      category: .pullRequest,
      defaultSuggestion: true,
      priorityTier: hasFailingCheckWithDetails ? followupTier : leadingTier
    )
  )
  failingItems.append(
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestRerunFailedJobs(repositoryID),
      title: "Re-run Failed Jobs",
      subtitle: pullRequest.title,
      kind: .rerunFailedJobs(worktreeID),
      category: .pullRequest,
      defaultSuggestion: true,
      priorityTier: followupTier
    )
  )
  if hasFailingCheckWithDetails {
    failingItems.append(
      CommandPaletteItem(
        id: CommandPaletteItemID.pullRequestOpenFailingCheck(repositoryID),
        title: "Open Failing Check Details",
        subtitle: pullRequest.title,
        kind: .openFailingCheckDetails(worktreeID),
        category: .pullRequest,
        defaultSuggestion: true,
        priorityTier: followupTier
      )
    )
  }
  return failingItems
}

private func makeMergePullRequestItem(
  canMerge: Bool,
  breakdown: PullRequestCheckBreakdown,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID
) -> CommandPaletteItem? {
  guard canMerge else { return nil }
  let successfulChecks = breakdown.passed
  let successfulChecksLabel =
    successfulChecks == 1
    ? "1 successful check"
    : "\(successfulChecks) successful checks"
  return CommandPaletteItem(
    id: CommandPaletteItemID.pullRequestMerge(repositoryID),
    title: "Merge PR",
    subtitle: "Merge Ready - \(successfulChecksLabel)",
    kind: .mergePullRequest(worktreeID),
    category: .pullRequest,
    defaultSuggestion: true,
    priorityTier: 0
  )
}

private func makeClosePullRequestItem(
  isOpen: Bool,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID,
  pullRequestTitle: String
) -> CommandPaletteItem? {
  guard isOpen else { return nil }
  return CommandPaletteItem(
    id: CommandPaletteItemID.pullRequestClose(repositoryID),
    title: "Close PR",
    subtitle: pullRequestTitle,
    kind: .closePullRequest(worktreeID),
    category: .pullRequest,
    defaultSuggestion: true,
    priorityTier: 1
  )
}

#if DEBUG
  private func debugToastItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "debug.toast.inProgress",
        title: "[Debug] Toast: In Progress",
        subtitle: "Simulates an in-progress toast",
        kind: .debugTestToast(.inProgress("Merging pull request…")),
        category: .debug,
        defaultSuggestion: true
      ),
      CommandPaletteItem(
        id: "debug.toast.success",
        title: "[Debug] Toast: Success",
        subtitle: "Simulates a success toast",
        kind: .debugTestToast(.success("Pull request merged")),
        category: .debug,
        defaultSuggestion: true
      ),
      CommandPaletteItem(
        id: "debug.update.simulate-found",
        title: "[Debug] Simulate Update Found",
        subtitle: "Shows the toolbar update badge without querying Sparkle",
        kind: .debugSimulateUpdateFound,
        category: .debug,
        defaultSuggestion: true
      ),
      CommandPaletteItem(
        id: "debug.dock.notification-dot",
        title: "[Debug] Light Dock Notification Dot",
        subtitle: "Forces the Dock notification badge on for visual testing",
        kind: .debugLightDockNotificationDot,
        category: .debug,
        defaultSuggestion: true
      ),
    ]
  }
#endif
