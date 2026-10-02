import Foundation

nonisolated struct GithubPullRequest: Decodable, Equatable, Hashable {
  let number: Int
  let title: String
  let state: String
  let additions: Int
  let deletions: Int
  let isDraft: Bool
  let reviewDecision: String?
  var mergeable: String?
  var mergeStateStatus: String?
  let updatedAt: Date?
  let url: String
  let headRefName: String?
  let baseRefName: String?
  let commitsCount: Int?
  let authorLogin: String?
  let statusCheckRollup: GithubPullRequestStatusCheckRollup?
  // `var` (rather than `let`) keeps it decodable and gives the memberwise init an
  // implicit `nil` default, so existing construction sites (tests, caches) compile
  // unchanged; only the GraphQL decode path populates it.
  var mergeQueueEntry: GithubMergeQueueEntry?
}
