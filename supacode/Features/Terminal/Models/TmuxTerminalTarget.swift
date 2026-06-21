import Foundation

internal nonisolated struct TmuxWindowID: Codable, Equatable, Hashable, Sendable {
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

internal nonisolated struct TmuxPaneID: Codable, Equatable, Hashable, Sendable {
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

internal nonisolated struct TmuxCardID: Codable, Equatable, Hashable, Sendable {
  internal let rawValue: String

  internal init(rawValue: String) {
    self.rawValue = rawValue
  }
}

internal nonisolated struct TmuxTerminalTarget: Codable, Equatable, Hashable, Sendable {
  internal static let cardContainerSession = "prowl-cards"

  internal let socketURL: URL
  internal let groupSession: String
  internal let clientSession: String
  internal let cardID: TmuxCardID
  internal var windowID: TmuxWindowID?
  internal var paneID: TmuxPaneID?

  internal init(
    socketURL: URL,
    groupSession: String,
    clientSession: String,
    cardID: TmuxCardID,
    windowID: TmuxWindowID?,
    paneID: TmuxPaneID?
  ) {
    self.socketURL = socketURL
    self.groupSession = groupSession
    self.clientSession = clientSession
    self.cardID = cardID
    self.windowID = windowID
    self.paneID = paneID
  }

  internal static func make(
    appNamespace: String,
    worktreeID _: Worktree.ID,
    tabID: TerminalTabID,
    cardID: TmuxCardID,
    socketRoot: URL
  ) -> TmuxTerminalTarget {
    let tabPrefix = tabID.rawValue.uuidString.replacing("-", with: "").prefix(12)
    return TmuxTerminalTarget(
      socketURL: socketRoot.appending(path: "\(appNamespace).sock"),
      groupSession: cardContainerSession,
      clientSession: "\(appNamespace)-tab-\(tabPrefix)",
      cardID: cardID,
      windowID: nil,
      paneID: nil
    )
  }

  internal static func restored(
    socketURL: URL,
    tabID: TerminalTabID,
    cardID: TmuxCardID,
    windowID: TmuxWindowID,
    paneID: TmuxPaneID?
  ) -> TmuxTerminalTarget {
    let tabPrefix = tabID.rawValue.uuidString.replacing("-", with: "").prefix(12)
    return TmuxTerminalTarget(
      socketURL: socketURL,
      groupSession: cardContainerSession,
      clientSession: "prowl-tab-\(tabPrefix)",
      cardID: cardID,
      windowID: windowID,
      paneID: paneID
    )
  }
}

private nonisolated enum TmuxIDValidation {
  private static let asciiDigitRange = UInt8(ascii: "0")...UInt8(ascii: "9")

  fileprivate static func isValid(_ rawValue: String, prefix: UInt8) -> Bool {
    let bytes = rawValue.utf8
    guard bytes.first == prefix else { return false }

    let suffix = bytes.dropFirst()
    return !suffix.isEmpty && suffix.allSatisfy { asciiDigitRange.contains($0) }
  }
}
