import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowBundleRunMachineTests {
  private func start(_ definition: WorkflowDefinition) throws -> (
    machine: WorkflowRunMachine, effects: [WorkflowRunEffect]
  ) {
    try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "worktree", name: "test", branch: "main", path: "/tmp/prowl-bundle-tests")), bindings: [:]
      ),
      now: { Date(timeIntervalSince1970: 1) })
  }

  @Test func retryHasNewIdentityAndIgnoresOldCompletion() throws {
    var (machine, _) = try start(
      .init(
        id: "test", name: "Test",
        steps: [
          .init(id: "snapshot", action: .action(id: "builtin:collect-worktree-context", inputs: [:])),
          .init(id: "end", action: .notify("{{ actions.snapshot.output.branch }}")),
        ]))
    let first = try #require(machine.run.actionExecutionID)
    _ = machine.apply(.actionFailed(stepID: "snapshot", reason: "failed", executionID: first))
    _ = machine.apply(.user(.retry))
    let second = try #require(machine.run.actionExecutionID)
    #expect(first != second)
    #expect(
      machine.apply(
        .actionCompleted(
          stepID: "snapshot", outputs: ["output": .object(["branch": .string("stale")])],
          executionID: first)
      ).isEmpty)
    let effects = machine.apply(
      .actionCompleted(
        stepID: "snapshot",
        outputs: ["output": .object(["branch": .string("main")])], executionID: second))
    #expect(effects.contains(.notify("main")))
    #expect(machine.run.status == .completed)
  }

  @Test func unlimitedControlLoopYieldsAndCanBeCancelled() throws {
    var (machine, effects) = try start(
      .init(
        id: "loop", name: "Loop",
        steps: [
          .init(
            id: "loop",
            action: .control(
              .loop(
                condition: "true", maximum: nil,
                steps: [.init(id: "tick", action: .control(.set([:])))])))
        ]))
    #expect(effects.contains(.yieldControl))
    effects = machine.apply(.user(.cancel))
    #expect(machine.run.status == .cancelled)
    #expect(effects.contains(.finished(.cancelled)))
    #expect(machine.apply(.continueControlFlow).isEmpty)
  }

  @Test func typedInputsReceiveTheCurrentExecutionIdentity() throws {
    let (machine, effects) = try start(
      .init(
        id: "typed", name: "Typed",
        steps: [
          .init(
            id: "action",
            action: .action(
              id: "local:echo",
              inputs: [
                "count": .integer(3),
                "execution": .string("{{ context.action.execution_id }}"),
              ]))
        ]))
    let invocation = try #require(effects.first { if case .runAction = $0 { true } else { false } })
    guard case .runAction(_, _, let inputs) = invocation else { return }
    #expect(inputs["count"] == .integer(3))
    #expect(inputs["execution"] == machine.run.actionExecutionID.map(WorkflowJSONValue.string))
  }
  @Test func actionRequestKeepsItsInputSnapshot() throws {
    let (machine, effects) = try start(
      .init(
        id: "snapshot", name: "Snapshot",
        steps: [
          .init(
            id: "capture",
            action: .action(
              id: "local:echo",
              inputs: [
                "timestamp": .string("{{ context.step.captured_at }}")
              ]))
        ]))
    guard
      case .runAction(_, _, let inputs) = effects.first(where: {
        if case .runAction = $0 { true } else { false }
      })
    else {
      Issue.record("Missing action")
      return
    }
    #expect(
      inputs["timestamp"]
        == (try WorkflowExpression.evaluate(
          "context.step.captured_at",
          values: machine.run.stepValues)))
  }

  @Test func loopCapIsTerminalAndNeverReportsSuccess() throws {
    let (machine, effects) = try start(
      .init(
        id: "capped", name: "Capped",
        steps: [
          .init(
            id: "loop",
            action: .control(
              .loop(
                condition: "true", maximum: 2,
                steps: [.init(id: "tick", action: .control(.set([:])))])))
        ]))
    #expect(machine.run.status == .iterationLimitReached)
    #expect(effects.contains(.finished(.iterationLimitReached)))
  }

  @Test func repeatedLaunchKeepsTheExistingRoleBinding() throws {
    let definition = try #require(
      WorkflowDocumentParser.parse(
        """
        schema: prowl.workflow/v1
        id: launch-twice
        name: Launch Twice
        roles:
          helper: {source: launch}
        steps:
          - id: first
            launch: helper
            prompt: Start.
          - id: second
            launch: helper
            prompt: Again.
        """
      ).definition)
    let profile = WorkflowProfileBinding(id: UUID(), name: "Helper", agent: "pi")
    var (machine, _) = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "test", name: "test", branch: "main", path: "/tmp")),
        bindings: ["helper": .launch(profile, pane: nil)]), now: { Date(timeIntervalSince1970: 1) })
    let pane = WorkflowPaneIdentity(surfaceID: UUID(), tabID: UUID(), handle: "p1", displayName: "Helper", agent: "pi")
    let effects = machine.apply(.launched(ordinal: 1, pane: pane, dispatchID: nil))
    #expect(machine.run.bindings["helper"]?.pane == pane)
    #expect(machine.run.status.attention != nil)
    #expect(!effects.contains { if case .launch = $0 { true } else { false } })
  }

}
