import Foundation

nonisolated enum GithubCLIError: LocalizedError, Equatable {
  case unavailable
  case outdated
  case commandFailed(String)
  case rateLimited(retryAt: Date)

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
    }
  }
}
