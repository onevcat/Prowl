import ComposableArchitecture
import Foundation

extension RepositoriesFeature {
  func reduceSidebarGroups(
    state: inout State,
    action: SidebarGroupAction
  ) -> Effect<Action> {
    switch action {
    case .newGroupRequested(let repositoryID):
      state.groupTitlePrompt = GroupTitlePrompt(target: .newGroup(containing: repositoryID), currentTitle: "")
      return .none

    case .renameGroupRequested(let groupID):
      guard let group = state.sidebarLayout.group(id: groupID) else { return .none }
      state.groupTitlePrompt = GroupTitlePrompt(target: .rename(groupID), currentTitle: group.title)
      return .none

    case .titlePromptSubmitted(let title):
      guard let prompt = state.groupTitlePrompt, let title = RepositoryGroup.normalizedTitle(title) else {
        return .none
      }
      state.groupTitlePrompt = nil
      switch prompt.target {
      case .newGroup(let repositoryID):
        let groupID = uuid()
        return editSidebarLayout(state: &state) {
          $0.createGroup(id: groupID, title: title, containing: repositoryID)
        }
      case .rename(let groupID):
        return editSidebarLayout(state: &state) { $0.renameGroup(groupID, to: title) }
      }

    case .titlePromptCanceled:
      state.groupTitlePrompt = nil
      return .none

    case .moveRepositoryToGroup(let repositoryID, let groupID):
      return editSidebarLayout(state: &state) { $0.moveRepository(repositoryID, toGroup: groupID) }

    case .removeRepositoryFromGroup(let repositoryID):
      return editSidebarLayout(state: &state) { $0.removeFromGroup(repositoryID) }

    case .setGroupColor(let groupID, let color):
      return editSidebarLayout(state: &state) { $0.setGroupColor(groupID, to: color) }

    case .ungroup(let groupID):
      state.$collapsedGroupIDs.withLock { $0.removeAll { $0 == groupID.uuidString } }
      return editSidebarLayout(state: &state) { $0.ungroup(groupID) }
    }
  }

  /// Applies `edit` to the layout that the sidebar shows (with every root in it) and
  /// saves the result when the edit changed it. An edit that changes nothing, such
  /// as a drop at the current place, saves nothing.
  func editSidebarLayout(
    state: inout State,
    _ edit: (inout SidebarLayout) -> Void
  ) -> Effect<Action> {
    let materialized = state.materializedSidebarLayout()
    var layout = materialized
    edit(&layout)
    guard layout != materialized else { return .none }
    state.sidebarLayout = layout
    let savedLayout = layout
    return .run { _ in
      await repositoryPersistence.saveSidebarLayout(savedLayout)
    }
  }

  var sidebarGroupsReducer: some ReducerOf<Self> {
    Reduce { state, action in
      guard case .sidebarGroups(let action) = action else {
        return .none
      }
      return reduceSidebarGroups(state: &state, action: action)
    }
  }
}

extension RepositoriesFeature.State {
  /// The stored layout with each shown root that it does not hold at the end of the
  /// top level, as the sidebar shows it.
  func materializedSidebarLayout() -> SidebarLayout {
    sidebarLayout.appendingMissing(orderedRepositoryIDs())
  }

  var collapsedGroupIDSet: Set<RepositoryGroup.ID> {
    Set(collapsedGroupIDs.compactMap(UUID.init(uuidString:)))
  }

  /// Repositories whose rows the sidebar shows: own expansion and an open group
  /// (docs-ai 086). Hotkey rows and keyboard navigation follow this set.
  var visibleExpandedRepositoryIDs: Set<Repository.ID> {
    visibleRepositoryIDs(ownExpanded: expandedRepositoryIDs)
  }

  func visibleRepositoryIDs(ownExpanded: Set<Repository.ID>) -> Set<Repository.ID> {
    let collapsed = collapsedGroupIDSet
    guard !collapsed.isEmpty else { return ownExpanded }
    let hidden = sidebarLayout.groups.filter { collapsed.contains($0.id) }.flatMap(\.repositoryIDs)
    return ownExpanded.subtracting(hidden)
  }

  func isGroupTitlePromptTargetAvailable(_ target: GroupTitlePrompt.Target) -> Bool {
    switch target {
    case .newGroup(let repositoryID):
      repositories[id: repositoryID] != nil || repositoryRoots.contains { $0.standardized.id == repositoryID }
    case .rename(let groupID):
      sidebarLayout.group(id: groupID) != nil
    }
  }
}
