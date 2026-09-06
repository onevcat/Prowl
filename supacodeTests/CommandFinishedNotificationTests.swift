import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CommandFinishedNotificationTests {
  private let surfaceId = UUID()

  // MARK: - Notification Generation

  @Test func generatesNotificationWhenThresholdExceeded() {
    let state = makeState()
    state.handleCommandFinished(exitCode: 0, durationNs: 15_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.count == 1)
    #expect(state.notifications.first?.title == "Command finished")
    #expect(state.notifications.first?.body == "Completed in 15s")
    #expect(state.notifications.first?.surfaceId == surfaceId)
  }

  @Test func doesNotGenerateNotificationUnderThreshold() {
    let state = makeState()
    state.handleCommandFinished(exitCode: 0, durationNs: 5_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.isEmpty)
  }

  @Test func doesNotGenerateNotificationAtExactThreshold() {
    let state = makeState(threshold: 10)
    state.handleCommandFinished(exitCode: 0, durationNs: 10_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.count == 1)
  }

  // MARK: - Exit Code Filtering

  @Test func doesNotGenerateNotificationForSIGINT() {
    let state = makeState()
    state.handleCommandFinished(exitCode: 130, durationNs: 60_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.isEmpty)
  }

  @Test func doesNotGenerateNotificationForSIGTERM() {
    let state = makeState()
    state.handleCommandFinished(exitCode: 143, durationNs: 60_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.isEmpty)
  }

  @Test func generatesFailureNotificationForNonZeroExitCode() {
    let state = makeState()
    state.handleCommandFinished(exitCode: 1, durationNs: 30_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.count == 1)
    #expect(state.notifications.first?.title == "Command failed")
    #expect(state.notifications.first?.body == "Failed (exit code 1) after 30s")
  }

  @Test func generatesNotificationForNilExitCode() {
    let state = makeState()
    state.handleCommandFinished(exitCode: nil, durationNs: 20_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.count == 1)
    #expect(state.notifications.first?.title == "Command finished")
    #expect(state.notifications.first?.body == "Completed in 20s")
  }

  // MARK: - Feature Toggle

  @Test func doesNotGenerateNotificationWhenDisabled() {
    let state = makeState()
    state.setCommandFinishedNotification(enabled: false, threshold: 10)
    state.handleCommandFinished(exitCode: 0, durationNs: 60_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.isEmpty)
  }

  @Test func respectsUpdatedThreshold() {
    let state = makeState()
    state.setCommandFinishedNotification(enabled: true, threshold: 30)
    state.handleCommandFinished(exitCode: 0, durationNs: 20_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.isEmpty)

    state.handleCommandFinished(exitCode: 0, durationNs: 31_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.count == 1)
  }

  // MARK: - Recent Interaction Suppression

  @Test func doesNotGenerateNotificationAfterRecentKeyInput() {
    let state = makeState()
    state.recordKeyInput(forSurfaceID: surfaceId)
    state.handleCommandFinished(exitCode: 0, durationNs: 60_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.isEmpty)
  }

  @Test func recentKeyInputOnDifferentSurfaceDoesNotSuppressNotification() {
    let state = makeState()
    let otherSurfaceId = UUID()
    state.recordKeyInput(forSurfaceID: otherSurfaceId)
    state.handleCommandFinished(exitCode: 0, durationNs: 60_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.count == 1)
  }

  @Test func generatesNotificationWithNoKeyInputHistory() {
    let state = makeState()
    state.handleCommandFinished(exitCode: 0, durationNs: 60_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.count == 1)
  }

  @Test func workflowNotificationIsReadAndMarkedViewedWhenItsWorktreeIsVisible() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    manager.handleCommand(.setNotificationsEnabled(true))
    manager.handleCommand(.setSelectedWorktreeID(worktree.id))
    state.syncFocus(windowIsKey: true, windowIsVisible: true)
    var viewed: [Bool] = []
    state.onNotificationReceived = { _, _, _, isViewed in viewed.append(isViewed) }

    state.appendNotification(
      title: "Workflow needs attention",
      body: "Reviewer is waiting",
      surfaceId: surfaceId,
      treatAsViewedWhenWorktreeIsVisible: true
    )

    #expect(state.notifications.count == 1)
    #expect(state.notifications.first?.isRead == true)
    #expect(viewed == [true])
  }

  @Test func selectedWorkflowNotificationRemainsUnreadWhenTheAppIsInTheBackground() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    manager.handleCommand(.setNotificationsEnabled(true))
    manager.handleCommand(.setSelectedWorktreeID(worktree.id))
    state.syncFocus(windowIsKey: false, windowIsVisible: true)
    var viewed: [Bool] = []
    state.onNotificationReceived = { _, _, _, isViewed in viewed.append(isViewed) }

    state.appendNotification(
      title: "Workflow needs attention",
      body: "Reviewer is waiting",
      surfaceId: surfaceId,
      treatAsViewedWhenWorktreeIsVisible: true
    )

    #expect(state.notifications.count == 1)
    #expect(state.notifications.first?.isRead == false)
    #expect(viewed == [false])
  }

  @Test func workflowNotificationRemainsUnreadAndPropagatesForABackgroundWorktree() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    manager.handleCommand(.setNotificationsEnabled(true))
    manager.handleCommand(.setSelectedWorktreeID("another-worktree"))
    var received = 0
    state.onNotificationReceived = { _, _, _, _ in received += 1 }

    state.appendNotification(
      title: "Workflow needs attention",
      body: "Reviewer is waiting",
      surfaceId: surfaceId,
      treatAsViewedWhenWorktreeIsVisible: true
    )

    #expect(state.notifications.count == 1)
    #expect(state.notifications.first?.isRead == false)
    #expect(received == 1)
  }

  // MARK: - Duration Formatting

  @Test func formatDurationSeconds() {
    #expect(WorktreeTerminalState.formatDuration(5) == "5s")
    #expect(WorktreeTerminalState.formatDuration(59) == "59s")
  }

  @Test func formatDurationMinutes() {
    #expect(WorktreeTerminalState.formatDuration(60) == "1m")
    #expect(WorktreeTerminalState.formatDuration(90) == "1m 30s")
    #expect(WorktreeTerminalState.formatDuration(3599) == "59m 59s")
  }

  @Test func formatDurationHours() {
    #expect(WorktreeTerminalState.formatDuration(3600) == "1h")
    #expect(WorktreeTerminalState.formatDuration(3660) == "1h 1m")
    #expect(WorktreeTerminalState.formatDuration(7200) == "2h")
  }

  // MARK: - Manager Propagation

  @Test func managerPropagatesSettingsToExistingStates() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    manager.setCommandFinishedNotification(enabled: true, threshold: 30)
    state.handleCommandFinished(exitCode: 0, durationNs: 20_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.isEmpty)

    state.handleCommandFinished(exitCode: 0, durationNs: 31_000_000_000, surfaceId: surfaceId)

    #expect(state.notifications.count == 1)
  }

  @Test func managerPropagatesSettingsToNewStates() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.setCommandFinishedNotification(enabled: true, threshold: 60)

    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.handleCommandFinished(exitCode: 0, durationNs: 30_000_000_000, surfaceId: surfaceId)
    #expect(state.notifications.isEmpty)

    state.handleCommandFinished(exitCode: 0, durationNs: 61_000_000_000, surfaceId: surfaceId)
    #expect(state.notifications.count == 1)
  }

  // MARK: - Auto-close on success

  @Test func autoCloseFlagIsConsumedOnSuccess() {
    let state = makeState()
    state.markSurfaceForAutoClose(surfaceId)
    #expect(state.isMarkedForAutoClose(surfaceId))

    state.handleCommandFinished(exitCode: 0, durationNs: 1_000_000_000, surfaceId: surfaceId)

    #expect(!state.isMarkedForAutoClose(surfaceId))
  }

  @Test func autoCloseFlagIsConsumedOnFailureButDoesNotClose() {
    let state = makeState()
    state.markSurfaceForAutoClose(surfaceId)

    state.handleCommandFinished(exitCode: 1, durationNs: 30_000_000_000, surfaceId: surfaceId)

    #expect(!state.isMarkedForAutoClose(surfaceId))
    // Standard failure notification still fires since close was not triggered.
    #expect(state.notifications.count == 1)
    #expect(state.notifications.first?.title == "Command failed")
  }

  @Test func unmarkedSurfaceDoesNotConsumeAutoCloseState() {
    let state = makeState()
    let otherSurfaceId = UUID()
    state.markSurfaceForAutoClose(otherSurfaceId)

    state.handleCommandFinished(exitCode: 0, durationNs: 15_000_000_000, surfaceId: surfaceId)

    #expect(state.isMarkedForAutoClose(otherSurfaceId))
  }

  // MARK: - Custom command success toast

  @Test func customCommandSuccessEmitsNameAndDuration() {
    let state = makeState()
    var received: [(String, Int)] = []
    state.onCustomCommandSucceeded = { name, durationMs in
      received.append((name, durationMs))
    }
    state.markSurfaceForCustomCommand(surfaceId, name: "Build")

    state.handleCommandFinished(exitCode: 0, durationNs: 1_500_000_000, surfaceId: surfaceId)

    #expect(received.count == 1)
    #expect(received.first?.0 == "Build")
    #expect(received.first?.1 == 1_500)
  }

  @Test func customCommandFailureSkipsSuccessEvent() {
    let state = makeState()
    var received: [(String, Int)] = []
    state.onCustomCommandSucceeded = { name, durationMs in
      received.append((name, durationMs))
    }
    state.markSurfaceForCustomCommand(surfaceId, name: "Build")

    state.handleCommandFinished(exitCode: 2, durationNs: 5_000_000_000, surfaceId: surfaceId)

    #expect(received.isEmpty)
  }

  @Test func customCommandMarkIsOneShot() {
    let state = makeState()
    var received: [(String, Int)] = []
    state.onCustomCommandSucceeded = { name, durationMs in
      received.append((name, durationMs))
    }
    state.markSurfaceForCustomCommand(surfaceId, name: "Build")

    state.handleCommandFinished(exitCode: 0, durationNs: 1_000_000_000, surfaceId: surfaceId)
    state.handleCommandFinished(exitCode: 0, durationNs: 2_000_000_000, surfaceId: surfaceId)

    #expect(received.count == 1)
  }

  @Test func customCommandDurationFormatter() {
    #expect(formatCustomCommandDuration(0) == "0ms")
    #expect(formatCustomCommandDuration(250) == "250ms")
    #expect(formatCustomCommandDuration(999) == "999ms")
    #expect(formatCustomCommandDuration(1_000) == "1.0s")
    #expect(formatCustomCommandDuration(1_540) == "1.5s")
    #expect(formatCustomCommandDuration(9_900) == "9.9s")
    #expect(formatCustomCommandDuration(12_000) == "12s")
    #expect(formatCustomCommandDuration(75_000) == "1m 15s")
  }

  // MARK: - Helpers

  private func makeState(threshold: Int = 10) -> WorktreeTerminalState {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    state.setCommandFinishedNotification(enabled: true, threshold: threshold)
    return state
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-\(UUID().uuidString)",
      name: "wt-test",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-test"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }
}
