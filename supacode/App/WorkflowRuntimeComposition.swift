// supacode/App/WorkflowRuntimeComposition.swift
// The live boundaries of the workflow runner (docs-ai 063 B3): the activation bridge over the
// dispatch store, the idle wait built on the #733 evidence rules, the profile launch with
// child-only workflow environment, the per-activation watchdog sources, admission facts, and the
// CLI coordinator. Nothing here holds run state; the reducer does.

import ComposableArchitecture
import Foundation

/// Lets the responder dependency (installed before the store exists) reach the coordinator that
/// is built with the CLI router.
@MainActor
final class WorkflowCoordinatorBox {
  var coordinator: WorkflowRuntimeCoordinator?
}

/// Panes a workflow launch created but the reducer has not bound yet (dsl-spec §10: one run per
/// pane). A launch without `expect` opens no dispatch record, so between surface creation and
/// the reducer's `.launched` nothing else would keep admission from binding that pane.
@MainActor
final class WorkflowPaneReservations {
  private var surfaceIDs: Set<UUID> = []

  func reserve(_ surfaceID: UUID) {
    surfaceIDs.insert(surfaceID)
  }

  func release(_ surfaceID: UUID) {
    surfaceIDs.remove(surfaceID)
  }

  /// Reservations still worth honoring: the pane exists and no run — live, ended, or relaunched
  /// away from it — has ever bound it (a pane a finished run kept is free again).
  func pending(everBound: Set<UUID>, isLive: (UUID) -> Bool) -> Set<UUID> {
    surfaceIDs = surfaceIDs.filter { !everBound.contains($0) && isLive($0) }
    return surfaceIDs
  }

  /// The reservations admission still honors, pruned against every pane a run ever owned —
  /// a relaunch's old pane included, so a reservation ends the moment its launch was taken up.
  func pending(for workflowRuns: WorkflowRunsFeature.State, isLive: (UUID) -> Bool) -> Set<UUID> {
    pending(everBound: Set(workflowRuns.paneOwners.keys), isLive: isLive)
  }
}

/// Everything the app installs for the workflow runner at its composition root.
struct WorkflowRuntimeInstallation {
  let coordinatorBox: WorkflowCoordinatorBox
  let reservations: WorkflowPaneReservations
  let activation: WorkflowActivationClient
  let runtime: WorkflowRuntimeClient
  let watchdog: WorkflowWatchdogClient
  let queue: WorkflowEffectQueueClient
  let responder: WorkflowCLIResponderClient
  let start: WorkflowStartClient
  let settings: WorkflowSettingsClient

  func install(into values: inout DependencyValues) {
    values.workflowActivationClient = activation
    values.workflowRuntimeClient = runtime
    values.workflowWatchdogClient = watchdog
    values.workflowEffectQueue = queue
    values.workflowCLIResponder = responder
    values.workflowStartClient = start
    values[WorkflowSettingsClient.self] = settings
  }
}

extension SupacodeApp {
  private static let workflowLogger = SupaLogger("Workflow")

  @MainActor
  static func makeWorkflowRuntime(
    terminalManager: WorktreeTerminalManager,
    storeBox: SupacodeAppStoreBox
  ) -> WorkflowRuntimeInstallation {
    let bridge = makeWorkflowActivationBridge(terminalManager: terminalManager, storeBox: storeBox)
    let coordinatorBox = WorkflowCoordinatorBox()
    let reservations = WorkflowPaneReservations()
    return WorkflowRuntimeInstallation(
      coordinatorBox: coordinatorBox,
      reservations: reservations,
      activation: makeWorkflowActivationClient(bridge: bridge),
      runtime: makeWorkflowRuntimeClient(
        terminalManager: terminalManager, storeBox: storeBox, reservations: reservations),
      watchdog: makeWorkflowWatchdogClient(
        terminalManager: terminalManager, activationBridge: bridge, storeBox: storeBox),
      queue: WorkflowEffectQueue().client,
      responder: WorkflowCLIResponderClient(respond: { requestID, resolution in
        coordinatorBox.coordinator?.resolve(requestID, resolution)
      }),
      start: makeWorkflowStartClient(
        terminalManager: terminalManager, storeBox: storeBox,
        coordinatorBox: coordinatorBox, reservations: reservations),
      settings: makeWorkflowSettingsClient(terminalManager: terminalManager, storeBox: storeBox)
    )
  }

  // MARK: - Activation bridge

  @MainActor
  static func makeWorkflowActivationBridge(
    terminalManager: WorktreeTerminalManager,
    storeBox: SupacodeAppStoreBox
  ) -> LiveWorkflowActivationBridge {
    LiveWorkflowActivationBridge(terminalManager: terminalManager) { surfaceID in
      guard let appStore = storeBox.store else { return nil }
      let resolver = makeTargetResolver(appStore: appStore, terminalManager: terminalManager)
      guard case .success(let target) = resolver.resolve(.pane(surfaceID.uuidString)) else {
        return nil
      }
      return TabResolvedTarget(from: target)
    }
  }

  @MainActor
  static func makeWorkflowActivationClient(bridge: LiveWorkflowActivationBridge)
    -> WorkflowActivationClient
  {
    WorkflowActivationClient(
      openMessage: { bridge.openMessageActivation(surfaceID: $0) },
      cancel: { bridge.cancelActivation(dispatchID: $0) },
      abandon: { bridge.abandonActivation(dispatchID: $0, reason: $1) },
      complete: { bridge.completeActivation(dispatchID: $0, summary: $1) },
      observe: { bridge.observeActivation(dispatchID: $0) }
    )
  }

  // MARK: - Evidence

  /// The same view of a pane `agents wait` and `agents dispatch` use (docs-ai 064.012/014).
  @MainActor
  static func makeWorkflowConditionSnapshot(
    surfaceID: UUID,
    terminalManager: WorktreeTerminalManager,
    storeBox: SupacodeAppStoreBox
  ) -> AgentConditionSnapshot {
    let observed = terminalManager.agentObservationSnapshot(surfaceID: surfaceID)
    let agent = storeBox.store?.state.repositories.activeAgents.entries.first {
      $0.surfaceID == surfaceID
    }
    let evidence = terminalManager.currentAgentSignalEvidence(surfaceID: surfaceID)
    return AgentConditionSnapshot(
      agent: agent,
      signal: evidence.activeTerminal,
      changedSignal: evidence.latest,
      revision: observed?.revision ?? 0,
      isLive: terminalManager.isSurfaceLive(surfaceID),
      signals: terminalManager.agentSignalsPayload(surfaceID: surfaceID)
    )
  }

  // MARK: - Watchdog

  @MainActor
  static func makeWorkflowWatchdogClient(
    terminalManager: WorktreeTerminalManager,
    activationBridge: LiveWorkflowActivationBridge,
    storeBox: SupacodeAppStoreBox
  ) -> WorkflowWatchdogClient {
    WorkflowWatchdogClient(arm: { _, request in
      let sources = WorkflowWatchdog.Sources(
        observeAgent: { terminalManager.observeAgentState(surfaceID: request.surfaceID) },
        observeDispatch: {
          request.dispatchID.flatMap { activationBridge.observeActivation(dispatchID: $0) }
        },
        snapshot: {
          WorkflowWatchdog.snapshot(
            from: makeWorkflowConditionSnapshot(
              surfaceID: request.surfaceID, terminalManager: terminalManager, storeBox: storeBox))
        }
      )
      let watchdog = WorkflowWatchdog(
        request: request, settings: WorkflowWatchdogSettings(), sources: sources)
      return WorkflowWatchdogHandle(verdicts: watchdog.start(), cancel: { watchdog.cancel() })
    })
  }

  // MARK: - Runtime

  /// How long a pane without a detected agent may take to show one before the idle wait gives up
  /// (the CLI wait's appearance grace), and how long a heuristic `blocked` must persist (the
  /// watchdog's blocked grace).
  nonisolated static let workflowRoleWaitPollMilliseconds = 250
  nonisolated static let workflowRoleWaitAppearanceMilliseconds = 10_000
  nonisolated static let workflowRoleWaitBlockedMilliseconds = 30_000

  @MainActor
  static func makeWorkflowRuntimeClient(
    terminalManager: WorktreeTerminalManager,
    storeBox: SupacodeAppStoreBox,
    reservations: WorkflowPaneReservations = WorkflowPaneReservations()
  ) -> WorkflowRuntimeClient {
    WorkflowRuntimeClient(
      waitForRole: { surfaceID in
        await waitForWorkflowRole(
          surfaceID: surfaceID, terminalManager: terminalManager, storeBox: storeBox)
      },
      deliverLine: { worktree, surfaceID, line, isLive in
        guard let state = terminalManager.stateIfExists(for: worktree.id) else {
          return .insertFailed
        }
        // Same main-actor turn as the insertion: a fence raised by a cancel cannot slip in between.
        guard isLive() else { return .stale }
        guard state.insertCommittedText(line, in: surfaceID) else { return .insertFailed }
        return state.submitLine(in: surfaceID) ? .delivered : .submitFailed
      },
      launch: { worktree, frozenPlan, request in
        await launchWorkflowRole(
          worktree: worktree, frozenPlan: frozenPlan, request: request,
          boundary: WorkflowLaunchBoundary(
            terminalManager: terminalManager, storeBox: storeBox, reservations: reservations))
      },
      close: { worktree, surfaceID, runID in
        // Same main-actor turn as the close: a run that ended no longer counts as busy at
        // admission, so a later run may have bound the pane — and kept it when it ended.
        if let owner = storeBox.store?.state.workflowRuns.paneOwners[surfaceID], owner != runID {
          workflowLogger.warning(
            "[Workflow] Run \(runID) left pane \(surfaceID) open: workflow run \(owner) bound it since.")
          return false
        }
        return terminalManager.stateIfExists(for: worktree.id)?.closeSurface(
          id: surfaceID, confirmation: .skip) ?? false
      },
      notify: { worktree, notification in
        workflowLogger.notice("[\(worktree.name)] \(notification.title): \(notification.body)")
        let state = terminalManager.stateIfExists(for: worktree.id)
        let requestedSurface = notification.targetSurfaceID.flatMap { surfaceID in
          terminalManager.isSurfaceLive(surfaceID) ? surfaceID : nil
        }
        let fallbackSurface = state?.tabManager.selectedTabId.flatMap { state?.activeSurfaceID(for: $0) }
        if let surfaceID = requestedSurface ?? fallbackSurface, let state {
          state.appendNotification(
            title: notification.title,
            body: notification.body,
            surfaceId: surfaceID,
            treatAsViewedWhenWorktreeIsVisible: notification.treatAsViewedWhenWorktreeIsVisible
          )
          return
        }
        guard let appStore = storeBox.store else { return }
        let settings = appStore.state.settings
        let isViewed = notification.treatAsViewedWhenWorktreeIsVisible && state?.isViewingWorktree() == true
        guard !(settings.muteNotificationsForActiveSurface && isViewed), settings.systemNotificationsEnabled else {
          return
        }
        @Dependency(SystemNotificationClient.self) var notifications
        Task { @MainActor in
          await notifications.send(
            notification.title,
            notification.body,
            worktree.id,
            notification.targetSurfaceID
          )
        }
      }
    )
  }

  /// The #733 idle precondition without its five-second cap (docs-ai 063.007, "What B3 must do
  /// with each effect"), decided by `WorkflowRoleWaitPolicy` against the baseline captured when
  /// the wait started: a fresh exact `turn-ended` ends it at once, a detector-only idle view must
  /// stay stable for two seconds, `working` keeps waiting, an exact `needs-input` or a heuristic
  /// `blocked` that persists for the blocked grace ends the wait as blocked, and a pane that holds
  /// someone else's pending dispatch record ends it as `dispatchPending`.
  @MainActor
  private static func waitForWorkflowRole(
    surfaceID: UUID,
    terminalManager: WorktreeTerminalManager,
    storeBox: SupacodeAppStoreBox
  ) async -> WorkflowRoleWaitOutcome {
    let clock = ContinuousClock()
    var elapsed = 0
    var policy = WorkflowRoleWaitPolicy(
      blockedGraceMilliseconds: workflowRoleWaitBlockedMilliseconds,
      appearanceGraceMilliseconds: workflowRoleWaitAppearanceMilliseconds)
    while !Task.isCancelled {
      let snapshot = makeWorkflowConditionSnapshot(
        surfaceID: surfaceID, terminalManager: terminalManager, storeBox: storeBox)
      let pending = terminalManager.pendingAgentDispatchSnapshot(surfaceID: surfaceID)?.record.id
      if let outcome = policy.observe(snapshot, pendingDispatchID: pending, elapsedMilliseconds: elapsed) {
        return outcome
      }
      do {
        try await clock.sleep(for: .milliseconds(workflowRoleWaitPollMilliseconds))
      } catch {
        return .cancelled
      }
      elapsed += workflowRoleWaitPollMilliseconds
    }
    return .cancelled
  }

  /// A2's plan → prepare → launch sequence for a `launch` role: the dispatch record is issued
  /// first (when the step expects a delivery), the frozen plan is prepared with its placeholder
  /// prompt, the rendered kickoff prompt and the child-only `PROWL_WORKFLOW_*` values are attached
  /// after preflight (like `attachingDispatch`), and the record is bound to the new pane. Every
  /// failure after a step rolls the earlier ones back: the issuance is cancelled and the pane closed.
  @MainActor
  private static func launchWorkflowRole(
    worktree: Worktree,
    frozenPlan: AgentProfileLaunchPlan,
    request: WorkflowLaunchRequest,
    boundary: WorkflowLaunchBoundary
  ) async -> Result<WorkflowLaunchResult, WorkflowLaunchError> {
    let (terminalManager, storeBox, reservations) = (boundary.terminalManager, boundary.storeBox, boundary.reservations)
    var dispatchID: String?
    if request.expectsDelivery {
      do {
        dispatchID = try terminalManager.issueAgentDispatch().record.id
      } catch {
        return .failure(.failed("the launch activation could not be issued: \(error)"))
      }
    }
    func rollback(closing surfaceID: UUID?) {
      if let dispatchID { terminalManager.cancelAgentDispatchIssuance(dispatchID: dispatchID) }
      if let surfaceID {
        reservations.release(surfaceID)
        _ = terminalManager.stateIfExists(for: worktree.id)?.closeSurface(
          id: surfaceID, confirmation: .skip)
      }
    }
    let attached: PreparedAgentProfileLaunch
    let prepared = await prepareWorkflowLaunch(
      worktree: worktree, frozenPlan: frozenPlan, request: request, terminalManager: terminalManager)
    switch prepared {
    case .failure(let error):
      rollback(closing: nil)
      return .failure(error)
    case .success(let value):
      attached = value
    }
    let launched: LaunchedSurface
    switch terminalManager.launchPreparedAgentProfile(attached, in: worktree) {
    case .failure(let error):
      rollback(closing: nil)
      return .failure(.failed("the profile could not be launched: \(error)"))
    case .success(let value):
      launched = value
    }
    // Reserved until the reducer binds the pane (or a later admission finds it bound / gone).
    reservations.reserve(launched.surfaceID)
    guard let appStore = storeBox.store else {
      rollback(closing: launched.surfaceID)
      return .failure(.failed("the app store is unavailable"))
    }
    let resolver = makeTargetResolver(appStore: appStore, terminalManager: terminalManager)
    guard case .success(let target) = resolver.resolve(.pane(launched.surfaceID.uuidString)) else {
      rollback(closing: launched.surfaceID)
      return .failure(.failed("the launched pane could not be resolved"))
    }
    if let dispatchID {
      do {
        try terminalManager.bindAgentDispatch(
          dispatchID: dispatchID, target: TabResolvedTarget(from: target))
      } catch {
        rollback(closing: launched.surfaceID)
        return .failure(.failed("the launch activation could not be bound: \(error)"))
      }
    }
    if !request.background {
      selectCLIWorktreeContext(
        worktreeID: worktree.id, appStore: appStore, terminalManager: terminalManager)
      terminalManager.state(for: worktree).selectTab(launched.tabID)
    }
    let snapshot = TargetResolutionSnapshotBuilder.makeSnapshot(
      repositoriesState: appStore.state.repositories,
      terminalManager: terminalManager
    )
    let handle = snapshot.worktrees.flatMap(\.tabs).flatMap(\.panes).first {
      $0.id == launched.surfaceID
    }?.handle
    return .success(
      WorkflowLaunchResult(
        pane: WorkflowPaneIdentity(
          surfaceID: launched.surfaceID,
          tabID: launched.tabID.rawValue,
          handle: handle.map { "p\($0)" } ?? launched.surfaceID.uuidString,
          displayName: request.profile.name,
          agent: request.profile.agent),
        dispatchID: dispatchID))
  }

  /// Placement, A2 preflight with the placeholder prompt, then the kickoff prompt and the
  /// `PROWL_WORKFLOW_*` carriers attached to the prepared plan.
  @MainActor
  private static func prepareWorkflowLaunch(
    worktree: Worktree,
    frozenPlan: AgentProfileLaunchPlan,
    request: WorkflowLaunchRequest,
    terminalManager: WorktreeTerminalManager
  ) async -> Result<PreparedAgentProfileLaunch, WorkflowLaunchError> {
    let placement: AgentProfileLaunchRequest.Placement
    switch request.placement {
    case .tab:
      placement = .tab(background: request.background)
    case .split:
      placement = .split(
        anchor: request.anchorSurfaceID,
        direction: splitDirection(request.direction),
        background: request.background
      )
    }
    let launchRequest = AgentProfileLaunchRequest(
      plan: frozenPlan,
      placement: placement,
      workingDirectoryOverride: worktree.workingDirectory,
      inheritanceAnchor: request.anchorSurfaceID,
      title: request.profile.name
    )
    let preparation: PreparedAgentProfileLaunch
    switch await terminalManager.prepareAgentProfileLaunch(launchRequest, in: worktree) {
    case .failure(let error):
      return .failure(.failed("the profile launch could not be prepared: \(error)"))
    case .success(let value):
      preparation = value
    }
    let attachedPlan: AgentProfileLaunchPlan
    do {
      attachedPlan = try preparation.context.request.plan.attachingWorkflow(
        prompt: request.prompt, environment: request.environment)
    } catch {
      return .failure(.failed("the kickoff prompt could not be attached: \(error)"))
    }
    let attached = PreparedAgentProfileLaunch(
      context: FrozenAgentProfileLaunchContext(
        request: AgentProfileLaunchRequest(
          plan: attachedPlan,
          placement: preparation.context.request.placement,
          workingDirectoryOverride: preparation.context.request.workingDirectoryOverride,
          inheritanceAnchor: preparation.context.request.inheritanceAnchor,
          title: preparation.context.request.title),
        inheritedCWD: preparation.context.inheritedCWD,
        anchorSurfaceID: preparation.context.anchorSurfaceID,
        tracksFocusedAnchor: preparation.context.tracksFocusedAnchor,
        tracksInheritedCWD: preparation.context.tracksInheritedCWD),
      warnings: preparation.warnings)
    return .success(attached)
  }

  nonisolated private static func splitDirection(_ direction: WorkflowSplitDirection)
    -> UserCustomSplitDirection
  {
    switch direction {
    case .right: .right
    case .left: .left
    case .top: .top
    case .down: .down
    }
  }

  // MARK: - Admission and coordination

  @MainActor
  static func makeWorkflowAdmissionEnvironment(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager,
    reservations: WorkflowPaneReservations
  ) -> WorkflowAdmissionEnvironment {
    @Shared(.userGlobalSettings) var settings
    let profiles = settings.agentProfiles
    let bundledSkills =
      Bundle.main.resourceURL.flatMap { try? ProwlSkills.bundled(resourcesURL: $0) } ?? []
    return WorkflowAdmissionEnvironment(
      profiles: profiles,
      recommendation: { repositoryRootURL in
        @Shared(.userRepositorySettings(repositoryRootURL)) var repositorySettings
        return (
          repositorySettings.defaultAgentProfileID, repositorySettings.lastLaunchedAgentProfileID
        )
      },
      rememberedBinding: { key in
        @Shared(.userGlobalSettings) var settings
        return settings.rememberedWorkflowBinding(for: key)
      },
      detectedAgent: { surfaceID in
        appStore.state.repositories.activeAgents.entries.first { $0.surfaceID == surfaceID }.map {
          WorkflowDetectedAgent(token: $0.agent.rawValue, displayName: $0.agent.displayName)
        }
      },
      pendingDispatchID: { surfaceID in
        terminalManager.pendingAgentDispatchSnapshot(surfaceID: surfaceID)?.record.id
      },
      busySurfaceIDs: reservations.pending(
        for: appStore.state.workflowRuns, isLive: { terminalManager.isSurfaceLive($0) }),
      worktree: { id in
        resolveCLITerminalWorktree(
          id: id, repositories: Array(appStore.state.repositories.repositories))
      },
      branchName: { worktree in
        WorktreeBranchReader.branchName(of: worktree.workingDirectory) ?? worktree.name
      },
      makeLaunchPlan: { profile in
        try AgentProfileLaunchPlanner.plan(
          for: profile,
          intent: .prompt(WorkflowRunAdmissionPlaceholder.prompt),
          homeBaseDirectory: SupacodePaths.agentProfileHomesDirectory)
      },
      bundledSkill: { id in bundledSkills.first { $0.id == id } }
    )
  }

  @MainActor
  static func makeWorkflowCoordinator(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager,
    rendezvous: WorkflowCLIRendezvous,
    reservations: WorkflowPaneReservations
  ) -> WorkflowRuntimeCoordinator {
    WorkflowRuntimeCoordinator(
      dependencies: WorkflowRuntimeCoordinator.Dependencies(
        admissionEnvironment: {
          makeWorkflowAdmissionEnvironment(
            appStore: appStore, terminalManager: terminalManager, reservations: reservations)
        },
        sessions: { Array(appStore.state.workflowRuns.sessions.values) },
        send: { appStore.send(.workflowRuns($0)) },
        pendingDispatchID: {
          terminalManager.pendingAgentDispatchSnapshot(surfaceID: $0)?.record.id
        },
        worktreeRoots: {
          workflowRunRoots(of: Array(appStore.state.repositories.repositories)).map {
            URL(filePath: $0, directoryHint: .isDirectory)
          }
        },
        rendezvous: rendezvous
      ))
  }

  /// The `WORKFLOW_DELIVERY_REQUIRED` refusal of `agents dispatch-complete` for a pane whose
  /// pending record is a workflow activation (decision W3), live or already ended.
  @MainActor
  static func workflowDeliveryRefusal(
    surfaceID: UUID,
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> CommandError? {
    guard let dispatchID = terminalManager.pendingAgentDispatchSnapshot(surfaceID: surfaceID)?.record.id else {
      return nil
    }
    return WorkflowRuntimeCoordinator.deliveryRefusal(
      dispatchID: dispatchID, sessions: Array(appStore.state.workflowRuns.sessions.values))
  }
}

/// The app objects a workflow launch touches.
@MainActor
struct WorkflowLaunchBoundary {
  let terminalManager: WorktreeTerminalManager
  let storeBox: SupacodeAppStoreBox
  let reservations: WorkflowPaneReservations
}

/// The prompt a frozen `launch` plan is compiled with; `attachingWorkflow` replaces it at launch.
nonisolated enum WorkflowRunAdmissionPlaceholder {
  static let prompt = "[Prowl workflow kickoff]"
}

/// `git symbolic-ref --short HEAD` of a worktree, synchronously and cheaply; nil outside Git.
nonisolated enum WorktreeBranchReader {
  static func branchName(of worktree: URL) -> String? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = [
      "-C", worktree.path(percentEncoded: false), "symbolic-ref", "--short", "-q", "HEAD",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    guard let branch = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !branch.isEmpty
    else { return nil }
    return branch
  }
}
