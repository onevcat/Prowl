import SwiftUI

struct ToolbarNotificationsPopoverView: View {
  let groups: [ToolbarNotificationRepositoryGroup]
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onDismissAll: () -> Void

  var body: some View {
    let notificationCount = groups.reduce(0) { count, repository in
      count + repository.notificationCount
    }
    let notificationLabel = notificationCount == 1 ? "notification" : "notifications"
    let notificationRows = makeNotificationRows()

    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Notifications")
              .font(.headline)
            Text("\(notificationCount) \(notificationLabel)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Dismiss All") {
            onDismissAll()
          }
          .disabled(notificationCount == 0)
          .help("Dismiss all notifications")
        }

        Divider()

        VStack(alignment: .leading, spacing: 0) {
          ForEach(notificationRows) { row in
            notificationButton(row)
            if row.id != notificationRows.last?.id {
              Divider()
                .padding(.leading, 20)
            }
          }
        }
      }
      .padding()
    }
    .frame(minWidth: 320, maxWidth: 520, maxHeight: 440)
  }

  private func makeNotificationRows() -> [ToolbarNotificationRow] {
    let rows = groups.flatMap { repository in
      repository.worktrees.flatMap { worktree in
        worktree.notifications.map { notification in
          ToolbarNotificationRow(
            repositoryName: repository.name,
            worktreeID: worktree.id,
            worktreeName: worktree.name,
            notification: notification
          )
        }
      }
    }

    return rows.filter(\.isUnread) + rows.filter { !$0.isUnread }
  }

  @ViewBuilder
  private func notificationButton(_ row: ToolbarNotificationRow) -> some View {
    Button {
      onSelectNotification(row.worktreeID, row.notification)
    } label: {
      HStack(alignment: .top, spacing: 8) {
        Circle()
          .fill(row.isUnread ? Color.orange : Color.clear)
          .frame(width: 6, height: 6)
          .padding(.top, 5)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(row.notification.content)
            .font(.caption)
            .fontWeight(row.isUnread ? .semibold : .regular)
            .foregroundStyle(row.notification.isRead ? Color.secondary : Color.primary)
            .lineLimit(2)
          HStack(spacing: 5) {
            Text(row.repositoryName)
              .lineLimit(1)
            Circle()
              .fill(Color.secondary)
              .frame(width: 3, height: 3)
              .accessibilityHidden(true)
            Text(row.worktreeName)
              .lineLimit(1)
          }
          .font(.caption2.weight(.regular))
          .foregroundStyle(.tertiary)
          .padding(.top, 1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
    .help(
      row.notification.content.isEmpty
        ? "Select worktree and focus terminal"
        : row.notification.content
    )
  }
}

private struct ToolbarNotificationRow: Identifiable {
  let repositoryName: String
  let worktreeID: Worktree.ID
  let worktreeName: String
  let notification: WorktreeTerminalNotification

  var id: WorktreeTerminalNotification.ID {
    notification.id
  }

  var isUnread: Bool {
    !notification.isRead
  }
}
