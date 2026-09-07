// supacodeTests/WorkflowRunsFeatureTests.swift
// The reducer that wires B2's machine to the boundaries (docs-ai 063 B3): ordered effect
// execution, the two-phase `done` rendezvous, late launches, and the restart scan.

import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

/// A line the fake terminal received, with whether the instruction file it points at existed.
struct WorkflowTypedLineRecord {
  let surfaceID: UUID
  let line: String
  let instructionExisted: Bool
}

@MainActor
struct WorkflowRunsFeatureTests {
  nonisolated private static let now = Date(timeIntervalSince1970: 1_760_000_000)
  private static let authorPane = WorkflowRunMachineTests.authorPane
  private static let reviewerProfile = WorkflowRunMachineTests.reviewerProfile

  /// A `close` followed by another awaited step, so the close is queued while the run goes on.
  nonisolated private static let closeThenSummary = """
    schema: prowl.workflow/v1
    id: test.close-then-summary
    name: Close Then Summary
    roles:
      author:
        source: current
      reviewer:
        source: launch
        placement: split
        direction: right
    steps:
      - id: brief
        message: author
        text: "Write the brief."
        expect: { delivery: brief }
      - id: launch
        launch: reviewer
        prompt: "Review {{ deliveries.brief.path }}."
        expect: { delivery: findings }
      - id: cleanup
        close: reviewer
      - id: summary
        message: author
        text: "Findings: {{ deliveries.findings.path }}. Summarize."
        expect: { delivery: summary }
    """

  /// A native action as the first step: the run starts in `runningAction`.
  nonisolated private static let actionFirst = """
    schema: prowl.workflow/v1
    id: test.action-first
    name: Action First
    roles:
      author:
        source: current
      reviewer:
        source: launch
        placement: tab
    steps:
      - id: context
        action: builtin:collect-worktree-context
        with: { root: "{{ context.worktree.path }}" }
      - id: launch
        launch: reviewer
        prompt: "Review."
      - id: done
        notify: "Done"
    """

  /// Records every boundary call; the runtime fakes answer synchronously.
  @MainActor
  final class Fixture {
    let root: URL
    let worktree: Worktree
    var typed: [WorkflowTypedLineRecord] = []
    var launches: [WorkflowLaunchRequest] = []
    var closed: [UUID] = []
    var notifications: [WorkflowRuntimeNotification] = []
    var opened: [UUID] = []
    var cancelled: [String] = []
    var abandoned: [(dispatchID: String, reason: String)] = []
    var completed: [String] = []
    var armed: [WorkflowWatchdogRequest] = []
    var disarmed: [Int] = []
    var responses: [(requestID: UUID, resolution: WorkflowRequestResolution)] = []
    var roleWaitOutcome: WorkflowRoleWaitOutcome = .idle
    var launchOutcome: Result<WorkflowLaunchResult, WorkflowLaunchError>?
    /// What the liveness guard answered on each `deliverLine`.
    var guardAnswers: [Bool] = []
    private var dispatchCounter = 0
    private var paneCounter = 10

    init() throws {
      root =
        FileManager.default.temporaryDirectory
        .appending(path: "workflow-runs-feature-tests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .standardizedFileURL
      let skill = root.appending(
        path: "skills/prowl.adversarial-reviewer", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
      try "---\nname: r\ndescription: d\n---\n# Reviewer\n".write(
        to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
      worktree = Worktree(
        id: "wt", name: "feature", detail: "", workingDirectory: root, repositoryRootURL: root)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }

    var runtime: WorkflowRuntimeClient {
      WorkflowRuntimeClient(
        waitForRole: { [self] _ in roleWaitOutcome },
        deliverLine: { [self] _, surfaceID, line, isLive in
          let live = isLive()
          guardAnswers.append(live)
          guard live else { return .stale }
          let pointer = line.split(separator: " ").first { $0.hasPrefix("/") }.map(String.init)
          let existed = pointer.map { FileManager.default.fileExists(atPath: $0) } ?? true
          typed.append(WorkflowTypedLineRecord(surfaceID: surfaceID, line: line, instructionExisted: existed))
          return .delivered
        },
        launch: { [self] _, _, request in
          launches.append(request)
          if let launchOutcome { return launchOutcome }
          paneCounter += 1
          let pane = WorkflowPaneIdentity(
            surfaceID: UUID(), tabID: UUID(), handle: "p\(paneCounter)",
            displayName: request.profile.name,
            agent: request.profile.agent)
          let dispatchID = request.expectsDelivery ? issue(pane.surfaceID) : nil
          return .success(WorkflowLaunchResult(pane: pane, dispatchID: dispatchID))
        },
        close: { [self] _, surfaceID, _ in
          closed.append(surfaceID)
          return true
        },
        notify: { [self] _, notification in notifications.append(notification) }
      )
    }

    var activation: WorkflowActivationClient {
      WorkflowActivationClient(
        openMessage: { [self] surfaceID in .success(issue(surfaceID)) },
        cancel: { [self] id in cancelled.append(id) },
        abandon: { [self] id, reason in abandoned.append((id, reason)) },
        complete: { [self] id, _ in completed.append(id) },
        observe: { _ in nil }
      )
    }

    var watchdog: WorkflowWatchdogClient {
      WorkflowWatchdogClient(arm: { [self] _, request in
        armed.append(request)
        return WorkflowWatchdogHandle(
          verdicts: AsyncStream { $0.finish() },
          cancel: { [self] in disarmed.append(request.ordinal) })
      })
    }

    var responder: WorkflowCLIResponderClient {
      WorkflowCLIResponderClient(respond: { [self] requestID, resolution in
        responses.append((requestID, resolution))
      })
    }

    private func issue(_ surfaceID: UUID) -> String {
      dispatchCounter += 1
      opened.append(surfaceID)
      return "dispatch-\(dispatchCounter)"
    }

    func session(
      _ yaml: String = WorkflowRunMachineTests.adversarialReview,
      selfInitiated: Bool = false,
      inputs: [String: String] = [:],
      skipped: Set<String> = [],
      startedAt: Date = WorkflowRunsFeatureTests.now
    ) throws -> (WorkflowRunSession, [WorkflowRunEffect]) {
      let definition = try #require(WorkflowDocumentParser.parse(yaml).definition)
      let counter = WorkflowRunMachineTests.TokenCounter()
      let started = try WorkflowRunMachine.start(
        WorkflowRunStartRequest(
          definition: definition,
          runID: UUID(),
          context: WorkflowRunContext(
            scope: .user, definitionPath: nil,
            worktree: WorkflowRunWorktree(
              id: "wt", name: "feature", branch: "feat/x", path: root.path(percentEncoded: false))),
          bindings: [
            definition.roles[0].name: .current(WorkflowRunsFeatureTests.authorPane),
            definition.roles[1].name: .launch(WorkflowRunsFeatureTests.reviewerProfile, pane: nil),
          ],
          inputs: inputs,
          skippedSteps: skipped,
          selfInitiated: selfInitiated),
        now: { startedAt },
        makeToken: { counter.next() })
      let plan = AgentProfileLaunchPlan(
        profileID: WorkflowRunsFeatureTests.reviewerProfile.id, profileName: "Pi Reviewer",
        runtime: .pi,
        invocation: AgentInvocation(executable: "pi", arguments: ["placeholder"]),
        commandEnvironmentTokens: [], placement: .split, splitDirection: .right,
        surfaceEnvironment: [AgentProfileLaunchPlanner.promptCarrierName: "placeholder"],
        dedicatedHome: nil)
      let session = WorkflowRunSession(
        run: started.machine.run,
        worktree: worktree,
        launchPlans: [definition.roles[1].name: plan],
        bindingMemoryKeys: [
          definition.roles[1].name: WorkflowBindingResolver.memoryKey(
            scope: .user, workflowID: definition.id, role: definition.roles[1])
        ],
        skills: [
          "prowl.adversarial-reviewer": BundledSkill(
            id: "prowl.adversarial-reviewer", name: "Reviewer", description: "d",
            audience: .workflow,
            directoryURL: root.appending(
              path: "skills/prowl.adversarial-reviewer", directoryHint: .isDirectory))
        ])
      return (session, started.effects)
    }
  }

  private func makeStore(
    _ fixture: Fixture, queue: WorkflowEffectQueueClient,
    storage: SettingsTestStorage = SettingsTestStorage(),
    actionExecutor: (any WorkflowActionExecuting)? = nil
  ) -> TestStoreOf<WorkflowRunsFeature> {
    let store = TestStore(initialState: WorkflowRunsFeature.State()) {
      WorkflowRunsFeature()
    } withDependencies: {
      if let actionExecutor {
        $0.workflowActionExecutor = actionExecutor
      }
      $0.workflowRuntimeClient = fixture.runtime
      $0.workflowActivationClient = fixture.activation
      $0.workflowWatchdogClient = fixture.watchdog
      $0.workflowEffectQueue = queue
      $0.workflowCLIResponder = fixture.responder
      $0.date.now = Self.now
      $0.uuid = .incrementing
      $0.settingsFileStorage = storage.storage
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  /// A queue that records batches without performing them, for transitions under test control.
  @MainActor
  final class RecordingQueue {
    var batches: [(runID: UUID, effects: [WorkflowRunEffect])] = []
    var fenced: [UUID] = []
    var finished: [UUID] = []
    var client: WorkflowEffectQueueClient {
      WorkflowEffectQueueClient(
        start: { _ in AsyncStream { $0.finish() } },
        enqueue: { [self] runID, batch in batches.append((runID, batch.effects)) },
        fence: { [self] runID in fenced.append(runID) },
        isStale: { _, _ in false },
        finish: { [self] runID in finished.append(runID) })
    }
    var effects: [WorkflowRunEffect] { batches.flatMap(\.effects) }
  }

  /// A real queue whose fence rises on the n-th staleness check of the run — as a cancel that
  /// reduces on that very main-actor turn would raise it; `reached()` returns once it did.
  @MainActor
  final class FencingQueue {
    private let queue = WorkflowEffectQueue()
    private let fenceOnCheck: Int
    private var checks = 0
    private var waiter: CheckedContinuation<Void, Never>?

    init(fenceOnCheck: Int) {
      self.fenceOnCheck = fenceOnCheck
    }

    var client: WorkflowEffectQueueClient {
      WorkflowEffectQueueClient(
        start: { [queue] runID in queue.start(runID) },
        enqueue: { [queue] runID, batch in queue.enqueue(runID, batch) },
        fence: { [queue] runID in queue.fence(runID) },
        isStale: { [self] runID, sequence in
          checks += 1
          if checks == fenceOnCheck {
            queue.fence(runID)
            waiter?.resume()
            waiter = nil
          }
          return queue.isStale(runID, sequence: sequence)
        },
        finish: { [queue] runID in queue.finish(runID) })
    }

    func reached() async {
      guard checks < fenceOnCheck else { return }
      await withCheckedContinuation { waiter = $0 }
    }
  }

  /// A native action that reports when it started and finishes only once released.
  nonisolated final class GatedActionExecutor: WorkflowActionExecuting, Sendable {
    private let startedStream = AsyncStream<Void>.makeStream()
    private let releaseStream = AsyncStream<Void>.makeStream()

    func execute(actionID: String, inputs: [String: WorkflowJSONValue], context: WorkflowActionContext) async throws
      -> [String: WorkflowJSONValue]
    {
      startedStream.continuation.yield()
      for await _ in releaseStream.stream { break }
      return ["summary": "done"]
    }

    func started() async {
      for await _ in startedStream.stream { break }
    }

    func release() {
      releaseStream.continuation.yield()
    }
  }

  private static let timeout: Duration = .seconds(5)
  /// Tokens are minted by the reducer's `uuid` dependency (`.incrementing`) when a step opens.
  nonisolated private static let firstToken = "00000000-0000-0000-0000-000000000000"
  nonisolated private static let secondToken = "00000000-0000-0000-0000-000000000001"

  // MARK: - Ordered execution

  @Test(.dependencies) func aRunPerformsItsEffectsInMachineOrderAndAnswersDoneAfterPersistence()
    async throws
  {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let storage = SettingsTestStorage()
    let store = makeStore(fixture, queue: WorkflowEffectQueue().client, storage: storage)
    let (session, effects) = try fixture.session()
    let runID = session.run.id
    let runDirectory = session.store.directory(for: runID)

    await store.send(.started(session, effects: effects))
    await store.receive(.event(runID: runID, .roleIdle(ordinal: 1)), timeout: Self.timeout)
    await store.receive(
      .event(runID: runID, .injectionSucceeded(ordinal: 1, dispatchID: "dispatch-1")),
      timeout: Self.timeout)
    #expect(fixture.typed.count == 1)
    #expect(
      fixture.typed[0].instructionExisted,
      "the instruction file must exist before the pointer is typed")
    #expect(fixture.typed[0].line.contains("PROWL_WORKFLOW_TOKEN=\(Self.firstToken) prowl workflow deliver -"))
    #expect(fixture.armed.map(\.ordinal) == [1])
    let record = try session.store.readRecord(runID: runID)
    #expect(record.run.status.state == "running")

    let requestID = UUID()
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: requestID, runID: runID, ordinal: 1, selector: .token(Self.firstToken),
          body: "# Brief\n## Scope\nx\n## Claims\ny", verdict: nil, source: "pane"))
    )
    #expect(store.state.pendingDeliveries[requestID]?.ordinal == 1)
    await store.receive(.event(runID: runID, .outputPersisted(ordinal: 1)), timeout: Self.timeout)
    #expect(fixture.responses.count == 1)
    guard case .delivered(let run, let receipt) = fixture.responses[0].resolution else {
      Issue.record("expected a delivered resolution, got \(fixture.responses[0].resolution)")
      return
    }
    #expect(receipt.ordinal == 1)
    #expect(run.deliveries["brief"]?.ordinal == 1)
    #expect(store.state.pendingDeliveries.isEmpty)
    #expect(fixture.disarmed.first == 1, "the accepted delivery disarms its watchdog")
    #expect(fixture.completed == ["dispatch-1"])

    // The next step launches the reviewer: skill materialized, plan frozen, pane bound, memory written.
    await store.receive(\.event, timeout: Self.timeout)
    #expect(fixture.launches.count == 1)
    #expect(fixture.launches[0].environment["PROWL_WORKFLOW_TOKEN"] == Self.secondToken)
    #expect(
      FileManager.default.fileExists(
        atPath: runDirectory.appending(path: "skills/prowl.adversarial-reviewer/SKILL.md").path(
          percentEncoded: false)))
    let reviewerPane = try #require(store.state.sessions[runID]?.run.bindings["reviewer"]?.pane)
    #expect(reviewerPane.handle == "p11")
    #expect(store.state.paneOwners[reviewerPane.surfaceID] == runID, "a launch take-up records the owner")
    #expect(fixture.armed.map(\.ordinal) == [1, 2])
    let key = try #require(session.bindingMemoryKeys["reviewer"])
    let remembered = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      return settings.rememberedWorkflowBinding(for: key)
    }
    #expect(remembered == Self.reviewerProfile.id)

    await store.send(.userAction(runID: runID, .cancel)) {
      $0.sessions[runID]?.run.status = .cancelled
    }
    await store.finish(timeout: Self.timeout)
    #expect(fixture.abandoned.map(\.dispatchID) == ["dispatch-2"])
    #expect(fixture.disarmed.sorted() == [1, 2])
    #expect(try session.store.readRecord(runID: runID).run.status.state == "cancelled")
    let log = try String(contentsOf: runDirectory.appending(path: "log.md"), encoding: .utf8)
    #expect(log.contains("Run finished: cancelled."))
    #expect(!log.contains("TOKEN-"))
  }

  @Test(.dependencies) func aFailedInstructionWriteStopsTheBatchBeforeAnythingIsTyped() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let store = makeStore(fixture, queue: WorkflowEffectQueue().client)
    let (session, effects) = try fixture.session()
    let runID = session.run.id
    // The run directory's `instructions` leaf becomes a link, which the store refuses.
    try session.store.ensureLayout(runID: runID)
    let instructions = session.store.directory(for: runID).appending(
      path: "instructions", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: instructions)
    let elsewhere = fixture.root.appending(path: "elsewhere", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: instructions, withDestinationURL: elsewhere)

    await store.send(.started(session, effects: effects))
    await store.receive(.event(runID: runID, .roleIdle(ordinal: 1)), timeout: Self.timeout)
    await store.receive(\.event, timeout: Self.timeout)
    #expect(
      store.state.sessions[runID]?.run.status.attention?.reason.code == "injection_failed:activation_unavailable")
    #expect(fixture.typed.isEmpty)
    #expect(fixture.opened.isEmpty)
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  // MARK: - Rendezvous (decision W1)

  @Test(.dependencies) func cancelWhileTheOutputIsPersistingFailsThePendingDone() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, _) = try fixture.session()
    let waiting = try waitingForDelivery(session)
    let runID = waiting.run.id
    await store.send(.started(waiting, effects: []))

    let requestID = UUID()
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: requestID, runID: runID, ordinal: 1, selector: .token("TOKEN-1"),
          body: "## Scope\nx\n## Claims\ny", verdict: nil, source: "pane")))
    #expect(store.state.pendingDeliveries[requestID]?.ordinal == 1)
    #expect(store.state.sessions[runID]?.run.activeActivation?.state == .persisting)
    #expect(fixture.responses.isEmpty)
    #expect(
      queue.effects.contains { if case .persistOutput = $0 { return true } else { return false } })

    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
    #expect(store.state.pendingDeliveries.isEmpty)
    #expect(fixture.responses.count == 1)
    #expect(fixture.responses[0].requestID == requestID)
    #expect(
      fixture.responses[0].resolution
        == .failed(
          code: CLIErrorCode.stepNotExpecting,
          message: "The step stopped waiting for this delivery before the output was saved."))
    #expect(queue.effects.contains(.finished(.cancelled)))

    // The queued `.outputPersisted` of the abandoned write is stale: ignored, nothing answered twice.
    await store.send(.event(runID: runID, .outputPersisted(ordinal: 1)))
    #expect(fixture.responses.count == 1)
  }

  @Test(.dependencies) func aPersistenceFailureFailsThePendingDoneWithWorkflowFailed() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, _) = try fixture.session()
    let waiting = try waitingForDelivery(session)
    let runID = waiting.run.id
    await store.send(.started(waiting, effects: []))
    let requestID = UUID()
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: requestID, runID: runID, ordinal: 1, selector: .token("TOKEN-1"),
          body: "## Scope\nx\n## Claims\ny", verdict: nil, source: "manual")))
    #expect(queue.effects.first == .log("Step 'brief': delivery received (source=manual)."))

    await store.send(.event(runID: runID, .outputPersistFailed(ordinal: 1, reason: "disk full")))
    #expect(store.state.sessions[runID]?.run.status.attention?.reason.code == "persist_failed")
    #expect(store.state.pendingDeliveries.isEmpty)
    #expect(fixture.responses.count == 1)
    guard case .failed(let code, let message) = fixture.responses[0].resolution else {
      Issue.record("expected a failure")
      return
    }
    #expect(code == CLIErrorCode.workflowFailed)
    #expect(message.contains("disk full"))
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  @Test(.dependencies) func aProvisionalDeliveryIsAnsweredAsProvisionalWithItsIssues() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, _) = try fixture.session()
    let waiting = try waitingForDelivery(session)
    let runID = waiting.run.id
    await store.send(.started(waiting, effects: []))
    let requestID = UUID()
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: requestID, runID: runID, ordinal: 1, selector: .token("TOKEN-1"),
          body: "## Scope\nonly", verdict: nil, source: "pane")))
    await store.send(.event(runID: runID, .outputPersisted(ordinal: 1)))
    #expect(store.state.sessions[runID]?.run.status.attention?.reason.code == "delivery_issues")
    #expect(fixture.responses.count == 1)
    guard case .provisional(_, let receipt) = fixture.responses[0].resolution else {
      Issue.record("expected a provisional resolution")
      return
    }
    #expect(receipt.issues == [.missingSections(["## Claims"])])
    #expect(fixture.completed.isEmpty, "the dispatch record stays pending until the user accepts")
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  @Test(.dependencies) func aRejectedDeliveryIsAnsweredAtOnceWithoutAPendingRequest() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, _) = try fixture.session()
    let waiting = try waitingForDelivery(session)
    let runID = waiting.run.id
    await store.send(.started(waiting, effects: []))

    let wrongToken = UUID()
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: wrongToken, runID: runID, ordinal: 1, selector: .token("TOKEN-9"),
          body: "## Scope\nx\n## Claims\ny", verdict: nil, source: "pane")))
    let unknownRun = UUID()
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: unknownRun, runID: UUID(), ordinal: nil, selector: .manual(stepID: "brief"),
          body: "x", verdict: nil, source: "manual")))
    await store.finish(timeout: Self.timeout)
    #expect(store.state.pendingDeliveries.isEmpty)
    #expect(fixture.responses.map(\.requestID) == [wrongToken, unknownRun])
    #expect(
      fixture.responses[0].resolution
        == .failed(
          code: CLIErrorCode.tokenInvalid, message: WorkflowDeliveryError.tokenInvalid.message))
    #expect(
      fixture.responses[1].resolution
        == .failed(code: CLIErrorCode.runNotFound, message: "The workflow run is not active."))
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  // MARK: - Late and stale launches

  @Test(.dependencies) func aLaunchThatCompletesAfterTheRunEndedIsAbandonedAndClosed() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, _) = try fixture.session()
    let runID = session.run.id
    await store.send(.started(session, effects: []))
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)

    let pane = WorkflowPaneIdentity(
      surfaceID: UUID(), tabID: nil, handle: "p7", displayName: "Pi", agent: "pi")
    await store.send(
      .event(runID: runID, .launched(ordinal: 2, pane: pane, dispatchID: "late-dispatch")))
    await store.finish(timeout: Self.timeout)
    #expect(fixture.abandoned.map(\.dispatchID) == ["late-dispatch"])
    #expect(fixture.closed == [pane.surfaceID])
  }

  @Test(.dependencies) func aLaunchTheMachineNoLongerExpectsIsClosedToo() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, _) = try fixture.session()
    let waiting = try waitingForDelivery(session)
    let runID = waiting.run.id
    await store.send(.started(waiting, effects: []))

    let pane = WorkflowPaneIdentity(
      surfaceID: UUID(), tabID: nil, handle: "p8", displayName: "Pi", agent: "pi")
    await store.send(
      .event(runID: runID, .launched(ordinal: 42, pane: pane, dispatchID: "stale-dispatch")))
    await store.finish(timeout: Self.timeout)
    #expect(store.state.sessions[runID]?.run.bindings["reviewer"]?.pane == nil)
    #expect(fixture.abandoned.map(\.dispatchID) == ["stale-dispatch"])
    #expect(fixture.closed == [pane.surfaceID])
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  // MARK: - Fences and stale work

  /// Cancel, skip, and retry revoke the invocation whose work may still sit in the queue; the
  /// reducer fences the queue so that work is dropped instead of typing into the pane.
  @Test(.dependencies) func revokingAnInFlightInvocationFencesTheQueue() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session()
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    #expect(queue.fenced.isEmpty)
    // The idle wait ended and the inject is (conceptually) queued; a cancel must fence it.
    await store.send(.userAction(runID: runID, .cancel))
    #expect(queue.fenced == [runID])
    await store.finish(timeout: Self.timeout)

    // A retry from an attention likewise revokes the in-flight invocation.
    let second = try fixture.session().0
    let secondID = second.run.id
    await store.send(.started(second, effects: []))
    await store.send(.event(runID: secondID, .roleUnavailable(ordinal: 1, .roleBlocked)))
    #expect(queue.fenced == [runID], "attention alone revokes nothing")
    await store.send(.userAction(runID: secondID, .retry))
    #expect(queue.fenced == [runID, secondID])
    await store.send(.userAction(runID: secondID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  /// A typed line whose `.injectionSucceeded` the machine no longer takes up (the step moved on)
  /// leaves a pending dispatch record behind unless the wiring abandons it.
  @Test(.dependencies) func anIgnoredInjectionAbandonsTheRecordItOpened() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, _) = try fixture.session()
    let waiting = try waitingForDelivery(session)
    let runID = waiting.run.id
    await store.send(.started(waiting, effects: []))
    await store.send(.event(runID: runID, .injectionSucceeded(ordinal: 1, dispatchID: "stale-1")))
    await store.finish(timeout: Self.timeout)
    #expect(fixture.abandoned.map(\.dispatchID) == ["stale-1"])

    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
    await store.send(.event(runID: runID, .injectionSucceeded(ordinal: 1, dispatchID: "late-1")))
    await store.finish(timeout: Self.timeout)
    // The cancel's own abandon of `dispatch-0` is an ordered effect the recording queue never
    // performs; the late injection's record is abandoned directly by the reducer.
    #expect(fixture.abandoned.map(\.dispatchID) == ["stale-1", "late-1"])
  }

  /// The first `inject` makes three staleness checks in order: the batch check, the guard before
  /// the record is issued, and the guard the terminal evaluates on the typing turn. A fence that
  /// rises on the last one (a cancel reducing on that turn) returns the issuance: nothing is typed
  /// and no event reaches the machine.
  @Test(.dependencies) func aFenceOnTheTypingTurnReturnsTheIssuanceAndTypesNothing() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = FencingQueue(fenceOnCheck: 3)
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session()
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    await store.receive(.event(runID: runID, .roleIdle(ordinal: 1)), timeout: Self.timeout)
    await queue.reached()
    #expect(fixture.opened.count == 1)
    #expect(fixture.guardAnswers == [false], "the guard the terminal evaluates reflects the real fence")
    #expect(fixture.cancelled == ["dispatch-1"])
    #expect(fixture.typed.isEmpty)
    #expect(store.state.sessions[runID]?.run.phase == .injecting(ordinal: 1))
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  /// A fence that rises between the batch check and the issuance opens no record at all.
  @Test(.dependencies) func aFenceBeforeTheIssuanceOpensNoRecord() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = FencingQueue(fenceOnCheck: 2)
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session()
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    await store.receive(.event(runID: runID, .roleIdle(ordinal: 1)), timeout: Self.timeout)
    await queue.reached()
    #expect(fixture.opened.isEmpty)
    #expect(fixture.cancelled.isEmpty)
    #expect(fixture.typed.isEmpty)
    #expect(fixture.guardAnswers.isEmpty)
    #expect(store.state.sessions[runID]?.run.phase == .injecting(ordinal: 1))
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  /// A native action checks the fence once more right before it starts: a cancel that lands
  /// after the batch check runs nothing, and the run log says so.
  @Test(.dependencies) func aFenceBeforeANativeActionStartsRunsNothing() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = FencingQueue(fenceOnCheck: 2)
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session(Self.actionFirst)
    let runID = session.run.id
    #expect(
      effects.contains(
        .runAction(
          stepID: "context", actionID: "builtin:collect-worktree-context",
          inputs: ["root": .string(fixture.root.path(percentEncoded: false))])))
    await store.send(.started(session, effects: effects))
    await queue.reached()
    #expect(store.state.sessions[runID]?.run.phase == .runningAction(stepID: "context"))
    #expect(store.state.sessions[runID]?.run.status == .running)
    #expect(store.state.sessions[runID]?.run.actionOutputs.isEmpty == true)
    await store.send(.userAction(runID: runID, .cancel)) {
      $0.sessions[runID]?.run.status = .cancelled
    }
    await store.finish(timeout: Self.timeout)
    let log = try String(
      contentsOf: session.store.directory(for: runID).appending(path: "log.md"), encoding: .utf8)
    #expect(log.contains("Run finished: cancelled."))
    #expect(!log.contains("action completed"))
  }

  /// An action that already left the main actor runs to completion; the run that was cancelled
  /// meanwhile discards its result and the log records that it finished late.
  @Test(.dependencies) func aNativeActionThatOutlivesTheRunIsDiscardedAndLogged() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let gate = GatedActionExecutor()
    let store = makeStore(fixture, queue: WorkflowEffectQueue().client, actionExecutor: gate)
    let (session, effects) = try fixture.session(Self.actionFirst)
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    await gate.started()
    await store.send(.userAction(runID: runID, .cancel)) {
      $0.sessions[runID]?.run.status = .cancelled
    }
    gate.release()
    await store.finish(timeout: Self.timeout)
    #expect(store.state.sessions[runID]?.run.actionOutputs.isEmpty == true)
    let log = try String(
      contentsOf: session.store.directory(for: runID).appending(path: "log.md"), encoding: .utf8)
    #expect(!log.contains("action completed"))
    #expect(!log.contains("not started"))
    #expect(log.contains("Run finished: cancelled."))
  }

  /// `close` is revocable: a cancel that beats a queued close keeps the pane, while a close the
  /// run reaches normally removes it before the next line is typed.
  @Test(.dependencies) func aCloseStepRemovesThePaneBeforeTheNextLineIsTyped() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let store = makeStore(fixture, queue: WorkflowEffectQueue().client)
    let (session, effects) = try fixture.session(Self.closeThenSummary)
    let runID = session.run.id
    let reviewer = try await driveToCleanup(store, fixture: fixture, session: session, effects: effects)
    await store.receive(.event(runID: runID, .roleIdle(ordinal: 3)), timeout: Self.timeout)
    await store.receive(
      .event(runID: runID, .injectionSucceeded(ordinal: 3, dispatchID: "dispatch-3")), timeout: Self.timeout)
    #expect(fixture.closed == [reviewer.surfaceID])
    #expect(fixture.typed.count == 2)
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  @Test(.dependencies) func aCancelThatBeatsAQueuedCloseKeepsThePane() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    // Staleness checks in FIFO order: inject 1 (batch, issuance, typing turn), launch 2 (batch),
    // then the close's batch check — the fence rises there.
    let queue = FencingQueue(fenceOnCheck: 5)
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session(Self.closeThenSummary)
    let runID = session.run.id
    let reviewer = try await driveToCleanup(store, fixture: fixture, session: session, effects: effects)
    await queue.reached()
    #expect(fixture.closed.isEmpty)
    #expect(store.state.sessions[runID]?.run.bindings["reviewer"]?.pane?.surfaceID == reviewer.surfaceID)
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
    #expect(fixture.closed.isEmpty, "cancel never closes panes")
  }

  /// The boundary's ownership rule: the pane belongs to the run that bound it most recently —
  /// recorded at admission and at launch take-up, never read from a clock — also once that run
  /// has ended and kept it, never to an earlier run whose close is still queued.
  @Test(.dependencies) func theMostRecentBindingOwnsAPaneWhateverTheClockSays() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let pane = WorkflowRunMachineTests.reviewerPane
    var earlier = try fixture.session().0
    earlier.run.bindings["reviewer"] = .launch(Self.reviewerProfile, pane: pane)
    await store.send(.started(earlier, effects: [])) {
      $0.paneOwners[pane.surfaceID] = earlier.run.id
    }
    // A later admission whose clock reading is *earlier* still takes the pane over.
    var later = try fixture.session(startedAt: Self.now.addingTimeInterval(-60)).0
    later.run.bindings["author"] = .current(pane)
    await store.send(.started(later, effects: [])) {
      $0.paneOwners[pane.surfaceID] = later.run.id
    }
    await store.send(.userAction(runID: later.run.id, .cancel))
    await store.send(.userAction(runID: earlier.run.id, .cancel))
    await store.finish(timeout: Self.timeout)
    #expect(store.state.activeSession(boundTo: pane.surfaceID) == nil, "an ended run is no longer busy")
    #expect(
      store.state.paneOwners[pane.surfaceID] == later.run.id,
      "the later run keeps the pane it ended with; the earlier run never gets it back")
  }

  /// A relaunch drops the old pane from the role's binding, but the pane stays among the panes
  /// the run ever owned: admission prunes launch reservations against that set, so the old pane
  /// is neither reserved forever nor handed back to the run that left it.
  @Test(.dependencies) func aRelaunchKeepsTheOldPaneAmongTheOwnedOnes() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let store = makeStore(fixture, queue: WorkflowEffectQueue().client)
    let (session, effects) = try fixture.session()
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    await store.receive(.event(runID: runID, .roleIdle(ordinal: 1)), timeout: Self.timeout)
    await store.receive(
      .event(runID: runID, .injectionSucceeded(ordinal: 1, dispatchID: "dispatch-1")), timeout: Self.timeout)
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: UUID(), runID: runID, ordinal: 1, selector: .token(Self.firstToken),
          body: "# Brief\n## Scope\nx\n## Claims\ny", verdict: nil, source: "pane")))
    await store.receive(.event(runID: runID, .outputPersisted(ordinal: 1)), timeout: Self.timeout)
    await store.receive(\.event, timeout: Self.timeout)
    let first = try #require(store.state.sessions[runID]?.run.bindings["reviewer"]?.pane)
    #expect(store.state.paneOwners[first.surfaceID] == runID)
    // The launch boundary reserved the pane while the launch was in flight.
    let reservations = WorkflowPaneReservations()
    reservations.reserve(first.surfaceID)

    await store.send(.event(runID: runID, .watchdog(ordinal: 2, .attention(.agentGone(.sessionEnded)))))
    await store.send(.userAction(runID: runID, .relaunch))
    await store.receive(\.event, timeout: Self.timeout)
    let second = try #require(store.state.sessions[runID]?.run.bindings["reviewer"]?.pane)
    #expect(second.surfaceID != first.surfaceID)
    #expect(store.state.sessions[runID]?.boundSurfaceIDs == [Self.authorPane.surfaceID, second.surfaceID])
    #expect(store.state.paneOwners[first.surfaceID] == runID, "the pane the relaunch left stays owned")
    #expect(store.state.paneOwners[second.surfaceID] == runID)
    #expect(
      reservations.pending(for: store.state, isLive: { _ in true }).isEmpty,
      "admission no longer holds the pane the relaunch left, even while it lives")
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  /// A fence that lands before the executor even reaches the action's batch skips it at the
  /// batch check, and the run log still records that the action was not started.
  @Test(.dependencies) func anActionSkippedAtTheBatchCheckIsLoggedAsNotStarted() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = FencingQueue(fenceOnCheck: 1)
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session(Self.actionFirst)
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    await queue.reached()
    #expect(store.state.sessions[runID]?.run.phase == .runningAction(stepID: "context"))
    await store.send(.userAction(runID: runID, .cancel)) {
      $0.sessions[runID]?.run.status = .cancelled
    }
    await store.finish(timeout: Self.timeout)
    let log = try String(
      contentsOf: session.store.directory(for: runID).appending(path: "log.md"), encoding: .utf8)
    #expect(
      log.contains(
        "Step 'context': native action 'builtin:collect-worktree-context' not started; the run had moved on."))
    #expect(!log.contains("finished after the run moved on"))
  }

  /// Brief delivered, reviewer launched, findings delivered: the run is at `cleanup` (a queued
  /// close) with the `summary` message's idle wait armed. Returns the reviewer's pane.
  private func driveToCleanup(
    _ store: TestStoreOf<WorkflowRunsFeature>, fixture: Fixture, session: WorkflowRunSession,
    effects: [WorkflowRunEffect]
  ) async throws -> WorkflowPaneIdentity {
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    await store.receive(.event(runID: runID, .roleIdle(ordinal: 1)), timeout: Self.timeout)
    await store.receive(
      .event(runID: runID, .injectionSucceeded(ordinal: 1, dispatchID: "dispatch-1")), timeout: Self.timeout)
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: UUID(), runID: runID, ordinal: 1, selector: .token(Self.firstToken), body: "brief",
          verdict: nil, source: "pane")))
    await store.receive(.event(runID: runID, .outputPersisted(ordinal: 1)), timeout: Self.timeout)
    await store.receive(\.event, timeout: Self.timeout)
    let reviewer = try #require(store.state.sessions[runID]?.run.bindings["reviewer"]?.pane)
    await store.send(
      .deliver(
        WorkflowDeliveryRequest(
          requestID: UUID(), runID: runID, ordinal: 2, selector: .token(Self.secondToken), body: "findings",
          verdict: nil, source: "pane")))
    await store.receive(.event(runID: runID, .outputPersisted(ordinal: 2)), timeout: Self.timeout)
    return reviewer
  }

  /// Bookkeeping survives a fence; only pane- and worktree-facing effects are revocable.
  @Test func onlyPaneAndWorktreeFacingEffectsAreRevocable() {
    let pane = UUID()
    let request = WorkflowLaunchRequest(
      role: "r", ordinal: 1, profile: Self.reviewerProfile, prompt: "p", environment: [:], placement: .tab,
      direction: .right, background: false, anchorSurfaceID: nil, skill: nil, expectsDelivery: true,
      redelivery: false)
    #expect(WorkflowRunEffect.openActivation(role: "r", surfaceID: pane, ordinal: 1).isRevocable)
    #expect(
      WorkflowRunEffect.inject(role: "r", surfaceID: pane, ordinal: 1, line: "l", opensActivation: true).isRevocable)
    #expect(WorkflowRunEffect.typeLine(role: "r", surfaceID: pane, line: "l").isRevocable)
    #expect(WorkflowRunEffect.launch(request).isRevocable)
    #expect(
      WorkflowRunEffect.runAction(stepID: "s", actionID: "builtin:collect-worktree-context", inputs: [:]).isRevocable)
    #expect(!WorkflowRunEffect.completeActivation(dispatchID: "d", summary: "s").isRevocable)
    #expect(!WorkflowRunEffect.abandonActivation(dispatchID: "d", reason: "r").isRevocable)
    #expect(!WorkflowRunEffect.persist.isRevocable)
    #expect(!WorkflowRunEffect.persistOutput(name: "o", ordinal: 1, body: "b").isRevocable)
    #expect(!WorkflowRunEffect.log("l").isRevocable)
    #expect(WorkflowRunEffect.close(role: "r", surfaceID: pane).isRevocable, "cancel never closes panes")
    #expect(!WorkflowRunEffect.notify("n").isRevocable)
    #expect(!WorkflowRunEffect.notify("n").isRevocable)
    #expect(!WorkflowRunEffect.finished(.cancelled).isRevocable)
  }

  // MARK: - Start rendezvous

  /// A self-initiated `run` is answered only once its first activation is open, so the caller
  /// never holds a completion command before the record `done` is attributed by exists.
  @Test(.dependencies) func aSelfInitiatedRunIsAnsweredOnceItsActivationIsOpen() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session(selfInitiated: true)
    let runID = session.run.id
    #expect(session.run.phase == .injecting(ordinal: 1))
    #expect(effects.contains(.openActivation(role: "author", surfaceID: Self.authorPane.surfaceID, ordinal: 1)))
    let requestID = UUID()
    await store.send(.started(session, effects: effects, requestID: requestID)) {
      $0.pendingStarts[requestID] = runID
    }
    #expect(fixture.responses.isEmpty)
    await store.send(.event(runID: runID, .injectionSucceeded(ordinal: 1, dispatchID: "dispatch-1"))) {
      $0.pendingStarts = [:]
    }
    await store.finish(timeout: Self.timeout)
    #expect(fixture.responses.count == 1)
    guard case .started(let run) = fixture.responses[0].resolution else {
      Issue.record("expected a started resolution")
      return
    }
    #expect(run.phase == .waitingForDelivery(ordinal: 1))
    #expect(run.activeActivation?.dispatchID == "dispatch-1")

    // A failed opening answers too, with the run in attention.
    let (second, secondEffects) = try fixture.session(selfInitiated: true)
    let secondRequest = UUID()
    await store.send(.started(second, effects: secondEffects, requestID: secondRequest))
    await store.send(.event(runID: second.run.id, .injectionFailed(ordinal: 1, .surfaceMissing)))
    await store.finish(timeout: Self.timeout)
    guard case .started(let failed) = fixture.responses[1].resolution else {
      Issue.record("expected a started resolution")
      return
    }
    #expect(failed.status.attention?.reason.code == "injection_failed:surface_missing")
    await store.send(.userAction(runID: runID, .cancel))
    await store.send(.userAction(runID: second.run.id, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  // MARK: - Idle wait outcomes

  @Test(.dependencies) func aBlockedRoleDuringTheIdleWaitRaisesAttention() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    fixture.roleWaitOutcome = .blocked
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session()
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    await store.receive(
      .event(runID: runID, .roleUnavailable(ordinal: 1, .roleBlocked)), timeout: Self.timeout)
    #expect(store.state.sessions[runID]?.run.status.attention?.reason.code == "injection_failed:role_blocked")
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  @Test(.dependencies) func aPaneWithAForeignPendingDispatchEndsTheIdleWaitInAttention() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    fixture.roleWaitOutcome = .dispatchPending("someone-elses-dispatch")
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, effects) = try fixture.session()
    let runID = session.run.id
    await store.send(.started(session, effects: effects))
    await store.receive(\.event, timeout: Self.timeout)
    #expect(
      store.state.sessions[runID]?.run.status.attention?.reason.code == "injection_failed:activation_unavailable")
    #expect(store.state.sessions[runID]?.run.status.attention?.message.contains("someone-elses-dispatch") == true)
    #expect(fixture.typed.isEmpty)
    await store.send(.userAction(runID: runID, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  // MARK: - Presentation notices

  @Test(.dependencies) func statusEdgesEmitOneTypedNotice() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let (session, _) = try fixture.session()
    let runID = session.run.id
    var expectedMachine = session.machine(now: { Self.now }, makeToken: { "unused" })
    _ = expectedMachine.apply(.injectionFailed(ordinal: 1, .surfaceMissing))
    let notice = try #require(
      WorkflowRunNotice.statusEdge(from: session.run.status, to: expectedMachine.run)
    )

    await store.send(.started(session, effects: []))
    await store.send(.event(runID: runID, .injectionFailed(ordinal: 1, .surfaceMissing)))
    await store.receive(\.delegate.notice, notice)
    #expect(notice.kind == .needsAttention)
    #expect(notice.runID == runID)
    #expect(notice.worktreeID == fixture.worktree.id)
    #expect(notice.targetSurfaceID == Self.authorPane.surfaceID)
    #expect(notice.body.contains("pane is gone"))

    // A late event while the same attention state is active is ignored and emits no duplicate.
    store.exhaustivity = .on
    await store.send(.event(runID: runID, .injectionFailed(ordinal: 1, .surfaceMissing)))
    _ = expectedMachine.apply(.user(.cancel))
    await store.send(.userAction(runID: runID, .cancel)) {
      $0.sessions[runID]?.run = expectedMachine.run
    }
    await store.finish(timeout: Self.timeout)
  }

  @Test func runNoticeCoversMeaningfulTerminalEdgesButNotExplicitCancellation() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var session = try fixture.session().0
    let running = session.run.status

    session.run.status = .completed
    #expect(WorkflowRunNotice.statusEdge(from: running, to: session.run)?.kind == .completed)
    session.run.status = .skipped(step: "brief", dependent: "launch")
    #expect(WorkflowRunNotice.statusEdge(from: running, to: session.run)?.kind == .skipped)
    session.run.status = .iterationLimitReached
    #expect(WorkflowRunNotice.statusEdge(from: running, to: session.run)?.kind == .iterationLimitReached)
    session.run.status = .cancelled
    #expect(WorkflowRunNotice.statusEdge(from: running, to: session.run) == nil)
    #expect(WorkflowRunNotice.statusEdge(from: .completed, to: session.run) == nil)
  }

  @Test func changedAttentionEmitsANewNoticeButIdenticalAttentionDoesNot() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var session = try fixture.session().0
    let ordinal = try #require(session.run.currentInvocation?.ordinal)
    let blocked = WorkflowAttention(
      reason: .blocked,
      stepID: "brief",
      role: "author",
      ordinal: ordinal,
      actions: [.focusPane, .keepWaiting, .cancel],
      message: "The role is blocked."
    )
    let waiting = WorkflowAttention(
      reason: .idleWithoutDelivery,
      stepID: "brief",
      role: "author",
      ordinal: ordinal,
      actions: [.focusPane, .nudge, .keepWaiting, .skip, .cancel],
      message: "The role went idle without delivering."
    )
    session.run.status = .needsAttention(waiting)

    #expect(
      WorkflowRunNotice.statusEdge(from: .needsAttention(blocked), to: session.run)?.kind == .needsAttention
    )
    #expect(WorkflowRunNotice.statusEdge(from: session.run.status, to: session.run) == nil)
  }

  @Test(.dependencies) func explicitFinalNotifySuppressesTheDuplicateGenericCompletionNotification() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    var session = try fixture.session().0
    session.run.status = .completed
    let base = try #require(WorkflowRunNotice.statusEdge(from: nil, to: session.run))
    let expected = WorkflowRunNotice(
      kind: base.kind,
      runID: base.runID,
      worktreeID: base.worktreeID,
      workflowName: base.workflowName,
      title: base.title,
      body: base.body,
      targetSurfaceID: base.targetSurfaceID,
      postsNotification: false
    )

    await store.send(.started(session, effects: [.notify("Custom completion")]))
    await store.receive(\.delegate.notice, expected)
    await store.finish(timeout: Self.timeout)
  }

  // MARK: - Restart scan

  @Test(
    .dependencies {
      $0[WorkflowHistoryStorageKey.self] = WorkflowHistoryStorage(
        baseURL: FileManager.default.temporaryDirectory.appending(path: "workflow-recovery-\(UUID().uuidString)"))
    })
  func recoveryRunsOnceGlobally() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let (session, _) = try fixture.session()
    try session.store.ensureLayout(runID: session.run.id)
    try session.store.writeRecord(WorkflowRunRecord(run: session.run))
    let queue = RecordingQueue()
    let store = makeStore(fixture, queue: queue.client)
    let root = fixture.root.path(percentEncoded: false)

    await store.send(.markInterruptedRuns(worktreeRoots: [root])) {
      $0.scannedWorktreeRoots = [root]
    }
    await store.finish(timeout: Self.timeout)
    #expect(try session.store.readRecord(runID: session.run.id).run.status.state == "interrupted")

    // A second scan of the same root is a no-op even after a new run started there.
    await store.send(.started(session, effects: []))
    await store.send(.markInterruptedRuns(worktreeRoots: [root]))
    await store.finish(timeout: Self.timeout)
    #expect(store.state.sessions[session.run.id]?.run.status == .running)
    await store.send(.userAction(runID: session.run.id, .cancel))
    await store.finish(timeout: Self.timeout)
  }

  // MARK: - Helpers

  /// The session after its first message was typed: activation 1 waits on `dispatch-0`.
  private func waitingForDelivery(_ session: WorkflowRunSession) throws -> WorkflowRunSession {
    var machine = session.machine(now: { Self.now }, makeToken: { "TOKEN-1" })
    _ = machine.apply(.roleIdle(ordinal: 1))
    _ = machine.apply(.injectionSucceeded(ordinal: 1, dispatchID: "dispatch-0"))
    #expect(machine.run.phase == .waitingForDelivery(ordinal: 1))
    var waiting = session
    waiting.run = machine.run
    return waiting
  }
}

/// The per-run FIFO's fence: everything enqueued before it is stale, later batches are not.
@MainActor
struct WorkflowEffectQueueTests {
  @Test func aFenceMarksEarlierBatchesStaleAndLaterOnesLive() async throws {
    let queue = WorkflowEffectQueue()
    let runID = UUID()
    let stream = queue.start(runID)
    let session = try WorkflowRunsFeatureTests.Fixture().session().0
    queue.enqueue(runID, WorkflowEffectBatch(session: session, effects: [.log("one")]))
    queue.enqueue(runID, WorkflowEffectBatch(session: session, effects: [.log("two")]))
    queue.fence(runID)
    queue.enqueue(runID, WorkflowEffectBatch(session: session, effects: [.log("three")]))
    queue.finish(runID)
    var seen: [(sequence: Int, stale: Bool)] = []
    for await batch in stream {
      seen.append((batch.sequence, queue.isStale(runID, sequence: batch.sequence)))
    }
    #expect(seen.map(\.sequence) == [1, 2, 3])
    // After `finish` nothing is known about the run: every sequence reads stale.
    #expect(queue.isStale(runID, sequence: 3))
    let queue2 = WorkflowEffectQueue()
    _ = queue2.start(runID)
    queue2.enqueue(runID, WorkflowEffectBatch(session: session, effects: [.log("one")]))
    queue2.enqueue(runID, WorkflowEffectBatch(session: session, effects: [.log("two")]))
    queue2.fence(runID)
    queue2.enqueue(runID, WorkflowEffectBatch(session: session, effects: [.log("three")]))
    #expect(queue2.isStale(runID, sequence: 1))
    #expect(queue2.isStale(runID, sequence: 2))
    #expect(!queue2.isStale(runID, sequence: 3))
  }
}
