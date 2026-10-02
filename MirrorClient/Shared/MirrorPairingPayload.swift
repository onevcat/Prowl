import Foundation
import Network

nonisolated struct MirrorPairingPayload: Codable, Equatable {
  let type: String
  let version: Int
  let address: String
  let port: UInt16
  let code: String
  let expiresAt: Int64

  enum Problem: LocalizedError {
    case invalid, expired

    var errorDescription: String? {
      switch self {
      case .invalid: String(localized: "Scan a Prowl pairing QR code from Add a Device on Host.")
      case .expired:
        String(localized: "This pairing code expired. Refresh Code on Host and scan again.")
      }
    }
  }

  init(address: String, port: UInt16, code: String, expires: Date) throws {
    type = "prowl-mirror-pairing"
    version = 1
    self.address = address
    self.port = port
    self.code = try MirrorPairingCode.normalized(code)
    expiresAt = Int64(expires.timeIntervalSince1970.rounded(.up))
    try validate(now: .distantPast)
  }

  static func parse(_ text: String, now: Date = Date()) throws -> Self {
    guard text.utf8.count <= 2048,
      let payload = try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
    else { throw Problem.invalid }
    try payload.validate(now: now)
    return payload
  }

  func encoded() throws -> String {
    String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
  }

  private var isLocalOnly: Bool {
    if let ipv4 = IPv4Address(address) {
      return ipv4.isLoopback || ipv4.rawValue.allSatisfy { $0 == 0 }
    }
    if let ipv6 = IPv6Address(address) {
      let bytes = Array(ipv6.rawValue)
      return ipv6.isLoopback || bytes.allSatisfy { $0 == 0 }
        || (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
          && (bytes[12] == 127 || bytes.suffix(4).allSatisfy { $0 == 0 }))
    }
    return true
  }

  private func validate(now: Date) throws {
    guard type == "prowl-mirror-pairing", version == 1, port > 0,
      IPv4Address(address) != nil || IPv6Address(address) != nil,
      !isLocalOnly, !address.contains("%"),
      (try? MirrorPairingCode.normalized(code)) == code, expiresAt > 0
    else { throw Problem.invalid }
    guard Double(expiresAt) > now.timeIntervalSince1970 else { throw Problem.expired }
  }
}
