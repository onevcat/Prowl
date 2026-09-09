import Foundation

nonisolated struct MirrorPaneDescriptor: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let title: String
  let directory: String
  let busy: Bool
  var projectName: String?
  var subtitle: String?
}

nonisolated struct MirrorFrame: Codable, Equatable, Sendable {
  let columns: UInt32
  let rows: UInt32
  let bytes: Data
}

nonisolated struct MirrorMessage: Codable, Sendable {
  enum Kind: String, Codable {
    case list, panes, subscribe, frame, acknowledge, input, history, historyPage, failure, ping, pong
  }
  var version = 1
  let kind: Kind
  var paneID: UUID?
  var panes: [MirrorPaneDescriptor]?
  var frame: MirrorFrame?
  var bytes: Data?
  var sequence: UInt64?
  var historyID: UUID?
  var offset: Int?
  var lines: [String]?
  var total: Int?
  var error: String?
}

nonisolated enum MirrorProtocolError: Error, LocalizedError {
  case invalidMessage, messageTooLarge, invalidPairingKey
  var errorDescription: String? {
    switch self {
    case .invalidMessage: "Invalid remote mirror message."
    case .messageTooLarge: "Remote mirror message exceeds the size limit."
    case .invalidPairingKey: "Paste the 64-character pairing key shown on the Host."
    }
  }
}

nonisolated enum MirrorWire {
  static let maximumPayload = 8 * 1024 * 1024
  static let maximumInput = 64 * 1024

  static func encode(_ message: MirrorMessage) throws -> Data {
    let payload = try JSONEncoder().encode(message)
    return try frame(payload)
  }

  static func frame(_ payload: Data) throws -> Data {
    guard !payload.isEmpty, payload.count <= maximumPayload else { throw MirrorProtocolError.messageTooLarge }
    var length = UInt32(payload.count).bigEndian
    var result = withUnsafeBytes(of: &length) { Data($0) }
    result.append(payload)
    return result
  }

  static func length(_ header: Data) throws -> Int {
    guard header.count == 4 else { throw MirrorProtocolError.invalidMessage }
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= maximumPayload else { throw MirrorProtocolError.messageTooLarge }
    return length
  }

  static func decode(_ data: Data) throws -> MirrorMessage {
    guard data.count <= maximumPayload else { throw MirrorProtocolError.messageTooLarge }
    let message = try JSONDecoder().decode(MirrorMessage.self, from: data)
    guard message.version == 1 else { throw MirrorProtocolError.invalidMessage }
    return message
  }
}

/// One unacknowledged frame per subscriber bounds memory even on a stalled link.
nonisolated struct MirrorFrameGate {
  private(set) var sequence: UInt64 = 0
  private(set) var outstanding: UInt64?
  private var previous: MirrorFrame?

  mutating func offer(_ frame: MirrorFrame) -> UInt64? {
    guard outstanding == nil, previous != frame else { return nil }
    sequence += 1
    outstanding = sequence
    previous = frame
    return sequence
  }

  mutating func acknowledge(_ sequence: UInt64) throws {
    guard outstanding == sequence else { throw MirrorProtocolError.invalidMessage }
    outstanding = nil
  }
}

/// Pages refer to one retained-text snapshot, never moving offsets in a live PTY.
nonisolated struct MirrorHistory {
  let id = UUID()
  let lines: [String]
  static let pageSize = 200
  static let maximumBytes = 2 * 1024 * 1024

  init(text: String) {
    // A byte limit can split a scalar; discard only its leading continuation bytes.
    let bytes = text.utf8.suffix(Self.maximumBytes).drop(while: { $0 & 0xC0 == 0x80 })
    guard let bounded = String(bytes: bytes, encoding: .utf8) else {
      preconditionFailure("A scalar-aligned suffix of a Swift String must be valid UTF-8")
    }
    lines = bounded.components(separatedBy: "\n")
  }

  func page(before offset: Int) throws -> (start: Int, lines: [String]) {
    guard (0...lines.count).contains(offset) else { throw MirrorProtocolError.invalidMessage }
    let start = max(0, offset - Self.pageSize)
    return (start, Array(lines[start..<offset]))
  }
}
