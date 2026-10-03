import Foundation

@MainActor
protocol MirrorPaneSource {
  func panes() -> [MirrorPaneDescriptor]
  var supportsStyledScrollback: Bool { get }
  func snapshot(_ id: UUID, styledScrollback: Bool) throws -> MirrorFrame
  func snapshot(_ id: UUID) throws -> MirrorFrame
  func write(_ bytes: Data, to id: UUID) throws
  func textSnapshot(_ id: UUID) throws -> MirrorTextSnapshot
  func activeText(_ id: UUID) throws -> String
  var supportsViewportText: Bool { get }
  var supportsScrollState: Bool { get }
  var supportsRemoteScroll: Bool { get }
  func scroll(_ direction: MirrorMessage.ScrollDirection, to id: UUID) throws
  var supportsBoundedHistory: Bool { get }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText
}

struct MirrorTextSnapshot {
  let text: String
  var columns: UInt32 = 0
  var rows: UInt32 = 0
  var truncated = false
  var scrollBounds: MirrorScrollBounds?
}

extension MirrorPaneSource {
  var supportsStyledScrollback: Bool { false }
  func snapshot(_ id: UUID, styledScrollback: Bool) throws -> MirrorFrame { try snapshot(id) }
  func textSnapshot(_ id: UUID) throws -> MirrorTextSnapshot { .init(text: try activeText(id)) }
  var supportsViewportText: Bool { false }
  var supportsScrollState: Bool { false }
  var supportsRemoteScroll: Bool { false }
  func scroll(_ direction: MirrorMessage.ScrollDirection, to id: UUID) throws {
    throw MirrorProtocolError.invalidMessage
  }
  var supportsBoundedHistory: Bool { false }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText {
    throw MirrorProtocolError.invalidMessage
  }
  func activeText(_ id: UUID) throws -> String { throw MirrorProtocolError.invalidMessage }
}

// A resize or a viewport move raced a read-only capture. Retry on the next poll.
enum MirrorPaneSourceError: Error {
  case captureChanged
}
