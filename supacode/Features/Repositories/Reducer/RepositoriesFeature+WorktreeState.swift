import Foundation
import IdentifiedCollections
import Sharing

struct FailedWorktreeCleanup {
  let didRemoveWorktree: Bool
  let didUpdatePinned: Bool
  let didUpdateOrder: Bool
  let worktree: Worktree?
}

func removePendingWorktree(_ id: String, state: inout RepositoriesFeature.State) {
  state.pendingWorktrees.removeAll { $0.id == id }
}

func requestCanvasFocus(
  _ target: CanvasFocusRequest.Target,
  openedWorktreeID: Worktree.ID,
  state: inout RepositoriesFeature.State
) {
  state.nextCanvasFocusRequestID += 1
  state.pendingCanvasFocusRequest = CanvasFocusRequest(
    id: state.nextCanvasFocusRequestID,
    target: target
  )
  state.openedWorktreeIDs.insert(openedWorktreeID)
}

func updatePendingWorktreeProgress(
  _ id: String,
  progress: WorktreeCreationProgress,
  state: inout RepositoriesFeature.State
) {
  guard let index = state.pendingWorktrees.firstIndex(where: { $0.id == id }) else {
    return
  }
  state.pendingWorktrees[index].progress = progress
}

func insertWorktree(
  _ worktree: Worktree,
  repositoryID: Repository.ID,
  state: inout RepositoriesFeature.State
) {
  guard let index = state.repositories.index(id: repositoryID) else { return }
  let repository = state.repositories[index]
  if repository.worktrees[id: worktree.id] != nil {
    return
  }
  var worktrees = repository.worktrees
  worktrees.insert(worktree, at: 0)
  state.repositories[index] = Repository(
    id: repository.id,
    rootURL: repository.rootURL,
    name: repository.name,
    worktrees: worktrees
  )
}

@discardableResult
func removeWorktree(
  _ worktreeID: Worktree.ID,
  repositoryID: Repository.ID,
  state: inout RepositoriesFeature.State
) -> Bool {
  guard let index = state.repositories.index(id: repositoryID) else { return false }
  let repository = state.repositories[index]
  guard repository.worktrees[id: worktreeID] != nil else { return false }
  var worktrees = repository.worktrees
  worktrees.remove(id: worktreeID)
  state.repositories[index] = Repository(
    id: repository.id,
    rootURL: repository.rootURL,
    name: repository.name,
    worktrees: worktrees
  )
  return true
}

func cleanupFailedWorktree(
  repositoryID: Repository.ID,
  name: String?,
  baseDirectory: URL,
  state: inout RepositoriesFeature.State
) -> FailedWorktreeCleanup {
  guard let name, !name.isEmpty else {
    return FailedWorktreeCleanup(
      didRemoveWorktree: false,
      didUpdatePinned: false,
      didUpdateOrder: false,
      worktree: nil
    )
  }
  let repositoryRootURL = URL(fileURLWithPath: repositoryID).standardizedFileURL
  let normalizedBaseDirectory = baseDirectory.standardizedFileURL
  let worktreeURL =
    normalizedBaseDirectory
    .appending(path: name, directoryHint: .isDirectory)
    .standardizedFileURL
  guard isPathInsideBaseDirectory(worktreeURL, baseDirectory: normalizedBaseDirectory) else {
    return FailedWorktreeCleanup(
      didRemoveWorktree: false,
      didUpdatePinned: false,
      didUpdateOrder: false,
      worktree: nil
    )
  }
  let worktreeID = worktreeURL.path(percentEncoded: false)
  let worktree =
    state.repositories[id: repositoryID]?.worktrees[id: worktreeID]
    ?? Worktree(
      id: worktreeID,
      name: name,
      detail: "",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL
    )
  let cleanup = cleanupWorktreeState(
    worktreeID,
    repositoryID: repositoryID,
    state: &state
  )
  return FailedWorktreeCleanup(
    didRemoveWorktree: cleanup.didRemoveWorktree,
    didUpdatePinned: cleanup.didUpdatePinned,
    didUpdateOrder: cleanup.didUpdateOrder,
    worktree: worktree
  )
}

func isPathInsideBaseDirectory(_ path: URL, baseDirectory: URL) -> Bool {
  PathPolicy.contains(path, in: baseDirectory)
}

struct WorktreeCleanupStateResult {
  let didRemoveWorktree: Bool
  let didUpdatePinned: Bool
  let didUpdateOrder: Bool
}

func cleanupWorktreeState(
  _ worktreeID: Worktree.ID,
  repositoryID: Repository.ID,
  state: inout RepositoriesFeature.State
) -> WorktreeCleanupStateResult {
  let didRemoveWorktree = removeWorktree(worktreeID, repositoryID: repositoryID, state: &state)
  state.pendingWorktrees.removeAll { $0.id == worktreeID }
  state.pendingSetupScriptWorktreeIDs.remove(worktreeID)
  state.pendingTerminalFocusWorktreeIDs.remove(worktreeID)
  state.archivingWorktreeIDs.remove(worktreeID)
  state.archiveScriptProgressByWorktreeID.removeValue(forKey: worktreeID)
  state.deletingWorktreeIDs.remove(worktreeID)
  state.worktreeInfoByID.removeValue(forKey: worktreeID)
  let didUpdatePinned = state.pinnedWorktreeIDs.contains(worktreeID)
  if didUpdatePinned {
    state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
  }
  var didUpdateOrder = false
  if var order = state.worktreeOrderByRepository[repositoryID] {
    let countBefore = order.count
    order.removeAll { $0 == worktreeID }
    if order.count != countBefore {
      didUpdateOrder = true
      if order.isEmpty {
        state.worktreeOrderByRepository.removeValue(forKey: repositoryID)
      } else {
        state.worktreeOrderByRepository[repositoryID] = order
      }
    }
  }
  return WorktreeCleanupStateResult(
    didRemoveWorktree: didRemoveWorktree,
    didUpdatePinned: didUpdatePinned,
    didUpdateOrder: didUpdateOrder
  )
}

nonisolated func archiveScriptCommand(_ script: String) -> String {
  let normalized = script.replacing("\n", with: "\\n")
  return "bash -lc \(shellQuote(normalized))"
}

func resolvedRepositoryScript(
  profileID: String?,
  inlineScript: String,
  worktree: Worktree
) -> String {
  guard let profileID else {
    return inlineScript
  }
  @Shared(.scriptProfiles) var scriptProfiles
  guard let profile = scriptProfiles.first(where: { $0.id == profileID }) else {
    return ""
  }
  return profile.terminalInvocation(environment: worktree.scriptEnvironment)
}

nonisolated func worktreeCreateCommand(
  baseDirectoryURL: URL,
  name: String,
  copyIgnored: Bool,
  copyUntracked: Bool,
  baseRef: String,
  directoryOverride: URL? = nil
) -> String {
  let baseDir = baseDirectoryURL.path(percentEncoded: false)
  var parts = ["wt", "--base-dir", baseDir, "sw"]
  if copyIgnored {
    parts.append("--copy-ignored")
  }
  if copyUntracked {
    parts.append("--copy-untracked")
  }
  if !baseRef.isEmpty {
    parts.append("--from")
    parts.append(baseRef)
  }
  if let directoryOverride {
    parts.append("--path")
    parts.append(directoryOverride.path(percentEncoded: false))
  }
  if copyIgnored || copyUntracked {
    parts.append("--verbose")
  }
  parts.append(name)
  return parts.map(shellQuote).joined(separator: " ")
}

nonisolated func shellQuote(_ value: String) -> String {
  "'\(value.replacing("'", with: "'\"'\"'"))'"
}

func updateWorktreeName(
  _ worktreeID: Worktree.ID,
  name: String,
  state: inout RepositoriesFeature.State
) {
  for index in state.repositories.indices {
    var repository = state.repositories[index]
    guard let worktreeIndex = repository.worktrees.index(id: worktreeID) else {
      continue
    }
    let worktree = repository.worktrees[worktreeIndex]
    guard worktree.name != name else {
      return
    }
    var worktrees = repository.worktrees
    worktrees[id: worktreeID] = Worktree(
      id: worktree.id,
      name: name,
      detail: worktree.detail,
      workingDirectory: worktree.workingDirectory,
      repositoryRootURL: worktree.repositoryRootURL,
      createdAt: worktree.createdAt
    )
    repository = Repository(
      id: repository.id,
      rootURL: repository.rootURL,
      name: repository.name,
      worktrees: worktrees
    )
    state.repositories[index] = repository
    return
  }
}

@discardableResult
func updateWorktreeLineChanges(
  worktreeID: Worktree.ID,
  added: Int,
  removed: Int,
  state: inout RepositoriesFeature.State
) -> Bool {
  var entry = state.worktreeInfoByID[worktreeID] ?? WorktreeInfoEntry()
  if added == 0 && removed == 0 {
    entry.addedLines = nil
    entry.removedLines = nil
  } else {
    entry.addedLines = added
    entry.removedLines = removed
  }
  let previousEntry = state.worktreeInfoByID[worktreeID]
  if entry.isEmpty {
    guard previousEntry != nil else {
      return false
    }
    state.worktreeInfoByID.removeValue(forKey: worktreeID)
    return true
  }
  guard previousEntry != entry else {
    return false
  }
  state.worktreeInfoByID[worktreeID] = entry
  return true
}

func updateWorktreePullRequest(
  worktreeID: Worktree.ID,
  pullRequest: GithubPullRequest?,
  state: inout RepositoriesFeature.State
) {
  var entry = state.worktreeInfoByID[worktreeID] ?? WorktreeInfoEntry()
  entry.pullRequest = pullRequest
  if entry.isEmpty {
    state.worktreeInfoByID.removeValue(forKey: worktreeID)
  } else {
    state.worktreeInfoByID[worktreeID] = entry
  }
}

nonisolated func normalizedLineChanges(_ entry: WorktreeInfoEntry?) -> (added: Int, removed: Int)? {
  guard let added = entry?.addedLines, let removed = entry?.removedLines else {
    return nil
  }
  return normalizedLineChanges(added: added, removed: removed)
}

nonisolated func normalizedLineChanges(
  added: Int,
  removed: Int
) -> (added: Int, removed: Int)? {
  guard added != 0 || removed != 0 else {
    return nil
  }
  return (added, removed)
}

nonisolated func lineChangesEqual(
  _ lhs: (added: Int, removed: Int)?,
  _ rhs: (added: Int, removed: Int)?
) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil):
    return true
  case (.some(let lhs), .some(let rhs)):
    return lhs.added == rhs.added && lhs.removed == rhs.removed
  default:
    return false
  }
}
