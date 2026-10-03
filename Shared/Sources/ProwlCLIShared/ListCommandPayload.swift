import Foundation

public struct ListCommandPayload: Codable, Equatable {
  public let count: Int
  public let items: [ListCommandItem]
  /// The pane the server resolved for the calling process; absent outside a pane.
  public let caller: ListCommandCaller?

  public init(count: Int, items: [ListCommandItem], caller: ListCommandCaller? = nil) {
    self.count = count
    self.items = items
    self.caller = caller
  }
}

/// Server-resolved identity of the `prowl` caller. Unlike an inherited `PROWL_PANE_ID`, it
/// stays correct for commands that Codex's shared daemon runs (docs-ai 073).
public struct ListCommandCaller: Codable, Equatable {
  public struct Reference: Codable, Equatable {
    public let id: String

    public init(id: String) {
      self.id = id
    }
  }

  public let pane: Reference
  public let worktree: Reference

  public init(paneID: String, worktreeID: String) {
    self.pane = Reference(id: paneID)
    self.worktree = Reference(id: worktreeID)
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
  public let handle: Int?
  public let title: String
  public let selected: Bool

  public init(id: String, handle: Int? = nil, title: String, selected: Bool) {
    self.id = id
    self.handle = handle
    self.title = title
    self.selected = selected
  }
}

public struct ListCommandPane: Codable, Equatable {
  public let id: String
  public let handle: Int?
  public let title: String
  public let cwd: String?
  public let focused: Bool
  /// Whether the surface occupies a visible part of an on-screen window. The app always
  /// sends it; `nil` means the response came from an app that predates the field.
  public let visible: Bool?
  /// The coding agent detected in this pane (e.g. "claude", "codex"), or nil if none.
  /// Stable machine token (`DetectedAgent.rawValue`); useful for handoff orchestration.
  public let agent: String?

  public init(
    id: String,
    handle: Int? = nil,
    title: String,
    cwd: String?,
    focused: Bool,
    visible: Bool?,
    agent: String? = nil
  ) {
    self.id = id
    self.handle = handle
    self.title = title
    self.cwd = cwd
    self.focused = focused
    self.visible = visible
    self.agent = agent
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
