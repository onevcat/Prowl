import Clocks
import Testing

/// Waits until `condition` holds, and records an issue once it has failed for both
/// `minimumPolls` polls and `timeout`.
///
/// Both bounds matter. Swift Testing runs thousands of tests in one process, so the main actor
/// can stay saturated for a minute: then a poll is one scheduler turn, and a wall-clock cap
/// alone gives up while the awaited work still waits for its turn. Work outside the process
/// (a child process, a kernel event) needs wall-clock time instead, however fast the turns are.
/// A met condition ends the wait at once, so the bounds only delay a failure.
nonisolated func waitUntil(
  minimumPolls: Int = 10_000,
  timeout: Duration = .seconds(30),
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: () async -> Bool
) async {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  var polls = 0
  while await !condition() {
    polls += 1
    if polls >= minimumPolls, ContinuousClock.now >= deadline {
      Issue.record(
        "The condition did not hold within \(polls) polls and \(timeout)", sourceLocation: sourceLocation)
      return
    }
    await Task.yield()
  }
}

/// Advances `clock` a tick at a time until `task` returns, and returns its value, or nil after
/// recording an issue when it does not return within the bounds of `waitUntil`.
///
/// Code under test reaches each `clock.sleep` after hops that a loaded runner can delay, so a
/// fixed number of ticks can run ahead of it and leave it suspended for good. Use it only
/// where the code counts the ticks it waited, not clock time: a tick that no sleep receives
/// then changes nothing.
///
/// Every tick runs `Task.megaYield` twice: 20 detached background-priority tasks each, which
/// starve on a busy runner. For a long chain of sleeps, inject `YieldingClock` instead.
@MainActor
func advance<Value: Sendable>(
  _ clock: TestClock<Duration>,
  by tick: Duration,
  until task: Task<Value, Never>,
  timeout: Duration = .seconds(30),
  sourceLocation: SourceLocation = #_sourceLocation
) async -> Value? {
  let result = TaskResult<Value>()
  Task { result.value = await task.value }
  await waitUntil(timeout: timeout, sourceLocation: sourceLocation) {
    guard result.value == nil else { return true }
    await clock.advance(by: tick)
    return false
  }
  if result.value == nil { task.cancel() }
  return result.value
}

@MainActor
private final class TaskResult<Value> {
  var value: Value?
}

/// A clock whose sleeps return after one `Task.yield()`, for code that counts the sleeps it
/// waited, not clock time. Unlike `TestClock` and `ImmediateClock`, it never runs
/// `Task.megaYield`, so a long chain of sleeps stays fast when the runner is busy.
nonisolated struct YieldingClock: Clock {
  var now: ContinuousClock.Instant { .now }
  var minimumResolution: Duration { .zero }

  func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
    try Task.checkCancellation()
    await Task.yield()
  }
}
