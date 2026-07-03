import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct SettingsFeatureTests {
  @Test(.dependencies) func loadSettings() async {
    let loaded = GlobalSettings(
      appearanceMode: .dark,
      defaultEditorID: OpenWorktreeAction.automaticSettingsID,
      confirmBeforeQuit: true,
      updateChannel: .stable,
      updatesAutomaticallyCheckForUpdates: false,
      updatesAutomaticallyDownloadUpdates: true,
      inAppNotificationsEnabled: false,
      notificationSoundEnabled: true,
      systemNotificationsEnabled: true,
      moveNotifiedWorktreeToTop: false,
      analyticsEnabled: false,
      crashReportsEnabled: true,
      githubIntegrationEnabled: true,
      deleteBranchOnDeleteWorktree: false,
      mergedWorktreeAction: .archive,
      promptForWorktreeCreation: true
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = loaded }

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.task)
    await store.receive(\.settingsLoaded) {
      $0.appearanceMode = .dark
      $0.defaultEditorID = OpenWorktreeAction.automaticSettingsID
      $0.confirmBeforeQuit = true
      $0.updateChannel = .stable
      $0.updatesAutomaticallyCheckForUpdates = false
      $0.updatesAutomaticallyDownloadUpdates = true
      $0.inAppNotificationsEnabled = false
      $0.notificationSoundEnabled = true
      $0.moveNotifiedWorktreeToTop = false
      $0.systemNotificationsEnabled = true
      $0.analyticsEnabled = false
      $0.crashReportsEnabled = true
      $0.githubIntegrationEnabled = true
      $0.deleteBranchOnDeleteWorktree = false
      $0.mergedWorktreeAction = .archive
      $0.promptForWorktreeCreation = true
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func savesUpdatesChanges() async {
    let initialSettings = GlobalSettings(
      appearanceMode: .system,
      defaultEditorID: OpenWorktreeAction.automaticSettingsID,
      confirmBeforeQuit: true,
      updateChannel: .stable,
      updatesAutomaticallyCheckForUpdates: false,
      updatesAutomaticallyDownloadUpdates: false,
      inAppNotificationsEnabled: false,
      notificationSoundEnabled: false,
      systemNotificationsEnabled: false,
      moveNotifiedWorktreeToTop: true,
      analyticsEnabled: true,
      crashReportsEnabled: false,
      githubIntegrationEnabled: true,
      deleteBranchOnDeleteWorktree: true,
      mergedWorktreeAction: nil,
      promptForWorktreeCreation: false
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.appearanceMode, .light))) {
      $0.appearanceMode = .light
    }
    let expectedSettings = GlobalSettings(
      appearanceMode: .light,
      defaultEditorID: initialSettings.defaultEditorID,
      confirmBeforeQuit: initialSettings.confirmBeforeQuit,
      updateChannel: initialSettings.updateChannel,
      updatesAutomaticallyCheckForUpdates: initialSettings.updatesAutomaticallyCheckForUpdates,
      updatesAutomaticallyDownloadUpdates: initialSettings.updatesAutomaticallyDownloadUpdates,
      inAppNotificationsEnabled: initialSettings.inAppNotificationsEnabled,
      notificationSoundEnabled: initialSettings.notificationSoundEnabled,
      systemNotificationsEnabled: initialSettings.systemNotificationsEnabled,
      moveNotifiedWorktreeToTop: initialSettings.moveNotifiedWorktreeToTop,
      analyticsEnabled: initialSettings.analyticsEnabled,
      crashReportsEnabled: initialSettings.crashReportsEnabled,
      githubIntegrationEnabled: initialSettings.githubIntegrationEnabled,
      deleteBranchOnDeleteWorktree: initialSettings.deleteBranchOnDeleteWorktree,
      mergedWorktreeAction: initialSettings.mergedWorktreeAction,
      promptForWorktreeCreation: initialSettings.promptForWorktreeCreation
    )
    await store.receive(\.delegate.settingsChanged)

    expectNoDifference(settingsFile.global, expectedSettings)
  }

  @Test(.dependencies) func setSystemNotificationsEnabledPersistsChanges() async {
    var initialSettings = GlobalSettings.default
    initialSettings.systemNotificationsEnabled = false
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.setSystemNotificationsEnabled(true)) {
      $0.systemNotificationsEnabled = true
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.systemNotificationsEnabled == true)
  }

  @Test(.dependencies) func refreshDockBadgeAuthorizationStoresSystemState() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.systemNotificationClient.dockBadgeAuthorization = { .badgeDisabled }
    }

    await store.send(.refreshDockBadgeAuthorization)
    await store.receive(\.dockBadgeAuthorizationResponse) {
      $0.dockBadgeAuthorization = .badgeDisabled
    }
  }

  @Test(.dependencies) func selectionDoesNotMutateRepositorySettings() async {
    let selection = SettingsSection.repository("repo-id")
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.setSelection(selection)) {
      $0.selection = selection
    }

    await store.send(.setSelection(.general)) {
      $0.selection = .general
    }
  }

  @Test(.dependencies) func loadingSettingsDoesNotResetSelection() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let selection = SettingsSection.repository("repo-id")
    var state = SettingsFeature.State()
    state.selection = selection
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .git,
      settings: .default,
      userSettings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    let loaded = GlobalSettings(
      appearanceMode: .light,
      defaultEditorID: OpenWorktreeAction.automaticSettingsID,
      confirmBeforeQuit: false,
      updateChannel: .tip,
      updatesAutomaticallyCheckForUpdates: false,
      updatesAutomaticallyDownloadUpdates: true,
      inAppNotificationsEnabled: false,
      notificationSoundEnabled: false,
      systemNotificationsEnabled: true,
      moveNotifiedWorktreeToTop: true,
      analyticsEnabled: true,
      crashReportsEnabled: false,
      githubIntegrationEnabled: true,
      deleteBranchOnDeleteWorktree: true,
      mergedWorktreeAction: .archive,
      promptForWorktreeCreation: false
    )

    await store.send(.settingsLoaded(loaded)) {
      $0.appearanceMode = .light
      $0.defaultEditorID = OpenWorktreeAction.automaticSettingsID
      $0.confirmBeforeQuit = false
      $0.updateChannel = .tip
      $0.updatesAutomaticallyCheckForUpdates = false
      $0.updatesAutomaticallyDownloadUpdates = true
      $0.inAppNotificationsEnabled = false
      $0.notificationSoundEnabled = false
      $0.moveNotifiedWorktreeToTop = true
      $0.systemNotificationsEnabled = true
      $0.analyticsEnabled = true
      $0.crashReportsEnabled = false
      $0.githubIntegrationEnabled = true
      $0.deleteBranchOnDeleteWorktree = true
      $0.mergedWorktreeAction = .archive
      $0.promptForWorktreeCreation = false
      $0.selection = selection
      $0.repositorySettings = RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .git,
        settings: .default,
        userSettings: .default
      )
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func settingsLoadedNormalizesDefaultWorktreeBaseDirectoryPath() async {
    var loaded = GlobalSettings.default
    loaded.defaultWorktreeBaseDirectoryPath = " ~/worktrees "
    let expectedPath = SupacodePaths.normalizedWorktreeBaseDirectoryPath(" ~/worktrees ")!
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    }

    await store.send(.settingsLoaded(loaded)) {
      $0.defaultWorktreeBaseDirectoryPath = expectedPath
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(store.state.defaultWorktreeBaseDirectoryPath == expectedPath)
  }

  @Test(.dependencies) func changingDefaultWorktreeBaseDirectoryUpdatesRepositorySettingsState() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let expectedPath = SupacodePaths.normalizedWorktreeBaseDirectoryPath(" ~/worktrees ")!
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    var state = SettingsFeature.State()
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .git,
      settings: .default,
      userSettings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.defaultWorktreeBaseDirectoryPath, " ~/worktrees "))) {
      $0.defaultWorktreeBaseDirectoryPath = " ~/worktrees "
      $0.repositorySettings?.globalDefaultWorktreeBaseDirectoryPath = expectedPath
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(store.state.repositorySettings?.globalDefaultWorktreeBaseDirectoryPath == expectedPath)
    #expect(settingsFile.global.defaultWorktreeBaseDirectoryPath == expectedPath)
  }

  @Test(.dependencies) func changingCanvasDefaultLayoutPersists() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }
    // Default is Tile; switch to Uniform and confirm it persists.
    #expect(store.state.canvasDefaultLayout == .tile)
    await store.send(.binding(.set(\.canvasDefaultLayout, .uniform))) {
      $0.canvasDefaultLayout = .uniform
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.canvasDefaultLayout == .uniform)
  }

  @Test(.dependencies) func changingGlobalOverrideDefaultsUpdatesRepositorySettingsState() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    var state = SettingsFeature.State()
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .git,
      settings: .default,
      userSettings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.copyIgnoredOnWorktreeCreate, true))) {
      $0.copyIgnoredOnWorktreeCreate = true
      $0.repositorySettings?.globalCopyIgnoredOnWorktreeCreate = true
    }
    await store.receive(\.delegate.settingsChanged)

    await store.send(.binding(.set(\.copyUntrackedOnWorktreeCreate, true))) {
      $0.copyUntrackedOnWorktreeCreate = true
      $0.repositorySettings?.globalCopyUntrackedOnWorktreeCreate = true
    }
    await store.receive(\.delegate.settingsChanged)

    await store.send(.binding(.set(\.pullRequestMergeStrategy, .squash))) {
      $0.pullRequestMergeStrategy = .squash
      $0.repositorySettings?.globalPullRequestMergeStrategy = .squash
    }
    await store.receive(\.delegate.settingsChanged)

    #expect(store.state.repositorySettings?.globalCopyIgnoredOnWorktreeCreate == true)
    #expect(store.state.repositorySettings?.globalCopyUntrackedOnWorktreeCreate == true)
    #expect(store.state.repositorySettings?.globalPullRequestMergeStrategy == .squash)
    #expect(settingsFile.global.copyIgnoredOnWorktreeCreate == true)
    #expect(settingsFile.global.copyUntrackedOnWorktreeCreate == true)
    #expect(settingsFile.global.pullRequestMergeStrategy == .squash)
  }

  @Test(.dependencies) func setTerminalFontSizePersistsWithoutAnalyticsOrGlobalFanout() async {
    var initialSettings = GlobalSettings.default
    initialSettings.analyticsEnabled = true
    initialSettings.terminalFontSize = nil
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }
    let capturedEvents = LockIsolated<[String]>([])

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { event, _ in
        capturedEvents.withValue { $0.append(event) }
      }
    }

    await store.send(.setTerminalFontSize(18)) {
      $0.terminalFontSize = 18
    }
    await store.receive(\.delegate.terminalFontSizeChanged)
    await store.finish()

    #expect(settingsFile.global.terminalFontSize == 18)
    #expect(capturedEvents.value.isEmpty)
  }

  @Test(.dependencies) func setTerminalFontSizeIgnoresDuplicateValue() async {
    var initialSettings = GlobalSettings.default
    initialSettings.analyticsEnabled = true
    initialSettings.terminalFontSize = 18
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }
    let capturedEvents = LockIsolated<[String]>([])

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { event, _ in
        capturedEvents.withValue { $0.append(event) }
      }
    }

    await store.send(.setTerminalFontSize(18))
    await store.finish()

    #expect(settingsFile.global.terminalFontSize == 18)
    #expect(capturedEvents.value.isEmpty)
  }

  @Test(.dependencies) func keybindingOverridesPersistAndFanOut() async {
    var initialSettings = GlobalSettings.default
    initialSettings.keybindingUserOverrides = .empty
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let overrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.openSettings: KeybindingUserOverride(
          binding: Keybinding(key: ";", modifiers: .init(command: true))
        )
      ]
    )

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.keybindingUserOverrides, overrides))) {
      $0.keybindingUserOverrides = overrides
    }
    await store.receive(\.delegate.settingsChanged)

    #expect(settingsFile.global.keybindingUserOverrides == overrides)
  }

  @Test(.dependencies) func autoShowActiveAgentsPanelPersistsChanges() async {
    var initialSettings = GlobalSettings.default
    initialSettings.autoShowActiveAgentsPanel = false
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.autoShowActiveAgentsPanel, true))) {
      $0.autoShowActiveAgentsPanel = true
    }
    await store.receive(\.delegate.settingsChanged)

    #expect(settingsFile.global.autoShowActiveAgentsPanel == true)
  }

  @Test(.dependencies) func telegramSettingsPersistAndFanOut() async {
    var initialSettings = GlobalSettings.default
    initialSettings.telegramBotEnabled = false
    initialSettings.telegramBotToken = nil
    initialSettings.telegramAllowedUserIDs = []
    initialSettings.telegramDefaultReadLines = 80
    initialSettings.telegramRequireExplicitPaneForWrite = true
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.telegramBotEnabled, true))) {
      $0.telegramBotEnabled = true
    }
    await store.receive(\.delegate.settingsChanged)

    await store.send(.binding(.set(\.telegramBotToken, " 123:abc "))) {
      $0.telegramBotToken = " 123:abc "
    }
    await store.receive(\.delegate.settingsChanged)

    await store.send(.setTelegramAllowedUserIDsText("42, 99")) {
      $0.telegramAllowedUserIDsText = "42, 99"
      $0.telegramAllowedUserIDs = [42, 99]
    }
    await store.receive(\.delegate.settingsChanged)

    await store.send(.binding(.set(\.telegramDefaultReadLines, 25))) {
      $0.telegramDefaultReadLines = 25
    }
    await store.receive(\.delegate.settingsChanged)

    #expect(settingsFile.global.telegramBotEnabled == true)
    #expect(settingsFile.global.telegramBotToken == "123:abc")
    #expect(settingsFile.global.telegramAllowedUserIDs == [42, 99])
    #expect(settingsFile.global.telegramDefaultReadLines == 25)
    #expect(settingsFile.global.telegramRequireExplicitPaneForWrite == true)
  }

  @Test(.dependencies) func telegramConnectionTestUsesConfiguredToken() async {
    var initialSettings = GlobalSettings.default
    initialSettings.telegramBotToken = "token"
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }
    let requestedTokens = LockIsolated<[String]>([])

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    } withDependencies: {
      $0[TelegramBotClient.self].getMe = { token in
        requestedTokens.withValue { $0.append(token) }
        return TelegramBotUser(id: 1, isBot: true, firstName: "Prowl", username: "prowl_bot")
      }
    }

    await store.send(.testTelegramConnectionButtonTapped) {
      $0.telegramConnectionStatus = .testing
    }
    await store.receive(\.telegramConnectionTestCompleted) {
      $0.telegramConnectionStatus = .success("@prowl_bot")
    }

    #expect(requestedTokens.value == ["token"])
  }

  @Test(.dependencies) func showActiveAgentTabTitlesPersistsChanges() async {
    var initialSettings = GlobalSettings.default
    initialSettings.showActiveAgentTabTitles = false
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.showActiveAgentTabTitles, true))) {
      $0.showActiveAgentTabTitles = true
    }
    await store.receive(\.delegate.settingsChanged)

    #expect(settingsFile.global.showActiveAgentTabTitles == true)
  }

  @Test(.dependencies) func showActiveAgentStatusInShelfPersistsChanges() async {
    var initialSettings = GlobalSettings.default
    initialSettings.showActiveAgentStatusInShelf = true
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.showActiveAgentStatusInShelf, false))) {
      $0.showActiveAgentStatusInShelf = false
    }
    await store.receive(\.delegate.settingsChanged)

    #expect(settingsFile.global.showActiveAgentStatusInShelf == false)
  }

  @Test(.dependencies) func disablingAnalyticsResetsClient() async {
    var initialSettings = GlobalSettings.default
    initialSettings.analyticsEnabled = true
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }
    let resetCount = LockIsolated(0)

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
      $0.analyticsClient.reset = {
        resetCount.withValue { $0 += 1 }
      }
    }

    await store.send(.binding(.set(\.analyticsEnabled, false))) {
      $0.analyticsEnabled = false
    }
    await store.receive(\.delegate.settingsChanged)
    await store.finish()

    #expect(resetCount.value == 1)
    #expect(settingsFile.global.analyticsEnabled == false)
  }

  @Test(.dependencies) func togglingOtherSettingWhileAnalyticsOffDoesNotReset() async {
    var initialSettings = GlobalSettings.default
    initialSettings.analyticsEnabled = false
    initialSettings.confirmBeforeQuit = true
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }
    let resetCount = LockIsolated(0)

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
      $0.analyticsClient.reset = {
        resetCount.withValue { $0 += 1 }
      }
    }

    await store.send(.binding(.set(\.confirmBeforeQuit, false))) {
      $0.confirmBeforeQuit = false
    }
    await store.receive(\.delegate.settingsChanged)
    await store.finish()

    #expect(resetCount.value == 0)
  }

  @Test(.dependencies) func clearTerminalLayoutSnapshotSendsDelegate() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.terminalLayoutPersistence.clearSnapshot = { true }
    }

    await store.send(.clearTerminalLayoutSnapshotButtonTapped)
    await store.receive(\.delegate.terminalLayoutSnapshotCleared)
  }
}
