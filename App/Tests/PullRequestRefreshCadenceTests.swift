import Foundation
import Testing

@testable import Prowl

struct PullRequestRefreshCadenceTests {
  nonisolated static let answeredAt = Date(timeIntervalSince1970: 1_000_000)

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
      // A background refresh reports the checks as per-state counts, without the list.
      Case(
        pullRequest: pullRequest(
          state: "OPEN",
          counts: PullRequestCheckBreakdown(passed: 2, failed: 0, inProgress: 1, expected: 0, skipped: 0)
        ),
        secondsSinceAnswer: 1,
        isDue: true
      ),
      Case(
        pullRequest: pullRequest(
          state: "OPEN",
          counts: PullRequestCheckBreakdown(passed: 0, failed: 0, inProgress: 0, expected: 1, skipped: 0)
        ),
        secondsSinceAnswer: 1,
        isDue: true
      ),
      Case(
        pullRequest: pullRequest(
          state: "OPEN",
          counts: PullRequestCheckBreakdown(passed: 3, failed: 1, inProgress: 0, expected: 0, skipped: 1)
        ),
        secondsSinceAnswer: 179,
        isDue: false
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
        branch: "feature",
        checkpoint: checkpoint(for: testCase.pullRequest),
        now: Self.answeredAt.addingTimeInterval(TimeInterval(testCase.secondsSinceAnswer)),
        isSelected: false
      ) == testCase.isDue
    )
  }

  @Test func selectedWorktreeIsAlwaysDue() {
    #expect(
      PullRequestRefreshCadence.isDue(
        branch: "feature",
        checkpoint: checkpoint(for: pullRequest(state: "MERGED")),
        now: Self.answeredAt.addingTimeInterval(1),
        isSelected: true
      )
    )
  }

  @Test func neverAnsweredWorktreeIsDue() {
    #expect(
      PullRequestRefreshCadence.isDue(branch: "feature", checkpoint: nil, now: Self.answeredAt, isSelected: false)
    )
  }

  @Test func switchedBranchIsDue() {
    // The checkpoint answered for the merged branch; the worktree is on another branch now.
    #expect(
      PullRequestRefreshCadence.isDue(
        branch: "new-feature",
        checkpoint: checkpoint(for: pullRequest(state: "MERGED")),
        now: Self.answeredAt.addingTimeInterval(1),
        isSelected: false
      )
    )
  }

  @Test func checkpointReadsItsIntervalFromTheAnswer() {
    let computing = pullRequest(state: "OPEN", mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN")
    #expect(checkpoint(for: computing).interval == nil)
    #expect(checkpoint(for: pullRequest(state: "OPEN")).interval == PullRequestRefreshCadence.settledOpenInterval)
    #expect(checkpoint(for: nil).interval == PullRequestRefreshCadence.noPullRequestInterval)
    #expect(checkpoint(for: pullRequest(state: "MERGED")).interval == PullRequestRefreshCadence.finishedInterval)
  }
}

nonisolated private func checkpoint(for pullRequest: GithubPullRequest?) -> PullRequestRefreshCadence.Checkpoint {
  PullRequestRefreshCadence.Checkpoint(
    branch: "feature",
    pullRequest: pullRequest,
    answeredAt: PullRequestRefreshCadenceTests.answeredAt
  )
}

nonisolated private func pullRequest(
  state: String,
  checks: [GithubPullRequestStatusCheck] = [],
  counts: PullRequestCheckBreakdown? = nil,
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
    statusCheckRollup: checks.isEmpty && counts == nil
      ? nil : GithubPullRequestStatusCheckRollup(checks: checks, counts: counts),
    mergeQueueEntry: queued ? GithubMergeQueueEntry(position: 1, estimatedTimeToMerge: nil, state: "QUEUED") : nil
  )
}
