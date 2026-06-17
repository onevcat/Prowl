import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

private struct ShellCommandRecord: Equatable, Sendable {
  var executableURL: URL
  var arguments: [String]
  var currentDirectoryURL: URL?
}

private struct WorkspaceAddRemoveFixture {
  var rootURL: URL
  var appURL: URL
  var apiURL: URL
  var webURL: URL
  var profileURL: URL
}

private struct WorkspaceBootstrapFixture {
  var rootURL: URL
  var profileURL: URL
}

private func normalizedPath(_ url: URL) -> String {
  var path = url.standardizedFileURL.path(percentEncoded: false)
  while path.count > 1, path.hasSuffix("/") {
    path.removeLast()
  }
  return path
}

private func makeWorkspaceAddRemoveFixture() throws -> WorkspaceAddRemoveFixture {
  let fixture = WorkspaceAddRemoveFixture(
    rootURL: FileManager.default.temporaryDirectory
      .appending(path: "prowl-settings-add-remove-\(UUID().uuidString)"),
    appURL: FileManager.default.temporaryDirectory
      .appending(path: "prowl-settings-app-\(UUID().uuidString)"),
    apiURL: FileManager.default.temporaryDirectory
      .appending(path: "prowl-settings-api-\(UUID().uuidString)"),
    webURL: FileManager.default.temporaryDirectory
      .appending(path: "prowl-settings-web-\(UUID().uuidString)"),
    profileURL: FileManager.default.temporaryDirectory
      .appending(path: "prowl-settings-add-remove-profiles-\(UUID().uuidString).json")
  )
  try FileManager.default.createDirectory(
    at: fixture.rootURL.appending(path: ProjectWorkspace.metadataDirectoryName),
    withIntermediateDirectories: true
  )
  try FileManager.default.createDirectory(at: fixture.appURL, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: fixture.apiURL, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: fixture.webURL, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: fixture.rootURL.appending(path: "api"), withIntermediateDirectories: true)
  try Data(
    """
    {
      "schema_version": "prowl.workspace.v1",
      "title": "Workspace",
      "repositories": [
        {
          "id": "app",
          "name": "App",
          "path": "app",
          "source_kind": "existing_path",
          "source_location": "\(fixture.appURL.path(percentEncoded: false))"
        },
        {
          "id": "api",
          "name": "API",
          "path": "api",
          "source_kind": "local_repository",
          "source_location": "\(fixture.apiURL.path(percentEncoded: false))"
        }
      ]
    }
    """.utf8
  )
  .write(to: ProjectWorkspace.metadataURL(for: fixture.rootURL))
  return fixture
}

private func makeWorkspaceBootstrapFixture() throws -> WorkspaceBootstrapFixture {
  let fixture = WorkspaceBootstrapFixture(
    rootURL: FileManager.default.temporaryDirectory
      .appending(path: "prowl-settings-bootstrap-\(UUID().uuidString)"),
    profileURL: FileManager.default.temporaryDirectory
      .appending(path: "prowl-settings-bootstrap-profiles-\(UUID().uuidString).json")
  )
  try FileManager.default.createDirectory(
    at: fixture.rootURL.appending(path: ProjectWorkspace.metadataDirectoryName),
    withIntermediateDirectories: true
  )
  try FileManager.default.createDirectory(
    at: fixture.rootURL.appending(path: "app"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: fixture.rootURL.appending(path: "api"), withIntermediateDirectories: true)
  try Data(
    """
    {
      "schema_version": "prowl.workspace.v1",
      "title": "Workspace",
      "repositories": [
        {
          "id": "app",
          "name": "App",
          "path": "app",
          "source_kind": "existing_path",
          "bootstrap": {
            "script_kind": "user_profile",
            "script_id": "sync-app",
            "run_on": ["manual"],
            "required": true
          }
        },
        {
          "id": "api",
          "name": "API",
          "path": "api",
          "source_kind": "existing_path"
        }
      ]
    }
    """.utf8
  )
  .write(to: ProjectWorkspace.metadataURL(for: fixture.rootURL))
  return fixture
}

private func recordingShellClient(
  commands: LockIsolated<[ShellCommandRecord]>,
  onRunLogin: @escaping @Sendable ([String]) throws -> Void = { _ in }
) -> ShellClient {
  ShellClient(
    run: { executableURL, arguments, currentDirectoryURL in
      commands.withValue {
        $0.append(
          ShellCommandRecord(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
          )
        )
      }
      return ShellOutput(stdout: "", stderr: "", exitCode: 0)
    },
    runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
      commands.withValue {
        $0.append(
          ShellCommandRecord(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
          )
        )
      }
      try onRunLogin(arguments)
      return ShellOutput(stdout: "", stderr: "", exitCode: 0)
    },
    runLoginStreamWithEnvironmentImpl: { executableURL, arguments, currentDirectoryURL, _, _ in
      commands.withValue {
        $0.append(
          ShellCommandRecord(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
          )
        )
      }
      return AsyncThrowingStream { continuation in
        continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
        continuation.finish()
      }
    }
  )
}

@MainActor
struct RepositorySettingsFeatureTests {
  @Test func githubAccountOverrideRoundTripsThroughRepositorySettings() throws {
    var settings = RepositorySettings.default
    settings.githubAccountOverride = GithubAccountOverride(host: "github.com", login: "work")

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(
      decoded.githubAccountOverride == GithubAccountOverride(host: "github.com", login: "work"))
  }

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

    let savedData = try #require(
      localStorage.data(at: SupacodePaths.userRepositorySettingsURL(for: rootURL)))
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

  @Test(.dependencies) func workspaceDraftSavesMetadataAndRegeneratesGuide() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-settings-workspace-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: ProjectWorkspace.metadataDirectoryName),
      withIntermediateDirectories: true
    )
    let metadataURL = ProjectWorkspace.metadataURL(for: rootURL)
    try Data(
      """
      {
        "schema_version": "prowl.workspace.v1",
        "title": "Old Workspace",
        "repositories": [
          {
            "id": "app",
            "name": "App",
            "path": "app",
            "source_kind": "existing_path"
          },
          {
            "id": "api",
            "name": "API",
            "path": "api",
            "source_kind": "existing_path"
          }
        ]
      }
      """.utf8
    )
    .write(to: metadataURL)

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    var state = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )
    state.setWorkspace(workspace)
    let store = TestStore(initialState: state) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 20)
    }

    await store.send(.workspaceTitleChanged("New Workspace")) {
      $0.workspaceDraft?.title = "New Workspace"
    }
    await store.send(.workspaceAgentGuideEnabledChanged(true)) {
      $0.workspaceDraft?.agentGuideEnabled = true
    }
    await store.send(.workspaceRepositoryRoleChanged(id: "app", "macOS app")) {
      $0.workspaceDraft?.repositories[0].role = "macOS app"
    }
    await store.send(.workspaceRepositoryAgentNotesChanged(id: "app", "Use reducer tests.")) {
      $0.workspaceDraft?.repositories[0].agentNotes = "Use reducer tests."
    }
    await store.send(.workspaceBootstrapIDChanged(id: "app", "sync-app")) {
      $0.workspaceDraft?.repositories[0].bootstrapScriptID = "sync-app"
    }
    await store.send(.workspaceBootstrapCreateChanged(id: "app", true)) {
      $0.workspaceDraft?.repositories[0].bootstrapRunOnCreate = true
    }
    await store.send(.saveWorkspaceMetadataButtonTapped)
    await store.receive(\.workspaceMetadataSaved) {
      $0.workspace?.title = "New Workspace"
      $0.workspace?.agentGuide = ProjectWorkspaceAgentGuide(enabled: true)
      $0.workspace?.repositories[0].role = "macOS app"
      $0.workspace?.repositories[0].agentNotes = "Use reducer tests."
      $0.workspace?.repositories[0].bootstrap = ProjectWorkspaceRepositoryBootstrap(
        scriptKind: .userProfile,
        scriptID: "sync-app",
        runOn: [.create]
      )
      $0.workspace?.updatedAt = Date(timeIntervalSince1970: 20)
      if let workspace = $0.workspace {
        $0.workspaceDraft = RepositorySettingsFeature.WorkspaceDraft(workspace: workspace)
      }
      $0.workspaceSaveStatus = "Saved workspace metadata."
      $0.workspaceSaveError = nil
    }
    await store.receive(\.delegate.settingsChanged)

    let saved = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(saved.title == "New Workspace")
    #expect(saved.repositories[0].agentNotes == "Use reducer tests.")
    #expect(saved.repositories[0].bootstrap?.scriptID == "sync-app")
    let guide = try String(contentsOf: rootURL.appending(path: "AGENTS.md"), encoding: .utf8)
    #expect(guide.contains("- Title: New Workspace"))
    #expect(guide.contains("- Agent notes: Use reducer tests."))
  }

  @Test(.dependencies) func workspaceSettingsAddRemoveRestoreAndSaveRepositoryChanges() async throws {
    let fixture = try makeWorkspaceAddRemoveFixture()
    let rootURL = fixture.rootURL
    let webURL = fixture.webURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.appURL)
      try? FileManager.default.removeItem(at: fixture.apiURL)
      try? FileManager.default.removeItem(at: fixture.webURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    let storage = SettingsTestStorage()
    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.bootstrapProfilesFileURL = fixture.profileURL
    } operation: {
      @Shared(.bootstrapProfiles) var storedProfiles: [ProjectWorkspaceBootstrapProfile]
      $storedProfiles.withLock { $0 = [] }
    }
    var state = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )
    state.setWorkspace(workspace)
    let commands = LockIsolated<[ShellCommandRecord]>([])
    let store = TestStore(initialState: state) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 50)
      $0.uuid = .incrementing
      $0.gitClient.repoRoot = { url in url }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "main" }
      $0.gitClient.branchRefOptions = { _ in
        [GitBranchRefOption(ref: "main", kind: .local)]
      }
      $0.settingsFileStorage = storage.storage
      $0.bootstrapProfilesFileURL = fixture.profileURL
      $0[ShellClient.self] = recordingShellClient(commands: commands) { arguments in
        if arguments.contains(rootURL.appending(path: "web").path(percentEncoded: false)) {
          try FileManager.default.createDirectory(
            at: rootURL.appending(path: "web"),
            withIntermediateDirectories: true
          )
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.workspaceAddLocalRepository(webURL.path(percentEncoded: false)))
    await store.receive(\.workspaceRepositoryBaseRefsLoaded)
    await store.send(.workspaceRepositoryNameChanged(id: UUID(0).uuidString, "Web"))
    await store.send(.workspaceRepositoryPathChanged(id: UUID(0).uuidString, "web"))
    await store.send(
      .workspaceRepositoryCheckoutModeChanged(id: UUID(0).uuidString, .createBranch)
    )
    await store.send(.workspaceRepositoryBranchNameChanged(id: UUID(0).uuidString, "codex/web"))
    await store.send(.workspaceRemoveRepository(id: "api"))
    await store.send(.workspaceRestoreRepository(id: "api"))
    await store.send(.workspaceRemoveRepository(id: "api"))
    await store.send(.workspaceBootstrapIDChanged(id: UUID(0).uuidString, "sync-web"))
    await store.send(.workspaceBootstrapOnAddChanged(id: UUID(0).uuidString, true))
    await store.send(.saveWorkspaceMetadataButtonTapped)
    await store.receive(\.workspaceMetadataSaved)
    await store.receive(\.delegate.settingsChanged)

    #expect(store.state.workspace?.repositories.map(\.id) == ["app", UUID(0).uuidString])
    #expect(store.state.workspace?.repositories.map(\.path) == ["app", "web"])
    #expect(store.state.workspace?.repositories.last?.sourceLocation == normalizedPath(webURL))
    #expect(store.state.workspace?.repositories.last?.bootstrap?.runOn == [.onAdd])
    #expect(store.state.workspace?.updatedAt == Date(timeIntervalSince1970: 50))
    #expect(store.state.workspaceSaveStatus == "Saved workspace metadata.")
    #expect(store.state.workspaceSaveError == nil)

    let saved = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(saved.repositories.map(\.id) == ["app", UUID(0).uuidString])
    #expect(saved.repositories.map(\.path) == ["app", "web"])
    #expect(saved.repositories.last?.bootstrap?.runOn == [.onAdd])
    #expect(
      commands.value.map(\.arguments).contains([
        "git", "-C", normalizedPath(fixture.apiURL), "worktree",
        "remove", "--force", rootURL.appending(path: "api").path(percentEncoded: false),
      ])
    )
    #expect(
      commands.value.map(\.arguments).contains([
        "git", "-C", normalizedPath(fixture.webURL), "worktree", "add",
        "-b", "codex/web", rootURL.appending(path: "web").path(percentEncoded: false),
        "--end-of-options", "main",
      ])
    )
  }

  @Test(.dependencies) func workspaceSaveFailsWhenNewRepositoryCannotBePlanned() async throws {
    let fixture = try makeWorkspaceAddRemoveFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.appURL)
      try? FileManager.default.removeItem(at: fixture.apiURL)
      try? FileManager.default.removeItem(at: fixture.webURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    let storage = SettingsTestStorage()
    var state = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )
    state.setWorkspace(workspace)
    let store = TestStore(initialState: state) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 50)
      $0.uuid = .incrementing
      $0.settingsFileStorage = storage.storage
      $0.bootstrapProfilesFileURL = fixture.profileURL
    }

    await store.send(.workspaceAddRemoteRepository(name: "Remote", url: "")) {
      $0.workspaceDraft?.repositories.append(
        RepositorySettingsFeature.RepositoryDraft(
          id: UUID(0).uuidString,
          name: "Remote",
          sourceKind: .remote,
          sourceLocation: ""
        )
      )
      $0.workspaceSaveStatus = nil
    }
    await store.send(.saveWorkspaceMetadataButtonTapped)
    await store.receive(\.workspaceMetadataSaveFailed) {
      $0.workspaceSaveError = "Source required for Remote."
      $0.workspaceSaveStatus = nil
    }

    let saved = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(saved.repositories.map(\.id) == ["app", "api"])
  }

  @Test(.dependencies) func workspaceManualBootstrapRunsOnlyForSavedRepositories() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }
    let profiles = [
      ProjectWorkspaceBootstrapProfile(id: "sync-app", name: "Sync App", script: "echo sync")
    ]
    let storage = SettingsTestStorage()
    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.bootstrapProfilesFileURL = fixture.profileURL
    } operation: {
      @Shared(.bootstrapProfiles) var storedProfiles: [ProjectWorkspaceBootstrapProfile]
      $storedProfiles.withLock { $0 = profiles }
    }

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    var state = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )
    state.setWorkspace(workspace)
    let commands = LockIsolated<[ShellCommandRecord]>([])
    let store = TestStore(initialState: state) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.bootstrapProfilesFileURL = fixture.profileURL
      $0.uuid = .incrementing
      $0[ShellClient.self] = recordingShellClient(commands: commands)
    }

    await store.send(.workspaceAddRemoteRepository(name: "Web", url: "")) {
      $0.workspaceDraft?.repositories.append(
        RepositorySettingsFeature.RepositoryDraft(
          id: UUID(0).uuidString,
          name: "Web",
          sourceKind: .remote,
          sourceLocation: ""
        )
      )
    }
    await store.send(.workspaceBootstrapIDChanged(id: UUID(0).uuidString, "sync-app")) {
      $0.workspaceDraft?.repositories[2].bootstrapScriptID = "sync-app"
    }
    await store.send(.runWorkspaceBootstrapButtonTapped(id: UUID(0).uuidString))
    #expect(commands.value.isEmpty)

    await store.send(.runWorkspaceBootstrapButtonTapped(id: "app"))
    await store.receive(\.workspaceBootstrapRan) {
      $0.workspaceSaveStatus = "Ran bootstrap for App."
      $0.workspaceSaveError = nil
    }
    #expect(commands.value.count == 1)
    #expect(
      commands.value.first?.currentDirectoryURL.map(normalizedPath)
        == normalizedPath(rootURL.appending(path: "app")))
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
