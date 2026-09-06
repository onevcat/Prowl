import Clocks
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AgentWaitCommandHandlerTests {
  @Test func succeededDispatchReturnsReceiptAndFailedReceiptIsStructuredError() async throws {
    let succeeded = snapshot(
      .completed(
        id: "d1", outcome: .succeeded, summary: "Done", createdAt: Self.start, completedAt: Self.start))
    let successHandler = handler(dispatchSnapshot: succeeded)
    let success = await successHandler.handle(envelope: waitDispatch("d1"))
    #expect(success.ok)
    let payload = try #require(success.data).decode(as: AgentWaitCommandPayload.self)
    guard case .dispatch(let dispatch) = payload else {
      Issue.record("Expected dispatch payload")
      return
    }
    #expect(dispatch.receipt.summary == "Done")
    #expect(dispatch.target == succeeded.binding?.target)

    let failed = snapshot(
      .completed(
        id: "d2", outcome: .failed, summary: "Tests failed", createdAt: Self.start, completedAt: Self.start))
    let failure = await handler(dispatchSnapshot: failed).handle(envelope: waitDispatch("d2"))
    #expect(failure.error?.code == CLIErrorCode.dispatchFailed)
    let details = try #require(failure.error?.details).decode(as: AgentWaitErrorDetails.self)
    guard case .dispatch(let dispatchDetails) = details else {
      Issue.record("Expected dispatch error details")
      return
    }
    #expect(dispatchDetails.record.state == .completed)
  }

  @Test func dispatchNeedsInputAndIncompleteNeverBecomeSuccess() async {
    let pending = snapshot(.pending(id: "d1", createdAt: Self.start))
    for (event, code) in [
      (AgentDispatchObservation.needsInput(pending), CLIErrorCode.dispatchNeedsInput),
      (.incomplete(pending), CLIErrorCode.dispatchIncomplete),
    ] {
      let handler = AgentWaitCommandHandler(
        observeDispatch: { _ in
          .success(
            AgentDispatchObservationStream { continuation in
              continuation.yield(event)
            })
        }
      )
      let response = await handler.handle(envelope: waitDispatch("d1"))
      #expect(!response.ok)
      #expect(response.error?.code == code)
    }
  }

  @Test func exactConditionSignalCanResolveInitialSnapshotButChangedCannot() async throws {
    let target = resolvedTarget()
    let entry = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .idle)
    let signal = AgentSignal(
      kind: .turnEnded,
      source: .cooperativeCLI,
      confidence: .exact,
      timestamp: Self.start,
      sessionID: nil,
      detail: nil,
      claimedOrigin: nil
    )
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: entry, signal: signal, revision: 2, isLive: true, signals: .empty)
      }
    )
    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .agentsWait(
          AgentWaitInput(mode: .condition, pane: target.paneID, condition: .idle, timeoutSeconds: 1)
        )
      )
    )
    #expect(response.ok)
    let payload = try #require(response.data).decode(as: AgentWaitCommandPayload.self)
    guard case .condition(let condition) = payload else {
      Issue.record("Expected condition payload")
      return
    }
    #expect(condition.observation.confidence == "exact")
    #expect(condition.observation.source == "cooperative_cli")
  }

  @Test func changedExactRejectsHeuristicRevisionWithoutANewSignal() async {
    let clock = TestClock()
    let target = resolvedTarget()
    let surfaceID = UUID(uuidString: target.paneID)!
    let idle = agentEntry(surfaceID: surfaceID, status: .idle)
    let working = agentEntry(surfaceID: surfaceID, status: .working)
    let staleSignal = AgentSignal(
      kind: .turnEnded,
      source: .cooperativeCLI,
      confidence: .exact,
      timestamp: Self.start,
      sessionID: nil,
      detail: nil,
      claimedOrigin: nil
    )
    var snapshotReads = 0
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        snapshotReads += 1
        let didChangeHeuristically = snapshotReads > 2
        return .init(
          agent: didChangeHeuristically ? working : idle,
          signal: staleSignal,
          revision: didChangeHeuristically ? 2 : 1,
          isLive: true,
          signals: .empty
        )
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsWait(
            .init(
              mode: .condition,
              pane: target.paneID,
              condition: .changed,
              timeoutSeconds: 1,
              minimumConfidence: .exact
            )
          )
        ))
    }

    for _ in 0..<5 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.waitTimeout)
  }

  @Test func heuristicIdleRequiresTwoSecondsOfUnchangedState() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let entry = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .idle)
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: entry, signal: nil, revision: 1, isLive: true, signals: .empty)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsWait(
            .init(mode: .condition, pane: target.paneID, condition: .idle, timeoutSeconds: 3)
          )
        ))
    }
    for _ in 0..<9 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    #expect(!task.isCancelled)
    await Task.yield()
    await clock.advance(by: .milliseconds(200))
    let response = await task.value
    let payload = try #require(response.data).decode(as: AgentWaitCommandPayload.self)
    guard case .condition(let condition) = payload else {
      Issue.record("Expected condition payload")
      return
    }
    #expect(condition.waitedMilliseconds == 2_000)
    #expect(condition.observation.confidence == "heuristic")
  }

  @Test func requestedScreenWaitsForEightHundredMillisecondsOfStability() async throws {
    let clock = TestClock()
    let completed = snapshot(
      .completed(
        id: "d1", outcome: .succeeded, summary: "Done", createdAt: Self.start, completedAt: Self.start))
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in
        .success(
          AgentDispatchObservationStream { continuation in
            continuation.yield(.snapshot(completed))
            continuation.finish()
          })
      },
      screenProvider: { _ in "one\ntwo\nthree" },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsWait(
            .init(mode: .dispatch, dispatchID: "d1", timeoutSeconds: 1, includeScreenLines: 2)
          )
        ))
    }
    for _ in 0..<4 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    let payload = try #require(response.data).decode(as: AgentWaitCommandPayload.self)
    guard case .dispatch(let dispatch) = payload else {
      Issue.record("Expected dispatch payload")
      return
    }
    let screenPayload = try #require(dispatch.screen)
    guard case .captured(let screen) = screenPayload else {
      Issue.record("Expected captured screen")
      return
    }
    #expect(screen.waitedMilliseconds == 800)
    #expect(screen.text == "two\nthree")
    #expect(screen.stabilized)
  }

  @Test func requestedScreenIsIncludedWithFailedDispatch() async throws {
    let clock = TestClock()
    let failed = snapshot(
      .completed(
        id: "d1",
        outcome: .failed,
        summary: "Tests failed",
        createdAt: Self.start,
        completedAt: Self.start
      ))
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in
        .success(
          AgentDispatchObservationStream { continuation in
            continuation.yield(.snapshot(failed))
            continuation.finish()
          })
      },
      screenProvider: { _ in "failed evidence" },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsWait(
            .init(mode: .dispatch, dispatchID: "d1", timeoutSeconds: 1, includeScreenLines: 2)
          )
        ))
    }

    for _ in 0..<4 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    let details = try #require(response.error?.details)
    let object = try #require(
      JSONSerialization.jsonObject(with: details.bytes) as? [String: Any]
    )
    let screen = try #require(object["screen"] as? [String: Any])
    #expect(screen["status"] as? String == "captured")
    #expect(screen["text"] as? String == "failed evidence")
  }

  @Test func requestedScreenIsIncludedWithConditionTimeout() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let entry = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .working)
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: entry, signal: nil, revision: 1, isLive: true, signals: .empty)
      },
      screenProvider: { _ in "timeout evidence" },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsWait(
            .init(
              mode: .condition,
              pane: target.paneID,
              condition: .blocked,
              timeoutSeconds: 1,
              minimumConfidence: .exact,
              includeScreenLines: 2
            )
          )
        ))
    }

    for _ in 0..<9 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    let details = try #require(response.error?.details)
    let object = try #require(
      JSONSerialization.jsonObject(with: details.bytes) as? [String: Any]
    )
    let screen = try #require(object["screen"] as? [String: Any])
    #expect(screen["status"] as? String == "captured")
    #expect(screen["text"] as? String == "timeout evidence")
  }

  @Test func cancellingGenericWaitRemovesObservationSubscriber() async {
    let clock = TestClock()
    let target = resolvedTarget()
    let surfaceID = UUID(uuidString: target.paneID)!
    let store = AgentObservationStore(bufferCapacity: 8)
    let entry = agentEntry(surfaceID: surfaceID, status: .working)
    store.publishAgentChanged(entry)
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      observeCondition: { store.observe(surfaceID: $0, isLive: true) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(
          agent: entry,
          signal: nil,
          revision: store.snapshot(surfaceID: surfaceID)?.revision ?? 0,
          isLive: true,
          signals: .empty
        )
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsWait(
            .init(mode: .condition, pane: target.paneID, condition: .blocked, timeoutSeconds: 600)
          )
        ))
    }

    for _ in 0..<10 where store.subscriberCount(surfaceID: surfaceID) == 0 {
      await Task.yield()
    }
    #expect(store.subscriberCount(surfaceID: surfaceID) == 1)
    task.cancel()
    _ = await task.value
    for _ in 0..<10 where store.subscriberCount(surfaceID: surfaceID) != 0 {
      await Task.yield()
    }
    #expect(store.subscriberCount(surfaceID: surfaceID) == 0)
  }

  @Test func genericNonExitWaitReturnsAgentGoneWhenSurfaceCloses() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let entry = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .working)
    var snapshotReads = 0
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        snapshotReads += 1
        let isLive = snapshotReads <= 2
        return .init(
          agent: isLive ? entry : nil,
          signal: nil,
          revision: isLive ? 1 : 0,
          isLive: isLive,
          signals: .empty
        )
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsWait(
            .init(
              mode: .condition,
              pane: target.paneID,
              condition: .blocked,
              timeoutSeconds: 1,
              minimumConfidence: .exact
            )
          )
        ))
    }

    for _ in 0..<5 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.agentGone)
    let details = try #require(response.error?.details).decode(as: AgentWaitErrorDetails.self)
    guard case .condition(let condition) = details else {
      Issue.record("Expected condition error details")
      return
    }
    #expect(condition.observation?.source == "surface")
    #expect(condition.observation?.confidence == "exact")
  }

  @Test func genericWaitResubscribesAfterObservationOverflow() async {
    let clock = TestClock()
    let target = resolvedTarget()
    let entry = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .working)
    var subscriptionCount = 0
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      observeCondition: { _ in
        subscriptionCount += 1
        if subscriptionCount == 1 {
          return AgentObservationStream { continuation in
            continuation.finish(throwing: AgentObservationError.bufferOverflow)
          }
        }
        return AgentObservationStream { _ in }
      },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: entry, signal: nil, revision: 1, isLive: true, signals: .empty)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsWait(
            .init(mode: .condition, pane: target.paneID, condition: .blocked, timeoutSeconds: 600)
          )
        ))
    }

    for _ in 0..<10 where subscriptionCount < 2 {
      await Task.yield()
    }
    #expect(subscriptionCount == 2)
    task.cancel()
    _ = await task.value
  }

  @Test func preArmNeedsInputNeedsBlockedDetectorBeforeSatisfyingBlocked() async {
    let clock = TestClock()
    let target = resolvedTarget()
    let working = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .working)
    let staleNeedsInput = signal(.needsInput, at: Self.start)
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: working, signal: staleNeedsInput, revision: 3, isLive: true, signals: .empty)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .blocked, timeout: 1, minimumConfidence: .exact))
    }

    for _ in 0..<6 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.waitTimeout)
  }

  @Test func preArmNeedsInputSatisfiesBlockedWhenDetectorAgrees() async throws {
    let target = resolvedTarget()
    let blocked = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .blocked)
    let needsInput = signal(.needsInput, at: Self.start)
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: blocked, signal: needsInput, revision: 3, isLive: true, signals: .empty)
      }
    )
    let response = await handler.handle(
      envelope: conditionWait(target, .blocked, timeout: 1, minimumConfidence: .exact)
    )
    #expect(response.ok)
    let payload = try #require(response.data).decode(as: AgentWaitCommandPayload.self)
    guard case .condition(let condition) = payload else {
      Issue.record("Expected condition payload")
      return
    }
    #expect(condition.observation.source == "cooperative_cli")
    #expect(condition.observation.status == .blocked)
  }

  @Test func needsInputArrivingAfterArmSatisfiesBlockedWithoutDetectorCorroboration() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let working = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .working)
    let preArm = signal(.turnEnded, at: Self.start)
    let fresh = signal(.needsInput, at: Self.start.addingTimeInterval(5))
    var snapshotReads = 0
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        snapshotReads += 1
        return .init(
          agent: working,
          signal: snapshotReads > 3 ? fresh : preArm,
          revision: snapshotReads > 3 ? 4 : 3,
          isLive: true,
          signals: .empty
        )
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .blocked, timeout: 5, minimumConfidence: .exact))
    }

    for _ in 0..<4 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.ok)
    let payload = try #require(response.data).decode(as: AgentWaitCommandPayload.self)
    guard case .condition(let condition) = payload else {
      Issue.record("Expected condition payload")
      return
    }
    #expect(condition.observation.source == "cooperative_cli")
    #expect(condition.observation.status == .working)
    #expect(condition.waitedMilliseconds == 400)
  }

  @Test func preArmTurnEndedNeedsIdleDetectorBeforeSatisfyingIdle() async {
    let clock = TestClock()
    let target = resolvedTarget()
    let working = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .working)
    let staleTurnEnded = signal(.turnEnded, at: Self.start)
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: working, signal: staleTurnEnded, revision: 3, isLive: true, signals: .empty)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .idle, timeout: 1, minimumConfidence: .exact))
    }

    for _ in 0..<6 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.waitTimeout)
  }

  @Test func agentAppearingWithinGraceStartsTheConditionWait() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let idle = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .idle)
    let turnEnded = signal(.turnEnded, at: Self.start.addingTimeInterval(1))
    var snapshotReads = 0
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        snapshotReads += 1
        let appeared = snapshotReads > 3
        return .init(
          agent: appeared ? idle : nil,
          signal: appeared ? turnEnded : nil,
          revision: appeared ? 1 : 0,
          isLive: true,
          signals: .empty
        )
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .idle, timeout: 60, minimumConfidence: .exact))
    }

    for _ in 0..<4 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.ok)
    let payload = try #require(response.data).decode(as: AgentWaitCommandPayload.self)
    guard case .condition(let condition) = payload else {
      Issue.record("Expected condition payload")
      return
    }
    #expect(condition.observation.source == "cooperative_cli")
    #expect(condition.waitedMilliseconds == 600)
  }

  @Test func agentNeverAppearingFailsWithAgentNotFoundAfterGrace() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: nil, signal: nil, revision: 0, isLive: true, signals: .empty)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .blocked, timeout: 600))
    }

    let graceTicks = AgentWaitCommandHandler.agentAppearanceGraceMilliseconds / 200
    for _ in 0..<graceTicks {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.agentNotFound)
    let details = try #require(response.error?.details).decode(as: AgentWaitErrorDetails.self)
    guard case .condition(let condition) = details else {
      Issue.record("Expected condition error details")
      return
    }
    #expect(condition.waitedMilliseconds == AgentWaitCommandHandler.agentAppearanceGraceMilliseconds)
    #expect(condition.target?.pane.id == target.paneID)
  }

  @Test func shortTimeoutBoundsTheAgentAppearanceGrace() async throws {
    let clock = TestClock()
    let target = resolvedTarget()
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: nil, signal: nil, revision: 0, isLive: true, signals: .empty)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .idle, timeout: 1))
    }

    for _ in 0..<5 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.agentNotFound)
    let details = try #require(response.error?.details).decode(as: AgentWaitErrorDetails.self)
    guard case .condition(let condition) = details else {
      Issue.record("Expected condition error details")
      return
    }
    #expect(condition.waitedMilliseconds == 1_000)
  }

  @Test func autoIdleFallsBackToDetectorWhenLiveChannelHoldsNoTerminalSignal() async throws {
    // A freshly launched Profile has a verified_live channel that has only reported
    // `session-start`; the channel cannot describe the current level, so the stabilized
    // detector view resolves the wait instead of a timeout.
    let clock = TestClock()
    let target = resolvedTarget()
    let idle = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .idle)
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: idle, signal: nil, revision: 2, isLive: true, signals: Self.liveClaudeSignals)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .idle, timeout: 3))
    }

    // Advance past the timeout so a regression surfaces as WAIT_TIMEOUT instead of a hang.
    for _ in 0..<16 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.ok, "\(String(describing: response.error))")
    let payload = try #require(response.data).decode(as: AgentWaitCommandPayload.self)
    guard case .condition(let condition) = payload else {
      Issue.record("Expected condition payload")
      return
    }
    #expect(condition.waitedMilliseconds == 2_000)
    #expect(condition.observation.confidence == "heuristic")
    #expect(condition.observation.source == "detection")
  }

  @Test func autoIdleDoesNotOverridePreArmNeedsInputWhileLiveChannelIsPresent() async {
    // The channel's active terminal level is an exact `needs-input`: the runtime disagrees with
    // the screen, so the stabilized detector view must not end the wait on its own.
    let clock = TestClock()
    let target = resolvedTarget()
    let idle = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .idle)
    let needsInput = signal(.needsInput, at: Self.start)
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: idle, signal: needsInput, revision: 2, isLive: true, signals: Self.liveClaudeSignals)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .idle, timeout: 3))
    }

    for _ in 0..<16 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.waitTimeout)
  }

  @Test func autoIdleDoesNotOverrideFreshNeedsInputDuringStabilization() async {
    // The detector has shown idle for 1.8 s when an exact `needs-input` lands before the screen
    // catches up: exact evidence wins, so the stabilizer resets instead of resolving idle at the
    // two-second mark.
    let clock = TestClock()
    let target = resolvedTarget()
    let idle = agentEntry(surfaceID: UUID(uuidString: target.paneID)!, status: .idle)
    let fresh = signal(.needsInput, at: Self.start.addingTimeInterval(1.8))
    var snapshotReads = 0
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        snapshotReads += 1
        // Read 1 is the arm-time baseline and poll read k happens at (k - 2) * 200 ms, so the
        // signal lands at 1.8 s — inside the stabilizer's window.
        let arrived = snapshotReads > 10
        return .init(
          agent: idle,
          signal: arrived ? fresh : nil,
          revision: arrived ? 3 : 2,
          isLive: true,
          signals: Self.liveClaudeSignals
        )
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .idle, timeout: 3))
    }

    for _ in 0..<16 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.waitTimeout)
    #expect(snapshotReads > 10)
  }

  @Test func autoExitWaitsForSessionEndWhileLiveChannelIsPresent() async {
    // A verified_live channel reports its own `session-end`; the detector losing sight of the
    // agent on a still-live surface is not an exit under `auto`.
    let clock = TestClock()
    let target = resolvedTarget()
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: nil, signal: nil, revision: 2, isLive: true, signals: Self.liveClaudeSignals)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .exit, timeout: 3))
    }

    for _ in 0..<16 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.waitTimeout)
  }

  @Test func autoChangedIgnoresDetectorChangesWhileLiveChannelIsPresent() async {
    // `changed` stays an edge wait: with a verified_live channel the runtime reports the next
    // edge, so a detector-only state change never resolves it under `auto`.
    let clock = TestClock()
    let target = resolvedTarget()
    let surfaceID = UUID(uuidString: target.paneID)!
    let idle = agentEntry(surfaceID: surfaceID, status: .idle)
    let working = agentEntry(surfaceID: surfaceID, status: .working)
    let staleSignal = signal(.turnEnded, at: Self.start)
    var snapshotReads = 0
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        snapshotReads += 1
        let didChangeHeuristically = snapshotReads > 2
        return .init(
          agent: didChangeHeuristically ? working : idle,
          signal: staleSignal,
          revision: didChangeHeuristically ? 2 : 1,
          isLive: true,
          signals: Self.liveClaudeSignals
        )
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .changed, timeout: 3))
    }

    for _ in 0..<16 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.waitTimeout)
  }

  @Test func autoExitFallsBackToDetectorWhenChannelCannotReportSessionEnd() async throws {
    // Codex's notifier reports only `turn-ended`, so after `/quit` the detector losing the agent
    // on a still-live surface is the only exit evidence and must keep resolving under `auto`.
    let clock = TestClock()
    let target = resolvedTarget()
    let handler = AgentWaitCommandHandler(
      observeDispatch: { _ in .failure(.notFound) },
      resolveConditionTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        .init(agent: nil, signal: nil, revision: 2, isLive: true, signals: Self.liveCodexSignals)
      },
      clock: clock,
      now: { Self.start }
    )
    let task = Task {
      await handler.handle(envelope: conditionWait(target, .exit, timeout: 3))
    }

    for _ in 0..<16 {
      await Task.yield()
      await clock.advance(by: .milliseconds(200))
    }
    let response = await task.value
    #expect(response.ok, "\(String(describing: response.error))")
    let payload = try #require(response.data).decode(as: AgentWaitCommandPayload.self)
    guard case .condition(let condition) = payload else {
      Issue.record("Expected condition payload")
      return
    }
    #expect(condition.waitedMilliseconds == 2_000)
    #expect(condition.observation.confidence == "heuristic")
    #expect(condition.observation.rawState == "absent")
  }

  private static let liveCodexSignals = AgentSignalsPayload(
    channels: [
      AgentSignalChannelPayload(
        source: "hook_codex",
        state: .verifiedLive,
        confidence: "exact",
        events: [.turnEnded],
        lastSeenAt: "2026-08-28T00:00:00Z"
      )
    ],
    last: nil,
    lastBinding: nil
  )

  private static let liveClaudeSignals = AgentSignalsPayload(
    channels: [
      AgentSignalChannelPayload(
        source: "hook_claude",
        state: .verifiedLive,
        confidence: "exact",
        events: [.needsInput, .sessionEnd, .sessionStart, .turnEnded],
        lastSeenAt: "2026-08-28T00:00:00Z"
      )
    ],
    last: nil,
    lastBinding: nil
  )

  private func conditionWait(
    _ target: TabResolvedTarget,
    _ condition: AgentWaitCondition,
    timeout: Int,
    minimumConfidence: AgentWaitMinimumConfidence? = nil
  ) -> CommandEnvelope {
    CommandEnvelope(
      output: .json,
      command: .agentsWait(
        AgentWaitInput(
          mode: .condition,
          pane: target.paneID,
          condition: condition,
          timeoutSeconds: timeout,
          minimumConfidence: minimumConfidence
        )
      )
    )
  }

  private func signal(_ event: AgentSignal.Kind, at timestamp: Date) -> AgentSignal {
    AgentSignal(
      kind: event,
      source: .cooperativeCLI,
      confidence: .exact,
      timestamp: timestamp,
      sessionID: nil,
      detail: nil,
      claimedOrigin: nil
    )
  }

  private static let start = Date(timeIntervalSince1970: 1_000)

  private func handler(dispatchSnapshot: AgentDispatchSnapshot) -> AgentWaitCommandHandler {
    AgentWaitCommandHandler(
      observeDispatch: { _ in
        .success(
          AgentDispatchObservationStream { continuation in
            continuation.yield(.snapshot(dispatchSnapshot))
            continuation.finish()
          })
      },
      clock: TestClock(),
      now: { Self.start }
    )
  }

  private func waitDispatch(_ id: String) -> CommandEnvelope {
    CommandEnvelope(
      output: .json,
      command: .agentsWait(AgentWaitInput(mode: .dispatch, dispatchID: id, timeoutSeconds: 1))
    )
  }

  private func snapshot(_ record: AgentDispatchRecord) -> AgentDispatchSnapshot {
    AgentDispatchSnapshot(
      record: record,
      binding: AgentDispatchBinding(
        surfaceID: UUID(),
        target: target(),
        evidenceEpoch: UUID()
      )
    )
  }

  private func target() -> TabTarget {
    TabTarget(
      worktree: .init(id: "w1", name: "App", path: "/App", rootPath: "/App", kind: "worktree"),
      tab: .init(id: "t1", title: "Agent", selected: true),
      pane: .init(id: UUID().uuidString, title: "Agent", cwd: "/App", focused: true)
    )
  }

  private func resolvedTarget() -> TabResolvedTarget {
    let value = target()
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
      iconLookupToken: "codex",
      agent: .codex,
      rawState: Self.rawState(for: status),
      displayState: status,
      lastChangedAt: Self.start
    )
  }

  private static func rawState(for status: AgentDisplayState) -> AgentRawState {
    switch status {
    case .working: .working
    case .blocked: .blocked
    case .idle, .done: .idle
    }
  }
}
