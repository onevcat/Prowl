import Foundation
import Testing

@testable import supacode

actor GithubBatchShellProbe {
  struct Snapshot {
    let ghCallCount: Int
    let maxInFlight: Int
    let whichCallCount: Int
    let loginCallCount: Int
  }

  private var ghCallCount = 0
  private var inFlight = 0
  private var maxInFlight = 0
  private var whichCallCount = 0
  private var loginCallCount = 0

  func beginGhCall() -> Int {
    ghCallCount += 1
    inFlight += 1
    if inFlight > maxInFlight {
      maxInFlight = inFlight
    }
    return ghCallCount
  }

  func endGhCall() {
    inFlight -= 1
  }

  func recordWhichCall() {
    whichCallCount += 1
  }

  func recordLoginCall() {
    loginCallCount += 1
  }

  func snapshot() -> Snapshot {
    Snapshot(
      ghCallCount: ghCallCount,
      maxInFlight: maxInFlight,
      whichCallCount: whichCallCount,
      loginCallCount: loginCallCount
    )
  }
}

actor GithubCommandProbe {
  struct Call: Equatable {
    let arguments: [String]
    let currentDirectoryURL: URL?
  }

  private var calls: [Call] = []

  func record(arguments: [String], currentDirectoryURL: URL?) {
    calls.append(Call(arguments: arguments, currentDirectoryURL: currentDirectoryURL))
  }

  func snapshot() -> [Call] {
    calls
  }
}

struct GithubCLIClientTests {
  @Test func resolveRemoteInfoUsesGhRepoView() async throws {
    let repoRoot = URL(fileURLWithPath: "/tmp/fork")
    let probe = GithubCommandProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.record(arguments: arguments, currentDirectoryURL: currentDirectoryURL)
        return ShellOutput(
          stdout: #"{"owner":{"login":"supabitapp"},"name":"supacode","url":"https://github.com/supabitapp/supacode"}"#,
          stderr: "",
          exitCode: 0
        )
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    let remoteInfo = await client.resolveRemoteInfo(repoRoot)

    #expect(remoteInfo == GithubRemoteInfo(host: "github.com", owner: "supabitapp", repo: "supacode"))
    let calls = await probe.snapshot()
    #expect(
      calls == [
        GithubCommandProbe.Call(
          arguments: ["repo", "view", "--json", "owner,name,url"],
          currentDirectoryURL: repoRoot
        )
      ])
  }

  @Test func pullRequestMutationsUseResolvedRemoteInfo() async throws {
    let repoRoot = URL(fileURLWithPath: "/tmp/fork")
    let remoteInfo = GithubRemoteInfo(host: "github.enterprise.test", owner: "octo", repo: "repo")
    let probe = GithubCommandProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.record(arguments: arguments, currentDirectoryURL: currentDirectoryURL)
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    try await client.mergePullRequest(repoRoot, remoteInfo, 12, .squash, nil)
    try await client.closePullRequest(repoRoot, remoteInfo, 13, nil)
    try await client.markPullRequestReady(repoRoot, remoteInfo, 14, nil)

    let calls = await probe.snapshot()
    #expect(
      calls.map(\.arguments) == [
        ["pr", "merge", "12", "--squash", "--repo", "github.enterprise.test/octo/repo"],
        ["pr", "close", "13", "--repo", "github.enterprise.test/octo/repo"],
        ["pr", "ready", "14", "--repo", "github.enterprise.test/octo/repo"],
      ])
    #expect(calls.allSatisfy { $0.currentDirectoryURL == repoRoot })
  }

  @Test func pullRequestMutationChecksExpectedAccountBeforeCommand() async throws {
    let repoRoot = URL(fileURLWithPath: "/tmp/private")
    let remoteInfo = GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo")
    let account = GithubAccountOverride(host: "github.com", login: "work")
    let probe = GithubCommandProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.record(arguments: arguments, currentDirectoryURL: currentDirectoryURL)
        if arguments.starts(with: ["auth", "status"]) {
          return ShellOutput(
            stdout: #"{"hosts":{"github.com":[{"active":true,"login":"work","state":"success"}]}}"#,
            stderr: "",
            exitCode: 0
          )
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    try await client.mergePullRequest(repoRoot, remoteInfo, 12, .squash, account)

    let calls = await probe.snapshot()
    #expect(
      calls.map(\.arguments) == [
        ["auth", "status", "--active", "--hostname", "github.com", "--json", "hosts"],
        ["pr", "merge", "12", "--squash", "--repo", "github.com/octo/repo"],
      ])
  }

  @Test func pullRequestMutationSwitchesAndRestoresExpectedAccount() async throws {
    let repoRoot = URL(fileURLWithPath: "/tmp/private")
    let remoteInfo = GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo")
    let account = GithubAccountOverride(host: "github.com", login: "work")
    let probe = GithubCommandProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.record(arguments: arguments, currentDirectoryURL: currentDirectoryURL)
        return ShellOutput(
          stdout: #"{"hosts":{"github.com":[{"active":true,"login":"personal","state":"success"}]}}"#,
          stderr: "",
          exitCode: 0
        )
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    try await client.mergePullRequest(repoRoot, remoteInfo, 12, .squash, account)

    let calls = await probe.snapshot()
    #expect(
      calls.map(\.arguments) == [
        ["auth", "status", "--active", "--hostname", "github.com", "--json", "hosts"],
        ["auth", "switch", "--hostname", "github.com", "--user", "work"],
        ["pr", "merge", "12", "--squash", "--repo", "github.com/octo/repo"],
        ["auth", "switch", "--hostname", "github.com", "--user", "personal"],
      ])
  }

  @Test func batchPullRequestsCapsConcurrencyAtThree() async throws {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, arguments, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        _ = arguments
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        do {
          try await ContinuousClock().sleep(for: .milliseconds(80))
          let stdout = graphQLResponse(for: arguments)
          await probe.endGhCall()
          return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
        } catch {
          await probe.endGhCall()
          throw error
        }
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let branches = (0..<100).map { "feature-\($0)" }

    _ = try await client.batchPullRequests("github.com", "khoi", "repo", branches, nil)

    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 4)
    #expect(snapshot.maxInFlight == 3)
    #expect(snapshot.whichCallCount == 1)
    #expect(snapshot.loginCallCount == 4)
  }

  @Test func batchPullRequestsThrowsWhenAnyChunkFails() async {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, arguments, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        _ = arguments
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        let callIndex = await probe.beginGhCall()
        if callIndex == 2 {
          await probe.endGhCall()
          throw ShellClientError(
            command: "gh api graphql",
            stdout: "",
            stderr: "boom",
            exitCode: 1
          )
        }
        do {
          try await ContinuousClock().sleep(for: .milliseconds(40))
          let stdout = graphQLResponse(for: arguments)
          await probe.endGhCall()
          return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
        } catch {
          await probe.endGhCall()
          throw error
        }
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let branches = (0..<30).map { "feature-\($0)" }

    do {
      _ = try await client.batchPullRequests("github.com", "khoi", "repo", branches, nil)
      Issue.record("Expected batchPullRequests to throw")
    } catch let error as GithubCLIError {
      switch error {
      case .commandFailed:
        break
      case .outdated, .unavailable:
        Issue.record("Unexpected GithubCLIError: \(error.localizedDescription)")
      }
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
  }

  @Test func batchPullRequestsDeduplicatesBeforeChunking() async throws {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, arguments, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        _ = arguments
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        let stdout = graphQLResponse(for: arguments)
        await probe.endGhCall()
        return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let uniqueBranches = (0..<30).map { "feature-\($0)" }
    let branches = uniqueBranches + ["feature-0", "feature-1", "feature-2", "", ""]

    let result = try await client.batchPullRequests("github.com", "khoi", "repo", branches, nil)

    #expect(result.isEmpty)
    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 2)
    #expect(snapshot.whichCallCount == 1)
    #expect(snapshot.loginCallCount == 2)
  }

  @Test func batchAcrossRepositoriesReturnsEmptyResultWhenNoRequests() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { _ in
      ShellOutput(stdout: #"{"data":{}}"#, stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", [], nil)

    #expect(result.successByRepo.isEmpty)
    #expect(result.failedRepos.isEmpty)
    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 0)
    #expect(snapshot.whichCallCount == 0)
  }

  @Test func batchAcrossRepositoriesSkipsReposWithoutBranches() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "khoi", repo: "alpha", branches: []),
      CrossRepoPullRequestRequest(owner: "khoi", repo: "beta", branches: ["", "  "]),
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    #expect(result.successByRepo.isEmpty)
    #expect(result.failedRepos.isEmpty)
    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 0)
  }

  @Test func batchAcrossRepositoriesSendsSingleGraphQLCallForMultipleRepos() async throws {
    let probe = GithubBatchShellProbe()
    let observedArguments = ObservedArguments()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      await observedArguments.append(arguments)
      return ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "khoi", repo: "alpha", branches: ["feat-1", "feat-2"]),
      CrossRepoPullRequestRequest(owner: "supabit", repo: "beta", branches: ["feat-3"]),
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    #expect(result.successByRepo[RepoKey(owner: "khoi", repo: "alpha")] != nil)
    #expect(result.successByRepo[RepoKey(owner: "supabit", repo: "beta")] != nil)
    #expect(result.failedRepos.isEmpty)
    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 1)
    let invocations = await observedArguments.snapshot()
    #expect(invocations.count == 1)
  }

  @Test func batchAcrossRepositoriesUsesProvidedHostnameInGhArguments() async throws {
    let probe = GithubBatchShellProbe()
    let observedArguments = ObservedArguments()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      await observedArguments.append(arguments)
      return ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "octo", repo: "ghe-repo", branches: ["main"])
    ]

    _ = try await client.batchPullRequestsAcrossRepositories("github.enterprise.test", requests, nil)

    let invocations = await observedArguments.snapshot()
    #expect(invocations.count == 1)
    let firstCall = try #require(invocations.first)
    #expect(firstCall.contains("api"))
    #expect(firstCall.contains("graphql"))
    let hostnameIndex = try #require(firstCall.firstIndex(of: "--hostname"))
    #expect(firstCall[firstCall.index(after: hostnameIndex)] == "github.enterprise.test")
  }

  @Test func batchAcrossRepositoriesEmbedsOwnerAndRepoLiteralsInQuery() async throws {
    let probe = GithubBatchShellProbe()
    let observedArguments = ObservedArguments()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      await observedArguments.append(arguments)
      return ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "khoi", repo: "alpha", branches: ["feat-1"]),
      CrossRepoPullRequestRequest(owner: "supabit", repo: "beta", branches: ["feat-2"]),
    ]

    _ = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    let invocations = await observedArguments.snapshot()
    let queryArgument = try #require(invocations.first?.first(where: { $0.hasPrefix("query=") }))
    let query = String(queryArgument.dropFirst("query=".count))
    #expect(query.contains(#"owner: "khoi""#))
    #expect(query.contains(#"name: "alpha""#))
    #expect(query.contains(#"owner: "supabit""#))
    #expect(query.contains(#"name: "beta""#))
    let structure = parseCrossRepoQuery(query)
    #expect(structure.repos.count == 2)
    #expect(structure.repos.allSatisfy { !$0.branchAliases.isEmpty })
  }

  @Test func batchAcrossRepositoriesDeduplicatesBranchesPerRepo() async throws {
    let probe = GithubBatchShellProbe()
    let observedArguments = ObservedArguments()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      await observedArguments.append(arguments)
      return ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(
        owner: "khoi",
        repo: "alpha",
        branches: ["feat-1", "feat-1", "feat-2", "", "feat-2"]
      )
    ]

    _ = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    let invocations = await observedArguments.snapshot()
    let queryArgument = try #require(invocations.first?.first(where: { $0.hasPrefix("query=") }))
    let structure = parseCrossRepoQuery(String(queryArgument.dropFirst("query=".count)))
    let alpha = try #require(structure.repos.first { $0.repo == "alpha" })
    #expect(alpha.branchAliases.count == 2)
  }

  @Test func batchAcrossRepositoriesSplitsAtAliasLimit() async throws {
    let probe = GithubBatchShellProbe()
    let observedArguments = ObservedArguments()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      await observedArguments.append(arguments)
      return ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = (0..<18).map { index in
      CrossRepoPullRequestRequest(owner: "khoi", repo: "repo-\(index)", branches: ["main"])
    }

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 2)
    let invocations = await observedArguments.snapshot()
    #expect(invocations.count == 2)
    let totalRepoBlocks = invocations.reduce(0) { partial, args in
      guard let queryArg = args.first(where: { $0.hasPrefix("query=") }) else {
        return partial
      }
      let query = String(queryArg.dropFirst("query=".count))
      return partial + parseCrossRepoQuery(query).repos.count
    }
    #expect(totalRepoBlocks == 18)
    #expect(result.successByRepo.count == 18)
    #expect(result.failedRepos.isEmpty)
  }

  @Test func batchAcrossRepositoriesCapsConcurrencyAtThree() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      try await ContinuousClock().sleep(for: .milliseconds(80))
      return ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = (0..<60).map { index in
      CrossRepoPullRequestRequest(owner: "khoi", repo: "repo-\(index)", branches: ["main"])
    }

    _ = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 4)
    #expect(snapshot.maxInFlight == 3)
  }

  @Test func batchAcrossRepositoriesRoutesPartialErrorsToFailedRepos() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      let stdout = crossRepoGraphQLResponse(for: arguments, failedRepoAliases: ["r1"])
      return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "khoi", repo: "alpha", branches: ["feat-1"]),
      CrossRepoPullRequestRequest(owner: "ghost", repo: "missing", branches: ["main"]),
      CrossRepoPullRequestRequest(owner: "supabit", repo: "beta", branches: ["feat-2"]),
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    #expect(result.successByRepo[RepoKey(owner: "khoi", repo: "alpha")] != nil)
    #expect(result.successByRepo[RepoKey(owner: "supabit", repo: "beta")] != nil)
    #expect(result.failedRepos[RepoKey(owner: "ghost", repo: "missing")] != nil)
  }

  @Test func batchAcrossRepositoriesRoutesFieldErrorPathToOwnRepo() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      let stdout = crossRepoGraphQLResponse(
        for: arguments,
        fieldErrorPaths: [["r0", "r0_b1"]]
      )
      return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "khoi", repo: "alpha", branches: ["feat-1", "feat-2"]),
      CrossRepoPullRequestRequest(owner: "supabit", repo: "beta", branches: ["feat-3"]),
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    #expect(result.failedRepos[RepoKey(owner: "khoi", repo: "alpha")] != nil)
    #expect(result.successByRepo[RepoKey(owner: "supabit", repo: "beta")] != nil)
  }

  @Test func batchAcrossRepositoriesReturnsAllFailedWhenAllReposErrored() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      let stdout = crossRepoGraphQLResponse(
        for: arguments,
        failedRepoAliases: ["r0", "r1"]
      )
      return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "khoi", repo: "alpha", branches: ["feat-1"]),
      CrossRepoPullRequestRequest(owner: "supabit", repo: "beta", branches: ["feat-2"]),
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    #expect(result.successByRepo.isEmpty)
    #expect(result.failedRepos.count == 2)
  }

  @Test func batchAcrossRepositoriesThrowsOnTotalShellFailure() async {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { _ in
      throw ShellClientError(
        command: "gh api graphql",
        stdout: "",
        stderr: "boom",
        exitCode: 1
      )
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "khoi", repo: "alpha", branches: ["feat-1"])
    ]

    do {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)
      Issue.record("Expected batchPullRequestsAcrossRepositories to throw")
    } catch let error as GithubCLIError {
      switch error {
      case .commandFailed:
        break
      case .outdated, .unavailable:
        Issue.record("Unexpected GithubCLIError: \(error.localizedDescription)")
      }
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
  }

  @Test func batchAcrossRepositoriesEscapesBranchSpecialCharacters() async throws {
    let probe = GithubBatchShellProbe()
    let observedArguments = ObservedArguments()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      await observedArguments.append(arguments)
      return ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(
        owner: "khoi",
        repo: "alpha",
        branches: [#"weird"branch"#, "tab\there", "back\\slash"]
      )
    ]

    _ = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    let invocations = await observedArguments.snapshot()
    let queryArgument = try #require(invocations.first?.first(where: { $0.hasPrefix("query=") }))
    let query = String(queryArgument.dropFirst("query=".count))
    #expect(query.contains(#"\""#))
    #expect(query.contains(#"\t"#))
    #expect(query.contains(#"\\"#))
  }

  @Test func batchAcrossRepositoriesSurfacesDecodedPullRequestData() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      let stdout = crossRepoGraphQLResponseWithSinglePR(
        for: arguments,
        prNumber: 42
      )
      return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "khoi", repo: "alpha", branches: ["feat-1"])
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    let alphaPRs = try #require(result.successByRepo[RepoKey(owner: "khoi", repo: "alpha")])
    let pullRequest = try #require(alphaPRs["feat-1"])
    #expect(pullRequest.number == 42)
  }

  @Test func batchAcrossRepositoriesIgnoresForkOnlyPullRequestMatches() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      let stdout = crossRepoGraphQLResponseWithForkOnlyPR(
        for: arguments,
        prNumber: 2174
      )
      return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let requests = [
      CrossRepoPullRequestRequest(owner: "onevcat", repo: "Kingfisher", branches: ["master"])
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    let kingfisherPRs = try #require(result.successByRepo[RepoKey(owner: "onevcat", repo: "Kingfisher")])
    #expect(kingfisherPRs["master"] == nil)
  }

  @Test func batchAcrossRepositoriesAllowsPullRequestFromConfiguredHeadRemote() async throws {
    let probe = GithubBatchShellProbe()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      let stdout = crossRepoGraphQLResponseWithHeadRepositoryPR(
        for: arguments,
        fixture: HeadRepositoryPRFixture(
          baseOwner: "supabitapp",
          baseRepo: "supacode",
          headOwner: "onevcat",
          headRepo: "Prowl",
          branch: "feature"
        )
      )
      return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let allowedHeadRepositories: Set<RepoKey> = [
      RepoKey(owner: "onevcat", repo: "Prowl"),
      RepoKey(owner: "supabitapp", repo: "supacode"),
    ]
    let requests = [
      CrossRepoPullRequestRequest(
        owner: "onevcat",
        repo: "Prowl",
        branches: ["feature"],
        allowedHeadRepositories: allowedHeadRepositories
      ),
      CrossRepoPullRequestRequest(
        owner: "supabitapp",
        repo: "supacode",
        branches: ["feature"],
        allowedHeadRepositories: allowedHeadRepositories
      ),
    ]

    let result = try await client.batchPullRequestsAcrossRepositories("github.com", requests, nil)

    let upstreamPRs = try #require(result.successByRepo[RepoKey(owner: "supabitapp", repo: "supacode")])
    #expect(upstreamPRs["feature"]?.number == 42)
  }

  @Test func executableResolutionIsSingleFlightAndReused() async {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, _, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        await probe.endGhCall()
        return ShellOutput(stdout: "gh version 2.79.0", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    let first = await client.isAvailable()
    let second = await client.isAvailable()

    #expect(first)
    #expect(second)
    let snapshot = await probe.snapshot()
    #expect(snapshot.whichCallCount == 1)
    #expect(snapshot.ghCallCount == 2)
    #expect(snapshot.loginCallCount == 2)
  }

  @Test func executableResolutionFallsBackToCommonInstallPathWhenShellPathMissesGh() async throws {
    let fallbackDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-gh-fallback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: fallbackDirectory)
    }
    let fallbackGh = fallbackDirectory.appendingPathComponent("gh")
    let created = FileManager.default.createFile(
      atPath: fallbackGh.path,
      contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: 0o755]
    )
    #expect(created)

    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          throw ShellClientError(command: "which gh", stdout: "", stderr: "gh not found", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          throw ShellClientError(command: "which gh", stdout: "", stderr: "gh not found", exitCode: 1)
        }
        #expect(executableURL == fallbackGh)
        #expect(arguments == ["--version"])
        await probe.recordLoginCall()
        return ShellOutput(stdout: "gh version 2.79.0", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell, fallbackExecutableURLs: [fallbackGh])

    #expect(await client.isAvailable())

    let snapshot = await probe.snapshot()
    #expect(snapshot.whichCallCount == 2)
    #expect(snapshot.loginCallCount == 1)
  }

  @Test func executableResolutionReportsUnavailableWhenNoFallbackPathResolves() async throws {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          throw ShellClientError(command: "which gh", stdout: "", stderr: "gh not found", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, _, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          throw ShellClientError(command: "which gh", stdout: "", stderr: "gh not found", exitCode: 1)
        }
        await probe.recordLoginCall()
        return ShellOutput(stdout: "gh version 2.79.0", stderr: "", exitCode: 0)
      }
    )
    let missingGh = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-gh-missing-\(UUID().uuidString)/gh")
    let client = GithubCLIClient.live(shell: shell, fallbackExecutableURLs: [missingGh])

    #expect(await client.isAvailable() == false)

    let snapshot = await probe.snapshot()
    #expect(snapshot.whichCallCount == 2)
    #expect(snapshot.loginCallCount == 0)
  }

  @Test func executableResolutionPicksFirstExecutableFallbackAndSkipsMisses() async throws {
    let fallbackDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-gh-order-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: fallbackDirectory)
    }
    let missingGh = fallbackDirectory.appendingPathComponent("missing/gh")
    let nonExecutableGh = fallbackDirectory.appendingPathComponent("non-executable-gh")
    #expect(
      FileManager.default.createFile(
        atPath: nonExecutableGh.path,
        contents: Data("#!/bin/sh\n".utf8),
        attributes: [.posixPermissions: 0o644]
      )
    )
    let firstExecutableGh = fallbackDirectory.appendingPathComponent("first-gh")
    let laterExecutableGh = fallbackDirectory.appendingPathComponent("later-gh")
    for executable in [firstExecutableGh, laterExecutableGh] {
      #expect(
        FileManager.default.createFile(
          atPath: executable.path,
          contents: Data("#!/bin/sh\n".utf8),
          attributes: [.posixPermissions: 0o755]
        )
      )
    }

    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          throw ShellClientError(command: "which gh", stdout: "", stderr: "gh not found", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, _, _, _ in
        if executableURL.lastPathComponent == "which" {
          throw ShellClientError(command: "which gh", stdout: "", stderr: "gh not found", exitCode: 1)
        }
        // First executable entry wins: missing and non-executable candidates are skipped.
        #expect(executableURL == firstExecutableGh)
        return ShellOutput(stdout: "gh version 2.79.0", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(
      shell: shell,
      fallbackExecutableURLs: [missingGh, nonExecutableGh, firstExecutableGh, laterExecutableGh]
    )

    #expect(await client.isAvailable())
  }

  @Test func defaultFallbackExecutableURLsOrdersPathsAndDropsHomeWhenAbsent() {
    let withHome = GithubCLIExecutableResolver.defaultFallbackExecutableURLs(
      environment: ["HOME": "/Users/tester"]
    )
    #expect(
      withHome.map(\.path) == [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/Users/tester/.local/bin/gh",
      ]
    )

    let withoutHome = GithubCLIExecutableResolver.defaultFallbackExecutableURLs(environment: [:])
    #expect(
      withoutHome.map(\.path) == [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
      ]
    )
  }
}

nonisolated private func graphQLResponse(for arguments: [String]) -> String {
  guard let queryArgument = arguments.first(where: { $0.hasPrefix("query=") }) else {
    return #"{"data":{"repository":{}}}"#
  }
  let query = String(queryArgument.dropFirst("query=".count))
  let aliases = queryAliases(from: query)
  let entries = aliases.map { #""\#($0)":{"nodes":[]}"# }.joined(separator: ",")
  return #"{"data":{"repository":{\#(entries)}}}"#
}

nonisolated private func queryAliases(from query: String) -> [String] {
  guard let regex = try? NSRegularExpression(pattern: #"branch\d+"#) else {
    return []
  }
  let range = NSRange(query.startIndex..<query.endIndex, in: query)
  var seen = Set<String>()
  var aliases: [String] = []
  for match in regex.matches(in: query, range: range) {
    guard let aliasRange = Range(match.range, in: query) else {
      continue
    }
    let alias = String(query[aliasRange])
    if seen.insert(alias).inserted {
      aliases.append(alias)
    }
  }
  return aliases
}

nonisolated struct CrossRepoQueryStructure {
  let repos: [Entry]

  struct Entry {
    let alias: String
    let owner: String
    let repo: String
    let branchAliases: [String]
  }
}

nonisolated func parseCrossRepoQuery(_ query: String) -> CrossRepoQueryStructure {
  guard
    let repoRegex = try? NSRegularExpression(
      pattern: #"(r\d+):\s*repository\(owner:\s*"([^"]+)",\s*name:\s*"([^"]+)"\)"#
    )
  else {
    return CrossRepoQueryStructure(repos: [])
  }
  let nsQuery = query as NSString
  let queryRange = NSRange(location: 0, length: nsQuery.length)
  var entries: [CrossRepoQueryStructure.Entry] = []
  let repoMatches = repoRegex.matches(in: query, range: queryRange)
  for (matchIndex, match) in repoMatches.enumerated() {
    let alias = nsQuery.substring(with: match.range(at: 1))
    let owner = nsQuery.substring(with: match.range(at: 2))
    let repo = nsQuery.substring(with: match.range(at: 3))
    let blockStart = match.range.location + match.range.length
    let blockEnd: Int
    if matchIndex + 1 < repoMatches.count {
      blockEnd = repoMatches[matchIndex + 1].range.location
    } else {
      blockEnd = nsQuery.length
    }
    guard blockEnd > blockStart else {
      continue
    }
    let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
    let block = nsQuery.substring(with: blockRange)
    let branchAliases = matchedAliases(in: block, pattern: "\(alias)_b\\d+")
    entries.append(
      CrossRepoQueryStructure.Entry(alias: alias, owner: owner, repo: repo, branchAliases: branchAliases)
    )
  }
  return CrossRepoQueryStructure(repos: entries)
}

nonisolated private func matchedAliases(in text: String, pattern: String) -> [String] {
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return []
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  var seen = Set<String>()
  var aliases: [String] = []
  for match in regex.matches(in: text, range: range) {
    guard let matchRange = Range(match.range, in: text) else {
      continue
    }
    let alias = String(text[matchRange])
    if seen.insert(alias).inserted {
      aliases.append(alias)
    }
  }
  return aliases
}

nonisolated func crossRepoGraphQLResponse(
  for arguments: [String],
  failedRepoAliases: Set<String> = [],
  fieldErrorPaths: [[String]] = []
) -> String {
  guard let queryArgument = arguments.first(where: { $0.hasPrefix("query=") }) else {
    return #"{"data":null}"#
  }
  let query = String(queryArgument.dropFirst("query=".count))
  let structure = parseCrossRepoQuery(query)
  var dataEntries: [String] = []
  for entry in structure.repos {
    if failedRepoAliases.contains(entry.alias) {
      dataEntries.append(#""\#(entry.alias)":null"#)
      continue
    }
    let aliasEntries = entry.branchAliases.map { #""\#($0)":{"nodes":[]}"# }.joined(separator: ",")
    dataEntries.append(#""\#(entry.alias)":{\#(aliasEntries)}"#)
  }
  let dataJSON = "{\(dataEntries.joined(separator: ","))}"
  var errorEntries: [String] = []
  for alias in failedRepoAliases {
    errorEntries.append(
      #"{"path":["\#(alias)"],"message":"Could not resolve to a Repository","type":"NOT_FOUND"}"#
    )
  }
  for path in fieldErrorPaths {
    let serializedPath = path.map { #""\#($0)""# }.joined(separator: ",")
    errorEntries.append(#"{"path":[\#(serializedPath)],"message":"Field error"}"#)
  }
  if errorEntries.isEmpty {
    return #"{"data":\#(dataJSON)}"#
  }
  let errorsJSON = "[\(errorEntries.joined(separator: ","))]"
  return #"{"data":\#(dataJSON),"errors":\#(errorsJSON)}"#
}

actor ObservedArguments {
  private var calls: [[String]] = []

  func append(_ arguments: [String]) {
    calls.append(arguments)
  }

  func snapshot() -> [[String]] {
    calls
  }
}

nonisolated func crossRepoGraphQLResponseWithSinglePR(
  for arguments: [String],
  prNumber: Int
) -> String {
  guard let queryArgument = arguments.first(where: { $0.hasPrefix("query=") }) else {
    return #"{"data":{}}"#
  }
  let structure = parseCrossRepoQuery(String(queryArgument.dropFirst("query=".count)))
  var repositoryPayload: [String: Any] = [:]
  for (entryIndex, entry) in structure.repos.enumerated() {
    var aliasPayload: [String: Any] = [:]
    for (branchIndex, alias) in entry.branchAliases.enumerated() {
      let node: [String: Any] = [
        "number": prNumber + entryIndex * 100 + branchIndex,
        "title": "PR",
        "state": "OPEN",
        "additions": 1,
        "deletions": 1,
        "isDraft": false,
        "reviewDecision": NSNull(),
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "url": "https://example.com/pr",
        "updatedAt": NSNull(),
        "headRefName": NSNull(),
        "baseRefName": "main",
        "commits": ["totalCount": 1],
        "author": ["login": "khoi"],
        "headRepository": [
          "name": entry.repo,
          "owner": ["login": entry.owner],
        ],
        "statusCheckRollup": NSNull(),
      ]
      aliasPayload[alias] = ["nodes": [node]]
    }
    repositoryPayload[entry.alias] = aliasPayload
  }
  let body: [String: Any] = ["data": repositoryPayload]
  guard let data = try? JSONSerialization.data(withJSONObject: body),
    let json = String(bytes: data, encoding: .utf8)
  else {
    return #"{"data":{}}"#
  }
  return json
}

nonisolated func crossRepoGraphQLResponseWithForkOnlyPR(
  for arguments: [String],
  prNumber: Int
) -> String {
  guard let queryArgument = arguments.first(where: { $0.hasPrefix("query=") }) else {
    return #"{"data":{}}"#
  }
  let structure = parseCrossRepoQuery(String(queryArgument.dropFirst("query=".count)))
  var repositoryPayload: [String: Any] = [:]
  for entry in structure.repos {
    var aliasPayload: [String: Any] = [:]
    for alias in entry.branchAliases {
      let node: [String: Any] = [
        "number": prNumber,
        "title": "Add extension to has image property components",
        "state": "CLOSED",
        "additions": 254,
        "deletions": 70,
        "isDraft": false,
        "reviewDecision": NSNull(),
        "mergeable": "CONFLICTING",
        "mergeStateStatus": "DIRTY",
        "url": "https://github.com/onevcat/Kingfisher/pull/2174",
        "updatedAt": NSNull(),
        "headRefName": "master",
        "baseRefName": "v8",
        "commits": ["totalCount": 11],
        "author": ["login": "Mxlris"],
        "headRepository": [
          "name": "Kingfisher",
          "owner": ["login": "MxIris-Library-Forks"],
        ],
        "statusCheckRollup": NSNull(),
      ]
      aliasPayload[alias] = ["nodes": [node]]
    }
    repositoryPayload[entry.alias] = aliasPayload
  }
  let body: [String: Any] = ["data": repositoryPayload]
  guard let data = try? JSONSerialization.data(withJSONObject: body),
    let json = String(bytes: data, encoding: .utf8)
  else {
    return #"{"data":{}}"#
  }
  return json
}

nonisolated struct HeadRepositoryPRFixture {
  let baseOwner: String
  let baseRepo: String
  let headOwner: String
  let headRepo: String
  let branch: String
}

nonisolated func crossRepoGraphQLResponseWithHeadRepositoryPR(
  for arguments: [String],
  fixture: HeadRepositoryPRFixture
) -> String {
  guard let queryArgument = arguments.first(where: { $0.hasPrefix("query=") }) else {
    return #"{"data":{}}"#
  }
  let structure = parseCrossRepoQuery(String(queryArgument.dropFirst("query=".count)))
  var repositoryPayload: [String: Any] = [:]
  for entry in structure.repos {
    var aliasPayload: [String: Any] = [:]
    for alias in entry.branchAliases {
      if entry.owner == fixture.baseOwner, entry.repo == fixture.baseRepo {
        let node: [String: Any] = [
          "number": 42,
          "title": "Fork workflow PR",
          "state": "OPEN",
          "additions": 10,
          "deletions": 2,
          "isDraft": false,
          "reviewDecision": NSNull(),
          "mergeable": "MERGEABLE",
          "mergeStateStatus": "CLEAN",
          "url": "https://github.com/\(fixture.baseOwner)/\(fixture.baseRepo)/pull/42",
          "updatedAt": NSNull(),
          "headRefName": fixture.branch,
          "baseRefName": "main",
          "commits": ["totalCount": 3],
          "author": ["login": fixture.headOwner],
          "headRepository": [
            "name": fixture.headRepo,
            "owner": ["login": fixture.headOwner],
          ],
          "statusCheckRollup": NSNull(),
        ]
        aliasPayload[alias] = ["nodes": [node]]
      } else {
        aliasPayload[alias] = ["nodes": []]
      }
    }
    repositoryPayload[entry.alias] = aliasPayload
  }
  let body: [String: Any] = ["data": repositoryPayload]
  guard let data = try? JSONSerialization.data(withJSONObject: body),
    let json = String(bytes: data, encoding: .utf8)
  else {
    return #"{"data":{}}"#
  }
  return json
}

nonisolated func makeBatchAcrossShellMock(
  probe: GithubBatchShellProbe,
  responseBuilder: @escaping @Sendable (_ arguments: [String]) async throws -> ShellOutput
) -> ShellClient {
  ShellClient(
    run: { executableURL, _, _ in
      if executableURL.lastPathComponent == "which" {
        await probe.recordWhichCall()
        return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
      }
      return ShellOutput(stdout: "", stderr: "", exitCode: 0)
    },
    runLoginImpl: { executableURL, arguments, _, _ in
      guard executableURL.lastPathComponent == "gh" else {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      await probe.recordLoginCall()
      _ = await probe.beginGhCall()
      do {
        let output = try await responseBuilder(arguments)
        await probe.endGhCall()
        return output
      } catch {
        await probe.endGhCall()
        throw error
      }
    }
  )
}
