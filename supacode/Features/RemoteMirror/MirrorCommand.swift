import Foundation

nonisolated struct MirrorCommandRequest: Codable, Equatable, Sendable {
  let requestID: UUID
  let request: Request

  struct Request: Codable, Equatable, Sendable {
    let output: String
    let command: Command
    init(command: Command) {
      output = "json"
      self.command = command
    }
  }

  enum Command: Codable, Equatable, Sendable {
    case list(Empty)
    case profiles(Empty)
    case create(Create)
    case agentsDispatch(Dispatch)
    case send(MirrorShellInput)

    var targetPaneID: UUID? {
      switch self {
      case .agentsDispatch(let input): UUID(uuidString: input.pane)
      case .send(let input): UUID(uuidString: input.selector.value)
      default: nil
      }
    }
  }

  struct Dispatch: Codable, Equatable, Sendable {
    let pane: String
    let prompt: String
  }

  struct Empty: Codable, Equatable, Sendable {}
  struct Create: Codable, Equatable, Sendable {
    let resource: String
    let selector: Selector
    let launch: Launch
    let background: Bool
    init(worktreeID: String, profileID: String, prompt: String?) {
      resource = "tab"
      selector = .worktree(worktreeID)
      launch = Launch(profile: profileID, prompt: prompt)
      background = true
    }
  }
  enum Selector: Codable, Equatable, Sendable { case worktree(String) }
  struct Launch: Codable, Equatable, Sendable {
    let profile: String
    let prompt: String?
  }
}

nonisolated struct MirrorCommandResponse: Codable, Sendable {
  let requestID: UUID
  let response: MirrorJSON
}

/// Inline CLI JSON, without a dependency on the macOS command implementation.
nonisolated enum MirrorJSON: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([MirrorJSON])
  case object([String: MirrorJSON])

  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let decoded = try? value.decode(Bool.self) {
      self = .bool(decoded)
    } else if let decoded = try? value.decode(Double.self) {
      self = .number(decoded)
    } else if let decoded = try? value.decode(String.self) {
      self = .string(decoded)
    } else if let decoded = try? value.decode([MirrorJSON].self) {
      self = .array(decoded)
    } else {
      self = .object(try value.decode([String: MirrorJSON].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .bool(let item): try value.encode(item)
    case .number(let item): try value.encode(item)
    case .string(let item): try value.encode(item)
    case .array(let item): try value.encode(item)
    case .object(let item): try value.encode(item)
    }
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}

nonisolated struct MirrorShellInput: Codable, Equatable, Sendable {
  enum PaneSelector: Codable, Equatable, Sendable {
    case pane(String)
    var value: String {
      switch self {
      case .pane(let value): value
      }
    }
  }
  let selector: PaneSelector
  let text: String
  let trailingEnter: Bool
  let source: String
  let wait: Bool
  let captureOutput: Bool
  enum CodingKeys: String, CodingKey {
    case selector, text, source, wait
    case trailingEnter = "trailing_enter"
    case captureOutput = "capture_output"
  }
  init(pane: UUID, text: String) {
    selector = .pane(pane.uuidString)
    self.text = text
    trailingEnter = true
    source = "argv"
    wait = false
    captureOutput = false
  }
}
