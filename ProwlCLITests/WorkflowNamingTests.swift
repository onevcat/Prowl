import Testing
@testable import ProwlCLIShared
@testable import prowl

struct WorkflowNamingTests {
  @Test func optionalExpressionsStillValidateNamespaceSpelling() throws {
    for (expression, accepted) in [
      ("context.run.directory ?? 'missing'", false),
      ("exists(outputs.findings.path)", false),
      ("exists(context.source) && context.source.pane_id != ''", false),
      ("!exists(context.execution) || context.execution.id == ''", false),
      ("context['run']['workflow_id'] ?? 'missing'", false),
      ("context.roles['author']['pane'] ?? ''", false),
      ("context.run.path ?? ''", true),
      ("exists(deliveries.findings.path)", true),
      ("exists(context.initiator) && context.initiator.pane_id != ''", true),
    ] {
      let definition = WorkflowDefinition(
        id: "naming", name: "Naming", roles: [.init(name: "author", source: .current)],
        steps: [.init(id: "condition", action: .control(.conditional(condition: expression, then: [], else: [])))])
      let diagnostics = WorkflowValidator.validate(definition, context: .init(scope: .user))
      #expect(diagnostics.contains { $0.code == "unknown_variable" } != accepted)
    }
  }

  @Test func verdictDiagnosticsNameTheDeclarationKey() throws {
    for values in ["[clean]", "[clean, clean]"] {
      let parsed = WorkflowDocumentParser.parse("""
        schema: prowl.workflow/v1
        id: naming
        name: Naming
        roles: {author: {source: current}}
        steps: [{id: report, message: author, prompt: Review., expect: {delivery: report, verdicts: \(values)}}]
        """)
      let definition = try #require(parsed.definition)
      let diagnostics = WorkflowValidator.validate(definition, context: .init(scope: .user))
      #expect(diagnostics.contains { $0.message.contains("'verdicts'") })
    }
  }

  @Test func localActionIDsUseKebabCase() {
    let yaml = """
      schema: prowl.action/v1
      name: Write report
      input_schema: {type: object}
      output_schema: {type: object}
      backend: {type: script, interpreter: /bin/sh, entrypoint: main.sh}
      """
    #expect(throws: (any Error).self) { try WorkflowScriptAction.parse(yaml, id: "write_report") }
  }

  @Test func retiredExpectationKeysAreRejected() {
    for fields in ["output: brief", "verdict: [ready, blocked]"] {
      let parsed = WorkflowDocumentParser.parse("""
        schema: prowl.workflow/v1
        id: naming
        name: Naming
        roles: {author: {source: current}}
        steps: [{id: brief, message: author, prompt: Write., expect: {\(fields)}}]
        """)
      #expect(parsed.definition == nil)
      #expect(parsed.diagnostics.contains { $0.code == "unknown_key" })
    }
  }

  @Test func currentNamespacesValidateAndOldNamespacesDoNot() throws {
    for (reference, accepted) in [
      ("context.workflow.id", true), ("context.workflow.name", true), ("context.run.path", true),
      ("context.initiator.pane_id", true), ("context.roles.author.display_name", true),
      ("context.roles.author.pane_id", true), ("context.run.workflow_id", false),
      ("context.run.directory", false), ("context.source.pane_id", false),
      ("context.roles.author.name", false), ("context.roles.author.pane", false),
    ] {
      let parsed = WorkflowDocumentParser.parse("""
        schema: prowl.workflow/v1
        id: naming
        name: Naming
        roles: {author: {source: current}}
        steps: [{id: report, notify: '{{ \(reference) }}'}]
        """)
      let definition = try #require(parsed.definition)
      let diagnostics = WorkflowValidator.validate(definition, context: .init(scope: .user))
      #expect(diagnostics.contains { $0.code == "unknown_variable" } != accepted)
    }
  }

  @Test func inheritedEnvironmentHasAnExplicitName() throws {
    let source = """
      schema: prowl.action/v1
      name: Read configuration
      input_schema: {type: object}
      output_schema: {type: object}
      backend:
        type: script
        interpreter: /bin/sh
        entrypoint: main.sh
        inherit_env: [SELECTED_VALUE]
      """
    _ = try WorkflowScriptAction.parse(source, id: "read-configuration")
    #expect(throws: (any Error).self) {
      try WorkflowScriptAction.parse(source.replacing("inherit_env", with: "environment"), id: "read-configuration")
    }
  }

  @Test func acceptsDeliveryAndPluralVerdictDeclaration() {
    let parsed = WorkflowDocumentParser.parse("""
      schema: prowl.workflow/v1
      id: naming
      name: Naming
      roles: {author: {source: current}}
      steps:
        - id: brief
          message: author
          prompt: Write a briefing.
          expect: {delivery: briefing, verdicts: [ready, blocked]}
      """)
    #expect(parsed.diagnostics.isEmpty)
    #expect(parsed.definition != nil)
  }

  @Test func routesDeliverAndRejectsRetiredCommand() throws {
    _ = try ProwlCommand.parseAsRoot(["workflow", "deliver", "-"])
    #expect(throws: (any Error).self) {
      _ = try ProwlCommand.parseAsRoot(["workflow", "done", "-"])
    }
  }

  @Test func collectorUsesVerbFirstName() {
    #expect(WorkflowActionRegistry.schema(for: "builtin:collect-worktree-context") != nil)
    #expect(WorkflowActionRegistry.schema(for: "builtin:git.context") == nil)
  }
}
