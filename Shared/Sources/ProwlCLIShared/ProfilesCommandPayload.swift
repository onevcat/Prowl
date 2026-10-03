import Foundation

public struct ProfilesCommandPayload: Codable, Sendable, Equatable {
  public let count: Int
  public let profiles: [ProfilesCommandProfile]

  public init(count: Int, profiles: [ProfilesCommandProfile]) {
    self.count = count
    self.profiles = profiles
  }
}

public struct ProfilesCommandProfile: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let enabled: Bool
  public let runtime: String
  public let availability: ProfilesCommandAvailability

  public init(
    id: String,
    name: String,
    enabled: Bool,
    runtime: String,
    availability: ProfilesCommandAvailability
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.runtime = runtime
    self.availability = availability
  }
}

public struct ProfilesCommandAvailability: Codable, Sendable, Equatable {
  public let status: ProfilesCommandAvailabilityStatus
  public let reason: String?

  public init(status: ProfilesCommandAvailabilityStatus, reason: String? = nil) {
    self.status = status
    self.reason = reason
  }
}

public enum ProfilesCommandAvailabilityStatus: String, Codable, Sendable, Equatable {
  case available
  case unavailable
  case unknown
}
