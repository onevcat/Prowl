import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowBindingResolverTests {
  private static let claudeID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private static let codexID = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
  private static let codexHighID = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
  private static let disabledID = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!
  private static let ampID = UUID(uuidString: "00000000-0000-0000-0000-00000000000E")!

  private let profiles = [
    AgentProfile(id: claudeID, name: "Claude Code", runtime: .claude),
    AgentProfile(id: codexID, name: "Codex", runtime: .codex),
    AgentProfile(
      id: codexHighID, name: "Codex xHigh", runtime: .codex, reasoningEffort: "xhigh", executionMode: .standard),
    AgentProfile(id: disabledID, name: "Disabled Codex", isEnabled: false, runtime: .codex, reasoningEffort: "xhigh"),
    AgentProfile(id: ampID, name: "Amp", runtime: .amp),
  ]

  private func role(
    agents: [String]? = ["codex", "claude"],
    suggest: WorkflowProfileSuggestion? = nil
  ) -> WorkflowRoleDefinition {
    WorkflowRoleDefinition(
      name: "reviewer", source: .launch,
      launch: WorkflowLaunchRequirements(agents: agents, suggest: suggest))
  }

  private func context(
    designated: UUID? = nil, lastLaunched: UUID? = nil,
    promptSupport: @escaping @Sendable (AgentProfile) -> Bool = { $0.runtime != .amp }
  ) -> WorkflowBindingResolverContext {
    WorkflowBindingResolverContext(
      profiles: profiles, designatedProfileID: designated, lastLaunchedProfileID: lastLaunched,
      supportsSeededPrompt: promptSupport)
  }

  // MARK: - Memory key

  @Test func canonicalRequirementsSortKeysAndAgentsAndOmitAbsentFields() {
    let role = WorkflowRoleDefinition(
      name: "reviewer", source: .launch,
      launch: WorkflowLaunchRequirements(
        agents: ["codex", "claude"], suggest: WorkflowProfileSuggestion(agent: "codex", reasoningEffort: "xhigh")))
    #expect(
      WorkflowBindingResolver.canonicalRequirements(role)
        == "{\"agents\":[\"claude\",\"codex\"],\"kind\":\"interactive\",\"source\":\"launch\","
        + "\"suggest\":{\"agent\":\"codex\",\"reasoning_effort\":\"xhigh\"}}")
    let bare = WorkflowRoleDefinition(name: "r", source: .launch, launch: WorkflowLaunchRequirements())
    #expect(WorkflowBindingResolver.canonicalRequirements(bare) == "{\"kind\":\"interactive\",\"source\":\"launch\"}")
    #expect(
      WorkflowBindingResolver.canonicalRequirements(WorkflowRoleDefinition(name: "a", source: .current))
        == "{\"source\":\"current\"}")
  }

  @Test func digestIgnoresAgentOrderAndPresentationButNotRequirements() {
    let base = role(agents: ["codex", "claude"])
    let reordered = role(agents: ["claude", "codex"])
    let placementOnly = WorkflowRoleDefinition(
      name: "reviewer", source: .launch,
      launch: WorkflowLaunchRequirements(agents: ["codex", "claude"], bind: .auto, placement: .tab, background: true))
    let narrowed = role(agents: ["codex"])
    #expect(WorkflowBindingResolver.requirementsDigest(base) == WorkflowBindingResolver.requirementsDigest(reordered))
    #expect(
      WorkflowBindingResolver.requirementsDigest(base) == WorkflowBindingResolver.requirementsDigest(placementOnly))
    #expect(WorkflowBindingResolver.requirementsDigest(base) != WorkflowBindingResolver.requirementsDigest(narrowed))
    #expect(WorkflowBindingResolver.requirementsDigest(base).count == 64)
    let key = WorkflowBindingResolver.memoryKey(
      scope: .repo(repositoryID: "repo-1"), workflowID: "prowl.adversarial-review", role: base)
    #expect(key.scope == "repo:repo-1")
    #expect(key.workflowID == "prowl.adversarial-review")
    #expect(key.role == "reviewer")
    #expect(key.digest == WorkflowBindingResolver.requirementsDigest(base))
  }

  // MARK: - Tiers

  @Test func rememberedBindingWinsWhenStillAdmissible() throws {
    let result = try WorkflowBindingResolver.resolve(
      role: role(), remembered: Self.codexID, override: nil, context: context()
    ).get()
    #expect(result.resolution == .resolved(profiles[1], tier: .remembered))
    #expect(result.rejected.isEmpty)
  }

  @Test func rememberedBindingThatFailsValidationFallsThrough() throws {
    let disabled = try WorkflowBindingResolver.resolve(
      role: role(), remembered: Self.disabledID, override: nil, context: context()
    ).get()
    #expect(disabled.rejected[.remembered] == .disabled)
    #expect(disabled.resolution == .resolved(profiles[0], tier: .recommended))

    let missing = try WorkflowBindingResolver.resolve(
      role: role(), remembered: UUID(), override: nil, context: context()
    ).get()
    #expect(missing.rejected[.remembered] == .missing)

    let wrongAgent = try WorkflowBindingResolver.resolve(
      role: role(agents: ["codex"]), remembered: Self.claudeID, override: nil, context: context()
    ).get()
    #expect(wrongAgent.rejected[.remembered] == .agentNotAllowed("claude"))
    #expect(wrongAgent.resolution == .resolved(profiles[1], tier: .recommended))

    let noPrompt = try WorkflowBindingResolver.resolve(
      role: role(agents: nil), remembered: Self.ampID, override: nil, context: context()
    ).get()
    #expect(noPrompt.rejected[.remembered] == .promptUnsupported)
  }

  @Test func suggestionMatchesExactlyBeforeTheRecommendation() throws {
    let suggest = WorkflowProfileSuggestion(agent: "codex", reasoningEffort: "xhigh", executionMode: "standard")
    let result = try WorkflowBindingResolver.resolve(
      role: role(suggest: suggest), remembered: nil, override: nil, context: context()
    ).get()
    #expect(result.resolution == .resolved(profiles[2], tier: .suggestion))

    let unmatched = WorkflowProfileSuggestion(agent: "codex", model: "gpt-x")
    let fallback = try WorkflowBindingResolver.resolve(
      role: role(suggest: unmatched), remembered: nil, override: nil, context: context(designated: Self.codexID)
    ).get()
    #expect(fallback.resolution == .resolved(profiles[1], tier: .recommended))
  }

  @Test func recommendationFollowsThe053TiersOverTheFilteredSet() throws {
    let designated = try WorkflowBindingResolver.resolve(
      role: role(), remembered: nil, override: nil,
      context: context(designated: Self.codexHighID, lastLaunched: Self.codexID)
    ).get()
    #expect(designated.resolution == .resolved(profiles[2], tier: .recommended))
    let lastLaunched = try WorkflowBindingResolver.resolve(
      role: role(), remembered: nil, override: nil,
      context: context(designated: Self.disabledID, lastLaunched: Self.codexID)
    ).get()
    #expect(lastLaunched.resolution == .resolved(profiles[1], tier: .recommended))
    let filtered = try WorkflowBindingResolver.resolve(
      role: role(agents: ["codex"]), remembered: nil, override: nil, context: context(designated: Self.claudeID)
    ).get()
    #expect(filtered.resolution == .resolved(profiles[1], tier: .recommended))
  }

  @Test func nothingAdmissibleAsksWithTheSuggestion() throws {
    let suggest = WorkflowProfileSuggestion(agent: "gemini")
    let result = try WorkflowBindingResolver.resolve(
      role: role(agents: ["gemini"], suggest: suggest), remembered: nil, override: nil, context: context()
    ).get()
    #expect(result.resolution == .ask(candidates: [], suggestion: suggest))
    let noPromptSupport = try WorkflowBindingResolver.resolve(
      role: role(), remembered: nil, override: nil, context: context(promptSupport: { _ in false })
    ).get()
    #expect(noPromptSupport.resolution == .ask(candidates: [], suggestion: nil))
  }

  @Test func overridesResolveByIDOrUniqueNameAndFallThroughWhenInadmissible() throws {
    let byID = try WorkflowBindingResolver.resolve(
      role: role(), remembered: nil, override: .profileID(Self.codexID), context: context()
    ).get()
    #expect(byID.resolution == .resolved(profiles[1], tier: .override))
    let byName = try WorkflowBindingResolver.resolve(
      role: role(), remembered: nil, override: .profileName("Codex xHigh"), context: context()
    ).get()
    #expect(byName.resolution == .resolved(profiles[2], tier: .override))
    let auto = try WorkflowBindingResolver.resolve(
      role: role(), remembered: Self.codexID, override: .auto, context: context()
    ).get()
    #expect(auto.resolution == .resolved(profiles[1], tier: .remembered))

    #expect(
      WorkflowBindingResolver.resolve(role: role(), remembered: nil, override: .profileName("Nope"), context: context())
        == .failure(.profileNotFound("Nope")))
    #expect(
      WorkflowBindingResolver.resolve(role: role(), remembered: nil, override: .profileID(UUID()), context: context())
        .failureCode == "PROFILE_NOT_FOUND")
    var duplicated = profiles
    duplicated.append(AgentProfile(id: UUID(), name: "Codex", runtime: .codex))
    let duplicateContext = WorkflowBindingResolverContext(profiles: duplicated, supportsSeededPrompt: { _ in true })
    #expect(
      WorkflowBindingResolver.resolve(
        role: role(), remembered: nil, override: .profileName("Codex"), context: duplicateContext)
        == .failure(.profileNotUnique("Codex")))

    let inadmissible = try WorkflowBindingResolver.resolve(
      role: role(), remembered: nil, override: .profileID(Self.disabledID), context: context()
    ).get()
    #expect(inadmissible.rejected[.override] == .disabled)
    #expect(inadmissible.resolution == .resolved(profiles[0], tier: .recommended))
  }

  @Test func nonLaunchRolesCannotBeResolved() {
    let current = WorkflowRoleDefinition(name: "author", source: .current)
    #expect(
      WorkflowBindingResolver.resolve(role: current, remembered: nil, override: nil, context: context())
        == .failure(.roleNotLaunchable("author")))
  }

  @Test func adapterProbeRejectsAmpAndAcceptsSeededPromptRuntimes() {
    #expect(WorkflowBindingResolver.adapterSupportsSeededPrompt(profiles[0]))
    #expect(WorkflowBindingResolver.adapterSupportsSeededPrompt(profiles[1]))
    #expect(!WorkflowBindingResolver.adapterSupportsSeededPrompt(profiles[4]))
  }
}

extension Result where Success == WorkflowBindingResult, Failure == WorkflowBindingError {
  fileprivate var failureCode: String? {
    if case .failure(let error) = self { return error.code }
    return nil
  }
}
