import Foundation

@MainActor
protocol MirrorPaneSource {
  func panes() -> [MirrorPaneDescriptor]
  func snapshot(_ id: UUID) throws -> MirrorFrame
  func write(_ bytes: Data, to id: UUID) throws
  func textSnapshot(_ id: UUID) throws -> MirrorTextSnapshot
  func activeText(_ id: UUID) throws -> String
  var supportsBoundedHistory: Bool { get }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText
}

struct MirrorTextSnapshot {
  let text: String
  var columns: UInt32 = 0
  var rows: UInt32 = 0
  var truncated = false
}

extension MirrorPaneSource {
  func textSnapshot(_ id: UUID) throws -> MirrorTextSnapshot { .init(text: try activeText(id)) }
  var supportsBoundedHistory: Bool { false }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText {
    throw MirrorProtocolError.invalidMessage
  }
  func activeText(_ id: UUID) throws -> String { throw MirrorProtocolError.invalidMessage }
}
