import Foundation
import Testing

@testable import Prowl

struct PullRequestCheckCountsTests {
  @Test func countsOnlyRollupDecodesEveryState() throws {
    let json = """
      {
        "contexts": {
          "checkRunCountsByState": [
            {"state": "SUCCESS", "count": 4},
            {"state": "NEUTRAL", "count": 1},
            {"state": "FAILURE", "count": 1},
            {"state": "TIMED_OUT", "count": 1},
            {"state": "ACTION_REQUIRED", "count": 1},
            {"state": "STARTUP_FAILURE", "count": 1},
            {"state": "STALE", "count": 1},
            {"state": "CANCELLED", "count": 2},
            {"state": "SKIPPED", "count": 1},
            {"state": "IN_PROGRESS", "count": 1},
            {"state": "QUEUED", "count": 1},
            {"state": "PENDING", "count": 1},
            {"state": "WAITING", "count": 1},
            {"state": "COMPLETED", "count": 1}
          ],
          "statusContextCountsByState": [
            {"state": "SUCCESS", "count": 2},
            {"state": "FAILURE", "count": 1},
            {"state": "ERROR", "count": 1},
            {"state": "EXPECTED", "count": 3},
            {"state": "PENDING", "count": 1}
          ]
        }
      }
      """
    let rollup = try JSONDecoder().decode(GithubPullRequestStatusCheckRollup.self, from: Data(json.utf8))

    #expect(rollup.checks.isEmpty)
    #expect(
      rollup.breakdown
        == PullRequestCheckBreakdown(passed: 7, failed: 7, inProgress: 6, expected: 3, skipped: 3)
    )
  }

  // Each count state lands in the same bucket an individual check of that state lands in, so the
  // badge reads the same whether a refresh fetched counts or the full list.
  @Test(
    arguments: [
      ("SUCCESS", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "SUCCESS")),
      ("NEUTRAL", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "NEUTRAL")),
      ("FAILURE", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "FAILURE")),
      ("TIMED_OUT", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "TIMED_OUT")),
      ("ACTION_REQUIRED", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "ACTION_REQUIRED")),
      ("STARTUP_FAILURE", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "STARTUP_FAILURE")),
      ("STALE", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "STALE")),
      ("CANCELLED", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "CANCELLED")),
      ("SKIPPED", GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "SKIPPED")),
      ("IN_PROGRESS", GithubPullRequestStatusCheck(status: "IN_PROGRESS")),
      ("QUEUED", GithubPullRequestStatusCheck(status: "QUEUED")),
      ("PENDING", GithubPullRequestStatusCheck(status: "PENDING")),
      ("WAITING", GithubPullRequestStatusCheck(status: "WAITING")),
      ("COMPLETED", GithubPullRequestStatusCheck(status: "COMPLETED")),
    ]
  )
  func checkRunCountMatchesTheIndividualCheck(state: String, check: GithubPullRequestStatusCheck) throws {
    let json = #"{"contexts":{"checkRunCountsByState":[{"state":"\#(state)","count":1}]}}"#
    let rollup = try JSONDecoder().decode(GithubPullRequestStatusCheckRollup.self, from: Data(json.utf8))
    #expect(rollup.breakdown == PullRequestCheckBreakdown(checks: [check]))
  }

  @Test(
    arguments: [
      ("SUCCESS", GithubPullRequestStatusCheck(state: "SUCCESS")),
      ("FAILURE", GithubPullRequestStatusCheck(state: "FAILURE")),
      ("ERROR", GithubPullRequestStatusCheck(state: "ERROR")),
      ("EXPECTED", GithubPullRequestStatusCheck(state: "EXPECTED")),
      ("PENDING", GithubPullRequestStatusCheck(state: "PENDING")),
    ]
  )
  func statusContextCountMatchesTheIndividualContext(state: String, check: GithubPullRequestStatusCheck) throws {
    let json = #"{"contexts":{"statusContextCountsByState":[{"state":"\#(state)","count":1}]}}"#
    let rollup = try JSONDecoder().decode(GithubPullRequestStatusCheckRollup.self, from: Data(json.utf8))
    #expect(rollup.breakdown == PullRequestCheckBreakdown(checks: [check]))
  }

  @Test func countsWinOverAListCappedAtOneHundred() throws {
    let json = """
      {
        "contexts": {
          "checkRunCountsByState": [{"state": "SUCCESS", "count": 140}],
          "nodes": [{"name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"}]
        }
      }
      """
    let rollup = try JSONDecoder().decode(GithubPullRequestStatusCheckRollup.self, from: Data(json.utf8))

    #expect(rollup.checks.map(\.displayName) == ["build"])
    #expect(rollup.breakdown.passed == 140)
  }

  @Test func mergeReadinessReadsCounts() {
    let pullRequest = GithubPullRequest(
      number: 1,
      title: "PR",
      state: "OPEN",
      additions: 0,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: "MERGEABLE",
      mergeStateStatus: "UNSTABLE",
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: GithubPullRequestStatusCheckRollup(
        checks: [],
        counts: PullRequestCheckBreakdown(passed: 3, failed: 2, inProgress: 0, expected: 0, skipped: 0)
      )
    )

    #expect(PullRequestMergeReadiness(pullRequest: pullRequest).blockingReason == .checksFailed(2))
  }

  @Test func onlyDetailFieldsListEachCheck() {
    let counts = pullRequestNodeFields(includeCheckDetails: false)
    let details = pullRequestNodeFields(includeCheckDetails: true)

    #expect(counts.contains("checkRunCountsByState"))
    #expect(counts.contains("statusContextCountsByState"))
    #expect(!counts.contains("... on CheckRun"))
    #expect(!counts.contains("first: 100"))
    #expect(details.contains("checkRunCountsByState"))
    #expect(details.contains("contexts(first: 100)"))
    #expect(details.contains("... on CheckRun"))
  }

  @Test func crossRepoQueryListsChecksOnlyForDetailBranches() async throws {
    let probe = GithubBatchShellProbe()
    let observedArguments = ObservedArguments()
    let shell = makeBatchAcrossShellMock(probe: probe) { arguments in
      await observedArguments.append(arguments)
      return ShellOutput(stdout: crossRepoGraphQLResponse(for: arguments), stderr: "", exitCode: 0)
    }
    let client = GithubCLIClient.live(shell: shell)
    let request = CrossRepoPullRequestRequest(
      owner: "khoi",
      repo: "repo",
      branches: ["quiet", "selected", "other"],
      detailBranches: ["selected"]
    )

    _ = try await client.batchPullRequestsAcrossRepositories("github.com", [request], nil)

    let arguments = try #require(await observedArguments.snapshot().first)
    let query = try #require(arguments.first { $0.hasPrefix("query=") })
    #expect(query.components(separatedBy: "checkRunCountsByState").count - 1 == 3)
    #expect(query.components(separatedBy: "... on CheckRun").count - 1 == 1)
    let selectedBlock = try #require(query.range(of: "r0_b1:"))
    let otherBlock = try #require(query.range(of: "r0_b2:"))
    let detailRange = try #require(query.range(of: "... on CheckRun"))
    #expect(detailRange.lowerBound > selectedBlock.lowerBound)
    #expect(detailRange.lowerBound < otherBlock.lowerBound)
  }
}
