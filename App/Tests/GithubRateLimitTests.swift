import ComposableArchitecture
import Foundation
import Testing

@testable import Prowl

struct GithubRateLimitClassifierTests {
  // The refusal Prowl received on 2026-09-30, as `gh api graphql --include` prints it.
  nonisolated static let graphQLRefusal = """
    HTTP/2.0 200 OK
    Content-Type: application/json; charset=utf-8
    X-Ratelimit-Remaining: 4979

    {"errors":[{"type":"RATE_LIMIT","code":"graphql_rate_limit",\
    "message":"API rate limit already exceeded for user ID 1."}]}
    """

  @Test func graphQLRateLimitErrorIsARefusal() {
    let signal = GithubRateLimitClassifier.classify(
      stdout: Self.graphQLRefusal,
      stderr: "gh: API rate limit already exceeded for user ID 1.",
      succeeded: false
    )
    #expect(signal == GithubRateLimitSignal(isRefusal: true, retryAfter: nil, resetAt: nil))
  }

  @Test func rateLimitedErrorTypeIsARefusalEvenWhenGhExitsZero() {
    let stdout = #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: true)
    #expect(signal?.isRefusal == true)
  }

  @Test func secondaryLimitCarriesRetryAfter() {
    let stdout = """
      HTTP/2.0 403 Forbidden
      Retry-After: 120

      {"message":"You have exceeded a secondary rate limit.","documentation_url":"https://docs.github.com"}
      """
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: false)
    #expect(signal == GithubRateLimitSignal(isRefusal: true, retryAfter: .seconds(120), resetAt: nil))
  }

  @Test func tooManyRequestsIsARefusal() {
    let stdout = "HTTP/2.0 429 Too Many Requests\n\n{}"
    #expect(GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: false)?.isRefusal == true)
  }

  @Test func exhaustedPrimaryBudgetRefusalCarriesTheResetTime() {
    let stdout = """
      HTTP/2.0 403 Forbidden
      X-Ratelimit-Remaining: 0
      X-Ratelimit-Reset: 1790892842

      {"message":"API rate limit exceeded for user ID 1."}
      """
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: false)
    #expect(
      signal
        == GithubRateLimitSignal(
          isRefusal: true,
          retryAfter: nil,
          resetAt: Date(timeIntervalSince1970: 1_790_892_842)
        ))
  }

  @Test func spendingTheLastOfTheBudgetBlocksWithoutDiscardingTheAnswer() {
    let stdout = """
      HTTP/2.0 200 OK
      X-Ratelimit-Remaining: 0
      X-Ratelimit-Reset: 1790892842

      {"data":{}}
      """
    let signal = GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: true)
    #expect(signal?.isRefusal == false)
    #expect(signal?.resetAt == Date(timeIntervalSince1970: 1_790_892_842))
  }

  @Test func permissionDenialIsNotARateLimit() {
    let stdout = """
      HTTP/2.0 403 Forbidden
      X-Ratelimit-Remaining: 4000

      {"message":"Resource not accessible by integration"}
      """
    #expect(GithubRateLimitClassifier.classify(stdout: stdout, stderr: "gh: HTTP 403", succeeded: false) == nil)
  }

  @Test func payloadTextMentioningRateLimitsIsNotARateLimit() {
    let stdout = """
      HTTP/2.0 200 OK

      {"data":{"repository":{"b0":{"nodes":[{"title":"Back off on rate limit errors"}]}}}}
      """
    #expect(GithubRateLimitClassifier.classify(stdout: stdout, stderr: "", succeeded: true) == nil)
  }

  @Test func nonAPICommandsReportThroughStderr() {
    let signal = GithubRateLimitClassifier.classify(
      stdout: "",
      stderr: "GraphQL: API rate limit exceeded for user ID 1. (rateLimit)",
      succeeded: false
    )
    #expect(signal?.isRefusal == true)
  }
}

struct GithubRateLimitGateTests {
  @Test func backoffDoublesFromOneMinuteAndStopsAtOneHour() {
    let delays = (1...8).map { GithubRateLimitGate.backoff(afterRefusals: $0, jitter: 0) }
    #expect(Array(delays.prefix(7)) == [60, 120, 240, 480, 960, 1920, 3600].map { Duration.seconds($0) })
    #expect(delays.last == .seconds(3600))
    #expect(GithubRateLimitGate.backoff(afterRefusals: 1, jitter: 1) == .seconds(75))
    #expect(GithubRateLimitGate.backoff(afterRefusals: 7, jitter: 1) == .seconds(3600))
  }

  @Test func refusalBlocksEveryRequestUntilTheBackoffEnds() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })

    let ticket = try await gate.admit()
    let retryAt = await gate.record(ticket, signal: GithubRateLimitSignal(isRefusal: true))
    #expect(retryAt == clock.value.addingTimeInterval(60))

    clock.withValue { $0.addTimeInterval(59) }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt!)) {
      _ = try await gate.admit()
    }

    clock.withValue { $0.addTimeInterval(1) }
    #expect(try await gate.admit() == GithubRateLimitGate.Ticket(isProbe: true))
  }

  @Test func failedProbeDoublesTheBackoff() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let first = try await gate.admit()
    _ = await gate.record(first, signal: GithubRateLimitSignal(isRefusal: true))
    clock.withValue { $0.addTimeInterval(60) }

    let probe = try await gate.admit()
    let retryAt = await gate.record(probe, signal: GithubRateLimitSignal(isRefusal: true))

    #expect(retryAt == clock.value.addingTimeInterval(120))
  }

  @Test func retryAfterOverridesTheBackoff() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let ticket = try await gate.admit()

    let retryAt = await gate.record(ticket, signal: GithubRateLimitSignal(isRefusal: true, retryAfter: .seconds(7)))

    #expect(retryAt == clock.value.addingTimeInterval(7))
  }

  @Test func answeredProbeReopensTheGateAndResetsTheBackoff() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true))
    clock.withValue { $0.addTimeInterval(60) }

    let probe = try await gate.admit()
    #expect(await gate.record(probe, signal: nil) == nil)

    #expect(try await gate.admit() == GithubRateLimitGate.Ticket(isProbe: false))
    let retryAt = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true))
    #expect(retryAt == clock.value.addingTimeInterval(60))
  }

  @Test func requestAdmittedBeforeTheRefusalCannotReopenTheGate() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let early = try await gate.admit()
    let refused = try await gate.admit()
    let retryAt = await gate.record(refused, signal: GithubRateLimitSignal(isRefusal: true))

    #expect(await gate.record(early, signal: nil) == nil)

    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt!)) {
      _ = try await gate.admit()
    }
  }

  @Test func requestsArrivingDuringTheProbeWaitForItsAnswer() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true))
    clock.withValue { $0.addTimeInterval(60) }
    let probe = try await gate.admit()

    let waiter = Task { try await gate.admit() }
    while await gate.waitingRequestCount == 0 {
      await Task.yield()
    }
    let refusedAgain = await gate.record(probe, signal: GithubRateLimitSignal(isRefusal: true))

    await #expect(throws: GithubCLIError.rateLimited(retryAt: refusedAgain!)) {
      _ = try await waiter.value
    }
  }

  @Test func abandonedProbePassesToTheNextRequest() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true))
    clock.withValue { $0.addTimeInterval(60) }
    let probe = try await gate.admit()

    await gate.abandon(probe)

    #expect(try await gate.admit() == GithubRateLimitGate.Ticket(isProbe: true))
  }
}

struct GithubRateLimitedClientTests {
  @Test func refusedGraphQLQueryStartsNoFurtherGhProcessUntilTheRetryTime() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let launches = LockIsolated(0)
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { _ in
        throw ShellClientError(
          command: "gh api graphql",
          stdout: GithubRateLimitClassifierTests.graphQLRefusal,
          stderr: "gh: API rate limit already exceeded for user ID 1.",
          exitCode: 1
        )
      },
      rateLimitGate: gate
    )
    let request = CrossRepoPullRequestRequest(owner: "octo", repo: "repo", branches: ["feature"])
    let retryAt = clock.value.addingTimeInterval(60)

    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    }
    #expect(launches.value == 1)

    clock.withValue { $0.addTimeInterval(59) }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequests("github.com", "octo", "repo", ["feature"], nil)
    }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      try await client.mergePullRequest(
        URL(fileURLWithPath: "/tmp/repo"),
        GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"),
        1,
        .squash,
        nil
      )
    }
    #expect(launches.value == 1)

    clock.withValue { $0.addTimeInterval(1) }
    _ = try? await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    #expect(launches.value == 2)
  }

  @Test func retryAfterHeaderSetsTheRetryTime() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    let launches = LockIsolated(0)
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { _ in
        throw ShellClientError(
          command: "gh api graphql",
          stdout:
            "HTTP/2.0 403 Forbidden\nRetry-After: 300\n\n{\"message\":\"You have exceeded a secondary rate limit.\"}",
          stderr: "gh: You have exceeded a secondary rate limit. (HTTP 403)",
          exitCode: 1
        )
      },
      rateLimitGate: gate
    )
    let request = CrossRepoPullRequestRequest(owner: "octo", repo: "repo", branches: ["feature"])
    let retryAt = clock.value.addingTimeInterval(300)

    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    }
    clock.withValue { $0.addTimeInterval(299) }
    await #expect(throws: GithubCLIError.rateLimited(retryAt: retryAt)) {
      _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)
    }
    #expect(launches.value == 1)
  }

  @Test func versionCheckRunsWhileRateLimited() async throws {
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let gate = GithubRateLimitGate(now: { clock.value }, jitter: { 0 })
    _ = await gate.record(try await gate.admit(), signal: GithubRateLimitSignal(isRefusal: true))
    let launches = LockIsolated(0)
    let client = GithubCLIClient.live(
      shell: fakeGh(launches: launches) { _ in ShellOutput(stdout: "gh version 2.102.0", stderr: "", exitCode: 0) },
      rateLimitGate: gate
    )

    #expect(await client.isAvailable())
    #expect(launches.value == 1)
  }
}

private func fakeGh(
  launches: LockIsolated<Int>,
  respond: @escaping @Sendable ([String]) async throws -> ShellOutput
) -> ShellClient {
  ShellClient(
    run: { executableURL, _, _ in
      if executableURL.lastPathComponent == "which" {
        return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
      }
      return ShellOutput(stdout: "", stderr: "", exitCode: 0)
    },
    runLoginImpl: { executableURL, arguments, _, _ in
      guard executableURL.lastPathComponent == "gh" else {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      launches.withValue { $0 += 1 }
      return try await respond(arguments)
    }
  )
}
