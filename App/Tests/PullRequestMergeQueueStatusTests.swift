import Foundation
import Testing

@testable import supacode

struct PullRequestMergeQueueStatusTests {
  private func makePullRequest(
    state: String = "OPEN",
    isDraft: Bool = false,
    mergeQueueEntry: GithubMergeQueueEntry? = nil
  ) -> GithubPullRequest {
    GithubPullRequest(
      number: 1,
      title: "PR",
      state: state,
      additions: 0,
      deletions: 0,
      isDraft: isDraft,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pr/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: nil,
      authorLogin: nil,
      statusCheckRollup: nil,
      mergeQueueEntry: mergeQueueEntry
    )
  }

  private func entry(position: Int = 0, estimate: Int? = nil, state: String? = nil) -> GithubMergeQueueEntry {
    GithubMergeQueueEntry(position: position, estimatedTimeToMerge: estimate, state: state)
  }

  // MARK: - Membership

  @Test func nilWhenNoEntry() {
    #expect(PullRequestMergeQueueStatus(pullRequest: makePullRequest()) == nil)
  }

  @Test func nilWhenNotOpenEvenWithEntry() {
    let pullRequest = makePullRequest(state: "MERGED", mergeQueueEntry: entry())
    #expect(PullRequestMergeQueueStatus(pullRequest: pullRequest) == nil)
  }

  @Test func nilWhenDraftEvenWithEntry() {
    let pullRequest = makePullRequest(isDraft: true, mergeQueueEntry: entry())
    #expect(PullRequestMergeQueueStatus(pullRequest: pullRequest) == nil)
  }

  @Test func presentForOpenNonDraftWithEntry() {
    let pullRequest = makePullRequest(mergeQueueEntry: entry(position: 2, estimate: 120, state: "QUEUED"))
    let status = PullRequestMergeQueueStatus(pullRequest: pullRequest)
    #expect(status != nil)
    // position is rendered 1-based.
    #expect(status?.position == 3)
    #expect(status?.state == .queued)
  }

  // MARK: - Summary

  @Test func summaryByState() {
    func summary(_ state: String?) -> String? {
      PullRequestMergeQueueStatus(pullRequest: makePullRequest(mergeQueueEntry: entry(state: state)))?.summary
    }
    #expect(summary("QUEUED") == "In merge queue")
    #expect(summary("MERGEABLE") == "In merge queue")
    #expect(summary(nil) == "In merge queue")
    #expect(summary("AWAITING_CHECKS") == "Awaiting checks in merge queue")
    #expect(summary("UNMERGEABLE") == "Cannot merge from queue")
    #expect(summary("LOCKED") == "Merge queue locked")
  }

  // MARK: - Labels

  @Test func positionLabelIsOneBased() {
    let status = PullRequestMergeQueueStatus(pullRequest: makePullRequest(mergeQueueEntry: entry(position: 0)))
    #expect(status?.positionLabel == "Position 1")
  }

  @Test func estimatedTimeLabelEdges() {
    func label(_ estimate: Int?) -> String? {
      PullRequestMergeQueueStatus(pullRequest: makePullRequest(mergeQueueEntry: entry(estimate: estimate)))?
        .estimatedTimeLabel
    }
    #expect(label(nil) == nil)
    #expect(label(0) == nil)
    #expect(label(30) == "<1 min left")
    #expect(label(120)?.hasPrefix("~") == true)
    #expect(label(120)?.hasSuffix("left") == true)
  }

  @Test func detailJoinsPositionAndTime() {
    let withTime = PullRequestMergeQueueStatus(
      pullRequest: makePullRequest(mergeQueueEntry: entry(position: 1, estimate: 120))
    )
    #expect(withTime?.detail?.contains("Position 2") == true)
    #expect(withTime?.detail?.contains("·") == true)

    let withoutTime = PullRequestMergeQueueStatus(
      pullRequest: makePullRequest(mergeQueueEntry: entry(position: 1, estimate: nil))
    )
    #expect(withoutTime?.detail == "Position 2")
  }
}
