import Foundation

nonisolated enum AgentIslandDisplayPreference: Codable, Equatable, Hashable, Sendable {
  case automatic
  case display(id: String, name: String)

  private enum CodingKeys: String, CodingKey {
    case mode
    case id
    case name
  }

  private enum Mode: String, Codable {
    case automatic
    case display
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Mode.self, forKey: .mode) {
    case .automatic:
      self = .automatic
    case .display:
      self = .display(
        id: try container.decode(String.self, forKey: .id),
        name: try container.decode(String.self, forKey: .name)
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .automatic:
      try container.encode(Mode.automatic, forKey: .mode)
    case .display(let id, let name):
      try container.encode(Mode.display, forKey: .mode)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
    }
  }
}
