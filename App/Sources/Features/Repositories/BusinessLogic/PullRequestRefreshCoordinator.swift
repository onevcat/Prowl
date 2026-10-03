import ComposableArchitecture
import Foundation

@MainActor
final class PullRequestRefreshCoordinator {
  nonisolated struct Request: Equatable, Sendable {
    let repositoryID: Repository.ID
    let repositoryRootURL: URL
    let host: String
    let repositories: [GithubRemoteInfo]
    let accountOverride: GithubAccountOverride?
    let branches: [String]
    let worktreeIDs: [Worktree.ID]

    var owner: String {
      repositories.first?.owner ?? ""
    }

    var repo: String {
      repositories.first?.repo ?? ""
    }

    init(
      repositoryID: Repository.ID,
      repositoryRootURL: URL,
      host: String,
      owner: String,
      repo: String,
      accountOverride: GithubAccountOverride?,
      branches: [String],
      worktreeIDs: [Worktree.ID]
    ) {
      self.init(
        repositoryID: repositoryID,
        repositoryRootURL: repositoryRootURL,
        host: host,
        repositories: [GithubRemoteInfo(host: host, owner: owner, repo: repo)],
        accountOverride: accountOverride,
        branches: branches,
        worktreeIDs: worktreeIDs
      )
    }

    init(
      repositoryID: Repository.ID,
      repositoryRootURL: URL,
      host: String,
      repositories: [GithubRemoteInfo],
      accountOverride: GithubAccountOverride?,
      branches: [String],
      worktreeIDs: [Worktree.ID]
    ) {
      self.repositoryID = repositoryID
      self.repositoryRootURL = repositoryRootURL
      self.host = host
      self.repositories = Self.deduplicateRepositories(repositories)
      self.accountOverride = accountOverride
      self.branches = branches
      self.worktreeIDs = worktreeIDs
    }

    private static func deduplicateRepositories(_ repositories: [GithubRemoteInfo]) -> [GithubRemoteInfo] {
      var seen = Set<RepoKey>()
      return repositories.filter { seen.insert($0.key).inserted }
    }
  }

  nonisolated enum Outcome: Sendable, Equatable {
    case refreshed(
      repositoryID: Repository.ID,
      repositoryRootURL: URL,
      worktreeIDs: [Worktree.ID],
      prsByBranch: [String: GithubPullRequest],
      confirmedNoPrBranches: Set<String>
    )
    case failed(
      repositoryID: Repository.ID,
      worktreeIDs: [Worktree.ID],
      message: String
    )
  }

  private let githubCLI: GithubCLIClient
  private let clock: any Clock<Duration>
  private let softTimeout: Duration
  private let resultHandler: @MainActor (Outcome) -> Void

  private nonisolated struct BatchKey: Hashable, Sendable {
    let host: String
    let accountOverride: GithubAccountOverride?
  }

  private var pendingByHost: [BatchKey: [Repository.ID: Request]] = [:]
  private let flushDebouncer: KeyedDebouncer<BatchKey>
  private var inflightHosts: Set<BatchKey> = []
  private var queuedByHost: [BatchKey: [Repository.ID: Request]] = [:]

  init(
    githubCLI: GithubCLIClient,
    clock: any Clock<Duration>,
    debounceWindow: Duration = .milliseconds(250),
    softTimeout: Duration = .seconds(12),
    resultHandler: @MainActor @escaping (Outcome) -> Void
  ) {
    self.githubCLI = githubCLI
    self.clock = clock
    self.softTimeout = softTimeout
    self.resultHandler = resultHandler
    flushDebouncer = KeyedDebouncer(interval: debounceWindow, clock: clock)
  }

  func enqueue(_ request: Request) {
    // Trim and drop whitespace-only entries so "feat" and "feat " do not get treated as
    // distinct branches downstream and don't leak padding into the GraphQL headRefName.
    let cleanedBranches = request.branches.compactMap { branch -> String? in
      let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    guard !cleanedBranches.isEmpty, !request.repositories.isEmpty else {
      return
    }
    let normalized = Request(
      repositoryID: request.repositoryID,
      repositoryRootURL: request.repositoryRootURL,
      host: request.host,
      repositories: request.repositories.filter { $0.host == request.host },
      accountOverride: request.accountOverride,
      branches: cleanedBranches,
      worktreeIDs: request.worktreeIDs
    )
    guard !normalized.repositories.isEmpty else {
      return
    }

    let key = BatchKey(host: normalized.host, accountOverride: normalized.accountOverride)
    if inflightHosts.contains(key) {
      mergeRequest(normalized, into: &queuedByHost)
      return
    }

    mergeRequest(normalized, into: &pendingByHost)
    rescheduleDebounce(forKey: key)
  }

  func cancelHost(_ host: String) {
    flushDebouncer.cancelAll { $0.host == host }
    pendingByHost = pendingByHost.filter { $0.key.host != host }
    queuedByHost = queuedByHost.filter { $0.key.host != host }
    inflightHosts = inflightHosts.filter { $0.host != host }
  }

  func reset() {
    flushDebouncer.cancelAll()
    pendingByHost.removeAll()
    queuedByHost.removeAll()
    inflightHosts.removeAll()
  }

  private func mergeRequest(
    _ request: Request,
    into bucket: inout [BatchKey: [Repository.ID: Request]]
  ) {
    let key = BatchKey(host: request.host, accountOverride: request.accountOverride)
    var hostBucket = bucket[key] ?? [:]
    if let existing = hostBucket[request.repositoryID] {
      var seen = Set<String>(existing.branches)
      var combined = existing.branches
      for branch in request.branches where seen.insert(branch).inserted {
        combined.append(branch)
      }
      var workseen = Set<Worktree.ID>(existing.worktreeIDs)
      var workCombined = existing.worktreeIDs
      for worktreeID in request.worktreeIDs where workseen.insert(worktreeID).inserted {
        workCombined.append(worktreeID)
      }
      var seenRepositories = Set<RepoKey>(existing.repositories.map(\.key))
      var combinedRepositories = existing.repositories
      for repository in request.repositories where seenRepositories.insert(repository.key).inserted {
        combinedRepositories.append(repository)
      }
      hostBucket[request.repositoryID] = Request(
        repositoryID: request.repositoryID,
        repositoryRootURL: request.repositoryRootURL,
        host: request.host,
        repositories: combinedRepositories,
        accountOverride: request.accountOverride,
        branches: combined,
        worktreeIDs: workCombined
      )
    } else {
      hostBucket[request.repositoryID] = request
    }
    bucket[key] = hostBucket
  }

  private func rescheduleDebounce(forKey key: BatchKey) {
    flushDebouncer.schedule(key) { [weak self] in
      await self?.flush(key: key)
    }
  }

  private func flush(key: BatchKey) async {
    flushDebouncer.cancel(key)
    guard let bucket = pendingByHost.removeValue(forKey: key), !bucket.isEmpty else {
      return
    }
    inflightHosts.insert(key)
    let requests = Array(bucket.values)
    await processBatch(key: key, requests: requests)
    inflightHosts.remove(key)
    if let queued = queuedByHost.removeValue(forKey: key), !queued.isEmpty {
      pendingByHost[key, default: [:]].merge(queued) { _, new in new }
      await flush(key: key)
    }
  }

  private func processBatch(key: BatchKey, requests: [Request]) async {
    let groupsByKey = groupBranchesByRepo(requests)
    let crossRepoRequests = groupsByKey.values.map { group in
      CrossRepoPullRequestRequest(
        owner: group.key.owner,
        repo: group.key.repo,
        branches: group.branches,
        allowedHeadRepositories: group.allowedHeadRepositories
      )
    }
    do {
      let result = try await runBatchWithTimeout(
        host: key.host,
        requests: crossRepoRequests,
        accountOverride: key.accountOverride
      )
      var prsByRepo = result.successByRepo
      var failedMessagesByRepo = result.failedRepos.mapValues { String(describing: $0) }
      if !result.failedRepos.isEmpty {
        let failedGroups = result.failedRepos.keys.compactMap { groupsByKey[$0] }
        let fallback = await fetchFallbackResults(key: key, groups: failedGroups)
        for (repoKey, prsByBranch) in fallback.successByRepo {
          prsByRepo[repoKey] = prsByBranch
          failedMessagesByRepo.removeValue(forKey: repoKey)
        }
        failedMessagesByRepo.merge(fallback.failedMessagesByRepo) { _, new in new }
      }
      emitOutcomes(
        requests,
        prsByRepo: prsByRepo,
        failedMessagesByRepo: failedMessagesByRepo
      )
    } catch {
      let fallback = await fetchFallbackResults(key: key, groups: Array(groupsByKey.values))
      emitOutcomes(
        requests,
        prsByRepo: fallback.successByRepo,
        failedMessagesByRepo: fallback.failedMessagesByRepo
      )
    }
  }

  private func fetchFallbackResults(
    key: BatchKey,
    groups: [RepoRequestGroup]
  ) async -> RepoFetchResults {
    // Run per-repo fallback requests concurrently; serial awaits here would multiply
    // a slow recovery path by the number of repos in the batch.
    await withTaskGroup(of: RepoFetchOutcome.self) { taskGroup in
      let githubCLI = self.githubCLI
      for repoGroup in groups {
        taskGroup.addTask {
          do {
            let prs = try await githubCLI.batchPullRequests(
              key.host,
              repoGroup.key.owner,
              repoGroup.key.repo,
              repoGroup.branches,
              key.accountOverride
            )
            return .success(repoGroup.key, prs)
          } catch {
            return .failed(repoGroup.key, String(describing: error))
          }
        }
      }
      var results = RepoFetchResults()
      for await outcome in taskGroup {
        switch outcome {
        case .success(let repoKey, let prsByBranch):
          results.successByRepo[repoKey] = prsByBranch
        case .failed(let repoKey, let message):
          results.failedMessagesByRepo[repoKey] = message
        }
      }
      return results
    }
  }

  private func runBatchWithTimeout(
    host: String,
    requests: [CrossRepoPullRequestRequest],
    accountOverride: GithubAccountOverride?
  ) async throws -> CrossRepoPullRequestResult {
    try await withThrowingTaskGroup(of: BatchTimeoutOutcome.self) { group in
      let githubCLI = self.githubCLI
      let softTimeout = self.softTimeout
      let clock = self.clock
      group.addTask {
        let value = try await githubCLI.batchPullRequestsAcrossRepositories(host, requests, accountOverride)
        return .completed(value)
      }
      group.addTask {
        try await clock.sleep(for: softTimeout)
        return .timedOut
      }
      defer { group.cancelAll() }
      while let outcome = try await group.next() {
        switch outcome {
        case .completed(let value):
          return value
        case .timedOut:
          throw PullRequestRefreshCoordinatorError.softTimeout
        }
      }
      throw PullRequestRefreshCoordinatorError.softTimeout
    }
  }

  private func emitOutcomes(
    _ requests: [Request],
    prsByRepo: [RepoKey: [String: GithubPullRequest]],
    failedMessagesByRepo: [RepoKey: String]
  ) {
    for request in requests {
      let prsByBranch = mergedPullRequests(for: request, prsByRepo: prsByRepo)
      let candidateKeys = request.repositories.map(\.key)
      let allCandidatesFailed =
        !candidateKeys.isEmpty
        && candidateKeys.allSatisfy { prsByRepo[$0] == nil && failedMessagesByRepo[$0] != nil }
      if allCandidatesFailed {
        resultHandler(
          .failed(
            repositoryID: request.repositoryID,
            worktreeIDs: request.worktreeIDs,
            message: failureMessage(for: candidateKeys, failedMessagesByRepo: failedMessagesByRepo)
          )
        )
      } else {
        // Only mark branches as "confirmed no PR" when all candidate repos
        // succeeded — if any repo failed, the branch status is unknown and
        // the reducer should preserve existing PR state.
        let allCandidatesSucceeded =
          !candidateKeys.isEmpty
          && candidateKeys.allSatisfy { prsByRepo[$0] != nil && failedMessagesByRepo[$0] == nil }
        let confirmedNoPrBranches: Set<String> =
          allCandidatesSucceeded ? Set(request.branches).subtracting(prsByBranch.keys) : []
        resultHandler(
          .refreshed(
            repositoryID: request.repositoryID,
            repositoryRootURL: request.repositoryRootURL,
            worktreeIDs: request.worktreeIDs,
            prsByBranch: prsByBranch,
            confirmedNoPrBranches: confirmedNoPrBranches
          )
        )
      }
    }
  }

  private func mergedPullRequests(
    for request: Request,
    prsByRepo: [RepoKey: [String: GithubPullRequest]]
  ) -> [String: GithubPullRequest] {
    var prsByBranch: [String: GithubPullRequest] = [:]
    for branch in request.branches {
      for repository in request.repositories {
        if let pullRequest = prsByRepo[repository.key]?[branch] {
          prsByBranch[branch] = pullRequest
          break
        }
      }
    }
    return prsByBranch
  }

  private func failureMessage(
    for repoKeys: [RepoKey],
    failedMessagesByRepo: [RepoKey: String]
  ) -> String {
    let messages = repoKeys.compactMap { repoKey -> String? in
      guard let message = failedMessagesByRepo[repoKey] else {
        return nil
      }
      return "\(repoKey.owner)/\(repoKey.repo): \(message)"
    }
    return messages.isEmpty ? "GitHub pull request refresh failed." : messages.joined(separator: "; ")
  }

  private func groupBranchesByRepo(_ requests: [Request]) -> [RepoKey: RepoRequestGroup] {
    var groupsByKey: [RepoKey: RepoRequestGroup] = [:]
    for request in requests {
      let allowedHeadRepositories = Set(request.repositories.map(\.key))
      for repository in request.repositories {
        groupsByKey[repository.key, default: RepoRequestGroup(key: repository.key)].append(
          branches: request.branches,
          allowedHeadRepositories: allowedHeadRepositories
        )
      }
    }
    return groupsByKey
  }

  private struct RepoRequestGroup: Sendable {
    let key: RepoKey
    private(set) var branches: [String] = []
    private(set) var allowedHeadRepositories: Set<RepoKey> = []
    private var seenBranches: Set<String> = []

    init(key: RepoKey) {
      self.key = key
    }

    mutating func append(
      branches newBranches: [String],
      allowedHeadRepositories newAllowedHeadRepositories: Set<RepoKey>
    ) {
      for branch in newBranches where seenBranches.insert(branch).inserted {
        branches.append(branch)
      }
      allowedHeadRepositories.formUnion(newAllowedHeadRepositories)
    }
  }

  private enum BatchTimeoutOutcome: Sendable {
    case completed(CrossRepoPullRequestResult)
    case timedOut
  }

  private struct RepoFetchResults: Sendable {
    var successByRepo: [RepoKey: [String: GithubPullRequest]] = [:]
    var failedMessagesByRepo: [RepoKey: String] = [:]
  }

  private enum RepoFetchOutcome: Sendable {
    case success(RepoKey, [String: GithubPullRequest])
    case failed(RepoKey, String)
  }
}

enum PullRequestRefreshCoordinatorError: Error, Equatable {
  case softTimeout
}

nonisolated struct PullRequestRefreshCoordinatorClient: Sendable {
  var enqueue: @Sendable (PullRequestRefreshCoordinator.Request) -> Void
  var cancelHost: @Sendable (String) -> Void
  var reset: @Sendable () -> Void

  nonisolated static let unimplemented = PullRequestRefreshCoordinatorClient(
    enqueue: { _ in },
    cancelHost: { _ in },
    reset: {}
  )
}

extension PullRequestRefreshCoordinatorClient: DependencyKey {
  nonisolated static let liveValue = unimplemented
  nonisolated static let testValue = unimplemented
}

extension DependencyValues {
  var pullRequestRefreshCoordinator: PullRequestRefreshCoordinatorClient {
    get { self[PullRequestRefreshCoordinatorClient.self] }
    set { self[PullRequestRefreshCoordinatorClient.self] = newValue }
  }
}
