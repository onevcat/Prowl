import Foundation

nonisolated enum PullRequestMergeBlockingReason: Equatable, Hashable {
  case mergeConflicts
  case changesRequested
  case checksFailed(Int)
  case checksPending(Int)
  case blocked
}

nonisolated struct PullRequestMergeReadiness: Equatable, Hashable {
  let blockingReason: PullRequestMergeBlockingReason?

  init(pullRequest: GithubPullRequest) {
    let mergeable = pullRequest.mergeable?.uppercased()
    let mergeStateStatus = pullRequest.mergeStateStatus?.uppercased()
    let reviewDecision = pullRequest.reviewDecision?.uppercased()
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    let breakdown = PullRequestCheckBreakdown(checks: checks)

    if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" {
      self.blockingReason = .mergeConflicts
      return
    }
    if reviewDecision == "CHANGES_REQUESTED" {
      self.blockingReason = .changesRequested
      return
    }
    if breakdown.failed > 0 {
      self.blockingReason = .checksFailed(breakdown.failed)
      return
    }
    // `expected` checks (legacy commit-status required contexts that have not
    // reported yet) are still in flight, so treat them like in-progress checks
    // rather than letting the PR fall through to a green "Mergeable".
    let pendingChecks = breakdown.inProgress + breakdown.expected
    if pendingChecks > 0 {
      self.blockingReason = .checksPending(pendingChecks)
      return
    }

    if mergeable == "MERGEABLE" {
      self.blockingReason = nil
      return
    }

    self.blockingReason = .blocked
  }

  var isBlocking: Bool {
    blockingReason != nil
  }

  var isConflicting: Bool {
    blockingReason == .mergeConflicts
  }

  var label: String {
    switch blockingReason {
    case .none:
      return String(localized: "Mergeable")
    case .mergeConflicts:
      return String(localized: "Merge conflicts")
    case .changesRequested:
      return String(localized: "Changes requested")
    case .checksFailed(let count):
      if count == 1 {
        return String(localized: "\(count) check failed")
      }
      return String(localized: "\(count) checks failed")
    case .checksPending(let count):
      if count == 1 {
        return String(localized: "\(count) check running")
      }
      return String(localized: "\(count) checks running")
    case .blocked:
      return String(localized: "Blocked")
    }
  }
}
