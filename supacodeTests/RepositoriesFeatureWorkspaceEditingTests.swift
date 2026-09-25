import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureWorkspaceEditingTests {
  @Test func promptRequestedReadsMetadataFromDiskAndPresentsEditor() async throws {
    let rootURL = try makeWorkspaceOnDisk(
      title: "Disk Title",
      repositories: [ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app")]
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let repositoryID = rootURL.path(percentEncoded: false)
    // The in-memory snapshot is stale on purpose: the editor must show the file.
    let snapshot = ProjectWorkspace(
      id: repositoryID, title: "Stale Title",
      repositories: [ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app")])
    let workspace = Repository(
      id: repositoryID, rootURL: rootURL, name: "Stale Title", kind: .plain, worktrees: [],
      workspace: snapshot)
    let opened = Repository(
      id: "/tmp/opened", rootURL: URL(fileURLWithPath: "/tmp/opened"), name: "Opened", kind: .git,
      worktrees: [])
    var initialState = RepositoriesFeature.State()
    initialState.repositories = [workspace, opened]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    await store.send(.workspaceEditing(.promptRequested(repositoryID, removingChildID: nil)))
    await store.receive(\.workspaceEditing.promptLoaded) {
      $0.workspaceEditor = WorkspaceEditorFeature.State(
        editing: loaded,
        rootURL: rootURL,
        repositoryID: repositoryID,
        openedRepositoryCandidates: [
          ProjectWorkspaceCreationRepository(
            id: "/tmp/opened", name: "Opened", rootURL: URL(fileURLWithPath: "/tmp/opened"))
        ]
      )
    }
    #expect(store.state.workspaceEditor?.title == "Disk Title")
    #expect(store.state.workspaceEditor?.mode == .edit(repositoryID: repositoryID))
  }

  @Test func promptRequestedWithChildPreMarksThatMemberForRemoval() async throws {
    let rootURL = try makeWorkspaceOnDisk(
      title: "Two",
      repositories: [
        ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app"),
        ProjectWorkspaceRepositoryEntry(id: "api", name: "API", path: "api"),
      ]
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let repositoryID = rootURL.path(percentEncoded: false)
    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    var initialState = RepositoriesFeature.State()
    initialState.repositories = [
      Repository(id: repositoryID, rootURL: rootURL, name: "Two", kind: .plain, worktrees: [], workspace: loaded)
    ]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let apiPath = rootURL.appending(path: "api").standardizedFileURL.path(percentEncoded: false)

    await store.send(.workspaceEditing(.promptRequested(repositoryID, removingChildID: apiPath)))
    await store.receive(\.workspaceEditing.promptLoaded)
    #expect(store.state.workspaceEditor?.existingRepositories[id: "api"]?.isMarkedForRemoval == true)
    #expect(store.state.workspaceEditor?.existingRepositories[id: "app"]?.isMarkedForRemoval == false)
  }

  @Test func promptRequestedIgnoresNonWorkspaceAndAlreadyOpenEditor() async {
    var initialState = RepositoriesFeature.State()
    initialState.repositories = [
      Repository(id: "/tmp/git", rootURL: URL(fileURLWithPath: "/tmp/git"), name: "Git", kind: .git, worktrees: [])
    ]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.workspaceEditing(.promptRequested("/tmp/git", removingChildID: nil)))
  }

  @Test func saveWorkspaceWritesMetadataReloadsAndToasts() async throws {
    let rootURL = try makeWorkspaceOnDisk(
      title: "Before",
      repositories: [ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app")]
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let repositoryID = rootURL.path(percentEncoded: false)
    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    var initialState = RepositoriesFeature.State()
    initialState.repositories = [
      Repository(id: repositoryID, rootURL: rootURL, name: "Before", kind: .plain, worktrees: [], workspace: loaded)
    ]
    initialState.repositoryRoots = [rootURL]
    initialState.workspaceEditor = WorkspaceEditorFeature.State(
      editing: loaded, rootURL: rootURL, repositoryID: repositoryID)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.shellClient.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: rootURL.path(percentEncoded: false), kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    let request = ProjectWorkspaceUpdateRequest(
      rootURL: rootURL,
      title: "After",
      description: "Edited",
      members: [.existing(loaded.repositories[0])],
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    await store.send(.workspaceEditing(.saveWorkspace(request))) {
      $0.workspaceEditor?.isSaving = true
    }
    await store.receive(\.workspaceEditing.workspaceSaved) {
      $0.workspaceEditor = nil
    }
    // The toast and the reload are merged effects with no ordering guarantee,
    // so only the reload is awaited explicitly (non-exhaustive skips the rest).
    await store.receive(\.repositoriesLoaded, timeout: .seconds(5))
    await store.finish()

    #expect(ProjectWorkspace.load(from: rootURL)?.title == "After")
    #expect(ProjectWorkspace.load(from: rootURL)?.description == "Edited")
    // The reload normalizes the persisted path (symlinks resolved), so look
    // the workspace up by kind rather than by the pre-normalization id.
    #expect(store.state.repositories.first(where: \.isWorkspace)?.name == "After")
    #expect(store.state.alert == nil)
  }

  @Test func saveWorkspaceReportsCleanupFailuresInAlert() async throws {
    let outsideURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    let outsidePath = outsideURL.path(percentEncoded: false)
    let rootURL = try makeWorkspaceOnDisk(
      title: "Cleanup",
      repositories: [
        ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app"),
        ProjectWorkspaceRepositoryEntry(id: "ext", name: "External", path: outsidePath),
      ]
    )
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: outsideURL)
    }
    let repositoryID = rootURL.path(percentEncoded: false)
    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    var initialState = RepositoriesFeature.State()
    initialState.repositories = [
      Repository(id: repositoryID, rootURL: rootURL, name: "Cleanup", kind: .plain, worktrees: [], workspace: loaded)
    ]
    initialState.repositoryRoots = [rootURL]
    initialState.workspaceEditor = WorkspaceEditorFeature.State(
      editing: loaded, rootURL: rootURL, repositoryID: repositoryID)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.shellClient.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: rootURL.path(percentEncoded: false), kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    let ext = try #require(loaded.repositories.first { $0.id == "ext" })
    await store.send(
      .workspaceEditing(
        .saveWorkspace(
          ProjectWorkspaceUpdateRequest(
            rootURL: rootURL,
            title: "Cleanup",
            members: [.existing(loaded.repositories[0])],
            removals: [ProjectWorkspaceRepositoryRemoval(entry: ext, deleteFiles: true)],
            updatedAt: Date()
          ))))
    await store.receive(\.workspaceEditing.workspaceSaved) {
      $0.workspaceEditor = nil
    }
    await store.finish()

    #expect(store.state.alert != nil)
    #expect(FileManager.default.fileExists(atPath: outsidePath))
    #expect(ProjectWorkspace.load(from: rootURL)?.repositories.map(\.id) == ["app"])
  }

  @Test func saveWorkspaceReportsFailedBranchDeletionAfterCommittedSave() async throws {
    let rootURL = try makeWorkspaceOnDisk(
      title: "Branches",
      repositories: [
        ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app"),
        ProjectWorkspaceRepositoryEntry(
          id: "api", name: "API", path: "api", sourceKind: .localRepository,
          sourceLocation: "/tmp/source/api", branchName: "feature/api"),
      ]
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "api"), withIntermediateDirectories: true)
    let repositoryID = rootURL.path(percentEncoded: false)
    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    var initialState = RepositoriesFeature.State()
    initialState.repositories = [
      Repository(id: repositoryID, rootURL: rootURL, name: "Branches", kind: .plain, worktrees: [], workspace: loaded)
    ]
    initialState.repositoryRoots = [rootURL]
    initialState.workspaceEditor = WorkspaceEditorFeature.State(
      editing: loaded, rootURL: rootURL, repositoryID: repositoryID)
    let deleteAttempts = LockIsolated(0)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      // `git worktree remove` succeeds; the branch deletion is refused.
      $0.shellClient.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
      $0.gitClient.deleteLocalBranch = { _, _, _ in
        deleteAttempts.withValue { $0 += 1 }
        throw GitClientError.commandFailed(command: "git branch -D feature/api", message: "checked out elsewhere")
      }
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: rootURL.path(percentEncoded: false), kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    let api = try #require(loaded.repositories.first { $0.id == "api" })
    await store.send(
      .workspaceEditing(
        .saveWorkspace(
          ProjectWorkspaceUpdateRequest(
            rootURL: rootURL,
            title: "Branches",
            members: [.existing(loaded.repositories[0])],
            removals: [ProjectWorkspaceRepositoryRemoval(entry: api, deleteFiles: true, deleteBranch: true)],
            updatedAt: Date()
          ))))
    await store.receive(\.workspaceEditing.workspaceSaved) {
      $0.workspaceEditor = nil
    }
    await store.finish()

    #expect(deleteAttempts.value == 1)
    // The save is committed; the branch that was explicitly requested but
    // not deleted must still be surfaced to the user.
    #expect(ProjectWorkspace.load(from: rootURL)?.repositories.map(\.id) == ["app"])
    #expect(store.state.alert != nil)
  }

  @Test func saveWorkspaceFailureKeepsEditorOpenWithMessage() async throws {
    let missingRoot = FileManager.default.temporaryDirectory
      .appending(path: "prowl-missing-\(UUID().uuidString)")
      .standardizedFileURL
    let repositoryID = missingRoot.path(percentEncoded: false)
    let workspace = ProjectWorkspace(
      id: repositoryID, title: "Gone",
      repositories: [ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app")])
    var initialState = RepositoriesFeature.State()
    initialState.repositories = [
      Repository(
        id: repositoryID, rootURL: missingRoot, name: "Gone", kind: .plain, worktrees: [], workspace: workspace)
    ]
    initialState.workspaceEditor = WorkspaceEditorFeature.State(
      editing: workspace, rootURL: missingRoot, repositoryID: repositoryID)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.shellClient.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    }

    let request = ProjectWorkspaceUpdateRequest(
      rootURL: missingRoot, title: "Gone", members: [.existing(workspace.repositories[0])], updatedAt: Date())
    await store.send(.workspaceEditing(.saveWorkspace(request))) {
      $0.workspaceEditor?.isSaving = true
    }
    await store.receive(\.workspaceEditing.workspaceSaveFailed) {
      $0.workspaceEditor?.isSaving = false
      $0.workspaceEditor?.validationMessage =
        ProjectWorkspaceCreationError.workspaceMetadataMissing(repositoryID).localizedDescription
    }
    // Cancel is ignored only while saving; afterwards it closes the editor.
    await store.send(.workspaceEditor(.presented(.delegate(.cancel))))
    await store.receive(\.workspaceEditing.promptCanceled) {
      $0.workspaceEditor = nil
    }
  }

  @Test func saveFailureWithoutEditorShowsAlert() async {
    // `ifLet` clears the sheet state on `.dismiss`, so a failure that lands
    // after the sheet is gone must still surface somewhere.
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.workspaceEditing(.workspaceSaveFailed("boom"))) {
      $0.alert = AlertState {
        TextState("Unable to save workspace")
      } actions: {
        ButtonState(role: .cancel) {
          TextState("OK")
        }
      } message: {
        TextState("boom")
      }
    }
  }

  @Test func cancelWhileSavingIsIgnored() async {
    let rootURL = URL(fileURLWithPath: "/tmp/ws")
    let workspace = ProjectWorkspace(
      id: "/tmp/ws", title: "Busy",
      repositories: [ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app")])
    var initialState = RepositoriesFeature.State()
    initialState.workspaceEditor = WorkspaceEditorFeature.State(
      editing: workspace, rootURL: rootURL, repositoryID: "/tmp/ws")
    initialState.workspaceEditor?.isSaving = true
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.workspaceEditor(.presented(.delegate(.cancel))))
    await store.receive(\.workspaceEditing.promptCanceled)
    #expect(store.state.workspaceEditor != nil)
  }

  @Test func editorSubmitInEditModeRoutesToSave() async {
    let rootURL = URL(fileURLWithPath: "/tmp/ws-missing-\(UUID().uuidString)", isDirectory: true)
    let repositoryID = rootURL.path(percentEncoded: false)
    let workspace = ProjectWorkspace(
      id: repositoryID, title: "Route",
      repositories: [ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app")])
    var initialState = RepositoriesFeature.State()
    initialState.workspaceEditor = WorkspaceEditorFeature.State(
      editing: workspace, rootURL: rootURL, repositoryID: repositoryID)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
      $0.shellClient.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    }
    store.exhaustivity = .off

    await store.send(.workspaceEditor(.presented(.submitButtonTapped)))
    await store.receive(\.workspaceEditor.presented.delegate.submit)
    await store.receive(\.workspaceEditing.saveWorkspace) {
      $0.workspaceEditor?.isSaving = true
    }
    await store.receive(\.workspaceEditing.workspaceSaveFailed) {
      $0.workspaceEditor?.isSaving = false
    }
  }

  // MARK: - Helpers

  private func makeWorkspaceOnDisk(
    title: String,
    repositories: [ProjectWorkspaceRepositoryEntry]
  ) throws -> URL {
    // No directory hint: the id must match how repository loading derives
    // ids (no trailing slash).
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-editing-\(UUID().uuidString)")
      .standardizedFileURL
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: ProjectWorkspace.metadataDirectoryName), withIntermediateDirectories: true)
    let workspace = ProjectWorkspace(title: title, repositories: repositories)
    try ProjectWorkspace.encodeMetadata(workspace, preservingUnknownKeysIn: nil)
      .write(to: ProjectWorkspace.metadataURL(for: rootURL))
    return rootURL
  }
}
