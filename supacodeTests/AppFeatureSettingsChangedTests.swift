import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(
  .serialized,
  .dependency(\.defaultAppStorage, .appFeatureSettingsChangedTests)
)
struct AppFeatureSettingsChangedTests {
  @Test(.dependencies) func settingsChangedPropagatesRepositorySettings() async {
    var settings = GlobalSettings.default
    settings.githubIntegrationEnabled = false
    settings.mergedWorktreeAction = .archive
    settings.moveNotifiedWorktreeToTop = false
    settings.showActiveAgentTabTitles = true
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.settings(.delegate(.settingsChanged(settings)))) {
      $0.repositories.showActiveAgentTabTitles = true
    }
    await store.receive(\.repositories.githubIntegration.setGithubIntegrationEnabled) {
      $0.repositories.githubIntegrationAvailability = .disabled
    }
    await store.receive(\.repositories.githubIntegration.setMergedWorktreeAction) {
      $0.repositories.mergedWorktreeAction = .archive
    }
    await store.receive(\.repositories.setArchivedAutoDeletePeriod)
    await store.receive(\.repositories.worktreeOrdering.setMoveNotifiedWorktreeToTop) {
      $0.repositories.moveNotifiedWorktreeToTop = false
    }
    await store.receive(\.updates.applySettings) {
      $0.updates.didConfigureUpdates = true
    }
    await store.finish()
  }

  @Test(.dependencies) func terminalFontSizeEventDoesNotFanOutGlobalSettingsEffects() async {
    let sentTerminalCommands = LockIsolated<[TerminalClient.Command]>([])
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentTerminalCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.terminalEvent(.fontSizeChanged(18)))
    await store.receive(\.settings.setTerminalFontSize) {
      $0.settings.terminalFontSize = 18
    }
    await store.receive(\.settings.delegate.terminalFontSizeChanged)
    await store.finish()

    #expect(sentTerminalCommands.value.isEmpty)
    #expect(watcherCommands.value.isEmpty)
  }

  @Test(.dependencies) func settingsChangedPropagatesAnonymousTmuxGlobalSetting() async {
    let sentTerminalCommands = LockIsolated<[TerminalClient.Command]>([])
    var settings = GlobalSettings.default
    settings.useAnonymousTmuxBackedTerminals = true

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentTerminalCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()

    #expect(sentTerminalCommands.value.contains(.setAnonymousTmuxBackedTerminalsEnabled(true)))
  }

  @Test(.dependencies) func settingsChangedEnablesAgentDetectionWhenActiveAgentsPanelVisible() async {
    let sentTerminalCommands = LockIsolated<[TerminalClient.Command]>([])
    UserDefaults.appFeatureSettingsChangedTests.set(false, forKey: "activeAgentsPanelHidden")

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentTerminalCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.settingsChanged(.default))))
    await store.finish()

    #expect(sentTerminalCommands.value.contains(.setAgentDetectionEnabled(true)))
  }

  @Test(.dependencies) func settingsChangedEnablesAgentDetectionWhenAutoShowActiveAgentsPanelEnabled() async {
    let sentTerminalCommands = LockIsolated<[TerminalClient.Command]>([])
    var settings = GlobalSettings.default
    settings.autoShowActiveAgentsPanel = true
    UserDefaults.appFeatureSettingsChangedTests.set(true, forKey: "activeAgentsPanelHidden")

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentTerminalCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()

    #expect(sentTerminalCommands.value.contains(.setAgentDetectionEnabled(true)))
  }

  @Test(.dependencies) func openingActiveAgentsPanelEnablesAgentDetection() async {
    let sentTerminalCommands = LockIsolated<[TerminalClient.Command]>([])
    UserDefaults.appFeatureSettingsChangedTests.set(true, forKey: "activeAgentsPanelHidden")

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentTerminalCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.activeAgents(.togglePanelVisibility))) {
      $0.repositories.activeAgents.$isPanelHidden.withLock { $0 = false }
    }
    await store.finish()

    #expect(sentTerminalCommands.value.contains(.setAgentDetectionEnabled(true)))
  }

  @Test(.dependencies) func agentEntryAutoShowsActiveAgentsPanelInCanvasWhenEnabled() async {
    var settings = SettingsFeature.State()
    settings.autoShowActiveAgentsPanel = true
    var state = AppFeature.State(settings: settings)
    state.repositories.selection = .canvas
    state.repositories.activeAgents.$isPanelHidden.withLock { $0 = true }
    let entry = activeAgentEntry()

    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.terminalEvent(.agentEntryChanged(entry))) {
      $0.repositories.activeAgents.$isPanelHidden.withLock { $0 = false }
    }
    await store.receive(\.repositories.activeAgents.agentEntryChanged) {
      $0.repositories.activeAgents.entries = [entry]
    }
  }

  @Test(.dependencies) func agentEntryKeepsActiveAgentsPanelHiddenOutsideCanvasWhenEnabled() async {
    var settings = SettingsFeature.State()
    settings.autoShowActiveAgentsPanel = true
    var state = AppFeature.State(settings: settings)
    state.repositories.activeAgents.$isPanelHidden.withLock { $0 = true }
    let entry = activeAgentEntry()

    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.terminalEvent(.agentEntryChanged(entry)))
    await store.receive(\.repositories.activeAgents.agentEntryChanged) {
      $0.repositories.activeAgents.entries = [entry]
    }
  }

  @Test(.dependencies) func agentEntryKeepsActiveAgentsPanelHiddenInShelfWhenEnabled() async {
    var settings = SettingsFeature.State()
    settings.autoShowActiveAgentsPanel = true
    var state = AppFeature.State(settings: settings)
    state.repositories.isShelfActive = true
    state.repositories.activeAgents.$isPanelHidden.withLock { $0 = true }
    let entry = activeAgentEntry()

    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.terminalEvent(.agentEntryChanged(entry)))
    await store.receive(\.repositories.activeAgents.agentEntryChanged) {
      $0.repositories.activeAgents.entries = [entry]
    }
  }

  @Test(.dependencies) func agentEntryKeepsActiveAgentsPanelHiddenInCanvasWhenAutoShowDisabled()
    async
  {
    var settings = SettingsFeature.State()
    settings.autoShowActiveAgentsPanel = false
    var state = AppFeature.State(settings: settings)
    state.repositories.selection = .canvas
    state.repositories.activeAgents.$isPanelHidden.withLock { $0 = true }
    let entry = activeAgentEntry()

    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.terminalEvent(.agentEntryChanged(entry)))
    await store.receive(\.repositories.activeAgents.agentEntryChanged) {
      $0.repositories.activeAgents.entries = [entry]
    }
  }

  @Test(.dependencies) func lastAgentEntryRemovedHidesOpenActiveAgentsPanelInCanvasWhenEnabled()
    async
  {
    var settings = SettingsFeature.State()
    settings.autoShowActiveAgentsPanel = true
    var state = AppFeature.State(settings: settings)
    state.repositories.selection = .canvas
    let entry = activeAgentEntry()
    state.repositories.activeAgents.entries = [entry]
    state.repositories.activeAgents.$isPanelHidden.withLock { $0 = false }

    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.terminalEvent(.agentEntryRemoved(entry.id))) {
      $0.repositories.activeAgents.$isPanelHidden.withLock { $0 = true }
    }
    await store.receive(\.repositories.activeAgents.agentEntryRemoved) {
      $0.repositories.activeAgents.entries = []
    }
  }

  @Test(.dependencies) func agentEntryRemovedKeepsOpenActiveAgentsPanelOutsideCanvasWhenEnabled()
    async
  {
    var settings = SettingsFeature.State()
    settings.autoShowActiveAgentsPanel = true
    var state = AppFeature.State(settings: settings)
    let entry = activeAgentEntry()
    state.repositories.activeAgents.entries = [entry]
    state.repositories.activeAgents.$isPanelHidden.withLock { $0 = false }

    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.terminalEvent(.agentEntryRemoved(entry.id)))
    await store.receive(\.repositories.activeAgents.agentEntryRemoved) {
      $0.repositories.activeAgents.entries = []
    }
  }

  @Test func appStateInitializesActiveAgentTabTitleDisplayFromSettings() {
    var settings = SettingsFeature.State()
    settings.showActiveAgentTabTitles = true

    let state = AppFeature.State(settings: settings)

    #expect(state.repositories.showActiveAgentTabTitles == true)
  }

  @Test(.dependencies) func settingsChangedRecomputesResolvedKeybindings() async {
    var settings = GlobalSettings.default
    settings.keybindingUserOverrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.openSettings: KeybindingUserOverride(
          binding: Keybinding(key: ";", modifiers: .init(command: true))
        )
      ]
    )

    let expectedResolved = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: settings.keybindingUserOverrides
    )

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.settings(.delegate(.settingsChanged(settings)))) {
      $0.settings.keybindingUserOverrides = settings.keybindingUserOverrides
      $0.resolvedKeybindings = expectedResolved
    }
    await store.receive(\.repositories.githubIntegration.setGithubIntegrationEnabled)
    await store.receive(\.repositories.githubIntegration.setMergedWorktreeAction)
    await store.receive(\.repositories.setArchivedAutoDeletePeriod)
    await store.receive(\.repositories.worktreeOrdering.setMoveNotifiedWorktreeToTop)
    await store.receive(\.updates.applySettings) {
      $0.updates.didConfigureUpdates = true
    }
    await store.receive(\.repositories.githubIntegration.refreshGithubIntegrationAvailability) {
      $0.repositories.githubIntegrationAvailability = .checking
    }
    await store.receive(\.repositories.githubIntegration.githubIntegrationAvailabilityUpdated) {
      $0.repositories.githubIntegrationAvailability = .available
      $0.repositories.queuedPullRequestRefreshByRepositoryID = [:]
      $0.repositories.inFlightPullRequestRefreshRepositoryIDs = []
    }

    expectNoDifference(
      store.state.resolvedKeybindings.display(for: AppShortcuts.CommandID.openSettings),
      "⌘;"
    )
  }

  @Test(.dependencies) func settingsChangedRegistersUserOverrideAppShortcutsForMenuPreference() async {
    let registeredShortcuts = LockIsolated<[[Keybinding]]>([])
    var settings = GlobalSettings.default
    settings.keybindingUserOverrides = KeybindingUserOverrideStore(
      overrides: [
        AppShortcuts.CommandID.toggleCanvasMaxMode: KeybindingUserOverride(
          binding: Keybinding(key: "return", modifiers: .init(command: true, control: true))
        )
      ]
    )

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.customShortcutRegistryClient.setShortcuts = { shortcuts in
        registeredShortcuts.withValue { $0.append(shortcuts) }
      }
    }

    await store.send(.settings(.delegate(.settingsChanged(settings)))) {
      $0.settings.keybindingUserOverrides = settings.keybindingUserOverrides
      $0.resolvedKeybindings = KeybindingResolver.resolve(
        schema: .appResolverSchema(),
        userOverrides: settings.keybindingUserOverrides
      )
    }
    await store.receive(\.repositories.githubIntegration.setGithubIntegrationEnabled)
    await store.receive(\.repositories.githubIntegration.setMergedWorktreeAction)
    await store.receive(\.repositories.setArchivedAutoDeletePeriod)
    await store.receive(\.repositories.worktreeOrdering.setMoveNotifiedWorktreeToTop)
    await store.receive(\.updates.applySettings) {
      $0.updates.didConfigureUpdates = true
    }
    await store.receive(\.repositories.githubIntegration.refreshGithubIntegrationAvailability) {
      $0.repositories.githubIntegrationAvailability = .checking
    }
    await store.receive(\.repositories.githubIntegration.githubIntegrationAvailabilityUpdated) {
      $0.repositories.githubIntegrationAvailability = .available
      $0.repositories.queuedPullRequestRefreshByRepositoryID = [:]
      $0.repositories.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()

    let registeredDisplays = registeredShortcuts.value.flatMap { $0 }.map(\.display)
    #expect(registeredDisplays.contains("⌘⌃↩"))
    #expect(registeredDisplays.contains("⌘1") == false)
  }

  @Test(.dependencies) func settingsChangedRegistersDefaultAppShortcutsForMenuPreference() async {
    let registeredShortcuts = LockIsolated<[[Keybinding]]>([])
    let settings = GlobalSettings.default

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.customShortcutRegistryClient.setShortcuts = { shortcuts in
        registeredShortcuts.withValue { $0.append(shortcuts) }
      }
    }

    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.receive(\.repositories.githubIntegration.setGithubIntegrationEnabled)
    await store.receive(\.repositories.githubIntegration.setMergedWorktreeAction)
    await store.receive(\.repositories.setArchivedAutoDeletePeriod)
    await store.receive(\.repositories.worktreeOrdering.setMoveNotifiedWorktreeToTop)
    await store.receive(\.updates.applySettings) {
      $0.updates.didConfigureUpdates = true
    }
    await store.receive(\.repositories.githubIntegration.refreshGithubIntegrationAvailability) {
      $0.repositories.githubIntegrationAvailability = .checking
    }
    await store.receive(\.repositories.githubIntegration.githubIntegrationAvailabilityUpdated) {
      $0.repositories.githubIntegrationAvailability = .available
      $0.repositories.queuedPullRequestRefreshByRepositoryID = [:]
      $0.repositories.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()

    let registeredDisplays = registeredShortcuts.value.flatMap { $0 }.map(\.display)
    #expect(registeredDisplays.contains("⌘⌃↩"))
    #expect(registeredDisplays.contains("⌘1") == false)
  }

  @Test(.dependencies) func clearTerminalLayoutSnapshotShowsSuccessToast() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.terminalLayoutSnapshotCleared(success: true))))
    await store.receive(\.repositories.showToast) {
      $0.repositories.statusToast = .success("Saved terminal layout cleared")
    }
  }

  private func activeAgentEntry() -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: fixedUUID(0),
      worktreeID: "/repo/wt",
      worktreeName: "wt",
      workingDirectory: nil,
      tabID: TerminalTabID(rawValue: fixedUUID(1)),
      tabTitle: "codex",
      surfaceID: fixedUUID(0),
      paneIndex: 1,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
      agent: .codex,
      rawState: .working,
      displayState: .working,
      lastChangedAt: Date(timeIntervalSince1970: 10)
    )
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepository(worktrees: [Worktree]) -> Repository {
    Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  private func fixedUUID(_ value: UInt8) -> UUID {
    UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }
}

extension UserDefaults {
  fileprivate nonisolated(unsafe) static let appFeatureSettingsChangedTests = UserDefaults(
    suiteName: "com.onevcat.Prowl.AppFeatureSettingsChangedTests"
  )!
}
