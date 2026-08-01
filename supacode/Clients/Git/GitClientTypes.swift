import Foundation

enum GitOperation: String {
  case repoRoot = "repo_root"
  case worktreeList = "worktree_list"
  case worktreeCreate = "worktree_create"
  case worktreeRemove = "worktree_remove"
  case worktreePrune = "worktree_prune"
  case repoIsBare = "repo_is_bare"
  case branchNames = "branch_names"
  case branchNameValidation = "branch_name_validation"
  case branchRefs = "branch_refs"
  case defaultRemoteBranchRef = "default_remote_branch_ref"
  case localHeadRef = "local_head_ref"
  case ignoredFileCount = "ignored_file_count"
  case untrackedFileCount = "untracked_file_count"
  case branchRename = "branch_rename"
  case branchDelete = "branch_delete"
  case lineChanges = "line_changes"
  case diffNameStatus = "diff_name_status"
  case outgoingChangesComparison = "outgoing_changes_comparison"
  case outgoingDiffNameStatus = "outgoing_diff_name_status"
  case untrackedFilePaths = "untracked_file_paths"
  case showFile = "show_file"
  case remoteInfo = "remote_info"
  case remoteList = "remote_list"
  case fetchRemote = "fetch_remote"
  case remoteBranchRefs = "remote_branch_refs"
}

nonisolated struct GitLineChanges: Equatable, Sendable {
  let added: Int
  let removed: Int
  let skippedUntrackedFileCount: Int

  init(
    added: Int,
    removed: Int,
    skippedUntrackedFileCount: Int = 0
  ) {
    self.added = added
    self.removed = removed
    self.skippedUntrackedFileCount = skippedUntrackedFileCount
  }

  var isEmpty: Bool {
    added == 0 && removed == 0 && skippedUntrackedFileCount == 0
  }
}

nonisolated struct UntrackedLineCountResult: Equatable, Sendable {
  let lines: Int
  let skippedFileCount: Int
}

enum GitClientError: LocalizedError {
  case commandFailed(command: String, message: String)
  case worktreeNotRegistered(path: String)
  case worktreeRecoveryFailed(path: String, removalError: String, recoveryError: String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let command, let message):
      if message.isEmpty {
        return "Git command failed: \(command)"
      }
      return "Git command failed: \(command)\n\(message)"
    case .worktreeNotRegistered(let path):
      return "Git no longer recognizes this worktree: \(path)"
    case .worktreeRecoveryFailed(let path, let removalError, let recoveryError):
      return "\(removalError)\nUnable to restore the worktree directory at \(path): \(recoveryError)"
    }
  }
}

nonisolated struct GitWorktreeCreateRequest: Equatable, Sendable {
  struct CopyFiles: Equatable, Sendable {
    var ignored: Bool
    var untracked: Bool
  }

  var name: String
  var repoRoot: URL
  var baseDirectory: URL
  var copyFiles: CopyFiles
  var baseRef: String
  var directoryOverride: URL?

  init(
    name: String,
    repoRoot: URL,
    baseDirectory: URL,
    copyFiles: CopyFiles,
    baseRef: String,
    directoryOverride: URL? = nil
  ) {
    self.name = name
    self.repoRoot = repoRoot
    self.baseDirectory = baseDirectory
    self.copyFiles = copyFiles
    self.baseRef = baseRef
    self.directoryOverride = directoryOverride
  }
}

enum GitWorktreeCreateEvent: Equatable, Sendable {
  case outputLine(ShellStreamLine)
  case finished(Worktree)
}

enum LocalBranchDeletionOutcome: Equatable, Sendable {
  case deleted
  case notFound
  case protected
  case notRequested
}

nonisolated enum GitRemoteMatcher {
  static func matchingRemote(for ref: String, from remotes: [String]) -> String? {
    remotes
      .sorted { $0.count > $1.count }
      .first { ref.hasPrefix("\($0)/") }
  }
}

nonisolated enum GitBranchRefKind: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
  case local
  case remoteTracking = "remote_tracking"
  case fetchedRemote = "fetched_remote"

  var title: String {
    switch self {
    case .local:
      return "Local Branches"
    case .remoteTracking:
      return "Remote Branches"
    case .fetchedRemote:
      return "Fetched Remote Branches"
    }
  }
}

nonisolated struct GitBranchRefOption: Codable, Equatable, Hashable, Sendable, Identifiable {
  var ref: String
  var kind: GitBranchRefKind

  var id: String {
    "\(kind.rawValue):\(ref)"
  }

  init(ref: String, kind: GitBranchRefKind) {
    self.ref = ref
    self.kind = kind
  }
}

nonisolated enum OutgoingBaseSource: Equatable, Sendable {
  case pullRequest
  case repositorySetting
  case automatic

  var label: String {
    switch self {
    case .pullRequest: "pull request base"
    case .repositorySetting: "worktree base setting"
    case .automatic: "default branch"
    }
  }
}

nonisolated struct OutgoingBaseResolution: Equatable, Sendable {
  /// Fully qualified ref (`refs/remotes/...` or `refs/heads/...`) so
  /// `rev-parse`/`merge-base` never hit Git's short-name disambiguation,
  /// which prefers a local branch literally named `<remote>/<branch>`.
  let ref: String
  let displayName: String
  let source: OutgoingBaseSource
}

nonisolated struct GitPullRequestBase: Equatable, Sendable {
  let url: String
  let baseRefName: String
}

nonisolated enum OutgoingBaseResolutionError: Error, Equatable, Sendable, LocalizedError {
  case incompletePullRequest
  case invalidPullRequestURL(String)
  case noMatchingRemote(host: String, repositoryPath: String)
  case multipleMatchingRemotes([String])
  case unresolvedPullRequestBase(remote: String, branch: String)
  case unresolvedRepositorySettingBase(String)
  case noResolvableBase

  var errorDescription: String? {
    switch self {
    case .incompletePullRequest:
      "The cached pull request has no base branch yet. Refresh pull request status and try again."
    case .invalidPullRequestURL(let url):
      "Prowl could not parse the pull request URL (\(url))."
    case .noMatchingRemote(let host, let repositoryPath):
      "No local remote matches the pull request repository \(host)/\(repositoryPath). "
        + "Add that remote and fetch it, then try again."
    case .multipleMatchingRemotes(let names):
      "Multiple remotes point at the pull request repository: \(names.joined(separator: ", ")). "
        + "Remove or rename one so Prowl can pick the base remote."
    case .unresolvedPullRequestBase(let remote, let branch):
      "The pull request base \(remote)/\(branch) is not available locally. "
        + "Run `git fetch \(remote)` and try again."
    case .unresolvedRepositorySettingBase(let ref):
      "The configured worktree base \(ref) does not exist locally. "
        + "Fetch it, or update the base branch in the repository's settings."
    case .noResolvableBase:
      "No pull request, configured base branch, or default remote branch was found to compare against."
    }
  }
}

nonisolated struct GitOutgoingChangesComparison: Equatable, Sendable {
  let base: OutgoingBaseResolution
  let mergeBase: String
  let head: String
}

nonisolated struct GitRemoteBranchRefs: Equatable, Sendable {
  var options: [GitBranchRefOption]
  var defaultBaseRef: String?
}

nonisolated enum GitRemoteNaming {
  static func repositoryName(fromRemoteURL remoteURL: String) -> String {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty else {
      return ""
    }
    let separatorIndex = trimmed.lastIndex { $0 == "/" || $0 == ":" }
    let component =
      separatorIndex.map { String(trimmed[trimmed.index(after: $0)...]) }
      ?? trimmed
    return component.hasSuffix(".git") ? String(component.dropLast(4)) : component
  }
}

struct GitWtWorktreeEntry: Decodable, Equatable {
  let branch: String
  let path: String
  let head: String
  let isBare: Bool

  enum CodingKeys: String, CodingKey {
    case branch
    case path
    case head
    case isBare = "is_bare"
  }
}
