import Foundation
import Testing

@testable import supacode

struct GitRemoteInfoTests {
  @Test func parseRepositoryWebInfoFromGitHubRemote() {
    let info = GitClient.parseRepositoryWebInfo("git@github.com:octo/repo.git")
    #expect(info == GitRemoteWebInfo(host: "github.com", repositoryPath: "octo/repo"))
    #expect(info?.repositoryURL == URL(string: "https://github.com/octo/repo"))
  }

  @Test func parseRepositoryWebInfoFromGitLabSubgroupRemote() {
    let info = GitClient.parseRepositoryWebInfo("https://gitlab.com/group/subgroup/repo.git")
    #expect(info == GitRemoteWebInfo(host: "gitlab.com", repositoryPath: "group/subgroup/repo"))
    #expect(info?.repositoryURL == URL(string: "https://gitlab.com/group/subgroup/repo"))
  }

  @Test func parseRepositoryWebInfoPreservesCustomPortAndPathPrefix() {
    let info = GitClient.parseRepositoryWebInfo("ssh://git@git.example.com:8443/scm/platform/repo.git")
    #expect(info == GitRemoteWebInfo(host: "git.example.com", repositoryPath: "scm/platform/repo", port: 8443))
    #expect(info?.repositoryURL == URL(string: "https://git.example.com:8443/scm/platform/repo"))
  }

  @Test func parseRepositoryWebInfoRejectsUnparseableRemote() {
    let info = GitClient.parseRepositoryWebInfo("/tmp/local-only/repo.git")
    #expect(info == nil)
  }

  @Test func parseSSHRemote() {
    let info = GitClient.parseGithubRemoteInfo("git@github.com:octo/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseSSHURLRemote() {
    let info = GitClient.parseGithubRemoteInfo("ssh://git@github.com/octo/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseHTTPSRemote() {
    let info = GitClient.parseGithubRemoteInfo("https://github.com/octo/repo")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parsePullRequestURLRemote() {
    let info = GitClient.parseGithubRemoteInfo("https://github.com/octo/repo/pull/123")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseEnterpriseRemote() {
    let info = GitClient.parseGithubRemoteInfo("git@github.acme.com:team/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.acme.com", owner: "team", repo: "repo"))
  }

  @Test func rejectsNonGithubRemote() {
    let info = GitClient.parseGithubRemoteInfo("https://gitlab.com/group/repo.git")
    #expect(info == nil)
  }

  @Test func prioritizesGithubRemotesForPullRequestLookup() {
    let fork = GithubRemoteInfo(host: "github.com", owner: "fork", repo: "project")
    let upstream = GithubRemoteInfo(host: "github.com", owner: "upstream", repo: "project")
    let team = GithubRemoteInfo(host: "github.com", owner: "team", repo: "project")
    let zed = GithubRemoteInfo(host: "github.com", owner: "zed", repo: "project")
    let duplicateTeam = GithubRemoteInfo(host: "github.com", owner: "TEAM", repo: "project")

    let infos = GitClient.prioritizedGithubRemoteInfos([
      (name: "zed", info: zed),
      (name: "upstream", info: upstream),
      (name: "origin", info: fork),
      (name: "team", info: team),
      (name: "zz-team", info: duplicateTeam),
    ])

    #expect(infos == [fork, upstream, team, zed])
  }
}
