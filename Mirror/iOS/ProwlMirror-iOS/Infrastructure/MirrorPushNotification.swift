import CryptoKit
import Foundation
import UserNotifications

/// What a Mirror push shows (docs-ai 095). The Notification Service Extension and the app
/// both compile this file. When a push cannot be opened, the notification keeps the gateway's
/// localized fallback text.
nonisolated enum MirrorPushNotification {
  static let sealedKey = "sealed"
  static let hostIDKey = "hostID"
  static let paneIDKey = "paneID"
  static let kindKey = "kind"

  struct Opened: Equatable {
    let hostID: UUID
    let content: MirrorPushContent
  }

  /// `nil` when `sealed` is missing or malformed, this phone has no key for the Host, or the
  /// content does not decrypt or decode.
  static func open(userInfo: [AnyHashable: Any], key: (UUID) -> SymmetricKey?) -> Opened? {
    guard let sealed = userInfo[sealedKey] as? String,
      let hostID = MirrorPushCrypto.hostID(ofSealed: sealed),
      let key = key(hostID),
      let plaintext = try? MirrorPushCrypto.open(sealed, key: key),
      let content = try? MirrorPushContent.decode(plaintext)
    else { return nil }
    return Opened(hostID: hostID, content: content)
  }

  /// Generic text by kind: the tab name and the prompt stay off the lock screen. The Host and
  /// pane go into `userInfo` for the tap, and notifications group by Host.
  static func apply(_ opened: Opened, to content: UNMutableNotificationContent) {
    content.title = String(localized: "MIRROR_PUSH_TITLE")
    content.body =
      switch opened.content.kind {
      case .blocked: String(localized: "MIRROR_PUSH_BLOCKED")
      case .done: String(localized: "MIRROR_PUSH_DONE")
      }
    content.threadIdentifier = opened.hostID.uuidString
    content.targetContentIdentifier = opened.content.paneID.uuidString
    var userInfo = content.userInfo
    userInfo.removeValue(forKey: sealedKey)
    userInfo[hostIDKey] = opened.hostID.uuidString
    userInfo[paneIDKey] = opened.content.paneID.uuidString
    userInfo[kindKey] = opened.content.kind.rawValue
    content.userInfo = userInfo
  }
}
