import ComposableArchitecture
import Foundation

func queuePullRequestRefresh(
  repositoryID: Repository.ID,
  repositoryRootURL: URL,
  worktreeIDs: [Worktree.ID],
  refreshesByRepositoryID: inout [Repository.ID: RepositoriesFeature.PendingPullRequestRefresh]
) {
  if var pending = refreshesByRepositoryID[repositoryID] {
    var seenWorktreeIDs = Set(pending.worktreeIDs)
    for worktreeID in worktreeIDs where seenWorktreeIDs.insert(worktreeID).inserted {
      pending.worktreeIDs.append(worktreeID)
    }
    refreshesByRepositoryID[repositoryID] = pending
  } else {
    refreshesByRepositoryID[repositoryID] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: repositoryRootURL,
      worktreeIDs: worktreeIDs
    )
  }
}

func reorderedUnpinnedWorktreeIDs(
  for worktreeID: Worktree.ID,
  in repository: Repository,
  state: RepositoriesFeature.State
) -> [Worktree.ID] {
  var ordered = state.orderedUnpinnedWorktreeIDs(in: repository)
  guard let index = ordered.firstIndex(of: worktreeID) else {
    return ordered
  }
  ordered.remove(at: index)
  ordered.insert(worktreeID, at: 0)
  return ordered
}

func restoreSelection(
  _ id: Worktree.ID?,
  pendingID: Worktree.ID,
  state: inout RepositoriesFeature.State
) {
  guard state.selection == .worktree(pendingID) else { return }
  setSingleWorktreeSelection(
    isSelectionValid(id, state: state) ? id : nil,
    state: &state,
    recordHistory: false
  )
  pruneWorktreeHistoryTails(state: &state)
}

func isSelectionValid(
  _ id: Worktree.ID?,
  state: RepositoriesFeature.State
) -> Bool {
  state.selectedRow(for: id) != nil
}

/// Choose the next book to open after `worktreeID`'s book is retired.
/// Prefer the book immediately *after* the closed one in Shelf order;
/// fall back to the one immediately *before* it; return `nil` when
/// Shelf is inactive, when the closed book isn't the currently open
/// one, or when no other books remain.
func replacementBookAfterClosing(
  worktreeID: Worktree.ID,
  state: RepositoriesFeature.State
) -> ShelfBook? {
  guard state.isShelfActive,
    state.selectedTerminalWorktree?.id == worktreeID
  else { return nil }
  let books = state.orderedShelfBooks()
  guard let index = books.firstIndex(where: { $0.id == worktreeID }) else {
    return nil
  }
  let remaining = books.enumerated().filter { $0.offset != index }.map(\.element)
  guard !remaining.isEmpty else { return nil }
  // After removing index `index`, the "next" book is now at position
  // `index` in the reduced list (if it exists); otherwise the last one
  // is the "previous" relative to what was closed.
  if index < remaining.count {
    return remaining[index]
  }
  return remaining.last
}

/// Returns the Shelf book at `offset` positions from the currently open
/// book (wrapping around the book list). Returns nil if there are no
/// books. When there is no open book, offset > 0 picks the first book
/// and offset < 0 picks the last.
func shelfBook(
  atOffset offset: Int,
  state: RepositoriesFeature.State
) -> ShelfBook? {
  let books = state.orderedShelfBooks()
  guard !books.isEmpty else { return nil }
  if let currentID = state.openShelfBookID,
    let currentIndex = books.firstIndex(where: { $0.id == currentID })
  {
    let nextIndex = (currentIndex + offset + books.count) % books.count
    return books[nextIndex]
  }
  return offset > 0 ? books.first : books.last
}

/// Dispatches the right selection action for a book — a worktree vs.
/// a plain folder requires different Reducer actions even though the
/// Shelf treats them uniformly.
func shelfBookSelectionEffect(
  for book: ShelfBook
) -> Effect<RepositoriesFeature.Action> {
  switch book.kind {
  case .worktree:
    return .send(.selectWorktree(book.id, focusTerminal: true, recordHistory: false))
  case .plainFolder:
    return .send(.selectRepository(book.repositoryID))
  }
}

func isSidebarSelectionValid(
  _ selection: SidebarSelection?,
  state: RepositoriesFeature.State
) -> Bool {
  switch selection {
  case .worktree(let id):
    return isSelectionValid(id, state: state)
  case .repository(let id):
    return state.repositories[id: id] != nil
  case .archivedWorktrees, .canvas:
    return true
  case nil:
    return false
  }
}

func setSingleWorktreeSelection(
  _ worktreeID: Worktree.ID?,
  state: inout RepositoriesFeature.State,
  recordHistory: Bool = false
) {
  if recordHistory {
    recordWorktreeHistoryTransition(from: state.selectedWorktreeID, to: worktreeID, state: &state)
  }
  state.selection = worktreeID.map(SidebarSelection.worktree)
  state.selectedWorkspaceChildID = nil
  if let worktreeID {
    state.sidebarSelectedWorktreeIDs = [worktreeID]
  } else {
    state.sidebarSelectedWorktreeIDs = []
  }
}

enum WorktreeHistoryDirection {
  case backward
  case forward
}

private let worktreeHistoryStackLimit = 50

func navigateWorktreeHistory(
  direction: WorktreeHistoryDirection,
  state: inout RepositoriesFeature.State
) -> Effect<RepositoriesFeature.Action> {
  guard !state.isShowingShelf, !state.isShowingCanvas else { return .none }
  guard let currentID = state.selectedWorktreeID else { return .none }
  var sourceStack =
    direction == .backward
    ? state.worktreeHistoryBackStack
    : state.worktreeHistoryForwardStack
  guard let destinationID = popValidWorktreeHistoryDestination(from: &sourceStack, currentID: currentID, state: state)
  else {
    if direction == .backward {
      state.worktreeHistoryBackStack = sourceStack
    } else {
      state.worktreeHistoryForwardStack = sourceStack
    }
    return .none
  }

  if direction == .backward {
    state.worktreeHistoryBackStack = sourceStack
    pushWorktreeHistoryID(currentID, onto: &state.worktreeHistoryForwardStack)
  } else {
    state.worktreeHistoryForwardStack = sourceStack
    pushWorktreeHistoryID(currentID, onto: &state.worktreeHistoryBackStack)
  }
  setSingleWorktreeSelection(destinationID, state: &state, recordHistory: false)
  state.openedWorktreeIDs.insert(destinationID)
  // Match sidebar/arrow navigation: focus the terminal of the worktree we land on.
  state.pendingTerminalFocusWorktreeIDs.insert(destinationID)
  return .send(.delegate(.selectedWorktreeChanged(state.worktree(for: destinationID))))
}

func recordWorktreeHistoryTransition(
  from previousID: Worktree.ID?,
  to nextID: Worktree.ID?,
  state: inout RepositoriesFeature.State
) {
  // Shelf / Canvas are mode switches, not worktree navigation — leave
  // history frozen so users can resume Back/Forward where they left off.
  guard !state.isShowingShelf, !state.isShowingCanvas else { return }
  // No-op transitions (same worktree, or both endpoints nil) leave history alone.
  if previousID == nextID { return }
  // Any user-initiated selection change invalidates the redo path. Crucially
  // this also fires when the user navigates to/from .repository or
  // .archivedWorktrees (one or both IDs nil), so a stale forward stack
  // can't carry over into an unrelated path.
  state.worktreeHistoryForwardStack = []
  // Only push onto the back stack when leaving a still-valid worktree; we
  // don't want non-worktree selections (repository / archived) showing up
  // as Back targets.
  guard let previousID, isSelectionValid(previousID, state: state) else { return }
  pushWorktreeHistoryID(previousID, onto: &state.worktreeHistoryBackStack)
}

private func popValidWorktreeHistoryDestination(
  from stack: inout [Worktree.ID],
  currentID: Worktree.ID,
  state: RepositoriesFeature.State
) -> Worktree.ID? {
  while let candidateID = stack.popLast() {
    guard candidateID != currentID, isSelectionValid(candidateID, state: state) else {
      continue
    }
    return candidateID
  }
  return nil
}

private func pushWorktreeHistoryID(_ id: Worktree.ID, onto stack: inout [Worktree.ID]) {
  stack.append(id)
  if stack.count > worktreeHistoryStackLimit {
    stack.removeFirst(stack.count - worktreeHistoryStackLimit)
  }
}

func pruneWorktreeHistoryTails(state: inout RepositoriesFeature.State) {
  pruneWorktreeHistoryTail(stack: &state.worktreeHistoryBackStack, state: state)
  pruneWorktreeHistoryTail(stack: &state.worktreeHistoryForwardStack, state: state)
}

private func pruneWorktreeHistoryTail(
  stack: inout [Worktree.ID],
  state: RepositoriesFeature.State
) {
  while let last = stack.last,
    last == state.selectedWorktreeID || !isSelectionValid(last, state: state)
  {
    stack.removeLast()
  }
}

func repositoryForWorktreeCreation(
  _ state: RepositoriesFeature.State
) -> Repository? {
  if let selectedRepository = state.selectedRepository,
    selectedRepository.capabilities.supportsWorktrees
  {
    return selectedRepository
  }
  if let selectedWorktreeID = state.selectedWorktreeID {
    if let pending = state.pendingWorktree(for: selectedWorktreeID) {
      if let repository = state.repositories[id: pending.repositoryID],
        repository.capabilities.supportsWorktrees
      {
        return repository
      }
      return nil
    }
    for repository in state.repositories
    where repository.worktrees[id: selectedWorktreeID] != nil {
      if repository.capabilities.supportsWorktrees {
        return repository
      }
      return nil
    }
  }
  if state.repositories.count == 1,
    let repository = state.repositories.first,
    repository.capabilities.supportsWorktrees
  {
    return repository
  }
  return nil
}

func prunePinnedWorktreeIDs(state: inout RepositoriesFeature.State) -> Bool {
  let availableIDs = Set(state.repositories.flatMap { $0.worktrees.map(\.id) })
  let mainIDs = Set(
    state.repositories.compactMap { repository in
      repository.worktrees.first(where: { state.isMainWorktree($0) })?.id
    }
  )
  let archivedSet = state.archivedWorktreeIDSet
  let pruned = state.pinnedWorktreeIDs.filter {
    availableIDs.contains($0)
      && !mainIDs.contains($0)
      && !archivedSet.contains($0)
  }
  if pruned != state.pinnedWorktreeIDs {
    state.pinnedWorktreeIDs = pruned
    return true
  }
  return false
}

func pruneRepositoryOrderIDs(
  roots: [URL],
  state: inout RepositoriesFeature.State
) -> Bool {
  let rootIDs = roots.map { $0.standardizedFileURL.path(percentEncoded: false) }
  let availableIDs = Set(rootIDs + state.repositories.map(\.id))
  let pruned = state.repositoryOrderIDs.filter { availableIDs.contains($0) }
  if pruned != state.repositoryOrderIDs {
    state.repositoryOrderIDs = pruned
    return true
  }
  return false
}

func pruneWorktreeOrderByRepository(
  roots: [URL],
  state: inout RepositoriesFeature.State
) -> Bool {
  let rootIDs = Set(roots.map { $0.standardizedFileURL.path(percentEncoded: false) })
  let repositoriesByID = Dictionary(
    state.repositories.map { ($0.id, $0) },
    uniquingKeysWith: { first, _ in first }
  )
  let pinnedSet = Set(state.pinnedWorktreeIDs)
  let archivedSet = state.archivedWorktreeIDSet
  var pruned: [Repository.ID: [Worktree.ID]] = [:]
  for (repoID, order) in state.worktreeOrderByRepository {
    guard let repository = repositoriesByID[repoID] else {
      if rootIDs.contains(repoID), !order.isEmpty {
        pruned[repoID] = order
      }
      continue
    }
    let mainID = repository.worktrees.first(where: { state.isMainWorktree($0) })?.id
    let availableIDs = Set(repository.worktrees.map(\.id))
    var seen: Set<Worktree.ID> = []
    var filtered: [Worktree.ID] = []
    for id in order {
      if availableIDs.contains(id),
        id != mainID,
        !pinnedSet.contains(id),
        !archivedSet.contains(id),
        seen.insert(id).inserted
      {
        filtered.append(id)
      }
    }
    if !filtered.isEmpty {
      pruned[repoID] = filtered
    }
  }
  if pruned != state.worktreeOrderByRepository {
    state.worktreeOrderByRepository = pruned
    return true
  }
  return false
}

func pruneArchivedWorktrees(
  availableWorktreeIDs: Set<Worktree.ID>,
  state: inout RepositoriesFeature.State
) -> Bool {
  let pruned = state.archivedWorktrees.filter { availableWorktreeIDs.contains($0.id) }
  if pruned != state.archivedWorktrees {
    state.archivedWorktrees = pruned
    return true
  }
  return false
}

func firstAvailableWorktreeID(
  from repositories: [Repository],
  state: RepositoriesFeature.State
) -> Worktree.ID? {
  for repository in repositories {
    if let first = state.orderedWorktrees(in: repository).first {
      return first.id
    }
  }
  return nil
}

func firstAvailableWorktreeID(
  in repositoryID: Repository.ID,
  state: RepositoriesFeature.State
) -> Worktree.ID? {
  guard let repository = state.repositories[id: repositoryID] else {
    return nil
  }
  return state.orderedWorktrees(in: repository).first?.id
}

func findWorktreeAndRepository(
  worktreeID: Worktree.ID,
  state: RepositoriesFeature.State
) -> (worktree: Worktree, repository: Repository)? {
  for repository in state.repositories {
    if let worktree = repository.worktrees[id: worktreeID] {
      return (worktree, repository)
    }
  }
  return nil
}

func nextWorktreeID(
  afterRemoving worktree: Worktree,
  in repository: Repository,
  state: RepositoriesFeature.State
) -> Worktree.ID? {
  let orderedIDs = state.orderedWorktrees(in: repository).map(\.id)
  guard let index = orderedIDs.firstIndex(of: worktree.id) else { return nil }
  let nextIndex = index + 1
  if nextIndex < orderedIDs.count {
    return orderedIDs[nextIndex]
  }
  if index > 0 {
    return orderedIDs[index - 1]
  }
  return nil
}
