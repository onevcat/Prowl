import Foundation
import Security

nonisolated struct MirrorSavedConnection: Codable, Equatable {
  let address: String
  let port: UInt16
  var pairingKey: String
  var credential: MirrorDeviceCredential?

  var endpointID: String { address + ":" + String(port) }

  static func verifiedHosts(from records: [Self]) -> [Self] {
    var hosts: [String: Self] = [:]
    for record in records where record.credential != nil {
      hosts[record.endpointID] = record
    }
    return hosts.values.sorted { $0.endpointID < $1.endpointID }
  }

  static func loadAll(
    service: String? = nil,
    copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
  ) throws -> [Self] {
    var request = query(account: "", service: service)
    request.removeValue(forKey: kSecAttrAccount as String)
    // macOS password queries cannot return data for all matches at once.
    request[kSecReturnAttributes as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = copyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw MirrorCredentialVault.Failure(status: status, operation: .readHost) }
    guard let items = result as? [[String: Any]] else { throw MirrorProtocolError.invalidMessage }
    let records: [Self] = items.compactMap { item in
      guard let account = item[kSecAttrAccount as String] as? String,
        account.hasPrefix("host:")
      else { return nil }
      do {
        return try load(account: account, service: service, copyMatching: copyMatching)
      } catch {
        SupaLogger("RemoteMirror").warning("Skipped an unreadable saved Host: \(error)")
        return nil
      }
    }
    return verifiedHosts(from: records)
  }

  private static func query(account: String, service: String? = nil) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String:
        service ?? "\(Bundle.main.bundleIdentifier ?? "com.onevcat.prowl").remote-mirror",
      kSecAttrAccount as String: account,
    ]
  }

  static func load(
    account: String = "last-verified-host", service: String? = nil,
    copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
  ) throws -> Self? {
    var request = query(account: account, service: service)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = copyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw MirrorCredentialVault.Failure(status: status, operation: .readHost) }
    guard let data = result as? Data else { throw MirrorProtocolError.invalidMessage }
    let saved = try JSONDecoder().decode(Self.self, from: data)
    return saved.credential == nil ? nil : saved
  }

  func save(account: String = "last-verified-host", service: String? = nil) throws {
    guard credential != nil else { return }
    var saved = self
    saved.pairingKey = ""
    let data = try JSONEncoder().encode(saved)
    let update = [kSecValueData as String: data]
    var status = SecItemUpdate(Self.query(account: account, service: service) as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var item = Self.query(account: account, service: service)
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw MirrorCredentialVault.Failure(status: status, operation: .saveHost) }
  }

  static func remove(account: String = "last-verified-host", service: String? = nil) throws {
    let status = SecItemDelete(query(account: account, service: service) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MirrorCredentialVault.Failure(status: status, operation: .removeHost)
    }
  }

  /// Removes this endpoint's credential, and the last-used record when it points at the same Host.
  func forget(service: String? = nil) throws {
    try Self.remove(account: "host:" + endpointID, service: service)
    if let last = try Self.load(service: service), last.endpointID == endpointID {
      try Self.remove(service: service)
    }
  }

}
