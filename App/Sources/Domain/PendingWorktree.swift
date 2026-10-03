import Foundation

struct PendingWorktree: Identifiable, Hashable {
  let id: String
  let repositoryID: Repository.ID
  var progress: WorktreeCreationProgress
}
