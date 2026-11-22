import UserNotifications
import os

/// Opens each Mirror push with the Host's key from the shared Keychain group (docs-ai 095).
/// The work is synchronous and short, so the time limit does not apply.
final class NotificationService: UNNotificationServiceExtension {
  private static let log = Logger(subsystem: "com.onevcat.prowl.mirror-ios", category: "Push")

  override func didReceive(
    _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let original = request.content
    let result = MirrorPushNotification.read(
      userInfo: original.userInfo, key: { try? MirrorPushKeyStore.load(hostID: $0) })
    guard case .success(let opened) = result, let content = original.mutableCopy() as? UNMutableNotificationContent
    else {
      if case .failure(let failure) = result {
        Self.log.error("A push shows the fallback text: \(failure.rawValue, privacy: .public)")
      }
      contentHandler(original)
      return
    }
    MirrorPushNotification.apply(opened, to: content, showsDetails: MirrorPushKeyStore.showsDetails)
    contentHandler(content)
  }
}
