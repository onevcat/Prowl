import Foundation
import IdentifiedCollections

enum WindowTitle {
  static let appName = "Prowl"
  static let archivedWorktreesTitle = String(localized: "Archived Worktrees")
  static let canvasTitle = String(localized: "Canvas")

  static func format(repository: String, tab: String?) -> String {
    guard let tab, !tab.isEmpty else { return repository }
    return "\(repository) · \(tab)"
  }

  @MainActor
  static func compute(
    repositories: RepositoriesFeature.State,
    terminalManager: WorktreeTerminalManager
  ) -> String {
    compute(
      repositories: repositories,
      terminalState: { terminalManager.stateIfExists(for: $0) }
    )
  }

  @MainActor
  static func compute(
    repositories: RepositoriesFeature.State,
    terminalState: (Worktree.ID) -> WorktreeTerminalState?
  ) -> String {
    switch repositories.selection {
    case .archivedWorktrees:
      return archivedWorktreesTitle
    case .canvas:
      return canvasTitle
    case .repository(let repositoryID):
      return repositoryTitle(repositoryID: repositoryID, repositories: repositories, terminalState: terminalState)
    case .worktree(let worktreeID):
      return worktreeTitle(worktreeID: worktreeID, repositories: repositories, terminalState: terminalState)
    case nil:
      return appName
    }
  }

  static func sanitize(_ raw: String) -> String? {
    let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let trimmed = String(String.UnicodeScalarView(scalars))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  @MainActor
  private static func worktreeTitle(
    worktreeID: Worktree.ID,
    repositories: RepositoriesFeature.State,
    terminalState: (Worktree.ID) -> WorktreeTerminalState?
  ) -> String {
    guard let repositoryID = repositories.repositoryID(containing: worktreeID),
      repositories.repositories[id: repositoryID] != nil
    else {
      return appName
    }
    // No active tab → drop worktree context so the title doesn't outlive the last tab.
    guard let tab = selectedTabTitle(in: terminalState(worktreeID)) else {
      return appName
    }
    return format(
      repository: repositoryDisplayTitle(repositoryID: repositoryID, repositories: repositories),
      tab: tab
    )
  }

  @MainActor
  private static func repositoryTitle(
    repositoryID: Repository.ID,
    repositories: RepositoriesFeature.State,
    terminalState: (Worktree.ID) -> WorktreeTerminalState?
  ) -> String {
    guard repositories.repositories[id: repositoryID] != nil else {
      return appName
    }
    return format(
      repository: repositoryDisplayTitle(repositoryID: repositoryID, repositories: repositories),
      tab: selectedTabTitle(in: terminalState(repositoryID))
    )
  }

  private static func repositoryDisplayTitle(
    repositoryID: Repository.ID,
    repositories: RepositoriesFeature.State
  ) -> String {
    if let customTitle = repositories.repositoryCustomTitles[repositoryID]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !customTitle.isEmpty
    {
      return customTitle
    }
    return repositories.repositories[id: repositoryID]?.name ?? appName
  }

  @MainActor
  private static func selectedTabTitle(in state: WorktreeTerminalState?) -> String? {
    guard let state,
      let selectedTabID = state.tabManager.selectedTabId,
      let tab = state.tabManager.tabs.first(where: { $0.id == selectedTabID })
    else {
      return nil
    }
    return sanitize(tab.title)
  }
}
