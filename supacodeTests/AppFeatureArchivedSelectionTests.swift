import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import ProwlCLIShared
import Testing

@testable import supacode

// `repositoriesChanged` kicks off workflow history maintenance, which reads the
// date dependency. Isolate history per test so recovery cannot interrupt another test's runs.
@Suite(
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_700_000_000)),
  .dependencies {
    $0[WorkflowHistoryStorageKey.self] = WorkflowHistoryStorage(
      baseURL: FileManager.default.temporaryDirectory.appending(path: "workflow-history-\(UUID().uuidString)"))
  }
)
@MainActor
struct AppFeatureArchivedSelectionTests {
  @Test(.dependencies) func selectingArchivedWorktreesDoesNotClearLastFocused() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    let saved = LockIsolated<[Worktree.ID?]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { id in
        saved.withValue { $0.append(id) }
      }
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }

    await store.send(.repositories(.selectArchivedWorktrees)) {
      $0.repositories.worktreeHistoryBackStack = [worktree.id]
      $0.repositories.selection = .archivedWorktrees
      $0.repositories.preArchivedWorktreeID = worktree.id
    }
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.finish()
    #expect(saved.value.isEmpty)
  }

  @Test(.dependencies) func repositoriesChangedPrunesArchivedWorktreesFromTerminalAndRunScriptStatus() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let activeWorktree = Worktree(
      id: "/tmp/repo/wt-active",
      name: "wt-active",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-active"),
      repositoryRootURL: rootURL
    )
    let archivedWorktree = Worktree(
      id: "/tmp/repo/wt-archived",
      name: "wt-archived",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-archived"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [activeWorktree, archivedWorktree])
    )
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(activeWorktree.id)
    repositoriesState.archivedWorktrees = [ArchivedWorktree(id: archivedWorktree.id, archivedAt: .distantPast)]
    var appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    appState.runScriptStatusByWorktreeID = [
      activeWorktree.id: true,
      archivedWorktree.id: true,
    ]
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.runScriptStatusByWorktreeID = [activeWorktree.id: true]
    }
    await store.finish()

    #expect(
      sentCommands.value == [
        .prune([activeWorktree.id])
      ]
    )
  }
  @Test(.dependencies, arguments: [false, true])
  func removingFailedRepositoryClosesOnlyItsPreservedTerminals(keepingOtherRepositories: Bool) async {
    let root = URL(fileURLWithPath: "/tmp/failed-removal-\(UUID().uuidString)")
    let repositories = ["removed", "failed", "healthy"].map { name in
      let url = root.appending(path: name)
      let worktree = Worktree(
        id: url.path, name: name, detail: "", workingDirectory: url, repositoryRootURL: url)
      return Repository(id: url.path, rootURL: url, name: name, worktrees: [worktree])
    }
    let removed = repositories[0]
    let otherFailed = repositories[1]
    let healthy = repositories[2]
    let initialRepositories = keepingOtherRepositories ? repositories : [removed]
    let loadedRepositories = keepingOtherRepositories ? [healthy] : []
    let failedRepositories = keepingOtherRepositories ? [removed, otherFailed] : [removed]
    let roots = initialRepositories.map(\.rootURL)
    let entries = LockIsolated(initialRepositories.map { PersistedRepositoryEntry(path: $0.id, kind: .git) })
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    for repository in initialRepositories {
      _ = manager.state(for: repository.worktrees[0])
    }
    let removedState = manager.stateIfExists(for: removed.id)
    let otherFailedState = manager.stateIfExists(for: otherFailed.id)
    let healthyState = manager.stateIfExists(for: healthy.id)
    var state = AppFeature.State()
    state.repositories.repositories = IdentifiedArray(uniqueElements: initialRepositories)
    state.repositories.repositoryRoots = roots
    state.repositories.snapshotPersistencePhase = .active
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { manager.handleCommand($0) }
      $0.worktreeInfoWatcher.send = { _ in }
      $0.repositoryPersistence.loadRepositoryEntries = { entries.value }
      $0.repositoryPersistence.saveRepositoryEntries = { entries.setValue($0) }
      $0.gitClient.repoRoot = { url in
        if url.path == healthy.id { return healthy.rootURL }
        throw GitClientError.unavailable(details: "Unavailable test Git")
      }
      $0.gitClient.worktrees = { url in
        if url.path == healthy.id { return Array(healthy.worktrees) }
        throw GitClientError.unavailable(details: "Unavailable test Git")
      }
    }
    store.exhaustivity = .off
    await store.send(
      .repositories(
        .repositoriesLoaded(
          loadedRepositories,
          failures: failedRepositories.map {
            .init(rootID: $0.id, message: "Unavailable test Git", isGitUnavailable: true)
          },
          roots: roots, animated: false)))
    await store.finish()
    #expect(removedState != nil)
    #expect(manager.stateIfExists(for: removed.id) === removedState)

    await store.send(.repositories(.repositoryManagement(.removeFailedRepository(removed.id))))
    await store.finish()
    #expect(manager.stateIfExists(for: removed.id) == nil)
    #expect(!entries.value.contains(where: { $0.path == removed.id }))
    #expect(store.state.repositories.loadFailuresByID[removed.id] == nil)
    if keepingOtherRepositories {
      #expect(manager.stateIfExists(for: otherFailed.id) === otherFailedState)
      #expect(manager.stateIfExists(for: healthy.id) === healthyState)
      #expect(store.state.repositories.loadFailuresByID[otherFailed.id] != nil)
    }
  }

  @Test(.dependencies) func failedRepositoryLoadDoesNotCloseItsTerminals() async {
    var state = AppFeature.State()
    state.repositories.repositoryRoots = [URL(fileURLWithPath: "/tmp/unavailable")]
    state.repositories.loadFailuresByID = ["/tmp/unavailable": "Git is unavailable"]
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in commands.withValue { $0.append(command) } }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.delegate(.repositoriesChanged([]))))
    await store.finish()
    #expect(commands.value.contains(.prunePreservingRepositories(keeping: [], repositoryIDs: ["/tmp/unavailable"])))
    #expect(!commands.value.contains(.prune([])))
  }

}
