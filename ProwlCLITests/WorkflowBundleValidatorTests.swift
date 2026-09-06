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

  @Test func skippedBranchAndLoopOutputsAreUnavailableOutsideTheirScope() {
    for control in ["if: 'true'\n    then:", "while: 'false'\n    steps:"] {
      let diagnostics = codes("""
        - id: branch
          \(control)
            - id: snapshot
              action: builtin:git.context
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
              action: builtin:git.context
          else:
            - id: consume
              notify: '{{ actions.snapshot.output.path }}'
      """) == ["unknown_variable"])
  }

  @Test func outerOutputsRemainAvailableInsideNestedLoops() {
    #expect(codes("""
        - id: snapshot
          action: builtin:git.context
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
    #expect(codes("  - id: invalid\n    notify: '{{ context.execution.id }}'") == ["unknown_variable"])
    #expect(codes("  - id: snapshot\n    action: builtin:git.context\n    with: {root: '{{ context.execution.cwd }}'}").isEmpty)
  }

  @Test func builtinInputTypesAndRemovedActionsAreRejected() {
    #expect(codes("  - id: snapshot\n    action: builtin:git.context\n    with: {root: 3}") == ["action_input_type"])
    #expect(codes("  - id: old\n    action: handoff.checkpoint") == ["unknown_action"])
  }
  @Test func aBranchCannotOverwriteAnOuterOutputBinding() {
    let diagnostics = codes("""
      - id: outer
        message: author
        text: Write.
        expect: {output: report}
      - id: branch
        if: 'true'
        then:
          - id: inner
            message: author
            text: Write again.
            expect: {output: report}
      - id: after
        notify: '{{ outputs.report.path }}'
    """, state: "roles: {author: {source: current}}")
    #expect(diagnostics.contains("output_shadowing"))
  }

}
