import SwiftUI

struct NotificationPopoverView: View {
  let notifications: [WorktreeTerminalNotification]
  let onFocusNotification: (WorktreeTerminalNotification) -> Void

  var body: some View {
    let count = notifications.count
    let countLabel = count == 1 ? "notification" : "notifications"
    ScrollView {
      VStack(alignment: .leading) {
        Text("Notifications")
          .interfaceFont(.headline)
        Text("\(count) \(countLabel)")
          .interfaceFont(.subheadline)
          .foregroundStyle(.secondary)
        Divider()
        ForEach(notifications) { notification in
          Button {
            onFocusNotification(notification)
          } label: {
            HStack(alignment: .top) {
              Image(systemName: "bell")
                .foregroundStyle(notification.isRead ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
              Text(notification.content)
                .foregroundStyle(notification.isRead ? Color.secondary : Color.primary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .interfaceFont(.caption)
          .help(notification.content.isEmpty ? "Focus pane" : notification.content)
        }
      }
      .padding()
    }
    .frame(minWidth: 260, maxWidth: 480, maxHeight: 400)
  }
}
