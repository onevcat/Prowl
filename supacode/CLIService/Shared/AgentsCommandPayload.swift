import Foundation

public struct AgentsCommandPayload: Codable, Equatable {
  public let count: Int
  public let agents: [AgentsCommandAgent]

  public init(count: Int, agents: [AgentsCommandAgent]) {
    self.count = count
    self.agents = agents
  }
}

public struct AgentsCommandAgent: Codable, Equatable {
  public let id: String
  public let type: String
  public let name: String
  public let status: AgentsCommandStatus
  public let rawState: String
  public let detectionReason: String?
  public let screenReason: String?
  public let lastChangedAt: String
  public let project: AgentsCommandProject
  public let worktree: AgentsCommandWorktree
  public let tab: AgentsCommandTab
  public let pane: AgentsCommandPane
  public let session: AgentsCommandSession?
  public let signals: AgentSignalsPayload?

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case name
    case status
    case rawState = "raw_state"
    case detectionReason = "detection_reason"
    case screenReason = "screen_reason"
    case lastChangedAt = "last_changed_at"
    case project
    case worktree
    case tab
    case pane
    case session
    case signals
  }

  public init(
    id: String,
    type: String,
    name: String,
    status: AgentsCommandStatus,
    rawState: String,
    detectionReason: String? = nil,
    screenReason: String? = nil,
    lastChangedAt: String,
    project: AgentsCommandProject,
    worktree: AgentsCommandWorktree,
    tab: AgentsCommandTab,
    pane: AgentsCommandPane,
    session: AgentsCommandSession? = nil,
    signals: AgentSignalsPayload? = nil
  ) {
    self.id = id
    self.type = type
    self.name = name
    self.status = status
    self.rawState = rawState
    self.detectionReason = detectionReason
    self.screenReason = screenReason
    self.lastChangedAt = lastChangedAt
    self.project = project
    self.worktree = worktree
    self.tab = tab
    self.pane = pane
    self.session = session
    self.signals = signals
  }
}

public struct AgentsCommandSession: Codable, Equatable {
  public let id: String
  public let path: String?
  public let confidence: String
  public let source: String

  public init(id: String, path: String?, confidence: String, source: String) {
    self.id = id
    self.path = path
    self.confidence = confidence
    self.source = source
  }
}

public enum AgentsCommandStatus: String, Codable, Equatable, Sendable {
  case blocked
  case working
  case done
  case idle
}

public struct AgentsCommandProject: Codable, Equatable {
  public let name: String
  public let branch: String
  public let path: String

  public init(name: String, branch: String, path: String) {
    self.name = name
    self.branch = branch
    self.path = path
  }
}

public struct AgentsCommandWorktree: Codable, Equatable {
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

public struct AgentsCommandTab: Codable, Equatable {
  public let id: String
  public let title: String
  public let selected: Bool

  public init(id: String, title: String, selected: Bool) {
    self.id = id
    self.title = title
    self.selected = selected
  }
}

public struct AgentsCommandPane: Codable, Equatable {
  public let id: String
  public let handle: Int?
  public let index: Int
  public let title: String
  public let cwd: String?
  public let focused: Bool

  public init(id: String, handle: Int? = nil, index: Int, title: String, cwd: String?, focused: Bool) {
    self.id = id
    self.handle = handle
    self.index = index
    self.title = title
    self.cwd = cwd
    self.focused = focused
  }
}
