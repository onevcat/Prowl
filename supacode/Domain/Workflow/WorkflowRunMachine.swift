// supacode/Domain/Workflow/WorkflowRunMachine.swift
// The pure run state machine (docs-ai 063 B2, decision H2): `apply(event)` and `deliver(...)`
// mutate a `WorkflowRun` value and return the effects the wiring layer must perform. No I/O
// happens here; every transport concern is an effect.

import Foundation
import ProwlCLIShared

// MARK: - Watchdog vocabulary shared with the driver

nonisolated struct WorkflowWatchdogRequest: Equatable, Sendable {
  let ordinal: Int
  let stepID: String
  let role: String
  let surfaceID: UUID
  let dispatchID: String?
  /// `expect.timeout`; nil = no hard cap.
  let timeoutSeconds: Int?
  let timeoutPolicy: WorkflowTimeoutPolicy
  /// Resumed after "Keep waiting" / "Nudge again": the one automatic nudge is spent.
  let nudgedAlready: Bool
}

nonisolated enum WorkflowWatchdogAttention: Equatable, Sendable {
  case needsInput
  case idleWithoutDelivery
  case blocked
  case agentGone(WorkflowAgentGoneReason)
}

nonisolated enum WorkflowWatchdogVerdict: Equatable, Sendable {
  case nudge
  case attention(WorkflowWatchdogAttention)
  case timeout
}

// MARK: - Events and effects

nonisolated enum WorkflowUserAction: Equatable, Sendable {
  case retry
  case relaunch
  case skip
  case cancel
  case nudge
  case keepWaiting
  /// Keep a provisional delivery; `verdict` supplies the declared value it lacked, if any.
  case acceptDelivery(verdict: String?)
  /// Type the requirements into the role's pane again and wait for a new delivery.
  case askAgain
}

nonisolated enum WorkflowRunEvent: Equatable, Sendable {
  case roleIdle(ordinal: Int)
  /// The idle wait ended without an idle role: the pane is gone, its agent stays blocked, or it
  /// hosts no agent to inject into. The step enters attention as a failed injection would.
  case roleUnavailable(ordinal: Int, WorkflowInjectionFailure)
  case injectionSucceeded(ordinal: Int, dispatchID: String?)
  case injectionFailed(ordinal: Int, WorkflowInjectionFailure)
  case launched(ordinal: Int, pane: WorkflowPaneIdentity, dispatchID: String?)
  case launchFailed(ordinal: Int, reason: String)
  case actionCompleted(stepID: String, outputs: [String: WorkflowJSONValue], executionID: String = "")
  case actionFailed(stepID: String, reason: String, executionID: String = "", retryAllowed: Bool = true)
  case continueControlFlow
  /// The `.persistDelivery` effect of a delivery succeeded / failed (dsl-spec §5: validate,
  /// persist, then complete the record).
  case deliveryPersisted(ordinal: Int)
  case deliveryPersistFailed(ordinal: Int, reason: String)
  case watchdog(ordinal: Int, WorkflowWatchdogVerdict)
  case user(WorkflowUserAction)
}

nonisolated struct WorkflowLaunchRequest: Equatable, Sendable {
  let role: String
  let ordinal: Int
  let profile: WorkflowProfileBinding
  let prompt: String
  /// Child-environment values (`PROWL_WORKFLOW_*`); never persisted.
  let environment: [String: String]
  let placement: WorkflowPlacement
  let direction: WorkflowSplitDirection
  let background: Bool
  /// The `current` role's pane when the workflow has one; the split anchor.
  let anchorSurfaceID: UUID?
  let skill: String?
  let expectsDelivery: Bool
  /// A Relaunch re-delivering a `message` step's content as the kickoff prompt.
  let redelivery: Bool
}

nonisolated enum WorkflowRunEffect: Equatable, Sendable {
  /// Wait until the role is idle (dsl-spec §4 injection gate), then send `.roleIdle`.
  case awaitRoleIdle(role: String, surfaceID: UUID, ordinal: Int)
  /// The step left its idle wait without injecting (Skip / Cancel / Retry); stop waiting.
  case cancelRoleWait(ordinal: Int)
  /// Self-initiated first step: open the activation record without typing anything.
  case openActivation(role: String, surfaceID: UUID, ordinal: Int)
  case materializePrompt(ordinal: Int, stepID: String, text: String)
  case materializeSkill(id: String)
  /// Issue + bind the activation (when `opensActivation`) and type the line as one operation.
  case inject(role: String, surfaceID: UUID, ordinal: Int, line: String, opensActivation: Bool)
  /// Type a line without opening an activation (the nudge).
  case typeLine(role: String, surfaceID: UUID, line: String)
  case launch(WorkflowLaunchRequest)
  case runAction(stepID: String, actionID: String, inputs: [String: WorkflowJSONValue])
  case yieldControl
  case notify(String)
  case close(role: String, surfaceID: UUID)
  case abandonActivation(dispatchID: String, reason: String)
  case completeActivation(dispatchID: String, summary: String)
  case armWatchdog(WorkflowWatchdogRequest)
  case disarmWatchdog(ordinal: Int)
  case persistDelivery(name: String, ordinal: Int, body: String)
  case persist
  case log(String)
  case finished(WorkflowRunStatus)
}

// MARK: - Deliveries and skips

nonisolated enum WorkflowDeliverySelector: Equatable, Sendable {
  /// From the caller pane's pending dispatch; the token must match the activation.
  case token(String?)
  /// `--run --step` without a caller pane: the step's current activation, no token needed.
  case manual(stepID: String)
}

nonisolated struct WorkflowDeliveryReceipt: Equatable, Sendable {
  let ordinal: Int
  let stepID: String
  let record: WorkflowDeliveryRecord
  /// Non-empty when the delivery was accepted provisionally; the CLI reports them as warnings.
  let issues: [WorkflowDeliveryIssue]
}

nonisolated enum WorkflowSkipConsequence: Equatable, Sendable {
  /// The step produces no delivery; skipping it affects nothing else.
  case noDelivery
  /// Only optional action inputs read the delivery; those actions run without the key.
  case continues(optionalInputs: [String])
  /// A template, condition, or required action input reads the delivery: the run ends `skipped`.
  case endsRun(dependent: String)
}

nonisolated enum WorkflowRunStartError: Error, Equatable, Sendable {
  case invalidInput(name: String, reason: String)
  case unsafePath(String)
  case unknownSkipStep(String)
  /// `--skip` names a step without an `expect`; only awaited deliveries can be skipped at start.
  case skipNotExpecting(String)
  case skipNotAllowed(step: String, dependent: String)
  case missingBinding(role: String)
}

/// Everything `WorkflowRunMachine.start` needs: the validated definition, the frozen context
/// and bindings, and the start-sheet / CLI choices.
nonisolated struct WorkflowRunStartRequest: Sendable {
  let definition: WorkflowDefinition
  let runID: UUID
  let context: WorkflowRunContext
  let bindings: [String: WorkflowRoleBinding]
  let inputs: [String: String]
  let skippedSteps: Set<String>
  /// The run was started from the pane that is the `current` role (dsl-spec §9).
  let selfInitiated: Bool
  let limits: WorkflowDeliveryLimits

  init(
    definition: WorkflowDefinition,
    runID: UUID,
    context: WorkflowRunContext,
    bindings: [String: WorkflowRoleBinding],
    inputs: [String: String] = [:],
    skippedSteps: Set<String> = [],
    selfInitiated: Bool = false,
    limits: WorkflowDeliveryLimits = WorkflowDeliveryLimits()
  ) {
    self.definition = definition
    self.runID = runID
    self.context = context
    self.bindings = bindings
    self.inputs = inputs
    self.skippedSteps = skippedSteps
    self.selfInitiated = selfInitiated
    self.limits = limits
  }
}

// MARK: - Machine

nonisolated struct WorkflowRunMachine {
  private(set) var run: WorkflowRun
  let limits: WorkflowDeliveryLimits
  let now: @Sendable () -> Date
  let makeToken: @Sendable () -> String

  // MARK: Start

  /// Freezes the run and enters step 1. Throws the start-time validation failures the CLI
  /// maps to `INVALID_ARGUMENT` / `UNSAFE_PATH`.
  static func start(
    _ request: WorkflowRunStartRequest,
    now: @escaping @Sendable () -> Date,
    makeToken: @escaping @Sendable () -> String = { UUID().uuidString }
  ) throws(WorkflowRunStartError) -> (machine: WorkflowRunMachine, effects: [WorkflowRunEffect]) {
    let definition = request.definition
    let context = request.context
    let bindings = request.bindings
    let skippedSteps = request.skippedSteps
    let runID = request.runID
    let inputs = try resolveInputs(definition: definition, provided: request.inputs)
    guard WorkflowRenderedText.isSingleLine(context.worktree.path) else {
      throw .unsafePath(context.worktree.path)
    }
    let launchRoles = WorkflowRoleRequirements.launchRoles(in: definition, inputs: inputs, skipped: skippedSteps)
    for role in definition.roles
    where bindings[role.name] == nil && (role.source != .launch || launchRoles.contains(role.name)) {
      throw .missingBinding(role: role.name)
    }
    let startedAt = now()
    var run = WorkflowRun(
      id: runID,
      definition: definition,
      context: context,
      inputs: inputs,
      startedAt: startedAt,
      updatedAt: startedAt,
      bindings: bindings,
      preSkippedSteps: skippedSteps
    )
    do { run.controlCursor = try WorkflowControlCursor(definition: definition) } catch {
      throw .invalidInput(name: "state", reason: "\(error)")
    }
    let flattened = definition.flattenedSteps
    for stepID in skippedSteps.sorted() {
      guard let step = flattened.first(where: { $0.id == stepID }) else { throw .unknownSkipStep(stepID) }
      guard step.action.expect != nil else { throw .skipNotExpecting(stepID) }
    }
    for stepID in skippedSteps.sorted() {
      if case .endsRun(let dependent) = Self.startConsequence(
        forStep: stepID, definition: definition, preSkipped: skippedSteps)
      {
        throw .skipNotAllowed(step: stepID, dependent: dependent)
      }
    }
    var machine = WorkflowRunMachine(run: run, limits: request.limits, now: now, makeToken: makeToken)
    var effects: [WorkflowRunEffect] = [
      .log("Run \(runID.uuidString) of workflow '\(definition.id)' started."), .persist,
    ]
    machine.enterCurrentStep(selfInitiated: request.selfInitiated, effects: &effects)
    return (machine, effects)
  }

  private static func resolveInputs(
    definition: WorkflowDefinition, provided: [String: String]
  ) throws(WorkflowRunStartError) -> [String: String] {
    for name in provided.keys.sorted() where definition.input(named: name) == nil {
      throw .invalidInput(name: name, reason: "the workflow declares no input '\(name)'.")
    }
    var resolved: [String: String] = [:]
    for input in definition.inputs {
      guard let value = provided[input.name] ?? input.defaultValue?.stringValue else {
        throw .invalidInput(name: input.name, reason: "a value is required.")
      }
      switch input.type {
      case .integer:
        guard let number = Int(value) else {
          throw .invalidInput(name: input.name, reason: "'\(value)' is not an integer.")
        }
        if let minimum = input.minimum, number < minimum {
          throw .invalidInput(name: input.name, reason: "\(number) is below the minimum \(minimum).")
        }
        if let maximum = input.maximum, number > maximum {
          throw .invalidInput(name: input.name, reason: "\(number) is above the maximum \(maximum).")
        }
        resolved[input.name] = String(number)
      case .string:
        guard WorkflowRenderedText.isSingleLine(value) else {
          throw .invalidInput(name: input.name, reason: "the value must be one line without control characters.")
        }
        resolved[input.name] = value
      case .enum:
        guard input.values.contains(value) else {
          throw .invalidInput(
            name: input.name, reason: "'\(value)' is not one of \(input.values.joined(separator: ", ")).")
        }
        guard WorkflowRenderedText.isSingleLine(value) else {
          throw .invalidInput(name: input.name, reason: "the value must be one line without control characters.")
        }
        resolved[input.name] = value
      }
    }
    return resolved
  }

  // MARK: Events

  mutating func apply(_ event: WorkflowRunEvent) -> [WorkflowRunEffect] {
    let archived = archiveDeliveryPersistence(event)
    guard !run.status.isTerminal else { return archived ? [.persist] : [] }
    var effects: [WorkflowRunEffect] = []
    switch event {
    case .roleIdle(let ordinal):
      guard case .waitingForRole(_, ordinal) = run.phase else { return [] }
      injectCurrentMessage(ordinal: ordinal, effects: &effects)
    case .injectionSucceeded(let ordinal, let dispatchID):
      guard case .injecting(ordinal) = run.phase else { return [] }
      openWaiting(ordinal: ordinal, dispatchID: dispatchID, effects: &effects)
    case .injectionFailed(let ordinal, let failure), .roleUnavailable(let ordinal, let failure):
      applyInjectionFailed(ordinal: ordinal, failure: failure, effects: &effects)
    case .launched(let ordinal, let pane, let dispatchID):
      applyLaunched(ordinal: ordinal, pane: pane, dispatchID: dispatchID, effects: &effects)
    case .launchFailed(let ordinal, let reason):
      applyLaunchFailed(ordinal: ordinal, reason: reason, effects: &effects)
    case .actionCompleted(let stepID, let outputs, let executionID):
      applyActionCompleted(stepID: stepID, outputs: outputs, executionID: executionID, effects: &effects)
    case .actionFailed(let stepID, let reason, let executionID, let retryAllowed):
      applyActionFailed(
        stepID: stepID, reason: reason, executionID: executionID, retryAllowed: retryAllowed, effects: &effects)
    case .continueControlFlow:
      continueControlFlow(effects: &effects)
    case .deliveryPersisted(let ordinal):
      applyDeliveryPersisted(ordinal: ordinal, effects: &effects)
    case .deliveryPersistFailed(let ordinal, let reason):
      applyDeliveryPersistFailed(ordinal: ordinal, reason: reason, effects: &effects)
    case .watchdog(let ordinal, let verdict):
      applyWatchdog(ordinal: ordinal, verdict: verdict, effects: &effects)
    case .user(let action):
      applyUser(action, effects: &effects)
    }
    return archived && !effects.contains(.persist) ? effects + [.persist] : effects
  }

  private mutating func archiveDeliveryPersistence(_ event: WorkflowRunEvent) -> Bool {
    let ordinal: Int
    let failure: String?
    switch event {
    case .deliveryPersisted(let value):
      ordinal = value
      failure = nil
    case .deliveryPersistFailed(let value, let reason):
      ordinal = value
      failure = reason
    default: return false
    }
    guard let submission = run.pendingHistorySubmissions.removeValue(forKey: ordinal),
      let index = run.stepRecords.lastIndex(where: { $0.ordinal == ordinal })
    else { return false }
    if let failure {
      let message = "Delivery could not be saved: \(failure)"
      run.stepRecords[index].error = run.stepRecords[index].error.map { $0 + "\n" + message } ?? message
    } else {
      run.stepRecords[index].delivery = submission.delivery
      run.stepRecords[index].submissions = (run.stepRecords[index].submissions ?? []) + [submission]
    }
    run.updatedAt = now()
    return true
  }

  private mutating func continueControlFlow(effects: inout [WorkflowRunEffect]) {
    guard run.phase == .idle else { return }
    advance(effects: &effects)
  }

  private mutating func applyInjectionFailed(
    ordinal: Int, failure: WorkflowInjectionFailure, effects: inout [WorkflowRunEffect]
  ) {
    switch run.phase {
    case .injecting(ordinal):
      break
    case .waitingForRole(_, ordinal):
      // `.roleUnavailable`: the idle wait ended without an idle role; the step fails as an injection would.
      run.phase = .injecting(ordinal: ordinal)
    default:
      return
    }
    guard let invocation = invocation(ordinal) else { return }
    if failure == .roleBusy {
      guard let surfaceID = run.bindings[invocation.role]?.pane?.surfaceID else { return }
      run.phase = .waitingForRole(role: invocation.role, ordinal: ordinal)
      effects.append(.awaitRoleIdle(role: invocation.role, surfaceID: surfaceID, ordinal: ordinal))
      effects.append(
        .log("Step '\(invocation.stepID)': role '\(invocation.role)' is busy again; waiting for it to be idle."))
      return
    }
    raiseAttention(
      .injectionFailed(failure), stepID: invocation.stepID, role: invocation.role, ordinal: ordinal, effects: &effects)
  }

  private mutating func applyLaunched(
    ordinal: Int, pane: WorkflowPaneIdentity, dispatchID: String?, effects: inout [WorkflowRunEffect]
  ) {
    guard case .launching(ordinal) = run.phase, let invocation = invocation(ordinal),
      let binding = run.bindings[invocation.role]
    else { return }
    if let previous = binding.pane, !run.participants[invocation.role, default: []].contains(previous) {
      run.participants[invocation.role, default: []].append(previous)
    }
    run.participants[invocation.role, default: []].append(pane)
    run.bindings[invocation.role] = binding.binding(pane: pane)
    updateInvocation(ordinal: ordinal) {
      $0.target = .init(source: binding.source, profile: binding.profile, pane: pane)
    }
    effects.append(.log("Step '\(invocation.stepID)': role '\(invocation.role)' launched in \(pane.handle)."))
    openWaiting(ordinal: ordinal, dispatchID: dispatchID, effects: &effects)
  }

  private mutating func applyLaunchFailed(ordinal: Int, reason: String, effects: inout [WorkflowRunEffect]) {
    guard case .launching(ordinal) = run.phase, let invocation = invocation(ordinal) else { return }
    raiseAttention(
      .launchFailed(reason), stepID: invocation.stepID, role: invocation.role, ordinal: ordinal, effects: &effects)
  }

  private mutating func applyActionFailed(
    stepID: String, reason: String, executionID: String, retryAllowed: Bool, effects: inout [WorkflowRunEffect]
  ) {
    guard run.actionExecutionID == executionID, case .runningAction(stepID) = run.phase,
      run.currentStep?.id == stepID
    else { return }
    raiseAttention(
      .actionFailed(reason), stepID: stepID, role: nil, ordinal: nil, effects: &effects,
      allowedActions: retryAllowed ? nil : [.cancel])
  }

  private mutating func applyActionCompleted(
    stepID: String, outputs: [String: WorkflowJSONValue], executionID: String, effects: inout [WorkflowRunEffect]
  ) {
    guard run.actionExecutionID == executionID, case .runningAction(stepID) = run.phase,
      run.currentStep?.id == stepID
    else { return }
    if let index = run.stepRecords.indices.last {
      run.stepRecords[index].outputs = outputs
    }
    run.actionOutputs[stepID] = outputs
    completeCurrentStep(effects: &effects)
    effects.append(.log("Step '\(stepID)': action completed."))
    advance(effects: &effects)
  }

  // MARK: Deliveries

  /// Accepts one delivery for the activation `ordinal` (the caller pane's pending dispatch
  /// resolved by the wiring layer; nil = the current activation). Errors map to the CLI codes.
  mutating func deliver(
    ordinal: Int?,
    selector: WorkflowDeliverySelector,
    body: String,
    verdict: String?
  ) -> (result: Result<WorkflowDeliveryReceipt, WorkflowDeliveryError>, effects: [WorkflowRunEffect]) {
    guard !run.status.isTerminal, let activation = run.currentActivation, activation.state == .waiting,
      ordinal == nil || ordinal == activation.ordinal
    else {
      return (.failure(.stepNotExpecting), [])
    }
    switch selector {
    case .token(nil):
      return (.failure(.tokenRequired), [])
    case .token(let token?):
      guard token == activation.token else { return (.failure(.tokenInvalid), []) }
    case .manual(let stepID):
      guard stepID == activation.stepID else { return (.failure(.stepNotExpecting), []) }
    }
    let validated: WorkflowValidatedDelivery
    switch WorkflowDeliveryValidator.validate(body: body, verdict: verdict, expect: activation.expect, limits: limits) {
    case .failure(let error):
      return (.failure(error), [])
    case .success(let delivery):
      validated = delivery
    }
    let record = deliveryRecord(for: activation, verdict: validated.verdict)
    updateActivation(ordinal: activation.ordinal) {
      $0.state = .persisting
      $0.pendingDelivery = validated
    }
    let issueNote =
      validated.issues.isEmpty ? "" : " with issues: " + validated.issues.map(\.message).joined(separator: "; ")
    run.status = .running
    run.updatedAt = now()
    // The watchdog supervises a *waiting* delivery: an accepted one is no longer its business,
    // so it is disarmed before the delivery is even written and queued verdicts are ignored.
    let effects: [WorkflowRunEffect] = [
      .disarmWatchdog(ordinal: activation.ordinal),
      .log(
        "Step '\(activation.stepID)': delivery '\(activation.deliveryName)' accepted "
          + "(invocation \(activation.ordinal))\(issueNote); persisting."),
      deliveryPersistenceEffect(activation: activation, delivery: validated),
    ]
    return (
      .success(
        WorkflowDeliveryReceipt(
          ordinal: activation.ordinal, stepID: activation.stepID, record: record, issues: validated.issues)),
      effects
    )
  }

  private func deliveryRecord(for activation: WorkflowActivation, verdict: String?) -> WorkflowDeliveryRecord {
    WorkflowDeliveryRecord(
      name: activation.deliveryName,
      ordinal: activation.ordinal,
      path: WorkflowRunPaths.path(
        WorkflowRunPaths.deliveryURL(
          runDirectory: run.runDirectory, name: activation.deliveryName, ordinal: activation.ordinal)),
      latestPath: WorkflowRunPaths.path(
        WorkflowRunPaths.deliveryURL(runDirectory: run.runDirectory, name: activation.deliveryName, ordinal: nil)),
      verdict: verdict,
      deliveredAt: now()
    )
  }

  private mutating func deliveryPersistenceEffect(
    activation: WorkflowActivation, delivery: WorkflowValidatedDelivery
  ) -> WorkflowRunEffect {
    run.pendingHistorySubmissions[activation.ordinal] = .init(
      delivery: submissionRecord(activation: activation, delivery: delivery, verdict: delivery.verdict),
      accepted: false, issues: delivery.issues.map(\.message))
    return .persistDelivery(name: activation.deliveryName, ordinal: activation.ordinal, body: delivery.body)
  }

  private func submissionRecord(
    activation: WorkflowActivation, delivery: WorkflowValidatedDelivery, verdict: String?
  ) -> WorkflowDeliveryRecord {
    let record = deliveryRecord(for: activation, verdict: verdict)
    return WorkflowDeliveryRecord(
      name: record.name, ordinal: record.ordinal,
      path: WorkflowRunPaths.submissionURL(
        runDirectory: run.runDirectory, name: record.name,
        ordinal: record.ordinal, body: delivery.body
      ).path,
      latestPath: record.latestPath, verdict: verdict, deliveredAt: record.deliveredAt)
  }

  private mutating func applyDeliveryPersistFailed(ordinal: Int, reason: String, effects: inout [WorkflowRunEffect]) {
    guard let activation = run.activeActivation, activation.ordinal == ordinal, activation.state == .persisting
    else { return }
    raiseAttention(
      .persistFailed(reason), stepID: activation.stepID, role: activation.role, ordinal: ordinal, effects: &effects)
  }

  /// The delivery is on disk: a clean delivery completes the dispatch record and advances; one
  /// with issues stays provisional and asks the user (Accept / Accept with verdict / Ask again).
  private mutating func applyDeliveryPersisted(ordinal: Int, effects: inout [WorkflowRunEffect]) {
    guard case .waitingForDelivery(ordinal) = run.phase, let activation = run.activeActivation,
      activation.state == .persisting, let delivery = activation.pendingDelivery
    else { return }
    guard delivery.issues.isEmpty else {
      updateActivation(ordinal: ordinal) { $0.state = .provisional }
      raiseAttention(
        .deliveryIssues(delivery.issues), stepID: activation.stepID, role: activation.role, ordinal: ordinal,
        effects: &effects)
      return
    }
    acceptDelivery(activation: activation, delivery: delivery, verdict: delivery.verdict, effects: &effects)
  }

  /// Records the delivery, completes the dispatch record, and advances.
  private mutating func acceptDelivery(
    activation: WorkflowActivation, delivery: WorkflowValidatedDelivery, verdict: String?,
    effects: inout [WorkflowRunEffect]
  ) {
    let ordinal = activation.ordinal
    let record = deliveryRecord(for: activation, verdict: verdict)
    if let index = run.stepRecords.lastIndex(where: { $0.ordinal == ordinal }) {
      let archived = submissionRecord(activation: activation, delivery: delivery, verdict: verdict)
      run.stepRecords[index].delivery = archived
      if let last = run.stepRecords[index].submissions?.indices.last {
        run.stepRecords[index].submissions?[last].accepted = true
        run.stepRecords[index].submissions?[last].delivery = archived
      }
    }
    run.deliveries[activation.deliveryName] = record
    run.skippedDeliveries[activation.deliveryName] = nil
    updateActivation(ordinal: ordinal) {
      $0.state = .delivered
      $0.pendingDelivery = nil
    }
    if let dispatchID = activation.dispatchID {
      let verdictNote = verdict.map { " with verdict '\($0)'" } ?? ""
      effects.append(
        .completeActivation(
          dispatchID: dispatchID,
          summary:
            "Received delivery '\(activation.deliveryName)' for workflow step '\(activation.stepID)'\(verdictNote)."
        ))
    }
    effects.append(
      .log("Step '\(activation.stepID)': delivery '\(activation.deliveryName)' delivered (invocation \(ordinal))."))
    run.status = .running
    completeCurrentStep(effects: &effects)
    advance(effects: &effects)
  }

  // MARK: Skip consequence

  func skipConsequence(forStep stepID: String) -> WorkflowSkipConsequence {
    Self.skipConsequence(forStep: stepID, in: run)
  }

  /// The §5 Skip rule at start time, for the start sheet and `--skip` validation alike: the
  /// consequence of skipping `stepID` given the other steps already chosen to skip, or nil when
  /// the step carries no `expect` (or does not exist) and so offers no skip choice.
  static func startSkipConsequence(
    forStep stepID: String, definition: WorkflowDefinition, alreadySkipped: Set<String>
  ) -> WorkflowSkipConsequence? {
    guard let step = definition.flattenedSteps.first(where: { $0.id == stepID }),
      step.action.expect != nil
    else { return nil }
    return startConsequence(forStep: stepID, definition: definition, preSkipped: alreadySkipped)
  }

  /// Before execution, conservatively inspect every branch that could consume a skipped delivery.
  private static func startConsequence(
    forStep stepID: String, definition: WorkflowDefinition, preSkipped: Set<String>
  ) -> WorkflowSkipConsequence {
    guard let name = definition.flattenedSteps.first(where: { $0.id == stepID })?.deliveryName else {
      return .noDelivery
    }
    let remaining = definition.steps
    return consequence(of: name, forStep: stepID, remaining: remaining, preSkipped: preSkipped)
  }

  /// Inspect the cursor's remaining steps, including subsequent loop iterations, for required readers.
  private static func skipConsequence(forStep stepID: String, in run: WorkflowRun)
    -> WorkflowSkipConsequence
  {
    guard let name = run.definition.flattenedSteps.first(where: { $0.id == stepID })?.deliveryName else {
      return .noDelivery
    }
    return consequence(
      of: name, forStep: stepID,
      remaining: run.controlCursor?.remainingSteps ?? run.definition.steps, preSkipped: run.preSkippedSteps)
  }

  private static func consequence(
    of name: String, forStep stepID: String, remaining: [WorkflowStepDefinition],
    preSkipped: Set<String>
  ) -> WorkflowSkipConsequence {
    var optional: [String] = []
    for step in remaining where step.id != stepID && !preSkipped.contains(step.id) {
      if let dependent = reader(of: name, in: step, preSkipped: preSkipped, optional: &optional) {
        return .endsRun(dependent: dependent)
      }
    }
    return .continues(optionalInputs: optional)
  }

  /// The id of the step that reads `name` in a way the Skip rule does not tolerate, or nil.
  private static func reader(
    of name: String, in step: WorkflowStepDefinition, preSkipped: Set<String>, optional: inout [String]
  ) -> String? {
    if let title = step.title, references(name, in: title) { return step.id }
    switch step.action {
    case .message(_, let prompt, _):
      if references(name, in: prompt) { return step.id }
    case .launch(_, let prompt, _, _):
      if references(name, in: prompt) { return step.id }
    case .notify(let text):
      if references(name, in: text) { return step.id }
    case .close:
      break
    case .action(_, let inputs):
      if inputs.values.contains(where: { references(name, in: $0) }) { return step.id }
    case .control(let control):
      return controlReader(of: name, in: step, control: control, preSkipped: preSkipped, optional: &optional)
    }

    return nil
  }

  private static func controlReader(
    of name: String, in step: WorkflowStepDefinition, control: WorkflowControlStep,
    preSkipped: Set<String>, optional: inout [String]
  ) -> String? {
    let expressions: [String]
    switch control {
    case .set(let assignments): expressions = Array(assignments.values)
    case .conditional(let condition, _, _), .loop(let condition, _, _): expressions = [condition]
    case .breakLoop, .continueLoop: expressions = []
    }
    if expressions.contains(where: { references(name, in: "{{ " + $0 + " }}") }) { return step.id }
    for inner in step.action.children where !preSkipped.contains(inner.id) {
      if let dependent = reader(of: name, in: inner, preSkipped: preSkipped, optional: &optional) { return dependent }
    }
    return nil
  }

  private static func references(_ name: String, in text: String) -> Bool {
    guard let paths = try? WorkflowExpression.requiredReferences(in: text) else { return false }
    return paths.contains { $0.count >= 2 && $0[0] == "deliveries" && $0[1] == name }
  }

  private static func references(_ name: String, in value: WorkflowJSONValue) -> Bool {
    switch value {
    case .string(let text): references(name, in: text)
    case .array(let items): items.contains { references(name, in: $0) }
    case .object(let fields): fields.values.contains { references(name, in: $0) }
    default: false
    }
  }

  // MARK: Advancing

  /// Executes steps from the cursor until one needs the outside world (or the run ends).
  private mutating func advance(effects: inout [WorkflowRunEffect]) {
    enterCurrentStep(selfInitiated: false, effects: &effects)
  }

  private mutating func enterCurrentStep(selfInitiated: Bool, effects: inout [WorkflowRunEffect]) {
    guard run.status == .running else { return }
    run.phase = .idle
    while run.status == .running {
      guard prepareControlStep(effects: &effects) else { return }
      guard let step = run.currentStep else {
        finish(.completed, effects: &effects)
        return
      }
      run.stepValues = run.expressionValues(capturedAt: now())
      if run.preSkippedSteps.contains(step.id) {
        skipAtStart(step, effects: &effects)
        continue
      }
      switch step.action {
      case .message:
        enterMessage(step, selfInitiated: selfInitiated, effects: &effects)
        return
      case .launch:
        enterLaunch(step, effects: &effects)
        return
      case .action(let id, let inputs):
        enterAction(step, id: id, inputs: inputs, effects: &effects)
        return
      case .notify(let text):
        guard enterNotify(step, text: text, effects: &effects) else { return }
      case .close(let role):
        enterClose(step, role: role, effects: &effects)
      case .control:
        return
      }
    }
  }

  private mutating func skipAtStart(_ step: WorkflowStepDefinition, effects: inout [WorkflowRunEffect]) {
    recordStep(step, state: .skipped, ordinal: nil)
    if let name = step.deliveryName {
      run.skippedDeliveries[name] = step.id
    }
    effects.append(.log("Step '\(step.id)': skipped at start."))
    moveNext()
  }

  /// False when rendering ended the run.
  private mutating func enterNotify(_ step: WorkflowStepDefinition, text: String, effects: inout [WorkflowRunEffect])
    -> Bool
  {
    guard let rendered = render(text, step: step, effects: &effects) else { return false }
    recordStep(step, state: .completed, ordinal: nil)
    run.stepRecords[run.stepRecords.count - 1].summary = rendered
    effects.append(.notify(rendered))
    effects.append(.log("Step '\(step.id)': notified \"\(rendered)\"."))
    moveNext()
    return true
  }

  private mutating func enterClose(_ step: WorkflowStepDefinition, role: String, effects: inout [WorkflowRunEffect]) {
    recordStep(step, state: .completed, ordinal: nil)
    if let surfaceID = run.bindings[role]?.pane?.surfaceID {
      run.stepRecords[run.stepRecords.count - 1].summary = "Requested closure of role '\(role)'."
      effects.append(.close(role: role, surfaceID: surfaceID))
      effects.append(.log("Step '\(step.id)': close requested for role '\(role)'."))
    } else {
      run.stepRecords[run.stepRecords.count - 1].summary = "Role '\(role)' has no pane to close."
      effects.append(.log("Step '\(step.id)': role '\(role)' has no pane to close."))
    }
    moveNext()
  }

  private mutating func moveNext() {
    run.controlCursor?.complete()
  }

  // MARK: Step entry

  private mutating func enterMessage(
    _ step: WorkflowStepDefinition, selfInitiated: Bool, effects: inout [WorkflowRunEffect]
  ) {
    guard case .message(let role, let prompt, let expect) = step.action else { return }
    let ordinal = mintOrdinal()
    run.invocations.append(
      WorkflowInvocation(
        ordinal: ordinal, stepID: step.id, iteration: run.currentIteration, role: role, kind: .message, startedAt: now()
      ))
    recordStep(step, state: .active, ordinal: ordinal)
    guard let pane = run.bindings[role]?.pane else {
      run.phase = .injecting(ordinal: ordinal)
      raiseAttention(.agentGone(.notLaunched), stepID: step.id, role: role, ordinal: ordinal, effects: &effects)
      return
    }
    let isCurrentRole = run.definition.role(named: role)?.source == .current
    if selfInitiated, isCurrentRole {
      guard
        let line = renderMessageLine(ordinal: ordinal, step: step, prompt: prompt, expect: expect, effects: &effects)
      else { return }
      run.selfInitiatedLine = line
      effects.append(.log("Step '\(step.id)': returned to the caller's own pane instead of being typed."))
      if expect != nil {
        run.phase = .injecting(ordinal: ordinal)
        effects.append(.openActivation(role: role, surfaceID: pane.surfaceID, ordinal: ordinal))
      } else {
        completeCurrentStep(effects: &effects)
        advance(effects: &effects)
      }
      return
    }
    run.phase = .waitingForRole(role: role, ordinal: ordinal)
    effects.append(.persist)
    effects.append(.log("Step '\(step.id)': waiting for role '\(role)' to be idle."))
    effects.append(.awaitRoleIdle(role: role, surfaceID: pane.surfaceID, ordinal: ordinal))
  }

  private mutating func injectCurrentMessage(ordinal: Int, effects: inout [WorkflowRunEffect]) {
    guard let step = run.currentStep, case .message(let role, let prompt, let expect) = step.action,
      let pane = run.bindings[role]?.pane
    else { return }
    guard
      let line = renderMessageLine(ordinal: ordinal, step: step, prompt: prompt, expect: expect, effects: &effects)
    else { return }
    run.phase = .injecting(ordinal: ordinal)
    effects.append(
      .inject(role: role, surfaceID: pane.surfaceID, ordinal: ordinal, line: line, opensActivation: expect != nil))
  }

  /// Renders the typed line (saving the prompt first) and opens the activation
  /// token; nil when rendering failed, in which case the run is already in attention or ended.
  private mutating func renderMessageLine(
    ordinal: Int,
    step: WorkflowStepDefinition,
    prompt: String,
    expect: WorkflowExpectation?,
    effects: inout [WorkflowRunEffect]
  ) -> String? {
    guard let invocation = invocation(ordinal) else { return nil }
    guard let rendered = render(prompt, step: step, effects: &effects) else { return nil }
    var completion: WorkflowCompletionCommand?
    if let expect, let deliveryName = step.deliveryName {
      // A `roleBusy` refusal returns the same invocation to its idle wait: the activation and its
      // token survive, so the command the run already rendered stays valid (dsl-spec §5).
      let activation: WorkflowActivation
      if let existing = invocation.activation, existing.state == .waiting {
        activation = existing
      } else {
        activation = WorkflowActivation(
          ordinal: ordinal, stepID: step.id, role: invocation.role, token: makeToken(), expect: expect,
          deliveryName: deliveryName, dispatchID: nil, state: .waiting)
        updateInvocation(ordinal: ordinal) { $0.activation = activation }
      }
      completion = activation.completion
    }
    let grant = taskContent(
      text: rendered, ordinal: ordinal, skill: nil)
    updateInvocation(ordinal: ordinal) { $0.content = grant }
    let url = WorkflowRunPaths.promptURL(runDirectory: run.runDirectory, stepID: step.id, ordinal: ordinal)
    updateInvocation(ordinal: ordinal) { $0.promptPath = WorkflowRunPaths.path(url) }
    effects.append(.materializePrompt(ordinal: ordinal, stepID: step.id, text: grant.text))
    do {
      return try WorkflowTypedLine.prompt(grant, completion: completion)
    } catch {
      run.phase = .injecting(ordinal: ordinal)
      updateActivation(ordinal: ordinal) { $0.state = .revoked }
      raiseAttention(.renderedTextInvalid, stepID: step.id, role: invocation.role, ordinal: ordinal, effects: &effects)
      return nil
    }
  }

  private mutating func enterLaunch(_ step: WorkflowStepDefinition, effects: inout [WorkflowRunEffect]) {
    guard case .launch(let role, let prompt, let skill, let expect) = step.action else { return }
    guard run.bindings[role]?.pane == nil else {
      raiseAttention(
        .launchFailed("Role '\(role)' was already launched. Use message for repeated work."),
        stepID: step.id, role: role, ordinal: nil, effects: &effects, allowedActions: [.cancel])
      return
    }
    let ordinal = mintOrdinal()
    run.invocations.append(
      WorkflowInvocation(
        ordinal: ordinal, stepID: step.id, iteration: run.currentIteration, role: role, kind: .launch, startedAt: now())
    )
    recordStep(step, state: .active, ordinal: ordinal)
    guard let rendered = render(prompt, step: step, effects: &effects) else { return }
    let plan = LaunchPlan(
      step: step, ordinal: ordinal, role: role, userPrompt: rendered, skill: skill, expect: expect, redelivery: false)
    launch(plan, effects: &effects)
  }

  private struct LaunchPlan {
    let step: WorkflowStepDefinition
    let ordinal: Int
    let role: String
    let userPrompt: String
    let skill: String?
    let expect: WorkflowExpectation?
    let redelivery: Bool
  }

  private mutating func launch(_ plan: LaunchPlan, effects: inout [WorkflowRunEffect]) {
    let (step, ordinal, role, userPrompt, skill, expect, redelivery) = (
      plan.step, plan.ordinal, plan.role, plan.userPrompt, plan.skill, plan.expect, plan.redelivery
    )
    guard let profile = run.bindings[role]?.profile, let requirements = run.definition.role(named: role)?.launch else {
      run.phase = .launching(ordinal: ordinal)
      raiseAttention(
        .launchFailed("role '\(role)' has no frozen profile"), stepID: step.id, role: role, ordinal: ordinal,
        effects: &effects)
      return
    }
    var environment = [
      WorkflowSchema.runEnvironmentKey: run.id.uuidString,
      WorkflowSchema.roleEnvironmentKey: role,
    ]
    var protocolBlock: String?
    if let expect, let deliveryName = step.deliveryName {
      let activation = WorkflowActivation(
        ordinal: ordinal, stepID: step.id, role: role, token: makeToken(), expect: expect,
        deliveryName: deliveryName, dispatchID: nil, state: .waiting)
      updateInvocation(ordinal: ordinal) { $0.activation = activation }
      environment[WorkflowSchema.tokenEnvironmentKey] = activation.token
      let title = step.title.flatMap { try? WorkflowExpression.renderText($0, values: run.stepValues) }
      protocolBlock = activation.completion.protocolBlock(
        runID: run.id.uuidString, workflowName: run.definition.name, role: role, stepTitle: title, expect: expect)
    }
    let grant = taskContent(text: userPrompt, ordinal: ordinal, skill: skill)
    let promptURL = WorkflowRunPaths.promptURL(runDirectory: run.runDirectory, stepID: step.id, ordinal: ordinal)
    updateInvocation(ordinal: ordinal) {
      $0.content = grant
      $0.promptPath = WorkflowRunPaths.path(promptURL)
    }
    effects.append(.materializePrompt(ordinal: ordinal, stepID: step.id, text: grant.text))
    let prompt = WorkflowLaunchPrompt.render(
      userPrompt: grant.text + "\n\n" + grant.guidance, protocolBlock: protocolBlock)
    do {
      try WorkflowLaunchPrompt.validate(prompt)
    } catch {
      run.phase = .launching(ordinal: ordinal)
      updateActivation(ordinal: ordinal) { $0.state = .revoked }
      let reason =
        switch error {
        case .containsNUL: "the rendered prompt contains NUL"
        case .tooLarge(let bytes): "the rendered prompt is \(bytes) bytes, above \(WorkflowLaunchPrompt.maximumBytes)"
        }
      raiseAttention(.launchFailed(reason), stepID: step.id, role: role, ordinal: ordinal, effects: &effects)
      return
    }
    if let skill {
      effects.append(.materializeSkill(id: skill))
    }
    let anchor = run.definition.roles.first { $0.source == .current }.flatMap { run.bindings[$0.name]?.pane?.surfaceID }
    run.phase = .launching(ordinal: ordinal)
    effects.append(.persist)
    effects.append(
      .log(
        "Step '\(step.id)': launching role '\(role)' with profile '\(profile.name)'\(redelivery ? " (relaunch)" : "").")
    )
    effects.append(
      .launch(
        WorkflowLaunchRequest(
          role: role, ordinal: ordinal, profile: profile, prompt: prompt, environment: environment,
          placement: requirements.placement, direction: requirements.direction, background: requirements.background,
          anchorSurfaceID: anchor, skill: skill, expectsDelivery: expect != nil, redelivery: redelivery)))
  }

  private func taskContent(text: String, ordinal: Int, skill: String?) -> WorkflowTaskContent {
    func paths(_ value: WorkflowJSONValue) -> [String] {
      switch value {
      case .string(let value): return [value]
      case .array(let values): return values.flatMap(paths)
      case .object(let values): return values.values.flatMap(paths)
      default: return []
      }
    }
    let known =
      run.deliveries.values.flatMap { [$0.path, $0.latestPath] }
      + run.actionOutputs.values.flatMap { $0.values.flatMap(paths) }
      + run.stepValues.values.flatMap(paths)
    return WorkflowTaskContent.make(
      text: text, task: (run.id, ordinal), runDirectory: run.runDirectory, knownPaths: known, skill: skill)
  }

  private mutating func enterAction(
    _ step: WorkflowStepDefinition, id: String, inputs: [String: WorkflowJSONValue], effects: inout [WorkflowRunEffect]
  ) {
    recordStep(step, state: .active, ordinal: nil)
    let executionID = makeToken()
    run.actionExecutionID = executionID
    run.stepRecords[run.stepRecords.count - 1].actionExecutionID = executionID
    run.actionAttempts[step.id, default: 0] += 1
    var values = run.stepValues
    let directory = run.runDirectory.appending(path: "actions/\(step.id)/\(executionID)")
    if case .object(var context) = values["context"] {
      context["action"] = .object([
        "execution_id": .string(executionID), "step_id": .string(step.id),
        "attempt": .integer(run.actionAttempts[step.id] ?? 1),
        "working_directory": .string(run.context.worktree.path),
        "artifacts_directory": .string(directory.appending(path: "artifacts").path),
      ])
      values["context"] = .object(context)
    }
    run.stepValues = values
    do {
      let resolved =
        try run.context.literalActionInputs
        ? inputs : inputs.mapValues { try WorkflowExpression.renderValue($0, values: values) }
      run.phase = .runningAction(stepID: step.id)
      effects.append(.persist)
      effects.append(.log("Step '\(step.id)': running action '\(id)' (\(executionID))."))
      effects.append(.runAction(stepID: step.id, actionID: id, inputs: resolved))
    } catch {
      raiseAttention(
        .actionFailed("Action input evaluation failed: \(error)"), stepID: step.id,
        role: nil, ordinal: nil, effects: &effects)
    }
  }

  private mutating func prepareControlStep(effects: inout [WorkflowRunEffect]) -> Bool {
    guard var cursor = run.controlCursor else { return true }
    do {
      let outcome = try cursor.next(values: run.expressionValues(capturedAt: now()))
      run.controlCursor = cursor
      recordControlEvaluations(cursor)
      switch outcome {
      case .step: return true
      case .finished: finish(.completed, effects: &effects)
      case .yielded: effects.append(.yieldControl)
      }
    } catch let limit as WorkflowLoopLimit {
      run.controlCursor = cursor
      recordControlEvaluations(cursor)
      effects.append(.log("Loop '\(limit.stepID)' reached max_iterations while its condition remained true."))
      finish(.iterationLimitReached, effects: &effects)
    } catch {
      run.controlCursor = cursor
      recordControlEvaluations(cursor)
      if let position = cursor.failedPosition {
        run.stepRecords.append(
          .init(
            stepID: position.stepID, iteration: position.iteration, state: .active,
            ordinal: nil, iterationPath: position.path, title: position.title))
      }
      raiseAttention(
        .actionFailed("Control evaluation failed: \(error)"), stepID: cursor.failedPosition?.stepID ?? "control",
        role: nil, ordinal: nil, effects: &effects, allowedActions: [.cancel])
    }
    return false
  }

  private mutating func recordControlEvaluations(_ cursor: WorkflowControlCursor) {
    for evaluation in cursor.evaluations {
      if run.stepRecords.count >= 10_000 {
        run.historyIsPartial = true
        continue
      }
      run.stepRecords.append(
        .init(
          stepID: evaluation.stepID, iteration: evaluation.iteration,
          state: evaluation.skipped ? .skipped : .completed, ordinal: nil,
          iterationPath: evaluation.path, branchExcluded: evaluation.skipped,
          title: evaluation.title, summary: evaluation.summary))
    }
    for name in cursor.expiredDeliveries { run.deliveries.removeValue(forKey: name) }
    for name in cursor.expiredActions { run.actionOutputs.removeValue(forKey: name) }
  }

  // MARK: Waiting and watchdog

  private mutating func openWaiting(ordinal: Int, dispatchID: String?, effects: inout [WorkflowRunEffect]) {
    guard let invocation = invocation(ordinal) else { return }
    guard let activation = invocation.activation else {
      completeCurrentStep(effects: &effects)
      effects.append(.log("Step '\(invocation.stepID)': delivered to role '\(invocation.role)'."))
      advance(effects: &effects)
      return
    }
    let deadline = activation.expect.timeoutSeconds.map { now().addingTimeInterval(TimeInterval($0)) }
    updateActivation(ordinal: ordinal) {
      $0.dispatchID = dispatchID
      if $0.deadline == nil { $0.deadline = deadline }
    }
    run.phase = .waitingForDelivery(ordinal: ordinal)
    effects.append(.persist)
    effects.append(
      .log(
        "Step '\(invocation.stepID)': waiting for delivery '\(activation.deliveryName)' from role '\(invocation.role)'."
      )
    )
    armWatchdog(ordinal: ordinal, nudgedAlready: false, effects: &effects)
  }

  private mutating func armWatchdog(ordinal: Int, nudgedAlready: Bool, effects: inout [WorkflowRunEffect]) {
    guard let invocation = invocation(ordinal), let activation = invocation.activation,
      let surfaceID = run.bindings[invocation.role]?.pane?.surfaceID
    else { return }
    // The hard cap is an absolute deadline: a re-armed watchdog gets what is left of it.
    let remaining = activation.deadline.map { max(1, Int($0.timeIntervalSince(now()).rounded(.up))) }
    if nudgedAlready {
      effects.append(.disarmWatchdog(ordinal: ordinal))
    }
    effects.append(
      .armWatchdog(
        WorkflowWatchdogRequest(
          ordinal: ordinal, stepID: invocation.stepID, role: invocation.role, surfaceID: surfaceID,
          dispatchID: activation.dispatchID, timeoutSeconds: remaining,
          timeoutPolicy: activation.expect.onTimeout ?? .attention, nudgedAlready: nudgedAlready)))
  }

  private mutating func applyWatchdog(
    ordinal: Int, verdict: WorkflowWatchdogVerdict, effects: inout [WorkflowRunEffect]
  ) {
    guard let activation = run.currentActivation, activation.ordinal == ordinal, activation.state == .waiting
    else { return }
    switch verdict {
    case .nudge:
      typeNudge(activation, effects: &effects)
      effects.append(.log("Step '\(activation.stepID)': nudged role '\(activation.role)'."))
    case .attention(let reason):
      let mapped: WorkflowAttentionReason =
        switch reason {
        case .needsInput: .needsInput
        case .idleWithoutDelivery: .idleWithoutDelivery
        case .blocked: .blocked
        case .agentGone(let gone): .agentGone(gone)
        }
      raiseAttention(mapped, stepID: activation.stepID, role: activation.role, ordinal: ordinal, effects: &effects)
    case .timeout:
      switch activation.expect.onTimeout ?? .attention {
      case .attention:
        raiseAttention(.timeout, stepID: activation.stepID, role: activation.role, ordinal: ordinal, effects: &effects)
      case .skip:
        effects.append(.log("Step '\(activation.stepID)': timeout; skipping as configured."))
        skipCurrentStep(effects: &effects)
      case .cancel:
        effects.append(.log("Step '\(activation.stepID)': timeout; cancelling as configured."))
        cancel(effects: &effects)
      }
    }
  }

  private mutating func typeNudge(_ activation: WorkflowActivation, effects: inout [WorkflowRunEffect]) {
    guard let surfaceID = run.bindings[activation.role]?.pane?.surfaceID,
      let line = try? WorkflowTypedLine.nudge(completion: activation.completion)
    else { return }
    effects.append(.typeLine(role: activation.role, surfaceID: surfaceID, line: line))
  }

  // MARK: User actions

  private mutating func applyUser(_ action: WorkflowUserAction, effects: inout [WorkflowRunEffect]) {
    let attention = run.status.attention
    switch action {
    case .cancel:
      cancel(effects: &effects)
    case .skip:
      guard attention == nil || attention?.actions.contains(.skip) == true else { return }
      guard run.currentInvocation != nil || attention != nil else { return }
      skipCurrentStep(effects: &effects)
    case .keepWaiting:
      keepWaiting(effects: &effects)
    case .nudge:
      nudgeAgain(effects: &effects)
    case .acceptDelivery(let verdict):
      acceptProvisionalDelivery(verdict: verdict, effects: &effects)
    case .askAgain:
      askAgain(effects: &effects)
    case .retry:
      guard let attention, attention.actions.contains(.retry) else { return }
      if case .persistFailed = attention.reason, let activation = run.activeActivation,
        let delivery = activation.pendingDelivery
      {
        run.status = .running
        effects.append(.log("Step '\(activation.stepID)': retrying to persist delivery '\(activation.deliveryName)'."))
        effects.append(deliveryPersistenceEffect(activation: activation, delivery: delivery))
        return
      }
      retryCurrentStep(effects: &effects)
    case .relaunch:
      guard let attention, attention.actions.contains(.relaunch) else { return }
      relaunchCurrentStep(effects: &effects)
    }
  }

  private mutating func keepWaiting(effects: inout [WorkflowRunEffect]) {
    guard let attention = run.status.attention, attention.actions.contains(.keepWaiting),
      let ordinal = attention.ordinal
    else { return }
    run.status = .running
    guard !enforceExpiredDeadline(effects: &effects) else { return }
    effects.append(.log("Step '\(attention.stepID)': keep waiting."))
    armWatchdog(ordinal: ordinal, nudgedAlready: true, effects: &effects)
    effects.append(.persist)
  }

  private mutating func nudgeAgain(effects: inout [WorkflowRunEffect]) {
    guard let attention = run.status.attention, attention.actions.contains(.nudge),
      let activation = run.currentActivation
    else { return }
    run.status = .running
    guard !enforceExpiredDeadline(effects: &effects) else { return }
    typeNudge(activation, effects: &effects)
    effects.append(.log("Step '\(attention.stepID)': nudged again by the user."))
    armWatchdog(ordinal: activation.ordinal, nudgedAlready: true, effects: &effects)
    effects.append(.persist)
  }

  /// "Accept as delivered" / "Accept with verdict": a declared verdict must be supplied when the
  /// delivery lacked one, otherwise the accepted delivery could not drive conditions or templates.
  private mutating func acceptProvisionalDelivery(verdict: String?, effects: inout [WorkflowRunEffect]) {
    guard let attention = run.status.attention, let activation = run.activeActivation,
      activation.state == .provisional, let delivery = activation.pendingDelivery
    else { return }
    let accepted: String?
    if let allowed = activation.expect.verdicts {
      // The delivery's own valid verdict wins; otherwise the user must pick a declared one.
      if let own = delivery.verdict {
        accepted = own
      } else {
        guard attention.actions.contains(.acceptWithVerdict), let verdict, allowed.contains(verdict) else { return }
        accepted = verdict
      }
    } else {
      guard attention.actions.contains(.acceptDelivery) else { return }
      accepted = nil
    }
    run.status = .running
    let note = accepted.map { " with verdict '\($0)'" } ?? ""
    effects.append(.log("Step '\(activation.stepID)': provisional delivery accepted by the user\(note)."))
    acceptDelivery(activation: activation, delivery: delivery, verdict: accepted, effects: &effects)
  }

  /// "Ask again": the same activation (and token) goes back to waiting, the requirements are
  /// typed into the role's pane, and the watchdog is re-armed with a fresh nudge.
  private mutating func askAgain(effects: inout [WorkflowRunEffect]) {
    guard let attention = run.status.attention, attention.actions.contains(.askAgain),
      let activation = run.activeActivation, activation.state == .provisional,
      let delivery = activation.pendingDelivery,
      let surfaceID = run.bindings[activation.role]?.pane?.surfaceID,
      let line = try? WorkflowTypedLine.askAgain(issues: delivery.issues, completion: activation.completion)
    else { return }
    updateActivation(ordinal: activation.ordinal) {
      $0.state = .waiting
      $0.pendingDelivery = nil
    }
    run.status = .running
    effects.append(.log("Step '\(activation.stepID)': asked role '\(activation.role)' to deliver again."))
    effects.append(.typeLine(role: activation.role, surfaceID: surfaceID, line: line))
    armWatchdog(ordinal: activation.ordinal, nudgedAlready: false, effects: &effects)
    effects.append(.persist)
  }

  /// A hard cap that already passed while the run sat in attention is applied now instead
  /// of being re-armed for another second; true when the timeout policy ran.
  private mutating func enforceExpiredDeadline(effects: inout [WorkflowRunEffect]) -> Bool {
    guard let activation = run.currentActivation, activation.state == .waiting, let deadline = activation.deadline,
      deadline <= now()
    else { return false }
    effects.append(.log("Step '\(activation.stepID)': the timeout already passed; applying its policy."))
    applyWatchdog(ordinal: activation.ordinal, verdict: .timeout, effects: &effects)
    return true
  }

  private mutating func cancel(effects: inout [WorkflowRunEffect]) {
    let stepID = run.currentStep?.id ?? "-"
    revokeCurrentActivation(
      reason: "Workflow run \(run.id.uuidString) cancelled at step '\(stepID)'.", effects: &effects)
    if let record = run.stepRecords.indices.last, run.stepRecords[record].state == .active {
      run.stepRecords[record].state = .failed
    }
    finish(.cancelled, effects: &effects)
  }

  private mutating func skipCurrentStep(effects: inout [WorkflowRunEffect]) {
    guard let step = run.currentStep else { return }
    revokeCurrentActivation(reason: "Workflow run \(run.id.uuidString): step '\(step.id)' skipped.", effects: &effects)
    updateActivation(ordinal: run.currentInvocation?.ordinal ?? -1) { $0.state = .skipped }
    if let index = run.stepRecords.indices.last, run.stepRecords[index].state == .active {
      run.stepRecords[index].state = .skipped
    }
    if let name = step.deliveryName {
      run.skippedDeliveries[name] = step.id
    }
    run.status = .running
    effects.append(.log("Step '\(step.id)': skipped."))
    switch skipConsequence(forStep: step.id) {
    case .endsRun(let dependent):
      finish(.skipped(step: step.id, dependent: dependent), effects: &effects)
    case .noDelivery, .continues:
      moveNext()
      advance(effects: &effects)
    }
  }

  private mutating func retryCurrentStep(effects: inout [WorkflowRunEffect]) {
    guard let step = run.currentStep else { return }
    run.status = .running
    if let index = run.stepRecords.indices.last, run.stepRecords[index].state == .active {
      run.stepRecords[index].state = .failed
    }
    revokeCurrentActivation(reason: "Workflow run \(run.id.uuidString): step '\(step.id)' retried.", effects: &effects)
    effects.append(.log("Step '\(step.id)': retry."))
    advance(effects: &effects)
  }

  private mutating func relaunchCurrentStep(effects: inout [WorkflowRunEffect]) {
    guard let step = run.currentStep, let role = step.action.targetRole,
      case .launch(let profile, _) = run.bindings[role]
    else { return }
    run.status = .running
    if let index = run.stepRecords.indices.last, run.stepRecords[index].state == .active {
      run.stepRecords[index].state = .failed
    }
    revokeCurrentActivation(
      reason: "Workflow run \(run.id.uuidString): role '\(role)' relaunched at step '\(step.id)'.", effects: &effects)
    if let previous = run.bindings[role]?.pane, !run.participants[role, default: []].contains(previous) {
      run.participants[role, default: []].append(previous)
    }
    run.bindings[role] = .launch(profile, pane: nil)
    switch step.action {
    case .launch:
      advance(effects: &effects)
    case .message(_, let prompt, let expect):
      let ordinal = mintOrdinal()
      run.invocations.append(
        WorkflowInvocation(
          ordinal: ordinal, stepID: step.id, iteration: run.currentIteration, role: role, kind: .launch,
          startedAt: now()))
      recordStep(step, state: .active, ordinal: ordinal)
      guard let rendered = render(prompt, step: step, effects: &effects) else { return }
      launch(
        LaunchPlan(
          step: step, ordinal: ordinal, role: role, userPrompt: rendered, skill: nil, expect: expect, redelivery: true),
        effects: &effects)
    default:
      return
    }
  }

  /// Revokes the current activation's token and abandons its dispatch record.
  private mutating func revokeCurrentActivation(reason: String, effects: inout [WorkflowRunEffect]) {
    if case .waitingForRole(_, let ordinal) = run.phase {
      effects.append(.cancelRoleWait(ordinal: ordinal))
    }
    guard let invocation = run.currentInvocation, let activation = invocation.activation else { return }
    let open = [.waiting, .persisting, .provisional].contains(activation.state)
    if open {
      updateActivation(ordinal: activation.ordinal) {
        $0.state = .revoked
        $0.pendingDelivery = nil
      }
    }
    let endedAt = now()
    updateInvocation(ordinal: activation.ordinal) { $0.endedAt = endedAt }
    if let dispatchID = activation.dispatchID, open {
      effects.append(.abandonActivation(dispatchID: dispatchID, reason: reason))
    }
    if case .waitingForDelivery = run.phase {
      effects.append(.disarmWatchdog(ordinal: activation.ordinal))
    }
  }

  // MARK: Attention and finishing

  private mutating func raiseAttention(
    _ reason: WorkflowAttentionReason, stepID: String, role: String?, ordinal: Int?, effects: inout [WorkflowRunEffect],
    allowedActions: [WorkflowAttentionAction]? = nil
  ) {
    let isLaunchRole = role.flatMap { run.bindings[$0]?.source } == .launch
    let actions: [WorkflowAttentionAction] =
      switch reason {
      case .needsInput, .blocked: [.focusPane, .cancel]
      case .idleWithoutDelivery, .timeout: [.nudge, .keepWaiting, .skip, .cancel]
      case .agentGone: isLaunchRole ? [.relaunch, .skip, .cancel] : [.skip, .cancel]
      case .injectionFailed(.surfaceMissing):
        isLaunchRole ? [.relaunch, .retry, .skip, .cancel] : [.retry, .skip, .cancel]
      case .injectionFailed(.roleBlocked), .injectionFailed(.submitFailed): [.focusPane, .retry, .skip, .cancel]
      case .injectionFailed: [.retry, .skip, .cancel]
      case .launchFailed: [.retry, .skip, .cancel]
      case .renderedTextInvalid: [.skip, .cancel]
      case .actionFailed, .persistFailed: [.retry, .cancel]
      case .deliveryIssues(let issues):
        (issues.contains(where: Self.needsVerdict) ? [.acceptWithVerdict] : [.acceptDelivery]) + [
          .askAgain, .skip, .cancel,
        ]
      }
    let attention = WorkflowAttention(
      reason: reason, stepID: stepID, role: role, ordinal: ordinal, actions: allowedActions ?? actions,
      message: attentionMessage(reason, stepID: stepID, role: role))
    if let index = run.stepRecords.lastIndex(where: { $0.stepID == stepID }) {
      run.stepRecords[index].error = attention.message
    }
    run.status = .needsAttention(attention)
    effects.append(.log("Step '\(stepID)': needs attention — \(attention.message)"))
    effects.append(.persist)
  }

  // One case per attention reason: the copy table is deliberately exhaustive (decision H7).
  // swiftlint:disable:next cyclomatic_complexity
  private func attentionMessage(_ reason: WorkflowAttentionReason, stepID: String, role: String?) -> String {
    let subject: String
    if let role, let binding = run.bindings[role] {
      subject = "\(role) (\(binding.displayName))"
    } else {
      subject = role ?? "the step"
    }
    let deliveryName = run.currentActivation?.deliveryName ?? "its delivery"
    switch reason {
    case .needsInput:
      return "\(subject) is waiting for input in its pane."
    case .idleWithoutDelivery:
      return "\(subject) has been idle without delivering \(deliveryName); Prowl nudged it once."
    case .blocked:
      return "\(subject) looks blocked on screen."
    case .agentGone(.sessionEnded):
      return "\(subject)'s agent session ended before it delivered \(deliveryName)."
    case .agentGone(.paneClosed):
      return "\(subject)'s pane was closed before it delivered \(deliveryName)."
    case .agentGone(.processGone):
      return "\(subject)'s agent process is gone."
    case .agentGone(.notLaunched):
      return "\(subject) has no pane: its launch was skipped or did not succeed."
    case .injectionFailed(.roleBusy):
      return "\(subject) is busy."
    case .injectionFailed(.roleBlocked):
      return "The line could not be typed: \(subject) is blocked."
    case .injectionFailed(.surfaceMissing):
      return "The line could not be typed: \(subject)'s pane is gone."
    case .injectionFailed(.insertFailed):
      return "The line could not be typed into \(subject)'s pane."
    case .injectionFailed(.submitFailed):
      return "The line was inserted but not submitted; it may still sit unsubmitted in \(subject)'s input. "
        + "Focus the pane and press Enter, or retry."
    case .injectionFailed(.activationUnavailable(let detail)):
      return "The activation for \(subject) could not be opened: \(detail)"
    case .launchFailed(let detail):
      return "Launching \(subject) failed: \(detail)"
    case .renderedTextInvalid:
      return "The rendered line of step '\(stepID)' is not a single terminal line; nothing was typed."
    case .actionFailed(let detail):
      return "Step '\(stepID)' failed: \(detail)"
    case .persistFailed(let detail):
      return "The delivery from step '\(stepID)' could not be saved to the run directory: \(detail)"
    case .deliveryIssues(let issues):
      return "\(subject) delivered \(deliveryName), but: \(issues.map(\.message).joined(separator: "; "))."
        + " Accept it, ask again, or skip."
    case .timeout:
      return "Step '\(stepID)' reached its timeout without a delivery from \(subject)."
    }
  }

  /// A provisional delivery without a usable verdict can only be accepted together with one.
  private static func needsVerdict(_ issue: WorkflowDeliveryIssue) -> Bool {
    switch issue {
    case .verdictMissing, .verdictUndeclared: true
    case .missingSections, .unparsableJSON, .verdictUnexpected: false
    }
  }

  private mutating func finish(_ status: WorkflowRunStatus, effects: inout [WorkflowRunEffect]) {
    run.status = status
    run.phase = .idle
    run.finishedAt = now()
    run.updatedAt = run.finishedAt ?? run.updatedAt
    effects.append(.log("Run finished: \(Self.describe(status))."))
    effects.append(.persist)
    effects.append(.finished(status))
  }

  static func describe(_ status: WorkflowRunStatus) -> String {
    switch status {
    case .running: "running"
    case .needsAttention(let attention): "needs attention (\(attention.message))"
    case .completed: "completed"
    case .cancelled: "cancelled"
    case .skipped(let step, let dependent):
      "skipped (step '\(step)' was skipped but '\(dependent)' depends on its delivery)"
    case .iterationLimitReached: "iteration limit reached"
    case .interrupted: "interrupted"
    }
  }

  // MARK: Helpers

  private mutating func completeCurrentStep(effects: inout [WorkflowRunEffect]) {
    if let ordinal = run.currentInvocation?.ordinal {
      let endedAt = now()
      updateInvocation(ordinal: ordinal) { $0.endedAt = endedAt }
    }
    if let index = run.stepRecords.indices.last, run.stepRecords[index].state == .active {
      run.stepRecords[index].state = .completed
    }
    run.phase = .idle
    run.updatedAt = now()
    moveNext()
    _ = effects
  }

  private mutating func recordStep(_ step: WorkflowStepDefinition, state: WorkflowStepState, ordinal: Int?) {
    if let ordinal, let role = step.action.targetRole, let binding = run.bindings[role] {
      updateInvocation(ordinal: ordinal) {
        $0.target = .init(source: binding.source, profile: binding.profile, pane: binding.pane)
      }
    }
    run.stepRecords.append(
      WorkflowStepRecord(
        stepID: step.id, iteration: run.currentIteration, state: state, ordinal: ordinal,
        iterationPath: run.controlCursor?.iterationPath,
        title: step.title.flatMap { try? WorkflowExpression.renderText($0, values: run.stepValues) }
          ?? step.historyTitle))
    run.updatedAt = now()
  }

  private mutating func mintOrdinal() -> Int {
    defer { run.nextOrdinal += 1 }
    return run.nextOrdinal
  }

  private func invocation(_ ordinal: Int) -> WorkflowInvocation? {
    run.invocations.first { $0.ordinal == ordinal }
  }

  private mutating func updateInvocation(ordinal: Int, _ change: (inout WorkflowInvocation) -> Void) {
    guard let index = run.invocations.firstIndex(where: { $0.ordinal == ordinal }) else { return }
    change(&run.invocations[index])
  }

  private mutating func updateActivation(ordinal: Int, _ change: (inout WorkflowActivation) -> Void) {
    updateInvocation(ordinal: ordinal) { invocation in
      guard var activation = invocation.activation else { return }
      change(&activation)
      invocation.activation = activation
    }
  }

  /// Rendering failures enter attention; skip dependency checks run before advancing.
  private mutating func render(_ text: String, step: WorkflowStepDefinition, effects: inout [WorkflowRunEffect])
    -> String?
  {
    do {
      return try WorkflowExpression.renderText(text, values: run.stepValues)

    } catch {
      let ordinal = run.currentInvocation?.ordinal
      raiseAttention(
        .actionFailed("template cannot be rendered: \(error)"), stepID: step.id, role: step.action.targetRole,
        ordinal: ordinal, effects: &effects)
    }
    return nil
  }

}
