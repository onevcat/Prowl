public struct BootstrapProfilePayloadModel: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let command: String
  public let environment: [String: String]
  public let script: String
  public let timeoutSeconds: Int

  public enum CodingKeys: String, CodingKey {
    case id
    case name
    case description
    case command
    case environment
    case script
    case timeoutSeconds = "timeout_seconds"
  }

  public init(
    id: String,
    name: String,
    description: String,
    command: String,
    environment: [String: String],
    script: String,
    timeoutSeconds: Int
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.command = command
    self.environment = environment
    self.script = script
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct BootstrapProfilesPayload: Codable, Equatable, Sendable {
  public let path: String
  public let profiles: [BootstrapProfilePayloadModel]

  public init(path: String, profiles: [BootstrapProfilePayloadModel]) {
    self.path = path
    self.profiles = profiles
  }
}

public struct BootstrapProfilePayload: Codable, Equatable, Sendable {
  public let path: String
  public let profile: BootstrapProfilePayloadModel

  public init(path: String, profile: BootstrapProfilePayloadModel) {
    self.path = path
    self.profile = profile
  }
}

public struct BootstrapDeletePayload: Codable, Equatable, Sendable {
  public let path: String
  public let id: String

  public init(path: String, id: String) {
    self.path = path
    self.id = id
  }
}
