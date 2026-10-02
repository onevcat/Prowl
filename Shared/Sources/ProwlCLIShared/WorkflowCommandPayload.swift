// ProwlShared/WorkflowCommandPayload.swift
// `prowl workflow` response data (`prowl.cli.workflow.v1`), discriminated by `action`.
// `list`, `run`, `status`, `deliver`, and `cancel` cross the socket; `validate` and `schema` are
// produced locally by the CLI.

import Foundation

nonisolated public enum WorkflowCommandPayload: Codable, Equatable, Sendable {
  public static let schemaVersion = "prowl.cli.workflow.v1"
  public static let commandName = "workflow"

  case read(WorkflowContentPayload)
  case list(WorkflowListPayload)
  case run(WorkflowRunPayload)
  case status(WorkflowRunPayload)
  case deliver(WorkflowDeliverPayload)
  case cancel(WorkflowRunPayload)
  case validate(WorkflowValidatePayload)
  case schema(WorkflowSchemaPayload)

  public var action: WorkflowCommandAction {
    switch self {
    case .read: .read
    case .list: .list
    case .run: .run
    case .status: .status
    case .deliver: .deliver
    case .cancel: .cancel
    case .validate: .validate
    case .schema: .schema
    }
  }

  private enum CodingKeys: String, CodingKey {
    case action
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(WorkflowCommandAction.self, forKey: .action) {
    case .read: self = .read(try WorkflowContentPayload(from: decoder))
    case .list: self = .list(try WorkflowListPayload(from: decoder))
    case .run: self = .run(try WorkflowRunPayload(from: decoder))
    case .status: self = .status(try WorkflowRunPayload(from: decoder))
    case .deliver: self = .deliver(try WorkflowDeliverPayload(from: decoder))
    case .cancel: self = .cancel(try WorkflowRunPayload(from: decoder))
    case .validate: self = .validate(try WorkflowValidatePayload(from: decoder))
    case .schema: self = .schema(try WorkflowSchemaPayload(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(action, forKey: .action)
    switch self {
    case .read(let payload): try payload.encode(to: encoder)
    case .list(let payload): try payload.encode(to: encoder)
    case .run(let payload), .status(let payload), .cancel(let payload):
      try payload.encode(to: encoder)
    case .deliver(let payload): try payload.encode(to: encoder)
    case .validate(let payload): try payload.encode(to: encoder)
    case .schema(let payload): try payload.encode(to: encoder)
    }
  }
}

nonisolated public enum WorkflowCommandAction: String, Codable, Equatable, Sendable {
  case read
  case list
  case run
  case status
  case deliver
  case cancel
  case validate
  case schema
}

// MARK: - list

nonisolated public struct WorkflowListPayload: Codable, Equatable, Sendable {
  /// The worktree whose repo source was searched; absent when no worktree could be resolved.
  public let worktree: WorkflowListWorktree?
  public let sources: WorkflowListSources
  public let workflows: [WorkflowListEntry]

  public init(
    worktree: WorkflowListWorktree?, sources: WorkflowListSources, workflows: [WorkflowListEntry]
  ) {
    self.worktree = worktree
    self.sources = sources
    self.workflows = workflows
  }
}

nonisolated public struct WorkflowListWorktree: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let path: String
  public let rootPath: String

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case path
    case rootPath = "root_path"
  }

  public init(id: String, name: String, path: String, rootPath: String) {
    self.id = id
    self.name = name
    self.path = path
    self.rootPath = rootPath
  }
}

/// Directories searched; a nil entry means the source does not apply (no app bundle, no worktree).
nonisolated public struct WorkflowListSources: Codable, Equatable, Sendable {
  public let bundle: String?
  public let user: String
  public let repo: String?

  public init(bundle: String?, user: String, repo: String?) {
    self.bundle = bundle
    self.user = user
    self.repo = repo
  }
}

nonisolated public struct WorkflowListEntry: Codable, Equatable, Sendable {
  /// Absent when the file did not parse.
  public let id: String?
  public let name: String?
  public let description: String?
  public let scope: WorkflowScope
  public let path: String
  public let enabled: Bool
  public let valid: Bool
  public let errors: Int
  public let warnings: Int
  public let shadowed: Bool

  public init(
    id: String?,
    name: String?,
    description: String?,
    scope: WorkflowScope,
    path: String,
    enabled: Bool,
    valid: Bool,
    errors: Int,
    warnings: Int,
    shadowed: Bool
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.scope = scope
    self.path = path
    self.enabled = enabled
    self.valid = valid
    self.errors = errors
    self.warnings = warnings
    self.shadowed = shadowed
  }

  public init(entry: WorkflowCatalogEntry, enabled: Bool) {
    self.init(
      id: entry.file.id,
      name: entry.file.definition?.name,
      description: entry.file.definition?.description,
      scope: entry.file.scope,
      path: entry.file.url.path(percentEncoded: false),
      enabled: enabled,
      valid: entry.file.isValid,
      errors: entry.file.diagnostics.errorCount,
      warnings: entry.file.diagnostics.warningCount,
      shadowed: entry.shadowed
    )
  }
}

// MARK: - run / status / cancel

/// One workflow run as the CLI sees it (docs-ai 063 B3). `source` says whether the run is live in
/// the app (`live`) or was read back from its `run.json` after a restart (`record`); a record
/// carries no `activation` and no `self_initiated` block.
nonisolated public struct WorkflowRunPayload: Codable, Equatable, Sendable {
  public let id: String
  public let workflow: WorkflowIdentity
  public let scope: WorkflowScope
  public let definitionPath: String?
  public let source: WorkflowRunPayloadSource
  public let status: WorkflowRunStatusPayload
  /// The step in progress; absent once the run has ended.
  public let step: String?
  /// The caller pane's role when the command was attributed to a pane bound in this run.
  public let role: String?
  public let worktree: WorkflowRunWorktreePayload
  public let runDirectory: String
  public let bindings: [String: WorkflowBindingPayload]
  /// The activation currently waiting for (or persisting) a delivery.
  public let activation: WorkflowActivationPayload?
  /// Latest delivered output per name.
  public let deliveries: [String: WorkflowDeliveryRecordPayload]
  public let startedAt: String
  public let updatedAt: String
  public let finishedAt: String?
  /// The first step's line when the run was started from the `current` role's own pane: the
  /// caller already holds it, nothing was typed (dsl-spec §9).
  public let selfInitiated: WorkflowSelfInitiatedPayload?

  enum CodingKeys: String, CodingKey {
    case id
    case workflow
    case scope
    case definitionPath = "definition_path"
    case source
    case status
    case step
    case role
    case worktree
    case runDirectory = "run_directory"
    case bindings
    case activation
    case deliveries
    case startedAt = "started_at"
    case updatedAt = "updated_at"
    case finishedAt = "finished_at"
    case selfInitiated = "self_initiated"
  }

  public init(
    id: String,
    workflow: WorkflowIdentity,
    scope: WorkflowScope,
    definitionPath: String?,
    source: WorkflowRunPayloadSource,
    status: WorkflowRunStatusPayload,
    step: String?,
    role: String?,
    worktree: WorkflowRunWorktreePayload,
    runDirectory: String,
    bindings: [String: WorkflowBindingPayload],
    activation: WorkflowActivationPayload?,
    deliveries: [String: WorkflowDeliveryRecordPayload],
    startedAt: String,
    updatedAt: String,
    finishedAt: String?,
    selfInitiated: WorkflowSelfInitiatedPayload?
  ) {
    self.id = id
    self.workflow = workflow
    self.scope = scope
    self.definitionPath = definitionPath
    self.source = source
    self.status = status
    self.step = step
    self.role = role
    self.worktree = worktree
    self.runDirectory = runDirectory
    self.bindings = bindings
    self.activation = activation
    self.deliveries = deliveries
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.finishedAt = finishedAt
    self.selfInitiated = selfInitiated
  }
}

nonisolated public enum WorkflowRunPayloadSource: String, Codable, Equatable, Sendable {
  case live
  case record
}

nonisolated public struct WorkflowRunStatusPayload: Codable, Equatable, Sendable {
  /// `running`, `needs_attention`, `completed`, `cancelled`, `skipped`, `iteration_limit_reached`, `interrupted`.
  public let state: String
  /// The step that ended a `skipped` run, or the step in attention.
  public let step: String?
  /// The step whose input made a `skipped` run end.
  public let dependent: String?
  public let attention: WorkflowAttentionPayload?

  public init(
    state: String, step: String? = nil, dependent: String? = nil,
    attention: WorkflowAttentionPayload? = nil
  ) {
    self.state = state
    self.step = step
    self.dependent = dependent
    self.attention = attention
  }
}

nonisolated public struct WorkflowAttentionPayload: Codable, Equatable, Sendable {
  public let reason: String
  public let message: String
  public let step: String
  public let role: String?
  public let ordinal: Int?
  public let actions: [String]
  /// Issue codes of a provisional delivery (`delivery_issues` only).
  public let issues: [String]?

  public init(
    reason: String,
    message: String,
    step: String,
    role: String?,
    ordinal: Int?,
    actions: [String],
    issues: [String]? = nil
  ) {
    self.reason = reason
    self.message = message
    self.step = step
    self.role = role
    self.ordinal = ordinal
    self.actions = actions
    self.issues = issues
  }
}

nonisolated public struct WorkflowRunWorktreePayload: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let branch: String
  public let path: String

  public init(id: String, name: String, branch: String, path: String) {
    self.id = id
    self.name = name
    self.branch = branch
    self.path = path
  }
}

nonisolated public struct WorkflowBindingPayload: Codable, Equatable, Sendable {
  public let source: WorkflowRoleSource
  /// Frozen for `launch` roles: identity and agent token only, never the launch plan.
  public let profile: WorkflowProfileBindingPayload?
  /// The role's pane; absent for a `launch` role until its pane exists.
  public let pane: WorkflowPaneBindingPayload?

  public init(
    source: WorkflowRoleSource, profile: WorkflowProfileBindingPayload? = nil,
    pane: WorkflowPaneBindingPayload? = nil
  ) {
    self.source = source
    self.profile = profile
    self.pane = pane
  }
}

nonisolated public struct WorkflowProfileBindingPayload: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let agent: String

  public init(id: String, name: String, agent: String) {
    self.id = id
    self.name = name
    self.agent = agent
  }
}

nonisolated public struct WorkflowPaneBindingPayload: Codable, Equatable, Sendable {
  public let id: String
  public let tabID: String?
  /// The short `pN` handle templates expose.
  public let handle: String
  public let displayName: String
  /// The detected agent token; absent for a bare shell.
  public let agent: String?

  enum CodingKeys: String, CodingKey {
    case id
    case tabID = "tab_id"
    case handle
    case displayName = "display_name"
    case agent
  }

  public init(id: String, tabID: String?, handle: String, displayName: String, agent: String?) {
    self.id = id
    self.tabID = tabID
    self.handle = handle
    self.displayName = displayName
    self.agent = agent
  }
}

nonisolated public struct WorkflowActivationPayload: Codable, Equatable, Sendable {
  public let ordinal: Int
  public let step: String
  public let role: String
  /// `waiting`, `persisting`, `provisional`, `delivered`, `skipped`, `revoked`.
  public let state: String
  public let dispatchID: String?
  public let delivery: String
  public let expect: WorkflowExpectationPayload
  /// The absolute `expect.timeout` deadline, when the step declares one.
  public let deadline: String?

  enum CodingKeys: String, CodingKey {
    case ordinal
    case step
    case role
    case state
    case dispatchID = "dispatch_id"
    case delivery
    case expect
    case deadline
  }

  public init(
    ordinal: Int,
    step: String,
    role: String,
    state: String,
    dispatchID: String?,
    delivery: String,
    expect: WorkflowExpectationPayload,
    deadline: String?
  ) {
    self.ordinal = ordinal
    self.step = step
    self.role = role
    self.state = state
    self.dispatchID = dispatchID
    self.delivery = delivery
    self.expect = expect
    self.deadline = deadline
  }
}

/// What a waiting activation requires of its delivery (dsl-spec §5).
nonisolated public struct WorkflowExpectationPayload: Codable, Equatable, Sendable {
  public let format: WorkflowDeliveryFormat
  public let sections: [String]
  public let verdicts: [String]?
  public let strict: Bool
  /// The exact `prowl workflow deliver` commands that complete the step, one per allowed verdict.
  public let completion: [String]

  public init(
    format: WorkflowDeliveryFormat, sections: [String], verdicts: [String]?, strict: Bool,
    completion: [String]
  ) {
    self.format = format
    self.sections = sections
    self.verdicts = verdicts
    self.strict = strict
    self.completion = completion
  }
}

nonisolated public struct WorkflowDeliveryRecordPayload: Codable, Equatable, Sendable {
  public let name: String
  public let ordinal: Int
  /// `deliveries/<name>.<ordinal>.md`.
  public let path: String
  /// `deliveries/<name>.md`, the atomically replaced latest view.
  public let latestPath: String
  public let verdict: String?
  public let deliveredAt: String

  enum CodingKeys: String, CodingKey {
    case name
    case ordinal
    case path
    case latestPath = "latest_path"
    case verdict
    case deliveredAt = "delivered_at"
  }

  public init(
    name: String, ordinal: Int, path: String, latestPath: String, verdict: String?,
    deliveredAt: String
  ) {
    self.name = name
    self.ordinal = ordinal
    self.path = path
    self.latestPath = latestPath
    self.verdict = verdict
    self.deliveredAt = deliveredAt
  }
}

nonisolated public struct WorkflowSelfInitiatedPayload: Codable, Equatable, Sendable {
  /// The line the runner would have typed, completion command included.
  public let line: String
  /// The saved task-only prompt for this invocation.
  public let promptPath: String?
  /// The `prowl workflow deliver` commands that complete the step, one per allowed verdict.
  public let completion: [String]

  enum CodingKeys: String, CodingKey {
    case line
    case promptPath = "prompt_path"
    case completion
  }

  public init(line: String, promptPath: String?, completion: [String]) {
    self.line = line
    self.promptPath = promptPath
    self.completion = completion
  }
}

// MARK: - deliver

nonisolated public struct WorkflowDeliverPayload: Codable, Equatable, Sendable {
  public let run: WorkflowRunPayload
  public let delivery: WorkflowDeliveryPayload

  public init(run: WorkflowRunPayload, delivery: WorkflowDeliveryPayload) {
    self.run = run
    self.delivery = delivery
  }
}

/// The receipt of one `prowl workflow deliver`. `delivered` means the output is the step's output
/// and the run advanced; `provisional` means it is on disk with the listed `warnings` and the
/// run waits for the user to accept it, ask again, or skip (decision H14 of docs-ai 063.007).
nonisolated public struct WorkflowDeliveryPayload: Codable, Equatable, Sendable {
  public let state: WorkflowDeliveryState
  public let ordinal: Int
  public let step: String
  public let role: String
  public let record: WorkflowDeliveryRecordPayload
  public let warnings: [WorkflowDeliveryWarningPayload]

  public init(
    state: WorkflowDeliveryState,
    ordinal: Int,
    step: String,
    role: String,
    record: WorkflowDeliveryRecordPayload,
    warnings: [WorkflowDeliveryWarningPayload]
  ) {
    self.state = state
    self.ordinal = ordinal
    self.step = step
    self.role = role
    self.record = record
    self.warnings = warnings
  }
}

nonisolated public enum WorkflowDeliveryState: String, Codable, Equatable, Sendable {
  case delivered
  case provisional
}

nonisolated public struct WorkflowDeliveryWarningPayload: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

// MARK: - validate

nonisolated public struct WorkflowValidatePayload: Codable, Equatable, Sendable {
  public let path: String
  public let valid: Bool
  /// Present when the file parsed, even if validation then failed.
  public let workflow: WorkflowIdentity?
  public let diagnostics: [WorkflowDiagnosticPayload]

  public init(
    path: String, valid: Bool, workflow: WorkflowIdentity?, diagnostics: [WorkflowDiagnosticPayload]
  ) {
    self.path = path
    self.valid = valid
    self.workflow = workflow
    self.diagnostics = diagnostics
  }

  public init(file: WorkflowSourceFile) {
    self.init(
      path: file.url.path(percentEncoded: false),
      valid: file.isValid,
      workflow: file.definition.map { WorkflowIdentity(id: $0.id, name: $0.name) },
      diagnostics: file.diagnostics.map(WorkflowDiagnosticPayload.init)
    )
  }
}

nonisolated public struct WorkflowIdentity: Codable, Equatable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

nonisolated public struct WorkflowDiagnosticPayload: Codable, Equatable, Sendable {
  public let severity: WorkflowDiagnosticSeverity
  public let code: String
  public let message: String
  public let line: Int?
  public let column: Int?

  public init(
    severity: WorkflowDiagnosticSeverity, code: String, message: String, line: Int?, column: Int?
  ) {
    self.severity = severity
    self.code = code
    self.message = message
    self.line = line
    self.column = column
  }

  public init(_ diagnostic: WorkflowDiagnostic) {
    self.init(
      severity: diagnostic.severity,
      code: diagnostic.code,
      message: diagnostic.message,
      line: diagnostic.location?.line,
      column: diagnostic.location?.column
    )
  }
}

// MARK: - schema

nonisolated public struct WorkflowSchemaPayload: Codable, Equatable, Sendable {
  /// The Draft 2020-12 JSON Schema of a workflow file, inline.
  public let schema: RawJSON

  public init(schema: RawJSON) {
    self.schema = schema
  }
}

nonisolated extension RawJSON: Equatable {
  public static func == (lhs: RawJSON, rhs: RawJSON) -> Bool {
    lhs.bytes == rhs.bytes
  }
}
