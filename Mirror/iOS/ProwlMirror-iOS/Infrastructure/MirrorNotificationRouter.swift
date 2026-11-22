import Foundation
import Observation
import UserNotifications

/// The pane a tapped notification points at (docs-ai 095 P3f). The app delegate sets it; the
/// root view selects the Host, waits for its pane list and opens the pane.
@Observable
final class MirrorNotificationRouter {
  static let shared = MirrorNotificationRouter()

  nonisolated struct Target: Equatable, Sendable {
    let hostID: UUID
    let paneID: UUID
  }

  var pending: Target?

  /// The target of a notification that the extension opened; `nil` for the fallback text,
  /// which carries no route.
  nonisolated static func target(of userInfo: [AnyHashable: Any]) -> Target? {
    guard let host = (userInfo[MirrorPushNotification.hostIDKey] as? String).flatMap(UUID.init(uuidString:)),
      let pane = (userInfo[MirrorPushNotification.paneIDKey] as? String).flatMap(UUID.init(uuidString:))
    else { return nil }
    return Target(hostID: host, paneID: pane)
  }

  /// Where a target leads once the Host's panes are known: the pane, or `nil` when the pane is
  /// gone (the agents list stays).
  nonisolated static func route(
    for target: Target, host: MirrorHostRecord, panes: [MirrorPaneDescriptor]
  ) -> MirrorPaneRoute? {
    guard host.hostID == target.hostID, let pane = panes.first(where: { $0.id == target.paneID }) else { return nil }
    return MirrorPaneRoute(host: host, pane: pane)
  }
}

/// Shows Mirror notifications in the foreground too, and routes a tap.
final class MirrorNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  static let shared = MirrorNotificationDelegate()

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let target = MirrorNotificationRouter.target(of: response.notification.request.content.userInfo)
    else { return }
    MirrorNotificationRouter.shared.pending = target
  }
}
