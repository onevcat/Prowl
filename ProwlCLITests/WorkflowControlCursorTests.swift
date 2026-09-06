import Testing
@testable import ProwlCLIShared

struct WorkflowControlCursorTests {
  @Test func nestedLoopsAndContinueRetainOnlyExplicitState() throws {
    let definition = try #require(WorkflowDocumentParser.parse("""
      schema: prowl.workflow/v1
      id: count
      name: Count
      state:
        count: {type: integer, initial: 0}
      steps:
        - id: loop
          while: state.count < 3
          steps:
            - id: increment
              set: {count: state.count + 1}
            - id: skip
              if: state.count == 2
              then: [{id: next, continue: true}]
            - id: observe
              notify: '{{ state.count }}'
        - id: end
          notify: done
      """).definition)
    var cursor = try WorkflowControlCursor(definition: definition)
    var observed: [String] = []
    for _ in 0..<20 {
      switch try cursor.next(values: [:], budget: 64) {
      case .step(let step):
        if case .notify(let text) = step.action {
          observed.append(try WorkflowExpression.renderText(text, values: cursor.values(over: [:])))
        }
        cursor.complete()
      case .finished: break
      case .yielded: continue
      }
      if cursor.isFinished { break }
    }
    #expect(observed == ["1", "3", "done"])
  }

  @Test func unlimitedPureLoopYieldsAndCapDoesNotCompleteSuccessfully() throws {
    let step = WorkflowStepDefinition(id: "loop", action: .control(.loop(condition: "true", maximum: nil,
      steps: [.init(id: "tick", action: .control(.set([:])))])))
    var cursor = try WorkflowControlCursor(definition: .init(id: "test", name: "Test", steps: [step]))
    #expect(try cursor.next(values: [:], budget: 64) == .yielded)
    let capped = WorkflowStepDefinition(id: "loop", action: .control(.loop(condition: "true", maximum: 2,
      steps: [.init(id: "tick", action: .control(.set([:])))])))
    var limited = try WorkflowControlCursor(definition: .init(id: "test", name: "Test", steps: [capped]))
    #expect(throws: (any Error).self) { try limited.next(values: [:], budget: 64) }
  }
}
