import Foundation

nonisolated struct GithubGraphQLPullRequestResponse: Decodable {
  let data: DataContainer

  func pullRequestsByBranch(
    aliasMap: [String: String],
    owner: String,
    repo: String
  ) -> [String: GithubPullRequest] {
    var results: [String: GithubPullRequest] = [:]
    for (alias, connection) in data.repository.pullRequestsByAlias {
      guard let branch = aliasMap[alias] else {
        continue
      }
      if let node = connection.bestMatchingPullRequest(owner: owner, repo: repo) {
        results[branch] = node.pullRequest
      }
    }
    return results
  }

  nonisolated struct DataContainer: Decodable {
    let repository: Repository
  }

  nonisolated struct Repository: Decodable {
    let pullRequestsByAlias: [String: PullRequestConnection]

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: DynamicKey.self)
      var results: [String: PullRequestConnection] = [:]
      for key in container.allKeys {
        results[key.stringValue] = try container.decode(PullRequestConnection.self, forKey: key)
      }
      self.pullRequestsByAlias = results
    }
  }

  nonisolated struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      self.intValue = nil
    }

    init?(intValue: Int) {
      self.stringValue = "\(intValue)"
      self.intValue = intValue
    }
  }

  nonisolated struct PullRequestConnection: Decodable {
    let nodes: [PullRequestNode]

    func bestMatchingPullRequest(owner: String, repo: String) -> PullRequestNode? {
      bestMatchingPullRequest(allowedHeadRepositories: [RepoKey(owner: owner, repo: repo)])
    }

    func bestMatchingPullRequest(allowedHeadRepositories: Set<RepoKey>) -> PullRequestNode? {
      // GitHub's `headRefName` filter is repository-agnostic: forks can have the
      // same branch name as the local worktree. Only a head repository matching
      // one of the local GitHub remotes proves this PR belongs to this checkout.
      let allowedKeys = Set(allowedHeadRepositories.map { $0.normalizedHeadRepositoryKey })
      let candidates = nodes.filter { $0.matchesAnyRepository(in: allowedKeys) }
      return candidates.max(by: { left, right in
        let leftRank = left.stateRank
        let rightRank = right.stateRank
        if leftRank != rightRank {
          return leftRank < rightRank
        }
        let leftDate = left.updatedAt ?? .distantPast
        let rightDate = right.updatedAt ?? .distantPast
        if leftDate != rightDate {
          return leftDate < rightDate
        }
        return left.number < right.number
      })
    }
  }

  nonisolated struct PullRequestNode: Decodable {
    let number: Int
    let title: String
    let state: String
    let additions: Int
    let deletions: Int
    let isDraft: Bool
    let reviewDecision: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let updatedAt: Date?
    let url: String
    let headRefName: String?
    let baseRefName: String?
    let commits: CommitConnection?
    let author: PullRequestAuthor?
    let statusCheckRollup: GithubPullRequestStatusCheckRollup?
    let mergeQueueEntry: GithubMergeQueueEntry?
    let headRepository: HeadRepository?

    var pullRequest: GithubPullRequest {
      GithubPullRequest(
        number: number,
        title: title,
        state: state,
        additions: additions,
        deletions: deletions,
        isDraft: isDraft,
        reviewDecision: reviewDecision,
        mergeable: mergeable,
        mergeStateStatus: mergeStateStatus,
        updatedAt: updatedAt,
        url: url,
        headRefName: headRefName,
        baseRefName: baseRefName,
        commitsCount: commits?.totalCount,
        authorLogin: author?.login,
        statusCheckRollup: statusCheckRollup,
        mergeQueueEntry: mergeQueueEntry
      )
    }

    var stateRank: Int {
      switch state.uppercased() {
      case "OPEN":
        return 2
      case "MERGED":
        return 1
      default:
        return 0
      }
    }

    func matches(owner: String, repo: String) -> Bool {
      guard let headRepository else {
        return false
      }
      return headRepository.normalizedKey == RepoKey(owner: owner, repo: repo).normalizedHeadRepositoryKey
    }

    func matchesAnyRepository(in normalizedKeys: Set<String>) -> Bool {
      guard let headRepository else {
        return false
      }
      return normalizedKeys.contains(headRepository.normalizedKey)
    }

  }

  nonisolated struct CommitConnection: Decodable {
    let totalCount: Int
  }

  nonisolated struct PullRequestAuthor: Decodable {
    let login: String
  }

  nonisolated struct HeadRepository: Decodable {
    let name: String
    let owner: HeadRepositoryOwner

    nonisolated var normalizedKey: String {
      RepoKey(owner: owner.login, repo: name).normalizedHeadRepositoryKey
    }
  }

  nonisolated struct HeadRepositoryOwner: Decodable {
    let login: String
  }
}

extension RepoKey {
  nonisolated var normalizedHeadRepositoryKey: String {
    "\(owner.lowercased())/\(repo.lowercased())"
  }
}
