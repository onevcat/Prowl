import Foundation
import Sharing

struct SidebarPresentation: Equatable {
  var items: [SidebarItem]

  static func showsListHeader(repositoryCount: Int) -> Bool {
    true
  }

  /// The keys of the shown top-level entries in order: repository IDs and group keys.
  /// Repository drop offsets index this list (docs-ai 086).
  var topLevelKeys: [String] {
    items.compactMap(\.topLevelKey)
  }
}

enum SidebarItem: Equatable, Identifiable {
  case listHeader(SidebarListHeaderModel)
  case repository(SidebarRepositoryContainerModel)
  case failedRepository(FailedRepositoryModel)
  case group(SidebarGroupModel)
  case archivedWorktrees(ArchivedWorktreesRowModel)

  var id: SidebarPresentationItemID {
    switch self {
    case .listHeader:
      return .listHeader
    case .repository(let model):
      return .repository(model.id)
    case .failedRepository(let model):
      return .failedRepository(model.id)
    case .group(let model):
      return .group(model.id)
    case .archivedWorktrees:
      return .archivedWorktrees
    }
  }

  var topLevelKey: String? {
    switch self {
    case .repository(let model):
      return model.id
    case .failedRepository(let model) where model.isReorderable:
      return model.id
    case .group(let model):
      return SidebarLayoutItem.groupKey(model.id)
    case .listHeader, .failedRepository, .archivedWorktrees:
      return nil
    }
  }
}

enum SidebarPresentationItemID: Equatable, Hashable {
  case listHeader
  case repository(Repository.ID)
  case failedRepository(Repository.ID)
  case group(RepositoryGroup.ID)
  case archivedWorktrees
}

enum SidebarScrollID: Equatable, Hashable, Sendable {
  case repository(Repository.ID)
  case group(RepositoryGroup.ID)
  case worktree(Worktree.ID)
  case archivedWorktrees
}

struct SidebarListHeaderModel: Equatable, Identifiable {
  let id = SidebarPresentationItemID.listHeader
  var repositoryCount: Int
}

struct SidebarRepositoryContainerModel: Equatable, Identifiable {
  var id: Repository.ID { repositoryID }

  var repositoryID: Repository.ID
  var title: String
  /// The root on this Mac. Nil for a remote repository.
  var rootURL: URL?
  var kind: Repository.Kind
  var isExpanded: Bool
  var isRemoving: Bool
  var isWorkspace: Bool
  var worktreeSections: WorktreeRowSections
  var workspaceChildRows: [WorkspaceChildRowModel]
}

/// A display-only sidebar row for one workspace child repository. `branchName`
/// is the live current branch (falling back to metadata); `info` carries the
/// uncommitted diff counts and PR, mirroring a worktree row's badges.
struct WorkspaceChildRowModel: Equatable, Identifiable {
  let id: String
  let repositoryName: String
  let branchName: String?
  let info: WorktreeInfoEntry?
  let workingDirectory: URL
}

/// A sidebar group container (docs-ai 086). `members` holds the member rows while
/// the group is open and is empty while it is collapsed.
struct SidebarGroupModel: Equatable, Identifiable {
  var id: RepositoryGroup.ID { group.id }

  var group: RepositoryGroup
  var isExpanded: Bool
  var memberCount: Int
  var members: [SidebarItem]
}

struct FailedRepositoryModel: Equatable, Identifiable {
  var id: Repository.ID
  var name: String
  var path: String
  var failureMessage: String
  var isGitUnavailable: Bool = false
  /// The host of a remote folder that did not answer or needs a rebind (docs-ai 084 C1).
  var hostStatus: RemoteHostStatus?
  var isReorderable: Bool
}

struct ArchivedWorktreesRowModel: Equatable, Identifiable {
  let id = SidebarPresentationItemID.archivedWorktrees
  var count: Int
}

enum SidebarWorktreeSection: Equatable {
  case pinned
  case unpinned
}

struct SidebarWorktreeDropTarget: Equatable {
  var repositoryID: Repository.ID
  var section: SidebarWorktreeSection
  var source: IndexSet
  var destination: Int

  var action: RepositoriesFeature.WorktreeOrderingAction {
    switch section {
    case .pinned:
      return .pinnedWorktreesMoved(repositoryID: repositoryID, source, destination)
    case .unpinned:
      return .unpinnedWorktreesMoved(repositoryID: repositoryID, source, destination)
    }
  }
}

extension RepositoriesFeature.State {
  func sidebarPresentation(
    expandedRepositoryIDs: Set<Repository.ID>,
    includesArchivedWorktreesRow: Bool = false
  ) -> SidebarPresentation {
    let repositoriesByID = Dictionary(
      repositories.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let roots = orderedRepositoryRoots()
    let rootsByID = Dictionary(roots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let collapsedGroupIDs = collapsedGroupIDSet
    var items: [SidebarItem] = []

    if SidebarPresentation.showsListHeader(repositoryCount: roots.count) {
      items.append(.listHeader(SidebarListHeaderModel(repositoryCount: roots.count)))
    }

    func repositoryItem(_ repositoryID: Repository.ID) -> SidebarItem? {
      guard let standardizedRoot = rootsByID[repositoryID] else { return nil }
      if let failureMessage = loadFailuresByID[repositoryID] {
        return .failedRepository(
          FailedRepositoryModel(
            id: repositoryID,
            name: Repository.name(for: standardizedRoot),
            path: sidebarPath(for: standardizedRoot),
            failureMessage: failureMessage,
            isGitUnavailable: gitUnavailableRepositoryIDs.contains(repositoryID),
            hostStatus: remoteHostStatus(for: repositoryID),
            isReorderable: true
          )
        )
      }
      guard let repository = repositoriesByID[repositoryID] else { return nil }
      let isExpanded = expandedRepositoryIDs.contains(repository.id)
      return .repository(
        SidebarRepositoryContainerModel(
          repositoryID: repository.id,
          title: repository.name,
          rootURL: repository.localURL,
          kind: repository.kind,
          isExpanded: isExpanded,
          isRemoving: isRemovingRepository(repository),
          isWorkspace: repository.isWorkspace,
          worktreeSections: isExpanded ? worktreeRowSections(in: repository) : .empty,
          workspaceChildRows: isExpanded && repository.isWorkspace
            ? workspaceChildRows(in: repository)
            : []
        )
      )
    }

    for layoutItem in sidebarLayout.appendingMissing(roots.map(\.id)).items {
      switch layoutItem {
      case .repository(let repositoryID):
        if let item = repositoryItem(repositoryID) {
          items.append(item)
        }
      case .group(let group):
        let isExpanded = !collapsedGroupIDs.contains(group.id)
        items.append(
          .group(
            SidebarGroupModel(
              group: group,
              isExpanded: isExpanded,
              memberCount: group.repositoryIDs.count(where: { rootsByID[$0] != nil }),
              members: isExpanded ? group.repositoryIDs.compactMap(repositoryItem) : []
            )
          )
        )
      }
    }

    if includesArchivedWorktreesRow, !archivedWorktrees.isEmpty {
      items.append(.archivedWorktrees(ArchivedWorktreesRowModel(count: archivedWorktrees.count)))
    }

    return SidebarPresentation(items: items)
  }

}

extension RepositoriesFeature.State {
  /// The local path, or `alias:/path` for a remote folder (docs-ai 084 D1).
  fileprivate func sidebarPath(for location: RepositoryLocation) -> String {
    guard case .remote(let hostProfileID, let path) = location else { return location.path }
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    let alias = hostProfiles.first { $0.id == hostProfileID }?.alias ?? String(localized: "Unknown host")
    return "\(alias):\(path)"
  }
}

extension WorktreeRowSections {
  static let empty = WorktreeRowSections(
    main: nil,
    pinned: [],
    pending: [],
    unpinned: []
  )
}
