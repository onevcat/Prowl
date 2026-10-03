import Foundation

/// Local display transport, independent of the remote protocol and its credentials.
public nonisolated struct MirrorRelayPacket: Equatable, Sendable {
  public enum Kind: UInt8, Sendable {
    case authenticate = 1
    case frame, input, acknowledge, ping, pong
  }
  public let kind: Kind
  public let payload: Data
  public static let maximumPayload = 8 * 1024 * 1024

  public init(kind: Kind, payload: Data) {
    self.kind = kind
    self.payload = payload
  }

  public func encoded() throws -> Data {
    guard Self.validLength(payload.count, kind: kind) else {
      throw Failure.invalidPacket
    }
    let count = UInt32(payload.count)
    var bytes = Data([kind.rawValue])
    bytes.append(
      contentsOf: (0..<4).reversed().map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
    bytes.append(payload)
    return bytes
  }

  public static func header(_ bytes: Data) throws -> (kind: Kind, length: Int) {
    guard bytes.count == 5, let kind = Kind(rawValue: bytes[bytes.startIndex]) else {
      throw Failure.invalidPacket
    }
    let length = bytes.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
    // Code security: bound allocations before consuming an untrusted length.
    guard validLength(length, kind: kind) else { throw Failure.invalidPacket }
    return (kind, length)
  }

  private static func validLength(_ length: Int, kind: Kind) -> Bool {
    if kind == .ping || kind == .pong { return length == 0 }
    return length > 0 && length <= maximumPayload
  }

  public static func sequenceBytes(_ sequence: UInt64) -> Data {
    Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) })
  }

  public static func sequence(_ bytes: Data) throws -> UInt64 {
    guard bytes.count == 8 else { throw Failure.invalidPacket }
    return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
  }

  public enum Failure: Error { case invalidPacket }
}
