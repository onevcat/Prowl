import Foundation
import Network

/// Validation for the Client connection form. Host names are accepted; only a listener needs an IP.
nonisolated enum MirrorEndpointInput {
  struct Endpoint: Equatable {
    let address: String
    let port: UInt16
  }

  enum Problem: Error, Equatable {
    case emptyAddress
    case addressContainsPort
    case invalidAddress
    case invalidPort
    case missingPairingCode
    case invalidPairingCode

    var message: String {
      switch self {
      case .emptyAddress: String(localized: "Enter the Host address.")
      case .addressContainsPort: String(localized: "Enter the port in its own field.")
      case .invalidAddress: String(localized: "Enter an IP address or a host name without spaces.")
      case .invalidPort: String(localized: "Enter a port between 1 and 65535.")
      case .missingPairingCode: String(localized: "Enter the pairing code shown on Host.")
      case .invalidPairingCode:
        String(localized: "Pairing codes have eight letters or digits, shown as XXXX-XXXX.")
      }
    }
  }

  static func endpoint(address: String, port: String) throws(Problem) -> Endpoint {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .emptyAddress }
    guard !trimmed.contains(where: \.isWhitespace), !trimmed.contains("/") else { throw .invalidAddress }
    if trimmed.contains(":"), IPv6Address(trimmed) == nil { throw .addressContainsPort }
    guard let number = UInt16(port.trimmingCharacters(in: .whitespaces)), number > 0 else { throw .invalidPort }
    return Endpoint(address: trimmed, port: number)
  }

  static func pairingCode(_ input: String, required: Bool) throws(Problem) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      if required { throw .missingPairingCode }
      return ""
    }
    guard let code = try? MirrorPairingCode.normalized(trimmed) else { throw .invalidPairingCode }
    return code
  }
}
