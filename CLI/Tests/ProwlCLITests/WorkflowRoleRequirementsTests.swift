import Foundation
import Testing

@testable import ProwlCLIShared

struct WorkflowRoleRequirementsTests {
  @Test func shippedHandoffIsAValidBuiltInBundle() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let file = WorkflowDiscovery.load(
      url: root.appending(path: "Resources/workflows/handoff.pwlworkflow"),
      scope: .bundle, context: .init(scope: .bundle))
    #expect(file.isValid)
    #expect(file.definition?.id == "prowl.handoff")
  }

  private func definition(condition: String = "inputs.next == 'launch'") throws -> WorkflowDefinition {
    try #require(
      WorkflowDocumentParser.parse(
        """
        schema: prowl.workflow/v1
        id: example
        name: Example
        inputs:
          next: {type: enum, values: [save, launch], default: launch}
        roles:
          receiver: {source: launch}
        steps:
          - id: choose
            if: "\(condition)"
            then:
              - id: receive
                launch: receiver
                prompt: Continue.
                expect: {delivery: accepted}
        """
      ).definition)
  }

  @Test func saveOnlyDoesNotRequireAReceiver() throws {
    #expect(WorkflowRoleRequirements.launchRoles(in: try definition(), inputs: ["next": "save"]).isEmpty)
    #expect(WorkflowRoleRequirements.launchRoles(in: try definition(), inputs: [:]) == ["receiver"])
    #expect(WorkflowRoleRequirements.launchRoles(in: try definition(), inputs: ["next": "launch"]) == ["receiver"])
  }

  @Test func skippedLaunchDoesNotRequireAReceiver() throws {
    #expect(WorkflowRoleRequirements.launchRoles(in: try definition(), inputs: [:], skipped: ["receive"]).isEmpty)
  }

  @Test func optionalRuntimeReferencesDoNotPredictTheBranch() throws {
    let definition = try definition(condition: "!exists(state.ready)")
    #expect(WorkflowRoleRequirements.launchRoles(in: definition, inputs: [:]) == ["receiver"])
  }
}
