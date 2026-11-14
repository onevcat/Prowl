import Foundation
import Testing

@testable import Prowl

struct WorkspaceChildRowModelTests {
  @Test func pullRequestURLUsesTheChildPullRequest() {
    let row = makeRow(pullRequestURL: "https://github.com/onevcat/demo/pull/7")

    #expect(row.pullRequestURL == URL(string: "https://github.com/onevcat/demo/pull/7"))
  }

  @Test func pullRequestURLIsNilWithoutAPullRequest() {
    #expect(makeRow(pullRequestURL: nil).pullRequestURL == nil)
  }

  @Test func pullRequestURLRejectsANonWebURL() {
    #expect(makeRow(pullRequestURL: "file:///tmp/pr").pullRequestURL == nil)
    #expect(makeRow(pullRequestURL: "not a url").pullRequestURL == nil)
  }

  private func makeRow(pullRequestURL: String?) -> WorkspaceChildRowModel {
    WorkspaceChildRowModel(
      id: "/tmp/workspace/child",
      repositoryName: "child",
      branchName: "feature",
      info: pullRequestURL.map { WorktreeInfoEntry(pullRequest: makePullRequest(url: $0)) },
      workingDirectory: URL(fileURLWithPath: "/tmp/workspace/child")
    )
  }

  private func makePullRequest(url: String) -> GithubPullRequest {
    GithubPullRequest(
      number: 7,
      title: "Demo",
      state: "OPEN",
      additions: 0,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: url,
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "octocat",
      statusCheckRollup: nil
    )
  }
}
