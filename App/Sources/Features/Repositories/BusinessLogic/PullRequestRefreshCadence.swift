import Foundation

// Decides which worktrees a periodic refresh asks GitHub about. A pull request whose state can
// change soon is refreshed on every sweep; one that has settled is asked about less often, so the
// batched query stays small on an account other tools share.
nonisolated enum PullRequestRefreshCadence {
  /// An open pull request with nothing in flight: reviews and new pushes still change it.
  static let settledOpenInterval: Duration = .seconds(180)
  /// No pull request yet: one appears when someone opens it, from Prowl or elsewhere.
  static let noPullRequestInterval: Duration = .seconds(300)
  /// Merged or closed: only a reopened or new pull request for the same branch changes it.
  static let finishedInterval: Duration = .seconds(1_800)

  static func isDue(
    pullRequest: GithubPullRequest?,
    lastCheckedAt: Date?,
    now: Date,
    isSelected: Bool
  ) -> Bool {
    if isSelected {
      return true
    }
    guard let lastCheckedAt else {
      return true
    }
    guard let interval = interval(for: pullRequest) else {
      return true
    }
    return now.timeIntervalSince(lastCheckedAt) >= interval.seconds
  }

  /// nil means every sweep.
  static func interval(for pullRequest: GithubPullRequest?) -> Duration? {
    guard let pullRequest else {
      return noPullRequestInterval
    }
    switch pullRequest.state.uppercased() {
    case "MERGED", "CLOSED":
      return finishedInterval
    default:
      return isActive(pullRequest) ? nil : settledOpenInterval
    }
  }

  // Checks still running, GitHub still computing mergeability, or a place in the merge queue.
  private static func isActive(_ pullRequest: GithubPullRequest) -> Bool {
    let checks = PullRequestCheckBreakdown(checks: pullRequest.statusCheckRollup?.checks ?? [])
    if checks.inProgress + checks.expected > 0 {
      return true
    }
    if pullRequest.mergeable?.uppercased() == "UNKNOWN" || pullRequest.mergeStateStatus?.uppercased() == "UNKNOWN" {
      return true
    }
    return pullRequest.mergeQueueEntry != nil
  }
}

extension Duration {
  nonisolated fileprivate var seconds: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
