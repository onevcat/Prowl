import ComposableArchitecture
import Foundation
import SwiftUI

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State: Equatable {
    var appearanceMode: AppearanceMode
    var defaultEditorID: String
    var confirmBeforeQuit: Bool
    var updatesAutomaticallyCheckForUpdates: Bool
    var updatesAutomaticallyDownloadUpdates: Bool
    var inAppNotificationsEnabled: Bool
    var notificationSound: NotificationSound
    var systemNotificationsEnabled: Bool
    var muteNotificationsForActiveSurface: Bool
    var moveNotifiedWorktreeToTop: Bool
    var commandFinishedNotificationEnabled: Bool
    var commandFinishedNotificationThreshold: Int
    var analyticsEnabled: Bool
    var crashReportsEnabled: Bool
    var githubIntegrationEnabled: Bool
    var deleteBranchOnAutomaticCleanup: Bool
    var mergedWorktreeAction: MergedWorktreeAction?
    var archivedAutoDeletePeriod: AutoDeletePeriod?
    var promptForWorktreeCreation: Bool
    var fetchRemoteBeforeWorktreeCreation: Bool
    var defaultWorktreeBaseDirectoryPath: String
    var copyIgnoredOnWorktreeCreate: Bool
    var copyUntrackedOnWorktreeCreate: Bool
    var pullRequestMergeStrategy: PullRequestMergeStrategy
    var restoreTerminalLayoutOnLaunch: Bool
    var terminalFontSize: Float32?
    var ghosttyConfigPath: String?
    var keybindingUserOverrides: KeybindingUserOverrideStore
    var defaultViewMode: DefaultViewMode
    var canvasDefaultLayout: CanvasDefaultLayout
    var dimUnfocusedSplits: Bool
    var autoShowActiveAgentsPanel: Bool
    var showActiveAgentTabTitles: Bool
    var showActiveAgentStatusInShelf: Bool
    var windowTintMode: WindowTintMode
    var shelfSpineTintFallback: ShelfSpineTintFallback
    var shelfSpineTintFollowsRepositoryColor: Bool
    /// Mirrors `GlobalSettings.windowTintCustomColor` as a live `Color` so
    /// the `ColorPicker` can bind to it directly; converted back to the
    /// persistable `TintColor` at the `globalSettings` boundary.
    var windowTintCustomColor: Color
    var showRunButtonInToolbar: Bool
    var showDefaultEditorInToolbar: Bool
    var dockBounceMode: DockBounceMode
    var showNotificationDotOnDock: Bool
    var externalDiffToolID: String
    var externalDiffCustomCommand: String
    var detectRepositoryIconsAutomatically: Bool
    var cliInstallStatus: CLIInstallStatus = .notInstalled
    var cliInstallShowAlert: Bool = true
    /// Whether macOS will render the Dock notification badge (notification
    /// permission + the per-app "Badge app icon" switch). Refreshed when the
    /// Notifications settings pane appears.
    var dockBadgeAuthorization: SystemNotificationClient.DockBadgeAuthorization = .available
    var selection: SettingsSection? = .general
    var repositorySettings: RepositorySettingsFeature.State?
    var globalCustomCommands: GlobalCustomCommandsFeature.State?
    var agentProfiles: AgentProfilesFeature.State?
    @Presents var alert: AlertState<Alert>?

    init(settings: GlobalSettings = .default) {
      let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(
        settings.defaultEditorID)
      appearanceMode = settings.appearanceMode
      defaultEditorID = normalizedDefaultEditorID
      confirmBeforeQuit = settings.confirmBeforeQuit
      updatesAutomaticallyCheckForUpdates = settings.updatesAutomaticallyCheckForUpdates
      updatesAutomaticallyDownloadUpdates = settings.updatesAutomaticallyDownloadUpdates
      inAppNotificationsEnabled = settings.inAppNotificationsEnabled
      notificationSound = settings.notificationSound
      systemNotificationsEnabled = settings.systemNotificationsEnabled
      muteNotificationsForActiveSurface = settings.muteNotificationsForActiveSurface
      moveNotifiedWorktreeToTop = settings.moveNotifiedWorktreeToTop
      commandFinishedNotificationEnabled = settings.commandFinishedNotificationEnabled
      commandFinishedNotificationThreshold = settings.commandFinishedNotificationThreshold
      analyticsEnabled = settings.analyticsEnabled
      crashReportsEnabled = settings.crashReportsEnabled
      githubIntegrationEnabled = settings.githubIntegrationEnabled
      deleteBranchOnAutomaticCleanup = settings.deleteBranchOnAutomaticCleanup
      mergedWorktreeAction = settings.mergedWorktreeAction
      archivedAutoDeletePeriod = settings.archivedAutoDeletePeriod
      promptForWorktreeCreation = settings.promptForWorktreeCreation
      fetchRemoteBeforeWorktreeCreation = settings.fetchOriginBeforeWorktreeCreation
      defaultWorktreeBaseDirectoryPath =
        SupacodePaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath)
        ?? ""
      copyIgnoredOnWorktreeCreate = settings.copyIgnoredOnWorktreeCreate
      copyUntrackedOnWorktreeCreate = settings.copyUntrackedOnWorktreeCreate
      pullRequestMergeStrategy = settings.pullRequestMergeStrategy
      restoreTerminalLayoutOnLaunch = settings.restoreTerminalLayoutOnLaunch
      terminalFontSize = settings.terminalFontSize
      ghosttyConfigPath = settings.ghosttyConfigPath
      keybindingUserOverrides = settings.keybindingUserOverrides
      defaultViewMode = settings.defaultViewMode
      canvasDefaultLayout = settings.canvasDefaultLayout
      dimUnfocusedSplits = settings.dimUnfocusedSplits
      autoShowActiveAgentsPanel = settings.autoShowActiveAgentsPanel
      showActiveAgentTabTitles = settings.showActiveAgentTabTitles
      showActiveAgentStatusInShelf = settings.showActiveAgentStatusInShelf
      windowTintMode = settings.windowTintMode
      shelfSpineTintFallback = settings.shelfSpineTintFallback
      shelfSpineTintFollowsRepositoryColor = settings.shelfSpineTintFollowsRepositoryColor
      windowTintCustomColor = settings.windowTintCustomColor.color
      showRunButtonInToolbar = settings.showRunButtonInToolbar
      showDefaultEditorInToolbar = settings.showDefaultEditorInToolbar
      dockBounceMode = settings.dockBounceMode
      showNotificationDotOnDock = settings.showNotificationDotOnDock
      externalDiffToolID = settings.externalDiffToolID
      externalDiffCustomCommand = settings.externalDiffCustomCommand
      detectRepositoryIconsAutomatically = settings.detectRepositoryIconsAutomatically
    }

    var globalSettings: GlobalSettings {
      var settings = GlobalSettings(
        appearanceMode: appearanceMode,
        defaultEditorID: defaultEditorID,
        confirmBeforeQuit: confirmBeforeQuit,
        updatesAutomaticallyCheckForUpdates: updatesAutomaticallyCheckForUpdates,
        updatesAutomaticallyDownloadUpdates: updatesAutomaticallyDownloadUpdates,
        inAppNotificationsEnabled: inAppNotificationsEnabled,
        notificationSound: notificationSound,
        systemNotificationsEnabled: systemNotificationsEnabled,
        muteNotificationsForActiveSurface: muteNotificationsForActiveSurface,
        moveNotifiedWorktreeToTop: moveNotifiedWorktreeToTop,
        commandFinishedNotificationEnabled: commandFinishedNotificationEnabled,
        commandFinishedNotificationThreshold: commandFinishedNotificationThreshold,
        analyticsEnabled: analyticsEnabled,
        crashReportsEnabled: crashReportsEnabled,
        githubIntegrationEnabled: githubIntegrationEnabled,
        deleteBranchOnAutomaticCleanup: deleteBranchOnAutomaticCleanup,
        mergedWorktreeAction: mergedWorktreeAction,
        promptForWorktreeCreation: promptForWorktreeCreation,
        fetchOriginBeforeWorktreeCreation: fetchRemoteBeforeWorktreeCreation,
        defaultWorktreeBaseDirectoryPath: SupacodePaths.normalizedWorktreeBaseDirectoryPath(
          defaultWorktreeBaseDirectoryPath
        ),
        copyIgnoredOnWorktreeCreate: copyIgnoredOnWorktreeCreate,
        copyUntrackedOnWorktreeCreate: copyUntrackedOnWorktreeCreate,
        pullRequestMergeStrategy: pullRequestMergeStrategy,
        restoreTerminalLayoutOnLaunch: restoreTerminalLayoutOnLaunch,
        archivedAutoDeletePeriod: archivedAutoDeletePeriod,
        terminalFontSize: terminalFontSize,
        ghosttyConfigPath: ghosttyConfigPath,
        keybindingUserOverrides: keybindingUserOverrides,
        defaultViewMode: defaultViewMode,
        canvasDefaultLayout: canvasDefaultLayout,
        dimUnfocusedSplits: dimUnfocusedSplits,
        autoShowActiveAgentsPanel: autoShowActiveAgentsPanel,
        showActiveAgentTabTitles: showActiveAgentTabTitles,
        showActiveAgentStatusInShelf: showActiveAgentStatusInShelf,
        windowTintMode: windowTintMode,
        windowTintCustomColor: TintColor(windowTintCustomColor),
        showRunButtonInToolbar: showRunButtonInToolbar,
        showDefaultEditorInToolbar: showDefaultEditorInToolbar,
        dockBounceMode: dockBounceMode,
        showNotificationDotOnDock: showNotificationDotOnDock,
        shelfSpineTintFallback: shelfSpineTintFallback,
        shelfSpineTintFollowsRepositoryColor: shelfSpineTintFollowsRepositoryColor
      )
      settings.externalDiffToolID = externalDiffToolID
      settings.externalDiffCustomCommand = externalDiffCustomCommand
      settings.detectRepositoryIconsAutomatically = detectRepositoryIconsAutomatically
      return settings
    }
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(GlobalSettings)
    case setSelection(SettingsSection?)
    case setSystemNotificationsEnabled(Bool)
    case setCommandFinishedNotificationThreshold(String)
    case setTerminalFontSize(Float32?)
    case setGhosttyConfigPath(String?)
    case clearShortcutButtonTapped(commandID: String)
    case clearTerminalLayoutSnapshotButtonTapped
    case installCLIButtonTapped(showAlert: Bool = true)
    case uninstallCLIButtonTapped
    case cliInstallCompleted(Result<String, CLIInstallError>)
    case refreshCLIInstallStatus
    case refreshDockBadgeAuthorization
    case dockBadgeAuthorizationResponse(SystemNotificationClient.DockBadgeAuthorization)
    case showNotificationPermissionAlert(errorMessage: String?)
    case repositorySettings(RepositorySettingsFeature.Action)
    case globalCustomCommands(GlobalCustomCommandsFeature.Action)
    case agentProfiles(AgentProfilesFeature.Action)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  enum Alert: Equatable {
    case dismiss
    case openSystemNotificationSettings
  }

  enum CLIInstallResultMessage: Equatable {
    case installed(path: String)
    case uninstalled
    case failed(message: String)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(GlobalSettings)
    case terminalFontSizeChanged(Float32?)
    case ghosttyConfigPathChanged(String?)
    case terminalLayoutSnapshotCleared(success: Bool)
    case cliInstallCompleted(CLIInstallResultMessage)
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient
  @Dependency(NotificationSoundClient.self) private var notificationSoundClient
  @Dependency(TerminalLayoutPersistenceClient.self) private var terminalLayoutPersistence
  @Dependency(CLIInstallClient.self) private var cliInstallClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        @Shared(.settingsFile) var settingsFile
        return .send(.settingsLoaded(settingsFile.global))

      case .settingsLoaded(let settings):
        let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(
          settings.defaultEditorID)
        let normalizedWorktreeBaseDirPath =
          SupacodePaths.normalizedWorktreeBaseDirectoryPath(
            settings.defaultWorktreeBaseDirectoryPath)
        let normalizedSettings: GlobalSettings
        if normalizedDefaultEditorID == settings.defaultEditorID,
          normalizedWorktreeBaseDirPath == settings.defaultWorktreeBaseDirectoryPath
        {
          normalizedSettings = settings
        } else {
          var updatedSettings = settings
          updatedSettings.defaultEditorID = normalizedDefaultEditorID
          updatedSettings.defaultWorktreeBaseDirectoryPath = normalizedWorktreeBaseDirPath
          normalizedSettings = updatedSettings
          @Shared(.settingsFile) var settingsFile
          $settingsFile.withLock { $0.global = normalizedSettings }
        }
        state.appearanceMode = normalizedSettings.appearanceMode
        state.defaultEditorID = normalizedSettings.defaultEditorID
        state.confirmBeforeQuit = normalizedSettings.confirmBeforeQuit
        state.updatesAutomaticallyCheckForUpdates =
          normalizedSettings.updatesAutomaticallyCheckForUpdates
        state.updatesAutomaticallyDownloadUpdates =
          normalizedSettings.updatesAutomaticallyDownloadUpdates
        state.inAppNotificationsEnabled = normalizedSettings.inAppNotificationsEnabled
        state.notificationSound = normalizedSettings.notificationSound
        state.systemNotificationsEnabled = normalizedSettings.systemNotificationsEnabled
        state.muteNotificationsForActiveSurface =
          normalizedSettings.muteNotificationsForActiveSurface
        state.moveNotifiedWorktreeToTop = normalizedSettings.moveNotifiedWorktreeToTop
        state.commandFinishedNotificationEnabled =
          normalizedSettings.commandFinishedNotificationEnabled
        state.commandFinishedNotificationThreshold =
          normalizedSettings.commandFinishedNotificationThreshold
        state.analyticsEnabled = normalizedSettings.analyticsEnabled
        state.crashReportsEnabled = normalizedSettings.crashReportsEnabled
        state.githubIntegrationEnabled = normalizedSettings.githubIntegrationEnabled
        state.deleteBranchOnAutomaticCleanup = normalizedSettings.deleteBranchOnAutomaticCleanup
        state.mergedWorktreeAction = normalizedSettings.mergedWorktreeAction
        state.archivedAutoDeletePeriod = normalizedSettings.archivedAutoDeletePeriod
        state.promptForWorktreeCreation = normalizedSettings.promptForWorktreeCreation
        state.fetchRemoteBeforeWorktreeCreation =
          normalizedSettings.fetchOriginBeforeWorktreeCreation
        state.defaultWorktreeBaseDirectoryPath =
          normalizedSettings.defaultWorktreeBaseDirectoryPath ?? ""
        state.copyIgnoredOnWorktreeCreate = normalizedSettings.copyIgnoredOnWorktreeCreate
        state.copyUntrackedOnWorktreeCreate = normalizedSettings.copyUntrackedOnWorktreeCreate
        state.pullRequestMergeStrategy = normalizedSettings.pullRequestMergeStrategy
        state.restoreTerminalLayoutOnLaunch = normalizedSettings.restoreTerminalLayoutOnLaunch
        state.terminalFontSize = normalizedSettings.terminalFontSize
        state.ghosttyConfigPath = normalizedSettings.ghosttyConfigPath
        state.keybindingUserOverrides = normalizedSettings.keybindingUserOverrides
        state.defaultViewMode = normalizedSettings.defaultViewMode
        state.dimUnfocusedSplits = normalizedSettings.dimUnfocusedSplits
        state.autoShowActiveAgentsPanel = normalizedSettings.autoShowActiveAgentsPanel
        state.showActiveAgentTabTitles = normalizedSettings.showActiveAgentTabTitles
        state.showActiveAgentStatusInShelf = normalizedSettings.showActiveAgentStatusInShelf
        state.windowTintMode = normalizedSettings.windowTintMode
        state.shelfSpineTintFallback = normalizedSettings.shelfSpineTintFallback
        state.shelfSpineTintFollowsRepositoryColor =
          normalizedSettings.shelfSpineTintFollowsRepositoryColor
        state.windowTintCustomColor = normalizedSettings.windowTintCustomColor.color
        state.showRunButtonInToolbar = normalizedSettings.showRunButtonInToolbar
        state.showDefaultEditorInToolbar = normalizedSettings.showDefaultEditorInToolbar
        state.dockBounceMode = normalizedSettings.dockBounceMode
        state.showNotificationDotOnDock = normalizedSettings.showNotificationDotOnDock
        state.externalDiffToolID = normalizedSettings.externalDiffToolID
        state.externalDiffCustomCommand = normalizedSettings.externalDiffCustomCommand
        state.canvasDefaultLayout = normalizedSettings.canvasDefaultLayout
        state.detectRepositoryIconsAutomatically =
          normalizedSettings.detectRepositoryIconsAutomatically
        state.syncGlobalDefaults(from: normalizedSettings)
        return .send(.delegate(.settingsChanged(normalizedSettings)))

      case .binding(\.notificationSound):
        let sound = state.notificationSound
        // Preview the chosen sound, but only on the in-app path: with system
        // notifications on, the banner plays the macOS default instead. `.never`
        // has nothing to audition.
        let shouldPreview = !state.systemNotificationsEnabled && sound != .never
        state.syncGlobalDefaults(from: state.globalSettings)
        return .merge(
          persist(state),
          shouldPreview ? .run { _ in await notificationSoundClient.play(sound) } : .none
        )

      case .binding:
        state.commandFinishedNotificationThreshold = min(
          max(state.commandFinishedNotificationThreshold, 0), 600)
        state.syncGlobalDefaults(from: state.globalSettings)
        return persist(state)

      case .setCommandFinishedNotificationThreshold(let text):
        if let parsed = Int(text) {
          state.commandFinishedNotificationThreshold = min(max(parsed, 0), 600)
        } else {
          state.commandFinishedNotificationThreshold = 10
        }
        return persist(state)

      case .setSystemNotificationsEnabled(let isEnabled):
        state.systemNotificationsEnabled = isEnabled
        state.syncGlobalDefaults(from: state.globalSettings)
        return persist(state)

      case .setTerminalFontSize(let fontSize):
        guard state.terminalFontSize != fontSize else { return .none }
        state.terminalFontSize = fontSize
        return .merge(
          persist(state, captureAnalytics: false, emitSettingsChanged: false),
          .send(.delegate(.terminalFontSizeChanged(fontSize)))
        )

      case .setGhosttyConfigPath(let path):
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        guard state.ghosttyConfigPath != normalizedPath else { return .none }
        state.ghosttyConfigPath = normalizedPath
        return .merge(
          persist(state, emitSettingsChanged: false),
          .send(.delegate(.ghosttyConfigPathChanged(normalizedPath)))
        )

      case .clearShortcutButtonTapped(let commandID):
        guard
          let command = KeybindingSchemaDocument.appDefaultsV1.commands.first(where: {
            $0.id == commandID
          }),
          command.allowUserOverride
        else {
          return .none
        }

        let clearedOverride = KeybindingUserOverride(binding: nil, isEnabled: false)
        guard state.keybindingUserOverrides.overrides[commandID] != clearedOverride else {
          return .none
        }

        state.keybindingUserOverrides.overrides[commandID] = clearedOverride
        state.syncGlobalDefaults(from: state.globalSettings)
        return persist(state)

      case .clearTerminalLayoutSnapshotButtonTapped:
        return .run { send in
          let success = await terminalLayoutPersistence.clearSnapshot()
          await send(.delegate(.terminalLayoutSnapshotCleared(success: success)))
        }

      case .installCLIButtonTapped(let showAlert):
        state.cliInstallShowAlert = showAlert
        let installPath = cliDefaultInstallPath
        return .run { [cliInstallClient] send in
          do {
            try await cliInstallClient.install(installPath)
            let path = installPath.path(percentEncoded: false)
            await send(.cliInstallCompleted(.success(path)))
          } catch let error as CLIInstallError {
            await send(.cliInstallCompleted(.failure(error)))
          } catch {
            await send(
              .cliInstallCompleted(.failure(CLIInstallError(message: error.localizedDescription))))
          }
        }

      case .uninstallCLIButtonTapped:
        // Uninstall is only reachable from the Settings UI, so its result
        // must always alert — without this, a palette-triggered install
        // (showAlert: false) leaves the flag stuck and a failed uninstall
        // would report nothing at all.
        state.cliInstallShowAlert = true
        let installPath = cliDefaultInstallPath
        return .run { [cliInstallClient] send in
          do {
            try await cliInstallClient.uninstall(installPath)
            await send(.cliInstallCompleted(.success("")))
          } catch let error as CLIInstallError {
            await send(.cliInstallCompleted(.failure(error)))
          } catch {
            await send(
              .cliInstallCompleted(.failure(CLIInstallError(message: error.localizedDescription))))
          }
        }

      case .cliInstallCompleted(.success(let path)):
        if state.cliInstallShowAlert {
          if path.isEmpty {
            state.alert = AlertState {
              TextState("Command Line Tool Uninstalled")
            } actions: {
              ButtonState(action: .dismiss) { TextState("OK") }
            } message: {
              TextState("The prowl command line tool has been removed.")
            }
          } else {
            state.alert = AlertState {
              TextState("Command Line Tool Installed")
            } actions: {
              ButtonState(action: .dismiss) { TextState("OK") }
            } message: {
              TextState("The prowl command is now available at \(path).")
            }
          }
        }
        state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
        let result: CLIInstallResultMessage = path.isEmpty ? .uninstalled : .installed(path: path)
        return .send(.delegate(.cliInstallCompleted(result)))

      case .cliInstallCompleted(.failure(let error)):
        if state.cliInstallShowAlert {
          state.alert = AlertState {
            TextState("Command Line Tool Error")
          } actions: {
            ButtonState(action: .dismiss) { TextState("OK") }
          } message: {
            TextState(error.message)
          }
        }
        state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
        return .send(.delegate(.cliInstallCompleted(.failed(message: error.message))))

      case .refreshCLIInstallStatus:
        state.cliInstallStatus = cliInstallClient.installationStatus(cliDefaultInstallPath)
        return .none

      case .refreshDockBadgeAuthorization:
        return .run { send in
          await send(
            .dockBadgeAuthorizationResponse(systemNotificationClient.dockBadgeAuthorization()))
        }

      case .dockBadgeAuthorizationResponse(let authorization):
        state.dockBadgeAuthorization = authorization
        return .none

      case .showNotificationPermissionAlert:
        state.alert = AlertState {
          TextState("Prowl cannot send system notifications")
        } actions: {
          ButtonState(action: .openSystemNotificationSettings) {
            TextState("Open System Settings")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "Notification permission is turned off. Open System Settings to allow Prowl to send notifications."
          )
        }
        return .none

      case .setSelection(let selection):
        state.selection = selection ?? .general
        return .none

      case .alert(.presented(.openSystemNotificationSettings)):
        return .run { _ in
          await systemNotificationClient.openSettings()
        }

      case .alert:
        return .none

      case .repositorySettings:
        return .none

      case .globalCustomCommands:
        return .none

      case .agentProfiles:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.repositorySettings, action: \.repositorySettings) {
      RepositorySettingsFeature()
    }
    .ifLet(\.globalCustomCommands, action: \.globalCustomCommands) {
      GlobalCustomCommandsFeature()
    }
    .ifLet(\.agentProfiles, action: \.agentProfiles) {
      AgentProfilesFeature()
    }
    // Without this, alert state is only cleared by the view's dismiss
    // writeback: state set while the Settings window is closed (or closed
    // while an alert is up) would wedge as permanently "presented".
    .ifLet(\.$alert, action: \.alert)
  }

  private func persist(
    _ state: State,
    captureAnalytics: Bool = true,
    emitSettingsChanged: Bool = true
  ) -> Effect<Action> {
    let settings = state.globalSettings
    @Shared(.settingsFile) var settingsFile
    let previouslyAnalyticsEnabled = settingsFile.global.analyticsEnabled
    $settingsFile.withLock { $0.global = settings }
    if captureAnalytics, settings.analyticsEnabled {
      analyticsClient.capture("settings_changed", nil)
    }
    if previouslyAnalyticsEnabled, !settings.analyticsEnabled {
      analyticsClient.reset()
    }
    if emitSettingsChanged {
      return .send(.delegate(.settingsChanged(settings)))
    }
    return .none
  }
}

extension SettingsFeature.State {
  mutating func syncGlobalDefaults(from settings: GlobalSettings) {
    repositorySettings?.globalDefaultWorktreeBaseDirectoryPath =
      settings.defaultWorktreeBaseDirectoryPath
    repositorySettings?.globalCopyIgnoredOnWorktreeCreate =
      settings.copyIgnoredOnWorktreeCreate
    repositorySettings?.globalCopyUntrackedOnWorktreeCreate =
      settings.copyUntrackedOnWorktreeCreate
    repositorySettings?.globalPullRequestMergeStrategy =
      settings.pullRequestMergeStrategy
  }
}
