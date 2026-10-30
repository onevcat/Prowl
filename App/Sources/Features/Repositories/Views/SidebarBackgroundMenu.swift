import ComposableArchitecture
import SwiftUI

/// The context menu of the sidebar list outside the rows: actions on the sidebar
/// as a whole. Each add action goes straight to its own UI, not to the add panel.
struct SidebarBackgroundMenu: View {
  let store: StoreOf<RepositoriesFeature>
  @Binding var expandedRepoIDs: Set<Repository.ID>
  @Binding var collapsedGroupIDs: Set<RepositoryGroup.ID>
  let onClone: () -> Void
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    let state = store.state
    let expansion = SidebarListView.SidebarExpansionState(
      groups: state.sidebarLayout.groups,
      expandableRepositoryIDs: SidebarListView.expandableRepositoryIDs(in: state.repositories),
      activeRepositoryIDs: [],
      expandedRepositoryIDs: expandedRepoIDs,
      collapsedGroupIDs: collapsedGroupIDs
    )
    let canExpand = !expansion.groups.isEmpty || !expansion.expandableRepositoryIDs.isEmpty

    Button("New Group…") {
      store.send(.sidebarGroups(.newEmptyGroupRequested))
    }
    .help("Add an empty group to the sidebar")
    Divider()
    Button("Add Repository…") {
      store.send(.setOpenPanelPresented(true))
    }
    .help(
      AppShortcuts.helpText(
        title: "Add Repository",
        commandID: AppShortcuts.CommandID.openRepository,
        in: resolvedKeybindings
      )
    )
    Button("Clone Repository…") {
      onClone()
    }
    .help("Clone a remote repository into a local directory")
    if RemoteFolders.isEnabledInThisProcess {
      Button("Add Remote Project…") {
        store.send(.addRemoteFolderRequested)
      }
      .help("Add a project on another machine over SSH")
    }
    Button("Add Workspace…") {
      store.send(.workspaceCreation(.promptRequested))
    }
    .help("A shared task folder spanning multiple repos for one agent.")
    Divider()
    Button("Expand All") {
      apply(.expandAll, to: expansion)
    }
    .help("Expand all groups and repositories")
    .disabled(!canExpand)
    Button("Collapse All") {
      apply(.collapseAll, to: expansion)
    }
    .help("Collapse all groups and repositories")
    .disabled(!canExpand)
    Divider()
    Button("Refresh Worktrees") {
      store.send(.refreshWorktrees)
    }
    .help(
      AppShortcuts.helpText(
        title: "Refresh Worktrees",
        commandID: AppShortcuts.CommandID.refreshWorktrees,
        in: resolvedKeybindings
      )
    )
    .disabled(state.repositoryRoots.isEmpty)
    Button(state.isShowingArchivedWorktrees ? "Exit Archived Worktrees" : "Archived Worktrees") {
      store.send(.selectArchivedWorktrees)
    }
    .help(
      AppShortcuts.helpText(
        title: state.isShowingArchivedWorktrees ? "Exit Archived Worktrees" : "Archived Worktrees",
        commandID: AppShortcuts.CommandID.archivedWorktrees,
        in: resolvedKeybindings
      )
    )
  }

  private func apply(
    _ action: SidebarListView.RepositoryListHeaderAction,
    to expansion: SidebarListView.SidebarExpansionState
  ) {
    withAnimation(.easeOut(duration: 0.2)) {
      let result = expansion.applying(action)
      expandedRepoIDs = result.expandedRepositoryIDs
      collapsedGroupIDs = result.collapsedGroupIDs
    }
  }
}
