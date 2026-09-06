import ComposableArchitecture
import Foundation
import ProwlCLIShared

let appLogger = SupaLogger("App")
let notificationJumpLogger = SupaLogger("NotificationJump")

enum CancelID {
  static let periodicRefresh = "app.periodicRefresh"
}

/// Every directory a workflow run directory can live under (docs-ai 063 B3): each worktree, and
/// the root of a plain repository, which the CLI resolves as its own worktree.
func workflowRunRoots(of repositories: [Repository]) -> [String] {
  var roots: [String] = []
  for repository in repositories {
    if repository.capabilities.supportsRunnableFolderActions, !repository.capabilities.supportsWorktrees {
      roots.append(repository.rootURL.path(percentEncoded: false))
    }
    roots += repository.worktrees.map { $0.workingDirectory.path(percentEncoded: false) }
  }
  return roots
}

func makeTerminalRestorableWorktrees(from repositories: [Repository]) -> [Worktree] {
  var worktrees: [Worktree] = []
  worktrees.reserveCapacity(repositories.reduce(0) { $0 + max(1, $1.worktrees.count) })
  for repository in repositories {
    if repository.capabilities.supportsWorktrees {
      worktrees.append(contentsOf: repository.worktrees)
      continue
    }
    if repository.capabilities.supportsRunnableFolderActions {
      worktrees.append(
        Worktree(
          id: repository.id,
          name: repository.name,
          detail: repository.rootURL.path(percentEncoded: false),
          workingDirectory: repository.rootURL,
          repositoryRootURL: repository.rootURL
        )
      )
    }
  }
  return worktrees
}

func openedWorktreeIDsForInfoWatcher(
  from repositories: RepositoriesFeature.State
) -> Set<Worktree.ID> {
  let watchedIDs = Set(repositories.worktreesForInfoWatcher().map(\.id))
  return repositories.openedWorktreeIDs.intersection(watchedIDs)
}

/// Resolves the window-scoped Rename Branch command without duplicating
/// Normal/Canvas target semantics at each entry point. Explicit row context
/// menus bypass this query because their target is already unambiguous.
func renameBranchCommandTargetID(
  appState: AppFeature.State,
  canvasFocusedWorktreeID: Worktree.ID?
) -> Worktree.ID? {
  let repositories = appState.repositories
  guard repositories.sidebarSelectedWorktreeIDs.count <= 1,
    !appState.hasBlockingRenameBranchPresentation
  else {
    return nil
  }
  let explicitTargetID = repositories.isShowingCanvas ? canvasFocusedWorktreeID : nil
  guard let target = repositories.actionTargetTerminalWorktree(explicitTargetID: explicitTargetID),
    repositories.worktree(for: target.id) != nil,
    !repositories.isWorktreeArchived(target.id)
  else {
    return nil
  }
  return target.id
}

extension AppFeature.State {
  fileprivate var hasBlockingRenameBranchPresentation: Bool {
    isRunScriptPromptPresented
      || handoffHud != nil
      || workflowStart != nil
      || alert != nil
      || repositories.isOpenPanelPresented
      || repositories.worktreeCreationPrompt != nil
      || repositories.workspaceCreationPrompt != nil
      || repositories.pendingRenameBranchRequest != nil
      || repositories.deleteWorktreeConfirmation != nil
      || repositories.removeWorkspaceConfirmation != nil
      || repositories.alert != nil
  }
}

extension AppFeature {
  func appQuitProperties(launchedAt: Date?) -> [String: Any]? {
    guard let seconds = Self.sessionDurationSeconds(launchedAt: launchedAt, now: now) else { return nil }
    return ["session_duration_seconds": seconds]
  }

  func restoreCommandPaletteTerminalFocusEffect(repositories: RepositoriesFeature.State) -> Effect<Action> {
    guard let worktree = commandPaletteTerminalFocusTarget(repositories: repositories) else { return .none }
    return .run { _ in
      await terminalClient.send(.focusSelectedTab(worktree))
    }
  }

  /// Delegate actions that intentionally shift focus elsewhere (selection
  /// changes, view changes that swap the focused terminal). These skip the
  /// post-delegate focus restore so we don't fight the natural new focus.
  static func commandPaletteDelegateChangesActiveSelection(
    _ delegate: CommandPaletteFeature.Delegate
  ) -> Bool {
    switch delegate {
    case .selectWorktree, .jumpToLatestUnread, .viewArchivedWorktrees,
      .newWorktree, .toggleCanvas, .renameBranch, .handOff, .runWorkflow:
      // `.handOff` opens the HUD, whose key-capture view takes first
      // responder; restoring terminal focus here would steal it back and
      // leak arrow keys into the live agent session. `.runWorkflow` presents
      // the start sheet, whose controls own the keyboard the same way.
      return true
    default:
      return false
    }
  }

  func commandPaletteTerminalFocusTarget(repositories: RepositoriesFeature.State) -> Worktree? {
    if let worktree = repositories.selectedTerminalWorktree {
      return worktree
    }
    return canvasFocusedTerminalWorktree(repositories: repositories)
  }

  func actionTargetWorktree(repositories: RepositoriesFeature.State) -> Worktree? {
    // Same resolver as every UI entry point (palette item factories); only
    // the source of the explicit target — the focused Canvas card — lives
    // here, behind the terminal client dependency.
    repositories.actionTargetTerminalWorktree(
      explicitTargetID: canvasFocusedWorktreeID(repositories: repositories)
    )
  }

  func canvasFocusedTerminalWorktree(repositories: RepositoriesFeature.State) -> Worktree? {
    guard let worktreeID = canvasFocusedWorktreeID(repositories: repositories) else {
      return nil
    }
    return terminalWorktree(for: worktreeID, repositories: repositories)
  }

  private func canvasFocusedWorktreeID(repositories: RepositoriesFeature.State) -> Worktree.ID? {
    guard repositories.isShowingCanvas else { return nil }
    return terminalClient.canvasFocusedWorktreeID()
  }

  func terminalWorktree(
    for worktreeID: Worktree.ID,
    repositories: RepositoriesFeature.State
  ) -> Worktree? {
    if let worktree = repositories.worktree(for: worktreeID) {
      return worktree
    }
    guard let repository = repositories.repositories[id: worktreeID],
      repository.capabilities.supportsRunnableFolderActions,
      !repository.capabilities.supportsWorktrees
    else {
      return nil
    }
    return Worktree(
      id: repository.id,
      name: repository.name,
      detail: repository.rootURL.path(percentEncoded: false),
      workingDirectory: repository.rootURL,
      repositoryRootURL: repository.rootURL
    )
  }

  static func sessionDurationSeconds(launchedAt: Date?, now: Date) -> Int? {
    guard let launchedAt else { return nil }
    return max(0, Int(now.timeIntervalSince(launchedAt)))
  }

  func resolvedKeybindings(
    settings: SettingsFeature.State,
    customCommands: [EffectiveCustomCommand]
  ) -> ResolvedKeybindingMap {
    let migration = LegacyCustomCommandShortcutMigration.migrate(commands: customCommands)
    var resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(effectiveCustomCommands: customCommands),
      userOverrides: settings.keybindingUserOverrides,
      migratedOverrides: migration.overrides
    )
    let localBindings: [Keybinding] =
      customCommands
      .filter { $0.source == .repository }
      .compactMap { resolved.keybinding(for: $0.keybindingID) }
    for command in customCommands where command.source == .global {
      guard
        let binding = resolved.keybinding(for: command.keybindingID),
        localBindings.contains(where: { $0.hasSameTrigger(as: binding) })
      else {
        continue
      }
      guard let resolvedBinding = resolved.binding(for: command.keybindingID) else { continue }
      resolved.bindingsByCommandID[command.keybindingID] = ResolvedKeybinding(
        command: resolvedBinding.command,
        binding: nil,
        source: resolvedBinding.source
      )
    }
    let customCommandIDs = customCommands.map(\.keybindingID)
    let customCommandBindings = customCommandIDs.compactMap { resolved.keybinding(for: $0) }
    guard !customCommandBindings.isEmpty else {
      return resolved
    }
    for binding in AppShortcuts.bindings where binding.scope == .configurableAppAction {
      guard let resolvedBinding = resolved.binding(for: binding.id),
        let shortcut = resolvedBinding.binding,
        customCommandBindings.contains(where: { $0.hasSameTrigger(as: shortcut) })
      else {
        continue
      }
      resolved.bindingsByCommandID[binding.id] = ResolvedKeybinding(
        command: resolvedBinding.command,
        binding: nil,
        source: resolvedBinding.source
      )
    }
    return resolved
  }

  /// Applies a worktree's repository settings (open action, run script) into
  /// state. Shared by the normal `worktreeSettingsLoaded` action and the Canvas
  /// focus path so both stay in sync.
  func applyWorktreeSettings(
    _ settings: RepositorySettings,
    workingDirectory: URL?,
    into state: inout State
  ) {
    @Shared(.settingsFile) var settingsFile
    let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(
      settingsFile.global.defaultEditorID
    )
    state.openActionSelection = OpenWorktreeAction.fromSettingsID(
      settings.openActionID,
      defaultEditorID: normalizedDefaultEditorID,
      workingDirectory: workingDirectory
    )
    state.openActionIsAutomatic = settings.openActionID == OpenWorktreeAction.automaticSettingsID
    state.selectedRunScript = settings.runScript
  }

  /// Applies a worktree's user settings (custom commands, keybindings) into
  /// state and returns the effect that re-registers custom shortcuts. Shared by
  /// the normal `worktreeUserSettingsLoaded` action and the Canvas focus path.
  func applyWorktreeUserSettings(
    _ settings: UserRepositorySettings,
    globalSettings: UserGlobalSettings,
    into state: inout State
  ) -> Effect<Action> {
    state.selectedCustomCommands = EffectiveCustomCommand.resolve(
      repositoryCommands: settings.customCommands,
      globalCommands: globalSettings.customCommands,
      disabledGlobalCommandIDs: settings.disabledGlobalCommandIDs
    )
    state.resolvedKeybindings = resolvedKeybindings(
      settings: state.settings,
      customCommands: state.selectedCustomCommands
    )
    let userOverrideConflicts = AppShortcuts.userOverrideConflicts(in: state.selectedCustomCommands)
    let shortcuts: [UserCustomShortcut] = state.selectedCustomCommands.compactMap { command in
      state.resolvedKeybindings.keybinding(for: command.keybindingID)?.userCustomShortcut
    }
    return .run { _ in
      let logger = SupaLogger("Shortcuts")
      for conflict in userOverrideConflicts {
        logger.warning(
          "shortcut_conflict reason=userOverride app_action=\"\(conflict.appActionTitle)\" "
            + "app_shortcut=\(conflict.appShortcutDisplay) custom_command=\"\(conflict.commandTitle)\" "
            + "custom_shortcut=\(conflict.commandShortcutDisplay) result=customOverride"
        )
      }
      await customShortcutRegistryClient.setShortcuts(shortcuts)
    }
  }

  func applyDefaultViewMode(into state: inout State) -> Effect<Action> {
    guard !state.hasAppliedInitialViewMode else { return .none }
    state.hasAppliedInitialViewMode = true

    @Shared(.settingsFile) var settingsFile
    let shouldEnterShelf =
      settingsFile.global.defaultViewMode == .shelf
      && !state.repositories.isShelfActive
    let shouldEnterCanvas =
      settingsFile.global.defaultViewMode == .canvas
      && !state.repositories.isShowingCanvas

    var effects: [Effect<Action>] = []
    if shouldEnterShelf {
      effects.append(.send(.repositories(.toggleShelf)))
    }
    // Enter Canvas after the selection effects so `.selectCanvas`
    // records the just-selected worktree as the pre-Canvas anchor.
    if shouldEnterCanvas {
      if state.repositories.selectedTerminalWorktree == nil,
        let targetID = defaultViewFallbackSelectionID(in: state.repositories)
      {
        effects.append(defaultViewSelectionEffect(for: targetID, repositories: state.repositories))
      }
      effects.append(.send(.repositories(.toggleCanvas)))
    }
    return effects.isEmpty ? .none : .concatenate(effects)
  }

  func defaultViewFallbackSelectionID(in repositories: RepositoriesFeature.State) -> Worktree.ID? {
    let candidateIDs =
      [repositories.lastFocusedWorktreeID].compactMap(\.self)
      + repositories.orderedWorktreeRows().map(\.id)
    return candidateIDs.first { id in
      repositories.worktree(for: id) != nil
        || repositories.repositories[id: id]?.kind == .plain
    }
  }

  func defaultViewSelectionEffect(
    for targetID: Worktree.ID,
    repositories: RepositoriesFeature.State
  ) -> Effect<Action> {
    if repositories.worktree(for: targetID) == nil,
      repositories.repositories[id: targetID]?.kind == .plain
    {
      return .send(.repositories(.selectRepository(targetID)))
    }
    return .send(.repositories(.selectWorktree(targetID)))
  }
}

// Renders Custom Command run duration for status toasts.
// Sub-second runs show ms; short runs show one decimal; long runs reuse the
// whole-seconds formatter used by other command-finished notifications.
func formatCustomCommandDuration(_ durationMs: Int) -> String {
  if durationMs < 1_000 {
    return "\(max(durationMs, 0))ms"
  }
  let seconds = Double(durationMs) / 1_000.0
  if seconds < 10 {
    return String(format: "%.1fs", seconds)
  }
  return WorktreeTerminalState.formatDuration(Int(seconds))
}
