import Foundation

nonisolated enum MergedWorktreeAction: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
  case archive
  case delete

  var id: String { rawValue }

  var title: String {
    switch self {
    case .archive: String(localized: "Archive")
    case .delete: String(localized: "Delete")
    }
  }
}
