import AppKit
import ComposableArchitecture
import Foundation
import PostHog
import SwiftUI

@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var repositories: RepositoriesFeature.State
    var settings: SettingsFeature.State
    var updates = UpdatesFeature.State()
    var commandPalette = CommandPaletteFeature.State()
    var openActionSelection: OpenWorktreeAction = .finder
    /// Whether the selected worktree's repository resolves its open action
    /// automatically (project-aware) rather than a user-pinned app. Drives the
    /// "Automatic" entry's checkmark in the toolbar's Open menu.
    var openActionIsAutomatic: Bool = true
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
      var repositories = repositories
      repositories.showActiveAgentTabTitles = settings.showActiveAgentTabTitles
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
    case openActionResetToAutomatic
    case worktreeSettingsLoaded(RepositorySettings, worktreeID: Worktree.ID)
    case worktreeUserSettingsLoaded(UserRepositorySettings, worktreeID: Worktree.ID)
    case openSelectedWorktree
    case showSelectedWorktreeDiff
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

  @Dependency(AnalyticsClient.self) var analyticsClient
  @Dependency(\.date.now) var now
  @Dependency(RepositoryPersistenceClient.self) var repositoryPersistence
  @Dependency(WorkspaceClient.self) var workspaceClient
  @Dependency(SettingsWindowClient.self) var settingsWindowClient
  @Dependency(AppLifecycleClient.self) var appLifecycleClient
  @Dependency(NotificationSoundClient.self) var notificationSoundClient
  @Dependency(SystemNotificationClient.self) var systemNotificationClient
  @Dependency(DockClient.self) var dockClient
  @Dependency(TerminalClient.self) var terminalClient
  @Dependency(WorktreeInfoWatcherClient.self) var worktreeInfoWatcher
  @Dependency(CustomShortcutRegistryClient.self) var customShortcutRegistryClient
  @Dependency(ExternalDiffToolClient.self) var externalDiffToolClient

  var body: some Reducer<State, Action> {
    let core = Reduce<State, Action> { state, action in
      switch action {
      case .appLaunched:
        try? SupacodePaths.migrateLegacyCacheFilesIfNeeded()
        appLogger.info("[LayoutRestore] appLaunched: launchRestoreMode=\(String(describing: state.launchRestoreMode))")
        state.launchedAt = now
        state.repositories.launchRestoreMode = state.launchRestoreMode
        analyticsClient.capture("app_launched", nil)
        return .merge(
          .send(.repositories(.task)),
          .send(.settings(.task)),
          .send(.updates(.task)),
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
          if state.settings.restoreTerminalLayoutOnLaunch,
            !state.suppressLayoutSaveUntilRelaunch,
            state.launchRestoreMode != .restoreLayout
          {
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

      case .repositories(.delegate(.showDiff(let worktreeID))):
        guard let worktree = state.repositories.worktree(for: worktreeID) else {
          return .none
        }
        return openDiffEffect(worktree: worktree, resolvedKeybindings: state.resolvedKeybindings)

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
          repoSettingsState.workspace = repository.workspace
          repoSettingsState.globalCopyIgnoredOnWorktreeCreate = state.settings.copyIgnoredOnWorktreeCreate
          repoSettingsState.globalCopyUntrackedOnWorktreeCreate = state.settings.copyUntrackedOnWorktreeCreate
          repoSettingsState.globalPullRequestMergeStrategy = state.settings.pullRequestMergeStrategy
          state.settings.repositorySettings = repoSettingsState
        case .general, .notifications, .shortcuts, .worktree, .updates, .advanced, .github, .telegram:
          state.settings.repositorySettings = nil
        }
        return .none

      case .settings(.delegate(.settingsChanged(let settings))):
        let shouldCheckSystemNotificationPermission =
          settings.systemNotificationsEnabled && !state.lastKnownSystemNotificationsEnabled
        state.lastKnownSystemNotificationsEnabled = settings.systemNotificationsEnabled
        state.settings.keybindingUserOverrides = settings.keybindingUserOverrides
        state.repositories.showActiveAgentTabTitles = settings.showActiveAgentTabTitles
        if let selectedWorktree = state.repositories.selectedTerminalWorktree {
          let rootURL = selectedWorktree.repositoryRootURL
          @Shared(.repositorySettings(rootURL)) var repositorySettings
          state.openActionSelection = OpenWorktreeAction.fromSettingsID(
            repositorySettings.openActionID,
            defaultEditorID: settings.defaultEditorID,
            workingDirectory: selectedWorktree.workingDirectory
          )
          state.openActionIsAutomatic =
            repositorySettings.openActionID == OpenWorktreeAction.automaticSettingsID
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
                automaticallyChecks: settings.updatesAutomaticallyCheckForUpdates
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
        state.openActionIsAutomatic = false
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        let rootURL = worktree.repositoryRootURL
        let actionID = action.settingsID
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0.openActionID = actionID }
        return .none

      case .openActionResetToAutomatic:
        guard let worktree = state.repositories.selectedTerminalWorktree else {
          return .none
        }
        // Clearing the pin only matters when the repo isn't already automatic;
        // re-resolve and reopen unconditionally so the entry behaves like the
        // concrete app rows, where selecting always opens.
        if !state.openActionIsAutomatic {
          let rootURL = worktree.repositoryRootURL
          @Shared(.repositorySettings(rootURL)) var repositorySettings
          $repositorySettings.withLock { $0.openActionID = OpenWorktreeAction.automaticSettingsID }
        }
        @Shared(.settingsFile) var settingsFile
        state.openActionSelection = OpenWorktreeAction.fromSettingsID(
          OpenWorktreeAction.automaticSettingsID,
          defaultEditorID: settingsFile.global.defaultEditorID,
          workingDirectory: worktree.workingDirectory
        )
        state.openActionIsAutomatic = true
        return .send(.openSelectedWorktree)

      case .openSelectedWorktree:
        return .send(.openWorktree(OpenWorktreeAction.availableSelection(state.openActionSelection)))

      case .showSelectedWorktreeDiff:
        return openSelectedWorktreeDiffEffect(state: state)

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
        guard let worktree = actionTargetWorktree(repositories: state.repositories) else {
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
          state.openActionIsAutomatic = true
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
        applyWorktreeSettings(
          repositorySettings,
          workingDirectory: worktree.workingDirectory,
          into: &state
        )
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
        guard let worktree = actionTargetWorktree(repositories: state.repositories),
          worktree.id == worktreeID
        else {
          return .none
        }
        applyWorktreeSettings(
          settings,
          workingDirectory: worktree.workingDirectory,
          into: &state
        )
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

      case .repositories:
        return .none

      case .settings:
        return .none

      case .updates:
        return .none

      case .commandPalette(let action):
        return reduceCommandPaletteAction(action, state: &state)

      case .terminalEvent(let event):
        return reduceTerminalEvent(event, state: &state)
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
