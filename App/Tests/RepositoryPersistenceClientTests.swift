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

  @Test(.dependencies) func savesAndLoadsRepositoryEntries() async throws {
    let storage = SettingsTestStorage()
    let client = RepositoryPersistenceClient.liveValue

    let result = await withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      await client.saveRepositoryEntries([
        PersistedRepositoryEntry(path: "/tmp/repo-a", kind: .git),
        PersistedRepositoryEntry(path: "/tmp/repo-a", kind: .git),
        PersistedRepositoryEntry(path: "/tmp/folder/../folder", kind: .plain),
      ])
      return await client.loadRepositoryEntries()
    }

    #expect(
      result == [
        PersistedRepositoryEntry(path: "/tmp/repo-a", kind: .git),
        PersistedRepositoryEntry(path: "/tmp/folder", kind: .plain),
      ]
    )

    let finalSettings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(finalSettings.repositoryRoots == result.map(\.path))
  }

  @Test(.dependencies) func loadsLegacyRepositoryRootsAsGitEntries() async throws {
    let storage = SettingsTestStorage()
    let legacySettings = SettingsFile(
      repositoryRoots: ["/tmp/repo-a", "/tmp/repo-b/../repo-b"]
    )

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0 = legacySettings }
    }

    let client = RepositoryPersistenceClient.liveValue
    let result = await withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      await client.loadRepositoryEntries()
    }

    #expect(
      result == [
        PersistedRepositoryEntry(path: "/tmp/repo-a", kind: .git),
        PersistedRepositoryEntry(path: "/tmp/repo-b", kind: .git),
      ]
    )
  }

  @Test(.dependencies) func legacyArchivedWorktreeIDsMigratedAndCleared() async {
    let client = RepositoryPersistenceClient.liveValue

    // Seed legacy key
    @Shared(.appStorage("archivedWorktreeIDs")) var legacyArchived: [Worktree.ID] = []
    $legacyArchived.withLock { $0 = ["/tmp/repo/wt-1", "/tmp/repo/wt-2"] }

    // First load should migrate
    let loaded = await client.loadArchivedWorktrees()
    #expect(loaded.count == 2)
    #expect(loaded.map(\.id) == ["/tmp/repo/wt-1", "/tmp/repo/wt-2"])
    // Migrated timestamps should be recent, not distantPast
    for entry in loaded {
      #expect(entry.archivedAt > Date.distantPast)
    }

    // Legacy key should be cleared
    #expect(legacyArchived.isEmpty)

    // New key should be populated
    @Shared(.appStorage("archivedWorktrees")) var newArchived: [ArchivedWorktree] = []
    #expect(newArchived.count == 2)

    // Save empty (user clears all archives)
    await client.saveArchivedWorktrees([])

    // Reload should return empty — no resurrection from legacy key
    let reloaded = await client.loadArchivedWorktrees()
    #expect(reloaded.isEmpty)
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

  @Test func repositorySnapshotPayloadDeduplicatesRestoredWorktreeIDs() throws {
    let payloadData = Data(
      """
      {
        "version": 2,
        "repositories": [
          {
            "rootPath": "/tmp/repo",
            "name": "repo",
            "kind": "git",
            "worktrees": [
              {
                "name": "feature",
                "detail": ".worktrees/feature",
                "workingDirectoryPath": "/tmp/repo/.worktrees/feature",
                "createdAt": null
              },
              {
                "name": "duplicate",
                "detail": ".worktrees/feature",
                "workingDirectoryPath": "/tmp/repo/.worktrees/./feature",
                "createdAt": null
              }
            ]
          }
        ]
      }
      """.utf8
    )
    let payload = try JSONDecoder().decode(RepositorySnapshotCachePayload.self, from: payloadData)

    let restored = payload.restoreRepositories { path in
      path == "/tmp/repo" || path == "/tmp/repo/.worktrees/feature"
    }

    #expect(restored?.first?.worktrees.map(\.name) == ["feature"])
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

  @Test func repositorySnapshotPayloadRejectsTooManyRepositories() {
    let repositories = (0..<RepositorySnapshotCachePayload.maxRepositories + 1).map { index in
      Repository(
        id: "/tmp/repo-\(index)",
        rootURL: URL(fileURLWithPath: "/tmp/repo-\(index)"),
        name: "repo-\(index)",
        worktrees: IdentifiedArray()
      )
    }

    let payload = RepositorySnapshotCachePayload(repositories: repositories)
    let restored = payload.restoreRepositories { _ in true }

    #expect(restored == nil)
  }

  @Test func repositorySnapshotPayloadRejectsTooManyWorktreesPerRepository() {
    let repoRoot = "/tmp/repo"
    let worktrees = (0..<RepositorySnapshotCachePayload.maxWorktreesPerRepository + 1).map { index in
      Worktree(
        id: "\(repoRoot)/wt-\(index)",
        name: "wt-\(index)",
        detail: ".",
        workingDirectory: URL(fileURLWithPath: "\(repoRoot)/wt-\(index)"),
        repositoryRootURL: URL(fileURLWithPath: repoRoot)
      )
    }
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )

    let payload = RepositorySnapshotCachePayload(repositories: [repository])
    let restored = payload.restoreRepositories { _ in true }

    #expect(restored == nil)
  }

  @Test func repositorySnapshotPayloadRoundTripsPlainRepositories() {
    let repository = Repository(
      id: "/tmp/folder",
      rootURL: URL(fileURLWithPath: "/tmp/folder"),
      name: "folder",
      kind: .plain,
      worktrees: IdentifiedArray()
    )

    let payload = RepositorySnapshotCachePayload(repositories: [repository])
    let restored = payload.restoreRepositories { path in
      path == "/tmp/folder"
    }

    #expect(restored == [repository])
  }
}
