import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import supacode

@MainActor
struct HandoffHudFeatureTests {
  private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "handoff-hud-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func makeWorktree(root: URL) -> Worktree {
    Worktree(
      id: root.path(percentEncoded: false),
      name: "feature-handoff",
      detail: "feature-handoff",
      workingDirectory: root,
      repositoryRootURL: root
    )
  }

  private let sourcePaneID = UUID(uuidString: "5A0B7B44-11A2-4C6C-9A0F-2B93A8B0E001")!
  private let requestID = UUID(uuidString: "5A0B7B44-11A2-4C6C-9A0F-2B93A8B0E002")!

  private func makeSourceContext(
    agent: String = "codex",
    confidence: AgentSession.Confidence = .exact,
    observation: AgentLaunchObservation? = nil
  ) -> HandoffSourceContext {
    HandoffSourceContext(
      sessionContext: HandoffStore.SessionContext(
        agent: agent,
        paneID: sourcePaneID.uuidString,
        paneTitle: agent,
        source: "terminal-scrollback",
        confidence: "fallback",
        excerptText: "excerpt"
      ),
      observation: observation,
      session: AgentSession(
        id: "9B0E3B0E-67B3-4D45-A3A0-7DD9BC713711",
        transcriptPath: nil,
        source: .openFile,
        confidence: confidence
      )
    )
  }

  private nonisolated static let usableReply = """
    # Handoff

    ## Objective
    Finish the HUD.

    ## Current State
    Reducer under test.

    ## Next Steps
    1. Ship it.
    """

  private struct InjectedRequest: Equatable {
    let worktreeID: Worktree.ID
    let surfaceID: UUID
    let text: String
  }

  private func launchedPane(worktreeID: String) -> HandoffLaunchedPane {
    HandoffLaunchedPane(
      worktreeID: worktreeID,
      worktreeName: "feature-handoff",
      tabID: UUID().uuidString,
      paneID: UUID().uuidString,
      paneTitle: "claude"
    )
  }

  // MARK: - State construction

  @Test func makeRequiresDetectedAgentAndPaneIdentity() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)

    #expect(HandoffHudFeature.State.make(worktree: worktree, source: nil) == nil)
    let noAgent = HandoffSourceContext(
      sessionContext: HandoffStore.SessionContext(
        agent: nil,
        paneID: sourcePaneID.uuidString,
        paneTitle: nil,
        source: "terminal-scrollback",
        confidence: "fallback",
        excerptText: nil
      ),
      observation: nil,
      session: nil
    )
    #expect(HandoffHudFeature.State.make(worktree: worktree, source: noAgent) == nil)
    let noPaneUUID = HandoffSourceContext(
      sessionContext: HandoffStore.SessionContext(
        agent: "codex",
        paneID: "not-a-uuid",
        paneTitle: nil,
        source: "terminal-scrollback",
        confidence: "fallback",
        excerptText: nil
      ),
      observation: nil,
      session: nil
    )
    #expect(HandoffHudFeature.State.make(worktree: worktree, source: noPaneUUID) == nil)
  }

  @Test func makeBuildsRegistryTargetsAndMarksCurrentAgent() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let state = try #require(
      HandoffHudFeature.State.make(worktree: makeWorktree(root: root), source: makeSourceContext())
    )

    let agentKinds = state.targets.compactMap(\.agent)
    #expect(agentKinds == AgentRuntimeAdapterRegistry.launchableAgents)
    #expect(state.targets.last?.kind == .briefOnly)
    let codexTarget = try #require(state.targets.first { $0.agent == .codex })
    #expect(codexTarget.isCurrentAgent)
    let claudeTarget = try #require(state.targets.first { $0.agent == .claude })
    #expect(!claudeTarget.isCurrentAgent)
    #expect(state.source.forkRequest != nil)
    #expect(state.canFork)
    #expect(state.source.displayName == "codex")
    #expect(state.source.sourceSurfaceID == sourcePaneID)
  }

  @Test func makeOrdersRecommendedProfilesBeforeRuntimeDefaults() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let first = AgentProfile(name: "Claude · Personal", runtime: .claude)
    let recommended = AgentProfile(name: "Codex · Work", runtime: .codex)
    let disabled = AgentProfile(name: "Disabled", isEnabled: false, runtime: .codex)

    let state = try #require(
      HandoffHudFeature.State.make(
        worktree: makeWorktree(root: root),
        source: makeSourceContext(),
        profiles: [first, recommended, disabled],
        designatedProfileID: recommended.id
      )
    )

    #expect(state.selectedIndex == 0)
    #expect(
      state.targets.map(\.title) == [
        "Codex · Work", "Claude · Personal", "Claude Code", "Codex", "Only save progress, don't hand off",
      ])
    #expect(state.targets[0].kind == .profile(recommended.id, runtime: .codex))
    #expect(state.targets[0].subtitle.contains("Recommended"))
    #expect(state.targets[2].subtitle.hasPrefix("Runtime Default"))
  }

  @Test func makeWithMediumConfidenceSkipsForkRequest() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let state = try #require(
      HandoffHudFeature.State.make(
        worktree: makeWorktree(root: root),
        source: makeSourceContext(confidence: .medium)
      )
    )
    #expect(state.source.forkRequest == nil)
    #expect(!state.canFork)
  }

  @Test func makeSurfacesCarriedOverUnrestrictedMode() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let state = try #require(
      HandoffHudFeature.State.make(
        worktree: makeWorktree(root: root),
        source: makeSourceContext(
          observation: AgentLaunchObservation(model: "gpt-5.4", executionMode: .unrestricted)
        )
      )
    )
    let claudeTarget = try #require(state.targets.first { $0.agent == .claude })
    #expect(claudeTarget.subtitle.contains("bypass permissions"))
    #expect(claudeTarget.subtitle.contains("codex"))
    let briefTarget = try #require(state.targets.first { $0.kind == .briefOnly })
    #expect(!briefTarget.subtitle.contains("bypass"))
  }

  // MARK: - Selection

  @Test func selectionMovesWrapAround() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    var state = try #require(
      HandoffHudFeature.State.make(worktree: makeWorktree(root: root), source: makeSourceContext())
    )
    state.selectedIndex = 0
    let count = state.targets.count

    let store = TestStore(initialState: state) { HandoffHudFeature() }
    store.exhaustivity = .on

    await store.send(.moveSelection(delta: -1)) {
      $0.selectedIndex = count - 1
    }
    await store.send(.moveSelection(delta: 1)) {
      $0.selectedIndex = 0
    }
    await store.send(.setSelectedIndex(count))  // out of bounds: ignored
    await store.send(.setSelectedIndex(1)) {
      $0.selectedIndex = 1
    }
  }

  // MARK: - Inline path: inject, then observe the CLI completion

  @Test(.dependencies) func confirmInjectsRequestIntoSourcePane() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.selectedIndex = claudeIndex

    let injected = LockIsolated<[InjectedRequest]>([])
    let startedAt = Date(timeIntervalSince1970: 1_760_000_000)

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = startedAt
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { worktreeID, surfaceID, text in
        injected.withValue {
          $0.append(InjectedRequest(worktreeID: worktreeID, surfaceID: surfaceID, text: text))
        }
        return true
      }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .requesting, requestID: requestID)
      )
    }

    let request = try #require(injected.value.first)
    #expect(request.worktreeID == worktree.id)
    #expect(request.surfaceID == sourcePaneID)
    #expect(request.text.contains("prowl handoff to claude --pane \(sourcePaneID.uuidString) --brief -"))
    #expect(request.text.contains("\(HandoffInput.requestIDEnvironmentKey)=\(requestID.uuidString)"))
    #expect(request.text.contains("## Objective"))
    #expect(!request.text.contains("\n"))
  }

  @Test(.dependencies) func confirmProfileInjectsStableIDAndExplicitSourcePane() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    let profile = AgentProfile(name: "Codex · Work", runtime: .codex)
    let initial = try #require(
      HandoffHudFeature.State.make(
        worktree: worktree,
        source: makeSourceContext(),
        profiles: [profile]
      )
    )
    let registered = LockIsolated<HandoffRequestExpectation?>(nil)
    let injected = LockIsolated<String?>(nil)

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.uuid = UUIDGenerator { requestID }
      $0.handoffRequestClient = HandoffRequestClient(
        register: { _, expectation in registered.setValue(expectation) },
        supersede: { _ in true }
      )
      $0[TerminalClient.self].sendTextToSurface = { _, _, text in
        injected.setValue(text)
        return true
      }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[0],
          startedAt: Date(timeIntervalSince1970: 1_760_000_000),
          stage: .requesting,
          requestID: requestID
        )
      )
    }

    #expect(
      registered.value
        == HandoffRequestExpectation(
          sourcePaneID: sourcePaneID,
          operation: .handoff(target: .profile(profile.id))
        )
    )
    #expect(injected.value?.contains("--agent-profile-id \(profile.id.uuidString)") == true)
    #expect(injected.value?.contains("--pane \(sourcePaneID.uuidString)") == true)
    #expect(!((injected.value ?? "").contains(profile.name)))
  }

  @Test(.dependencies) func cliCompletionFromSourcePaneFinishesAndFocusesReceiver() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.selectedIndex = claudeIndex
    let launched = launchedPane(worktreeID: worktree.id)
    let focused = LockIsolated<[(Worktree.ID, UUID)]>([])

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
      $0[TerminalClient.self].focusSurface = { worktreeID, surfaceID in
        focused.withValue { $0.append((worktreeID, surfaceID)) }
        return true
      }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[claudeIndex], startedAt: Date(timeIntervalSince1970: 1_760_000_000), stage: .requesting,
          requestID: requestID)
      )
    }

    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .toAgent,
          sourcePaneID: sourcePaneID.uuidString,
          toAgent: "claude",
          briefing: .inline,
          launched: launched,
          requestID: requestID
        )
      )
    ) {
      $0.phase = .finished(.handedOff(agentDisplayName: "Claude Code"))
    }

    let (focusWorktreeID, focusSurfaceID) = try #require(focused.value.first)
    #expect(focusWorktreeID == launched.worktreeID)
    #expect(focusSurfaceID.uuidString == launched.paneID)
  }

  @Test(.dependencies) func profileLaunchFailureFinishesWithoutFocusing() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    let profile = AgentProfile(name: "Codex · Work", runtime: .codex)
    let initial = try #require(
      HandoffHudFeature.State.make(
        worktree: worktree,
        source: makeSourceContext(),
        profiles: [profile]
      )
    )
    let focused = LockIsolated(false)
    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
      $0[TerminalClient.self].focusSurface = { _, _ in
        focused.setValue(true)
        return true
      }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[0],
          startedAt: Date(timeIntervalSince1970: 1_760_000_000),
          stage: .requesting,
          requestID: requestID
        )
      )
    }
    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .toAgent,
          sourcePaneID: sourcePaneID.uuidString,
          toAgent: "codex",
          toProfileID: profile.id,
          toProfileName: profile.name,
          briefing: .inline,
          launched: nil,
          failureMessage: "Progress was saved, but Codex · Work could not be launched.",
          artifactsReady: true,
          requestID: requestID
        )
      )
    ) {
      $0.phase = .finished(
        .failed(message: "Progress was saved, but Codex · Work could not be launched.")
      )
    }
    #expect(focused.value == false)
  }

  @Test(.dependencies) func profileCompletionUsesLatestResolvedName() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    let profile = AgentProfile(name: "Codex · Work", runtime: .codex)
    let initial = try #require(
      HandoffHudFeature.State.make(
        worktree: worktree,
        source: makeSourceContext(),
        profiles: [profile]
      )
    )
    let launched = launchedPane(worktreeID: worktree.id)
    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
      $0[TerminalClient.self].focusSurface = { _, _ in true }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[0],
          startedAt: Date(timeIntervalSince1970: 1_760_000_000),
          stage: .requesting,
          requestID: requestID
        )
      )
    }
    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .toAgent,
          sourcePaneID: sourcePaneID.uuidString,
          toAgent: "codex",
          toProfileID: profile.id,
          toProfileName: "Codex · Renamed",
          briefing: .inline,
          launched: launched,
          requestID: requestID
        )
      )
    ) {
      $0.phase = .finished(.handedOff(agentDisplayName: "Codex · Renamed"))
    }
  }

  @Test(.dependencies) func cliCompletionFromOtherPaneOrActionIsIgnored() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.selectedIndex = claudeIndex

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[claudeIndex], startedAt: Date(timeIntervalSince1970: 1_760_000_000), stage: .requesting,
          requestID: requestID)
      )
    }

    // Another pane's handoff: not ours.
    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .toAgent,
          sourcePaneID: UUID().uuidString,
          toAgent: "claude",
          briefing: .inline,
          launched: nil,
          requestID: requestID
        )
      )
    )
    // Our pane, but a checkpoint — the run waits for a transition.
    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .save,
          sourcePaneID: sourcePaneID.uuidString,
          toAgent: nil,
          briefing: .inline,
          launched: nil,
          requestID: requestID
        )
      )
    )
    // Our pane and request, but a different destination: not this HUD run.
    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .toAgent,
          sourcePaneID: sourcePaneID.uuidString,
          toAgent: "codex",
          briefing: .inline,
          launched: launchedPane(worktreeID: worktree.id),
          requestID: requestID
        )
      )
    )
    // A matching destination without a receiver is still not a completed handoff.
    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .toAgent,
          sourcePaneID: sourcePaneID.uuidString,
          toAgent: "claude",
          briefing: .inline,
          launched: nil,
          requestID: requestID
        )
      )
    )
  }

  @Test(.dependencies) func briefOnlyCompletionFinishesAsSaved() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let briefIndex = try #require(initial.targets.firstIndex { $0.kind == .briefOnly })
    initial.selectedIndex = briefIndex
    let injected = LockIsolated<[String]>([])

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, text in
        injected.withValue { $0.append(text) }
        return true
      }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[briefIndex], startedAt: Date(timeIntervalSince1970: 1_760_000_000), stage: .requesting,
          requestID: requestID)
      )
    }
    #expect(
      injected.value.first?.contains("prowl handoff save --pane \(sourcePaneID.uuidString) --brief -") == true
    )

    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .save,
          sourcePaneID: sourcePaneID.uuidString,
          toAgent: nil,
          briefing: .inline,
          launched: nil,
          requestID: requestID
        )
      )
    ) {
      $0.phase = .finished(.briefSaved)
    }
  }

  // MARK: - Fallbacks

  @Test(.dependencies) func forkFallbackRunsTransitionAndLaunches() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.selectedIndex = claudeIndex

    let sent = LockIsolated<[TerminalClient.Command]>([])
    let startedAt = Date(timeIntervalSince1970: 1_760_000_000)
    let requestRegistry = HandoffRequestRegistry()

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = startedAt
      $0.uuid = UUIDGenerator { requestID }
      $0.handoffRequestClient = HandoffRequestClient(
        register: { requestID, expectation in
          requestRegistry.register(requestID, expectation: expectation)
        },
        supersede: { requestRegistry.supersede($0) }
      )

      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
      $0[TerminalClient.self].send = { command in
        sent.withValue { $0.append(command) }
      }
      $0[AgentRuntimeClient.self] = AgentRuntimeClient(resume: { _, _ in Self.usableReply })
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .requesting, requestID: requestID)
      )
    }
    await store.send(.fallbackForkTapped) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .forking, requestID: requestID)
      )
    }
    #expect(
      requestRegistry.claim(
        requestID,
        actual: HandoffRequestExpectation(
          sourcePaneID: sourcePaneID,
          operation: .handoff(target: .runtimeDefault(.claude))
        )
      ) == .unavailable
    )
    await store.receive(\.fallbackBriefingCollected) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .finishing, requestID: requestID)
      )
    }

    await store.receive(\.fallbackFinished) {
      $0.phase = .finished(.handedOff(agentDisplayName: "Claude Code"))
    }

    // The transition persisted the forked briefing and launched visibly.
    let store2 = HandoffStore(rootURL: root)
    let current = try String(contentsOf: store2.currentURL, encoding: .utf8)
    #expect(current.contains("Finish the HUD."))
    let log = try String(contentsOf: store2.logURL, encoding: .utf8)
    #expect(log.contains("codex → claude"))
    #expect(log.contains("briefing=fork"))
    #expect(log.contains("source=agents-hud"))
    let commands = sent.value
    #expect(
      commands.contains { command in
        if case .createTabWithInput(let commandWorktree, let input, _, _, _, _, _) = command {
          return commandWorktree.id == worktree.id && input.contains("claude")
        }
        return false
      }
    )
  }

  @Test(.dependencies) func contextOnlyFallbackRemovesStaleBriefing() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    let handoffStore = HandoffStore(rootURL: root)
    try handoffStore.writeBriefing(
      "# Handoff\n\n## Objective\nStale.\n\n## Current State\nx\n\n## Next Steps\n1. y\n",
      archivingPrevious: false,
      now: Date(timeIntervalSince1970: 1_759_000_000)
    )
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.selectedIndex = claudeIndex
    let startedAt = Date(timeIntervalSince1970: 1_760_000_000)

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = startedAt
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
      $0[TerminalClient.self].send = { _ in }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .requesting, requestID: requestID)
      )
    }
    await store.send(.fallbackContextOnlyTapped) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .finishing, requestID: requestID)

      )
    }
    await store.receive(\.fallbackFinished) {
      $0.phase = .finished(.handedOff(agentDisplayName: "Claude Code"))
    }

    // Context-only: the stale briefing was archived away, never handed over.
    #expect(!handoffStore.hasCurrentArtifact)
    let log = try String(contentsOf: handoffStore.logURL, encoding: .utf8)
    #expect(log.contains("briefing=none"))
  }

  @Test(.dependencies) func profileFallbackUsesSharedLauncherAndFocusesExactSurface() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    let profile = AgentProfile(
      name: "Codex · Work",
      runtime: .codex,
      model: "profile-model",
      placement: .split,
      extraArguments: "-p work",
      environmentOverrides: [
        AgentProfileEnvironmentOverride(name: "OPENAI_API_KEY", value: "secret")
      ]
    )
    let initial = try #require(
      HandoffHudFeature.State.make(
        worktree: worktree,
        source: makeSourceContext(
          observation: AgentLaunchObservation(model: "outgoing-model", executionMode: .unrestricted)
        ),
        profiles: [profile]
      )
    )
    let storage = SettingsTestStorage()
    let launchedPlan = LockIsolated<AgentProfileLaunchPlan?>(nil)
    let launchContext = LockIsolated<AgentProfileLaunchContext?>(nil)
    let launchedSurfaceID = UUID()
    let focused = LockIsolated<UUID?>(nil)

    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }
      return TestStore(initialState: initial) {
        HandoffHudFeature()
      } withDependencies: {
        $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
        $0.uuid = UUIDGenerator { requestID }
        $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
        $0[TerminalClient.self].launchAgentProfile = { plan, launchedWorktree, context in
          #expect(launchedWorktree == worktree)
          launchedPlan.setValue(plan)
          launchContext.setValue(context)
          return AgentProfileLaunchResult(
            tabID: TerminalTabID(),
            surfaceID: launchedSurfaceID,
            paneTitle: profile.name
          )
        }
        $0[TerminalClient.self].focusSurface = { _, surfaceID in
          focused.setValue(surfaceID)
          return true
        }
      }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[0],
          startedAt: Date(timeIntervalSince1970: 1_760_000_000),
          stage: .requesting,
          requestID: requestID
        )
      )
    }
    await store.send(.fallbackContextOnlyTapped) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[0],
          startedAt: Date(timeIntervalSince1970: 1_760_000_000),
          stage: .finishing,
          requestID: requestID
        )
      )
    }
    await store.receive(\.fallbackFinished) {
      $0.phase = .finished(.handedOff(agentDisplayName: profile.name))
    }

    let plan = try #require(launchedPlan.value)
    #expect(plan.profileID == profile.id)
    #expect(plan.invocation.arguments.contains("profile-model"))
    #expect(plan.invocation.arguments.contains("work"))
    #expect(!plan.terminalInput.contains("outgoing-model"))
    #expect(plan.surfaceEnvironment["PROWL_ENV_OPENAI_API_KEY"] == "secret")
    guard case .handoffBackgroundTab(let launchRoot) = launchContext.value else {
      Issue.record("Expected a handoff background launch context")
      return
    }
    #expect(launchRoot == root)
    #expect(focused.value == launchedSurfaceID)
    let log = try String(contentsOf: HandoffStore(rootURL: root).logURL, encoding: .utf8)
    #expect(log.contains("profile_id=\(profile.id.uuidString)"))
    #expect(!log.contains("secret"))
  }

  @Test(.dependencies) func deletedProfileFallbackFailsBeforeArtifacts() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    let profile = AgentProfile(name: "Deleted", runtime: .codex)
    let initial = try #require(
      HandoffHudFeature.State.make(
        worktree: worktree,
        source: makeSourceContext(),
        profiles: [profile]
      )
    )
    let storage = SettingsTestStorage()
    let launched = LockIsolated(false)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: initial) {
        HandoffHudFeature()
      } withDependencies: {
        $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
        $0.uuid = UUIDGenerator { requestID }
        $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
        $0[TerminalClient.self].launchAgentProfile = { _, _, _ in
          launched.setValue(true)
          return nil
        }
      }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[0],
          startedAt: Date(timeIntervalSince1970: 1_760_000_000),
          stage: .requesting,
          requestID: requestID
        )
      )
    }
    await store.send(.fallbackContextOnlyTapped) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[0],
          startedAt: Date(timeIntervalSince1970: 1_760_000_000),
          stage: .finishing,
          requestID: requestID
        )
      )
    }
    await store.receive(\.runFailed) {
      $0.phase = .finished(.failed(message: "The selected Agent Profile is missing or disabled."))
    }

    #expect(launched.value == false)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
  }

  @Test(.dependencies) func failedInjectionFallsBackAutomatically() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.selectedIndex = claudeIndex
    let startedAt = Date(timeIntervalSince1970: 1_760_000_000)

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = startedAt
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in false }
      $0[TerminalClient.self].send = { _ in }
      $0[AgentRuntimeClient.self] = AgentRuntimeClient(resume: { _, _ in Self.usableReply })
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .forking, requestID: requestID)
      )
    }
    await store.receive(\.fallbackBriefingCollected) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .finishing, requestID: requestID)
      )
    }

    await store.receive(\.fallbackFinished) {
      $0.phase = .finished(.handedOff(agentDisplayName: "Claude Code"))
    }
  }

  // MARK: - Cancellation

  @Test(.dependencies) func cancelWhileRequestingDismisses() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.selectedIndex = claudeIndex

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(
          target: $0.targets[claudeIndex], startedAt: Date(timeIntervalSince1970: 1_760_000_000), stage: .requesting,
          requestID: requestID)
      )
    }
    await store.send(.cancelTapped)
    await store.receive(\.delegate.dismiss)
  }

  @Test(.dependencies) func cancelWhileForkingAbortsWithoutWriting() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let worktree = makeWorktree(root: root)
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: worktree, source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.selectedIndex = claudeIndex
    let startedAt = Date(timeIntervalSince1970: 1_760_000_000)

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    } withDependencies: {
      $0.date.now = startedAt
      $0.uuid = UUIDGenerator { requestID }
      $0[TerminalClient.self].sendTextToSurface = { _, _, _ in true }
      $0[TerminalClient.self].send = { _ in }
      $0[AgentRuntimeClient.self] = AgentRuntimeClient(resume: { _, _ in
        try await Task.never()
      })
    }

    await store.send(.confirmSelection) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .requesting, requestID: requestID)
      )
    }
    await store.send(.fallbackForkTapped) {
      $0.phase = .running(
        HandoffHudRun(target: $0.targets[claudeIndex], startedAt: startedAt, stage: .forking, requestID: requestID)
      )
    }
    // A delayed CLI completion from the injected request cannot replace the
    // fallback that already superseded it.
    await store.send(
      .cliCompleted(
        HandoffCLICompletion(
          action: .toAgent,
          sourcePaneID: sourcePaneID.uuidString,
          toAgent: "claude",
          briefing: .inline,
          launched: launchedPane(worktreeID: worktree.id),
          requestID: requestID
        )
      )
    )
    await store.send(.cancelTapped)
    await store.receive(\.delegate.dismiss)
    await store.finish()

    // The aborted fork never touched the filesystem.
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
  }

  @Test func cancelWhileFinishingIsIgnored() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    var initial = try #require(
      HandoffHudFeature.State.make(worktree: makeWorktree(root: root), source: makeSourceContext())
    )
    let claudeIndex = try #require(initial.targets.firstIndex { $0.agent == .claude })
    initial.phase = .running(
      HandoffHudRun(
        target: initial.targets[claudeIndex],
        startedAt: Date(timeIntervalSince1970: 1_760_000_000),
        stage: .finishing,
        requestID: requestID
      )
    )

    let store = TestStore(initialState: initial) {
      HandoffHudFeature()
    }

    await store.send(.cancelTapped)
    await store.finish()
  }

}
