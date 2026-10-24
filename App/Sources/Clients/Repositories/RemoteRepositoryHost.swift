import ConcurrencyExtras
import Dependencies
import Foundation
import Sharing

/// Repository operations on one SSH host (docs-ai 084 B3), the remote input of
/// `RepositoryHost`. Paths are paths on that host.
///
/// The `GitClient` methods that only run commands run unchanged through the host's
/// command lane (`GitCommandExecutor.remote`). The local-only paths of `GitClient`
/// (009) are replaced:
///
/// - the worktree list, creation times and line counts come from the batched refresh
///   (`RemoteRepositoryRefresh`);
/// - a worktree is removed with `git worktree remove`, not moved aside on this Mac;
/// - the branch name and line changes of one worktree are not read here: the local
///   monitors that ask for them do not run for remote repositories, and the refresh
///   carries both (B3d).
nonisolated struct RemoteRepositoryHost: Sendable {
  let hostProfileID: UUID
  private let lane: RemoteCommandLane
  private let git: GitClient
  /// For commands that can take long: a fetch, or removing a large worktree.
  private let longRunningExecutor: GitCommandExecutor
  private let longRunningGit: GitClient

  private let executor: GitCommandExecutor

  init(hostProfileID: UUID, lane: RemoteCommandLane) {
    self.hostProfileID = hostProfileID
    self.lane = lane
    let gitCache = LockIsolated<GitExecutable?>(nil)
    executor = .remote(lane: lane, limits: .commandLane, gitCache: gitCache)
    git = GitClient(executor: executor)
    longRunningExecutor = .remote(lane: lane, limits: .longRunning, gitCache: gitCache)
    longRunningGit = GitClient(executor: longRunningExecutor)
  }

  /// `GitClient` reads a path from a URL; the URL never touches this Mac's disk.
  private static func url(_ path: String) -> URL {
    URL(filePath: path, directoryHint: .notDirectory)
  }

  // MARK: - Refresh

  /// Throws a `RemoteRepositoryRefreshError`, or a `RemoteRepositoryHostError` when the
  /// lane refuses to connect (for example after the host's authority changed).
  func refresh(repositoryPath: String) async throws -> RemoteRepositoryRefresh {
    let outcome: RemoteCommandOutcome
    do {
      outcome = try await lane.runScript(RemoteRepositoryRefresh.script(repositoryPath: repositoryPath), .commandLane)
    } catch is RemoteShellCommand.ValidationError {
      // Only a NUL byte in the path fails validation; such a path cannot exist.
      throw RemoteRepositoryRefreshError.missingFolder
    }
    return try RemoteRepositoryRefresh.parse(outcome)
  }

  // MARK: - Repository

  func worktrees(in repository: RepositoryLocation) async throws -> [Worktree] {
    try await refresh(repositoryPath: repository.path).worktrees(in: repository)
  }

  func pruneWorktrees(at path: String) async throws {
    try await git.pruneWorktrees(for: Self.url(path))
  }

  func localBranchNames(at path: String) async throws -> Set<String> {
    try await git.localBranchNames(for: Self.url(path))
  }

  /// Checked with this Mac's git, outside a repository: the rules of a branch name do not
  /// depend on the repository, and a connection error must not read as an invalid name.
  func isValidBranchName(_ name: String, at _: String) async -> Bool {
    await GitClient.local.isValidBranchName(name, for: URL(filePath: "/", directoryHint: .isDirectory))
  }

  func branchRefs(at path: String) async throws -> [String] {
    try await git.branchRefs(for: Self.url(path))
  }

  func automaticWorktreeBaseRef(at path: String) async -> String? {
    await git.automaticWorktreeBaseRef(for: Self.url(path))
  }

  /// Counted on the host, so a large list (an ignored `node_modules`) never crosses the
  /// connection or reaches the lane's output budget.
  func ignoredFileCount(at path: String) async throws -> Int {
    try await fileCount(at: path, ignored: true)
  }

  func untrackedFileCount(at path: String) async throws -> Int {
    try await fileCount(at: path, ignored: false)
  }

  private func fileCount(at path: String, ignored: Bool) async throws -> Int {
    let text = """
      set -o pipefail
      printf '\\036PROWL_OUTPUT\\036'
      git -C "$1" ls-files --others \(ignored ? "-i " : "")--exclude-standard | wc -l
      """
    let script = RemoteScript(text: text, arguments: [path])
    let command = RemoteShellCommand(executable: "git", arguments: ["-C", path, "ls-files", "--others"])
    let output = try RemoteGitShell.output(of: try await lane.runScript(script, .commandLane), command: command)
    guard let count = Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw RemoteRepositoryRefreshError.incompleteOutput
    }
    return count
  }

  func isBareRepository(at path: String) async throws -> Bool {
    try await git.isBareRepository(for: Self.url(path))
  }

  /// The same rules as the local host: a branch that does not exist is not found, and
  /// `main`, `master` and the default branch of `origin` are protected. The local host
  /// ignores a failed default-branch read; here it fails the deletion, because a dropped
  /// connection would otherwise remove the protection of the default branch.
  func deleteLocalBranch(named name: String, at path: String, force: Bool) async throws
    -> LocalBranchDeletionOutcome
  {
    guard !name.isEmpty else { return .notRequested }
    let normalizedName = name.lowercased()
    guard try await localBranchNames(at: path).contains(normalizedName) else { return .notFound }
    var protectedNames: Set<String> = ["main", "master"]
    if let defaultBranch = try await originDefaultBranch(at: path) {
      protectedNames.insert(defaultBranch.lowercased())
    }
    guard !protectedNames.contains(normalizedName) else { return .protected }
    try await runGit(["-C", path, "branch", force ? "-D" : "-d", name], operation: .branchDelete)
    return .deleted
  }

  /// The branch that `refs/remotes/origin/HEAD` names; nil when it is not set.
  private func originDefaultBranch(at path: String) async throws -> String? {
    let output: String
    do {
      output = try await runGit(
        ["-C", path, "symbolic-ref", "-q", "refs/remotes/origin/HEAD"], operation: .defaultRemoteBranchRef)
    } catch let GitClientError.commandFailed(_, message) where message.isEmpty {
      // `symbolic-ref -q` exits 1 without output when the ref is not set.
      return nil
    }
    let ref = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "refs/remotes/origin/"
    return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : nil
  }

  @discardableResult
  private func runGit(
    _ arguments: [String], operation: GitOperation, executor: GitCommandExecutor? = nil
  ) async throws -> String {
    let executor = executor ?? self.executor
    let git = try await executor.resolveGit(false)
    do {
      return try await git.run(arguments, shell: executor.shell).stdout
    } catch let error as RemoteRepositoryHostError {
      throw error
    } catch {
      throw wrapShellError(
        error, operation: operation,
        command: ([git.url.path(percentEncoded: false)] + arguments).joined(separator: " "))
    }
  }

  func repositoryWebURL(at path: String) async -> URL? {
    await git.repositoryWebURL(for: Self.url(path))
  }

  func githubRemoteInfos(at path: String) async -> [GithubRemoteInfo] {
    await git.githubRemoteInfos(for: Self.url(path))
  }

  func remoteInfo(at path: String) async -> GithubRemoteInfo? {
    await git.remoteInfo(for: Self.url(path))
  }

  func remoteNames(at path: String) async throws -> [String] {
    try await git.remoteNames(for: Self.url(path))
  }

  func fetchRemote(_ remote: String, at path: String) async throws {
    try await longRunningGit.fetchRemote(remote, for: Self.url(path))
  }

  // MARK: - Worktree

  /// Removes a registered worktree with `git worktree remove --force`, as the local host
  /// does after it moved the folder aside. A path that git does not list is refused.
  func removeWorktree(_ worktree: Worktree, deleteBranch: Bool) async throws {
    let rootPath = worktree.repositoryLocation.path
    let path = worktree.location.path
    let list = try await runGit(["-C", rootPath, "worktree", "list", "--porcelain"], operation: .worktreeList)
    guard GitClient.parseGitWorktreePorcelainPaths(list).contains(path) else {
      throw GitClientError.worktreeNotRegistered(path: path)
    }
    try await runGit(
      ["-C", rootPath, "worktree", "remove", "--force", path], operation: .worktreeRemove,
      executor: longRunningExecutor)
    if deleteBranch {
      _ = try? await deleteLocalBranch(named: worktree.name, at: rootPath, force: false)
    }
  }

  func renameBranch(at worktreePath: String, to name: String) async throws {
    try await git.renameBranch(in: Self.url(worktreePath), to: name)
  }
}

/// Finds the remote host of a host profile for `RepositoryHost`.
nonisolated struct RemoteRepositoryHostClient: Sendable {
  /// Nil when remote folders cannot run here (tests, and builds before C1 adds them).
  var host: @Sendable (_ hostProfileID: UUID) async throws -> RemoteRepositoryHost?

  static let unavailable = RemoteRepositoryHostClient(host: { _ in nil })
}

extension RemoteRepositoryHostClient: DependencyKey {
  static let liveValue: RemoteRepositoryHostClient = {
    // One host per profile, so its resolved `git` is kept across operations. An edited
    // profile gets a new host.
    let hosts = LockIsolated<[UUID: (profile: HostProfile, host: RemoteRepositoryHost)]>([:])
    return RemoteRepositoryHostClient(host: { hostProfileID in
      @Shared(.hostProfiles) var hostProfiles: [HostProfile]
      guard let profile = hostProfiles.first(where: { $0.id == hostProfileID }) else {
        throw RepositoryHostError.hostProfileMissing(hostProfileID)
      }
      return hosts.withValue { hosts in
        if let cached = hosts[hostProfileID], cached.profile == profile { return cached.host }
        let host = RemoteRepositoryHost(hostProfileID: hostProfileID, lane: .leased(profile))
        hosts[hostProfileID] = (profile, host)
        return host
      }
    })
  }()
  static let testValue = RemoteRepositoryHostClient.unavailable
}
