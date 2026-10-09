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

  /// What GitHub's last complete answer tells a periodic refresh about one worktree: the branch it
  /// answered for, when, and how long the answer stays good. The interval comes from the answer as
  /// GitHub gave it, not from the pull request on screen, which keeps the previous mergeability
  /// while GitHub still computes the new one.
  nonisolated struct Checkpoint: Equatable, Sendable {
    let branch: String
    let answeredAt: Date
    /// nil means every sweep.
    let interval: Duration?

    init(branch: String, pullRequest: GithubPullRequest?, answeredAt: Date) {
      self.branch = branch
      self.answeredAt = answeredAt
      self.interval = PullRequestRefreshCadence.interval(for: pullRequest)
    }
  }

  static func isDue(
    branch: String,
    checkpoint: Checkpoint?,
    now: Date,
    isSelected: Bool
  ) -> Bool {
    if isSelected {
      return true
    }
    // A checkpoint answers for the branch it was recorded for; a switched branch starts over.
    guard let checkpoint, checkpoint.branch == branch else {
      return true
    }
    guard let interval = checkpoint.interval else {
      return true
    }
    return now.timeIntervalSince(checkpoint.answeredAt) >= interval.seconds
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

  // Checks still running, GitHub still computing mergeability, or a place in the merge queue. A background
  // refresh carries only the per-state check counts, so the breakdown is read, never the check list.
  private static func isActive(_ pullRequest: GithubPullRequest) -> Bool {
    let checks = pullRequest.checkBreakdown
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
