import ComposableArchitecture
import Foundation
import Sharing

struct RepositoryPersistenceClient {
  var loadRepositoryEntries: @Sendable () async -> [PersistedRepositoryEntry]
  var saveRepositoryEntries: @Sendable ([PersistedRepositoryEntry]) async -> Void
  var loadRoots: @Sendable () async -> [String]
  var saveRoots: @Sendable ([String]) async -> Void
  var loadPinnedWorktreeIDs: @Sendable () async -> [Worktree.ID]
  var savePinnedWorktreeIDs: @Sendable ([Worktree.ID]) async -> Void
  var loadArchivedWorktrees: @Sendable () async -> [ArchivedWorktree]
  var saveArchivedWorktrees: @Sendable ([ArchivedWorktree]) async -> Void
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
      loadRepositoryEntries: {
        @Shared(.repositoryEntries) var entries: [PersistedRepositoryEntry]
        return entries
      },
      saveRepositoryEntries: { entries in
        @Shared(.repositoryEntries) var sharedEntries: [PersistedRepositoryEntry]
        $sharedEntries.withLock {
          $0 = entries
        }
      },
      loadRoots: {
        @Shared(.repositoryEntries) var entries: [PersistedRepositoryEntry]
        return entries.map(\.path)
      },
      saveRoots: { roots in
        @Shared(.repositoryEntries) var sharedEntries: [PersistedRepositoryEntry]
        let entries = RepositoryPathNormalizer.normalize(roots).map {
          PersistedRepositoryEntry(path: $0, kind: .git)
        }
        $sharedEntries.withLock {
          $0 = entries
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
      loadArchivedWorktrees: {
        @Shared(.appStorage("archivedWorktrees")) var archived: [ArchivedWorktree] = []
        if !archived.isEmpty {
          return normalizeArchivedWorktrees(archived)
        }
        // One-time migration from legacy format
        @Shared(.appStorage("archivedWorktreeIDs")) var legacyArchived: [Worktree.ID] = []
        let legacyIDs = RepositoryPathNormalizer.normalize(legacyArchived)
        guard !legacyIDs.isEmpty else { return [] }
        let now = Date()
        let migrated = legacyIDs.map { ArchivedWorktree(id: $0, archivedAt: now) }
        $archived.withLock { $0 = migrated }
        $legacyArchived.withLock { $0 = [] }
        return migrated
      },
      saveArchivedWorktrees: { worktrees in
        @Shared(.appStorage("archivedWorktrees")) var sharedArchived: [ArchivedWorktree] = []
        let normalized = normalizeArchivedWorktrees(worktrees)
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
        guard data.count <= RepositorySnapshotCachePayload.maxSnapshotFileBytes else {
          repositoryPersistenceLogger.warning("Repository snapshot exceeded size fuse and was reset")
          discardRepositorySnapshot(at: snapshotURL)
          return nil
        }
        let decoder = JSONDecoder()
        do {
          let payload = try await MainActor.run {
            try decoder.decode(RepositorySnapshotCachePayload.self, from: data)
          }
          guard
            let repositories = await MainActor.run(
              resultType: [Repository]?.self,
              body: {
                payload.restoreRepositories(
                  pathExists: { FileManager.default.fileExists(atPath: $0) }
                )
              }
            )
          else {
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
            at: SupacodePaths.cacheDirectory,
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
          guard data.count <= RepositorySnapshotCachePayload.maxSnapshotFileBytes else {
            repositoryPersistenceLogger.warning("Repository snapshot exceeded size fuse and was skipped")
            return
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
    loadRepositoryEntries: { [] },
    saveRepositoryEntries: { _ in },
    loadRoots: { [] },
    saveRoots: { _ in },
    loadPinnedWorktreeIDs: { [] },
    savePinnedWorktreeIDs: { _ in },
    loadArchivedWorktrees: { [] },
    saveArchivedWorktrees: { _ in },
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

nonisolated struct RepositorySnapshotCachePayload: Codable, Equatable, Sendable {
  nonisolated static let currentVersion = 2
  nonisolated static let maxSnapshotFileBytes = 2 * 1024 * 1024
  nonisolated static let maxRepositories = 256
  nonisolated static let maxWorktreesPerRepository = 512

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
    guard repositories.count <= Self.maxRepositories else {
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
  nonisolated struct SnapshotRepository: Codable, Equatable, Sendable {
    let rootPath: String
    let name: String
    let kind: Repository.Kind
    let worktrees: [SnapshotWorktree]
    let workspace: ProjectWorkspace?

    init(repository: Repository) {
      rootPath = repository.rootURL.path(percentEncoded: false)
      name = repository.name
      kind = repository.kind
      worktrees = repository.worktrees.map { SnapshotWorktree(worktree: $0) }
      workspace = repository.workspace
    }

    func restore(
      pathExists: @Sendable (String) -> Bool
    ) -> Repository? {
      guard let normalizedRootPath = normalizePath(rootPath), pathExists(normalizedRootPath) else {
        return nil
      }
      guard worktrees.count <= RepositorySnapshotCachePayload.maxWorktreesPerRepository else {
        return nil
      }

      let rootURL = URL(fileURLWithPath: normalizedRootPath).standardizedFileURL
      var restoredWorktrees: [Worktree] = []
      restoredWorktrees.reserveCapacity(worktrees.count)

      for worktree in worktrees {
        guard
          let restoredWorktree = worktree.restore(
            repositoryRootURL: rootURL,
            pathExists: pathExists
          )
        else {
          return nil
        }
        restoredWorktrees.append(restoredWorktree)
      }

      let repositoryName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return Repository(
        id: normalizedRootPath,
        rootURL: rootURL,
        name: repositoryName.isEmpty ? Repository.name(for: rootURL) : repositoryName,
        kind: kind,
        worktrees: IdentifiedArray(restoredWorktrees, uniquingIDsWith: { current, _ in current }),
        workspace: workspace?.normalized(relativeTo: rootURL)
      )
    }
  }

  nonisolated struct SnapshotWorktree: Codable, Equatable, Sendable {
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

private nonisolated func normalizeArchivedWorktrees(_ worktrees: [ArchivedWorktree]) -> [ArchivedWorktree] {
  var seen = Set<Worktree.ID>()
  var result: [ArchivedWorktree] = []
  result.reserveCapacity(worktrees.count)
  for entry in worktrees {
    guard let normalized = normalizePath(entry.id), seen.insert(normalized).inserted else {
      continue
    }
    result.append(ArchivedWorktree(id: normalized, archivedAt: entry.archivedAt))
  }
  return result
}

private nonisolated func normalizePath(_ path: String) -> String? {
  PathPolicy.normalizePath(path)
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
