import CryptoKit
import Foundation
import Security

/// The push key of each Host, in the Keychain group that the Notification Service Extension
/// shares (docs-ai 095). Only the derived key is shared; the device secret stays in the app's
/// own group.
nonisolated enum MirrorPushKeyStore {
  static let service = "com.onevcat.prowl.mirror.push-key"

  /// `$(AppIdentifierPrefix)com.onevcat.prowl.mirror.shared`, from the Info.plist, because the
  /// team prefix is known only at build time.
  static var accessGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "MirrorSharedKeychainGroup") as? String
  }

  struct Failure: LocalizedError, Equatable {
    let status: OSStatus
    var errorDescription: String? { "Unable to store the notification key (Keychain \(status))." }
  }

  static func save(_ key: SymmetricKey, hostID: UUID) throws {
    let bytes = key.withUnsafeBytes { Data($0) }
    var status = SecItemUpdate(query(hostID) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query(hostID)
      item[kSecValueData as String] = bytes
      // The extension runs while the phone is locked, after the first unlock since boot.
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(status: status) }
  }

  static func load(hostID: UUID) throws -> SymmetricKey? {
    var request = query(hostID)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
    return SymmetricKey(data: data)
  }

  static func remove(hostID: UUID) throws {
    let status = SecItemDelete(query(hostID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
  }

  private static func query(_ hostID: UUID) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: hostID.uuidString,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }
}
