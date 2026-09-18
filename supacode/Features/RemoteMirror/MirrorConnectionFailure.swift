import Foundation
import Network
import Security

/// User-facing classification of a transport failure. Raw Network.framework text belongs in the log.
nonisolated enum MirrorConnectionFailure: Equatable, Sendable {
  case handshakeRejected(OSStatus)
  case refused
  case unreachable
  case unresolvable
  case timedOut
  case addressInUse
  case addressUnavailable
  case other(String)

  init(_ error: NWError) {
    switch error {
    case .tls(let status):
      self = .handshakeRejected(status)
    case .posix(let code):
      switch code {
      case .ECONNREFUSED: self = .refused
      case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN: self = .unreachable
      case .ETIMEDOUT: self = .timedOut
      case .EADDRINUSE: self = .addressInUse
      case .EADDRNOTAVAIL: self = .addressUnavailable
      default: self = .other(error.localizedDescription)
      }
    case .dns:
      self = .unresolvable
    default:
      self = .other(error.localizedDescription)
    }
  }

  /// Message for an outgoing connection. `pairing` is true while a temporary code is presented.
  func clientMessage(endpoint: String, pairing: Bool) -> String {
    switch self {
    case .handshakeRejected:
      if pairing {
        return String(
          localized: "Host rejected the pairing code. Check the code, or refresh it on Host and try again."
        )
      }
      return String(localized: "This Host no longer recognizes this Mac. Enter a new pairing code from Host.")
    case .refused:
      return String(
        localized: "Nothing is listening at \(endpoint). Check that Host is started and the port is correct."
      )
    case .unreachable:
      return String(localized: "Cannot reach \(endpoint). Check that both Macs are on the same network or VPN.")
    case .unresolvable:
      return String(localized: "Cannot resolve the address \(endpoint). Check the name or use an IP address.")
    case .timedOut:
      return String(localized: "No response from \(endpoint). Check the address and that Host is started.")
    case .addressInUse, .addressUnavailable, .other:
      return String(localized: "Cannot connect to \(endpoint): \(detail)")
    }
  }

  /// Message for a listener that failed to start or stopped.
  func listenerMessage(address: String, port: String) -> String {
    switch self {
    case .addressInUse:
      String(localized: "Port \(port) is already in use. Stop the other program or choose another port.")
    case .addressUnavailable:
      String(localized: "This Mac has no network interface with the address \(address).")
    default:
      String(localized: "Cannot start Host: \(detail)")
    }
  }

  private var detail: String {
    switch self {
    case .handshakeRejected(let status): String(localized: "TLS handshake failed (\(String(status))).")
    case .refused: String(localized: "connection refused.")
    case .unreachable: String(localized: "network unreachable.")
    case .unresolvable: String(localized: "address not resolved.")
    case .timedOut: String(localized: "timed out.")
    case .addressInUse: String(localized: "address already in use.")
    case .addressUnavailable: String(localized: "address not available.")
    case .other(let text): text
    }
  }
}
