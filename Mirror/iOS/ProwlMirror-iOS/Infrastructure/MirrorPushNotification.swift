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

  /// Why a push keeps the fallback text. The extension logs it (docs-ai 095 M4); it names no
  /// Host or content.
  enum Failure: String, Error, Equatable {
    /// No `sealed` value, or not one that names a Host.
    case malformed
    /// This phone has no key for the Host: it was forgotten, or never registered here.
    case noKey
    /// The key does not open it: another pairing's key, or corrupt data.
    case cannotOpen
    /// It opens, but the content is of an unknown version or shape.
    case unsupportedContent
  }

  /// `nil` when the push cannot be opened; `read` says why.
  static func open(userInfo: [AnyHashable: Any], key: (UUID) -> SymmetricKey?) -> Opened? {
    try? read(userInfo: userInfo, key: key).get()
  }

  static func read(userInfo: [AnyHashable: Any], key: (UUID) -> SymmetricKey?) -> Result<Opened, Failure> {
    guard let sealed = userInfo[sealedKey] as? String, let hostID = MirrorPushCrypto.hostID(ofSealed: sealed) else {
      return .failure(.malformed)
    }
    guard let key = key(hostID) else { return .failure(.noKey) }
    guard let plaintext = try? MirrorPushCrypto.open(sealed, key: key) else { return .failure(.cannotOpen) }
    guard let content = try? MirrorPushContent.decode(plaintext) else { return .failure(.unsupportedContent) }
    return .success(Opened(hostID: hostID, content: content))
  }

  /// Generic text by kind, so the tab name stays off the lock screen, unless **Show Details**
  /// is on: then the Host's title (tab and worktree) and text. The Host and pane go into
  /// `userInfo` for the tap, and notifications group by Host.
  static func apply(_ opened: Opened, to content: UNMutableNotificationContent, showsDetails: Bool) {
    if showsDetails, !opened.content.title.isEmpty {
      content.title = opened.content.title
      content.body = opened.content.body
    } else {
      content.title = String(localized: "MIRROR_PUSH_TITLE")
      content.body =
        switch opened.content.kind {
        case .blocked: String(localized: "MIRROR_PUSH_BLOCKED")
        case .done: String(localized: "MIRROR_PUSH_DONE")
        }
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
