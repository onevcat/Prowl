import Foundation

@MainActor
protocol MirrorPaneSource {
  func panes() -> [MirrorPaneDescriptor]
  func snapshot(_ id: UUID) throws -> MirrorFrame
  func write(_ bytes: Data, to id: UUID) throws
  func retainedText(_ id: UUID) throws -> String
}
