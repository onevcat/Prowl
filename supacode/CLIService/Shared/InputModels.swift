// ProwlShared/InputModels.swift
// Typed input models matching input.md contract

import Foundation

public struct OpenInput: Codable, Sendable {
  /// Normalized absolute path, or nil for bare `prowl` (bring to front).
  public let path: String?

  /// Invocation kind: "bare", "implicit-open", or "open-subcommand".
  /// Optional — handler derives a default if absent.
  public let invocation: String?

  /// `true` when the CLI had to launch Prowl before sending this command.
  /// The handler copies this value into the response's `app_launched` field.
  public let appLaunched: Bool

  public init(path: String? = nil, invocation: String? = nil, appLaunched: Bool = false) {
    self.path = path
    self.invocation = invocation
    self.appLaunched = appLaunched
  }
}

public struct ListInput: Codable, Sendable {
  public init() {}
}

public struct AgentsInput: Codable, Sendable {
  public init() {}
}

public struct FocusInput: Codable, Sendable {
  public let selector: TargetSelector

  public init(selector: TargetSelector = .none) {
    self.selector = selector
  }
}

public enum InputSource: String, Codable, Sendable {
  case argv
  case stdin
}

public struct SendInput: Codable, Sendable {
  public let selector: TargetSelector
  public let text: String
  public let trailingEnter: Bool
  public let source: InputSource
  public let wait: Bool
  public let timeoutSeconds: Int?
  public let captureOutput: Bool

  enum CodingKeys: String, CodingKey {
    case selector
    case text
    case trailingEnter = "trailing_enter"
    case source
    case wait
    case timeoutSeconds = "timeout_seconds"
    case captureOutput = "capture_output"
  }

  public init(
    selector: TargetSelector = .none,
    text: String,
    trailingEnter: Bool = true,
    source: InputSource = .argv,
    wait: Bool = true,
    timeoutSeconds: Int? = nil,
    captureOutput: Bool = false
  ) {
    self.selector = selector
    self.text = text
    self.trailingEnter = trailingEnter
    self.source = source
    self.wait = wait
    self.timeoutSeconds = timeoutSeconds
    self.captureOutput = captureOutput
  }
}

public struct KeyInput: Codable, Sendable {
  public let selector: TargetSelector
  /// The user's original token after trimming (for `requested.token` in response).
  public let rawToken: String
  /// The canonical normalized token (for execution and `key.normalized` in response).
  public let token: String
  public let repeatCount: Int

  enum CodingKeys: String, CodingKey {
    case selector
    case rawToken = "raw_token"
    case token
    case repeatCount = "repeat_count"
  }

  public init(
    selector: TargetSelector = .none,
    rawToken: String,
    token: String,
    repeatCount: Int = 1
  ) {
    self.selector = selector
    self.rawToken = rawToken
    self.token = token
    self.repeatCount = repeatCount
  }
}

public struct ReadInput: Codable, Sendable {
  public let selector: TargetSelector
  public let last: Int?
  /// When true, the app re-reads the pane until its output stops changing before responding.
  public let waitStable: Bool
  /// Sampling interval in milliseconds while waiting for stable output (nil → app default).
  public let stableIntervalMs: Int?
  /// Output must stay unchanged for this many milliseconds to count as stable (nil → app default).
  public let stablePeriodMs: Int?
  /// Maximum seconds to keep waiting for stable output before returning the latest snapshot (nil → app default).
  public let waitTimeoutSeconds: Int?

  public init(
    selector: TargetSelector = .none,
    last: Int? = nil,
    waitStable: Bool = false,
    stableIntervalMs: Int? = nil,
    stablePeriodMs: Int? = nil,
    waitTimeoutSeconds: Int? = nil
  ) {
    self.selector = selector
    self.last = last
    self.waitStable = waitStable
    self.stableIntervalMs = stableIntervalMs
    self.stablePeriodMs = stablePeriodMs
    self.waitTimeoutSeconds = waitTimeoutSeconds
  }
}

public enum TabAction: String, Codable, Sendable {
  case create
  case close
}

public struct TabInput: Codable, Sendable {
  public let action: TabAction
  public let selector: TargetSelector
  public let path: String?
  public let force: Bool

  enum CodingKeys: String, CodingKey {
    case action
    case selector
    case path
    case force
  }

  public init(action: TabAction, selector: TargetSelector = .none, path: String? = nil, force: Bool = false) {
    self.action = action
    self.selector = selector
    self.path = path
    self.force = force
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.action = try container.decode(TabAction.self, forKey: .action)
    self.selector = try container.decode(TargetSelector.self, forKey: .selector)
    self.path = try container.decodeIfPresent(String.self, forKey: .path)
    self.force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
  }
}

public enum HandoffAction: String, Codable, Sendable {
  case save
  case toAgent = "to"
}

public struct HandoffInput: Codable, Sendable {
  /// Environment variable used only by HUD-injected shell commands to carry
  /// the one-shot request authorization ID to the socket payload.
  public nonisolated static let requestIDEnvironmentKey = "PROWL_HANDOFF_REQUEST_ID"

  public let action: HandoffAction
  public let selector: TargetSelector
  /// Target agent for `to` (e.g. "claude", "codex"). Required for `.to`, nil otherwise.
  public let toAgent: String?
  /// Target Prowl Agent Profile for `to`. Mutually exclusive with `toAgent` on input.
  public let toProfileID: UUID?
  /// Optional free-text note appended to the handoff log.
  public let note: String?
  /// When false, `to` refreshes + archives the handoff but does not launch the
  /// receiving agent (the human takes over manually).
  public let launch: Bool
  /// Inline agent-authored briefing text (`--brief`); the primary briefing
  /// path for self-handoffs.
  public let brief: String?
  /// Explicit context-only run (`--no-brief`): no briefing is collected and
  /// no fork resume is attempted.
  public let contextOnly: Bool
  /// Optional ID assigned by the HUD to authorize one injected transition.
  /// Ordinary CLI handoffs omit it and remain independent of HUD state.
  public let requestID: UUID?

  enum CodingKeys: String, CodingKey {
    case action
    case selector
    case toAgent = "to_agent"
    case toProfileID = "to_profile_id"
    case note
    case launch
    case brief
    case contextOnly = "context_only"
    case requestID = "request_id"

  }

  public init(
    action: HandoffAction,
    selector: TargetSelector = .none,
    toAgent: String? = nil,
    toProfileID: UUID? = nil,
    note: String? = nil,
    launch: Bool = true,
    brief: String? = nil,
    contextOnly: Bool = false,
    requestID: UUID? = nil

  ) {
    self.action = action
    self.selector = selector
    self.toAgent = toAgent
    self.toProfileID = toProfileID
    self.note = note
    self.launch = launch
    self.brief = brief
    self.contextOnly = contextOnly
    self.requestID = requestID

  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.action = try container.decode(HandoffAction.self, forKey: .action)
    self.selector = try container.decode(TargetSelector.self, forKey: .selector)
    self.toAgent = try container.decodeIfPresent(String.self, forKey: .toAgent)
    self.toProfileID = try container.decodeIfPresent(UUID.self, forKey: .toProfileID)
    self.note = try container.decodeIfPresent(String.self, forKey: .note)
    self.launch = try container.decodeIfPresent(Bool.self, forKey: .launch) ?? true
    self.brief = try container.decodeIfPresent(String.self, forKey: .brief)
    self.contextOnly = try container.decodeIfPresent(Bool.self, forKey: .contextOnly) ?? false
    self.requestID = try container.decodeIfPresent(UUID.self, forKey: .requestID)
  }
}

public enum PaneAction: String, Codable, Sendable {
  case close
}

public struct PaneInput: Codable, Sendable {
  public let action: PaneAction
  public let selector: TargetSelector
  public let force: Bool

  enum CodingKeys: String, CodingKey {
    case action
    case selector
    case force
  }

  public init(action: PaneAction, selector: TargetSelector = .none, force: Bool = false) {
    self.action = action
    self.selector = selector
    self.force = force
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.action = try container.decode(PaneAction.self, forKey: .action)
    self.selector = try container.decode(TargetSelector.self, forKey: .selector)
    self.force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
  }
}
