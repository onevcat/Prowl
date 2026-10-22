import Foundation
import IdentifiedCollections
import Testing

@testable import Prowl

@MainActor
struct WorktreeTerminalStateRepositoryIDTests {
  @Test func repositoryIDIsTheRepositoryIDOfItsWorktree() {
    // `/tmp` is a symlink on macOS. The ID must not resolve it, because
    // repository IDs keep the path as the user added it.
    let rootURL = URL(fileURLWithPath: "/tmp/prowl-repository-id-\(UUID().uuidString)")
    let repository = Repository(location: .local(rootURL), name: "repo", worktrees: [])
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        name: "feature",
        detail: "",
        location: .local(rootURL.appending(path: "feature")),
        repositoryLocation: repository.location
      )
    )

    #expect(state.repositoryID == repository.id)
    #expect(state.repositoryID.hasPrefix("/tmp/"))
  }
}
