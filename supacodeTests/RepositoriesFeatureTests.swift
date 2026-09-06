import Clocks
import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import ProwlCLIShared
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

  @Test func selectNextShelfBookRoutesToRightNavigationInCanvas() async {
    await assertCanvasNavigationActionRoutesToCommand(
      action: .selectNextShelfBook,
      command: .navigate(.moveRight)
    )
  }

  @Test func selectPreviousShelfBookRoutesToLeftNavigationInCanvas() async {
    await assertCanvasNavigationActionRoutesToCommand(
      action: .selectPreviousShelfBook,
      command: .navigate(.moveLeft)
    )
  }

  @Test func selectNextWorktreeRoutesToDownNavigationInCanvas() async {
    await assertCanvasNavigationActionRoutesToCommand(
      action: .selectNextWorktree,
      command: .navigate(.moveDown)
    )
  }

  @Test func selectPreviousWorktreeRoutesToUpNavigationInCanvas() async {
    await assertCanvasNavigationActionRoutesToCommand(
      action: .selectPreviousWorktree,
      command: .navigate(.moveUp)
    )
  }

  private func assertCanvasNavigationActionRoutesToCommand(
    action: RepositoriesFeature.Action,
    command: CanvasCommandRequest.Command
  ) async {
    var initialState = RepositoriesFeature.State()
    initialState.selection = .canvas
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(action)
    await store.receive(\.requestCanvasCommand) {
      $0.nextCanvasCommandRequestID = 1
      $0.pendingCanvasCommandRequest = CanvasCommandRequest(id: 1, command: command)
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
      changes: GitLineChanges(added: 12, removed: 4),
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
      changes: GitLineChanges(added: 0, removed: 0),
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
      changes: GitLineChanges(added: 12, removed: 4),
      state: &state
    )

    #expect(changed == true)
    #expect(
      state.worktreeInfoByID[worktree.id]
        == WorktreeInfoEntry(addedLines: 12, removedLines: 4, pullRequest: nil)
    )
  }

  @Test func updateWorktreeLineChangesKeepsAnIncompleteZeroCountVisible() {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])

    let changed = updateWorktreeLineChanges(
      worktreeID: worktree.id,
      changes: GitLineChanges(added: 0, removed: 0, skippedUntrackedFileCount: 1),
      state: &state
    )

    #expect(changed == true)
    #expect(
      state.worktreeInfoByID[worktree.id]
        == WorktreeInfoEntry(
          addedLines: 0,
          removedLines: 0,
          pullRequest: nil,
          skippedUntrackedFileCount: 1
        )
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
      $0.gitClient.lineChanges = { _ in GitLineChanges(added: 12, removed: 4) }
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
      $0.gitClient.lineChanges = { _ in GitLineChanges(added: 0, removed: 0) }
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
      $0.gitClient.lineChanges = { _ in GitLineChanges(added: 0, removed: 0) }
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
      $0.gitClient.lineChanges = { _ in GitLineChanges(added: 15, removed: 9) }
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

  @Test func filesChangedKeepsAnIncompleteLineCountVisible() async {
    let worktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.lineChanges = { _ in
        GitLineChanges(added: 0, removed: 0, skippedUntrackedFileCount: 1)
      }
    }

    await store.send(.worktreeInfoEvent(.filesChanged(worktreeID: worktree.id)))
    await store.receive(\.worktreeLineChangesLoaded) {
      $0.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
        addedLines: 0,
        removedLines: 0,
        pullRequest: nil,
        skippedUntrackedFileCount: 1
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
        return GitLineChanges(added: 15, removed: 9)
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

    await store.send(
      .worktreeInfoEvent(.repositoryWorktreesChanged(repositoryRootURL: repository.rootURL)))
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
    await store.finish()
  }

  @Test func plainRepositoryBecameGitRepositoryReloadsRepositories() async {
    let repoRoot = "/tmp/new-project"
    let rootURL = URL(fileURLWithPath: repoRoot)
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let plainRepository = makeRepository(
      id: repoRoot, name: "new-project", kind: .plain, worktrees: [])
    let store = TestStore(initialState: makeState(repositories: [plainRepository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: repoRoot, kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { _ in rootURL }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
      $0.gitClient.pruneWorktrees = { _ in }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }

    await store.send(
      .worktreeInfoEvent(.plainRepositoryBecameGitRepository(rootURL)))
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories[id: plainRepository.id] = makeRepository(
        id: repoRoot,
        name: "new-project",
        kind: .git,
        worktrees: [mainWorktree]
      )
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func repositoryRemoteConfigurationChangedRefreshesPullRequestsAndCodeHost() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .unavailable
    initialState.codeHostByRepositoryID[repository.id] = .github
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in nil }
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryRemoteConfigurationChanged(repositoryRootURL: repository.rootURL)
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: repository.rootURL,
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    }
    await store.receive(\.codeHostsDetected) {
      $0.codeHostByRepositoryID[repository.id] = .unknown
    }
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
    let loadedRootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
    let workspace = try #require(ProjectWorkspace.load(from: loadedRootURL))
    let repository = makeRepository(
      id: loadedRootURL.path(percentEncoded: false),
      name: "Multi Repo Workspace",
      kind: .plain,
      worktrees: [],
      workspace: workspace
    )

    let childID = repository.rootURL.appending(path: "app").standardizedFileURL.path(
      percentEncoded: false)
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: rootPath, kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { url in
        Issue.record(
          "workspace should load as plain without git probing: \(url.path(percentEncoded: false))")
        return url
      }
      $0.gitClient.worktrees = { url in
        Issue.record("workspace should not load git worktrees: \(url.path(percentEncoded: false))")
        return []
      }
      // The workspace's child repository is refreshed via the child pipeline
      // (live branch + diff), distinct from the worktree probing above.
      $0.gitClient.branchName = { _ in "main" }
      $0.gitClient.lineChanges = { _ in nil }
      $0.gitClient.remoteInfo = { _ in nil }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repository]
      $0.repositoryRoots = [URL(fileURLWithPath: rootPath)]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.workspaceChildrenInfoLoaded) {
      $0.workspaceChildBranchByID = [childID: "main"]
    }
    await store.finish()
  }

  @Test func workspaceCreationPromptOffersOpenedRepositoriesWithoutAddingThem() async {
    let repository = makeRepository(id: "/tmp/repo-a", name: "Repo A", worktrees: [])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let title = "Workspace"
    let requestedRootPath = defaultWorkspaceBaseRootPath(for: title)
    let resolvedRootPath = expectedDefaultWorkspaceRootPath(for: title)
    await store.send(.workspaceCreation(.promptRequested)) {
      $0.workspaceCreationPrompt = WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: title,
        rootPath: requestedRootPath,
        openedRepositoryCandidates: [
          ProjectWorkspaceCreationRepository(
            id: "/tmp/repo-a",
            name: "Repo A",
            rootURL: URL(fileURLWithPath: "/tmp/repo-a")
          )
        ]
      )
    }
    if resolvedRootPath == requestedRootPath {
      await store.receive(\.workspaceCreation.defaultRootPathResolved)
    } else {
      await store.receive(\.workspaceCreation.defaultRootPathResolved) {
        $0.workspaceCreationPrompt?.rootPath = resolvedRootPath
      }
    }
  }

  @Test func workspaceCreationPromptAddsOpenedRepositoryOnRequest() async {
    let repoRootA = "/tmp/repo-a"
    let candidate = ProjectWorkspaceCreationRepository(
      id: repoRootA,
      name: "Repo A",
      rootURL: URL(fileURLWithPath: repoRootA)
    )
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: "Workspace",
        rootPath: "/tmp/workspace",
        openedRepositoryCandidates: [candidate]
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.addOpenedRepository(repoRootA)) {
      $0.repositories = [candidate]
    }
    await store.receive(.delegate(.baseRefSourceChanged(repoRootA)))
  }

  @Test func resetLocalBranchChoiceTogglesAndClearsOnRefChange() async {
    let repoID = "/tmp/repo-a"
    let repo = ProjectWorkspaceCreationRepository(
      id: repoID,
      name: "Repo A",
      sourceKind: .bareRepository,
      sourceLocation: "/tmp/repo-a.git",
      checkoutMode: .useExistingRef,
      baseRef: "origin/feature",
      baseRefOptions: [
        GitBranchRefOption(ref: "origin/feature", kind: .remoteTracking),
        GitBranchRefOption(ref: "feature", kind: .local),
      ]
    )
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [repo],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.repositoryResetLocalBranchChanged(repoID, true)) {
      $0.repositories[id: repoID]?.resetLocalBranchToRemote = true
    }
    // Selecting a different ref invalidates the keep/reset choice.
    await store.send(.repositoryBaseRefChanged(repoID, "feature")) {
      $0.repositories[id: repoID]?.baseRef = "feature"
      $0.repositories[id: repoID]?.resetLocalBranchToRemote = false
    }
  }

  @Test func workspaceCreationPromptIgnoresDuplicateOpenedRepository() async {
    let repoRootA = "/tmp/repo-a"
    let candidate = ProjectWorkspaceCreationRepository(
      id: repoRootA,
      name: "Repo A",
      rootURL: URL(fileURLWithPath: repoRootA)
    )
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [candidate],
        title: "Workspace",
        rootPath: "/tmp/workspace",
        openedRepositoryCandidates: [candidate]
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.addOpenedRepository(repoRootA))
  }

  @Test func workspaceCreationPromptOffersLoadedRepositories() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: repoRootA, name: "main", repoRoot: repoRootA)
    let repoA = makeRepository(id: repoRootA, name: "Repo A", worktrees: [worktreeA])
    let repoB = makeRepository(id: repoRootB, name: "Repo B", worktrees: [])
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryCustomTitles[repoB.id] = "API"
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let title = "Workspace"
    let requestedRootPath = defaultWorkspaceBaseRootPath(for: title)
    let resolvedRootPath = expectedDefaultWorkspaceRootPath(for: title)
    await store.send(.workspaceCreation(.promptRequested)) {
      $0.workspaceCreationPrompt = WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: title,
        rootPath: requestedRootPath,
        openedRepositoryCandidates: [
          ProjectWorkspaceCreationRepository(
            id: repoRootA,
            name: "Repo A",
            rootURL: URL(fileURLWithPath: repoRootA)
          ),
          ProjectWorkspaceCreationRepository(
            id: repoRootB,
            name: "API",
            rootURL: URL(fileURLWithPath: repoRootB)
          ),
        ]
      )
    }
    if resolvedRootPath == requestedRootPath {
      await store.receive(\.workspaceCreation.defaultRootPathResolved)
    } else {
      await store.receive(\.workspaceCreation.defaultRootPathResolved) {
        $0.workspaceCreationPrompt?.rootPath = resolvedRootPath
      }
    }
  }

  @Test func workspaceCreationPromptLoadsBaseRefsForAddedOpenedRepository() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: repoRootA, name: "main", repoRoot: repoRootA)
    let repoA = makeRepository(id: repoRootA, name: "Repo A", worktrees: [worktreeA])
    let repoB = makeRepository(id: repoRootB, name: "Repo B", worktrees: [])
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryCustomTitles[repoB.id] = "API"
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repoRoot = { url in url }
      $0.gitClient.automaticWorktreeBaseRef = { url in
        url.path(percentEncoded: false) == repoRootA ? "main" : "master"
      }
      $0.gitClient.branchRefOptions = { url in
        url.path(percentEncoded: false) == repoRootA
          ? [
            GitBranchRefOption(ref: "main", kind: .local),
            GitBranchRefOption(ref: "origin/main", kind: .remoteTracking),
          ]
          : [
            GitBranchRefOption(ref: "master", kind: .local),
            GitBranchRefOption(ref: "origin/master", kind: .remoteTracking),
          ]
      }
    }

    let title = "Workspace"
    let requestedRootPath = defaultWorkspaceBaseRootPath(for: title)
    let resolvedRootPath = expectedDefaultWorkspaceRootPath(for: title)
    await store.send(.workspaceCreation(.promptRequested)) {
      $0.workspaceCreationPrompt = WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: title,
        rootPath: requestedRootPath,
        openedRepositoryCandidates: [
          ProjectWorkspaceCreationRepository(
            id: repoRootA,
            name: "Repo A",
            rootURL: URL(fileURLWithPath: repoRootA)
          ),
          ProjectWorkspaceCreationRepository(
            id: repoRootB,
            name: "API",
            rootURL: URL(fileURLWithPath: repoRootB)
          ),
        ]
      )
    }
    if resolvedRootPath == requestedRootPath {
      await store.receive(\.workspaceCreation.defaultRootPathResolved)
    } else {
      await store.receive(\.workspaceCreation.defaultRootPathResolved) {
        $0.workspaceCreationPrompt?.rootPath = resolvedRootPath
      }
    }
    await store.send(.workspaceCreationPrompt(.presented(.addOpenedRepository(repoRootA)))) {
      $0.workspaceCreationPrompt?.repositories.append(
        ProjectWorkspaceCreationRepository(
          id: repoRootA,
          name: "Repo A",
          rootURL: URL(fileURLWithPath: repoRootA)
        )
      )
    }
    await store.receive(\.workspaceCreationPrompt.presented.delegate.baseRefSourceChanged)
    await store.receive(\.workspaceCreation.refreshBaseRefs)
    await store.receive(\.workspaceCreation.baseRefsLoaded) {
      $0.workspaceCreationPrompt?.repositories[id: repoRootA]?.baseRef = "main"
      $0.workspaceCreationPrompt?.repositories[id: repoRootA]?.baseRefOptions = [
        GitBranchRefOption(ref: "main", kind: .local),
        GitBranchRefOption(ref: "origin/main", kind: .remoteTracking),
      ]
    }
  }

  @Test func workspaceCreationPromptSubmitBuildsDraft() async {
    let repoRootA = "/tmp/repo-a"
    let repoRootB = "/tmp/repo-b"
    let repositories = [
      ProjectWorkspaceCreationRepository(
        id: repoRootA,
        name: "Repo A",
        rootURL: URL(fileURLWithPath: repoRootA)
      ),
      ProjectWorkspaceCreationRepository(
        id: repoRootB,
        name: "Repo B",
        rootURL: URL(fileURLWithPath: repoRootB)
      ),
    ]
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: repositories,
        title: " Multi Repo ",
        rootPath: " /tmp/multi-repo-workspace "
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.createButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          ProjectWorkspaceCreationDraft(
            title: "Multi Repo",
            rootURL: URL(filePath: "/tmp/multi-repo-workspace", directoryHint: .isDirectory),
            repositories: [
              ProjectWorkspaceRepositoryPlan(
                id: repoRootA,
                name: "Repo A",
                path: nil,
                sourceKind: .existingPath,
                sourceLocation: repoRootA,
                checkout: .link
              ),
              ProjectWorkspaceRepositoryPlan(
                id: repoRootB,
                name: "Repo B",
                path: nil,
                sourceKind: .existingPath,
                sourceLocation: repoRootB,
                checkout: .link
              ),
            ]
          )
        )
      )
    )
  }

  @Test func workspaceCreationPromptAddsRemoteRepositoryAfterLoadingRefs() async {
    let options = [
      GitBranchRefOption(ref: "origin/feature/login", kind: .fetchedRemote),
      GitBranchRefOption(ref: "origin/main", kind: .fetchedRemote),
    ]
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.remoteBranchRefs = { remoteURL in
        #expect(remoteURL == "git@github.com:onevcat/app.git")
        return GitRemoteBranchRefs(options: options, defaultBaseRef: "origin/main")
      }
    }

    await store.send(.addRemoteButtonTapped) {
      $0.remoteRepositoryPrompt = WorkspaceCreationPromptFeature.RemoteRepositoryPromptState()
    }
    await store.send(.remoteRepositoryPromptURLChanged(" git@github.com:onevcat/app.git ")) {
      $0.remoteRepositoryPrompt?.url = " git@github.com:onevcat/app.git "
      $0.remoteRepositoryPrompt?.name = "app"
    }
    await store.send(.remoteRepositoryPromptLoadButtonTapped) {
      $0.remoteRepositoryPrompt?.url = "git@github.com:onevcat/app.git"
      $0.remoteRepositoryPrompt?.isLoading = true
    }
    await store.receive(
      .remoteRepositoryPromptLoaded(
        "git@github.com:onevcat/app.git",
        GitRemoteBranchRefs(options: options, defaultBaseRef: "origin/main"))
    ) {
      $0.remoteRepositoryPrompt?.isLoading = false
      $0.remoteRepositoryPrompt?.branchOptions = options
      $0.remoteRepositoryPrompt?.defaultBaseRef = "origin/main"
    }
    await store.send(.remoteRepositoryPromptAddButtonTapped) {
      $0.repositories.append(
        ProjectWorkspaceCreationRepository(
          id: UUID(0).uuidString,
          name: "app",
          sourceKind: .remote,
          sourceLocation: "git@github.com:onevcat/app.git",
          checkoutMode: .useExistingRef,
          baseRef: "origin/main",
          baseRefOptions: options
        )
      )
      $0.remoteRepositoryPrompt = nil
    }
  }

  @Test func workspaceCreationPromptFolderFollowsTitleUntilEdited() async {
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    let requestedRootPath = defaultWorkspaceBaseRootPath(for: "Client App")
    let resolvedRootPath = expectedDefaultWorkspaceRootPath(for: "Client App")
    await store.send(.titleChanged("Client App")) {
      $0.title = "Client App"
      $0.rootPath = requestedRootPath
    }
    if resolvedRootPath == requestedRootPath {
      await store.receive(
        .automaticRootPathResolved(path: resolvedRootPath, requestedRootPath: requestedRootPath)
      )
    } else {
      await store.receive(
        .automaticRootPathResolved(path: resolvedRootPath, requestedRootPath: requestedRootPath)
      ) {
        $0.rootPath = resolvedRootPath
      }
    }
    await store.send(.rootPathChanged("/tmp/manual-workspace")) {
      $0.rootPath = "/tmp/manual-workspace"
      $0.isRootPathDirty = true
    }
    await store.send(.titleChanged("Other Title")) {
      $0.title = "Other Title"
    }
  }

  @Test func workspaceCreationPromptRemoteLoadUsesDetectedDefaultFromOptions() async {
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.addRemoteButtonTapped) {
      $0.remoteRepositoryPrompt = WorkspaceCreationPromptFeature.RemoteRepositoryPromptState()
    }
    await store.send(
      .remoteRepositoryPromptLoaded(
        "",
        GitRemoteBranchRefs(
          options: [
            GitBranchRefOption(ref: " origin/main ", kind: .fetchedRemote),
            GitBranchRefOption(ref: "origin/main", kind: .fetchedRemote),
          ],
          defaultBaseRef: "origin/missing"
        )
      )
    ) {
      $0.remoteRepositoryPrompt?.branchOptions = [
        GitBranchRefOption(ref: "origin/main", kind: .fetchedRemote)
      ]
      $0.remoteRepositoryPrompt?.defaultBaseRef = "origin/main"
    }
  }

  @Test func workspaceCreationPromptAddsLocalRepository() async {
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.addRepositoryFromURL(.localRepository, "/tmp/local-api")) {
      $0.repositories.append(
        ProjectWorkspaceCreationRepository(
          id: UUID(0).uuidString,
          name: "local-api",
          sourceKind: .localRepository,
          sourceLocation: "/tmp/local-api"
        )
      )
    }
    await store.receive(.delegate(.baseRefSourceChanged(UUID(0).uuidString)))
  }

  @Test func workspaceCreationPromptClearsAndReloadsBaseRefsWhenSourceLocationChanges() async {
    let repositoryID = "repo"
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [
          ProjectWorkspaceCreationRepository(
            id: repositoryID,
            name: "Repo",
            sourceKind: .bareRepository,
            sourceLocation: "/tmp/repo-a.git",
            checkoutMode: .useExistingRef,
            baseRef: "origin/main",
            baseRefOptions: [GitBranchRefOption(ref: "origin/main", kind: .remoteTracking)]
          )
        ],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.repositorySourceLocationChanged(repositoryID, "/tmp/repo-b.git")) {
      $0.repositories[id: repositoryID]?.sourceLocation = "/tmp/repo-b.git"
      $0.repositories[id: repositoryID]?.baseRef = nil
      $0.repositories[id: repositoryID]?.baseRefOptions = []
    }
    await store.receive(.delegate(.baseRefSourceChanged(repositoryID)))
  }

  @Test func workspaceCreationPromptClearsBaseRefsWhenRemoteSourceLocationChanges() async {
    let repositoryID = "remote"
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [
          ProjectWorkspaceCreationRepository(
            id: repositoryID,
            name: "Remote",
            sourceKind: .remote,
            sourceLocation: "git@github.com:onevcat/app.git",
            checkoutMode: .useExistingRef,
            baseRef: "origin/main",
            baseRefOptions: [GitBranchRefOption(ref: "origin/main", kind: .fetchedRemote)]
          )
        ],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(
      .repositorySourceLocationChanged(repositoryID, "git@github.com:onevcat/other.git")
    ) {
      $0.repositories[id: repositoryID]?.sourceLocation = "git@github.com:onevcat/other.git"
      $0.repositories[id: repositoryID]?.baseRef = nil
      $0.repositories[id: repositoryID]?.baseRefOptions = []
    }
  }

  @Test func workspaceCreationPromptRejectsUnknownBaseRef() async {
    let repoRootA = "/tmp/repo-a"
    let repoRootB = "/tmp/repo-b"
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [
          ProjectWorkspaceCreationRepository(
            id: repoRootA,
            name: "Repo A",
            rootURL: URL(fileURLWithPath: repoRootA),
            baseRefOptions: [GitBranchRefOption(ref: "main", kind: .local)]
          ),
          ProjectWorkspaceCreationRepository(
            id: repoRootB,
            name: "Repo B",
            rootURL: URL(fileURLWithPath: repoRootB),
            baseRefOptions: [GitBranchRefOption(ref: "master", kind: .local)]
          ),
        ],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.repositoryBaseRefChanged(repoRootA, "missing-branch"))
    await store.send(.repositoryBaseRefChanged(repoRootA, "main")) {
      $0.repositories[id: repoRootA]?.baseRef = "main"
    }
  }

  @Test func workspaceCreationPromptRequiresExistingRefForUseExistingMode() async {
    let repoRootA = "/tmp/repo-a"
    let repoRootB = "/tmp/repo-b"
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [
          ProjectWorkspaceCreationRepository(
            id: repoRootA,
            name: "Repo A",
            rootURL: URL(fileURLWithPath: repoRootA),
            checkoutMode: .useExistingRef,
            baseRefOptions: [GitBranchRefOption(ref: "main", kind: .local)]
          ),
          ProjectWorkspaceCreationRepository(
            id: repoRootB,
            name: "Repo B",
            rootURL: URL(fileURLWithPath: repoRootB)
          ),
        ],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Choose an existing branch for Repo A."
      $0.validationTarget = .repository(repoRootA, .baseRef)
      $0.validationRequestID = 1
    }
    await store.send(.repositoryBaseRefChanged(repoRootA, "main")) {
      $0.repositories[id: repoRootA]?.baseRef = "main"
      $0.validationMessage = nil
      $0.validationTarget = nil
    }
  }

  @Test func workspaceCreationPromptRequiresBranchNameForCreateBranchMode() async {
    let repoRootB = "/tmp/repo-b"
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [
          ProjectWorkspaceCreationRepository(
            id: "remote",
            name: "Remote",
            sourceKind: .remote,
            sourceLocation: "git@github.com:onevcat/app.git",
            checkoutMode: .createBranch,
            baseRef: "origin/main",
            baseRefOptions: [GitBranchRefOption(ref: "origin/main", kind: .fetchedRemote)]
          ),
          ProjectWorkspaceCreationRepository(
            id: repoRootB,
            name: "Repo B",
            rootURL: URL(fileURLWithPath: repoRootB)
          ),
        ],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Branch name required for Remote."
      $0.validationTarget = .repository("remote", .branchName)
      $0.validationRequestID = 1
    }
    await store.send(.repositoryBranchNameChanged("remote", "codex/app")) {
      $0.repositories[id: "remote"]?.branchName = "codex/app"
      $0.validationMessage = nil
      $0.validationTarget = nil
    }
  }

  @Test func workspaceCreationPromptResetsLinkModeWhenSwitchingToBare() async {
    let repositoryID = "repo"
    let store = TestStore(
      initialState: WorkspaceCreationPromptFeature.State(
        repositories: [
          ProjectWorkspaceCreationRepository(
            id: repositoryID,
            name: "Repo",
            rootURL: URL(fileURLWithPath: "/tmp/repo")
          )
        ],
        title: "Workspace",
        rootPath: "/tmp/workspace"
      )
    ) {
      WorkspaceCreationPromptFeature()
    }

    await store.send(.repositorySourceKindChanged(repositoryID, .bareRepository)) {
      $0.repositories[id: repositoryID]?.sourceKind = .bareRepository
      $0.repositories[id: repositoryID]?.checkoutMode = .createBranch
    }
    await store.receive(.delegate(.baseRefSourceChanged(repositoryID)))
  }

  @Test func requestRemoveWorkspaceShowsConfirmationSheet() async {
    let workspaceID = "/tmp/ws"
    let repository = makeRepository(
      id: workspaceID,
      name: "WS",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "WS")
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.repositoryManagement(.requestRemoveRepository(workspaceID))) {
      $0.removeWorkspaceConfirmation = RemoveWorkspaceConfirmation(
        repositoryID: workspaceID,
        workspaceTitle: "WS",
        rootPath: workspaceID
      )
    }
    await store.send(.repositoryManagement(.removeWorkspaceDeleteFilesChanged(true))) {
      $0.removeWorkspaceConfirmation?.deleteFiles = true
    }
    await store.send(.repositoryManagement(.removeWorkspacePromptDismissed)) {
      $0.removeWorkspaceConfirmation = nil
    }
  }

  @Test func requestRemoveWorkspaceBuildsBranchOptions() async {
    let workspaceID = "/tmp/ws"
    let workspace = ProjectWorkspace(
      title: "WS",
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .bareRepository,
          sourceLocation: "/tmp/api.git",
          branchName: "chore/x"
        ),
        ProjectWorkspace.RepositoryEntry(
          id: "app",
          name: "App",
          path: "app",
          sourceKind: .existingPath,
          sourceLocation: "/tmp/app"
        ),
        ProjectWorkspace.RepositoryEntry(
          id: "web",
          name: "Web",
          path: "web",
          sourceKind: .remote,
          sourceLocation: "git@github.com:onevcat/web.git",
          branchName: "feature/web"
        ),
      ]
    )
    let repository = makeRepository(
      id: workspaceID,
      name: "WS",
      kind: .plain,
      worktrees: [],
      workspace: workspace
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.repositoryManagement(.requestRemoveRepository(workspaceID))) {
      $0.removeWorkspaceConfirmation = RemoveWorkspaceConfirmation(
        repositoryID: workspaceID,
        workspaceTitle: "WS",
        rootPath: workspaceID,
        branchOptions: [
          RemoveWorkspaceConfirmation.BranchOption(
            id: "api",
            repositoryName: "API",
            branchName: "chore/x"
          )
        ]
      )
    }
    await store.send(.repositoryManagement(.removeWorkspaceDeleteBranchChanged("api", true))) {
      $0.removeWorkspaceConfirmation?.branchOptions[0].isSelected = true
    }
  }

  @Test func removeWorkspaceConfirmedRemovesEntry() async {
    let workspaceID = "/tmp/ws"
    let repository = makeRepository(
      id: workspaceID,
      name: "WS",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "WS")
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositoryManagement(.requestRemoveRepository(workspaceID)))
    await store.send(.repositoryManagement(.removeWorkspacePromptConfirmed)) {
      $0.removeWorkspaceConfirmation = nil
      $0.removingRepositoryIDs = [workspaceID]
    }
    await store.receive(\.repositoryManagement.repositoryRemoved)
    await store.finish()
  }

  @Test func removeSelectedWorkspaceSelectsNextRepository() async {
    let workspaceID = "/tmp/ws"
    let otherWorktree = makeWorktree(id: "/tmp/other/main", name: "main", repoRoot: "/tmp/other")
    let otherRepo = makeRepository(id: "/tmp/other", name: "other", worktrees: [otherWorktree])
    let wsRepo = makeRepository(
      id: workspaceID,
      name: "WS",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "WS")
    )
    var state = makeState(repositories: [wsRepo, otherRepo])
    state.selection = .repository(workspaceID)
    state.selectedWorkspaceChildID = "child-1"
    let otherEntry = PersistedRepositoryEntry(path: "/tmp/other", kind: .git)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [otherEntry] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { @Sendable url in url }
      $0.gitClient.worktrees = { @Sendable _ in [otherWorktree] }
      $0.gitClient.isBareRepository = { @Sendable _ in false }
    }
    store.exhaustivity = .off

    await store.send(.repositoryManagement(.requestRemoveRepository(workspaceID)))
    await store.send(.repositoryManagement(.removeWorkspacePromptConfirmed))
    await store.receive(\.repositoryManagement.repositoryRemoved)
    await store.receive(\.repositoriesLoaded)
    await store.finish()

    #expect(store.state.selectedWorkspaceChildID == nil)
    #expect(store.state.selectedWorkspaceChildID == nil)
    // After removing the currently-selected workspace with another repo available,
    // the sidebar should auto-select the next item — not leave an empty selection.
    #expect(
      store.state.selection == .worktree(otherWorktree.id),
      "Expected auto-selection of next worktree, got \(String(describing: store.state.selection))"
    )
  }

  @Test func removeWorkspaceRoutesBranchDeletionThroughGuardedClient() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-ws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "api"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let workspaceID = rootURL.path(percentEncoded: false)
    let workspace = ProjectWorkspace(
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .bareRepository,
          sourceLocation: "/tmp/api.git",
          branchName: "chore/x"
        )
      ]
    )
    let repository = makeRepository(
      id: workspaceID, name: "WS", kind: .plain, worktrees: [], workspace: workspace
    )
    struct DeleteBranchCall: Sendable, Equatable {
      let name: String
      let root: String
      let force: Bool
    }
    let deleteCalls = LockIsolated<[DeleteBranchCall]>([])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.shellClient.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
      $0.gitClient.deleteLocalBranch = { name, url, force in
        deleteCalls.withValue {
          $0.append(
            DeleteBranchCall(name: name, root: url.path(percentEncoded: false), force: force))
        }
        return .deleted
      }
    }
    store.exhaustivity = .off

    await store.send(.repositoryManagement(.requestRemoveRepository(workspaceID)))
    await store.send(.repositoryManagement(.removeWorkspaceDeleteFilesChanged(true)))
    await store.send(.repositoryManagement(.removeWorkspaceDeleteBranchChanged("api", true)))
    await store.send(.repositoryManagement(.removeWorkspacePromptConfirmed))
    await store.receive(\.repositoryManagement.repositoryRemoved)
    await store.finish()

    // Branch deletion must go through the guarded GitClient entry point with
    // force = true, never a raw `git branch -D`.
    #expect(deleteCalls.value.count == 1)
    #expect(deleteCalls.value.first?.name == "chore/x")
    #expect(deleteCalls.value.first?.root == "/tmp/api.git")
    #expect(deleteCalls.value.first?.force == true)
    // All worktrees unregistered, so the folder is deleted without prompting.
    #expect(!FileManager.default.fileExists(atPath: workspaceID))
  }

  @Test func removeWorkspaceAsksBeforeDeletingFolderWhenWorktreeRemovalFails() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-ws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "api"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let workspaceID = rootURL.path(percentEncoded: false)
    let workspace = ProjectWorkspace(
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .bareRepository,
          sourceLocation: "/tmp/api.git"
        )
      ]
    )
    let repository = makeRepository(
      id: workspaceID, name: "WS", kind: .plain, worktrees: [], workspace: workspace
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.shellClient.runLoginImpl = { _, _, _, _ in
        throw ShellClientError(command: "git", stdout: "", stderr: "broken", exitCode: 1)
      }
    }
    store.exhaustivity = .off

    await store.send(.repositoryManagement(.requestRemoveRepository(workspaceID)))
    await store.send(.repositoryManagement(.removeWorkspaceDeleteFilesChanged(true)))
    await store.send(.repositoryManagement(.removeWorkspacePromptConfirmed))
    await store.receive(\.repositoryManagement.workspaceCleanupReportedFailures)

    // The folder must NOT be deleted yet — the user is asked first.
    #expect(store.state.alert != nil)
    #expect(FileManager.default.fileExists(atPath: workspaceID))

    await store.send(
      .alert(
        .presented(
          .confirmWorkspaceRootDeletion(
            repositoryID: workspaceID,
            rootPath: workspaceID,
            selectionWasRemoved: false
          ))))
    await store.receive(\.repositoryManagement.repositoryRemoved)
    await store.finish()

    #expect(!FileManager.default.fileExists(atPath: workspaceID))
  }

  @Test func keepWorkspaceFolderAfterCleanupFailureRemovesEntryButKeepsFolder() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-ws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "api"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let workspaceID = rootURL.path(percentEncoded: false)
    let workspace = ProjectWorkspace(
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .bareRepository,
          sourceLocation: "/tmp/api.git"
        )
      ]
    )
    let repository = makeRepository(
      id: workspaceID, name: "WS", kind: .plain, worktrees: [], workspace: workspace
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.shellClient.runLoginImpl = { _, _, _, _ in
        throw ShellClientError(command: "git", stdout: "", stderr: "broken", exitCode: 1)
      }
    }
    store.exhaustivity = .off

    await store.send(.repositoryManagement(.requestRemoveRepository(workspaceID)))
    await store.send(.repositoryManagement(.removeWorkspaceDeleteFilesChanged(true)))
    await store.send(.repositoryManagement(.removeWorkspacePromptConfirmed))
    await store.receive(\.repositoryManagement.workspaceCleanupReportedFailures)

    await store.send(
      .alert(
        .presented(
          .keepWorkspaceFolderAfterCleanupFailure(
            repositoryID: workspaceID,
            selectionWasRemoved: false
          ))))
    await store.receive(\.repositoryManagement.repositoryRemoved)
    await store.finish()

    // Entry removed from Prowl, but the on-disk folder is preserved.
    #expect(FileManager.default.fileExists(atPath: workspaceID))
  }

  @Test func repositoryRemovedDropsEntryDespiteTrailingSlashMismatch() async {
    let repository = makeRepository(
      id: "/tmp/ws/",
      name: "WS",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "WS")
    )
    let savedEntries = LockIsolated<[[PersistedRepositoryEntry]]>([])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: "/tmp/ws", kind: .plain)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in
        savedEntries.withValue { $0.append(entries) }
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { _ in
        throw GitClientError.commandFailed(command: "git", message: "not a git repository")
      }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoryManagement(.repositoryRemoved("/tmp/ws/", selectionWasRemoved: false)))
    await store.finish()

    #expect(savedEntries.value.last == [])
  }

  @Test func workspaceCreationCancelWhileCreatingShowsToast() async {
    var initialState = RepositoriesFeature.State()
    initialState.workspaceCreationPrompt = WorkspaceCreationPromptFeature.State(
      repositories: [],
      title: "Workspace",
      rootPath: "/tmp/workspace"
    )
    initialState.workspaceCreationPrompt?.isCreating = true
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.workspaceCreation(.promptCanceled)) {
      $0.workspaceCreationPrompt = nil
    }
    await store.receive(\.showToast, .warning("Workspace creation canceled"))
  }

  @Test func workspaceGitRunnerUsesLoginShellForGitCommands() async throws {
    struct LoginCall: Equatable, Sendable {
      let executablePath: String
      let arguments: [String]
      let currentDirectoryPath: String?
    }
    let directRunCalls = LockIsolated(0)
    let loginCalls = LockIsolated<[LoginCall]>([])
    let runner = RepositoriesFeature.workspaceGitRunner(
      shellClient: ShellClient(
        run: { _, _, _ in
          directRunCalls.withValue { $0 += 1 }
          throw ShellClientError(command: "git", stdout: "", stderr: "direct run used", exitCode: 1)
        },
        runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
          loginCalls.withValue {
            $0.append(
              LoginCall(
                executablePath: executableURL.path(percentEncoded: false),
                arguments: arguments,
                currentDirectoryPath: currentDirectoryURL?.path(percentEncoded: false)
              ))
          }
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
      )
    )

    try await runner.run(
      ProjectWorkspaceGitCommand(
        arguments: ["-C", "/tmp/repo", "worktree", "add", "/tmp/workspace/repo"],
        currentDirectoryURL: URL(fileURLWithPath: "/tmp/repo")
      ))

    #expect(directRunCalls.value == 0)
    #expect(
      loginCalls.value == [
        LoginCall(
          executablePath: "/usr/bin/env",
          arguments: ["git", "-C", "/tmp/repo", "worktree", "add", "/tmp/workspace/repo"],
          currentDirectoryPath: "/tmp/repo"
        )
      ])
  }

  @Test func workspaceCreationSuccessOpensWorkspaceAndShowsToast() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-feature-success-\(UUID().uuidString)", directoryHint: .isDirectory)
      .standardizedFileURL
    defer { try? FileManager.default.removeItem(at: rootURL) }
    var initialState = RepositoriesFeature.State()
    initialState.workspaceCreationPrompt = WorkspaceCreationPromptFeature.State(
      repositories: [],
      title: "Feature",
      rootPath: rootURL.path(percentEncoded: false)
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
      $0.shellClient.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    let draft = ProjectWorkspaceCreationDraft(
      title: "Feature",
      rootURL: rootURL,
      repositories: [
        ProjectWorkspaceRepositoryPlan(
          id: "app",
          name: "App",
          path: "app",
          sourceKind: .remote,
          sourceLocation: "git@github.com:onevcat/app.git",
          checkout: .useExistingRef("origin/main")
        ),
        ProjectWorkspaceRepositoryPlan(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .remote,
          sourceLocation: "git@github.com:onevcat/api.git",
          checkout: .useExistingRef("origin/main")
        ),
      ]
    )

    await store.send(.workspaceCreation(.createWorkspace(draft))) {
      $0.workspaceCreationPrompt?.isCreating = true
    }
    await store.receive(\.workspaceCreation.workspaceCreated) {
      $0.workspaceCreationPrompt = nil
    }
    await store.receive(\.showToast, .success("Workspace created")) {
      $0.statusToast = .success("Workspace created")
    }
    await store.receive(\.repositoryManagement.openRepositories)
    await store.finish()

    #expect(ProjectWorkspace.load(from: rootURL)?.title == "Feature")
  }

  @Test func workspaceBaseRefsLoadErrorSurfacesValidationMessage() async {
    let repositoryID = "/tmp/repo"
    var initialState = RepositoriesFeature.State()
    initialState.workspaceCreationPrompt = WorkspaceCreationPromptFeature.State(
      repositories: [
        ProjectWorkspaceCreationRepository(
          id: repositoryID,
          name: "Repo",
          rootURL: URL(fileURLWithPath: repositoryID)
        )
      ],
      title: "Workspace",
      rootPath: "/tmp/workspace"
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .workspaceCreation(
        .baseRefsLoaded(
          repositoryID: repositoryID,
          sourceKind: .existingPath,
          sourceLocation: repositoryID,
          options: [],
          defaultBaseRef: nil,
          errorMessage: "Could not read branches for Repo: boom"
        )
      )
    ) {
      $0.workspaceCreationPrompt?.validationMessage = "Could not read branches for Repo: boom"
    }
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
      $0.gitClient.repositoryWebURL = { _ in nil }
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

  @Test func loadPersistedRepositoriesResolvesSymlinkedGitRepositoryRoot() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let realRoot = tempRoot.appending(path: "real", directoryHint: .isDirectory)
    let symlinkRoot = tempRoot.appending(path: "link", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)

    let realPath = realRoot.standardizedFileURL.path(percentEncoded: false)
    let symlinkPath = symlinkRoot.standardizedFileURL.path(percentEncoded: false)
    let worktree = makeWorktree(id: realPath, name: "main", repoRoot: realPath)
    let repository = makeRepository(id: realPath, name: "real", kind: .git, worktrees: [worktree])
    let savedEntries = LockIsolated<[[PersistedRepositoryEntry]]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = {
        [PersistedRepositoryEntry(path: symlinkPath, kind: .git)]
      }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in
        savedEntries.withValue { $0.append(entries) }
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repoRoot = { url in
        #expect(url.standardizedFileURL.path(percentEncoded: false) == symlinkPath)
        return realRoot
      }
      $0.gitClient.worktrees = { url in
        #expect(url.standardizedFileURL.path(percentEncoded: false) == realPath)
        return [worktree]
      }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repository]
      $0.repositoryRoots = [realRoot.standardizedFileURL]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    #expect(savedEntries.value == [[PersistedRepositoryEntry(path: realPath, kind: .git)]])
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
        Issue.record(
          "downgraded git entry should not load worktrees: \(url.path(percentEncoded: false))")
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
      $0.gitClient.repositoryWebURL = { _ in nil }
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

  @Test func openRepositoriesFinishedAutoSelectsNewGitRepositoryAfterInitialLoad() async {
    let existingWorktree = makeWorktree(id: "/tmp/existing/main", name: "main", repoRoot: "/tmp/existing")
    let existingRepository = makeRepository(id: "/tmp/existing", worktrees: [existingWorktree])
    let newWorktree = makeWorktree(id: "/tmp/new/main", name: "main", repoRoot: "/tmp/new")
    let newRepository = makeRepository(id: "/tmp/new", name: "new", worktrees: [newWorktree])
    var initialState = makeState(repositories: [existingRepository])
    initialState.isInitialLoadComplete = true
    initialState.snapshotPersistencePhase = .active

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in nil }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [existingRepository, newRepository],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [existingRepository.rootURL, newRepository.rootURL]
        ))
    ) {
      $0.repositories = [existingRepository, newRepository]
      $0.repositoryRoots = [existingRepository.rootURL, newRepository.rootURL]
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(newWorktree.id)
      $0.sidebarSelectedWorktreeIDs = [newWorktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [newWorktree.id]
      $0.openedWorktreeIDs = [newWorktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test func openRepositoriesFinishedAutoSelectsNewPlainRepositoryAfterInitialLoad() async {
    let existingWorktree = makeWorktree(id: "/tmp/existing/main", name: "main", repoRoot: "/tmp/existing")
    let existingRepository = makeRepository(id: "/tmp/existing", worktrees: [existingWorktree])
    let plainRepository = makeRepository(
      id: "/tmp/plain",
      name: "plain",
      kind: .plain,
      worktrees: []
    )
    var initialState = makeState(repositories: [existingRepository])
    initialState.isInitialLoadComplete = true
    initialState.snapshotPersistencePhase = .active

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in nil }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [existingRepository, plainRepository],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [existingRepository.rootURL, plainRepository.rootURL]
        ))
    ) {
      $0.repositories = [existingRepository, plainRepository]
      $0.repositoryRoots = [existingRepository.rootURL, plainRepository.rootURL]
      $0.pendingTerminalFocusWorktreeIDs = [plainRepository.id]
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.selectRepository) {
      $0.selection = .repository(plainRepository.id)
      $0.openedWorktreeIDs = [plainRepository.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test func openRepositoriesFinishedDoesNotAutoSelectDuringInitialLoad() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in nil }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [repository],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [repository.rootURL]
        ))
    ) {
      $0.repositories = [repository]
      $0.repositoryRoots = [repository.rootURL]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func openRepositoriesFinishedDoesNotAutoSelectWhileRestoringSnapshot() async {
    let existingWorktree = makeWorktree(id: "/tmp/existing/main", name: "main", repoRoot: "/tmp/existing")
    let existingRepository = makeRepository(id: "/tmp/existing", worktrees: [existingWorktree])
    let newWorktree = makeWorktree(id: "/tmp/new/main", name: "main", repoRoot: "/tmp/new")
    let newRepository = makeRepository(id: "/tmp/new", name: "new", worktrees: [newWorktree])
    var initialState = makeState(repositories: [existingRepository])
    initialState.isInitialLoadComplete = true
    initialState.snapshotPersistencePhase = .restoring

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in nil }
    }

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [existingRepository, newRepository],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [existingRepository.rootURL, newRepository.rootURL]
        ))
    ) {
      $0.repositories = [existingRepository, newRepository]
      $0.repositoryRoots = [existingRepository.rootURL, newRepository.rootURL]
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
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

  @Test func newTerminalTabSelectsWorktreeAndCreatesRootTab() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminalTab(worktree.id))
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.openedWorktreeIDs = [worktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()

    #expect(
      sentCommands.value == [
        .createTabInDirectory(worktree, directory: worktree.workingDirectory)
      ]
    )
  }

  @Test func newTerminalTabInCanvasCreatesAndFocusesNewCanvasTab() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let createdTabID = TerminalTabID(rawValue: UUID())
    var initialState = makeState(repositories: [repository])
    initialState.selection = .canvas

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.createTabInDirectory = { actualWorktree, actualDirectory in
        #expect(actualWorktree == worktree)
        #expect(actualDirectory == worktree.workingDirectory)
        return createdTabID
      }
    }

    await store.send(.newTerminalTab(worktree.id))
    await store.receive(\.newTerminalTabCreatedInCanvas) {
      $0.nextCanvasFocusRequestID = 1
      $0.pendingCanvasFocusRequest = CanvasFocusRequest(
        id: 1,
        target: .tab(createdTabID)
      )
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.finish()

    #expect(store.state.selection == .canvas)
  }

  @Test func newTerminalTabWithUnknownWorktreeDoesNothing() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.newTerminalTab("/tmp/unknown"))
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
      paneTitle: "agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
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
      paneTitle: "agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
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

  @Test func activeAgentHandOffTappedFocusesSurfaceAndSelectsWorktree() async {
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
      paneTitle: "agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
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

    // The context-menu hand off shares the tap path: anchor first, then the
    // worktree selection so the HUD opens over the entry's own terminal.
    await store.send(.activeAgents(.handOffTapped(entry.id))) {
      $0.activeAgents.focusedSurfaceID = surfaceID
    }
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

  @Test func activeAgentMarkAsReadTappedMarksSurfaceNotificationsRead() async {
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
      paneTitle: "agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
      agent: .codex,
      rawState: .working,
      displayState: .working,
      lastChangedAt: Date(timeIntervalSince1970: 0)
    )
    state.activeAgents.entries = [entry]

    let markedRead = LockIsolated<(Worktree.ID, UUID)?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.markNotificationsReadForSurface = { worktreeID, surface in
        markedRead.setValue((worktreeID, surface))
      }
    }

    // Mark as Read clears the entry's pane without selecting or focusing it.
    await store.send(.activeAgents(.markAsReadTapped(entry.id)))

    #expect(markedRead.value?.0 == worktree.id)
    #expect(markedRead.value?.1 == surfaceID)
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
      paneTitle: "agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
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
      $0.preArchivedWorktreeID = worktree1.id
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

    store.exhaustivity = .off
    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.promptedWorktreeCreationDataLoaded) {
      #expect($0.worktreeCreationPrompt?.repositoryID == repository.id)
      #expect($0.worktreeCreationPrompt?.branchName == "")
      #expect($0.worktreeCreationPrompt?.baseRefOptions == ["origin/dev", "origin/main"])
      #expect($0.worktreeCreationPrompt?.isSuggestingName == true)
      #expect($0.worktreeCreationPrompt?.randomPlaceholder.isEmpty == false)
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
      validationMessage: nil,
      randomPlaceholder: "bold-cat-042"
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
      validationMessage: nil,
      randomPlaceholder: "bold-cat-042"
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

    store.exhaustivity = .off
    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repoA.id)))
    await promptLoadGate.waitUntilArmed()
    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repoB.id)))
    await promptLoadGate.resume()
    await store.receive(\.worktreeCreation.promptedWorktreeCreationDataLoaded) {
      #expect($0.worktreeCreationPrompt?.repositoryID == repoB.id)
      #expect($0.worktreeCreationPrompt?.branchName == "")
      #expect($0.worktreeCreationPrompt?.isSuggestingName == true)
    }
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
      validationMessage: nil,
      randomPlaceholder: "bold-cat-042"
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
          continuation.yield(
            .outputLine(ShellStreamLine(source: .stderr, text: "[2/2] copy .cache")))
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
        throw NSError(
          domain: "git", code: 128, userInfo: [NSLocalizedDescriptionKey: "network unreachable"])
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

  @Test(.dependencies)
  func createRandomWorktreeUsesGlobalWorktreeBaseDirectoryWhenRepositoryOverrideMissing() async {
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

  @Test(.dependencies) func createRandomWorktreeUsesGlobalCopyFlagsWhenRepositoryOverridesMissing()
    async
  {
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
        observedCopyFlags.withValue {
          $0 = (request.copyFiles.ignored, request.copyFiles.untracked)
        }
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
        observedCopyFlags.withValue {
          $0 = (request.copyFiles.ignored, request.copyFiles.untracked)
        }
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

  @Test(.dependencies) func createRandomWorktreeInRepositoryStreamFailureRemovesPendingWorktree()
    async
  {
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
          continuation.finish(
            throwing: GitClientError.commandFailed(command: "wt sw", message: "boom"))
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
    let repository = makeRepository(
      id: repoRoot, worktrees: [makeWorktree(id: repoRoot, name: "main")])
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
        targets: [
          RepositoriesFeature.DeleteWorktreeTarget(
            worktreeID: worktree.id, repositoryID: repository.id)
        ],
        deleteBranch: false
      )
      $0.nextDeleteWorktreeConfirmationID = 1
    }
  }

  @Test(.dependencies) func requestDeleteWorktreePreselectsRememberedBranchChoice() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let state = makeState(repositories: [repository])
    state.$deleteBranchOnManualWorktreeDelete.withLock { $0 = true }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeLifecycle(.requestDeleteWorktree(worktree.id, repository.id))) {
      $0.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
        id: 0,
        title: "Delete worktree?",
        message: "Delete \(worktree.name)? The worktree directory will be removed.",
        targets: [
          RepositoriesFeature.DeleteWorktreeTarget(
            worktreeID: worktree.id, repositoryID: repository.id)
        ],
        deleteBranch: true
      )
      $0.nextDeleteWorktreeConfirmationID = 1
    }
  }

  @Test(.dependencies) func deletePromptConfirmedRemembersBranchChoice() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, worktree])
    var state = makeState(repositories: [repository])
    state.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
      id: 0,
      title: "Delete worktree?",
      message: "Delete feature? The worktree directory will be removed.",
      targets: [
        RepositoriesFeature.DeleteWorktreeTarget(
          worktreeID: worktree.id, repositoryID: repository.id)
      ],
      deleteBranch: true
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
      $0.gitClient.deleteLocalBranch = { _, _, _ in .deleted }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.worktreeLifecycle(.deleteWorktreePromptConfirmed)) {
      $0.deleteWorktreeConfirmation = nil
      $0.$deleteBranchOnManualWorktreeDelete.withLock { $0 = true }
    }
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
  }

  @Test(.dependencies) func deletePromptConfirmedRemembersUncheckedBranchChoice() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, worktree])
    var state = makeState(repositories: [repository])
    state.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
      id: 0,
      title: "Delete worktree?",
      message: "Delete feature? The worktree directory will be removed.",
      targets: [
        RepositoriesFeature.DeleteWorktreeTarget(
          worktreeID: worktree.id, repositoryID: repository.id)
      ],
      deleteBranch: false
    )
    state.$deleteBranchOnManualWorktreeDelete.withLock { $0 = true }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.worktreeLifecycle(.deleteWorktreePromptConfirmed)) {
      $0.deleteWorktreeConfirmation = nil
      $0.$deleteBranchOnManualWorktreeDelete.withLock { $0 = false }
    }
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
  }

  @Test(.dependencies) func dismissingDeletePromptDoesNotRememberChangedChoice() async {
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
        targets: [
          RepositoriesFeature.DeleteWorktreeTarget(
            worktreeID: worktree.id, repositoryID: repository.id)
        ],
        deleteBranch: false
      )
      $0.nextDeleteWorktreeConfirmationID = 1
    }
    await store.send(.worktreeLifecycle(.deleteWorktreePromptDeleteBranchChanged(true))) {
      $0.deleteWorktreeConfirmation?.deleteBranch = true
    }
    await store.send(.worktreeLifecycle(.deleteWorktreePromptDismissed)) {
      $0.deleteWorktreeConfirmation = nil
    }
    await store.send(.worktreeLifecycle(.requestDeleteWorktree(worktree.id, repository.id))) {
      $0.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
        id: 1,
        title: "Delete worktree?",
        message: "Delete \(worktree.name)? The worktree directory will be removed.",
        targets: [
          RepositoriesFeature.DeleteWorktreeTarget(
            worktreeID: worktree.id, repositoryID: repository.id)
        ],
        deleteBranch: false
      )
      $0.nextDeleteWorktreeConfirmationID = 2
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
      targets: [
        RepositoriesFeature.DeleteWorktreeTarget(
          worktreeID: worktree.id, repositoryID: repository.id)
      ],
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
        throw GitClientError.commandFailed(
          command: "git branch -d feature", message: "not fully merged")
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

  @Test func deleteWorktreeFailureKeepsWorktreeAndShowsGitError() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in
        throw GitClientError.commandFailed(
          command: "git worktree remove --force \(worktree.id)",
          message: "fatal: cannot remove a locked working tree"
        )
      }
    }

    await store.send(
      .worktreeLifecycle(
        .deleteWorktreeConfirmed(worktree.id, repository.id, deleteBranch: false)
      )
    ) {
      $0.deletingWorktreeIDs = [worktree.id]
    }
    await store.receive(\.worktreeLifecycle.deleteWorktreeFailed) {
      $0.deletingWorktreeIDs = []
      $0.alert = AlertState {
        TextState("Unable to delete worktree")
      } actions: {
        ButtonState(role: .cancel) {
          TextState("OK")
        }
      } message: {
        TextState(
          "Git command failed: git worktree remove --force \(worktree.id)\n"
            + "fatal: cannot remove a locked working tree"
        )
      }
    }
    await store.finish()

    #expect(store.state.repositories[id: repository.id]?.worktrees[id: worktree.id] != nil)
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
      RepositoriesFeature.DeleteWorktreeTarget(
        worktreeID: worktree1.id, repositoryID: repository.id),
      RepositoriesFeature.DeleteWorktreeTarget(
        worktreeID: worktree2.id, repositoryID: repository.id),
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
      TextState(
        "Find \(worktree.name) later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay))."
      )
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
      RepositoriesFeature.ArchiveWorktreeTarget(
        worktreeID: worktree1.id, repositoryID: repository.id),
      RepositoriesFeature.ArchiveWorktreeTarget(
        worktreeID: worktree2.id, repositoryID: repository.id),
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
      TextState(
        "Find them later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay)).")
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
          continuation.yield(
            .finished(ShellOutput(stdout: "syncing\ndone", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    }

    await store.send(
      .worktreeLifecycle(.archiveWorktreeConfirmed(featureWorktree.id, repository.id))
    ) {
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

    await store.send(
      .worktreeLifecycle(.archiveWorktreeConfirmed(featureWorktree.id, repository.id))
    ) {
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
      .worktreeLifecycle(
        .archiveScriptSucceeded(worktreeID: featureWorktree.id, repositoryID: repository.id))
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

    await store.send(
      .worktreeLifecycle(
        .archiveScriptFailed(worktreeID: featureWorktree.id, message: "late failure")))
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
      .worktreeLifecycle(
        .archiveScriptSucceeded(worktreeID: featureWorktree.id, repositoryID: repository.id))
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

    await store.send(
      .worktreeLifecycle(
        .archiveScriptFailed(worktreeID: featureWorktree.id, message: "script failed")))
    #expect(store.state.archivingWorktreeIDs.isEmpty)
    #expect(store.state.archiveScriptProgressByWorktreeID.isEmpty)
    #expect(store.state.alert != nil)
  }

  @Test func repositoriesLoadedClearsRenamePromptWhenTargetDisappears() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "eagle", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let reloadedRepository = makeRepository(id: "/tmp/repo", worktrees: [])
    var state = makeState(repositories: [repository])
    state.nextPendingRenameBranchRequestID = 1
    state.pendingRenameBranchRequest = PendingRenameBranchRequest(
      id: 1,
      worktreeID: worktree.id,
      currentName: worktree.name
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.pendingRenameBranchRequest = nil
    }
  }

  @Test func archivingTargetClearsRenamePrompt() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "eagle", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.nextPendingRenameBranchRequestID = 1
    state.pendingRenameBranchRequest = PendingRenameBranchRequest(
      id: 1,
      worktreeID: worktree.id,
      currentName: worktree.name
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.repositoryPersistence.saveArchivedWorktrees = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.worktreeLifecycle(.archiveWorktreeApply(worktree.id, repository.id))) {
      $0.pendingRenameBranchRequest = nil
    }
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
    let repository = makeRepository(
      id: repoRoot, worktrees: [mainWorktree, featureA, featureB, featureC])
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
    #expect(
      store.state.repositories[id: repository.id]?.worktrees[id: worktree.id]?.name == "falcon")
    #expect(
      store.state.repositories[id: repository.id]?.worktrees[id: worktree.id]?.createdAt
        == createdAt)
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

    await store.send(
      .worktreeOrdering(.unpinnedWorktreesMoved(repositoryID: repoRoot, IndexSet(integer: 0), 3))
    ) {
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

    await store.send(
      .worktreeOrdering(.pinnedWorktreesMoved(repositoryID: repoA, IndexSet(integer: 1), 0))
    ) {
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
    #expect(
      store.state.archivedWorktrees == [ArchivedWorktree(id: worktree.id, archivedAt: fixedDate)])
  }

  @Test func repositoriesLoadedSkipsSelectionChangeWhenOnlyDisplayDataChanges() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let updatedWorktree = makeWorktree(
      id: "/tmp/repo/main", name: "main-updated", repoRoot: repoRoot)
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
    await store.finish()
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
    let updatedRepository = makeRepository(
      id: repoRoot, worktrees: [newWorktree, existingWorktree])
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

  @Test(.dependencies) func repositoryPullRequestsLoadedAutoDeleteOnlyDeletesProwlCreatedBranches()
    async
  {
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
      $0.global.deleteBranchOnAutomaticCleanup = true
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

  @Test(.dependencies) func repositoryPullRequestsLoadedAutoDeleteDeletesProwlCreatedBranch() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let prowlWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, prowlWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .delete
    state.$prowlCreatedWorktreeIDs.withLock { $0 = [prowlWorktree.id] }
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.deleteBranchOnAutomaticCleanup = true
    }
    let deletedBranches = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
      $0.gitClient.deleteLocalBranch = { branchName, _, force in
        #expect(force == false)
        deletedBranches.withValue { $0.append(branchName) }
        return .deleted
      }
    }
    store.exhaustivity = .off
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: prowlWorktree.name)

    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [prowlWorktree.id: mergedPullRequest]
        ))
    )
    await store.receive(\.worktreeLifecycle.deleteWorktreeConfirmed) {
      $0.deletingWorktreeIDs = [prowlWorktree.id]
    }
    await store.receive(\.worktreeLifecycle.worktreeDeleted)

    #expect(deletedBranches.value == [prowlWorktree.name])
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
    let openPullRequest = makePullRequest(
      state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.mergedWorktreeAction = .archive
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let upstreamRemoteInfo = GithubRemoteInfo(
      host: "github.com", owner: "supabitapp", repo: "supacode")
    let mergedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.resolveRemoteInfo = { _ in upstreamRemoteInfo }
      $0.githubCLI.mergePullRequest = { _, _, number, _, _ in
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
    let openPullRequest = makePullRequest(
      state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let upstreamRemoteInfo = GithubRemoteInfo(
      host: "github.com", owner: "supabitapp", repo: "supacode")
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
      $0.githubCLI.mergePullRequest = { _, _, _, strategy, _ in
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
    let openPullRequest = makePullRequest(
      state: "OPEN", headRefName: featureWorktree.name, number: 12)
    let upstreamRemoteInfo = GithubRemoteInfo(
      host: "github.com", owner: "supabitapp", repo: "supacode")
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
      $0.githubCLI.mergePullRequest = { root, remoteInfo, number, _, _ in
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

  @Test func pullRequestMergeUsesPullRequestURLRemoteInfo() async {
    let fixture = makePullRequestURLRemoteInfoFixture(repoRoot: "/tmp/repo-pr-url-merge")
    let remoteInfos = LockIsolated<[GithubRemoteInfo]>([])
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("git remoteInfo should not run when PR URL resolves")
        return nil
      }
      $0.githubCLI.resolveRemoteInfo = { _ in
        Issue.record("gh resolveRemoteInfo should not run when PR URL resolves")
        return nil
      }
      $0.githubCLI.mergePullRequest = { _, remoteInfo, _, _, _ in
        remoteInfos.withValue { $0.append(remoteInfo) }
      }
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(fixture.featureWorktree.id, .merge)))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Merging pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request merged")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(remoteInfos.value == [fixture.expectedRemoteInfo])
    await store.finish()
  }

  @Test func pullRequestCloseUsesPullRequestURLRemoteInfo() async {
    let fixture = makePullRequestURLRemoteInfoFixture(repoRoot: "/tmp/repo-pr-url-close")
    let remoteInfos = LockIsolated<[GithubRemoteInfo]>([])
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("git remoteInfo should not run when PR URL resolves")
        return nil
      }
      $0.githubCLI.resolveRemoteInfo = { _ in
        Issue.record("gh resolveRemoteInfo should not run when PR URL resolves")
        return nil
      }
      $0.githubCLI.closePullRequest = { _, remoteInfo, _, _ in
        remoteInfos.withValue { $0.append(remoteInfo) }
      }
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(fixture.featureWorktree.id, .close)))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Closing pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request closed")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(remoteInfos.value == [fixture.expectedRemoteInfo])
    await store.finish()
  }

  @Test func pullRequestMarkReadyUsesPullRequestURLRemoteInfo() async {
    let fixture = makePullRequestURLRemoteInfoFixture(repoRoot: "/tmp/repo-pr-url-ready")
    let remoteInfos = LockIsolated<[GithubRemoteInfo]>([])
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("git remoteInfo should not run when PR URL resolves")
        return nil
      }
      $0.githubCLI.resolveRemoteInfo = { _ in
        Issue.record("gh resolveRemoteInfo should not run when PR URL resolves")
        return nil
      }
      $0.githubCLI.markPullRequestReady = { _, remoteInfo, _, _ in
        remoteInfos.withValue { $0.append(remoteInfo) }
      }
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(fixture.featureWorktree.id, .markReadyForReview)))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Marking PR ready…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request marked ready")
    }
    #expect(remoteInfos.value == [fixture.expectedRemoteInfo])
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
    let openPullRequest = makePullRequest(
      state: "OPEN", headRefName: featureWorktree.name, number: 12)
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
      $0.githubCLI.mergePullRequest = { _, _, _, _, _ in
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
    let openPullRequest = makePullRequest(
      state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let upstreamRemoteInfo = GithubRemoteInfo(
      host: "github.com", owner: "supabitapp", repo: "supacode")
    let closedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.resolveRemoteInfo = { _ in upstreamRemoteInfo }
      $0.githubCLI.closePullRequest = { _, _, number, _ in
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
      $0.gitClient.githubRemoteInfos = { _ in [] }
      $0.githubCLI.resolveRemoteInfo = { _ in nil }
      $0.pullRequestRefreshCoordinator.enqueue = { _ in
        Issue.record("Coordinator should not enqueue when GitHub remotes are unavailable")
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
      $0.continuousClock = TestClock()
      $0.githubIntegration.isAvailable = { false }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("remoteInfo should not be requested when GitHub integration is unavailable")
        return nil
      }
      $0.githubCLI.batchPullRequests = { _, _, _, _, _ in
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
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] =
        RepositoriesFeature.PendingPullRequestRefresh(
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
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] =
        RepositoriesFeature.PendingPullRequestRefresh(
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
    initialState.pendingPullRequestRefreshByRepositoryID[repository.id] =
      RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.githubRemoteInfos = { _ in [] }
      $0.githubCLI.resolveRemoteInfo = { _ in nil }
      $0.pullRequestRefreshCoordinator.enqueue = { _ in
        Issue.record("Coordinator should not enqueue when GitHub remotes are unavailable")
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
    initialState.queuedPullRequestRefreshByRepositoryID[repository.id] =
      RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }

    await store.send(.githubIntegration(.githubIntegrationAvailabilityUpdated(false))) {
      $0.githubIntegrationAvailability = .unavailable
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] =
        RepositoriesFeature.PendingPullRequestRefresh(
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
    state.pendingPullRequestRefreshByRepositoryID["repo"] =
      RepositoriesFeature.PendingPullRequestRefresh(
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
      $0.gitClient.githubRemoteInfos = { _ in [] }
      $0.githubCLI.resolveRemoteInfo = { _ in nil }
      $0.pullRequestRefreshCoordinator.enqueue = { _ in
        Issue.record("Coordinator should not enqueue when GitHub remotes are unavailable")
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

  @Test func repositoryPullRequestsLoadedPreservesMergeableWhenNewIsUnknown() async {
    let repoRoot = "/tmp/repo"
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [featureWorktree])
    let previousPR = GithubPullRequest(
      number: 1,
      title: "PR",
      state: "OPEN",
      additions: 10,
      deletions: 5,
      isDraft: false,
      reviewDecision: nil,
      mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN",
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
    var newPR = previousPR
    newPR.mergeable = "UNKNOWN"
    newPR.mergeStateStatus = "BEHIND"
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: previousPR
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [featureWorktree.id: newPR]
        ))
    )
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedPreservesMergeableButUpdatesOtherFields() async {
    let repoRoot = "/tmp/repo"
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [featureWorktree])
    let previousPR = GithubPullRequest(
      number: 1,
      title: "Old title",
      state: "OPEN",
      additions: 10,
      deletions: 5,
      isDraft: false,
      reviewDecision: nil,
      mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN",
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
    let newPR = GithubPullRequest(
      number: 1,
      title: "New title",
      state: "OPEN",
      additions: 10,
      deletions: 5,
      isDraft: false,
      reviewDecision: nil,
      mergeable: "UNKNOWN",
      mergeStateStatus: "BEHIND",
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
    var expectedPR = newPR
    expectedPR.mergeable = "MERGEABLE"
    expectedPR.mergeStateStatus = "CLEAN"
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: previousPR
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [featureWorktree.id: newPR]
        ))
    ) {
      $0.worktreeInfoByID[featureWorktree.id]?.pullRequest = expectedPR
    }
  }

  @Test func repositoryPullRequestsLoadedKeepsUnknownWhenNoPreviousPR() async {
    let repoRoot = "/tmp/repo"
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [featureWorktree])
    let newPR = GithubPullRequest(
      number: 1,
      title: "PR",
      state: "OPEN",
      additions: 10,
      deletions: 5,
      isDraft: false,
      reviewDecision: nil,
      mergeable: "UNKNOWN",
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }
    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [featureWorktree.id: newPR]
        ))
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: newPR
      )
    }
  }

  @Test func repositoryPullRequestsLoadedKeepsUnknownWhenPreviousAlsoUnknown() async {
    let repoRoot = "/tmp/repo"
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [featureWorktree])
    let previousPR = GithubPullRequest(
      number: 1,
      title: "Old title",
      state: "OPEN",
      additions: 10,
      deletions: 5,
      isDraft: false,
      reviewDecision: nil,
      mergeable: "UNKNOWN",
      mergeStateStatus: "BEHIND",
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
    let newPR = GithubPullRequest(
      number: 1,
      title: "New title",
      state: "OPEN",
      additions: 10,
      deletions: 5,
      isDraft: false,
      reviewDecision: nil,
      mergeable: "UNKNOWN",
      mergeStateStatus: "BEHIND",
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: previousPR
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    await store.send(
      .githubIntegration(
        .repositoryPullRequestsLoaded(
          repositoryID: repository.id,
          pullRequestsByWorktreeID: [featureWorktree.id: newPR]
        ))
    ) {
      $0.worktreeInfoByID[featureWorktree.id]?.pullRequest = newPR
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

  @Test(.dependencies) func autoDeleteExpiredArchivedWorktreesOnlyDeletesProwlCreatedBranches()
    async
  {
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
      $0.global.deleteBranchOnAutomaticCleanup = true
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
      $0.preArchivedWorktreeID = wt1.id
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

  // MARK: - Workspace child rows

  private func makeWorkspaceRepository(
    id: String,
    children: [ProjectWorkspace.RepositoryEntry]
  ) -> Repository {
    makeRepository(
      id: id,
      name: "Workspace",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "Workspace", repositories: children)
    )
  }

  @Test func applyWorkspaceChildrenInfoWritesBranchDiffAndPR() {
    var state = RepositoriesFeature.State()
    let pullRequest = makePullRequest(state: "OPEN", headRefName: "feature")
    applyWorkspaceChildrenInfo(
      [
        WorkspaceChildInfoUpdate(
          id: "/ws/app",
          branch: "feature",
          lineChanges: GitLineChanges(added: 7, removed: 2),
          pullRequest: pullRequest
        ),
        WorkspaceChildInfoUpdate(
          id: "/ws/api",
          branch: "  ",
          lineChanges: GitLineChanges(added: 0, removed: 0),
          pullRequest: nil
        ),
      ],
      state: &state
    )

    #expect(state.workspaceChildBranchByID["/ws/app"] == "feature")
    #expect(state.workspaceChildInfoByID["/ws/app"]?.addedLines == 7)
    #expect(state.workspaceChildInfoByID["/ws/app"]?.removedLines == 2)
    #expect(state.workspaceChildInfoByID["/ws/app"]?.pullRequest == pullRequest)
    // Blank branch + empty diff + no PR → no entries.
    #expect(state.workspaceChildBranchByID["/ws/api"] == nil)
    #expect(state.workspaceChildInfoByID["/ws/api"] == nil)
  }

  @Test func workspaceChildRowsMergesLiveBranchAndInfo() {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath,
      branchName: "metadata-branch"
    )
    let repository = makeWorkspaceRepository(id: "/tmp/ws", children: [entry])
    var state = makeState(repositories: [repository])
    let childID = entry.resolvedURL(relativeTo: repository.rootURL).path(percentEncoded: false)
    state.workspaceChildBranchByID[childID] = "live-branch"
    state.workspaceChildInfoByID[childID] = WorktreeInfoEntry(
      addedLines: 3, removedLines: 1, pullRequest: nil)

    let rows = state.workspaceChildRows(in: repository)

    #expect(rows.count == 1)
    #expect(rows.first?.repositoryName == "App")
    // Live branch wins over the metadata branch.
    #expect(rows.first?.branchName == "live-branch")
    #expect(rows.first?.info?.addedLines == 3)
  }

  @Test func workspaceChildRowsFallsBackToMetadataBranch() {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .bareRepository,
      branchName: "metadata-branch"
    )
    let repository = makeWorkspaceRepository(id: "/tmp/ws2", children: [entry])
    let state = makeState(repositories: [repository])

    let rows = state.workspaceChildRows(in: repository)
    #expect(rows.first?.branchName == "metadata-branch")
    #expect(rows.first?.info == nil)
  }

  @Test func diffTargetForWorkspaceChildDiffsChildRepoAndHostsHunkInWorkspace() {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath,
      branchName: "metadata-branch"
    )
    let repository = makeWorkspaceRepository(id: "/tmp/ws-diff", children: [entry])
    var state = makeState(repositories: [repository])
    let childID = entry.resolvedURL(relativeTo: repository.rootURL).path(percentEncoded: false)
    state.workspaceChildBranchByID[childID] = "live-branch"

    let target = state.diffTarget(for: .workspaceChild(workspaceID: repository.id, path: childID))

    let childURL = URL(fileURLWithPath: childID)
    #expect(target?.id == .workspaceChild(workspaceID: repository.id, path: childID))
    #expect(target?.workingDirectory == childURL)
    // Live branch wins over the metadata branch.
    #expect(target?.branchName == "live-branch")
    #expect(target?.repositoryRootURL == childURL)
    // Hunk stays hosted in the workspace terminal, running in the child dir.
    #expect(target?.terminalHost.id == repository.id)
    #expect(target?.terminalHost.workingDirectory == repository.rootURL)
    #expect(target?.terminalWorkingDirectory == childURL)
  }

  @Test func diffTargetForWorkspaceChildFallsBackBranchToMetadataThenRepositoryName() {
    let withMetadataBranch = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath,
      branchName: "metadata-branch"
    )
    let withoutAnyBranch = ProjectWorkspace.RepositoryEntry(
      id: "api",
      name: "Api",
      path: "api",
      sourceKind: .existingPath
    )
    let repository = makeWorkspaceRepository(
      id: "/tmp/ws-diff-fallback",
      children: [withMetadataBranch, withoutAnyBranch]
    )
    let state = makeState(repositories: [repository])
    let metadataChildID = withMetadataBranch.resolvedURL(relativeTo: repository.rootURL)
      .path(percentEncoded: false)
    let namelessChildID = withoutAnyBranch.resolvedURL(relativeTo: repository.rootURL)
      .path(percentEncoded: false)

    #expect(
      state.diffTarget(
        for: .workspaceChild(workspaceID: repository.id, path: metadataChildID)
      )?.branchName == "metadata-branch"
    )
    #expect(
      state.diffTarget(
        for: .workspaceChild(workspaceID: repository.id, path: namelessChildID)
      )?.branchName == "Api"
    )
  }

  @Test func diffTargetResolvesWorktreesAndRejectsUnknownChildren() {
    let worktree = makeWorktree(id: "/tmp/repo-dt/wt", name: "feature")
    let repository = makeRepository(id: "/tmp/repo-dt", worktrees: [worktree])
    let state = makeState(repositories: [repository])

    #expect(state.diffTarget(for: .worktree(worktree.id)) == DiffTarget(worktree: worktree))
    #expect(state.diffTarget(for: .worktree("/tmp/missing")) == nil)
    #expect(
      state.diffTarget(for: .workspaceChild(workspaceID: repository.id, path: "/tmp/missing")) == nil
    )
  }

  @Test func diffTargetScopesWorkspaceChildToItsOwnWorkspace() {
    // Two workspaces referencing the same absolute child path: each target
    // must resolve within its own workspace so Hunk lands in the right
    // terminal.
    let sharedEntry = ProjectWorkspace.RepositoryEntry(
      id: "shared",
      name: "Shared",
      path: "/tmp/shared-child",
      sourceKind: .existingPath
    )
    let firstWorkspace = makeWorkspaceRepository(id: "/tmp/ws-dup-1", children: [sharedEntry])
    let secondWorkspace = makeWorkspaceRepository(id: "/tmp/ws-dup-2", children: [sharedEntry])
    let state = makeState(repositories: [firstWorkspace, secondWorkspace])
    let childID = sharedEntry.resolvedURL(relativeTo: firstWorkspace.rootURL).path(percentEncoded: false)

    let firstTarget = state.diffTarget(
      for: .workspaceChild(workspaceID: firstWorkspace.id, path: childID)
    )
    let secondTarget = state.diffTarget(
      for: .workspaceChild(workspaceID: secondWorkspace.id, path: childID)
    )

    #expect(firstTarget?.terminalHost.id == firstWorkspace.id)
    #expect(secondTarget?.terminalHost.id == secondWorkspace.id)
    #expect(firstTarget?.workingDirectory == secondTarget?.workingDirectory)
  }

  @Test func diffTargetUsesRecordedSourceRootForSettingsAndTemplates() {
    // Linked and worktree checkouts live inside the workspace folder but
    // belong to a source repository elsewhere; settings and {repoPath} must
    // follow the recorded source. Remote clones have no local source and stay
    // rooted at the checkout.
    let linkedEntry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath,
      sourceLocation: "/tmp/source-repo"
    )
    let remoteEntry = ProjectWorkspace.RepositoryEntry(
      id: "api",
      name: "Api",
      path: "api",
      sourceKind: .remote,
      sourceLocation: "https://example.com/api.git"
    )
    let repository = makeWorkspaceRepository(
      id: "/tmp/ws-roots",
      children: [linkedEntry, remoteEntry]
    )
    let state = makeState(repositories: [repository])
    let linkedChildID = linkedEntry.resolvedURL(relativeTo: repository.rootURL)
      .path(percentEncoded: false)
    let remoteChildID = remoteEntry.resolvedURL(relativeTo: repository.rootURL)
      .path(percentEncoded: false)

    let linkedTarget = state.diffTarget(
      for: .workspaceChild(workspaceID: repository.id, path: linkedChildID)
    )
    let remoteTarget = state.diffTarget(
      for: .workspaceChild(workspaceID: repository.id, path: remoteChildID)
    )

    #expect(linkedTarget?.repositoryRootURL == URL(fileURLWithPath: "/tmp/source-repo"))
    #expect(linkedTarget?.workingDirectory == URL(fileURLWithPath: linkedChildID))
    #expect(remoteTarget?.repositoryRootURL == URL(fileURLWithPath: remoteChildID))
  }

  @Test func pruneClearsSelectedChildRemovedFromItsWorkspaceDespiteDuplicatePath() {
    // Two workspaces reference the same absolute child path. Removing the
    // child from the selected workspace must clear the selection even though
    // the path stays globally valid through the other workspace — otherwise
    // View/Palette advertise Diff for a target that resolves to nil.
    let sharedEntry = ProjectWorkspace.RepositoryEntry(
      id: "shared",
      name: "Shared",
      path: "/tmp/shared-prune-child",
      sourceKind: .existingPath
    )
    let selectedWorkspace = makeWorkspaceRepository(id: "/tmp/ws-prune-1", children: [sharedEntry])
    let otherWorkspace = makeWorkspaceRepository(id: "/tmp/ws-prune-2", children: [sharedEntry])
    var state = makeState(repositories: [selectedWorkspace, otherWorkspace])
    let childID = sharedEntry.resolvedURL(relativeTo: selectedWorkspace.rootURL)
      .path(percentEncoded: false)
    state.selection = .repository(selectedWorkspace.id)
    state.selectedWorkspaceChildID = childID

    // Reload with the child still present: selection survives.
    pruneWorkspaceChildInfo(state: &state)
    #expect(state.selectedWorkspaceChildID == childID)

    // Reload after the child was removed from the selected workspace only.
    let emptiedWorkspace = makeWorkspaceRepository(id: "/tmp/ws-prune-1", children: [])
    state.repositories = [emptiedWorkspace, otherWorkspace]
    pruneWorkspaceChildInfo(state: &state)
    #expect(state.selectedWorkspaceChildID == nil)
    #expect(state.selectedDiffTargetID == nil)
  }

  @Test func pullRequestForDiffTargetDispatchesToTheMatchingCache() {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath
    )
    let workspace = makeWorkspaceRepository(id: "/tmp/ws-pr", children: [entry])
    let worktree = makeWorktree(id: "/tmp/repo-pr/wt", name: "feature")
    let repository = makeRepository(id: "/tmp/repo-pr", worktrees: [worktree])
    var state = makeState(repositories: [repository, workspace])
    let childID = entry.resolvedURL(relativeTo: workspace.rootURL).path(percentEncoded: false)
    let worktreePR = makePullRequest(state: "OPEN", headRefName: "feature", number: 1)
    let childPR = makePullRequest(state: "OPEN", headRefName: "child-branch", number: 2)
    state.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(pullRequest: worktreePR)
    state.workspaceChildInfoByID[childID] = WorktreeInfoEntry(pullRequest: childPR)

    #expect(state.pullRequest(for: .worktree(worktree.id)) == worktreePR)
    #expect(
      state.pullRequest(for: .workspaceChild(workspaceID: workspace.id, path: childID)) == childPR
    )
    #expect(state.pullRequest(for: .worktree("/tmp/missing")) == nil)
  }

  @Test func selectedDiffTargetIDFollowsWorktreeThenWorkspaceChild() {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath
    )
    let workspace = makeWorkspaceRepository(id: "/tmp/ws-selected", children: [entry])
    let worktree = makeWorktree(id: "/tmp/repo-sel/wt", name: "alpha")
    let repository = makeRepository(id: "/tmp/repo-sel", worktrees: [worktree])
    var state = makeState(repositories: [repository, workspace])
    let childID = entry.resolvedURL(relativeTo: workspace.rootURL).path(percentEncoded: false)

    state.selection = .worktree(worktree.id)
    #expect(state.selectedDiffTargetID == .worktree(worktree.id))

    state.selection = .repository(workspace.id)
    state.selectedWorkspaceChildID = childID
    #expect(state.selectedDiffTargetID == .workspaceChild(workspaceID: workspace.id, path: childID))

    // A stale child id must not leak once a non-workspace repository is selected.
    state.selection = .repository(repository.id)
    #expect(state.selectedDiffTargetID == nil)

    state.selection = .repository(workspace.id)
    state.selectedWorkspaceChildID = nil
    #expect(state.selectedDiffTargetID == nil)
  }

  @Test func openWorkspaceChildFocusesOrCreatesBoundTerminalTabInChildDirectory() async {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath
    )
    let repository = makeWorkspaceRepository(id: "/tmp/ws-open-child", children: [entry])
    let childID = entry.resolvedURL(relativeTo: repository.rootURL).path(percentEncoded: false)
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.openWorkspaceChild(childID)) {
      $0.selection = .repository(repository.id)
      $0.selectedWorkspaceChildID = childID
      $0.openedWorktreeIDs = [repository.id]
      $0.pendingTerminalFocusWorktreeIDs = [repository.id]
    }
    await store.finish()

    let workspaceWorktree = Worktree(
      id: repository.id,
      name: repository.name,
      detail: repository.rootURL.path(percentEncoded: false),
      workingDirectory: repository.rootURL,
      repositoryRootURL: repository.rootURL
    )
    #expect(
      sentCommands.value == [
        .focusOrCreateTabInDirectory(
          workspaceWorktree,
          directory: URL(fileURLWithPath: childID),
          title: "App"
        )
      ])
  }

  @Test func repositoriesLoadedRefreshesAndPrunesWorkspaceChildren() async {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath,
      branchName: "metadata"
    )
    let repository = makeWorkspaceRepository(id: "/tmp/ws-refresh", children: [entry])
    let childID = entry.resolvedURL(relativeTo: repository.rootURL).path(percentEncoded: false)
    var initialState = makeState(repositories: [repository])
    // A stale child entry from a workspace that no longer exists must be pruned.
    initialState.workspaceChildInfoByID["/tmp/gone/app"] = WorktreeInfoEntry(
      addedLines: 1,
      removedLines: 1,
      pullRequest: nil
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.branchName = { _ in "feature/live" }
      $0.gitClient.lineChanges = { _ in
        GitLineChanges(added: 7, removed: 2, skippedUntrackedFileCount: 1)
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded([repository], failures: [], roots: [repository.rootURL], animated: false)
    )
    await store.receive(\.workspaceChildrenInfoLoaded)
    await store.finish()

    #expect(store.state.workspaceChildInfoByID["/tmp/gone/app"] == nil)
    #expect(store.state.workspaceChildBranchByID[childID] == "feature/live")
    #expect(store.state.workspaceChildInfoByID[childID]?.addedLines == 7)
    #expect(store.state.workspaceChildInfoByID[childID]?.removedLines == 2)
    #expect(store.state.workspaceChildInfoByID[childID]?.skippedUntrackedFileCount == 1)
  }

  @Test func workspaceChildrenInfoLoadedIgnoresUpdatesForRemovedChildren() async {
    // An in-flight refresh can land after a reload removed its child; the
    // stale update must not repopulate the just-pruned maps.
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath
    )
    let repository = makeWorkspaceRepository(id: "/tmp/ws-stale", children: [entry])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(
      .workspaceChildrenInfoLoaded([
        WorkspaceChildInfoUpdate(
          id: "/tmp/ws-removed/app",
          branch: "stale",
          lineChanges: GitLineChanges(added: 1, removed: 1),
          pullRequest: nil
        )
      ])
    )

    #expect(store.state.workspaceChildBranchByID.isEmpty)
    #expect(store.state.workspaceChildInfoByID.isEmpty)
  }

  @Test func openRepositoriesFinishedRefreshesWorkspaceChildren() async {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath,
      branchName: "metadata"
    )
    let repository = makeWorkspaceRepository(id: "/tmp/ws-open-refresh", children: [entry])
    let childID = entry.resolvedURL(relativeTo: repository.rootURL).path(percentEncoded: false)
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.branchName = { _ in "feature/live" }
      $0.gitClient.lineChanges = { _ in nil }
      $0.gitClient.remoteInfo = { _ in nil }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [repository],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [repository.rootURL]
        ))
    ) {
      $0.repositories = [repository]
      $0.repositoryRoots = [repository.rootURL]
      $0.isInitialLoadComplete = true
      $0.snapshotPersistencePhase = .active
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.workspaceChildrenInfoLoaded) {
      $0.workspaceChildBranchByID = [childID: "feature/live"]
    }
    await store.finish()
  }

  @Test func workspaceChildRefreshLoadsPullRequestWhenGithubIntegrationAvailable() async {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath,
      branchName: "metadata"
    )
    let repository = makeWorkspaceRepository(id: "/tmp/ws-pr", children: [entry])
    let childID = entry.resolvedURL(relativeTo: repository.rootURL).path(percentEncoded: false)
    let pullRequest = makePullRequest(state: "OPEN", headRefName: "feature/live", number: 42)
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    struct PullRequestBatchCall: Equatable, Sendable {
      let host: String
      let owner: String
      let repo: String
      let branches: [String]
    }
    let calls = LockIsolated<[PullRequestBatchCall]>([])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.branchName = { _ in "feature/live" }
      $0.gitClient.lineChanges = { _ in nil }
      $0.gitClient.remoteInfo = { url in
        #expect(url.path(percentEncoded: false) == childID)
        return GithubRemoteInfo(host: "github.com", owner: "onevcat", repo: "app")
      }
      $0.githubCLI.batchPullRequests = { host, owner, repo, branches, accountOverride in
        #expect(accountOverride == nil)
        calls.withValue {
          $0.append(
            PullRequestBatchCall(host: host, owner: owner, repo: repo, branches: branches))
        }
        return ["feature/live": pullRequest]
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded([repository], failures: [], roots: [repository.rootURL], animated: false)
    )
    await store.receive(\.workspaceChildrenInfoLoaded)
    await store.finish()

    #expect(calls.value.count == 1)
    #expect(calls.value.first?.host == "github.com")
    #expect(calls.value.first?.owner == "onevcat")
    #expect(calls.value.first?.repo == "app")
    #expect(calls.value.first?.branches == ["feature/live"])
    #expect(store.state.workspaceChildInfoByID[childID]?.pullRequest == pullRequest)
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

  private func makePullRequestURLRemoteInfoFixture(repoRoot: String) -> PullRequestURLRemoteInfoFixture {
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
      number: 456,
      url: "https://github.com/onevcat/Prowl/pull/456"
    )
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: pullRequest
    )
    return PullRequestURLRemoteInfoFixture(
      featureWorktree: featureWorktree,
      state: state,
      expectedRemoteInfo: GithubRemoteInfo(host: "github.com", owner: "onevcat", repo: "Prowl")
    )
  }

  private struct PullRequestURLRemoteInfoFixture {
    let featureWorktree: Worktree
    let state: RepositoriesFeature.State
    let expectedRemoteInfo: GithubRemoteInfo
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
    let clock = TestClock()
    let fetchStarted = AsyncGate()
    let startedRoots = LockIsolated<Set<String>>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRootA, repoRootB] }
      $0.gitClient.worktrees = { root in
        let path = root.path(percentEncoded: false)
        _ = startedRoots.withValue { $0.insert(path) }
        await fetchStarted.resume()
        if path == repoRootA {
          try? await clock.sleep(for: .seconds(1))
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
    await fetchStarted.wait()
    await clock.advance()
    #expect(startedRoots.value == [repoRootA, repoRootB])
    await clock.advance(by: .seconds(1))

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

// The collision-free base path seeded synchronously by `.promptRequested`
// before the unique-path effect resolves (no filesystem lookup).
func defaultWorkspaceBaseRootPath(for title: String) -> String {
  let folderName = ProjectWorkspace.defaultWorkspaceFolderName(for: title)
  return SupacodePaths.workspacesDirectory
    .appending(path: folderName, directoryHint: .isDirectory)
    .standardizedFileURL
    .path(percentEncoded: false)
}

func expectedDefaultWorkspaceRootPath(for title: String) -> String {
  let folderName = ProjectWorkspace.defaultWorkspaceFolderName(for: title)
  return ProjectWorkspace.uniqueWorkspaceRootPath(folderName: folderName)
}
