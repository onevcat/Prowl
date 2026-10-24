import ComposableArchitecture
import Foundation

struct GitClientDependency: Sendable {
  var repoRoot: @Sendable (URL) async throws -> URL
  var worktrees: @Sendable (URL) async throws -> [Worktree]
  var pruneWorktrees: @Sendable (URL) async throws -> Void
  var localBranchNames: @Sendable (URL) async throws -> Set<String>
  var isValidBranchName: @Sendable (String, URL) async -> Bool
  var branchRefs: @Sendable (URL) async throws -> [String]
  var branchRefOptions: @Sendable (URL) async throws -> [GitBranchRefOption]
  var remoteBranchRefs: @Sendable (String) async throws -> GitRemoteBranchRefs
  var defaultRemoteBranchRef: @Sendable (URL) async throws -> String?
  var automaticWorktreeBaseRef: @Sendable (URL) async -> String?
  var ignoredFileCount: @Sendable (URL) async throws -> Int
  var untrackedFileCount: @Sendable (URL) async throws -> Int
  var createWorktree:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String
    ) async throws
      -> Worktree
  var createWorktreeStream: @Sendable (GitWorktreeCreateRequest) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error>
  var removeWorktree: @Sendable (_ worktree: Worktree, _ deleteBranch: Bool) async throws -> URL
  var deleteLocalBranch:
    @Sendable (_ branchName: String, _ repoRoot: URL, _ force: Bool) async throws
      -> LocalBranchDeletionOutcome
  var isBareRepository: @Sendable (_ repoRoot: URL) async throws -> Bool
  var branchName: @Sendable (URL) async -> String?
  var lineChanges: @Sendable (URL) async -> GitLineChanges?
  var renameBranch: @Sendable (_ worktreeURL: URL, _ branchName: String) async throws -> Void
  var repositoryWebURL: @Sendable (_ repositoryRoot: URL) async -> URL?
  var githubRemoteInfos: @Sendable (_ repositoryRoot: URL) async -> [GithubRemoteInfo]
  var remoteInfo: @Sendable (_ repositoryRoot: URL) async -> GithubRemoteInfo?
  var remoteNames: @Sendable (_ repoRoot: URL) async throws -> [String]
  var fetchRemote: @Sendable (_ remote: String, _ repoRoot: URL) async throws -> Void
}

extension GitClientDependency: DependencyKey {
  static let liveValue = GitClientDependency(
    repoRoot: { try await GitClient.local.repoRoot(for: $0) },
    worktrees: { try await GitClient.local.worktrees(for: $0) },
    pruneWorktrees: { try await GitClient.local.pruneWorktrees(for: $0) },
    localBranchNames: { try await GitClient.local.localBranchNames(for: $0) },
    isValidBranchName: { branchName, repoRoot in
      await GitClient.local.isValidBranchName(branchName, for: repoRoot)
    },
    branchRefs: { try await GitClient.local.branchRefs(for: $0) },
    branchRefOptions: { try await GitClient.local.branchRefOptions(for: $0) },
    remoteBranchRefs: { try await GitClient.local.remoteBranchRefs(for: $0) },
    defaultRemoteBranchRef: { try await GitClient.local.defaultRemoteBranchRef(for: $0) },
    automaticWorktreeBaseRef: { await GitClient.local.automaticWorktreeBaseRef(for: $0) },
    ignoredFileCount: { try await GitClient.local.ignoredFileCount(for: $0) },
    untrackedFileCount: { try await GitClient.local.untrackedFileCount(for: $0) },
    createWorktree: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef in
      try await GitClient.local.createWorktree(
        named: name,
        in: repoRoot,
        baseDirectory: baseDirectory,
        copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
        baseRef: baseRef
      )
    },
    createWorktreeStream: { request in
      GitClient.local.createWorktreeStream(request)
    },
    removeWorktree: { worktree, deleteBranch in
      try await GitClient.local.removeWorktree(worktree, deleteBranch: deleteBranch)
    },
    deleteLocalBranch: { branchName, repoRoot, force in
      try await GitClient.local.deleteLocalBranch(named: branchName, for: repoRoot, force: force)
    },
    isBareRepository: { repoRoot in
      try await GitClient.local.isBareRepository(for: repoRoot)
    },
    branchName: { await GitClient.local.branchName(for: $0) },
    lineChanges: { await GitClient.local.lineChanges(at: $0) },
    renameBranch: { worktreeURL, branchName in
      try await GitClient.local.renameBranch(in: worktreeURL, to: branchName)
    },
    repositoryWebURL: { repositoryRoot in
      await GitClient.local.repositoryWebURL(for: repositoryRoot)
    },
    githubRemoteInfos: { repositoryRoot in
      await GitClient.local.githubRemoteInfos(for: repositoryRoot)
    },
    remoteInfo: { repositoryRoot in
      await GitClient.local.remoteInfo(for: repositoryRoot)
    },
    remoteNames: { repoRoot in
      try await GitClient.local.remoteNames(for: repoRoot)
    },
    fetchRemote: { remote, repoRoot in
      try await GitClient.local.fetchRemote(remote, for: repoRoot)
    }
  )
  static let testValue = liveValue
}

extension DependencyValues {
  var gitClient: GitClientDependency {
    get { self[GitClientDependency.self] }
    set { self[GitClientDependency.self] = newValue }
  }
}
