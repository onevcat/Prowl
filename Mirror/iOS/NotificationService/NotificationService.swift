import UserNotifications

/// Opens each Mirror push with the Host's key from the shared Keychain group (docs-ai 095).
/// The work is synchronous and short, so the time limit does not apply.
final class NotificationService: UNNotificationServiceExtension {
  override func didReceive(
    _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let original = request.content
    guard
      let opened = MirrorPushNotification.open(
        userInfo: original.userInfo, key: { try? MirrorPushKeyStore.load(hostID: $0) }),
      let content = original.mutableCopy() as? UNMutableNotificationContent
    else {
      contentHandler(original)
      return
    }
    MirrorPushNotification.apply(opened, to: content, showsDetails: MirrorPushKeyStore.showsDetails)
    contentHandler(content)
  }
}
