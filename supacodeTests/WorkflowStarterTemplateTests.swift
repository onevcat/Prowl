import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowStarterTemplateTests {
  @Test func starterValidatesAsAUserWorkflow() throws {
    let parsed = WorkflowDocumentParser.parse(WorkflowStarterTemplate.yaml(id: "new-workflow"))
    let definition = try #require(parsed.definition)
    #expect(parsed.diagnostics.isEmpty)
    #expect(definition.id == "new-workflow")

    let diagnostics = WorkflowValidator.validate(definition, context: WorkflowValidationContext(scope: .user))
    #expect(diagnostics.filter { $0.severity == .error }.isEmpty, "\(diagnostics)")
    #expect(definition.roles.map(\.name) == ["author", "reviewer"])
    #expect(definition.steps.map(\.id) == ["brief", "review", "done"])
  }

  @Test func writeUsesTheFileStemAsIdAndNeverOverwrites() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "prowl-starter-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try WorkflowStarterTemplate.write(in: directory)
    let second = try WorkflowStarterTemplate.write(in: directory)

    #expect(first.lastPathComponent == "new-workflow.yaml")
    #expect(second.lastPathComponent == "new-workflow-2.yaml")
    let secondDefinition = WorkflowDocumentParser.parse(try String(contentsOf: second, encoding: .utf8)).definition
    #expect(secondDefinition?.id == "new-workflow-2")
    #expect(WorkflowStarterTemplate.uniqueFileURL(in: directory).lastPathComponent == "new-workflow-3.yaml")
  }
}
