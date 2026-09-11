import Foundation
import Security

nonisolated struct MirrorSavedConnection: Codable, Equatable {
  let address: String
  let port: UInt16
  var pairingKey: String
  var credential: MirrorDeviceCredential?

  private static func query(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String:
        "\(Bundle.main.bundleIdentifier ?? "com.onevcat.prowl").remote-mirror",
      kSecAttrAccount as String: account,
    ]
  }

  static func load(account: String = "last-verified-host") throws -> Self? {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    guard let data = result as? Data else { throw MirrorProtocolError.invalidMessage }
    let saved = try JSONDecoder().decode(Self.self, from: data)
    return saved.credential == nil ? nil : saved
  }

  func save(account: String = "last-verified-host") throws {
    guard credential != nil else { return }
    var saved = self
    saved.pairingKey = ""
    let data = try JSONEncoder().encode(saved)
    let update = [kSecValueData as String: data]
    var status = SecItemUpdate(Self.query(account: account) as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var item = Self.query(account: account)
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  static func remove(account: String = "last-verified-host") throws {
    let status = SecItemDelete(query(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
      "Unable to access saved Host credentials (Keychain \(status))."
    }
  }
}
