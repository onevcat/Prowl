import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct BatchedPullRequestRefreshReducerTests {
  @Test func refreshDispatchesViaCoordinatorUsingCurrentRemoteInfos() async {
    let context = makeContext()
    let enqueued = LockIsolated<[PullRequestRefreshCoordinator.Request]>([])
    let upstreamInfo = GithubRemoteInfo(host: "github.com", owner: "khoi", repo: "upstream")

    let store = TestStore(initialState: context.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.githubRemoteInfos = { _ in [context.remoteInfo, upstreamInfo] }
      $0.githubCLI.resolveRemoteInfo = { _ in
        Issue.record("gh resolveRemoteInfo should not run when git remotes resolve")
        return nil
      }
      $0.githubCLI.batchPullRequests = { _, _, _, _, _ in
        Issue.record("Legacy batchPullRequests should not run on coordinator path")
        return [:]
      }
      $0.pullRequestRefreshCoordinator = PullRequestRefreshCoordinatorClient(
        enqueue: { request in
          enqueued.withValue { $0.append(request) }
        },
        cancelHost: { _ in },
        reset: {}
      )
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    }
    await store.receive(\.githubIntegration.pullRequestRefreshBatchCountResolved) {
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 1
      $0.prRefreshRemotePrioritiesByRepositoryID[context.repository.id] = [
        "github.com/khoi/alpha": 0,
        "github.com/khoi/upstream": 1,
      ]
    }
    await store.finish()

    let snapshot = enqueued.value
    #expect(snapshot.count == 1)
    let request = snapshot[0]
    #expect(request.host == "github.com")
    #expect(request.repositories == [context.remoteInfo, upstreamInfo])
    #expect(request.branches == ["main", "feature"])
  }

  @Test func refreshWaitsForAllHostBatchesBeforeCompleting() async {
    let context = makeContext()
    let enqueued = LockIsolated<[PullRequestRefreshCoordinator.Request]>([])
    let githubPullRequest = makePullRequestFixture()
    let enterpriseInfo = GithubRemoteInfo(host: "ghe.example", owner: "khoi", repo: "alpha")

    let store = TestStore(initialState: context.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.githubRemoteInfos = { _ in [context.remoteInfo, enterpriseInfo] }
      $0.pullRequestRefreshCoordinator = PullRequestRefreshCoordinatorClient(
        enqueue: { request in
          enqueued.withValue { $0.append(request) }
        },
        cancelHost: { _ in },
        reset: {}
      )
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    }
    await store.receive(\.githubIntegration.pullRequestRefreshBatchCountResolved) {
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 2
      $0.prRefreshRemotePrioritiesByRepositoryID[context.repository.id] = [
        "ghe.example/khoi/alpha": 1,
        "github.com/khoi/alpha": 0,
      ]
    }

    #expect(Set(enqueued.value.map(\.host)) == ["github.com", "ghe.example"])

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .refreshed(
            repositoryID: context.repository.id,
            repositoryRootURL: context.repoRootURL,
            worktreeIDs: context.worktreeIDs,
            prsByBranch: ["feature": githubPullRequest],
            confirmedNoPrBranches: []
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 1
      $0.prRefreshResultsByRepositoryID[context.repository.id] = ["feature": githubPullRequest]
      $0.prRefreshNoPrBranchesByID[context.repository.id] = []
      $0.prRefreshResultPrioritiesByRepositoryID[context.repository.id] = ["feature": .max]
    }

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .refreshed(
            repositoryID: context.repository.id,
            repositoryRootURL: context.repoRootURL,
            worktreeIDs: context.worktreeIDs,
            prsByBranch: [:],
            confirmedNoPrBranches: []
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID = [:]
      $0.prRefreshResultsByRepositoryID = [:]
      $0.prRefreshNoPrBranchesByID = [:]
      $0.prRefreshResultPrioritiesByRepositoryID = [:]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded) {
      var entry = WorktreeInfoEntry()
      entry.pullRequest = githubPullRequest
      $0.worktreeInfoByID[context.featureWorktree.id] = entry
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.prRefreshBatchCountsByRepositoryID = [:]
      $0.prRefreshRemotePrioritiesByRepositoryID = [:]
    }
    await store.finish()
  }

  @Test func refreshPrefersHigherPriorityRemoteWhenHostBatchResultsRace() async {
    let context = makeContext()
    let enqueued = LockIsolated<[PullRequestRefreshCoordinator.Request]>([])
    let enterpriseInfo = GithubRemoteInfo(host: "github.enterprise.test", owner: "khoi", repo: "alpha")
    let enterprisePullRequest = makePullRequestFixture(
      title: "Enterprise PR",
      url: "https://github.enterprise.test/khoi/alpha/pull/8"
    )
    let originPullRequest = makePullRequestFixture(
      title: "Origin PR",
      url: "https://github.com/khoi/alpha/pull/7"
    )

    let store = TestStore(initialState: context.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.githubRemoteInfos = { _ in [context.remoteInfo, enterpriseInfo] }
      $0.pullRequestRefreshCoordinator = PullRequestRefreshCoordinatorClient(
        enqueue: { request in
          enqueued.withValue { $0.append(request) }
        },
        cancelHost: { _ in },
        reset: {}
      )
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    }
    await store.receive(\.githubIntegration.pullRequestRefreshBatchCountResolved) {
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 2
      $0.prRefreshRemotePrioritiesByRepositoryID[context.repository.id] = [
        "github.com/khoi/alpha": 0,
        "github.enterprise.test/khoi/alpha": 1,
      ]
    }

    #expect(Set(enqueued.value.map(\.host)) == ["github.com", "github.enterprise.test"])

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .refreshed(
            repositoryID: context.repository.id,
            repositoryRootURL: context.repoRootURL,
            worktreeIDs: context.worktreeIDs,
            prsByBranch: ["feature": enterprisePullRequest],
            confirmedNoPrBranches: []
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 1
      $0.prRefreshResultsByRepositoryID[context.repository.id] = ["feature": enterprisePullRequest]
      $0.prRefreshNoPrBranchesByID[context.repository.id] = []
      $0.prRefreshResultPrioritiesByRepositoryID[context.repository.id] = ["feature": 1]
    }

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .refreshed(
            repositoryID: context.repository.id,
            repositoryRootURL: context.repoRootURL,
            worktreeIDs: context.worktreeIDs,
            prsByBranch: ["feature": originPullRequest],
            confirmedNoPrBranches: []
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID = [:]
      $0.prRefreshResultsByRepositoryID = [:]
      $0.prRefreshNoPrBranchesByID = [:]
      $0.prRefreshResultPrioritiesByRepositoryID = [:]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded) {
      var entry = WorktreeInfoEntry()
      entry.pullRequest = originPullRequest
      $0.worktreeInfoByID[context.featureWorktree.id] = entry
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.prRefreshBatchCountsByRepositoryID = [:]
      $0.prRefreshRemotePrioritiesByRepositoryID = [:]
    }
    await store.finish()
  }

  @Test func refreshResolvesRemoteInfosOnFirstRun() async {
    let context = makeContext()
    let enqueued = LockIsolated<[PullRequestRefreshCoordinator.Request]>([])
    let initialState = context.state

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.githubRemoteInfos = { _ in [context.remoteInfo] }
      $0.githubCLI.resolveRemoteInfo = { _ in
        Issue.record("gh resolveRemoteInfo should not run when git remotes resolve")
        return nil
      }
      $0.pullRequestRefreshCoordinator = PullRequestRefreshCoordinatorClient(
        enqueue: { request in
          enqueued.withValue { $0.append(request) }
        },
        cancelHost: { _ in },
        reset: {}
      )
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    }
    await store.receive(\.githubIntegration.pullRequestRefreshBatchCountResolved) {
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 1
      $0.prRefreshRemotePrioritiesByRepositoryID[context.repository.id] = [
        "github.com/khoi/alpha": 0
      ]
    }
    await store.finish()

    #expect(enqueued.value.count == 1)
  }

  @Test func refreshPreservesPullRequestsWhenGithubRemotesUnavailable() async {
    let context = makeContext()
    let enqueued = LockIsolated<[PullRequestRefreshCoordinator.Request]>([])
    let stalePullRequest = makePullRequestFixture(url: "https://github.com/khoi/alpha/pull/7")
    var initialState = context.state
    var staleEntry = WorktreeInfoEntry()
    staleEntry.pullRequest = stalePullRequest
    initialState.worktreeInfoByID[context.featureWorktree.id] = staleEntry

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.githubRemoteInfos = { _ in [] }
      $0.githubCLI.resolveRemoteInfo = { _ in nil }
      $0.pullRequestRefreshCoordinator = PullRequestRefreshCoordinatorClient(
        enqueue: { request in
          enqueued.withValue { $0.append(request) }
        },
        cancelHost: { _ in },
        reset: {}
      )
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()

    #expect(enqueued.value.isEmpty)
  }

  @Test func coordinatorOutcomeRefreshedTranslatesToLoadedAndCompleted() async {
    let context = makeContext()
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    let pullRequest = makePullRequestFixture()
    let outcome = PullRequestRefreshCoordinator.Outcome.refreshed(
      repositoryID: context.repository.id,
      repositoryRootURL: context.repoRootURL,
      worktreeIDs: context.worktreeIDs,
      prsByBranch: ["feature": pullRequest],
      confirmedNoPrBranches: []
    )

    await store.send(.githubIntegration(.pullRequestRefreshBatchOutcome(outcome)))
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded) {
      var entry = WorktreeInfoEntry()
      entry.pullRequest = pullRequest
      $0.worktreeInfoByID[context.featureWorktree.id] = entry
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func coordinatorOutcomeFailedClearsInFlight() async {
    let context = makeContext()
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    let outcome = PullRequestRefreshCoordinator.Outcome.failed(
      repositoryID: context.repository.id,
      worktreeIDs: context.worktreeIDs,
      message: "boom"
    )

    await store.send(.githubIntegration(.pullRequestRefreshBatchOutcome(outcome)))
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func coordinatorOutcomeConfirmedNoPrClearsStalePullRequest() async {
    let context = makeContext()
    let stalePullRequest = makePullRequestFixture(url: "https://github.com/khoi/alpha/pull/7")
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    var staleEntry = WorktreeInfoEntry()
    staleEntry.pullRequest = stalePullRequest
    initialState.worktreeInfoByID[context.featureWorktree.id] = staleEntry

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    let outcome = PullRequestRefreshCoordinator.Outcome.refreshed(
      repositoryID: context.repository.id,
      repositoryRootURL: context.repoRootURL,
      worktreeIDs: context.worktreeIDs,
      prsByBranch: [:],
      confirmedNoPrBranches: ["feature"]
    )

    await store.send(.githubIntegration(.pullRequestRefreshBatchOutcome(outcome)))
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded) {
      $0.worktreeInfoByID.removeValue(forKey: context.featureWorktree.id)
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func coordinatorOutcomeUnknownBranchStatusPreservesPullRequest() async {
    let context = makeContext()
    let stalePullRequest = makePullRequestFixture(url: "https://github.com/khoi/alpha/pull/7")
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    var staleEntry = WorktreeInfoEntry()
    staleEntry.pullRequest = stalePullRequest
    initialState.worktreeInfoByID[context.featureWorktree.id] = staleEntry

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    let outcome = PullRequestRefreshCoordinator.Outcome.refreshed(
      repositoryID: context.repository.id,
      repositoryRootURL: context.repoRootURL,
      worktreeIDs: context.worktreeIDs,
      prsByBranch: [:],
      confirmedNoPrBranches: []
    )

    await store.send(.githubIntegration(.pullRequestRefreshBatchOutcome(outcome)))
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded)
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()

    #expect(store.state.worktreeInfoByID[context.featureWorktree.id]?.pullRequest == stalePullRequest)
  }

  @Test func confirmedNoPrClearIsSuppressedWhenAnotherHostBatchFailedFirst() async {
    let context = makeContext()
    let stalePullRequest = makePullRequestFixture(url: "https://ghe.example/khoi/alpha/pull/9")
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    initialState.prRefreshBatchCountsByRepositoryID[context.repository.id] = 2
    var staleEntry = WorktreeInfoEntry()
    staleEntry.pullRequest = stalePullRequest
    initialState.worktreeInfoByID[context.featureWorktree.id] = staleEntry

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .failed(
            repositoryID: context.repository.id,
            worktreeIDs: context.worktreeIDs,
            message: "enterprise host down"
          )
        ))
    ) {
      $0.prRefreshFailedBatchRepositoryIDs = [context.repository.id]
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 1
    }

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .refreshed(
            repositoryID: context.repository.id,
            repositoryRootURL: context.repoRootURL,
            worktreeIDs: context.worktreeIDs,
            prsByBranch: [:],
            confirmedNoPrBranches: ["feature"]
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID = [:]
      $0.prRefreshFailedBatchRepositoryIDs = []
    }
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded)
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()

    #expect(store.state.worktreeInfoByID[context.featureWorktree.id]?.pullRequest == stalePullRequest)
  }

  @Test func confirmedNoPrClearIsDiscardedWhenFinalHostBatchFails() async {
    let context = makeContext()
    let stalePullRequest = makePullRequestFixture(url: "https://ghe.example/khoi/alpha/pull/9")
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    initialState.prRefreshBatchCountsByRepositoryID[context.repository.id] = 2
    var staleEntry = WorktreeInfoEntry()
    staleEntry.pullRequest = stalePullRequest
    initialState.worktreeInfoByID[context.featureWorktree.id] = staleEntry

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .refreshed(
            repositoryID: context.repository.id,
            repositoryRootURL: context.repoRootURL,
            worktreeIDs: context.worktreeIDs,
            prsByBranch: [:],
            confirmedNoPrBranches: ["feature"]
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 1
      $0.prRefreshResultsByRepositoryID[context.repository.id] = [:]
      $0.prRefreshNoPrBranchesByID[context.repository.id] = ["feature"]
      $0.prRefreshResultPrioritiesByRepositoryID[context.repository.id] = [:]
    }

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .failed(
            repositoryID: context.repository.id,
            worktreeIDs: context.worktreeIDs,
            message: "enterprise host down"
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID = [:]
      $0.prRefreshResultsByRepositoryID = [:]
      $0.prRefreshNoPrBranchesByID = [:]
      $0.prRefreshResultPrioritiesByRepositoryID = [:]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()

    #expect(store.state.worktreeInfoByID[context.featureWorktree.id]?.pullRequest == stalePullRequest)
  }

  @Test func pullRequestFromLaterHostBatchOverridesEarlierConfirmedNoPr() async {
    let context = makeContext()
    let pullRequest = makePullRequestFixture()
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    initialState.prRefreshBatchCountsByRepositoryID[context.repository.id] = 2

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .refreshed(
            repositoryID: context.repository.id,
            repositoryRootURL: context.repoRootURL,
            worktreeIDs: context.worktreeIDs,
            prsByBranch: [:],
            confirmedNoPrBranches: ["feature"]
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID[context.repository.id] = 1
      $0.prRefreshResultsByRepositoryID[context.repository.id] = [:]
      $0.prRefreshNoPrBranchesByID[context.repository.id] = ["feature"]
      $0.prRefreshResultPrioritiesByRepositoryID[context.repository.id] = [:]
    }

    await store.send(
      .githubIntegration(
        .pullRequestRefreshBatchOutcome(
          .refreshed(
            repositoryID: context.repository.id,
            repositoryRootURL: context.repoRootURL,
            worktreeIDs: context.worktreeIDs,
            prsByBranch: ["feature": pullRequest],
            confirmedNoPrBranches: []
          )
        ))
    ) {
      $0.prRefreshBatchCountsByRepositoryID = [:]
      $0.prRefreshResultsByRepositoryID = [:]
      $0.prRefreshNoPrBranchesByID = [:]
      $0.prRefreshResultPrioritiesByRepositoryID = [:]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded) {
      var entry = WorktreeInfoEntry()
      entry.pullRequest = pullRequest
      $0.worktreeInfoByID[context.featureWorktree.id] = entry
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test(.dependencies) func refreshSkippedWhenPullRequestStateFetchDisabled() async {
    let context = makeContext()
    let enqueued = LockIsolated<[PullRequestRefreshCoordinator.Request]>([])

    @Shared(.repositorySettings(context.repoRootURL)) var repositorySettings
    $repositorySettings.withLock { $0.fetchPullRequestState = false }

    let store = TestStore(initialState: context.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = PullRequestRefreshCoordinatorClient(
        enqueue: { request in
          enqueued.withValue { $0.append(request) }
        },
        cancelHost: { _ in },
        reset: {}
      )
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested)
    await store.finish()

    #expect(enqueued.value.isEmpty)
  }
}

// MARK: - Fixtures

@MainActor
private func makeContext() -> RefreshTestContext {
  let repoRoot = "/tmp/coord-repo-\(UUID().uuidString)"
  let mainWorktree = Worktree(
    id: repoRoot,
    name: "main",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: repoRoot),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
  let featureWorktree = Worktree(
    id: "\(repoRoot)/feature",
    name: "feature",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "\(repoRoot)/feature"),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
  let repository = Repository(
    id: repoRoot,
    rootURL: URL(fileURLWithPath: repoRoot),
    name: "alpha",
    worktrees: IdentifiedArrayOf(uniqueElements: [mainWorktree, featureWorktree])
  )
  var state = RepositoriesFeature.State()
  state.repositories = [repository]
  state.repositoryRoots = [repository.rootURL]
  state.githubIntegrationAvailability = .available
  return RefreshTestContext(
    repoRoot: repoRoot,
    repository: repository,
    mainWorktree: mainWorktree,
    featureWorktree: featureWorktree,
    remoteInfo: GithubRemoteInfo(host: "github.com", owner: "khoi", repo: "alpha"),
    state: state
  )
}

@MainActor
private struct RefreshTestContext {
  let repoRoot: String
  let repository: Repository
  let mainWorktree: Worktree
  let featureWorktree: Worktree
  let remoteInfo: GithubRemoteInfo
  let state: RepositoriesFeature.State

  var repoRootURL: URL { URL(fileURLWithPath: repoRoot) }
  var worktreeIDs: [Worktree.ID] { [mainWorktree.id, featureWorktree.id] }
}

nonisolated private func makePullRequestFixture(
  title: String = "Coord PR",
  url: String = "https://example.com/coord-pr/7"
) -> GithubPullRequest {
  GithubPullRequest(
    number: 7,
    title: title,
    state: "OPEN",
    additions: 0,
    deletions: 0,
    isDraft: false,
    reviewDecision: nil,
    mergeable: nil,
    mergeStateStatus: nil,
    updatedAt: nil,
    url: url,
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: nil
  )
}
