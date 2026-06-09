import Clocks
import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureTests {
  @Test func requestCanvasCommandSetsPendingRequestWithIncrementingID() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.requestCanvasCommand(.toggleExpand)) {
      $0.nextCanvasCommandRequestID = 1
      $0.pendingCanvasCommandRequest = CanvasCommandRequest(id: 1, command: .toggleExpand)
    }
    await store.send(.requestCanvasCommand(.arrange)) {
      $0.nextCanvasCommandRequestID = 2
      $0.pendingCanvasCommandRequest = CanvasCommandRequest(id: 2, command: .arrange)
    }
  }

  @Test func consumeCanvasCommandRequestClearsOnlyMatchingID() async {
    var initialState = RepositoriesFeature.State()
    initialState.nextCanvasCommandRequestID = 5
    initialState.pendingCanvasCommandRequest = CanvasCommandRequest(id: 5, command: .organize)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // A stale id is ignored.
    await store.send(.consumeCanvasCommandRequest(4))
    // The matching id clears the request.
    await store.send(.consumeCanvasCommandRequest(5)) {
      $0.pendingCanvasCommandRequest = nil
    }
  }

  @Test func refreshWorktreesSetsRefreshingStateUntilLoadCompletes() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [worktree] }
    }

    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
  }

  @Test func refreshWorktreesWithoutRootsStopsRefreshingImmediately() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories) {
      $0.isRefreshingWorktrees = false
    }
  }

  @Test func repositoriesLoadedClearsRefreshingState() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.isRefreshingWorktrees = true
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [repository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
  }

  @Test func customTitlesLoadedReplacesEntireDictionary() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.customTitlesLoaded(["repo-a": "Alpha", "repo-b": "Beta"])) {
      $0.repositoryCustomTitles = ["repo-a": "Alpha", "repo-b": "Beta"]
    }

    // Re-sending the same dict is a no-op (state mutation guard avoids
    // gratuitous TCA-driven view refreshes).
    await store.send(.customTitlesLoaded(["repo-a": "Alpha", "repo-b": "Beta"]))

    await store.send(.customTitlesLoaded(["repo-c": "Gamma"])) {
      $0.repositoryCustomTitles = ["repo-c": "Gamma"]
    }
  }

  @Test func customTitleUpdatedSetsAndRemovesSingleEntry() async {
    var initialState = RepositoriesFeature.State()
    initialState.repositoryCustomTitles = ["repo-a": "Alpha"]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.customTitleUpdated("repo-b", "Beta")) {
      $0.repositoryCustomTitles = ["repo-a": "Alpha", "repo-b": "Beta"]
    }

    // Same value → no state change
    await store.send(.customTitleUpdated("repo-b", "Beta"))

    // nil removes the entry
    await store.send(.customTitleUpdated("repo-a", nil)) {
      $0.repositoryCustomTitles = ["repo-b": "Beta"]
    }

    // Removing a non-existent entry is a no-op
    await store.send(.customTitleUpdated("repo-a", nil))
  }

  @Test func updateWorktreeLineChangesReturnsFalseWhenCountsMatchExistingEntry() {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: 12,
      removedLines: 4,
      pullRequest: nil
    )

    let changed = updateWorktreeLineChanges(
      worktreeID: worktree.id,
      added: 12,
      removed: 4,
      state: &state
    )

    #expect(changed == false)
    #expect(
      state.worktreeInfoByID[worktree.id]
        == WorktreeInfoEntry(addedLines: 12, removedLines: 4, pullRequest: nil)
    )
  }

  @Test func updateWorktreeLineChangesReturnsFalseWhenClearingAlreadyEmptyDiffs() {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    let pullRequest = makePullRequest(state: "OPEN", headRefName: worktree.name)
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: pullRequest
    )

    let changed = updateWorktreeLineChanges(
      worktreeID: worktree.id,
      added: 0,
      removed: 0,
      state: &state
    )

    #expect(changed == false)
    #expect(
      state.worktreeInfoByID[worktree.id]
        == WorktreeInfoEntry(addedLines: nil, removedLines: nil, pullRequest: pullRequest)
    )
  }

  @Test func updateWorktreeLineChangesReturnsTrueWhenCountsChange() {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])

    let changed = updateWorktreeLineChanges(
      worktreeID: worktree.id,
      added: 12,
      removed: 4,
      state: &state
    )

    #expect(changed == true)
    #expect(
      state.worktreeInfoByID[worktree.id]
        == WorktreeInfoEntry(addedLines: 12, removedLines: 4, pullRequest: nil)
    )
  }

  @Test func filesChangedSkipsLineChangeActionWhenGitCountsMatchCurrentState() async {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: 12,
      removedLines: 4,
      pullRequest: nil
    )

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.lineChanges = { _ in (12, 4) }
    }

    await store.send(.worktreeInfoEvent(.filesChanged(worktreeID: worktree.id)))
    await store.finish()
  }

  @Test func filesChangedSkipsLineChangeActionWhenGitReportsAlreadyEmptyDiff() async {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let pullRequest = makePullRequest(state: "OPEN", headRefName: worktree.name)
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: pullRequest
    )

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.lineChanges = { _ in (0, 0) }
    }

    await store.send(.worktreeInfoEvent(.filesChanged(worktreeID: worktree.id)))
    await store.finish()
  }

  @Test func filesChangedSkipsLineChangeActionWhenEntryExplicitlyHoldsZeros() async {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: 0,
      removedLines: 0,
      pullRequest: nil
    )

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.lineChanges = { _ in (0, 0) }
    }

    await store.send(.worktreeInfoEvent(.filesChanged(worktreeID: worktree.id)))
    await store.finish()
  }

  @Test func filesChangedEmitsLineChangeActionWhenGitCountsDiffer() async {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: 12,
      removedLines: 4,
      pullRequest: nil
    )

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.lineChanges = { _ in (15, 9) }
    }

    await store.send(.worktreeInfoEvent(.filesChanged(worktreeID: worktree.id)))
    await store.receive(\.worktreeLineChangesLoaded) {
      $0.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
        addedLines: 15,
        removedLines: 9,
        pullRequest: nil
      )
    }
  }

  @Test(.dependencies) func filesChangedSkipsLineChangesWhenObservationDisabled() async {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: 12,
      removedLines: 4,
      pullRequest: nil
    )

    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock { $0.observeLineDiffsAutomatically = false }

    let lineChangeRequests = LockIsolated(0)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.lineChanges = { _ in
        lineChangeRequests.withValue { $0 += 1 }
        return (15, 9)
      }
    }

    await store.send(.worktreeInfoEvent(.filesChanged(worktreeID: worktree.id)))
    await store.finish()

    #expect(lineChangeRequests.value == 0)
  }

  @Test func repositoryWorktreesChangedReloadsRepositories() async {
    let existingWorktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let discoveredWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [existingWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [existingWorktree, discoveredWorktree] }
    }

    await store.send(.worktreeInfoEvent(.repositoryWorktreesChanged(repositoryRootURL: repository.rootURL)))
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories[id: repository.id] = makeRepository(
        id: repository.id,
        worktrees: [existingWorktree, discoveredWorktree]
      )
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func repositoriesLoadedEmitsChangedDelegateWhenTransitioningFromRestoring() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.snapshotPersistencePhase = .restoring

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [repository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    // Even though repos didn't change, the delegate must fire because we
    // transitioned from .restoring → .active. Layout restore depends on
    // receiving repositoriesChanged while phase is .active.
    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func taskRestoresRepositorySnapshotBeforeLiveRefreshCompletes() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let worktreeID = worktree.id
    let liveRefreshGate = AsyncGate()

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadLastFocusedWorktreeID = { worktreeID }
      $0.repositoryPersistence.loadRepositorySnapshot = { [repository] }
      $0.repositoryPersistence.loadRoots = { [repoRoot] }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.worktrees = { _ in
        await liveRefreshGate.wait()
        return [worktree]
      }
    }

    await store.send(.task) {
      $0.snapshotPersistencePhase = .restoring
    }
    await store.receive(\.pinnedWorktreeIDsLoaded)
    await store.receive(\.archivedWorktreesLoaded)
    await store.receive(\.repositoryOrderIDsLoaded)
    await store.receive(\.worktreeOrderByRepositoryLoaded)
    await store.receive(\.lastFocusedWorktreeIDLoaded) {
      $0.lastFocusedWorktreeID = worktreeID
      $0.shouldRestoreLastFocusedWorktree = true
    }
    await store.receive(\.repositorySnapshotLoaded) {
      $0.repositories = [repository]
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.selection = .worktree(worktreeID)
      $0.shouldRestoreLastFocusedWorktree = false
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.loadPersistedRepositories)

    await liveRefreshGate.resume()

    await store.receive(\.repositoriesLoaded) {
      $0.snapshotPersistencePhase = .active
    }
    // After the fix, repositoriesLoaded also emits repositoriesChanged
    // when transitioning from .restoring → .active (even if repos are identical).
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func taskFallsBackToLiveLoadWhenRepositorySnapshotIsMissing() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRoot] }
      $0.repositoryPersistence.loadRepositorySnapshot = { nil }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.worktrees = { _ in [worktree] }
    }

    await store.send(.task) {
      $0.snapshotPersistencePhase = .restoring
    }
    await store.receive(\.pinnedWorktreeIDsLoaded)
    await store.receive(\.archivedWorktreesLoaded)
    await store.receive(\.repositoryOrderIDsLoaded)
    await store.receive(\.worktreeOrderByRepositoryLoaded)
    await store.receive(\.lastFocusedWorktreeIDLoaded) {
      $0.shouldRestoreLastFocusedWorktree = true
    }
    await store.receive(\.repositorySnapshotLoaded)
    await store.receive(\.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repository]
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.shouldRestoreLastFocusedWorktree = false
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func loadPersistedRepositoriesLoadsMixedGitAndPlainEntries() async {
    let repoRoot = "/tmp/repo"
    let plainRoot = "/tmp/folder"
    let worktree = makeWorktree(id: "\(repoRoot)/main", name: "main", repoRoot: repoRoot)
    let gitRepository = makeRepository(id: repoRoot, worktrees: [worktree])
    let plainRepository = makeRepository(
      id: plainRoot,
      name: "folder",
      kind: .plain,
      worktrees: []
    )

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [
          PersistedRepositoryEntry(path: repoRoot, kind: .git),
          PersistedRepositoryEntry(path: plainRoot, kind: .plain),
        ]
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.worktrees = { root in
        let path = root.path(percentEncoded: false)
        if path == repoRoot {
          return [worktree]
        }
        Issue.record("worktrees should not load for plain repository: \(path)")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [gitRepository, plainRepository]
      $0.repositoryRoots = [repoRoot, plainRoot].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func loadPersistedRepositoriesLoadsWorkspaceMetadataAsPlainRepository() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-workspace-\(UUID().uuidString)")
      .standardizedFileURL
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try FileManager.default.createDirectory(
      at: rootURL.appending(path: ProjectWorkspace.metadataDirectoryName),
      withIntermediateDirectories: true
    )
    try Data(
      """
      {
        "title": "Multi Repo Workspace",
        "repositories": [
          {
            "name": "App",
            "role": "client",
            "path": "app",
            "source_kind": "existing_path"
          }
        ]
      }
      """.utf8
    )
    .write(to: ProjectWorkspace.metadataURL(for: rootURL))

    let rootPath = rootURL.path(percentEncoded: false)
    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    let repository = makeRepository(
      id: rootPath,
      name: "Multi Repo Workspace",
      kind: .plain,
      worktrees: [],
      workspace: workspace
    )

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: rootPath, kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { url in
        Issue.record("workspace should load as plain without git probing: \(url.path(percentEncoded: false))")
        return url
      }
      $0.gitClient.worktrees = { url in
        Issue.record("workspace should not load git worktrees: \(url.path(percentEncoded: false))")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repository]
      $0.repositoryRoots = [rootURL]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func loadPersistedRepositoriesAutoUpgradesPlainFolderWhenItBecomesGitRoot() async {
    let root = "/tmp/folder"
    let worktree = makeWorktree(id: root, name: "folder", repoRoot: root)
    let upgradedRepository = makeRepository(
      id: root,
      name: "folder",
      kind: .git,
      worktrees: [worktree]
    )
    let savedEntries = LockIsolated<[[PersistedRepositoryEntry]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: root, kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in
        savedEntries.withValue { $0.append(entries) }
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { url in
        #expect(url.path(percentEncoded: false) == root)
        return URL(fileURLWithPath: root)
      }
      $0.gitClient.worktrees = { url in
        #expect(url.path(percentEncoded: false) == root)
        return [worktree]
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [upgradedRepository]
      $0.repositoryRoots = [URL(fileURLWithPath: root)]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    let expectedSavedEntries = [
      [PersistedRepositoryEntry(path: root, kind: .git)]
    ]
    #expect(savedEntries.value == expectedSavedEntries)
  }

  @Test func loadPersistedRepositoriesDoesNotUpgradePlainFolderWhenOnlyAncestorIsGitRoot() async {
    let root = "/tmp/folder"
    let ancestorRoot = "/tmp"
    let plainRepository = makeRepository(
      id: root,
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    let savedEntries = LockIsolated<[[PersistedRepositoryEntry]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: root, kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in
        savedEntries.withValue { $0.append(entries) }
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { url in
        #expect(url.path(percentEncoded: false) == root)
        return URL(fileURLWithPath: ancestorRoot)
      }
      $0.gitClient.worktrees = { url in
        Issue.record("plain folder should not load worktrees: \(url.path(percentEncoded: false))")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [plainRepository]
      $0.repositoryRoots = [URL(fileURLWithPath: root)]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    #expect(savedEntries.value.isEmpty)
  }

  @Test func loadPersistedRepositoriesAutoDowngradesGitRepoWhenItStopsBeingRepoRoot() async {
    let root = "/tmp/repo"
    let ancestorRoot = "/tmp"
    let downgradedRepository = makeRepository(
      id: root,
      name: "repo",
      kind: .plain,
      worktrees: []
    )
    let savedEntries = LockIsolated<[[PersistedRepositoryEntry]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: root, kind: .git)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in
        savedEntries.withValue { $0.append(entries) }
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { url in
        #expect(url.path(percentEncoded: false) == root)
        return URL(fileURLWithPath: ancestorRoot)
      }
      $0.gitClient.worktrees = { url in
        Issue.record("downgraded git entry should not load worktrees: \(url.path(percentEncoded: false))")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [downgradedRepository]
      $0.repositoryRoots = [URL(fileURLWithPath: root)]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    let expectedSavedEntries = [
      [PersistedRepositoryEntry(path: root, kind: .plain)]
    ]
    #expect(savedEntries.value == expectedSavedEntries)
  }

  @Test func loadPersistedRepositoriesDoesNotDowngradeGitRepoOnUnexpectedProbeError() async {
    let root = "/tmp/repo"
    let worktree = makeWorktree(id: "\(root)/main", name: "main", repoRoot: root)
    let repository = makeRepository(id: root, name: "repo", kind: .git, worktrees: [worktree])
    let savedEntries = LockIsolated<[[PersistedRepositoryEntry]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: root, kind: .git)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in
        savedEntries.withValue { $0.append(entries) }
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { _ in
        throw GitClientError.commandFailed(command: "wt root", message: "permission denied")
      }
      $0.gitClient.worktrees = { url in
        #expect(url.path(percentEncoded: false) == root)
        return [worktree]
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repository]
      $0.repositoryRoots = [URL(fileURLWithPath: root)]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    #expect(savedEntries.value.isEmpty)
  }

  @Test func openRepositoriesAddsPlainFoldersInsteadOfRejectingThem() async {
    let repoSelection = "/tmp/repo/subdir"
    let repoRoot = "/tmp/repo"
    let plainRoot = "/tmp/plain"
    let worktree = makeWorktree(id: "\(repoRoot)/main", name: "main", repoRoot: repoRoot)
    let gitRepository = makeRepository(id: repoRoot, worktrees: [worktree])
    let plainRepository = makeRepository(
      id: plainRoot,
      name: "plain",
      kind: .plain,
      worktrees: []
    )
    let savedEntries = LockIsolated<[[PersistedRepositoryEntry]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in
        savedEntries.withValue { $0.append(entries) }
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { url in
        let path = url.path(percentEncoded: false)
        if path == repoSelection {
          return URL(fileURLWithPath: repoRoot)
        }
        if path == plainRoot {
          throw GitClientError.commandFailed(command: "wt root", message: "not a git repository")
        }
        Issue.record("Unexpected repoRoot lookup: \(path)")
        return URL(fileURLWithPath: repoRoot)
      }
      $0.gitClient.worktrees = { root in
        let path = root.path(percentEncoded: false)
        if path == repoRoot {
          return [worktree]
        }
        Issue.record("worktrees should not load for plain repository: \(path)")
        return []
      }
    }

    await store.send(
      .repositoryManagement(
        .openRepositories([
          URL(fileURLWithPath: repoSelection),
          URL(fileURLWithPath: plainRoot),
        ]))
    )
    await store.receive(\.repositoryManagement.openRepositoriesFinished) {
      $0.repositories = [gitRepository, plainRepository]
      $0.repositoryRoots = [repoRoot, plainRoot].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    let expectedSavedEntries = [
      [
        PersistedRepositoryEntry(path: repoRoot, kind: .git),
        PersistedRepositoryEntry(path: plainRoot, kind: .plain),
      ]
    ]
    #expect(savedEntries.value == expectedSavedEntries)
  }

  @Test func revealInSidebarExpandsCollapsedRepository() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree.id]
    initialState.$collapsedRepositoryIDs.withLock { $0 = [repository.id] }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.revealSelectedWorktreeInSidebar) {
      $0.$collapsedRepositoryIDs.withLock { $0 = [] }
      $0.nextPendingSidebarRevealID = 1
      $0.pendingSidebarReveal = .init(id: 1, worktreeID: worktree.id)
    }
  }

  @Test func revealInSidebarWithNoSelectionIsNoOp() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let initialState = makeState(repositories: [repository])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.revealSelectedWorktreeInSidebar)
  }

  @Test func revealInSidebarKeepsOtherRepositoriesCollapsed() async {
    let worktree1 = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let worktree2 = makeWorktree(id: "/tmp/repo-b/wt", name: "wt", repoRoot: "/tmp/repo-b")
    let repoA = makeRepository(id: "/tmp/repo-a", worktrees: [worktree1])
    let repoB = makeRepository(id: "/tmp/repo-b", worktrees: [worktree2])
    var initialState = makeState(repositories: [repoA, repoB])
    initialState.selection = .worktree(worktree1.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree1.id]
    initialState.$collapsedRepositoryIDs.withLock { $0 = [repoA.id, repoB.id] }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.revealSelectedWorktreeInSidebar) {
      $0.$collapsedRepositoryIDs.withLock { $0 = [repoB.id] }
      $0.nextPendingSidebarRevealID = 1
      $0.pendingSidebarReveal = .init(id: 1, worktreeID: worktree1.id)
    }
  }

  @Test func consumePendingSidebarRevealClearsMatchingRequest() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.nextPendingSidebarRevealID = 1
    initialState.pendingSidebarReveal = .init(id: 1, worktreeID: worktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.consumePendingSidebarReveal(1)) {
      $0.pendingSidebarReveal = nil
    }
  }

  @Test func consumePendingSidebarRevealIgnoresStaleRequest() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.nextPendingSidebarRevealID = 2
    initialState.pendingSidebarReveal = .init(id: 2, worktreeID: worktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // Stale ID should be ignored, pendingSidebarReveal remains unchanged.
    await store.send(.consumePendingSidebarReveal(1))
  }

  @Test func openRepositoriesDoesNotDowngradeFoldersOnUnexpectedProbeError() async {
    let repoSelection = "/tmp/repo/subdir"
    let repoRoot = "/tmp/repo"
    let blockedRoot = "/tmp/blocked"
    let worktree = makeWorktree(id: "\(repoRoot)/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let savedEntries = LockIsolated<[[PersistedRepositoryEntry]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in
        savedEntries.withValue { $0.append(entries) }
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { url in
        let path = url.path(percentEncoded: false)
        if path == repoSelection {
          return URL(fileURLWithPath: repoRoot)
        }
        if path == blockedRoot {
          throw GitClientError.commandFailed(command: "wt root", message: "permission denied")
        }
        Issue.record("Unexpected repoRoot lookup: \(path)")
        return URL(fileURLWithPath: repoRoot)
      }
      $0.gitClient.worktrees = { url in
        #expect(url.path(percentEncoded: false) == repoRoot)
        return [worktree]
      }
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Some folders couldn't be opened")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("\(blockedRoot): permission denied")
    }

    await store.send(
      .repositoryManagement(
        .openRepositories([
          URL(fileURLWithPath: repoSelection),
          URL(fileURLWithPath: blockedRoot),
        ]))
    )
    await store.receive(\.repositoryManagement.openRepositoriesFinished) {
      $0.repositories = [repository]
      $0.repositoryRoots = [repoRoot].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
      $0.alert = expectedAlert
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    let expectedSavedEntries = [
      [PersistedRepositoryEntry(path: repoRoot, kind: .git)]
    ]
    #expect(savedEntries.value == expectedSavedEntries)
  }

  @Test func repositoriesLoadedSkipsRepositorySnapshotPersistenceWhileRestoring() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let savedSnapshots = LockIsolated<[[Repository]]>([])
    var state = RepositoriesFeature.State()
    state.snapshotPersistencePhase = .restoring

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveRepositorySnapshot = { repositories in
        savedSnapshots.withValue { $0.append(repositories) }
      }
    }

    await store.send(
      .repositoriesLoaded(
        [repository],
        failures: [],
        roots: [URL(fileURLWithPath: repoRoot)],
        animated: false
      )
    ) {
      $0.repositories = [repository]
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    #expect(savedSnapshots.value.isEmpty)
  }

  @Test func repositoriesLoadedPersistsRepositorySnapshotOnSuccess() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let savedSnapshots = LockIsolated<[[Repository]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveRepositorySnapshot = { repositories in
        savedSnapshots.withValue { $0.append(repositories) }
      }
    }

    await store.send(
      .repositoriesLoaded(
        [repository],
        failures: [],
        roots: [URL(fileURLWithPath: repoRoot)],
        animated: false
      )
    ) {
      $0.repositories = [repository]
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    #expect(savedSnapshots.value == [[repository]])
  }

  @Test func repositoriesLoadedSkipsRepositorySnapshotPersistenceWhenLoadFails() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let savedSnapshots = LockIsolated<[[Repository]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveRepositorySnapshot = { repositories in
        savedSnapshots.withValue { $0.append(repositories) }
      }
    }

    await store.send(
      .repositoriesLoaded(
        [repository],
        failures: [.init(rootID: repoRoot, message: "wt failed")],
        roots: [URL(fileURLWithPath: repoRoot)],
        animated: false
      )
    ) {
      $0.repositories = [repository]
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.isInitialLoadComplete = true
      $0.loadFailuresByID = [repoRoot: "wt failed"]
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    #expect(savedSnapshots.value.isEmpty)
  }

  @Test func selectWorktreeSendsDelegate() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "fox")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(worktree.id)) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func activeAgentEntryTappedFocusesSurfaceBeforeSelectingWorktree() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    let surfaceID = UUID()
    let entry = ActiveAgentEntry(
      id: surfaceID,
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      workingDirectory: nil,
      tabID: TerminalTabID(rawValue: UUID()),
      tabTitle: "agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      agent: .codex,
      rawState: .working,
      displayState: .working,
      lastChangedAt: Date(timeIntervalSince1970: 0)
    )
    state.activeAgents.entries = [entry]

    let focusedSurface = LockIsolated<(Worktree.ID, UUID)?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.focusSurface = { worktreeID, surface in
        focusedSurface.setValue((worktreeID, surface))
        return true
      }
    }

    // Tapping mirrors the surface into the keyboard-nav anchor synchronously...
    await store.send(.activeAgents(.entryTapped(entry.id))) {
      $0.activeAgents.focusedSurfaceID = surfaceID
    }
    // ...then the worktree is selected with `focusTerminal` (proved by the pending
    // focus set) only after the target surface has already been focused, so the
    // worktree shows the right tab the instant it becomes visible.
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.openedWorktreeIDs = [worktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)

    #expect(focusedSurface.value?.0 == worktree.id)
    #expect(focusedSurface.value?.1 == surfaceID)
  }

  @Test func activeAgentEntryTappedSelectsPlainRepository() async {
    let repository = makeRepository(
      id: "/tmp/folder",
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    var state = makeState(repositories: [repository])
    let surfaceID = UUID()
    let entry = ActiveAgentEntry(
      id: surfaceID,
      worktreeID: repository.id,
      worktreeName: repository.name,
      workingDirectory: nil,
      tabID: TerminalTabID(rawValue: UUID()),
      tabTitle: "agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      agent: .codex,
      rawState: .working,
      displayState: .working,
      lastChangedAt: Date(timeIntervalSince1970: 0)
    )
    state.activeAgents.entries = [entry]

    let focusedSurface = LockIsolated<(Worktree.ID, UUID)?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.focusSurface = { worktreeID, surface in
        focusedSurface.setValue((worktreeID, surface))
        return true
      }
    }

    await store.send(.activeAgents(.entryTapped(entry.id))) {
      $0.pendingTerminalFocusWorktreeIDs = [repository.id]
      $0.activeAgents.focusedSurfaceID = surfaceID
    }
    await store.receive(\.selectRepository) {
      $0.selection = .repository(repository.id)
      $0.sidebarSelectedWorktreeIDs = []
      $0.openedWorktreeIDs = [repository.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)

    #expect(focusedSurface.value?.0 == repository.id)
    #expect(focusedSurface.value?.1 == surfaceID)
  }

  @Test func selectWorktreeCollapsesSidebarSelectedWorktreeIDs() async {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let wt3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(wt1.id)
    initialState.sidebarSelectedWorktreeIDs = [wt1.id, wt2.id, wt3.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(wt2.id)) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.openedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectRepositoryClearsWorktreeSelectionAndSendsNilDelegate() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectRepository(repository.id)) {
      $0.worktreeHistoryBackStack = [worktree.id]
      $0.selection = .repository(repository.id)
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func focusCanvasRepositoryRequestsCanvasFocusWithoutLeavingCanvas() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .canvas

    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.focusCanvasRepository(repository.id)) {
      $0.nextCanvasFocusRequestID = 1
      $0.pendingCanvasFocusRequest = CanvasFocusRequest(
        id: 1,
        target: .worktree(worktree.id)
      )
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.finish()

    #expect(store.state.selection == .canvas)
    #expect(
      sentCommands.value == [
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      ]
    )
  }

  @Test func focusCanvasPlainRepositoryRequestsCanvasFocusWithoutLeavingCanvas() async {
    let repository = makeRepository(
      id: "/tmp/folder",
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    var initialState = makeState(repositories: [repository])
    initialState.selection = .canvas

    let expectedWorktree = Worktree(
      id: repository.id,
      name: repository.name,
      detail: repository.rootURL.path(percentEncoded: false),
      workingDirectory: repository.rootURL,
      repositoryRootURL: repository.rootURL
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.focusCanvasRepository(repository.id)) {
      $0.nextCanvasFocusRequestID = 1
      $0.pendingCanvasFocusRequest = CanvasFocusRequest(
        id: 1,
        target: .worktree(repository.id)
      )
      $0.openedWorktreeIDs = [repository.id]
    }
    await store.finish()

    #expect(store.state.selection == .canvas)
    #expect(
      sentCommands.value == [
        .ensureInitialTab(expectedWorktree, runSetupScriptIfNew: false, focusing: false)
      ]
    )
  }

  @Test func focusCanvasWorktreeRequestsCanvasFocusWithoutLeavingCanvas() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .canvas

    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.focusCanvasWorktree(worktree.id)) {
      $0.nextCanvasFocusRequestID = 1
      $0.pendingCanvasFocusRequest = CanvasFocusRequest(
        id: 1,
        target: .worktree(worktree.id)
      )
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.finish()

    #expect(store.state.selection == .canvas)
    #expect(
      sentCommands.value == [
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      ]
    )
  }

  @Test func activeAgentEntryTappedInCanvasRequestsExactCardFocusWithoutLeavingCanvas() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.selection = .canvas
    let surfaceID = UUID()
    let tabID = TerminalTabID(rawValue: UUID())
    let entry = ActiveAgentEntry(
      id: surfaceID,
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      workingDirectory: nil,
      tabID: tabID,
      tabTitle: "agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      agent: .codex,
      rawState: .working,
      displayState: .working,
      lastChangedAt: Date(timeIntervalSince1970: 0)
    )
    state.activeAgents.entries = [entry]

    let focusedSurface = LockIsolated<(Worktree.ID, UUID)?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.focusSurface = { worktreeID, surface in
        focusedSurface.setValue((worktreeID, surface))
        return true
      }
    }

    await store.send(.activeAgents(.entryTapped(entry.id))) {
      $0.activeAgents.focusedSurfaceID = surfaceID
      $0.nextCanvasFocusRequestID = 1
      $0.pendingCanvasFocusRequest = CanvasFocusRequest(
        id: 1,
        target: .tab(tabID)
      )
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.finish()

    #expect(store.state.selection == .canvas)
    #expect(focusedSurface.value?.0 == worktree.id)
    #expect(focusedSurface.value?.1 == surfaceID)
  }

  @Test func selectPlainRepositorySendsPlainFolderTerminalTargetDelegate() async {
    let repository = makeRepository(
      id: "/tmp/folder",
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectRepository(repository.id)) {
      $0.selection = .repository(repository.id)
      $0.sidebarSelectedWorktreeIDs = []
      $0.openedWorktreeIDs = [repository.id]
    }
    #expect(
      store.state.selectedTerminalWorktree
        == Worktree(
          id: repository.id,
          name: repository.name,
          detail: repository.rootURL.path(percentEncoded: false),
          workingDirectory: repository.rootURL,
          repositoryRootURL: repository.rootURL
        )
    )
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func toggleCanvasRestoresFocusedPlainRepositorySelection() async {
    let repository = makeRepository(
      id: "/tmp/folder",
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    var initialState = makeState(repositories: [repository])
    initialState.selection = .canvas
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { repository.id }
    }

    await store.send(.toggleCanvas) {
      $0.pendingTerminalFocusWorktreeIDs = [repository.id]
    }
    await store.receive(\.selectRepository) {
      $0.selection = .repository(repository.id)
      $0.sidebarSelectedWorktreeIDs = []
      $0.openedWorktreeIDs = [repository.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func toggleCanvasFallsBackToPreCanvasPlainRepositorySelection() async {
    let repository = makeRepository(
      id: "/tmp/folder",
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    var initialState = makeState(repositories: [repository])
    initialState.selection = .canvas
    initialState.preCanvasTerminalTargetID = repository.id
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { nil }
    }

    await store.send(.toggleCanvas) {
      $0.pendingTerminalFocusWorktreeIDs = [repository.id]
    }
    await store.receive(\.selectRepository) {
      $0.selection = .repository(repository.id)
      $0.sidebarSelectedWorktreeIDs = []
      $0.openedWorktreeIDs = [repository.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectTabbedFromCanvasExitsCanvasInsteadOfFocusingCard() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .canvas

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { worktree.id }
    }

    await store.send(.setTopSegment(.tabbed))
    await store.receive(\.selectTabbed)
    await store.receive(\.toggleCanvas)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktree.id]
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    #expect(store.state.pendingCanvasFocusRequest == nil)
  }

  @Test func selectShelfFromCanvasExitsCanvasInsteadOfFocusingCard() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .canvas

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { worktree.id }
    }

    await store.send(.setTopSegment(.shelf))
    await store.receive(\.selectShelf)
    await store.receive(\.toggleShelf) {
      $0.isShelfActive = true
    }
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktree.id]
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    #expect(store.state.pendingCanvasFocusRequest == nil)
    #expect(store.state.isShowingShelf)
  }

  @Test func selectCanvasSeedsInitialTabForSelectedWorktree() async {
    // Canvas only renders cards for worktrees with a live terminal surface.
    // Entering Canvas must seed the selected worktree's tab so launching
    // straight into Canvas shows that worktree's card — Normal/Shelf open one
    // tab on launch, but Canvas mounts no per-worktree view to do it lazily.
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)

    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.selectCanvas) {
      $0.preCanvasWorktreeID = worktree.id
      $0.preCanvasTerminalTargetID = worktree.id
      $0.selection = .canvas
    }
    await store.finish()

    #expect(
      sentCommands.value == [
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false),
        .setCanvasMode(true),
      ]
    )
  }

  @Test func selectCanvasWithoutSelectionOnlyEntersCanvasMode() async {
    // With nothing selected there is no surface to seed — Canvas just flips
    // into canvas mode and renders an empty board.
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.selectCanvas) {
      $0.selection = .canvas
    }
    await store.finish()

    #expect(sentCommands.value == [.setCanvasMode(true)])
  }

  @Test func selectRepositoryIgnoresUnknownRepository() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.selectRepository("/tmp/missing"))
  }

  @Test func setSidebarSelectedWorktreeIDsKeepsSelectedAndPrunesUnknown() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree1.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .setSidebarSelectedWorktreeIDs(
        [worktree2.id, "/tmp/repo/unknown"]
      )
    ) {
      $0.sidebarSelectedWorktreeIDs = [worktree1.id, worktree2.id]
    }
  }

  @Test func selectArchivedWorktreesClearsSidebarSelectedWorktreeIDs() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree1.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree1.id, worktree2.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectArchivedWorktrees) {
      $0.worktreeHistoryBackStack = [worktree1.id]
      $0.selection = .archivedWorktrees
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func createRandomWorktreeWithoutRepositoriesShowsAlert() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Open a repository to create a worktree.")
    }

    await store.send(.worktreeCreation(.createRandomWorktree)) {
      $0.alert = expectedAlert
    }
  }

  @Test func canCreateWorktreeIsFalseForSelectedPlainRepository() {
    let repository = makeRepository(id: "/tmp/folder", kind: .plain, worktrees: [])
    var state = makeState(repositories: [repository])
    state.selection = .repository(repository.id)

    #expect(state.canCreateWorktree == false)
  }

  @Test func createRandomWorktreeInPlainRepositoryShowsAlert() async {
    let repository = makeRepository(id: "/tmp/folder", kind: .plain, worktrees: [])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .repository(repository.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("This folder doesn't support worktrees.")
    }

    await store.send(.worktreeCreation(.createRandomWorktree)) {
      $0.alert = expectedAlert
    }
  }

  @Test func createRandomWorktreeInRepositoryWithPromptEnabledPresentsPrompt() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.branchRefs = { _ in ["origin/main", "origin/dev"] }
    }

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.promptedWorktreeCreationDataLoaded) {
      $0.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repository.id,
        repositoryRootURL: repository.rootURL,
        repositoryName: repository.name,
        automaticBaseRef: "origin/main",
        baseRefOptions: ["origin/dev", "origin/main"],
        branchName: "",
        selectedBaseRef: nil,
        fetchRemote: true,
        defaultWorktreeBaseDirectory: SupacodePaths.worktreeBaseDirectory(
          for: repository.rootURL,
          globalDefaultPath: nil,
          repositoryOverridePath: nil
        ).path(percentEncoded: false),
        validationMessage: nil
      )
    }
  }

  @Test func promptedWorktreeCreationCancelDismissesPrompt() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      baseRefOptions: ["origin/main"],
      branchName: "feature/new-branch",
      selectedBaseRef: nil,
      fetchRemote: true,
      defaultWorktreeBaseDirectory: "",
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeCreationPrompt(.presented(.delegate(.cancel))))
    await store.receive(\.worktreeCreation.promptCanceled) {
      $0.worktreeCreationPrompt = nil
    }
  }

  @Test func startPromptedWorktreeCreationWithDuplicateLocalBranchShowsValidation() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      baseRefOptions: ["origin/main"],
      branchName: "feature/existing",
      selectedBaseRef: nil,
      fetchRemote: true,
      defaultWorktreeBaseDirectory: "",
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.localBranchNames = { _ in ["feature/existing"] }
    }

    await store.send(
      .worktreeCreation(
        .startPromptedWorktreeCreation(
          repositoryID: repository.id,
          branchName: "feature/existing",
          baseRef: nil
        ))
    ) {
      $0.worktreeCreationPrompt?.validationMessage = nil
      $0.worktreeCreationPrompt?.isValidating = true
    }
    await store.receive(\.worktreeCreation.promptedWorktreeCreationChecked) {
      $0.worktreeCreationPrompt?.validationMessage = "Branch name already exists."
      $0.worktreeCreationPrompt?.isValidating = false
    }
  }

  @Test func createRandomWorktreeInRepositoryLatestPromptRequestWins() async {
    actor PromptLoadGate {
      var continuation: CheckedContinuation<Void, Never>?

      func wait() async {
        await withCheckedContinuation { continuation in
          self.continuation = continuation
        }
      }

      func waitUntilArmed() async {
        while continuation == nil {
          await Task.yield()
        }
      }

      func resume() {
        continuation?.resume()
        continuation = nil
      }
    }

    let repoRootA = "/tmp/repo-a"
    let repoRootB = "/tmp/repo-b"
    let promptLoadGate = PromptLoadGate()
    let repoA = makeRepository(
      id: repoRootA,
      worktrees: [makeWorktree(id: repoRootA, name: "main", repoRoot: repoRootA)]
    )
    let repoB = makeRepository(
      id: repoRootB,
      worktrees: [makeWorktree(id: repoRootB, name: "main", repoRoot: repoRootB)]
    )
    let store = TestStore(initialState: makeState(repositories: [repoA, repoB])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.automaticWorktreeBaseRef = { root in
        if root.path(percentEncoded: false) == repoRootA {
          await promptLoadGate.wait()
        }
        return "origin/main"
      }
      $0.gitClient.branchRefs = { _ in ["origin/main"] }
    }

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repoA.id)))
    await promptLoadGate.waitUntilArmed()
    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repoB.id)))
    await promptLoadGate.resume()
    await store.receive(\.worktreeCreation.promptedWorktreeCreationDataLoaded) {
      $0.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repoB.id,
        repositoryRootURL: repoB.rootURL,
        repositoryName: repoB.name,
        automaticBaseRef: "origin/main",
        baseRefOptions: ["origin/main"],
        branchName: "",
        selectedBaseRef: nil,
        fetchRemote: true,
        defaultWorktreeBaseDirectory: SupacodePaths.worktreeBaseDirectory(
          for: repoB.rootURL,
          globalDefaultPath: nil,
          repositoryOverridePath: nil
        ).path(percentEncoded: false),
        validationMessage: nil
      )
    }
    await store.finish()
  }

  @Test func promptedWorktreeCreationCancelDuringValidationStopsCreation() async {
    let validationClock = TestClock()
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      baseRefOptions: ["origin/main"],
      branchName: "feature/new-branch",
      selectedBaseRef: nil,
      fetchRemote: true,
      defaultWorktreeBaseDirectory: "",
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.localBranchNames = { _ in
        try? await validationClock.sleep(for: .seconds(1))
        return []
      }
    }

    await store.send(
      .worktreeCreation(
        .startPromptedWorktreeCreation(
          repositoryID: repository.id,
          branchName: "feature/new-branch",
          baseRef: nil
        ))
    ) {
      $0.worktreeCreationPrompt?.validationMessage = nil
      $0.worktreeCreationPrompt?.isValidating = true
    }
    await store.send(.worktreeCreationPrompt(.presented(.delegate(.cancel))))
    await store.receive(\.worktreeCreation.promptCanceled) {
      $0.worktreeCreationPrompt = nil
    }
    await validationClock.advance(by: .seconds(1))
    await store.finish()
  }

  @Test func createWorktreeInRepositoryWithInvalidBranchNameFails() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.isValidBranchName = { _, _ in false }
      $0.gitClient.localBranchNames = { _ in [] }
    }
    store.exhaustivity = .off

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name invalid")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Enter a valid git branch name and try again.")
    }

    await store.send(
      .worktreeCreation(
        .createWorktreeInRepository(
          repositoryID: repository.id,
          nameSource: .explicit("../../Desktop"),
          baseRefSource: .repositorySetting,
          fetchRemote: true
        ))
    )
    await store.receive(\.worktreeCreation.createRandomWorktreeFailed) {
      $0.alert = expectedAlert
    }
    #expect(store.state.pendingWorktrees.isEmpty)
    await store.finish()
  }

  @Test func createRandomWorktreeFailedWithTraversalNameSkipsCleanup() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let removed = LockIsolated(false)
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in
        removed.withValue { $0 = true }
        return URL(fileURLWithPath: "/tmp/removed")
      }
      $0.gitClient.pruneWorktrees = { _ in }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .worktreeCreation(
        .createRandomWorktreeFailed(
          title: "Unable to create worktree",
          message: "boom",
          pendingID: "pending:1",
          previousSelection: nil,
          repositoryID: repository.id,
          name: "../../Desktop",
          baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees")
        ))
    ) {
      $0.alert = expectedAlert
    }
    await store.finish()
    #expect(removed.value == false)
  }

  @Test(.dependencies) func createRandomWorktreeInRepositoryStreamsOutputLines() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = false
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 2 }
      $0.gitClient.untrackedFileCount = { _ in 1 }
      $0.gitClient.createWorktreeStream = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[1/2] copy .env")))
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[2/2] copy .cache")))
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(store.state.selection == .worktree(createdWorktree.id))
    #expect(store.state.sidebarSelectedWorktreeIDs == [createdWorktree.id])
    #expect(store.state.pendingSetupScriptWorktreeIDs.contains(createdWorktree.id))
    #expect(store.state.pendingTerminalFocusWorktreeIDs.contains(createdWorktree.id))
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: createdWorktree.id] != nil)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func createWorktreeFetchesMatchedRemoteBeforeCreatingWorktree() async {
    let repoRoot = "/tmp/\(UUID().uuidString)-repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "\(repoRoot)/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.remoteNames = { _ in ["origin", "upstream"] }
      $0.gitClient.fetchRemote = { remote, _ in
        events.withValue { $0.append("fetch:\(remote)") }
      }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _ in
        events.withValue { $0.append("create") }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeCreation(
        .createWorktreeInRepository(
          repositoryID: repository.id,
          nameSource: .random,
          baseRefSource: .repositorySetting,
          fetchRemote: true
        ))
    )
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(events.value == ["fetch:origin", "create"])
  }

  @Test(.dependencies) func createWorktreeSkipsFetchWhenDisabled() async {
    let repoRoot = "/tmp/\(UUID().uuidString)-repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "\(repoRoot)/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.remoteNames = { _ in
        Issue.record("remoteNames should not be requested when fetch is disabled")
        return ["origin"]
      }
      $0.gitClient.fetchRemote = { _, _ in
        Issue.record("fetchRemote should not run when fetch is disabled")
      }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeCreation(
        .createWorktreeInRepository(
          repositoryID: repository.id,
          nameSource: .random,
          baseRefSource: .repositorySetting,
          fetchRemote: false
        ))
    )
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()
  }

  @Test(.dependencies) func createWorktreeContinuesWhenFetchFails() async {
    let repoRoot = "/tmp/\(UUID().uuidString)-repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "\(repoRoot)/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { _, _ in
        throw NSError(domain: "git", code: 128, userInfo: [NSLocalizedDescriptionKey: "network unreachable"])
      }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeCreation(
        .createWorktreeInRepository(
          repositoryID: repository.id,
          nameSource: .random,
          baseRefSource: .repositorySetting,
          fetchRemote: true
        ))
    )
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()
  }

  @Test(.dependencies) func createWorktreeSkipsFetchWhenNoMatchedRemote() async {
    let repoRoot = "/tmp/\(UUID().uuidString)-repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "\(repoRoot)/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "local-branch" }
      $0.gitClient.remoteNames = { _ in ["origin", "upstream"] }
      $0.gitClient.fetchRemote = { _, _ in
        Issue.record("fetchRemote should not run when no remote matches the base ref")
      }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeCreation(
        .createWorktreeInRepository(
          repositoryID: repository.id,
          nameSource: .random,
          baseRefSource: .repositorySetting,
          fetchRemote: true
        ))
    )
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()
  }

  @Test(.dependencies) func createRandomWorktreeUsesRepositoryWorktreeBaseDirectoryOverride() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let observedBaseDirectory = LockIsolated<URL?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = false
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/global-worktrees"
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.worktreeBaseDirectoryPath = "/tmp/repo-override"
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { request in
        observedBaseDirectory.withValue { $0 = request.baseDirectory }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()

    let expectedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/global-worktrees",
      repositoryOverridePath: "/tmp/repo-override"
    )
    #expect(observedBaseDirectory.value == expectedBaseDirectory)
  }

  @Test(.dependencies) func createRandomWorktreeUsesGlobalWorktreeBaseDirectoryWhenRepositoryOverrideMissing() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let observedBaseDirectory = LockIsolated<URL?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = false
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/global-worktrees"
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.worktreeBaseDirectoryPath = nil
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { request in
        observedBaseDirectory.withValue { $0 = request.baseDirectory }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()

    let expectedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/global-worktrees",
      repositoryOverridePath: nil
    )
    #expect(observedBaseDirectory.value == expectedBaseDirectory)
  }

  @Test(.dependencies) func createRandomWorktreeUsesGlobalCopyFlagsWhenRepositoryOverridesMissing() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let observedCopyFlags = LockIsolated<(Bool, Bool)?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.copyIgnoredOnWorktreeCreate = true
      $0.global.copyUntrackedOnWorktreeCreate = true
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.copyIgnoredOnWorktreeCreate = nil
      $0.copyUntrackedOnWorktreeCreate = nil
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { request in
        observedCopyFlags.withValue { $0 = (request.copyFiles.ignored, request.copyFiles.untracked) }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(observedCopyFlags.value?.0 == true)
    #expect(observedCopyFlags.value?.1 == true)
  }

  @Test(.dependencies) func createRandomWorktreeInBareRepositoryIgnoresGlobalCopyFlags() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let observedCopyFlags = LockIsolated<(Bool, Bool)?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.copyIgnoredOnWorktreeCreate = true
      $0.global.copyUntrackedOnWorktreeCreate = true
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.copyIgnoredOnWorktreeCreate = nil
      $0.copyUntrackedOnWorktreeCreate = nil
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in true }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { request in
        observedCopyFlags.withValue { $0 = (request.copyFiles.ignored, request.copyFiles.untracked) }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(observedCopyFlags.value?.0 == false)
    #expect(observedCopyFlags.value?.1 == false)
  }

  @Test(.dependencies) func createRandomWorktreeInRepositoryStreamFailureRemovesPendingWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = false
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 2 }
      $0.gitClient.untrackedFileCount = { _ in 1 }
      $0.gitClient.createWorktreeStream = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[1/2] copy .env")))
          continuation.finish(throwing: GitClientError.commandFailed(command: "wt sw", message: "boom"))
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.createRandomWorktreeFailed)
    await store.finish()

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Git command failed: wt sw\nboom")
    }

    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(store.state.selection == nil)
    #expect(store.state.alert == expectedAlert)
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: mainWorktree.id] != nil)
  }

  @Test(.dependencies) func createRandomWorktreeFailureUsesProvidedBaseDirectoryForCleanup() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createTimeBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/worktrees-original",
      repositoryOverridePath: nil
    )
    let changedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/worktrees-changed",
      repositoryOverridePath: nil
    )
    let removedWorktree = LockIsolated<(path: String, deleteBranch: Bool)?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/worktrees-changed"
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, deleteBranch in
        let workingDirectory = await MainActor.run { worktree.workingDirectory }
        removedWorktree.withValue {
          $0 = (workingDirectory.path(percentEncoded: false), deleteBranch)
        }
        return workingDirectory
      }
      $0.gitClient.pruneWorktrees = { _ in }
    }
    store.exhaustivity = .off

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .worktreeCreation(
        .createRandomWorktreeFailed(
          title: "Unable to create worktree",
          message: "boom",
          pendingID: "pending:test",
          previousSelection: nil,
          repositoryID: repository.id,
          name: "new-branch",
          baseDirectory: createTimeBaseDirectory
        ))
    ) {
      $0.alert = expectedAlert
    }
    await store.finish()

    #expect(changedBaseDirectory != createTimeBaseDirectory)
    #expect(removedWorktree.value != nil)
    #expect(removedWorktree.value?.deleteBranch == false)
    #expect(
      removedWorktree.value?.path
        == createTimeBaseDirectory
        .appending(path: "new-branch", directoryHint: .isDirectory)
        .path(percentEncoded: false)
    )
    #expect(
      removedWorktree.value?.path
        != changedBaseDirectory
        .appending(path: "new-branch", directoryHint: .isDirectory)
        .path(percentEncoded: false)
    )
  }

  @Test func pendingProgressUpdateUpdatesPendingWorktreeState() async {
    let repoRoot = "/tmp/repo"
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)]
    )
    let pendingID = "pending:test"
    var state = makeState(repositories: [repository])
    state.selection = .worktree(pendingID)
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches)
      )
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let nextProgress = WorktreeCreationProgress(
      stage: .creatingWorktree,
      worktreeName: "swift-otter",
      baseRef: "origin/main",
      copyIgnored: false,
      copyUntracked: true
    )
    await store.send(
      .worktreeCreation(
        .pendingWorktreeProgressUpdated(
          id: pendingID,
          progress: nextProgress
        ))
    ) {
      $0.pendingWorktrees[0].progress = nextProgress
    }
  }

  @Test func pendingProgressUpdateIsIgnoredAfterCreateFailureRemovesPendingWorktree() async {
    let repoRoot = "/tmp/repo"
    let repository = makeRepository(id: repoRoot, worktrees: [makeWorktree(id: repoRoot, name: "main")])
    let pendingID = "pending:test"
    var state = makeState(repositories: [repository])
    state.selection = .worktree(pendingID)
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(
          stage: .checkingRepositoryMode,
          worktreeName: "swift-otter"
        )
      )
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .worktreeCreation(
        .createRandomWorktreeFailed(
          title: "Unable to create worktree",
          message: "boom",
          pendingID: pendingID,
          previousSelection: nil,
          repositoryID: repository.id,
          name: nil,
          baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees")
        ))
    ) {
      $0.pendingWorktrees = []
      $0.selection = nil
      $0.alert = expectedAlert
    }

    await store.send(
      .worktreeCreation(
        .pendingWorktreeProgressUpdated(
          id: pendingID,
          progress: WorktreeCreationProgress(stage: .creatingWorktree)
        ))
    )
    #expect(store.state.pendingWorktrees.isEmpty)
  }

  @Test func requestDeleteWorktreeShowsConfirmation() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.worktreeLifecycle(.requestDeleteWorktree(worktree.id, repository.id))) {
      $0.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
        id: 0,
        title: "Delete worktree?",
        message: "Delete \(worktree.name)? The worktree directory will be removed.",
        targets: [RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree.id, repositoryID: repository.id)],
        deleteBranch: false
      )
      $0.nextDeleteWorktreeConfirmationID = 1
    }
  }

  @Test(.dependencies) func requestDeleteProwlCreatedWorktreeCanPreselectBranchDeletion() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let state = makeState(repositories: [repository])
    state.$prowlCreatedWorktreeIDs.withLock {
      $0 = [worktree.id]
    }
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.deleteBranchOnDeleteWorktree = true
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeLifecycle(.requestDeleteWorktree(worktree.id, repository.id))) {
      $0.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
        id: 0,
        title: "Delete worktree?",
        message: "Delete \(worktree.name)? The worktree directory will be removed.",
        targets: [RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree.id, repositoryID: repository.id)],
        deleteBranch: true
      )
      $0.nextDeleteWorktreeConfirmationID = 1
    }
  }

  @Test(.dependencies) func deletePromptConfirmedAsksBeforeForceDeletingBranch() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, worktree])
    var state = makeState(repositories: [repository])
    state.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
      id: 0,
      title: "Delete worktree?",
      message: "Delete feature? The worktree directory will be removed.",
      targets: [RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree.id, repositoryID: repository.id)],
      deleteBranch: true
    )
    let forceDeleteAttempts = LockIsolated<[Bool]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, deleteBranch in
        #expect(deleteBranch == false)
        return worktree.workingDirectory
      }
      $0.gitClient.deleteLocalBranch = { _, _, force in
        forceDeleteAttempts.withValue { $0.append(force) }
        if force {
          return .deleted
        }
        throw GitClientError.commandFailed(command: "git branch -d feature", message: "not fully merged")
      }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.worktreeLifecycle(.deleteWorktreePromptConfirmed)) {
      $0.deleteWorktreeConfirmation = nil
    }
    await store.receive(\.worktreeLifecycle.deleteWorktreeConfirmed) {
      $0.deletingWorktreeIDs = [worktree.id]
    }
    await store.receive(\.worktreeLifecycle.worktreeDeleted) {
      $0.deletingWorktreeIDs = []
      $0.repositories = [makeRepository(id: repoRoot, worktrees: [mainWorktree])]
      #expect($0.alert != nil)
    }
    await store.send(
      .alert(
        .presented(
          .confirmForceDeleteBranch(
            ForceDeleteBranchRequest(
              branchName: "feature",
              repositoryRootURL: URL(fileURLWithPath: repoRoot),
              errorMessage: "Git command failed: git branch -d feature\nnot fully merged"
            )))))

    #expect(forceDeleteAttempts.value == [false, true])
  }

  @Test(.dependencies) func worktreeDeletedPresentsQueuedForceDeleteBranchPromptsInOrder() async {
    let repoRoot = "/tmp/repo"
    let firstRequest = ForceDeleteBranchRequest(
      branchName: "first",
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      errorMessage: "first failed"
    )
    let secondRequest = ForceDeleteBranchRequest(
      branchName: "second",
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      errorMessage: "second failed"
    )
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.deleteLocalBranch = { _, _, _ in .deleted }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeLifecycle(
        .worktreeDeleted(
          "/tmp/repo/first",
          repositoryID: repoRoot,
          selectionWasRemoved: false,
          nextSelection: nil,
          forceDeleteBranchRequest: firstRequest
        ))
    ) {
      $0.pendingForceDeleteBranchRequests = [firstRequest]
      #expect($0.alert != nil)
    }
    await store.send(
      .worktreeLifecycle(
        .worktreeDeleted(
          "/tmp/repo/second",
          repositoryID: repoRoot,
          selectionWasRemoved: false,
          nextSelection: nil,
          forceDeleteBranchRequest: secondRequest
        ))
    ) {
      $0.pendingForceDeleteBranchRequests = [firstRequest, secondRequest]
      #expect($0.alert != nil)
    }
    await store.send(.alert(.presented(.confirmForceDeleteBranch(firstRequest))))
    await store.receive(\.worktreeLifecycle.forceDeleteBranchConfirmed) {
      $0.pendingForceDeleteBranchRequests = [secondRequest]
      #expect($0.alert != nil)
    }
    await store.send(.alert(.dismiss)) {
      $0.alert = nil
      $0.pendingForceDeleteBranchRequests = []
    }
  }

  @Test func requestDeleteMainWorktreeShowsNotAllowedAlert() async {
    let mainWorktree = makeWorktree(id: "/tmp/repo", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [mainWorktree])

    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Delete not allowed")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Deleting the main worktree is not allowed.")
    }

    await store.send(.worktreeLifecycle(.requestDeleteWorktree(mainWorktree.id, repository.id))) {
      $0.alert = expectedAlert
    }
  }
  @Test func requestDeleteWorktreesShowsBatchConfirmation() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "owl", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "hawk", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    let targets = [
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree1.id, repositoryID: repository.id),
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree2.id, repositoryID: repository.id),
    ]
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.worktreeLifecycle(.requestDeleteWorktrees(targets))) {
      $0.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
        id: 0,
        title: "Delete 2 worktrees?",
        message: "Delete 2 worktrees? Their worktree directories will be removed.",
        targets: targets,
        deleteBranch: false
      )
      $0.nextDeleteWorktreeConfirmationID = 1
    }
  }

  @Test func requestArchiveWorktreeShowsConfirmation() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let archivedDisplay = AppShortcuts.archivedWorktrees.display
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive worktree?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchiveWorktree(worktree.id, repository.id)) {
        TextState("Archive (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Find \(worktree.name) later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay)).")
    }

    await store.send(.worktreeLifecycle(.requestArchiveWorktree(worktree.id, repository.id))) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestArchiveWorktreesShowsBatchConfirmation() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "owl", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "hawk", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    let targets = [
      RepositoriesFeature.ArchiveWorktreeTarget(worktreeID: worktree1.id, repositoryID: repository.id),
      RepositoriesFeature.ArchiveWorktreeTarget(worktreeID: worktree2.id, repositoryID: repository.id),
    ]
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let archivedDisplay = AppShortcuts.archivedWorktrees.display
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive 2 worktrees?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchiveWorktrees(targets)) {
        TextState("Archive 2 (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Find them later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay)).")
    }

    await store.send(.worktreeLifecycle(.requestArchiveWorktrees(targets))) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestArchiveWorktreeMergedArchivesImmediately() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(featureWorktree.id)
    state.pinnedWorktreeIDs = [featureWorktree.id]
    state.worktreeOrderByRepository[repoRoot] = [featureWorktree.id]
    state.worktreeInfoByID = [
      featureWorktree.id: WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: makePullRequest(state: "MERGED")
      )
    ]
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
    }

    await store.send(.worktreeLifecycle(.requestArchiveWorktree(featureWorktree.id, repository.id)))
    await store.receive(\.worktreeLifecycle.archiveWorktreeConfirmed)
    await store.receive(\.worktreeLifecycle.archiveWorktreeApply) {
      $0.archivedWorktrees = [ArchivedWorktree(id: featureWorktree.id, archivedAt: fixedDate)]
      $0.pinnedWorktreeIDs = []
      $0.worktreeOrderByRepository = [:]
      $0.selection = .worktree(mainWorktree.id)
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test(.dependencies) func archiveWorktreeConfirmedRunsArchiveScriptAndShowsProgress() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(mainWorktree.id)
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.archiveScript = "echo syncing\necho done"
    }
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      $0.shellClient.runLoginStreamImpl = { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "syncing")))
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "done")))
          continuation.yield(.finished(ShellOutput(stdout: "syncing\ndone", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    }

    await store.send(.worktreeLifecycle(.archiveWorktreeConfirmed(featureWorktree.id, repository.id))) {
      $0.archivingWorktreeIDs = [featureWorktree.id]
      $0.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "Preparing archive script",
        commandText: "bash -lc 'echo syncing\\necho done'"
      )
    }
    await store.receive(\.worktreeLifecycle.archiveScriptProgressUpdated) {
      $0.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "syncing",
        commandText: "bash -lc 'echo syncing\\necho done'",
        outputLines: ["syncing"]
      )
    }
    await store.receive(\.worktreeLifecycle.archiveScriptProgressUpdated) {
      $0.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "done",
        commandText: "bash -lc 'echo syncing\\necho done'",
        outputLines: ["syncing", "done"]
      )
    }
    await store.receive(\.worktreeLifecycle.archiveScriptSucceeded) {
      $0.archivingWorktreeIDs = []
      $0.archiveScriptProgressByWorktreeID = [:]
    }
    await store.receive(\.worktreeLifecycle.archiveWorktreeApply) {
      $0.archivedWorktrees = [ArchivedWorktree(id: featureWorktree.id, archivedAt: fixedDate)]
    }
    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test(.dependencies) func archiveWorktreeConfirmedScriptFailureBlocksArchive() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.archiveScript = "exit 7"
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.shellClient.runLoginStreamImpl = { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.finish(
            throwing: ShellClientError(
              command: "bash -lc exit 7",
              stdout: "",
              stderr: "fail",
              exitCode: 7
            )
          )
        }
      }
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive script failed")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Command failed: bash -lc exit 7\nstderr:\nfail")
    }

    await store.send(.worktreeLifecycle(.archiveWorktreeConfirmed(featureWorktree.id, repository.id))) {
      $0.archivingWorktreeIDs = [featureWorktree.id]
      $0.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "Preparing archive script",
        commandText: "bash -lc 'exit 7'"
      )
    }
    await store.receive(\.worktreeLifecycle.archiveScriptFailed) {
      $0.archivingWorktreeIDs = []
      $0.archiveScriptProgressByWorktreeID = [:]
      $0.alert = expectedAlert
    }
    #expect(store.state.archivedWorktrees.isEmpty)
  }

  @Test func archiveScriptSucceededIgnoredWhenNotArchiving() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeLifecycle(.archiveScriptSucceeded(worktreeID: featureWorktree.id, repositoryID: repository.id))
    )
    #expect(store.state.archivedWorktrees.isEmpty)
  }

  @Test func archiveScriptFailedIgnoredWhenNotArchiving() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.worktreeLifecycle(.archiveScriptFailed(worktreeID: featureWorktree.id, message: "late failure")))
    #expect(store.state.alert == nil)
    #expect(store.state.archivedWorktrees.isEmpty)
  }

  @Test func repositoriesLoadedKeepsArchiveInFlightUntilSuccessCompletion() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let reloadedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    state.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
      titleText: "Running archive script",
      detailText: "still running"
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    #expect(store.state.archivingWorktreeIDs.contains(featureWorktree.id))
    #expect(store.state.archiveScriptProgressByWorktreeID[featureWorktree.id] != nil)

    await store.send(
      .worktreeLifecycle(.archiveScriptSucceeded(worktreeID: featureWorktree.id, repositoryID: repository.id))
    )
    #expect(store.state.archivingWorktreeIDs.isEmpty)
    #expect(store.state.archiveScriptProgressByWorktreeID.isEmpty)
  }

  @Test func repositoriesLoadedKeepsArchiveInFlightUntilFailureCompletion() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let reloadedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    state.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
      titleText: "Running archive script",
      detailText: "still running"
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    #expect(store.state.archivingWorktreeIDs.contains(featureWorktree.id))
    #expect(store.state.archiveScriptProgressByWorktreeID[featureWorktree.id] != nil)

    await store.send(.worktreeLifecycle(.archiveScriptFailed(worktreeID: featureWorktree.id, message: "script failed")))
    #expect(store.state.archivingWorktreeIDs.isEmpty)
    #expect(store.state.archiveScriptProgressByWorktreeID.isEmpty)
    #expect(store.state.alert != nil)
  }

  @Test func requestRenameBranchWithEmptyNameShowsAlert() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name required")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Enter a branch name to rename.")
    }

    await store.send(.requestRenameBranch(worktree.id, " ")) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestRenameBranchWithWhitespaceShowsAlert() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name invalid")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Branch names can't contain spaces.")
    }

    await store.send(.requestRenameBranch(worktree.id, "feature branch")) {
      $0.alert = expectedAlert
    }
  }

  @Test func worktreeNotificationReceivedDoesNotShowStatusToast() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.worktreeNotificationReceived(featureWorktree.id)))
    #expect(store.state.statusToast == nil)
  }

  @Test func worktreeNotificationReceivedReordersUnpinnedWorktrees() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB])
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [featureA.id, featureB.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.worktreeNotificationReceived(featureB.id))) {
      $0.worktreeOrderByRepository[repoRoot] = [featureB.id, featureA.id]
    }
    #expect(store.state.statusToast == nil)
  }

  @Test func worktreeNotificationReceivedDoesNotReorderWhenMoveToTopDisabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB])
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [featureA.id, featureB.id]
    state.moveNotifiedWorktreeToTop = false
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.worktreeNotificationReceived(featureB.id)))
    #expect(store.state.worktreeOrderByRepository[repoRoot] == [featureA.id, featureB.id])
    #expect(store.state.statusToast == nil)
  }

  @Test func worktreeNotificationDuringSidebarDragDefersReorder() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB])
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [featureA.id, featureB.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.setSidebarDragActive(true))) {
      $0.isSidebarDragActive = true
    }
    await store.send(.worktreeOrdering(.worktreeNotificationReceived(featureB.id))) {
      $0.pendingSidebarNotifyReorderIDs = [featureB.id]
    }
    #expect(store.state.worktreeOrderByRepository[repoRoot] == [featureA.id, featureB.id])
  }

  @Test func endingSidebarDragAppliesPendingNotificationReordersInOrder() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let featureC = makeWorktree(id: "/tmp/repo/c", name: "c", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB, featureC])
    var state = makeState(repositories: [repository])
    state.isSidebarDragActive = true
    state.pendingSidebarNotifyReorderIDs = [featureA.id, featureC.id, featureB.id]
    state.worktreeOrderByRepository[repoRoot] = [featureA.id, featureB.id, featureC.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.setSidebarDragActive(false))) {
      $0.isSidebarDragActive = false
      $0.pendingSidebarNotifyReorderIDs = []
      $0.worktreeOrderByRepository[repoRoot] = [featureB.id, featureC.id, featureA.id]
    }
  }

  @Test func repeatedNotificationDuringSidebarDragKeepsLatestPosition() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB])
    var state = makeState(repositories: [repository])
    state.isSidebarDragActive = true
    state.worktreeOrderByRepository[repoRoot] = [featureA.id, featureB.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.worktreeNotificationReceived(featureA.id))) {
      $0.pendingSidebarNotifyReorderIDs = [featureA.id]
    }
    await store.send(.worktreeOrdering(.worktreeNotificationReceived(featureB.id))) {
      $0.pendingSidebarNotifyReorderIDs = [featureA.id, featureB.id]
    }
    await store.send(.worktreeOrdering(.worktreeNotificationReceived(featureA.id))) {
      $0.pendingSidebarNotifyReorderIDs = [featureB.id, featureA.id]
    }
    await store.send(.worktreeOrdering(.setSidebarDragActive(false))) {
      $0.isSidebarDragActive = false
      $0.pendingSidebarNotifyReorderIDs = []
      $0.worktreeOrderByRepository[repoRoot] = [featureA.id, featureB.id]
    }
  }

  @Test func stalePendingNotificationReordersAreIgnoredWhenDragEnds() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA])
    var state = makeState(repositories: [repository])
    state.isSidebarDragActive = true
    state.pendingSidebarNotifyReorderIDs = ["/tmp/repo/stale", featureA.id]
    state.worktreeOrderByRepository[repoRoot] = [featureA.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.setSidebarDragActive(false))) {
      $0.isSidebarDragActive = false
      $0.pendingSidebarNotifyReorderIDs = []
    }
  }

  @Test func notificationDuringSidebarDragDoesNotRecordWhenMoveToTopDisabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA])
    var state = makeState(repositories: [repository])
    state.isSidebarDragActive = true
    state.moveNotifiedWorktreeToTop = false
    state.worktreeOrderByRepository[repoRoot] = [featureA.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.worktreeNotificationReceived(featureA.id)))
    #expect(store.state.pendingSidebarNotifyReorderIDs.isEmpty)
    #expect(store.state.worktreeOrderByRepository[repoRoot] == [featureA.id])
  }

  @Test func setMoveNotifiedWorktreeToTopUpdatesState() async {
    var state = makeState(repositories: [])
    state.moveNotifiedWorktreeToTop = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.setMoveNotifiedWorktreeToTop(false))) {
      $0.moveNotifiedWorktreeToTop = false
    }
  }

  @Test func worktreeBranchNameLoadedPreservesCreatedAt() async {
    let createdAt = Date(timeIntervalSince1970: 1_737_303_600)
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle", createdAt: createdAt)
    let renamedWorktree = makeWorktree(id: "/tmp/wt", name: "falcon", createdAt: createdAt)
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.worktreeBranchNameLoaded(worktreeID: worktree.id, name: "falcon")) {
      var repository = $0.repositories[id: repository.id]!
      var worktrees = repository.worktrees
      worktrees[id: worktree.id] = renamedWorktree
      repository = Repository(
        id: repository.id,
        rootURL: repository.rootURL,
        name: repository.name,
        worktrees: worktrees
      )
      $0.repositories[id: repository.id] = repository
    }
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: worktree.id]?.name == "falcon")
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: worktree.id]?.createdAt == createdAt)
  }

  @Test func orderedWorktreeRowsAreGlobal() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a"),
        makeWorktree(id: "/tmp/repo-a/wt2", name: "wt2", repoRoot: "/tmp/repo-a"),
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt3", name: "wt3", repoRoot: "/tmp/repo-b")
      ]
    )
    let state = makeState(repositories: [repoA, repoB])

    expectNoDifference(
      state.orderedWorktreeRows().map(\.id),
      [
        "/tmp/repo-a/wt1",
        "/tmp/repo-a/wt2",
        "/tmp/repo-b/wt3",
      ]
    )
  }

  @Test func orderedWorktreeRowsRespectRepositoryOrderIDs() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a")
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt2", name: "wt2", repoRoot: "/tmp/repo-b")
      ]
    )
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryOrderIDs = [repoB.id, repoA.id]

    expectNoDifference(
      state.orderedWorktreeRows().map(\.id),
      [
        "/tmp/repo-b/wt2",
        "/tmp/repo-a/wt1",
      ]
    )
  }

  @Test func orderedWorktreeRowsCanFilterCollapsedRepositoriesForHotkeys() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a")
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt2", name: "wt2", repoRoot: "/tmp/repo-b")
      ]
    )
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryOrderIDs = [repoA.id, repoB.id]

    expectNoDifference(
      state.orderedWorktreeRows(includingRepositoryIDs: [repoB.id]).map(\.id),
      [
        "/tmp/repo-b/wt2"
      ]
    )
  }

  @Test func orderedRepositoryRootsAppendMissing() {
    let repoA = makeRepository(id: "/tmp/repo-a", worktrees: [])
    let repoB = makeRepository(id: "/tmp/repo-b", worktrees: [])
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryOrderIDs = [repoB.id]

    expectNoDifference(
      state.orderedRepositoryRoots().map { $0.path(percentEncoded: false) },
      [
        repoB.id,
        repoA.id,
      ]
    )
  }

  @Test func orderedUnpinnedWorktreesPutMissingFirst() {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let worktree3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: repoRoot)
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [worktree1, worktree2, worktree3]
    )
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [worktree2.id]

    expectNoDifference(
      state.orderedUnpinnedWorktreeIDs(in: repository),
      [
        worktree1.id,
        worktree3.id,
        worktree2.id,
      ]
    )
  }

  @Test func unpinnedWorktreeMoveUpdatesOrder() async {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let worktree3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: repoRoot)
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [worktree1, worktree2, worktree3]
    )
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [worktree1.id, worktree2.id, worktree3.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.unpinnedWorktreesMoved(repositoryID: repoRoot, IndexSet(integer: 0), 3))) {
      $0.worktreeOrderByRepository[repoRoot] = [worktree2.id, worktree3.id, worktree1.id]
    }
  }

  @Test func pinnedWorktreeMoveUpdatesSubsetOrder() async {
    let repoA = "/tmp/repo-a"
    let repoB = "/tmp/repo-b"
    let worktreeA1 = makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: repoA)
    let worktreeA2 = makeWorktree(id: "/tmp/repo-a/wt2", name: "wt2", repoRoot: repoA)
    let worktreeB1 = makeWorktree(id: "/tmp/repo-b/wt1", name: "wt1", repoRoot: repoB)
    let repositoryA = makeRepository(id: repoA, worktrees: [worktreeA1, worktreeA2])
    let repositoryB = makeRepository(id: repoB, worktrees: [worktreeB1])
    var state = makeState(repositories: [repositoryA, repositoryB])
    state.pinnedWorktreeIDs = [worktreeA1.id, worktreeB1.id, worktreeA2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.pinnedWorktreesMoved(repositoryID: repoA, IndexSet(integer: 1), 0))) {
      $0.pinnedWorktreeIDs = [worktreeA2.id, worktreeB1.id, worktreeA1.id]
    }
  }

  @Test func loadRepositoriesFailureKeepsPreviousState() async {
    let repository = makeRepository(id: "/tmp/repo", worktrees: [])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func worktreeOrderPreservedWhenRepositoryLoadFails() async {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.worktreeOrderByRepository = [
      repoRoot: [worktree1.id, worktree2.id]
    ]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
    expectNoDifference(
      store.state.worktreeOrderByRepository,
      [repoRoot: [worktree1.id, worktree2.id]]
    )
  }

  @Test func archivedWorktreesPreservedWhenRepositoryLoadFails() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    var initialState = makeState(repositories: [repository])
    initialState.archivedWorktrees = [ArchivedWorktree(id: worktree.id, archivedAt: fixedDate)]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
    #expect(store.state.archivedWorktrees == [ArchivedWorktree(id: worktree.id, archivedAt: fixedDate)])
  }

  @Test func repositoriesLoadedSkipsSelectionChangeWhenOnlyDisplayDataChanges() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let updatedWorktree = makeWorktree(id: "/tmp/repo/main", name: "main-updated", repoRoot: repoRoot)
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [updatedWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [updatedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.repositories = [updatedRepository]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func repositoriesLoadedUpdatesSelectedWorktreeDelegateOnSelectionChange() async {
    let repoRoot = "/tmp/repo"
    let selectedWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let remainingWorktree = makeWorktree(id: "/tmp/repo/next", name: "next", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [selectedWorktree, remainingWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [remainingWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(selectedWorktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [updatedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.repositories = [updatedRepository]
      $0.selection = nil
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func worktreeDeletedPrunesStateAndSendsDelegates() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let removedWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, removedWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(mainWorktree.id)
    initialState.deletingWorktreeIDs = [removedWorktree.id]
    initialState.pendingSetupScriptWorktreeIDs = [removedWorktree.id]
    initialState.pendingTerminalFocusWorktreeIDs = [removedWorktree.id]
    initialState.pendingWorktrees = [
      PendingWorktree(
        id: removedWorktree.id,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName)
      )
    ]
    initialState.pinnedWorktreeIDs = [removedWorktree.id]
    initialState.worktreeInfoByID = [
      removedWorktree.id: WorktreeInfoEntry(addedLines: 1, removedLines: 2, pullRequest: nil)
    ]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(
      .worktreeLifecycle(
        .worktreeDeleted(
          removedWorktree.id,
          repositoryID: repository.id,
          selectionWasRemoved: false,
          nextSelection: nil,
          forceDeleteBranchRequest: nil
        ))
    ) {
      $0.deletingWorktreeIDs = []
      $0.pendingSetupScriptWorktreeIDs = []
      $0.pendingTerminalFocusWorktreeIDs = []
      $0.pendingWorktrees = []
      $0.pinnedWorktreeIDs = []
      $0.worktreeInfoByID = [:]
      $0.repositories = [updatedRepository]
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
  }

  @Test func worktreeDeletedResetsSelectionWhenDriftedToDeletingWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let removedWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, removedWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(removedWorktree.id)
    initialState.deletingWorktreeIDs = [removedWorktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(
      .worktreeLifecycle(
        .worktreeDeleted(
          removedWorktree.id,
          repositoryID: repository.id,
          selectionWasRemoved: false,
          nextSelection: nil,
          forceDeleteBranchRequest: nil
        ))
    ) {
      $0.deletingWorktreeIDs = []
      $0.repositories = [updatedRepository]
      $0.selection = .worktree(mainWorktree.id)
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
  }

  @Test func createRandomWorktreeSucceededSendsRepositoriesChanged() async {
    let repoRoot = "/tmp/repo"
    let existingWorktree = makeWorktree(id: "/tmp/repo/wt-main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [existingWorktree])
    let newWorktree = makeWorktree(id: "/tmp/repo/wt-new", name: "new", repoRoot: repoRoot)
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [newWorktree, existingWorktree])
    let pendingID = "pending:\(UUID().uuidString)"
    var initialState = makeState(repositories: [repository])
    initialState.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches)
      )
    ]
    initialState.selection = .worktree(pendingID)
    initialState.sidebarSelectedWorktreeIDs = [existingWorktree.id, pendingID]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [newWorktree, existingWorktree] }
    }

    await store.send(
      .worktreeCreation(
        .createRandomWorktreeSucceeded(
          newWorktree,
          repositoryID: repository.id,
          pendingID: pendingID
        ))
    ) {
      $0.pendingSetupScriptWorktreeIDs.insert(newWorktree.id)
      $0.pendingTerminalFocusWorktreeIDs.insert(newWorktree.id)
      $0.pendingWorktrees = []
      $0.selection = .worktree(newWorktree.id)
      $0.sidebarSelectedWorktreeIDs = [newWorktree.id]
      $0.$prowlCreatedWorktreeIDs.withLock {
        $0.append(newWorktree.id)
      }
      $0.repositories = [updatedRepository]
    }

    await store.receive(\.reloadRepositories)
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.delegate.worktreeCreated)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
  }

  @Test func repositoryPullRequestsLoadedAutoArchivesWhenEnabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .archive
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
        ))
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.receive(\.worktreeLifecycle.archiveWorktreeConfirmed)
    await store.receive(\.worktreeLifecycle.archiveWorktreeApply) {
      $0.archivedWorktrees = [ArchivedWorktree(id: featureWorktree.id, archivedAt: fixedDate)]
    }
    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoArchiveForMainWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .archive
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: mainWorktree.name)

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [mainWorktree.id: mergedPullRequest]
        ))
    )
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedAutoDeletesWhenEnabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .delete
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
    }
    store.exhaustivity = .off
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
        ))
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.receive(\.worktreeLifecycle.deleteWorktreeConfirmed) {
      $0.deletingWorktreeIDs = [featureWorktree.id]
    }
  }

  @Test(.dependencies) func repositoryPullRequestsLoadedAutoDeleteOnlyDeletesProwlCreatedBranches() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let externalWorktree = makeWorktree(
      id: "\(repoRoot)/external",
      name: "external",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, externalWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .delete
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.deleteBranchOnDeleteWorktree = true
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, deleteBranch in
        #expect(worktree.id == externalWorktree.id)
        #expect(deleteBranch == false)
        return worktree.workingDirectory
      }
    }
    store.exhaustivity = .off
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: externalWorktree.name)

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [externalWorktree.id: mergedPullRequest]
        ))
    )
    await store.receive(\.worktreeLifecycle.deleteWorktreeConfirmed) {
      $0.deletingWorktreeIDs = [externalWorktree.id]
    }
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoDeleteForMainWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .delete
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: mainWorktree.name)

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [mainWorktree.id: mergedPullRequest]
        ))
    )
    await store.finish()
  }

  @Test func pullRequestActionMergeRefreshesImmediatelyWithoutSyntheticMergedState() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.mergedWorktreeAction = .archive
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let upstreamRemoteInfo = GithubRemoteInfo(host: "github.com", owner: "supabitapp", repo: "supacode")
    let mergedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.resolveRemoteInfo = { _ in upstreamRemoteInfo }
      $0.githubCLI.mergePullRequest = { _, _, number, _ in
        mergedNumbers.withValue { $0.append(number) }
      }
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .merge)))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Merging pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request merged")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(store.state.worktreeInfoByID[featureWorktree.id]?.pullRequest?.state == "OPEN")
    #expect(store.state.archivedWorktrees.isEmpty)
    #expect(mergedNumbers.value == [12])
    await store.finish()
  }

  @Test func pullRequestActionMergeUsesGlobalStrategyWhenRepositoryOverrideMissing() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let upstreamRemoteInfo = GithubRemoteInfo(host: "github.com", owner: "supabitapp", repo: "supacode")
    let mergedStrategies = LockIsolated<[PullRequestMergeStrategy]>([])
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.pullRequestMergeStrategy = .squash
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.pullRequestMergeStrategy = nil
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.resolveRemoteInfo = { _ in upstreamRemoteInfo }
      $0.githubCLI.mergePullRequest = { _, _, _, strategy in
        mergedStrategies.withValue { $0.append(strategy) }
      }
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .merge)))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Merging pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request merged")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(mergedStrategies.value == [.squash])
    await store.finish()
  }

  @Test func pullRequestActionMergeUsesResolvedRemoteInfo() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    let upstreamRemoteInfo = GithubRemoteInfo(host: "github.com", owner: "supabitapp", repo: "supacode")
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let mutationRemoteInfos = LockIsolated<[GithubRemoteInfo?]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.gitClient.remoteInfo = { root in
        #expect(root == URL(fileURLWithPath: repoRoot))
        return upstreamRemoteInfo
      }
      $0.githubCLI.resolveRemoteInfo = { _ in
        Issue.record("gh resolveRemoteInfo should not run when git remote resolves")
        return nil
      }
      $0.githubCLI.mergePullRequest = { root, remoteInfo, number, _ in
        #expect(root == featureWorktree.workingDirectory)
        #expect(number == 12)
        mutationRemoteInfos.withValue { $0.append(remoteInfo) }
      }
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .merge)))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Merging pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request merged")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(mutationRemoteInfos.value == [upstreamRemoteInfo])
    await store.finish()
  }

  @Test func pullRequestActionMergeRequiresResolvedRemoteInfo() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let mergeAttempts = LockIsolated(0)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.resolveRemoteInfo = { _ in nil }
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.mergePullRequest = { _, _, _, _ in
        mergeAttempts.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .merge)))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Merging pull request…")
    }
    await store.receive(\.dismissToast) {
      $0.statusToast = nil
    }
    await store.receive(\.presentAlert) {
      $0.alert = AlertState<RepositoriesFeature.Alert> {
        TextState("GitHub repository not resolved")
      } actions: {
        ButtonState(role: .cancel) {
          TextState("OK")
        }
      } message: {
        TextState(
          "Prowl could not determine which GitHub repository owns this pull request. "
            + "Check the repository remote and try again."
        )
      }
    }
    #expect(mergeAttempts.value == 0)
    await store.finish()
  }

  @Test func pullRequestActionCloseRefreshesImmediately() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let upstreamRemoteInfo = GithubRemoteInfo(host: "github.com", owner: "supabitapp", repo: "supacode")
    let closedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.resolveRemoteInfo = { _ in upstreamRemoteInfo }
      $0.githubCLI.closePullRequest = { _, _, number in
        closedNumbers.withValue { $0.append(number) }
      }
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .close)))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Closing pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request closed")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(closedNumbers.value == [12])
    await store.finish()
  }

  @Test func pullRequestActionOpenOnCodeHostOpensPullRequestURLWhenAvailable() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let pullRequest = makePullRequest(
      state: "OPEN",
      headRefName: featureWorktree.name,
      number: 12,
      url: "https://github.com/octo/repo/pull/12"
    )
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: pullRequest
    )
    let openedURLs = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in
        Issue.record("repositoryWebURL should not be requested when a pull request URL exists")
        return nil
      }
      $0.openURLClient.open = { url in
        openedURLs.withValue { $0.append(url) }
      }
    }

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .openOnCodeHost)))
    await store.finish()

    #expect(openedURLs.value == [URL(string: "https://github.com/octo/repo/pull/12")!])
  }

  @Test func pullRequestActionOpenOnCodeHostFallsBackToRepositoryURL() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let repositoryURL = URL(string: "https://gitlab.com/group/subgroup/repo")!
    let openedURLs = LockIsolated<[URL]>([])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in
        repositoryURL
      }
      $0.openURLClient.open = { url in
        openedURLs.withValue { $0.append(url) }
      }
    }

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .openOnCodeHost)))
    await store.finish()

    #expect(openedURLs.value == [repositoryURL])
  }

  @Test func pullRequestActionOpenOnCodeHostFallsBackWhenPullRequestURLIsInvalid() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let pullRequest = makePullRequest(
      state: "OPEN",
      headRefName: featureWorktree.name,
      number: 12,
      url: "/octo/repo/pull/12"
    )
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: pullRequest
    )
    let repositoryURL = URL(string: "https://git.example.com/scm/repo")!
    let openedURLs = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in
        repositoryURL
      }
      $0.openURLClient.open = { url in
        openedURLs.withValue { $0.append(url) }
      }
    }

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .openOnCodeHost)))
    await store.finish()

    #expect(openedURLs.value == [repositoryURL])
  }

  @Test func pullRequestActionOpenOnCodeHostShowsAlertWhenRepositoryURLUnavailable() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in nil }
    }

    await store.send(.githubIntegration(.pullRequestAction(featureWorktree.id, .openOnCodeHost)))
    await store.receive(\.presentAlert) {
      $0.alert = AlertState<RepositoriesFeature.Alert> {
        TextState("Repository URL not available")
      } actions: {
        ButtonState(role: .cancel) {
          TextState("OK")
        }
      } message: {
        TextState("Prowl could not determine a code host URL for this repository.")
      }
    }
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshMarksInFlightThenCompletes() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshQueuesWhileAvailabilityUnknown() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { false }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("remoteInfo should not be requested when GitHub integration is unavailable")
        return nil
      }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when GitHub integration is unavailable")
        return [:]
      }
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    }
    await store.receive(\.githubIntegration.refreshGithubIntegrationAvailability) {
      $0.githubIntegrationAvailability = .checking
    }
    await store.receive(\.githubIntegration.githubIntegrationAvailabilityUpdated) {
      $0.githubIntegrationAvailability = .unavailable
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.send(.githubIntegration(.setGithubIntegrationEnabled(false))) {
      $0.githubIntegrationAvailability = .disabled
      $0.pendingPullRequestRefreshByRepositoryID = [:]
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshQueuesWhileAvailabilityUnavailable() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .unavailable
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityRecoveryReplaysPendingRefreshes() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .unavailable
    initialState.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      worktreeIDs: [mainWorktree.id, featureWorktree.id]
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(.githubIntegration(.githubIntegrationAvailabilityUpdated(true))) {
      $0.githubIntegrationAvailability = .available
      $0.pendingPullRequestRefreshByRepositoryID = [:]
    }
    await store.receive(\.worktreeInfoEvent)
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityUnavailablePromotesQueuedRefreshesToPending() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    initialState.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    initialState.queuedPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      worktreeIDs: [mainWorktree.id, featureWorktree.id]
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.githubIntegration(.githubIntegrationAvailabilityUpdated(false))) {
      $0.githubIntegrationAvailability = .unavailable
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.send(.githubIntegration(.setGithubIntegrationEnabled(false))) {
      $0.githubIntegrationAvailability = .disabled
      $0.pendingPullRequestRefreshByRepositoryID = [:]
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityUpdatedWhileDisabledIsIgnored() async {
    var state = makeState(repositories: [])
    state.githubIntegrationAvailability = .disabled
    state.pendingPullRequestRefreshByRepositoryID["repo"] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      worktreeIDs: []
    )
    let expectedState = state
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.githubIntegration(.githubIntegrationAvailabilityUpdated(false)))
    await store.send(.githubIntegration(.githubIntegrationAvailabilityUpdated(true)))
    #expect(store.state == expectedState)
    await store.finish()
  }

  @Test func repositoryPullRequestRefreshCompletedReplaysQueuedRefresh() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .available
    state.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    state.queuedPullRequestRefreshByRepositoryID[repository.id] =
      RepositoriesFeature
      .PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(
      .githubIntegration(.repositoryPullRequestRefreshCompleted(repository.id))
    ) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.queuedPullRequestRefreshByRepositoryID = [:]
    }
    await store.receive(\.worktreeInfoEvent)
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedSkipsNoopPayload() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let pullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name)
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: pullRequest
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [featureWorktree.id: pullRequest]
        ))
    )
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedClearsStalePullRequestWhenNil() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(state: "OPEN", headRefName: featureWorktree.name)
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let pullRequestsByWorktreeID: [Worktree.ID: GithubPullRequest?] = [featureWorktree.id: nil]

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: pullRequestsByWorktreeID
        ))
    ) {
      $0.worktreeInfoByID.removeValue(forKey: featureWorktree.id)
    }
  }

  @Test func repositoryPullRequestsLoadedClearsMergedPullRequestForMainWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: mainWorktree.name)
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[mainWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: mergedPullRequest
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [mainWorktree.id: mergedPullRequest]
        ))
    ) {
      $0.worktreeInfoByID.removeValue(forKey: mainWorktree.id)
    }
  }

  @Test func unarchiveWorktreeNoopsWhenNotArchived() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.worktreeLifecycle(.unarchiveWorktree(worktree.id)))
    expectNoDifference(store.state.archivedWorktrees, [])
  }

  // MARK: - Auto-delete Archived Worktrees

  @Test func autoDeleteExpiredArchivedWorktreesDeletesExpired() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let expiredWorktree = makeWorktree(id: "/tmp/repo/expired", name: "expired", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, expiredWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let archivedAt = fixedDate.addingTimeInterval(-2 * 86_400)  // 2 days ago
    var state = makeState(repositories: [repository])
    state.archivedWorktrees = [ArchivedWorktree(id: expiredWorktree.id, archivedAt: archivedAt)]
    state.archivedAutoDeletePeriod = .oneDay
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
    }
    store.exhaustivity = .off

    await store.send(.autoDeleteExpiredArchivedWorktrees)
    await store.receive(\.worktreeLifecycle.deleteWorktreeConfirmed) {
      $0.deletingWorktreeIDs = [expiredWorktree.id]
    }
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
  }

  @Test(.dependencies) func autoDeleteExpiredArchivedWorktreesOnlyDeletesProwlCreatedBranches() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let expiredWorktree = makeWorktree(id: "/tmp/repo/expired", name: "expired", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, expiredWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let archivedAt = fixedDate.addingTimeInterval(-2 * 86_400)
    var state = makeState(repositories: [repository])
    state.archivedWorktrees = [ArchivedWorktree(id: expiredWorktree.id, archivedAt: archivedAt)]
    state.archivedAutoDeletePeriod = .oneDay
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.deleteBranchOnDeleteWorktree = true
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      $0.gitClient.removeWorktree = { worktree, deleteBranch in
        #expect(worktree.id == expiredWorktree.id)
        #expect(deleteBranch == false)
        return worktree.workingDirectory
      }
    }
    store.exhaustivity = .off

    await store.send(.autoDeleteExpiredArchivedWorktrees)
    await store.receive(\.worktreeLifecycle.deleteWorktreeConfirmed) {
      $0.deletingWorktreeIDs = [expiredWorktree.id]
    }
  }

  @Test func autoDeleteKeepsUnexpiredArchivedWorktrees() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let recentWorktree = makeWorktree(id: "/tmp/repo/recent", name: "recent", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, recentWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let archivedAt = fixedDate.addingTimeInterval(-1 * 86_400)  // 1 day ago
    var state = makeState(repositories: [repository])
    state.archivedWorktrees = [ArchivedWorktree(id: recentWorktree.id, archivedAt: archivedAt)]
    state.archivedAutoDeletePeriod = .sevenDays
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
    }

    await store.send(.autoDeleteExpiredArchivedWorktrees)
    // No effects — worktree is not expired yet
  }

  @Test func autoDeleteNilPeriodDoesNothing() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, worktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    var state = makeState(repositories: [repository])
    state.archivedWorktrees = [
      ArchivedWorktree(id: worktree.id, archivedAt: .distantPast)
    ]
    state.archivedAutoDeletePeriod = nil
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
    }

    await store.send(.autoDeleteExpiredArchivedWorktrees)
    // No effects — auto-delete is disabled
  }

  @Test func autoDeleteSkipsMainWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    var state = makeState(repositories: [repository])
    state.archivedWorktrees = [
      ArchivedWorktree(id: mainWorktree.id, archivedAt: .distantPast)
    ]
    state.archivedAutoDeletePeriod = .oneDay
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
    }

    await store.send(.autoDeleteExpiredArchivedWorktrees)
    // No effects — main worktree must not be deleted
  }

  @Test func autoDeleteMultipleExpiredWorktreesConcurrently() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let expired1 = makeWorktree(id: "/tmp/repo/expired1", name: "expired1", repoRoot: repoRoot)
    let expired2 = makeWorktree(id: "/tmp/repo/expired2", name: "expired2", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, expired1, expired2])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let archivedAt = fixedDate.addingTimeInterval(-2 * 86_400)
    var state = makeState(repositories: [repository])
    state.archivedWorktrees = [
      ArchivedWorktree(id: expired1.id, archivedAt: archivedAt),
      ArchivedWorktree(id: expired2.id, archivedAt: archivedAt),
    ]
    state.archivedAutoDeletePeriod = .oneDay
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.autoDeleteExpiredArchivedWorktrees)
    // Both deleteWorktreeConfirmed should fire
    await store.receive(\.worktreeLifecycle.deleteWorktreeConfirmed)
    await store.receive(\.worktreeLifecycle.deleteWorktreeConfirmed)
    // Both worktreeDeleted should complete without crash
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
    // State should be consistent: both worktrees removed from archives
    #expect(store.state.archivedWorktrees.isEmpty)
    #expect(store.state.deletingWorktreeIDs.isEmpty)
  }

  // MARK: - Select Next/Previous Worktree

  @Test func selectNextWorktreeWrapsForward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt2.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.openedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = [wt2.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeWrapsBackward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.openedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeWithNoSelectionSelectsFirst() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.openedWorktreeIDs = [wt1.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeCollapsesSidebarSelectionToSingleWorktree() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let wt3 = makeWorktree(id: "/tmp/wt3", name: "gamma")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = [wt1.id, wt3.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.openedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeWithNoSelectionSelectsLast() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.openedWorktreeIDs = [wt2.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeWithEmptyRowsIsNoOp() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
  }

  @Test func selectNextWorktreeSingleWorktreeReturnsSame() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "solo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(worktree.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.openedWorktreeIDs = [worktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeSkipsCollapsedRepository() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt1.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo2.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt3.id)
      $0.sidebarSelectedWorktreeIDs = [wt3.id]
      $0.openedWorktreeIDs = [wt3.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt3.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeSkipsCollapsedRepository() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt3.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo2.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.openedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = [wt3.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeAllCollapsedIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    var state = makeState(repositories: [repo1])
    state.selection = .worktree(wt1.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo1.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
  }

  @Test func selectPreviousWorktreeAllCollapsedIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    var state = makeState(repositories: [repo1])
    state.selection = .worktree(wt1.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo1.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
  }

  @Test func selectNextWorktreeWrapsAroundSkippingCollapsedRepo() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt3.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo2.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.openedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = [wt3.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  // MARK: - Worktree History Back/Forward

  @Test func selectingDifferentWorktreePushesPreviousOntoBackStack() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.worktreeHistoryForwardStack = [wt2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(wt2.id)) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.openedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeHistoryForwardStack = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func worktreeHistoryBackPopsPreviousAndPushesCurrentToForward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt2.id)
    state.worktreeHistoryBackStack = [wt1.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryBack) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.openedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = []
      $0.worktreeHistoryForwardStack = [wt2.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func worktreeHistoryForwardPopsNextAndPushesCurrentToBack() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.worktreeHistoryForwardStack = [wt2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryForward) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.openedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeHistoryForwardStack = []
      $0.pendingTerminalFocusWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func worktreeHistoryBackSkipsStaleEntriesUntilValidIDFound() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt3 = makeWorktree(id: "/tmp/wt3", name: "gamma")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt3])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt3.id)
    state.worktreeHistoryBackStack = [wt1.id, "/tmp/wt2-deleted"]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryBack) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.openedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = []
      $0.worktreeHistoryForwardStack = [wt3.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func canNavigateBackwardFiltersStaleAndSelfReferentialEntries() {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)

    state.worktreeHistoryBackStack = ["/tmp/gone-a", "/tmp/gone-b"]
    #expect(!state.canNavigateWorktreeHistoryBackward)

    state.worktreeHistoryBackStack = [wt1.id]
    #expect(!state.canNavigateWorktreeHistoryBackward)

    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    state.repositories = [makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])]
    state.worktreeHistoryBackStack = [wt2.id, "/tmp/gone"]
    #expect(state.canNavigateWorktreeHistoryBackward)
  }

  @Test func canNavigateWorktreeHistoryDisabledWhenSelectionIsNotAWorktree() {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.worktreeHistoryBackStack = [wt1.id]
    state.worktreeHistoryForwardStack = [wt2.id]

    state.selection = .repository(repository.id)
    #expect(!state.canNavigateWorktreeHistoryBackward)
    #expect(!state.canNavigateWorktreeHistoryForward)

    state.selection = .archivedWorktrees
    #expect(!state.canNavigateWorktreeHistoryBackward)
    #expect(!state.canNavigateWorktreeHistoryForward)

    state.selection = nil
    #expect(!state.canNavigateWorktreeHistoryBackward)
    #expect(!state.canNavigateWorktreeHistoryForward)

    state.selection = .worktree(wt1.id)
    #expect(state.canNavigateWorktreeHistoryForward)
  }

  @Test func selectRepositoryPushesWorktreeOntoBackStackAndClearsForwardStack() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = [wt1.id]
    state.worktreeHistoryForwardStack = [wt2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectRepository(repository.id)) {
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeHistoryForwardStack = []
      $0.selection = .repository(repository.id)
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectArchivedWorktreesPushesWorktreeOntoBackStackAndClearsForwardStack() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = [wt1.id]
    state.worktreeHistoryForwardStack = [wt2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectArchivedWorktrees) {
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeHistoryForwardStack = []
      $0.selection = .archivedWorktrees
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func reselectingWorktreeAfterRepositoryDoesNotResurrectStaleForwardEntry() async {
    // Reproduces the scenario from the Copilot review: after the user
    // navigates Back and then leaves the worktree view through a
    // non-worktree selection, the stale forward target must not survive
    // the next worktree selection.
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let wt3 = makeWorktree(id: "/tmp/wt3", name: "gamma")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var state = makeState(repositories: [repository])
    // User landed on wt2 via Back, leaving wt3 in the forward stack.
    state.selection = .worktree(wt2.id)
    state.worktreeHistoryBackStack = [wt1.id]
    state.worktreeHistoryForwardStack = [wt3.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Detour through repository view.
    await store.send(.selectRepository(repository.id)) {
      $0.worktreeHistoryBackStack = [wt1.id, wt2.id]
      $0.worktreeHistoryForwardStack = []
      $0.selection = .repository(repository.id)
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)

    // Reselect a worktree — no leftover forward target should remain.
    await store.send(.selectWorktree(wt2.id)) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.openedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)

    #expect(!store.state.canNavigateWorktreeHistoryForward)
    #expect(store.state.canNavigateWorktreeHistoryBackward)
  }

  private func makeWorktree(
    id: String,
    name: String,
    repoRoot: String = "/tmp/repo",
    createdAt: Date? = nil
  ) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      createdAt: createdAt
    )
  }

  private func makePullRequest(
    state: String,
    headRefName: String? = nil,
    number: Int = 1,
    url: String? = nil
  ) -> GithubPullRequest {
    GithubPullRequest(
      number: number,
      title: "PR",
      state: state,
      additions: 0,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: url ?? "https://example.com/pull/\(number)",
      headRefName: headRefName,
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
  }

  private func makeRepository(
    id: String,
    name: String = "repo",
    kind: Repository.Kind = .git,
    worktrees: [Worktree],
    workspace: ProjectWorkspace? = nil
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      kind: kind,
      worktrees: IdentifiedArray(uniqueElements: worktrees),
      workspace: workspace
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.rootURL)
    return state
  }

  @Test func loadPersistedRepositoriesStartsFetchesConcurrentlyAndPreservesRootOrder() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: "\(repoRootA)/main", name: "main", repoRoot: repoRootA)
    let worktreeB = makeWorktree(id: "\(repoRootB)/main", name: "main", repoRoot: repoRootB)
    let repoA = makeRepository(
      id: repoRootA,
      name: URL(fileURLWithPath: repoRootA).lastPathComponent,
      worktrees: [worktreeA]
    )
    let repoB = makeRepository(
      id: repoRootB,
      name: URL(fileURLWithPath: repoRootB).lastPathComponent,
      worktrees: [worktreeB]
    )
    let gate = AsyncGate()
    let startedRoots = LockIsolated<Set<String>>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRootA, repoRootB] }
      $0.gitClient.worktrees = { root in
        let path = root.path(percentEncoded: false)
        _ = startedRoots.withValue { $0.insert(path) }
        if path == repoRootA {
          await gate.wait()
          return [worktreeA]
        }
        if path == repoRootB {
          return [worktreeB]
        }
        Issue.record("Unexpected root: \(path)")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)

    var secondFetchStarted = false
    for _ in 0..<100 {
      if startedRoots.value.contains(repoRootB) {
        secondFetchStarted = true
        break
      }
      await Task.yield()
    }
    #expect(secondFetchStarted)

    await gate.resume()

    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func loadPersistedRepositoriesRestoresLastFocusedSelectionAfterFullLoad() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: "\(repoRootA)/main", name: "main", repoRoot: repoRootA)
    let worktreeB = makeWorktree(id: "\(repoRootB)/main", name: "main", repoRoot: repoRootB)
    let repoA = makeRepository(
      id: repoRootA,
      name: URL(fileURLWithPath: repoRootA).lastPathComponent,
      worktrees: [worktreeA]
    )
    let repoB = makeRepository(
      id: repoRootB,
      name: URL(fileURLWithPath: repoRootB).lastPathComponent,
      worktrees: [worktreeB]
    )

    var state = RepositoriesFeature.State()
    state.lastFocusedWorktreeID = worktreeB.id
    state.shouldRestoreLastFocusedWorktree = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRootA, repoRootB] }
      $0.gitClient.worktrees = { root in
        switch root.path(percentEncoded: false) {
        case repoRootA:
          return [worktreeA]
        case repoRootB:
          return [worktreeB]
        default:
          Issue.record("Unexpected root: \(root.path(percentEncoded: false))")
          return []
        }
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.selection = .worktree(worktreeB.id)
      $0.shouldRestoreLastFocusedWorktree = false
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test func cliOpenLaunchModeSkipsLastFocusedRestoreSelection() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: "\(repoRootA)/main", name: "main", repoRoot: repoRootA)
    let worktreeB = makeWorktree(id: "\(repoRootB)/main", name: "main", repoRoot: repoRootB)
    let repoA = makeRepository(
      id: repoRootA,
      name: URL(fileURLWithPath: repoRootA).lastPathComponent,
      worktrees: [worktreeA]
    )
    let repoB = makeRepository(
      id: repoRootB,
      name: URL(fileURLWithPath: repoRootB).lastPathComponent,
      worktrees: [worktreeB]
    )

    var state = RepositoriesFeature.State()
    state.launchRestoreMode = .cliOpenPath(repoRootA)

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadLastFocusedWorktreeID = { worktreeB.id }
      $0.repositoryPersistence.loadRepositorySnapshot = { [repoA, repoB] }
      $0.repositoryPersistence.loadRoots = { [repoRootA, repoRootB] }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.worktrees = { root in
        switch root.path(percentEncoded: false) {
        case repoRootA:
          return [worktreeA]
        case repoRootB:
          return [worktreeB]
        default:
          return []
        }
      }
    }

    await store.send(.task) {
      $0.snapshotPersistencePhase = .restoring
    }
    await store.receive(\.pinnedWorktreeIDsLoaded)
    await store.receive(\.archivedWorktreesLoaded)
    await store.receive(\.repositoryOrderIDsLoaded)
    await store.receive(\.worktreeOrderByRepositoryLoaded)
    await store.receive(\.lastFocusedWorktreeIDLoaded) {
      $0.lastFocusedWorktreeID = worktreeB.id
      $0.shouldRestoreLastFocusedWorktree = false
    }
    await store.receive(\.repositorySnapshotLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.selection = nil
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.snapshotPersistencePhase = .active
      $0.selection = nil
      $0.shouldRestoreLastFocusedWorktree = false
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  private actor AsyncGate {
    var continuation: CheckedContinuation<Void, Never>?
    var isOpen = false

    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }

    func resume() {
      if let continuation {
        continuation.resume()
        self.continuation = nil
      } else {
        isOpen = true
      }
    }
  }
}
