import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AgentObservationTests {
  @Test func liveShellStartsWithAtomicEmptySnapshotAndReplaysLatestSignal() async throws {
    let fixture = makeFixture()
    let firstStream = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID)
    var firstIterator = firstStream.makeAsyncIterator()

    let first = try await firstIterator.next()
    guard case .snapshot(let initial) = first else {
      Issue.record("Expected snapshot first")
      return
    }
    #expect(initial.agent == nil)
    #expect(initial.latestSignal == nil)
    #expect(initial.revision == 0)

    let signal = makeSignal()
    #expect(fixture.manager.recordAgentSignal(signal, surfaceID: fixture.surfaceID))
    #expect(try await firstIterator.next() == .signal(signal))

    let secondStream = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID)
    var secondIterator = secondStream.makeAsyncIterator()
    guard case .snapshot(let replay) = try await secondIterator.next() else {
      Issue.record("Expected replay snapshot first")
      return
    }
    #expect(replay.agent == nil)
    #expect(replay.latestSignal == signal)
    #expect(replay.revision == 1)
  }

  @Test func signalIsMulticastToIndependentSubscribers() async throws {
    let fixture = makeFixture()
    var first = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID).makeAsyncIterator()
    var second = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID).makeAsyncIterator()
    _ = try await first.next()
    _ = try await second.next()

    let signal = makeSignal(detail: "Review complete")
    #expect(fixture.manager.recordAgentSignal(signal, surfaceID: fixture.surfaceID))

    #expect(try await first.next() == .signal(signal))
    #expect(try await second.next() == .signal(signal))
  }

  @Test func publishedAgentRemovalPrecedesSurfaceClosureAndFinishesStream() async throws {
    let fixture = makeFixture()
    var iterator = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID).makeAsyncIterator()
    _ = try await iterator.next()

    fixture.state.emitAgentEntry(
      surfaceID: fixture.surfaceID,
      tabId: fixture.tabID,
      state: PaneAgentState(detectedAgent: .claude, state: .working)
    )
    guard case .changed(let entry) = try await iterator.next() else {
      Issue.record("Expected changed event")
      return
    }
    #expect(entry.surfaceID == fixture.surfaceID)

    #expect(fixture.state.closeSurface(id: fixture.surfaceID, confirmation: .skip))
    #expect(try await iterator.next() == .removed)
    #expect(try await iterator.next() == .surfaceClosed)
    #expect(try await iterator.next() == nil)
  }

  @Test func shellWithoutPublishedAgentClosesWithoutFalseRemoval() async throws {
    let fixture = makeFixture()
    fixture.state.wakeAgentDetection(forSurfaceID: fixture.surfaceID)
    var iterator = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID).makeAsyncIterator()
    _ = try await iterator.next()

    #expect(fixture.state.closeSurface(id: fixture.surfaceID, confirmation: .skip))
    #expect(try await iterator.next() == .surfaceClosed)
    #expect(try await iterator.next() == nil)
  }

  @Test func agentRemovalDoesNotCloseObserverAndLaterSignalStillArrives() async throws {
    let fixture = makeFixture()
    var iterator = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID).makeAsyncIterator()
    _ = try await iterator.next()
    fixture.state.emitAgentEntry(
      surfaceID: fixture.surfaceID,
      tabId: fixture.tabID,
      state: PaneAgentState(detectedAgent: .claude, state: .working)
    )
    _ = try await iterator.next()

    fixture.state.emitAgentEntry(
      surfaceID: fixture.surfaceID,
      tabId: fixture.tabID,
      state: PaneAgentState()
    )
    #expect(try await iterator.next() == .removed)

    let signal = makeSignal()
    #expect(fixture.manager.recordAgentSignal(signal, surfaceID: fixture.surfaceID))
    #expect(try await iterator.next() == .signal(signal))
  }

  @Test func closeAllAndPruneFinishEverySurfaceObserver() async throws {
    let closeAllFixture = makeFixture()
    var closeAllIterator = closeAllFixture.manager
      .observeAgentState(surfaceID: closeAllFixture.surfaceID)
      .makeAsyncIterator()
    _ = try await closeAllIterator.next()
    closeAllFixture.state.emitAgentEntry(
      surfaceID: closeAllFixture.surfaceID,
      tabId: closeAllFixture.tabID,
      state: PaneAgentState(detectedAgent: .claude, state: .working)
    )
    guard case .changed = try await closeAllIterator.next() else {
      Issue.record("Expected published agent before close-all")
      return
    }

    closeAllFixture.state.closeAllSurfaces()
    #expect(try await closeAllIterator.next() == .removed)
    #expect(try await closeAllIterator.next() == .surfaceClosed)
    #expect(try await closeAllIterator.next() == nil)

    let pruneFixture = makeFixture()
    var pruneIterator = pruneFixture.manager
      .observeAgentState(surfaceID: pruneFixture.surfaceID)
      .makeAsyncIterator()
    _ = try await pruneIterator.next()
    pruneFixture.state.emitAgentEntry(
      surfaceID: pruneFixture.surfaceID,
      tabId: pruneFixture.tabID,
      state: PaneAgentState(detectedAgent: .codex, state: .working)
    )
    guard case .changed = try await pruneIterator.next() else {
      Issue.record("Expected published agent before prune")
      return
    }

    pruneFixture.manager.prune(keeping: [])
    #expect(try await pruneIterator.next() == .removed)
    #expect(try await pruneIterator.next() == .surfaceClosed)
    #expect(try await pruneIterator.next() == nil)
  }

  @Test func cancellationRemovesOnlyTheCancelledSubscriber() async throws {
    let fixture = makeFixture()
    let firstStream = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID)
    let secondStream = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID)
    #expect(fixture.manager.agentObservationSubscriberCount(surfaceID: fixture.surfaceID) == 2)

    let task = Task {
      for try await _ in firstStream {}
    }
    await Task.yield()
    task.cancel()
    _ = await task.result
    for _ in 0..<10 where fixture.manager.agentObservationSubscriberCount(surfaceID: fixture.surfaceID) == 2 {
      await Task.yield()
    }

    #expect(fixture.manager.agentObservationSubscriberCount(surfaceID: fixture.surfaceID) == 1)
    var secondIterator = secondStream.makeAsyncIterator()
    _ = try await secondIterator.next()
    let signal = makeSignal()
    #expect(fixture.manager.recordAgentSignal(signal, surfaceID: fixture.surfaceID))
    #expect(try await secondIterator.next() == .signal(signal))
  }

  @Test func closedSurfaceProducesSnapshotThenSurfaceClosed() async throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    var iterator = manager.observeAgentState(surfaceID: UUID()).makeAsyncIterator()

    guard case .snapshot(let snapshot) = try await iterator.next() else {
      Issue.record("Expected snapshot first")
      return
    }
    #expect(snapshot.agent == nil)
    #expect(snapshot.latestSignal == nil)
    #expect(try await iterator.next() == .surfaceClosed)
    #expect(try await iterator.next() == nil)
  }

  @Test func signalFromPaneWithoutDetectedAgentIsRecordedButUnbound() {
    let fixture = makeFixture()
    let signal = makeSignal(detail: "from a plain shell")
    let caller = CallerPane(
      worktreeID: "/tmp/agent-observation",
      surfaceID: fixture.surfaceID,
      processAncestry: []
    )

    #expect(fixture.manager.recordAgentSignal(signal, caller: caller) == .recorded(binding: .unbound))
    #expect(fixture.manager.currentEligibleAgentSignal(surfaceID: fixture.surfaceID) == nil)
    let diagnostics = fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID)
    #expect(diagnostics.channels.isEmpty)
    #expect(diagnostics.last?.detail == "from a plain shell")
    #expect(diagnostics.lastBinding == .unbound)
  }

  @Test func signalForClosedSurfaceReportsPaneGone() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let caller = CallerPane(worktreeID: "/tmp/agent-observation", surfaceID: UUID(), processAncestry: [])
    #expect(manager.recordAgentSignal(makeSignal(), caller: caller) == .paneGone)
  }

  @Test func normalizedWorkingActivityInvalidatesPriorTerminalEvidence() throws {
    let fixture = makeFixture()
    let processID = getpid()
    let startedAt = try #require(ProcessDetection.processStartDate(pid: processID))
    let session = AgentSession(
      id: "session-1",
      transcriptPath: nil,
      source: .commandLine,
      confidence: .exact
    )
    let idleState = PaneAgentState(
      detectedAgent: .pi,
      agentProcessID: processID,
      session: session,
      state: .idle
    )
    fixture.state.surfaceAgentStates[fixture.surfaceID] = idleState
    fixture.state.emitAgentEntry(
      surfaceID: fixture.surfaceID,
      tabId: fixture.tabID,
      state: idleState
    )
    let signal = makeSignal()
    let caller = CallerPane(
      worktreeID: "/tmp/agent-observation",
      surfaceID: fixture.surfaceID,
      processAncestry: [
        AgentProcessGeneration(pid: processID, startedAt: startedAt)
      ]
    )

    #expect(fixture.manager.recordAgentSignal(signal, caller: caller) == .recorded(binding: .current))
    #expect(fixture.manager.currentEligibleAgentSignal(surfaceID: fixture.surfaceID) == signal)

    let workingState = PaneAgentState(
      detectedAgent: .pi,
      agentProcessID: processID,
      session: session,
      state: .working
    )
    fixture.state.surfaceAgentStates[fixture.surfaceID] = workingState
    fixture.state.emitAgentEntry(
      surfaceID: fixture.surfaceID,
      tabId: fixture.tabID,
      state: workingState
    )

    #expect(fixture.manager.currentEligibleAgentSignal(surfaceID: fixture.surfaceID) == nil)
    let diagnostics = fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID)
    #expect(diagnostics.last?.event == .turnEnded)
    #expect(diagnostics.lastBinding == .current)
  }

  @Test func mediumSessionGuessDoesNotRejectCurrentGenerationSignal() throws {
    let fixture = makeFixture()
    let processID = getpid()
    let startedAt = try #require(ProcessDetection.processStartDate(pid: processID))
    let state = PaneAgentState(
      detectedAgent: .pi,
      agentProcessID: processID,
      session: AgentSession(
        id: "guessed-session",
        transcriptPath: nil,
        source: .recentFile,
        confidence: .medium
      ),
      state: .idle
    )
    fixture.state.surfaceAgentStates[fixture.surfaceID] = state
    fixture.state.emitAgentEntry(
      surfaceID: fixture.surfaceID,
      tabId: fixture.tabID,
      state: state
    )
    let signal = AgentSignal(
      kind: .turnEnded,
      source: .hook(runtime: .pi, event: "agent_end"),
      confidence: .exact,
      timestamp: Date(timeIntervalSince1970: 1_000),
      sessionID: "actual-session",
      detail: nil,
      claimedOrigin: nil
    )
    let caller = CallerPane(
      worktreeID: "/tmp/agent-observation",
      surfaceID: fixture.surfaceID,
      processAncestry: [
        AgentProcessGeneration(pid: processID, startedAt: startedAt)
      ]
    )

    #expect(fixture.manager.recordAgentSignal(signal, caller: caller) == .recorded(binding: .current))
    #expect(fixture.manager.currentEligibleAgentSignal(surfaceID: fixture.surfaceID) == signal)
    #expect(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).lastBinding == .current)
  }

  @Test func mediumToHighSessionCorrectionKeepsSessionlessSignalCurrent() throws {
    let fixture = makeFixture()
    let processID = getpid()
    let startedAt = try #require(ProcessDetection.processStartDate(pid: processID))
    let mediumState = PaneAgentState(
      detectedAgent: .pi,
      agentProcessID: processID,
      session: AgentSession(
        id: "guessed-session",
        transcriptPath: nil,
        source: .recentFile,
        confidence: .medium
      ),
      state: .idle
    )
    fixture.state.surfaceAgentStates[fixture.surfaceID] = mediumState
    fixture.state.emitAgentEntry(
      surfaceID: fixture.surfaceID,
      tabId: fixture.tabID,
      state: mediumState
    )
    let signal = AgentSignal(
      kind: .turnEnded,
      source: .cooperativeCLI,
      confidence: .exact,
      timestamp: Date(timeIntervalSince1970: 1_000),
      sessionID: nil,
      detail: nil,
      claimedOrigin: nil
    )
    let caller = CallerPane(
      worktreeID: "/tmp/agent-observation",
      surfaceID: fixture.surfaceID,
      processAncestry: [
        AgentProcessGeneration(pid: processID, startedAt: startedAt)
      ]
    )
    #expect(fixture.manager.recordAgentSignal(signal, caller: caller) == .recorded(binding: .current))
    #expect(fixture.manager.currentEligibleAgentSignal(surfaceID: fixture.surfaceID) == signal)

    fixture.state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState(
      detectedAgent: .pi,
      agentProcessID: processID,
      session: AgentSession(
        id: "actual-session",
        transcriptPath: nil,
        source: .transcriptMatch,
        confidence: .high
      ),
      state: .idle
    )

    #expect(fixture.manager.currentEligibleAgentSignal(surfaceID: fixture.surfaceID) == signal)
    #expect(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).lastBinding == .current)
  }

  @Test func boundedOverflowIsExplicitAndRecoverableByResubscription() async throws {
    let fixture = makeFixture(bufferCapacity: 1)
    let stream = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID)
    let signal = makeSignal()

    // Leave the initial snapshot buffered so the next critical event overflows.
    #expect(fixture.manager.recordAgentSignal(signal, surfaceID: fixture.surfaceID))

    var iterator = stream.makeAsyncIterator()
    guard case .snapshot = try await iterator.next() else {
      Issue.record("Expected the protected initial snapshot")
      return
    }
    do {
      _ = try await iterator.next()
      Issue.record("Expected explicit buffer overflow")
    } catch let error as AgentObservationError {
      #expect(error == .bufferOverflow)
    }

    var replacement = fixture.manager.observeAgentState(surfaceID: fixture.surfaceID).makeAsyncIterator()
    guard case .snapshot(let snapshot) = try await replacement.next() else {
      Issue.record("Expected resubscription snapshot")
      return
    }
    #expect(snapshot.latestSignal == signal)
  }

  @Test func engineChildRebindingKeepsTheLaunchGenerationCurrent() throws {
    let fixture = makeFixture()
    let engine = try makeEngineChild()
    defer { engine.terminate() }
    let launchPID = getpid()
    let launchStartedAt = try #require(ProcessDetection.processStartDate(pid: launchPID))
    let engineStartedAt = try #require(ProcessDetection.processStartDate(pid: engine.processIdentifier))
    let launchOnly = PaneAgentState(
      detectedAgent: .droid,
      agentProcessID: launchPID,
      launchProcessID: launchPID,
      state: .idle
    )
    fixture.state.surfaceAgentStates[fixture.surfaceID] = launchOnly
    fixture.state.emitAgentEntry(surfaceID: fixture.surfaceID, tabId: fixture.tabID, state: launchOnly)
    let signal = makeSignal()
    let caller = CallerPane(
      worktreeID: "/tmp/agent-observation",
      surfaceID: fixture.surfaceID,
      processAncestry: [
        AgentProcessGeneration(pid: engine.processIdentifier, startedAt: engineStartedAt),
        AgentProcessGeneration(pid: launchPID, startedAt: launchStartedAt),
      ]
    )
    #expect(fixture.manager.recordAgentSignal(signal, caller: caller) == .recorded(binding: .current))
    #expect(fixture.manager.currentEligibleAgentSignal(surfaceID: fixture.surfaceID) == signal)

    // The runtime forks an engine child that the classifier now identifies
    // instead of the launcher (Droid's `droid exec`). Same launch, same
    // generation: the evidence must survive.
    let engineBound = PaneAgentState(
      detectedAgent: .droid,
      agentProcessID: engine.processIdentifier,
      launchProcessID: launchPID,
      state: .idle
    )
    fixture.state.surfaceAgentStates[fixture.surfaceID] = engineBound
    fixture.state.emitAgentEntry(surfaceID: fixture.surfaceID, tabId: fixture.tabID, state: engineBound)

    #expect(fixture.manager.currentEligibleAgentSignal(surfaceID: fixture.surfaceID) == signal)
    #expect(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).lastBinding == .current)
  }

  @Test func engineChildRebindingKeepsTheManagedHookVerifiable() throws {
    let fixture = makeFixture()
    let engine = try makeEngineChild()
    defer { engine.terminate() }
    let launchPID = getpid()
    let launchStartedAt = try #require(ProcessDetection.processStartDate(pid: launchPID))
    let engineStartedAt = try #require(ProcessDetection.processStartDate(pid: engine.processIdentifier))
    let registration = AgentHookLaunchRegistration(
      token: "token-123",
      runtime: .droid,
      launchCWD: URL(filePath: "/tmp/agent-observation", directoryHint: .isDirectory),
      nativeEvents: ["SessionStart": .sessionStart, "Stop": .turnEnded],
      coveredEvents: [.sessionStart, .turnEnded],
      forwardingRecord: nil
    )
    let plan = AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Droid",
      runtime: .droid,
      invocation: AgentInvocation(executable: "droid", arguments: []),
      hookRegistration: registration,
      commandEnvironmentTokens: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: [:],
      dedicatedHome: nil
    )
    #expect(fixture.state.onAgentProfileSurfacePrepared?(fixture.surfaceID, plan) == true)

    for (identified, state) in [(launchPID, AgentRawState.idle), (engine.processIdentifier, .working)] {
      let paneState = PaneAgentState(
        detectedAgent: .droid,
        agentProcessID: identified,
        launchProcessID: launchPID,
        state: state
      )
      fixture.state.surfaceAgentStates[fixture.surfaceID] = paneState
      fixture.state.emitAgentEntry(surfaceID: fixture.surfaceID, tabId: fixture.tabID, state: paneState)
    }

    let input = AgentNativeHookInput(
      runtime: .droid,
      token: "token-123",
      signal: AgentNativeHookSignal(
        event: .turnEnded,
        nativeEvent: "Stop",
        cwd: "/tmp/agent-observation",
        sessionID: "session-1"
      )
    )
    let caller = CallerPane(
      worktreeID: "/tmp/agent-observation",
      surfaceID: fixture.surfaceID,
      processAncestry: [
        AgentProcessGeneration(pid: engine.processIdentifier, startedAt: engineStartedAt),
        AgentProcessGeneration(pid: launchPID, startedAt: launchStartedAt),
      ]
    )
    #expect(fixture.manager.recordAgentNativeHook(input, caller: caller))
    let channel = try #require(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).channels.first)
    #expect(channel.source == "hook_droid")
    #expect(channel.state == .verifiedLive)
  }

  /// Oh My Pi rotates through `session_switch` (no `session_start`); a repeated `session_start`
  /// for the current id (Pi `reload`) is idempotent (docs-ai 064.010).
  @Test func ompSessionSwitchRotatesTheManagedSessionAndDelayedStopsAreRejected() throws {
    let fixture = makeFixture()
    let table = AgentNativeHookDecoder.nativeEvents(for: .omp)
    let caller = try registerRelayedRuntime(.omp, table: table, fixture: fixture)
    func hook(_ nativeEvent: String, session: String) -> AgentNativeHookInput {
      AgentNativeHookInput(
        runtime: .omp,
        token: "token-relayed",
        signal: AgentNativeHookSignal(
          event: table[nativeEvent]!,
          nativeEvent: nativeEvent,
          cwd: "/tmp/agent-observation",
          sessionID: session
        )
      )
    }

    #expect(fixture.manager.recordAgentNativeHook(hook("session_start", session: "S1"), caller: caller))
    #expect(fixture.manager.recordAgentNativeHook(hook("session_stop", session: "S1"), caller: caller))
    var channel = try #require(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).channels.first)
    #expect(channel.source == "hook_omp")
    #expect(channel.state == .verifiedLive)
    #expect(channel.sessionID == "S1")
    #expect(channel.events.contains(.turnEnded))

    // `/new`: a single `session_switch` carries the new id.
    #expect(fixture.manager.recordAgentNativeHook(hook("session_switch", session: "S2"), caller: caller))
    channel = try #require(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).channels.first)
    #expect(channel.sessionID == "S2")
    #expect(channel.state == .verifiedLive)
    #expect(!fixture.manager.recordAgentNativeHook(hook("session_stop", session: "S1"), caller: caller))
    #expect(fixture.manager.recordAgentNativeHook(hook("session_stop", session: "S2"), caller: caller))

    // Re-announcing the current id is idempotent, never a rotation.
    #expect(fixture.manager.recordAgentNativeHook(hook("session_start", session: "S2"), caller: caller))
    channel = try #require(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).channels.first)
    #expect(channel.sessionID == "S2")
    #expect(channel.state == .verifiedLive)
  }

  /// OpenCode declares no SessionStart (its session is created lazily and `/new` / resume emit
  /// nothing), so like Codex the first ordinary event verifies and a new id rotates.
  @Test func opencodeIsNonAnnouncingSoTheFirstIdleVerifiesAndANewSessionRotates() throws {
    let fixture = makeFixture()
    let table = AgentNativeHookDecoder.nativeEvents(for: .opencode)
    let caller = try registerRelayedRuntime(.opencode, table: table, fixture: fixture)
    func hook(_ nativeEvent: String, session: String) -> AgentNativeHookInput {
      AgentNativeHookInput(
        runtime: .opencode,
        token: "token-relayed",
        signal: AgentNativeHookSignal(
          event: table[nativeEvent]!,
          nativeEvent: nativeEvent,
          cwd: "/tmp/agent-observation",
          sessionID: session
        )
      )
    }

    #expect(fixture.manager.recordAgentNativeHook(hook("session.idle", session: "ses_1"), caller: caller))
    var channel = try #require(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).channels.first)
    #expect(channel.source == "hook_opencode")
    #expect(channel.state == .verifiedLive)
    #expect(channel.sessionID == "ses_1")
    #expect(!channel.events.contains(.sessionStart))
    #expect(fixture.manager.recordAgentNativeHook(hook("permission.asked", session: "ses_1"), caller: caller))

    #expect(fixture.manager.recordAgentNativeHook(hook("session.idle", session: "ses_2"), caller: caller))
    channel = try #require(fixture.manager.agentSignalsPayload(surfaceID: fixture.surfaceID).channels.first)
    #expect(channel.sessionID == "ses_2")
    #expect(channel.state == .verifiedLive)
    #expect(!fixture.manager.recordAgentNativeHook(hook("session.idle", session: "ses_1"), caller: caller))
  }

  /// Register a single-process relayed runtime (Pi family, OpenCode TUI) on the fixture's pane
  /// and return the exact caller the bridge would present.
  private func registerRelayedRuntime(
    _ runtime: AgentProfileRuntime,
    table: [String: AgentSignalEvent],
    fixture: Fixture
  ) throws -> CallerPane {
    let launchPID = getpid()
    let launchStartedAt = try #require(ProcessDetection.processStartDate(pid: launchPID))
    let hookRuntime = try #require(AgentNativeHookRuntime(rawValue: runtime.rawValue))
    let registration = AgentHookLaunchRegistration(
      token: "token-relayed",
      runtime: hookRuntime,
      launchCWD: URL(filePath: "/tmp/agent-observation", directoryHint: .isDirectory),
      nativeEvents: table,
      coveredEvents: Array(Set(table.values)).sorted { $0.rawValue < $1.rawValue },
      forwardingRecord: nil
    )
    let plan = AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: runtime.rawValue,
      runtime: runtime,
      invocation: AgentInvocation(executable: runtime.rawValue, arguments: []),
      hookRegistration: registration,
      commandEnvironmentTokens: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: [:],
      dedicatedHome: nil
    )
    #expect(fixture.state.onAgentProfileSurfacePrepared?(fixture.surfaceID, plan) == true)
    let paneState = PaneAgentState(
      detectedAgent: runtime.agent,
      agentProcessID: launchPID,
      launchProcessID: launchPID,
      state: .working
    )
    fixture.state.surfaceAgentStates[fixture.surfaceID] = paneState
    fixture.state.emitAgentEntry(surfaceID: fixture.surfaceID, tabId: fixture.tabID, state: paneState)
    return CallerPane(
      worktreeID: "/tmp/agent-observation",
      surfaceID: fixture.surfaceID,
      processAncestry: [AgentProcessGeneration(pid: launchPID, startedAt: launchStartedAt)]
    )
  }

  private struct Fixture {
    let manager: WorktreeTerminalManager
    let state: WorktreeTerminalState
    let tabID: TerminalTabID
    let surfaceID: UUID
  }

  private func makeFixture(bufferCapacity: Int = 64) -> Fixture {
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      agentObservationBufferCapacity: bufferCapacity
    )
    let worktree = Worktree(
      id: "/tmp/agent-observation",
      name: "agent-observation",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/agent-observation"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/agent-observation")
    )
    let state = manager.state(for: worktree)
    let tabID = state.createTab()!
    let surfaceID = state.focusedSurfaceId(in: tabID)!
    return Fixture(manager: manager, state: state, tabID: tabID, surfaceID: surfaceID)
  }

  private func makeSignal(detail: String? = nil) -> AgentSignal {
    AgentSignal(
      kind: .turnEnded,
      source: .cooperativeCLI,
      confidence: .exact,
      timestamp: Date(timeIntervalSince1970: 1_000),
      sessionID: "session-1",
      detail: detail,
      claimedOrigin: nil
    )
  }

  /// A live child of the test host standing in for an engine process the
  /// launched agent forked; generation checks need real start dates.
  private func makeEngineChild() throws -> Process {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    return process
  }
}
