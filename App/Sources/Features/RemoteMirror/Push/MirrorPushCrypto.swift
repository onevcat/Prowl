import CryptoKit
import Foundation

/// End-to-end encryption of push payloads between the Host and the phone (docs-ai 095
/// "Encryption and content"). The iOS Notification Service Extension uses the same rules.
nonisolated enum MirrorPushCrypto {
  static let info = Data("prowl-mirror-push-v1".utf8)

  /// HKDF-SHA256 over the 32-byte device secret; salt = the Host UUID in its uppercase
  /// canonical spelling.
  static func key(deviceSecret: Data, hostID: UUID) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: deviceSecret), salt: Data(hostID.uuidString.utf8), info: info,
      outputByteCount: 32)
  }

  /// Base64 of the Host UUID's 16 raw bytes followed by the ChaChaPoly combined box
  /// (nonce, ciphertext, tag). The UUID is in clear so the extension can choose the key.
  static func seal(_ plaintext: Data, key: SymmetricKey, hostID: UUID, nonce: ChaChaPoly.Nonce = .init()) throws
    -> String
  {
    let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
    return (withUnsafeBytes(of: hostID.uuid) { Data($0) } + box.combined).base64EncodedString()
  }

  /// The first 16 bytes of HMAC-SHA256(key, "collapse:" + pane UUID), URL-safe Base64 without
  /// padding (22 characters), so the gateway never sees pane IDs.
  static func collapseID(paneID: UUID, key: SymmetricKey) -> String {
    let mac = HMAC<SHA256>.authenticationCode(for: Data(("collapse:" + paneID.uuidString).utf8), using: key)
    return Data(mac.prefix(16)).base64EncodedString()
      .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
  }
}

/// The sealed JSON of a push: `{v, kind, paneID, title, body, stateChangedAt}` (docs-ai 095).
nonisolated struct MirrorPushContent: Codable, Equatable, Sendable {
  var version = 1
  let kind: MirrorPushKind
  let paneID: UUID
  let title: String
  let body: String
  let stateChangedAt: String?

  private enum CodingKeys: String, CodingKey {
    case version = "v"
    case kind, paneID, title, body, stateChangedAt
  }
}
