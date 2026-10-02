import Foundation

public struct TabCommandPayload: Codable, Sendable, Equatable {
  public let action: TabAction
  public let target: TabTarget

  public init(action: TabAction, target: TabTarget) {
    self.action = action
    self.target = target
  }
}

nonisolated public struct TabTarget: Codable, Sendable, Equatable {
  public let worktree: TabTargetWorktree
  public let tab: TabTargetTab
  public let pane: TabTargetPane

  public init(worktree: TabTargetWorktree, tab: TabTargetTab, pane: TabTargetPane) {
    self.worktree = worktree
    self.tab = tab
    self.pane = pane
  }
}

nonisolated public struct TabTargetWorktree: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let path: String
  public let rootPath: String
  public let kind: String

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case path
    case rootPath = "root_path"
    case kind
  }

  public init(id: String, name: String, path: String, rootPath: String, kind: String) {
    self.id = id
    self.name = name
    self.path = path
    self.rootPath = rootPath
    self.kind = kind
  }
}

nonisolated public struct TabTargetTab: Codable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let selected: Bool

  public init(id: String, title: String, selected: Bool) {
    self.id = id
    self.title = title
    self.selected = selected
  }
}

nonisolated public struct TabTargetPane: Codable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let cwd: String?
  public let focused: Bool

  public init(id: String, title: String, cwd: String?, focused: Bool) {
    self.id = id
    self.title = title
    self.cwd = cwd
    self.focused = focused
  }
}
