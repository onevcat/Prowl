import Foundation

nonisolated enum CodeHost: Equatable, Hashable, Sendable {
  case github
  case gitlab
  case bitbucket
  case codeberg
  case sourcehut
  case gitea
  case unknown

  var displayName: String {
    switch self {
    case .github: "GitHub"
    case .gitlab: "GitLab"
    case .bitbucket: "Bitbucket"
    case .codeberg: "Codeberg"
    case .sourcehut: "SourceHut"
    case .gitea: "Gitea"
    case .unknown: String(localized: "Code Host")
    }
  }

  static func from(host: String?) -> CodeHost {
    guard let host, !host.isEmpty else { return .unknown }
    let lowered = host.lowercased()
    if lowered.contains("github") { return .github }
    if lowered.contains("gitlab") { return .gitlab }
    if lowered.contains("bitbucket") { return .bitbucket }
    if lowered.contains("codeberg") { return .codeberg }
    if lowered == "sr.ht" || lowered.hasSuffix(".sr.ht") || lowered.contains("sourcehut") { return .sourcehut }
    if lowered.contains("gitea") { return .gitea }
    return .unknown
  }
}
