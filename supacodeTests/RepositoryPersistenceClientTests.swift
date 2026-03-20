import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import supacode

struct RepositoryPersistenceClientTests {
  @Test(.dependencies) func savesAndLoadsRootsAndPins() async throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.appearanceMode = .dark
      }
    }

    let client = RepositoryPersistenceClient.liveValue
    let result = await withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      await client.saveRoots([
        "/tmp/repo-a",
        "/tmp/repo-a",
        "/tmp/repo-b/../repo-b",
      ])
      await client.savePinnedWorktreeIDs([
        "/tmp/repo-a/wt-1",
        "/tmp/repo-a/wt-1",
      ])
      let roots = await client.loadRoots()
      let pinned = await client.loadPinnedWorktreeIDs()
      return (roots: roots, pinned: pinned)
    }

    #expect(result.roots == ["/tmp/repo-a", "/tmp/repo-b"])
    #expect(result.pinned == ["/tmp/repo-a/wt-1"])

    let finalSettings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(finalSettings.global.appearanceMode == .dark)
  }

  @Test func repositorySnapshotPayloadRoundTripsRepositories() {
    let repoRoot = "/tmp/repo"
    let worktree = Worktree(
      id: "\(repoRoot)/main",
      name: "main",
      detail: ".",
      workingDirectory: URL(fileURLWithPath: "\(repoRoot)/main"),
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      createdAt: Date(timeIntervalSince1970: 123)
    )
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )

    let payload = RepositorySnapshotCachePayload(repositories: [repository])
    let restored = payload.restoreRepositories { path in
      [repoRoot, "\(repoRoot)/main"].contains(path)
    }

    #expect(restored == [repository])
  }

  @Test func repositorySnapshotPayloadRejectsMissingWorktreePath() {
    let repoRoot = "/tmp/repo"
    let worktree = Worktree(
      id: "\(repoRoot)/main",
      name: "main",
      detail: ".",
      workingDirectory: URL(fileURLWithPath: "\(repoRoot)/main"),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )

    let payload = RepositorySnapshotCachePayload(repositories: [repository])
    let restored = payload.restoreRepositories { path in
      path == repoRoot
    }

    #expect(restored == nil)
  }
}
