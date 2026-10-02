import Foundation

nonisolated struct GithubRemoteInfo: Equatable, Sendable {
  let host: String
  let owner: String
  let repo: String

  nonisolated var key: RepoKey {
    RepoKey(owner: owner, repo: repo)
  }
}
