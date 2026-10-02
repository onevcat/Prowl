import Foundation
import ProwlCLIShared
import XCTest

/// The dsl-spec.md §4 example and helpers shared by the workflow test suites.
enum WorkflowFixtures {
  static let adversarialReview = """
    schema: prowl.workflow/v1
    id: prowl.adversarial-review
    name: Adversarial Review
    description: One reviewer, bounded rounds until clean.
    icon: magnifyingglass.circle

    inputs:
      max_rounds: { type: integer, default: 5, min: 1, max: 10 }
      focus:      { type: string,  default: "", prompt: "What should the reviewer focus on?" }
      mode:       { type: enum, values: [strict, lenient], default: strict }

    roles:
      author:
        source: current
      reviewer:
        source: launch
        kind: interactive
        agents: [codex, claude]
        suggest:
          agent: codex
          reasoning_effort: xhigh
          execution_mode: standard
        bind: ask
        placement: split
        direction: right
        background: false

    state:
      verdict: {type: string, initial: issues}
      findings_path: {type: string, initial: ""}

    steps:
      - id: brief
        title: "Author writing the brief"
        message: author
        prompt: |
          Write a short brief for an adversarial reviewer: ## Scope, ## Claims, ## How to verify.
          Deliver it with the generated completion command.
        expect: { delivery: brief, sections: ["## Scope", "## Claims"], timeout: 10m }

      - id: launch
        title: "Reviewer starting round 1"
        launch: reviewer
        prompt: "Read {{ deliveries.brief.path }} and the bundled reviewer skill, then review. Focus: {{ inputs.focus }}"
        skill: prowl.adversarial-reviewer
        expect: { delivery: findings, sections: ["## Findings", "## Verdict"], verdicts: [clean, issues], timeout: 30m }

      - id: remember
        set:
          verdict: deliveries.findings.verdict
          findings_path: deliveries.findings.path

      - id: rounds
        while: state.verdict != 'clean'
        max_iterations: 10
        steps:
          - id: fix
            title: "Round {{ context.step.iteration }}: author addressing findings"
            message: author
            prompt: "Findings: {{ state.findings_path }}. Fix or rebut each item."
            expect: { delivery: disposition, timeout: 30m }
          - id: rereview
            message: reviewer
            prompt: "Disposition: {{ deliveries.disposition.path }}. Re-review."
            expect: { delivery: round_findings, verdicts: [clean, issues], timeout: 30m }
          - id: retain
            set:
              verdict: deliveries.round_findings.verdict
              findings_path: deliveries.round_findings.path

      - id: context
        action: builtin:collect-worktree-context
        with: { root: "{{ context.worktree.path }}" }

      - id: done
        notify: "Adversarial review: {{ state.verdict }}"

      - id: cleanup
        close: reviewer
    """

  /// A minimal valid user-scope workflow: one current role, one message step.
  static func minimal(id: String = "demo", extraSteps: String = "", extraRoles: String = "") -> String {
    """
    schema: prowl.workflow/v1
    id: \(id)
    name: Demo
    roles:
      author:
        source: current
    \(extraRoles)
    steps:
      - id: ask
        message: author
        prompt: "Say hello."
    \(extraSteps)

    """
  }

  static func parse(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) throws -> WorkflowDefinition {
    let result = WorkflowDocumentParser.parse(yaml)
    return try XCTUnwrap(
      result.definition,
      "Expected the document to parse; diagnostics: \(result.diagnostics)",
      file: file,
      line: line
    )
  }

  static func parseCodes(_ yaml: String) -> [String] {
    WorkflowDocumentParser.parse(yaml).diagnostics.map(\.code)
  }

  /// Parse + validate; parse errors short-circuit validation exactly as discovery does.
  static func diagnostics(
    _ yaml: String,
    scope: WorkflowScope = .user,
    bundledSkillIDs: Set<String>? = ["prowl.adversarial-reviewer"],
    knownAgents: Set<String>? = nil,
    installedAgents: Set<String>? = nil,
    enabledProfiles: [WorkflowProfileSuggestion]? = nil
  ) -> [WorkflowDiagnostic] {
    let context = WorkflowValidationContext(
      scope: scope, bundledSkillIDs: bundledSkillIDs, knownAgents: knownAgents, installedAgents: installedAgents,
      enabledProfiles: enabledProfiles)
    return WorkflowDiscovery.parse(yaml, url: URL(filePath: "/fixture.yaml"), scope: scope, context: context)
      .diagnostics
  }

  static func codes(
    _ yaml: String,
    scope: WorkflowScope = .user,
    bundledSkillIDs: Set<String>? = ["prowl.adversarial-reviewer"],
    knownAgents: Set<String>? = nil,
    installedAgents: Set<String>? = nil,
    enabledProfiles: [WorkflowProfileSuggestion]? = nil
  ) -> [String] {
    diagnostics(
      yaml, scope: scope, bundledSkillIDs: bundledSkillIDs, knownAgents: knownAgents, installedAgents: installedAgents,
      enabledProfiles: enabledProfiles
    ).map(\.code)
  }
}
