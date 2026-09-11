import Foundation

nonisolated struct MirrorPaneDescriptor: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let title: String
  let directory: String
  let busy: Bool
  var projectName: String?
  var subtitle: String?
  var role: String?
}

nonisolated struct MirrorFrame: Codable, Equatable, Sendable {
  let columns: UInt32
  let rows: UInt32
  let bytes: Data
}

nonisolated enum MirrorMessage: Codable, Sendable {
  enum Representation: String, Codable, Sendable {
    case terminal = "vt-v1"
    case text = "text-v1"
  }
  enum Intent: String, Codable, Sendable {
    case takeover, ifFree
  }
  enum EndReason: String, Codable, Sendable {
    case takenOver, hostStopped, paneClosed
  }
  case challenge(Challenge)
  case authenticate(Authentication)
  case pair(PairRequest)
  case paired(MirrorDeviceCredential)
  case authenticated(UUID)
  struct Challenge: Codable, Sendable {
    let hostID: UUID
    let nonce: Data
  }
  struct Authentication: Codable, Sendable {
    let deviceID: UUID
    let proof: Data
  }
  struct PairRequest: Codable, Sendable {
    let name: String
    let proof: Data
  }
  enum Kind: String, Codable {
    case challenge, authenticate, pair, paired, authenticated, list, panes, subscribe, subscribed,
      frame, textFrame, acknowledge, input, history, historyPage, failure, ping, pong, ended,
      refresh, command, commandResult, commandReceipt
  }
  case list
  case panes(PanesPayload)
  struct PanesPayload: Codable, Sendable {
    var panes: [MirrorPaneDescriptor]
    var capabilities: [String]
    var hostRunID: UUID
  }
  case subscribe(SubscribePayload)
  struct SubscribePayload: Codable, Sendable {
    var paneID: UUID
    var representation: Representation
    var intent: Intent
  }
  case subscribed(SubscribedPayload)
  struct SubscribedPayload: Codable, Sendable {
    var paneID: UUID
    var subscriptionID: UUID
    var hostRunID: UUID
  }
  case frame(FramePayload)
  struct FramePayload: Codable, Sendable {
    var frame: MirrorFrame
    var sequence: UInt64
    var subscriptionID: UUID
  }
  case textFrame(TextFramePayload)
  struct TextFramePayload: Codable, Sendable {
    var columns: UInt32 = 0
    var rows: UInt32 = 0
    var truncated: Bool = false
    var sequence: UInt64
    var text: String
    var subscriptionID: UUID
  }
  case acknowledge(AcknowledgePayload)
  struct AcknowledgePayload: Codable, Sendable {
    var sequence: UInt64
    var subscriptionID: UUID
  }
  case input(InputPayload)
  struct InputPayload: Codable, Sendable {
    var bytes: Data
    var subscriptionID: UUID
  }
  case history(HistoryPayload)
  struct HistoryPayload: Codable, Sendable {
    var historyID: UUID?
    var offset: Int?
    var subscriptionID: UUID
  }
  case historyPage(HistoryPagePayload)
  struct HistoryPagePayload: Codable, Sendable {
    var historyID: UUID
    var offset: Int
    var lines: [String]
    var total: Int
    var subscriptionID: UUID
    var capturedAt: TimeInterval
    var truncated: Bool
  }
  case failure(FailurePayload)
  struct FailurePayload: Codable, Sendable {
    var error: String
    var subscriptionID: UUID?
  }
  case ping
  case pong
  case ended(EndedPayload)
  struct EndedPayload: Codable, Sendable {
    var reason: EndReason
  }
  case refresh(RefreshPayload)
  struct RefreshPayload: Codable, Sendable {
    var subscriptionID: UUID
  }
  case command(CommandPayload)
  struct CommandPayload: Codable, Sendable {
    var subscriptionID: UUID?
    var commandRequest: MirrorCommandRequest
  }
  case commandResult(CommandResultPayload)
  struct CommandResultPayload: Codable, Sendable {
    var commandResponse: MirrorCommandResponse
  }
  case commandReceipt(CommandReceiptPayload)
  struct CommandReceiptPayload: Codable, Sendable {
    var subscriptionID: UUID
    var commandReceiptID: UUID
  }
  var kind: Kind {
    switch self {
    case .challenge: .challenge
    case .authenticate: .authenticate
    case .pair: .pair
    case .paired: .paired
    case .authenticated: .authenticated
    case .list: .list
    case .panes: .panes
    case .subscribe: .subscribe
    case .subscribed: .subscribed
    case .frame: .frame
    case .textFrame: .textFrame
    case .acknowledge: .acknowledge
    case .input: .input
    case .history: .history
    case .historyPage: .historyPage
    case .failure: .failure
    case .ping: .ping
    case .pong: .pong
    case .ended: .ended
    case .refresh: .refresh
    case .command: .command
    case .commandResult: .commandResult
    case .commandReceipt: .commandReceipt
    }
  }
  var panes: [MirrorPaneDescriptor]? {
    switch self {
    case .panes(let payload): payload.panes
    default: nil
    }
  }
  var capabilities: [String]? {
    switch self {
    case .panes(let payload): payload.capabilities
    default: nil
    }
  }
  var hostRunID: UUID? {
    switch self {
    case .panes(let payload): payload.hostRunID
    case .subscribed(let payload): payload.hostRunID
    default: nil
    }
  }
  var paneID: UUID? {
    switch self {
    case .subscribe(let payload): payload.paneID
    case .subscribed(let payload): payload.paneID
    default: nil
    }
  }
  var representation: Representation? {
    switch self {
    case .subscribe(let payload): payload.representation
    default: nil
    }
  }
  var intent: Intent? {
    switch self {
    case .subscribe(let payload): payload.intent
    default: nil
    }
  }
  var subscriptionID: UUID? {
    switch self {
    case .subscribed(let payload): payload.subscriptionID
    case .frame(let payload): payload.subscriptionID
    case .textFrame(let payload): payload.subscriptionID
    case .acknowledge(let payload): payload.subscriptionID
    case .input(let payload): payload.subscriptionID
    case .history(let payload): payload.subscriptionID
    case .historyPage(let payload): payload.subscriptionID
    case .failure(let payload): payload.subscriptionID
    case .refresh(let payload): payload.subscriptionID
    case .command(let payload): payload.subscriptionID
    case .commandReceipt(let payload): payload.subscriptionID
    default: nil
    }
  }
  var frame: MirrorFrame? {
    switch self {
    case .frame(let payload): payload.frame
    default: nil
    }
  }
  var sequence: UInt64? {
    switch self {
    case .frame(let payload): payload.sequence
    case .textFrame(let payload): payload.sequence
    case .acknowledge(let payload): payload.sequence
    default: nil
    }
  }
  var text: String? {
    switch self {
    case .textFrame(let payload): payload.text
    default: nil
    }
  }
  var bytes: Data? {
    switch self {
    case .input(let payload): payload.bytes
    default: nil
    }
  }
  var historyID: UUID? {
    switch self {
    case .history(let payload): payload.historyID
    case .historyPage(let payload): payload.historyID
    default: nil
    }
  }
  var offset: Int? {
    switch self {
    case .history(let payload): payload.offset
    case .historyPage(let payload): payload.offset
    default: nil
    }
  }
  var lines: [String]? {
    switch self {
    case .historyPage(let payload): payload.lines
    default: nil
    }
  }
  var total: Int? {
    switch self {
    case .historyPage(let payload): payload.total
    default: nil
    }
  }
  var capturedAt: TimeInterval? {
    switch self {
    case .historyPage(let payload): payload.capturedAt
    default: nil
    }
  }
  var truncated: Bool? {
    switch self {
    case .historyPage(let payload): payload.truncated
    default: nil
    }
  }
  var error: String? {
    switch self {
    case .failure(let payload): payload.error
    default: nil
    }
  }
  var reason: EndReason? {
    switch self {
    case .ended(let payload): payload.reason
    default: nil
    }
  }
  var commandRequest: MirrorCommandRequest? {
    switch self {
    case .command(let payload): payload.commandRequest
    default: nil
    }
  }
  var commandResponse: MirrorCommandResponse? {
    switch self {
    case .commandResult(let payload): payload.commandResponse
    default: nil
    }
  }
  var commandReceiptID: UUID? {
    switch self {
    case .commandReceipt(let payload): payload.commandReceiptID
    default: nil
    }
  }
}

nonisolated enum MirrorProtocolError: Error, LocalizedError {
  case invalidMessage, messageTooLarge, invalidPairingKey
  var errorDescription: String? {
    switch self {
    case .invalidMessage: "Invalid remote mirror message."
    case .messageTooLarge: "Remote mirror message exceeds the size limit."
    case .invalidPairingKey: "Enter the current 8-character pairing code shown on Host."
    }
  }
}

nonisolated enum MirrorWire {
  static let maximumPayload = 8 * 1024 * 1024
  static let maximumInput = 64 * 1024

  static func encode(_ message: MirrorMessage) throws -> Data {
    let payload: Data
    switch message {
    case .frame(let value):
      guard value.sequence > 0, (1...1000).contains(value.frame.columns),
        (1...1000).contains(value.frame.rows)
      else { throw MirrorProtocolError.invalidMessage }
      var bytes = Data([1])
      bytes.append(uuidBytes(value.subscriptionID))
      append(value.sequence, to: &bytes)
      append(value.frame.columns, to: &bytes)
      append(value.frame.rows, to: &bytes)
      bytes.append(value.frame.bytes)
      payload = bytes
    case .textFrame(let value):
      guard value.sequence > 0, value.columns <= 1000, value.rows <= 1000 else {
        throw MirrorProtocolError.invalidMessage
      }
      var bytes = Data([2])
      bytes.append(uuidBytes(value.subscriptionID))
      append(value.sequence, to: &bytes)
      append(value.columns, to: &bytes)
      append(value.rows, to: &bytes)
      bytes.append(value.truncated ? 1 : 0)
      bytes.append(Data(value.text.utf8))
      payload = bytes
    default:
      payload = Data([0]) + (try JSONEncoder().encode(message))
    }
    return try frame(payload)
  }

  private static func uuidBytes(_ id: UUID) -> Data {
    var value = id.uuid
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }

  static func frame(_ payload: Data) throws -> Data {
    guard !payload.isEmpty, payload.count <= maximumPayload else {
      throw MirrorProtocolError.messageTooLarge
    }
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
    guard let kind = data.first else { throw MirrorProtocolError.invalidMessage }
    if kind == 0 {
      let message = try JSONDecoder().decode(MirrorMessage.self, from: data.dropFirst())
      guard message.kind != .frame, message.kind != .textFrame else {
        throw MirrorProtocolError.invalidMessage
      }
      return message
    }
    guard kind == 1 || kind == 2, data.count >= (kind == 1 ? 33 : 34) else {
      throw MirrorProtocolError.invalidMessage
    }
    let raw = Array(data)
    let id = UUID(
      uuid: (
        raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8],
        raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15], raw[16]
      ))
    let sequence = raw[17..<25].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    guard sequence > 0 else { throw MirrorProtocolError.invalidMessage }
    if kind == 2 {
      let columns = raw[25..<29].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      let rows = raw[29..<33].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard columns <= 1000, rows <= 1000, raw[33] <= 1,
        let text = String(bytes: raw.dropFirst(34), encoding: .utf8)
      else { throw MirrorProtocolError.invalidMessage }
      return .textFrame(
        .init(
          columns: columns, rows: rows, truncated: raw[33] == 1,
          sequence: sequence, text: text, subscriptionID: id))
    }
    let columns = raw[25..<29].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let rows = raw[29..<33].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard (1...1000).contains(columns), (1...1000).contains(rows) else {
      throw MirrorProtocolError.invalidMessage
    }
    return .frame(
      .init(
        frame: .init(columns: columns, rows: rows, bytes: Data(raw.dropFirst(33))),
        sequence: sequence, subscriptionID: id))
  }

}

/// Empty text is a replacement frame, distinct from a subscription with no baseline.
nonisolated struct MirrorTextFrameGate {
  private var gate = MirrorFrameGate()
  var outstanding: UInt64? { gate.outstanding }

  mutating func offer(
    _ text: String, columns: UInt32 = 0, rows: UInt32 = 0, truncated: Bool = false
  ) -> UInt64? {
    gate.offer(
      MirrorFrame(columns: columns, rows: rows, bytes: Data([truncated ? 1 : 0]) + Data(text.utf8)))
  }

  mutating func acknowledge(_ sequence: UInt64) throws {
    try gate.acknowledge(sequence)
  }

  mutating func requestRefresh() { gate.requestRefresh() }
}

/// One unacknowledged frame per subscriber bounds memory even on a stalled link.
nonisolated struct MirrorFrameGate {
  private(set) var sequence: UInt64 = 0
  private(set) var outstanding: UInt64?
  private var previous: MirrorFrame?

  mutating func requestRefresh() { previous = nil }

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
nonisolated struct MirrorRetainedText {
  let text: String
  let truncated: Bool
}

nonisolated struct MirrorHistory {
  let id = UUID()
  let lines: [String]
  let capturedAt = Date().timeIntervalSince1970
  let truncated: Bool
  static let pageSize = 200
  static let maximumBytes = 2 * 1024 * 1024

  init(text: String, truncated: Bool = false) {
    self.truncated = truncated || text.utf8.count > Self.maximumBytes
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
