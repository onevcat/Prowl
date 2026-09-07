// supacode/Domain/Workflow/WorkflowRun.swift
// The state of one workflow run (docs-ai 063 B2, dsl-spec §5/§8/§10): frozen context and
// bindings, the position cursor, invocations and activations, deliveries, and the attention
// vocabulary the panel renders. Transitions live in WorkflowRunMachine.

import Foundation
import ProwlCLIShared

// MARK: - Identity and bindings

/// A pane a role is bound to; the handle is the short `pN` form templates expose.
nonisolated struct WorkflowPaneIdentity: Equatable, Sendable, Codable {
  let surfaceID: UUID
  let tabID: UUID?
  let handle: String
  /// The pane's launch-profile name when Prowl launched it, otherwise the detected agent's
  /// display name (or `shell` when none).
  let displayName: String
  /// The detected agent token; nil for a bare shell.
  let agent: String?

  enum CodingKeys: String, CodingKey {
    case surfaceID = "surface_id"
    case tabID = "tab_id"
    case handle
    case displayName = "display_name"
    case agent
  }
}

/// The profile frozen into a `launch` role: identity and agent token only — the launch plan
/// (with its environment) stays with the wiring layer and never reaches `run.json`.
nonisolated struct WorkflowProfileBinding: Equatable, Sendable, Codable {
  let id: UUID
  let name: String
  let agent: String
}

nonisolated enum WorkflowRoleBinding: Equatable, Sendable {
  case current(WorkflowPaneIdentity)
  case pick(WorkflowPaneIdentity)
  case launch(WorkflowProfileBinding, pane: WorkflowPaneIdentity?)

  var source: WorkflowRoleSource {
    switch self {
    case .current: .current
    case .pick: .pick
    case .launch: .launch
    }
  }

  var pane: WorkflowPaneIdentity? {
    switch self {
    case .current(let pane), .pick(let pane): pane
    case .launch(_, let pane): pane
    }
  }

  var profile: WorkflowProfileBinding? {
    if case .launch(let profile, _) = self { return profile }
    return nil
  }

  /// `roles.<r>.name` / `roles.<r>.agent` as dsl-spec §6 defines them.
  var displayName: String {
    switch self {
    case .current(let pane), .pick(let pane): pane.displayName
    case .launch(let profile, _): profile.name
    }
  }

  var agent: String {
    switch self {
    case .current(let pane), .pick(let pane): pane.agent ?? ""
    case .launch(let profile, _): profile.agent
    }
  }

  func binding(pane: WorkflowPaneIdentity) -> WorkflowRoleBinding {
    switch self {
    case .current: .current(pane)
    case .pick: .pick(pane)
    case .launch(let profile, _): .launch(profile, pane: pane)
    }
  }
}

// MARK: - Context

nonisolated enum WorkflowRunScope: Equatable, Sendable, Codable {
  case bundle
  case user
  case repo(repositoryID: String)

  /// The scope key of the binding memory (dsl-spec §3): `bundle`, `user`, or `repo:<repository id>`.
  var key: String {
    switch self {
    case .bundle: "bundle"
    case .user: "user"
    case .repo(let repositoryID): "repo:\(repositoryID)"
    }
  }

  var workflowScope: WorkflowScope {
    switch self {
    case .bundle: .bundle
    case .user: .user
    case .repo: .repo
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let key = try container.decode(String.self)
    switch key {
    case "bundle": self = .bundle
    case "user": self = .user
    default:
      guard key.hasPrefix("repo:") else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown workflow scope '\(key)'.")
      }
      self = .repo(repositoryID: String(key.dropFirst("repo:".count)))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(key)
  }
}

nonisolated struct WorkflowRunWorktree: Equatable, Sendable, Codable {
  let id: String
  let name: String
  let branch: String
  /// The worktree root every run-relative path hangs from.
  let path: String

  var rootURL: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

nonisolated struct WorkflowRunContext: Equatable, Sendable {
  let scope: WorkflowRunScope
  let definitionPath: String?
  let worktree: WorkflowRunWorktree
  var bundle: WorkflowPreparedBundle?
  var sourcePaneID: UUID?
  var sourceTabID: UUID?
  var literalActionInputs = false
  var historyDirectory: URL?
  var occupancy: WorkflowRunOccupancy?
}

/// Every path under a run directory, derived from validated slugs and the run UUID only.
nonisolated enum WorkflowRunPaths {
  static func runsDirectory(root: URL) -> URL {
    let storage = WorkflowHistoryStorage.configured
    return storage.baseURL.appending(path: storage.rootKey(root))
  }

  static func runDirectory(root: URL, runID: UUID, createdAt: Date? = nil) -> URL {
    let storage = WorkflowHistoryStorage.configured
    if createdAt == nil, let existing = try? storage.find(runID) { return existing }
    return storage.directory(root: root, createdAt: createdAt ?? Date(), runID: runID)
  }

  static func instructionURL(runDirectory: URL, stepID: String, ordinal: Int) -> URL {
    runDirectory.appending(path: "instructions", directoryHint: .isDirectory)
      .appending(path: "\(stepID).\(ordinal).md", directoryHint: .notDirectory)
  }

  /// `deliveries/<name>.<ordinal>.md`, or the latest view `deliveries/<name>.md` without an ordinal.
  static func deliveryURL(runDirectory: URL, name: String, ordinal: Int?) -> URL {
    let file = ordinal.map { "\(name).\($0).md" } ?? "\(name).md"
    return runDirectory.appending(path: "deliveries", directoryHint: .isDirectory)
      .appending(path: file, directoryHint: .notDirectory)
  }

  static func skillDirectory(runDirectory: URL, skillID: String) -> URL {
    runDirectory.appending(path: "skills", directoryHint: .isDirectory)
      .appending(path: skillID, directoryHint: .isDirectory)
  }

  static func path(_ url: URL) -> String {
    AgentProfileLaunchPlanner.pathString(url)
  }
}

// MARK: - Invocations and activations

nonisolated enum WorkflowActivationState: String, Equatable, Sendable, Codable {
  case waiting
  /// A validated delivery is being written to the run directory; the record completes once it is.
  case persisting
  /// The delivery is on disk but had issues a non-strict step tolerates; the user decides.
  case provisional
  case delivered
  case skipped
  case revoked
}

/// A waiting invocation (dsl-spec §5): the token correlates a delivery, the dispatch id is
/// the record in the shared dispatch store once the activation is open.
nonisolated struct WorkflowActivation: Equatable, Sendable {
  let ordinal: Int
  let stepID: String
  let role: String
  let token: String
  let expect: WorkflowExpectation
  let deliveryName: String
  var dispatchID: String?
  var state: WorkflowActivationState
  /// `expect.timeout` as an absolute deadline, fixed when the activation opened; a re-armed
  /// watchdog receives the remaining time, never a fresh cap.
  var deadline: Date?
  /// The validated body while the delivery is being persisted (never written to `run.json`).
  var pendingDelivery: WorkflowValidatedDelivery?

  var completion: WorkflowCompletionCommand {
    WorkflowCompletionCommand(token: token, verdicts: expect.verdicts)
  }
}

nonisolated enum WorkflowInvocationKind: String, Equatable, Sendable, Codable {
  case message
  case launch
}

nonisolated struct WorkflowInvocation: Equatable, Sendable {
  let ordinal: Int
  let stepID: String
  /// 1-based iteration when the step sits inside a loop.
  let iteration: Int?
  let role: String
  let kind: WorkflowInvocationKind
  let startedAt: Date
  var instructionPath: String?
  var content: WorkflowTaskContent?
  var activation: WorkflowActivation?
  var endedAt: Date?
}

nonisolated struct WorkflowDeliveryRecord: Equatable, Sendable, Codable {
  let name: String
  let ordinal: Int
  /// `deliveries/<name>.<ordinal>.md`.
  let path: String
  /// `deliveries/<name>.md`, the atomically replaced latest view.
  let latestPath: String
  let verdict: String?
  let deliveredAt: Date

  enum CodingKeys: String, CodingKey {
    case name
    case ordinal
    case path
    case latestPath = "latest_path"
    case verdict
    case deliveredAt = "delivered_at"
  }
}

// MARK: - Position and step records

nonisolated enum WorkflowStepState: String, Equatable, Sendable, Codable {
  case active
  case completed
  case skipped
  case failed
}

nonisolated struct WorkflowStepRecord: Equatable, Sendable {
  let stepID: String
  let iteration: Int?
  var state: WorkflowStepState
  var ordinal: Int?
}

// MARK: - Attention and status

nonisolated enum WorkflowAttentionAction: String, Equatable, Sendable, Codable, CaseIterable {
  case focusPane = "focus_pane"
  case nudge
  case keepWaiting = "keep_waiting"
  case retry
  case relaunch
  /// Keep a provisional delivery as it is.
  case acceptDelivery = "accept_delivery"
  /// Keep a provisional delivery and supply the verdict it lacks (one of the declared values).
  case acceptWithVerdict = "accept_with_verdict"
  /// Type the step's requirements into the role's pane again and keep waiting.
  case askAgain = "ask_again"
  case skip
  case cancel
}

nonisolated enum WorkflowAgentGoneReason: String, Equatable, Sendable, Codable {
  case sessionEnded = "session_ended"
  case paneClosed = "pane_closed"
  case processGone = "process_gone"
  /// The role has no pane: its launch was skipped or never succeeded.
  case notLaunched = "not_launched"
}

/// Why an injection did not deliver the line.
nonisolated enum WorkflowInjectionFailure: Equatable, Sendable {
  /// The role is working or blocked again; the step returns to its idle wait.
  case roleBusy
  case roleBlocked
  case surfaceMissing
  case insertFailed
  /// The insert succeeded; the line may sit unsubmitted in the pane's input.
  case submitFailed
  case activationUnavailable(String)
}

nonisolated enum WorkflowAttentionReason: Equatable, Sendable {
  case needsInput
  case idleWithoutDelivery
  case blocked
  case agentGone(WorkflowAgentGoneReason)
  case injectionFailed(WorkflowInjectionFailure)
  case launchFailed(String)
  case renderedTextInvalid
  case actionFailed(String)
  /// The validated output could not be written to the run directory.
  case persistFailed(String)
  /// A non-strict delivery is on disk with these issues; the user accepts, asks again, or skips.
  case deliveryIssues([WorkflowDeliveryIssue])
  case timeout
}

nonisolated struct WorkflowAttention: Equatable, Sendable {
  let reason: WorkflowAttentionReason
  let stepID: String
  let role: String?
  let ordinal: Int?
  let actions: [WorkflowAttentionAction]
  /// Panel copy (decision H7 of docs-ai 063.007); C1 renders it as is.
  let message: String
}

nonisolated enum WorkflowRunStatus: Equatable, Sendable {
  case running
  case needsAttention(WorkflowAttention)
  case completed
  case cancelled
  case skipped(step: String, dependent: String)
  case iterationLimitReached
  case interrupted

  var isTerminal: Bool {
    switch self {
    case .running, .needsAttention: false
    case .completed, .cancelled, .skipped, .iterationLimitReached, .interrupted: true
    }
  }

  var attention: WorkflowAttention? {
    if case .needsAttention(let attention) = self { return attention }
    return nil
  }
}

/// What the run is doing inside the current step.
nonisolated enum WorkflowRunPhase: Equatable, Sendable {
  case idle
  case waitingForRole(role: String, ordinal: Int)
  case injecting(ordinal: Int)
  case launching(ordinal: Int)
  case waitingForDelivery(ordinal: Int)
  case runningAction(stepID: String)
}

// MARK: - Run

nonisolated struct WorkflowRun: Equatable, Sendable {
  let id: UUID
  let definition: WorkflowDefinition
  let context: WorkflowRunContext
  let inputs: [String: String]
  let startedAt: Date
  var updatedAt: Date
  var finishedAt: Date?
  var bindings: [String: WorkflowRoleBinding]
  var status: WorkflowRunStatus = .running
  var phase: WorkflowRunPhase = .idle
  var invocations: [WorkflowInvocation] = []
  /// Latest delivered output per name (latest wins across steps).
  var deliveries: [String: WorkflowDeliveryRecord] = [:]
  var actionOutputs: [String: [String: WorkflowJSONValue]] = [:]
  var controlCursor: WorkflowControlCursor?
  var stepValues: [String: WorkflowJSONValue] = [:]
  var observations: [String: WorkflowJSONValue] = [:]
  var actionExecutionID: String?
  var actionAttempts: [String: Int] = [:]
  /// Output name → the step whose skip made it missing.
  var skippedOutputs: [String: String] = [:]
  /// Steps skipped at start (`--skip` / the start sheet).
  let preSkippedSteps: Set<String>
  var stepRecords: [WorkflowStepRecord] = []
  var nextOrdinal = 1
  /// The first step's rendered line when the run was started from the `current` role's own
  /// pane: returned to the caller instead of being typed (dsl-spec §9).
  var selfInitiatedLine: String?

  var runDirectory: URL {
    context.historyDirectory
      ?? WorkflowRunPaths.runDirectory(root: context.worktree.rootURL, runID: id, createdAt: startedAt)
  }

  var currentInvocation: WorkflowInvocation? {
    switch phase {
    case .waitingForRole(_, let ordinal), .injecting(let ordinal), .launching(let ordinal),
      .waitingForDelivery(let ordinal):
      return invocations.first { $0.ordinal == ordinal }
    case .idle, .runningAction:
      return nil
    }
  }

  /// The activation currently waiting for a delivery, if any.
  var currentActivation: WorkflowActivation? {
    guard case .waitingForDelivery(let ordinal) = phase else { return nil }
    return invocations.first { $0.ordinal == ordinal }?.activation
  }

  /// The activation of the invocation in flight, whatever its state.
  var activeActivation: WorkflowActivation? {
    currentInvocation?.activation
  }

  func activation(forDispatchID dispatchID: String) -> WorkflowActivation? {
    invocations.lazy.compactMap(\.activation).first { $0.dispatchID == dispatchID }
  }

  /// The step the position cursor points at; nil past the end of the sequence it is in.
  var currentStep: WorkflowStepDefinition? { controlCursor?.currentStep }
  var currentIteration: Int? { controlCursor?.iteration }

  /// Whether the runner will deliver a `message` to the `current` role (dsl-spec §3).
  func deliversToCurrentRole() -> Bool {
    guard let current = definition.roles.first(where: { $0.source == .current }) else { return false }
    return definition.flattenedSteps.contains { step in
      if case .message(let role, _, _) = step.action, role == current.name {
        return !preSkippedSteps.contains(step.id)
      }
      return false
    }
  }
}
