import Foundation

nonisolated enum RepositoryHostError: Error, Equatable, LocalizedError {
  /// The repository is on another host, and no host connection exists for it yet (docs-ai 084 B3).
  case remoteUnavailable(RepositoryLocation)

  var errorDescription: String? {
    switch self {
    case .remoteUnavailable:
      String(localized: "Remote folders are not available yet.")
    }
  }
}

/// Repository state reads and worktree operations, addressed by where the
/// repository lives (docs-ai 084, host boundary). Reducers call these instead of
/// reading a local URL from a repository or worktree.
///
/// A local location runs on `local`, which keeps the local fast paths of
/// `GitClient`. A remote location fails with `RepositoryHostError.remoteUnavailable`
/// (or returns no value) until B3 adds the remote host.
nonisolated struct RepositoryHost: Sendable {
  let local: GitClientDependency

  private func localURL(_ location: RepositoryLocation) throws -> URL {
    guard let url = location.localURL else { throw RepositoryHostError.remoteUnavailable(location) }
    return url
  }

  // MARK: - Repository

  func worktrees(in repository: RepositoryLocation) async throws -> [Worktree] {
    try await local.worktrees(localURL(repository))
  }

  func pruneWorktrees(in repository: RepositoryLocation) async throws {
    try await local.pruneWorktrees(localURL(repository))
  }

  func localBranchNames(in repository: RepositoryLocation) async throws -> Set<String> {
    try await local.localBranchNames(localURL(repository))
  }

  func isValidBranchName(_ name: String, in repository: RepositoryLocation) async -> Bool {
    guard let url = repository.localURL else { return false }
    return await local.isValidBranchName(name, url)
  }

  func branchRefs(in repository: RepositoryLocation) async throws -> [String] {
    try await local.branchRefs(localURL(repository))
  }

  func automaticWorktreeBaseRef(in repository: RepositoryLocation) async -> String? {
    guard let url = repository.localURL else { return nil }
    return await local.automaticWorktreeBaseRef(url)
  }

  func ignoredFileCount(in repository: RepositoryLocation) async throws -> Int {
    try await local.ignoredFileCount(localURL(repository))
  }

  func untrackedFileCount(in repository: RepositoryLocation) async throws -> Int {
    try await local.untrackedFileCount(localURL(repository))
  }

  func isBareRepository(_ repository: RepositoryLocation) async throws -> Bool {
    try await local.isBareRepository(localURL(repository))
  }

  func deleteLocalBranch(
    named branchName: String,
    in repository: RepositoryLocation,
    force: Bool
  ) async throws -> LocalBranchDeletionOutcome {
    try await local.deleteLocalBranch(branchName, localURL(repository), force)
  }

  func repositoryWebURL(for repository: RepositoryLocation) async -> URL? {
    guard let url = repository.localURL else { return nil }
    return await local.repositoryWebURL(url)
  }

  func remoteNames(in repository: RepositoryLocation) async throws -> [String] {
    try await local.remoteNames(localURL(repository))
  }

  func fetchRemote(_ remote: String, in repository: RepositoryLocation) async throws {
    try await local.fetchRemote(remote, localURL(repository))
  }

  /// Creates a worktree in `repository`, which replaces the request's `repoRoot`.
  /// The other folders of the request are local URLs: the remote host (B3) maps them
  /// to paths on that host.
  func createWorktreeStream(
    in repository: RepositoryLocation,
    _ request: GitWorktreeCreateRequest
  ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error> {
    guard let url = repository.localURL else {
      return AsyncThrowingStream { $0.finish(throwing: RepositoryHostError.remoteUnavailable(repository)) }
    }
    var request = request
    request.repoRoot = url
    return local.createWorktreeStream(request)
  }

  // MARK: - Worktree

  /// Removes `worktree`. The local host moves the folder aside first and prunes it
  /// in the background.
  func removeWorktree(_ worktree: Worktree, deleteBranch: Bool) async throws -> URL {
    _ = try localURL(worktree.location)
    return try await local.removeWorktree(worktree, deleteBranch)
  }

  func branchName(of worktree: RepositoryLocation) async -> String? {
    guard let url = worktree.localURL else { return nil }
    return await local.branchName(url)
  }

  func lineChanges(in worktree: RepositoryLocation) async -> GitLineChanges? {
    guard let url = worktree.localURL else { return nil }
    return await local.lineChanges(url)
  }

  func renameBranch(in worktree: RepositoryLocation, to branchName: String) async throws {
    try await local.renameBranch(localURL(worktree), branchName)
  }
}
