import Foundation

nonisolated enum GithubCLIError: LocalizedError, Equatable {
  case unavailable
  case outdated
  case commandFailed(String)
  case rateLimited(retryAt: Date)
  /// GitHub answered the query but reported an error for this repository, with the error `type`
  /// GitHub attached to it (`NOT_FOUND`, `FORBIDDEN`, ...), when it attached one.
  case graphQLError(type: String?, message: String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return String(localized: "GitHub CLI is unavailable")
    case .outdated:
      return String(localized: "GitHub CLI is outdated. Update to the latest version.")
    case .commandFailed(let message):
      return message
    case .rateLimited(let retryAt):
      let time = retryAt.formatted(date: .omitted, time: .shortened)
      return String(localized: "GitHub rate-limited until \(time)")
    case .graphQLError(_, let message):
      return message
    }
  }

  // Whether a smaller per-repository query could still change the answer. A rate-limit refusal, a
  // missing or unusable gh, and a GraphQL error GitHub marks as final (the repository does not
  // exist or is not visible to the account) are answered with finality, so more requests cannot help.
  var allowsFallback: Bool {
    switch self {
    case .unavailable, .outdated, .rateLimited:
      return false
    case .commandFailed:
      return true
    case .graphQLError(let type, _):
      guard let type else {
        return true
      }
      return !Self.permanentGraphQLErrorTypes.contains(type.uppercased())
    }
  }

  private static let permanentGraphQLErrorTypes: Set<String> = ["NOT_FOUND", "FORBIDDEN", "INSUFFICIENT_SCOPES"]
}
