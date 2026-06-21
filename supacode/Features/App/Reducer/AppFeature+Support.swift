import ComposableArchitecture
import Foundation

let appLogger = SupaLogger("App")
let notificationJumpLogger = SupaLogger("NotificationJump")

enum CancelID {
  static let periodicRefresh = "app.periodicRefresh"
  static let canvasSidebarAutoHide = "app.canvasSidebarAutoHide"
}

nonisolated let canvasSidebarAutoHideDelay: Duration = .seconds(3)

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

func terminalRecoveryWorktrees(from repositories: [Repository]) -> [Worktree] {
  makeTerminalRestorableWorktrees(from: repositories)
}

nonisolated func normalizedRecoveryRootPath(_ path: String) -> String {
  var path = path
  while path.count > 1, path.hasSuffix("/") {
    path.removeLast()
  }
  return path
}

func repositoryDisplayNamesByRootPath(from state: RepositoriesFeature.State) -> [String: String] {
  var displayNames: [String: String] = [:]
  for repository in state.repositories {
    let rawRootPath = normalizedRecoveryRootPath(repository.rootURL.path(percentEncoded: false))
    let standardizedRootPath = normalizedRecoveryRootPath(
      repository.rootURL.standardizedFileURL.path(percentEncoded: false)
    )
    let customTitle = state.repositoryCustomTitles[repository.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName: String
    if let customTitle, !customTitle.isEmpty {
      displayName = customTitle
    } else {
      displayName = repository.name
    }
    displayNames[rawRootPath] = displayName
    displayNames[standardizedRootPath] = displayName
  }
  return displayNames
}

func openedWorktreeIDsForInfoWatcher(
  from repositories: RepositoriesFeature.State
) -> Set<Worktree.ID> {
  let watchedIDs = Set(repositories.worktreesForInfoWatcher().map(\.id))
  return repositories.openedWorktreeIDs.intersection(watchedIDs)
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
      .newWorktree, .toggleCanvas, .renameBranch:
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
    if let worktree = repositories.selectedTerminalWorktree {
      return worktree
    }
    return canvasFocusedTerminalWorktree(repositories: repositories)
  }

  func terminalCommandWorktree(repositories: RepositoriesFeature.State) -> Worktree? {
    if repositories.isShowingFreestyle {
      return FreestyleTerminal.worktree()
    }
    return actionTargetWorktree(repositories: repositories)
  }

  func shouldCancelCanvasSidebarAutoHide(
    for action: RepositoriesFeature.Action
  ) -> Bool {
    switch action {
    case .toggleCanvas,
      .selectArchivedWorktrees,
      .selectFreestyle,
      .selectRepository,
      .selectWorktree:
      return true
    default:
      return false
    }
  }

  func canvasFocusedTerminalWorktree(repositories: RepositoriesFeature.State) -> Worktree? {
    guard repositories.isShowingCanvas,
      let worktreeID = terminalClient.canvasFocusedWorktreeID()
    else {
      return nil
    }
    return terminalWorktree(for: worktreeID, repositories: repositories)
  }

  func canvasFocusedWorktree(
    focusedWorktreeID: Worktree.ID?,
    state: State
  ) -> Worktree? {
    if let focusedWorktreeID {
      if focusedWorktreeID == FreestyleTerminal.worktreeID {
        return FreestyleTerminal.worktree()
      }
      if let worktree = terminalWorktree(for: focusedWorktreeID, repositories: state.repositories) {
        return worktree
      }
    }
    return canvasFocusedTerminalWorktree(repositories: state.repositories)
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
    customCommands: [UserCustomCommand]
  ) -> ResolvedKeybindingMap {
    let migration = LegacyCustomCommandShortcutMigration.migrate(commands: customCommands)
    var resolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(customCommands: customCommands),
      userOverrides: settings.keybindingUserOverrides,
      migratedOverrides: migration.overrides
    )
    let customCommandIDs = customCommands.map { command in
      LegacyCustomCommandShortcutMigration.customCommandBindingID(for: command.id)
    }
    let customCommandBindings = customCommandIDs.compactMap { resolved.keybinding(for: $0) }
    guard !customCommandBindings.isEmpty else {
      return resolved
    }
    for binding in AppShortcuts.bindings where binding.scope == .configurableAppAction {
      guard let resolvedBinding = resolved.binding(for: binding.id),
        let shortcut = resolvedBinding.binding,
        customCommandBindings.contains(shortcut)
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
    into state: inout State
  ) -> Effect<Action> {
    state.selectedCustomCommands = UserRepositorySettings.normalizedCommands(settings.customCommands)
    state.resolvedKeybindings = resolvedKeybindings(
      settings: state.settings,
      customCommands: state.selectedCustomCommands
    )
    let userOverrideConflicts = AppShortcuts.userOverrideConflicts(in: state.selectedCustomCommands)
    let keybindings = menuPreferredKeybindings(
      resolvedKeybindings: state.resolvedKeybindings,
      customCommands: state.selectedCustomCommands
    )
    return .run { _ in
      let logger = SupaLogger("Shortcuts")
      for conflict in userOverrideConflicts {
        logger.warning(
          "shortcut_conflict reason=userOverride app_action=\"\(conflict.appActionTitle)\" "
            + "app_shortcut=\(conflict.appShortcutDisplay) custom_command=\"\(conflict.commandTitle)\" "
            + "custom_shortcut=\(conflict.commandShortcutDisplay) result=customOverride"
        )
      }
      await customShortcutRegistryClient.setShortcuts(keybindings)
    }
  }

  func menuPreferredKeybindings(
    resolvedKeybindings: ResolvedKeybindingMap,
    customCommands: [UserCustomCommand]
  ) -> [Keybinding] {
    var keybindings: [Keybinding] = []
    func append(_ keybinding: Keybinding?) {
      guard let keybinding, !keybindings.contains(keybinding) else { return }
      keybindings.append(keybinding)
    }

    for binding in AppShortcuts.bindings
    where binding.scope == .configurableAppAction
      && !AppShortcuts.isGhosttyManagedActionCommandID(binding.id)
    {
      append(resolvedKeybindings.keybinding(for: binding.id))
    }

    for command in customCommands {
      let commandID = LegacyCustomCommandShortcutMigration.customCommandBindingID(for: command.id)
      append(resolvedKeybindings.keybinding(for: commandID))
    }
    return keybindings
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
