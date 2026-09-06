import Foundation
import ProwlCLIShared

private let dispatchLogger = SupaLogger("AgentDispatchCommandHandler")

/// `prowl agents dispatch <pane> --prompt -`: creates a pending dispatch for an agent that
/// already runs in the pane and types the prompt plus the completion protocol into it
/// (docs-ai 064.014). The precondition reuses the `agents wait --until idle` evidence rules:
/// a corroborated exact `turn-ended` resolves immediately, a detector-only idle view must
/// stay unchanged for two seconds, and a working or blocked agent is refused rather than
/// having text merged into its running turn.
@MainActor
final class AgentDispatchCommandHandler: CommandHandler {
  typealias ResolveTarget = @MainActor (String) -> Result<TabResolvedTarget, TargetResolverError>
  typealias PendingDispatch = @MainActor (TabResolvedTarget) -> AgentDispatchSnapshot?
  typealias ConditionSnapshotProvider = @MainActor (TabResolvedTarget) -> AgentConditionSnapshot
  typealias IssueDispatch = @MainActor (TabResolvedTarget) -> Result<AgentDispatchSnapshot, AgentDispatchStoreError>
  typealias DeliverPrompt = @MainActor (TabResolvedTarget, String) -> Bool
  typealias CancelDispatch = @MainActor (String) -> Void

  /// How long the precondition lets the evidence settle before refusing: a runtime
  /// `turn-ended` the detector has not corroborated yet, or a detector-only idle view that still
  /// needs its two seconds of stability. A pane the evidence already calls working or blocked is
  /// refused at once.
  nonisolated static let idleGraceMilliseconds = 5_000

  private enum IdleVerdict {
    case idle
    case busy(AgentWaitObservation)
    /// Idle by one source only; keep polling within the grace budget.
    case settling(String)
  }

  private let resolveTarget: ResolveTarget
  private let pendingDispatch: PendingDispatch
  private let conditionSnapshot: ConditionSnapshotProvider
  private let issueDispatch: IssueDispatch
  private let deliverPrompt: DeliverPrompt
  private let cancelDispatch: CancelDispatch
  private let clock: any Clock<Duration>
  private let now: @MainActor () -> Date
  private let formatter: ISO8601DateFormatter

  init(
    resolveTarget: @escaping ResolveTarget,
    pendingDispatch: @escaping PendingDispatch = { _ in nil },
    conditionSnapshot: @escaping ConditionSnapshotProvider = { _ in
      AgentConditionSnapshot(agent: nil, signal: nil, revision: 0, isLive: false, signals: .empty)
    },
    issueDispatch: @escaping IssueDispatch = { _ in .failure(.bindingMissing) },
    deliverPrompt: @escaping DeliverPrompt = { _, _ in false },
    cancelDispatch: @escaping CancelDispatch = { _ in },
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.resolveTarget = resolveTarget
    self.pendingDispatch = pendingDispatch
    self.conditionSnapshot = conditionSnapshot
    self.issueDispatch = issueDispatch
    self.deliverPrompt = deliverPrompt
    self.cancelDispatch = cancelDispatch
    self.clock = clock
    self.now = now
    self.formatter = AgentDispatchCompleteCommandHandler.makeFormatter()
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .agentsDispatch(let input) = envelope.command else {
      return failure(code: CLIErrorCode.invalidArgument, message: "Expected an agents.dispatch command.")
    }
    if let message = input.validationErrorMessage {
      return failure(code: CLIErrorCode.invalidArgument, message: message)
    }
    let target: TabResolvedTarget
    switch resolveTarget(input.pane) {
    case .failure(.notFound(let message)):
      return failure(code: CLIErrorCode.targetNotFound, message: message)
    case .failure(.notUnique(let message)):
      return failure(code: CLIErrorCode.targetNotUnique, message: message)
    case .success(let resolved):
      target = resolved
    }
    if let pending = pendingDispatch(target) {
      return pendingFailure(pending, target: target)
    }
    if let refusal = await awaitIdleAgent(target: target) {
      return refusal
    }

    let issued: AgentDispatchSnapshot
    switch issueDispatch(target) {
    case .success(let snapshot):
      issued = snapshot
    case .failure(.capacityExceeded):
      return failure(
        code: CLIErrorCode.dispatchCapacityExceeded,
        message: "All dispatch receipt slots are occupied by pending work; "
          + "complete or abandon a dispatch before dispatching another task."
      )
    case .failure(.surfacePending):
      if let pending = pendingDispatch(target) {
        return pendingFailure(pending, target: target)
      }
      return failure(code: CLIErrorCode.dispatchPending, message: "The pane already holds a pending dispatch.")
    case .failure:
      return failure(
        code: CLIErrorCode.dispatchFailed,
        message: "The dispatch could not be bound to the pane's current agent."
      )
    }
    guard deliverPrompt(target, AgentDispatchPrompt.renderInjected(userPrompt: input.prompt)) else {
      cancelDispatch(issued.record.id)
      return failure(code: CLIErrorCode.dispatchFailed, message: "The prompt could not be delivered to the pane.")
    }
    guard case .pending(let record) = issued.payload(using: formatter) else {
      return failure(code: CLIErrorCode.dispatchFailed, message: "The dispatch record is not pending.")
    }
    do {
      return try CommandResponse(
        ok: true,
        command: "agents.dispatch",
        schemaVersion: "prowl.cli.agents.dispatch.v1",
        data: RawJSON(encoding: AgentDispatchCommandPayload(target: TabTarget(from: target), dispatch: record))
      )
    } catch {
      return failure(code: CLIErrorCode.dispatchFailed, message: "Failed to encode the dispatch record.")
    }
  }

  /// Nil when the pane hosts an idle agent; otherwise the structured refusal.
  private func awaitIdleAgent(target: TabResolvedTarget) async -> CommandResponse? {
    var elapsedMilliseconds = 0
    var stabilizer = AgentConditionEvidence.HeuristicStabilizer()
    while true {
      if Task.isCancelled {
        return failure(code: CLIErrorCode.timeout, message: "The dispatch was cancelled.")
      }
      let snapshot = conditionSnapshot(target)
      guard snapshot.isLive else {
        return failure(
          code: CLIErrorCode.agentGone,
          message: "The selected agent pane is gone.",
          details: AgentDispatchErrorDetails(target: TabTarget(from: target), signals: snapshot.signals)
        )
      }
      guard snapshot.agent != nil else {
        return failure(
          code: CLIErrorCode.agentNotFound,
          message: "The selected pane hosts no detected agent; dispatch needs an idle agent to deliver to.",
          details: AgentDispatchErrorDetails(target: TabTarget(from: target), signals: snapshot.signals)
        )
      }
      switch verdict(for: snapshot) {
      case .idle:
        return nil
      case .busy(let observation):
        return busyFailure(observation, snapshot: snapshot, target: target)
      case .settling(let state):
        let detectorCandidate =
          AgentConditionEvidence.detectorReports(.idle, normalizedState: state)
          && AgentConditionEvidence.allowsHeuristic(.auto, condition: .idle, snapshot: snapshot)
        if stabilizer.observe(candidate: detectorCandidate ? state : nil, elapsedMilliseconds: elapsedMilliseconds) {
          return nil
        }
        guard elapsedMilliseconds < Self.idleGraceMilliseconds else {
          return busyFailure(heuristicObservation(snapshot, state: state), snapshot: snapshot, target: target)
        }
      }
      do {
        try await clock.sleep(for: .milliseconds(200))
      } catch {
        return failure(code: CLIErrorCode.timeout, message: "The dispatch was cancelled.")
      }
      elapsedMilliseconds += 200
    }
  }

  /// The shared arm-time evaluation (`AgentConditionEvidence.idleVerdict`): either source alone
  /// is not a refusal yet — the wait itself would keep polling — so it settles within the grace
  /// budget; working or blocked without such evidence is refused.
  private func verdict(for snapshot: AgentConditionSnapshot) -> IdleVerdict {
    switch AgentConditionEvidence.idleVerdict(for: snapshot) {
    case .idle: .idle
    case .settling(let state): .settling(state)
    case .busy(let state): .busy(heuristicObservation(snapshot, state: state))
    }
  }

  private func heuristicObservation(_ snapshot: AgentConditionSnapshot, state: String) -> AgentWaitObservation {
    AgentWaitObservation(
      status: AgentConditionEvidence.status(for: snapshot.agent, fallback: .idle),
      rawState: snapshot.agent?.rawState.rawValue ?? state,
      source: "detection",
      confidence: "heuristic",
      timestamp: formatter.string(from: snapshot.agent?.lastChangedAt ?? now()),
      revision: Int(clamping: snapshot.revision)
    )
  }

  private func busyFailure(
    _ observation: AgentWaitObservation,
    snapshot: AgentConditionSnapshot,
    target: TabResolvedTarget
  ) -> CommandResponse {
    let reason: String =
      if let signal = snapshot.signal, signal.event == .needsInput {
        "its runtime reported needs-input"
      } else {
        "the detector reports \(observation.status.rawValue)"
      }
    return failure(
      code: CLIErrorCode.dispatchTargetBusy,
      message: "The pane's agent is not idle (\(reason)); wait for it to finish before dispatching.",
      details: AgentDispatchErrorDetails(
        target: TabTarget(from: target),
        observation: observation,
        signals: snapshot.signals
      )
    )
  }

  private func pendingFailure(_ pending: AgentDispatchSnapshot, target: TabResolvedTarget) -> CommandResponse {
    failure(
      code: CLIErrorCode.dispatchPending,
      message: "The pane already holds pending dispatch \(pending.record.id); "
        + "wait for its receipt or abandon it before dispatching again.",
      details: AgentDispatchErrorDetails(
        target: TabTarget(from: target),
        record: pending.payload(using: formatter)
      )
    )
  }

  private func failure(
    code: String,
    message: String,
    details: AgentDispatchErrorDetails? = nil
  ) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "agents.dispatch",
      schemaVersion: "prowl.cli.agents.dispatch.v1",
      error: CommandError(code: code, message: message, details: details.flatMap { try? RawJSON(encoding: $0) })
    )
  }
}

@MainActor
final class AgentDispatchCompleteCommandHandler: CommandHandler {
  typealias ResolveCaller = @MainActor (pid_t) -> CallerPane?
  /// Completes the caller pane's current pending dispatch; the pane, not a public id, is the
  /// record's address.
  typealias Complete =
    @MainActor (
      UUID, DispatchCompletionOutcome, String
    ) -> Result<AgentDispatchMutationResult, AgentDispatchStoreError>
  /// A refusal for a caller pane whose pending record belongs to someone else — a workflow
  /// activation answers `WORKFLOW_DELIVERY_REQUIRED` here (docs-ai 063 B3, decision W3) so the
  /// store never completes it through this path.
  typealias Intercept = @MainActor (UUID) -> CommandError?

  private let resolveCaller: ResolveCaller
  private let complete: Complete
  private let intercept: Intercept
  private let formatter: ISO8601DateFormatter

  init(
    resolveCaller: @escaping ResolveCaller,
    complete: @escaping Complete,
    intercept: @escaping Intercept = { _ in nil },
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.resolveCaller = resolveCaller
    self.complete = complete
    self.intercept = intercept
    self.formatter = Self.makeFormatter()
    _ = now
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    await handle(envelope: envelope, context: CLICommandContext())
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope, context: CLICommandContext) async -> CommandResponse {
    guard case .agentsDispatchComplete(let input) = envelope.command else {
      return failure(code: CLIErrorCode.invalidArgument, message: "Expected an agents.dispatch-complete command.")
    }
    if let message = input.validationErrorMessage {
      return failure(code: CLIErrorCode.invalidArgument, message: message)
    }
    guard let processID = context.callerProcessID, let caller = resolveCaller(processID) else {
      return failure(
        code: CLIErrorCode.dispatchContextRequired,
        message: "Run dispatch completion from the Prowl pane that owns this dispatch."
      )
    }
    if let refusal = intercept(caller.surfaceID) {
      return CommandResponse(
        ok: false,
        command: "agents.dispatch-complete",
        schemaVersion: "prowl.cli.agents.dispatch-complete.v1",
        error: refusal
      )
    }
    switch complete(caller.surfaceID, input.outcome, input.summary) {
    case .failure(let error):
      return map(error)
    case .success(let result):
      if let launchDispatchID = input.dispatchID, launchDispatchID != result.snapshot.record.id {
        dispatchLogger.info(
          "Completed dispatch \(result.snapshot.record.id) for pane \(caller.surfaceID) "
            + "from a process launched with PROWL_DISPATCH_ID=\(launchDispatchID)"
        )
      }
      guard let binding = result.snapshot.binding,
        case .completed(let receipt) = result.snapshot.payload(using: formatter)
      else {
        return failure(code: CLIErrorCode.dispatchFailed, message: "The dispatch receipt is incomplete.")
      }
      do {
        return try CommandResponse(
          ok: true,
          command: "agents.dispatch-complete",
          schemaVersion: "prowl.cli.agents.dispatch-complete.v1",
          data: RawJSON(
            encoding: DispatchCompleteCommandPayload(
              target: binding.target,
              receipt: receipt,
              replayed: result.replayed
            ))
        )
      } catch {
        return failure(code: CLIErrorCode.dispatchFailed, message: "Failed to encode the dispatch receipt.")
      }
    }
  }

  private func map(_ error: AgentDispatchStoreError) -> CommandResponse {
    switch error {
    case .notFound:
      failure(code: CLIErrorCode.dispatchNotFound, message: "This pane has no dispatch to complete.")
    case .sourceMismatch:
      failure(code: CLIErrorCode.dispatchSourceMismatch, message: "This pane does not own the dispatch receipt.")
    case .alreadyCompleted:
      failure(code: CLIErrorCode.dispatchAlreadyCompleted, message: "The dispatch was already completed differently.")
    case .alreadyTerminal:
      failure(code: CLIErrorCode.dispatchAlreadyTerminal, message: "The dispatch is already terminal.")
    case .bindingMissing:
      failure(code: CLIErrorCode.dispatchFailed, message: "The dispatch has no bound pane.")
    case .capacityExceeded, .alreadyBound, .surfacePending:
      failure(code: CLIErrorCode.dispatchFailed, message: "The dispatch receipt could not be updated.")
    }
  }

  private func failure(code: String, message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "agents.dispatch-complete",
      schemaVersion: "prowl.cli.agents.dispatch-complete.v1",
      error: CommandError(code: code, message: message)
    )
  }

  static func makeFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }
}

@MainActor
final class AgentDispatchAbandonCommandHandler: CommandHandler {
  typealias Abandon =
    @MainActor (
      String, String
    ) -> Result<AgentDispatchMutationResult, AgentDispatchStoreError>

  private let abandon: Abandon
  private let formatter: ISO8601DateFormatter

  init(
    abandon: @escaping Abandon,
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.abandon = abandon
    self.formatter = AgentDispatchCompleteCommandHandler.makeFormatter()
    _ = now
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .agentsDispatchAbandon(let input) = envelope.command else {
      return failure(code: CLIErrorCode.invalidArgument, message: "Expected an agents.dispatch-abandon command.")
    }
    if let message = input.validationErrorMessage {
      return failure(code: CLIErrorCode.invalidArgument, message: message)
    }
    switch abandon(input.dispatchID, input.reason) {
    case .failure(.notFound):
      return failure(code: CLIErrorCode.dispatchNotFound, message: "The dispatch receipt was not found.")
    case .failure(.alreadyTerminal), .failure(.alreadyCompleted):
      return failure(code: CLIErrorCode.dispatchAlreadyTerminal, message: "The dispatch is already terminal.")
    case .failure:
      return failure(code: CLIErrorCode.dispatchFailed, message: "The dispatch receipt could not be abandoned.")
    case .success(let result):
      guard let binding = result.snapshot.binding,
        case .abandoned(let record) = result.snapshot.payload(using: formatter)
      else {
        return failure(code: CLIErrorCode.dispatchFailed, message: "The dispatch has no bound pane.")
      }
      do {
        return try CommandResponse(
          ok: true,
          command: "agents.dispatch-abandon",
          schemaVersion: "prowl.cli.agents.dispatch-abandon.v1",
          data: RawJSON(
            encoding: DispatchAbandonCommandPayload(
              target: binding.target,
              record: record,
              replayed: result.replayed
            ))
        )
      } catch {
        return failure(code: CLIErrorCode.dispatchFailed, message: "Failed to encode the abandoned dispatch.")
      }
    }
  }

  private func failure(code: String, message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "agents.dispatch-abandon",
      schemaVersion: "prowl.cli.agents.dispatch-abandon.v1",
      error: CommandError(code: code, message: message)
    )
  }
}
