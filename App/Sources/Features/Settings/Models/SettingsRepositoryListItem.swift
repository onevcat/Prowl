import Foundation
import IdentifiedCollections

/// One entry of the repository list in Settings: a repository, or a sidebar group with
/// the repositories it holds. Settings lists repositories in the sidebar order, so the
/// two lists read the same.
nonisolated enum SettingsRepositoryListItem: Equatable, Identifiable, Sendable {
  case repository(Repository.ID)
  case group(id: RepositoryGroup.ID, title: String, repositoryIDs: [Repository.ID])

  var id: String {
    switch self {
    case .repository(let id): id
    case .group(let id, _, _): SidebarLayoutItem.groupKey(id)
    }
  }
}

extension RepositoriesFeature.State {
  /// The loaded repositories in sidebar order, with the sidebar groups.
  ///
  /// A group without a loaded repository is left out, because Settings has nothing to
  /// show for it. A loaded repository that the layout does not hold goes at the end.
  func settingsRepositoryListItems() -> [SettingsRepositoryListItem] {
    var items: [SettingsRepositoryListItem] = []
    var listed: Set<Repository.ID> = []
    func loaded(_ ids: [Repository.ID]) -> [Repository.ID] {
      ids.filter { repositories[id: $0] != nil && listed.insert($0).inserted }
    }
    for item in materializedSidebarLayout().items {
      switch item {
      case .repository(let id):
        items += loaded([id]).map(SettingsRepositoryListItem.repository)
      case .group(let group):
        let members = loaded(group.repositoryIDs)
        if !members.isEmpty {
          items.append(.group(id: group.id, title: group.title, repositoryIDs: members))
        }
      }
    }
    items += loaded(repositories.map(\.id)).map(SettingsRepositoryListItem.repository)
    return items
  }
}
