import Testing

@testable import supacode

struct LineChangeBadgePresentationTests {
  @Test func exactCountsUseTheExistingLabels() {
    let presentation = LineChangeBadgePresentation(
      addedLines: 12,
      removedLines: 4,
      skippedUntrackedFileCount: 0
    )

    #expect(presentation.addedText == "+12")
    #expect(presentation.removedText == "-4")
    #expect(presentation.incompleteCountDescription == nil)
    #expect(presentation.accessibilityLabel == "12 added lines, 4 removed lines")
  }

  @Test func incompleteCountsRemainVisibleWithoutPretendingToBeExact() {
    let presentation = LineChangeBadgePresentation(
      addedLines: 0,
      removedLines: 4,
      skippedUntrackedFileCount: 1
    )

    #expect(presentation.addedText == "+…")
    #expect(presentation.removedText == "-4")
    #expect(
      presentation.incompleteCountDescription
        == "Addition count is incomplete because 1 untracked file was not counted."
    )
    #expect(
      presentation.accessibilityLabel
        == "Addition count incomplete, 0 lines counted; 1 untracked file was not counted. 4 removed lines."
    )
  }

  @Test func incompleteNonzeroCountsShowTheirKnownLowerBound() {
    let presentation = LineChangeBadgePresentation(
      addedLines: 12,
      removedLines: 4,
      skippedUntrackedFileCount: 2
    )

    #expect(presentation.addedText == "+12…")
    #expect(
      presentation.incompleteCountDescription
        == "Addition count is incomplete because 2 untracked files were not counted."
    )
  }
}
