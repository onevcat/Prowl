import Foundation
import Testing

@testable import supacode

struct WorktreeTerminalNotificationPruneTests {
  private func notification(surface: UUID, title: String, isRead: Bool) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(surfaceId: surface, title: title, body: "", isRead: isRead)
  }

  @Test func pruningRemovesEveryNotificationFromTheClosedSurface() {
    let closed = UUID()
    let other = UUID()
    let notifications = [
      notification(surface: closed, title: "unread", isRead: false),
      notification(surface: other, title: "kept", isRead: false),
      // A read notification from the closed surface should go too — the
      // surface no longer exists, so keeping it serves no purpose.
      notification(surface: closed, title: "read", isRead: true),
    ]

    let pruned = WorktreeTerminalState.prunedNotifications(from: notifications, removingSurfaceID: closed)

    #expect(pruned.map(\.title) == ["kept"])
  }

  @Test func pruningAClosedSurfaceClearsAStuckUnseenIndicator() {
    // The bug: an unread notification from a closed surface kept
    // `hasUnseenNotification`-style state lit forever. After pruning the only
    // unread notification, nothing unread should remain.
    let closed = UUID()
    let notifications = [notification(surface: closed, title: "stuck", isRead: false)]

    let pruned = WorktreeTerminalState.prunedNotifications(from: notifications, removingSurfaceID: closed)

    #expect(pruned.isEmpty)
    #expect(!pruned.contains { !$0.isRead })
  }

  @Test func pruningLeavesUnrelatedSurfacesUntouched() {
    let other = UUID()
    let notifications = [notification(surface: other, title: "kept", isRead: false)]

    let pruned = WorktreeTerminalState.prunedNotifications(from: notifications, removingSurfaceID: UUID())

    #expect(pruned == notifications)
  }
}
