import Clocks
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

// MARK: - Policy (pure)

struct WorkflowWatchdogPolicyTests {
  private let settings = WorkflowWatchdogSettings()
  private let exact = WorkflowWatchdogSnapshot(
    state: "working", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: true)
  private let codexLike = WorkflowWatchdogSnapshot(
    state: "working", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: false)
  private let heuristic = WorkflowWatchdogSnapshot(
    state: "working", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false)

  private func idle(_ live: Bool = true) -> WorkflowWatchdogSnapshot {
    WorkflowWatchdogSnapshot(state: "idle", liveChannelCoversTurnEnded: live, liveChannelCoversSessionEnd: live)
  }

  private func working(_ live: Bool = true) -> WorkflowWatchdogSnapshot {
    WorkflowWatchdogSnapshot(state: "working", liveChannelCoversTurnEnded: live, liveChannelCoversSessionEnd: live)
  }

  @Test func settingsClampTurnGraceToTheFloor() {
    #expect(WorkflowWatchdogSettings(turnGrace: .seconds(2)).turnGrace == .seconds(5))
    #expect(WorkflowWatchdogSettings().turnGrace == .seconds(15))
    #expect(WorkflowWatchdogSettings().idleGrace == .seconds(180))
    #expect(WorkflowWatchdogSettings().blockedGrace == .seconds(30))
  }

  @Test func exactModeNeedsInputIsImmediateAndKeepsWatching() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    #expect(policy.apply(.armed(exact)) == [])
    #expect(policy.mode == .exact(coversSessionEnd: true))
    #expect(policy.apply(.needsInput) == [.emit(.attention(.needsInput))])
    #expect(!policy.stopped)
    #expect(policy.apply(.turnEnded) == [.schedule(.turnGrace, .seconds(15))])
  }

  @Test func exactModeTurnEndedNudgesOnceThenEscalates() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = policy.apply(.armed(exact))
    #expect(policy.apply(.turnEnded) == [.schedule(.turnGrace, .seconds(15))])
    #expect(policy.apply(.deadline(.turnGrace, idle())) == [.emit(.nudge), .schedule(.idleGrace, .seconds(180))])
    #expect(policy.nudged)
    #expect(policy.apply(.deadline(.idleGrace, idle())) == [.emit(.attention(.idleWithoutDelivery)), .stop])
    #expect(policy.stopped)
    #expect(policy.apply(.turnEnded) == [])
  }

  @Test func turnGraceReArmsWhenTheRoleIsWorkingOrReportedActivity() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = policy.apply(.armed(exact))
    _ = policy.apply(.turnEnded)
    let reArm: WorkflowWatchdogCommands = [.schedule(.turnGrace, .seconds(15))]
    #expect(policy.apply(.deadline(.turnGrace, working())) == reArm)
    #expect(!policy.nudged)
    _ = policy.apply(.turnEnded)
    #expect(policy.apply(.signal(.progress)) == [])
    #expect(policy.apply(.deadline(.turnGrace, idle())) == reArm)
    _ = policy.apply(.turnEnded)
    #expect(policy.apply(.signal(.sessionStart)) == [])
    #expect(policy.apply(.deadline(.turnGrace, idle())) == reArm)
    _ = policy.apply(.turnEnded)
    #expect(policy.apply(.detector(state: "working")) == [])
    #expect(policy.apply(.deadline(.turnGrace, idle())) == reArm)
    _ = policy.apply(.turnEnded)
    #expect(policy.apply(.deadline(.turnGrace, idle())) == [.emit(.nudge), .schedule(.idleGrace, .seconds(180))])
  }

  /// Seen live (063 B3): a launched agent answered before the detector first saw it, so the
  /// detector's first `working` arrived after the exact `turn-ended`. Activity at the grace
  /// expiry must re-arm the grace, never leave the watchdog waiting for an event that never comes.
  @Test func activityAtATurnGraceExpiryReArmsTheGraceInsteadOfGoingSilent() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = policy.apply(
      .armed(
        WorkflowWatchdogSnapshot(state: "absent", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false)
      ))
    #expect(policy.apply(.turnEnded) == [.schedule(.turnGrace, .seconds(15))])
    #expect(policy.apply(.detector(state: "working")) == [.cancel(.appearanceGrace)])
    #expect(policy.apply(.deadline(.turnGrace, idle())) == [.schedule(.turnGrace, .seconds(15))])
    #expect(policy.apply(.deadline(.turnGrace, idle())) == [.emit(.nudge), .schedule(.idleGrace, .seconds(180))])
    // The same after the nudge: a spurious activity mark at idle_grace re-arms idle_grace.
    _ = policy.apply(.signal(.progress))
    #expect(policy.apply(.deadline(.idleGrace, idle())) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.deadline(.idleGrace, idle())) == [.emit(.attention(.idleWithoutDelivery)), .stop])
  }

  @Test func idleGraceReArmsWhileTheNudgedRoleWorksAndNeverNudgesTwice() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = policy.apply(.armed(exact))
    _ = policy.apply(.turnEnded)
    _ = policy.apply(.deadline(.turnGrace, idle()))
    #expect(policy.apply(.deadline(.idleGrace, working())) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.turnEnded) == [.cancel(.idleGrace), .schedule(.turnGrace, .seconds(15))])
    #expect(policy.apply(.deadline(.turnGrace, idle())) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.deadline(.idleGrace, idle())) == [.emit(.attention(.idleWithoutDelivery)), .stop])
  }

  @Test func resumedWatchdogSkipsTheAutomaticNudge() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: true)
    _ = policy.apply(.armed(exact))
    _ = policy.apply(.turnEnded)
    #expect(policy.apply(.deadline(.turnGrace, idle())) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.deadline(.idleGrace, idle())) == [.emit(.attention(.idleWithoutDelivery)), .stop])
  }

  @Test func goneEvidenceEndsTheWatchdog() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = policy.apply(.armed(exact))
    _ = policy.apply(.turnEnded)
    #expect(
      policy.apply(.gone(.sessionEnded)) == [.emit(.attention(.agentGone(.sessionEnded))), .cancel(.turnGrace), .stop])

    var closed = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = closed.apply(.armed(exact))
    #expect(closed.apply(.surfaceClosed) == [.emit(.attention(.agentGone(.paneClosed))), .stop])

    var delivered = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = delivered.apply(.armed(exact))
    #expect(delivered.apply(.activationClosed) == [.stop])
  }

  @Test func detectorRemovalIsDiagnosticOnlyWhenAChannelCoversSessionEnd() {
    var covered = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = covered.apply(.armed(exact))
    #expect(covered.apply(.detectorRemoved) == [])
    #expect(!covered.stopped)

    var uncovered = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = uncovered.apply(.armed(codexLike))
    #expect(uncovered.apply(.detectorRemoved) == [.emit(.attention(.agentGone(.processGone))), .stop])

    var heuristicPolicy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = heuristicPolicy.apply(.armed(heuristic))
    #expect(heuristicPolicy.apply(.detectorRemoved) == [.emit(.attention(.agentGone(.processGone))), .stop])
  }

  @Test func heuristicModeUsesDetectorLevelsWithGrace() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    #expect(policy.apply(.armed(heuristic)) == [])
    #expect(policy.mode == .heuristic)
    #expect(policy.apply(.detector(state: "blocked")) == [.schedule(.blockedGrace, .seconds(30))])
    #expect(policy.apply(.detector(state: "blocked")) == [])
    #expect(
      policy.apply(
        .deadline(
          .blockedGrace,
          WorkflowWatchdogSnapshot(
            state: "blocked", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false))) == [
          .emit(.attention(.blocked))
        ])
    #expect(!policy.stopped)
    #expect(policy.apply(.detector(state: "working")) == [])
    #expect(policy.apply(.detector(state: "idle")) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.detector(state: "done")) == [])
    #expect(policy.apply(.detector(state: "working")) == [.cancel(.idleGrace)])
    #expect(policy.apply(.detector(state: "idle")) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.deadline(.idleGrace, idle(false))) == [.emit(.nudge), .schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.deadline(.idleGrace, working(false))) == [])
    #expect(policy.apply(.detector(state: "idle")) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.deadline(.idleGrace, idle(false))) == [.emit(.attention(.idleWithoutDelivery)), .stop])
  }

  @Test func heuristicModeArmedOnAnIdleLevelStartsTheGraceAtOnce() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    #expect(policy.apply(.armed(idle(false))) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.deadline(.idleGrace, idle(false))) == [.emit(.nudge), .schedule(.idleGrace, .seconds(180))])
  }

  @Test func exactModeIgnoresDetectorLevels() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = policy.apply(.armed(idle()))
    #expect(policy.apply(.detector(state: "idle")) == [])
    #expect(policy.apply(.detector(state: "blocked")) == [])
    #expect(policy.apply(.deadline(.blockedGrace, idle())) == [])
  }

  @Test func idleAttentionKeepsTheHardTimeoutAlive() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: 600, nudgedAlready: true)
    #expect(policy.apply(.armed(exact)) == [.schedule(.timeout, .seconds(600))])
    _ = policy.apply(.turnEnded)
    #expect(policy.apply(.deadline(.turnGrace, idle())) == [.schedule(.idleGrace, .seconds(180))])
    #expect(policy.apply(.deadline(.idleGrace, idle())) == [.emit(.attention(.idleWithoutDelivery))])
    #expect(!policy.stopped)
    #expect(policy.apply(.deadline(.timeout, idle())) == [.emit(.timeout), .stop])

    var untimed = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: true)
    _ = untimed.apply(.armed(exact))
    _ = untimed.apply(.turnEnded)
    _ = untimed.apply(.deadline(.turnGrace, idle()))
    #expect(untimed.apply(.deadline(.idleGrace, idle())) == [.emit(.attention(.idleWithoutDelivery)), .stop])
  }

  @Test func armingOnAGonePaneRaisesAttentionAtOnce() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: 600, nudgedAlready: false)
    let gone = WorkflowWatchdogSnapshot(
      state: "gone", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false)
    #expect(policy.apply(.armed(gone)) == [.emit(.attention(.agentGone(.paneClosed))), .stop])
    #expect(policy.stopped)
  }

  @Test func armingWithoutADetectedAgentWaitsTheAppearanceGraceThenReportsItGone() {
    let absent = WorkflowWatchdogSnapshot(
      state: "absent", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false)
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    #expect(policy.apply(.armed(absent)) == [.schedule(.appearanceGrace, .seconds(10))])
    #expect(policy.apply(.deadline(.appearanceGrace, absent)) == [.emit(.attention(.agentGone(.processGone))), .stop])

    var appearing = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = appearing.apply(.armed(absent))
    #expect(appearing.apply(.detector(state: "working")) == [.cancel(.appearanceGrace)])
    #expect(!appearing.stopped)

    var settled = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = settled.apply(.armed(absent))
    #expect(settled.apply(.deadline(.appearanceGrace, idle(false))) == [.schedule(.idleGrace, .seconds(180))])

    var exact = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: nil, nudgedAlready: false)
    _ = exact.apply(
      .armed(
        WorkflowWatchdogSnapshot(state: "absent", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: true)))
    #expect(exact.apply(.deadline(.appearanceGrace, working())) == [])
  }

  @Test func hardTimeoutFiresRegardlessOfMode() {
    var policy = WorkflowWatchdogPolicy(settings: settings, timeoutSeconds: 600, nudgedAlready: false)
    #expect(policy.apply(.armed(exact)) == [.schedule(.timeout, .seconds(600))])
    _ = policy.apply(.turnEnded)
    #expect(policy.apply(.deadline(.timeout, working())) == [.emit(.timeout), .cancel(.turnGrace), .stop])
  }

  @Test func snapshotMapsConditionEvidence() {
    let live = AgentSignalChannelPayload(
      source: "hook_claude", state: .verifiedLive, confidence: "exact", events: [.turnEnded, .sessionStart],
      lastSeenAt: "t")
    let observed = AgentSignalChannelPayload(
      source: "cooperative_cli", state: .observed, confidence: "exact", events: [.sessionEnd], lastSeenAt: "t")
    let signals = AgentSignalsPayload(channels: [live, observed], last: nil, lastBinding: nil)
    let condition = AgentConditionSnapshot(agent: nil, signal: nil, revision: 3, isLive: true, signals: signals)
    #expect(
      WorkflowWatchdog.snapshot(from: condition)
        == WorkflowWatchdogSnapshot(
          state: "absent", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: false))
    let gone = AgentConditionSnapshot(agent: nil, signal: nil, revision: 3, isLive: false, signals: .empty)
    #expect(WorkflowWatchdog.snapshot(from: gone).state == "gone")
  }
}

// MARK: - Driver (streams + TestClock)

@MainActor
@Suite(.serialized)
struct WorkflowWatchdogDriverTests {
  @MainActor
  final class SnapshotBox {
    var snapshot: WorkflowWatchdogSnapshot
    init(_ snapshot: WorkflowWatchdogSnapshot) { self.snapshot = snapshot }
  }

  private static let request = WorkflowWatchdogRequest(
    ordinal: 1, stepID: "brief", role: "author", surfaceID: UUID(), dispatchID: "d1",
    timeoutSeconds: nil, timeoutPolicy: .attention, nudgedAlready: false)

  private static let pending = AgentDispatchSnapshot(
    record: .pending(id: "d1", createdAt: Date(timeIntervalSince1970: 0)), binding: nil)

  private func settle() async {
    for _ in 0..<25 { await Task.yield() }
  }

  struct Rig {
    let watchdog: WorkflowWatchdog
    let agent: AgentObservationStream.Continuation
    let dispatch: AgentDispatchObservationStream.Continuation
  }

  private func makeWatchdog(
    request: WorkflowWatchdogRequest = request,
    snapshot: SnapshotBox,
    clock: TestClock<Duration>
  ) -> Rig {
    let (agentStream, agentContinuation) = AgentObservationStream.makeStream()
    let (dispatchStream, dispatchContinuation) = AgentDispatchObservationStream.makeStream()
    let watchdog = WorkflowWatchdog(
      request: request,
      settings: WorkflowWatchdogSettings(),
      sources: WorkflowWatchdog.Sources(
        observeAgent: { agentStream },
        observeDispatch: { dispatchStream },
        snapshot: { snapshot.snapshot }),
      clock: clock)
    return Rig(watchdog: watchdog, agent: agentContinuation, dispatch: dispatchContinuation)
  }

  @Test func exactModeNudgesAfterTurnGraceAndEscalatesAfterIdleGrace() async throws {
    let clock = TestClock()
    let box = SnapshotBox(
      WorkflowWatchdogSnapshot(state: "working", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: true))
    let rig = makeWatchdog(snapshot: box, clock: clock)
    let (watchdog, dispatch) = (rig.watchdog, rig.dispatch)
    var verdicts = watchdog.start().makeAsyncIterator()
    await settle()
    dispatch.yield(.incomplete(Self.pending))
    await settle()
    box.snapshot = WorkflowWatchdogSnapshot(
      state: "idle", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: true)
    await settle()
    await clock.advance(by: .seconds(14))
    await settle()
    await clock.advance(by: .seconds(1))
    #expect(await verdicts.next() == .nudge)
    await settle()
    await clock.advance(by: .seconds(180))
    #expect(await verdicts.next() == .attention(.idleWithoutDelivery))
    #expect(await verdicts.next() == nil)
    #expect(!watchdog.isRunning)
  }

  @Test func turnGraceReReadsTheStateAndReArmsOnWorking() async throws {
    let clock = TestClock()
    let box = SnapshotBox(
      WorkflowWatchdogSnapshot(state: "working", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: true))
    let rig = makeWatchdog(snapshot: box, clock: clock)
    let (watchdog, dispatch) = (rig.watchdog, rig.dispatch)
    var verdicts = watchdog.start().makeAsyncIterator()
    await settle()
    dispatch.yield(.incomplete(Self.pending))
    await settle()
    await clock.advance(by: .seconds(15))
    await settle()
    dispatch.yield(.incomplete(Self.pending))
    await settle()
    box.snapshot = WorkflowWatchdogSnapshot(
      state: "idle", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: true)
    await settle()
    await clock.advance(by: .seconds(15))
    #expect(await verdicts.next() == .nudge)
    watchdog.cancel()
    #expect(await verdicts.next() == nil)
  }

  @Test func needsInputAndGoneArriveThroughTheDispatchStream() async throws {
    let clock = TestClock()
    let box = SnapshotBox(
      WorkflowWatchdogSnapshot(state: "working", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: true))
    let rig = makeWatchdog(snapshot: box, clock: clock)
    let (watchdog, dispatch) = (rig.watchdog, rig.dispatch)
    var verdicts = watchdog.start().makeAsyncIterator()
    await settle()
    dispatch.yield(.needsInput(Self.pending))
    #expect(await verdicts.next() == .attention(.needsInput))
    let gone = AgentDispatchSnapshot(
      record: .gone(
        id: "d1", createdAt: Date(timeIntervalSince1970: 0), goneAt: Date(timeIntervalSince1970: 1), reason: .sessionEnd
      ),
      binding: nil)
    dispatch.yield(.changed(gone))
    #expect(await verdicts.next() == .attention(.agentGone(.sessionEnded)))
    #expect(await verdicts.next() == nil)
    _ = watchdog
  }

  @Test func surfaceClosedOnTheAgentStreamEndsTheWatchdog() async throws {
    let clock = TestClock()
    let box = SnapshotBox(
      WorkflowWatchdogSnapshot(state: "working", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false))
    let rig = makeWatchdog(snapshot: box, clock: clock)
    let (watchdog, agent) = (rig.watchdog, rig.agent)
    var verdicts = watchdog.start().makeAsyncIterator()
    await settle()
    agent.yield(.surfaceClosed)
    #expect(await verdicts.next() == .attention(.agentGone(.paneClosed)))
    #expect(await verdicts.next() == nil)
    _ = watchdog
  }

  @Test func heuristicModeIdleLevelNudgesAfterIdleGrace() async throws {
    let clock = TestClock()
    let box = SnapshotBox(
      WorkflowWatchdogSnapshot(state: "idle", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false))
    let watchdog = makeWatchdog(snapshot: box, clock: clock).watchdog
    var verdicts = watchdog.start().makeAsyncIterator()
    await settle()
    await clock.advance(by: .seconds(180))
    #expect(await verdicts.next() == .nudge)
    await settle()
    await clock.advance(by: .seconds(180))
    #expect(await verdicts.next() == .attention(.idleWithoutDelivery))
    #expect(await verdicts.next() == nil)
    _ = watchdog
  }

  @Test func hardTimeoutFiresOnTheClock() async throws {
    let clock = TestClock()
    let box = SnapshotBox(
      WorkflowWatchdogSnapshot(state: "working", liveChannelCoversTurnEnded: true, liveChannelCoversSessionEnd: true))
    let request = WorkflowWatchdogRequest(
      ordinal: 1, stepID: "brief", role: "author", surfaceID: UUID(), dispatchID: "d1",
      timeoutSeconds: 60, timeoutPolicy: .skip, nudgedAlready: false)
    let watchdog = makeWatchdog(request: request, snapshot: box, clock: clock).watchdog
    var verdicts = watchdog.start().makeAsyncIterator()
    await settle()
    await clock.advance(by: .seconds(60))
    #expect(await verdicts.next() == .timeout)
    #expect(await verdicts.next() == nil)
    _ = watchdog
  }

  @Test func cancelStopsEverythingWithoutAVerdict() async throws {
    let clock = TestClock()
    let box = SnapshotBox(
      WorkflowWatchdogSnapshot(state: "idle", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false))
    let watchdog = makeWatchdog(snapshot: box, clock: clock).watchdog
    var verdicts = watchdog.start().makeAsyncIterator()
    await settle()
    watchdog.cancel()
    #expect(await verdicts.next() == nil)
    await settle()
    await clock.advance(by: .seconds(400))
    #expect(!watchdog.isRunning)
  }

  @Test func observerOverflowsAreRetriedUntilTheStreamDelivers() async throws {
    let clock = TestClock()
    let box = SnapshotBox(
      WorkflowWatchdogSnapshot(state: "idle", liveChannelCoversTurnEnded: false, liveChannelCoversSessionEnd: false))
    let (dispatchStream, _) = AgentDispatchObservationStream.makeStream()
    let attempts = Counter()
    let watchdog = WorkflowWatchdog(
      request: Self.request,
      settings: WorkflowWatchdogSettings(),
      sources: WorkflowWatchdog.Sources(
        observeAgent: {
          attempts.increment()
          if attempts.value <= 4 {
            return AgentObservationStream { $0.finish(throwing: AgentObservationError.bufferOverflow) }
          }
          return AgentObservationStream { continuation in
            continuation.yield(.removed)
            continuation.finish()
          }
        },
        observeDispatch: { dispatchStream },
        snapshot: { box.snapshot }),
      clock: clock)
    var verdicts = watchdog.start().makeAsyncIterator()
    #expect(await verdicts.next() == .attention(.agentGone(.processGone)))
    #expect(await verdicts.next() == nil)
    #expect(attempts.value == 5)
  }

  @MainActor
  final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  @Test func inputMappingCoversEveryObservation() {
    let entry = ActiveAgentEntry(
      id: UUID(), worktreeID: "wt", worktreeName: "wt", workingDirectory: nil, tabID: TerminalTabID(),
      paneTitle: "t", surfaceID: UUID(), paneIndex: 1, iconLookupToken: "claude", agent: .claude,
      rawState: .idle, displayState: .done, lastChangedAt: Date())
    #expect(WorkflowWatchdog.input(for: .changed(entry)) == .detector(state: "done"))
    #expect(
      WorkflowWatchdog.input(for: .snapshot(AgentObservationSnapshot(agent: nil, latestSignal: nil, revision: 0)))
        == .detector(state: "absent"))
    #expect(WorkflowWatchdog.input(for: .removed) == .detectorRemoved)
    #expect(WorkflowWatchdog.input(for: .surfaceClosed) == .surfaceClosed)
    let signal = AgentSignal(
      kind: .progress(nil), source: .cooperativeCLI, confidence: .exact, timestamp: Date(), sessionID: nil, detail: nil,
      claimedOrigin: nil)
    #expect(WorkflowWatchdog.input(for: .signal(signal)) == .signal(.progress))
    #expect(WorkflowWatchdog.input(for: .snapshot(Self.pending)) == nil)
    #expect(WorkflowWatchdog.input(for: .incomplete(Self.pending)) == .turnEnded)
    #expect(WorkflowWatchdog.input(for: .needsInput(Self.pending)) == .needsInput)
    let abandoned = AgentDispatchSnapshot(
      record: .abandoned(id: "d1", createdAt: Date(), abandonedAt: Date(), reason: "r"), binding: nil)
    #expect(WorkflowWatchdog.input(for: .changed(abandoned)) == .activationClosed)
    let closed = AgentDispatchSnapshot(
      record: .gone(id: "d1", createdAt: Date(), goneAt: Date(), reason: .surfaceClosed), binding: nil)
    #expect(WorkflowWatchdog.input(for: .changed(closed)) == .gone(.paneClosed))
  }
}
