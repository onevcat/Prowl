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
///   carries both (B3e);
/// - a worktree is created by the bundled `wt` script, which the lane sends to `bash -s`
///   on the host (B3c).
nonisolated struct RemoteRepositoryHost: Sendable {
  let hostProfileID: UUID
  private let lane: RemoteCommandLane
  private let git: GitClient
  /// For commands that can take long: a fetch, or removing a large worktree.
  private let longRunningExecutor: GitCommandExecutor
  private let longRunningGit: GitClient

  private let executor: GitCommandExecutor
  /// The `$HOME` read; concurrent first callers share it.
  private let home = LockIsolated<Task<String, Error>?>(nil)

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
      \(RemoteGitShell.printMarker)
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

  /// `$HOME` on the host as a physical path (`pwd -P`), so the worktrees placed under it
  /// get the IDs that git lists. Read once per host; a failed read is not kept.
  func homeDirectory() async throws -> String {
    let lane = lane
    let task = home.withValue { home in
      if let home { return home }
      let task = Task {
        let command = RemoteShellCommand(executable: "sh", arguments: ["-c", #"cd -- "$HOME" && pwd -P"#])
        let output = try RemoteGitShell.output(
          of: try await lane.run(RemoteGitShell.framed(command), .commandLane), command: command)
        let home = output.stdout.trimmingCharacters(in: .newlines)
        guard home.hasPrefix("/") else { throw RemoteRepositoryHostError.unsupported }
        return home
      }
      home = task
      return task
    }
    do {
      return try await task.value
    } catch {
      home.withValue { if $0 == task { $0 = nil } }
      throw error
    }
  }

  /// `path` resolved on the host (`pwd -P`); nil when it is not a folder that can be
  /// entered, or the host cannot answer.
  func physicalPath(_ path: String) async -> String? {
    let command = RemoteShellCommand(executable: "pwd", arguments: ["-P"], workingDirectory: path)
    let output = try? RemoteGitShell.output(
      of: try await lane.run(RemoteGitShell.framed(command), .commandLane), command: command)
    let resolved = output?.stdout.trimmingCharacters(in: .newlines) ?? ""
    return resolved.hasPrefix("/") ? resolved : nil
  }

  // MARK: - Worktree

  /// Creates a worktree with the bundled `wt` script, run by `bash -s` in the repository
  /// with the same arguments as on this Mac (`GitClient.createWorktreeArguments`). The
  /// request's folders are paths on the host. Progress lines arrive as `wt` prints them.
  /// The script itself resolves the new worktree's path (`pwd -P`), so the worktree's ID
  /// is the path that git lists, and no second command runs after `wt` succeeded.
  func createWorktreeStream(
    _ request: GitWorktreeCreateRequest, in repository: RepositoryLocation
  ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let worktree = try await createWorktree(request, in: repository) { continuation.yield(.outputLine($0)) }
          continuation.yield(.finished(worktree))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func createWorktree(
    _ request: GitWorktreeCreateRequest, in repository: RepositoryLocation,
    onLine: @escaping @Sendable (ShellStreamLine) -> Void
  ) async throws -> Worktree {
    let arguments = GitClient.createWorktreeArguments(
      baseDirectory: request.baseDirectory, name: request.name, copyIgnored: request.copyFiles.ignored,
      copyUntracked: request.copyFiles.untracked, baseRef: request.baseRef,
      directoryOverride: request.directoryOverride)
    let script = RemoteScript(
      text: try Self.creationScriptText(), arguments: arguments, workingDirectory: repository.path)
    let lines = WorktreeCreationLines(onLine: onLine)
    let outcome: RemoteCommandOutcome
    do {
      outcome = try await lane.stream(script, .worktreeCreation) { stream, text in lines.receive(stream, text) }
    } catch {
      throw RemoteWorktreeCreationError(underlying: error, addedPath: lines.addedPath)
    }
    let display = RemoteShellCommand(executable: "wt", arguments: arguments)
    let commandText = ([display.executable] + arguments).joined(separator: " ")
    do {
      _ = try RemoteGitShell.output(of: outcome, command: display)
    } catch let error as RemoteRepositoryHostError {
      throw RemoteWorktreeCreationError(underlying: error, addedPath: lines.addedPath)
    } catch {
      throw RemoteWorktreeCreationError(
        underlying: wrapShellError(error, operation: .worktreeCreate, command: commandText),
        addedPath: lines.addedPath)
    }
    guard let result = lines.result else {
      throw GitClientError.commandFailed(command: commandText, message: "Empty output")
    }
    return Worktree(
      name: request.name,
      detail: RemotePaths.relativePath(from: result.root, to: result.path),
      location: .remote(hostProfileID: hostProfileID, path: result.path),
      repositoryLocation: repository,
      // The host's creation time arrives with the next refresh; the worktree was made now.
      createdAt: Date()
    )
  }

  /// `wt` runs inside a function, so its standard output can be read: the script prints
  /// it after the marker, then the repository's and the new worktree's physical paths as
  /// the last two lines. Git's C locale applies, as `GitClient` sets it locally.
  ///
  /// The command substitution must not be part of a condition (`|| exit`, `if`): bash 5
  /// then ignores `set -e` inside it, and `wt` would go on after a failed
  /// `git worktree add`. Its status is read on the next line instead.
  ///
  /// A `git` function reports each `git worktree add` that succeeds on standard error
  /// (`PROWL_WORKTREE_ADDED`). It is the only proof that this attempt registered a
  /// worktree, so cleanup after a failure never removes one that another creation added.
  private static func creationScriptText() throws -> String {
    guard let wtScript = bundledWtScript else { throw RemoteRepositoryHostError.bundledScriptMissing }
    return """
      git() {
        command git "$@"
        prowl_git_status=$?
        if [ "$prowl_git_status" -eq 0 ] && [ "$1" = -C ] && [ "$3" = worktree ] && [ "$4" = add ]; then
          shift 4
          if [ "$1" = -b ]; then shift 2; fi
          printf 'PROWL_WORKTREE_ADDED\\t%s\\n' "$1" >&2
        fi
        return "$prowl_git_status"
      }
      prowl_wt() {
      \(wtScript)
      }
      LC_ALL=C LANG=C LC_MESSAGES=C
      export LC_ALL LANG LC_MESSAGES
      \(RemoteGitShell.printMarker)
      printf '\\n'
      prowl_root=$(pwd -P)
      prowl_output=$(prowl_wt "$@")
      prowl_status=$?
      [ "$prowl_status" -eq 0 ] || exit "$prowl_status"
      printf '%s\\n' "$prowl_output"
      prowl_path=$(printf '%s\\n' "$prowl_output" | awk 'NF { line = $0 } END { print line }')
      if [ -n "$prowl_path" ] && cd -- "$prowl_path" 2>/dev/null; then prowl_path=$(pwd -P); fi
      printf 'PROWL_ROOT\\t%s\\nPROWL_PATH\\t%s\\n' "$prowl_root" "$prowl_path"
      """
  }

  private static let bundledWtScript: String? = Bundle.main
    .url(forResource: "wt", withExtension: nil, subdirectory: "git-wt")
    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

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

/// The lines of a remote worktree creation: standard output before the marker is shell
/// startup output and is dropped; the `PROWL_ROOT` and `PROWL_PATH` records at the end are
/// the result, not progress.
private nonisolated final class WorktreeCreationLines: @unchecked Sendable {
  struct Result {
    let root: String
    let path: String
  }

  private let lock = NSLock()
  private let onLine: @Sendable (ShellStreamLine) -> Void
  private var sawMarker = false
  private var root: String?
  private var path: String?
  private var added: String?

  /// The path of a worktree that this attempt's `git worktree add` registered.
  var addedPath: String? { lock.withLock { added } }

  init(onLine: @escaping @Sendable (ShellStreamLine) -> Void) {
    self.onLine = onLine
  }

  var result: Result? {
    lock.withLock {
      guard let root, let path, !path.isEmpty else { return nil }
      return Result(root: root, path: path)
    }
  }

  func receive(_ stream: RemoteOutputStream, _ text: String) {
    let line: ShellStreamLine? = lock.withLock {
      switch stream {
      case .standardError:
        if text.hasPrefix("PROWL_WORKTREE_ADDED\t") {
          added = String(text.dropFirst("PROWL_WORKTREE_ADDED\t".count))
          return nil
        }
        return ShellStreamLine(source: .stderr, text: text)
      case .standardOutput:
        guard sawMarker else {
          if text.hasSuffix(RemoteGitShell.outputMarker) { sawMarker = true }
          return nil
        }
        if text.hasPrefix("PROWL_ROOT\t") {
          root = String(text.dropFirst("PROWL_ROOT\t".count))
          return nil
        }
        if text.hasPrefix("PROWL_PATH\t") {
          path = String(text.dropFirst("PROWL_PATH\t".count))
          return nil
        }
        return ShellStreamLine(source: .stdout, text: text)
      }
    }
    if let line { onLine(line) }
  }
}

/// A remote worktree creation that failed. `addedPath` is the worktree that this attempt
/// registered before the failure, if it did; nothing else may be cleaned up.
nonisolated struct RemoteWorktreeCreationError: Error, LocalizedError {
  let underlying: Error
  let addedPath: String?

  var errorDescription: String? { underlying.localizedDescription }
}
