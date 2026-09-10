import Foundation
import ProwlCLIShared
import XCTest

final class WorkflowValidatorTests: XCTestCase {
  private func minimal(id: String = "demo", steps: String = "", roles: String = "") -> String {
    WorkflowFixtures.minimal(id: id, extraSteps: steps, extraRoles: roles)
  }

  private func errors(_ diagnostics: [WorkflowDiagnostic]) -> [String] {
    diagnostics.filter { $0.severity == .error }.map(\.code)
  }

  private func warnings(_ diagnostics: [WorkflowDiagnostic]) -> [String] {
    diagnostics.filter { $0.severity == .warning }.map(\.code)
  }

  // MARK: - The spec example

  func testSpecExampleIsValidInBundleScope() {
    let diagnostics = WorkflowFixtures.diagnostics(WorkflowFixtures.adversarialReview, scope: .bundle)
    XCTAssertEqual(diagnostics, [])
  }

  func testReservedIDIsRejectedOutsideTheBundle() {
    for scope in [WorkflowScope.user, .repo] {
      let diagnostics = WorkflowFixtures.diagnostics(WorkflowFixtures.adversarialReview, scope: scope)
      XCTAssertEqual(errors(diagnostics), ["reserved_id"], "\(scope)")
    }
  }

  func testUnknownBundleReportsSkillsAsUncheckedAndAKnownBundleChecksThem() {
    let unchecked = WorkflowFixtures.diagnostics(
      WorkflowFixtures.adversarialReview, scope: .bundle, bundledSkillIDs: nil)
    XCTAssertEqual(warnings(unchecked), ["skill_unchecked"])
    XCTAssertEqual(errors(unchecked), [])
    let missing = WorkflowFixtures.diagnostics(
      WorkflowFixtures.adversarialReview, scope: .bundle, bundledSkillIDs: ["prowl-cli"])
    XCTAssertEqual(errors(missing), ["skill_not_found"])
  }

  // MARK: - Ids and roles

  func testSlugsAreEnforcedForIdsRolesStepsDeliveriesAndInputs() {
    XCTAssertEqual(WorkflowFixtures.codes(minimal(id: "Demo Flow")), ["workflow_id"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(roles: "  Reviewer:\n    source: pick")), ["role_name_slug"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(steps: "  - id: Fix It\n    notify: hi")), ["step_id_slug"])
    XCTAssertEqual(
      WorkflowFixtures.codes(
        minimal(steps: "  - id: b\n    message: author\n    prompt: hi\n    expect: { delivery: Bad.Name }")),
      ["delivery_name_slug"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  Max: { type: integer }\n"), ["input_name_slug"])
  }

  func testAtMostOneCurrentRole() {
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(roles: "  other:\n    source: current")), ["multiple_current_roles"])
  }

  func testUndefinedRolesAndRoleSources() {
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: "  - id: b\n    message: ghost\n    prompt: hi")), ["undefined_role"])
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: "  - id: b\n    close: ghost")), ["undefined_role"])
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: "  - id: b\n    close: author")), ["close_role_source"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(steps: "  - id: b\n    launch: author\n    prompt: go")), ["launch_role_source"])
  }

  func testLaunchOrderingRules() {
    let role = "  r:\n    source: launch"
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(steps: "  - id: b\n    message: r\n    prompt: hi", roles: role)),
      ["message_before_launch"])
    let twice = "  - id: l1\n    launch: r\n    prompt: go\n  - id: l2\n    launch: r\n    prompt: again"
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: twice, roles: role)), ["launch_twice"])
    let ordered = "  - id: l1\n    launch: r\n    prompt: go\n  - id: m\n    message: r\n    prompt: \"pane {{ context.roles.r.pane_id }}\""
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: ordered, roles: role)), [])
  }

  func testDuplicateStepIdsAcrossNesting() {
    let steps = """
        - id: loop
          while: "true"
          steps:
            - id: ask
              notify: hi
      """
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: steps)), ["duplicate_step_id"])
  }

  // MARK: - Inputs

  func testInputConstraints() {
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  n: { type: integer, default: 11, min: 1, max: 10 }\n"),
      ["input_range"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  n: { type: integer, min: 5, max: 1 }\n"), ["input_range"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  m: { type: enum, values: [a, b], default: c }\n"), ["enum_default"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  m: { type: enum, values: [a, a] }\n"), ["enum_values_duplicate"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  s: { type: string, default: \"two\\nlines\" }\n"),
      ["input_default_multiline"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  m: { type: enum, values: [a, \"two\\nlines\"] }\n"),
      ["enum_value_multiline"])
  }

  // MARK: - Templates

  func testTemplateReferencesAreWhitelistedAndOrdered() {
    let role = "  r:\n    source: launch"
    func codes(_ text: String, roles: String = "") -> [String] {
      WorkflowFixtures.codes(minimal(steps: "  - id: b\n    notify: \"\(text)\"", roles: roles))
    }
    XCTAssertEqual(codes("{{ context.run.id }} {{ context.run.path }} {{ context.worktree.path }} {{ context.worktree.branch }}"), [])
    XCTAssertEqual(codes("{{ context.roles.author.display_name }} {{ context.roles.author.agent }} {{ context.roles.author.pane_id }}"), [])
    XCTAssertEqual(codes("{{ nope.x }}"), ["unknown_variable"])
    XCTAssertEqual(codes("{{ context.worktree.owner }}"), ["unknown_variable"])
    XCTAssertEqual(codes("{{ inputs.missing }}"), ["unknown_variable"])
    XCTAssertEqual(codes("{{ deliveries.brief.path }}"), ["unknown_variable"], "no producer yet")
    XCTAssertEqual(codes("{{ context.roles.r.pane_id }}", roles: role), [], "unlaunched pane is explicitly null")
    XCTAssertEqual(codes("{{ context.step.iteration }}"), [], "outside a loop iteration is explicitly null")
    XCTAssertEqual(codes("{{ loop.count }}"), ["unknown_variable"], "before any loop")
    XCTAssertEqual(codes("{{ open"), ["template_syntax"])
    XCTAssertEqual(codes("{{ }}"), ["expression_syntax"])
  }

  func testDeliveryAndActionReferencesFollowProducers() {
    let steps = """
        - id: b
          message: author
          prompt: hi
          expect: { delivery: brief }
        - id: ctx
          action: builtin:collect-worktree-context
        - id: n
          notify: "{{ deliveries.brief.path }} {{ actions.ctx.output.path }} {{ actions.ctx.output.branch }}"
        - id: v
          notify: "{{ deliveries.brief.verdict }}"
        - id: k
          notify: "{{ actions.ctx.nope }}"
      """
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: steps)), ["unknown_variable", "unknown_variable"])
  }

  func testActionsInsideALoopAreNotVisibleAfterIt() {
    let steps = """
        - id: loop
          while: "true"
          steps:
            - id: ctx
              action: builtin:collect-worktree-context
            - id: inside
              notify: "{{ actions.ctx.output.path }} round {{ context.step.iteration }}"
        - id: after
          notify: "{{ actions.ctx.output.path }}"
      """
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: steps)), ["unknown_variable"])
  }

  // MARK: - Actions

  func testActionInputsFollowTheRegistry() {
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: "  - id: b\n    action: fs.delete")), ["unknown_action"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(steps: "  - id: b\n    action: builtin:collect-worktree-context\n    with: { depth: 3 }")),
      ["unknown_action_input"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(steps: "  - id: b\n    action: handoff.transition\n    with: { from: author }")),
      ["unknown_action"])
  }

  // MARK: - Repeat and until




  func testVerdictRules() {
    func expect(_ verdict: String) -> String {
      minimal(steps: "  - id: b\n    message: author\n    prompt: hi\n    expect: { verdicts: \(verdict) }")
    }
    XCTAssertEqual(WorkflowFixtures.codes(expect("[clean]")), ["verdict_count"])
    XCTAssertEqual(WorkflowFixtures.codes(expect("[a, b, c, d, e]")), ["verdict_count"])
    XCTAssertEqual(WorkflowFixtures.codes(expect("[clean, clean]")), ["verdict_duplicate"])
    XCTAssertEqual(WorkflowFixtures.codes(expect("[clean, \"Needs Work\"]")), ["verdict_slug"])
    XCTAssertEqual(WorkflowFixtures.codes(expect("[clean, issues]")), [])
  }

  func testPromptsAcceptQuotedNewlinesAndBlockScalars() {
    let text = minimal(steps: "  - id: b\n    message: author\n    prompt: \"two\\nlines\"")
    XCTAssertEqual(WorkflowFixtures.codes(text), [])
    let instruction = minimal(steps: "  - id: b\n    message: author\n    prompt: |\n      two\n      lines")
    XCTAssertEqual(WorkflowFixtures.codes(instruction), [])
  }

  // MARK: - Warnings

  func testWarnings() {
    let long = minimal(steps: "  - id: b\n    message: author\n    prompt: hi\n    expect: { timeout: 3h }")
    XCTAssertEqual(WorkflowFixtures.codes(long), ["timeout_long"])
    let spelled = minimal(steps: "  - id: b\n    message: author\n    prompt: \"finish with prowl workflow deliver -\"")
    XCTAssertEqual(WorkflowFixtures.codes(spelled), ["spells_completion_command"])
    XCTAssertEqual(WorkflowFixtures.diagnostics(spelled).first?.severity, .warning)
  }

  func testSkipWarnsOnlyWhenALaterNonOptionalConsumerExists() {
    let blocking = """
        - id: b
          message: author
          prompt: hi
          expect: { delivery: brief, timeout: 5m, on_timeout: skip }
        - id: n
          notify: "{{ deliveries.brief.path }}"
      """
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: blocking)), ["skip_ends_run"])
    let optional = """
        - id: b
          message: author
          prompt: hi
          expect: { delivery: brief, timeout: 5m, on_timeout: skip }
        - id: t
          action: builtin:collect-worktree-context
          with: { root: "{{ deliveries.brief.path ?? context.worktree.path }}" }
      """
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: optional)), [])
  }

  func testAgentTokenWarnings() {
    let role = "  r:\n    source: launch\n    agents: [codex, robo]"
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(roles: role), knownAgents: ["codex", "claude"]), ["unknown_agent"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(roles: role), installedAgents: ["claude"]), ["agents_not_installed"])
    XCTAssertEqual(WorkflowFixtures.codes(minimal(roles: role), installedAgents: ["codex"]), [])
    XCTAssertEqual(WorkflowFixtures.codes(minimal(roles: role)), [], "unknown catalogs skip the warnings")
  }

  // MARK: - Round 1 review findings

  func testInputDefaultsRemainSingleLineButPromptsAllowTabs() {
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  s: { type: string, default: \"has\\ttab\" }\n"),
      ["input_default_multiline"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(steps: "  - id: b\n    message: author\n    prompt: \"a\\tb\"")), [])
  }


  func testVerdictReferencesFollowTheLatestProducer() {
    let stale = """
        - id: first
          message: author
          prompt: First
          expect: { delivery: result, verdicts: [clean, issues] }
        - id: second
          message: author
          prompt: Second
          expect: { delivery: result }
        - id: report
          notify: "{{ deliveries.result.verdict }}"
      """
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: stale)), ["unknown_variable"])
    let refreshed = """
        - id: first
          message: author
          prompt: First
          expect: { delivery: result }
        - id: second
          message: author
          prompt: Second
          expect: { delivery: result, verdicts: [clean, issues] }
        - id: report
          notify: "{{ deliveries.result.verdict }}"
      """
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: refreshed)), [])
  }


  func testSuggestWarnsWhenNoEnabledProfileMatches() {
    let role = "  r:\n    source: launch\n    suggest: { agent: codex, reasoning_effort: xhigh }"
    let codexHigh = WorkflowProfileSuggestion(agent: "codex", model: "gpt-5", reasoningEffort: "xhigh", executionMode: "standard")
    let claude = WorkflowProfileSuggestion(agent: "claude", model: nil, reasoningEffort: nil, executionMode: "standard")
    XCTAssertEqual(WorkflowFixtures.codes(minimal(roles: role), enabledProfiles: [claude]), ["suggest_unmatched"])
    XCTAssertEqual(WorkflowFixtures.codes(minimal(roles: role), enabledProfiles: [claude, codexHigh]), [])
    XCTAssertEqual(WorkflowFixtures.codes(minimal(roles: role)), [], "no profile catalog: no warning")
  }

  // MARK: - Round 2 review findings




  func testBlankNamesAndTokensAreRejectedLikeTheSchemaDoes() {
    XCTAssertEqual(
      WorkflowFixtures.codes("schema: prowl.workflow/v1\nid: demo\nname: \"\"\nroles:\n  author:\n    source: current\nsteps:\n  - id: a\n    notify: hi\n"),
      ["name_empty"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal(roles: "  r:\n    source: launch\n    agents: [\"\", codex]")), ["agent_token_empty"])
    XCTAssertEqual(
      WorkflowFixtures.codes(minimal() + "inputs:\n  m: { type: enum, values: [\"\", b] }\n"), ["enum_value_empty"])
  }

  // MARK: - Round 3 review findings

  func testSkipWarningsRespectProducerAndConsumerOrder() {
    let consumedBefore = """
        - id: first
          message: author
          prompt: First
          expect: { delivery: brief }
        - id: use
          notify: "{{ deliveries.brief.path }}"
        - id: second
          message: author
          prompt: Second
          expect: { delivery: brief, timeout: 5m, on_timeout: skip }
      """
    XCTAssertEqual(WorkflowFixtures.codes(minimal(steps: consumedBefore)), [], "nothing after the skip depends on it")
  }
}
