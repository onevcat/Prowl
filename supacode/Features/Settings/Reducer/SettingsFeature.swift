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
    var updateChannel: UpdateChannel
    var updatesAutomaticallyCheckForUpdates: Bool
    var updatesAutomaticallyDownloadUpdates: Bool
    var inAppNotificationsEnabled: Bool
    var notificationSoundEnabled: Bool
    var systemNotificationsEnabled: Bool
    var moveNotifiedWorktreeToTop: Bool
    var commandFinishedNotificationEnabled: Bool
    var commandFinishedNotificationThreshold: Int
    var analyticsEnabled: Bool
    var crashReportsEnabled: Bool
    var githubIntegrationEnabled: Bool
    var telegramBotEnabled: Bool
    var telegramBotToken: String
    var telegramAllowedUserIDsText: String
    var telegramAllowedUserIDs: [Int64]
    var telegramDefaultReadLines: Int
    var telegramRequireExplicitPaneForWrite: Bool
    var telegramConnectionStatus: TelegramConnectionStatus = .idle
    var deleteBranchOnDeleteWorktree: Bool
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
    var cliInstallStatus: CLIInstallStatus = .notInstalled
    var cliInstallShowAlert: Bool = true
    /// Whether macOS will render the Dock notification badge (notification
    /// permission + the per-app "Badge app icon" switch). Refreshed when the
    /// Notifications settings pane appears.
    var dockBadgeAuthorization: SystemNotificationClient.DockBadgeAuthorization = .available
    var selection: SettingsSection? = .general
    var repositorySettings: RepositorySettingsFeature.State?
    @Presents var alert: AlertState<Alert>?

    init(settings: GlobalSettings = .default) {
      let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(settings.defaultEditorID)
      appearanceMode = settings.appearanceMode
      defaultEditorID = normalizedDefaultEditorID
      confirmBeforeQuit = settings.confirmBeforeQuit
      updateChannel = settings.updateChannel
      updatesAutomaticallyCheckForUpdates = settings.updatesAutomaticallyCheckForUpdates
      updatesAutomaticallyDownloadUpdates = settings.updatesAutomaticallyDownloadUpdates
      inAppNotificationsEnabled = settings.inAppNotificationsEnabled
      notificationSoundEnabled = settings.notificationSoundEnabled
      systemNotificationsEnabled = settings.systemNotificationsEnabled
      moveNotifiedWorktreeToTop = settings.moveNotifiedWorktreeToTop
      commandFinishedNotificationEnabled = settings.commandFinishedNotificationEnabled
      commandFinishedNotificationThreshold = settings.commandFinishedNotificationThreshold
      analyticsEnabled = settings.analyticsEnabled
      crashReportsEnabled = settings.crashReportsEnabled
      githubIntegrationEnabled = settings.githubIntegrationEnabled
      telegramBotEnabled = settings.telegramBotEnabled
      telegramBotToken = settings.telegramBotToken ?? ""
      telegramAllowedUserIDs = settings.telegramAllowedUserIDs
      telegramAllowedUserIDsText = TelegramAllowedUserIDsParser.format(settings.telegramAllowedUserIDs)
      telegramDefaultReadLines = settings.telegramDefaultReadLines
      telegramRequireExplicitPaneForWrite = settings.telegramRequireExplicitPaneForWrite
      deleteBranchOnDeleteWorktree = settings.deleteBranchOnDeleteWorktree
      mergedWorktreeAction = settings.mergedWorktreeAction
      archivedAutoDeletePeriod = settings.archivedAutoDeletePeriod
      promptForWorktreeCreation = settings.promptForWorktreeCreation
      fetchRemoteBeforeWorktreeCreation = settings.fetchOriginBeforeWorktreeCreation
      defaultWorktreeBaseDirectoryPath =
        SupacodePaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath) ?? ""
      copyIgnoredOnWorktreeCreate = settings.copyIgnoredOnWorktreeCreate
      copyUntrackedOnWorktreeCreate = settings.copyUntrackedOnWorktreeCreate
      pullRequestMergeStrategy = settings.pullRequestMergeStrategy
      restoreTerminalLayoutOnLaunch = settings.restoreTerminalLayoutOnLaunch
      terminalFontSize = settings.terminalFontSize
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
    }

    var globalSettings: GlobalSettings {
      var settings = GlobalSettings(
        appearanceMode: appearanceMode,
        defaultEditorID: defaultEditorID,
        confirmBeforeQuit: confirmBeforeQuit,
        updateChannel: updateChannel,
        updatesAutomaticallyCheckForUpdates: updatesAutomaticallyCheckForUpdates,
        updatesAutomaticallyDownloadUpdates: updatesAutomaticallyDownloadUpdates,
        inAppNotificationsEnabled: inAppNotificationsEnabled,
        notificationSoundEnabled: notificationSoundEnabled,
        systemNotificationsEnabled: systemNotificationsEnabled,
        moveNotifiedWorktreeToTop: moveNotifiedWorktreeToTop,
        commandFinishedNotificationEnabled: commandFinishedNotificationEnabled,
        commandFinishedNotificationThreshold: commandFinishedNotificationThreshold,
        analyticsEnabled: analyticsEnabled,
        crashReportsEnabled: crashReportsEnabled,
        githubIntegrationEnabled: githubIntegrationEnabled,
        telegramBotEnabled: telegramBotEnabled,
        telegramBotToken: telegramBotToken.trimmedNilIfEmpty,
        telegramAllowedUserIDs: telegramAllowedUserIDs,
        telegramDefaultReadLines: telegramDefaultReadLines,
        telegramRequireExplicitPaneForWrite: telegramRequireExplicitPaneForWrite,
        deleteBranchOnDeleteWorktree: deleteBranchOnDeleteWorktree,
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
      return settings
    }
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(GlobalSettings)
    case setSelection(SettingsSection?)
    case setSystemNotificationsEnabled(Bool)
    case setCommandFinishedNotificationThreshold(String)
    case setTelegramAllowedUserIDsText(String)
    case testTelegramConnectionButtonTapped
    case telegramConnectionTestCompleted(Result<String, TelegramConnectionTestError>)
    case setTerminalFontSize(Float32?)
    case clearTerminalLayoutSnapshotButtonTapped
    case installCLIButtonTapped(showAlert: Bool = true)
    case uninstallCLIButtonTapped
    case cliInstallCompleted(Result<String, CLIInstallError>)
    case refreshCLIInstallStatus
    case refreshDockBadgeAuthorization
    case dockBadgeAuthorizationResponse(SystemNotificationClient.DockBadgeAuthorization)
    case showNotificationPermissionAlert(errorMessage: String?)
    case repositorySettings(RepositorySettingsFeature.Action)
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

  enum TelegramConnectionStatus: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
  }

  struct TelegramConnectionTestError: Error, Equatable {
    let message: String
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(GlobalSettings)
    case terminalFontSizeChanged(Float32?)
    case terminalLayoutSnapshotCleared(success: Bool)
    case cliInstallCompleted(CLIInstallResultMessage)
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient
  @Dependency(TerminalLayoutPersistenceClient.self) private var terminalLayoutPersistence
  @Dependency(CLIInstallClient.self) private var cliInstallClient
  @Dependency(TelegramBotClient.self) private var telegramBotClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        @Shared(.settingsFile) var settingsFile
        return .send(.settingsLoaded(settingsFile.global))

      case .settingsLoaded(let settings):
        let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(settings.defaultEditorID)
        let normalizedWorktreeBaseDirPath =
          SupacodePaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath)
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
        state.updateChannel = normalizedSettings.updateChannel
        state.updatesAutomaticallyCheckForUpdates = normalizedSettings.updatesAutomaticallyCheckForUpdates
        state.updatesAutomaticallyDownloadUpdates = normalizedSettings.updatesAutomaticallyDownloadUpdates
        state.inAppNotificationsEnabled = normalizedSettings.inAppNotificationsEnabled
        state.notificationSoundEnabled = normalizedSettings.notificationSoundEnabled
        state.systemNotificationsEnabled = normalizedSettings.systemNotificationsEnabled
        state.moveNotifiedWorktreeToTop = normalizedSettings.moveNotifiedWorktreeToTop
        state.commandFinishedNotificationEnabled = normalizedSettings.commandFinishedNotificationEnabled
        state.commandFinishedNotificationThreshold = normalizedSettings.commandFinishedNotificationThreshold
        state.analyticsEnabled = normalizedSettings.analyticsEnabled
        state.crashReportsEnabled = normalizedSettings.crashReportsEnabled
        state.githubIntegrationEnabled = normalizedSettings.githubIntegrationEnabled
        state.telegramBotEnabled = normalizedSettings.telegramBotEnabled
        state.telegramBotToken = normalizedSettings.telegramBotToken ?? ""
        state.telegramAllowedUserIDs = normalizedSettings.telegramAllowedUserIDs
        state.telegramAllowedUserIDsText = TelegramAllowedUserIDsParser.format(
          normalizedSettings.telegramAllowedUserIDs)
        state.telegramDefaultReadLines = normalizedSettings.telegramDefaultReadLines
        state.telegramRequireExplicitPaneForWrite = normalizedSettings.telegramRequireExplicitPaneForWrite
        state.deleteBranchOnDeleteWorktree = normalizedSettings.deleteBranchOnDeleteWorktree
        state.mergedWorktreeAction = normalizedSettings.mergedWorktreeAction
        state.archivedAutoDeletePeriod = normalizedSettings.archivedAutoDeletePeriod
        state.promptForWorktreeCreation = normalizedSettings.promptForWorktreeCreation
        state.fetchRemoteBeforeWorktreeCreation = normalizedSettings.fetchOriginBeforeWorktreeCreation
        state.defaultWorktreeBaseDirectoryPath = normalizedSettings.defaultWorktreeBaseDirectoryPath ?? ""
        state.copyIgnoredOnWorktreeCreate = normalizedSettings.copyIgnoredOnWorktreeCreate
        state.copyUntrackedOnWorktreeCreate = normalizedSettings.copyUntrackedOnWorktreeCreate
        state.pullRequestMergeStrategy = normalizedSettings.pullRequestMergeStrategy
        state.restoreTerminalLayoutOnLaunch = normalizedSettings.restoreTerminalLayoutOnLaunch
        state.terminalFontSize = normalizedSettings.terminalFontSize
        state.keybindingUserOverrides = normalizedSettings.keybindingUserOverrides
        state.defaultViewMode = normalizedSettings.defaultViewMode
        state.dimUnfocusedSplits = normalizedSettings.dimUnfocusedSplits
        state.autoShowActiveAgentsPanel = normalizedSettings.autoShowActiveAgentsPanel
        state.showActiveAgentTabTitles = normalizedSettings.showActiveAgentTabTitles
        state.showActiveAgentStatusInShelf = normalizedSettings.showActiveAgentStatusInShelf
        state.windowTintMode = normalizedSettings.windowTintMode
        state.shelfSpineTintFallback = normalizedSettings.shelfSpineTintFallback
        state.shelfSpineTintFollowsRepositoryColor = normalizedSettings.shelfSpineTintFollowsRepositoryColor
        state.windowTintCustomColor = normalizedSettings.windowTintCustomColor.color
        state.showRunButtonInToolbar = normalizedSettings.showRunButtonInToolbar
        state.showDefaultEditorInToolbar = normalizedSettings.showDefaultEditorInToolbar
        state.dockBounceMode = normalizedSettings.dockBounceMode
        state.showNotificationDotOnDock = normalizedSettings.showNotificationDotOnDock
        state.externalDiffToolID = normalizedSettings.externalDiffToolID
        state.externalDiffCustomCommand = normalizedSettings.externalDiffCustomCommand
        state.syncGlobalDefaults(from: normalizedSettings)
        return .send(.delegate(.settingsChanged(normalizedSettings)))

      case .binding:
        state.commandFinishedNotificationThreshold = min(max(state.commandFinishedNotificationThreshold, 0), 600)
        state.telegramDefaultReadLines = min(max(state.telegramDefaultReadLines, 1), 500)
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

      case .setTelegramAllowedUserIDsText(let text):
        state.telegramAllowedUserIDsText = text
        guard let ids = TelegramAllowedUserIDsParser.parse(text) else {
          return .none
        }
        state.telegramAllowedUserIDs = ids
        return persist(state)

      case .testTelegramConnectionButtonTapped:
        guard let token = state.globalSettings.telegramBotToken else {
          state.telegramConnectionStatus = .failure("Bot token is required.")
          return .none
        }
        state.telegramConnectionStatus = .testing
        return .run { [telegramBotClient] send in
          do {
            let user = try await telegramBotClient.getMe(token)
            let label = user.username.map { "@\($0)" } ?? user.firstName
            await send(.telegramConnectionTestCompleted(.success(label)))
          } catch {
            await send(
              .telegramConnectionTestCompleted(
                .failure(TelegramConnectionTestError(message: telegramConnectionErrorMessage(error)))
              )
            )
          }
        }

      case .telegramConnectionTestCompleted(.success(let label)):
        state.telegramConnectionStatus = .success(label)
        return .none

      case .telegramConnectionTestCompleted(.failure(let error)):
        state.telegramConnectionStatus = .failure(error.message)
        return .none

      case .setTerminalFontSize(let fontSize):
        guard state.terminalFontSize != fontSize else { return .none }
        state.terminalFontSize = fontSize
        return .merge(
          persist(state, captureAnalytics: false, emitSettingsChanged: false),
          .send(.delegate(.terminalFontSizeChanged(fontSize)))
        )

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
            await send(.cliInstallCompleted(.failure(CLIInstallError(message: error.localizedDescription))))
          }
        }

      case .uninstallCLIButtonTapped:
        let installPath = cliDefaultInstallPath
        return .run { [cliInstallClient] send in
          do {
            try await cliInstallClient.uninstall(installPath)
            await send(.cliInstallCompleted(.success("")))
          } catch let error as CLIInstallError {
            await send(.cliInstallCompleted(.failure(error)))
          } catch {
            await send(.cliInstallCompleted(.failure(CLIInstallError(message: error.localizedDescription))))
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
          await send(.dockBadgeAuthorizationResponse(systemNotificationClient.dockBadgeAuthorization()))
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

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .alert(.presented(.openSystemNotificationSettings)):
        state.alert = nil
        return .run { _ in
          await systemNotificationClient.openSettings()
        }

      case .alert:
        return .none

      case .repositorySettings:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.repositorySettings, action: \.repositorySettings) {
      RepositorySettingsFeature()
    }
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
  var telegramBotConfiguration: TelegramBotConfiguration {
    TelegramBotConfiguration(
      enabled: telegramBotEnabled,
      token: telegramBotToken,
      allowedUserIDs: telegramAllowedUserIDs,
      defaultReadLines: telegramDefaultReadLines,
      requireExplicitPaneForWrite: telegramRequireExplicitPaneForWrite
    )
  }

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

private func telegramConnectionErrorMessage(_ error: Error) -> String {
  if let clientError = error as? TelegramBotClientError {
    switch clientError {
    case .invalidResponse:
      return "Telegram returned an invalid response."
    case .api(let errorCode, let description):
      if let errorCode {
        return "Telegram API error \(errorCode): \(description)"
      }
      return "Telegram API error: \(description)"
    }
  }
  return "Could not reach Telegram Bot API."
}

extension String {
  fileprivate var trimmedNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
