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
    /// Branches whose pull request also lists each check, such as the selected worktree's.
    let detailBranches: [String]

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
      worktreeIDs: [Worktree.ID],
      detailBranches: [String] = []
    ) {
      self.init(
        repositoryID: repositoryID,
        repositoryRootURL: repositoryRootURL,
        host: host,
        repositories: [GithubRemoteInfo(host: host, owner: owner, repo: repo)],
        accountOverride: accountOverride,
        branches: branches,
        worktreeIDs: worktreeIDs,
        detailBranches: detailBranches
      )
    }

    init(
      repositoryID: Repository.ID,
      repositoryRootURL: URL,
      host: String,
      repositories: [GithubRemoteInfo],
      accountOverride: GithubAccountOverride?,
      branches: [String],
      worktreeIDs: [Worktree.ID],
      detailBranches: [String] = []
    ) {
      self.repositoryID = repositoryID
      self.repositoryRootURL = repositoryRootURL
      self.host = host
      self.repositories = Self.deduplicateRepositories(repositories)
      self.accountOverride = accountOverride
      self.branches = branches
      self.worktreeIDs = worktreeIDs
      self.detailBranches = detailBranches
    }

    private static func deduplicateRepositories(_ repositories: [GithubRemoteInfo]) -> [GithubRemoteInfo] {
      var seen = Set<RepoKey>()
      return repositories.filter { seen.insert($0.key).inserted }
    }
  }

  nonisolated enum Outcome: Sendable, Equatable {
    // isPartial: a candidate repository of the request did not answer, even after the fallback. The
    // found pull requests are real, but nothing is confirmed absent and the answer is not complete.
    case refreshed(
      repositoryID: Repository.ID,
      repositoryRootURL: URL,
      worktreeIDs: [Worktree.ID],
      prsByBranch: [String: GithubPullRequest],
      confirmedNoPrBranches: Set<String>,
      isPartial: Bool = false
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
  private let minimumQueryGap: Duration
  private let resultHandler: @MainActor (Outcome) -> Void

  private nonisolated struct BatchKey: Hashable, Sendable {
    let host: String
    let accountOverride: GithubAccountOverride?
  }

  private var pendingByHost: [BatchKey: [Repository.ID: Request]] = [:]
  private let flushDebouncer: KeyedDebouncer<BatchKey>
  private var inflightHosts: Set<BatchKey> = []
  private var queuedByHost: [BatchKey: [Repository.ID: Request]] = [:]
  // Advanced by reset, and per host by cancelHost, so a batch that finishes its gap after either one
  // does not release state that now belongs to a newer batch, while cancelling one host leaves the
  // batches of every other host running.
  private var generation = 0
  private var hostGenerations: [String: Int] = [:]

  init(
    githubCLI: GithubCLIClient,
    clock: any Clock<Duration>,
    debounceWindow: Duration = .milliseconds(250),
    softTimeout: Duration = .seconds(12),
    minimumQueryGap: Duration = .seconds(15),
    resultHandler: @MainActor @escaping (Outcome) -> Void
  ) {
    self.githubCLI = githubCLI
    self.clock = clock
    self.softTimeout = softTimeout
    self.minimumQueryGap = minimumQueryGap
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
      worktreeIDs: request.worktreeIDs,
      detailBranches: request.detailBranches
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
    hostGenerations[host, default: 0] += 1
    flushDebouncer.cancelAll { $0.host == host }
    pendingByHost = pendingByHost.filter { $0.key.host != host }
    queuedByHost = queuedByHost.filter { $0.key.host != host }
    inflightHosts = inflightHosts.filter { $0.host != host }
  }

  func reset() {
    generation += 1
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
      var combinedDetailBranches = existing.detailBranches
      for branch in request.detailBranches where !combinedDetailBranches.contains(branch) {
        combinedDetailBranches.append(branch)
      }
      hostBucket[request.repositoryID] = Request(
        repositoryID: request.repositoryID,
        repositoryRootURL: request.repositoryRootURL,
        host: request.host,
        repositories: combinedRepositories,
        accountOverride: request.accountOverride,
        branches: combined,
        worktreeIDs: workCombined,
        detailBranches: combinedDetailBranches
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
    let startedGeneration = currentGeneration(of: key)
    let requests = Array(bucket.values)
    await processBatch(key: key, requests: requests)
    // Requests that arrive during the gap merge into the next batch instead of starting their own,
    // so a burst of new worktrees costs one query rather than one per repository.
    if minimumQueryGap > .zero {
      try? await clock.sleep(for: minimumQueryGap)
    }
    guard currentGeneration(of: key) == startedGeneration else {
      return
    }
    inflightHosts.remove(key)
    if let queued = queuedByHost.removeValue(forKey: key), !queued.isEmpty {
      pendingByHost[key, default: [:]].merge(queued) { _, new in new }
      await flush(key: key)
    }
  }

  // Both counters only grow, so the sum changes whenever either one does.
  private func currentGeneration(of key: BatchKey) -> Int {
    generation + hostGenerations[key.host, default: 0]
  }

  private func processBatch(key: BatchKey, requests: [Request]) async {
    let groupsByKey = groupBranchesByRepo(requests)
    let crossRepoRequests = groupsByKey.values.map { group in
      CrossRepoPullRequestRequest(
        owner: group.key.owner,
        repo: group.key.repo,
        branches: group.branches,
        allowedHeadRepositories: group.allowedHeadRepositories,
        detailBranches: group.detailBranches
      )
    }
    // Each call below sends exactly one query, so the gap spaces every query rather than only every
    // batch: a batch of many repositories, or a fallback, cannot turn into back-to-back requests.
    var pacer = QueryPacer(gap: minimumQueryGap, clock: clock)
    var prsByRepo: [RepoKey: [String: GithubPullRequest]] = [:]
    var failedMessagesByRepo: [RepoKey: String] = [:]
    var fallbackKeys: [RepoKey] = []
    for chunk in crossRepoRequests.chunked(by: crossRepoBatchAliasLimit) {
      await pacer.beforeQuery()
      do {
        let result = try await runBatchWithTimeout(
          host: key.host,
          requests: chunk,
          accountOverride: key.accountOverride
        )
        prsByRepo.merge(result.successByRepo) { _, new in new }
        // A smaller query cannot fix a rate limit or a repository GitHub cannot resolve for the account,
        // so only the other failures fall back per repository.
        for (repoKey, error) in result.failedRepos {
          failedMessagesByRepo[repoKey] = String(describing: error)
          if error.allowsFallback {
            fallbackKeys.append(repoKey)
          }
        }
      } catch let error as GithubCLIError where !error.allowsFallback {
        // A smaller query cannot fix a rate limit, and the gate reports the retry time on its own.
        for request in chunk {
          failedMessagesByRepo[request.key] = error.localizedDescription
        }
      } catch {
        for request in chunk {
          failedMessagesByRepo[request.key] = String(describing: error)
          fallbackKeys.append(request.key)
        }
      }
    }
    if !fallbackKeys.isEmpty {
      let fallback = await fetchFallbackResults(
        key: key,
        groups: fallbackKeys.compactMap { groupsByKey[$0] },
        pacer: &pacer
      )
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
  }

  private func fetchFallbackResults(
    key: BatchKey,
    groups: [RepoRequestGroup],
    pacer: inout QueryPacer
  ) async -> RepoFetchResults {
    // One query at a time, each paced: the fallback runs after a failed batch, which is exactly
    // when a burst of queries does the most harm to an account other tools share.
    var results = RepoFetchResults()
    for repoGroup in groups {
      var prsByBranch: [String: GithubPullRequest] = [:]
      do {
        for branches in repoGroup.branches.chunked(by: batchPullRequestsChunkSize) {
          await pacer.beforeQuery()
          let prs = try await githubCLI.batchPullRequests(
            key.host,
            repoGroup.key.owner,
            repoGroup.key.repo,
            branches,
            repoGroup.detailBranches,
            key.accountOverride
          )
          prsByBranch.merge(prs) { _, new in new }
        }
        results.successByRepo[repoGroup.key] = prsByBranch
      } catch {
        results.failedMessagesByRepo[repoGroup.key] = String(describing: error)
      }
    }
    return results
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
            confirmedNoPrBranches: confirmedNoPrBranches,
            isPartial: !allCandidatesSucceeded
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
          detailBranches: request.detailBranches,
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
    private(set) var detailBranches: Set<String> = []
    private var seenBranches: Set<String> = []

    init(key: RepoKey) {
      self.key = key
    }

    mutating func append(
      branches newBranches: [String],
      detailBranches newDetailBranches: [String],
      allowedHeadRepositories newAllowedHeadRepositories: Set<RepoKey>
    ) {
      for branch in newBranches where seenBranches.insert(branch).inserted {
        branches.append(branch)
      }
      detailBranches.formUnion(newDetailBranches)
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

}

// Spaces the queries of one batch: every query after the first waits the gap.
private struct QueryPacer {
  let gap: Duration
  let clock: any Clock<Duration>
  private var queriesSent = 0

  init(gap: Duration, clock: any Clock<Duration>) {
    self.gap = gap
    self.clock = clock
  }

  mutating func beforeQuery() async {
    if queriesSent > 0, gap > .zero {
      try? await clock.sleep(for: gap)
    }
    queriesSent += 1
  }
}

extension Array {
  nonisolated fileprivate func chunked(by size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
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
