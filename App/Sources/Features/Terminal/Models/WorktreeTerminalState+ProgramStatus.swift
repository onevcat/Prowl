import Foundation

private let agentDetectionLogger = ProwlLogger("AgentDetection")

/// OSC 7501 program status inside the terminal owner (docs-ai 079 slice 2).
///
/// The record store belongs to the surface; the coordinator receives snapshots of
/// it. A report for a bound agent is pushed straight through the coordinator and
/// published in the same main-thread turn; a report for an unbound pane only wakes
/// the probe. `COMMAND_FINISHED` (OSC 133 D, from the shell) is exit evidence for
/// every agent: it wakes a cache-bypassing probe whose single miss releases the entry.
extension WorktreeTerminalState {
  /// What the fresh probe after a `COMMAND_FINISHED` found.
  enum CommandFinishedOutcome: Equatable {
    /// The same launch is still in the foreground (a nested shell's prompt returned,
    /// or an engine child was replaced under a live launcher): nothing changes.
    case sameOwner
    /// No agent: the entry is released and the live records that existed at the D go.
    case released
    /// A successor launch started before the probe ran: the finished owner's launch
    /// context is retired like a release, and only the predecessor's records go.
    case successor
  }

  static func commandFinishedOutcome(
    identified: IdentifiedAgentProcess?,
    previous: PaneAgentState,
    isLiveAncestor: (_ ancestor: pid_t, _ descendant: pid_t) -> Bool
  ) -> CommandFinishedOutcome {
    guard let identified else { return .released }
    guard previous.detectedAgent != nil, previous.launchProcessID != nil else { return .successor }
    let launch = PaneAgentState.retainedLaunchProcessID(
      identifiedLaunchProcessID: identified.launchProcessID,
      identifiedProcessID: identified.process.pid,
      previous: previous,
      isLiveAncestor: isLiveAncestor
    )
    return launch == previous.launchProcessID ? .sameOwner : .successor
  }

  /// The schedule after one tick: a verified producer's eligible root slows the loop
  /// to the delegated cadence; everything else is unchanged.
  static func nextSchedule(
    _ schedule: AgentDetectionSchedule, hasAgent: Bool, delegated: Bool, now: Date
  ) -> AgentDetectionSchedule {
    guard hasAgent else { return schedule.observedNoAgent(now: now) }
    return delegated ? schedule.observedDelegatedAgent(now: now) : schedule.observedAgent(now: now)
  }

  func handleProgramStatus(_ report: GhosttyProgramStatusReport, surfaceID: UUID, now: Date = Date()) {
    var store = programStatusStoresBySurface[surfaceID] ?? ProgramStatusRecordStore()
    store.apply(report, arrivedAt: now)
    programStatusStoresBySurface[surfaceID] = store
    // Retained for undo: the process keeps running and the protocol has no
    // heartbeat, so the store stays fed while publication is suppressed.
    guard surfaces[surfaceID] != nil else { return }
    guard let coordinator = agentDetectionCoordinators[surfaceID], coordinator.boundAgent != nil else {
      // Pi reports within 10 ms of the query echo, before the first probe ran.
      wakeAgentDetection(forSurfaceID: surfaceID)
      return
    }
    switch coordinator.receive(programStatus: store) {
    case .decision(let decision):
      publishDecision(surfaceID: surfaceID, decision: decision, now: now)
    case .withdrawn:
      // The last published state stands until an observe that starts now completes
      // with a fresh screen read and a fresh provider sample.
      wakeAgentDetection(forSurfaceID: surfaceID)
    case .none:
      break
    }
  }

  /// The shell's prompt returned (OSC 133 D). With a detected agent the probe is woken
  /// with its cache bypassed and the store waits for the probe's verdict; otherwise the
  /// protocol's new-prompt rule applies to the store at once.
  func noteCommandFinishedForAgentDetection(surfaceID: UUID) {
    let revision = programStatusStoresBySurface[surfaceID]?.revision ?? 0
    guard surfaces[surfaceID] != nil, surfaceAgentStates[surfaceID]?.detectedAgent != nil else {
      programStatusStoresBySurface[surfaceID]?.commandFinished(upTo: revision)
      return
    }
    pendingCommandFinishedBySurface[surfaceID] = PendingCommandFinished(storeRevision: revision)
    agentDetectionFreshProbeRequests.insert(surfaceID)
    wakeAgentDetection(forSurfaceID: surfaceID)
  }

  /// Applies the fresh probe's verdict to the store and, for a successor, retires the
  /// finished owner's launch context exactly as a release would.
  func applyCommandFinished(_ pending: PendingCommandFinished, identified: IdentifiedAgentProcess?, surfaceID: UUID) {
    let previous = surfaceAgentStates[surfaceID] ?? PaneAgentState()
    switch Self.commandFinishedOutcome(
      identified: identified, previous: previous, isLiveAncestor: Self.processIsLiveAncestor)
    {
    case .sameOwner:
      return
    case .successor:
      removeAgentEntryIfNeeded(surfaceID: surfaceID)
    case .released:
      break
    }
    programStatusStoresBySurface[surfaceID]?.commandFinished(upTo: pending.storeRevision)
  }

  /// Surfaces freed after the undo window, or closed for good.
  func dropProgramStatusStores(forSurfaceIDs surfaceIDs: [UUID]) {
    for surfaceID in surfaceIDs {
      programStatusStoresBySurface.removeValue(forKey: surfaceID)
      programStatusUnmappedAppsLoggedBySurface.removeValue(forKey: surfaceID)
    }
  }

  /// New producers show up in dogfooding logs: a root record whose `app` is not the
  /// bound agent's is reported once per surface and app.
  func logUnmappedProgramStatusAppIfNeeded(surfaceID: UUID, agent: DetectedAgent?) {
    guard let store = programStatusStoresBySurface[surfaceID], let root = store.root,
      let app = store.app(of: root), app != agent?.programStatusApp,
      programStatusUnmappedAppsLoggedBySurface[surfaceID]?.contains(app) != true
    else { return }
    programStatusUnmappedAppsLoggedBySurface[surfaceID, default: []].insert(app)
    logProgramStatus(
      "[ProgramStatus] surface=\(surfaceID.uuidString.prefix(8)) program status present,"
        + " app=\(app) unmapped (agent=\(agent?.rawValue ?? "none"))")
  }

  func logProgramStatus(_ message: String) {
    if let programStatusLogForTesting {
      programStatusLogForTesting(message)
    } else {
      agentDetectionLogger.debug(message)
    }
  }

  func makeAgentDetectionCoordinator(surfaceID: UUID) -> AgentDetectionCoordinator {
    if let programStatusSupportForTesting {
      return AgentDetectionCoordinator(surfaceID: surfaceID, support: programStatusSupportForTesting)
    }
    return AgentDetectionCoordinator(surfaceID: surfaceID)
  }

  // MARK: Publication

  /// The pushed half of `detectAgentState`'s tail: state, decision, seen flag, and
  /// `lastChangedAt` are merged into the current pane state; session, pid, launch
  /// observation, and profile metadata are untouched.
  func publishDecision(surfaceID: UUID, decision: AgentStateDecision, now: Date = Date()) {
    guard let previous = surfaceAgentStates[surfaceID], previous.detectedAgent != nil,
      let tabId = tabId(containing: surfaceID)
    else { return }
    var next = previous
    next.state = decision.state
    next.decision = decision
    next.seen = Self.resolvedSeen(previous: previous, decision: decision, isViewed: isViewedSurface(surfaceID))
    next.lastChangedAt = previous.state != decision.state ? now : previous.lastChangedAt
    commitAgentState(next, previous: previous, surfaceID: surfaceID, tabId: tabId)
  }

  func commitAgentState(_ next: PaneAgentState, previous: PaneAgentState, surfaceID: UUID, tabId: TerminalTabID) {
    guard next != previous else { return }
    surfaceAgentStates[surfaceID] = next
    updateTabAgentBusyState(for: tabId)
    emitAgentEntry(surfaceID: surfaceID, tabId: tabId, state: next)
  }

  /// Done is a completed turn the user has not looked at. Every legacy path earns it
  /// on a busy → idle transition; an OSC decision earns it only for `done` and
  /// `error`, because `idle` is sent at mount, on interrupt, and on a session reset.
  nonisolated static func resolvedSeen(previous: PaneAgentState, decision: AgentStateDecision, isViewed: Bool) -> Bool {
    if isViewed { return true }
    guard previous.state == .working || previous.state == .blocked, decision.state == .idle else {
      return previous.seen
    }
    if case .programStatus(let reason) = decision.reason, !reason.earnsDoneBadge {
      return previous.seen
    }
    return false
  }

  // MARK: Wake

  /// Ends the loop's current sleep, or marks the wake so the next sleep is skipped
  /// when the loop is mid-tick.
  func interruptAgentDetectionSleep(forSurfaceID surfaceID: UUID) {
    if let sleeper = agentDetectionSleepersBySurface.removeValue(forKey: surfaceID) {
      sleeper.cancel()
    } else if agentDetectionTasks[surfaceID] != nil {
      agentDetectionWakeRequests.insert(surfaceID)
    }
  }

  /// The loop's interruptible sleep. Cancellation of the loop cancels the sleeper too.
  func sleepAgentDetection(forSurfaceID surfaceID: UUID, interval: Duration) async {
    if agentDetectionWakeRequests.remove(surfaceID) != nil { return }
    let sleeper = Task { try await Task.sleep(for: interval) }
    agentDetectionSleepersBySurface[surfaceID] = sleeper
    await withTaskCancellationHandler {
      _ = try? await sleeper.value
    } onCancel: {
      sleeper.cancel()
    }
    agentDetectionSleepersBySurface.removeValue(forKey: surfaceID)
  }

  func clearAgentDetectionWakeState(forSurfaceID surfaceID: UUID) {
    agentDetectionSleepersBySurface.removeValue(forKey: surfaceID)?.cancel()
    agentDetectionWakeRequests.remove(surfaceID)
    agentDetectionFreshProbeRequests.remove(surfaceID)
    pendingCommandFinishedBySurface.removeValue(forKey: surfaceID)
  }

  func probeForegroundJob(processGroupID: pid_t?, childPID: pid_t?, fresh: Bool) async -> ForegroundJob? {
    if let agentProcessProbeForTesting {
      return await agentProcessProbeForTesting(processGroupID, childPID, fresh)
    }
    return await AgentProcessProbe.shared.foregroundJob(
      processGroupID: processGroupID, childPID: childPID, bypassingCache: fresh)
  }
}
