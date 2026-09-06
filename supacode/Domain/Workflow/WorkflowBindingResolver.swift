// supacode/Domain/Workflow/WorkflowBindingResolver.swift
// Pure binding resolution for `launch` roles (dsl-spec §3, decision H10): remembered binding →
// enabled profile matching `suggest` exactly → 053 Recommended over the `agents`-filtered set →
// ask. Every candidate is re-validated; the memory key carries a digest of the role's
// requirement block so an edited requirement never reuses a stale binding.

import CryptoKit
import Foundation
import ProwlCLIShared

/// The four-tuple key of the binding memory. Codable so the wiring layer can keep it in
/// `@Shared` storage; the digest is SHA-256 over the canonical requirement JSON.
nonisolated struct WorkflowBindingMemoryKey: Hashable, Codable, Sendable {
  let scope: String
  let workflowID: String
  let role: String
  let digest: String

  enum CodingKeys: String, CodingKey {
    case scope
    case workflowID = "workflow_id"
    case role
    case digest
  }
}

nonisolated enum WorkflowBindingOverride: Equatable, Sendable {
  case profileID(UUID)
  case profileName(String)
  case auto
}

nonisolated enum WorkflowBindingTier: Hashable, Sendable {
  case override
  case remembered
  case suggestion
  case recommended
}

nonisolated enum WorkflowBindingResolution: Equatable, Sendable {
  case resolved(AgentProfile, tier: WorkflowBindingTier)
  /// Nothing resolved unambiguously: the admissible candidates for a picker, plus the
  /// suggestion a "Create profile from suggestion…" action would start from.
  case ask(candidates: [AgentProfile], suggestion: WorkflowProfileSuggestion?)
}

nonisolated enum WorkflowBindingError: Error, Equatable, Sendable {
  case profileNotFound(String)
  case profileNotUnique(String)
  case roleNotLaunchable(String)

  var code: String {
    switch self {
    case .profileNotFound: CLIErrorCode.profileNotFound
    case .profileNotUnique: CLIErrorCode.profileNotUnique
    case .roleNotLaunchable: CLIErrorCode.invalidArgument
    }
  }
}

/// Why a candidate was rejected; reported so a CLI override that fell through can warn.
nonisolated enum WorkflowBindingRejection: Equatable, Sendable {
  case missing
  case disabled
  case agentNotAllowed(String)
  case promptUnsupported
}

nonisolated struct WorkflowBindingResolverContext: Sendable {
  let profiles: [AgentProfile]
  /// The 053 Recommended inputs of the source repository.
  let designatedProfileID: UUID?
  let lastLaunchedProfileID: UUID?
  /// Whether the runtime's adapter renders a seeded prompt; the default probes the registry.
  let supportsSeededPrompt: @Sendable (AgentProfile) -> Bool

  init(
    profiles: [AgentProfile],
    designatedProfileID: UUID? = nil,
    lastLaunchedProfileID: UUID? = nil,
    supportsSeededPrompt: @escaping @Sendable (AgentProfile) -> Bool = WorkflowBindingResolver
      .adapterSupportsSeededPrompt
  ) {
    self.profiles = profiles
    self.designatedProfileID = designatedProfileID
    self.lastLaunchedProfileID = lastLaunchedProfileID
    self.supportsSeededPrompt = supportsSeededPrompt
  }
}

nonisolated struct WorkflowBindingResult: Equatable, Sendable {
  let resolution: WorkflowBindingResolution
  /// The explicit override or remembered binding that failed re-validation, if any.
  let rejected: [WorkflowBindingTier: WorkflowBindingRejection]
}

nonisolated enum WorkflowBindingResolver {
  // MARK: Memory key

  static func memoryKey(scope: WorkflowRunScope, workflowID: String, role: WorkflowRoleDefinition)
    -> WorkflowBindingMemoryKey
  {
    WorkflowBindingMemoryKey(
      scope: scope.key, workflowID: workflowID, role: role.name, digest: requirementsDigest(role))
  }

  /// SHA-256 over the canonical JSON of `{source, kind, agents, suggest}`: sorted keys,
  /// `agents` sorted, absent keys omitted. Prompt-only edits keep the digest.
  static func requirementsDigest(_ role: WorkflowRoleDefinition) -> String {
    let json = canonicalRequirements(role)
    let digest = SHA256.hash(data: Data(json.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func canonicalRequirements(_ role: WorkflowRoleDefinition) -> String {
    var fields: [String: Any] = ["source": role.source.rawValue]
    if let launch = role.launch {
      fields["kind"] = launch.kind.rawValue
      if let agents = launch.agents {
        fields["agents"] = agents.sorted()
      }
      if let suggest = launch.suggest {
        var suggestion: [String: String] = [:]
        suggestion["agent"] = suggest.agent
        suggestion["model"] = suggest.model
        suggestion["reasoning_effort"] = suggest.reasoningEffort
        suggestion["execution_mode"] = suggest.executionMode
        fields["suggest"] = suggestion
      }
    }
    // JSONSerialization with sortedKeys is deterministic for string/array/dictionary values.
    guard
      let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return json
  }

  // MARK: Resolution

  static func resolve(
    role: WorkflowRoleDefinition,
    remembered: UUID?,
    override: WorkflowBindingOverride?,
    context: WorkflowBindingResolverContext
  ) -> Result<WorkflowBindingResult, WorkflowBindingError> {
    guard role.source == .launch, let requirements = role.launch else {
      return .failure(.roleNotLaunchable(role.name))
    }
    var rejected: [WorkflowBindingTier: WorkflowBindingRejection] = [:]
    if let override, override != .auto {
      let profile: AgentProfile?
      switch override {
      case .profileID(let id):
        profile = context.profiles.first { $0.id == id }
        guard profile != nil else { return .failure(.profileNotFound(id.uuidString)) }
      case .profileName(let name):
        let matches = context.profiles.filter { $0.name == name }
        guard !matches.isEmpty else { return .failure(.profileNotFound(name)) }
        guard matches.count == 1 else { return .failure(.profileNotUnique(name)) }
        profile = matches.first
      case .auto:
        profile = nil
      }
      if let profile {
        if let rejection = rejection(of: profile, requirements: requirements, context: context) {
          rejected[.override] = rejection
        } else {
          return .success(WorkflowBindingResult(resolution: .resolved(profile, tier: .override), rejected: rejected))
        }
      }
    }
    if let remembered {
      if let profile = context.profiles.first(where: { $0.id == remembered }) {
        if let rejection = rejection(of: profile, requirements: requirements, context: context) {
          rejected[.remembered] = rejection
        } else {
          return .success(WorkflowBindingResult(resolution: .resolved(profile, tier: .remembered), rejected: rejected))
        }
      } else {
        rejected[.remembered] = .missing
      }
    }
    let admissible = context.profiles.filter { rejection(of: $0, requirements: requirements, context: context) == nil }
    if let suggest = requirements.suggest, let match = admissible.first(where: { matches($0, suggestion: suggest) }) {
      return .success(WorkflowBindingResult(resolution: .resolved(match, tier: .suggestion), rejected: rejected))
    }
    if let recommended = AgentProfileRecommendation.recommendedProfile(
      profiles: admissible,
      designatedID: context.designatedProfileID,
      lastLaunchedID: context.lastLaunchedProfileID)
    {
      return .success(WorkflowBindingResult(resolution: .resolved(recommended, tier: .recommended), rejected: rejected))
    }
    return .success(
      WorkflowBindingResult(
        resolution: .ask(candidates: admissible, suggestion: requirements.suggest), rejected: rejected))
  }

  /// nil when the profile may be bound: exists, enabled, satisfies `agents`, supports a seeded prompt.
  static func rejection(
    of profile: AgentProfile,
    requirements: WorkflowLaunchRequirements,
    context: WorkflowBindingResolverContext
  ) -> WorkflowBindingRejection? {
    guard profile.isEnabled else { return .disabled }
    let token = profile.runtime.agent.rawValue
    if let agents = requirements.agents, !agents.contains(token) {
      return .agentNotAllowed(token)
    }
    guard context.supportsSeededPrompt(profile) else { return .promptUnsupported }
    return nil
  }

  /// Every field the suggestion names must equal the profile's; absent fields do not constrain.
  static func matches(_ profile: AgentProfile, suggestion: WorkflowProfileSuggestion) -> Bool {
    let actual = WorkflowProfileSuggestion(
      agent: profile.runtime.agent.rawValue,
      model: profile.model,
      reasoningEffort: profile.reasoningEffort,
      executionMode: profile.executionMode.rawValue)
    for (wanted, value) in [
      (suggestion.agent, actual.agent), (suggestion.model, actual.model),
      (suggestion.reasoningEffort, actual.reasoningEffort), (suggestion.executionMode, actual.executionMode),
    ] where wanted != nil && wanted != value {
      return false
    }
    return true
  }

  /// Probes the runtime adapter with a seeded prompt; Amp rejects it, the others render it.
  @Sendable static func adapterSupportsSeededPrompt(_ profile: AgentProfile) -> Bool {
    let request = AgentStartRequest(
      runtime: profile.runtime,
      intent: .prompt("probe"),
      configuration: AgentLaunchConfiguration(
        model: profile.model,
        executionMode: profile.executionMode,
        reasoningEffort: profile.reasoningEffort,
        extraArguments: ShellWordSplitter.split(profile.extraArguments)),
      dedicatedHome: nil)
    guard let invocation = try? AgentRuntimeAdapterRegistry.makeStartInvocation(request) else { return false }
    return invocation.arguments.last == "probe"
  }
}
