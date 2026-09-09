import ComposableArchitecture
import Sharing
import SwiftUI

struct SidebarView: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Shared(.appStorage("sidebarCollapsedRepositoryIDs")) private var collapsedRepositoryIDs: [Repository.ID] = []
  @State private var sidebarSelections: Set<SidebarSelection> = []

  var body: some View {
    let state = store.state
    let repositoryIDs = Set(state.repositories.map(\.id))
    let expandedRepoIDs = state.expandedRepositoryIDs
    let expandedRepoIDsBinding = expandedRepoIDsBinding(
      repositoryIDs: repositoryIDs,
      expandedRepoIDs: expandedRepoIDs
    )
    let visibleHotkeyRows = state.orderedWorktreeRows(includingRepositoryIDs: expandedRepoIDs)
    let visibleWorktreeIDs = Set(visibleHotkeyRows.map(\.id))
    let effectiveSelectedRows = selectedRows(state: state)
    let confirmWorktreeAction = makeConfirmWorktreeAction(state: state)
    let archiveWorktreeAction = makeArchiveWorktreeAction(rows: effectiveSelectedRows)
    let deleteWorktreeAction = makeDeleteWorktreeAction(rows: effectiveSelectedRows)

    return SidebarListView(
      store: store,
      expandedRepoIDs: expandedRepoIDsBinding,
      sidebarSelections: $sidebarSelections,
      terminalManager: terminalManager
    )
    .focusedSceneValue(\.confirmWorktreeAction, confirmWorktreeAction)
    .focusedSceneValue(\.archiveWorktreeAction, archiveWorktreeAction)
    .focusedSceneValue(\.deleteWorktreeAction, deleteWorktreeAction)
    .focusedSceneValue(\.visibleHotkeyWorktreeRows, visibleHotkeyRows)
    // `visibleHotkeyWorktreeRows` stays a plain value: `WorktreeRowModel` is
    // Equatable, so SwiftUI already skips republishing it on no-op body runs.
    .onAppear { syncSidebarSelections(state: state, visibleWorktreeIDs: visibleWorktreeIDs) }
    .onChange(of: state.selection) { _, _ in
      if state.selection != nil { mirrors.selectedID = nil }
      syncSidebarSelections(state: state, visibleWorktreeIDs: visibleWorktreeIDs)
    }
    .onChange(of: visibleHotkeyRows.map(\.id)) { _, _ in
      syncSidebarSelections(state: state, visibleWorktreeIDs: visibleWorktreeIDs)
    }
    .onChange(of: sidebarSelections) { _, newValue in
      store.send(.setSidebarSelectedWorktreeIDs(selectedWorktreeIDs(from: newValue)))
    }
    .onChange(of: repositoryIDs) { _, newValue in
      let collapsed = Set(collapsedRepositoryIDs).intersection(newValue)
      $collapsedRepositoryIDs.withLock {
        $0 = Array(collapsed).sorted()
      }
    }
  }

  private func expandedRepoIDsBinding(
    repositoryIDs: Set<Repository.ID>,
    expandedRepoIDs: Set<Repository.ID>
  ) -> Binding<Set<Repository.ID>> {
    Binding<Set<Repository.ID>>(
      get: { expandedRepoIDs },
      set: { newValue in
        let collapsed = repositoryIDs.subtracting(newValue)
        $collapsedRepositoryIDs.withLock {
          $0 = Array(collapsed).sorted()
        }
      }
    )
  }

  private func selectedRows(state: RepositoriesFeature.State) -> [WorktreeRowModel] {
    let selectedRow = state.selectedRow(for: state.selectedWorktreeID)
    let selectedWorktreeIDs = state.sidebarSelectedWorktreeIDs
    let selectedRows = state.orderedWorktreeRows().filter { selectedWorktreeIDs.contains($0.id) }
    return selectedRows.isEmpty ? (selectedRow.map { [$0] } ?? []) : selectedRows
  }

  private func makeConfirmWorktreeAction(
    state: RepositoriesFeature.State
  ) -> FocusedAction<Void>? {
    guard let alert = state.confirmWorktreeAlert else { return nil }
    return FocusedAction(isEnabled: true, token: state.confirmWorktreeActionToken) {
      store.send(.alert(.presented(alert)))
    }
  }

  private func makeArchiveWorktreeAction(
    rows: [WorktreeRowModel]
  ) -> FocusedAction<Void>? {
    let targets =
      rows
      .filter { $0.isRemovable && !$0.isMainWorktree && !$0.isDeleting }
      .map {
        RepositoriesFeature.ArchiveWorktreeTarget(
          worktreeID: $0.id,
          repositoryID: $0.repositoryID
        )
      }
    guard !targets.isEmpty else { return nil }
    return FocusedAction(isEnabled: true, token: targets.map(\.worktreeID)) {
      if targets.count == 1, let target = targets.first {
        store.send(.worktreeLifecycle(.requestArchiveWorktree(target.worktreeID, target.repositoryID)))
      } else {
        store.send(.worktreeLifecycle(.requestArchiveWorktrees(targets)))
      }
    }
  }

  private func makeDeleteWorktreeAction(
    rows: [WorktreeRowModel]
  ) -> FocusedAction<Void>? {
    let targets =
      rows
      .filter { $0.isRemovable && !$0.isDeleting }
      .map {
        RepositoriesFeature.DeleteWorktreeTarget(
          worktreeID: $0.id,
          repositoryID: $0.repositoryID
        )
      }
    guard !targets.isEmpty else { return nil }
    return FocusedAction(isEnabled: true, token: targets.map(\.worktreeID)) {
      if targets.count == 1, let target = targets.first {
        store.send(.worktreeLifecycle(.requestDeleteWorktree(target.worktreeID, target.repositoryID)))
      } else {
        store.send(.worktreeLifecycle(.requestDeleteWorktrees(targets)))
      }
    }
  }

  private func syncSidebarSelections(
    state: RepositoriesFeature.State,
    visibleWorktreeIDs: Set<Worktree.ID>
  ) {
    sidebarSelections = normalizedSidebarSelections(
      state: state,
      visibleWorktreeIDs: visibleWorktreeIDs
    )
    store.send(.setSidebarSelectedWorktreeIDs(selectedWorktreeIDs(from: sidebarSelections)))
  }

  private func normalizedSidebarSelections(
    state: RepositoriesFeature.State,
    visibleWorktreeIDs: Set<Worktree.ID>
  ) -> Set<SidebarSelection> {
    if state.isShowingCanvas {
      return [.canvas]
    }
    if state.isShowingArchivedWorktrees {
      return [.archivedWorktrees]
    }
    if let selectedRepository = state.selectedRepository, selectedRepository.kind == .plain {
      return [.repository(selectedRepository.id)]
    }
    if state.selectedRepositoryID != nil {
      return []
    }
    var normalized = Set(
      state.sidebarSelectedWorktreeIDs
        .intersection(visibleWorktreeIDs)
        .map(SidebarSelection.worktree)
    )
    if let selectedWorktreeID = state.selectedWorktreeID {
      normalized.insert(.worktree(selectedWorktreeID))
    }
    return normalized
  }

  private func selectedWorktreeIDs(from selections: Set<SidebarSelection>) -> Set<Worktree.ID> {
    Set(selections.compactMap(\.worktreeID))
  }
}
