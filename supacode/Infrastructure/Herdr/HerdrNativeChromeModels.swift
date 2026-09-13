import Foundation

nonisolated internal enum HerdrEndpointKey: Hashable, Sendable {
  case local
  case ssh(profileID: String)

  internal var storageKey: String {
    switch self {
    case .local: return "local"
    case .ssh(let profileID): return "ssh:\(profileID)"
    }
  }
}

nonisolated extension HerdrEndpointKey: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case profileID = "profile_id"
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "local":
      self = .local
    case "ssh":
      let profileID = try container.decode(String.self, forKey: .profileID)
      guard profileID.count == 32,
        profileID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .profileID,
          in: container,
          debugDescription: "SSH profile ID must be 32 lowercase hexadecimal characters."
        )
      }
      self = .ssh(profileID: profileID)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unknown endpoint kind."
      )
    }
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .local:
      try container.encode("local", forKey: .kind)
    case .ssh(let profileID):
      try container.encode("ssh", forKey: .kind)
      try container.encode(profileID, forKey: .profileID)
    }
  }
}

nonisolated internal struct HerdrWorkspaceTarget: Codable, Hashable, Sendable {
  internal let endpointKey: HerdrEndpointKey
  internal let workspaceID: String

  private enum CodingKeys: String, CodingKey {
    case endpointKey = "endpoint_key"
    case workspaceID = "workspace_id"
  }
}

nonisolated internal struct HerdrTabTarget: Codable, Hashable, Sendable {
  internal let endpointKey: HerdrEndpointKey
  internal let tabID: String

  private enum CodingKeys: String, CodingKey {
    case endpointKey = "endpoint_key"
    case tabID = "tab_id"
  }
}

nonisolated internal struct HerdrPaneTarget: Codable, Hashable, Sendable {
  internal let endpointKey: HerdrEndpointKey
  internal let paneID: String

  private enum CodingKeys: String, CodingKey {
    case endpointKey = "endpoint_key"
    case paneID = "pane_id"
  }
}

nonisolated internal struct HerdrConnectionIdentity: Codable, Equatable, Hashable, Sendable {
  internal let generation: UInt64
  internal let serverBootID: String

  private enum CodingKeys: String, CodingKey {
    case generation = "connection_generation"
    case serverBootID = "server_boot_id"
  }
}

nonisolated internal enum HerdrConnectionIdentityState: Equatable, Sendable {
  case absent
  case concrete(HerdrConnectionIdentity)
}

nonisolated extension HerdrConnectionIdentityState: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case connectionGeneration = "connection_generation"
    case serverBootID = "server_boot_id"
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "absent":
      self = .absent
    case "concrete":
      self = .concrete(
        HerdrConnectionIdentity(
          generation: try container.decode(UInt64.self, forKey: .connectionGeneration),
          serverBootID: try container.decode(String.self, forKey: .serverBootID)
        )
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unknown connection fence kind."
      )
    }
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .absent:
      try container.encode("absent", forKey: .kind)
    case .concrete(let identity):
      try container.encode("concrete", forKey: .kind)
      try container.encode(identity.generation, forKey: .connectionGeneration)
      try container.encode(identity.serverBootID, forKey: .serverBootID)
    }
  }
}

nonisolated internal enum HerdrEndpointFenceAcceptance: Equatable, Sendable {
  case accepted
  case stale
  case replacedConnection
  case retiredConnection
}

nonisolated internal struct HerdrEndpointWatermarks: Equatable, Sendable {
  private struct Watermark: Equatable, Sendable {
    var currentIdentity: HerdrConnectionIdentity
    var revision: UInt64
    var retiredIdentities: Set<HerdrConnectionIdentity>
  }

  private var values: [HerdrEndpointKey: Watermark] = [:]

  internal mutating func accept(_ fence: HerdrEndpointFence) -> HerdrEndpointFenceAcceptance {
    guard var watermark = values[fence.endpointKey] else {
      values[fence.endpointKey] = Watermark(
        currentIdentity: fence.identity,
        revision: fence.snapshotRevision,
        retiredIdentities: []
      )
      return .accepted
    }
    if watermark.currentIdentity == fence.identity {
      guard fence.snapshotRevision > watermark.revision else { return .stale }
      watermark.revision = fence.snapshotRevision
      values[fence.endpointKey] = watermark
      return .accepted
    }
    guard fence.identity.generation >= watermark.currentIdentity.generation,
      !watermark.retiredIdentities.contains(fence.identity)
    else {
      return .retiredConnection
    }
    watermark.retiredIdentities.insert(watermark.currentIdentity)
    watermark.currentIdentity = fence.identity
    watermark.revision = fence.snapshotRevision
    values[fence.endpointKey] = watermark
    return .replacedConnection
  }
}

nonisolated internal struct HerdrEndpointFence: Codable, Equatable, Hashable, Sendable {
  internal let endpointKey: HerdrEndpointKey
  internal let identity: HerdrConnectionIdentity
  internal let snapshotRevision: UInt64

  private enum CodingKeys: String, CodingKey {
    case kind
    case endpointKey = "endpoint_key"
    case connectionGeneration = "connection_generation"
    case serverBootID = "server_boot_id"
    case snapshotRevision = "snapshot_revision"
  }

  internal init(
    endpointKey: HerdrEndpointKey,
    identity: HerdrConnectionIdentity,
    snapshotRevision: UInt64
  ) {
    self.endpointKey = endpointKey
    self.identity = identity
    self.snapshotRevision = snapshotRevision
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .kind) == "endpoint" else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Expected an endpoint fence."
      )
    }
    endpointKey = try container.decode(HerdrEndpointKey.self, forKey: .endpointKey)
    identity = HerdrConnectionIdentity(
      generation: try container.decode(UInt64.self, forKey: .connectionGeneration),
      serverBootID: try container.decode(String.self, forKey: .serverBootID)
    )
    snapshotRevision = try container.decode(UInt64.self, forKey: .snapshotRevision)
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("endpoint", forKey: .kind)
    try container.encode(endpointKey, forKey: .endpointKey)
    try container.encode(identity.generation, forKey: .connectionGeneration)
    try container.encode(identity.serverBootID, forKey: .serverBootID)
    try container.encode(snapshotRevision, forKey: .snapshotRevision)
  }
}

nonisolated internal enum HerdrProfileAvailability: String, Codable, Sendable {
  case enabled
  case disabled
  case unknown

  internal init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: value) ?? .unknown
  }
}

nonisolated internal enum HerdrEndpointStatus: String, Codable, Sendable {
  case connecting
  case online
  case reconnecting
  case attention
  case disabled
  case unknown

  internal init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: value) ?? .unknown
  }
}

nonisolated internal enum HerdrSnapshotFreshness: String, Codable, Sendable {
  case current
  case stale
  case absent
  case unknown

  internal init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: value) ?? .unknown
  }
}

nonisolated internal struct HerdrFocusSelection: Codable, Equatable, Sendable {
  internal let workspaceID: String?
  internal let tabID: String?
  internal let paneID: String?

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case paneID = "pane_id"
  }
}

nonisolated internal struct HerdrSelection: Codable, Equatable, Sendable {
  internal let workspaceID: String?
  internal let tabID: String?
  internal let paneID: String?

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case paneID = "pane_id"
  }
}

nonisolated internal struct HerdrActivationCapabilities: Codable, Equatable, Sendable {
  internal let canActivate: Bool
  internal let canFocus: Bool
  internal let optionalMethods: Set<String>
  internal let missingRequiredCapability: String?

  private enum CodingKeys: String, CodingKey {
    case canActivate = "can_activate"
    case canFocus = "can_focus"
    case optionalMethods = "optional_methods"
    case missingRequiredCapability = "missing_required_capability"
  }
}

nonisolated internal struct HerdrAttention: Codable, Equatable, Sendable {
  internal let setupCommand: String?
  internal let diagnostic: String

  private enum CodingKeys: String, CodingKey {
    case setupCommand = "setup_command"
    case diagnostic
  }
}

nonisolated internal struct HerdrClientShellWorktree: Codable, Equatable, Sendable {
  internal let key: String
  internal let label: String
  internal let repoRoot: String?
  internal let checkoutPath: String?
  internal let isLinkedWorktree: Bool

  private enum CodingKeys: String, CodingKey {
    case key
    case label
    case repoRoot = "repo_root"
    case checkoutPath = "checkout_path"
    case isLinkedWorktree = "is_linked_worktree"
  }
}

nonisolated internal struct HerdrClientShellWorkspace: Codable, Equatable, Sendable {
  internal let workspaceID: String
  internal let activeTabID: String
  internal let number: Int
  internal let label: String
  internal let customLabel: Bool
  internal let branch: String?
  internal let worktree: HerdrClientShellWorktree?
  internal let focused: Bool
  internal let agentStatus: String

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case activeTabID = "active_tab_id"
    case number
    case label
    case customLabel = "custom_label"
    case branch
    case worktree
    case focused
    case agentStatus = "agent_status"
  }
}

nonisolated internal struct HerdrClientShellTab: Codable, Equatable, Sendable {
  internal let tabID: String
  internal let workspaceID: String
  internal let number: Int
  internal let label: String
  internal let customLabel: Bool
  internal let zoomed: Bool
  internal let focused: Bool
  internal let worktree: HerdrClientShellWorktree?
  internal let hasWorktreeProvenance: Bool
  internal let agentStatus: String

  private enum CodingKeys: String, CodingKey {
    case tabID = "tab_id"
    case workspaceID = "workspace_id"
    case number
    case label
    case customLabel = "custom_label"
    case zoomed
    case focused
    case worktree
    case agentStatus = "agent_status"
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tabID = try container.decode(String.self, forKey: .tabID)
    workspaceID = try container.decode(String.self, forKey: .workspaceID)
    number = try container.decode(Int.self, forKey: .number)
    label = try container.decode(String.self, forKey: .label)
    customLabel = try container.decode(Bool.self, forKey: .customLabel)
    zoomed = try container.decode(Bool.self, forKey: .zoomed)
    focused = try container.decode(Bool.self, forKey: .focused)
    worktree = try container.decodeIfPresent(HerdrClientShellWorktree.self, forKey: .worktree)
    hasWorktreeProvenance = container.contains(.worktree)
    agentStatus = try container.decode(String.self, forKey: .agentStatus)
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(tabID, forKey: .tabID)
    try container.encode(workspaceID, forKey: .workspaceID)
    try container.encode(number, forKey: .number)
    try container.encode(label, forKey: .label)
    try container.encode(customLabel, forKey: .customLabel)
    try container.encode(zoomed, forKey: .zoomed)
    try container.encode(focused, forKey: .focused)
    if hasWorktreeProvenance {
      try container.encode(worktree, forKey: .worktree)
    }
    try container.encode(agentStatus, forKey: .agentStatus)
  }
}

nonisolated internal struct HerdrNativeInputContext: Codable, Equatable, Sendable {
  internal let kind: String
  internal let agent: String?
  internal let shell: String?

  internal var terminalContext: TerminalInputContext {
    switch kind {
    case "chat_agent", "agent": return .chatAgent
    case "command", "command_like", "shell": return .commandLike
    default: return .unknown
    }
  }
}

nonisolated internal struct HerdrClientShellPane: Codable, Equatable, Sendable {
  internal let paneID: String
  internal let workspaceID: String
  internal let tabID: String
  internal let label: String?
  internal let cwd: String?
  internal let foregroundCWD: String?
  internal let focused: Bool
  internal let inputContext: HerdrNativeInputContext

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case label
    case cwd
    case foregroundCWD = "foreground_cwd"
    case focused
    case inputContext = "input_context"
  }
}

nonisolated internal struct HerdrClientShellAgent: Codable, Equatable, Sendable {
  internal let paneID: String
  internal let workspaceID: String
  internal let tabID: String
  internal let name: String?
  internal let displayAgent: String?
  internal let agent: String?
  internal let title: String?
  internal let terminalTitle: String?
  internal let terminalTitleStripped: String?
  internal let agentStatus: String
  internal let focused: Bool

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case name
    case displayAgent = "display_agent"
    case agent
    case title
    case terminalTitle = "terminal_title"
    case terminalTitleStripped = "terminal_title_stripped"
    case agentStatus = "agent_status"
    case focused
  }
}

nonisolated internal struct HerdrClientShellSnapshot: Codable, Equatable, Sendable {
  internal let bootID: String
  internal let revision: UInt64
  internal let focusedWorkspaceID: String?
  internal let focusedTabID: String?
  internal let focusedPaneID: String?
  internal let workspaces: [HerdrClientShellWorkspace]
  internal let tabs: [HerdrClientShellTab]
  internal let panes: [HerdrClientShellPane]
  internal let agents: [HerdrClientShellAgent]

  private enum CodingKeys: String, CodingKey {
    case bootID = "boot_id"
    case revision
    case focusedWorkspaceID = "focused_workspace_id"
    case focusedTabID = "focused_tab_id"
    case focusedPaneID = "focused_pane_id"
    case workspaces
    case tabs
    case panes
    case agents
  }

  internal var legacyProjection: HerdrSessionSnapshot {
    let projectedWorkspaces = workspaces.map { workspace in
      HerdrWorkspace(
        workspaceID: workspace.workspaceID,
        number: workspace.number,
        label: workspace.label,
        focused: workspace.focused,
        activeTabID: workspace.activeTabID,
        agentStatus: workspace.agentStatus,
        branch: workspace.branch,
        worktree: workspace.worktree.map {
          HerdrWorkspaceWorktree(
            repoName: $0.label,
            repoRoot: $0.repoRoot ?? "",
            checkoutPath: $0.checkoutPath ?? "",
            isLinkedWorktree: $0.isLinkedWorktree,
            repoKey: $0.key
          )
        }
      )
    }
    let projectedTabs = tabs.map { tab in
      HerdrTab(
        tabID: tab.tabID,
        workspaceID: tab.workspaceID,
        number: tab.number,
        label: tab.label,
        customName: tab.customLabel ? tab.label : nil,
        focused: tab.focused,
        agentStatus: tab.agentStatus,
        worktree: tab.worktree.map {
          HerdrWorkspaceWorktree(
            repoName: $0.label,
            repoRoot: $0.repoRoot ?? "",
            checkoutPath: $0.checkoutPath ?? "",
            isLinkedWorktree: $0.isLinkedWorktree,
            repoKey: $0.key
          )
        },
        hasWorktreeProvenance: tab.hasWorktreeProvenance
      )
    }
    let projectedPanes = panes.map { pane in
      HerdrPane(
        paneID: pane.paneID,
        workspaceID: pane.workspaceID,
        tabID: pane.tabID,
        focused: pane.focused,
        cwd: pane.cwd,
        foregroundCWD: pane.foregroundCWD,
        label: pane.label
      )
    }
    let projectedAgents = agents.map { agent in
      HerdrAgent(
        paneID: agent.paneID,
        workspaceID: agent.workspaceID,
        tabID: agent.tabID,
        name: agent.name,
        agent: agent.agent,
        title: agent.title,
        displayAgent: agent.displayAgent,
        agentStatus: agent.agentStatus,
        focused: agent.focused
      )
    }
    let layouts = projectedTabs.map { tab in
      let tabPanes = projectedPanes.filter { $0.tabID == tab.id }
      return HerdrLayout(
        workspaceID: tab.workspaceID,
        tabID: tab.id,
        zoomed: tabs.first { $0.tabID == tab.id }?.zoomed ?? false,
        focusedPaneID: tabPanes.first(where: \.focused)?.id,
        panes: tabPanes.map { HerdrLayoutPane(paneID: $0.id, focused: $0.focused) }
      )
    }
    return HerdrSessionSnapshot(
      version: nil,
      protocolVersion: nil,
      focusedWorkspaceID: focusedWorkspaceID,
      focusedTabID: focusedTabID,
      focusedPaneID: focusedPaneID,
      workspaces: projectedWorkspaces,
      tabs: projectedTabs,
      panes: projectedPanes,
      layouts: layouts,
      agents: projectedAgents
    )
  }
}

nonisolated internal struct HerdrEndpointProjection: Codable, Equatable, Identifiable, Sendable {
  internal let endpointKey: HerdrEndpointKey
  internal let label: String
  internal let availability: HerdrProfileAvailability
  internal let status: HerdrEndpointStatus
  internal let freshness: HerdrSnapshotFreshness
  internal let connectionIdentity: HerdrConnectionIdentityState
  internal let snapshot: HerdrClientShellSnapshot?
  internal let focus: HerdrFocusSelection
  internal let activation: HerdrActivationCapabilities
  internal let attention: HerdrAttention?

  internal var id: HerdrEndpointKey { endpointKey }
  internal var isActionable: Bool {
    availability == .enabled && status == .online && freshness == .current
      && activation.canActivate
  }

  private enum CodingKeys: String, CodingKey {
    case endpointKey = "endpoint_key"
    case label
    case availability
    case status
    case freshness
    case connectionIdentity = "connection_identity"
    case snapshot
    case focus
    case activation
    case attention
  }
}

nonisolated internal enum HerdrUnavailablePresentationReason: String, Codable, Sendable {
  case initialSync = "initial_sync"
  case activationFailed = "activation_failed"
  case sourceUnavailable = "source_unavailable"
  case contractDisconnected = "contract_disconnected"
  case unknown
}

nonisolated internal enum HerdrCommittedPresentation: Equatable, Sendable {
  case unavailable(HerdrUnavailablePresentationReason)
  case active(endpointKey: HerdrEndpointKey, selection: HerdrSelection?)
}

nonisolated extension HerdrCommittedPresentation: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case reason
    case endpointKey = "endpoint_key"
    case selection
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "unavailable":
      self = .unavailable(
        try container.decode(HerdrUnavailablePresentationReason.self, forKey: .reason)
      )
    case "active":
      self = .active(
        endpointKey: try container.decode(HerdrEndpointKey.self, forKey: .endpointKey),
        selection: try container.decodeIfPresent(HerdrSelection.self, forKey: .selection)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unknown committed presentation kind."
      )
    }
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .unavailable(let reason):
      try container.encode("unavailable", forKey: .kind)
      try container.encode(reason, forKey: .reason)
    case .active(let endpointKey, let selection):
      try container.encode("active", forKey: .kind)
      try container.encode(endpointKey, forKey: .endpointKey)
      try container.encodeIfPresent(selection, forKey: .selection)
    }
  }
}

nonisolated internal struct HerdrRequestedSelection: Codable, Equatable, Sendable {
  internal let endpointKey: HerdrEndpointKey
  internal let selection: HerdrSelection?

  private enum CodingKeys: String, CodingKey {
    case endpointKey = "endpoint_key"
    case selection
  }
}

nonisolated internal struct HerdrPendingActivation: Codable, Equatable, Sendable {
  internal let epoch: UInt64
  internal let requestID: String
  internal let sourceEndpointKey: HerdrEndpointKey
  internal let targetEndpointKey: HerdrEndpointKey
  internal let phase: String

  private enum CodingKeys: String, CodingKey {
    case epoch
    case requestID = "request_id"
    case sourceEndpointKey = "source_endpoint_key"
    case targetEndpointKey = "target_endpoint_key"
    case phase
  }
}

nonisolated internal struct HerdrNativeChromeCapabilities: Codable, Equatable, Sendable {
  internal let required: Set<String>
  internal let optional: Set<String>
}

nonisolated internal struct HerdrAggregateState: Codable, Equatable, Sendable {
  internal let catalogRevision: UInt64
  internal let endpoints: [HerdrEndpointProjection]
  internal let perEndpointFocus: [HerdrEndpointKey: HerdrFocusSelection]
  internal let committedPresentation: HerdrCommittedPresentation
  internal let requestedSelection: HerdrRequestedSelection?
  internal let pendingActivation: HerdrPendingActivation?
  internal let capabilities: HerdrNativeChromeCapabilities

  internal var committedActiveEndpointKey: HerdrEndpointKey? {
    guard case .active(let endpointKey, _) = committedPresentation else { return nil }
    return endpointKey
  }

  internal var committedActiveSelection: HerdrSelection? {
    guard case .active(_, let selection) = committedPresentation else { return nil }
    return selection
  }

  internal var committedEndpoint: HerdrEndpointProjection? {
    guard let key = committedActiveEndpointKey else { return nil }
    return endpoints.first { $0.endpointKey == key }
  }

  private enum CodingKeys: String, CodingKey {
    case catalogRevision = "catalog_revision"
    case endpoints
    case perEndpointFocus = "per_endpoint_focus"
    case committedPresentation = "committed_presentation"
    case requestedSelection = "requested_selection"
    case pendingActivation = "pending_activation"
    case capabilities
  }

  internal init(
    catalogRevision: UInt64,
    endpoints: [HerdrEndpointProjection],
    perEndpointFocus: [HerdrEndpointKey: HerdrFocusSelection],
    committedPresentation: HerdrCommittedPresentation,
    requestedSelection: HerdrRequestedSelection?,
    pendingActivation: HerdrPendingActivation?,
    capabilities: HerdrNativeChromeCapabilities
  ) {
    self.catalogRevision = catalogRevision
    self.endpoints = endpoints
    self.perEndpointFocus = perEndpointFocus
    self.committedPresentation = committedPresentation
    self.requestedSelection = requestedSelection
    self.pendingActivation = pendingActivation
    self.capabilities = capabilities
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    catalogRevision = try container.decode(UInt64.self, forKey: .catalogRevision)
    var endpointContainer = try container.nestedUnkeyedContainer(forKey: .endpoints)
    var decodedEndpoints: [HerdrEndpointProjection] = []
    while !endpointContainer.isAtEnd {
      let endpointDecoder = try endpointContainer.superDecoder()
      if let endpoint = try? HerdrEndpointProjection(from: endpointDecoder) {
        decodedEndpoints.append(endpoint)
      }
    }
    guard Set(decodedEndpoints.map(\.endpointKey)).count == decodedEndpoints.count else {
      throw DecodingError.dataCorruptedError(
        forKey: .endpoints,
        in: container,
        debugDescription: "Aggregate state contains duplicate endpoint keys."
      )
    }
    endpoints = decodedEndpoints
    let focusRecords = try container.decode(
      [HerdrEndpointFocusRecord].self, forKey: .perEndpointFocus)
    var decodedFocus: [HerdrEndpointKey: HerdrFocusSelection] = [:]
    for record in focusRecords {
      guard decodedFocus.updateValue(record.focus, forKey: record.endpointKey) == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .perEndpointFocus,
          in: container,
          debugDescription: "Aggregate state contains duplicate endpoint focus keys."
        )
      }
    }
    perEndpointFocus = decodedFocus
    committedPresentation = try container.decode(
      HerdrCommittedPresentation.self,
      forKey: .committedPresentation
    )
    requestedSelection = try container.decodeIfPresent(
      HerdrRequestedSelection.self,
      forKey: .requestedSelection
    )
    pendingActivation = try container.decodeIfPresent(
      HerdrPendingActivation.self,
      forKey: .pendingActivation
    )
    capabilities = try container.decode(HerdrNativeChromeCapabilities.self, forKey: .capabilities)
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(catalogRevision, forKey: .catalogRevision)
    try container.encode(endpoints, forKey: .endpoints)
    try container.encode(
      perEndpointFocus.map { HerdrEndpointFocusRecord(endpointKey: $0.key, focus: $0.value) },
      forKey: .perEndpointFocus
    )
    try container.encode(committedPresentation, forKey: .committedPresentation)
    try container.encodeIfPresent(requestedSelection, forKey: .requestedSelection)
    try container.encodeIfPresent(pendingActivation, forKey: .pendingActivation)
    try container.encode(capabilities, forKey: .capabilities)
  }
}

nonisolated private struct HerdrEndpointFocusRecord: Codable {
  let endpointKey: HerdrEndpointKey
  let focus: HerdrFocusSelection

  private enum CodingKeys: String, CodingKey {
    case endpointKey = "endpoint_key"
    case focus
  }
}

nonisolated internal struct HerdrNativeChromeEnvelope<Payload: Codable & Sendable>: Codable,
  Sendable
{
  internal let contractVersion: UInt32
  internal let clientInstanceID: String
  internal let messageKind: String
  internal let eventSequence: UInt64?
  internal let projectionRevision: UInt64?
  internal let requestID: String?
  internal let activationEpoch: UInt64?
  internal let payload: Payload

  internal init(
    contractVersion: UInt32,
    clientInstanceID: String,
    messageKind: String,
    eventSequence: UInt64?,
    projectionRevision: UInt64?,
    requestID: String?,
    activationEpoch: UInt64?,
    payload: Payload
  ) {
    self.contractVersion = contractVersion
    self.clientInstanceID = clientInstanceID
    self.messageKind = messageKind
    self.eventSequence = eventSequence
    self.projectionRevision = projectionRevision
    self.requestID = requestID
    self.activationEpoch = activationEpoch
    self.payload = payload
  }

  internal init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    contractVersion = try container.decode(UInt32.self, forKey: .contractVersion)
    clientInstanceID = try container.decode(String.self, forKey: .clientInstanceID)
    messageKind = try container.decode(String.self, forKey: .messageKind)
    guard container.contains(.eventSequence), container.contains(.projectionRevision),
      container.contains(.requestID), container.contains(.activationEpoch)
    else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath, debugDescription: "Core nullable fields are required.")
      )
    }
    eventSequence = try container.decodeIfPresent(UInt64.self, forKey: .eventSequence)
    projectionRevision = try container.decodeIfPresent(UInt64.self, forKey: .projectionRevision)
    requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    activationEpoch = try container.decodeIfPresent(UInt64.self, forKey: .activationEpoch)
    payload = try container.decode(Payload.self, forKey: .payload)
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(contractVersion, forKey: .contractVersion)
    try container.encode(clientInstanceID, forKey: .clientInstanceID)
    try container.encode(messageKind, forKey: .messageKind)
    if let eventSequence {
      try container.encode(eventSequence, forKey: .eventSequence)
    } else {
      try container.encodeNil(forKey: .eventSequence)
    }
    if let projectionRevision {
      try container.encode(projectionRevision, forKey: .projectionRevision)
    } else {
      try container.encodeNil(forKey: .projectionRevision)
    }
    if let requestID {
      try container.encode(requestID, forKey: .requestID)
    } else {
      try container.encodeNil(forKey: .requestID)
    }
    if let activationEpoch {
      try container.encode(activationEpoch, forKey: .activationEpoch)
    } else {
      try container.encodeNil(forKey: .activationEpoch)
    }
    try container.encode(payload, forKey: .payload)
  }

  private enum CodingKeys: String, CodingKey {
    case contractVersion = "contract_version"
    case clientInstanceID = "client_instance_id"
    case messageKind = "message_kind"
    case eventSequence = "event_sequence"
    case projectionRevision = "projection_revision"
    case requestID = "request_id"
    case activationEpoch = "activation_epoch"
    case payload
  }
}

nonisolated internal struct HerdrNativeProcessStartIdentity: Codable, Equatable, Sendable {
  internal let seconds: UInt64
  internal let microseconds: UInt64
}

nonisolated internal struct HerdrNativeContractReady: Codable, Equatable, Sendable {
  internal let surfaceProof: String
  internal let challenge: String
  internal let processID: Int32
  internal let userID: UInt32
  internal let processGroupID: UInt32
  internal let foregroundProcessGroupID: UInt32
  internal let processStartIdentity: HerdrNativeProcessStartIdentity
  internal let ownerProcessID: Int32
  internal let capabilities: HerdrNativeChromeCapabilities

  internal init(
    surfaceProof: String,
    processID: Int32,
    capabilities: HerdrNativeChromeCapabilities,
    challenge: String = "",
    userID: UInt32 = 0,
    processGroupID: UInt32 = 0,
    foregroundProcessGroupID: UInt32 = 0,
    processStartIdentity: HerdrNativeProcessStartIdentity = .init(seconds: 0, microseconds: 0),
    ownerProcessID: Int32 = 0
  ) {
    self.surfaceProof = surfaceProof
    self.challenge = challenge
    self.processID = processID
    self.userID = userID
    self.processGroupID = processGroupID
    self.foregroundProcessGroupID = foregroundProcessGroupID
    self.processStartIdentity = processStartIdentity
    self.ownerProcessID = ownerProcessID
    self.capabilities = capabilities
  }

  private enum CodingKeys: String, CodingKey {
    case surfaceProof = "surface_proof"
    case challenge
    case processID = "process_id"
    case userID = "user_id"
    case processGroupID = "process_group_id"
    case foregroundProcessGroupID = "foreground_process_group_id"
    case processStartIdentity = "process_start_identity"
    case ownerProcessID = "owner_process_id"
    case capabilities
  }
}

nonisolated internal struct HerdrNativeMutationResult: Codable, Equatable, Sendable {
  internal let succeeded: Bool
  internal let message: String?
  internal let endpointKey: HerdrEndpointKey?
  internal let endpointFence: HerdrEndpointFence?

  internal init(
    succeeded: Bool,
    message: String?,
    endpointKey: HerdrEndpointKey? = nil,
    endpointFence: HerdrEndpointFence? = nil
  ) {
    self.succeeded = succeeded
    self.message = message
    self.endpointKey = endpointKey
    self.endpointFence = endpointFence
  }

  private enum CodingKeys: String, CodingKey {
    case succeeded
    case message
    case endpointKey = "endpoint_key"
    case endpointFence = "endpoint_fence"
  }
}

nonisolated internal struct HerdrNativeAggregatePayload: Codable, Equatable, Sendable {
  internal let state: HerdrAggregateState
  internal let syncCommitted: Bool
  internal let succeeded: Bool?
  internal let message: String?
  internal let endpointKey: HerdrEndpointKey?
  internal let endpointFence: HerdrEndpointFence?
  internal let processInfo: HerdrPaneProcessInfo?

  private enum CodingKeys: String, CodingKey {
    case state
    case syncCommitted = "sync_committed"
    case succeeded
    case message
    case endpointKey = "endpoint_key"
    case endpointFence = "endpoint_fence"
    case processInfo = "process_info"
  }
}

nonisolated internal struct HerdrNativeActionPayload: Codable, Equatable, Sendable {
  internal let action: String
  internal let endpointKey: HerdrEndpointKey?
  internal let endpointFence: HerdrEndpointFence?
  internal let resourceKind: String?
  internal let resourceID: String?
  internal let method: String?
  internal let params: [String: HerdrJSONValue]?

  private enum CodingKeys: String, CodingKey {
    case action
    case endpointKey = "endpoint_key"
    case endpointFence = "endpoint_fence"
    case resourceKind = "resource_kind"
    case resourceID = "resource_id"
    case method
    case params
  }
}

nonisolated internal enum HerdrTabRenameMethod {
  internal static func method(for label: String?) -> String {
    label == nil ? "tab.rename.v2" : "tab.rename"
  }
}

nonisolated internal enum HerdrJSONValue: Codable, Equatable, Sendable {
  case string(String)
  case int(Int)
  case bool(Bool)
  case null

  internal init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else {
      throw DecodingError.typeMismatch(
        Self.self,
        .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON action value.")
      )
    }
  }

  internal func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

nonisolated internal enum HerdrNativeClientEvent: Equatable, Sendable {
  case noContractClaim
  case aggregateStarted(clientInstanceID: String)
  case stream(HerdrNativeStreamState)
  case incompatible(String)
}

nonisolated internal struct HerdrNativeActionRequest: Equatable, Sendable {
  internal let requestID: String
  internal let activationEpoch: UInt64?
  internal let payload: HerdrNativeActionPayload
}

nonisolated internal enum HerdrNativeClaimResult: Sendable {
  case noContractClaim
  case aggregate(HerdrNativeContractSession)
  case incompatible(String)
}

nonisolated internal enum HerdrNativeStreamState: Equatable, Sendable {
  case frame(HerdrNativeAggregateFrame)
  case disconnected
  case reconnected(epoch: UInt64)
  case incompatible(String)
}

nonisolated internal struct HerdrNativeContractSession: Sendable {
  internal let clientInstanceID: String
  internal let stream: AsyncStream<HerdrNativeStreamState>
  internal let send: @Sendable (Data) async throws -> Void
  internal let cancel: @Sendable () -> Void
}

nonisolated internal struct HerdrNativeAggregateFrame: Equatable, Sendable {
  internal let messageKind: String
  internal let sequence: UInt64
  internal let projectionRevision: UInt64
  internal let activationEpoch: UInt64?
  internal let requestID: String?
  internal let mutationResult: HerdrNativeMutationResult?
  internal let processInfoTarget: HerdrPaneTarget?
  internal let processInfoFence: HerdrEndpointFence?
  internal let processInfo: HerdrPaneProcessInfo?
  internal let state: HerdrAggregateState
  internal let syncCommitted: Bool
}
