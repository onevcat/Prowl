import Clocks
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AgentDispatchCommandHandlerTests {
  @Test func completionRequiresCallerContextAndReturnsImmutableReceipt() async throws {
    let caller = CallerPane(worktreeID: "w1", surfaceID: UUID())
    let target = makeTarget(paneID: caller.surfaceID.uuidString)
    let snapshot = AgentDispatchSnapshot(
      record: .completed(
        id: "d1",
        outcome: .succeeded,
        summary: "Done",
        createdAt: Self.start,
        completedAt: Self.start
      ),
      binding: AgentDispatchBinding(surfaceID: caller.surfaceID, target: target, evidenceEpoch: UUID())
    )
    let handler = AgentDispatchCompleteCommandHandler(
      resolveCaller: { _ in caller },
      complete: { surfaceID, outcome, summary in
        #expect(surfaceID == caller.surfaceID)
        #expect(outcome == .succeeded)
        #expect(summary == "Done")
        return .success(AgentDispatchMutationResult(snapshot: snapshot, replayed: false))
      },
      now: { Self.start }
    )

    let missingContext = await handler.handle(
      envelope: envelope(.agentsDispatchComplete(.init(dispatchID: "d1", outcome: .succeeded, summary: "Done")))
    )
    #expect(missingContext.error?.code == CLIErrorCode.dispatchContextRequired)

    let response = await handler.handle(
      envelope: envelope(.agentsDispatchComplete(.init(dispatchID: "d1", outcome: .succeeded, summary: "Done"))),
      context: CLICommandContext(callerProcessID: 123)
    )
    #expect(response.ok)
    let payload = try #require(response.data).decode(as: DispatchCompleteCommandPayload.self)
    #expect(payload.target == target)
    #expect(payload.receipt.id == "d1")
    #expect(!payload.replayed)
  }

  /// A worker launched with an older `PROWL_DISPATCH_ID` — or none at all — still completes
  /// whatever its pane currently holds: the pane, not the id, addresses the record.
  @Test func completionResolvesThePaneRecordRegardlessOfLaunchDispatchID() async throws {
    let caller = CallerPane(worktreeID: "w1", surfaceID: UUID())
    let target = makeTarget(paneID: caller.surfaceID.uuidString)
    let current = AgentDispatchSnapshot(
      record: .completed(id: "d2", outcome: .failed, summary: "No", createdAt: Self.start, completedAt: Self.start),
      binding: AgentDispatchBinding(surfaceID: caller.surfaceID, target: target, evidenceEpoch: UUID())
    )
    var completedSurfaces: [UUID] = []
    let handler = AgentDispatchCompleteCommandHandler(
      resolveCaller: { _ in caller },
      complete: { surfaceID, _, _ in
        completedSurfaces.append(surfaceID)
        return .success(AgentDispatchMutationResult(snapshot: current, replayed: false))
      }
    )
    for launchID in ["d1", nil] {
      let response = await handler.handle(
        envelope: envelope(.agentsDispatchComplete(.init(dispatchID: launchID, outcome: .failed, summary: "No"))),
        context: CLICommandContext(callerProcessID: 123)
      )
      #expect(response.ok)
      let payload = try #require(response.data).decode(as: DispatchCompleteCommandPayload.self)
      #expect(payload.receipt.id == "d2")
    }
    #expect(completedSurfaces == [caller.surfaceID, caller.surfaceID])
  }

  /// A workflow activation is completed by `prowl workflow deliver`, never here (063 B3, W3).
  @Test func completionIsInterceptedBeforeTheStoreForWorkflowActivations() async throws {
    let caller = CallerPane(worktreeID: "w1", surfaceID: UUID())
    var completed = 0
    let handler = AgentDispatchCompleteCommandHandler(
      resolveCaller: { _ in caller },
      complete: { _, _, _ in
        completed += 1
        return .failure(.notFound)
      },
      intercept: { surfaceID in
        #expect(surfaceID == caller.surfaceID)
        return CommandError(
          code: CLIErrorCode.workflowDeliveryRequired, message: "deliver with prowl workflow deliver -")
      }
    )
    let response = await handler.handle(
      envelope: envelope(.agentsDispatchComplete(.init(dispatchID: nil, outcome: .succeeded, summary: "Done"))),
      context: CLICommandContext(callerProcessID: 123)
    )
    #expect(response.ok == false)
    #expect(response.command == "agents.dispatch-complete")
    #expect(response.error?.code == CLIErrorCode.workflowDeliveryRequired)
    #expect(response.error?.message == "deliver with prowl workflow deliver -")
    #expect(completed == 0)
  }

  @Test func completionMapsStoreFailuresToStableCodes() async {
    let caller = CallerPane(worktreeID: "w1", surfaceID: UUID())
    for (error, code) in [
      (AgentDispatchStoreError.notFound, CLIErrorCode.dispatchNotFound),
      (.sourceMismatch, CLIErrorCode.dispatchSourceMismatch),
      (.alreadyCompleted, CLIErrorCode.dispatchAlreadyCompleted),
      (.alreadyTerminal, CLIErrorCode.dispatchAlreadyTerminal),
    ] {
      let handler = AgentDispatchCompleteCommandHandler(
        resolveCaller: { _ in caller },
        complete: { _, _, _ in .failure(error) }
      )
      let response = await handler.handle(
        envelope: envelope(.agentsDispatchComplete(.init(dispatchID: "d1", outcome: .failed, summary: "No"))),
        context: CLICommandContext(callerProcessID: 123)
      )
      #expect(response.error?.code == code)
    }
  }

  @Test func abandonmentNeedsNoCallerAndIsIdempotent() async throws {
    let target = makeTarget(paneID: UUID().uuidString)
    let snapshot = AgentDispatchSnapshot(
      record: .abandoned(id: "d1", createdAt: Self.start, abandonedAt: Self.start, reason: "Stop"),
      binding: AgentDispatchBinding(surfaceID: UUID(), target: target, evidenceEpoch: UUID())
    )
    let handler = AgentDispatchAbandonCommandHandler(
      abandon: { id, reason in
        #expect(id == "d1")
        #expect(reason == "Stop")
        return .success(AgentDispatchMutationResult(snapshot: snapshot, replayed: true))
      },
      now: { Self.start }
    )
    let response = await handler.handle(
      envelope: envelope(.agentsDispatchAbandon(.init(dispatchID: "d1", reason: "Stop")))
    )
    #expect(response.ok)
    let payload = try #require(response.data).decode(as: DispatchAbandonCommandPayload.self)
    #expect(payload.target == target)
    #expect(payload.replayed)
  }

  // MARK: - agents dispatch

  @Test func dispatchRejectsInvalidPromptsBeforeResolvingAnything() async {
    var resolved = 0
    let handler = AgentDispatchCommandHandler(resolveTarget: { _ in
      resolved += 1
      return .failure(.notFound("unused"))
    })
    for prompt in ["", "   \n", "bad\u{1B}[201~", "bell\u{07}", "cr\r\n"] {
      let response = await handler.handle(envelope: envelope(.agentsDispatch(.init(pane: "p7", prompt: prompt))))
      #expect(response.error?.code == CLIErrorCode.invalidArgument, "prompt: \(prompt.debugDescription)")
    }
    #expect(resolved == 0)
    #expect(DispatchInput(pane: "p7", prompt: "line one\n\tline two").validationErrorMessage == nil)
  }

  @Test func dispatchMapsTargetResolutionFailures() async {
    let notFound = AgentDispatchCommandHandler(resolveTarget: { _ in .failure(.notFound("No pane p9.")) })
    let response = await notFound.handle(envelope: dispatch(pane: "p9"))
    #expect(response.error?.code == CLIErrorCode.targetNotFound)
    #expect(response.error?.message == "No pane p9.")

    let notUnique = AgentDispatchCommandHandler(resolveTarget: { _ in .failure(.notUnique("Ambiguous.")) })
    #expect(await notUnique.handle(envelope: dispatch(pane: "p9")).error?.code == CLIErrorCode.targetNotUnique)
  }

  @Test func dispatchRefusesWhileThePaneHoldsAPendingRecordAndNeverIssuesAnother() async throws {
    let target = resolvedTarget()
    let pending = AgentDispatchSnapshot(
      record: .pending(id: "d1", createdAt: Self.start),
      binding: AgentDispatchBinding(
        surfaceID: surfaceID(of: target), target: TabTarget(from: target), evidenceEpoch: UUID())
    )
    var issued = 0
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      pendingDispatch: { _ in pending },
      conditionSnapshot: { _ in self.snapshot(target, status: .idle, signal: self.turnEnded) },
      issueDispatch: { _ in
        issued += 1
        return .failure(.surfacePending)
      }
    )
    let response = await handler.handle(envelope: dispatch(pane: target.paneID))
    #expect(response.error?.code == CLIErrorCode.dispatchPending)
    #expect(issued == 0)
    let details = try #require(response.error?.details).decode(as: AgentDispatchErrorDetails.self)
    #expect(details.record?.id == "d1")
    #expect(details.record?.state == .pending)
    #expect(details.target == TabTarget(from: target))
  }

  @Test func dispatchNeedsADetectedAgentAndALiveSurface() async throws {
    let target = resolvedTarget()
    let absent = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in .init(agent: nil, signal: nil, revision: 1, isLive: true, signals: .empty) }
    )
    let notFound = await absent.handle(envelope: dispatch(pane: target.paneID))
    #expect(notFound.error?.code == CLIErrorCode.agentNotFound)
    let details = try #require(notFound.error?.details).decode(as: AgentDispatchErrorDetails.self)
    #expect(details.target == TabTarget(from: target))
    #expect(details.record == nil)

    let closed = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in .init(agent: nil, signal: nil, revision: 0, isLive: false, signals: .empty) }
    )
    #expect(await closed.handle(envelope: dispatch(pane: target.paneID)).error?.code == CLIErrorCode.agentGone)
  }

  @Test func dispatchRefusesWorkingBlockedAndRuntimeNeedsInputAgents() async throws {
    struct BusyCase {
      let status: AgentDisplayState
      let signal: AgentSignal?
      let label: String
    }
    let target = resolvedTarget()
    let cases = [
      BusyCase(status: .working, signal: nil, label: "working"),
      BusyCase(status: .blocked, signal: nil, label: "blocked"),
      BusyCase(status: .blocked, signal: turnEnded, label: "blocked despite an old turn-ended"),
      BusyCase(status: .idle, signal: needsInput, label: "runtime needs-input while the screen looks idle"),
    ]
    for busy in cases {
      var issued = 0
      let handler = AgentDispatchCommandHandler(
        resolveTarget: { _ in .success(target) },
        conditionSnapshot: { _ in
          self.snapshot(target, status: busy.status, signal: busy.signal, channels: [self.liveClaudeChannel])
        },
        issueDispatch: { _ in
          issued += 1
          return .failure(.bindingMissing)
        }
      )
      let response = await handler.handle(envelope: dispatch(pane: target.paneID))
      let comment = Comment(rawValue: busy.label)
      #expect(response.error?.code == CLIErrorCode.dispatchTargetBusy, comment)
      #expect(issued == 0, comment)
      let details = try #require(response.error?.details).decode(as: AgentDispatchErrorDetails.self)
      #expect(details.observation?.status.rawValue == busy.status.rawValue, comment)
      #expect(details.signals?.channels.count == 1, comment)
    }
  }

  @Test func dispatchWithCorroboratedTurnEndedIssuesBindsThenDeliversPrefixedProtocol() async throws {
    let target = resolvedTarget()
    let issued = AgentDispatchSnapshot(
      record: .pending(id: "d7", createdAt: Self.start),
      binding: AgentDispatchBinding(
        surfaceID: surfaceID(of: target), target: TabTarget(from: target), evidenceEpoch: UUID())
    )
    var lifecycle: [String] = []
    var delivered: String?
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        self.snapshot(target, status: .done, signal: self.turnEnded, channels: [self.liveClaudeChannel])
      },
      issueDispatch: { resolved in
        lifecycle.append("issue:\(resolved.paneID)")
        return .success(issued)
      },
      deliverPrompt: { _, text in
        lifecycle.append("deliver")
        delivered = text
        return true
      },
      cancelDispatch: { lifecycle.append("cancel:\($0)") },
      now: { Self.start }
    )
    let response = await handler.handle(
      envelope: envelope(.agentsDispatch(.init(pane: target.paneID, prompt: "Round two: re-review the diff.")))
    )
    #expect(response.ok)
    #expect(response.command == "agents.dispatch")
    #expect(response.schemaVersion == "prowl.cli.agents.dispatch.v1")
    #expect(lifecycle == ["issue:\(target.paneID)", "deliver"])
    let payload = try #require(response.data).decode(as: AgentDispatchCommandPayload.self)
    #expect(payload.dispatch.id == "d7")
    #expect(payload.dispatch.state == .pending)
    #expect(payload.target == TabTarget(from: target))

    let text = try #require(delivered)
    #expect(text == AgentDispatchPrompt.renderInjected(userPrompt: "Round two: re-review the diff."))
    #expect(text.hasPrefix("[Prowl] Round two: re-review the diff.\n"))
    #expect(text.contains("Prowl dispatch completion protocol v\(AgentDispatchPrompt.protocolVersion)"))
    #expect(text.contains("prowl agents dispatch-complete --outcome succeeded|failed"))
    #expect(!text.contains("d7"))
  }

  /// Right after a turn the detector still shows `working` for its hold period although the
  /// runtime already reported `turn-ended`; the precondition waits for the corroboration
  /// instead of refusing, like `--until idle` would keep polling.
  @Test func dispatchWaitsForTheDetectorToCorroborateAFreshTurnEnded() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let issued = AgentDispatchSnapshot(
      record: .pending(id: "d11", createdAt: Self.start),
      binding: AgentDispatchBinding(
        surfaceID: surfaceID(of: target), target: TabTarget(from: target), evidenceEpoch: UUID())
    )
    var reads = 0
    var delivered = 0
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        reads += 1
        return self.snapshot(
          target, status: reads > 3 ? .done : .working, signal: self.turnEnded, channels: [self.liveClaudeChannel])
      },
      issueDispatch: { _ in .success(issued) },
      deliverPrompt: { _, _ in
        delivered += 1
        return true
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task { await handler.handle(envelope: self.dispatch(pane: target.paneID)) }
    for _ in 0..<3 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.ok)
    #expect(reads == 4)
    #expect(delivered == 1)
  }

  @Test func dispatchRefusesWhenTheDetectorNeverCorroboratesWithinTheGrace() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    var issued = 0
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        self.snapshot(target, status: .working, signal: self.turnEnded, channels: [self.liveClaudeChannel])
      },
      issueDispatch: { _ in
        issued += 1
        return .failure(.bindingMissing)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task { await handler.handle(envelope: self.dispatch(pane: target.paneID)) }
    for _ in 0..<(AgentDispatchCommandHandler.idleGraceMilliseconds / 200) {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.dispatchTargetBusy)
    #expect(issued == 0)
    let details = try #require(response.error?.details).decode(as: AgentDispatchErrorDetails.self)
    #expect(details.observation?.status == .working)
  }

  @Test func dispatchWithoutRuntimeEvidenceWaitsForTwoSecondsOfStableIdleDetection() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let issued = AgentDispatchSnapshot(
      record: .pending(id: "d8", createdAt: Self.start),
      binding: AgentDispatchBinding(
        surfaceID: surfaceID(of: target), target: TabTarget(from: target), evidenceEpoch: UUID())
    )
    var reads = 0
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        reads += 1
        return self.snapshot(target, status: .idle, signal: nil)
      },
      issueDispatch: { _ in .success(issued) },
      deliverPrompt: { _, _ in true },
      clock: clock,
      now: { Self.start }
    )
    let task = Task { await handler.handle(envelope: self.dispatch(pane: target.paneID)) }
    for _ in 0..<9 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    #expect(!task.isCancelled)
    await Task.yield()
    await clock.advance(by: .milliseconds(200))
    let response = await task.value
    #expect(response.ok)
    #expect(reads == 11)
  }

  @Test func dispatchStabilizationAbortsWhenTheAgentStartsWorking() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    var reads = 0
    var issued = 0
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        reads += 1
        return self.snapshot(target, status: reads > 3 ? .working : .idle, signal: nil)
      },
      issueDispatch: { _ in
        issued += 1
        return .failure(.bindingMissing)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task { await handler.handle(envelope: self.dispatch(pane: target.paneID)) }
    for _ in 0..<4 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.dispatchTargetBusy)
    #expect(issued == 0)
  }

  @Test func dispatchWithALiveChannelHoldingNoLevelStillUsesTheStabilizedDetector() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let issued = AgentDispatchSnapshot(
      record: .pending(id: "d9", createdAt: Self.start),
      binding: AgentDispatchBinding(
        surfaceID: surfaceID(of: target), target: TabTarget(from: target), evidenceEpoch: UUID())
    )
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        self.snapshot(target, status: .idle, signal: nil, channels: [self.liveClaudeChannel])
      },
      issueDispatch: { _ in .success(issued) },
      deliverPrompt: { _, _ in true },
      clock: clock,
      now: { Self.start }
    )
    let task = Task { await handler.handle(envelope: self.dispatch(pane: target.paneID)) }
    for _ in 0..<10 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.ok)
  }

  @Test func dispatchMapsIssuanceFailuresAndRollsBackAFailedDelivery() async throws {
    let target = resolvedTarget()
    let idle: AgentDispatchCommandHandler.ConditionSnapshotProvider = { _ in
      self.snapshot(target, status: .idle, signal: self.turnEnded)
    }
    let capacity = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: idle,
      issueDispatch: { _ in .failure(.capacityExceeded) }
    )
    #expect(
      await capacity.handle(envelope: dispatch(pane: target.paneID)).error?.code
        == CLIErrorCode.dispatchCapacityExceeded
    )

    let raced = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: idle,
      issueDispatch: { _ in .failure(.surfacePending) }
    )
    #expect(await raced.handle(envelope: dispatch(pane: target.paneID)).error?.code == CLIErrorCode.dispatchPending)

    let unbound = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: idle,
      issueDispatch: { _ in .failure(.bindingMissing) }
    )
    #expect(await unbound.handle(envelope: dispatch(pane: target.paneID)).error?.code == CLIErrorCode.dispatchFailed)

    var cancelled: [String] = []
    let undeliverable = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: idle,
      issueDispatch: { _ in
        .success(
          AgentDispatchSnapshot(
            record: .pending(id: "d10", createdAt: Self.start),
            binding: AgentDispatchBinding(
              surfaceID: self.surfaceID(of: target), target: TabTarget(from: target), evidenceEpoch: UUID())
          ))
      },
      deliverPrompt: { _, _ in false },
      cancelDispatch: { cancelled.append($0) }
    )
    let response = await undeliverable.handle(envelope: dispatch(pane: target.paneID))
    #expect(response.error?.code == CLIErrorCode.dispatchFailed)
    #expect(cancelled == ["d10"])
  }

  // MARK: - Helpers

  private static let start = Date(timeIntervalSince1970: 1_000)

  private var turnEnded: AgentSignal {
    AgentSignal(
      kind: .turnEnded,
      source: .hook(runtime: .claude, event: "Stop"),
      confidence: .exact,
      timestamp: Self.start,
      sessionID: nil,
      detail: nil,
      claimedOrigin: nil
    )
  }

  private var needsInput: AgentSignal {
    AgentSignal(
      kind: .needsInput,
      source: .hook(runtime: .claude, event: "Notification"),
      confidence: .exact,
      timestamp: Self.start,
      sessionID: nil,
      detail: nil,
      claimedOrigin: nil
    )
  }

  private var liveClaudeChannel: AgentSignalChannelPayload {
    AgentSignalChannelPayload(
      source: "hook_claude",
      state: .verifiedLive,
      confidence: "exact",
      events: [.sessionStart, .turnEnded, .needsInput, .sessionEnd],
      lastSeenAt: "2026-08-29T00:00:00.000Z"
    )
  }

  private func envelope(_ command: Command) -> CommandEnvelope {
    CommandEnvelope(output: .json, command: command)
  }

  private func dispatch(pane: String) -> CommandEnvelope {
    envelope(.agentsDispatch(.init(pane: pane, prompt: "Round two.")))
  }

  private func makeTarget(paneID: String) -> TabTarget {
    TabTarget(
      worktree: .init(id: "w1", name: "App", path: "/App", rootPath: "/App", kind: "worktree"),
      tab: .init(id: "t1", title: "Agent", selected: true),
      pane: .init(id: paneID, title: "Agent", cwd: "/App", focused: true)
    )
  }

  private func resolvedTarget() -> TabResolvedTarget {
    let value = makeTarget(paneID: UUID().uuidString)
    return TabResolvedTarget(
      worktreeID: value.worktree.id,
      worktreeName: value.worktree.name,
      worktreePath: value.worktree.path,
      worktreeRootPath: value.worktree.rootPath,
      worktreeKind: value.worktree.kind,
      tabID: value.tab.id,
      tabTitle: value.tab.title,
      tabSelected: value.tab.selected,
      paneID: value.pane.id,
      paneTitle: value.pane.title,
      paneCWD: value.pane.cwd,
      paneFocused: value.pane.focused
    )
  }

  private func surfaceID(of target: TabResolvedTarget) -> UUID {
    UUID(uuidString: target.paneID)!
  }

  private func snapshot(
    _ target: TabResolvedTarget,
    status: AgentDisplayState,
    signal: AgentSignal?,
    channels: [AgentSignalChannelPayload] = []
  ) -> AgentConditionSnapshot {
    AgentConditionSnapshot(
      agent: agentEntry(surfaceID: surfaceID(of: target), status: status),
      signal: signal,
      revision: 3,
      isLive: true,
      signals: AgentSignalsPayload(channels: channels, last: nil, lastBinding: nil)
    )
  }

  private func agentEntry(surfaceID: UUID, status: AgentDisplayState) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: surfaceID,
      worktreeID: "w1",
      worktreeName: "App",
      workingDirectory: URL(fileURLWithPath: "/App"),
      tabID: TerminalTabID(rawValue: UUID()),
      paneTitle: "Agent",
      surfaceID: surfaceID,
      paneIndex: 0,
      iconLookupToken: "claude",
      agent: .claude,
      rawState: status == .working ? .working : status == .blocked ? .blocked : .idle,
      displayState: status,
      lastChangedAt: Self.start
    )
  }
}
