import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct ToolbarNotificationGroupingTests {
  @Test func groupsNotificationsByRepositoryAndWorktreeInDisplayOrder() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"

    let repoAMain = makeWorktree(id: repoAPath, name: "main", repoRoot: repoAPath)
    let repoAOne = makeWorktree(id: "\(repoAPath)/one", name: "one", repoRoot: repoAPath)
    let repoATwo = makeWorktree(id: "\(repoAPath)/two", name: "two", repoRoot: repoAPath)

    let repoBMain = makeWorktree(id: repoBPath, name: "main", repoRoot: repoBPath)
    let repoBOne = makeWorktree(id: "\(repoBPath)/one", name: "one", repoRoot: repoBPath)

    let repoA = makeRepository(id: repoAPath, name: "Repo A", worktrees: [repoAMain, repoAOne, repoATwo])
    let repoB = makeRepository(id: repoBPath, name: "Repo B", worktrees: [repoBMain, repoBOne])

    var state = RepositoriesFeature.State(repositories: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.repositoryOrderIDs = [repoB.id, repoA.id]
    state.worktreeOrderByRepository[repoA.id] = [repoATwo.id, repoAOne.id]

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: repoAOne).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "A1", body: "done", isRead: true)
    ]
    manager.state(for: repoATwo).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "A2", body: "done")
    ]
    manager.state(for: repoBOne).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "B1", body: "done", isRead: true)
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)

    #expect(groups.map(\.id) == [repoB.id, repoA.id])
    #expect(groups[0].worktrees.map(\.id) == [repoBOne.id])
    #expect(groups[1].worktrees.map(\.id) == [repoATwo.id, repoAOne.id])
    #expect(groups[1].unseenWorktreeCount == 1)
  }

  @Test func omitsArchivedAndEmptyNotificationGroups() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"

    let repoAMain = makeWorktree(id: repoAPath, name: "main", repoRoot: repoAPath)
    let repoAArchived = makeWorktree(id: "\(repoAPath)/archived", name: "archived", repoRoot: repoAPath)
    let repoBMain = makeWorktree(id: repoBPath, name: "main", repoRoot: repoBPath)
    let repoBEmpty = makeWorktree(id: "\(repoBPath)/empty", name: "empty", repoRoot: repoBPath)

    let repoA = makeRepository(id: repoAPath, name: "Repo A", worktrees: [repoAMain, repoAArchived])
    let repoB = makeRepository(id: repoBPath, name: "Repo B", worktrees: [repoBMain, repoBEmpty])

    var state = RepositoriesFeature.State(repositories: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.archivedWorktrees = [ArchivedWorktree(id: repoAArchived.id, archivedAt: .distantPast)]

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: repoAArchived).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "Archived", body: "hidden")
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)

    #expect(groups.isEmpty)
  }

  @Test func unseenWorktreeCountUsesUnreadNotificationsOnly() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let readOnly = makeWorktree(id: "\(repoPath)/read-only", name: "read-only", repoRoot: repoPath)
    let mixed = makeWorktree(id: "\(repoPath)/mixed", name: "mixed", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, readOnly, mixed])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: readOnly).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "Read 1", body: "done", isRead: true)
    ]
    manager.state(for: mixed).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "Read 2", body: "done", isRead: true),
      WorktreeTerminalNotification(surfaceId: UUID(), title: "Unread", body: "new", isRead: false),
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)

    #expect(groups.count == 1)
    #expect(groups[0].notificationCount == 3)
    #expect(groups[0].unseenWorktreeCount == 1)
  }

  @Test func keepsReadOnlyNotificationsInGroups() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: feature).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "Read", body: "kept", isRead: true)
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)

    #expect(groups.map(\.id) == [repo.id])
    #expect(groups[0].worktrees.map(\.id) == [feature.id])
    #expect(groups[0].unseenWorktreeCount == 0)
  }

  @Test func customTitleOverridesGroupName() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: feature).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "Note", body: "done")
    ]

    let groups = state.toolbarNotificationGroups(
      terminalManager: manager,
      customTitles: [repo.id: "Aliased Repo"]
    )

    #expect(groups.count == 1)
    #expect(groups[0].name == "Aliased Repo")
  }

  @Test func missingCustomTitleFallsBackToRepositoryName() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: feature).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "Note", body: "done")
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager, customTitles: [:])

    #expect(groups.count == 1)
    #expect(groups[0].name == "Repo")
  }

  @Test func unreadNotificationGroupsKeepOnlyUnreadNotifications() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"

    let repoAMain = makeWorktree(id: repoAPath, name: "main", repoRoot: repoAPath)
    let repoAOne = makeWorktree(id: "\(repoAPath)/one", name: "one", repoRoot: repoAPath)
    let repoATwo = makeWorktree(id: "\(repoAPath)/two", name: "two", repoRoot: repoAPath)

    let repoBMain = makeWorktree(id: repoBPath, name: "main", repoRoot: repoBPath)
    let repoBOne = makeWorktree(id: "\(repoBPath)/one", name: "one", repoRoot: repoBPath)
    let repoBTwo = makeWorktree(id: "\(repoBPath)/two", name: "two", repoRoot: repoBPath)

    let repoA = makeRepository(id: repoAPath, name: "Repo A", worktrees: [repoAMain, repoAOne, repoATwo])
    let repoB = makeRepository(id: repoBPath, name: "Repo B", worktrees: [repoBMain, repoBOne, repoBTwo])

    var state = RepositoriesFeature.State(repositories: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.repositoryOrderIDs = [repoB.id, repoA.id]
    state.worktreeOrderByRepository[repoA.id] = [repoATwo.id, repoAOne.id]
    state.worktreeOrderByRepository[repoB.id] = [repoBTwo.id, repoBOne.id]

    let repoAUnreadID = UUID()
    let repoAReadID = UUID()
    let repoBUnreadID = UUID()
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: repoAOne).notifications = [
      WorktreeTerminalNotification(id: repoAUnreadID, surfaceId: UUID(), title: "A1 unread", body: "new"),
      WorktreeTerminalNotification(id: repoAReadID, surfaceId: UUID(), title: "A1 read", body: "done", isRead: true),
    ]
    manager.state(for: repoATwo).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "A2 read", body: "done", isRead: true)
    ]
    manager.state(for: repoBOne).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "B1 read", body: "done", isRead: true)
    ]
    manager.state(for: repoBTwo).notifications = [
      WorktreeTerminalNotification(id: repoBUnreadID, surfaceId: UUID(), title: "B2 unread", body: "new")
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)
    let unreadGroups = groups.unreadNotificationGroups

    #expect(groups.map(\.id) == [repoB.id, repoA.id])
    #expect(unreadGroups.map(\.id) == [repoB.id, repoA.id])
    #expect(unreadGroups[0].worktrees.map(\.id) == [repoBTwo.id])
    #expect(unreadGroups[1].worktrees.map(\.id) == [repoAOne.id])
    #expect(unreadGroups[0].worktrees[0].notifications.map(\.id) == [repoBUnreadID])
    #expect(unreadGroups[1].worktrees[0].notifications.map(\.id) == [repoAUnreadID])
    #expect(unreadGroups[1].worktrees[0].notifications.map(\.isRead) == [false])
  }

  @Test func remainingNotificationGroupsExcludeUnreadNotifications() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let mixed = makeWorktree(id: "\(repoPath)/mixed", name: "mixed", repoRoot: repoPath)
    let readOnly = makeWorktree(id: "\(repoPath)/read-only", name: "read-only", repoRoot: repoPath)
    let unreadOnly = makeWorktree(id: "\(repoPath)/unread-only", name: "unread-only", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, mixed, readOnly, unreadOnly])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [repo.rootURL]
    state.worktreeOrderByRepository[repo.id] = [mixed.id, readOnly.id, unreadOnly.id]

    let mixedUnreadID = UUID()
    let mixedReadID = UUID()
    let readOnlyID = UUID()
    let unreadOnlyID = UUID()
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: mixed).notifications = [
      WorktreeTerminalNotification(id: mixedUnreadID, surfaceId: UUID(), title: "Mixed unread", body: "new"),
      WorktreeTerminalNotification(id: mixedReadID, surfaceId: UUID(), title: "Mixed read", body: "done", isRead: true),
    ]
    manager.state(for: readOnly).notifications = [
      WorktreeTerminalNotification(id: readOnlyID, surfaceId: UUID(), title: "Read only", body: "done", isRead: true)
    ]
    manager.state(for: unreadOnly).notifications = [
      WorktreeTerminalNotification(id: unreadOnlyID, surfaceId: UUID(), title: "Unread only", body: "new")
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)
    let remainingGroups = groups.remainingNotificationGroups

    #expect(remainingGroups.map(\.id) == [repo.id])
    #expect(remainingGroups[0].worktrees.map(\.id) == [mixed.id, readOnly.id])
    #expect(remainingGroups[0].worktrees[0].notifications.map(\.id) == [mixedReadID])
    #expect(remainingGroups[0].worktrees[0].hasUnseenNotifications == false)
    #expect(remainingGroups[0].worktrees[1].notifications.map(\.id) == [readOnlyID])
  }

  @Test func unreadNotificationGroupsAndRepositoryGroupsShareReadState() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let notificationID = UUID()
    let surfaceID = UUID()
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: feature).notifications = [
      WorktreeTerminalNotification(
        id: notificationID,
        surfaceId: surfaceID,
        title: "Unread",
        body: "new"
      ),
    ]

    let initialGroups = state.toolbarNotificationGroups(terminalManager: manager)
    let initialUnreadGroups = initialGroups.unreadNotificationGroups

    #expect(initialUnreadGroups.map(\.id) == [repo.id])
    #expect(initialUnreadGroups[0].worktrees.map(\.id) == [feature.id])
    #expect(initialUnreadGroups[0].worktrees[0].notifications.map(\.id) == [notificationID])
    #expect(initialGroups.remainingNotificationGroups.isEmpty)
    #expect(initialGroups[0].worktrees[0].notifications.map(\.id) == [notificationID])
    #expect(initialGroups[0].worktrees[0].notifications.map(\.isRead) == [false])

    manager.state(for: feature).markNotificationsRead(forSurfaceID: surfaceID)

    let updatedGroups = state.toolbarNotificationGroups(terminalManager: manager)
    let updatedRemainingGroups = updatedGroups.remainingNotificationGroups

    #expect(updatedGroups.unreadNotificationGroups.isEmpty)
    #expect(updatedGroups[0].worktrees[0].notifications.map(\.id) == [notificationID])
    #expect(updatedGroups[0].worktrees[0].notifications.map(\.isRead) == [true])
    #expect(updatedRemainingGroups.map(\.id) == [repo.id])
    #expect(updatedRemainingGroups[0].worktrees[0].notifications.map(\.id) == [notificationID])
    #expect(updatedRemainingGroups[0].worktrees[0].hasUnseenNotifications == false)
  }

  private func makeWorktree(
    id: String,
    name: String,
    repoRoot: String
  ) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(
    id: String,
    name: String,
    worktrees: [Worktree]
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}
