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

public enum DispatchCompletionOutcome: String, Codable, CaseIterable, Sendable {
  case succeeded
  case failed
}

public struct DispatchCompleteInput: Codable, Sendable {
  nonisolated public static let environmentKey = "PROWL_DISPATCH_ID"
  public static let maximumSummaryBytes = 32 * 1_024

  /// The launch-scoped `PROWL_DISPATCH_ID` when the caller still carries one. The app
  /// resolves the receipt from the caller pane's current pending dispatch, so this value
  /// is compatibility diagnostics only: a process launched with an older id still
  /// completes the pane's current record.
  public let dispatchID: String?
  public let outcome: DispatchCompletionOutcome
  public let summary: String

  enum CodingKeys: String, CodingKey {
    case dispatchID = "dispatch_id"
    case outcome
    case summary
  }

  public init(dispatchID: String?, outcome: DispatchCompletionOutcome, summary: String) {
    self.dispatchID = dispatchID
    self.outcome = outcome
    self.summary = summary
  }

  public var validationErrorMessage: String? {
    dispatchID.flatMap {
      CLIInputTextValidator.validateDispatchID($0, name: DispatchCompleteInput.environmentKey)
    }
      ?? CLIInputTextValidator.validate(
        summary,
        name: "--summary",
        maximumBytes: Self.maximumSummaryBytes
      )
  }
}

/// `prowl agents dispatch <pane> --prompt -`: a new pending dispatch for an agent that
/// already runs in an existing pane. The prompt reaches the runtime through the pane's
/// input path as one bracketed paste followed by Enter, so newlines and tabs survive but
/// every other control character would be stripped or reinterpreted before delivery.
public struct DispatchInput: Codable, Sendable, Equatable {
  public static let maximumPromptUTF8ByteCount = CreateLaunchInput.maximumPromptUTF8ByteCount

  public let pane: String
  public let prompt: String

  public init(pane: String, prompt: String) {
    self.pane = pane
    self.prompt = prompt
  }

  public var validationErrorMessage: String? {
    guard !pane.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "agents dispatch requires a pane handle (pN) or pane UUID."
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "The dispatch prompt is empty."
    }
    guard prompt.utf8.count <= Self.maximumPromptUTF8ByteCount else {
      return "The dispatch prompt exceeds the 256 KiB UTF-8 limit."
    }
    guard !prompt.unicodeScalars.contains(where: Self.isDisallowedScalar) else {
      return "The dispatch prompt must not contain control characters other than newlines and tabs."
    }
    return nil
  }

  private static func isDisallowedScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar != "\n" && scalar != "\t" && CharacterSet.controlCharacters.contains(scalar)
  }
}

public struct DispatchAbandonInput: Codable, Sendable {
  public static let maximumReasonBytes = 32 * 1_024

  public let dispatchID: String
  public let reason: String

  enum CodingKeys: String, CodingKey {
    case dispatchID = "dispatch_id"
    case reason
  }

  public init(dispatchID: String, reason: String) {
    self.dispatchID = dispatchID
    self.reason = reason
  }

  public var validationErrorMessage: String? {
    CLIInputTextValidator.validateDispatchID(dispatchID, name: "--dispatch")
      ?? CLIInputTextValidator.validate(
        reason,
        name: "--reason",
        maximumBytes: Self.maximumReasonBytes
      )
  }
}

public enum AgentWaitMode: String, Codable, Sendable {
  case dispatch
  case condition
}

public enum AgentWaitCondition: String, Codable, CaseIterable, Sendable {
  case idle
  case blocked
  case changed
  case exit
}

public enum AgentWaitMinimumConfidence: String, Codable, CaseIterable, Sendable {
  case auto
  case exact
  case high
  case heuristic
}

public struct AgentWaitInput: Codable, Sendable {
  public static let defaultTimeoutSeconds = 600
  public static let maximumTimeoutSeconds = 600
  public static let maximumScreenLines = 200

  public let mode: AgentWaitMode
  public let dispatchID: String?
  public let pane: String?
  public let condition: AgentWaitCondition?
  public let timeoutSeconds: Int
  public let minimumConfidence: AgentWaitMinimumConfidence?
  public let includeScreenLines: Int?

  enum CodingKeys: String, CodingKey {
    case mode
    case dispatchID = "dispatch_id"
    case pane
    case condition
    case timeoutSeconds = "timeout_seconds"
    case minimumConfidence = "minimum_confidence"
    case includeScreenLines = "include_screen_lines"
  }

  public init(
    mode: AgentWaitMode,
    dispatchID: String? = nil,
    pane: String? = nil,
    condition: AgentWaitCondition? = nil,
    timeoutSeconds: Int = Self.defaultTimeoutSeconds,
    minimumConfidence: AgentWaitMinimumConfidence? = nil,
    includeScreenLines: Int? = nil
  ) {
    self.mode = mode
    self.dispatchID = dispatchID
    self.pane = pane
    self.condition = condition
    self.timeoutSeconds = timeoutSeconds
    self.minimumConfidence = minimumConfidence
    self.includeScreenLines = includeScreenLines
  }
}

private enum CLIInputTextValidator {
  static func validateDispatchID(_ value: String, name: String) -> String? {
    validate(value, name: name, maximumBytes: 256)
  }

  static func validate(_ value: String, name: String, maximumBytes: Int) -> String? {
    guard !value.isEmpty else { return "\(name) must not be empty." }
    guard value.utf8.count <= maximumBytes else {
      return "\(name) must be at most \(maximumBytes) UTF-8 bytes."
    }
    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      return "\(name) must not contain control characters."
    }
    return nil
  }
}

nonisolated public enum AgentSignalEvent: String, Codable, CaseIterable, Hashable, Sendable {
  case turnEnded = "turn-ended"
  case needsInput = "needs-input"
  case sessionStart = "session-start"
  case sessionEnd = "session-end"
  case progress
}

nonisolated public struct AgentSignalInput: Codable, Sendable {
  public static let maximumSessionIDBytes = 256
  public static let maximumOriginBytes = 256
  public static let maximumDetailBytes = 32 * 1_024

  public let event: AgentSignalEvent
  public let progress: Int?
  public let origin: String?
  public let sessionID: String?
  public let detail: String?

  enum CodingKeys: String, CodingKey {
    case event
    case progress
    case origin
    case sessionID = "session_id"
    case detail
  }

  public init(
    event: AgentSignalEvent,
    progress: Int? = nil,
    origin: String? = nil,
    sessionID: String? = nil,
    detail: String? = nil
  ) {
    self.event = event
    self.progress = progress
    self.origin = origin
    self.sessionID = sessionID
    self.detail = detail
  }

  public var validationErrorMessage: String? {
    if event != .progress, progress != nil {
      return "--progress is only valid with the 'progress' event."
    }
    if let progress, !(0...100).contains(progress) {
      return "--progress must be between 0 and 100."
    }
    if let message = Self.validateText(
      sessionID,
      name: "--session",
      maximumBytes: Self.maximumSessionIDBytes
    ) {
      return message
    }
    if let message = Self.validateText(
      origin,
      name: "--origin",
      maximumBytes: Self.maximumOriginBytes
    ) {
      return message
    }
    return Self.validateText(
      detail,
      name: "--detail",
      maximumBytes: Self.maximumDetailBytes
    )
  }

  private static func validateText(_ value: String?, name: String, maximumBytes: Int) -> String? {
    guard let value else { return nil }
    guard !value.isEmpty else { return "\(name) must not be empty." }
    guard value.utf8.count <= maximumBytes else {
      return "\(name) must be at most \(maximumBytes) UTF-8 bytes."
    }
    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      return "\(name) must not contain control characters."
    }
    return nil
  }
}

public struct ProfilesInput: Codable, Sendable {
  public init() {}
}

public struct AgentReadInput: Codable, Sendable {
  public static let defaultMaxBytes = 1_024 * 1_024
  public static let maximumMaxBytes = 4 * 1_024 * 1_024

  public let pane: String
  public let maxBytes: Int
  public let resultOnly: Bool

  enum CodingKeys: String, CodingKey {
    case pane
    case maxBytes = "max_bytes"
    case resultOnly = "result_only"
  }

  public init(pane: String, maxBytes: Int = Self.defaultMaxBytes, resultOnly: Bool = false) {
    self.pane = pane
    self.maxBytes = maxBytes
    self.resultOnly = resultOnly
  }
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

public enum ReadInputSource: String, Codable, Sendable {
  case viewport
  case detection
}

public struct ReadInput: Codable, Sendable {
  public let selector: TargetSelector
  public let last: Int?
  /// The terminal buffer requested by the caller.
  public let source: ReadInputSource
  /// When true, the app re-reads the pane until its output stops changing before responding.
  public let waitStable: Bool
  /// Sampling interval in milliseconds while waiting for stable output (nil → app default).
  public let stableIntervalMs: Int?
  /// Output must stay unchanged for this many milliseconds to count as stable (nil → app default).
  public let stablePeriodMs: Int?
  /// Maximum seconds to keep waiting for stable output before returning the latest snapshot (nil → app default).
  public let waitTimeoutSeconds: Int?

  enum CodingKeys: String, CodingKey {
    case selector
    case last
    case source
    case waitStable
    case stableIntervalMs
    case stablePeriodMs
    case waitTimeoutSeconds
  }

  public init(
    selector: TargetSelector = .none,
    last: Int? = nil,
    source: ReadInputSource = .viewport,
    waitStable: Bool = false,
    stableIntervalMs: Int? = nil,
    stablePeriodMs: Int? = nil,
    waitTimeoutSeconds: Int? = nil
  ) {
    self.selector = selector
    self.last = last
    self.source = source
    self.waitStable = waitStable
    self.stableIntervalMs = stableIntervalMs
    self.stablePeriodMs = stablePeriodMs
    self.waitTimeoutSeconds = waitTimeoutSeconds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.selector = try container.decodeIfPresent(TargetSelector.self, forKey: .selector) ?? .none
    self.last = try container.decodeIfPresent(Int.self, forKey: .last)
    self.source = try container.decodeIfPresent(ReadInputSource.self, forKey: .source) ?? .viewport
    self.waitStable = try container.decodeIfPresent(Bool.self, forKey: .waitStable) ?? false
    self.stableIntervalMs = try container.decodeIfPresent(Int.self, forKey: .stableIntervalMs)
    self.stablePeriodMs = try container.decodeIfPresent(Int.self, forKey: .stablePeriodMs)
    self.waitTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .waitTimeoutSeconds)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(selector, forKey: .selector)
    try container.encodeIfPresent(last, forKey: .last)
    try container.encode(source, forKey: .source)
    try container.encode(waitStable, forKey: .waitStable)
    try container.encodeIfPresent(stableIntervalMs, forKey: .stableIntervalMs)
    try container.encodeIfPresent(stablePeriodMs, forKey: .stablePeriodMs)
    try container.encodeIfPresent(waitTimeoutSeconds, forKey: .waitTimeoutSeconds)
  }
}

public enum LifecycleResource: String, Codable, Sendable, Equatable {
  case tab
  case pane
}

public enum CreatePaneDirection: String, Codable, CaseIterable, Sendable, Equatable {
  case right
  case left
  case upward = "up"
  case down
}

public struct CreateLaunchInput: Codable, Sendable, Equatable {
  /// Keeps the surface-shell spawn and prompted child exec comfortably below
  /// macOS ARG_MAX, including the inherited environment and configured argv.
  public static let maximumPromptUTF8ByteCount = 256 * 1_024

  public let profile: String
  public let prompt: String?

  public init(profile: String, prompt: String? = nil) {
    self.profile = profile
    self.prompt = prompt
  }
}

public struct CreateInput: Codable, Sendable {
  public let resource: LifecycleResource
  public let selector: TargetSelector
  public let path: String?
  public let direction: CreatePaneDirection?
  public let launch: CreateLaunchInput?
  public let background: Bool

  enum CodingKeys: String, CodingKey {
    case resource
    case selector
    case path
    case direction
    case launch
    case background
  }

  public init(
    resource: LifecycleResource,
    selector: TargetSelector,
    path: String? = nil,
    direction: CreatePaneDirection? = nil,
    launch: CreateLaunchInput? = nil,
    background: Bool = false
  ) {
    self.resource = resource
    self.selector = selector
    self.path = path
    self.direction = direction
    self.launch = launch
    self.background = background
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    resource = try container.decode(LifecycleResource.self, forKey: .resource)
    selector = try container.decode(TargetSelector.self, forKey: .selector)
    path = try container.decodeIfPresent(String.self, forKey: .path)
    direction = try container.decodeIfPresent(CreatePaneDirection.self, forKey: .direction)
    launch = try container.decodeIfPresent(CreateLaunchInput.self, forKey: .launch)
    background = try container.decodeIfPresent(Bool.self, forKey: .background) ?? false
  }
}

public struct CloseInput: Codable, Sendable {
  public let selector: TargetSelector
  public let force: Bool

  public init(selector: TargetSelector, force: Bool = false) {
    self.selector = selector
    self.force = force
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
    note: String? = nil,
    launch: Bool = true,
    brief: String? = nil,
    contextOnly: Bool = false,
    requestID: UUID? = nil

  ) {
    self.action = action
    self.selector = selector
    self.toAgent = toAgent
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

// MARK: - Workflow

nonisolated public enum WorkflowInputAction: String, Codable, Sendable {
  case read
  case list
  case run
  case status
  case deliver
  case cancel
}

/// The wire request for the workflow command family (docs-ai 063 B1/B3). Fields are
/// action-specific; the app handler ignores the ones that do not belong to `action`.
nonisolated public struct WorkflowInput: Codable, Sendable {
  public let action: WorkflowInputAction
  /// `list`: the worktree whose repo source is searched. `run`: the source pane (a workflow with a
  /// `current` role) or worktree. `.none` = the caller's pane, then the focused worktree (`list`).
  public let target: TargetSelector
  /// `run`: workflow id or unique name.
  public let workflow: String?
  public let invocation: Int?
  public let contentOffset: Int64?
  public let contentResource: String?
  public let testAction: String?
  public let actionInputs: [String: WorkflowJSONValue]?
  /// `run`: `<role>=<binding>` overrides (dsl-spec §9).
  public let roleBindings: [String]
  /// `run`: `<name>=<value>` inputs.
  public let inputValues: [String]
  /// `run`: step ids skipped at start.
  public let skippedSteps: [String]
  /// `status` / `cancel`: the run; `deliver`: the manual target together with `stepID`.
  public let runID: String?
  public let stepID: String?
  /// `deliver`: the delivered output body (already read by the CLI).
  public let body: String?
  public let verdict: String?
  /// `deliver`: `--token` or `$PROWL_WORKFLOW_TOKEN`; correlation only, never authentication.
  public let token: String?
  /// `deliver`: deliver to the explicit target even when the caller pane belongs to another step.
  public let force: Bool

  public init(
    action: WorkflowInputAction = .list,
    target: TargetSelector = .none,
    workflow: String? = nil,
    invocation: Int? = nil,
    contentOffset: Int64? = nil,
    contentResource: String? = nil,
    testAction: String? = nil,
    actionInputs: [String: WorkflowJSONValue]? = nil,
    roleBindings: [String] = [],
    inputValues: [String] = [],
    skippedSteps: [String] = [],
    runID: String? = nil,
    stepID: String? = nil,
    body: String? = nil,
    verdict: String? = nil,
    token: String? = nil,
    force: Bool = false
  ) {
    self.action = action
    self.target = target
    self.workflow = workflow
    self.invocation = invocation
    self.contentOffset = contentOffset
    self.contentResource = contentResource
    self.testAction = testAction
    self.actionInputs = actionInputs
    self.roleBindings = roleBindings
    self.inputValues = inputValues
    self.skippedSteps = skippedSteps
    self.runID = runID
    self.stepID = stepID
    self.body = body
    self.verdict = verdict
    self.token = token
    self.force = force
  }
}
