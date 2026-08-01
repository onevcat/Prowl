import ComposableArchitecture
import Foundation

/// A row in the hand-off HUD's choose step.
struct HandoffTargetOption: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Hashable, Sendable {
    case agent(DetectedAgent)
    case profile(AgentProfile.ID, runtime: DetectedAgent)
    case briefOnly
  }

  let kind: Kind
  let title: String
  let subtitle: String
  /// The receiving agent equals the outgoing one (fresh-session restart).
  let isCurrentAgent: Bool

  var id: Kind { kind }

  var agent: DetectedAgent? {
    switch kind {
    case .agent(let agent), .profile(_, let agent): agent
    case .briefOnly: nil
    }
  }

  var receivingTarget: HandoffReceivingTarget? {
    switch kind {
    case .agent(let agent): .runtimeDefault(agent)
    case .profile(let profileID, _): .profile(profileID)
    case .briefOnly: nil
    }
  }
}

/// The outgoing side of a hand-off, captured once when the HUD opens.
struct HandoffHudSource: Equatable, Sendable {
  /// Detected agent token, e.g. "codex".
  let agentToken: String
  let displayName: String
  /// The source pane the injected request goes to (and the pane whose CLI
  /// completion the HUD waits for).
  let sourceSurfaceID: UUID
  /// Non-nil only for a resumable exact/high-confidence session — enables the
  /// fork fallback.
  let forkRequest: AgentResumeRequest?
  let sessionContext: HandoffStore.SessionContext?
  let observation: AgentLaunchObservation?
}

enum HandoffStage: Equatable, Sendable {
  /// Request injected into the live source agent; waiting for its CLI call.
  case requesting
  /// Fallback: fork briefing + transition, headless.
  case forking
  /// Artifact persistence and receiver launch have committed; this phase runs
  /// to completion rather than presenting a misleading cancel affordance.
  case finishing
}

enum HandoffHudOutcome: Equatable, Sendable {
  case handedOff(agentDisplayName: String)
  case briefSaved
  case failed(message: String)
}

struct HandoffHudRun: Equatable, Sendable {
  let target: HandoffTargetOption
  let startedAt: Date
  var stage: HandoffStage
  /// Non-nil only for an inline request injected by this HUD run.
  let requestID: UUID?

}

enum HandoffHudPhase: Equatable {
  case choosing
  case running(HandoffHudRun)
  case finished(HandoffHudOutcome)
}

/// The staged hand-off HUD (docs-ai 047.004): choose a receiving agent, then
/// ask the *live* source agent to run the CLI self-handoff by injecting a
/// one-line request into its pane. The agent authors its briefing inline and
/// the shared CLI transition completes headlessly; the HUD observes the
/// completion (`cliCompleted`) and finishes. Resume-fork and context-only are
/// explicit fallbacks the user picks while waiting — the inline path is the
/// primary one because the live agent holds context no transcript fork can
/// reconstruct.
@Reducer
struct HandoffHudFeature {
  @ObservableState
  struct State: Equatable {
    let worktree: Worktree
    let rootURL: URL
    let source: HandoffHudSource
    let targets: [HandoffTargetOption]
    var selectedIndex = 0
    var phase: HandoffHudPhase = .choosing

    var run: HandoffHudRun? {
      guard case .running(let run) = phase else { return nil }
      return run
    }

    var isChoosing: Bool { phase == .choosing }

    var canFork: Bool { source.forkRequest != nil }

    /// Build the HUD for a pane with a detected agent; nil without one — the
    /// no-source mechanical handoff stays CLI-only.
    static func make(
      worktree: Worktree,
      source: HandoffSourceContext?,
      profiles: [AgentProfile] = [],
      designatedProfileID: AgentProfile.ID? = nil,
      lastLaunchedProfileID: AgentProfile.ID? = nil
    ) -> State? {
      guard
        let sessionContext = source?.sessionContext,
        let agentToken = sessionContext.agent,
        let sourceSurfaceID = UUID(uuidString: sessionContext.paneID)
      else {
        return nil
      }
      let sourceAgent = DetectedAgent(rawValue: agentToken)
      let forkRequest = HandoffCommandHandler.forkRequest(
        outgoingAgent: agentToken,
        session: source?.session,
        observation: source?.observation
      )
      let enabledProfiles = profiles.filter(\.isEnabled)
      let recommendedProfile = AgentProfileRecommendation.recommendedProfile(
        profiles: enabledProfiles,
        designatedID: designatedProfileID,
        lastLaunchedID: lastLaunchedProfileID
      )
      let orderedProfiles =
        (recommendedProfile.map { [$0] } ?? [])
        + enabledProfiles.filter { $0.id != recommendedProfile?.id }
      var targets = orderedProfiles.map { profile in
        let runtime = profile.runtime.agent
        return HandoffTargetOption(
          kind: .profile(profile.id, runtime: runtime),
          title: profile.name,
          subtitle:
            profile.id == recommendedProfile?.id
            ? "Recommended · \(runtime.displayName) Profile"
            : "\(runtime.displayName) Profile",
          isCurrentAgent: runtime == sourceAgent
        )
      }
      targets += AgentRuntimeAdapterRegistry.launchableAgents.map { agent in
        HandoffTargetOption(
          kind: .agent(agent),
          title: AgentRuntimeAdapterRegistry.displayName(for: agent),
          subtitle: (enabledProfiles.isEmpty ? "" : "Runtime Default · ")
            + Self.launchSubtitle(
              sourceAgent: sourceAgent,
              sourceDisplayName: sourceAgent?.displayName ?? agentToken,
              observation: source?.observation,
              destination: agent
            ),
          isCurrentAgent: agent == sourceAgent
        )
      }
      targets.append(
        HandoffTargetOption(
          kind: .briefOnly,
          title: "Only save progress, don't hand off",
          subtitle: "Saves a briefing checkpoint for a later hand-off",
          isCurrentAgent: false
        )
      )
      return State(
        worktree: worktree,
        rootURL: worktree.workingDirectory,
        source: HandoffHudSource(
          agentToken: agentToken,
          displayName: sourceAgent?.displayName ?? agentToken,
          sourceSurfaceID: sourceSurfaceID,
          forkRequest: forkRequest,
          sessionContext: sessionContext,
          observation: source?.observation
        ),
        targets: targets
      )
    }

    /// Read-only launch-configuration facts; the HUD never offers options.
    private static func launchSubtitle(
      sourceAgent: DetectedAgent?,
      sourceDisplayName: String,
      observation: AgentLaunchObservation?,
      destination: DetectedAgent
    ) -> String {
      let standard = "Launches with its default setup"
      guard let sourceAgent else { return standard }
      let configuration = AgentRuntimeAdapterRegistry.inheritedConfiguration(
        from: sourceAgent,
        observation: observation,
        to: destination
      )
      if configuration.executionMode == .unrestricted, observation?.executionMode == .unrestricted {
        return "Will bypass permissions (carried over from \(sourceDisplayName))"
      }
      return standard
    }
  }

  enum Action: Equatable {
    case moveSelection(delta: Int)
    case setSelectedIndex(Int)
    case confirmSelection
    case fallbackForkTapped
    case fallbackContextOnlyTapped
    /// Fork collection has produced a validated (or context-only) briefing.
    /// Handling this action establishes the non-cancellable commit boundary.
    case fallbackBriefingCollected(HandoffPreparedBriefing)

    /// A CLI handoff completed somewhere in the app; the reducer ignores it
    /// unless it came from this HUD's source pane.
    case cliCompleted(HandoffCLICompletion)
    case fallbackFinished(HandoffHudOutcome)
    case runFailed(message: String)
    case cancelTapped
    case closeTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case dismiss
  }

  private nonisolated struct FallbackCancelID: Hashable {
    let worktreeID: Worktree.ID
  }

  @Dependency(AgentRuntimeClient.self) private var agentRuntimeClient
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(HandoffRequestClient.self) private var handoffRequestClient
  @Dependency(\.uuid) private var uuid

  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .moveSelection(let delta):
        guard state.isChoosing, !state.targets.isEmpty else { return .none }
        let count = state.targets.count
        state.selectedIndex = (state.selectedIndex + delta + count) % count
        return .none

      case .setSelectedIndex(let index):
        guard state.isChoosing, state.targets.indices.contains(index) else { return .none }
        state.selectedIndex = index
        return .none

      case .confirmSelection:
        guard state.isChoosing, state.targets.indices.contains(state.selectedIndex) else { return .none }
        let target = state.targets[state.selectedIndex]
        let operation = target.receivingTarget.map { HandoffRequestOperation.handoff(target: $0) } ?? .checkpoint
        let expectation = HandoffRequestExpectation(
          sourcePaneID: state.source.sourceSurfaceID,
          operation: operation
        )
        let requestID = uuid()
        handoffRequestClient.register(requestID, expectation)
        let delivered = terminalClient.sendTextToSurface(
          state.worktree.id,
          state.source.sourceSurfaceID,
          HandoffInjection.instruction(for: expectation, requestID: requestID)
        )
        state.phase = .running(
          HandoffHudRun(
            target: target,
            startedAt: now,
            stage: .requesting,
            requestID: requestID
          )
        )

        if delivered {
          // The panel goes non-modal while waiting: hand the keyboard back to
          // the terminal so the user can approve any permission prompt the
          // injected request triggers in the source agent.
          let worktree = state.worktree
          let client = terminalClient
          return .run { _ in
            await client.send(.focusSelectedTab(worktree))
          }
        }
        // The pane cannot take input (gone or wedged) — cancel its just-registered
        // request before the HUD takes the independent fallback path.
        _ = handoffRequestClient.supersede(requestID)
        return state.canFork
          ? startForkFallback(&state)
          : startContextOnlyFallback(&state)

      case .fallbackForkTapped:
        guard
          let requestID = state.run?.requestID,
          handoffRequestClient.supersede(requestID)
        else { return .none }
        return startForkFallback(&state)

      case .fallbackContextOnlyTapped:
        guard
          let requestID = state.run?.requestID,
          handoffRequestClient.supersede(requestID)
        else { return .none }
        return startContextOnlyFallback(&state)

      case .fallbackBriefingCollected(let briefing):
        guard state.run?.stage == .forking else { return .none }
        return startFallbackCommit(&state, briefing: briefing)

      case .cliCompleted(let completion):
        guard let run = state.run,
          run.stage == .requesting,
          completion.sourcePaneID == state.source.sourceSurfaceID.uuidString,
          completion.requestID == run.requestID
        else { return .none }
        let expectedAction: HandoffAction = run.target.kind == .briefOnly ? .save : .toAgent
        guard completion.action == expectedAction else { return .none }
        switch run.target.kind {
        case .briefOnly:
          guard completion.toAgent == nil, completion.toProfileID == nil else { return .none }
          if let message = completion.failureMessage {
            state.phase = .finished(.failed(message: message))
            return .cancel(id: FallbackCancelID(worktreeID: state.worktree.id))
          }
          state.phase = .finished(.briefSaved)
        case .agent(let expectedAgent):
          guard completion.toAgent == expectedAgent.rawValue, completion.toProfileID == nil else { return .none }
          if let message = completion.failureMessage {
            state.phase = .finished(.failed(message: message))
            return .cancel(id: FallbackCancelID(worktreeID: state.worktree.id))
          }
          guard let launched = completion.launched,
            let paneID = UUID(uuidString: launched.paneID)
          else { return .none }
          state.phase = .finished(.handedOff(agentDisplayName: run.target.title))
          // The user is present and asked for this hand-off — jump to the
          // receiver. The transition core itself never focuses anything.
          _ = terminalClient.focusSurface(launched.worktreeID, paneID)
        case .profile(let expectedProfileID, _):
          guard completion.toProfileID == expectedProfileID else { return .none }
          if let message = completion.failureMessage {
            state.phase = .finished(.failed(message: message))
            return .cancel(id: FallbackCancelID(worktreeID: state.worktree.id))
          }
          guard let launched = completion.launched,
            let paneID = UUID(uuidString: launched.paneID)
          else { return .none }
          state.phase = .finished(
            .handedOff(agentDisplayName: completion.toProfileName ?? run.target.title)
          )
          _ = terminalClient.focusSurface(launched.worktreeID, paneID)
        }
        return .cancel(id: FallbackCancelID(worktreeID: state.worktree.id))

      case .fallbackFinished(let outcome):
        guard state.run != nil else { return .none }
        state.phase = .finished(outcome)
        return .none

      case .runFailed(let message):
        guard state.run != nil else { return .none }
        state.phase = .finished(.failed(message: message))
        return .none

      case .cancelTapped:
        switch state.phase {
        case .choosing:
          return .send(.delegate(.dismiss))
        case .running(let run) where run.stage == .requesting:
          // The injected request cannot be unsent; if the agent still hands
          // off, the CLI path completes headlessly and notifies.
          return .send(.delegate(.dismiss))
        case .running(let run) where run.stage == .forking:
          // Fork collection is the only cancellable fallback phase. No
          // artifact work begins until it reports a prepared briefing.
          return .merge(
            .cancel(id: FallbackCancelID(worktreeID: state.worktree.id)),
            .send(.delegate(.dismiss))
          )
        case .running:
          // The fallback crossed its commit boundary and must finish as one
          // transition; cancellation here would leave a partial handoff.
          return .none
        case .finished:
          return .none
        }

      case .closeTapped:
        guard case .finished = state.phase else { return .none }
        return .send(.delegate(.dismiss))

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Fallbacks

  private func makeCoordinator(_ state: State) -> HandoffCoordinator {
    let client = agentRuntimeClient
    return HandoffCoordinator(
      store: HandoffStore(rootURL: state.rootURL),
      resume: { request, workingDirectory in
        try await client.resume(request, in: workingDirectory)
      }
    )
  }

  private func startForkFallback(_ state: inout State) -> Effect<Action> {
    guard let forkRequest = state.source.forkRequest else {
      return startContextOnlyFallback(&state)
    }
    guard var run = state.run else { return .none }
    run.stage = .forking
    state.phase = .running(run)

    let coordinator = makeCoordinator(state)
    let worktreeID = state.worktree.id
    return .run { send in
      let briefing = try await coordinator.collectBriefing(.fork(forkRequest))
      await send(.fallbackBriefingCollected(briefing))
    } catch: { error, send in
      guard !(error is CancellationError) else { return }
      await send(.runFailed(message: error.localizedDescription))
    }
    .cancellable(id: FallbackCancelID(worktreeID: worktreeID), cancelInFlight: true)
  }

  private func startContextOnlyFallback(_ state: inout State) -> Effect<Action> {
    startFallbackCommit(&state, briefing: .contextOnly)
  }

  /// Crosses the fallback's visible commit boundary. From here onward the
  /// transition must run to one consistent outcome: archive/write/save/log and
  /// receiver launch cannot be independently cancelled.
  private func startFallbackCommit(
    _ state: inout State,
    briefing: HandoffPreparedBriefing
  ) -> Effect<Action> {
    guard var run = state.run else { return .none }
    run.stage = .finishing
    state.phase = .running(run)

    let target = run.target

    switch target.kind {
    case .briefOnly:
      return startCheckpointFallback(state, briefing: briefing)
    case .agent(let destination):
      return startRuntimeFallback(
        state,
        destination: destination,
        targetTitle: target.title,
        briefing: briefing
      )
    case .profile(let profileID, _):
      return startProfileFallback(state, profileID: profileID, briefing: briefing)
    }
  }

  private func startCheckpointFallback(
    _ state: State,
    briefing: HandoffPreparedBriefing
  ) -> Effect<Action> {
    let coordinator = makeCoordinator(state)
    let source = state.source
    let timestamp = now
    return .run { send in
      _ = try await coordinator.makeCheckpoint(
        outgoingAgent: source.agentToken,
        sessionContext: source.sessionContext,
        note: nil,
        briefing: briefing,
        now: timestamp
      )
      await send(.fallbackFinished(.briefSaved))
    } catch: { error, send in
      await send(.runFailed(message: error.localizedDescription))
    }
  }

  private func startRuntimeFallback(
    _ state: State,
    destination: DetectedAgent,
    targetTitle: String,
    briefing: HandoffPreparedBriefing
  ) -> Effect<Action> {
    let coordinator = makeCoordinator(state)
    let source = state.source
    let worktree = state.worktree
    let rootURL = state.rootURL
    let timestamp = now
    let client = terminalClient
    let configuration = inheritedConfiguration(source: source, destination: destination)
    return .run { send in
      let artifacts = try await coordinator.makeTransitionArtifacts(
        outgoingAgent: source.agentToken,
        toAgent: destination.rawValue,
        sessionContext: source.sessionContext,
        briefing: briefing,
        now: timestamp
      )
      let request = AgentStartRequest(
        agent: destination,
        intent: .prompt(HandoffCommandHandler.kickoffPrompt(hasBriefing: artifacts.hasBriefing)),
        configuration: configuration
      )
      let kickoff = try AgentRuntimeAdapterRegistry.makeStartInvocation(request).terminalInput
      await coordinator.logTransition(
        from: source.agentToken,
        toAgent: destination.rawValue,
        disposition: .requested,
        briefing: artifacts.briefing,
        source: "agents-hud",
        now: timestamp
      )
      await client.send(
        .createTabWithInput(
          worktree,
          input: kickoff,
          workingDirectory: rootURL,
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: "Hand off → \(targetTitle)",
          customCommandIcon: nil
        )
      )
      await send(.fallbackFinished(.handedOff(agentDisplayName: targetTitle)))
    } catch: { error, send in
      await send(.runFailed(message: error.localizedDescription))
    }
  }

  private func startProfileFallback(
    _ state: State,
    profileID: AgentProfile.ID,
    briefing: HandoffPreparedBriefing
  ) -> Effect<Action> {
    @Shared(.userGlobalSettings) var userGlobalSettings
    guard
      let profile = userGlobalSettings.agentProfiles.first(where: { $0.id == profileID }),
      profile.isEnabled
    else {
      return .send(.runFailed(message: "The selected Agent Profile is missing or disabled."))
    }
    let plan: AgentProfileLaunchPlan
    do {
      plan = try AgentProfileLaunchPlanner.plan(
        for: profile,
        homeBaseDirectory: SupacodePaths.agentProfileHomesDirectory,
        intent: .prompt(HandoffCommandHandler.kickoffPrompt(hasBriefing: briefing.outcome.wroteBriefing))
      )
    } catch {
      return .send(.runFailed(message: "The selected Agent Profile could not be prepared."))
    }
    let coordinator = makeCoordinator(state)
    let source = state.source
    let worktree = state.worktree
    let rootURL = state.rootURL
    let timestamp = now
    let client = terminalClient
    return .run { send in
      let artifacts = try await coordinator.makeTransitionArtifacts(
        outgoingAgent: source.agentToken,
        toAgent: profile.runtime.agent.rawValue,
        sessionContext: source.sessionContext,
        briefing: briefing,
        now: timestamp
      )
      guard
        let result = await client.launchAgentProfile(
          plan,
          worktree,
          .handoffBackgroundTab(root: rootURL)
        )
      else {
        await coordinator.logTransition(
          from: source.agentToken,
          toAgent: profile.runtime.agent.rawValue,
          disposition: .failed,
          briefing: artifacts.briefing,
          toProfileID: profile.id,
          toProfileName: profile.name,
          archivedPath: artifacts.archivedPath,
          source: "agents-hud",
          now: timestamp
        )
        await send(
          .fallbackFinished(
            .failed(message: "Progress was saved, but \(profile.name) could not be launched.")
          )
        )
        return
      }
      await coordinator.logTransition(
        from: source.agentToken,
        toAgent: profile.runtime.agent.rawValue,
        disposition: .pane(result.surfaceID.uuidString),
        briefing: artifacts.briefing,
        toProfileID: profile.id,
        toProfileName: profile.name,
        source: "agents-hud",
        now: timestamp
      )
      _ = await client.focusSurface(worktree.id, result.surfaceID)
      await send(.fallbackFinished(.handedOff(agentDisplayName: profile.name)))
    } catch: { error, send in
      await send(.runFailed(message: error.localizedDescription))
    }
  }

  private func inheritedConfiguration(
    source: HandoffHudSource,
    destination: DetectedAgent
  ) -> AgentLaunchConfiguration {
    guard let sourceAgent = DetectedAgent(rawValue: source.agentToken) else {
      return AgentLaunchConfiguration()
    }
    return AgentRuntimeAdapterRegistry.inheritedConfiguration(
      from: sourceAgent,
      observation: source.observation,
      to: destination
    )
  }
}
