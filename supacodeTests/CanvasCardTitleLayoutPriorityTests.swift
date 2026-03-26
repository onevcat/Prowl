import Testing

@testable import supacode

struct CanvasCardTitleLayoutPriorityTests {
  @Test func titleSegmentPrioritiesAreRepo3Dir2Worktree1() {
    #expect(CanvasCardTitleLayoutPriority.repositoryName == 3)
    #expect(CanvasCardTitleLayoutPriority.currentDirectory == 2)
    #expect(CanvasCardTitleLayoutPriority.worktreeName == 1)
  }

  @Test func compressionOrderDeclaresWorktreeBeforeDirectoryUnderPressure() {
    #expect(CanvasCardTitleLayoutPriority.compressionOrder == [.worktreeName, .currentDirectory, .repositoryName])
  }

  @Test func fixedWidthCaseABoundaryPrefersSegment3TruncationFirst() {
    let allocation = CanvasCardTitleLayoutPriority.allocation(
      repositoryName: "repo",
      currentDirectory: "~/project/src",
      worktreeName: "feature-worktree",
      maxCharacters: 29
    )

    #expect(allocation.repositoryCharacters == "repo".count)
    #expect(allocation.currentDirectoryCharacters == "~/project/src".count)
    #expect(allocation.worktreeCharacters == "feature-worktree".count - 6)
  }

  @Test func fixedWidthCaseBNarrowKeepsSegment2ShortenedFormWhileSegment3TruncatesMore() {
    let allocation = CanvasCardTitleLayoutPriority.allocation(
      repositoryName: "repo",
      currentDirectory: "~/pr/src",
      worktreeName: "feature-worktree",
      maxCharacters: 15
    )

    #expect(allocation.repositoryCharacters == "repo".count)
    #expect(allocation.currentDirectoryCharacters == "~/pr/src".count)
    #expect(allocation.worktreeCharacters == 1)
  }

  @Test func fixedWidthCaseCWideKeepsExpectedFullVisibility() {
    let allocation = CanvasCardTitleLayoutPriority.allocation(
      repositoryName: "repo",
      currentDirectory: "~/pr/src",
      worktreeName: "feature-worktree",
      maxCharacters: 80
    )

    #expect(allocation.repositoryCharacters == "repo".count)
    #expect(allocation.currentDirectoryCharacters == "~/pr/src".count)
    #expect(allocation.worktreeCharacters == "feature-worktree".count)
  }
}
