import SwiftUI

struct WorktreePullRequestDisplay {
  let pullRequest: GithubPullRequest?
  let pullRequestState: String?
  let pullRequestBadgeStyle: (text: String, color: Color)?

  init(worktreeName: String, pullRequest: GithubPullRequest?) {
    let matchesWorktree =
      if let pullRequest {
        pullRequest.headRefName == nil || pullRequest.headRefName == worktreeName
      } else {
        false
      }
    let displayPullRequest = matchesWorktree ? pullRequest : nil
    let pullRequestState = displayPullRequest?.state.uppercased()
    let pullRequestNumber = displayPullRequest?.number
    let isQueued = displayPullRequest.flatMap(PullRequestMergeQueueStatus.init(pullRequest:)) != nil
    self.pullRequest = displayPullRequest
    self.pullRequestState = pullRequestState
    self.pullRequestBadgeStyle = PullRequestBadgeStyle.style(
      state: pullRequestState,
      number: pullRequestNumber,
      isQueued: isQueued
    )
  }
}

struct WorktreePullRequestAccessoryView: View {
  let display: WorktreePullRequestDisplay

  var body: some View {
    if let pullRequestBadgeStyle = display.pullRequestBadgeStyle,
      let pullRequest = display.pullRequest
    {
      PullRequestChecksPopoverButton(
        pullRequest: pullRequest
      ) {
        PullRequestBadgeView(text: pullRequestBadgeStyle.text, color: pullRequestBadgeStyle.color)
      }
    }
  }
}
