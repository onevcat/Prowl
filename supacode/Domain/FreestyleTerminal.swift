import Foundation

enum FreestyleTerminal {
  static let worktreeID: Worktree.ID = "__freestyle__"
  static let repositoryName = "System"
  static let displayName = "Freestyle"

  static func worktree(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Worktree {
    Worktree(
      id: worktreeID,
      name: displayName,
      detail: "~",
      workingDirectory: homeDirectory,
      repositoryRootURL: homeDirectory
    )
  }
}
