import Clocks
import Foundation
import Testing

@testable import Prowl

// Serialized: these tests drive TestClock-backed debounce and timeout tasks.
// Running them in parallel can race clock advancement ahead of task suspension
// under full-suite load, causing the queued refresh work to never flush.
@MainActor
@Suite(.serialized)
struct PullRequestRefreshCoordinatorTests {
  @Test func enqueueCoalescesMultipleReposIntoSingleBatchAfterDebounce() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha"))
    coordinator.enqueue(request(repo: "beta"))
    coordinator.enqueue(request(repo: "gamma"))

    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 1 }
    await waitUntil { await outcomes.refreshedRepositories().count == 3 }

    let batchedCalls = await probe.batchedCalls()
    #expect(batchedCalls.count == 1)
    #expect(batchedCalls.first?.requests.count == 3)
    let refreshed = await outcomes.refreshedRepositories()
    #expect(Set(refreshed) == Set(["alpha", "beta", "gamma"]))
  }

  @Test func enqueueDoesNotFlushBeforeDebounceWindow() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha"))
    await advanceCoordinatorClock(clock, by: .milliseconds(100))
    await Task.yield()

    #expect(await probe.batchedCalls().isEmpty)
  }

  @Test func multipleHostsTriggerIndependentBatches() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha", host: "github.com"))
    coordinator.enqueue(request(repo: "beta", host: "github.com"))
    coordinator.enqueue(request(repo: "gamma", host: "ghe.example"))

    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 2 }

    let calls = await probe.batchedCalls()
    #expect(calls.count == 2)
    let hosts = Set(calls.map(\.host))
    #expect(hosts == ["github.com", "ghe.example"])
  }

  @Test func sameHostWithDifferentAccountsTriggersIndependentBatches() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(
      request(repo: "alpha", accountOverride: GithubAccountOverride(host: "github.com", login: "one")))
    coordinator.enqueue(request(repo: "beta", accountOverride: GithubAccountOverride(host: "github.com", login: "two")))

    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 2 }

    let calls = await probe.batchedCalls()
    #expect(calls.count == 2)
    #expect(Set(calls.compactMap(\.accountOverride?.login)) == ["one", "two"])
  }

  @Test func partialErrorTriggersPerRepoFallback() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var success: [RepoKey: [String: GithubPullRequest]] = [:]
        var failed: [RepoKey: GithubCLIError] = [:]
        for request in requests {
          let key = RepoKey(owner: request.owner, repo: request.repo)
          if request.repo == "beta" {
            failed[key] = .commandFailed("not found")
          } else {
            success[key] = [:]
          }
        }
        return CrossRepoPullRequestResult(successByRepo: success, failedRepos: failed)
      },
      legacy: { _, _, repo, _ in
        ["legacy-branch": makeFixturePullRequest(repo: repo)]
      }
    )

    coordinator.enqueue(request(repo: "alpha"))
    coordinator.enqueue(request(repo: "beta"))

    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.legacyCalls().count == 1 }
    await waitUntil { await outcomes.refreshedRepositories().count == 2 }

    let legacyCalls = await probe.legacyCalls()
    #expect(legacyCalls.count == 1)
    #expect(legacyCalls.first?.repo == "beta")
    let refreshed = await outcomes.refreshedRepositories()
    #expect(Set(refreshed) == ["alpha", "beta"])
  }

  @Test func batchedThrowFallsBackAllReposToLegacy() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, _ in
        throw GithubCLIError.commandFailed("network down")
      },
      legacy: { _, _, _, _ in
        [:]
      }
    )

    coordinator.enqueue(request(repo: "alpha"))
    coordinator.enqueue(request(repo: "beta"))

    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.legacyCalls().count == 2 }

    let legacyCalls = await probe.legacyCalls()
    #expect(Set(legacyCalls.map(\.repo)) == ["alpha", "beta"])
  }

  @Test func legacyFailureSurfacesAsFailedOutcome() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, _ in
        throw GithubCLIError.commandFailed("offline")
      },
      legacy: { _, _, _, _ in
        throw GithubCLIError.commandFailed("legacy down too")
      }
    )

    coordinator.enqueue(request(repo: "alpha"))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await outcomes.failedRepositories().count == 1 }

    let failed = await outcomes.failedRepositories()
    #expect(failed == ["alpha"])
  }

  @Test func detailBranchesReachTheBatchedQuery() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha", branches: ["feat-1", "feat-2"]))
    coordinator.enqueue(
      PullRequestRefreshCoordinator.Request(
        repositoryID: "alpha",
        repositoryRootURL: URL(fileURLWithPath: "/tmp/alpha"),
        host: "github.com",
        owner: "khoi",
        repo: "alpha",
        accountOverride: nil,
        branches: ["feat-2"],
        worktreeIDs: ["alpha-wt"],
        detailBranches: ["feat-2"]
      )
    )
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 1 }

    let call = try #require(await probe.batchedCalls().first)
    #expect(call.requests.map(\.detailBranches) == [["feat-2"]])
  }

  @Test func fallbackKeepsDetailBranches() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, _ in
        throw GithubCLIError.commandFailed("network down")
      }
    )

    coordinator.enqueue(
      PullRequestRefreshCoordinator.Request(
        repositoryID: "alpha",
        repositoryRootURL: URL(fileURLWithPath: "/tmp/alpha"),
        host: "github.com",
        owner: "khoi",
        repo: "alpha",
        accountOverride: nil,
        branches: ["feat-1", "feat-2"],
        worktreeIDs: ["alpha-wt"],
        detailBranches: ["feat-2"]
      )
    )
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.legacyCalls().count == 1 }

    #expect(await probe.legacyCalls().map(\.detailBranches) == [["feat-2"]])
  }

  @Test func rateLimitedBatchSkipsFallback() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let retryAt = Date(timeIntervalSince1970: 1_000_060)
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, _ in
        throw GithubCLIError.rateLimited(retryAt: retryAt)
      },
      legacy: { _, _, _, _ in
        Issue.record("A rate-limited batch must not fall back to per-repository queries")
        return [:]
      }
    )

    coordinator.enqueue(request(repo: "alpha"))
    coordinator.enqueue(request(repo: "beta"))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await outcomes.failedRepositories().count == 2 }

    #expect(await probe.legacyCalls().isEmpty)
    #expect(Set(await outcomes.failedRepositories()) == ["alpha", "beta"])
  }

  @Test func rateLimitedRepositoryInPartialResultSkipsFallback() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var success: [RepoKey: [String: GithubPullRequest]] = [:]
        var failed: [RepoKey: GithubCLIError] = [:]
        for request in requests {
          let key = RepoKey(owner: request.owner, repo: request.repo)
          switch request.repo {
          case "beta":
            failed[key] = .rateLimited(retryAt: Date(timeIntervalSince1970: 1_000_060))
          case "gamma":
            failed[key] = .commandFailed("not found")
          default:
            success[key] = [:]
          }
        }
        return CrossRepoPullRequestResult(successByRepo: success, failedRepos: failed)
      },
      legacy: { _, _, _, _ in [:] }
    )

    coordinator.enqueue(request(repo: "alpha"))
    coordinator.enqueue(request(repo: "beta"))
    coordinator.enqueue(request(repo: "gamma"))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await outcomes.snapshot().count == 3 }

    #expect(await probe.legacyCalls().map(\.repo) == ["gamma"])
  }

  @Test func permanentGraphQLErrorInPartialResultSkipsFallback() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var success: [RepoKey: [String: GithubPullRequest]] = [:]
        var failed: [RepoKey: GithubCLIError] = [:]
        for request in requests {
          let key = RepoKey(owner: request.owner, repo: request.repo)
          switch request.repo {
          case "beta":
            // GitHub answered: the repository does not exist for this account.
            failed[key] = .graphQLError(type: "NOT_FOUND", message: "Could not resolve to a Repository")
          case "gamma":
            // No type: GitHub may have timed out on this alias, so a smaller query is worth a try.
            failed[key] = .graphQLError(type: nil, message: "Something went wrong while executing your query")
          default:
            success[key] = [:]
          }
        }
        return CrossRepoPullRequestResult(successByRepo: success, failedRepos: failed)
      },
      legacy: { _, _, _, _ in [:] }
    )

    coordinator.enqueue(request(repo: "alpha"))
    coordinator.enqueue(request(repo: "beta"))
    coordinator.enqueue(request(repo: "gamma"))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await outcomes.snapshot().count == 3 }

    #expect(await probe.legacyCalls().map(\.repo) == ["gamma"])
    #expect(Set(await outcomes.failedRepositories()) == ["beta"])
  }

  @Test func inflightHostBuffersNewEnqueueAndFlushesAfterCompletion() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let release = AsyncStreamFlag()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        await release.wait()
        return successResult(for: requests)
      }
    )

    coordinator.enqueue(request(repo: "alpha"))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 1 }

    coordinator.enqueue(request(repo: "beta"))
    await Task.yield()
    #expect(await probe.batchedCalls().count == 1)

    await release.signal()
    await waitUntil { await probe.batchedCalls().count == 2 }
    let calls = await probe.batchedCalls()
    #expect(calls.last?.requests.map(\.repo) == ["beta"])
  }

  @Test func enqueueIgnoresEmptyBranches() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha", branches: []))
    coordinator.enqueue(request(repo: "beta", branches: ["", "   "]))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await Task.yield()

    #expect(await probe.batchedCalls().isEmpty)
  }

  @Test func enqueueMergesBranchListsForSameRepositoryWithinWindow() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha", branches: ["feat-1"]))
    coordinator.enqueue(request(repo: "alpha", branches: ["feat-2", "feat-1"]))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 1 }

    let calls = await probe.batchedCalls()
    #expect(calls.count == 1)
    let alphaRequest = try #require(calls.first?.requests.first { $0.repo == "alpha" })
    #expect(Set(alphaRequest.branches) == ["feat-1", "feat-2"])
  }

  @Test func duplicateRepoKeysBatchOnceAndFanOutToEachRepository() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var dict: [RepoKey: [String: GithubPullRequest]] = [:]
        for request in requests {
          dict[request.key] = [
            "feat-1": makeFixturePullRequest(repo: request.repo),
            "feat-2": makeFixturePullRequest(repo: request.repo),
          ]
        }
        return CrossRepoPullRequestResult(successByRepo: dict)
      }
    )

    coordinator.enqueue(
      request(repo: "alpha", repositoryID: "alpha-a", branches: ["feat-1"])
    )
    coordinator.enqueue(
      request(repo: "alpha", repositoryID: "alpha-b", branches: ["feat-2"])
    )
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 1 }
    await waitUntil { await outcomes.refreshedRepositories().count == 2 }

    let calls = await probe.batchedCalls()
    #expect(calls.count == 1)
    let batchedRequest = try #require(calls.first?.requests.first)
    #expect(calls.first?.requests.count == 1)
    #expect(batchedRequest.owner == "khoi")
    #expect(batchedRequest.repo == "alpha")
    #expect(Set(batchedRequest.branches) == ["feat-1", "feat-2"])

    let snapshots = await outcomes.snapshot()
    let refreshed = snapshots.compactMap { outcome -> (Repository.ID, [String])? in
      if case .refreshed(let id, _, _, let prs, _, _) = outcome {
        return (id, Array(prs.keys))
      }
      return nil
    }
    #expect(Set(refreshed.map(\.0)) == ["alpha-a", "alpha-b"])
    #expect(refreshed.first { $0.0 == "alpha-a" }?.1 == ["feat-1"])
    #expect(refreshed.first { $0.0 == "alpha-b" }?.1 == ["feat-2"])
  }

  @Test func sameLocalRepositoryWithDifferentRemoteReposQueriesAllCandidatesBeforeEmitting() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var dict: [RepoKey: [String: GithubPullRequest]] = [:]
        for request in requests {
          if request.repo == "upstream" {
            dict[request.key] = ["feat-1": makeFixturePullRequest(repo: "upstream")]
          } else {
            dict[request.key] = [:]
          }
        }
        return CrossRepoPullRequestResult(successByRepo: dict)
      }
    )

    coordinator.enqueue(request(repo: "fork", repositoryID: "local"))
    coordinator.enqueue(request(repo: "upstream", repositoryID: "local"))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 1 }
    await waitUntil { await outcomes.refreshedRepositories().count == 1 }

    let calls = await probe.batchedCalls()
    #expect(calls.count == 1)
    #expect(Set(calls.first?.requests.map(\.repo) ?? []) == ["fork", "upstream"])
    let expectedAllowedHeadRepositories: Set<RepoKey> = [
      RepoKey(owner: "khoi", repo: "fork"),
      RepoKey(owner: "khoi", repo: "upstream"),
    ]
    #expect(calls.first?.requests.allSatisfy { $0.allowedHeadRepositories == expectedAllowedHeadRepositories } == true)

    let refreshed = await outcomes.snapshot().compactMap { outcome -> [String: GithubPullRequest]? in
      if case .refreshed("local", _, _, let prsByBranch, _, _) = outcome {
        return prsByBranch
      }
      return nil
    }
    #expect(refreshed.count == 1)
    #expect(refreshed.first?["feat-1"]?.title == "PR-upstream")
  }

  @Test func allCandidateReposSucceedingConfirmsBranchesWithoutPullRequests() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var dict: [RepoKey: [String: GithubPullRequest]] = [:]
        for request in requests {
          if request.repo == "upstream" {
            dict[request.key] = ["feat-1": makeFixturePullRequest(repo: "upstream")]
          } else {
            dict[request.key] = [:]
          }
        }
        return CrossRepoPullRequestResult(successByRepo: dict)
      }
    )

    coordinator.enqueue(request(repo: "fork", repositoryID: "local", branches: ["feat-1", "feat-2"]))
    coordinator.enqueue(request(repo: "upstream", repositoryID: "local", branches: ["feat-1", "feat-2"]))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await outcomes.refreshedRepositories().count == 1 }

    let refreshed = await outcomes.snapshot().compactMap { RefreshedAnswer(outcome: $0, repositoryID: "local") }
    let result = try #require(refreshed.first)
    #expect(refreshed.count == 1)
    #expect(result.prsByBranch["feat-1"]?.title == "PR-upstream")
    #expect(result.confirmedNoPrBranches == ["feat-2"])
    #expect(!result.isPartial)
  }

  @Test func partialCandidateRepoFailureLeavesBranchesUnconfirmed() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var success: [RepoKey: [String: GithubPullRequest]] = [:]
        var failed: [RepoKey: GithubCLIError] = [:]
        for request in requests {
          if request.repo == "upstream" {
            failed[request.key] = .commandFailed("boom")
          } else {
            success[request.key] = [:]
          }
        }
        return CrossRepoPullRequestResult(successByRepo: success, failedRepos: failed)
      },
      legacy: { _, _, _, _ in
        throw GithubCLIError.commandFailed("fallback down too")
      }
    )

    coordinator.enqueue(request(repo: "fork", repositoryID: "local", branches: ["feat-1", "feat-2"]))
    coordinator.enqueue(request(repo: "upstream", repositoryID: "local", branches: ["feat-1", "feat-2"]))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await outcomes.refreshedRepositories().count == 1 }

    let refreshed = await outcomes.snapshot().compactMap { RefreshedAnswer(outcome: $0, repositoryID: "local") }
    let result = try #require(refreshed.first)
    #expect(refreshed.count == 1)
    #expect(result.prsByBranch.isEmpty)
    #expect(result.confirmedNoPrBranches.isEmpty)
    // The reducer must not record this answer as complete.
    #expect(result.isPartial)
  }

  @Test func duplicateRepoKeysFallbackOnceAndFanOutToEachRepository() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, _ in
        throw GithubCLIError.commandFailed("batch unavailable")
      },
      legacy: { _, _, repo, branches in
        Dictionary(
          branches.map { branch in
            (branch, makeFixturePullRequest(repo: repo))
          },
          uniquingKeysWith: { first, _ in first }
        )
      }
    )

    coordinator.enqueue(
      request(repo: "alpha", repositoryID: "alpha-a", branches: ["feat-1"])
    )
    coordinator.enqueue(
      request(repo: "alpha", repositoryID: "alpha-b", branches: ["feat-2"])
    )
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.legacyCalls().count == 1 }
    await waitUntil { await outcomes.refreshedRepositories().count == 2 }

    let legacyCalls = await probe.legacyCalls()
    #expect(legacyCalls.count == 1)
    #expect(legacyCalls.first?.repo == "alpha")
    #expect(Set(legacyCalls.first?.branches ?? []) == ["feat-1", "feat-2"])
    let refreshed = await outcomes.refreshedRepositories()
    #expect(Set(refreshed) == ["alpha-a", "alpha-b"])
  }

  @Test func softTimeoutFallsBackToLegacy() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let neverFinish = AsyncStreamFlag()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      debounce: .milliseconds(250),
      softTimeout: .seconds(6),
      batched: { _, _ in
        await neverFinish.wait()
        return CrossRepoPullRequestResult()
      },
      legacy: { _, _, _, _ in [:] }
    )

    coordinator.enqueue(request(repo: "alpha"))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count >= 1 }
    await advanceCoordinatorClock(clock, by: .seconds(6))
    await waitUntil { await probe.legacyCalls().count >= 1 }

    let legacyCalls = await probe.legacyCalls()
    #expect(legacyCalls.map(\.repo) == ["alpha"])
    await neverFinish.signal()
  }

  @Test func resetCancelsPendingDebouncesAndInflight() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha"))
    coordinator.reset()
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await Task.yield()

    #expect(await probe.batchedCalls().isEmpty)
  }

  @Test func cancelHostStopsPendingFlush() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha", host: "host-a"))
    coordinator.enqueue(request(repo: "beta", host: "host-b"))
    coordinator.cancelHost("host-a")
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 1 }

    let calls = await probe.batchedCalls()
    #expect(calls.map(\.host) == ["host-b"])
  }

  @Test func batchedSuccessEmitsRefreshedWithBranchPRs() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var dict: [RepoKey: [String: GithubPullRequest]] = [:]
        for request in requests {
          let pullRequest = makeFixturePullRequest(repo: request.repo)
          dict[RepoKey(owner: request.owner, repo: request.repo)] = ["feat-1": pullRequest]
        }
        return CrossRepoPullRequestResult(successByRepo: dict)
      }
    )

    coordinator.enqueue(request(repo: "alpha", branches: ["feat-1"]))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await outcomes.refreshedRepositories().count == 1 }

    let snapshots = await outcomes.snapshot()
    let refresh = try #require(
      snapshots.compactMap { snapshot -> (String, [String: GithubPullRequest])? in
        if case .refreshed(let id, _, _, let prs, _, _) = snapshot {
          return (id, prs)
        }
        return nil
      }
      .first
    )
    #expect(refresh.0 == "alpha")
    #expect(refresh.1["feat-1"]?.title == "PR-alpha")
  }

  @Test func enqueueAfterFlushStartsNewDebounceWindow() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe, clock: clock, outcomes: outcomes,
      batched: { _, requests in successResult(for: requests) }
    )

    coordinator.enqueue(request(repo: "alpha"))
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.batchedCalls().count == 1 }
    #expect(await probe.batchedCalls().count == 1)

    coordinator.enqueue(request(repo: "beta"))
    await advanceCoordinatorClock(clock, by: .milliseconds(100))
    await Task.yield()
    #expect(await probe.batchedCalls().count == 1)
    await advanceCoordinatorClock(clock, by: .milliseconds(150))
    await waitUntil { await probe.batchedCalls().count == 2 }
    #expect(await probe.batchedCalls().count == 2)
  }

  @Test func legacyFallbackArgumentsMirrorOriginalRequest() async throws {
    let clock = TestClock()
    let probe = CoordinatorProbe()
    let outcomes = OutcomeCollector()
    let coordinator = makeCoordinator(
      probe: probe,
      clock: clock,
      outcomes: outcomes,
      batched: { _, requests in
        var failed: [RepoKey: GithubCLIError] = [:]
        for request in requests {
          failed[RepoKey(owner: request.owner, repo: request.repo)] = .commandFailed("nope")
        }
        return CrossRepoPullRequestResult(failedRepos: failed)
      },
      legacy: { _, _, _, _ in [:] }
    )

    coordinator.enqueue(
      request(repo: "alpha", host: "ghe.example", branches: ["feat-x", "feat-y"])
    )
    await advanceCoordinatorClock(clock, by: .milliseconds(250))
    await waitUntil { await probe.legacyCalls().count == 1 }

    let calls = await probe.legacyCalls()
    let call = try #require(calls.first)
    #expect(call.host == "ghe.example")
    #expect(call.owner == "khoi")
    #expect(call.repo == "alpha")
    #expect(Set(call.branches) == ["feat-x", "feat-y"])
  }
}

// MARK: - Helpers

@MainActor
private func makeCoordinator(
  probe: CoordinatorProbe,
  clock: TestClock<Duration>,
  outcomes: OutcomeCollector,
  debounce: Duration = .milliseconds(250),
  softTimeout: Duration = .seconds(6),
  batched:
    @escaping @Sendable (String, [CrossRepoPullRequestRequest]) async throws ->
    CrossRepoPullRequestResult,
  legacy:
    @escaping @Sendable (String, String, String, [String]) async throws ->
    [String: GithubPullRequest] = { _, _, _, _ in [:] }
) -> PullRequestRefreshCoordinator {
  var client = GithubCLIClient.testValue
  client.batchPullRequestsAcrossRepositories = { host, requests, accountOverride in
    await probe.recordBatched(host: host, requests: requests, accountOverride: accountOverride)
    return try await batched(host, requests)
  }
  client.batchPullRequests = { host, owner, repo, branches, detailBranches, _ in
    await probe.recordLegacy(host: host, owner: owner, repo: repo, branches: branches, detailBranches: detailBranches)
    return try await legacy(host, owner, repo, branches)
  }
  return PullRequestRefreshCoordinator(
    githubCLI: client,
    clock: clock,
    debounceWindow: debounce,
    softTimeout: softTimeout
  ) { outcome in
    Task { await outcomes.record(outcome) }
  }
}

@MainActor
private func waitUntil(
  _ condition: @MainActor @escaping () async -> Bool,
  maxIterations: Int = 10_000
) async {
  for _ in 0..<maxIterations {
    if await condition() {
      return
    }
    await Task.yield()
  }
}

private func advanceCoordinatorClock(
  _ clock: TestClock<Duration>,
  by duration: Duration
) async {
  // Let debounce tasks register and wake around TestClock advancement.
  await Task.yield()
  await clock.advance(by: duration)
  await Task.yield()
}

nonisolated private func request(
  repo: String,
  repositoryID: Repository.ID? = nil,
  rootPath: String? = nil,
  host: String = "github.com",
  accountOverride: GithubAccountOverride? = nil,
  branches: [String] = ["feat-1"],
  worktreeIDs: [Worktree.ID]? = nil
) -> PullRequestRefreshCoordinator.Request {
  let resolvedRepositoryID = repositoryID ?? repo
  return PullRequestRefreshCoordinator.Request(
    repositoryID: resolvedRepositoryID,
    repositoryRootURL: URL(fileURLWithPath: rootPath ?? "/tmp/\(resolvedRepositoryID)"),
    host: host,
    owner: "khoi",
    repo: repo,
    accountOverride: accountOverride,
    branches: branches,
    worktreeIDs: worktreeIDs ?? ["\(resolvedRepositoryID)-wt"]
  )
}

nonisolated private func successResult(
  for requests: [CrossRepoPullRequestRequest]
) -> CrossRepoPullRequestResult {
  var dict: [RepoKey: [String: GithubPullRequest]] = [:]
  for request in requests {
    dict[RepoKey(owner: request.owner, repo: request.repo)] = [:]
  }
  return CrossRepoPullRequestResult(successByRepo: dict)
}

nonisolated func makeFixturePullRequest(repo: String) -> GithubPullRequest {
  GithubPullRequest(
    number: 1,
    title: "PR-\(repo)",
    state: "OPEN",
    additions: 0,
    deletions: 0,
    isDraft: false,
    reviewDecision: nil,
    mergeable: nil,
    mergeStateStatus: nil,
    updatedAt: nil,
    url: "https://example.com/\(repo)/pull/1",
    headRefName: nil,
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: nil
  )
}

actor CoordinatorProbe {
  struct BatchedCall: Sendable {
    let host: String
    let requests: [CrossRepoPullRequestRequest]
    let accountOverride: GithubAccountOverride?
  }

  struct LegacyCall: Sendable {
    let host: String
    let owner: String
    let repo: String
    let branches: [String]
    let detailBranches: Set<String>
  }

  private var batched: [BatchedCall] = []
  private var legacy: [LegacyCall] = []

  func recordBatched(
    host: String,
    requests: [CrossRepoPullRequestRequest],
    accountOverride: GithubAccountOverride?
  ) {
    batched.append(BatchedCall(host: host, requests: requests, accountOverride: accountOverride))
  }

  func recordLegacy(host: String, owner: String, repo: String, branches: [String], detailBranches: Set<String>) {
    legacy.append(LegacyCall(host: host, owner: owner, repo: repo, branches: branches, detailBranches: detailBranches))
  }

  func batchedCalls() -> [BatchedCall] {
    batched
  }

  func legacyCalls() -> [LegacyCall] {
    legacy
  }
}

nonisolated private struct RefreshedAnswer: Sendable {
  let prsByBranch: [String: GithubPullRequest]
  let confirmedNoPrBranches: Set<String>
  let isPartial: Bool

  init?(outcome: PullRequestRefreshCoordinator.Outcome, repositoryID: Repository.ID) {
    guard case .refreshed(repositoryID, _, _, let prsByBranch, let confirmedNoPrBranches, let isPartial) = outcome
    else {
      return nil
    }
    self.prsByBranch = prsByBranch
    self.confirmedNoPrBranches = confirmedNoPrBranches
    self.isPartial = isPartial
  }
}

actor OutcomeCollector {
  private var outcomes: [PullRequestRefreshCoordinator.Outcome] = []

  func record(_ outcome: PullRequestRefreshCoordinator.Outcome) {
    outcomes.append(outcome)
  }

  func snapshot() -> [PullRequestRefreshCoordinator.Outcome] {
    outcomes
  }

  func refreshedRepositories() -> [String] {
    outcomes.compactMap {
      if case .refreshed(let id, _, _, _, _, _) = $0 {
        return id
      }
      return nil
    }
  }

  func failedRepositories() -> [String] {
    outcomes.compactMap {
      if case .failed(let id, _, _) = $0 {
        return id
      }
      return nil
    }
  }
}

actor AsyncStreamFlag {
  private var resumed = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    if resumed {
      return
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  func signal() {
    resumed = true
    continuation?.resume()
    continuation = nil
  }

  private func cancel() {
    continuation?.resume()
    continuation = nil
  }
}
