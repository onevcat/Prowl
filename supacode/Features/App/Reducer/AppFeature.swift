import AppKit
import ComposableArchitecture
import Foundation
import PostHog
import SwiftUI

private let appLogger = SupaLogger("App")
private let notificationJumpLogger = SupaLogger("NotificationJump")

private enum CancelID {
  static let periodicRefresh = "app.periodicRefresh"
}

private func makeTerminalRestorableWorktrees(from repositories: [Repository]) -> [Worktree] {
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

private func openedWorktreeIDsForInfoWatcher(
  from repositories: RepositoriesFeature.State
) -> Set<Worktree.ID> {
  let watchedIDs = Set(repositories.worktreesForInfoWatcher().map(\.id))
  return repositories.openedWorktreeIDs.intersection(watchedIDs)
}

@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var repositories: RepositoriesFeature.State
    var settings: SettingsFeature.State
    var updates = UpdatesFeature.State()
    var commandPalette = CommandPaletteFeature.State()
    var openActionSelection: OpenWorktreeAction = .finder
    var selectedRunScript: String = ""
    var selectedCustomCommands: [UserCustomCommand] = []
    var resolvedKeybindings: ResolvedKeybindingMap = .appDefaults
    var runScriptDraft: String = ""
    var isRunScriptPromptPresented = false
    var runScriptStatusByWorktreeID: [Worktree.ID: Bool] = [:]
    var notificationIndicatorCount: Int = 0
    var lastKnownSystemNotificationsEnabled: Bool
    var launchRestoreMode: LaunchRestoreMode
    var hasAppliedInitialViewMode = false
    var suppressLayoutSaveUntilRelaunch = false
    var launchedAt: Date?
    var leftSidebarVisibility: NavigationSplitViewVisibility = .all
    @Presents var alert: AlertState<Alert>?

    init(
      repositories: RepositoriesFeature.State = .init(),
      settings: SettingsFeature.State = .init()
    ) {
      self.repositories = repositories
      self.settings = settings
      lastKnownSystemNotificationsEnabled = settings.systemNotificationsEnabled
      launchRestoreMode = settings.restoreTerminalLayoutOnLaunch ? .restoreLayout : .lastFocusedWorktree
    }
  }

  enum Action {
    case appLaunched
    case scenePhaseChanged(ScenePhase)
    case repositories(RepositoriesFeature.Action)
    case settings(SettingsFeature.Action)
    case updates(UpdatesFeature.Action)
    case commandPalette(CommandPaletteFeature.Action)
    case openActionSelectionChanged(OpenWorktreeAction)
    case worktreeSettingsLoaded(RepositorySettings, worktreeID: Worktree.ID)
    case worktreeUserSettingsLoaded(UserRepositorySettings, worktreeID: Worktree.ID)
    case openSelectedWorktree
    case openWorktree(OpenWorktreeAction)
    case openWorktreeFailed(OpenActionError)
    case requestQuit
    case newTerminal
    case jumpToLatestUnread
    case toggleLeftSidebar
    case showLeftSidebar
    case setLeftSidebarVisibility(NavigationSplitViewVisibility)
    case runScript
    case runCustomCommand(Int)
    case canvasFocusedWorktreeChanged(Worktree.ID?)
    case runScriptDraftChanged(String)
    case runScriptPromptPresented(Bool)
    case saveRunScriptAndRun
    case stopRunScript
    case closeTab
    case closeSurface
    case startSearch
    case searchSelection
    case navigateSearchNext
    case navigateSearchPrevious
    case endSearch
    case systemNotificationsPermissionFailed(errorMessage: String?)
    case systemNotificationTapped(worktreeID: Worktree.ID, surfaceID: UUID)
    case alert(PresentationAction<Alert>)
    case terminalEvent(TerminalClient.Event)
  }

  enum Alert: Equatable {
    case dismiss
    case confirmQuit
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(\.date.now) private var now
  @Dependency(RepositoryPersistenceClient.self) private var repositoryPersistence
  @Dependency(WorkspaceClient.self) private var workspaceClient
  @Dependency(SettingsWindowClient.self) private var settingsWindowClient
  @Dependency(AppLifecycleClient.self) private var appLifecycleClient
  @Dependency(NotificationSoundClient.self) private var notificationSoundClient
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient
  @Dependency(DockClient.self) private var dockClient
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(WorktreeInfoWatcherClient.self) private var worktreeInfoWatcher
  @Dependency(CustomShortcutRegistryClient.self) private var customShortcutRegistryClient

  private func appQuitProperties(launchedAt: Date?) -> [String: Any]? {
    guard let seconds = Self.sessionDurationSeconds(launchedAt: launchedAt, now: now) else { return nil }
    return ["session_duration_seconds": seconds]
  }

  private func restoreCommandPaletteTerminalFocusEffect(repositories: RepositoriesFeature.State) -> Effect<Action> {
    guard let worktree = commandPaletteTerminalFocusTarget(repositories: repositories) else { return .none }
    return .run { _ in
      await terminalClient.send(.focusSelectedTab(worktree))
    }
  }

  /// Delegate actions that intentionally shift focus elsewhere (selection
  /// changes, view changes that swap the focused terminal). These skip the
  /// post-delegate focus restore so we don't fight the natural new focus.
  private static func commandPaletteDelegateChangesActiveSelection(
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

  private func commandPaletteTerminalFocusTarget(repositories: RepositoriesFeature.State) -> Worktree? {
    if let worktree = repositories.selectedTerminalWorktree {
      return worktree
    }
    return canvasFocusedTerminalWorktree(repositories: repositories)
  }

  private func actionTargetWorktree(repositories: RepositoriesFeature.State) -> Worktree? {
    if let worktree = repositories.selectedTerminalWorktree {
      return worktree
    }
    return canvasFocusedTerminalWorktree(repositories: repositories)
  }

  private func canvasFocusedTerminalWorktree(repositories: RepositoriesFeature.State) -> Worktree? {
    guard repositories.isShowingCanvas,
      let worktreeID = terminalClient.canvasFocusedWorktreeID()
    else {
      return nil
    }
    return terminalWorktree(for: worktreeID, repositories: repositories)
  }

  private func terminalWorktree(
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

  private func resolvedKeybindings(
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
  private func applyWorktreeSettings(_ settings: RepositorySettings, into state: inout State) {
    @Shared(.settingsFile) var settingsFile
    let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(
      settingsFile.global.defaultEditorID
    )
    state.openActionSelection = OpenWorktreeAction.fromSettingsID(
      settings.openActionID,
      defaultEditorID: normalizedDefaultEditorID
    )
    state.selectedRunScript = settings.runScript
  }

  /// Applies a worktree's user settings (custom commands, keybindings) into
  /// state and returns the effect that re-registers custom shortcuts. Shared by
  /// the normal `worktreeUserSettingsLoaded` action and the Canvas focus path.
  private func applyWorktreeUserSettings(
    _ settings: UserRepositorySettings,
    into state: inout State
  ) -> Effect<Action> {
    state.selectedCustomCommands = UserRepositorySettings.normalizedCommands(settings.customCommands)
    state.resolvedKeybindings = resolvedKeybindings(
      settings: state.settings,
      customCommands: state.selectedCustomCommands
    )
    let userOverrideConflicts = AppShortcuts.userOverrideConflicts(in: state.selectedCustomCommands)
    let shortcuts: [UserCustomShortcut] = state.selectedCustomCommands.compactMap { command in
      let commandID = LegacyCustomCommandShortcutMigration.customCommandBindingID(for: command.id)
      return state.resolvedKeybindings.keybinding(for: commandID)?.userCustomShortcut
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

  private func applyDefaultViewMode(into state: inout State) -> Effect<Action> {
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

  private func defaultViewFallbackSelectionID(in repositories: RepositoriesFeature.State) -> Worktree.ID? {
    let candidateIDs =
      [repositories.lastFocusedWorktreeID].compactMap(\.self)
      + repositories.orderedWorktreeRows().map(\.id)
    return candidateIDs.first { id in
      repositories.worktree(for: id) != nil
        || repositories.repositories[id: id]?.kind == .plain
    }
  }

  private func defaultViewSelectionEffect(
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

  var body: some Reducer<State, Action> {
    let core = Reduce<State, Action> { state, action in
      switch action {
      case .appLaunched:
        try? SupacodePaths.migrateLegacyCacheFilesIfNeeded()
        appLogger.info("[LayoutRestore] appLaunched: launchRestoreMode=\(String(describing: state.launchRestoreMode))")
        state.launchedAt = now
        state.repositories.launchRestoreMode = state.launchRestoreMode
        let agentDetectionEnabled = ActiveAgentsFeature.detectionEnabled(
          isPanelHidden: state.repositories.activeAgents.isPanelHidden,
          autoShowPanel: state.settings.autoShowActiveAgentsPanel
        )
        analyticsClient.capture("app_launched", nil)
        return .merge(
          .send(.repositories(.task)),
          .send(.settings(.task)),
          .send(.updates(.task)),
          .run { _ in
            await terminalClient.send(.setAgentDetectionEnabled(agentDetectionEnabled))
          },
          .run { _ in
            await dockClient.setNotificationBadge(0)
          },
          .run { send in
            for await event in await terminalClient.events() {
              await send(.terminalEvent(event))
            }
          },
          .run { send in
            for await event in await worktreeInfoWatcher.events() {
              await send(.repositories(.worktreeInfoEvent(event)))
            }
          }
        )

      case .scenePhaseChanged(let phase):
        switch phase {
        case .active:
          return .merge(
            .send(.repositories(.refreshWorktrees)),
            .run { _ in
              await worktreeInfoWatcher.send(.refreshLineChanges)
            },
            .run { send in
              while !Task.isCancelled {
                try? await ContinuousClock().sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await send(.repositories(.refreshWorktrees))
              }
            }
            .cancellable(id: CancelID.periodicRefresh, cancelInFlight: true)
          )
        case .inactive, .background:
          var effects: [Effect<Action>] = [.cancel(id: CancelID.periodicRefresh)]
          if state.settings.restoreTerminalLayoutOnLaunch, !state.suppressLayoutSaveUntilRelaunch {
            appLogger.info("[LayoutRestore] scenePhase=\(String(describing: phase)), saving layout snapshot")
            effects.append(.run { _ in await terminalClient.send(.saveLayoutSnapshot) })
          }
          return .merge(effects)
        @unknown default:
          return .cancel(id: CancelID.periodicRefresh)
        }

      case .repositories(.delegate(.selectedWorktreeChanged(let worktree))):
        let lastFocusedWorktreeID = state.repositories.selectedWorktreeID
        let repositoryPersistence = repositoryPersistence
        let isPlainFolderSelection =
          state.repositories.selectedRepository?.capabilities.supportsRunnableFolderActions == true
          && state.repositories.selectedRepository?.capabilities.supportsWorktrees == false
        guard let worktree else {
          state.openActionSelection = .finder
          state.selectedRunScript = ""
          state.selectedCustomCommands = []
          state.resolvedKeybindings = resolvedKeybindings(
            settings: state.settings,
            customCommands: state.selectedCustomCommands
          )
          state.runScriptDraft = ""
          state.isRunScriptPromptPresented = false
          var effects: [Effect<Action>] = [
            .run { _ in
              await terminalClient.send(.setSelectedWorktreeID(nil))
            },
            .run { _ in
              await worktreeInfoWatcher.send(.setSelectedWorktreeID(nil))
            },
          ]
          if !state.repositories.isShowingArchivedWorktrees, !state.repositories.isShowingCanvas {
            effects.insert(
              .run { _ in
                await repositoryPersistence.saveLastFocusedWorktreeID(lastFocusedWorktreeID)
              },
              at: 0
            )
          }
          return .merge(
            .merge(effects),
            .run { _ in
              await customShortcutRegistryClient.setShortcuts([])
            }
          )
        }
        let rootURL = worktree.repositoryRootURL
        let worktreeID = worktree.id
        state.selectedCustomCommands = []
        state.resolvedKeybindings = resolvedKeybindings(
          settings: state.settings,
          customCommands: state.selectedCustomCommands
        )
        state.runScriptDraft = ""
        state.isRunScriptPromptPresented = false
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        @Shared(.userRepositorySettings(rootURL)) var userRepositorySettings
        let settings = repositorySettings
        let userSettings = userRepositorySettings
        var effects: [Effect<Action>] = []
        if !isPlainFolderSelection {
          effects.append(
            .run { _ in
              await repositoryPersistence.saveLastFocusedWorktreeID(lastFocusedWorktreeID)
            }
          )
        }
        effects.append(
          .run { _ in
            await terminalClient.send(.setSelectedWorktreeID(worktree.id))
          }
        )
        effects.append(
          .run { _ in
            await worktreeInfoWatcher.send(.setSelectedWorktreeID(isPlainFolderSelection ? nil : worktree.id))
          }
        )
        effects.append(
          .run { _ in
            await customShortcutRegistryClient.setShortcuts([])
          }
        )
        effects.append(
          .concatenate(
            .send(.worktreeSettingsLoaded(settings, worktreeID: worktreeID)),
            .send(.worktreeUserSettingsLoaded(userSettings, worktreeID: worktreeID))
          )
        )
        return .merge(effects)

      case .repositories(.delegate(.worktreeCreated(let worktree))):
        let shouldRunSetupScript =
          state.repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id)
        return .run { _ in
          await terminalClient.send(
            .ensureInitialTab(
              worktree,
              runSetupScriptIfNew: shouldRunSetupScript,
              focusing: false
            )
          )
        }

      case .repositories(.delegate(.repositoriesChanged(let repositories))):
        let archivedIDs = state.repositories.archivedWorktreeIDSet
        let ids = state.repositories.terminalStateIDs.subtracting(archivedIDs)
        let recencyIDs = CommandPaletteFeature.recencyRetentionIDs(
          from: repositories,
          customCommands: state.selectedCustomCommands
        )
        let worktrees = state.repositories.worktreesForInfoWatcher()
        let openedWorktreeIDs = openedWorktreeIDsForInfoWatcher(from: state.repositories)
        let shouldRestoreLayout =
          state.launchRestoreMode == .restoreLayout
          && state.repositories.snapshotPersistencePhase == .active
        let shouldDeferDefaultView = state.launchRestoreMode == .restoreLayout
        appLogger.info(
          "[LayoutRestore] repositoriesChanged: mode=\(String(describing: state.launchRestoreMode))"
            + " phase=\(String(describing: state.repositories.snapshotPersistencePhase))"
            + " → shouldRestore=\(shouldRestoreLayout)"
        )
        if shouldRestoreLayout {
          state.launchRestoreMode = .lastFocusedWorktree
          state.repositories.selection = nil
        }
        state.runScriptStatusByWorktreeID = state.runScriptStatusByWorktreeID.filter { ids.contains($0.key) }
        let restorableWorktrees = makeTerminalRestorableWorktrees(from: Array(repositories))
        appLogger.info("[LayoutRestore] restorableWorktrees count=\(restorableWorktrees.count)")
        var allEffects: [Effect<Action>] = []
        if !shouldDeferDefaultView {
          allEffects.append(applyDefaultViewMode(into: &state))
        }
        if case .repository(let repositoryID)? = state.settings.selection,
          !repositories.contains(where: { $0.id == repositoryID })
        {
          var effects: [Effect<Action>] = [
            .send(.settings(.setSelection(.general))),
            .send(.commandPalette(.pruneRecency(recencyIDs))),
            .send(.repositories(.refreshAllCustomTitles)),
            .run { _ in
              await terminalClient.send(.prune(ids))
            },
            .run { _ in
              await worktreeInfoWatcher.send(.setWorktrees(worktrees))
            },
            .run { _ in
              await worktreeInfoWatcher.send(.setOpenedWorktreeIDs(openedWorktreeIDs))
            },
          ]
          if shouldRestoreLayout {
            effects.append(
              .run { _ in
                await terminalClient.send(.restoreLayoutSnapshot(worktrees: restorableWorktrees))
              }
            )
          }
          allEffects.append(.merge(effects))
          return .merge(allEffects)
        }
        var effects: [Effect<Action>] = [
          .send(.commandPalette(.pruneRecency(recencyIDs))),
          .send(.repositories(.refreshAllCustomTitles)),
          .run { _ in
            await terminalClient.send(.prune(ids))
          },
          .run { _ in
            await worktreeInfoWatcher.send(.setWorktrees(worktrees))
          },
          .run { _ in
            await worktreeInfoWatcher.send(.setOpenedWorktreeIDs(openedWorktreeIDs))
          },
        ]
        if shouldRestoreLayout {
          effects.append(
            .run { _ in
              await terminalClient.send(.restoreLayoutSnapshot(worktrees: restorableWorktrees))
            }
          )
        }
        allEffects.append(.merge(effects))
        return .merge(allEffects)

      case .repositories(.delegate(.openRepositorySettings(let repositoryID))):
        guard state.repositories.repositories.contains(where: { $0.id == repositoryID }) else {
          return .none
        }
        let selection = SettingsSection.repository(repositoryID)
        return .merge(
          .send(.settings(.setSelection(selection))),
          .run { _ in
            await settingsWindowClient.show()
          }
        )

      case .settings(.setSelection(let selection)):
        let resolvedSelection = selection ?? .general
        switch resolvedSelection {
        case .repository(let repositoryID):
          guard let repository = state.repositories.repositories[id: repositoryID] else {
            state.settings.repositorySettings = nil
            return .none
          }
          @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
          @Shared(.userRepositorySettings(repository.rootURL)) var userRepositorySettings
          @Shared(.repositoryAppearances) var repositoryAppearances
          var repoSettingsState = RepositorySettingsFeature.State(
            rootURL: repository.rootURL,
            repositoryID: repository.id,
            repositoryKind: repository.kind,
            settings: repositorySettings,
            userSettings: userRepositorySettings,
            appearance: repositoryAppearances[repository.id] ?? .empty
          )
          repoSettingsState.globalCopyIgnoredOnWorktreeCreate = state.settings.copyIgnoredOnWorktreeCreate
          repoSettingsState.globalCopyUntrackedOnWorktreeCreate = state.settings.copyUntrackedOnWorktreeCreate
          repoSettingsState.globalPullRequestMergeStrategy = state.settings.pullRequestMergeStrategy
          state.settings.repositorySettings = repoSettingsState
        case .general, .notifications, .shortcuts, .worktree, .updates, .advanced, .github:
          state.settings.repositorySettings = nil
        }
        return .none

      case .settings(.delegate(.settingsChanged(let settings))):
        let shouldCheckSystemNotificationPermission =
          settings.systemNotificationsEnabled && !state.lastKnownSystemNotificationsEnabled
        state.lastKnownSystemNotificationsEnabled = settings.systemNotificationsEnabled
        state.settings.keybindingUserOverrides = settings.keybindingUserOverrides
        let agentDetectionEnabled = ActiveAgentsFeature.detectionEnabled(
          isPanelHidden: state.repositories.activeAgents.isPanelHidden,
          autoShowPanel: settings.autoShowActiveAgentsPanel
        )
        if let selectedWorktree = state.repositories.selectedTerminalWorktree {
          let rootURL = selectedWorktree.repositoryRootURL
          @Shared(.repositorySettings(rootURL)) var repositorySettings
          state.openActionSelection = OpenWorktreeAction.fromSettingsID(
            repositorySettings.openActionID,
            defaultEditorID: settings.defaultEditorID
          )
        }
        state.resolvedKeybindings = resolvedKeybindings(
          settings: state.settings,
          customCommands: state.selectedCustomCommands
        )
        let badgeCount = settings.showNotificationDotOnDock ? state.notificationIndicatorCount : 0
        return .merge(
          .send(.repositories(.githubIntegration(.setGithubIntegrationEnabled(settings.githubIntegrationEnabled)))),
          .send(
            .repositories(
              .githubIntegration(
                .setMergedWorktreeAction(
                  settings.mergedWorktreeAction
                )
              )
            )
          ),
          .send(
            .repositories(
              .setArchivedAutoDeletePeriod(
                settings.archivedAutoDeletePeriod
              )
            )
          ),
          .send(
            .repositories(
              .worktreeOrdering(
                .setMoveNotifiedWorktreeToTop(
                  settings.moveNotifiedWorktreeToTop
                )
              )
            )
          ),
          .send(
            .updates(
              .applySettings(
                updateChannel: settings.updateChannel,
                automaticallyChecks: settings.updatesAutomaticallyCheckForUpdates,
                automaticallyDownloads: settings.updatesAutomaticallyDownloadUpdates
              )
            )
          ),
          .run { _ in
            await terminalClient.send(.setNotificationsEnabled(settings.inAppNotificationsEnabled))
          },
          .run { _ in
            await terminalClient.send(
              .setCommandFinishedNotification(
                enabled: settings.commandFinishedNotificationEnabled,
                threshold: settings.commandFinishedNotificationThreshold
              )
            )
          },
          .run { _ in
            await terminalClient.send(.setAgentDetectionEnabled(agentDetectionEnabled))
          },
          .run { _ in
            await worktreeInfoWatcher.send(
              .setPullRequestTrackingEnabled(settings.githubIntegrationEnabled)
            )
          },
          .run { send in
            guard shouldCheckSystemNotificationPermission else { return }
            let status = await systemNotificationClient.authorizationStatus()
            switch status {
            case .authorized:
              return
            case .notDetermined:
              let result = await systemNotificationClient.requestAuthorization()
              if !result.granted {
                await send(
                  .systemNotificationsPermissionFailed(errorMessage: result.errorMessage)
                )
              }
            case .denied:
              await send(.systemNotificationsPermissionFailed(errorMessage: "Authorization status is denied."))
            }
          },
          .run { _ in
            await dockClient.setNotificationBadge(badgeCount)
          }
        )

      case .settings(.delegate(.terminalFontSizeChanged)):
        return .none

      case .settings(.delegate(.cliInstallCompleted(let result))):
        switch result {
        case .installed(let path):
          return .send(.repositories(.showToast(.success("prowl installed at \(path)"))))
        case .uninstalled:
          return .send(.repositories(.showToast(.success("prowl command line tool removed"))))
        case .failed(let message):
          return .send(.repositories(.showToast(.warning("CLI install failed: \(message)"))))
        }

      case .settings(.delegate(.terminalLayoutSnapshotCleared(let success))):
        if success {
          state.suppressLayoutSaveUntilRelaunch = true
          return .send(.repositories(.showToast(.success("Saved terminal layout cleared"))))
        }
        return .send(
          .repositories(
            .presentAlert(
              title: "Unable to clear saved terminal layout",
              message: "Please check file permissions and try again."
            )
          )
        )

      case .openActionSelectionChanged(let action):
        state.openActionSelection = action
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        let rootURL = worktree.repositoryRootURL
        let actionID = action.settingsID
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0.openActionID = actionID }
        return .none

      case .openSelectedWorktree:
        return .send(.openWorktree(OpenWorktreeAction.availableSelection(state.openActionSelection)))

      case .openWorktree(let action):
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        analyticsClient.capture("worktree_opened", ["action": action.settingsID])
        if action == .editor {
          let shouldRunSetupScript =
            state.repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id)
          return .run { _ in
            await terminalClient.send(
              .createTabWithInput(
                worktree,
                input: "$EDITOR",
                runSetupScriptIfNew: shouldRunSetupScript,
                autoCloseOnSuccess: false
              )
            )
          }
        }
        return .run { send in
          await workspaceClient.open(action, worktree) { error in
            send(.openWorktreeFailed(error))
          }
        }

      case .openWorktreeFailed(let error):
        state.alert = AlertState {
          TextState(error.title)
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("OK")
          }
        } message: {
          TextState(error.message)
        }
        return .none

      case .requestQuit:
        guard state.settings.confirmBeforeQuit else {
          analyticsClient.capture("app_quit", appQuitProperties(launchedAt: state.launchedAt))
          return .run { @MainActor _ in
            appLifecycleClient.terminate()
          }
        }
        _ = appLifecycleClient.surfaceMainWindow()
        state.alert = AlertState {
          TextState("Quit Prowl?")
        } actions: {
          ButtonState(action: .confirmQuit) {
            TextState("Quit")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState("This will close all terminal sessions.")
        }
        return .none

      case .newTerminal:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        analyticsClient.capture("terminal_tab_created", nil)
        let shouldRunSetupScript = state.repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id)
        return .run { _ in
          await terminalClient.send(.createTab(worktree, runSetupScriptIfNew: shouldRunSetupScript))
        }

      case .jumpToLatestUnread:
        guard let location = terminalClient.latestUnreadNotification() else {
          notificationJumpLogger.debug("jumpToLatestUnread invoked with no unread notification.")
          return .none
        }
        guard state.repositories.worktree(for: location.worktreeID) != nil else {
          notificationJumpLogger.warning("Unread notification worktree vanished: \(location.worktreeID)")
          return .none
        }
        analyticsClient.capture("notifications_jump_to_latest_unread", nil)
        return .merge(
          .send(.repositories(.selectWorktree(location.worktreeID, focusTerminal: true))),
          .run { _ in
            _ = await terminalClient.focusSurface(location.worktreeID, location.surfaceID)
            await terminalClient.markNotificationRead(location.worktreeID, location.notificationID)
          }
        )

      case .toggleLeftSidebar:
        state.leftSidebarVisibility = state.leftSidebarVisibility == .detailOnly ? .all : .detailOnly
        return .none

      case .showLeftSidebar:
        state.leftSidebarVisibility = .all
        return .none

      case .setLeftSidebarVisibility(let visibility):
        state.leftSidebarVisibility = visibility
        return .none

      case .runScript:
        guard let worktree = actionTargetWorktree(repositories: state.repositories) else {
          return .none
        }
        let trimmed = state.selectedRunScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          if state.isRunScriptPromptPresented {
            return .none
          }
          state.runScriptDraft = state.selectedRunScript
          state.isRunScriptPromptPresented = true
          return .none
        }
        analyticsClient.capture("script_run", nil)
        let script = state.selectedRunScript
        return .run { _ in
          await terminalClient.send(.runScript(worktree, script: script))
        }

      case .runCustomCommand(let index):
        guard let worktree = actionTargetWorktree(repositories: state.repositories) else {
          return .none
        }
        guard state.selectedCustomCommands.indices.contains(index) else {
          return .none
        }
        let customCommand = state.selectedCustomCommands[index]
        guard customCommand.hasRunnableCommand else {
          return .none
        }
        let command = customCommand.command
        let closeOnSuccess = customCommand.closeOnSuccess
        let commandName = customCommand.resolvedTitle
        // Treat the model's "terminal" placeholder (and an empty value)
        // as "no icon configured", so the auto-detector can still brand
        // the tab from the command itself. Anything else is a deliberate
        // user pick and gets pinned for the duration of the run.
        let commandIcon: String? = {
          let trimmed = customCommand.systemImage.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty, trimmed != "terminal" else { return nil }
          return trimmed
        }()
        switch customCommand.execution {
        case .shellScript:
          return .run { _ in
            await terminalClient.send(
              .createTabWithInput(
                worktree,
                input: command,
                runSetupScriptIfNew: false,
                autoCloseOnSuccess: closeOnSuccess,
                customCommandName: commandName,
                customCommandIcon: commandIcon
              )
            )
          }
        case .split:
          let direction = customCommand.splitDirection
          return .run { _ in
            await terminalClient.send(
              .createSplitWithInput(
                worktree,
                direction: direction,
                input: command,
                autoCloseOnSuccess: closeOnSuccess,
                customCommandName: commandName,
                customCommandIcon: commandIcon
              )
            )
          }
        case .terminalInput:
          return .run { _ in
            await terminalClient.send(.insertText(worktree, text: command))
          }
        }

      case .canvasFocusedWorktreeChanged(let worktreeID):
        guard state.repositories.isShowingCanvas,
          let worktreeID,
          let worktree = terminalWorktree(for: worktreeID, repositories: state.repositories)
        else {
          state.openActionSelection = .finder
          state.selectedRunScript = ""
          state.selectedCustomCommands = []
          state.resolvedKeybindings = resolvedKeybindings(
            settings: state.settings,
            customCommands: state.selectedCustomCommands
          )
          state.runScriptDraft = ""
          state.isRunScriptPromptPresented = false
          return .run { _ in
            await customShortcutRegistryClient.setShortcuts([])
          }
        }
        let rootURL = worktree.repositoryRootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        @Shared(.userRepositorySettings(rootURL)) var userRepositorySettings
        // Apply both settings in this single reduce pass instead of dispatching
        // follow-up `.send`s. The Canvas focus ID (an `@Observable` on the
        // terminal manager) updates synchronously on card tap, so the toolbar's
        // Run + Custom Command items must update in the same transaction —
        // otherwise the command list lands a frame later and the toolbar
        // visibly reflows when switching between cards with different commands.
        applyWorktreeSettings(repositorySettings, into: &state)
        return applyWorktreeUserSettings(userRepositorySettings, into: &state)

      case .runScriptDraftChanged(let script):
        state.runScriptDraft = script
        return .none

      case .runScriptPromptPresented(let isPresented):
        state.isRunScriptPromptPresented = isPresented
        if !isPresented {
          state.runScriptDraft = ""
        }
        return .none

      case .saveRunScriptAndRun:
        guard let worktree = actionTargetWorktree(repositories: state.repositories) else {
          state.isRunScriptPromptPresented = false
          state.runScriptDraft = ""
          return .none
        }
        let script = state.runScriptDraft
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          return .none
        }
        let rootURL = worktree.repositoryRootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0.runScript = script }
        if state.settings.repositorySettings?.rootURL == rootURL {
          state.settings.repositorySettings?.settings.runScript = script
        }
        state.selectedRunScript = script
        state.isRunScriptPromptPresented = false
        state.runScriptDraft = ""
        return .send(.runScript)

      case .stopRunScript:
        guard let worktree = actionTargetWorktree(repositories: state.repositories) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.stopRunScript(worktree))
        }

      case .closeTab:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        analyticsClient.capture("terminal_tab_closed", nil)
        return .run { _ in
          await terminalClient.send(.closeFocusedTab(worktree))
        }

      case .closeSurface:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.closeFocusedSurface(worktree))
        }

      case .startSearch:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.startSearch(worktree))
        }

      case .searchSelection:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.searchSelection(worktree))
        }

      case .navigateSearchNext:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.navigateSearchNext(worktree))
        }

      case .navigateSearchPrevious:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.navigateSearchPrevious(worktree))
        }

      case .endSearch:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.endSearch(worktree))
        }

      case .settings(.repositorySettings(.delegate(.settingsChanged(let rootURL)))):
        // Always refresh the repo's custom title cache — display sites
        // (sidebar, shelf, canvas, toolbar, settings list) read it from
        // `RepositoriesFeature.State.repositoryCustomTitles` rather
        // than subscribing to the per-repo settings file directly.
        let refreshCustomTitle = Effect<Action>.send(.repositories(.refreshCustomTitle(rootURL)))
        guard let selectedWorktree = state.repositories.selectedTerminalWorktree,
          selectedWorktree.repositoryRootURL == rootURL
        else {
          return refreshCustomTitle
        }
        let worktreeID = selectedWorktree.id
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        @Shared(.userRepositorySettings(rootURL)) var userRepositorySettings
        return .concatenate(
          refreshCustomTitle,
          .send(.worktreeSettingsLoaded(repositorySettings, worktreeID: worktreeID)),
          .send(.worktreeUserSettingsLoaded(userRepositorySettings, worktreeID: worktreeID))
        )

      case .worktreeSettingsLoaded(let settings, let worktreeID):
        guard actionTargetWorktree(repositories: state.repositories)?.id == worktreeID else {
          return .none
        }
        applyWorktreeSettings(settings, into: &state)
        return .none

      case .worktreeUserSettingsLoaded(let settings, let worktreeID):
        guard actionTargetWorktree(repositories: state.repositories)?.id == worktreeID else {
          return .none
        }
        return applyWorktreeUserSettings(settings, into: &state)

      case .systemNotificationsPermissionFailed(let errorMessage):
        return .concatenate(
          .send(.settings(.setSystemNotificationsEnabled(false))),
          .send(.settings(.showNotificationPermissionAlert(errorMessage: errorMessage)))
        )

      case .systemNotificationTapped(let worktreeID, let surfaceID):
        guard state.repositories.worktree(for: worktreeID) != nil else {
          notificationJumpLogger.warning("Tapped notification worktree vanished: \(worktreeID)")
          return .none
        }
        return .merge(
          .send(.repositories(.selectWorktree(worktreeID, focusTerminal: true))),
          .run { _ in
            _ = await terminalClient.focusSurface(worktreeID, surfaceID)
            await terminalClient.markNotificationsReadForSurface(worktreeID, surfaceID)
          }
        )

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .alert(.presented(.confirmQuit)):
        analyticsClient.capture("app_quit", appQuitProperties(launchedAt: state.launchedAt))
        state.alert = nil
        return .run { @MainActor _ in
          appLifecycleClient.terminate()
        }

      case .alert:
        return .none

      case .repositories(.activeAgents(.togglePanelVisibility)):
        let nextIsPanelHidden = !state.repositories.activeAgents.isPanelHidden
        let agentDetectionEnabled = ActiveAgentsFeature.detectionEnabled(
          isPanelHidden: nextIsPanelHidden,
          autoShowPanel: state.settings.autoShowActiveAgentsPanel
        )
        return .run { _ in
          await terminalClient.send(.setAgentDetectionEnabled(agentDetectionEnabled))
        }

      case .repositories:
        return .none

      case .settings:
        return .none

      case .updates:
        return .none

      case .commandPalette(.setPresented(false)):
        guard state.commandPalette.isPresented else { return .none }
        return restoreCommandPaletteTerminalFocusEffect(repositories: state.repositories)

      case .commandPalette(.togglePresented):
        guard state.commandPalette.isPresented else { return .none }
        return restoreCommandPaletteTerminalFocusEffect(repositories: state.repositories)

      case .commandPalette(.delegate(.selectWorktree(let worktreeID))):
        return .send(.repositories(.selectWorktree(worktreeID)))

      case .commandPalette(.delegate(.checkForUpdates)):
        return .send(.updates(.checkForUpdates))

      case .commandPalette(.delegate(.openSettings)):
        return .merge(
          .send(.settings(.setSelection(.general))),
          .run { _ in
            await settingsWindowClient.show()
          }
        )

      case .commandPalette(.delegate(.newWorktree)):
        return .send(.repositories(.worktreeCreation(.createRandomWorktree)))

      case .commandPalette(.delegate(.openRepository)):
        return .send(.repositories(.setOpenPanelPresented(true)))

      case .commandPalette(.delegate(.deleteWorktree(let worktreeID, let repositoryID))):
        return .send(.repositories(.worktreeLifecycle(.requestDeleteWorktree(worktreeID, repositoryID))))

      case .commandPalette(.delegate(.viewArchivedWorktrees)):
        return .send(.repositories(.selectArchivedWorktrees))

      case .commandPalette(.delegate(.refreshWorktrees)):
        return .send(.repositories(.refreshWorktrees))

      case .commandPalette(.delegate(.jumpToLatestUnread)):
        return .send(.jumpToLatestUnread)

      case .commandPalette(.delegate(.installCLI)):
        return .send(.settings(.installCLIButtonTapped(showAlert: false)))

      case .commandPalette(.delegate(.toggleLeftSidebar)):
        return .send(.toggleLeftSidebar)

      case .commandPalette(.delegate(.toggleActiveAgentsPanel)):
        return .send(.repositories(.activeAgents(.togglePanelVisibility)))

      case .commandPalette(.delegate(.toggleCanvas)):
        return .send(.repositories(.toggleCanvas))

      case .commandPalette(.delegate(.toggleShelf)):
        return .send(.repositories(.toggleShelf))

      case .commandPalette(.delegate(.showDiff)):
        guard let worktreeID = state.repositories.selectedWorktreeID,
          let worktree = state.repositories.worktree(for: worktreeID)
        else {
          return .none
        }
        let keybindings = state.resolvedKeybindings
        return .run { _ in
          await MainActor.run {
            DiffWindowManager.shared.show(
              worktreeURL: worktree.workingDirectory,
              branchName: worktree.name,
              resolvedKeybindings: keybindings
            )
          }
        }

      case .commandPalette(.delegate(.revealInFinder)):
        return .send(.openWorktree(.finder))

      case .commandPalette(.delegate(.copyPath)):
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        let path = worktree.workingDirectory.path
        return .run { _ in
          await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
          }
        }

      case .commandPalette(.delegate(.revealInSidebar)):
        guard state.repositories.selectedWorktreeID != nil else { return .none }
        return .merge(
          .send(.showLeftSidebar),
          .send(.repositories(.revealSelectedWorktreeInSidebar))
        )

      case .commandPalette(.delegate(.runScript)):
        return .send(.runScript)

      case .commandPalette(.delegate(.stopRunScript)):
        return .send(.stopRunScript)

      case .commandPalette(.delegate(.renameBranch)):
        guard let worktreeID = state.repositories.selectedWorktreeID else { return .none }
        return .send(.repositories(.requestRenameBranchPrompt(worktreeID)))

      case .commandPalette(.delegate(.openRepositorySettings(let repositoryID))):
        // Reuse the existing repo-side flow so the repo-existence guard and
        // settingsWindowClient.show() live in one place
        // (.repositories(.delegate(.openRepositorySettings(_))) at line ~441).
        return .send(.repositories(.repositoryManagement(.openRepositorySettings(repositoryID))))

      case .commandPalette(.delegate(.togglePinWorktree(let worktreeID, let isCurrentlyPinned))):
        if isCurrentlyPinned {
          return .send(.repositories(.worktreeOrdering(.unpinWorktree(worktreeID))))
        }
        return .send(.repositories(.worktreeOrdering(.pinWorktree(worktreeID))))

      case .commandPalette(.delegate(.runCustomCommand(let index))):
        return .send(.runCustomCommand(index))

      case .commandPalette(.delegate(.ghosttyCommand(let action))):
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.performBindingAction(worktree, action: action))
        }

      case .commandPalette(.delegate(.changeFocusedTabIcon(let worktreeID))):
        guard let worktree = state.repositories.selectedTerminalWorktree,
          worktree.id == worktreeID
        else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.presentTabIconPicker(worktree))
        }

      case .commandPalette(.delegate(.openPullRequest(let worktreeID))):
        return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .openOnCodeHost))))

      case .commandPalette(.delegate(.markPullRequestReady(let worktreeID))):
        return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .markReadyForReview))))

      case .commandPalette(.delegate(.mergePullRequest(let worktreeID))):
        return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .merge))))

      case .commandPalette(.delegate(.closePullRequest(let worktreeID))):
        return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .close))))

      case .commandPalette(.delegate(.copyFailingJobURL(let worktreeID))):
        return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .copyFailingJobURL))))

      case .commandPalette(.delegate(.copyCiFailureLogs(let worktreeID))):
        return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .copyCiFailureLogs))))

      case .commandPalette(.delegate(.rerunFailedJobs(let worktreeID))):
        return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .rerunFailedJobs))))

      case .commandPalette(.delegate(.openFailingCheckDetails(let worktreeID))):
        return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .openFailingCheckDetails))))

      #if DEBUG
        case .commandPalette(.delegate(.debugTestToast(let toast))):
          return .send(.repositories(.showToast(toast)))

        case .commandPalette(.delegate(.debugSimulateUpdateFound)):
          return .send(.updates(.debugSimulateUpdateFound))

        case .commandPalette(.delegate(.debugLightDockNotificationDot)):
          return .run { _ in await dockClient.setNotificationBadge(1) }
      #endif

      case .commandPalette:
        return .none

      case .terminalEvent(.customCommandSucceeded(_, let name, let durationMs)):
        let message = "\(name) succeeded in \(formatCustomCommandDuration(durationMs))"
        return .send(.repositories(.showToast(.success(message))))

      case .terminalEvent(.notificationReceived(let worktreeID, let surfaceID, let title, let body)):
        var effects: [Effect<Action>] = [
          .send(.repositories(.worktreeOrdering(.worktreeNotificationReceived(worktreeID))))
        ]
        if state.settings.systemNotificationsEnabled {
          effects.append(
            .run { _ in
              await systemNotificationClient.send(title, body, worktreeID, surfaceID)
            }
          )
        }
        if state.settings.notificationSoundEnabled && !state.settings.systemNotificationsEnabled {
          effects.append(
            .run { _ in
              await notificationSoundClient.play()
            }
          )
        }
        let bounceMode = state.settings.dockBounceMode
        if bounceMode != .off {
          effects.append(
            .run { _ in
              await dockClient.bounce(bounceMode)
            }
          )
        }
        return .merge(effects)

      case .terminalEvent(.notificationIndicatorChanged(let count)):
        state.notificationIndicatorCount = count
        let badgeCount = state.settings.showNotificationDotOnDock ? count : 0
        return .run { _ in
          await dockClient.setNotificationBadge(badgeCount)
        }

      case .terminalEvent(.runScriptStatusChanged(let worktreeID, let isRunning)):
        if isRunning {
          state.runScriptStatusByWorktreeID[worktreeID] = true
        } else {
          state.runScriptStatusByWorktreeID.removeValue(forKey: worktreeID)
        }
        return .none

      case .terminalEvent(.agentEntryChanged(let entry)):
        return .send(
          .repositories(
            .activeAgents(
              .agentEntryChanged(entry, autoShowPanel: state.settings.autoShowActiveAgentsPanel)
            )
          )
        )

      case .terminalEvent(.agentEntryRemoved(let id)):
        return .send(.repositories(.activeAgents(.agentEntryRemoved(id))))

      case .terminalEvent(.commandPaletteToggleRequested(let worktreeID)):
        if state.commandPalette.isPresented {
          return .send(.commandPalette(.setPresented(false)))
        }
        if state.repositories.worktree(for: worktreeID) != nil {
          return .merge(
            .send(.repositories(.selectWorktree(worktreeID))),
            .send(.commandPalette(.setPresented(true)))
          )
        }
        if state.repositories.repositories[id: worktreeID]?.kind == .plain {
          return .merge(
            .send(.repositories(.selectRepository(worktreeID))),
            .send(.commandPalette(.setPresented(true)))
          )
        }
        return .send(.commandPalette(.setPresented(true)))
      case .terminalEvent(.setupScriptConsumed(let worktreeID)):
        return .send(.repositories(.worktreeCreation(.consumeSetupScript(worktreeID))))

      case .terminalEvent(.fontSizeChanged(let fontSize)):
        return .send(.settings(.setTerminalFontSize(fontSize)))

      case .terminalEvent(.layoutRestored(let selectedWorktreeID)):
        appLogger.info("[LayoutRestore] layoutRestored: selectedWorktreeID=\(selectedWorktreeID ?? "nil")")
        // Layout restore has settled: tabs are re-created, selection is set.
        // Now apply the default view preference, which was deferred in
        // `repositoriesChanged` (via `shouldDeferDefaultView`) to avoid
        // stray spines and a selection flash.
        var effects: [Effect<Action>] = []
        if let selectedWorktreeID {
          // Plain folders use .repository selection, not .worktree
          if let repo = state.repositories.repositories[id: selectedWorktreeID],
            repo.kind == .plain
          {
            effects.append(.send(.repositories(.selectRepository(selectedWorktreeID))))
          } else {
            effects.append(.send(.repositories(.selectWorktree(selectedWorktreeID))))
          }
        }
        return .concatenate([.merge(effects), applyDefaultViewMode(into: &state)])

      case .terminalEvent(.layoutRestoreFailed(let message)):
        appLogger.warning("[LayoutRestore] layoutRestoreFailed: \(message)")
        return .merge(
          .send(.repositories(.showToast(.warning(message)))),
          applyDefaultViewMode(into: &state)
        )

      case .terminalEvent(.tabCreated(let worktreeID)):
        // Every tab creation (user +, CLI open, layout restore, …)
        // marks its worktree as Shelf-visible. Layout restore in
        // particular only calls `selectWorktree` for the one active
        // worktree; other restored worktrees only surface here.
        var openedWorktreeIDs = openedWorktreeIDsForInfoWatcher(from: state.repositories)
        if state.repositories.worktree(for: worktreeID) != nil {
          openedWorktreeIDs.insert(worktreeID)
        }
        let syncedOpenedWorktreeIDs = openedWorktreeIDs
        return .merge(
          .send(.repositories(.markWorktreeOpened(worktreeID))),
          .run { _ in
            await worktreeInfoWatcher.send(.setOpenedWorktreeIDs(syncedOpenedWorktreeIDs))
          }
        )

      case .terminalEvent(.tabClosed(let worktreeID, let remainingTabs)):
        // Closing the last tab retires the book from the Shelf. Other
        // closes are routine and need no Reducer-side bookkeeping.
        guard remainingTabs == 0 else { return .none }
        var openedWorktreeIDs = openedWorktreeIDsForInfoWatcher(from: state.repositories)
        openedWorktreeIDs.remove(worktreeID)
        let syncedOpenedWorktreeIDs = openedWorktreeIDs
        return .merge(
          .send(.repositories(.markWorktreeClosed(worktreeID))),
          .run { _ in
            await worktreeInfoWatcher.send(.setOpenedWorktreeIDs(syncedOpenedWorktreeIDs))
          }
        )

      case .terminalEvent(.focusChanged(_, let surfaceID)):
        // Keep the Active Agents panel's keyboard-navigation anchor in sync with
        // the surface that actually has focus, so ⌃⌥↑/↓ steps from the right place.
        return .send(.repositories(.activeAgents(.focusedSurfaceChanged(surfaceID))))

      case .terminalEvent:
        return .none
      }
    }
    core
    Reduce<State, Action> { state, action in
      // Default-on focus restore: every command-palette delegate action that
      // doesn't intentionally shift selection sends focus back to the active
      // terminal once its effect has dispatched. Runs after `core` so it
      // sees the same action and adds a parallel effect.
      guard case .commandPalette(.delegate(let delegate)) = action,
        !Self.commandPaletteDelegateChangesActiveSelection(delegate)
      else {
        return .none
      }
      return restoreCommandPaletteTerminalFocusEffect(repositories: state.repositories)
    }
    Scope(state: \.repositories, action: \.repositories) {
      RepositoriesFeature()
    }
    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }
    Scope(state: \.updates, action: \.updates) {
      UpdatesFeature()
    }
    Scope(state: \.commandPalette, action: \.commandPalette) {
      CommandPaletteFeature()
    }
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
