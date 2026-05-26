import CryptoKit
import Foundation

internal struct TmuxWindowID: Codable, Equatable, Hashable, Sendable {
  internal let rawValue: String

  internal init?(rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  internal init(from decoder: Decoder) throws {
    let rawValue = try Self.decodeRawValue(from: decoder)
    guard Self.isValid(rawValue) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid tmux window ID")
      )
    }
    self.rawValue = rawValue
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private static func isValid(_ rawValue: String) -> Bool {
    TmuxIDValidation.isValid(rawValue, prefix: UInt8(ascii: "@"))
  }

  private static func decodeRawValue(from decoder: Decoder) throws -> String {
    if let rawValue = try? decoder.singleValueContainer().decode(String.self) {
      return rawValue
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    return try container.decode(String.self, forKey: .rawValue)
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }
}

internal struct TmuxPaneID: Codable, Equatable, Hashable, Sendable {
  internal let rawValue: String

  internal init?(rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  internal init(from decoder: Decoder) throws {
    let rawValue = try Self.decodeRawValue(from: decoder)
    guard Self.isValid(rawValue) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid tmux pane ID")
      )
    }
    self.rawValue = rawValue
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private static func isValid(_ rawValue: String) -> Bool {
    TmuxIDValidation.isValid(rawValue, prefix: UInt8(ascii: "%"))
  }

  private static func decodeRawValue(from decoder: Decoder) throws -> String {
    if let rawValue = try? decoder.singleValueContainer().decode(String.self) {
      return rawValue
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    return try container.decode(String.self, forKey: .rawValue)
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }
}

internal struct TmuxTerminalTarget: Codable, Equatable, Hashable, Sendable {
  internal let socketURL: URL
  internal let groupSession: String
  internal let clientSession: String
  internal var windowID: TmuxWindowID?
  internal var paneID: TmuxPaneID?

  internal static func make(
    appNamespace: String,
    worktreeID: Worktree.ID,
    tabID: TerminalTabID,
    socketRoot: URL
  ) -> TmuxTerminalTarget {
    let worktreeHash = stableHash(worktreeID)
    let tabPrefix = tabID.rawValue.uuidString.replacing("-", with: "").prefix(12)
    return TmuxTerminalTarget(
      socketURL: socketRoot.appending(path: "\(appNamespace).sock"),
      groupSession: "\(appNamespace)-wt-\(worktreeHash)",
      clientSession: "\(appNamespace)-tab-\(tabPrefix)",
      windowID: nil,
      paneID: nil
    )
  }

  private static func stableHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}

private enum TmuxIDValidation {
  private static let asciiDigitRange = UInt8(ascii: "0")...UInt8(ascii: "9")

  fileprivate static func isValid(_ rawValue: String, prefix: UInt8) -> Bool {
    let bytes = rawValue.utf8
    guard bytes.first == prefix else { return false }

    let suffix = bytes.dropFirst()
    return !suffix.isEmpty && suffix.allSatisfy { asciiDigitRange.contains($0) }
  }
}
