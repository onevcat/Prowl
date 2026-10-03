import ProwlCLIShared
import XCTest

final class WorkflowPromptContractTests: XCTestCase {
  func testMessageAcceptsSingleLineAndMultilinePrompts() throws {
    for prompt in ["prompt: Review this", "prompt: |\n      Review this\n      Report findings"] {
      let result = WorkflowDocumentParser.parse(document("message: author\n    \(prompt)"))
      XCTAssertEqual(result.diagnostics, [])
      let definition = try XCTUnwrap(result.definition)
      XCTAssertEqual(WorkflowValidator.validate(definition, context: .init(scope: .user)).filter { $0.severity == .error }, [])
    }
  }

  func testMessageRequiresPromptAndRejectsRetiredFields() {
    for field in ["text", "instruction"] {
      let result = WorkflowDocumentParser.parse(document("message: author\n    \(field): Review this"))
      XCTAssertNil(result.definition)
      XCTAssertEqual(Set(result.diagnostics.map(\.code)), ["unknown_key", "missing_key"])
      let mixed = WorkflowDocumentParser.parse(document("message: author\n    prompt: Review\n    \(field): Other"))
      XCTAssertEqual(mixed.diagnostics.map(\.code), ["unknown_key"])
    }
    XCTAssertEqual(WorkflowDocumentParser.parse(document("message: author")).diagnostics.map(\.code), ["missing_key"])
  }

  private func document(_ step: String) -> String {
    """
    schema: prowl.workflow/v1
    id: prompt-contract
    name: Prompt contract
    roles:
      author: { source: current }
    steps:
      - id: review
        \(step)
    """
  }
}
