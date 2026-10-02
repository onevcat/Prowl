import Foundation

nonisolated struct ArchivedWorktree: Codable, Equatable, Sendable, Identifiable {
  let id: Worktree.ID
  let archivedAt: Date
}
