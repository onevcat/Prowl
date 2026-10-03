import Foundation

nonisolated struct UserGlobalSettings: Codable, Equatable, Sendable {
  var customCommands: [UserCustomCommand]
  var agentProfiles: [AgentProfile]
  /// One-shot seeding marker for agent profiles (docs-ai 053): seeded profiles
  /// the user deletes must never respawn.
  var didSeedAgentProfiles: Bool
  /// `<scope>/<id>` keys of workflow definitions switched off (docs-ai 063 B1; Settings UI in D1).
  var disabledWorkflowIDs: [String]
  /// Remembered `launch` role bindings (dsl-spec §3): one profile per requirements-digest key.
  var workflowBindings: [WorkflowRememberedBinding]
  /// Per-workflow bind-mode overrides (docs-ai 063 C2): "Don't ask again" writes `auto`, D1's
  /// Settings control drives the same value; an absent key follows the YAML `bind` declaration.
  var workflowBindModeOverrides: [WorkflowBindModeOverride]

  static let `default` = UserGlobalSettings(customCommands: [])

  private enum CodingKeys: String, CodingKey {
    case customCommands
    case agentProfiles
    case didSeedAgentProfiles
    case disabledWorkflowIDs
    case workflowBindings
    case workflowBindModeOverrides
  }

  init(
    customCommands: [UserCustomCommand],
    agentProfiles: [AgentProfile] = [],
    didSeedAgentProfiles: Bool = false,
    disabledWorkflowIDs: [String] = [],
    workflowBindings: [WorkflowRememberedBinding] = [],
    workflowBindModeOverrides: [WorkflowBindModeOverride] = []
  ) {
    self.customCommands = UserCustomCommand.normalizedCommands(customCommands)
    self.agentProfiles = AgentProfile.normalizedProfiles(agentProfiles)
    self.didSeedAgentProfiles = didSeedAgentProfiles
    self.disabledWorkflowIDs = Self.normalizedWorkflowIDs(disabledWorkflowIDs)
    self.workflowBindings = WorkflowRememberedBinding.normalized(workflowBindings)
    self.workflowBindModeOverrides = WorkflowBindModeOverride.normalized(workflowBindModeOverrides)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let commands = try container.decodeIfPresent([UserCustomCommand].self, forKey: .customCommands) ?? []
    customCommands = UserCustomCommand.normalizedCommands(commands)
    let profiles = try container.decodeIfPresent([AgentProfile].self, forKey: .agentProfiles) ?? []
    agentProfiles = AgentProfile.normalizedProfiles(profiles)
    didSeedAgentProfiles = try container.decodeIfPresent(Bool.self, forKey: .didSeedAgentProfiles) ?? false
    let disabled = try container.decodeIfPresent([String].self, forKey: .disabledWorkflowIDs) ?? []
    disabledWorkflowIDs = Self.normalizedWorkflowIDs(disabled)
    let bindings = try container.decodeIfPresent([WorkflowRememberedBinding].self, forKey: .workflowBindings) ?? []
    workflowBindings = WorkflowRememberedBinding.normalized(bindings)
    let modeOverrides =
      try container.decodeIfPresent([WorkflowBindModeOverride].self, forKey: .workflowBindModeOverrides) ?? []
    workflowBindModeOverrides = WorkflowBindModeOverride.normalized(modeOverrides)
  }

  func normalized() -> UserGlobalSettings {
    UserGlobalSettings(
      customCommands: customCommands,
      agentProfiles: agentProfiles,
      didSeedAgentProfiles: didSeedAgentProfiles,
      disabledWorkflowIDs: disabledWorkflowIDs,
      workflowBindings: workflowBindings,
      workflowBindModeOverrides: workflowBindModeOverrides
    )
  }

  func rememberedWorkflowBinding(for key: WorkflowBindingMemoryKey) -> UUID? {
    workflowBindings.first { $0.key == key }?.profileID
  }

  mutating func remember(workflowBinding key: WorkflowBindingMemoryKey, profileID: UUID) {
    workflowBindings = WorkflowRememberedBinding.normalized(
      workflowBindings.filter { $0.key != key } + [WorkflowRememberedBinding(key: key, profileID: profileID)])
  }

  /// Drops a remembered binding so the next start resolves the role afresh (Settings "Ask at start").
  mutating func forget(workflowBinding key: WorkflowBindingMemoryKey) {
    workflowBindings = WorkflowRememberedBinding.normalized(workflowBindings.filter { $0.key != key })
  }

  /// The user's bind-mode override for a `<scope>/<id>` workflow key; nil follows the YAML `bind`.
  func workflowBindMode(for workflowKey: String) -> WorkflowBindModeOverride.Mode? {
    workflowBindModeOverrides.first { $0.workflowKey == workflowKey }?.mode
  }

  mutating func setWorkflowBindMode(_ mode: WorkflowBindModeOverride.Mode?, for workflowKey: String) {
    let kept = workflowBindModeOverrides.filter { $0.workflowKey != workflowKey }
    guard let mode else {
      workflowBindModeOverrides = WorkflowBindModeOverride.normalized(kept)
      return
    }
    workflowBindModeOverrides = WorkflowBindModeOverride.normalized(
      kept + [WorkflowBindModeOverride(workflowKey: workflowKey, mode: mode)])
  }

  /// Stable order, no duplicates: the set semantics of a persisted list.
  static func normalizedWorkflowIDs(_ ids: [String]) -> [String] {
    Array(Set(ids)).sorted()
  }
}

/// A per-workflow bind-mode override (docs-ai 063 C2), keyed like `disabledWorkflowIDs`.
nonisolated struct WorkflowBindModeOverride: Codable, Equatable, Sendable {
  enum Mode: String, Codable, Sendable {
    case ask
    case auto
  }

  /// `<scope>/<id>` of the workflow definition.
  let workflowKey: String
  let mode: Mode

  enum CodingKeys: String, CodingKey {
    case workflowKey = "workflow_key"
    case mode
  }

  /// One entry per key (last write wins), in a stable order.
  static func normalized(_ overrides: [WorkflowBindModeOverride]) -> [WorkflowBindModeOverride] {
    var seen: Set<String> = []
    var unique: [WorkflowBindModeOverride] = []
    for override in overrides.reversed() where seen.insert(override.workflowKey).inserted {
      unique.append(override)
    }
    return unique.sorted { $0.workflowKey < $1.workflowKey }
  }
}

/// One remembered `launch` binding: the profile that satisfied a role's requirements last time.
nonisolated struct WorkflowRememberedBinding: Codable, Equatable, Sendable {
  let key: WorkflowBindingMemoryKey
  let profileID: UUID

  enum CodingKeys: String, CodingKey {
    case key
    case profileID = "profile_id"
  }

  /// One entry per key, in a stable order.
  static func normalized(_ bindings: [WorkflowRememberedBinding]) -> [WorkflowRememberedBinding] {
    var seen: Set<WorkflowBindingMemoryKey> = []
    var unique: [WorkflowRememberedBinding] = []
    for binding in bindings.reversed() where seen.insert(binding.key).inserted {
      unique.append(binding)
    }
    return unique.sorted {
      ($0.key.scope, $0.key.workflowID, $0.key.role, $0.key.digest)
        < ($1.key.scope, $1.key.workflowID, $1.key.role, $1.key.digest)
    }
  }
}
