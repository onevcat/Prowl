import Foundation
import Security

protocol RemoteControlAccessTokenSecretStorage: Sendable {
  func load() throws -> Data?
  func save(_ secret: Data) throws
  func remove() throws
}

enum RemoteControlAccessTokenStoreError: Error, Equatable, Sendable {
  case keychainOperationFailed(OSStatus)
  case randomGenerationFailed(OSStatus)
}

@MainActor
final class RemoteControlAccessTokenStore {
  static let shared = RemoteControlAccessTokenStore()

  private static let tokenByteCount = 32
  private let storage: any RemoteControlAccessTokenSecretStorage

  init(storage: any RemoteControlAccessTokenSecretStorage = KeychainTokenStorage()) {
    self.storage = storage
  }

  func loadOrCreate() throws -> String {
    if let secret = try storage.load(), secret.count == Self.tokenByteCount {
      return Self.base64URLEncoded(secret)
    }
    return try rotate()
  }

  func rotate() throws -> String {
    let secret = try Self.makeRandomSecret()
    try storage.save(secret)
    return Self.base64URLEncoded(secret)
  }

  func remove() throws {
    try storage.remove()
  }

  private static func makeRandomSecret() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: tokenByteCount)
    let byteCount = bytes.count
    let status = bytes.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw RemoteControlAccessTokenStoreError.randomGenerationFailed(status)
    }
    return Data(bytes)
  }

  private static func base64URLEncoded(_ secret: Data) -> String {
    secret.base64EncodedString()
      .replacing("+", with: "-")
      .replacing("/", with: "_")
      .replacing("=", with: "")
  }
}

private struct KeychainTokenStorage: RemoteControlAccessTokenSecretStorage {
  private let service = "com.onevcat.prowl.remote-control"
  private let account = "access-token"

  func load() throws -> Data? {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(baseQuery(returningData: true) as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let secret = item as? Data else {
        throw RemoteControlAccessTokenStoreError.keychainOperationFailed(errSecDecode)
      }
      return secret
    case errSecItemNotFound:
      return nil
    default:
      throw RemoteControlAccessTokenStoreError.keychainOperationFailed(status)
    }
  }

  func save(_ secret: Data) throws {
    var query = baseQuery()
    query[kSecValueData] = secret
    query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    switch addStatus {
    case errSecSuccess:
      return
    case errSecDuplicateItem:
      let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData: secret] as CFDictionary)
      guard updateStatus == errSecSuccess else {
        throw RemoteControlAccessTokenStoreError.keychainOperationFailed(updateStatus)
      }
    default:
      throw RemoteControlAccessTokenStoreError.keychainOperationFailed(addStatus)
    }
  }

  func remove() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RemoteControlAccessTokenStoreError.keychainOperationFailed(status)
    }
  }

  private func baseQuery(returningData: Bool = false) -> [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    if returningData {
      query[kSecReturnData] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
    }
    return query
  }
}
