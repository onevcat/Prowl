import SwiftUI

struct ToolbarNotificationsPopoverButton: View {
  @Environment(ToolbarPopoverCoordinator.self) private var popovers
  let groups: [ToolbarNotificationRepositoryGroup]
  let unseenWorktreeCount: Int
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onDismissAll: () -> Void

  private var notificationCount: Int {
    groups.reduce(0) { count, repository in
      count
        + repository.worktrees.reduce(0) { worktreeCount, worktree in
          worktreeCount + worktree.notifications.filter { !$0.isRead }.count
        }
    }
  }

  var body: some View {
    Button {
      popovers.toggle(.notifications)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: unseenWorktreeCount > 0 ? "bell.badge.fill" : "bell.fill")
          .foregroundStyle(unseenWorktreeCount > 0 ? .orange : .secondary)
          .accessibilityHidden(true)
        if notificationCount > 0 {
          Text(notificationCount, format: .number)
            .font(.caption.monospacedDigit())
        }
      }
    }
    .help("Notifications. Hover or click to show all notifications.")
    .accessibilityLabel("Notifications")
    .onHover { popovers.hoverButton(.notifications, hovering: $0) }
    .popover(
      isPresented: Binding(
        get: { popovers.presented == .notifications },
        set: { if !$0 { popovers.dismiss(.notifications) } }
      )
    ) {
      ToolbarNotificationsPopoverView(
        groups: groups,
        onSelectNotification: { worktreeID, notification in
          onSelectNotification(worktreeID, notification)
          popovers.dismiss(.notifications)
        },
        onDismissAll: {
          onDismissAll()
          popovers.dismiss(.notifications)
        }
      )
      .onHover { popovers.hoverPopover(.notifications, hovering: $0) }
    }
    .onChange(of: groups) { _, newValue in
      if newValue.isEmpty { popovers.dismiss(.notifications) }
    }
    .onDisappear { popovers.dismiss(.notifications) }
  }
}
