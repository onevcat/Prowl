import CryptoKit
import Foundation
import Security

nonisolated struct MirrorDeviceCredential: Codable, Equatable, Sendable {
  let hostID: UUID
  let deviceID: UUID
  let key: Data
}

/// The kind of a paired device, for its icon in the device list. The device reports it at
/// pairing; a record from an earlier version has none.
nonisolated enum MirrorDevicePlatform: String, Codable, Sendable {
  case iOS = "ios"
  case iPadOS = "ipados"
  case macOS = "macos"
  case android

  var symbolName: String {
    switch self {
    case .iOS: "iphone"
    case .iPadOS: "ipad"
    case .macOS: "laptopcomputer"
    case .android: "smartphone"
    }
  }

  /// The symbol for a device that reported no platform.
  static let unknownSymbolName = "macbook.and.iphone"
}

nonisolated struct MirrorPairedDevice: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let key: Data
  let pairedAt: Date
  var lastSeen: Date?
  var platform: MirrorDevicePlatform?

  init(
    id: UUID, name: String, key: Data, pairedAt: Date, lastSeen: Date? = nil,
    platform: MirrorDevicePlatform? = nil
  ) {
    self.id = id
    self.name = name
    self.key = key
    self.pairedAt = pairedAt
    self.lastSeen = lastSeen
    self.platform = platform
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    key = try container.decode(Data.self, forKey: .key)
    pairedAt = try container.decode(Date.self, forKey: .pairedAt)
    lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
    // An unknown value must not make the whole identity unreadable.
    platform = try container.decodeIfPresent(String.self, forKey: .platform)
      .flatMap(MirrorDevicePlatform.init(rawValue:))
  }
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
    guard status == errSecSuccess else { throw Failure(status: status, operation: .readIdentity) }
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
    guard status == errSecSuccess else { throw Failure(status: status, operation: .saveIdentity) }
  }
  enum Operation { case readIdentity, saveIdentity, readHost, saveHost, removeHost }

  struct Failure: LocalizedError {
    let status: OSStatus
    let operation: Operation

    var errorDescription: String? {
      switch operation {
      case .readIdentity: String(localized: "Could not read this Mac’s Host identity. Try again.")
      case .saveIdentity: String(localized: "Could not save this Mac’s Host identity. Try again.")
      case .readHost: String(localized: "Could not read saved Host access. Try connecting again.")
      case .saveHost: String(localized: "Could not save access to this Host. Try connecting again.")
      case .removeHost: String(localized: "Could not remove saved Host access. Try again.")
      }
    }
  }
}
