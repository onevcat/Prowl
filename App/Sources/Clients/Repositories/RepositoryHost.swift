import Foundation

nonisolated enum RepositoryHostError: Error, Equatable, LocalizedError {
  /// The repository is on another host, and no host connection exists for it yet (docs-ai 084 B3).
  case remoteUnavailable(RepositoryLocation)
  /// The repository's host profile is not in `hosts.json`.
  case hostProfileMissing(UUID)

  var errorDescription: String? {
    switch self {
    case .remoteUnavailable:
      String(localized: "Remote folders are not available yet.")
    case .hostProfileMissing:
      String(localized: "The host of this remote folder is missing.")
    }
  }
}

/// Repository state reads and worktree operations, addressed by where the
/// repository lives (docs-ai 084, host boundary). Reducers call these instead of
/// reading a local URL from a repository or worktree.
///
/// A local location runs on `local`, which keeps the local fast paths of
/// `GitClient`. A remote location runs on the host that `remote` finds for its host
/// profile (B3). Without one, it fails with `RepositoryHostError.remoteUnavailable`
/// (or returns no value).
nonisolated struct RepositoryHost: Sendable {
  let local: GitClientDependency
  let remote: RemoteRepositoryHostClient

  init(local: GitClientDependency, remote: RemoteRepositoryHostClient = .unavailable) {
    self.local = local
    self.remote = remote
  }

  private func localURL(_ location: RepositoryLocation) throws -> URL {
    guard let url = location.localURL else { throw RepositoryHostError.remoteUnavailable(location) }
    return url
  }

  /// The host of a remote location, or nil for a local one.
  private func remoteHost(_ location: RepositoryLocation) async throws -> RemoteRepositoryHost? {
    guard case .remote(let hostProfileID, _) = location else { return nil }
    guard let host = try await remote.host(hostProfileID) else {
      throw RepositoryHostError.remoteUnavailable(location)
    }
    return host
  }

  /// The host of a remote location for an operation without an error channel; nil when
  /// it cannot be found.
  private func availableRemoteHost(_ location: RepositoryLocation) async -> RemoteRepositoryHost? {
    guard case .remote(let hostProfileID, _) = location else { return nil }
    return try? await remote.host(hostProfileID)
  }

  // MARK: - Repository

  func worktrees(in repository: RepositoryLocation) async throws -> [Worktree] {
    if let host = try await remoteHost(repository) { return try await host.worktrees(in: repository) }
    return try await local.worktrees(localURL(repository))
  }

  func pruneWorktrees(in repository: RepositoryLocation) async throws {
    if let host = try await remoteHost(repository) { return try await host.pruneWorktrees(at: repository.path) }
    try await local.pruneWorktrees(localURL(repository))
  }

  func localBranchNames(in repository: RepositoryLocation) async throws -> Set<String> {
    if let host = try await remoteHost(repository) { return try await host.localBranchNames(at: repository.path) }
    return try await local.localBranchNames(localURL(repository))
  }

  func isValidBranchName(_ name: String, in repository: RepositoryLocation) async -> Bool {
    guard let url = repository.localURL else {
      return await availableRemoteHost(repository)?.isValidBranchName(name, at: repository.path) ?? false
    }
    return await local.isValidBranchName(name, url)
  }

  func branchRefs(in repository: RepositoryLocation) async throws -> [String] {
    if let host = try await remoteHost(repository) { return try await host.branchRefs(at: repository.path) }
    return try await local.branchRefs(localURL(repository))
  }

  func automaticWorktreeBaseRef(in repository: RepositoryLocation) async -> String? {
    guard let url = repository.localURL else {
      return await availableRemoteHost(repository)?.automaticWorktreeBaseRef(at: repository.path)
    }
    return await local.automaticWorktreeBaseRef(url)
  }

  func ignoredFileCount(in repository: RepositoryLocation) async throws -> Int {
    if let host = try await remoteHost(repository) { return try await host.ignoredFileCount(at: repository.path) }
    return try await local.ignoredFileCount(localURL(repository))
  }

  func untrackedFileCount(in repository: RepositoryLocation) async throws -> Int {
    if let host = try await remoteHost(repository) { return try await host.untrackedFileCount(at: repository.path) }
    return try await local.untrackedFileCount(localURL(repository))
  }

  func isBareRepository(_ repository: RepositoryLocation) async throws -> Bool {
    if let host = try await remoteHost(repository) { return try await host.isBareRepository(at: repository.path) }
    return try await local.isBareRepository(localURL(repository))
  }

  func deleteLocalBranch(
    named branchName: String,
    in repository: RepositoryLocation,
    force: Bool
  ) async throws -> LocalBranchDeletionOutcome {
    if let host = try await remoteHost(repository) {
      return try await host.deleteLocalBranch(named: branchName, at: repository.path, force: force)
    }
    return try await local.deleteLocalBranch(branchName, localURL(repository), force)
  }

  func repositoryWebURL(for repository: RepositoryLocation) async -> URL? {
    guard let url = repository.localURL else {
      return await availableRemoteHost(repository)?.repositoryWebURL(at: repository.path)
    }
    return await local.repositoryWebURL(url)
  }

  func githubRemoteInfos(for repository: RepositoryLocation) async -> [GithubRemoteInfo] {
    guard let url = repository.localURL else {
      return await availableRemoteHost(repository)?.githubRemoteInfos(at: repository.path) ?? []
    }
    return await local.githubRemoteInfos(url)
  }

  func remoteInfo(for repository: RepositoryLocation) async -> GithubRemoteInfo? {
    guard let url = repository.localURL else {
      return await availableRemoteHost(repository)?.remoteInfo(at: repository.path)
    }
    return await local.remoteInfo(url)
  }

  func remoteNames(in repository: RepositoryLocation) async throws -> [String] {
    if let host = try await remoteHost(repository) { return try await host.remoteNames(at: repository.path) }
    return try await local.remoteNames(localURL(repository))
  }

  func fetchRemote(_ remote: String, in repository: RepositoryLocation) async throws {
    if let host = try await remoteHost(repository) { return try await host.fetchRemote(remote, at: repository.path) }
    try await local.fetchRemote(remote, localURL(repository))
  }

  /// Creates a worktree in `repository`, which replaces the request's `repoRoot`. For a
  /// local repository, the other folders of the request are local URLs; for a remote one,
  /// they hold paths on its host.
  func createWorktreeStream(
    in repository: RepositoryLocation,
    _ request: GitWorktreeCreateRequest
  ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error> {
    guard let url = repository.localURL else {
      return AsyncThrowingStream { continuation in
        let task = Task {
          do {
            guard let host = try await remoteHost(repository) else {
              throw RepositoryHostError.remoteUnavailable(repository)
            }
            for try await event in host.createWorktreeStream(request, in: repository) {
              continuation.yield(event)
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    var request = request
    request.repoRoot = url
    return local.createWorktreeStream(request)
  }

  /// Throws unless a remote location's host is known: `remoteUnavailable` without a host
  /// connection, `hostProfileMissing` without its profile. A local location passes.
  func requireRemoteHost(for location: RepositoryLocation) async throws {
    _ = try await remoteHost(location)
  }

  /// `location` with its path resolved on its host, for comparing it with the paths
  /// that git lists; a local location, or one that cannot be resolved, as it is.
  func physicalLocation(_ location: RepositoryLocation) async -> RepositoryLocation {
    guard case .remote(let hostProfileID, let path) = location,
      let host = await availableRemoteHost(location), let resolved = await host.physicalPath(path)
    else { return location }
    return .remote(hostProfileID: hostProfileID, path: resolved)
  }

  /// `$HOME` on a remote repository's host, where remote worktrees are placed by
  /// default; nil for a local repository.
  func remoteHomeDirectory(in repository: RepositoryLocation) async throws -> String? {
    try await remoteHost(repository)?.homeDirectory()
  }

  // MARK: - Worktree

  /// Removes `worktree`. The local host moves the folder aside first and prunes it
  /// in the background; the remote host runs `git worktree remove`.
  func removeWorktree(_ worktree: Worktree, deleteBranch: Bool) async throws {
    if let host = try await remoteHost(worktree.location) {
      return try await host.removeWorktree(worktree, deleteBranch: deleteBranch)
    }
    _ = try localURL(worktree.location)
    _ = try await local.removeWorktree(worktree, deleteBranch)
  }

  /// Nil for a remote worktree: the batched refresh carries its branch (B3f).
  func branchName(of worktree: RepositoryLocation) async -> String? {
    guard let url = worktree.localURL else { return nil }
    return await local.branchName(url)
  }

  /// Nil for a remote worktree: the batched refresh carries its line changes (B3f).
  func lineChanges(in worktree: RepositoryLocation) async -> GitLineChanges? {
    guard let url = worktree.localURL else { return nil }
    return await local.lineChanges(url)
  }

  func renameBranch(in worktree: RepositoryLocation, to branchName: String) async throws {
    if let host = try await remoteHost(worktree) {
      return try await host.renameBranch(at: worktree.path, to: branchName)
    }
    try await local.renameBranch(localURL(worktree), branchName)
  }
}
