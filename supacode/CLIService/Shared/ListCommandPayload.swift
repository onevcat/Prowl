import Foundation

public struct ListCommandPayload: Codable, Equatable {
  public let count: Int
  public let items: [ListCommandItem]

  public init(count: Int, items: [ListCommandItem]) {
    self.count = count
    self.items = items
  }
}

public struct ListCommandItem: Codable, Equatable {
  public let worktree: ListCommandWorktree
  public let tab: ListCommandTab
  public let pane: ListCommandPane
  public let task: ListCommandTask

  public init(
    worktree: ListCommandWorktree,
    tab: ListCommandTab,
    pane: ListCommandPane,
    task: ListCommandTask
  ) {
    self.worktree = worktree
    self.tab = tab
    self.pane = pane
    self.task = task
  }
}

public struct ListCommandWorktree: Codable, Equatable {
  public enum Kind: String, Codable, Equatable {
    case git
    case plain
    case workspace
  }

  public let id: String
  public let name: String
  public let path: String
  public let rootPath: String
  public let kind: Kind

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case path
    case rootPath = "root_path"
    case kind
  }

  public init(id: String, name: String, path: String, rootPath: String, kind: Kind) {
    self.id = id
    self.name = name
    self.path = path
    self.rootPath = rootPath
    self.kind = kind
  }
}

public struct ListCommandTab: Codable, Equatable {
  public let id: String
  public let title: String
  public let selected: Bool

  public init(id: String, title: String, selected: Bool) {
    self.id = id
    self.title = title
    self.selected = selected
  }
}

public struct ListCommandPane: Codable, Equatable {
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

public struct ListCommandTask: Codable, Equatable {
  public enum Status: String, Codable, Equatable {
    case running
    case idle
  }

  public let status: Status?

  public init(status: Status?) {
    self.status = status
  }
}
