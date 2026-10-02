import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AppFeaturePlainFolderTerminalTests {
  @Test(.dependencies) func selectingPlainRepositoryLoadsSettingsAndSelectsTerminalTarget() async throws {
    let repository = makePlainRepository()
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json"
    )
    let sentTerminalCommands = LockIsolated<[TerminalClient.Command]>([])
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])

    var settingsFile = SettingsFile.default
    var repositorySettings = RepositorySettings.default
    repositorySettings.openActionID = OpenWorktreeAction.terminal.settingsID
    repositorySettings.runScript = "pnpm dev"
    settingsFile.repositories[repository.id] = repositorySettings
    try settingsStorage.storage.save(
      JSONEncoder().encode(settingsFile),
      settingsFileURL
    )

    let userSettings = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(
          title: "Watch",
          systemImage: "terminal",
          command: "pnpm test --watch",
          execution: .terminalInput,
          shortcut: nil
        )
      ]
    )
    try localStorage.save(
      JSONEncoder().encode(userSettings),
      at: SupacodePaths.userRepositorySettingsURL(for: repository.rootURL)
    )

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(repository: repository),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { _ in }
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
      $0.terminalClient.send = { command in
        sentTerminalCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.repositories(.selectRepository(repository.id))) {
      $0.repositories.selection = .repository(repository.id)
      $0.repositories.openedWorktreeIDs = [repository.id]
    }
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.receive(\.worktreeSettingsLoaded) {
      $0.openActionSelection = .terminal
      $0.openActionIsAutomatic = false
      $0.selectedRunScript = "pnpm dev"
    }
    await store.receive(\.worktreeUserSettingsLoaded) {
      $0.selectedCustomCommands = userSettings.customCommands.map {
        EffectiveCustomCommand(source: .repository, command: $0)
      }
      $0.resolvedKeybindings = KeybindingResolver.resolve(
        schema: .appResolverSchema(customCommands: userSettings.customCommands)
      )
    }
    await store.finish()

    #expect(
      sentTerminalCommands.value == [
        .setSelectedWorktreeID(repository.id)
      ]
    )
    #expect(
      watcherCommands.value == [
        .setSelectedWorktreeID(nil)
      ]
    )
  }

  @Test(.dependencies) func newTerminalUsesPlainRepositoryTerminalTarget() async {
    let repository = makePlainRepository()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(repository: repository, selected: true),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminal)
    await store.finish()

    #expect(
      sent.value == [
        .createTab(
          makePlainTerminalTarget(repository: repository),
          runSetupScriptIfNew: false
        )
      ]
    )
  }

  @Test(.dependencies) func conflictingCustomShortcutOverridesAppShortcutOnlyForSelectedRepository() async {
    let repository = makePlainRepository()
    let registeredShortcuts = LockIsolated<[UserCustomShortcut]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(repository: repository, selected: true),
      settings: SettingsFeature.State()
    )
    state.repositories.selection = .repository(repository.id)

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.customShortcutRegistryClient.setShortcuts = { shortcuts in
        registeredShortcuts.setValue(shortcuts)
      }
    }
    store.exhaustivity = .off

    #expect(
      store.state.resolvedKeybindings.display(for: AppShortcuts.CommandID.showDiff) == AppShortcuts.showDiff.display
    )

    let conflicted = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(
          title: "Build",
          systemImage: "hammer",
          command: "swift build",
          execution: .shellScript,
          shortcut: UserCustomShortcut(
            key: "y",
            modifiers: UserCustomShortcutModifiers(command: true, shift: true)
          )
        )
      ]
    )

    await store.send(.worktreeUserSettingsLoaded(conflicted, worktreeID: repository.id))

    let expectedShortcut = conflicted.customCommands[0].shortcut?.normalized()
    #expect(store.state.selectedCustomCommands.map(\.command) == conflicted.customCommands)
    #expect(registeredShortcuts.value == [expectedShortcut].compactMap { $0 })
    let customCommandID = LegacyCustomCommandShortcutMigration.customCommandBindingID(
      for: conflicted.customCommands[0].id
    )
    #expect(store.state.resolvedKeybindings.display(for: customCommandID) == expectedShortcut?.display)
    #expect(store.state.resolvedKeybindings.display(for: AppShortcuts.CommandID.showDiff) == nil)

    await store.send(.worktreeUserSettingsLoaded(.default, worktreeID: repository.id))
    await store.finish()

    #expect(store.state.selectedCustomCommands.isEmpty)
    #expect(registeredShortcuts.value.isEmpty)
    #expect(
      store.state.resolvedKeybindings.display(for: AppShortcuts.CommandID.showDiff) == AppShortcuts.showDiff.display
    )
  }

  @Test func logicalCustomDigitOverridesPhysicalAppDigitBinding() {
    let physicalDigit = Keybinding(
      key: "digit_1",
      modifiers: KeybindingModifiers(command: true)
    )
    var settings = SettingsFeature.State()
    settings.keybindingUserOverrides.overrides[AppShortcuts.CommandID.toggleAgentIsland] =
      KeybindingUserOverride(binding: physicalDigit)
    let command = EffectiveCustomCommand(
      source: .repository,
      command: UserCustomCommand(
        id: "build",
        title: "Build",
        systemImage: "hammer",
        command: "make build",
        execution: .shellScript,
        shortcut: physicalDigit.userCustomShortcut
      )
    )

    let resolved = AppFeature().resolvedKeybindings(
      settings: settings,
      customCommands: [command]
    )

    #expect(resolved.keybinding(for: command.keybindingID) != nil)
    #expect(resolved.keybinding(for: AppShortcuts.CommandID.toggleAgentIsland) == nil)
  }

  @Test(.dependencies) func customCommandUsesPlainRepositoryTerminalTarget() async {
    let repository = makePlainRepository()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(repository: repository, selected: true),
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      EffectiveCustomCommand(
        source: .repository,
        command: UserCustomCommand(
          title: "Watch",
          systemImage: "terminal",
          command: "pnpm test --watch",
          execution: .terminalInput,
          shortcut: nil
        ))
    ]
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.runCustomCommand(state.selectedCustomCommands[0].id))
    await store.finish()

    #expect(
      sent.value == [
        .insertText(
          makePlainTerminalTarget(repository: repository),
          text: "pnpm test --watch"
        )
      ]
    )
  }

  private func makePlainRepository() -> Repository {
    Repository(
      id: "/tmp/folder",
      rootURL: URL(fileURLWithPath: "/tmp/folder"),
      name: "folder",
      kind: .plain,
      worktrees: []
    )
  }

  private func makeRepositoriesState(
    repository: Repository,
    selected: Bool = false
  ) -> RepositoriesFeature.State {
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    if selected {
      repositoriesState.selection = .repository(repository.id)
    }
    return repositoriesState
  }

  private func makePlainTerminalTarget(repository: Repository) -> Worktree {
    Worktree(
      id: repository.id,
      name: repository.name,
      detail: repository.rootURL.path(percentEncoded: false),
      workingDirectory: repository.rootURL,
      repositoryRootURL: repository.rootURL
    )
  }
}
