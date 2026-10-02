import Foundation
import Testing

@testable import Prowl

struct PullRequestRefreshCadenceTests {
  nonisolated static let checkedAt = Date(timeIntervalSince1970: 1_000_000)

  struct Case: Sendable, CustomTestStringConvertible {
    let pullRequest: GithubPullRequest?
    let secondsSinceAnswer: Int
    let isDue: Bool

    var testDescription: String {
      "\(pullRequest?.state ?? "no PR") after \(secondsSinceAnswer) s: \(isDue ? "due" : "not due")"
    }
  }

  @Test(
    arguments: [
      Case(pullRequest: nil, secondsSinceAnswer: 299, isDue: false),
      Case(pullRequest: nil, secondsSinceAnswer: 300, isDue: true),
      Case(pullRequest: pullRequest(state: "MERGED"), secondsSinceAnswer: 1_799, isDue: false),
      Case(pullRequest: pullRequest(state: "MERGED"), secondsSinceAnswer: 1_800, isDue: true),
      Case(pullRequest: pullRequest(state: "CLOSED"), secondsSinceAnswer: 1_800, isDue: true),
      Case(pullRequest: pullRequest(state: "OPEN"), secondsSinceAnswer: 179, isDue: false),
      Case(pullRequest: pullRequest(state: "OPEN"), secondsSinceAnswer: 180, isDue: true),
      Case(
        pullRequest: pullRequest(state: "OPEN", checks: [GithubPullRequestStatusCheck(status: "IN_PROGRESS")]),
        secondsSinceAnswer: 1,
        isDue: true
      ),
      Case(
        pullRequest: pullRequest(state: "OPEN", checks: [GithubPullRequestStatusCheck(state: "EXPECTED")]),
        secondsSinceAnswer: 1,
        isDue: true
      ),
      Case(pullRequest: pullRequest(state: "OPEN", mergeable: "UNKNOWN"), secondsSinceAnswer: 1, isDue: true),
      Case(pullRequest: pullRequest(state: "OPEN", mergeStateStatus: "UNKNOWN"), secondsSinceAnswer: 1, isDue: true),
      Case(pullRequest: pullRequest(state: "OPEN", queued: true), secondsSinceAnswer: 1, isDue: true),
      Case(
        pullRequest: pullRequest(
          state: "OPEN",
          checks: [GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "SUCCESS")]
        ),
        secondsSinceAnswer: 179,
        isDue: false
      ),
    ]
  )
  func dueByPullRequestState(_ testCase: Case) {
    #expect(
      PullRequestRefreshCadence.isDue(
        pullRequest: testCase.pullRequest,
        lastCheckedAt: Self.checkedAt,
        now: Self.checkedAt.addingTimeInterval(TimeInterval(testCase.secondsSinceAnswer)),
        isSelected: false
      ) == testCase.isDue
    )
  }

  @Test func selectedWorktreeIsAlwaysDue() {
    #expect(
      PullRequestRefreshCadence.isDue(
        pullRequest: pullRequest(state: "MERGED"),
        lastCheckedAt: Self.checkedAt,
        now: Self.checkedAt.addingTimeInterval(1),
        isSelected: true
      )
    )
  }

  @Test func neverAnsweredWorktreeIsDue() {
    #expect(
      PullRequestRefreshCadence.isDue(
        pullRequest: pullRequest(state: "MERGED"),
        lastCheckedAt: nil,
        now: Self.checkedAt,
        isSelected: false
      )
    )
  }
}

nonisolated private func pullRequest(
  state: String,
  checks: [GithubPullRequestStatusCheck] = [],
  mergeable: String? = "MERGEABLE",
  mergeStateStatus: String? = "CLEAN",
  queued: Bool = false
) -> GithubPullRequest {
  GithubPullRequest(
    number: 7,
    title: "PR",
    state: state,
    additions: 0,
    deletions: 0,
    isDraft: false,
    reviewDecision: nil,
    mergeable: mergeable,
    mergeStateStatus: mergeStateStatus,
    updatedAt: nil,
    url: "https://example.com/pull/7",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: checks.isEmpty ? nil : GithubPullRequestStatusCheckRollup(checks: checks),
    mergeQueueEntry: queued ? GithubMergeQueueEntry(position: 1, estimatedTimeToMerge: nil, state: "QUEUED") : nil
  )
}
