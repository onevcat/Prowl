import ComposableArchitecture
import SwiftUI

struct ArchivedWorktreesDetailView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  @State private var collapsedRepositoryIDs: Set<Repository.ID> = []
  @State private var selectedArchivedWorktreeIDs: Set<Worktree.ID> = []

  var body: some View {
    let snapshot = makeSnapshot()
    if snapshot.groups.isEmpty {
      emptyView
    } else {
      listView(snapshot: snapshot)
    }
  }

  private var emptyView: some View {
    ContentUnavailableView(
      "Archived Worktrees",
      systemImage: "archivebox",
      description: Text("Archive worktrees to keep them out of the main list.")
    )
  }

  private func listView(snapshot: ArchivedSnapshot) -> some View {
    let groups = snapshot.groups
    return List(selection: $selectedArchivedWorktreeIDs) {
      ForEach(groups.indices, id: \.self) { index in
        archivedSection(index: index, group: groups[index])
      }
    }
    .listStyle(.sidebar)
    .onChange(of: snapshot.groupIDs) { _, newValue in
      collapsedRepositoryIDs = collapsedRepositoryIDs.intersection(newValue)
    }
    .onChange(of: snapshot.archivedWorktreeIDs) { _, newValue in
      selectedArchivedWorktreeIDs = selectedArchivedWorktreeIDs.intersection(newValue)
    }
    .animation(.easeOut(duration: 0.2), value: snapshot.archivedRowIDs)
    .focusedSceneValue(\.deleteWorktreeAction, snapshot.deleteWorktreeAction)
    .focusedSceneValue(\.confirmWorktreeAction, snapshot.confirmWorktreeAction)
    .toolbar { toolbarContent(deleteWorktreeAction: snapshot.deleteWorktreeAction) }
  }

  @ViewBuilder
  private func archivedSection(
    index: Int,
    group: RepositoriesFeature.State.ArchivedWorktreeGroup
  ) -> some View {
    let isCollapsed = collapsedRepositoryIDs.contains(group.repository.id)
    Section {
      if !isCollapsed {
        ForEach(group.worktrees, id: \.id) { worktree in
          archivedRow(worktree: worktree, repositoryID: group.repository.id)
        }
      }
    } header: {
      ArchivedWorktreeSectionHeader(
        name: group.repository.name,
        worktreeCount: group.worktrees.count,
        isCollapsed: isCollapsed,
        showsTopSeparator: index > 0,
        onToggle: { toggleSection(group.repository.id) }
      )
    }
  }

  private func archivedRow(worktree: Worktree, repositoryID: Repository.ID) -> some View {
    ArchivedWorktreeRowView(
      worktree: worktree,
      info: store.state.worktreeInfo(for: worktree.id),
      onUnarchive: {
        store.send(.worktreeLifecycle(.unarchiveWorktree(worktree.id)))
      },
      onDelete: {
        store.send(.worktreeLifecycle(.requestDeleteWorktree(worktree.id, repositoryID)))
      }
    )
    .tag(worktree.id)
    .typeSelectEquivalent("")
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
  }

  @ToolbarContentBuilder
  private func toolbarContent(deleteWorktreeAction: FocusedAction<Void>?) -> some ToolbarContent {
    ToolbarItem {
      let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
      Button("Delete Selected", systemImage: "trash", role: .destructive) {
        deleteWorktreeAction?()
      }
      .help("Delete Selected (\(deleteShortcut))")
      .disabled(deleteWorktreeAction == nil)
    }
  }

  private struct ArchivedSnapshot {
    var groups: [RepositoriesFeature.State.ArchivedWorktreeGroup]
    var groupIDs: Set<Repository.ID>
    var archivedRowIDs: [Worktree.ID]
    var archivedWorktreeIDs: Set<Worktree.ID>
    var deleteWorktreeAction: FocusedAction<Void>?
    var confirmWorktreeAction: FocusedAction<Void>?
  }

  private func makeSnapshot() -> ArchivedSnapshot {
    let groups = store.state.archivedWorktreesByRepository()
    let groupIDs = Set(groups.map(\.repository.id))
    let archivedRowIDs = groups.flatMap(\.worktrees).map(\.id)
    let archivedWorktreeIDs = Set(archivedRowIDs)

    var repositoryByWorktreeID: [Worktree.ID: Repository.ID] = [:]
    repositoryByWorktreeID.reserveCapacity(archivedRowIDs.count)
    for group in groups {
      for worktree in group.worktrees {
        repositoryByWorktreeID[worktree.id] = group.repository.id
      }
    }

    var selectedTargets: [RepositoriesFeature.DeleteWorktreeTarget] = []
    selectedTargets.reserveCapacity(selectedArchivedWorktreeIDs.count)
    for worktreeID in selectedArchivedWorktreeIDs {
      if let repositoryID = repositoryByWorktreeID[worktreeID] {
        selectedTargets.append(
          RepositoriesFeature.DeleteWorktreeTarget(
            worktreeID: worktreeID,
            repositoryID: repositoryID
          )
        )
      }
    }

    let deleteWorktreeAction: FocusedAction<Void>?
    if selectedTargets.isEmpty {
      deleteWorktreeAction = nil
    } else {
      let store = self.store
      deleteWorktreeAction = FocusedAction(isEnabled: true, token: selectedTargets.map(\.worktreeID)) {
        store.send(.worktreeLifecycle(.requestDeleteWorktrees(selectedTargets)))
      }
    }

    let confirmWorktreeAction: FocusedAction<Void>?
    if let alert = store.state.confirmWorktreeAlert {
      let store = self.store
      confirmWorktreeAction = FocusedAction(isEnabled: true, token: store.state.confirmWorktreeActionToken) {
        store.send(.alert(.presented(alert)))
      }
    } else {
      confirmWorktreeAction = nil
    }

    return ArchivedSnapshot(
      groups: groups,
      groupIDs: groupIDs,
      archivedRowIDs: archivedRowIDs,
      archivedWorktreeIDs: archivedWorktreeIDs,
      deleteWorktreeAction: deleteWorktreeAction,
      confirmWorktreeAction: confirmWorktreeAction
    )
  }

  private func toggleSection(_ repositoryID: Repository.ID) {
    withAnimation(.easeOut(duration: 0.2)) {
      if collapsedRepositoryIDs.contains(repositoryID) {
        collapsedRepositoryIDs.remove(repositoryID)
      } else {
        collapsedRepositoryIDs.insert(repositoryID)
      }
    }
  }
}

private struct ArchivedWorktreeSectionHeader: View {
  let name: String
  let worktreeCount: Int
  let isCollapsed: Bool
  let showsTopSeparator: Bool
  let onToggle: () -> Void

  var body: some View {
    Button {
      onToggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption2)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(name)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text("(\(worktreeCount))")
          .font(.headline)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.top, 6)
      .contentShape(.rect)
    }
    .overlay(alignment: .top) {
      if showsTopSeparator {
        Rectangle()
          .fill(.secondary)
          .frame(height: 1)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(.plain)
    .help(isCollapsed ? "Expand repository section" : "Collapse repository section")
    .textCase(nil)
  }
}
