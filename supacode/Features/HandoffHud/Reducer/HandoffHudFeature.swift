import ComposableArchitecture
import Foundation
import ProwlCLIShared

/// A row in the hand-off HUD's choose step.
struct HandoffTargetOption: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Hashable, Sendable {
    case agent(DetectedAgent)
    case briefOnly
  }

  let kind: Kind
  let title: String
  let subtitle: String
  /// The receiving agent equals the outgoing one (fresh-session restart).
  let isCurrentAgent: Bool

  var id: Kind { kind }

  var agent: DetectedAgent? {
    guard case .agent(let agent) = kind else { return nil }
    return agent
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
  let sessionContext: HandoffStore.SessionContext?
  let observation: AgentLaunchObservation?
}

enum HandoffStage: Equatable, Sendable {
  /// Request injected into the live source agent; waiting for its CLI call.
  case requesting
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
/// completion (`cliCompleted`) and finishes. Context-only is the explicit
/// fallback while waiting; Handoff never starts a hidden model turn from a
/// recorded native session.
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

    /// Build the HUD for a pane with a detected agent; nil without one — the
    /// no-source mechanical handoff stays CLI-only.
    static func make(worktree: Worktree, source: HandoffSourceContext?) -> State? {
      guard
        let sessionContext = source?.sessionContext,
        let agentToken = sessionContext.agent,
        let sourceSurfaceID = UUID(uuidString: sessionContext.paneID)
      else {
        return nil
      }
      let sourceAgent = DetectedAgent(rawValue: agentToken)
      // Handoff destination policy is independent from generic Profile launch
      // support. Expanding the runtime catalog must not expose a receiver until
      // its kickoff semantics and transition contract are explicitly verified.
      var targets = HandoffAgentSupport.launchableAgents.compactMap(DetectedAgent.init(rawValue:)).map { agent in
        HandoffTargetOption(
          kind: .agent(agent),
          title: AgentRuntimeAdapterRegistry.displayName(for: agent),
          subtitle: Self.launchSubtitle(
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
    case fallbackContextOnlyTapped

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
        let purpose: HandoffInjection.Purpose =
          switch target.kind {
          case .agent(let agent): .handOff(agent: agent.rawValue)
          case .briefOnly: .checkpoint
          }
        let requestID = uuid()
        handoffRequestClient.register(requestID)
        let delivered = terminalClient.sendTextToSurface(
          state.worktree.id,
          state.source.sourceSurfaceID,
          HandoffInjection.instruction(for: purpose, requestID: requestID)
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
        return startContextOnlyFallback(&state)

      case .fallbackContextOnlyTapped:
        guard
          let requestID = state.run?.requestID,
          handoffRequestClient.supersede(requestID)
        else { return .none }
        return startContextOnlyFallback(&state)

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
          guard completion.toAgent == nil else { return .none }
          state.phase = .finished(.briefSaved)
        case .agent(let expectedAgent):
          guard completion.toAgent == expectedAgent.rawValue, let launched = completion.launched,
            let paneID = UUID(uuidString: launched.paneID)
          else { return .none }
          state.phase = .finished(.handedOff(agentDisplayName: run.target.title))
          // The user is present and asked for this hand-off — jump to the
          // receiver. The transition core itself never focuses anything.
          _ = terminalClient.focusSurface(launched.worktreeID, paneID)
        }
        return .none

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
    HandoffCoordinator(store: HandoffStore(rootURL: state.rootURL))
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

    let coordinator = makeCoordinator(state)
    let source = state.source
    let worktree = state.worktree
    let rootURL = state.rootURL
    let target = run.target
    let timestamp = now
    let client = terminalClient

    switch target.kind {
    case .briefOnly:
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

    case .agent(let destination):
      let configuration = inheritedConfiguration(source: source, destination: destination)
      let targetTitle = target.title
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
