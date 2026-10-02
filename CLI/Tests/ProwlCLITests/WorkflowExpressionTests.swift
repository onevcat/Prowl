import Foundation
import Testing
@testable import ProwlCLIShared

struct WorkflowExpressionTests {
  @Test func arithmeticAndTypedValues() throws {
    #expect(try WorkflowExpression.evaluate("2 + 3 * 4", values: [:]) == .integer(14))
    #expect(try WorkflowExpression.evaluate("state.items[1]", values: [
      "state": .object(["items": .array([.boolean(false), .boolean(true)])])
    ]) == .boolean(true))
    #expect(try WorkflowExpression.evaluate("append([1], 2)", values: [:]) == .array([.integer(1), .integer(2)]))
  }

  @Test func shortCircuitAndMissingValues() throws {
    #expect(try WorkflowExpression.evaluate("false && actions.missing.output", values: [:]) == .boolean(false))
    #expect(try WorkflowExpression.evaluate("true || (1 / 0 > 0)", values: [:]) == .boolean(true))
    #expect(try WorkflowExpression.evaluate("actions.missing.output ?? 3", values: [:]) == .integer(3))
    #expect(try WorkflowExpression.evaluate("exists(actions.missing)", values: [:]) == .boolean(false))
    #expect(throws: (any Error).self) { try WorkflowExpression.evaluate("1 / 0 ?? 3", values: [:]) }
    #expect(throws: (any Error).self) { try WorkflowExpression.evaluate("exists(1 / 0)", values: [:]) }
    #expect(throws: (any Error).self) { try WorkflowExpression.evaluate("actions.missing.output", values: [:]) }
  }

  @Test func rejectsCoercionOverflowAndTrailingTokens() {
    for expression in ["true + 1", "9007199254740991 + 1", "1 / 0", "1 2", "false && ("] {
      #expect(throws: (any Error).self) { try WorkflowExpression.evaluate(expression, values: [:]) }
    }
  }

  @Test func templatesPreserveTypesAndRejectCompositeText() throws {
    let values: [String: WorkflowJSONValue] = ["inputs": .object(["items": .array([.integer(1)])])]
    #expect(try WorkflowExpression.renderValue(.string("{{ inputs.items }}"), values: values) == .array([.integer(1)]))
    #expect(try WorkflowExpression.renderText("Count: {{ length(inputs.items) }}", values: values) == "Count: 1")
    #expect(throws: (any Error).self) { try WorkflowExpression.renderText("Items: {{ inputs.items }}", values: values) }
  }
  @Test func numericEqualitySurvivesJSONRoundTrips() throws {
    #expect(try WorkflowExpression.evaluate("1 == 1.0", values: [:]) == .boolean(true))
    #expect(try WorkflowExpression.evaluate("[1] == [1.0]", values: [:]) == .boolean(true))
    #expect(try WorkflowExpression.evaluate("true == 1", values: [:]) == .boolean(false))
  }

  @Test func rejectsExcessiveFlatExpressions() {
    let source = Array(repeating: "1", count: 600).joined(separator: "+")
    #expect(throws: (any Error).self) { try WorkflowExpression.evaluate(source, values: [:]) }
  }

}
