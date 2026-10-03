import Foundation

/// Drops a state-notification event that is identical to the last one emitted
/// for its slot, so an agent re-emitting the same status / focus / run-script /
/// font size doesn't flood the terminal event stream during a tool storm.
///
/// Only "latest value wins" events are coalesced. Lifecycle and one-shot events
/// — notifications, custom-command completions, tab open/close, agent removal,
/// setup-script consumption, layout restore — are never coalesced, because each
/// occurrence is meaningful (e.g. two identical notifications are two distinct
/// user-facing events).
struct TerminalEventCoalescer {
  enum CoalesceKey: Hashable {
    case focusChanged
    case fontSize
    case taskStatus(Worktree.ID)
    case runScriptStatus(Worktree.ID)
    case agentEntry(UUID)
  }

  private var lastEmitted: [CoalesceKey: TerminalClient.Event] = [:]

  /// The coalesce slot for an event, or `nil` when the event must never be
  /// coalesced.
  static func coalesceKey(for event: TerminalClient.Event) -> CoalesceKey? {
    switch event {
    case .focusChanged:
      return .focusChanged
    case .fontSizeChanged:
      return .fontSize
    case .taskStatusChanged(let worktreeID, _):
      return .taskStatus(worktreeID)
    case .runScriptStatusChanged(let worktreeID, _):
      return .runScriptStatus(worktreeID)
    case .agentEntryChanged(let entry):
      return .agentEntry(entry.id)
    case .customCommandSucceeded, .notificationReceived, .notificationIndicatorChanged,
      .tabCreated, .tabClosed, .tabRestored, .agentEntryRemoved, .commandPaletteToggleRequested,
      .setupScriptConsumed, .layoutRestored, .layoutRestoreFailed,
      .agentProfileLaunched, .agentProfileLaunchWarning, .agentProfileLaunchFailed:
      return nil
    }
  }

  /// Returns `true` when the event should be forwarded, `false` when it is an
  /// exact repeat of the last value emitted for its slot.
  mutating func shouldEmit(_ event: TerminalClient.Event) -> Bool {
    guard let key = Self.coalesceKey(for: event) else { return true }
    if lastEmitted[key] == event { return false }
    lastEmitted[key] = event
    return true
  }

  /// Clears the cache so a freshly subscribed stream can be re-seeded with the
  /// current state instead of having it suppressed as a duplicate.
  mutating func reset() {
    lastEmitted.removeAll()
  }

  /// Drops per-worktree slots for torn-down worktrees so a worktree ID that
  /// returns doesn't inherit a stale cached value.
  mutating func forget(worktreeIDs: Set<Worktree.ID>) {
    for worktreeID in worktreeIDs {
      lastEmitted[.taskStatus(worktreeID)] = nil
      lastEmitted[.runScriptStatus(worktreeID)] = nil
    }
  }
}
