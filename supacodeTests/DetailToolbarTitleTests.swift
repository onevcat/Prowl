import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

struct DetailToolbarTitleTests {
  @Test func branchSelectionUsesBranchTitle() {
    let worktree = Worktree(
      id: "/tmp/repo/main",
      name: "feature/title-bar",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/main"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    let title = DetailToolbarTitle.forSelection(
      worktree: worktree,
      repository: nil
    )

    #expect(title?.kind == .branch(name: "feature/title-bar"))
    #expect(title?.systemImage == "arrow.trianglehead.branch")
    #expect(title?.supportsRename == true)
  }

  @Test func plainFolderSelectionUsesFolderTitle() {
    let repository = Repository(
      id: "/tmp/folder",
      rootURL: URL(fileURLWithPath: "/tmp/folder"),
      name: "folder",
      kind: .plain,
      worktrees: []
    )

    let title = DetailToolbarTitle.forSelection(
      worktree: nil,
      repository: repository
    )

    #expect(title?.kind == .folder(name: "folder"))
    #expect(title?.systemImage == "folder")
    #expect(title?.supportsRename == false)
  }

  @Test func workspaceSelectionUsesWorkspaceTitle() {
    let repository = Repository(
      id: "/tmp/workspace",
      rootURL: URL(fileURLWithPath: "/tmp/workspace"),
      name: "workspace",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "workspace")
    )

    let title = DetailToolbarTitle.forSelection(
      worktree: nil,
      repository: repository
    )

    #expect(title?.kind == .workspace(name: "workspace"))
    #expect(title?.systemImage == "folder.badge.person.crop")
    #expect(title?.supportsRename == false)
  }
}
