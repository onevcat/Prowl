import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct AppFeatureJumpToLatestUnreadTests {
  @Test func jumpToLatestUnreadSelectsWorktreeAndFocusesSurface() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    let tabID = TerminalTabID()
    let surfaceID = UUID()
    let notificationID = UUID()
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .active
    let focusedSurfaces = LockIsolated<[(Worktree.ID, UUID)]>([])
    let readNotifications = LockIsolated<[(Worktree.ID, UUID)]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.latestUnreadNotification = {
        NotificationLocation(
          worktreeID: worktree.id,
          tabID: tabID,
          surfaceID: surfaceID,
          notificationID: notificationID
        )
      }
      $0.terminalClient.focusSurface = { worktreeID, targetSurfaceID in
        focusedSurfaces.withValue { $0.append((worktreeID, targetSurfaceID)) }
        return true
      }
      $0.terminalClient.markNotificationRead = { worktreeID, targetNotificationID in
        readNotifications.withValue { $0.append((worktreeID, targetNotificationID)) }
      }
    }
    store.exhaustivity = .off

    await store.send(.jumpToLatestUnread)
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
    }
    await store.finish()

    #expect(focusedSurfaces.value.map { "\($0.0)|\($0.1.uuidString)" } == ["\(worktree.id)|\(surfaceID.uuidString)"])
    #expect(
      readNotifications.value.map { "\($0.0)|\($0.1.uuidString)" } == ["\(worktree.id)|\(notificationID.uuidString)"])
  }

  @Test func systemNotificationTappedSelectsWorktreeAndFocusesSurface() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    let surfaceID = UUID()
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .active
    let focusedSurfaces = LockIsolated<[(Worktree.ID, UUID)]>([])
    let readSurfaces = LockIsolated<[(Worktree.ID, UUID)]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusSurface = { worktreeID, targetSurfaceID in
        focusedSurfaces.withValue { $0.append((worktreeID, targetSurfaceID)) }
        return true
      }
      $0.terminalClient.markNotificationsReadForSurface = { worktreeID, targetSurfaceID in
        readSurfaces.withValue { $0.append((worktreeID, targetSurfaceID)) }
      }
    }
    store.exhaustivity = .off

    await store.send(.systemNotificationTapped(worktreeID: worktree.id, surfaceID: surfaceID))
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
    }
    await store.finish()

    #expect(focusedSurfaces.value.map { "\($0.0)|\($0.1.uuidString)" } == ["\(worktree.id)|\(surfaceID.uuidString)"])
    #expect(readSurfaces.value.map { "\($0.0)|\($0.1.uuidString)" } == ["\(worktree.id)|\(surfaceID.uuidString)"])
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepository(worktrees: [Worktree]) -> Repository {
    Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}
