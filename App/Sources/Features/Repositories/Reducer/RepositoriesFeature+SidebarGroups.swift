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

    case .newEmptyGroupRequested:
      state.groupTitlePrompt = GroupTitlePrompt(target: .newEmptyGroup, currentTitle: "")
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
      case .newEmptyGroup:
        let groupID = uuid()
        // The new group is at the end of the list, which can be out of view.
        state.nextPendingSidebarRevealID += 1
        state.pendingSidebarReveal = .init(id: state.nextPendingSidebarRevealID, target: .group(groupID))
        return editSidebarLayout(state: &state) { $0.createEmptyGroup(id: groupID, title: title) }
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

    case .setGroupIcon, .chooseGroupSymbolRequested, .symbolPickerApplied, .symbolPickerCanceled,
      .importGroupImage, .groupImageImported, .groupImageImportFailed:
      return reduceGroupIcon(state: &state, action: action)

    case .ungroup(let groupID):
      let icon = state.sidebarLayout.group(id: groupID)?.icon
      state.pendingGroupImageImports[groupID] = nil
      state.$collapsedGroupIDs.withLock { $0.removeAll { $0 == groupID.uuidString } }
      return .merge(
        editSidebarLayout(state: &state) { $0.ungroup(groupID) },
        removeGroupImage(icon)
      )
    }
  }

  private func reduceGroupIcon(
    state: inout State,
    action: SidebarGroupAction
  ) -> Effect<Action> {
    switch action {
    case .setGroupIcon(let groupID, let icon):
      state.pendingGroupImageImports[groupID] = nil
      return setGroupIcon(state: &state, groupID: groupID, to: icon)

    case .chooseGroupSymbolRequested(let groupID):
      guard let group = state.sidebarLayout.group(id: groupID) else { return .none }
      let currentSymbol: String? =
        if case .sfSymbol(let name) = group.icon { name } else { nil }
      state.groupSymbolPicker = GroupSymbolPicker(groupID: groupID, currentSymbol: currentSymbol)
      return .none

    case .symbolPickerApplied(let symbolName):
      guard let picker = state.groupSymbolPicker else { return .none }
      state.groupSymbolPicker = nil
      state.pendingGroupImageImports[picker.groupID] = nil
      return setGroupIcon(state: &state, groupID: picker.groupID, to: symbolName.map(RepositoryIconSource.sfSymbol))

    case .symbolPickerCanceled:
      state.groupSymbolPicker = nil
      return .none

    case .importGroupImage(let groupID, let sourceURL):
      let importID = uuid()
      state.pendingGroupImageImports[groupID] = importID
      let store = groupIconAssetStore
      return .run { send in
        do {
          let filename = try store.importImage(sourceURL, ProwlPaths.groupIconsDirectory)
          await send(.sidebarGroups(.groupImageImported(groupID, importID: importID, filename: filename)))
        } catch {
          await send(
            .sidebarGroups(.groupImageImportFailed(groupID, importID: importID, message: error.localizedDescription)))
        }
      }

    case .groupImageImported(let groupID, let importID, let filename):
      // A later import or icon choice, or the removal of the group, makes this
      // import stale. Then nothing refers to the file.
      guard state.pendingGroupImageImports[groupID] == importID,
        state.sidebarLayout.group(id: groupID) != nil
      else {
        return removeGroupImage(.userImage(filename: filename))
      }
      state.pendingGroupImageImports[groupID] = nil
      return setGroupIcon(state: &state, groupID: groupID, to: .userImage(filename: filename))

    case .groupImageImportFailed(let groupID, let importID, let message):
      if state.pendingGroupImageImports[groupID] == importID {
        state.pendingGroupImageImports[groupID] = nil
      }
      state.alert = messageAlert(title: String(localized: "Unable to use this image"), message: message)
      return .none

    default:
      return .none
    }
  }

  /// Sets the icon and deletes the image file that the old icon used.
  private func setGroupIcon(
    state: inout State,
    groupID: RepositoryGroup.ID,
    to icon: RepositoryIconSource?
  ) -> Effect<Action> {
    let previousIcon = state.sidebarLayout.group(id: groupID)?.icon
    let edit = editSidebarLayout(state: &state) { $0.setGroupIcon(groupID, to: icon) }
    guard previousIcon != icon else { return edit }
    return .merge(edit, removeGroupImage(previousIcon))
  }

  private func removeGroupImage(_ icon: RepositoryIconSource?) -> Effect<Action> {
    guard let filename = icon?.storedImageFilename else { return .none }
    let store = groupIconAssetStore
    return .run { _ in
      try? store.remove(filename, ProwlPaths.groupIconsDirectory)
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
    case .newEmptyGroup:
      true
    case .rename(let groupID):
      sidebarLayout.group(id: groupID) != nil
    }
  }
}
