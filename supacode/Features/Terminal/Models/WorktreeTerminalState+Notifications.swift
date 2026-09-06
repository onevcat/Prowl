import Foundation
import ProwlCLIShared

extension WorktreeTerminalState {
  /// How recently the user must have typed for us to consider the exit user-initiated.
  static let recentInteractionWindow: Duration = .seconds(3)

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    if !enabled {
      markAllNotificationsRead()
    }
  }

  func setCommandFinishedNotification(enabled: Bool, threshold: Int) {
    commandFinishedNotificationEnabled = enabled
    commandFinishedNotificationThreshold = threshold
  }

  func clearNotificationIndicator() {
    markAllNotificationsRead()
  }

  func markAllNotificationsRead() {
    let previousHasUnseen = hasUnseenNotification
    for index in notifications.indices {
      notifications[index].isRead = true
    }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func markNotificationsRead(forSurfaceID surfaceID: UUID) {
    let previousHasUnseen = hasUnseenNotification
    for index in notifications.indices where notifications[index].surfaceId == surfaceID {
      notifications[index].isRead = true
    }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func markNotificationRead(id notificationID: WorktreeTerminalNotification.ID) {
    let previousHasUnseen = hasUnseenNotification
    guard let index = notifications.firstIndex(where: { $0.id == notificationID }) else {
      return
    }
    notifications[index].isRead = true
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func dismissNotification(_ notificationID: WorktreeTerminalNotification.ID) {
    let previousHasUnseen = hasUnseenNotification
    notifications.removeAll { $0.id == notificationID }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func dismissAllNotifications() {
    let previousHasUnseen = hasUnseenNotification
    notifications.removeAll()
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func recordKeyInput(forSurfaceID surfaceId: UUID) {
    lastKeyInputTimeBySurface[surfaceId] = .now
  }

  func handleCommandFinished(exitCode: Int?, durationNs: UInt64, surfaceId: UUID) {
    // Notify CLI waiters unconditionally before applying notification filters.
    if let continuation = commandFinishedWaiters.removeValue(forKey: surfaceId) {
      let durationMs = Int(durationNs / 1_000_000)
      continuation.yield((exitCode: exitCode, durationMs: durationMs))
      continuation.finish()
    }

    surfaceRunningStartedAtById.removeValue(forKey: surfaceId)
    noteCommandFinishedForCommandDetection(surfaceId: surfaceId)

    // Custom command success toast. One-shot: removed regardless of outcome.
    if let commandName = pendingCustomCommands.removeValue(forKey: surfaceId), exitCode == 0 {
      let durationMs = Int(durationNs / 1_000_000)
      onCustomCommandSucceeded?(commandName, durationMs)
    }

    // Auto-close on success (exit 0). One-shot: the id is removed regardless of outcome.
    if autoCloseSurfaceIds.remove(surfaceId) != nil {
      if exitCode == 0, surfaces[surfaceId] != nil {
        scheduleAutoClose(surfaceId: surfaceId)
        return
      }
    }

    guard commandFinishedNotificationEnabled else { return }
    let durationSeconds = Int(durationNs / 1_000_000_000)
    guard durationSeconds >= commandFinishedNotificationThreshold else { return }
    // Skip user-initiated termination (Ctrl+C / kill signal)
    if let code = exitCode, code == 130 || code == 143 { return }
    // Skip if the user was recently typing in this surface (e.g. /exit, quit)
    if let lastInput = lastKeyInputTimeBySurface[surfaceId],
      ContinuousClock.now - lastInput < Self.recentInteractionWindow
    {
      return
    }

    let title = (exitCode == nil || exitCode == 0) ? "Command finished" : "Command failed"
    let formattedDuration = Self.formatDuration(durationSeconds)
    let body: String
    if let code = exitCode, code != 0 {
      body = "Failed (exit code \(code)) after \(formattedDuration)"
    } else {
      body = "Completed in \(formattedDuration)"
    }
    appendNotification(title: title, body: body, surfaceId: surfaceId)
  }

  func appendNotification(
    title: String,
    body: String,
    surfaceId: UUID,
    treatAsViewedWhenWorktreeIsVisible: Bool = false
  ) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(trimmedTitle.isEmpty && trimmedBody.isEmpty) else { return }
    let isWorktreeSelected = isSelected()
    let isWorkflowViewed = treatAsViewedWhenWorktreeIsVisible && isViewingWorktree()
    if notificationsEnabled {
      let previousHasUnseen = hasUnseenNotification
      let isRead =
        treatAsViewedWhenWorktreeIsVisible
        ? isWorkflowViewed
        : (isWorktreeSelected && isFocusedSurface(surfaceId))
      notifications.insert(
        WorktreeTerminalNotification(
          surfaceId: surfaceId,
          title: trimmedTitle,
          body: trimmedBody,
          createdAt: Date(),
          isRead: isRead
        ),
        at: 0
      )
      emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
    }
    let isViewed = treatAsViewedWhenWorktreeIsVisible ? isWorkflowViewed : isViewedSurface(surfaceId)
    onNotificationReceived?(surfaceId, trimmedTitle, trimmedBody, isViewed)
  }

  static func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 {
      return "\(seconds)s"
    }
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    if minutes < 60 {
      return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
    }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
  }

  /// Removes every notification that originated from `surfaceID`, regardless of
  /// read state. Pure so the teardown behavior can be unit-tested without a
  /// live Ghostty surface.
  static func prunedNotifications(
    from notifications: [WorktreeTerminalNotification],
    removingSurfaceID surfaceID: UUID
  ) -> [WorktreeTerminalNotification] {
    notifications.filter { $0.surfaceId != surfaceID }
  }
}
