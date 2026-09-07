import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowExecutionContextTests {
  private func makeRun() throws -> WorkflowRun {
    let pane = WorkflowPaneIdentity(
      surfaceID: UUID(), tabID: UUID(), handle: "p3", displayName: "Source Agent", agent: "pi")
    let definition = WorkflowDefinition(
      id: "local.naming", name: "Naming",
      roles: [.init(name: "author", source: .current)],
      steps: [.init(id: "snapshot", action: .action(id: "builtin:collect-worktree-context", inputs: [:]))])
    let (machine, _) = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "target", name: "Project", branch: "main", path: "/tmp/project")),
        bindings: ["author": .current(pane)]),
      now: { Date(timeIntervalSince1970: 1) })
    return machine.run
  }

  @Test func definitionRunTargetAndRoleHaveDistinctIdentities() throws {
    let run = try makeRun()
    let values = run.expressionValues(capturedAt: Date(timeIntervalSince1970: 2))
    #expect(
      try WorkflowExpression.renderText("{{ context.workflow.id }}:{{ context.workflow.name }}", values: values)
        == "local.naming:Naming")
    #expect(try WorkflowExpression.renderText("{{ context.run.id }}", values: values) == run.id.uuidString)
    #expect(try WorkflowExpression.renderText("{{ context.run.path }}", values: values) == run.runDirectory.path)
    #expect(try WorkflowExpression.renderText("{{ context.worktree.path }}", values: values) == "/tmp/project")
    #expect(
      try WorkflowExpression.renderText("{{ context.roles.author.display_name }}", values: values) == "Source Agent")
    let paneID = try #require(run.bindings["author"]?.pane?.surfaceID.uuidString)
    #expect(try WorkflowExpression.renderText("{{ context.roles.author.pane_id }}", values: values) == paneID)
    #expect(try WorkflowExpression.renderText("{{ context.initiator.pane_id }}", values: values) == paneID)
  }

  @Test func actionInputsReceiveAttemptMetadata() throws {
    let run = try makeRun()
    let values = run.stepValues
    #expect(
      try WorkflowExpression.renderText("{{ context.action.execution_id }}", values: values)
        == run.actionExecutionID)
    #expect(
      try WorkflowExpression.renderText("{{ context.action.working_directory }}", values: values)
        == "/tmp/project")
    #expect(
      try WorkflowExpression.renderText("{{ context.action.artifacts_directory }}", values: values)
        .hasSuffix("/artifacts"))
    #expect(try WorkflowExpression.evaluate("context.action.attempt", values: values) == .integer(1))
  }
}
