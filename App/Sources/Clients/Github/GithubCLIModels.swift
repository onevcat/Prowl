import Foundation

nonisolated struct GithubAccountOverride: Codable, Equatable, Hashable, Sendable {
  let host: String
  let login: String

  init(host: String, login: String) {
    self.host = host
    self.login = login
  }

  var normalized: GithubAccountOverride? {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedHost.isEmpty, !trimmedLogin.isEmpty else {
      return nil
    }
    return GithubAccountOverride(host: trimmedHost, login: trimmedLogin)
  }
}

struct GithubAuthStatus: Equatable, Sendable {
  let username: String
  let host: String
}

nonisolated struct GithubAuthStatusSnapshot: Equatable, Sendable {
  let hosts: [String: [GithubAuthAccountStatus]]

  init(hosts: [String: [GithubAuthAccountStatus]]) {
    self.hosts = hosts
  }

  init(response: GithubAuthStatusResponse) {
    hosts = Dictionary(
      response.hosts.map { host, accounts in
        let statuses = accounts.map {
          GithubAuthAccountStatus(
            host: $0.host.isEmpty ? host : $0.host,
            login: $0.login,
            active: $0.active,
            state: $0.state,
            gitProtocol: $0.gitProtocol,
            scopes: $0.scopes,
            tokenSource: $0.tokenSource
          )
        }
        return (host, statuses)
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  var sortedHosts: [String] {
    hosts.keys.sorted { lhs, rhs in
      if lhs == "github.com" { return true }
      if rhs == "github.com" { return false }
      return lhs < rhs
    }
  }

  var allAccounts: [GithubAuthAccountStatus] {
    sortedHosts.flatMap { accounts(on: $0) }
  }

  func accounts(on host: String) -> [GithubAuthAccountStatus] {
    hosts[host] ?? []
  }

  func activeAccount(on host: String) -> GithubAuthAccountStatus? {
    accounts(on: host).first(where: \.active)
  }
}

nonisolated struct GithubAuthAccountStatus: Equatable, Identifiable, Sendable {
  let host: String
  let login: String
  let active: Bool
  let state: String?
  let gitProtocol: String?
  let scopes: String?
  let tokenSource: String?

  var id: String {
    "\(host)/\(login)"
  }

  var override: GithubAccountOverride {
    GithubAccountOverride(host: host, login: login)
  }
}

struct GithubAuthStatusResponse: Sendable {
  let hosts: [String: [GithubAuthAccount]]

  struct GithubAuthAccount: Sendable {
    let host: String
    let active: Bool
    let login: String
    let state: String?
    let gitProtocol: String?
    let scopes: String?
    let tokenSource: String?
  }
}

extension GithubAuthStatusResponse: Decodable {
  private enum CodingKeys: String, CodingKey {
    case hosts
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.hosts = try container.decode([String: [GithubAuthAccount]].self, forKey: .hosts)
  }
}

extension GithubAuthStatusResponse.GithubAuthAccount: Decodable {
  private enum CodingKeys: String, CodingKey {
    case host
    case active
    case login
    case state
    case gitProtocol
    case scopes
    case tokenSource
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
    self.active = try container.decode(Bool.self, forKey: .active)
    self.login = try container.decode(String.self, forKey: .login)
    state = try container.decodeIfPresent(String.self, forKey: .state)
    gitProtocol = try container.decodeIfPresent(String.self, forKey: .gitProtocol)
    scopes = try container.decodeIfPresent(String.self, forKey: .scopes)
    tokenSource = try container.decodeIfPresent(String.self, forKey: .tokenSource)
  }
}

nonisolated struct RepoKey: Hashable, Sendable {
  let owner: String
  let repo: String
}

nonisolated struct CrossRepoPullRequestRequest: Sendable, Hashable {
  let owner: String
  let repo: String
  let branches: [String]
  let allowedHeadRepositories: Set<RepoKey>

  init(
    owner: String,
    repo: String,
    branches: [String],
    allowedHeadRepositories: Set<RepoKey>? = nil
  ) {
    self.owner = owner
    self.repo = repo
    self.branches = branches
    self.allowedHeadRepositories = allowedHeadRepositories ?? [RepoKey(owner: owner, repo: repo)]
  }

  var key: RepoKey {
    RepoKey(owner: owner, repo: repo)
  }
}

nonisolated struct CrossRepoPullRequestResult: Sendable {
  let successByRepo: [RepoKey: [String: GithubPullRequest]]
  let failedRepos: [RepoKey: GithubCLIError]

  init(
    successByRepo: [RepoKey: [String: GithubPullRequest]] = [:],
    failedRepos: [RepoKey: GithubCLIError] = [:]
  ) {
    self.successByRepo = successByRepo
    self.failedRepos = failedRepos
  }
}

struct GithubPullRequestsRequest: Sendable {
  let host: String
  let owner: String
  let repo: String
}

nonisolated struct GithubRepoViewRemoteInfoResponse: Decodable, Sendable {
  let owner: Owner
  let name: String
  let url: String

  nonisolated var remoteInfo: GithubRemoteInfo? {
    guard let host = URL(string: url)?.host else {
      return nil
    }
    return GithubRemoteInfo(host: host, owner: owner.login, repo: name)
  }

  nonisolated struct Owner: Decodable, Sendable {
    let login: String
  }
}
