import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

@MainActor
struct AppFeatureDefaultEditorTests {
  nonisolated private static var xcodeInstalled: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") != nil
  }
  @Test(.dependencies) func defaultEditorAppliesToAutomaticRepositorySettings() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json"
    )
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    } operation: {
      var settings = GlobalSettings.default
      settings.defaultEditorID = OpenWorktreeAction.finder.settingsID
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global = settings }
      return TestStore(
        initialState: AppFeature.State(
          repositories: repositoriesState,
          settings: SettingsFeature.State(settings: settings)
        )
      ) {
        AppFeature()
      }
    }

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.receive(\.worktreeSettingsLoaded)
    await store.receive(\.worktreeUserSettingsLoaded)
    #expect(store.state.openActionSelection == .finder)
    #expect(store.state.selectedRunScript == "")
    await store.finish()
  }

  @Test(.dependencies) func repositoryLocalSettingsOverrideGlobalRepositorySettings() async throws {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json"
    )
    let repositoryID = worktree.repositoryRootURL.standardizedFileURL.path(percentEncoded: false)
    var globalRepositorySettings = RepositorySettings.default
    globalRepositorySettings.openActionID = OpenWorktreeAction.finder.settingsID
    var localRepositorySettings = RepositorySettings.default
    localRepositorySettings.openActionID = OpenWorktreeAction.terminal.settingsID
    localRepositorySettings.runScript = "pnpm dev"

    withDependencies {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalRepositorySettings
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try localStorage.save(
      encoder.encode(localRepositorySettings),
      at: ProwlPaths.repositorySettingsURL(for: worktree.repositoryRootURL)
    )

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.receive(\.worktreeSettingsLoaded) {
      $0.openActionSelection = .terminal
      $0.openActionIsAutomatic = false
      $0.selectedRunScript = "pnpm dev"
    }
    await store.receive(\.worktreeUserSettingsLoaded)
    await store.finish()
  }

  @Test(.dependencies, .enabled(if: xcodeInstalled))
  func automaticSelectionPrefersXcodeForSwiftPackageWorktree() async throws {
    let worktree = makeWorktree()
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: worktree.workingDirectory,
      withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: worktree.repositoryRootURL) }
    try Data().write(to: worktree.workingDirectory.appending(path: "Package.swift"))
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json"
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    }

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.receive(\.worktreeSettingsLoaded) {
      $0.openActionSelection = .xcode
    }
    await store.receive(\.worktreeUserSettingsLoaded)
    await store.finish()
  }

  @Test(.dependencies) func selectedWorktreeChangedOnlyUpdatesWatcherSelection() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let expectedOpenActionSelection = OpenWorktreeAction.preferredDefault()
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json"
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { _ in }
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    }

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.receive(\.worktreeSettingsLoaded) {
      $0.openActionSelection = expectedOpenActionSelection
    }
    await store.receive(\.worktreeUserSettingsLoaded)
    await store.finish()

    #expect(watcherCommands.value == [.setSelectedWorktreeID(worktree.id)])
  }

  @Test(.dependencies) func selectingAppPinsItAndClearsAutomatic() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json"
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }

    await store.send(.openActionSelectionChanged(.terminal)) {
      $0.openActionSelection = .terminal
      $0.openActionIsAutomatic = false
    }
    await store.finish()
  }

  @Test(.dependencies) func resetToAutomaticClearsRepositoryPinAndReopens() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json"
    )
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      var settings = GlobalSettings.default
      settings.defaultEditorID = OpenWorktreeAction.finder.settingsID
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global = settings }
      var initialState = AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State(settings: settings)
      )
      // Simulate a worktree whose repository has pinned a specific app.
      initialState.openActionSelection = .terminal
      initialState.openActionIsAutomatic = false
      return TestStore(initialState: initialState) {
        AppFeature()
      }
    }
    store.exhaustivity = .off

    await store.send(.openActionResetToAutomatic) {
      $0.openActionSelection = .finder
      $0.openActionIsAutomatic = true
    }
    await store.receive(\.openSelectedWorktree)
    await store.receive(\.openWorktree)
  }

  @Test(.dependencies) func selectingAppSyncsOpenRepositorySettingsPane() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json"
    )
    var initialState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    initialState.settings.repositorySettings = RepositorySettingsFeature.State(
      location: .local(worktree.repositoryRootURL),
      repositoryKind: .git,
      settings: .default,
      userSettings: .default
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }
    store.exhaustivity = .off

    await store.send(.openActionSelectionChanged(.terminal)) {
      $0.openActionSelection = .terminal
      $0.openActionIsAutomatic = false
      $0.settings.repositorySettings?.settings.openActionID =
        OpenWorktreeAction.terminal.settingsID
    }
    // Editing any field in the still-open pane writes its whole snapshot back.
    await store.send(
      .settings(.repositorySettings(.binding(.set(\.settings.customTitle, "Edited")))))
    await store.skipReceivedActions()

    let storedOpenActionID = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
      return repositorySettings.openActionID
    }
    #expect(storedOpenActionID == OpenWorktreeAction.terminal.settingsID)
  }

  @Test(.dependencies) func resetToAutomaticSyncsOpenRepositorySettingsPane() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json"
    )
    var pinnedSettings = RepositorySettings.default
    pinnedSettings.openActionID = OpenWorktreeAction.terminal.settingsID
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
      $repositorySettings.withLock { $0 = pinnedSettings }
      var initialState = AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
      initialState.openActionSelection = .terminal
      initialState.openActionIsAutomatic = false
      initialState.settings.repositorySettings = RepositorySettingsFeature.State(
        location: .local(worktree.repositoryRootURL),
        repositoryKind: .git,
        settings: pinnedSettings,
        userSettings: .default
      )
      return TestStore(initialState: initialState) {
        AppFeature()
      }
    }
    store.exhaustivity = .off

    await store.send(.openActionResetToAutomatic) {
      $0.openActionIsAutomatic = true
      $0.settings.repositorySettings?.settings.openActionID =
        OpenWorktreeAction.automaticSettingsID
    }
    await store.skipReceivedActions()
    await store.send(
      .settings(.repositorySettings(.binding(.set(\.settings.customTitle, "Edited")))))
    await store.skipReceivedActions()

    let storedOpenActionID = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
      return repositorySettings.openActionID
    }
    #expect(storedOpenActionID == OpenWorktreeAction.automaticSettingsID)
  }

  private func makeWorktree() -> Worktree {
    let repositoryRootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let worktreeURL = repositoryRootURL.appending(path: "wt-1")
    return Worktree(
      id: worktreeURL.path(percentEncoded: false),
      name: "wt-1",
      detail: "detail",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: worktree.repositoryRootURL.path(percentEncoded: false),
      rootURL: worktree.repositoryRootURL,
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }
}
