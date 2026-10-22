import Foundation
import IdentifiedCollections

@testable import Prowl

/// Remote repositories for tests of the remote-folder gates (docs-ai 084).
enum RemoteRepositoryFixtures {
  static let hostProfileID = UUID(uuidString: "5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42")!

  static func location(_ path: String) -> RepositoryLocation {
    .remote(hostProfileID: hostProfileID, path: path)
  }

  /// A git repository whose only worktree is its root.
  static func gitRepository(path: String = "/home/dev/app", name: String = "app") -> Repository {
    let root = location(path)
    let main = Worktree(name: "main", detail: "", location: root, repositoryLocation: root)
    return Repository(location: root, name: name, worktrees: [main])
  }

  /// A plain folder; it reaches terminals through `Repository.terminalWorktree`.
  static func plainFolder(path: String = "/home/dev/notes", name: String = "notes") -> Repository {
    Repository(location: location(path), name: name, kind: .plain, worktrees: [])
  }
}
