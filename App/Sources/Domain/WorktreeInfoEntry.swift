import Foundation

struct WorktreeInfoEntry: Equatable, Hashable {
  var addedLines: Int?
  var removedLines: Int?
  var pullRequest: GithubPullRequest?
  var skippedUntrackedFileCount: Int

  init(
    addedLines: Int? = nil,
    removedLines: Int? = nil,
    pullRequest: GithubPullRequest? = nil,
    skippedUntrackedFileCount: Int = 0
  ) {
    self.addedLines = addedLines
    self.removedLines = removedLines
    self.pullRequest = pullRequest
    self.skippedUntrackedFileCount = skippedUntrackedFileCount
  }

  var isEmpty: Bool {
    addedLines == nil && removedLines == nil && pullRequest == nil && skippedUntrackedFileCount == 0
  }
}
