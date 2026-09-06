import ComposableArchitecture
import Darwin
import Foundation
import ProwlCLIShared

// A login shell sources `.zprofile` / `.zlogin` before `gh` runs, so a banner or version-manager
// line can prepend to captured stdout and corrupt the JSON.
enum GithubCLIOutput {
  // No JSON found at all: the likely cause is shell startup output polluting stdout.
  nonisolated static let noPayloadMessage =
    "Could not read GitHub CLI output. Your shell startup files may be printing extra output to stdout."

  // Valid JSON was found but failed to decode: the likely cause is an incompatible gh version.
  nonisolated static let undecodableMessage =
    "Could not parse GitHub CLI output. The installed GitHub CLI version may be incompatible."

  nonisolated private static let logger = SupaLogger("GithubCLI")

  // Every balanced top-level JSON value ({...} or [...]) in `output`, in source order. An opener that
  // never balances (a stray brace from shell noise) is skipped, so leading noise cannot swallow a real
  // payload that follows.
  nonisolated static func balancedJSONSpans(in output: String) -> [Substring] {
    var spans: [Substring] = []
    var searchStart = output.startIndex
    while let start = output[searchStart...].firstIndex(where: { $0 == "{" || $0 == "[" }) {
      let opener = output[start]
      let closer: Character = opener == "{" ? "}" : "]"
      var depth = 0
      var inString = false
      var escaped = false
      var matchedEnd: String.Index?
      var index = start
      scan: while index < output.endIndex {
        let character = output[index]
        switch character {
        case _ where inString && escaped:
          escaped = false
        case "\\" where inString:
          escaped = true
        case "\"" where inString:
          inString = false
        case _ where inString:
          break
        case "\"":
          inString = true
        case opener:
          depth += 1
        case closer:
          depth -= 1
          guard depth == 0 else { break }
          matchedEnd = output.index(after: index)
          break scan
        default:
          break
        }
        index = output.index(after: index)
      }
      guard let end = matchedEnd else {
        // Unbalanced opener (stray bracket in noise): skip it and keep scanning.
        searchStart = output.index(after: start)
        continue
      }
      spans.append(output[start..<end])
      searchStart = end
    }
    return spans
  }

  // Decodes the JSON payload from possibly noisy gh stdout, surfacing a readable error (with the raw
  // output logged) instead of an opaque DecodingError. Throws when no payload is found at all.
  nonisolated static func decode<T: Decodable>(
    _ type: T.Type,
    from output: String,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T {
    guard let value = try decodeIfPresent(T.self, from: output, decoder: decoder) else {
      logDecodeFailure(output)
      throw GithubCLIError.commandFailed(noPayloadMessage)
    }
    return value
  }

  // Returns nil when `output` carries no JSON payload at all (e.g. `gh run list` with no runs), and
  // throws only when a payload is present but cannot be decoded. gh prints its JSON after any leading
  // shell noise, so the last decodable span wins.
  nonisolated static func decodeIfPresent<T: Decodable>(
    _ type: T.Type,
    from output: String,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T? {
    let spans = balancedJSONSpans(in: output)
    guard !spans.isEmpty else {
      return nil
    }
    var lastDecodingError: Error?
    var sawValidJSON = false
    for span in spans.reversed() {
      let data = Data(span.utf8)
      do {
        return try decoder.decode(T.self, from: data)
      } catch {
        lastDecodingError = error
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
          sawValidJSON = true
        }
      }
    }
    let detail = lastDecodingError.map { "\($0)" } ?? "unknown"
    logger.warning("Failed to decode GitHub CLI JSON output: \(snapshot(of: output)) error=\(detail)")
    // Valid JSON that failed to decode points at gh schema drift; otherwise the brackets were noise.
    throw GithubCLIError.commandFailed(sawValidJSON ? undecodableMessage : noPayloadMessage)
  }

  // Logs a length-capped snapshot of the offending output so the user can retrieve it from the log
  // stream without flooding it with a large banner.
  nonisolated static func logDecodeFailure(_ output: String) {
    logger.warning("Failed to read GitHub CLI JSON output: \(snapshot(of: output))")
  }

  // Caps the logged output so a large banner does not flood the log stream.
  nonisolated private static func snapshot(of output: String) -> String {
    let limit = 500
    let prefix = output.prefix(limit)
    return prefix.endIndex == output.endIndex ? String(prefix) : "\(prefix)… (truncated)"
  }
}

enum GithubAuthStatusParsing {
  // `hosts` is an unordered dictionary, so prefer github.com and otherwise sort the keys: the result
  // is deterministic even when more than one host has an active account.
  nonisolated static func activeAccount(
    in response: GithubAuthStatusResponse
  ) -> (host: String, login: String)? {
    let orderedHosts = response.hosts.keys.sorted { lhs, rhs in
      if lhs == "github.com" { return true }
      if rhs == "github.com" { return false }
      return lhs < rhs
    }
    let snapshot = GithubAuthStatusSnapshot(response: response)
    for host in orderedHosts {
      if let active = snapshot.activeAccount(on: host) {
        return (host, active.login)
      }
    }
    return nil
  }
}

actor GithubAccountSwitchLock {
  static let shared = GithubAccountSwitchLock()

  private var lockedHosts: Set<String> = []
  private var waitersByHost: [String: [CheckedContinuation<Void, Never>]] = [:]

  func acquire(host: String) async {
    if !lockedHosts.contains(host) {
      lockedHosts.insert(host)
      return
    }
    await withCheckedContinuation { continuation in
      waitersByHost[host, default: []].append(continuation)
    }
  }

  func release(host: String) {
    guard var waiters = waitersByHost[host], !waiters.isEmpty else {
      lockedHosts.remove(host)
      return
    }
    let next = waiters.removeFirst()
    waitersByHost[host] = waiters.isEmpty ? nil : waiters
    next.resume()
  }
}

struct GithubCLIClient: Sendable {
  var defaultBranch: @Sendable (URL) async throws -> String
  var resolveRemoteInfo: @Sendable (URL) async -> GithubRemoteInfo?
  var latestRun: @Sendable (URL, String, GithubAccountOverride?) async throws -> GithubWorkflowRun?
  var batchPullRequests:
    @Sendable (String, String, String, [String], GithubAccountOverride?) async throws -> [String: GithubPullRequest]
  var batchPullRequestsAcrossRepositories:
    @Sendable (String, [CrossRepoPullRequestRequest], GithubAccountOverride?) async throws -> CrossRepoPullRequestResult
  var mergePullRequest:
    @Sendable (URL, GithubRemoteInfo, Int, PullRequestMergeStrategy, GithubAccountOverride?) async throws -> Void
  var closePullRequest: @Sendable (URL, GithubRemoteInfo, Int, GithubAccountOverride?) async throws -> Void
  var markPullRequestReady: @Sendable (URL, GithubRemoteInfo, Int, GithubAccountOverride?) async throws -> Void
  var rerunFailedJobs: @Sendable (URL, Int, GithubAccountOverride?) async throws -> Void
  var failedRunLogs: @Sendable (URL, Int, GithubAccountOverride?) async throws -> String
  var runLogs: @Sendable (URL, Int, GithubAccountOverride?) async throws -> String
  var isAvailable: @Sendable () async -> Bool
  var authStatusSnapshot: @Sendable () async throws -> GithubAuthStatusSnapshot
  var authStatus: @Sendable () async throws -> GithubAuthStatus?
}

extension GithubCLIClient: DependencyKey {
  static let liveValue = live()

  static func live(
    shell: ShellClient = .liveValue,
    fallbackExecutableURLs: [URL] = GithubCLIExecutableResolver.defaultFallbackExecutableURLs()
  ) -> GithubCLIClient {
    let resolver = GithubCLIExecutableResolver(fallbackExecutableURLs: fallbackExecutableURLs)
    return GithubCLIClient(
      defaultBranch: defaultBranchFetcher(shell: shell, resolver: resolver),
      resolveRemoteInfo: resolveRemoteInfoFetcher(shell: shell, resolver: resolver),
      latestRun: latestRunFetcher(shell: shell, resolver: resolver),
      batchPullRequests: batchPullRequestsFetcher(shell: shell, resolver: resolver),
      batchPullRequestsAcrossRepositories: batchPullRequestsAcrossRepositoriesFetcher(shell: shell, resolver: resolver),
      mergePullRequest: mergePullRequestFetcher(shell: shell, resolver: resolver),
      closePullRequest: closePullRequestFetcher(shell: shell, resolver: resolver),
      markPullRequestReady: markPullRequestReadyFetcher(shell: shell, resolver: resolver),
      rerunFailedJobs: rerunFailedJobsFetcher(shell: shell, resolver: resolver),
      failedRunLogs: failedRunLogsFetcher(shell: shell, resolver: resolver),
      runLogs: runLogsFetcher(shell: shell, resolver: resolver),
      isAvailable: isAvailableFetcher(shell: shell, resolver: resolver),
      authStatusSnapshot: authStatusSnapshotFetcher(shell: shell, resolver: resolver),
      authStatus: authStatusFetcher(shell: shell, resolver: resolver)
    )
  }

  static let testValue = GithubCLIClient(
    defaultBranch: { _ in "main" },
    resolveRemoteInfo: { _ in nil },
    latestRun: { _, _, _ in nil },
    batchPullRequests: { _, _, _, _, _ in [:] },
    batchPullRequestsAcrossRepositories: { _, _, _ in CrossRepoPullRequestResult() },
    mergePullRequest: { _, _, _, _, _ in },
    closePullRequest: { _, _, _, _ in },
    markPullRequestReady: { _, _, _, _ in },
    rerunFailedJobs: { _, _, _ in },
    failedRunLogs: { _, _, _ in "" },
    runLogs: { _, _, _ in "" },
    isAvailable: { true },
    authStatusSnapshot: {
      GithubAuthStatusSnapshot(
        hosts: [
          "github.com": [
            GithubAuthAccountStatus(
              host: "github.com",
              login: "testuser",
              active: true,
              state: "success",
              gitProtocol: "ssh",
              scopes: nil,
              tokenSource: nil
            )
          ]
        ]
      )
    },
    authStatus: { GithubAuthStatus(username: "testuser", host: "github.com") }
  )
}

extension DependencyValues {
  var githubCLI: GithubCLIClient {
    get { self[GithubCLIClient.self] }
    set { self[GithubCLIClient.self] = newValue }
  }
}

nonisolated private func defaultBranchFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL) async throws -> String {
  { repoRoot in
    let output = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: ["repo", "view", "--json", "defaultBranchRef"],
      repoRoot: repoRoot
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try GithubCLIOutput.decode(GithubRepoViewResponse.self, from: output, decoder: decoder)
    return response.defaultBranchRef.name
  }
}

nonisolated private func resolveRemoteInfoFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL) async -> GithubRemoteInfo? {
  { repoRoot in
    do {
      let output = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: ["repo", "view", "--json", "owner,name,url"],
        repoRoot: repoRoot
      )
      guard let response = try GithubCLIOutput.decodeIfPresent(GithubRepoViewRemoteInfoResponse.self, from: output)
      else {
        return nil
      }
      return response.remoteInfo
    } catch {
      return nil
    }
  }
}

nonisolated private func latestRunFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, String, GithubAccountOverride?) async throws -> GithubWorkflowRun? {
  { repoRoot, branch, accountOverride in
    try await withExpectedGithubAccount(shell: shell, resolver: resolver, accountOverride: accountOverride) {
      let output = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: [
          "run",
          "list",
          "--branch",
          branch,
          "--limit",
          "1",
          "--json",
          "databaseId,workflowName,name,displayTitle,status,conclusion,createdAt,updatedAt",
        ],
        repoRoot: repoRoot
      )
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      // nil payload means no runs; a present-but-undecodable payload still throws.
      let runs = try GithubCLIOutput.decodeIfPresent([GithubWorkflowRun].self, from: output, decoder: decoder)
      return runs?.first
    }
  }
}

nonisolated private func batchPullRequestsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (String, String, String, [String], GithubAccountOverride?) async throws -> [String: GithubPullRequest] {
  { host, owner, repo, branches, accountOverride in
    try await withExpectedGithubAccount(
      shell: shell,
      resolver: resolver,
      host: host,
      accountOverride: accountOverride
    ) {
      let dedupedBranches = deduplicatedBranches(branches)
      guard !dedupedBranches.isEmpty else {
        return [:]
      }
      let request = GithubPullRequestsRequest(host: host, owner: owner, repo: repo)
      let chunks = makeBranchChunks(
        dedupedBranches,
        chunkSize: batchPullRequestsChunkSize
      )
      let chunkResults = try await loadPullRequestChunks(
        shell: shell,
        resolver: resolver,
        request: request,
        chunks: chunks
      )
      return mergePullRequestChunkResults(
        chunkResults,
        chunkCount: chunks.count
      )
    }
  }
}

nonisolated private let crossRepoBatchAliasLimit = 15
nonisolated private let crossRepoBatchMaxConcurrentRequests = 3

nonisolated private struct CrossRepoChunkOutcome: Sendable {
  let successByRepo: [RepoKey: [String: GithubPullRequest]]
  let failedRepos: [RepoKey: GithubCLIError]
}

nonisolated private func batchPullRequestsAcrossRepositoriesFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
)
  -> @Sendable (String, [CrossRepoPullRequestRequest], GithubAccountOverride?) async throws ->
  CrossRepoPullRequestResult
{
  { host, requests, accountOverride in
    try await withExpectedGithubAccount(
      shell: shell,
      resolver: resolver,
      host: host,
      accountOverride: accountOverride
    ) {
      let cleaned = sanitizeCrossRepoRequests(requests)
      guard !cleaned.isEmpty else {
        return CrossRepoPullRequestResult()
      }
      let chunks = makeCrossRepoChunks(cleaned, chunkSize: crossRepoBatchAliasLimit)
      let outcomes = try await loadCrossRepoChunks(
        shell: shell,
        resolver: resolver,
        host: host,
        chunks: chunks
      )
      return mergeCrossRepoChunkResults(outcomes)
    }
  }
}

nonisolated private func sanitizeCrossRepoRequests(
  _ requests: [CrossRepoPullRequestRequest]
) -> [CrossRepoPullRequestRequest] {
  var sanitized: [CrossRepoPullRequestRequest] = []
  for request in requests {
    var seen = Set<String>()
    let branches = request.branches.compactMap { value -> String? in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
        return nil
      }
      return trimmed
    }
    guard !branches.isEmpty else {
      continue
    }
    sanitized.append(
      CrossRepoPullRequestRequest(
        owner: request.owner,
        repo: request.repo,
        branches: branches,
        allowedHeadRepositories: request.allowedHeadRepositories
      )
    )
  }
  return sanitized
}

nonisolated private func makeCrossRepoChunks(
  _ requests: [CrossRepoPullRequestRequest],
  chunkSize: Int
) -> [[CrossRepoPullRequestRequest]] {
  guard !requests.isEmpty else {
    return []
  }
  var chunks: [[CrossRepoPullRequestRequest]] = []
  var index = 0
  while index < requests.count {
    let end = min(index + chunkSize, requests.count)
    chunks.append(Array(requests[index..<end]))
    index = end
  }
  return chunks
}

nonisolated private func loadCrossRepoChunks(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  host: String,
  chunks: [[CrossRepoPullRequestRequest]]
) async throws -> [CrossRepoChunkOutcome] {
  try await withThrowingTaskGroup(of: (Int, CrossRepoChunkOutcome).self) { group in
    var nextChunkIndex = 0
    let initialCount = min(crossRepoBatchMaxConcurrentRequests, chunks.count)
    while nextChunkIndex < initialCount {
      let chunkIndex = nextChunkIndex
      let chunk = chunks[chunkIndex]
      group.addTask {
        let outcome = try await fetchCrossRepoChunk(
          shell: shell,
          resolver: resolver,
          host: host,
          chunk: chunk
        )
        return (chunkIndex, outcome)
      }
      nextChunkIndex += 1
    }
    var resultsByIndex: [Int: CrossRepoChunkOutcome] = [:]
    while let (chunkIndex, outcome) = try await group.next() {
      resultsByIndex[chunkIndex] = outcome
      if nextChunkIndex < chunks.count {
        let candidateIndex = nextChunkIndex
        let candidateChunk = chunks[candidateIndex]
        group.addTask {
          let outcome = try await fetchCrossRepoChunk(
            shell: shell,
            resolver: resolver,
            host: host,
            chunk: candidateChunk
          )
          return (candidateIndex, outcome)
        }
        nextChunkIndex += 1
      }
    }
    return (0..<chunks.count).compactMap { resultsByIndex[$0] }
  }
}

nonisolated private func mergeCrossRepoChunkResults(
  _ outcomes: [CrossRepoChunkOutcome]
) -> CrossRepoPullRequestResult {
  var success: [RepoKey: [String: GithubPullRequest]] = [:]
  var failed: [RepoKey: GithubCLIError] = [:]
  for outcome in outcomes {
    for (key, prs) in outcome.successByRepo {
      success[key] = prs
    }
    for (key, error) in outcome.failedRepos {
      failed[key] = error
    }
  }
  return CrossRepoPullRequestResult(successByRepo: success, failedRepos: failed)
}

nonisolated private func fetchCrossRepoChunk(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  host: String,
  chunk: [CrossRepoPullRequestRequest]
) async throws -> CrossRepoChunkOutcome {
  let plan = makeCrossRepoBatchQuery(requests: chunk)
  let output = try await runGh(
    shell: shell,
    resolver: resolver,
    arguments: [
      "api",
      "graphql",
      "--hostname",
      host,
      "-f",
      "query=\(plan.query)",
    ],
    repoRoot: nil
  )
  guard !output.isEmpty else {
    var failed: [RepoKey: GithubCLIError] = [:]
    for key in plan.repoAliases.values {
      failed[key] = .commandFailed("Empty response from gh api graphql")
    }
    return CrossRepoChunkOutcome(successByRepo: [:], failedRepos: failed)
  }
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let response = try GithubCLIOutput.decode(CrossRepoPullRequestResponse.self, from: output, decoder: decoder)

  let errorMessagesByAlias = response.errorMessagesByAlias()
  var success: [RepoKey: [String: GithubPullRequest]] = [:]
  var failed: [RepoKey: GithubCLIError] = [:]
  for (alias, key) in plan.repoAliases {
    if let detail = errorMessagesByAlias[alias] {
      failed[key] = .commandFailed("GraphQL error for \(key.owner)/\(key.repo): \(detail)")
      continue
    }
    guard let payload = response.repositories[alias] else {
      failed[key] = .commandFailed("Missing response payload for \(key.owner)/\(key.repo)")
      continue
    }
    let branchAliasMap = plan.branchAliasesByRepo[alias] ?? [:]
    let prs = rankCrossRepoPullRequests(
      pullRequestsByAlias: payload.pullRequestsByAlias,
      aliasMap: branchAliasMap,
      allowedHeadRepositories: plan.allowedHeadRepositoriesByRepoAlias[alias] ?? [key]
    )
    success[key] = prs
  }
  return CrossRepoChunkOutcome(successByRepo: success, failedRepos: failed)
}

nonisolated private struct CrossRepoBatchQueryPlan: Sendable {
  let query: String
  let repoAliases: [String: RepoKey]
  let branchAliasesByRepo: [String: [String: String]]
  let allowedHeadRepositoriesByRepoAlias: [String: Set<RepoKey>]
}

nonisolated private func makeCrossRepoBatchQuery(
  requests: [CrossRepoPullRequestRequest]
) -> CrossRepoBatchQueryPlan {
  var repoAliases: [String: RepoKey] = [:]
  var branchAliasesByRepo: [String: [String: String]] = [:]
  var allowedHeadRepositoriesByRepoAlias: [String: Set<RepoKey>] = [:]
  var repoBlocks: [String] = []
  let orderBy = "orderBy: {field: UPDATED_AT, direction: DESC}"
  for (repoIndex, request) in requests.enumerated() {
    let repoAlias = "r\(repoIndex)"
    repoAliases[repoAlias] = RepoKey(owner: request.owner, repo: request.repo)
    allowedHeadRepositoriesByRepoAlias[repoAlias] = request.allowedHeadRepositories
    var branchAliasMap: [String: String] = [:]
    var selections: [String] = []
    for (branchIndex, branch) in request.branches.enumerated() {
      let branchAlias = "\(repoAlias)_b\(branchIndex)"
      branchAliasMap[branchAlias] = branch
      let escapedBranch = escapeGraphQLString(branch)
      let pullRequestsArgs =
        "first: 5, states: [OPEN, MERGED, CLOSED], headRefName: \"\(escapedBranch)\", \(orderBy)"
      let selection = """
          \(branchAlias): pullRequests(\(pullRequestsArgs)) {
            nodes {
              number
              title
              state
              additions
              deletions
              isDraft
              reviewDecision
              mergeable
              mergeStateStatus
              url
              updatedAt
              headRefName
              baseRefName
              commits {
                totalCount
              }
              author {
                login
              }
              headRepository {
                name
                owner { login }
              }
              mergeQueueEntry {
                position
                estimatedTimeToMerge
                state
              }
              statusCheckRollup {
                contexts(first: 100) {
                  nodes {
                    ... on CheckRun {
                      name
                      status
                      conclusion
                      startedAt
                      completedAt
                      detailsUrl
                    }
                    ... on StatusContext {
                      context
                      state
                      targetUrl
                      createdAt
                    }
                  }
                }
              }
            }
          }
        """
      selections.append(selection)
    }
    branchAliasesByRepo[repoAlias] = branchAliasMap
    let escapedOwner = escapeGraphQLString(request.owner)
    let escapedRepo = escapeGraphQLString(request.repo)
    let block = """
        \(repoAlias): repository(owner: \"\(escapedOwner)\", name: \"\(escapedRepo)\") {
      \(selections.joined(separator: "\n"))
        }
      """
    repoBlocks.append(block)
  }
  let query = """
    query {
    \(repoBlocks.joined(separator: "\n"))
    }
    """
  return CrossRepoBatchQueryPlan(
    query: query,
    repoAliases: repoAliases,
    branchAliasesByRepo: branchAliasesByRepo,
    allowedHeadRepositoriesByRepoAlias: allowedHeadRepositoriesByRepoAlias
  )
}

nonisolated private func rankCrossRepoPullRequests(
  pullRequestsByAlias: [String: GithubGraphQLPullRequestResponse.PullRequestConnection],
  aliasMap: [String: String],
  allowedHeadRepositories: Set<RepoKey>
) -> [String: GithubPullRequest] {
  var results: [String: GithubPullRequest] = [:]
  for (alias, connection) in pullRequestsByAlias {
    guard let branch = aliasMap[alias] else {
      continue
    }
    if let node = connection.bestMatchingPullRequest(allowedHeadRepositories: allowedHeadRepositories) {
      results[branch] = node.pullRequest
    }
  }
  return results
}

nonisolated private func mergePullRequestFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo, Int, PullRequestMergeStrategy, GithubAccountOverride?) async throws -> Void {
  { repoRoot, remoteInfo, pullRequestNumber, strategy, accountOverride in
    try await withExpectedGithubAccount(
      shell: shell,
      resolver: resolver,
      host: remoteInfo.host,
      accountOverride: accountOverride
    ) {
      _ = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: [
          "pr",
          "merge",
          "\(pullRequestNumber)",
          "--\(strategy.ghArgument)",
        ] + repoArgument(remoteInfo),
        repoRoot: repoRoot
      )
    }
  }
}

nonisolated private func closePullRequestFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo, Int, GithubAccountOverride?) async throws -> Void {
  { repoRoot, remoteInfo, pullRequestNumber, accountOverride in
    try await withExpectedGithubAccount(
      shell: shell,
      resolver: resolver,
      host: remoteInfo.host,
      accountOverride: accountOverride
    ) {
      _ = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: [
          "pr",
          "close",
          "\(pullRequestNumber)",
        ] + repoArgument(remoteInfo),
        repoRoot: repoRoot
      )
    }
  }
}

nonisolated private func markPullRequestReadyFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo, Int, GithubAccountOverride?) async throws -> Void {
  { repoRoot, remoteInfo, pullRequestNumber, accountOverride in
    try await withExpectedGithubAccount(
      shell: shell,
      resolver: resolver,
      host: remoteInfo.host,
      accountOverride: accountOverride
    ) {
      _ = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: [
          "pr",
          "ready",
          "\(pullRequestNumber)",
        ] + repoArgument(remoteInfo),
        repoRoot: repoRoot
      )
    }
  }
}

nonisolated private func repoArgument(_ remoteInfo: GithubRemoteInfo) -> [String] {
  ["--repo", "\(remoteInfo.host)/\(remoteInfo.owner)/\(remoteInfo.repo)"]
}

nonisolated private func rerunFailedJobsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int, GithubAccountOverride?) async throws -> Void {
  { repoRoot, runID, accountOverride in
    try await withExpectedGithubAccount(shell: shell, resolver: resolver, accountOverride: accountOverride) {
      _ = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: [
          "run",
          "rerun",
          "\(runID)",
          "--failed",
        ],
        repoRoot: repoRoot
      )
    }
  }
}

nonisolated private func failedRunLogsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int, GithubAccountOverride?) async throws -> String {
  { repoRoot, runID, accountOverride in
    try await withExpectedGithubAccount(shell: shell, resolver: resolver, accountOverride: accountOverride) {
      try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: [
          "run",
          "view",
          "\(runID)",
          "--log-failed",
        ],
        repoRoot: repoRoot
      )
    }
  }
}

nonisolated private func runLogsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int, GithubAccountOverride?) async throws -> String {
  { repoRoot, runID, accountOverride in
    try await withExpectedGithubAccount(shell: shell, resolver: resolver, accountOverride: accountOverride) {
      try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: [
          "run",
          "view",
          "\(runID)",
          "--log",
        ],
        repoRoot: repoRoot
      )
    }
  }
}

nonisolated private func isAvailableFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable () async -> Bool {
  {
    do {
      _ = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: ["--version"],
        repoRoot: nil
      )
      return true
    } catch {
      return false
    }
  }
}

nonisolated private func authStatusFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable () async throws -> GithubAuthStatus? {
  {
    let response = try await loadAuthStatusResponse(shell: shell, resolver: resolver)
    guard let active = GithubAuthStatusParsing.activeAccount(in: response) else {
      return nil
    }
    return GithubAuthStatus(username: active.login, host: active.host)
  }
}

nonisolated private func authStatusSnapshotFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable () async throws -> GithubAuthStatusSnapshot {
  {
    let response = try await loadAuthStatusResponse(shell: shell, resolver: resolver)
    return GithubAuthStatusSnapshot(response: response)
  }
}

nonisolated private func loadAuthStatusResponse(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  host: String? = nil,
  activeOnly: Bool = false
) async throws -> GithubAuthStatusResponse {
  var arguments = ["auth", "status"]
  if activeOnly {
    arguments.append("--active")
  }
  if let host {
    arguments.append(contentsOf: ["--hostname", host])
  }
  arguments.append(contentsOf: ["--json", "hosts"])
  let output = try await runGh(
    shell: shell,
    resolver: resolver,
    arguments: arguments,
    repoRoot: nil
  )
  return try GithubCLIOutput.decode(GithubAuthStatusResponse.self, from: output)
}

nonisolated private func withExpectedGithubAccount<Value>(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  host: String? = nil,
  accountOverride: GithubAccountOverride?,
  operation: () async throws -> Value
) async throws -> Value {
  guard let accountOverride = accountOverride?.normalized else {
    return try await operation()
  }
  if let host, host != accountOverride.host {
    throw GithubCLIError.commandFailed(
      "This repository uses \(host), but its GitHub account override is configured for "
        + "\(accountOverride.host)/\(accountOverride.login). Update the repository's GitHub identity setting."
    )
  }
  await GithubAccountSwitchLock.shared.acquire(host: accountOverride.host)
  let previousLogin: String?
  do {
    previousLogin = try await activeGithubLogin(
      shell: shell,
      resolver: resolver,
      host: accountOverride.host
    )
    if previousLogin != accountOverride.login {
      try await switchGithubAccount(
        shell: shell,
        resolver: resolver,
        accountOverride: accountOverride
      )
    }
  } catch {
    await GithubAccountSwitchLock.shared.release(host: accountOverride.host)
    throw error
  }
  do {
    let value = try await operation()
    await restoreGithubAccountIfNeeded(
      shell: shell,
      resolver: resolver,
      host: accountOverride.host,
      previousLogin: previousLogin,
      targetLogin: accountOverride.login
    )
    await GithubAccountSwitchLock.shared.release(host: accountOverride.host)
    return value
  } catch {
    await restoreGithubAccountIfNeeded(
      shell: shell,
      resolver: resolver,
      host: accountOverride.host,
      previousLogin: previousLogin,
      targetLogin: accountOverride.login
    )
    await GithubAccountSwitchLock.shared.release(host: accountOverride.host)
    throw error
  }
}

nonisolated private func activeGithubLogin(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  host: String
) async throws -> String? {
  let response = try await loadAuthStatusResponse(
    shell: shell,
    resolver: resolver,
    host: host,
    activeOnly: true
  )
  let snapshot = GithubAuthStatusSnapshot(response: response)
  return snapshot.activeAccount(on: host)?.login
}

nonisolated private func switchGithubAccount(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  accountOverride: GithubAccountOverride
) async throws {
  do {
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "auth",
        "switch",
        "--hostname",
        accountOverride.host,
        "--user",
        accountOverride.login,
      ],
      repoRoot: nil
    )
  } catch {
    throw GithubCLIError.commandFailed(
      "Prowl is configured to use \(accountOverride.login) on \(accountOverride.host), "
        + "but gh could not switch to that account. Run "
        + "`gh auth switch --hostname \(accountOverride.host) --user \(accountOverride.login)` and try again."
    )
  }
}

nonisolated private func restoreGithubAccountIfNeeded(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  host: String,
  previousLogin: String?,
  targetLogin: String
) async {
  guard let previousLogin, previousLogin != targetLogin else {
    return
  }
  do {
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "auth",
        "switch",
        "--hostname",
        host,
        "--user",
        previousLogin,
      ],
      repoRoot: nil
    )
  } catch {
    SupaLogger("GithubCLI").warning(
      "Failed to restore gh active account for \(host) to \(previousLogin): \(error.localizedDescription)"
    )
  }
}

nonisolated private func deduplicatedBranches(_ branches: [String]) -> [String] {
  var seen = Set<String>()
  return branches.filter { !$0.isEmpty && seen.insert($0).inserted }
}

nonisolated private let batchPullRequestsChunkSize = 25
nonisolated private let batchPullRequestsMaxConcurrentRequests = 3

nonisolated private func makeBranchChunks(
  _ branches: [String],
  chunkSize: Int
) -> [[String]] {
  guard !branches.isEmpty else {
    return []
  }

  var chunks: [[String]] = []
  var index = 0
  while index < branches.count {
    let end = min(index + chunkSize, branches.count)
    chunks.append(Array(branches[index..<end]))
    index = end
  }

  return chunks
}

nonisolated private func loadPullRequestChunks(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  request: GithubPullRequestsRequest,
  chunks: [[String]]
) async throws -> [Int: [String: GithubPullRequest]] {
  try await withThrowingTaskGroup(
    of: (Int, [String: GithubPullRequest]).self
  ) { group in
    var nextChunkIndex = 0
    let initialCount = min(batchPullRequestsMaxConcurrentRequests, chunks.count)
    while nextChunkIndex < initialCount {
      let chunkIndex = nextChunkIndex
      let chunk = chunks[chunkIndex]
      group.addTask {
        try await fetchPullRequestsChunk(
          shell: shell,
          resolver: resolver,
          request: request,
          chunk: chunk,
          chunkIndex: chunkIndex
        )
      }
      nextChunkIndex += 1
    }

    var resultsByChunkIndex: [Int: [String: GithubPullRequest]] = [:]
    while let (chunkIndex, prsByBranch) = try await group.next() {
      resultsByChunkIndex[chunkIndex] = prsByBranch
      if nextChunkIndex < chunks.count {
        let candidateIndex = nextChunkIndex
        let candidateChunk = chunks[candidateIndex]
        group.addTask {
          try await fetchPullRequestsChunk(
            shell: shell,
            resolver: resolver,
            request: request,
            chunk: candidateChunk,
            chunkIndex: candidateIndex
          )
        }
        nextChunkIndex += 1
      }
    }

    return resultsByChunkIndex
  }
}

nonisolated private func mergePullRequestChunkResults(
  _ chunkResults: [Int: [String: GithubPullRequest]],
  chunkCount: Int
) -> [String: GithubPullRequest] {
  var results: [String: GithubPullRequest] = [:]
  for chunkIndex in 0..<chunkCount {
    guard let prsByBranch = chunkResults[chunkIndex] else {
      continue
    }
    results.merge(prsByBranch) { _, new in new }
  }
  return results
}

nonisolated private func fetchPullRequestsChunk(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  request: GithubPullRequestsRequest,
  chunk: [String],
  chunkIndex: Int
) async throws -> (Int, [String: GithubPullRequest]) {
  let (query, aliasMap) = makeBatchPullRequestsQuery(branches: chunk)
  let output = try await runGh(
    shell: shell,
    resolver: resolver,
    arguments: [
      "api",
      "graphql",
      "--hostname",
      request.host,
      "-f",
      "query=\(query)",
      "-f",
      "owner=\(request.owner)",
      "-f",
      "repo=\(request.repo)",
    ],
    repoRoot: nil
  )
  guard !output.isEmpty else {
    return (chunkIndex, [:])
  }

  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let response = try GithubCLIOutput.decode(GithubGraphQLPullRequestResponse.self, from: output, decoder: decoder)
  let prsByBranch = response.pullRequestsByBranch(
    aliasMap: aliasMap,
    owner: request.owner,
    repo: request.repo
  )
  return (chunkIndex, prsByBranch)
}

nonisolated private func makeBatchPullRequestsQuery(
  branches: [String]
) -> (query: String, aliasMap: [String: String]) {
  var aliasMap: [String: String] = [:]
  var selections: [String] = []
  for (index, branch) in branches.enumerated() {
    let alias = "branch\(index)"
    aliasMap[alias] = branch
    let escapedBranch = escapeGraphQLString(branch)
    let orderBy = "orderBy: {field: UPDATED_AT, direction: DESC}"
    let selection = """
      \(alias): pullRequests(first: 5, states: [OPEN, MERGED, CLOSED], headRefName: \"\(escapedBranch)\", \(orderBy)) {
        nodes {
          number
          title
          state
          additions
          deletions
          isDraft
          reviewDecision
          mergeable
          mergeStateStatus
          url
          updatedAt
          headRefName
          baseRefName
          commits {
            totalCount
          }
          author {
            login
          }
          headRepository {
            name
            owner { login }
          }
          mergeQueueEntry {
            position
            estimatedTimeToMerge
            state
          }
          statusCheckRollup {
            contexts(first: 100) {
              nodes {
                ... on CheckRun {
                  name
                  status
                  conclusion
                  startedAt
                  completedAt
                  detailsUrl
                }
                ... on StatusContext {
                  context
                  state
                  targetUrl
                  createdAt
                }
              }
            }
          }
        }
      }
      """
    selections.append(selection)
  }
  let selectionBlock = selections.joined(separator: "\n")
  let query = """
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
    \(selectionBlock)
      }
    }
    """
  return (query, aliasMap)
}

nonisolated private func escapeGraphQLString(_ value: String) -> String {
  value
    .replacing("\\", with: "\\\\")
    .replacing("\"", with: "\\\"")
    .replacing("\n", with: "\\n")
    .replacing("\r", with: "\\r")
    .replacing("\t", with: "\\t")
}

nonisolated private func isOutdatedGitHubCLI(_ error: ShellClientError) -> Bool {
  let combined = "\(error.stdout)\n\(error.stderr)".lowercased()
  if combined.contains("unknown flag: --json") {
    return true
  }
  if combined.contains("unknown shorthand flag") && combined.contains("json") {
    return true
  }
  return false
}

nonisolated private func runGh(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  arguments: [String],
  repoRoot: URL?
) async throws -> String {
  let command = (["gh"] + arguments).joined(separator: " ")
  do {
    let executableURL = try await resolver.executableURL(shell: shell)
    do {
      return try await shell.runLogin(executableURL, arguments, repoRoot, log: false).stdout
    } catch {
      guard shouldRetryGhExecution(after: error) else {
        throw error
      }
      await resolver.invalidate()
      let executableURL = try await resolver.executableURL(shell: shell)
      return try await shell.runLogin(executableURL, arguments, repoRoot, log: false).stdout
    }
  } catch let error as GithubCLIError {
    throw error
  } catch {
    if let shellError = error as? ShellClientError {
      if isOutdatedGitHubCLI(shellError) {
        throw GithubCLIError.outdated
      }
      let message = shellError.errorDescription ?? "Command failed: \(command)"
      throw GithubCLIError.commandFailed(message)
    }
    throw GithubCLIError.commandFailed(error.localizedDescription)
  }
}

nonisolated private func shouldRetryGhExecution(after error: Error) -> Bool {
  if let shellError = error as? ShellClientError {
    let combined = "\(shellError.stdout)\n\(shellError.stderr)".lowercased()
    if combined.contains("no such file or directory") || combined.contains("command not found") {
      return true
    }
    if shellError.exitCode == 127 {
      return true
    }
  }
  let nsError = error as NSError
  if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
    return true
  }
  if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
    return true
  }
  return false
}
