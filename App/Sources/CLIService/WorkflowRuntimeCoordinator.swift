// supacode/CLIService/WorkflowRuntimeCoordinator.swift
// The socket side of `prowl workflow run / status / deliver / cancel` (docs-ai 063 B3). It reads the
// reducer's sessions, attributes a `deliver` to an activation (decision W3), enters the reducer
// through actions, and awaits the `deliver` rendezvous (decision W1). It owns no run state.

import Foundation
import ProwlCLIShared

/// A wire response carried as a failure through `Result`.
nonisolated struct WorkflowCommandRefusal: Error {
  let response: CommandResponse
}

@MainActor
final class WorkflowRuntimeCoordinator {
  struct Dependencies {
    let admissionEnvironment: @MainActor () -> WorkflowAdmissionEnvironment
    /// Every session the reducer holds, terminal ones included.
    let sessions: @MainActor () -> [WorkflowRunSession]
    let send: @MainActor (WorkflowRunsFeature.Action) -> Void
    /// The pending dispatch record of a pane, if any (the activation address of decision W3).
    let pendingDispatchID: @MainActor (UUID) -> String?
    /// Working directories of every known worktree, for `status` of a run that is not live (W5).
    let worktreeRoots: @MainActor () -> [URL]
    let paneOwner: @MainActor (UUID) -> UUID?
    let rendezvous: WorkflowCLIRendezvous
    let makeRequestID: @Sendable () -> UUID

    init(
      admissionEnvironment: @escaping @MainActor () -> WorkflowAdmissionEnvironment,
      sessions: @escaping @MainActor () -> [WorkflowRunSession],
      send: @escaping @MainActor (WorkflowRunsFeature.Action) -> Void,
      pendingDispatchID: @escaping @MainActor (UUID) -> String?,
      worktreeRoots: @escaping @MainActor () -> [URL],
      paneOwner: @escaping @MainActor (UUID) -> UUID? = { _ in nil },
      rendezvous: WorkflowCLIRendezvous = WorkflowCLIRendezvous(),
      makeRequestID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
      self.admissionEnvironment = admissionEnvironment
      self.sessions = sessions
      self.send = send
      self.pendingDispatchID = pendingDispatchID
      self.worktreeRoots = worktreeRoots
      self.paneOwner = paneOwner
      self.rendezvous = rendezvous
      self.makeRequestID = makeRequestID
    }
  }

  private let dependencies: Dependencies
  /// The verified caller role of each outstanding `run` / `deliver`, so the answer spells completion
  /// commands only to the pane that owns the activation (never to a manual or forced caller).
  private var callerRoles: [UUID: String] = [:]
  /// Request ids the reducer still owes an answer for; a cancelled waiter frees its rendezvous
  /// slot, but its id stays unusable until that answer arrives so nothing crosses requests.
  private var inFlight: Set<UUID> = []

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  // MARK: - run

  func run(
    _ input: WorkflowInput, source: WorkflowRunSource, snapshot: WorkflowRuntimeSnapshot
  ) async -> CommandResponse {
    var environment = dependencies.admissionEnvironment()
    environment = environment.busy(dependencies.sessions().filter { !$0.run.status.isTerminal })
    let admission = WorkflowRunAdmission.admit(input, source: source, snapshot: snapshot, environment: environment)
    switch admission {
    case .failure(let failure):
      return Self.failure(failure)
    case .success(let admitted):
      guard admitted.session.run.selfInitiatedLine != nil else {
        dependencies.send(.started(admitted.session, effects: admitted.effects))
        let run =
          dependencies.sessions().first { $0.run.id == admitted.session.run.id }?.run ?? admitted.session.run
        return Self.success(
          .run(WorkflowRunPayload(run: run, callerRole: admitted.callerRole, includeSelfInitiated: true)))
      }
      // A self-initiated first step hands the caller its completion command: answer only once
      // the activation record that attributes that command exists (or its opening failed).
      let requestID = dependencies.makeRequestID()
      guard claim(requestID, callerRole: admitted.callerRole) else {
        return Self.failure(code: CLIErrorCode.requestConflict, message: "Workflow request id is already in use.")
      }
      dependencies.send(.started(admitted.session, effects: admitted.effects, requestID: requestID))
      return await dependencies.rendezvous.wait(for: requestID)
    }
  }

  // MARK: - status

  func status(_ input: WorkflowInput, callerPane: CallerPane?) -> CommandResponse {
    if let reference = input.runID {
      guard let runID = UUID(uuidString: reference) else {
        return Self.failure(
          code: CLIErrorCode.invalidArgument, message: "'\(reference)' is not a run UUID.")
      }
      if let session = dependencies.sessions().first(where: { $0.run.id == runID }),
        !session.run.status.isTerminal || readRecord(runID: runID) != nil
      {
        let role = callerPane.flatMap { Self.role(of: $0.surfaceID, in: session) }
        return Self.success(
          .status(
            WorkflowRunPayload(run: session.run, callerRole: role, includeSelfInitiated: false)))
      }
      guard let record = readRecord(runID: runID) else {
        return Self.failure(
          code: CLIErrorCode.runNotFound,
          message: "No workflow run \(runID.uuidString) is live or recorded in personal history.")
      }
      return Self.success(.status(WorkflowRunPayload(record: record)))
    }
    guard let callerPane else {
      return Self.failure(
        code: CLIErrorCode.sourceRequired,
        message: "Run `prowl workflow status` inside a Prowl pane, or pass a run UUID.")
    }
    guard
      let session = dependencies.sessions().first(where: {
        !$0.run.status.isTerminal && $0.boundSurfaceIDs.contains(callerPane.surfaceID)
      })
    else {
      return Self.failure(
        code: CLIErrorCode.runNotFound, message: "This pane is not part of an active workflow run.")
    }
    let role = Self.role(of: callerPane.surfaceID, in: session)
    return Self.success(
      .status(WorkflowRunPayload(run: session.run, callerRole: role, includeSelfInitiated: false)))
  }

  // MARK: - Scoped task content

  func read(_ input: WorkflowInput, callerPane: CallerPane?) async -> CommandResponse {
    guard let callerPane else {
      return Self.failure(code: CLIErrorCode.sourceRequired, message: "Read workflow content from its assigned pane.")
    }
    guard let (session, invocation) = assignedContent(input, pane: callerPane.surfaceID),
      let grant = invocation.content
    else {
      return Self.failure(code: CLIErrorCode.stepNotExpecting, message: "This task is no longer assigned to this pane.")
    }
    let role = invocation.role
    let storage = session.store.storage
    let directory = session.run.runDirectory
    let requestResource = input.contentResource
    let offset = input.contentOffset ?? 0
    do {
      let payload = try await Task.detached(priority: .utility) {
        try storage.validate(directory)
        var resources = grant.resources
        if let skill = grant.skill {
          let skillDirectory = WorkflowRunPaths.skillDirectory(runDirectory: directory, skillID: skill)
          for (index, file) in try storage.files(in: skillDirectory).enumerated() {
            resources["skill-\(index + 1)"] = file.path
          }
        }
        var listings: [String: Data] = [:]
        for (id, path) in grant.resources.sorted(by: { $0.key < $1.key }) {
          let url = URL(filePath: path)
          try storage.validate(url)
          if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            let children = try storage.files(in: url).sorted { $0.path < $1.path }
            var names: [WorkflowContentResource] = []
            for (index, file) in children.enumerated() {
              let childID = "\(id)-file-\(index + 1)"
              resources[childID] = file.path
              names.append(.init(id: childID, name: String(file.path.dropFirst(url.path.count + 1))))
            }
            listings[id] = try JSONEncoder().encode(names)
          }
        }
        let resource = requestResource ?? "prompt"
        let data: Data
        let total: Int64
        let next: Int64?
        if resource == "prompt" || listings[resource] != nil {
          let full =
            listings[resource]
            ?? Data((grant.text + (invocation.activation?.completion.completionTrailer() ?? "")).utf8)
          guard offset >= 0, offset <= full.count else { throw WorkflowHistoryError.protectedRun }
          let end = min(Int(offset) + WorkflowSizeLimits.contentPage, full.count)
          data = full.subdata(in: Int(offset)..<end)
          total = Int64(full.count)
          next = end < full.count ? Int64(end) : nil
        } else {
          guard let path = resources[resource] else { throw WorkflowHistoryError.protectedRun }
          let chunk = try storage.readChunk(URL(filePath: path), offset: offset)
          data = chunk.data
          total = chunk.total
          next = chunk.nextOffset
        }
        let text = String(data: data, encoding: .utf8)
        let names = resources.sorted { $0.key < $1.key }.map { key, path in
          WorkflowContentResource(id: key, name: String(path.dropFirst(directory.path.count + 1)))
        }
        return WorkflowContentPayload(
          run: session.run.id.uuidString, invocation: invocation.ordinal, role: role, step: invocation.stepID,
          resource: resource, body: text ?? data.base64EncodedString(), encoding: text == nil ? "base64" : "utf-8",
          resources: names, offset: offset, nextOffset: next, totalBytes: total)
      }.value
      // Do not return bytes if cancellation or reassignment won during the filesystem read.
      guard assignedContent(input, pane: callerPane.surfaceID) != nil else {
        return Self.failure(code: CLIErrorCode.stepNotExpecting, message: "The task changed during content retrieval.")
      }
      return Self.success(.read(payload))
    } catch {
      return Self.failure(code: CLIErrorCode.workflowFailed, message: "Cannot read the assigned resource: \(error)")
    }
  }

  private func assignedContent(_ input: WorkflowInput, pane: UUID) -> (WorkflowRunSession, WorkflowInvocation)? {
    guard input.stepID == nil, !input.force, input.token == nil,
      let reference = input.runID, let runID = UUID(uuidString: reference),
      dependencies.paneOwner(pane) == runID,
      let session = dependencies.sessions().first(where: { $0.run.id == runID }),
      !session.run.status.isTerminal || session.run.status == .completed,
      let role = Self.role(of: pane, in: session),
      let invocation = session.run.invocations.last(where: { $0.role == role }),
      invocation.ordinal == input.invocation, invocation.content != nil,
      invocation.activation?.state != .skipped, invocation.activation?.state != .revoked
    else { return nil }
    return (session, invocation)
  }

  // MARK: - deliver

  func deliver(_ input: WorkflowInput, callerPane: CallerPane?) async -> CommandResponse {
    guard let body = input.body else {
      return Self.failure(
        code: CLIErrorCode.invalidArgument, message: "The delivery has no output body.")
    }
    let explicit: (runID: UUID, stepID: String)?
    switch input.runID {
    case .none:
      guard input.stepID == nil else {
        return Self.failure(
          code: CLIErrorCode.invalidArgument, message: "--run and --step must be passed together.")
      }
      explicit = nil
    case .some(let reference):
      guard let stepID = input.stepID else {
        return Self.failure(
          code: CLIErrorCode.invalidArgument, message: "--run and --step must be passed together.")
      }
      guard let runID = UUID(uuidString: reference) else {
        return Self.failure(
          code: CLIErrorCode.invalidArgument, message: "'\(reference)' is not a run UUID.")
      }
      explicit = (runID, stepID)
    }

    let attribution: Attribution
    switch attribute(explicit: explicit, callerPane: callerPane, token: input.token, force: input.force) {
    case .failure(let refusal):
      return refusal.response
    case .success(let value):
      attribution = value
    }
    let request = WorkflowDeliveryRequest(
      requestID: dependencies.makeRequestID(),
      runID: attribution.runID,
      ordinal: attribution.ordinal,
      selector: attribution.selector,
      body: body,
      verdict: input.verdict,
      source: attribution.source)
    guard claim(request.requestID, callerRole: attribution.callerRole) else {
      return Self.failure(code: CLIErrorCode.requestConflict, message: "Workflow request id is already in use.")
    }
    dependencies.send(.deliver(request))
    return await dependencies.rendezvous.wait(for: request.requestID)
  }

  /// Registers a request with the rendezvous and remembers its verified caller role; false when
  /// the id is still in flight (or waiting) for another request.
  private func claim(_ requestID: UUID, callerRole: String?) -> Bool {
    guard !inFlight.contains(requestID), dependencies.rendezvous.register(requestID) else { return false }
    inFlight.insert(requestID)
    if let callerRole {
      callerRoles[requestID] = callerRole
    }
    return true
  }

  private struct Attribution {
    let runID: UUID
    let ordinal: Int?
    let selector: WorkflowDeliverySelector
    let source: String
    /// The caller pane's role when the delivery was attributed by that pane; nil for manual.
    let callerRole: String?
  }

  /// Decision W3: the caller pane's pending dispatch identifies the activation first; explicit
  /// `--run --step` is the manual path; both present and disagreeing needs `--force`.
  private func attribute(
    explicit: (runID: UUID, stepID: String)?, callerPane: CallerPane?, token: String?, force: Bool
  ) -> Result<Attribution, WorkflowCommandRefusal> {
    let active = dependencies.sessions().filter { !$0.run.status.isTerminal }
    var callerActivation: (session: WorkflowRunSession, activation: WorkflowActivation)?
    if let callerPane, let dispatchID = dependencies.pendingDispatchID(callerPane.surfaceID) {
      for session in active {
        if let activation = session.run.activation(forDispatchID: dispatchID) {
          callerActivation = (session, activation)
          break
        }
      }
    }
    if let (session, activation) = callerActivation {
      if let explicit, explicit.runID != session.run.id || explicit.stepID != activation.stepID {
        guard force else {
          return .failure(
            Self.refusal(
              code: CLIErrorCode.roleMismatch,
              message:
                "This pane is waiting for step '\(activation.stepID)' of run \(session.run.id.uuidString), "
                + "not step '\(explicit.stepID)' of run \(explicit.runID.uuidString); "
                + "pass --force to deliver there anyway."
            ))
        }
        return manual(explicit, source: "manual --force", active: active)
      }
      return .success(
        Attribution(
          runID: session.run.id, ordinal: activation.ordinal, selector: .token(token),
          source: "pane", callerRole: activation.role))
    }
    guard let explicit else {
      if callerPane == nil {
        return .failure(
          Self.refusal(
            code: CLIErrorCode.sourceRequired,
            message: "Run `prowl workflow deliver` inside the pane that received the step, "
              + "or pass --run <run UUID> --step <step id> for a manual delivery."))
      }
      return .failure(
        Self.refusal(
          code: CLIErrorCode.stepNotExpecting,
          message:
            "This pane holds no waiting workflow activation; the step may have moved on or been skipped."
        ))
    }
    return manual(explicit, source: "manual", active: active)
  }

  private func manual(
    _ explicit: (runID: UUID, stepID: String), source: String, active: [WorkflowRunSession]
  ) -> Result<Attribution, WorkflowCommandRefusal> {
    guard let session = active.first(where: { $0.run.id == explicit.runID }) else {
      return .failure(
        Self.refusal(
          code: CLIErrorCode.runNotFound,
          message: "No active workflow run \(explicit.runID.uuidString)."))
    }
    return .success(
      Attribution(
        runID: session.run.id, ordinal: nil, selector: .manual(stepID: explicit.stepID),
        source: source, callerRole: nil))
  }

  /// The reducer's answer to a `run` or `deliver` request (through `WorkflowCLIResponderClient`).
  func resolve(_ requestID: UUID, _ resolution: WorkflowRequestResolution) {
    inFlight.remove(requestID)
    let callerRole = callerRoles.removeValue(forKey: requestID)
    let response: CommandResponse
    switch resolution {
    case .started(let run):
      response = Self.success(.run(WorkflowRunPayload(run: run, callerRole: callerRole, includeSelfInitiated: true)))
    case .delivered(let run, let receipt):
      response = Self.success(
        .deliver(Self.deliverPayload(run: run, receipt: receipt, state: .delivered, callerRole: callerRole)))
    case .provisional(let run, let receipt):
      response = Self.success(
        .deliver(Self.deliverPayload(run: run, receipt: receipt, state: .provisional, callerRole: callerRole)))
    case .failed(let code, let message):
      response = Self.failure(code: code, message: message)
    }
    dependencies.rendezvous.resolve(requestID, with: response)
  }

  private static func deliverPayload(
    run: WorkflowRun, receipt: WorkflowDeliveryReceipt, state: WorkflowDeliveryState, callerRole: String?
  ) -> WorkflowDeliverPayload {
    let role = run.invocations.first { $0.ordinal == receipt.ordinal }?.role ?? "-"
    return WorkflowDeliverPayload(
      run: WorkflowRunPayload(run: run, callerRole: callerRole, includeSelfInitiated: false),
      delivery: WorkflowDeliveryPayload(state: state, receipt: receipt, role: role))
  }

  /// The `WORKFLOW_DELIVERY_REQUIRED` refusal for `agents dispatch-complete` when the pane's
  /// pending record is a workflow activation. Terminal sessions count too: their abandon is
  /// queued behind earlier work, and a plain completion must not win that race.
  static func deliveryRefusal(dispatchID: String, sessions: [WorkflowRunSession]) -> CommandError? {
    for session in sessions {
      guard let activation = session.run.activation(forDispatchID: dispatchID) else { continue }
      if session.run.status.isTerminal {
        return CommandError(
          code: CLIErrorCode.workflowDeliveryRequired,
          message: "This pane's pending dispatch belongs to workflow run \(session.run.id.uuidString), "
            + "which already ended (\(WorkflowRunMachine.describe(session.run.status))); the record is being abandoned."
        )
      }
      return CommandError(
        code: CLIErrorCode.workflowDeliveryRequired,
        message: activation.completion.deliveryRequiredMessage(
          runID: session.run.id.uuidString, stepID: activation.stepID))
    }
    return nil
  }

  // MARK: - cancel

  func cancel(_ input: WorkflowInput, callerPane: CallerPane?) -> CommandResponse {
    guard let reference = input.runID, let runID = UUID(uuidString: reference) else {
      return Self.failure(code: CLIErrorCode.invalidArgument, message: "cancel needs a run UUID.")
    }
    guard let session = dependencies.sessions().first(where: { $0.run.id == runID }) else {
      return Self.failure(
        code: CLIErrorCode.runNotFound, message: "No live workflow run \(runID.uuidString).")
    }
    guard !session.run.status.isTerminal else {
      return Self.failure(
        code: CLIErrorCode.runNotFound,
        message:
          "Workflow run \(runID.uuidString) already ended (\(WorkflowRunMachine.describe(session.run.status)))."
      )
    }
    dependencies.send(.userAction(runID: runID, .cancel))
    let cancelled = dependencies.sessions().first { $0.run.id == runID }?.run ?? session.run
    let role = callerPane.flatMap { Self.role(of: $0.surfaceID, in: session) }
    return Self.success(
      .cancel(WorkflowRunPayload(run: cancelled, callerRole: role, includeSelfInitiated: false)))
  }

  // MARK: - Helpers

  private static func role(of surfaceID: UUID, in session: WorkflowRunSession) -> String? {
    session.run.bindings.first { $0.value.pane?.surfaceID == surfaceID }?.key
  }

  /// A v1 record from any known worktree root; nothing is reconstructed from it (decision W5).
  private func readRecord(runID: UUID) -> WorkflowRunRecord? {
    let storage = WorkflowHistoryStorage.configured
    guard let directory = try? storage.find(runID) else { return nil }
    return try? WorkflowRunStore(rootURL: directory, directory: directory, storage: storage).readRecord(runID: runID)
  }

  static func success(_ payload: WorkflowCommandPayload) -> CommandResponse {
    do {
      return try CommandResponse(
        ok: true,
        command: WorkflowCommandPayload.commandName,
        schemaVersion: WorkflowCommandPayload.schemaVersion,
        data: RawJSON(encoding: payload))
    } catch {
      return failure(
        code: CLIErrorCode.workflowFailed,
        message: "Failed to encode the workflow response: \(error)")
    }
  }

  static func failure(_ failure: WorkflowAdmissionFailure) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: WorkflowCommandPayload.commandName,
      schemaVersion: WorkflowCommandPayload.schemaVersion,
      error: CommandError(
        code: failure.code,
        message: failure.message,
        details: failure.details.flatMap {
          try? RawJSON(encoding: WorkflowCommandPayload.validate($0))
        }))
  }

  static func failure(code: String, message: String) -> CommandResponse {
    WorkflowCLIRendezvous.failure(code: code, message: message)
  }

  static func refusal(code: String, message: String) -> WorkflowCommandRefusal {
    WorkflowCommandRefusal(response: failure(code: code, message: message))
  }
}

extension WorkflowAdmissionEnvironment {
  /// The same environment with the panes of `sessions` marked busy.
  func busy(_ sessions: [WorkflowRunSession]) -> WorkflowAdmissionEnvironment {
    WorkflowAdmissionEnvironment(
      profiles: profiles,
      recommendation: recommendation,
      rememberedBinding: rememberedBinding,
      detectedAgent: detectedAgent,
      pendingDispatchID: pendingDispatchID,
      busySurfaceIDs: busySurfaceIDs.union(sessions.flatMap(\.boundSurfaceIDs)),
      worktree: worktree,
      branchName: branchName,
      makeLaunchPlan: makeLaunchPlan,
      bundledSkill: bundledSkill,
      now: now,
      makeRunID: makeRunID,
      makeToken: makeToken,
      limits: limits)
  }
}
