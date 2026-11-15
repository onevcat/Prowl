import ComposableArchitecture
import Foundation
import IdentifiedCollections

// The `project` order of the Active Agents panel (docs-ai 092). The panel, the keyboard
// navigation and the Agent Island roster read the order from `ActiveAgentsFeature.State`, but
// only this parent knows the sidebar layout and the repositories, so it keeps the inputs there.

extension RepositoriesFeature.State {
  /// What the `project` order depends on. It is `nil` in the other orders, so that agent
  /// updates cost nothing there.
  struct ActiveAgentOrderInputs: Equatable {
    let entries: IdentifiedArrayOf<ActiveAgentEntry>
    let repositories: IdentifiedArrayOf<Repository>
    let repositoryRoots: [RepositoryLocation]
    let sidebarLayout: SidebarLayout
  }

  var activeAgentOrderInputs: ActiveAgentOrderInputs? {
    guard activeAgents.sortOrder == .project else { return nil }
    return ActiveAgentOrderInputs(
      entries: activeAgents.entries,
      repositories: repositories,
      repositoryRoots: repositoryRoots,
      sidebarLayout: sidebarLayout
    )
  }

  mutating func refreshActiveAgentOrder() {
    if activeAgents.sortOrder == .project {
      activeAgents.projectIDsByEntryID = Self.activeAgentProjectIDs(
        entries: activeAgents.entries,
        repositories: repositories
      )
      activeAgents.projectOrder = materializedSidebarLayout().repositoryIDs
    } else {
      activeAgents.projectIDsByEntryID = [:]
      activeAgents.projectOrder = []
    }
    // The order moved under an open roster: keep its selection on a valid page.
    if activeAgents.isIslandRosterExpanded {
      activeAgents.islandNavigation.reconcile(entries: activeAgents.orderedEntries)
    }
  }

  /// The project of each agent: the repository that its row shows. This follows the
  /// resolution of `SidebarListView.activeAgentRowDisplay`: the agent's working directory
  /// first, and the tab's owning worktree only when the agent reports no directory. An agent
  /// that runs outside every repository has no project.
  static func activeAgentProjectIDs(
    entries: IdentifiedArrayOf<ActiveAgentEntry>,
    repositories: IdentifiedArrayOf<Repository>
  ) -> [ActiveAgentEntry.ID: Repository.ID] {
    // Keyed like `SidebarListView.activeAgentWorktreeMetadata`: a plain folder by its own ID,
    // a git repository by each worktree.
    var repositoryIDsByWorktreeID: [Worktree.ID: Repository.ID] = [:]
    for repository in repositories {
      if repository.capabilities.supportsRunnableFolderActions
        && !repository.capabilities.supportsWorktrees
      {
        repositoryIDsByWorktreeID[repository.id] = repository.id
      }
      for worktree in repository.worktrees {
        repositoryIDsByWorktreeID[worktree.id] = repository.id
      }
    }
    let resolvedWorktreeIDs = WorktreeDirectoryIndexCache.worktreeIDs(
      forWorkingDirectories: entries.compactMap(\.localWorkingDirectory),
      in: repositories
    )
    var projectIDs: [ActiveAgentEntry.ID: Repository.ID] = [:]
    for entry in entries {
      let worktreeID: Worktree.ID? =
        if entry.workingDirectory != nil {
          entry.remoteWorktreeID ?? entry.localWorkingDirectory.flatMap { resolvedWorktreeIDs[$0] }
        } else {
          entry.worktreeID
        }
      if let worktreeID, let repositoryID = repositoryIDsByWorktreeID[worktreeID] {
        projectIDs[entry.id] = repositoryID
      }
    }
    return projectIDs
  }
}
