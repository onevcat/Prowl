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

private struct DeletedBranchRequest: Equatable, Sendable {
  var name: String
  var url: URL
  var force: Bool
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
          "source_kind": "local_repository",
          "source_location": "\(fixture.appURL.path(percentEncoded: false))",
          "branch_name": "workspace-app",
          "base_ref": "main"
        },
        {
          "id": "api",
          "name": "API",
          "path": "api",
          "source_kind": "local_repository",
          "source_location": "\(fixture.apiURL.path(percentEncoded: false))",
          "branch_name": "workspace-api",
          "base_ref": "main"
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
      .appending(path: "prowl-settings-script-profiles-\(UUID().uuidString).json")
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
          "source_kind": "local_repository",
          "source_location": "\(fixture.rootURL.appending(path: "app").path(percentEncoded: false))",
          "branch_name": "workspace-app",
          "base_ref": "main",
          "bootstrap": {
            "script_kind": "user_profile",
            "script_ids": ["sync-app"],
            "run_on": ["create", "manual"],
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
            "source_kind": "local_repository",
            "source_location": "\(rootURL.appending(path: "app-source").path(percentEncoded: false))",
            "branch_name": "workspace-app",
            "base_ref": "main"
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
    await store.send(.workspaceBootstrapProfileAdded(id: "app", "sync-app"))
    await store.send(.workspaceBootstrapProfileAdded(id: "app", "common"))
    await store.send(.workspaceBootstrapProfileMoved(id: "app", "common", .earlier))
    await store.send(.workspaceBootstrapCreateChanged(id: "app", true))
    await store.send(.saveWorkspaceMetadataButtonTapped)
    await store.receive(\.workspaceMetadataSaved) {
      $0.workspace?.title = "New Workspace"
      $0.workspace?.agentGuide = ProjectWorkspaceAgentGuide(enabled: true)
      $0.workspace?.repositories[0].role = "macOS app"
      $0.workspace?.repositories[0].agentNotes = "Use reducer tests."
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
    #expect(saved.repositories[0].bootstrap == nil)
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
      $0.scriptProfilesFileURL = fixture.profileURL
    } operation: {
      @Shared(.scriptProfiles) var storedProfiles: [ScriptProfile]
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
      $0.scriptProfilesFileURL = fixture.profileURL
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
    await store.send(.workspaceBootstrapProfileAdded(id: UUID(0).uuidString, "sync-web"))
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

  @Test(.dependencies) func workspaceAddLocalRepositoryCanStartAsEmptyDraftAndBeDiscarded() async throws {
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
      $0.uuid = .incrementing
    }

    let repositoryID = UUID(0).uuidString
    await store.send(.workspaceAddLocalRepository("")) {
      $0.workspaceDraft?.repositories.append(
        RepositorySettingsFeature.RepositoryDraft(
          id: repositoryID,
          name: "",
          sourceKind: .localRepository,
          sourceLocation: ""
        )
      )
      $0.workspaceSaveStatus = nil
    }

    await store.send(.workspaceRepositorySourceChosen(id: repositoryID, fixture.webURL.path(percentEncoded: false))) {
      $0.workspaceDraft?.repositories[2].name = Repository.name(for: fixture.webURL)
      $0.workspaceDraft?.repositories[2].sourceLocation = fixture.webURL.path(percentEncoded: false)
    }

    await store.send(.workspaceDiscardNewRepository(id: repositoryID)) {
      $0.workspaceDraft?.repositories.removeLast()
    }
  }

  @Test(.dependencies) func workspaceRepositoryRemovalConfirmsSavesAndCanDeleteBranch() async throws {
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
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "web"), withIntermediateDirectories: true)
    var editableWorkspace = workspace
    editableWorkspace.repositories.append(
      ProjectWorkspace.RepositoryEntry(
        id: "web",
        name: "Web",
        path: "web",
        sourceKind: .existingPath,
        sourceLocation: fixture.webURL.path(percentEncoded: false)
      )
    )
    let storage = SettingsTestStorage()
    var state = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )
    state.setWorkspace(editableWorkspace)
    let commands = LockIsolated<[ShellCommandRecord]>([])
    let deletedBranches = LockIsolated<[DeletedBranchRequest]>([])
    let store = TestStore(initialState: state) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 50)
      $0.settingsFileStorage = storage.storage
      $0.scriptProfilesFileURL = fixture.profileURL
      $0[ShellClient.self] = recordingShellClient(commands: commands)
      $0.gitClient.deleteLocalBranch = { name, url, force in
        deletedBranches.withValue {
          $0.append(DeletedBranchRequest(name: name, url: url, force: force))
        }
        return .deleted
      }
    }
    store.exhaustivity = .off

    await store.send(.requestWorkspaceRepositoryRemoval(id: "api")) {
      $0.workspaceRepositoryRemovalConfirmation =
        RepositorySettingsFeature.WorkspaceRepositoryRemovalConfirmation(
          repositoryID: "api",
          repositoryName: "API",
          repositoryPath: "api",
          branchName: "workspace-api",
          deleteBranch: false
        )
    }
    await store.send(.workspaceRemovalDeleteBranchChanged(true)) {
      $0.workspaceRepositoryRemovalConfirmation?.deleteBranch = true
    }
    await store.send(.workspaceRepositoryRemovalConfirmed)
    await store.receive(\.saveWorkspaceMetadataButtonTapped)
    await store.receive(\.workspaceMetadataSaved)
    await store.receive(\.delegate.settingsChanged)
    await store.receive(\.workspaceBranchDeleted)

    #expect(store.state.workspace?.repositories.map(\.id) == ["app", "web"])
    #expect(store.state.workspaceSaveStatus == "Deleted branch workspace-api.")
    #expect(deletedBranches.value.count == 1)
    #expect(deletedBranches.value.first?.name == "workspace-api")
    #expect(deletedBranches.value.first.map { normalizedPath($0.url) } == normalizedPath(fixture.apiURL))
    #expect(deletedBranches.value.first?.force == true)
    #expect(
      commands.value.map(\.arguments).contains([
        "git", "-C", normalizedPath(fixture.apiURL), "worktree",
        "remove", "--force", rootURL.appending(path: "api").path(percentEncoded: false),
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
      $0.scriptProfilesFileURL = fixture.profileURL
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

  @Test(.dependencies) func workspaceSettingsDisablesBootstrapForLinkedRepository() async throws {
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
      $0.gitClient.repoRoot = { url in url }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "main" }
      $0.gitClient.branchRefOptions = { _ in
        [GitBranchRefOption(ref: "main", kind: .local)]
      }
      $0.settingsFileStorage = storage.storage
      $0.scriptProfilesFileURL = fixture.profileURL
    }
    store.exhaustivity = .off

    let repositoryID = UUID(0).uuidString
    await store.send(.workspaceAddLocalRepository(webURL.path(percentEncoded: false)))
    await store.receive(\.workspaceRepositoryBaseRefsLoaded)
    await store.send(.workspaceBootstrapProfileAdded(id: repositoryID, "sync-web"))
    await store.send(.workspaceBootstrapCreateChanged(id: repositoryID, true))
    await store.send(.workspaceBootstrapOnAddChanged(id: repositoryID, true))
    await store.send(.workspaceBootstrapRequiredChanged(id: repositoryID, true))
    await store.send(.workspaceBootstrapManualChanged(id: repositoryID, true))

    let repository = try #require(store.state.workspaceDraft?.repositories[2])
    #expect(repository.checkoutMode == .link)
    #expect(repository.bootstrapScriptIDs.isEmpty)
    #expect(repository.bootstrapRunOnCreate == false)
    #expect(repository.bootstrapRunOnAdd == false)
    #expect(repository.bootstrapRequired == false)
    #expect(repository.bootstrap?.runOn == nil)
  }

  @Test(.dependencies) func workspaceBootstrapRuntimeLoadsAndOpensLatestLog() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }

    let logURL =
      rootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName)
      .appending(path: "bootstrap-runs", directoryHint: .isDirectory)
      .appending(path: "app.log", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: logURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("ok".utf8).write(to: logURL)
    let runtimeState = ProjectWorkspaceBootstrapState(
      repositories: [
        "app": ProjectWorkspaceBootstrapRepositoryState(
          lastRunAt: Date(timeIntervalSince1970: 1_234),
          lastStatus: .succeeded,
          lastScriptIDs: ["sync-app"],
          lastLogPath: ".prowl/bootstrap-runs/app.log"
        )
      ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(runtimeState).write(to: ProjectWorkspaceBootstrapState.fileURL(for: rootURL))

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    var state = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )
    state.setWorkspace(workspace)
    let openedURLs = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.openURLClient.open = { url in
        openedURLs.withValue { $0.append(url) }
      }
    }

    await store.send(.loadWorkspaceBootstrapRuntime)
    await store.receive(\.workspaceBootstrapRuntimeLoaded) {
      $0.workspaceBootstrapRuntime = ProjectWorkspaceBootstrapRuntimeSnapshot(
        state: runtimeState,
        logURLsByRepositoryID: ["app": logURL]
      )
    }
    let appDraft = try #require(store.state.workspaceDraft?.repositories.first { $0.id == "app" })
    let apiDraft = try #require(store.state.workspaceDraft?.repositories.first { $0.id == "api" })
    #expect(appDraft.bootstrapScriptIDs == ["sync-app"])
    #expect(appDraft.isNew == false)
    #expect(appDraft.usesLinkCheckout == false)
    #expect(apiDraft.bootstrapScriptIDs.isEmpty)
    #expect(apiDraft.usesLinkCheckout)
    #expect(store.state.workspaceBootstrapRuntime.state.repositories["app"]?.lastStatus == .succeeded)
    await store.send(.openWorkspaceBootstrapLogButtonTapped(id: "app"))

    #expect(openedURLs.value == [logURL])
  }

  @Test(.dependencies) func missingOrMalformedBootstrapRuntimeDoesNotBlockWorkspaceSettings() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }

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
    }

    await store.send(.loadWorkspaceBootstrapRuntime)
    await store.receive(\.workspaceBootstrapRuntimeLoaded)
    #expect(store.state.workspaceBootstrapRuntime == .empty)
    #expect(store.state.workspaceSaveError == nil)

    try Data("not json".utf8).write(to: ProjectWorkspaceBootstrapState.fileURL(for: rootURL))
    await store.send(.loadWorkspaceBootstrapRuntime)
    await store.receive(\.workspaceBootstrapRuntimeLoaded)
    #expect(store.state.workspaceBootstrapRuntime == .empty)
    #expect(store.state.workspaceSaveError == nil)
  }

  @Test(.dependencies) func workspaceMetadataSavePreservesBootstrapPolicy() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    let originalBootstrap = try #require(workspace.repositories.first?.bootstrap)
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
    }
    store.exhaustivity = .off

    await store.send(.workspaceDescriptionChanged("Updated"))
    await store.send(.saveWorkspaceMetadataButtonTapped)
    await store.receive(\.workspaceMetadataSaved)

    let saved = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(saved.repositories.first?.bootstrap == originalBootstrap)
  }

  @Test(.dependencies) func workspaceManualBootstrapDoesNotRunMissingProfile() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
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
      $0[ShellClient.self] = recordingShellClient(commands: commands)
      @Shared(.scriptProfiles) var storedProfiles: [ScriptProfile]
      $storedProfiles.withLock { $0 = [] }
    }

    await store.send(.runWorkspaceBootstrapProfileButtonTapped(id: "app", scriptID: "sync-app"))

    #expect(commands.value.isEmpty)
  }

  @Test(.dependencies) func workspaceManualBootstrapDoesNotRunForLinkedRepository() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }

    var workspace = try #require(ProjectWorkspace.load(from: rootURL))
    workspace.repositories[1].bootstrap = ProjectWorkspaceRepositoryBootstrap(
      scriptKind: .userProfile,
      scriptIDs: ["sync-api"],
      runOn: [.manual]
    )
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
      $0[ShellClient.self] = recordingShellClient(commands: commands)
      @Shared(.scriptProfiles) var storedProfiles: [ScriptProfile]
      $storedProfiles.withLock {
        $0 = [ScriptProfile(id: "sync-api", name: "Sync API", script: "echo sync")]
      }
    }

    let apiDraft = try #require(store.state.workspaceDraft?.repositories.first { $0.id == "api" })
    #expect(apiDraft.bootstrapScriptIDs == ["sync-api"])
    #expect(apiDraft.usesLinkCheckout)
    await store.send(.runWorkspaceBootstrapProfileButtonTapped(id: "api", scriptID: "sync-api"))

    #expect(commands.value.isEmpty)
  }

  @Test(.dependencies) func workspaceManualBootstrapRunsOnlyForSavedRepositories() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }
    let profiles = [
      ScriptProfile(id: "sync-app", name: "Sync App", script: "echo sync"),
      ScriptProfile(id: "other", name: "Other", script: "echo other"),
    ]

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
      $0.uuid = .incrementing
      $0[ShellClient.self] = recordingShellClient(commands: commands)
      @Shared(.scriptProfiles) var storedProfiles: [ScriptProfile]
      $storedProfiles.withLock { $0 = profiles }
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
    await store.send(.workspaceBootstrapProfileAdded(id: UUID(0).uuidString, "sync-app")) {
      $0.workspaceDraft?.repositories[2].bootstrapScriptIDs = ["sync-app"]
      $0.workspaceDraft?.repositories[2].bootstrapRunOnAdd = true
    }
    await store.send(
      .runWorkspaceBootstrapProfileButtonTapped(id: UUID(0).uuidString, scriptID: "sync-app")
    )
    #expect(commands.value.isEmpty)

    await store.send(.runWorkspaceBootstrapProfileButtonTapped(id: "app", scriptID: "other"))
    #expect(commands.value.isEmpty)

    let originalWorkspace = store.state.workspace
    let originalMetadata = try Data(contentsOf: ProjectWorkspace.metadataURL(for: rootURL))
    let runID = RepositorySettingsFeature.workspaceBootstrapRunID(
      repositoryID: "app",
      scriptID: "sync-app"
    )
    await store.send(.runWorkspaceBootstrapProfileButtonTapped(id: "app", scriptID: "sync-app")) {
      $0.workspaceSaveStatus = "Running sync-app for App..."
      $0.workspaceSaveError = nil
      $0.runningWorkspaceBootstrapIDs = [runID]
    }
    await store.receive(\.workspaceBootstrapRan) {
      $0.runningWorkspaceBootstrapIDs = []
      $0.workspaceSaveStatus = "Ran bootstrap for sync-app for App."
      $0.workspaceSaveError = nil
    }
    let runtime = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)
    await store.receive(\.loadWorkspaceBootstrapRuntime)
    await store.receive(\.workspaceBootstrapRuntimeLoaded) {
      $0.workspaceBootstrapRuntime = runtime
    }
    #expect(commands.value.count == 1)
    #expect(
      commands.value.first?.currentDirectoryURL.map(normalizedPath)
        == normalizedPath(rootURL.appending(path: "app")))
    #expect(store.state.workspace == originalWorkspace)
    #expect(try Data(contentsOf: ProjectWorkspace.metadataURL(for: rootURL)) == originalMetadata)
  }

  @Test(.dependencies) func workspaceManualBootstrapProfileShowsRunningState() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }
    let profiles = [
      ScriptProfile(id: "sync-app", name: "Sync App", script: "echo sync")
    ]

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
      $0[ShellClient.self] = recordingShellClient(commands: commands)
      @Shared(.scriptProfiles) var storedProfiles: [ScriptProfile]
      $storedProfiles.withLock { $0 = profiles }
    }

    let runID = RepositorySettingsFeature.workspaceBootstrapRunID(
      repositoryID: "app",
      scriptID: "sync-app"
    )
    await store.send(.runWorkspaceBootstrapProfileButtonTapped(id: "app", scriptID: "sync-app")) {
      $0.workspaceSaveStatus = "Running sync-app for App..."
      $0.workspaceSaveError = nil
      $0.runningWorkspaceBootstrapIDs = [runID]
    }
    await store.receive(\.workspaceBootstrapRan) {
      $0.runningWorkspaceBootstrapIDs = []
      $0.workspaceSaveStatus = "Ran bootstrap for sync-app for App."
      $0.workspaceSaveError = nil
    }
    let runtime = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)
    await store.receive(\.loadWorkspaceBootstrapRuntime)
    await store.receive(\.workspaceBootstrapRuntimeLoaded) {
      $0.workspaceBootstrapRuntime = runtime
    }
  }

  @Test(.dependencies) func workspaceManualBootstrapFailureReloadsRuntimeWithoutSavingMetadata() async throws {
    let fixture = try makeWorkspaceBootstrapFixture()
    let rootURL = fixture.rootURL
    defer {
      try? FileManager.default.removeItem(at: fixture.rootURL)
      try? FileManager.default.removeItem(at: fixture.profileURL)
    }
    let failure = ProjectWorkspaceCreationError.bootstrapFailed(
      repository: "App",
      message: "manual failure"
    )
    let shellClient = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamWithEnvironmentImpl: { _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.finish(throwing: failure)
        }
      }
    )
    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    var state = RepositorySettingsFeature.State(
      rootURL: rootURL,
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )
    state.setWorkspace(workspace)
    let originalMetadata = try Data(contentsOf: ProjectWorkspace.metadataURL(for: rootURL))
    let store = TestStore(initialState: state) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0[ShellClient.self] = shellClient
      @Shared(.scriptProfiles) var storedProfiles: [ScriptProfile]
      $storedProfiles.withLock {
        $0 = [ScriptProfile(id: "sync-app", name: "Sync App", script: "exit 1")]
      }
    }
    let runID = RepositorySettingsFeature.workspaceBootstrapRunID(
      repositoryID: "app",
      scriptID: "sync-app"
    )

    await store.send(.runWorkspaceBootstrapProfileButtonTapped(id: "app", scriptID: "sync-app")) {
      $0.workspaceSaveStatus = "Running sync-app for App..."
      $0.workspaceSaveError = nil
      $0.runningWorkspaceBootstrapIDs = [runID]
    }
    await store.receive(\.workspaceBootstrapRunFailed) {
      $0.runningWorkspaceBootstrapIDs = []
      $0.workspaceSaveError = failure.localizedDescription
      $0.workspaceSaveStatus = nil
    }
    let runtime = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)
    await store.receive(\.loadWorkspaceBootstrapRuntime)
    await store.receive(\.workspaceBootstrapRuntimeLoaded) {
      $0.workspaceBootstrapRuntime = runtime
    }

    #expect(runtime.state.repositories["app"]?.lastStatus == .failed)
    #expect(runtime.logURLsByRepositoryID["app"] != nil)
    #expect(store.state.workspace == workspace)
    #expect(try Data(contentsOf: ProjectWorkspace.metadataURL(for: rootURL)) == originalMetadata)
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
