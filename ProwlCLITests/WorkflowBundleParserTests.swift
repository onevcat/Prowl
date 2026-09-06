import Testing
@testable import ProwlCLIShared

struct WorkflowBundleParserTests {
  @Test func launchesInsideLoopsAreRejectedEvenInsideBranches() {
    let parsed = WorkflowDocumentParser.parse("""
      schema: prowl.workflow/v1
      id: loop-launch
      name: Loop Launch
      roles: {helper: {source: launch}}
      steps:
        - id: loop
          while: 'true'
          steps:
            - id: branch
              if: 'true'
              then:
                - id: start
                  launch: helper
                  prompt: Work.
      """)
    #expect(parsed.definition == nil)
    #expect(parsed.diagnostics.contains { $0.code == "launch_in_loop" })
  }

  @Test func parsesTypedActionInputsAndNestedControlFlow() throws {
    let result = WorkflowDocumentParser.parse("""
      schema: prowl.workflow/v1
      id: sample
      name: Sample
      state:
        count: {type: integer, initial: 0}
      steps:
        - id: loop
          while: state.count < 3
          steps:
            - id: increment
              set:
                count: state.count + 1
            - id: inspect
              if: state.count == 2
              then:
                - id: next
                  continue: true
              else:
                - id: snapshot
                  action: local:count
                  with:
                    count: '{{ state.count }}'
                    enabled: true
                    items: [1, 2]
      """)
    #expect(result.diagnostics.isEmpty)
    let definition = try #require(result.definition)
    #expect(definition.flattenedSteps.map(\.id) == ["loop", "increment", "inspect", "next", "snapshot"])
  }

  @Test func rejectsUnknownSchemaAndLoopControlOutsideLoop() {
    let unknown = WorkflowDocumentParser.parse("schema: prowl.workflow/v99\nid: old\nname: Old\nsteps: [{id: end, notify: done}]")
    #expect(unknown.diagnostics.contains { $0.code == "unsupported_schema" })
    let invalid = WorkflowDocumentParser.parse("schema: prowl.workflow/v1\nid: bad\nname: Bad\nsteps: [{id: end, break: true}]")
    #expect(invalid.diagnostics.contains { $0.code == "loop_control_outside_loop" })
  }
}
