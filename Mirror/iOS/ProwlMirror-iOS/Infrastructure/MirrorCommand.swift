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
    case agentsInput(Dispatch)
    case agentsDispatch(Dispatch)
    case send(MirrorShellInput)
    /// Answers the choice menu on the pane's screen (docs-ai 089 S4, capability `prompt-respond`).
    case promptRespond(PromptRespond)
    /// Presses keys in an agent pane: the Terminal key bar and Stop (docs-ai 089 S5,
    /// capability `agent-keys`). Only `AgentKeys.allowed` keys pass.
    case agentKeys(AgentKeys)

    var targetPaneID: UUID? {
      switch self {
      case .agentsInput(let input), .agentsDispatch(let input): UUID(uuidString: input.pane)
      case .send(let input): UUID(uuidString: input.selector.value)
      case .promptRespond(let answer): UUID(uuidString: answer.pane)
      case .agentKeys(let input): UUID(uuidString: input.pane)
      default: nil
      }
    }
  }

  struct AgentKeys: Codable, Equatable, Sendable {
    /// Navigation and control keys a TUI needs; no printable text, which goes through
    /// `agents.input` with its readiness checks.
    static let allowed: Set<String> = [
      "esc", "ctrl-c", "tab", "shift-tab", "up", "down", "left", "right", "enter",
    ]
    static let maximumCount = 8

    let pane: String
    let keys: [String]

    /// Control-C may end the agent, so it can only be the last key: nothing may follow it into
    /// the shell underneath (089 review S5-R3).
    var isAllowed: Bool {
      !keys.isEmpty && keys.count <= Self.maximumCount && keys.allSatisfy(Self.allowed.contains)
        && !keys.dropLast().contains("ctrl-c")
    }
  }

  struct PromptRespond: Codable, Equatable, Sendable {
    let pane: String
    /// The `prompt.opened` id the client saw; the Host refuses when the screen shows another.
    let prompt: String
    /// The choice id, the option's number on screen.
    let choice: String
  }

  struct Dispatch: Codable, Equatable, Sendable {
    let pane: String
    let prompt: String
  }

  struct Empty: Codable, Equatable, Sendable {}
  struct Create: Codable, Equatable, Sendable {
    let resource: String
    let selector: Selector
    let launch: Launch?
    let background: Bool
    init(worktreeID: String) {
      resource = "tab"
      selector = .worktree(worktreeID)
      launch = nil
      background = true
    }
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
