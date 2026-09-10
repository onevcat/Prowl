// ProwlShared/WorkflowDefinition.swift
// The `prowl.workflow/v1` definition model (docs-ai 063, dsl-spec.md).
// Pure data: parsing lives in WorkflowDocumentParser, semantic rules in WorkflowValidator.

import Foundation

nonisolated public enum WorkflowSchema {
  public static let identifier = "prowl.workflow/v1"
  /// `prowl.*` ids are reserved for definitions shipped inside the app bundle.
  public static let reservedIDPrefix = "prowl."
  public static let verdictRange = 2...4
  /// Carries an activation's delivery token to `prowl workflow deliver`: typed as the line's
  /// environment prefix for a `message` step, set in the child environment for a `launch` step.
  public static let tokenEnvironmentKey = "PROWL_WORKFLOW_TOKEN"
  /// Cross-check hints in a launched surface's child environment; the dispatch store stays the authority.
  public static let runEnvironmentKey = "PROWL_WORKFLOW_RUN"
  public static let roleEnvironmentKey = "PROWL_WORKFLOW_ROLE"
  /// Workflow and skill ids may contain dots; a leading alphanumeric rules out `.` and `..`.
  public static var workflowIDPattern: Regex<Substring> { /^[a-z0-9][a-z0-9_.-]{0,63}$/ }
  /// Step ids, role names, delivery names, input names, and verdict values become path
  /// components and CLI arguments.
  public static var slugPattern: Regex<Substring> { /^[a-z0-9][a-z0-9_-]{0,63}$/ }

  public static func isWorkflowID(_ value: String) -> Bool {
    value.wholeMatch(of: workflowIDPattern) != nil
  }

  public static func isSlug(_ value: String) -> Bool {
    value.wholeMatch(of: slugPattern) != nil
  }

  public static func isActionID(_ value: String) -> Bool {
    value.utf8.count <= 64 && value.wholeMatch(of: /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/) != nil
  }
}

/// 1-based position inside the YAML source.
nonisolated public struct WorkflowSourceLocation: Equatable, Sendable, Codable {
  public let line: Int
  public let column: Int

  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
}

nonisolated public enum WorkflowDiagnosticSeverity: String, Equatable, Sendable, Codable {
  case error
  case warning
}

nonisolated public struct WorkflowDiagnostic: Equatable, Sendable, Codable {
  public let severity: WorkflowDiagnosticSeverity
  /// Stable machine-readable code (`unknown_key`, `undefined_role`, …).
  public let code: String
  public let message: String
  public let location: WorkflowSourceLocation?

  public init(
    severity: WorkflowDiagnosticSeverity,
    code: String,
    message: String,
    location: WorkflowSourceLocation? = nil
  ) {
    self.severity = severity
    self.code = code
    self.message = message
    self.location = location
  }

  public static func error(_ code: String, _ message: String, at location: WorkflowSourceLocation? = nil) -> Self {
    Self(severity: .error, code: code, message: message, location: location)
  }

  public static func warning(_ code: String, _ message: String, at location: WorkflowSourceLocation? = nil) -> Self {
    Self(severity: .warning, code: code, message: message, location: location)
  }
}

nonisolated extension [WorkflowDiagnostic] {
  public var hasErrors: Bool { contains { $0.severity == .error } }
  public var errorCount: Int { filter { $0.severity == .error }.count }
  public var warningCount: Int { filter { $0.severity == .warning }.count }
}

// MARK: - Definition

nonisolated public struct WorkflowDefinition: Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String?
  public let icon: String?
  public let inputs: [WorkflowInputDefinition]
  public let roles: [WorkflowRoleDefinition]
  public let steps: [WorkflowStepDefinition]
  public let state: [String: WorkflowStateDeclaration]

  public init(
    id: String,
    name: String,
    description: String? = nil,
    icon: String? = nil,
    inputs: [WorkflowInputDefinition] = [],
    roles: [WorkflowRoleDefinition] = [],
    steps: [WorkflowStepDefinition] = [],
    state: [String: WorkflowStateDeclaration] = [:]
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.icon = icon
    self.inputs = inputs
    self.roles = roles
    self.steps = steps
    self.state = state
  }

  public func role(named name: String) -> WorkflowRoleDefinition? {
    roles.first { $0.name == name }
  }

  public func input(named name: String) -> WorkflowInputDefinition? {
    inputs.first { $0.name == name }
  }

  /// Every step in document order, `repeat` bodies inlined after their `repeat` step.
  public var flattenedSteps: [WorkflowStepDefinition] {
    steps.flatMap { step -> [WorkflowStepDefinition] in
      [step]
        + step.action.children.flatMap { child in
          [child] + child.action.descendants
        }
    }
  }
}

// MARK: - Inputs

nonisolated public enum WorkflowInputType: String, Equatable, Sendable, Codable {
  case integer
  case string
  case `enum`
}

nonisolated public enum WorkflowScalar: Equatable, Sendable {
  case integer(Int)
  case string(String)

  public var stringValue: String {
    switch self {
    case .integer(let value): String(value)
    case .string(let value): value
    }
  }
}

nonisolated public struct WorkflowInputDefinition: Equatable, Sendable {
  public let name: String
  public let type: WorkflowInputType
  public let defaultValue: WorkflowScalar?
  public let prompt: String?
  public let minimum: Int?
  public let maximum: Int?
  /// Allowed values of an `enum` input; empty otherwise.
  public let values: [String]
  public let location: WorkflowSourceLocation?

  public init(
    name: String,
    type: WorkflowInputType,
    defaultValue: WorkflowScalar? = nil,
    prompt: String? = nil,
    minimum: Int? = nil,
    maximum: Int? = nil,
    values: [String] = [],
    location: WorkflowSourceLocation? = nil
  ) {
    self.name = name
    self.type = type
    self.defaultValue = defaultValue
    self.prompt = prompt
    self.minimum = minimum
    self.maximum = maximum
    self.values = values
    self.location = location
  }
}

// MARK: - Roles

nonisolated public enum WorkflowRoleSource: String, Equatable, Sendable, Codable {
  case current
  case launch
  case pick
}

nonisolated public enum WorkflowRoleKind: String, Equatable, Sendable, Codable {
  case interactive
}

nonisolated public enum WorkflowBindMode: String, Equatable, Sendable, Codable {
  case ask
  case auto
}

nonisolated public enum WorkflowPlacement: String, Equatable, Sendable, Codable {
  case split
  case tab
}

nonisolated public enum WorkflowSplitDirection: String, Equatable, Sendable, Codable {
  case right
  case left
  case top = "up"
  case down
}

/// Subset of profile preset fields a `launch` role may suggest; never a profile name or UUID.
nonisolated public struct WorkflowProfileSuggestion: Equatable, Sendable {
  public let agent: String?
  public let model: String?
  public let reasoningEffort: String?
  public let executionMode: String?

  public init(
    agent: String? = nil,
    model: String? = nil,
    reasoningEffort: String? = nil,
    executionMode: String? = nil
  ) {
    self.agent = agent
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.executionMode = executionMode
  }
}

nonisolated public struct WorkflowLaunchRequirements: Equatable, Sendable {
  public let kind: WorkflowRoleKind
  /// Allow-list of agent tokens; nil = any launchable agent.
  public let agents: [String]?
  public let suggest: WorkflowProfileSuggestion?
  public let bind: WorkflowBindMode
  public let placement: WorkflowPlacement
  public let direction: WorkflowSplitDirection
  public let background: Bool

  public init(
    kind: WorkflowRoleKind = .interactive,
    agents: [String]? = nil,
    suggest: WorkflowProfileSuggestion? = nil,
    bind: WorkflowBindMode = .ask,
    placement: WorkflowPlacement = .split,
    direction: WorkflowSplitDirection = .right,
    background: Bool = false
  ) {
    self.kind = kind
    self.agents = agents
    self.suggest = suggest
    self.bind = bind
    self.placement = placement
    self.direction = direction
    self.background = background
  }
}

nonisolated public struct WorkflowRoleDefinition: Equatable, Sendable {
  public let name: String
  public let source: WorkflowRoleSource
  /// Present exactly when `source == .launch`.
  public let launch: WorkflowLaunchRequirements?
  public let location: WorkflowSourceLocation?

  public init(
    name: String,
    source: WorkflowRoleSource,
    launch: WorkflowLaunchRequirements? = nil,
    location: WorkflowSourceLocation? = nil
  ) {
    self.name = name
    self.source = source
    self.launch = launch
    self.location = location
  }
}

// MARK: - Steps

nonisolated public enum WorkflowDeliveryFormat: String, Equatable, Sendable, Codable {
  case markdown
  case text
  case json
}

nonisolated public enum WorkflowTimeoutPolicy: String, Equatable, Sendable, Codable {
  case attention
  case skip
  case cancel
}

nonisolated public struct WorkflowExpectation: Equatable, Sendable {
  /// Delivery name; nil means the step id (see `WorkflowStepDefinition.deliveryName`).
  public let delivery: String?
  public let format: WorkflowDeliveryFormat
  public let sections: [String]
  /// Allowed verdict values; nil when the step does not require a verdict.
  public let verdicts: [String]?
  /// Hard cap in seconds; nil = wait as long as the agent works.
  public let timeoutSeconds: Int?
  public let onTimeout: WorkflowTimeoutPolicy?
  /// `true`: a delivery that misses `sections`, `format`, or `verdicts` is rejected. `false`
  /// (default): it is kept as provisional and the run asks the user to accept, ask again, or skip.
  public let strict: Bool
  public let location: WorkflowSourceLocation?

  public init(
    delivery: String? = nil,
    format: WorkflowDeliveryFormat = .markdown,
    sections: [String] = [],
    verdicts: [String]? = nil,
    timeoutSeconds: Int? = nil,
    onTimeout: WorkflowTimeoutPolicy? = nil,
    strict: Bool = false,
    location: WorkflowSourceLocation? = nil
  ) {
    self.delivery = delivery
    self.format = format
    self.sections = sections
    self.verdicts = verdicts
    self.timeoutSeconds = timeoutSeconds
    self.onTimeout = onTimeout
    self.strict = strict
    self.location = location
  }
}

nonisolated public enum WorkflowStepAction: Equatable, Sendable {
  case message(role: String, prompt: String, expect: WorkflowExpectation?)
  case launch(role: String, prompt: String, skill: String?, expect: WorkflowExpectation?)
  /// `with` preserves JSON values and evaluates embedded expressions.
  case action(id: String, inputs: [String: WorkflowJSONValue])
  case control(WorkflowControlStep)
  case notify(String)
  case close(role: String)

  public var verb: String {
    switch self {
    case .message: "message"
    case .launch: "launch"
    case .action: "action"
    case .notify: "notify"
    case .close: "close"
    case .control(let control): control.verb
    }
  }

  public var expect: WorkflowExpectation? {
    switch self {
    case .message(_, _, let expect), .launch(_, _, _, let expect): expect
    case .action, .notify, .close, .control: nil
    }
  }

  /// The role a `message`, `launch`, or `close` step addresses.
  public var targetRole: String? {
    switch self {
    case .message(let role, _, _), .launch(let role, _, _, _), .close(let role): role
    case .action, .notify, .control: nil
    }
  }
}

nonisolated public struct WorkflowStepDefinition: Equatable, Sendable {
  public let id: String
  public let title: String?
  public let action: WorkflowStepAction
  public let location: WorkflowSourceLocation?

  public init(id: String, title: String? = nil, action: WorkflowStepAction, location: WorkflowSourceLocation? = nil) {
    self.id = id
    self.title = title
    self.action = action
    self.location = location
  }

  /// The delivery name this step produces, when it has an `expect`.
  public var deliveryName: String? {
    guard let expect = action.expect else { return nil }
    return expect.delivery ?? id
  }
}
