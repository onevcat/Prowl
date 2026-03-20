import ComposableArchitecture
import Foundation
import Sharing

struct RepositoryPersistenceClient {
  var loadRoots: @Sendable () async -> [String]
  var saveRoots: @Sendable ([String]) async -> Void
  var loadPinnedWorktreeIDs: @Sendable () async -> [Worktree.ID]
  var savePinnedWorktreeIDs: @Sendable ([Worktree.ID]) async -> Void
  var loadArchivedWorktreeIDs: @Sendable () async -> [Worktree.ID]
  var saveArchivedWorktreeIDs: @Sendable ([Worktree.ID]) async -> Void
  var loadRepositoryOrderIDs: @Sendable () async -> [Repository.ID]
  var saveRepositoryOrderIDs: @Sendable ([Repository.ID]) async -> Void
  var loadWorktreeOrderByRepository: @Sendable () async -> [Repository.ID: [Worktree.ID]]
  var saveWorktreeOrderByRepository: @Sendable ([Repository.ID: [Worktree.ID]]) async -> Void
  var loadLastFocusedWorktreeID: @Sendable () async -> Worktree.ID?
  var saveLastFocusedWorktreeID: @Sendable (Worktree.ID?) async -> Void
  var loadRepositorySnapshot: @Sendable () async -> [Repository]?
  var saveRepositorySnapshot: @Sendable ([Repository]) async -> Void
}

extension RepositoryPersistenceClient: DependencyKey {
  static let liveValue: RepositoryPersistenceClient = {
    return RepositoryPersistenceClient(
      loadRoots: {
        @Shared(.repositoryRoots) var roots: [String]
        return roots
      },
      saveRoots: { roots in
        @Shared(.repositoryRoots) var sharedRoots: [String]
        $sharedRoots.withLock {
          $0 = roots
        }
      },
      loadPinnedWorktreeIDs: {
        @Shared(.pinnedWorktreeIDs) var pinned: [Worktree.ID]
        return pinned
      },
      savePinnedWorktreeIDs: { ids in
        @Shared(.pinnedWorktreeIDs) var sharedPinned: [Worktree.ID]
        $sharedPinned.withLock {
          $0 = ids
        }
      },
      loadArchivedWorktreeIDs: {
        @Shared(.appStorage("archivedWorktreeIDs")) var archived: [Worktree.ID] = []
        return RepositoryPathNormalizer.normalize(archived)
      },
      saveArchivedWorktreeIDs: { ids in
        @Shared(.appStorage("archivedWorktreeIDs")) var sharedArchived: [Worktree.ID] = []
        let normalized = RepositoryPathNormalizer.normalize(ids)
        $sharedArchived.withLock {
          $0 = normalized
        }
      },
      loadRepositoryOrderIDs: {
        @Shared(.appStorage("repositoryOrderIDs")) var order: [Repository.ID] = []
        return RepositoryOrderNormalizer.normalizeRepositoryIDs(order)
      },
      saveRepositoryOrderIDs: { ids in
        @Shared(.appStorage("repositoryOrderIDs")) var sharedOrder: [Repository.ID] = []
        let normalized = RepositoryOrderNormalizer.normalizeRepositoryIDs(ids)
        $sharedOrder.withLock {
          $0 = normalized
        }
      },
      loadWorktreeOrderByRepository: {
        @Shared(.appStorage("worktreeOrderByRepository")) var order: [Repository.ID: [Worktree.ID]] = [:]
        return RepositoryOrderNormalizer.normalizeWorktreeOrderByRepository(order)
      },
      saveWorktreeOrderByRepository: { order in
        @Shared(.appStorage("worktreeOrderByRepository")) var sharedOrder: [Repository.ID: [Worktree.ID]] = [:]
        let normalized = RepositoryOrderNormalizer.normalizeWorktreeOrderByRepository(order)
        $sharedOrder.withLock {
          $0 = normalized
        }
      },
      loadLastFocusedWorktreeID: {
        @Shared(.appStorage("lastFocusedWorktreeID")) var lastFocused: Worktree.ID?
        return lastFocused
      },
      saveLastFocusedWorktreeID: { id in
        @Shared(.appStorage("lastFocusedWorktreeID")) var sharedLastFocused: Worktree.ID?
        $sharedLastFocused.withLock {
          $0 = id
        }
      },
      loadRepositorySnapshot: {
        let snapshotURL = SupacodePaths.repositorySnapshotURL
        guard let data = try? Data(contentsOf: snapshotURL) else {
          return nil
        }
        guard !data.isEmpty else {
          discardRepositorySnapshot(at: snapshotURL)
          return nil
        }
        let decoder = JSONDecoder()
        do {
          let payload = try await MainActor.run {
            try decoder.decode(RepositorySnapshotCachePayload.self, from: data)
          }
          guard let repositories = await MainActor.run(
            resultType: [Repository]?.self,
            body: {
            payload.restoreRepositories(
              pathExists: { FileManager.default.fileExists(atPath: $0) }
            )
            }
          ) else {
            discardRepositorySnapshot(at: snapshotURL)
            return nil
          }
          return repositories
        } catch {
          repositoryPersistenceLogger.warning(
            "Unable to decode repository snapshot cache: \(error.localizedDescription)"
          )
          discardRepositorySnapshot(at: snapshotURL)
          return nil
        }
      },
      saveRepositorySnapshot: { repositories in
        let snapshotURL = SupacodePaths.repositorySnapshotURL
        guard !repositories.isEmpty else {
          discardRepositorySnapshot(at: snapshotURL)
          return
        }
        do {
          try FileManager.default.createDirectory(
            at: SupacodePaths.baseDirectory,
            withIntermediateDirectories: true
          )
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let payload = await MainActor.run {
            RepositorySnapshotCachePayload(repositories: repositories)
          }
          let data = try await MainActor.run {
            try encoder.encode(payload)
          }
          try data.write(to: snapshotURL, options: .atomic)
        } catch {
          repositoryPersistenceLogger.warning(
            "Unable to write repository snapshot cache: \(error.localizedDescription)"
          )
        }
      }
    )
  }()
  static let testValue = RepositoryPersistenceClient(
    loadRoots: { [] },
    saveRoots: { _ in },
    loadPinnedWorktreeIDs: { [] },
    savePinnedWorktreeIDs: { _ in },
    loadArchivedWorktreeIDs: { [] },
    saveArchivedWorktreeIDs: { _ in },
    loadRepositoryOrderIDs: { [] },
    saveRepositoryOrderIDs: { _ in },
    loadWorktreeOrderByRepository: { [:] },
    saveWorktreeOrderByRepository: { _ in },
    loadLastFocusedWorktreeID: { nil },
    saveLastFocusedWorktreeID: { _ in },
    loadRepositorySnapshot: { nil },
    saveRepositorySnapshot: { _ in }
  )
}

extension DependencyValues {
  var repositoryPersistence: RepositoryPersistenceClient {
    get { self[RepositoryPersistenceClient.self] }
    set { self[RepositoryPersistenceClient.self] = newValue }
  }
}

private nonisolated let repositoryPersistenceLogger = SupaLogger("Repositories")

private nonisolated func discardRepositorySnapshot(at url: URL) {
  guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
    return
  }
  do {
    try FileManager.default.removeItem(at: url)
  } catch {
    repositoryPersistenceLogger.warning(
      "Unable to remove repository snapshot cache: \(error.localizedDescription)"
    )
  }
}

struct RepositorySnapshotCachePayload: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let repositories: [SnapshotRepository]

  init(repositories: [Repository]) {
    version = Self.currentVersion
    self.repositories = repositories.map { SnapshotRepository(repository: $0) }
  }

  func restoreRepositories(
    pathExists: @Sendable (String) -> Bool
  ) -> [Repository]? {
    guard version == Self.currentVersion, !repositories.isEmpty else {
      return nil
    }

    var restored: [Repository] = []
    restored.reserveCapacity(repositories.count)

    for repository in repositories {
      guard let restoredRepository = repository.restore(pathExists: pathExists) else {
        return nil
      }
      restored.append(restoredRepository)
    }

    return restored
  }
}

extension RepositorySnapshotCachePayload {
  struct SnapshotRepository: Codable, Equatable, Sendable {
    let rootPath: String
    let name: String
    let worktrees: [SnapshotWorktree]

    init(repository: Repository) {
      rootPath = repository.rootURL.path(percentEncoded: false)
      name = repository.name
      worktrees = repository.worktrees.map { SnapshotWorktree(worktree: $0) }
    }

    func restore(
      pathExists: @Sendable (String) -> Bool
    ) -> Repository? {
      guard let normalizedRootPath = normalizePath(rootPath), pathExists(normalizedRootPath) else {
        return nil
      }

      let rootURL = URL(fileURLWithPath: normalizedRootPath).standardizedFileURL
      var restoredWorktrees: [Worktree] = []
      restoredWorktrees.reserveCapacity(worktrees.count)

      for worktree in worktrees {
        guard let restoredWorktree = worktree.restore(
          repositoryRootURL: rootURL,
          pathExists: pathExists
        ) else {
          return nil
        }
        restoredWorktrees.append(restoredWorktree)
      }

      let repositoryName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return Repository(
        id: normalizedRootPath,
        rootURL: rootURL,
        name: repositoryName.isEmpty ? Repository.name(for: rootURL) : repositoryName,
        worktrees: IdentifiedArray(uniqueElements: restoredWorktrees)
      )
    }
  }

  struct SnapshotWorktree: Codable, Equatable, Sendable {
    let name: String
    let detail: String
    let workingDirectoryPath: String
    let createdAt: Date?

    init(worktree: Worktree) {
      name = worktree.name
      detail = worktree.detail
      workingDirectoryPath = worktree.workingDirectory.path(percentEncoded: false)
      createdAt = worktree.createdAt
    }

    func restore(
      repositoryRootURL: URL,
      pathExists: @Sendable (String) -> Bool
    ) -> Worktree? {
      guard let normalizedPath = normalizePath(workingDirectoryPath), pathExists(normalizedPath) else {
        return nil
      }

      let worktreeURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
      return Worktree(
        id: normalizedPath,
        name: name,
        detail: detail,
        workingDirectory: worktreeURL,
        repositoryRootURL: repositoryRootURL,
        createdAt: createdAt
      )
    }
  }
}

private func normalizePath(_ path: String) -> String? {
  RepositoryPathNormalizer.normalize([path]).first
}

nonisolated enum RepositoryOrderNormalizer {
  static func normalizeRepositoryIDs(_ ids: [Repository.ID]) -> [Repository.ID] {
    RepositoryPathNormalizer.normalize(ids)
  }

  static func normalizeWorktreeOrderByRepository(
    _ order: [Repository.ID: [Worktree.ID]]
  ) -> [Repository.ID: [Worktree.ID]] {
    var normalized: [Repository.ID: [Worktree.ID]] = [:]
    for (repoID, worktreeIDs) in order {
      guard let normalizedRepoID = normalizePath(repoID) else { continue }
      let normalizedWorktreeIDs = RepositoryPathNormalizer.normalize(worktreeIDs)
      guard !normalizedWorktreeIDs.isEmpty else { continue }
      if var existing = normalized[normalizedRepoID] {
        for id in normalizedWorktreeIDs where !existing.contains(id) {
          existing.append(id)
        }
        normalized[normalizedRepoID] = existing
      } else {
        normalized[normalizedRepoID] = normalizedWorktreeIDs
      }
    }
    return normalized
  }

  private static func normalizePath(_ path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed)
      .standardizedFileURL
      .path(percentEncoded: false)
  }
}
