import Testing
@testable import ProwlCLIShared

struct WorkflowBundleValidatorTests {
  private func codes(_ steps: String, state: String = "") -> [String] {
    let yaml = """
      schema: prowl.workflow/v1
      id: example
      name: Example
      \(state)
      steps:
      \(steps)
      """
    let parsed = WorkflowDocumentParser.parse(yaml)
    guard let definition = parsed.definition else { return parsed.diagnostics.map(\.code) }
    return WorkflowValidator.validate(definition, context: .init(scope: .user)).map(\.code)
  }

  @Test func conditionalLaunchFactsJoinAcrossBranches() {
    let header = "roles: {helper: {source: launch}}"
    let choice = """
      - id: choose
        if: 'true'
        then: [{id: strict, launch: helper, prompt: Review strictly.}]
        else: [{id: normal, launch: helper, prompt: Review normally.}]
      """
    #expect(codes(choice + "\n- id: work\n  message: helper\n  prompt: Review.", state: header).isEmpty)
    #expect(codes(choice + "\n- id: again\n  launch: helper\n  prompt: Review.", state: header)
      .contains("launch_twice"))
    let partial = """
      - id: choose
        if: 'true'
        then: [{id: strict, launch: helper, prompt: Review strictly.}]
      """
    #expect(codes(partial + "\n- id: work\n  message: helper\n  prompt: Review.", state: header)
      .contains("message_before_launch"))
    #expect(codes(partial + "\n- id: again\n  launch: helper\n  prompt: Review.", state: header)
      .contains("launch_twice"))
  }

  @Test func skippedBranchAndLoopOutputsAreUnavailableOutsideTheirScope() {
    for control in ["if: 'true'\n    then:", "while: 'false'\n    steps:"] {
      let diagnostics = codes("""
        - id: branch
          \(control)
            - id: snapshot
              action: builtin:collect-worktree-context
        - id: consume
          notify: '{{ actions.snapshot.output.path }}'
      """)
      #expect(diagnostics.contains("unknown_variable"))
    }
  }

  @Test func elseCannotReadThenOutput() {
    #expect(codes("""
        - id: branch
          if: 'true'
          then:
            - id: snapshot
              action: builtin:collect-worktree-context
          else:
            - id: consume
              notify: '{{ actions.snapshot.output.path }}'
      """) == ["unknown_variable"])
  }

  @Test func outerOutputsRemainAvailableInsideNestedLoops() {
    #expect(codes("""
        - id: snapshot
          action: builtin:collect-worktree-context
        - id: outer
          while: 'true'
          max_iterations: 2
          steps:
            - id: inner
              while: 'false'
              steps:
                - id: consume
                  notify: '{{ actions.snapshot.output.path }}'
      """).isEmpty)
  }

  @Test func optionalOutputGuardsAllowShortCircuitedAccess() {
    for condition in [
      "exists(actions.missing.output) && actions.missing.output.count > 0",
      "!exists(actions.missing.output) || actions.missing.output.count > 0",
    ] {
      #expect(codes("  - id: branch\n    if: '" + condition + "'\n    then: [{id: done, notify: done}]").isEmpty)
    }
    #expect(codes("""
      - id: branch
        if: 'exists(actions.other.output) && actions.missing.output.count > 0'
        then: [{id: done, notify: done}]
      """).contains("unknown_variable"))
  }

  @Test func nestedWorkflowStructureHasABoundedDepth() {
    var step = "{id: done, notify: done}"
    for index in 0..<70 { step = "{id: branch" + String(index) + ", if: 'true', then: [" + step + "]}" }
    let parsed = WorkflowDocumentParser.parse(
      "schema: prowl.workflow/v1\nid: deep\nname: Deep\nsteps: [" + step + "]")
    #expect(parsed.definition == nil)
    #expect(parsed.diagnostics.contains { $0.code == "document_limit" })
  }

  @Test func missingDataRequiresExplicitHandling() {
    #expect(codes("""
        - id: consume
          notify: '{{ actions.missing.output.path }}'
      """) == ["unknown_variable"])
    #expect(codes("""
        - id: consume
          notify: '{{ actions.missing.output.path ?? "none" }}'
      """).isEmpty)
  }

  @Test func stateAndExpressionsAreValidated() {
    #expect(codes("  - id: set\n    set: {missing: '3'}") == ["unknown_state"])
    #expect(codes("  - id: loop\n    while: 'true && ('\n    steps: [{id: stop, break: true}]")
      .contains("expression_syntax"))
    #expect(codes("  - id: loop\n    while: 'true'\n    max_iterations: 0\n    steps: [{id: stop, break: true}]")
      .contains("loop_limit"))
  }

  @Test func executionContextOnlyExistsForActionInputs() {
    #expect(codes("  - id: invalid\n    notify: '{{ context.action.execution_id }}'") == ["unknown_variable"])
    #expect(codes("  - id: snapshot\n    action: builtin:collect-worktree-context\n    with: {root: '{{ context.action.working_directory }}'}").isEmpty)
  }

  @Test func builtinInputTypesAndRemovedActionsAreRejected() {
    #expect(codes("  - id: snapshot\n    action: builtin:collect-worktree-context\n    with: {root: 3}") == ["action_input_type"])
    #expect(codes("  - id: old\n    action: handoff.checkpoint") == ["unknown_action"])
  }
  @Test func aBranchCannotOverwriteAnOuterOutputBinding() {
    let diagnostics = codes("""
      - id: outer
        message: author
        prompt: Write.
        expect: {delivery: report}
      - id: branch
        if: 'true'
        then:
          - id: inner
            message: author
            prompt: Write again.
            expect: {delivery: report}
      - id: after
        notify: '{{ deliveries.report.path }}'
    """, state: "roles: {author: {source: current}}")
    #expect(diagnostics.contains("delivery_shadowing"))
  }

}
