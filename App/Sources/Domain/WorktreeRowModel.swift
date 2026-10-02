import Foundation

struct WorktreeRowModel: Identifiable, Hashable {
  let id: String
  let repositoryID: Repository.ID
  let name: String
  let detail: String
  let info: WorktreeInfoEntry?
  let isPinned: Bool
  let isMainWorktree: Bool
  let isPending: Bool
  let isArchiving: Bool
  let isDeleting: Bool
  let isRemovable: Bool
}
