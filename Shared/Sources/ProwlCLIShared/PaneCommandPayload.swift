import Foundation

public struct PaneCommandPayload: Codable, Sendable, Equatable {
  public let action: PaneAction
  public let target: TabTarget

  public init(action: PaneAction, target: TabTarget) {
    self.action = action
    self.target = target
  }
}
