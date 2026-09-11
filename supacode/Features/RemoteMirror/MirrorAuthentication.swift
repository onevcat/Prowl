import CryptoKit
import Foundation
import Security

nonisolated struct MirrorDeviceCredential: Codable, Equatable, Sendable {
  let hostID: UUID
  let deviceID: UUID
  let key: Data
}

nonisolated struct MirrorPairedDevice: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let key: Data
  let pairedAt: Date
  var lastSeen: Date?
}

nonisolated struct MirrorHostIdentity: Codable {
  let id: UUID
  var devices: [MirrorPairedDevice]
}

nonisolated enum MirrorAuthentication {
  static func randomKey() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw MirrorProtocolError.invalidMessage
    }
    return Data(bytes)
  }

  static func proof(key: Data, host: UUID, nonce: Data, purpose: String, identity: String) -> Data {
    let message = Data((purpose + ":" + host.uuidString + ":" + identity + ":").utf8) + nonce
    return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
  }

  static func verify(
    _ proof: Data, key: Data, challenge: MirrorMessage.Challenge, purpose: String, identity: String
  ) -> Bool {
    let message = Data((purpose + ":" + challenge.hostID.uuidString + ":" + identity + ":").utf8) + challenge.nonce
    return HMAC<SHA256>.isValidAuthenticationCode(
      proof, authenticating: message, using: SymmetricKey(data: key))
  }
}

/// One atomic Keychain record prevents metadata and secret updates from diverging.
nonisolated enum MirrorCredentialVault {
  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.onevcat.prowl")
        + ".mirror-devices",
      kSecAttrAccount as String: account,
    ]
  }
  static func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
    var query = query(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure(status: status) }
    guard let data = result as? Data else { throw MirrorProtocolError.invalidMessage }
    return try JSONDecoder().decode(type, from: data)
  }
  static func save<T: Encodable>(_ value: T, account: String) throws {
    let bytes = try JSONEncoder().encode(value)
    var status = SecItemUpdate(
      query(account) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query(account)
      item[kSecValueData as String] = bytes
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(status: status) }
  }
  struct Failure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Unable to store device credentials (Keychain \(status))." }
  }
}
