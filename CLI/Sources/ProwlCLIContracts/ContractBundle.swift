import Foundation

public enum ProwlCLIContractBundle {
  public static let schemaData: Data = load(resource: "cli-output-schema")

  /// Draft 2020-12 schema of a `prowl.workflow/v1` file; must equal
  /// `WorkflowJSONSchema.definitionSchemaJSON` (pinned by a test).
  public static let workflowDefinitionSchemaData: Data = load(resource: "workflow-definition-schema")

  private static func load(resource: String) -> Data {
    guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
      preconditionFailure("Missing Prowl CLI JSON Schema resource \(resource).json.")
    }
    do {
      return try Data(contentsOf: url)
    } catch {
      preconditionFailure("Failed to load Prowl CLI JSON Schema resource \(resource).json: \(error)")
    }
  }
}
