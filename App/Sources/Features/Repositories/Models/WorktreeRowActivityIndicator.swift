/// The activity mark in a sidebar worktree row, in place of its branch icon.
enum WorktreeRowActivityIndicator: Equatable {
  case none
  /// The row's own create/archive/delete work, or a command that reports progress.
  case progress
  /// An agent works in the worktree: the bagua indicator that Active Agents uses.
  case agentWorking
  /// An agent waits for an answer.
  case blocked

  init(
    isLoading: Bool,
    taskStatus: WorktreeTaskStatus?,
    hasBlockedAgent: Bool,
    hasBusyAgent: Bool,
    reduceMotion: Bool
  ) {
    // `isLoading` wins: that work belongs to the row, not to an agent. A blocked
    // agent must not wear a spinner, which tells you to wait.
    if isLoading {
      self = .progress
    } else if hasBlockedAgent {
      self = .blocked
    } else if taskStatus == .running {
      // `.running` also covers a command that reports progress; only an agent
      // gets the bagua. Reduce Motion keeps the system indicator.
      self = hasBusyAgent && !reduceMotion ? .agentWorking : .progress
    } else {
      self = .none
    }
  }
}
