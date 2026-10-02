import Testing

@testable import supacode

struct ReleaseActionLabelTests {
  private enum OuterAction {
    case idle
    case inner(InnerAction)
    case payload(id: Int, title: String)
  }

  private enum InnerAction {
    case ready
    case deep(DeepAction)
  }

  private enum DeepAction {
    case done(worktreeID: String, added: Int, removed: Int)
  }

  @Test func nestedEnumLabelUsesCasePathWithoutPayloads() {
    let label = releaseActionLabel(
      OuterAction.inner(.deep(.done(worktreeID: "wt-1", added: 3, removed: 1)))
    )

    #expect(label == "ReleaseActionLabelTests.OuterAction.inner.deep.done")
  }

  @Test func payloadCaseDoesNotExpandAssociatedValues() {
    let label = releaseActionLabel(OuterAction.payload(id: 42, title: "repo"))

    #expect(label == "ReleaseActionLabelTests.OuterAction.payload")
  }

  @Test func payloadlessCaseKeepsTypeAndCase() {
    let label = releaseActionLabel(OuterAction.idle)

    #expect(label == "ReleaseActionLabelTests.OuterAction.idle")
  }
}
