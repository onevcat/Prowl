import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeIsMainTests {
  @Test func identicalURLsAreMain() {
    let root = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: ".",
      workingDirectory: root,
      repositoryRootURL: root,
    )
    #expect(worktree.isMain == true)
  }

  @Test func subdirectoryWorktreeIsNotMain() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature",
      detail: "wt-1",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    #expect(worktree.isMain == false)
  }

  @Test func siblingWorktreeIsNotMain() {
    let worktree = Worktree(
      id: "/tmp/repo.wt/feature",
      name: "feature",
      detail: "../repo.wt/feature",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo.wt/feature"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    #expect(worktree.isMain == false)
  }

  @Test func dotComponentEquivalentURLsAreMain() {
    // `/tmp/./repo` and `/tmp/repo` are semantically the same directory.
    // The standardization fallback in Worktree.init covers this case even
    // if the caller forgot to normalize the URL beforehand.
    let worktree = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: ".",
      workingDirectory: URL(fileURLWithPath: "/tmp/./repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    #expect(worktree.isMain == true)
  }

  @Test func dotDotComponentEquivalentURLsAreMain() {
    let worktree = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: ".",
      workingDirectory: URL(fileURLWithPath: "/tmp/nested/../repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    #expect(worktree.isMain == true)
  }
}
