import Foundation
import ProwlCLIShared
import Sharing

@MainActor
enum ListRuntimeSnapshotBuilder {
  struct WorktreeContext {
    let id: String
    let name: String
    let path: String
    let rootPath: String
    let kind: ListCommandWorktree.Kind
    /// The host of a remote folder (docs-ai 084 C2); nil for a local worktree.
    var host: ListCommandHost?

    /// Whether `selector` names this worktree: its ID, its name, its path for a local
    /// worktree, or `alias:/path` for a remote one. A bare path never matches a worktree on
    /// another host.
    func matches(_ selector: String) -> Bool {
      name == selector || matchesExactly(selector)
    }

    /// Whether `selector` names this worktree by its ID or its path, not by its name.
    func matchesExactly(_ selector: String) -> Bool {
      id == selector || ListCommandHost.displayPath(path, host: host) == selector
    }

    var listWorktree: ListCommandWorktree {
      ListCommandWorktree(id: id, name: name, path: path, rootPath: rootPath, kind: kind, host: host)
    }
  }

  static func makeSnapshot(
    repositoriesState: RepositoriesFeature.State,
    terminalManager: WorktreeTerminalManager
  ) -> ListRuntimeSnapshot {
    let activeStates = terminalManager.activeWorktreeStates
    var activeSnapshots: [String: CLIWorktreeTerminalSnapshot] = [:]
    activeSnapshots.reserveCapacity(activeStates.count)
    for state in activeStates {
      activeSnapshots[state.worktreeID] = state.makeCLIListSnapshot()
    }

    let orderedContexts = orderedWorktreeContexts(from: repositoriesState)
    let focusedWorktreeID = terminalManager.selectedWorktreeID ?? terminalManager.canvasFocusedWorktreeID

    let worktrees: [ListRuntimeSnapshot.Worktree] = orderedContexts.compactMap { context in
      guard let terminalSnapshot = activeSnapshots[context.id] else {
        return nil
      }

      let tabs: [ListRuntimeSnapshot.Tab] = terminalSnapshot.tabs.compactMap { tabSnapshot in
        let panes = tabSnapshot.panes.map { paneSnapshot in
          ListRuntimeSnapshot.Pane(
            id: paneSnapshot.id,
            handle: paneSnapshot.handle,
            title: paneSnapshot.title,
            cwd: normalizeAbsolutePath(paneSnapshot.cwd),
            visible: paneSnapshot.visible,
            agent: paneSnapshot.agent
          )
        }

        guard !panes.isEmpty else {
          return nil
        }

        return ListRuntimeSnapshot.Tab(
          id: tabSnapshot.id,
          handle: tabSnapshot.handle,
          title: tabSnapshot.title,
          selected: tabSnapshot.selected,
          focusedPaneID: tabSnapshot.focusedPaneID,
          panes: panes
        )
      }

      guard !tabs.isEmpty else {
        return nil
      }

      return ListRuntimeSnapshot.Worktree(
        id: context.id,
        name: context.name,
        path: context.path,
        rootPath: context.rootPath,
        kind: context.kind,
        host: context.host,
        taskStatus: terminalSnapshot.taskStatus,
        tabs: tabs
      )
    }

    return ListRuntimeSnapshot(worktrees: worktrees, focusedWorktreeID: focusedWorktreeID)
  }

  static func orderedWorktreeContexts(from repositoriesState: RepositoriesFeature.State) -> [WorktreeContext] {
    var contexts: [WorktreeContext] = []
    let repositoriesByID = Dictionary(
      repositoriesState.repositories.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    let aliases = Dictionary(hostProfiles.map { ($0.id, $0.alias) }, uniquingKeysWith: { first, _ in first })
    for repositoryID in repositoriesState.orderedRepositoryIDs() {
      guard let repository = repositoriesByID[repositoryID] else { continue }
      // A remote folder carries its host, so a bare path matches local worktrees only
      // (docs-ai 084 C2).
      let host = repository.location.hostProfileID.map { hostProfileID in
        ListCommandHost(
          profileID: hostProfileID.uuidString.lowercased(),
          label: aliases[hostProfileID] ?? hostProfileID.uuidString.lowercased())
      }

      if repository.capabilities.supportsWorktrees {
        for worktree in repositoriesState.orderedWorktrees(in: repository) {
          contexts.append(
            WorktreeContext(
              id: worktree.id,
              name: worktree.name,
              path: worktree.location.path,
              rootPath: worktree.repositoryLocation.path,
              kind: listCommandKind(for: repository),
              host: host
            )
          )
        }
        continue
      }

      if let terminalWorktree = repository.terminalWorktree {
        contexts.append(
          WorktreeContext(
            id: terminalWorktree.id,
            name: terminalWorktree.name,
            path: terminalWorktree.location.path,
            rootPath: terminalWorktree.repositoryLocation.path,
            kind: listCommandKind(for: repository),
            host: host
          )
        )
      }
    }

    return contexts
  }

  private static func normalizeAbsolutePath(_ value: String?) -> String? {
    guard let value else { return nil }
    return value.hasPrefix("/") ? value : nil
  }

  private static func listCommandKind(for repository: Repository) -> ListCommandWorktree.Kind {
    if repository.isWorkspace {
      return .workspace
    }
    return repository.kind == .git ? .git : .plain
  }
}
