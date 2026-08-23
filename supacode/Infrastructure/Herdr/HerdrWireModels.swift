import Foundation

nonisolated internal enum HerdrProcessDetector {
  internal static func isHerdr(_ job: ForegroundJob?) -> Bool {
    guard let job else { return false }
    return job.processes.contains { process in
      [process.argv0, process.name]
        .compactMap { $0.flatMap(ProcessDetection.basename)?.lowercased() }
        .contains("herdr")
    }
  }
}

nonisolated internal enum HerdrSocketPathResolver {
  internal static func defaultPath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> String {
    let configurationDirectory: URL
    if let xdgPath = environment["XDG_CONFIG_HOME"], !xdgPath.isEmpty {
      configurationDirectory = URL(filePath: xdgPath, directoryHint: .isDirectory)
    } else {
      configurationDirectory = homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
    }
    return
      configurationDirectory
      .appending(path: "herdr", directoryHint: .isDirectory)
      .appending(path: "herdr.sock", directoryHint: .notDirectory)
      .path(percentEncoded: false)
  }
}

nonisolated internal struct HerdrPaneInfo: Decodable, Equatable, Sendable {
  internal let paneID: String
  internal let agent: String?
  internal let agentStatus: String?

  internal var inputContext: TerminalInputContext {
    agent == nil ? .commandLike : .chatAgent
  }

  nonisolated private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case agent
    case agentStatus = "agent_status"
  }
}

nonisolated internal struct HerdrResponseEnvelope: Decodable, Sendable {
  nonisolated internal struct Result: Decodable, Sendable {
    internal let type: String
    internal let pane: HerdrPaneInfo?
    internal let protocolVersion: UInt32?
    internal let snapshot: HerdrSessionSnapshot?

    nonisolated private enum CodingKeys: String, CodingKey {
      case type
      case pane
      case protocolVersion = "protocol"
      case snapshot
    }
  }

  nonisolated internal struct ErrorBody: Decodable, Sendable {
    internal let code: String
    internal let message: String
  }

  internal let id: String?
  internal let result: Result?
  internal let error: ErrorBody?

  internal var currentPane: HerdrPaneInfo? {
    guard result?.type == "pane_current" else { return nil }
    return result?.pane
  }
}

nonisolated internal enum HerdrProtocolCompatibility {
  internal static let supportedVersions: ClosedRange<UInt32> = 19...20

  internal static func validate(_ response: HerdrResponseEnvelope) throws {
    guard response.result?.type == "pong" else {
      throw HerdrSocketError.unsupportedResponseType(response.result?.type)
    }
    let actualVersion = response.result?.protocolVersion
    guard let actualVersion, supportedVersions.contains(actualVersion) else {
      throw HerdrSocketError.unsupportedProtocol(
        supported: supportedVersions,
        actual: actualVersion
      )
    }
  }
}

nonisolated internal struct HerdrEventEnvelope: Decodable, Sendable {
  internal let event: String
}

nonisolated internal struct HerdrRequest<Params: Encodable>: Encodable {
  internal let id: String
  internal let method: String
  internal let params: Params
}

nonisolated internal struct HerdrEmptyParams: Encodable, Sendable {}

nonisolated internal struct HerdrEventsSubscribeParams: Encodable, Sendable {
  nonisolated internal struct Subscription: Encodable, Sendable {
    internal let type: String
    internal let paneID: String?

    internal init(type: String, paneID: String? = nil) {
      self.type = type
      self.paneID = paneID
    }

    private enum CodingKeys: String, CodingKey {
      case type
      case paneID = "pane_id"
    }

    internal func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(type, forKey: .type)
      try container.encodeIfPresent(paneID, forKey: .paneID)
    }
  }

  internal let subscriptions: [Subscription]
}

nonisolated internal struct HerdrSessionSnapshot: Decodable, Equatable, Sendable {
  internal let version: String?
  internal let protocolVersion: UInt32?
  internal let focusedWorkspaceID: String?
  internal let focusedTabID: String?
  internal let focusedPaneID: String?
  internal let workspaces: [HerdrWorkspace]
  internal let tabs: [HerdrTab]
  internal let panes: [HerdrPane]
  internal let layouts: [HerdrLayout]
  internal let agents: [HerdrAgent]

  internal static let empty = Self(
    version: nil,
    protocolVersion: nil,
    focusedWorkspaceID: nil,
    focusedTabID: nil,
    focusedPaneID: nil,
    workspaces: [],
    tabs: [],
    panes: [],
    layouts: [],
    agents: []
  )

  internal init(
    version: String?,
    protocolVersion: UInt32?,
    focusedWorkspaceID: String?,
    focusedTabID: String?,
    focusedPaneID: String?,
    workspaces: [HerdrWorkspace],
    tabs: [HerdrTab],
    panes: [HerdrPane],
    layouts: [HerdrLayout],
    agents: [HerdrAgent]
  ) {
    self.version = version
    self.protocolVersion = protocolVersion
    self.focusedWorkspaceID = focusedWorkspaceID
    self.focusedTabID = focusedTabID
    self.focusedPaneID = focusedPaneID
    self.workspaces = workspaces
    self.tabs = tabs
    self.panes = panes
    self.layouts = layouts
    self.agents = agents
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case protocolVersion = "protocol"
    case focusedWorkspaceID = "focused_workspace_id"
    case focusedTabID = "focused_tab_id"
    case focusedPaneID = "focused_pane_id"
    case workspaces
    case tabs
    case panes
    case layouts
    case agents
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decodeIfPresent(String.self, forKey: .version),
      protocolVersion: try container.decodeIfPresent(UInt32.self, forKey: .protocolVersion),
      focusedWorkspaceID: try container.decodeIfPresent(String.self, forKey: .focusedWorkspaceID),
      focusedTabID: try container.decodeIfPresent(String.self, forKey: .focusedTabID),
      focusedPaneID: try container.decodeIfPresent(String.self, forKey: .focusedPaneID),
      workspaces: try container.decodeIfPresent([HerdrWorkspace].self, forKey: .workspaces) ?? [],
      tabs: try container.decodeIfPresent([HerdrTab].self, forKey: .tabs) ?? [],
      panes: try container.decodeIfPresent([HerdrPane].self, forKey: .panes) ?? [],
      layouts: try container.decodeIfPresent([HerdrLayout].self, forKey: .layouts) ?? [],
      agents: try container.decodeIfPresent([HerdrAgent].self, forKey: .agents) ?? []
    )
  }
}

nonisolated internal struct HerdrWorkspace: Decodable, Equatable, Sendable, Identifiable {
  internal let workspaceID: String
  internal let number: Int?
  internal let label: String
  internal let focused: Bool
  internal let paneCount: Int?
  internal let tabCount: Int?
  internal let activeTabID: String?
  internal let agentStatus: String?

  internal var id: String { workspaceID }

  internal init(
    workspaceID: String,
    number: Int? = nil,
    label: String? = nil,
    focused: Bool = false,
    paneCount: Int? = nil,
    tabCount: Int? = nil,
    activeTabID: String? = nil,
    agentStatus: String? = nil
  ) {
    self.workspaceID = workspaceID
    self.number = number
    self.label = label ?? workspaceID
    self.focused = focused
    self.paneCount = paneCount
    self.tabCount = tabCount
    self.activeTabID = activeTabID
    self.agentStatus = agentStatus
  }

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case number
    case label
    case focused
    case paneCount = "pane_count"
    case tabCount = "tab_count"
    case activeTabID = "active_tab_id"
    case agentStatus = "agent_status"
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workspaceID = try container.decode(String.self, forKey: .workspaceID)
    number = try container.decodeIfPresent(Int.self, forKey: .number)
    label = try container.decodeIfPresent(String.self, forKey: .label) ?? workspaceID
    focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
    paneCount = try container.decodeIfPresent(Int.self, forKey: .paneCount)
    tabCount = try container.decodeIfPresent(Int.self, forKey: .tabCount)
    activeTabID = try container.decodeIfPresent(String.self, forKey: .activeTabID)
    agentStatus = try container.decodeIfPresent(String.self, forKey: .agentStatus)
  }
}

nonisolated internal struct HerdrTab: Decodable, Equatable, Sendable, Identifiable {
  internal let tabID: String
  internal let workspaceID: String
  internal let number: Int?
  internal let label: String
  internal let focused: Bool
  internal let paneCount: Int?
  internal let agentStatus: String?

  internal var id: String { tabID }

  internal init(
    tabID: String,
    workspaceID: String,
    number: Int? = nil,
    label: String? = nil,
    focused: Bool = false,
    paneCount: Int? = nil,
    agentStatus: String? = nil
  ) {
    self.tabID = tabID
    self.workspaceID = workspaceID
    self.number = number
    self.label = label ?? tabID
    self.focused = focused
    self.paneCount = paneCount
    self.agentStatus = agentStatus
  }

  private enum CodingKeys: String, CodingKey {
    case tabID = "tab_id"
    case workspaceID = "workspace_id"
    case number
    case label
    case focused
    case paneCount = "pane_count"
    case agentStatus = "agent_status"
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tabID = try container.decode(String.self, forKey: .tabID)
    workspaceID = try container.decode(String.self, forKey: .workspaceID)
    number = try container.decodeIfPresent(Int.self, forKey: .number)
    label = try container.decodeIfPresent(String.self, forKey: .label) ?? tabID
    focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
    paneCount = try container.decodeIfPresent(Int.self, forKey: .paneCount)
    agentStatus = try container.decodeIfPresent(String.self, forKey: .agentStatus)
  }
}

nonisolated internal struct HerdrPane: Decodable, Equatable, Sendable, Identifiable {
  internal let paneID: String
  internal let terminalID: String?
  internal let workspaceID: String
  internal let tabID: String
  internal let focused: Bool
  internal let cwd: String?
  internal let foregroundCWD: String?
  internal let label: String?
  internal let agent: String?
  internal let title: String?
  internal let terminalTitle: String?
  internal let terminalTitleStripped: String?
  internal let displayAgent: String?
  internal let agentStatus: String?
  internal let tokens: [String: String]
  internal let revision: UInt64?

  internal var id: String { paneID }
  internal var isAgent: Bool { agent != nil }

  internal init(
    paneID: String,
    terminalID: String? = nil,
    workspaceID: String,
    tabID: String,
    focused: Bool = false,
    cwd: String? = nil,
    foregroundCWD: String? = nil,
    label: String? = nil,
    agent: String? = nil,
    title: String? = nil,
    terminalTitle: String? = nil,
    terminalTitleStripped: String? = nil,
    displayAgent: String? = nil,
    agentStatus: String? = nil,
    tokens: [String: String] = [:],
    revision: UInt64? = nil
  ) {
    self.paneID = paneID
    self.terminalID = terminalID
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.focused = focused
    self.cwd = cwd
    self.foregroundCWD = foregroundCWD
    self.label = label
    self.agent = agent
    self.title = title
    self.terminalTitle = terminalTitle
    self.terminalTitleStripped = terminalTitleStripped
    self.displayAgent = displayAgent
    self.agentStatus = agentStatus
    self.tokens = tokens
    self.revision = revision
  }

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case terminalID = "terminal_id"
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case focused
    case cwd
    case foregroundCWD = "foreground_cwd"
    case label
    case agent
    case title
    case terminalTitle = "terminal_title"
    case terminalTitleStripped = "terminal_title_stripped"
    case displayAgent = "display_agent"
    case agentStatus = "agent_status"
    case tokens
    case revision
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    paneID = try container.decode(String.self, forKey: .paneID)
    terminalID = try container.decodeIfPresent(String.self, forKey: .terminalID)
    workspaceID = try container.decode(String.self, forKey: .workspaceID)
    tabID = try container.decode(String.self, forKey: .tabID)
    focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
    cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    foregroundCWD = try container.decodeIfPresent(String.self, forKey: .foregroundCWD)
    label = try container.decodeIfPresent(String.self, forKey: .label)
    agent = try container.decodeIfPresent(String.self, forKey: .agent)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
    terminalTitleStripped = try container.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
    displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
    agentStatus = try container.decodeIfPresent(String.self, forKey: .agentStatus)
    tokens = try container.decodeIfPresent([String: String].self, forKey: .tokens) ?? [:]
    revision = try container.decodeIfPresent(UInt64.self, forKey: .revision)
  }
}

nonisolated internal struct HerdrAgent: Decodable, Equatable, Sendable, Identifiable {
  internal let paneID: String?
  internal let workspaceID: String?
  internal let tabID: String?
  internal let name: String?
  internal let agent: String?
  internal let title: String?
  internal let displayAgent: String?
  internal let agentStatus: String?
  internal let focused: Bool

  internal var id: String { paneID ?? name ?? agent ?? "agent" }

  internal init(
    paneID: String? = nil,
    workspaceID: String? = nil,
    tabID: String? = nil,
    name: String? = nil,
    agent: String? = nil,
    title: String? = nil,
    displayAgent: String? = nil,
    agentStatus: String? = nil,
    focused: Bool = false
  ) {
    self.paneID = paneID
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.name = name
    self.agent = agent
    self.title = title
    self.displayAgent = displayAgent
    self.agentStatus = agentStatus
    self.focused = focused
  }

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case name
    case agent
    case title
    case displayAgent = "display_agent"
    case agentStatus = "agent_status"
    case focused
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    paneID = try container.decodeIfPresent(String.self, forKey: .paneID)
    workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
    tabID = try container.decodeIfPresent(String.self, forKey: .tabID)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    agent = try container.decodeIfPresent(String.self, forKey: .agent)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
    agentStatus = try container.decodeIfPresent(String.self, forKey: .agentStatus)
    focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
  }
}

nonisolated internal struct HerdrLayout: Decodable, Equatable, Sendable {
  internal let workspaceID: String
  internal let tabID: String
  internal let zoomed: Bool
  internal let focusedPaneID: String?
  internal let panes: [HerdrLayoutPane]
  internal let splits: [HerdrLayoutSplit]

  internal init(
    workspaceID: String,
    tabID: String,
    zoomed: Bool = false,
    focusedPaneID: String? = nil,
    panes: [HerdrLayoutPane] = [],
    splits: [HerdrLayoutSplit] = []
  ) {
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.zoomed = zoomed
    self.focusedPaneID = focusedPaneID
    self.panes = panes
    self.splits = splits
  }

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case zoomed
    case focusedPaneID = "focused_pane_id"
    case panes
    case splits
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workspaceID = try container.decode(String.self, forKey: .workspaceID)
    tabID = try container.decode(String.self, forKey: .tabID)
    zoomed = try container.decodeIfPresent(Bool.self, forKey: .zoomed) ?? false
    focusedPaneID = try container.decodeIfPresent(String.self, forKey: .focusedPaneID)
    panes = try container.decodeIfPresent([HerdrLayoutPane].self, forKey: .panes) ?? []
    splits = try container.decodeIfPresent([HerdrLayoutSplit].self, forKey: .splits) ?? []
  }
}

nonisolated internal struct HerdrLayoutPane: Decodable, Equatable, Sendable {
  internal let paneID: String
  internal let focused: Bool
  internal let rect: HerdrLayoutRect?

  internal init(paneID: String, focused: Bool = false, rect: HerdrLayoutRect? = nil) {
    self.paneID = paneID
    self.focused = focused
    self.rect = rect
  }

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case focused
    case rect
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    paneID = try container.decode(String.self, forKey: .paneID)
    focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
    rect = try container.decodeIfPresent(HerdrLayoutRect.self, forKey: .rect)
  }
}

nonisolated internal struct HerdrLayoutSplit: Decodable, Equatable, Sendable {
  internal let id: String?
  internal let direction: String?
  internal let ratio: Double?
  internal let rect: HerdrLayoutRect?

  internal init(
    id: String? = nil,
    direction: String? = nil,
    ratio: Double? = nil,
    rect: HerdrLayoutRect? = nil
  ) {
    self.id = id
    self.direction = direction
    self.ratio = ratio
    self.rect = rect
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case direction
    case ratio
    case rect
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    direction = try container.decodeIfPresent(String.self, forKey: .direction)
    ratio = try container.decodeIfPresent(Double.self, forKey: .ratio)
    rect = try container.decodeIfPresent(HerdrLayoutRect.self, forKey: .rect)
  }
}

nonisolated internal struct HerdrLayoutRect: Decodable, Equatable, Sendable {
  internal let x: Int?
  internal let y: Int?
  internal let width: Int?
  internal let height: Int?

  internal init(x: Int?, y: Int?, width: Int?, height: Int?) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

nonisolated internal struct HerdrSnapshotResponse: Decodable, Sendable {
  internal let type: String
  internal let snapshot: HerdrSessionSnapshot

  private struct Result: Decodable {
    fileprivate let type: String
    fileprivate let snapshot: HerdrSessionSnapshot
  }

  private struct Root: Decodable {
    fileprivate let result: Result?
    fileprivate let type: String?
    fileprivate let snapshot: HerdrSessionSnapshot?
  }

  internal init(from decoder: Decoder) throws {
    let root = try Root(from: decoder)
    if let result = root.result {
      guard result.type == "session_snapshot" else {
        throw HerdrSocketError.unsupportedResponseType(result.type)
      }
      type = result.type
      snapshot = result.snapshot
    } else if let type = root.type, let snapshot = root.snapshot {
      guard type == "session_snapshot" else {
        throw HerdrSocketError.unsupportedResponseType(type)
      }
      self.type = type
      self.snapshot = snapshot
    } else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Missing session snapshot response")
      )
    }
  }
}

nonisolated internal struct HerdrWorkspaceFocusParams: Encodable, Sendable {
  internal let workspaceID: String

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
  }
}

nonisolated internal struct HerdrTabFocusParams: Encodable, Sendable {
  internal let tabID: String

  private enum CodingKeys: String, CodingKey {
    case tabID = "tab_id"
  }
}

nonisolated internal struct HerdrPaneFocusParams: Encodable, Sendable {
  internal let paneID: String

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
  }
}
