import ProwlCLIShared
import Testing

@testable import Prowl

struct WorkflowSkipIndexTests {
  @Test func onlyStepsWithAnExpectProduceADelivery() throws {
    let index = try makeIndex()
    #expect(index.delivery(ofStep: "write") == "draft")
    #expect(index.delivery(ofStep: "review") == "review")
    #expect(index.delivery(ofStep: "announce") == nil)
    #expect(index.delivery(ofStep: "check") == nil)
    #expect(index.delivery(ofStep: "missing") == nil)
  }

  @Test func eachKindOfStepRecordsTheDeliveriesItRequires() throws {
    let index = try makeIndex()
    // A title and a prompt.
    #expect(index.step("review", requires: "draft"))
    #expect(index.step("review", requires: "outline"))
    // A notification, nested action inputs, a condition, and an assignment.
    #expect(index.step("announce", requires: "review"))
    #expect(index.step("collect", requires: "draft"))
    #expect(index.step("collect", requires: "review"))
    #expect(index.step("check", requires: "review"))
    #expect(index.step("remember", requires: "draft"))
    #expect(index.step("rounds", requires: "review"))
  }

  @Test func aControlStepDoesNotAnswerForTheStepsInsideIt() throws {
    let index = try makeIndex()
    #expect(!index.step("check", requires: "draft"))
    #expect(index.step("remember", requires: "draft"))
    #expect(!index.step("rounds", requires: "outline"))
    #expect(index.step("again", requires: "outline"))
  }

  @Test func toleratedAndUnreadableReferencesAreNotRequired() throws {
    let index = try makeIndex()
    // `??` and `exists` tolerate a missing delivery.
    #expect(!index.step("write", requires: "outline"))
    #expect(!index.step("write", requires: "review"))
    // A text that does not parse requires nothing.
    #expect(!index.step("broken", requires: "draft"))
    #expect(!index.step("missing", requires: "draft"))
  }

  private func makeIndex() throws -> WorkflowSkipIndex {
    WorkflowSkipIndex(definition: try #require(WorkflowDocumentParser.parse(Self.workflow).definition))
  }

  private static let workflow = """
    schema: prowl.workflow/v1
    id: skip-index
    name: Skip Index
    state:
      path: {type: string, initial: ''}
    roles:
      author:
        source: current
    steps:
      - id: write
        message: author
        prompt: "Use {{ deliveries.outline.path ?? 'nothing' }} and {{ exists(deliveries.review) }}."
        expect: { delivery: draft }
      - id: review
        title: "Review of {{ deliveries.outline.path }}"
        message: author
        prompt: "Review {{ deliveries.draft.path }}."
        expect: {}
      - id: announce
        notify: "Reviewed: {{ deliveries.review.path }}"
      - id: collect
        action: local:collect
        with: { files: ["{{ deliveries.draft.path }}"], notes: { review: "{{ deliveries.review.path }}" } }
      - id: check
        if: deliveries.review.verdict == 'clean'
        then:
          - id: remember
            set:
              path: deliveries.draft.path
      - id: rounds
        while: deliveries.review.verdict != 'clean'
        max_iterations: 2
        steps:
          - id: again
            notify: "Read {{ deliveries.outline.path }} again"
      - id: broken
        notify: "Unclosed {{ deliveries.draft.path"
    """
}
