import Foundation

nonisolated struct PersistedRepositoryEntry: Codable, Equatable, Sendable {
  let path: String
  let kind: Repository.Kind
}
