import Foundation

nonisolated enum PullRequestMergeStrategy: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
  case merge
  case squash
  case rebase

  var id: String { rawValue }

  var title: String {
    switch self {
    case .merge:
      return String(localized: "Merge")
    case .squash:
      return String(localized: "Squash")
    case .rebase:
      return String(localized: "Rebase")
    }
  }

  var ghArgument: String {
    rawValue
  }
}
