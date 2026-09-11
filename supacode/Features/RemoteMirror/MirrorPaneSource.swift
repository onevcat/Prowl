import Foundation

@MainActor
protocol MirrorPaneSource {
  func panes() -> [MirrorPaneDescriptor]
  func snapshot(_ id: UUID) throws -> MirrorFrame
  func write(_ bytes: Data, to id: UUID) throws
  func retainedText(_ id: UUID) throws -> String
  func activeText(_ id: UUID) throws -> String
  var supportsBoundedHistory: Bool { get }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText
}

extension MirrorPaneSource {
  var supportsBoundedHistory: Bool { false }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText {
    throw MirrorProtocolError.invalidMessage
  }
  func activeText(_ id: UUID) throws -> String { throw MirrorProtocolError.invalidMessage }
}
