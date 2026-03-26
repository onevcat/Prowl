import ComposableArchitecture
import Foundation
import IdentifiedCollections

extension RepositoriesFeature.State {
  var selectedWorktreeID: Worktree.ID? {
    selection?.worktreeID
  }

  var canNavigateWorktreeHistoryBackward: Bool {
    guard canUseWorktreeHistory else { return false }
    return canNavigateWorktreeHistory(stack: worktreeHistoryBackStack)
  }

  var canNavigateWorktreeHistoryForward: Bool {
    guard canUseWorktreeHistory else { return false }
    return canNavigateWorktreeHistory(stack: worktreeHistoryForwardStack)
  }

  var selectedRepositoryID: Repository.ID? {
    guard case .repository(let repositoryID) = selection else { return nil }
    return repositoryID
  }

  var selectedRepository: Repository? {
    guard let selectedRepositoryID else { return nil }
    return repositories[id: selectedRepositoryID]
  }

  var selectedTerminalWorktree: Worktree? {
    if let selectedWorktreeID {
      return worktree(for: selectedWorktreeID)
    }
    guard let selectedRepository,
      selectedRepository.capabilities.supportsRunnableFolderActions,
      !selectedRepository.capabilities.supportsWorktrees
    else {
      return nil
    }
    return Worktree(
      id: selectedRepository.id,
      name: selectedRepository.name,
      detail: selectedRepository.rootURL.path(percentEncoded: false),
      workingDirectory: selectedRepository.rootURL,
      repositoryRootURL: selectedRepository.rootURL
    )
  }

  var terminalStateIDs: Set<Worktree.ID> {
    Set(
      repositories.flatMap { repository -> [Worktree.ID] in
        if repository.capabilities.supportsWorktrees {
          repository.worktrees.map(\.id)
        } else if repository.capabilities.supportsRunnableFolderActions {
          [repository.id]
        } else {
          []
        }
      }
    )
  }

  var expandedRepositoryIDs: Set<Repository.ID> {
    let repositoryIDs = Set(repositories.map(\.id))
    let collapsedSet = Set(collapsedRepositoryIDs).intersection(repositoryIDs)
    let pendingRepositoryIDs = Set(pendingWorktrees.map(\.repositoryID))
    return repositoryIDs.subtracting(collapsedSet).union(pendingRepositoryIDs)
  }

  func worktreeID(byOffset offset: Int) -> Worktree.ID? {
    let rows = orderedWorktreeRows(includingRepositoryIDs: expandedRepositoryIDs)
    guard !rows.isEmpty else { return nil }
    if let currentID = selectedWorktreeID,
      let currentIndex = rows.firstIndex(where: { $0.id == currentID })
    {
      return rows[(currentIndex + offset + rows.count) % rows.count].id
    }
    return rows[offset > 0 ? 0 : rows.count - 1].id
  }

  var isShowingArchivedWorktrees: Bool {
    selection == .archivedWorktrees
  }

  var isShowingCanvas: Bool {
    selection == .canvas
  }

  var isShowingFreestyle: Bool {
    selection == .freestyle
  }

  var isShowingShelf: Bool {
    // Shelf needs at least one repository to render. Guarding here (not just
    // on entry) also covers the launch race where the repository snapshot
    // briefly repopulates books and flips `isShelfActive` on before the empty
    // entries file reconciles repos back to zero — without this a zero-repo
    // launch with "Default View = Shelf" would stick on an empty Shelf instead
    // of falling back to Normal.
    isShelfActive && !repositories.isEmpty
  }

  var topSegment: TopSegment {
    if isShowingCanvas { return .canvas }
    if isShowingFreestyle { return .freestyle }
    if isShowingShelf { return .shelf }
    return .tabbed
  }

  private var canUseWorktreeHistory: Bool {
    // History navigation only makes sense when a worktree is the current
    // anchor. With selection on `.repository`, `.archivedWorktrees`, or `nil`,
    // there is no "current" position to step away from, so the menu items
    // (and their shortcuts) must be disabled.
    !isShowingShelf && !isShowingCanvas && !isShowingFreestyle && selectedWorktreeID != nil
  }

  var archivedWorktreeIDSet: Set<Worktree.ID> {
    Set(archivedWorktrees.map(\.id))
  }

  func isWorktreeArchived(_ id: Worktree.ID) -> Bool {
    archivedWorktreeIDSet.contains(id)
  }

  private func canNavigateWorktreeHistory(stack: [Worktree.ID]) -> Bool {
    stack.reversed().contains { id in
      id != selectedWorktreeID && isSelectionValid(id, state: self)
    }
  }

  func worktreeInfo(for worktreeID: Worktree.ID) -> WorktreeInfoEntry? {
    worktreeInfoByID[worktreeID]
  }

  func codeHost(for repositoryID: Repository.ID) -> CodeHost {
    codeHostByRepositoryID[repositoryID] ?? .unknown
  }

  func codeHost(forWorktreeID worktreeID: Worktree.ID?) -> CodeHost {
    guard let worktreeID, let repositoryID = repositoryID(containing: worktreeID) else {
      return .unknown
    }
    return codeHost(for: repositoryID)
  }

  func worktreesForInfoWatcher() -> [Worktree] {
    let worktrees = repositories.flatMap(\.worktrees)
    guard !isShowingArchivedWorktrees else {
      return worktrees
    }
    let archivedSet = archivedWorktreeIDSet
    return worktrees.filter { !archivedSet.contains($0.id) }
  }

  struct ArchivedWorktreeGroup: Equatable {
    var repository: Repository
    var worktrees: [Worktree]
  }

  func archivedWorktreesByRepository() -> [ArchivedWorktreeGroup] {
    let archivedSet = archivedWorktreeIDSet
    var groups: [ArchivedWorktreeGroup] = []
    for repository in repositories {
      let worktrees = Array(repository.worktrees.filter { archivedSet.contains($0.id) })
      if !worktrees.isEmpty {
        groups.append(ArchivedWorktreeGroup(repository: repository, worktrees: worktrees))
      }
    }
    return groups
  }

  var canCreateWorktree: Bool {
    if repositories.isEmpty {
      return false
    }
    if let repository = repositoryForWorktreeCreation(self) {
      return !removingRepositoryIDs.contains(repository.id)
    }
    return false
  }

  func worktree(for id: Worktree.ID?) -> Worktree? {
    guard let id else { return nil }
    for repository in repositories {
      if let worktree = repository.worktrees[id: id] {
        return worktree
      }
    }
    return nil
  }

  func canvasNavigationWorktree(forRepositoryID repositoryID: Repository.ID) -> Worktree? {
    guard let repository = repositories[id: repositoryID] else { return nil }
    if repository.capabilities.supportsWorktrees {
      return worktreeRows(in: repository)
        .compactMap { worktree(for: $0.id) }
        .first
    }
    guard repository.capabilities.supportsRunnableFolderActions else { return nil }
    return Worktree(
      id: repository.id,
      name: repository.name,
      detail: repository.rootURL.path(percentEncoded: false),
      workingDirectory: repository.rootURL,
      repositoryRootURL: repository.rootURL
    )
  }

  func pendingWorktree(for id: Worktree.ID?) -> PendingWorktree? {
    guard let id else { return nil }
    return pendingWorktrees.first(where: { $0.id == id })
  }

  func archiveScriptProgress(for id: Worktree.ID?) -> ArchiveScriptProgress? {
    guard let id else { return nil }
    return archiveScriptProgressByWorktreeID[id]
  }

  func shouldFocusTerminal(for worktreeID: Worktree.ID) -> Bool {
    pendingTerminalFocusWorktreeIDs.contains(worktreeID)
  }

  private func makePendingWorktreeRow(_ pending: PendingWorktree) -> WorktreeRowModel {
    let isDeleting = removingRepositoryIDs.contains(pending.repositoryID)
    return WorktreeRowModel(
      id: pending.id,
      repositoryID: pending.repositoryID,
      name: pending.progress.titleText,
      detail: pending.progress.detailText,
      info: worktreeInfo(for: pending.id),
      isPinned: false,
      isMainWorktree: false,
      isPending: true,
      isArchiving: false,
      isDeleting: isDeleting,
      isRemovable: false
    )
  }

  private func makeWorktreeRow(
    _ worktree: Worktree,
    repositoryID: Repository.ID,
    isPinned: Bool,
    isMainWorktree: Bool
  ) -> WorktreeRowModel {
    let isDeleting =
      removingRepositoryIDs.contains(repositoryID)
      || deletingWorktreeIDs.contains(worktree.id)
    let isArchiving = archivingWorktreeIDs.contains(worktree.id)
    return WorktreeRowModel(
      id: worktree.id,
      repositoryID: repositoryID,
      name: worktree.name,
      detail: worktree.detail,
      info: worktreeInfo(for: worktree.id),
      isPinned: isPinned,
      isMainWorktree: isMainWorktree,
      isPending: false,
      isArchiving: isArchiving,
      isDeleting: isDeleting,
      isRemovable: !isDeleting && !isArchiving
    )
  }

  func selectedRow(for id: Worktree.ID?) -> WorktreeRowModel? {
    guard let id else { return nil }
    if isWorktreeArchived(id) {
      return nil
    }
    if let pending = pendingWorktree(for: id) {
      return makePendingWorktreeRow(pending)
    }
    for repository in repositories {
      if let worktree = repository.worktrees[id: id] {
        return makeWorktreeRow(
          worktree,
          repositoryID: repository.id,
          isPinned: pinnedWorktreeIDs.contains(worktree.id),
          isMainWorktree: isMainWorktree(worktree)
        )
      }
    }
    return nil
  }

  func repositoryName(for id: Repository.ID) -> String? {
    repositories[id: id]?.name
  }

  func orderedRepositoryRoots() -> [URL] {
    let rootsByID = Dictionary(
      uniqueKeysWithValues: repositoryRoots.map {
        ($0.standardizedFileURL.path(percentEncoded: false), $0.standardizedFileURL)
      }
    )
    var ordered: [URL] = []
    var seen: Set<Repository.ID> = []
    for id in repositoryOrderIDs {
      if let rootURL = rootsByID[id], seen.insert(id).inserted {
        ordered.append(rootURL)
      }
    }
    for rootURL in repositoryRoots {
      let id = rootURL.standardizedFileURL.path(percentEncoded: false)
      if seen.insert(id).inserted {
        ordered.append(rootURL.standardizedFileURL)
      }
    }
    if ordered.isEmpty {
      ordered = repositories.map(\.rootURL)
    }
    return ordered
  }

  func orderedRepositoryIDs() -> [Repository.ID] {
    orderedRepositoryRoots().map { $0.standardizedFileURL.path(percentEncoded: false) }
  }

  func repositoryID(for worktreeID: Worktree.ID?) -> Repository.ID? {
    selectedRow(for: worktreeID)?.repositoryID
  }

  func repositoryID(containing worktreeID: Worktree.ID) -> Repository.ID? {
    for repository in repositories where repository.worktrees[id: worktreeID] != nil {
      return repository.id
    }
    return nil
  }

  func isMainWorktree(_ worktree: Worktree) -> Bool {
    worktree.isMain
  }

  func isWorktreeMerged(_ worktree: Worktree) -> Bool {
    worktreeInfoByID[worktree.id]?.pullRequest?.state == "MERGED"
  }

  func orderedPinnedWorktreeIDs(in repository: Repository) -> [Worktree.ID] {
    let archivedSet = archivedWorktreeIDSet
    return pinnedWorktreeIDs.filter { id in
      if archivedSet.contains(id) {
        return false
      }
      if let worktree = repository.worktrees[id: id] {
        return !isMainWorktree(worktree)
      }
      return false
    }
  }

  func orderedPinnedWorktrees(in repository: Repository) -> [Worktree] {
    orderedPinnedWorktreeIDs(in: repository).compactMap { repository.worktrees[id: $0] }
  }

  func replacingPinnedWorktreeIDs(
    in repository: Repository,
    with reordered: [Worktree.ID]
  ) -> [Worktree.ID] {
    let repoPinnedIDs = Set(orderedPinnedWorktreeIDs(in: repository))
    var iterator = reordered.makeIterator()
    return pinnedWorktreeIDs.map { id in
      if repoPinnedIDs.contains(id) {
        return iterator.next() ?? id
      }
      return id
    }
  }

  func orderedUnpinnedWorktreeIDs(in repository: Repository) -> [Worktree.ID] {
    let mainID = repository.worktrees.first(where: { isMainWorktree($0) })?.id
    let pinnedSet = Set(pinnedWorktreeIDs)
    let archivedSet = archivedWorktreeIDSet
    let available = repository.worktrees.filter { worktree in
      worktree.id != mainID
        && !pinnedSet.contains(worktree.id)
        && !archivedSet.contains(worktree.id)
    }
    let orderedIDs = worktreeOrderByRepository[repository.id] ?? []
    let availableIDs = Set(available.map(\.id))
    let orderedIDSet = Set(orderedIDs)
    var seen: Set<Worktree.ID> = []
    var missing: [Worktree.ID] = []
    for worktree in available where !orderedIDSet.contains(worktree.id) {
      if seen.insert(worktree.id).inserted {
        missing.append(worktree.id)
      }
    }
    var ordered: [Worktree.ID] = []
    for id in orderedIDs {
      if availableIDs.contains(id),
        seen.insert(id).inserted
      {
        ordered.append(id)
      }
    }
    return missing + ordered
  }

  func orderedUnpinnedWorktrees(in repository: Repository) -> [Worktree] {
    orderedUnpinnedWorktreeIDs(in: repository).compactMap { repository.worktrees[id: $0] }
  }

  func orderedWorktrees(in repository: Repository) -> [Worktree] {
    var ordered: [Worktree] = []
    if let mainWorktree = repository.worktrees.first(where: { isMainWorktree($0) }) {
      if !isWorktreeArchived(mainWorktree.id) {
        ordered.append(mainWorktree)
      }
    }
    ordered.append(contentsOf: orderedPinnedWorktrees(in: repository))
    ordered.append(contentsOf: orderedUnpinnedWorktrees(in: repository))
    return ordered
  }

  func isWorktreePinned(_ worktree: Worktree) -> Bool {
    pinnedWorktreeIDs.contains(worktree.id)
  }

  var confirmWorktreeAlert: RepositoriesFeature.Alert? {
    guard let alert else { return nil }
    for button in alert.buttons {
      if case .confirmArchiveWorktree(let worktreeID, let repositoryID)? = button.action.action {
        return .confirmArchiveWorktree(worktreeID, repositoryID)
      }
      if case .confirmArchiveWorktrees(let targets)? = button.action.action {
        return .confirmArchiveWorktrees(targets)
      }
    }
    return nil
  }

  /// Hashable projection of `confirmWorktreeAlert`, used as a `FocusedAction`
  /// token so the confirm command republishes only when the pending alert's
  /// targets actually change rather than on every view body run.
  var confirmWorktreeActionToken: [Worktree.ID]? {
    switch confirmWorktreeAlert {
    case .confirmArchiveWorktree(let worktreeID, _):
      return [worktreeID]
    case .confirmArchiveWorktrees(let targets):
      return targets.map(\.worktreeID)
    default:
      return nil
    }
  }

  func isRemovingRepository(_ repository: Repository) -> Bool {
    removingRepositoryIDs.contains(repository.id)
  }

  func worktreeRowSections(in repository: Repository) -> WorktreeRowSections {
    let mainWorktree = repository.worktrees.first(where: { isMainWorktree($0) })
    let pinnedWorktrees = orderedPinnedWorktrees(in: repository)
    let unpinnedWorktrees = orderedUnpinnedWorktrees(in: repository)
    let pendingEntries = pendingWorktrees.filter { $0.repositoryID == repository.id }
    let mainRow: WorktreeRowModel? =
      if let mainWorktree, !isWorktreeArchived(mainWorktree.id) {
        makeWorktreeRow(
          mainWorktree,
          repositoryID: repository.id,
          isPinned: false,
          isMainWorktree: true
        )
      } else {
        nil
      }
    var pinnedRows: [WorktreeRowModel] = []
    for worktree in pinnedWorktrees {
      pinnedRows.append(
        makeWorktreeRow(
          worktree,
          repositoryID: repository.id,
          isPinned: true,
          isMainWorktree: false
        )
      )
    }
    var pendingRows: [WorktreeRowModel] = []
    for pending in pendingEntries {
      pendingRows.append(makePendingWorktreeRow(pending))
    }
    var unpinnedRows: [WorktreeRowModel] = []
    for worktree in unpinnedWorktrees {
      unpinnedRows.append(
        makeWorktreeRow(
          worktree,
          repositoryID: repository.id,
          isPinned: false,
          isMainWorktree: false
        )
      )
    }
    return WorktreeRowSections(
      main: mainRow,
      pinned: pinnedRows,
      pending: pendingRows,
      unpinned: unpinnedRows
    )
  }

  func worktreeRows(in repository: Repository) -> [WorktreeRowModel] {
    let sections = worktreeRowSections(in: repository)
    return sections.allRows
  }

  func orderedWorktreeRows() -> [WorktreeRowModel] {
    orderedWorktreeRows(includingRepositoryIDs: Set(repositories.map(\.id)))
  }

  func orderedWorktreeRows(includingRepositoryIDs: Set<Repository.ID>) -> [WorktreeRowModel] {
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    return orderedRepositoryIDs()
      .filter { includingRepositoryIDs.contains($0) }
      .compactMap { repositoriesByID[$0] }
      .flatMap { worktreeRows(in: $0) }
  }
}

struct WorktreeRowSections: Equatable {
  let main: WorktreeRowModel?
  let pinned: [WorktreeRowModel]
  let pending: [WorktreeRowModel]
  let unpinned: [WorktreeRowModel]

  var allRows: [WorktreeRowModel] {
    var rows: [WorktreeRowModel] = []
    if let main {
      rows.append(main)
    }
    rows.append(contentsOf: pinned)
    rows.append(contentsOf: pending)
    rows.append(contentsOf: unpinned)
    return rows
  }
}
