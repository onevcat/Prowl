import Testing

@testable import supacode

struct WorktreeLoadingInfoTests {
  @Test func statusSubtitleUsesLatestFiveOutputLines() {
    let info = WorktreeLoadingInfo(
      name: "feature",
      repositoryName: "Prowl",
      state: .creating,
      statusTitle: "Creating worktree",
      statusDetail: "Preparing worktree",
      statusCommand: "git worktree add",
      statusLines: ["one", "two", "three", "four", "five", "six"]
    )

    #expect(info.statusSubtitle == "two\nthree\nfour\nfive\nsix")
  }

  @Test func statusSubtitleFallsBackToProgressDetailBeforeTitle() {
    let info = WorktreeLoadingInfo(
      name: "feature",
      repositoryName: "Prowl",
      state: .creating,
      statusTitle: "Creating worktree",
      statusDetail: "Preparing worktree",
      statusCommand: nil,
      statusLines: []
    )

    #expect(info.statusSubtitle == "Preparing worktree")
  }

  @Test func removingPlainFolderUsesFolderNounWithoutRepositorySuffix() {
    let info = WorktreeLoadingInfo(
      name: "Documents",
      repositoryName: "Documents",
      state: .removing,
      isFolder: true,
      statusTitle: nil,
      statusDetail: nil,
      statusCommand: nil,
      statusLines: []
    )

    #expect(info.statusSubtitle == "Removing folder...")
  }
}
