import Foundation

@MainActor
enum ListRuntimeSnapshotBuilder {
  struct WorktreeContext {
    let id: String
    let name: String
    let path: String
    let rootPath: String
    let kind: ListCommandWorktree.Kind
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
            title: paneSnapshot.title,
            cwd: normalizeAbsolutePath(paneSnapshot.cwd)
          )
        }

        guard !panes.isEmpty else {
          return nil
        }

        return ListRuntimeSnapshot.Tab(
          id: tabSnapshot.id,
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
        taskStatus: terminalSnapshot.taskStatus,
        tabs: tabs
      )
    }

    return ListRuntimeSnapshot(worktrees: worktrees, focusedWorktreeID: focusedWorktreeID)
  }

  static func orderedWorktreeContexts(from repositoriesState: RepositoriesFeature.State) -> [WorktreeContext] {
    var contexts: [WorktreeContext] = []
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositoriesState.repositories.map { ($0.id, $0) })

    for repositoryID in repositoriesState.orderedRepositoryIDs() {
      guard let repository = repositoriesByID[repositoryID] else {
        continue
      }

      if repository.capabilities.supportsWorktrees {
        for worktree in repositoriesState.orderedWorktrees(in: repository) {
          contexts.append(
            WorktreeContext(
              id: worktree.id,
              name: worktree.name,
              path: worktree.workingDirectory.path(percentEncoded: false),
              rootPath: worktree.repositoryRootURL.path(percentEncoded: false),
              kind: listCommandKind(for: repository)
            )
          )
        }
        continue
      }

      if repository.capabilities.supportsRunnableFolderActions {
        let rootPath = repository.rootURL.path(percentEncoded: false)
        contexts.append(
          WorktreeContext(
            id: repository.id,
            name: repository.name,
            path: rootPath,
            rootPath: rootPath,
            kind: listCommandKind(for: repository)
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
