import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowStartPlanTests {
  @Test func handoffRolesNameTheirStepsAndPlacement() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let yaml = try String(
      contentsOf: root.appending(path: "Resources/workflows/handoff.pwlworkflow/workflow.yaml"), encoding: .utf8)
    let definition = try #require(WorkflowDocumentParser.parse(yaml).definition)
    let plan = WorkflowStartPlan(definition: definition)

    #expect(plan.roles.map(\.title) == ["Author", "Receiver"])
    #expect(plan.roles[0].kindLabel == "This pane")
    #expect(plan.roles[0].stepsCaption == "Step 1 · Prepare handoff briefing")
    #expect(plan.roles[0].placementNote == nil)
    #expect(plan.roles[1].kindLabel == "New agent")
    #expect(plan.roles[1].stepsCaption == "Step 3 · Start receiving agent")
    #expect(plan.roles[1].placementNote == "Opens in a new tab")

    #expect(plan.steps.map(\.number) == [1, 2, 3, 4])
    #expect(
      plan.steps.map(\.title) == [
        "Prepare handoff briefing", "Save handoff packet", "Start receiving agent", "Send to Prowl Notifications",
      ])
    #expect(plan.steps.map(\.context) == [.always, .always, .conditional, .always])
    #expect(plan.steps.map(\.roleTitle) == ["Author", nil, "Receiver", nil])
    #expect(plan.steps.map(\.verb) == ["message", "action", "launch", "notify"])
  }

  @Test func loopBodiesAreRepeatedAndControlStepsAreNotListed() throws {
    let yaml = """
      schema: prowl.workflow/v1
      id: loop
      name: Loop
      state:
        rounds: { type: integer, initial: 0 }
      roles:
        author:
          source: current
        pair_reviewer:
          source: pick
      steps:
        - id: again
          while: state.rounds < 2
          steps:
            - id: bump
              set: { rounds: state.rounds + 1 }
            - id: review
              message: pair_reviewer
              prompt: Review.
              expect: { delivery: findings }
        - id: wrap
          message: author
          prompt: Wrap up.
      """
    let definition = try #require(WorkflowDocumentParser.parse(yaml).definition)
    let plan = WorkflowStartPlan(definition: definition)
    #expect(plan.steps.map(\.id) == ["review", "wrap"])
    #expect(plan.steps.map(\.context) == [.repeated, .always])
    #expect(plan.roles.map(\.title) == ["Author", "Pair reviewer"])
    #expect(plan.roles[1].kindLabel == "Existing agent")
    #expect(plan.roles[1].stepsCaption == "Step 1 · Message pair_reviewer")
    #expect(plan.roles[0].stepsCaption == "Step 2 · Message author")
  }
}
