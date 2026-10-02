import Foundation

/// The executable runtimes an Agent Profile may launch. Kept distinct from
/// `DetectedAgent` because launch metadata and detected process identity have
/// different consumers, while every standard runtime maps one-to-one (docs-ai
/// 055.002).
nonisolated enum AgentProfileRuntime: String, Codable, CaseIterable, Identifiable, Sendable {
  case claude
  case codex
  case gemini
  case cursor = "cursor-agent"
  case cline
  case opencode
  case copilot
  case kimi
  case droid
  case amp
  case qoder = "qodercli"
  case qwen
  case grok
  // swiftlint:disable:next identifier_name
  case pi
  case omp

  var id: String { rawValue }

  var agent: DetectedAgent {
    switch self {
    case .claude: .claude
    case .codex: .codex
    case .gemini: .gemini
    case .cursor: .cursor
    case .cline: .cline
    case .opencode: .opencode
    case .copilot: .copilot
    case .kimi: .kimi
    case .droid: .droid
    case .amp: .amp
    case .qoder: .qoder
    case .qwen: .qwen
    case .grok: .grok
    case .pi: .pi
    case .omp: .omp
    }
  }

  init(agent: DetectedAgent) {
    switch agent {
    case .claude: self = .claude
    case .codex: self = .codex
    case .gemini: self = .gemini
    case .cursor: self = .cursor
    case .cline: self = .cline
    case .opencode: self = .opencode
    case .copilot: self = .copilot
    case .kimi: self = .kimi
    case .droid: self = .droid
    case .amp: self = .amp
    case .qoder: self = .qoder
    case .qwen: self = .qwen
    case .grok: self = .grok
    case .pi: self = .pi
    case .omp: self = .omp
    }
  }

  var iconLookupToken: String {
    agent.iconLookupToken
  }

  /// The runtime's default home directory name under `$HOME`. Its existence
  /// is the seeding installation heuristic: the directory exists iff the CLI
  /// has ever run, while PATH lookups from a GUI app are unreliable.
  var defaultHomeDirectoryName: String {
    switch self {
    case .claude: ".claude"
    case .codex: ".codex"
    case .gemini: ".gemini"
    case .cursor: ".cursor"
    case .cline: ".cline"
    case .opencode: ".local/share/opencode"
    case .copilot: ".copilot"
    case .kimi: ".kimi"
    case .droid: ".factory"
    case .amp: ".config/amp"
    case .qoder: ".qoder"
    case .qwen: ".qwen"
    case .grok: ".grok"
    case .pi: ".pi/agent"
    case .omp: ".omp/agent"
    }
  }
}

/// One user-configured environment variable override, applied to the launched
/// process (docs-ai 053/004). An ordered row list rather than a dictionary:
/// the editor table needs stable row identity while a name is being typed, and
/// must tolerate in-progress rows — validity is judged at plan time, not here.
nonisolated struct AgentProfileEnvironmentOverride: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var name: String
  var value: String

  init(id: UUID = UUID(), name: String = "", value: String = "") {
    self.id = id
    self.name = name
    self.value = value
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
}

nonisolated enum AgentProfilePlacement: String, Codable, CaseIterable, Identifiable, Sendable {
  case tab
  case split

  var id: String { rawValue }
}

/// A named launch preset for a verified agent runtime (docs-ai 053).
/// Argv-only by default; an explicit account binding adds a dedicated,
/// UUID-derived runtime home and nothing else.
nonisolated struct AgentProfile: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var name: String
  var isEnabled: Bool
  var runtime: AgentProfileRuntime
  /// User-selected SF Symbol override; nil uses the runtime brand icon.
  var icon: String?
  var model: String?
  var reasoningEffort: String?
  var executionMode: AgentExecutionMode
  var placement: AgentProfilePlacement
  var splitDirection: UserCustomSplitDirection
  var extraArguments: String
  var environmentOverrides: [AgentProfileEnvironmentOverride]
  var bindsDedicatedHome: Bool

  init(
    id: UUID = UUID(),
    name: String,
    isEnabled: Bool = true,
    runtime: AgentProfileRuntime,
    icon: String? = nil,
    model: String? = nil,
    reasoningEffort: String? = nil,
    executionMode: AgentExecutionMode = .standard,
    placement: AgentProfilePlacement = .tab,
    splitDirection: UserCustomSplitDirection = .right,
    extraArguments: String = "",
    environmentOverrides: [AgentProfileEnvironmentOverride] = [],
    bindsDedicatedHome: Bool = false
  ) {
    self.id = id
    self.name = name
    self.isEnabled = isEnabled
    self.runtime = runtime
    self.icon = icon
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.executionMode = executionMode
    self.placement = placement
    self.splitDirection = splitDirection
    self.extraArguments = extraArguments
    self.environmentOverrides = environmentOverrides
    self.bindsDedicatedHome = bindsDedicatedHome
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, isEnabled, runtime, icon, model, reasoningEffort, executionMode
    case placement, splitDirection, extraArguments, environmentOverrides, bindsDedicatedHome
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    runtime = try container.decode(AgentProfileRuntime.self, forKey: .runtime)
    icon = try container.decodeIfPresent(String.self, forKey: .icon)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    executionMode =
      try container.decodeIfPresent(AgentExecutionMode.self, forKey: .executionMode) ?? .standard
    placement = try container.decodeIfPresent(AgentProfilePlacement.self, forKey: .placement) ?? .tab
    splitDirection =
      try container.decodeIfPresent(UserCustomSplitDirection.self, forKey: .splitDirection) ?? .right
    extraArguments = try container.decodeIfPresent(String.self, forKey: .extraArguments) ?? ""
    environmentOverrides =
      try container.decodeIfPresent(
        [AgentProfileEnvironmentOverride].self, forKey: .environmentOverrides
      ) ?? []
    bindsDedicatedHome = try container.decodeIfPresent(Bool.self, forKey: .bindsDedicatedHome) ?? false
  }

  /// Drops profiles whose trimmed name is empty and keeps only the first
  /// occurrence of each UUID.
  static func normalizedProfiles(_ profiles: [AgentProfile]) -> [AgentProfile] {
    var seen = Set<UUID>()
    return profiles.compactMap { profile in
      let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, seen.insert(profile.id).inserted else { return nil }
      var normalized = profile
      normalized.name = name
      return normalized
    }
  }
}

/// Three-tier Recommended resolution: per-repo designation, per-repo launch
/// memory, then the first enabled profile in list order. Each tier resolves
/// only to an existing, enabled profile; a dangling or disabled reference
/// falls through to the next tier. Runtime CLI availability is deliberately a
/// presentation concern: a missing CLI grays the item with a reason instead of
/// silently recommending another profile.
nonisolated enum AgentProfileRecommendation {
  static func recommendedProfile(
    profiles: [AgentProfile],
    designatedID: UUID?,
    lastLaunchedID: UUID?
  ) -> AgentProfile? {
    enabledProfile(in: profiles, id: designatedID)
      ?? enabledProfile(in: profiles, id: lastLaunchedID)
      ?? profiles.first(where: \.isEnabled)
  }

  private static func enabledProfile(in profiles: [AgentProfile], id: UUID?) -> AgentProfile? {
    guard let id else { return nil }
    return profiles.first { $0.id == id && $0.isEnabled }
  }
}
