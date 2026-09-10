// supacode/Features/Workflow/Reducer/WorkflowRunsFeature.swift
// The reducer that owns every live workflow run (docs-ai 063 B3, decision H2/W1). The pure
// `WorkflowRunMachine` is reconstructed per transition; this reducer performs its effects against
// the terminal, dispatch, launch, store, native-action, and watchdog boundaries, answers the CLI
// `deliver` rendezvous when an activation leaves `persisting`, and cleans up what arrives late.

import ComposableArchitecture
import Foundation
import ProwlCLIShared

/// The in-memory part of a run that `run.json` deliberately excludes: the worktree object, the
/// frozen profile launch plans (their surface environment carries override values), the binding
/// memory keys, and the bundled skill locations.
nonisolated struct WorkflowRunSession: Equatable, Sendable {
  var run: WorkflowRun
  let worktree: Worktree
  let launchPlans: [String: AgentProfileLaunchPlan]
  /// Per `launch` role, the binding-memory key its profile is remembered under once launched.
  let bindingMemoryKeys: [String: WorkflowBindingMemoryKey]
  let skills: [String: BundledSkill]
  let limits: WorkflowDeliveryLimits

  init(
    run: WorkflowRun,
    worktree: Worktree,
    launchPlans: [String: AgentProfileLaunchPlan],
    bindingMemoryKeys: [String: WorkflowBindingMemoryKey] = [:],
    skills: [String: BundledSkill] = [:],
    limits: WorkflowDeliveryLimits = WorkflowDeliveryLimits()
  ) {
    self.run = run
    self.worktree = worktree
    self.launchPlans = launchPlans
    self.bindingMemoryKeys = bindingMemoryKeys
    self.skills = skills
    self.limits = limits
  }

  var store: WorkflowRunStore { WorkflowRunStore(rootURL: run.context.worktree.rootURL, directory: run.runDirectory) }

  /// Every pane the run currently occupies (dsl-spec §10: one run per pane).
  var boundSurfaceIDs: Set<UUID> {
    Set(run.bindings.values.compactMap { $0.pane?.surfaceID })
  }

  func machine(now: @escaping @Sendable () -> Date, makeToken: @escaping @Sendable () -> String)
    -> WorkflowRunMachine
  {
    WorkflowRunMachine(run: run, limits: limits, now: now, makeToken: makeToken)
  }
}

/// A CLI `deliver` accepted by the machine and waiting for its output to reach the run directory.
nonisolated struct WorkflowPendingDelivery: Equatable, Sendable {
  let runID: UUID
  let ordinal: Int
  let receipt: WorkflowDeliveryReceipt
}

/// `prowl workflow deliver` after the handler attributed it (decision W3).
nonisolated struct WorkflowDeliveryRequest: Equatable, Sendable {
  let requestID: UUID
  let runID: UUID
  /// The activation the caller pane's pending dispatch resolved to; nil for a manual delivery.
  let ordinal: Int?
  let selector: WorkflowDeliverySelector
  let body: String
  let verdict: String?
  /// `pane` or `manual` (`manual --force` when the caller pane disagreed), for the run log.
  let source: String
}

@Reducer
struct WorkflowRunsFeature {
  @ObservableState
  struct State: Equatable {
    /// Every run started in this app instance, terminal ones included (`status` reads them).
    var sessions: [UUID: WorkflowRunSession] = [:]
    var pendingDeliveries: [UUID: WorkflowPendingDelivery] = [:]
    /// Self-initiated `run` requests waiting for their first activation to open (request → run).
    var pendingStarts: [UUID: UUID] = [:]
    /// Worktree roots whose leftover runs were marked `interrupted` at load (dsl-spec §10 Restart).
    var scannedWorktreeRoots: Set<String> = []
    /// The run that bound each pane most recently, whatever that run's status — recorded when a
    /// run is admitted (`current` / `pick` bind then) and when a launch is taken up, never from
    /// a clock. A pane a later run took over is not an earlier run's to close, even after the
    /// later run ended and kept it.
    var paneOwners: [UUID: UUID] = [:]

    var activeSessions: [WorkflowRunSession] {
      sessions.values.filter { !$0.run.status.isTerminal }
    }

    /// The active run a pane belongs to, if any.
    func activeSession(boundTo surfaceID: UUID) -> WorkflowRunSession? {
      activeSessions.first { $0.boundSurfaceIDs.contains(surfaceID) }
    }
  }

  enum Action: Equatable {
    /// Admission succeeded (preflight, layout, initial record): own the run and perform its effects.
    /// A self-initiated run passes the CLI request to answer once its first activation is open.
    case started(WorkflowRunSession, effects: [WorkflowRunEffect], requestID: UUID? = nil)
    case event(runID: UUID, WorkflowRunEvent)
    case executeAction(
      runID: UUID, stepID: String, actionID: String, inputs: [String: WorkflowJSONValue], executionID: String)
    case deliver(WorkflowDeliveryRequest)
    case userAction(runID: UUID, WorkflowUserAction)
    case markInterruptedRuns(worktreeRoots: [String])
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case notice(WorkflowRunNotice)
  }

  @Dependency(TerminalClient.self) var terminal
  @Dependency(WorkflowHistoryStorageKey.self) var historyStorage
  @Dependency(WorkflowRuntimeClient.self) var runtime
  @Dependency(WorkflowActivationClient.self) var activation
  @Dependency(WorkflowWatchdogClient.self) var watchdog
  @Dependency(WorkflowEffectQueueClient.self) var queue
  @Dependency(WorkflowCLIResponderClient.self) var responder
  @Dependency(WorkflowActionExecutorKey.self) var actionExecutor
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid

  nonisolated private static let logger = SupaLogger("WorkflowRuns")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .started(let session, let effects, let requestID):
        let runID = session.run.id
        state.sessions[runID] = session
        for surfaceID in session.boundSurfaceIDs {
          state.paneOwners[surfaceID] = runID
        }
        if let requestID {
          state.pendingStarts[requestID] = runID
        }
        // The queue exists before the first batch is enqueued below; the executor drains it.
        let batches = queue.start(runID)
        return .merge(
          executor(runID: runID, batches: batches),
          perform(effects, runID: runID, session: session),
          resolvePendingStarts(&state, runID: runID, session: session),
          statusNotice(from: nil, to: session.run, effects: effects)
        )

      case .executeAction(let runID, let stepID, let actionID, let inputs, let executionID):
        guard let session = state.sessions[runID], !session.run.status.isTerminal,
          session.run.actionExecutionID == executionID
        else { return .none }
        return executeAction(
          session: session, stepID: stepID, actionID: actionID, inputs: inputs, executionID: executionID)

      case .event(let runID, let event):
        guard var session = state.sessions[runID], !session.run.status.isTerminal else {
          return archiveOrCleanLateEvent(event, runID: runID, state: &state)
        }
        let timestamp = now
        let generator = uuid
        session.run.observations = runtime.observe(session.run)
        session.run.captureParticipantSessions()
        var machine = session.machine(now: { timestamp }, makeToken: { generator().uuidString })
        let effects = machine.apply(event)
        let previous = session.run
        session.run = machine.run
        state.sessions[runID] = session
        if case .launched = event {
          rememberLaunchedBindings(previous: previous, current: session)
          let previouslyBound = Set(previous.bindings.values.compactMap { $0.pane?.surfaceID })
          for surfaceID in session.boundSurfaceIDs.subtracting(previouslyBound) {
            state.paneOwners[surfaceID] = runID
          }
        }
        fenceIfStale(runID: runID, previous: previous, current: session.run)
        return .merge(
          resolvePendingDeliveries(&state, runID: runID, session: session),
          resolvePendingStarts(&state, runID: runID, session: session),
          perform(effects, runID: runID, session: session),
          staleEventCleanup(event, session: session),
          statusNotice(from: previous.status, to: session.run, effects: effects)
        )

      case .deliver(let request):
        guard var session = state.sessions[request.runID], !session.run.status.isTerminal else {
          return respond(
            request.requestID,
            .failed(code: CLIErrorCode.runNotFound, message: "The workflow run is not active."))
        }
        let timestamp = now
        let generator = uuid
        session.run.observations = runtime.observe(session.run)
        session.run.captureParticipantSessions()
        var machine = session.machine(now: { timestamp }, makeToken: { generator().uuidString })
        let (result, effects) = machine.deliver(
          ordinal: request.ordinal, selector: request.selector, body: request.body,
          verdict: request.verdict)
        switch result {
        case .failure(let error):
          return respond(request.requestID, .failed(code: error.code, message: error.message))
        case .success(let receipt):
          session.run = machine.run
          state.sessions[request.runID] = session
          state.pendingDeliveries[request.requestID] = WorkflowPendingDelivery(
            runID: request.runID, ordinal: receipt.ordinal, receipt: receipt)
          var ordered = effects
          if request.source != "pane" {
            ordered.insert(
              .log("Step '\(receipt.stepID)': delivery received (source=\(request.source))."), at: 0
            )
          }
          return perform(ordered, runID: request.runID, session: session)
        }

      case .userAction(let runID, let userAction):
        guard var session = state.sessions[runID], !session.run.status.isTerminal else {
          return .none
        }
        let timestamp = now
        let generator = uuid
        session.run.observations = runtime.observe(session.run)
        session.run.captureParticipantSessions()
        var machine = session.machine(now: { timestamp }, makeToken: { generator().uuidString })
        let effects = machine.apply(.user(userAction))
        let previous = session.run
        session.run = machine.run
        state.sessions[runID] = session
        fenceIfStale(runID: runID, previous: previous, current: session.run)
        return .merge(
          resolvePendingDeliveries(&state, runID: runID, session: session),
          resolvePendingStarts(&state, runID: runID, session: session),
          perform(effects, runID: runID, session: session),
          statusNotice(from: previous.status, to: session.run, effects: effects)
        )

      case .markInterruptedRuns(let roots):
        guard state.scannedWorktreeRoots.isEmpty else { return .none }
        state.scannedWorktreeRoots.formUnion(roots.isEmpty ? ["global"] : roots)
        let storage = historyStorage
        let clock = _now
        return .run { _ in
          await Task.detached(priority: .utility) {
            do {
              _ = try WorkflowActionProcessRegistry(directory: storage.baseURL.appending(path: ".processes"))
                .recoverAbandonedProcesses()
              let store = WorkflowRunStore(rootURL: storage.baseURL, storage: storage)
              let result = try store.markInterruptedRuns(now: { clock.wrappedValue }, allRoots: true)
              if !result.interrupted.isEmpty || !result.unreadable.isEmpty {
                Self.logger.info(
                  "Workflow history: \(result.interrupted.count) interrupted, \(result.unreadable.count) unreadable.")
              }
              _ = try WorkflowHistory(storage: storage).maintenance(now: clock.wrappedValue)
            } catch { Self.logger.warning("Workflow history maintenance failed: \(error)") }
          }.value
        }

      case .delegate:
        return .none
      }
    }
  }

  private func statusNotice(
    from previous: WorkflowRunStatus?,
    to run: WorkflowRun,
    effects: [WorkflowRunEffect]
  ) -> Effect<Action> {
    guard let base = WorkflowRunNotice.statusEdge(from: previous, to: run) else {
      return .none
    }
    let hasExplicitNotification = effects.contains {
      if case .notify = $0 { return true }
      return false
    }
    let notice = WorkflowRunNotice(
      kind: base.kind,
      runID: base.runID,
      worktreeID: base.worktreeID,
      workflowName: base.workflowName,
      title: base.title,
      body: base.body,
      targetSurfaceID: base.targetSurfaceID,
      postsNotification: !(base.kind == .completed && hasExplicitNotification)
    )
    return .send(.delegate(.notice(notice)))
  }

  // MARK: - Rendezvous

  private func respond(_ requestID: UUID, _ resolution: WorkflowRequestResolution) -> Effect<Action> {
    .run { _ in await responder.respond(requestID, resolution) }
  }

  /// Answers a self-initiated `run` once its first activation is open — or once opening it failed
  /// and the run sits in attention or ended — so the caller never holds a completion command
  /// before the dispatch record `deliver` is attributed by exists.
  private func resolvePendingStarts(
    _ state: inout State, runID: UUID, session: WorkflowRunSession
  ) -> Effect<Action> {
    var effects: [Effect<Action>] = []
    for (requestID, pendingRunID) in state.pendingStarts where pendingRunID == runID {
      if case .injecting = session.run.phase, session.run.status == .running { continue }
      state.pendingStarts.removeValue(forKey: requestID)
      effects.append(respond(requestID, .started(run: session.run)))
    }
    return .merge(effects)
  }

  /// Queued work belongs to the invocation that was in flight when it was enqueued. Once a
  /// transition revokes that invocation (retry, relaunch, skip, cancel, an ended run) the queue is
  /// fenced so the executor drops what is left of it instead of typing into a pane a cancel
  /// already left or opening a dispatch record nobody will complete.
  private func fenceIfStale(runID: UUID, previous: WorkflowRun, current: WorkflowRun) {
    guard !previous.status.isTerminal else { return }
    let revokedInFlight: Bool =
      switch previous.phase {
      case .waitingForRole(_, let ordinal), .injecting(let ordinal), .launching(let ordinal):
        current.phase != previous.phase && current.currentInvocation?.ordinal != ordinal
      case .runningAction(let stepID):
        current.phase != previous.phase && current.actionOutputs[stepID] == nil
      case .waitingForDelivery, .idle:
        false
      }
    let revokedActivation = previous.invocations.contains { invocation in
      guard let before = invocation.activation,
        let after = current.invocations.first(where: { $0.ordinal == invocation.ordinal })?.activation
      else { return false }
      let open: Set<WorkflowActivationState> = [.waiting, .persisting, .provisional]
      return open.contains(before.state) && (after.state == .revoked || after.state == .skipped)
    }
    if current.status.isTerminal || revokedInFlight || revokedActivation {
      queue.fence(runID)
    }
  }

  /// Answers every `deliver` whose activation left `persisting` (decision W1): delivered and
  /// provisional succeed; a revoked, skipped, or unpersistable activation and a run that ended fail.
  private func resolvePendingDeliveries(
    _ state: inout State, runID: UUID, session: WorkflowRunSession
  ) -> Effect<Action> {
    var effects: [Effect<Action>] = []
    for (requestID, pending) in state.pendingDeliveries where pending.runID == runID {
      let activation = session.run.invocations.first { $0.ordinal == pending.ordinal }?.activation
      let resolution: WorkflowRequestResolution?
      switch activation?.state {
      case .delivered:
        resolution = .delivered(run: session.run, receipt: pending.receipt)
      case .provisional:
        resolution = .provisional(run: session.run, receipt: pending.receipt)
      case .persisting:
        if case .persistFailed(let reason) = session.run.status.attention?.reason,
          session.run.status.attention?.ordinal == pending.ordinal
        {
          resolution = .failed(
            code: CLIErrorCode.workflowFailed,
            message:
              "The output was accepted but could not be saved to the run directory: \(reason)")
        } else if session.run.status.isTerminal {
          resolution = .failed(
            code: CLIErrorCode.stepNotExpecting,
            message:
              "The run ended (\(WorkflowRunMachine.describe(session.run.status))) before the output was saved."
          )
        } else {
          resolution = nil
        }
      case .waiting, .skipped, .revoked, .none:
        resolution = .failed(
          code: CLIErrorCode.stepNotExpecting,
          message: "The step stopped waiting for this delivery before the output was saved.")
      }
      guard let resolution else { continue }
      state.pendingDeliveries.removeValue(forKey: requestID)
      effects.append(respond(requestID, resolution))
    }
    return .merge(effects)
  }

  // MARK: - Late and stale events

  private func archiveOrCleanLateEvent(_ event: WorkflowRunEvent, runID: UUID, state: inout State) -> Effect<Action> {
    guard var session = state.sessions[runID] else { return lateEventCleanup(event, runID: runID, session: nil) }
    let timestamp = now
    let generator = uuid
    var machine = session.machine(now: { timestamp }, makeToken: { generator().uuidString })
    let effects = machine.apply(event)
    guard !effects.isEmpty else { return lateEventCleanup(event, runID: runID, session: session) }
    session.run = machine.run
    state.sessions[runID] = session
    // The non-revocable write precedes the cancellation batch. Its acknowledgement queues this
    // snapshot before finish closes the stream; buffered archival writes still drain in order.
    return perform(effects, runID: runID, session: session)
  }

  /// An event that arrives after the run ended (or for an unknown run) may own a pane or a
  /// dispatch record nobody will use: a `.launched` abandons its record and closes the pane, an
  /// `.injectionSucceeded` abandons the record it opened (B2: the machine ignores events on
  /// terminal runs, so the wiring must clean up).
  private func lateEventCleanup(_ event: WorkflowRunEvent, runID: UUID, session: WorkflowRunSession?)
    -> Effect<Action>
  {
    let runName = runID.uuidString
    switch event {
    case .launched(let ordinal, let pane, let dispatchID):
      return closeUnboundLaunch(
        pane: pane, dispatchID: dispatchID,
        reason: "Workflow run \(runName) ended before role launch \(ordinal) completed.",
        worktree: session?.worktree, runID: runID)
    case .injectionSucceeded(let ordinal, let dispatchID?):
      return abandonStaleActivation(
        dispatchID, reason: "Workflow run \(runName) ended before invocation \(ordinal) was typed.")
    default:
      return .none
    }
  }

  /// An event the running machine did not take up (its step was retried, relaunched, skipped, or
  /// cancelled while the effect was in flight) is cleaned up the same way.
  private func staleEventCleanup(_ event: WorkflowRunEvent, session: WorkflowRunSession) -> Effect<Action> {
    let runName = session.run.id.uuidString
    switch event {
    case .launched(let ordinal, let pane, let dispatchID) where !session.boundSurfaceIDs.contains(pane.surfaceID):
      return closeUnboundLaunch(
        pane: pane, dispatchID: dispatchID,
        reason: "Workflow run \(runName) moved on before role launch \(ordinal) completed.",
        worktree: session.worktree, runID: session.run.id)
    case .injectionSucceeded(let ordinal, let dispatchID?)
    where session.run.activation(forDispatchID: dispatchID) == nil:
      return abandonStaleActivation(
        dispatchID, reason: "Workflow run \(runName) moved on before invocation \(ordinal) was typed.")
    default:
      return .none
    }
  }

  private func abandonStaleActivation(_ dispatchID: String, reason: String) -> Effect<Action> {
    .run { _ in
      await activation.abandon(dispatchID, reason)
      Self.logger.info("[Workflow] Abandoned stale activation \(dispatchID): \(reason)")
    }
  }

  private func closeUnboundLaunch(
    pane: WorkflowPaneIdentity, dispatchID: String?, reason: String, worktree: Worktree?, runID: UUID
  ) -> Effect<Action> {
    .run { _ in
      if let dispatchID {
        await activation.abandon(dispatchID, reason)
      }
      if let worktree {
        _ = await runtime.close(worktree, pane.surfaceID, runID)
      }
      Self.logger.info("[Workflow] Closed unbound launch \(pane.handle): \(reason)")
    }
  }

  // MARK: - Binding memory

  /// A successful launch remembers its profile under B2's requirements digest (dsl-spec §3).
  private func rememberLaunchedBindings(previous: WorkflowRun, current: WorkflowRunSession) {
    for (role, binding) in current.run.bindings {
      guard case .launch(let profile, let pane) = binding, pane != nil,
        previous.bindings[role]?.pane == nil,
        let key = current.bindingMemoryKeys[role]
      else { continue }
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.remember(workflowBinding: key, profileID: profile.id) }
    }
  }

  // MARK: - Effects

  nonisolated private enum CancelID: Hashable, Sendable {
    case executor(UUID)
    case action(UUID)
    case roleWait(UUID, Int)
    case watchdog(UUID, Int)
    case observers(UUID)
  }

  /// The run's ordered effect executor (one per run). It ends when `.finished` closes the queue.
  /// Effects of a fenced batch are skipped one by one, so a fence raised mid-batch still stops
  /// the rest of it.
  private func executor(runID: UUID, batches: AsyncStream<WorkflowEffectBatch>) -> Effect<Action> {
    .run { send in
      for await batch in batches {
        for effect in batch.effects {
          // A fenced batch still performs its bookkeeping (records, logs, dispatch completions
          // and abandonments, notify) — those belong to transitions the machine already made —
          // but skips what would act on a pane or the worktree for an invocation the run has
          // left (`WorkflowRunEffect.isRevocable`), effect by effect.
          if effect.isRevocable, await queue.isStale(runID, batch.sequence) {
            Self.logger.info("[Workflow] Skipped stale effect of run \(runID): \(effect)")
            if case .runAction(let stepID, let actionID, _) = effect {
              await appendLog(
                "Step '\(stepID)': native action '\(actionID)' not started; the run had moved on.",
                store: batch.session.store, runID: runID)
            }
            continue
          }
          let outcome = await perform(
            effect, runID: runID, session: batch.session, send: send, sequence: batch.sequence)
          if outcome == .stop { break }
        }
      }
    }
    .cancellable(id: CancelID.executor(runID), cancelInFlight: true)
  }

  /// Splits a batch: ordered effects go to the run's queue; observers become cancellable effects.
  private func perform(_ effects: [WorkflowRunEffect], runID: UUID, session: WorkflowRunSession)
    -> Effect<Action>
  {
    var ordered: [WorkflowRunEffect] = []
    var observers: [Effect<Action>] = []
    let armedOrdinals = Set(
      effects.compactMap { effect -> Int? in
        if case .armWatchdog(let request) = effect { return request.ordinal }
        return nil
      })
    for effect in effects {
      switch effect {
      case .awaitRoleIdle(_, let surfaceID, let ordinal):
        observers.append(roleWait(runID: runID, surfaceID: surfaceID, ordinal: ordinal))
      case .cancelRoleWait(let ordinal):
        observers.append(.cancel(id: CancelID.roleWait(runID, ordinal)))
      case .armWatchdog(let request):
        observers.append(watchdogObserver(runID: runID, request: request))
      case .disarmWatchdog(let ordinal):
        // A re-arm in the same batch replaces the driver through `cancelInFlight`; a lone
        // disarm cancels the consuming effect, which tears the driver down.
        if !armedOrdinals.contains(ordinal) {
          observers.append(.cancel(id: CancelID.watchdog(runID, ordinal)))
        }
      case .finished:
        ordered.append(effect)
        observers.append(.cancel(id: CancelID.observers(runID)))
        observers.append(.cancel(id: CancelID.action(runID)))
      default:
        ordered.append(effect)
      }
    }
    if !ordered.isEmpty {
      // Enqueued synchronously while reducing so batches keep the machine's order.
      queue.enqueue(runID, WorkflowEffectBatch(session: session, effects: ordered))
    }
    return .merge(observers)
  }

  private func executeAction(
    session: WorkflowRunSession, stepID: String, actionID: String,
    inputs: [String: WorkflowJSONValue], executionID: String
  ) -> Effect<Action> {
    let run = session.run
    let timestamp = now
    let sourcePane = run.context.sourcePaneID ?? run.bindings.values.first { $0.source == .current }?.pane?.surfaceID
    let sourceContext =
      actionID == "builtin:save-handoff"
      ? sourcePane.flatMap {
        terminal.handoffSourceContextForSurface(session.worktree.id, $0)?.sessionContext
      } : nil
    let context = WorkflowActionContext(
      runID: run.id, rootURL: run.context.worktree.rootURL,
      roleAgents: run.bindings.mapValues { $0.agent },
      outgoingAgent: sourceContext?.agent ?? run.bindings.values.first { $0.source == .current }?.agent,
      sessionContext: sourceContext, now: timestamp,
      stepID: stepID, executionID: executionID, attempt: run.actionAttempts[stepID] ?? 1,
      bundle: run.context.bundle, values: run.stepValues, runDirectory: run.runDirectory)
    run.context.occupancy?.beginActivity()
    return .run { send in
      defer { run.context.occupancy?.endActivity() }
      do {
        let outputs = try await actionExecutor.execute(actionID: actionID, inputs: inputs, context: context)
        await send(.event(runID: run.id, .actionCompleted(stepID: stepID, outputs: outputs, executionID: executionID)))
      } catch {
        guard !Task.isCancelled else { return }
        await send(
          .event(
            runID: run.id,
            .actionFailed(
              stepID: stepID, reason: "\(error)", executionID: executionID,
              retryAllowed: !(error is WorkflowBundleIntegrityError))))
      }
    }.cancellable(id: CancelID.action(run.id), cancelInFlight: true)
  }

  /// The idle wait of a `message` step (dsl-spec §10): ends as `.roleIdle`, or as the failed
  /// injection the machine maps to attention.
  private func roleWait(runID: UUID, surfaceID: UUID, ordinal: Int) -> Effect<Action> {
    .run { send in
      switch await runtime.waitForRole(surfaceID) {
      case .idle:
        await send(.event(runID: runID, .roleIdle(ordinal: ordinal)))
      case .blocked:
        await send(.event(runID: runID, .roleUnavailable(ordinal: ordinal, .roleBlocked)))
      case .gone:
        await send(.event(runID: runID, .roleUnavailable(ordinal: ordinal, .surfaceMissing)))
      case .noAgent:
        await send(
          .event(
            runID: runID,
            .roleUnavailable(ordinal: ordinal, .activationUnavailable("the pane hosts no detected agent"))))
      case .dispatchPending(let dispatchID):
        await send(
          .event(
            runID: runID,
            .roleUnavailable(
              ordinal: ordinal,
              .activationUnavailable(
                "the pane already holds pending dispatch \(dispatchID); complete or abandon it first"))))
      case .cancelled:
        break
      }
    }
    .cancellable(id: CancelID.roleWait(runID, ordinal), cancelInFlight: true)
    .cancellable(id: CancelID.observers(runID))
  }

  /// One watchdog driver per waiting activation; cancelling the effect tears the driver down.
  private func watchdogObserver(runID: UUID, request: WorkflowWatchdogRequest) -> Effect<Action> {
    .run { send in
      let handle = await watchdog.arm(runID, request)
      for await verdict in handle.verdicts {
        await send(.event(runID: runID, .watchdog(ordinal: request.ordinal, verdict)))
      }
      await handle.cancel()
    }
    .cancellable(id: CancelID.watchdog(runID, request.ordinal), cancelInFlight: true)
    .cancellable(id: CancelID.observers(runID))
  }

  nonisolated private enum StepOutcome: Equatable {
    case `continue`
    /// The rest of the batch depends on what just failed (an instruction the line points at).
    case stop
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func perform(
    _ effect: WorkflowRunEffect,
    runID: UUID,
    session: WorkflowRunSession,
    send: Send<Action>,
    sequence: Int
  ) async -> StepOutcome {
    let store = session.store
    let queue = queue
    // Read on the main actor right before a pane is touched: no cancel can slip in between.
    let isLive: @MainActor () -> Bool = { !queue.isStale(runID, sequence) }
    switch effect {
    case .awaitRoleIdle, .cancelRoleWait, .armWatchdog, .disarmWatchdog:
      // Observers never enter the ordered queue.
      return .continue

    case .openActivation(_, let surfaceID, let ordinal):
      // Issuance and the machine's take-up of the record share this main-actor turn (`send`
      // reduces synchronously); the guard keeps a cancel that landed after the batch check
      // from opening a record the run would never own.
      guard isLive() else { return .stop }
      switch activation.openMessage(surfaceID) {
      case .success(let dispatchID):
        await send(
          .event(runID: runID, .injectionSucceeded(ordinal: ordinal, dispatchID: dispatchID)))
      case .failure(let failure):
        await send(
          .event(runID: runID, .injectionFailed(ordinal: ordinal, failure.injectionFailure)))
      }

    case .materializePrompt(let ordinal, let stepID, let text):
      do {
        try store.ensureLayout(runID: runID)
        _ = try store.writePrompt(runID: runID, stepID: stepID, ordinal: ordinal, text: text)
      } catch {
        let reason = "The instruction could not be persisted: \(error)"
        let event: WorkflowRunEvent =
          session.run.invocations.first { $0.ordinal == ordinal }?.kind == .launch
          ? .launchFailed(ordinal: ordinal, reason: reason)
          : .injectionFailed(ordinal: ordinal, .activationUnavailable(reason))
        await send(.event(runID: runID, event))
        return .stop
      }

    case .materializeSkill(let id):
      do {
        guard let skill = session.skills[id] else { throw WorkflowRunStoreError.skillMissing(id) }
        try store.ensureLayout(runID: runID)
        _ = try store.materializeSkill(runID: runID, skill: skill)
      } catch {
        guard let ordinal = session.run.currentInvocation?.ordinal else { return .stop }
        await send(
          .event(
            runID: runID,
            .launchFailed(
              ordinal: ordinal, reason: "skill '\(id)' could not be materialized: \(error)")))
        return .stop
      }

    case .inject(_, let surfaceID, let ordinal, let line, let opensActivation):
      // Issuance, the typed line, and — when the terminal refuses it — the issuance's return
      // share one main-actor turn: nothing can complete or bind the record in between.
      guard isLive() else { return .stop }
      var dispatchID: String?
      if opensActivation {
        switch activation.openMessage(surfaceID) {
        case .success(let value):
          dispatchID = value
        case .failure(let failure):
          await send(
            .event(runID: runID, .injectionFailed(ordinal: ordinal, failure.injectionFailure)))
          return .stop
        }
      }
      switch runtime.deliverLine(session.worktree, surfaceID, line, isLive) {
      case .delivered:
        await send(
          .event(runID: runID, .injectionSucceeded(ordinal: ordinal, dispatchID: dispatchID)))
      case .stale:
        // A cancel landed while the record was being issued: nothing was typed; give the
        // issuance back and let the fence swallow the rest of the batch.
        if let dispatchID { activation.cancel(dispatchID) }
        return .stop
      case .insertFailed:
        if let dispatchID { activation.cancel(dispatchID) }
        await send(.event(runID: runID, .injectionFailed(ordinal: ordinal, .insertFailed)))
        return .stop
      case .submitFailed:
        if let dispatchID { activation.cancel(dispatchID) }
        await send(.event(runID: runID, .injectionFailed(ordinal: ordinal, .submitFailed)))
        return .stop
      }

    case .typeLine(let role, let surfaceID, let line):
      let delivery = runtime.deliverLine(session.worktree, surfaceID, line, isLive)
      if delivery != .delivered && delivery != .stale {
        Self.logger.warning("[Workflow] Could not type into role '\(role)' of run \(runID).")
      }

    case .launch(let request):
      guard let plan = session.launchPlans[request.role] else {
        await send(
          .event(
            runID: runID,
            .launchFailed(
              ordinal: request.ordinal, reason: "role '\(request.role)' has no frozen launch plan"))
        )
        return .stop
      }
      switch await runtime.launch(session.worktree, plan, request) {
      case .success(let result):
        await send(
          .event(
            runID: runID,
            .launched(ordinal: request.ordinal, pane: result.pane, dispatchID: result.dispatchID)))
      case .failure(.failed(let reason)):
        await send(.event(runID: runID, .launchFailed(ordinal: request.ordinal, reason: reason)))
        return .stop
      }

    case .runAction(let stepID, let actionID, let inputs):
      guard isLive(), let executionID = session.run.actionExecutionID else { return .stop }
      await send(
        .executeAction(runID: runID, stepID: stepID, actionID: actionID, inputs: inputs, executionID: executionID))

    case .yieldControl:
      await Task.yield()
      await send(.event(runID: runID, .continueControlFlow))

    case .notify(let text):
      runtime.notify(
        session.worktree,
        WorkflowRuntimeNotification(
          title: "Workflow · \(session.run.definition.name)",
          body: text,
          targetSurfaceID: WorkflowRunNotice.targetSurfaceID(for: session.run),
          workflowRunID: session.run.id
        )
      )

    case .close(let role, let surfaceID):
      // Revocable: a cancel that beat the close keeps the pane (cancel never closes panes); the
      // boundary leaves a pane another run has bound since alone.
      guard isLive() else { return .stop }
      if !runtime.close(session.worktree, surfaceID, runID) {
        Self.logger.warning("[Workflow] Run \(runID) could not close the pane of role '\(role)'.")
      }

    case .abandonActivation(let dispatchID, let reason):
      activation.abandon(dispatchID, reason)

    case .completeActivation(let dispatchID, let summary):
      activation.complete(dispatchID, summary)

    case .persistDelivery(let name, let ordinal, let body):
      do {
        _ = try store.writeDelivery(runID: runID, name: name, ordinal: ordinal, body: body)
        await send(.event(runID: runID, .deliveryPersisted(ordinal: ordinal)))
      } catch {
        await send(.event(runID: runID, .deliveryPersistFailed(ordinal: ordinal, reason: "\(error)")))
      }

    case .persist:
      do {
        try store.ensureLayout(runID: runID)
        try store.writeRecord(WorkflowRunRecord(run: session.run))
      } catch {
        Self.logger.warning("[Workflow] Could not persist run \(runID): \(error)")
      }

    case .log(let line):
      appendLog(line, store: store, runID: runID)

    case .finished:
      queue.finish(runID)
      session.run.context.occupancy?.finish()
      let storage = store.storage
      let timestamp = now
      await Task.detached(priority: .utility) {
        do { _ = try WorkflowHistory(storage: storage).maintenance(now: timestamp) } catch {
          Self.logger.warning("Workflow history maintenance failed: \(error)")
        }
      }.value
    }
    return .continue
  }

  private func appendLog(_ line: String, store: WorkflowRunStore, runID: UUID) {
    do {
      try store.ensureLayout(runID: runID)
      try store.appendLog(runID: runID, line: line, now: now)
    } catch {
      Self.logger.warning("[Workflow] Could not append to the log of run \(runID): \(error)")
    }
  }
}

extension WorkflowRunEffect {
  /// Effects that act on a pane or the worktree for the invocation in flight, which a fence
  /// (retry / relaunch / skip / cancel / an ended run) must keep from running late; `close` is
  /// one of them because a cancel keeps every pane. Everything else — records, logs,
  /// materialized files, dispatch completions and abandonments, notify, teardown — belongs to a
  /// transition the machine already made and still runs. The fence a run's own end raises
  /// precedes the batch that ends it, so a `close` in that batch is still performed.
  nonisolated var isRevocable: Bool {
    switch self {
    case .openActivation, .inject, .typeLine, .launch, .runAction, .close: true
    case .awaitRoleIdle, .cancelRoleWait, .materializePrompt, .materializeSkill, .notify,
      .abandonActivation, .completeActivation, .armWatchdog, .disarmWatchdog, .persistDelivery, .persist, .log,
      .finished, .yieldControl:
      false
    }
  }
}
