import Testing
@testable import ProwlCLIShared

struct WorkflowStateTests {
  @Test func assignmentsReadOneSnapshot() throws {
    var state = try WorkflowTypedState(declarations: [
      "left": .init(type: "integer", initial: .integer(1)),
      "right": .init(type: "integer", initial: .integer(2)),
    ])
    try state.assign(["left": "state.right", "right": "state.left"], values: [:])
    #expect(state.values == ["left": .integer(2), "right": .integer(1)])
  }

  @Test func failedAssignmentDoesNotPartiallyCommit() throws {
    var state = try WorkflowTypedState(declarations: [
      "count": .init(type: "integer", initial: .integer(1)),
      "ready": .init(type: "boolean", initial: .boolean(false)),
    ])
    let before = state.values
    #expect(throws: (any Error).self) {
      try state.assign(["count": "2", "ready": "3"], values: [:])
    }
    #expect(state.values == before)
    #expect(throws: (any Error).self) { try state.assign(["unknown": "true"], values: [:]) }
    #expect(state.values == before)
  }

  @Test func typedArraysRejectMixedValues() throws {
    #expect(throws: (any Error).self) {
      try WorkflowTypedState(declarations: [
        "items": .init(type: "array<integer>", initial: .array([.integer(1), .string("2")]))
      ])
    }
    var state = try WorkflowTypedState(declarations: [
      "items": .init(type: "array<integer>", initial: .array([]))
    ])
    try state.assign(["items": "append(state.items, 3)"], values: [:])
    #expect(state.values["items"] == .array([.integer(3)]))
  }
}
