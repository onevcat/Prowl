import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct RepositorySettingsFeatureTests {
  @Test(.dependencies) func plainFolderTaskLoadsWithoutGitRequests() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/folder-\(UUID().uuidString)")
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let expectedDefaultWorktreeBaseDirectoryPath =
      SupacodePaths.normalizedWorktreeBaseDirectoryPath("/tmp/worktrees")
    let storedSettings = RepositorySettings(
      setupScript: "echo setup",
      archiveScript: "echo archive",
      runScript: "npm run dev",
      openActionID: OpenWorktreeAction.automaticSettingsID,
      worktreeBaseRef: "origin/main",
      copyIgnoredOnWorktreeCreate: true,
      copyUntrackedOnWorktreeCreate: true,
      pullRequestMergeStrategy: .squash,
    )
    let storedOnevcatSettings = UserRepositorySettings(
      customCommands: [.default(index: 0)]
    )
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    let bareRepositoryRequests = LockIsolated(0)
    let branchRefRequests = LockIsolated(0)
    let automaticBaseRefRequests = LockIsolated(0)
    var settingsFile = SettingsFile.default
    settingsFile.global.defaultWorktreeBaseDirectoryPath = "/tmp/worktrees"
    settingsFile.repositories[repositoryID] = storedSettings
    let settingsData = try #require(try? JSONEncoder().encode(settingsFile))
    try #require(try? settingsStorage.storage.save(settingsData, settingsFileURL))

    let userSettingsData = try #require(try? JSONEncoder().encode(storedOnevcatSettings))
    try #require(
      try? localStorage.save(
        userSettingsData,
        at: SupacodePaths.userRepositorySettingsURL(for: rootURL)
      )
    )

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .plain,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
      $0.gitClient.isBareRepository = { _ in
        bareRepositoryRequests.withValue { $0 += 1 }
        return false
      }
      $0.gitClient.branchRefs = { _ in
        branchRefRequests.withValue { $0 += 1 }
        return []
      }
      $0.gitClient.automaticWorktreeBaseRef = { _ in
        automaticBaseRefRequests.withValue { $0 += 1 }
        return "origin/main"
      }
    }

    await store.send(.task)
    await store.receive(\.settingsLoaded, timeout: .seconds(5)) {
      $0.settings = storedSettings
      $0.userSettings = storedOnevcatSettings
      $0.globalDefaultWorktreeBaseDirectoryPath = expectedDefaultWorktreeBaseDirectoryPath
    }
    await store.finish(timeout: .seconds(5))

    #expect(store.state.isBranchDataLoaded == false)
    #expect(store.state.branchOptions.isEmpty)
    #expect(bareRepositoryRequests.value == 0)
    #expect(branchRefRequests.value == 0)
    #expect(automaticBaseRefRequests.value == 0)
  }

  @Test func plainFolderVisibilityHidesGitOnlySections() {
    let state = RepositorySettingsFeature.State(
      rootURL: URL(fileURLWithPath: "/tmp/folder"),
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )

    #expect(state.showsWorktreeSettings == false)
    #expect(state.showsPullRequestSettings == false)
    #expect(state.showsSetupScriptSettings == false)
    #expect(state.showsArchiveScriptSettings == false)
    #expect(state.showsRunScriptSettings == true)
    #expect(state.showsCustomCommandsSettings == true)
  }

  @Test(.dependencies) func conflictingCustomShortcutPersistsAsUserOverride() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .plain,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }

    let conflicted = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(
          title: "Run tests",
          systemImage: "terminal",
          command: "swift test",
          execution: .shellScript,
          shortcut: UserCustomShortcut(
            key: "b",
            modifiers: UserCustomShortcutModifiers(command: true)
          )
        )
      ]
    )

    await store.send(.binding(.set(\.userSettings, conflicted))) {
      $0.userSettings = conflicted
    }
    await store.receive(\.delegate.settingsChanged)

    let savedData = try #require(localStorage.data(at: SupacodePaths.userRepositorySettingsURL(for: rootURL)))
    let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: savedData)
    #expect(decoded.customCommands.first?.shortcut == conflicted.customCommands.first?.shortcut)
  }

  @Test(.dependencies) func customTitleBindingPersistsToRepositoryFile() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)

    // Pre-seed a per-repo settings file so save() writes through to it
    // instead of falling back to the global settings file.
    let seedData = try #require(try? JSONEncoder().encode(RepositorySettings.default))
    try #require(try? localStorage.save(seedData, at: repositorySettingsURL))

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .plain,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }

    await store.send(.binding(.set(\.settings.customTitle, "My Custom Repo"))) {
      $0.settings.customTitle = "My Custom Repo"
    }
    await store.receive(\.delegate.settingsChanged)

    let savedData = try #require(localStorage.data(at: repositorySettingsURL))
    let decoded = try JSONDecoder().decode(RepositorySettings.self, from: savedData)
    #expect(decoded.customTitle == "My Custom Repo")
  }

  @Test(.dependencies) func customTitleWhitespaceOnlyPersistsAsNil() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)

    let seedData = try #require(try? JSONEncoder().encode(RepositorySettings.default))
    try #require(try? localStorage.save(seedData, at: repositorySettingsURL))

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .plain,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }

    await store.send(.binding(.set(\.settings.customTitle, "   "))) {
      $0.settings.customTitle = "   "
    }
    await store.receive(\.delegate.settingsChanged)

    let savedData = try #require(localStorage.data(at: repositorySettingsURL))
    let decoded = try JSONDecoder().decode(RepositorySettings.self, from: savedData)
    #expect(decoded.customTitle == nil)
  }

  @Test(.dependencies) func lineChangesRefreshIntervalsPersistToRepositoryFile() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)

    let seedData = try #require(try? JSONEncoder().encode(RepositorySettings.default))
    try #require(try? localStorage.save(seedData, at: repositorySettingsURL))

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .git,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }

    await store.send(.binding(.set(\.settings.focusedLineChangesRefreshIntervalSeconds, 120))) {
      $0.settings.focusedLineChangesRefreshIntervalSeconds = 120
    }
    await store.receive(\.delegate.settingsChanged)

    await store.send(.binding(.set(\.settings.unfocusedLineChangesRefreshIntervalSeconds, 300))) {
      $0.settings.unfocusedLineChangesRefreshIntervalSeconds = 300
    }
    await store.receive(\.delegate.settingsChanged)

    let savedData = try #require(localStorage.data(at: repositorySettingsURL))
    let decoded = try JSONDecoder().decode(RepositorySettings.self, from: savedData)
    #expect(decoded.focusedLineChangesRefreshIntervalSeconds == 120)
    #expect(decoded.unfocusedLineChangesRefreshIntervalSeconds == 300)
  }

  @Test func lineChangesRefreshIntervalsDecodeWithDefaultAndMinimum() throws {
    let missingData = Data("{}".utf8)
    let missing = try JSONDecoder().decode(RepositorySettings.self, from: missingData)
    #expect(
      missing.focusedLineChangesRefreshIntervalSeconds
        == RepositorySettings.defaultFocusedLineChangesRefreshIntervalSeconds
    )
    #expect(
      missing.unfocusedLineChangesRefreshIntervalSeconds
        == RepositorySettings.defaultUnfocusedLineChangesRefreshIntervalSeconds
    )

    let lowData = Data(
      """
      {
        "focusedLineChangesRefreshIntervalSeconds": 1,
        "unfocusedLineChangesRefreshIntervalSeconds": 2
      }
      """.utf8
    )
    let low = try JSONDecoder().decode(RepositorySettings.self, from: lowData)
    #expect(low.focusedLineChangesRefreshIntervalSeconds == RepositorySettings.minimumLineChangesRefreshIntervalSeconds)
    #expect(
      low.unfocusedLineChangesRefreshIntervalSeconds == RepositorySettings.minimumLineChangesRefreshIntervalSeconds)
  }

  @Test(.dependencies) func taskLoadsLatestUserSettingsAfterAsyncGitProbe() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let gitProbeGate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)

    let initialUserSettings = UserRepositorySettings(
      customCommands: [.default(index: 0)]
    )
    let updatedUserSettings = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(
          title: "Updated",
          systemImage: "terminal",
          command: "echo updated",
          execution: .shellScript,
          shortcut: nil
        )
      ]
    )

    let initialData = try #require(try? JSONEncoder().encode(initialUserSettings))
    try #require(
      try? localStorage.save(
        initialData,
        at: SupacodePaths.userRepositorySettingsURL(for: rootURL)
      )
    )

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .git,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
      $0.gitClient.isBareRepository = { _ in
        await withCheckedContinuation { continuation in
          gitProbeGate.setValue(continuation)
        }
        return false
      }
      $0.gitClient.branchRefs = { _ in [] }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
    }

    await store.send(.task)

    for _ in 0..<50 {
      if gitProbeGate.value != nil {
        break
      }
      await Task.yield()
    }
    #expect(gitProbeGate.value != nil)

    await store.send(.binding(.set(\.userSettings, updatedUserSettings))) {
      $0.userSettings = updatedUserSettings
    }
    await store.receive(\.delegate.settingsChanged)

    let continuation = try #require(gitProbeGate.value)
    continuation.resume()

    await store.receive(\.settingsLoaded, timeout: .seconds(5))
    await store.receive(\.branchDataLoaded) {
      $0.defaultWorktreeBaseRef = "origin/main"
      $0.branchOptions = ["origin/main"]
      $0.isBranchDataLoaded = true
    }
    #expect(store.state.userSettings == updatedUserSettings)
  }
}
