import Foundation
import Observation
import ProwlCLIShared
import Sharing
import SwiftUI

private let terminalLogger = SupaLogger("Terminal")
private let layoutRestoreFailureMessage = "Saved terminal layout was invalid and has been reset"

@MainActor
@Observable
final class WorktreeTerminalManager {
  private let runtime: GhosttyRuntime?
  private let layoutPersistence: TerminalLayoutPersistenceClient
  private let skipsSurfaceCreationForTesting: Bool
  private let targetHandleRegistry = TerminalTargetHandleRegistry()
  @ObservationIgnored private let agentObservationStore: AgentObservationStore
  @ObservationIgnored private let agentDispatchStore: AgentDispatchStore
  @ObservationIgnored private let codexConfigReadProcess: CodexConfigReadProcess
  @ObservationIgnored private let codexShellEnvironmentResolver:
    @Sendable (URL, String?) async -> CodexShellLaunchEnvironment?
  @ObservationIgnored private let hookResourcesProvider: @MainActor () -> AgentHookResources?
  @ObservationIgnored private let forwardingRecordBaseDirectory: URL
  @ObservationIgnored private var codexForwardingRecordStore: CodexForwardingRecordStore?
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  private var notificationsEnabled = true
  private var commandFinishedNotificationEnabled = true
  private var commandFinishedNotificationThreshold = 10
  private var preferredFontSize: Float32?
  private let baselineFontSize: Float32
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  private var eventCoalescer = TerminalEventCoalescer()
  /// Caps the live stream and the pre-subscription backlog so a producer that
  /// outruns the single main-actor consumer can't grow memory without bound.
  private static let eventBufferCap = 2048
  private static let pendingEventCap = 1024
  var selectedWorktreeID: Worktree.ID?
  /// The worktree+tab focused in Canvas, updated by CanvasView on card tap.
  /// Used by toggleCanvas to know which worktree to return to.
  var canvasFocusedWorktreeID: Worktree.ID?

  init(
    runtime: GhosttyRuntime,
    preferredFontSize: Float32? = nil,
    layoutPersistence: TerminalLayoutPersistenceClient = .liveValue,
    agentObservationBufferCapacity: Int = 64,
    agentDispatchStore: AgentDispatchStore = AgentDispatchStore(),
    codexConfigReadProcess: CodexConfigReadProcess = CodexConfigReadProcess(),
    codexShellEnvironmentResolver: @escaping @Sendable (URL, String?) async -> CodexShellLaunchEnvironment? = {
      await CodexShellLaunchEnvironmentProbe.resolve(cwd: $0, pathOverride: $1)
    },
    hookResourcesProvider: @escaping @MainActor () -> AgentHookResources? = {
      guard let url = SupacodePaths.bundledCLIURL else { return nil }
      return AgentHookResources(
        bundledCLIPath: url.path(percentEncoded: false),
        socketPath: ProwlSocket.defaultPath,
        copilotPluginPath: SupacodePaths.bundledCopilotHookPluginURL?.path(percentEncoded: false),
        piExtensionPath: SupacodePaths.bundledPiHookExtensionURL?.path(percentEncoded: false),
        ompExtensionPath: SupacodePaths.bundledOMPHookExtensionURL?.path(percentEncoded: false),
        opencodePluginPath: SupacodePaths.bundledOpenCodeHookPluginURL?.path(percentEncoded: false)
      )
    },
    forwardingRecordBaseDirectory: URL = SupacodePaths.agentHookForwardingDirectory,
    skipsSurfaceCreationForTesting: Bool = false
  ) {
    self.runtime = runtime
    self.layoutPersistence = layoutPersistence
    self.skipsSurfaceCreationForTesting = skipsSurfaceCreationForTesting
    self.preferredFontSize = preferredFontSize
    self.agentObservationStore = AgentObservationStore(bufferCapacity: agentObservationBufferCapacity)
    self.agentDispatchStore = agentDispatchStore
    self.codexConfigReadProcess = codexConfigReadProcess
    self.codexShellEnvironmentResolver = codexShellEnvironmentResolver
    self.hookResourcesProvider = hookResourcesProvider
    self.forwardingRecordBaseDirectory = forwardingRecordBaseDirectory
    baselineFontSize = runtime.defaultFontSize()
  }

  func handleCommand(_ command: TerminalClient.Command) {
    if handleTabCommand(command) {
      return
    }
    if handleBindingActionCommand(command) {
      return
    }
    if handleSearchCommand(command) {
      return
    }
    handleManagementCommand(command)
  }

  /// Creates a tab at an explicit directory and returns its ID for immediate Canvas selection.
  func createTabInDirectory(_ worktree: Worktree, directory: URL) -> TerminalTabID? {
    createTabAsync(in: worktree, runSetupScriptIfNew: false, workingDirectory: directory)
  }

  /// Synchronous launch boundary used by the CLI and workflow runner. Menu and
  /// palette launch events remain owned by the compatibility command below.
  func launchAgentProfile(
    _ request: AgentProfileLaunchRequest,
    in worktree: Worktree
  ) -> Result<LaunchedSurface, AgentProfileLaunchError> {
    state(for: worktree).launchAgentProfile(request)
  }

  func prepareAgentProfileLaunch(
    _ request: AgentProfileLaunchRequest,
    in worktree: Worktree
  ) async -> Result<PreparedAgentProfileLaunch, AgentProfileLaunchError> {
    let terminalState = state(for: worktree)
    guard terminalState.provisionAgentProfileHome(for: request.plan) else {
      return .failure(.homeProvisioningFailed)
    }
    var latestContext: FrozenAgentProfileLaunchContext?
    for attempt in 0..<2 {
      let context: FrozenAgentProfileLaunchContext
      switch terminalState.freezeAgentProfileLaunchContext(request) {
      case .success(let value): context = value
      case .failure(let error): return .failure(error)
      }
      latestContext = context
      let resources = hookResourcesProvider()
      let codexShellEnvironment: CodexShellLaunchEnvironment?
      if context.request.plan.runtime == .codex, resources != nil {
        codexShellEnvironment = await codexShellEnvironmentResolver(
          context.inheritedCWD,
          context.request.plan.profileEnvironmentOverrides["PATH"]
        )
      } else {
        codexShellEnvironment = nil
      }
      guard !Task.isCancelled else { return .failure(.preparationCancelled) }
      let preparation = await AgentManagedHookPreparer.prepare(
        plan: context.request.plan,
        inheritedCWD: context.inheritedCWD,
        resources: resources,
        codexShellEnvironment: codexShellEnvironment,
        codexConfigReadProcess: codexConfigReadProcess,
        droidSettingsEnvironmentResolver: { cwd, pathOverride in
          await DroidSettingsEnvironmentProbe.resolve(cwd: cwd, pathOverride: pathOverride)
        },
        openCodeEnvironmentResolver: { cwd, pathOverride in
          await ShellEnvironmentProbe.resolve(
            variables: OpenCodeHookPluginPreparer.environmentVariableNames,
            cwd: cwd,
            pathOverride: pathOverride
          )
        }
      )
      guard !Task.isCancelled else { return .failure(.preparationCancelled) }
      guard terminalState.isAgentProfileLaunchContextValid(context) else {
        if attempt == 0 { continue }
        let warning = LifecycleCommandWarning(
          code: .managedHookDegraded,
          runtime: request.plan.runtime.rawValue,
          message: "The launch target changed during managed hook preparation."
        )
        return .success(PreparedAgentProfileLaunch(context: context, warnings: [warning]))
      }
      return applyManagedHook(preparation, context: context, resources: resources)
    }
    guard let latestContext else { return .failure(.tabCreationFailed) }
    return .success(PreparedAgentProfileLaunch(context: latestContext, warnings: []))
  }

  /// Turn a completed hook preparation into an execution-ready launch context: materialize
  /// any private files, patch the plan, and keep every failure path fail-open for the user's
  /// launch. Any file already exposed to no child is discarded before returning.
  private func applyManagedHook(
    _ preparation: AgentManagedHookPreparation,
    context: FrozenAgentProfileLaunchContext,
    resources: AgentHookResources?
  ) -> Result<PreparedAgentProfileLaunch, AgentProfileLaunchError> {
    let runtimeRawValue = context.request.plan.runtime.rawValue
    func degraded(_ message: String) -> Result<PreparedAgentProfileLaunch, AgentProfileLaunchError> {
      .success(
        PreparedAgentProfileLaunch(
          context: context,
          warnings: [
            LifecycleCommandWarning(
              code: .managedHookDegraded,
              runtime: runtimeRawValue,
              message: message
            )
          ]
        )
      )
    }

    // Droid's merged settings arrive as data because only this actor owns the owner-only
    // store. Write it first, then render the argv against the resulting path.
    let settingsFile = writePendingHookSettingsFile(preparation.pendingSettingsFile)
    if preparation.pendingSettingsFile != nil, settingsFile == nil {
      return degraded("The managed hook settings file could not be created.")
    }
    var privateFiles = [settingsFile?.record].compactMap { $0 }
    func discardPrivateFiles() {
      for file in privateFiles { codexForwardingRecordStore?.discardUnexposed(file) }
    }

    guard let capability = preparation.capability,
      let preparedInvocation = settingsFile?.prepared ?? preparation.preparedInvocation,
      let resources
    else {
      discardPrivateFiles()
      return .success(
        PreparedAgentProfileLaunch(
          context: context,
          warnings: preparation.warning.map { [$0] } ?? []
        )
      )
    }

    if let argv = preparation.forwardingArgv {
      guard let store = forwardingRecordStore(),
        let record = try? store.create(argv: argv)
      else {
        discardPrivateFiles()
        return degraded("The existing Codex notifier could not be preserved safely.")
      }
      privateFiles.append(record)
    }
    if Task.isCancelled {
      discardPrivateFiles()
      return .failure(.preparationCancelled)
    }

    let executionPlan = context.request.plan.applyingManagedHook(
      preparedInvocation,
      resources: resources,
      launchCWD: preparation.launchCWD,
      token: UUID().uuidString,
      nativeEvents: capability.nativeEvents,
      coveredEvents: capability.coveredEvents,
      forwardingRecord: privateFiles.last
    )
    let preparedContext = FrozenAgentProfileLaunchContext(
      request: AgentProfileLaunchRequest(
        plan: executionPlan,
        placement: context.request.placement,
        workingDirectoryOverride: context.request.workingDirectoryOverride,
        inheritanceAnchor: context.request.inheritanceAnchor,
        title: context.request.title
      ),
      inheritedCWD: context.inheritedCWD,
      anchorSurfaceID: context.anchorSurfaceID,
      tracksFocusedAnchor: context.tracksFocusedAnchor,
      tracksInheritedCWD: context.tracksInheritedCWD
    )
    return .success(
      PreparedAgentProfileLaunch(
        context: preparedContext,
        warnings: preparation.warning.map { [$0] } ?? []
      )
    )
  }

  /// Materialize a runtime's merged hook settings into the owner-only store and render the
  /// argv that names it. Returns `nil` only when the file could not be created.
  private func writePendingHookSettingsFile(
    _ pending: PendingManagedHookSettingsFile?
  ) -> (record: CodexForwardingRecord, prepared: AgentHookPreparedInvocation)? {
    guard let pending,
      let store = forwardingRecordStore(),
      let record = try? store.createPrivateFile(pending.data)
    else { return nil }
    return (
      record,
      DroidHookSettingsPreparer.applying(
        settingsPath: record.locator,
        invocation: pending.invocation,
        promptArgumentIndex: pending.promptArgumentIndex
      )
    )
  }

  func discardPreparedAgentProfileLaunch(_ preparation: PreparedAgentProfileLaunch) {
    guard let record = preparation.context.request.plan.hookRegistration?.forwardingRecord else { return }
    codexForwardingRecordStore?.discardUnexposed(record)
  }

  func launchPreparedAgentProfile(
    _ preparation: PreparedAgentProfileLaunch,
    in worktree: Worktree
  ) -> Result<LaunchedSurface, AgentProfileLaunchError> {
    let result = state(for: worktree).launchAgentProfile(preparation.context.request)
    if case .failure = result,
      let record = preparation.context.request.plan.hookRegistration?.forwardingRecord
    {
      codexForwardingRecordStore?.discardUnexposed(record)
    }
    return result
  }

  func startAgentHookRuntimeMaintenance() {
    _ = forwardingRecordStore()
  }

  private func forwardingRecordStore() -> CodexForwardingRecordStore? {
    if let codexForwardingRecordStore { return codexForwardingRecordStore }
    guard
      let store = try? CodexForwardingRecordStore(baseDirectory: forwardingRecordBaseDirectory)
    else { return nil }
    store.sweepOrphans()
    codexForwardingRecordStore = store
    return store
  }

  /// The launch outcome is reported as an event either way: the reducer
  /// records the per-repo launch memory only on success and surfaces the
  /// failure as a toast (docs-ai 053/005).
  private func launchAgentProfile(_ plan: AgentProfileLaunchPlan, in worktree: Worktree) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      var placement: AgentProfileLaunchRequest.Placement =
        plan.placement == .split
        ? .split(anchor: nil, direction: plan.splitDirection, background: false)
        : .tab(background: false)
      for attempt in 0..<2 {
        let request = AgentProfileLaunchRequest(plan: plan, placement: placement)
        switch await prepareAgentProfileLaunch(request, in: worktree) {
        case .failure where Task.isCancelled:
          return
        case .failure(let error):
          if attempt == 0, case .split = placement, error == .splitAnchorUnavailable {
            placement = .tab(background: false)
            continue
          }
          emit(.agentProfileLaunchFailed(worktreeID: worktree.id, profileName: plan.profileName))
          return
        case .success(let preparation):
          switch launchPreparedAgentProfile(preparation, in: worktree) {
          case .success:
            for warning in preparation.warnings {
              emit(
                .agentProfileLaunchWarning(
                  worktreeID: worktree.id,
                  profileName: plan.profileName,
                  message: warning.message
                )
              )
            }
            emit(.agentProfileLaunched(worktreeID: worktree.id, profileID: plan.profileID))
            return
          case .failure:
            if attempt == 0, case .split = placement {
              placement = .tab(background: false)
              continue
            }
            emit(.agentProfileLaunchFailed(worktreeID: worktree.id, profileName: plan.profileName))
            return
          }
        }
      }
    }
  }

  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew):
      Task { createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew) }
    case .createTabWithInput(
      let worktree, let input, let workingDirectory, let runSetupScriptIfNew, let autoCloseOnSuccess,
      let customCommandName, let customCommandIcon):
      Task {
        createTabAsync(
          in: worktree,
          runSetupScriptIfNew: runSetupScriptIfNew,
          initialInput: input,
          workingDirectory: workingDirectory,
          autoCloseOnSuccess: autoCloseOnSuccess,
          customCommandName: customCommandName,
          customCommandIcon: customCommandIcon
        )
      }
    case .createSplitWithInput(
      let worktree, let direction, let input, let autoCloseOnSuccess, let customCommandName, let customCommandIcon):
      Task {
        createSplitAsync(
          in: worktree,
          direction: direction,
          initialInput: input,
          autoCloseOnSuccess: autoCloseOnSuccess,
          customCommandName: customCommandName,
          customCommandIcon: customCommandIcon
        )
      }
    case .launchAgentProfile(let worktree, let plan):
      launchAgentProfile(plan, in: worktree)
    case .createTabInDirectory(let worktree, let directory):
      Task {
        createTabAsync(in: worktree, runSetupScriptIfNew: false, workingDirectory: directory)
      }
    case .focusOrCreateTabInDirectory(let worktree, let directory, let title):
      state(for: worktree).focusOrCreateTab(boundToDirectory: directory, title: title)
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .runScript(let worktree, let script):
      _ = state(for: worktree).runScript(script)
    case .insertText(let worktree, let text):
      if !state(for: worktree).focusAndRunCommand(text) {
        Task {
          createTabAsync(
            in: worktree,
            runSetupScriptIfNew: false,
            initialInput: text,
            autoCloseOnSuccess: false
          )
        }
      }
    case .stopRunScript(let worktree):
      _ = state(for: worktree).stopRunScript()
    case .closeFocusedTab(let worktree):
      _ = closeFocusedTab(in: worktree)
    case .closeFocusedSurface(let worktree):
      _ = closeFocusedSurface(in: worktree)
    case .focusSelectedTab(let worktree):
      state(for: worktree).focusSelectedTab()
    default:
      return false
    }
    return true
  }

  private func handleSearchCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .startSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("start_search")
    case .searchSelection(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("search_selection")
    case .navigateSearchNext(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.previous)
    case .endSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("end_search")
    default:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      state(for: worktree).performBindingActionOnFocusedSurface(action)
    case .performBindingActionOnSurface(let worktree, let surfaceID, let action):
      state(for: worktree).performBindingAction(action, onSurfaceID: surfaceID)
    default:
      return false
    }
    return true
  }

  private func handleManagementCommand(_ command: TerminalClient.Command) {
    switch command {
    case .prune(let ids):
      prune(keeping: ids)
    case .setNotificationsEnabled(let enabled):
      setNotificationsEnabled(enabled)
    case .setCommandFinishedNotification(let enabled, let threshold):
      setCommandFinishedNotification(enabled: enabled, threshold: threshold)
    case .setCanvasMode(let enabled):
      if enabled {
        terminalLogger.info("[CanvasExit] enteringCanvas previousSelectedWorktree=\(selectedWorktreeID ?? "nil")")
        selectedWorktreeID = nil
      }
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      let previousSelectedWorktreeID = selectedWorktreeID
      let leavingCanvas = previousSelectedWorktreeID == nil
      if let previousID = previousSelectedWorktreeID, let previousState = states[previousID] {
        previousState.lastDefocusedAt = Date()
        previousState.setAllSurfacesOccluded()
      } else if leavingCanvas {
        // Leaving canvas mode: occlude all worktrees except the newly selected one.
        for (wid, state) in states where wid != id {
          state.setAllSurfacesOccluded()
        }
      }
      selectedWorktreeID = id
      terminalLogger.info(
        "[CanvasExit] setSelectedWorktreeID previous=\(previousSelectedWorktreeID ?? "nil") "
          + "next=\(id ?? "nil") leavingCanvas=\(leavingCanvas) states=\(states.count)"
      )
      terminalLogger.info("Selected worktree \(id ?? "nil")")
    case .saveLayoutSnapshot:
      terminalLogger.info("[LayoutRestore] received saveLayoutSnapshot command")
      Task { await persistLayoutSnapshot() }
    case .restoreLayoutSnapshot(let worktrees):
      terminalLogger.info("[LayoutRestore] received restoreLayoutSnapshot command, worktrees=\(worktrees.count)")
      Task { await restoreLayoutSnapshot(from: worktrees) }
    case .presentTabIconPicker(let worktree):
      state(for: worktree).presentIconPickerForFocusedTab()
    default:
      return
    }
  }

  /// Independent per-surface multicast observation. This deliberately does not
  /// reuse `eventStream()`, whose single production subscriber is `AppFeature`.
  func observeAgentState(surfaceID: UUID) -> AgentObservationStream {
    agentObservationStore.observe(surfaceID: surfaceID, isLive: containsSurface(surfaceID))
  }

  @discardableResult
  func recordAgentSignal(_ signal: AgentSignal, surfaceID: UUID) -> Bool {
    guard containsSurface(surfaceID) else { return false }
    agentObservationStore.publishSignal(signal, surfaceID: surfaceID)
    return true
  }

  @discardableResult
  func recordAgentSignal(_ signal: AgentSignal, caller: CallerPane) -> AgentSignalRecordOutcome {
    guard containsSurface(caller.surfaceID) else { return .paneGone }
    let evidence = refreshEvidenceEpoch(surfaceID: caller.surfaceID)
    let generationMatches = evidence.generation.map(caller.processAncestry.contains) ?? false
    let binding = agentObservationStore.bindingForSignal(
      surfaceID: caller.surfaceID,
      generationMatches: generationMatches,
      signalSessionID: signal.sessionID
    )
    agentObservationStore.publishSignal(signal, binding: binding, surfaceID: caller.surfaceID)
    guard
      binding == .current,
      let evidenceEpoch = agentObservationStore.currentEvidenceEpoch(surfaceID: caller.surfaceID)
    else { return .recorded(binding: binding) }
    noteDispatchEvidence(
      signal,
      surfaceID: caller.surfaceID,
      evidenceEpoch: evidenceEpoch
    )
    return .recorded(binding: binding)
  }

  @discardableResult
  func recordAgentNativeHook(_ input: AgentNativeHookInput, caller: CallerPane) -> Bool {
    guard containsSurface(caller.surfaceID) else { return false }
    refreshEvidenceEpoch(surfaceID: caller.surfaceID)
    switch agentObservationStore.recordManagedHook(
      input,
      callerAncestry: caller.processAncestry,
      surfaceID: caller.surfaceID
    ) {
    case .rejected:
      return false
    case .pending:
      return true
    case .accepted(let signal, let evidenceEpoch):
      noteDispatchEvidence(signal, surfaceID: caller.surfaceID, evidenceEpoch: evidenceEpoch)
      return true
    }
  }

  /// Reconciles the surface's evidence epoch with the agent generation and session the
  /// detector currently proves, activating any hook signals that were waiting for it.
  @discardableResult
  private func refreshEvidenceEpoch(
    surfaceID: UUID
  ) -> (generation: AgentProcessGeneration?, sessionID: String?) {
    let evidence = currentAgentEvidence(surfaceID: surfaceID)
    handleEvidenceEpochUpdate(
      agentObservationStore.updateEvidenceEpoch(
        surfaceID: surfaceID,
        processGeneration: evidence.generation,
        sessionID: evidence.sessionID
      ),
      surfaceID: surfaceID
    )
    return evidence
  }

  private func handleEvidenceEpochUpdate(
    _ update: AgentEvidenceEpochUpdate,
    surfaceID: UUID
  ) {
    for signal in update.activatedSignals {
      guard let epoch = agentObservationStore.currentEvidenceEpoch(surfaceID: surfaceID) else { continue }
      noteDispatchEvidence(signal, surfaceID: surfaceID, evidenceEpoch: epoch)
    }
    for record in update.revokedForwardingRecords {
      retireForwardingRecord(record)
    }
  }

  private func retireForwardingRecord(_ record: CodexForwardingRecord) {
    codexForwardingRecordStore?.retire(record)
  }

  private func noteDispatchEvidence(
    _ signal: AgentSignal,
    surfaceID: UUID,
    evidenceEpoch: UUID
  ) {
    switch signal.kind {
    case .turnEnded:
      agentDispatchStore.noteTerminalEvidence(
        surfaceID: surfaceID,
        evidenceEpoch: evidenceEpoch,
        evidence: .turnEnded
      )
    case .needsInput:
      agentDispatchStore.noteTerminalEvidence(
        surfaceID: surfaceID,
        evidenceEpoch: evidenceEpoch,
        evidence: .needsInput
      )
    case .sessionEnd:
      agentDispatchStore.noteTerminalEvidence(
        surfaceID: surfaceID,
        evidenceEpoch: evidenceEpoch,
        evidence: .sessionEnd
      )
    case .sessionStart, .progress:
      agentDispatchStore.noteActivity(surfaceID: surfaceID, evidenceEpoch: evidenceEpoch)
    }
  }

  /// Internal observer-health diagnostic; not a user-facing API.
  func agentObservationSubscriberCount(surfaceID: UUID) -> Int {
    agentObservationStore.subscriberCount(surfaceID: surfaceID)
  }

  func agentObservationSnapshot(surfaceID: UUID) -> AgentObservationSnapshot? {
    agentObservationStore.snapshot(surfaceID: surfaceID)
  }

  func agentEvidenceEpochForTesting(surfaceID: UUID) -> UUID? {
    agentObservationStore.currentEvidenceEpoch(surfaceID: surfaceID)
  }

  func isSurfaceLive(_ surfaceID: UUID) -> Bool {
    containsSurface(surfaceID)
  }

  func agentSignalsPayload(
    surfaceID: UUID,
    includeDiagnosticLast: Bool = true
  ) -> AgentSignalsPayload {
    refreshEvidenceEpoch(surfaceID: surfaceID)
    return agentObservationStore.signalsPayload(
      surfaceID: surfaceID,
      formatter: Self.agentSignalDateFormatter,
      includeDiagnosticLast: includeDiagnosticLast
    )
  }

  func currentAgentSignalEvidence(surfaceID: UUID) -> AgentCurrentSignalEvidence {
    _ = agentSignalsPayload(surfaceID: surfaceID)
    return agentObservationStore.currentSignalEvidence(surfaceID: surfaceID)
  }

  func currentEligibleAgentSignal(surfaceID: UUID) -> AgentSignal? {
    currentAgentSignalEvidence(surfaceID: surfaceID).activeTerminal
  }

  private func currentAgentEvidence(
    surfaceID: UUID
  ) -> (generation: AgentProcessGeneration?, sessionID: String?) {
    for state in states.values {
      guard let paneState = state.surfaceAgentStates[surfaceID] else { continue }
      // The launch process, not the identified one, is the generation subject:
      // hooks descend from both, and only the launch survives an engine child
      // taking over identification.
      let generation = (paneState.launchProcessID ?? paneState.agentProcessID).flatMap { pid in
        ProcessDetection.processStartDate(pid: pid).map {
          AgentProcessGeneration(pid: pid, startedAt: $0)
        }
      }
      let trustedSessionID = paneState.session.flatMap {
        $0.confidence == .medium ? nil : $0.id
      }
      return (generation, trustedSessionID)
    }
    return (nil, nil)
  }

  private static let agentSignalDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()

  func issueAgentDispatch() throws -> AgentDispatchSnapshot {
    try agentDispatchStore.issue()
  }

  func bindAgentDispatch(dispatchID: String, target: TabResolvedTarget) throws {
    guard let surfaceID = UUID(uuidString: target.paneID) else {
      throw AgentDispatchStoreError.bindingMissing
    }
    guard let snapshot = agentDispatchStore.snapshot(dispatchID: dispatchID) else {
      throw AgentDispatchStoreError.notFound
    }
    let target = TabTarget(from: target)
    if let existing = snapshot.binding {
      guard existing.surfaceID == surfaceID, existing.target == target else {
        throw AgentDispatchStoreError.alreadyBound
      }
      try agentDispatchStore.bind(dispatchID: dispatchID, binding: existing)
      return
    }
    guard snapshot.record.state == .pending else {
      throw AgentDispatchStoreError.alreadyTerminal
    }
    let evidenceEpoch: UUID
    if agentObservationStore.hasManagedHook(surfaceID: surfaceID) {
      guard let current = agentObservationStore.currentEvidenceEpoch(surfaceID: surfaceID) else {
        throw AgentDispatchStoreError.bindingMissing
      }
      evidenceEpoch = current
    } else {
      evidenceEpoch = agentObservationStore.beginDispatchEpoch(surfaceID: surfaceID)
    }
    try agentDispatchStore.bind(
      dispatchID: dispatchID,
      binding: AgentDispatchBinding(
        surfaceID: surfaceID,
        target: target,
        evidenceEpoch: evidenceEpoch
      )
    )
  }

  /// Issues a record for an agent already running in `target` and binds it to the pane's
  /// current evidence epoch in one main-actor step (docs-ai 064.014). Unlike a prompted
  /// launch this never begins a new epoch: the generation that will report the receipt is
  /// the one the pane holds now, so its hook and cooperative signals keep counting.
  func issueAgentDispatch(boundTo target: TabResolvedTarget) throws -> AgentDispatchSnapshot {
    guard let surfaceID = UUID(uuidString: target.paneID), containsSurface(surfaceID) else {
      throw AgentDispatchStoreError.bindingMissing
    }
    refreshEvidenceEpoch(surfaceID: surfaceID)
    guard let evidenceEpoch = agentObservationStore.currentEvidenceEpoch(surfaceID: surfaceID) else {
      throw AgentDispatchStoreError.bindingMissing
    }
    guard agentDispatchStore.pendingSnapshot(surfaceID: surfaceID) == nil else {
      throw AgentDispatchStoreError.surfacePending
    }
    let issued = try agentDispatchStore.issue()
    do {
      try agentDispatchStore.bind(
        dispatchID: issued.record.id,
        binding: AgentDispatchBinding(
          surfaceID: surfaceID,
          target: TabTarget(from: target),
          evidenceEpoch: evidenceEpoch
        )
      )
    } catch {
      agentDispatchStore.cancelIssuance(dispatchID: issued.record.id)
      throw error
    }
    return agentDispatchStore.snapshot(dispatchID: issued.record.id) ?? issued
  }

  func cancelAgentDispatchIssuance(dispatchID: String) {
    agentDispatchStore.cancelIssuance(dispatchID: dispatchID)
  }

  func agentDispatchSnapshot(dispatchID: String) -> AgentDispatchSnapshot? {
    agentDispatchStore.snapshot(dispatchID: dispatchID)
  }

  func pendingAgentDispatchSnapshot(surfaceID: UUID) -> AgentDispatchSnapshot? {
    agentDispatchStore.pendingSnapshot(surfaceID: surfaceID)
  }

  func completeAgentDispatch(
    dispatchID: String,
    outcome: DispatchCompletionOutcome,
    summary: String,
    callerSurfaceID: UUID
  ) throws -> AgentDispatchMutationResult {
    try agentDispatchStore.complete(
      dispatchID: dispatchID,
      outcome: outcome,
      summary: summary,
      callerSurfaceID: callerSurfaceID
    )
  }

  /// Completes the caller pane's current pending dispatch (see `AgentDispatchStore.complete(surfaceID:)`).
  func completeAgentDispatch(
    surfaceID: UUID,
    outcome: DispatchCompletionOutcome,
    summary: String
  ) throws -> AgentDispatchMutationResult {
    try agentDispatchStore.complete(surfaceID: surfaceID, outcome: outcome, summary: summary)
  }

  func abandonAgentDispatch(dispatchID: String, reason: String) throws -> AgentDispatchMutationResult {
    try agentDispatchStore.abandon(dispatchID: dispatchID, reason: reason)
  }

  func observeAgentDispatch(dispatchID: String) throws -> AgentDispatchObservationStream {
    try agentDispatchStore.observe(dispatchID: dispatchID)
  }

  func agentDispatchSubscriberCount(dispatchID: String) -> Int {
    agentDispatchStore.subscriberCount(dispatchID: dispatchID)
  }

  func eventStream() -> AsyncStream<TerminalClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(
      of: TerminalClient.Event.self,
      bufferingPolicy: .bufferingNewest(Self.eventBufferCap)
    )
    eventContinuation = continuation
    lastNotificationIndicatorCount = nil
    // A new subscriber must be re-seeded with current state, so the dedup cache
    // can't suppress the next emit as a duplicate of one the old stream saw.
    eventCoalescer.reset()
    if !pendingEvents.isEmpty {
      let bufferedEvents = pendingEvents
      pendingEvents.removeAll()
      for event in bufferedEvents {
        if case .notificationIndicatorChanged = event {
          continue
        }
        continuation.yield(event)
      }
    }
    emitNotificationIndicatorCountIfNeeded()
    return stream
  }

  func state(
    for worktree: Worktree,
    runSetupScriptIfNew: () -> Bool = { false }
  ) -> WorktreeTerminalState {
    if let existing = states[worktree.id] {
      existing.setDefaultFontSize(preferredFontSize)
      if runSetupScriptIfNew() {
        existing.enableSetupScriptIfNeeded()
      }
      return existing
    }
    let runSetupScript = runSetupScriptIfNew()
    let state = WorktreeTerminalState(
      runtime: runtime!,
      worktree: worktree,
      runSetupScript: runSetupScript,
      defaultFontSize: preferredFontSize,
      targetHandleRegistry: targetHandleRegistry,
      skipsSurfaceCreationForTesting: skipsSurfaceCreationForTesting
    )
    state.setNotificationsEnabled(notificationsEnabled)
    state.setCommandFinishedNotification(
      enabled: commandFinishedNotificationEnabled,
      threshold: commandFinishedNotificationThreshold
    )
    state.isSelected = { [weak self] in
      self?.selectedWorktreeID == worktree.id
    }
    state.onNotificationReceived = { [weak self] surfaceID, title, body, isViewed in
      self?.emit(
        .notificationReceived(
          worktreeID: worktree.id,
          surfaceID: surfaceID,
          title: title,
          body: body,
          isViewed: isViewed
        )
      )
    }
    state.onNotificationIndicatorChanged = { [weak self] in
      self?.emitNotificationIndicatorCountIfNeeded()
    }
    state.onTabCreated = { [weak self] in
      self?.emit(.tabCreated(worktreeID: worktree.id))
    }
    state.onTabClosed = { [weak self, weak state] in
      guard let self else { return }
      let remaining = state?.tabManager.tabs.count ?? 0
      emit(.tabClosed(worktreeID: worktree.id, remainingTabs: remaining))
    }
    state.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
    }
    state.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
    }
    configureAgentObservationCallbacks(state)
    state.onRunScriptStatusChanged = { [weak self] isRunning in
      self?.emit(.runScriptStatusChanged(worktreeID: worktree.id, isRunning: isRunning))
    }
    state.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    state.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    state.onFontSizeAdjusted = { [weak self] in
      self?.syncPreferredFontSize(from: worktree.id)
    }
    state.onCustomCommandSucceeded = { [weak self] name, durationMs in
      self?.emit(.customCommandSucceeded(worktreeID: worktree.id, name: name, durationMs: durationMs))
    }
    states[worktree.id] = state
    terminalLogger.info("Created terminal state for worktree \(worktree.id)")
    return state
  }

  private func configureAgentObservationCallbacks(_ state: WorktreeTerminalState) {
    state.onAgentEntryChanged = { [weak self] entry in
      guard let self else { return }
      let beganWorking = agentObservationStore.publishAgentChanged(entry)
      refreshEvidenceEpoch(surfaceID: entry.surfaceID)
      if beganWorking,
        let evidenceEpoch = agentObservationStore.currentEvidenceEpoch(surfaceID: entry.surfaceID)
      {
        agentDispatchStore.noteActivity(surfaceID: entry.surfaceID, evidenceEpoch: evidenceEpoch)
      }
      emit(.agentEntryChanged(entry))
    }
    state.onAgentEntryRemoved = { [weak self] surfaceID in
      guard let self else { return }
      if let record = agentObservationStore.revokeManagedHook(surfaceID: surfaceID) {
        retireForwardingRecord(record)
      }
      agentObservationStore.publishAgentRemoved(surfaceID: surfaceID)
      emit(.agentEntryRemoved(surfaceID))
    }
    state.onSurfaceClosed = { [weak self] surfaceID in
      guard let self else { return }
      if let record = agentObservationStore.revokeManagedHook(surfaceID: surfaceID) {
        retireForwardingRecord(record)
      }
      agentObservationStore.publishSurfaceClosed(surfaceID: surfaceID)
      agentDispatchStore.surfaceClosed(surfaceID: surfaceID)
    }
    state.onAgentProfileSurfacePrepared = { [weak self] surfaceID, plan in
      guard let self, containsSurface(surfaceID) else { return false }
      guard let registration = plan.hookRegistration else { return true }
      _ = agentObservationStore.registerManagedHook(registration, surfaceID: surfaceID)
      return true
    }
  }

  @discardableResult
  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil,
    workingDirectory: URL? = nil,
    autoCloseOnSuccess: Bool = false,
    customCommandName: String? = nil,
    customCommandIcon: String? = nil
  ) -> TerminalTabID? {
    let state = state(for: worktree) { runSetupScriptIfNew }
    let setupScript: String?
    // Skip setup injection when auto-close is requested so the setup script's
    // own exit code cannot trigger the close before the user's command runs.
    if !autoCloseOnSuccess, state.needsSetupScript() {
      @SharedReader(.repositorySettings(worktree.repositoryRootURL))
      var settings = RepositorySettings.default
      setupScript = settings.setupScript
    } else {
      setupScript = nil
    }
    let tabId = state.createTab(
      setupScript: setupScript,
      initialInput: initialInput,
      workingDirectoryOverride: workingDirectory
    )
    if let tabId, let surfaceId = state.focusedSurfaceId(in: tabId) {
      if autoCloseOnSuccess {
        state.markSurfaceForAutoClose(surfaceId)
      }
      if let customCommandName {
        state.markSurfaceForCustomCommand(surfaceId, name: customCommandName)
      }
      if let customCommandIcon {
        state.applyCustomCommandIcon(customCommandIcon, surfaceId: surfaceId)
      }
    }
    return tabId
  }

  private func createSplitAsync(
    in worktree: Worktree,
    direction: UserCustomSplitDirection,
    initialInput: String,
    autoCloseOnSuccess: Bool,
    customCommandName: String? = nil,
    customCommandIcon: String? = nil
  ) {
    let state = state(for: worktree)
    guard
      let newSurfaceId = state.createSplitOnFocusedSurface(
        direction: direction,
        initialInput: initialInput
      )
    else {
      return
    }
    if autoCloseOnSuccess {
      state.markSurfaceForAutoClose(newSurfaceId)
    }
    if let customCommandName {
      state.markSurfaceForCustomCommand(newSurfaceId, name: customCommandName)
    }
    if let customCommandIcon {
      state.applyCustomCommandIcon(customCommandIcon, surfaceId: newSurfaceId)
    }
  }

  @discardableResult
  func closeFocusedTab(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedTab()
  }

  @discardableResult
  func closeFocusedSurface(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedSurface()
  }

  func prune(keeping worktreeIDs: Set<Worktree.ID>) {
    var removed: [WorktreeTerminalState] = []
    var removedIDs: Set<Worktree.ID> = []
    for (id, state) in states where !worktreeIDs.contains(id) {
      removed.append(state)
      removedIDs.insert(id)
    }
    for state in removed {
      state.closeAllSurfaces()
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    eventCoalescer.forget(worktreeIDs: removedIDs)
    emitNotificationIndicatorCountIfNeeded()
  }

  var activeWorktreeStates: [WorktreeTerminalState] {
    states.values.filter { !$0.tabManager.tabs.isEmpty }
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  /// Map of shell child PIDs to their owning pane across all live worktree
  /// states, for the CLI service's caller-pane resolution.
  func paneByShellPID() -> [pid_t: CallerPane] {
    var map: [pid_t: CallerPane] = [:]
    for (worktreeID, state) in states {
      for (surfaceID, pid) in state.shellPIDsBySurface() {
        map[pid] = CallerPane(worktreeID: worktreeID, surfaceID: surfaceID)
      }
    }
    return map
  }

  func stateContaining(tabId: TerminalTabID) -> WorktreeTerminalState? {
    activeWorktreeStates.first { $0.surfaceView(for: tabId) != nil }
  }

  private func containsSurface(_ surfaceID: UUID) -> Bool {
    states.values.contains { $0.surfaceView(for: surfaceID) != nil }
  }

  @discardableResult
  func broadcastCommittedText(
    _ text: String,
    from primaryTabID: TerminalTabID,
    to selectedTabIDs: Set<TerminalTabID>
  ) -> Int {
    var mirrored = 0
    for tabId in selectedTabIDs where tabId != primaryTabID {
      if stateContaining(tabId: tabId)?.insertCommittedText(text, in: tabId) == true {
        mirrored += 1
      } else {
        terminalLogger.debug("Broadcast text failed for tab \(tabId)")
      }
    }
    return mirrored
  }

  @discardableResult
  func broadcastMirroredKey(
    _ key: MirroredTerminalKey,
    from primaryTabID: TerminalTabID,
    to selectedTabIDs: Set<TerminalTabID>
  ) -> Int {
    var mirrored = 0
    for tabId in selectedTabIDs where tabId != primaryTabID {
      if stateContaining(tabId: tabId)?.applyMirroredKey(key, in: tabId) == true {
        mirrored += 1
      } else {
        terminalLogger.debug("Broadcast key failed for tab \(tabId)")
      }
    }
    return mirrored
  }

  func taskStatus(for worktreeID: Worktree.ID) -> WorktreeTaskStatus? {
    states[worktreeID]?.taskStatus
  }

  /// Whether the worktree holds an agent awaiting an answer. Paired with
  /// `taskStatus(for:)` at the sidebar row so a blocked agent reads as needing
  /// input rather than as work in progress.
  func hasBlockedAgent(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.hasBlockedAgent == true
  }

  func isRunScriptRunning(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.isRunScriptRunning == true
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    for state in states.values {
      state.setNotificationsEnabled(enabled)
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  func setCommandFinishedNotification(enabled: Bool, threshold: Int) {
    commandFinishedNotificationEnabled = enabled
    commandFinishedNotificationThreshold = threshold
    for state in states.values {
      state.setCommandFinishedNotification(enabled: enabled, threshold: threshold)
    }
  }

  func hasUnseenNotifications(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.hasUnseenNotification == true
  }

  func latestUnreadNotificationLocation() -> NotificationLocation? {
    var bestLocation: NotificationLocation?
    var bestCreatedAt: Date?
    for (worktreeID, state) in states {
      for notification in state.unreadNotifications() {
        if let bestCreatedAt, bestCreatedAt >= notification.createdAt {
          break
        }
        guard let tabID = state.tabID(containing: notification.surfaceId) else {
          continue
        }
        bestLocation = NotificationLocation(
          worktreeID: worktreeID,
          tabID: tabID,
          surfaceID: notification.surfaceId,
          notificationID: notification.id
        )
        bestCreatedAt = notification.createdAt
        break
      }
    }
    return bestLocation
  }

  @discardableResult
  func focusSurface(worktreeID: Worktree.ID, surfaceID: UUID) -> Bool {
    states[worktreeID]?.focusSurface(id: surfaceID) == true
  }

  func markNotificationRead(worktreeID: Worktree.ID, notificationID: UUID) {
    states[worktreeID]?.markNotificationRead(id: notificationID)
  }

  func markNotificationsRead(worktreeID: Worktree.ID, surfaceID: UUID) {
    states[worktreeID]?.markNotificationsRead(forSurfaceID: surfaceID)
  }

  func surfaceBackgroundOpacity() -> Double {
    runtime?.backgroundOpacity() ?? 1.0
  }

  func unfocusedSplitOverlay() -> (fill: Color?, opacity: Double) {
    guard let runtime else { return (nil, 0) }
    return (runtime.unfocusedSplitFill(), runtime.unfocusedSplitOverlayOpacity())
  }

  func splitDividerAppearance() -> (color: Color?, width: CGFloat?) {
    guard let runtime else { return (nil, nil) }
    return (runtime.splitDividerColor(), runtime.splitDividerWidth())
  }

  func syncPreferredFontSize(from worktreeID: Worktree.ID) {
    guard let state = states[worktreeID] else { return }
    let fontSize = state.focusedFontSize()
    let normalized = normalizedFontSize(fontSize)
    guard preferredFontSize != normalized else { return }
    preferredFontSize = normalized
    for worktreeState in states.values {
      worktreeState.setDefaultFontSize(normalized)
    }
    emit(.fontSizeChanged(normalized))
  }

  private func normalizedFontSize(_ fontSize: Float32?) -> Float32? {
    guard let fontSize else { return nil }
    let epsilon: Float32 = 0.01
    if abs(fontSize - baselineFontSize) <= epsilon {
      return nil
    }
    return fontSize
  }

  private func emit(_ event: TerminalClient.Event) {
    guard eventCoalescer.shouldEmit(event) else { return }
    guard let eventContinuation else {
      if pendingEvents.count >= Self.pendingEventCap {
        pendingEvents.removeFirst()
        terminalLogger.debug("Dropped oldest pending terminal event (backlog cap reached)")
      }
      pendingEvents.append(event)
      return
    }
    eventContinuation.yield(event)
  }

  private func emitNotificationIndicatorCountIfNeeded() {
    let count = states.values.reduce(0) { count, state in
      count + (state.hasUnseenNotification ? 1 : 0)
    }
    if count != lastNotificationIndicatorCount {
      lastNotificationIndicatorCount = count
      emit(.notificationIndicatorChanged(count: count))
    }
  }

  func persistLayoutSnapshot() async {
    guard let payload = makeLayoutSnapshotPayload() else {
      terminalLogger.info("[LayoutRestore] persist: no active states, clearing snapshot")
      _ = await layoutPersistence.clearSnapshot()
      return
    }
    terminalLogger.info("[LayoutRestore] persist: saving \(payload.worktrees.count) worktree(s)")
    let saved = await layoutPersistence.saveSnapshot(payload)
    terminalLogger.info("[LayoutRestore] persist: save result=\(saved)")
  }

  func persistLayoutSnapshotSync() {
    guard let payload = makeLayoutSnapshotPayload() else {
      terminalLogger.info("[LayoutRestore] persistSync: no active states, clearing snapshot")
      discardTerminalLayoutSnapshot(at: SupacodePaths.terminalLayoutSnapshotURL, fileManager: .default)
      return
    }
    terminalLogger.info("[LayoutRestore] persistSync: saving \(payload.worktrees.count) worktree(s)")
    let saved = saveTerminalLayoutSnapshot(
      payload,
      at: SupacodePaths.terminalLayoutSnapshotURL,
      cacheDirectory: SupacodePaths.cacheDirectory,
      fileManager: .default
    )
    terminalLogger.info("[LayoutRestore] persistSync: save result=\(saved)")
  }

  func restoreLayoutSnapshot(from worktrees: [Worktree]) async {
    terminalLogger.info("[LayoutRestore] restore: loading snapshot from disk")
    guard let payload = await layoutPersistence.loadSnapshot() else {
      terminalLogger.info("[LayoutRestore] restore: no snapshot found on disk, skipping")
      emit(.layoutRestored(selectedWorktreeID: nil))
      return
    }
    terminalLogger.info(
      "[LayoutRestore] restore: loaded snapshot with \(payload.worktrees.count) worktree(s),"
        + " available worktrees=\(worktrees.count)"
    )
    for (index, snapshot) in payload.worktrees.enumerated() {
      terminalLogger.info(
        "[LayoutRestore] restore: snapshot[\(index)] worktreeID=\(snapshot.worktreeID)"
          + " tabs=\(snapshot.tabs.count) selectedTab=\(snapshot.selectedTabID ?? "nil")"
      )
    }
    for (index, worktree) in worktrees.enumerated() {
      terminalLogger.info("[LayoutRestore] restore: available[\(index)] id=\(worktree.id) name=\(worktree.name)")
    }
    let didRestore = applyLayoutSnapshotPayload(payload, availableWorktrees: worktrees)
    terminalLogger.info("[LayoutRestore] restore: applyResult=\(didRestore)")
    if didRestore {
      terminalLogger.info(
        "[LayoutRestore] restore: emitting layoutRestored selectedWorktreeID=\(payload.selectedWorktreeID ?? "nil")"
      )
      emit(.layoutRestored(selectedWorktreeID: payload.selectedWorktreeID))
    } else {
      terminalLogger.warning("[LayoutRestore] restore: clearing invalid snapshot and emitting failure toast")
      _ = await layoutPersistence.clearSnapshot()
      emit(.layoutRestoreFailed(message: layoutRestoreFailureMessage))
    }
  }

  private func makeLayoutSnapshotPayload() -> TerminalLayoutSnapshotPayload? {
    let activeStates = activeWorktreeStates.sorted { $0.worktreeID < $1.worktreeID }
    terminalLogger.info(
      "[LayoutRestore] makePayload: activeWorktreeStates=\(activeStates.count)"
        + " totalStates=\(states.count)"
    )
    guard !activeStates.isEmpty else {
      return nil
    }

    var snapshotWorktrees: [TerminalLayoutSnapshotPayload.SnapshotWorktree] = []
    snapshotWorktrees.reserveCapacity(activeStates.count)
    for state in activeStates {
      guard let snapshot = state.makeLayoutSnapshotWorktree() else {
        terminalLogger.warning(
          "[LayoutRestore] makePayload: failed to snapshot worktree \(state.worktreeID)"
        )
        return nil
      }
      snapshotWorktrees.append(snapshot)
    }
    return TerminalLayoutSnapshotPayload(
      selectedWorktreeID: selectedWorktreeID,
      worktrees: snapshotWorktrees
    )
  }

  private func applyLayoutSnapshotPayload(
    _ payload: TerminalLayoutSnapshotPayload,
    availableWorktrees: [Worktree]
  ) -> Bool {
    let worktreeByID = Dictionary(
      availableWorktrees.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var restoredStates: [WorktreeTerminalState] = []
    restoredStates.reserveCapacity(payload.worktrees.count)

    for snapshot in payload.worktrees {
      guard let worktree = worktreeByID[snapshot.worktreeID] else {
        terminalLogger.warning(
          "[LayoutRestore] apply: worktreeID \(snapshot.worktreeID) not found in available worktrees"
        )
        for state in restoredStates {
          state.closeAllSurfaces()
        }
        return false
      }
      terminalLogger.info("[LayoutRestore] apply: restoring worktree \(worktree.id)")
      let state = state(for: worktree)
      guard state.applyLayoutSnapshot(snapshot) else {
        terminalLogger.warning("[LayoutRestore] apply: applyLayoutSnapshot failed for \(worktree.id)")
        state.closeAllSurfaces()
        for restored in restoredStates {
          restored.closeAllSurfaces()
        }
        return false
      }
      restoredStates.append(state)
    }

    terminalLogger.info("[LayoutRestore] apply: successfully restored \(restoredStates.count) worktree(s)")
    return true
  }

  #if DEBUG
    /// Inert instance for SwiftUI previews — no GhosttyRuntime, all reads return defaults.
    static let preview: WorktreeTerminalManager = {
      let manager = WorktreeTerminalManager(preview: ())
      return manager
    }()

    private init(preview: Void) {
      self.runtime = nil
      self.layoutPersistence = .liveValue
      self.skipsSurfaceCreationForTesting = true
      self.preferredFontSize = nil
      self.agentObservationStore = AgentObservationStore(bufferCapacity: 64)
      self.agentDispatchStore = AgentDispatchStore()
      self.codexConfigReadProcess = CodexConfigReadProcess()
      self.codexShellEnvironmentResolver = { _, _ in nil }
      self.hookResourcesProvider = { nil }
      self.forwardingRecordBaseDirectory = SupacodePaths.agentHookForwardingDirectory
      self.baselineFontSize = 13
    }
  #endif
}
