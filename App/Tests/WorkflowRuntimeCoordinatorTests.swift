// supacodeTests/WorkflowRuntimeCoordinatorTests.swift
// `prowl workflow status / deliver / cancel` attribution and responses (docs-ai 063 B3, W1/W3/W5).

import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowRuntimeCoordinatorTests {
  nonisolated private static let now = Date(timeIntervalSince1970: 1_760_000_000)

  @MainActor
  final class Fixture {
    let root: URL
    var sessions: [WorkflowRunSession] = []
    var sent: [WorkflowRunsFeature.Action] = []
    var pendingByPane: [UUID: String] = [:]
    var contentOwner: UUID?
    let rendezvous = WorkflowCLIRendezvous()
    let requestID = UUID()
    /// What the reducer would answer to a `.deliver`, applied synchronously inside `send`.
    var answer: WorkflowRequestResolution?
    private(set) var coordinator: WorkflowRuntimeCoordinator!

    init() throws {
      root =
        FileManager.default.temporaryDirectory
        .appending(path: "workflow-coordinator-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .standardizedFileURL
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      coordinator = WorkflowRuntimeCoordinator(
        dependencies: WorkflowRuntimeCoordinator.Dependencies(
          admissionEnvironment: { fatalError("admission is covered by WorkflowRunAdmissionTests") },
          sessions: { [self] in sessions },
          send: { [self] action in
            sent.append(action)
            if case .deliver(let request) = action, let answer {
              coordinator.resolve(request.requestID, answer)
            }
            if case .userAction(let runID, .cancel) = action,
              let index = sessions.firstIndex(where: { $0.run.id == runID })
            {
              var machine = sessions[index].machine(now: { WorkflowRuntimeCoordinatorTests.now }, makeToken: { "T" })
              _ = machine.apply(.user(.cancel))
              sessions[index].run = machine.run
            }
          },
          pendingDispatchID: { [self] surfaceID in pendingByPane[surfaceID] },
          worktreeRoots: { [self] in [root] },
          paneOwner: { [self] pane in
            contentOwner ?? sessions.last(where: { $0.boundSurfaceIDs.contains(pane) })?.run.id
          },
          rendezvous: rendezvous,
          makeRequestID: { [self] in requestID }))
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }

    /// A review run whose first activation (`brief`, ordinal 1) waits on `dispatch-1` in the author pane.
    func waitingSession() throws -> WorkflowRunSession {
      let definition = try #require(WorkflowDocumentParser.parse(WorkflowRunMachineTests.adversarialReview).definition)
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
            "author": .current(WorkflowRunMachineTests.authorPane),
            "reviewer": .launch(WorkflowRunMachineTests.reviewerProfile, pane: nil),
          ]),
        now: { WorkflowRuntimeCoordinatorTests.now },
        makeToken: { counter.next() })
      var machine = started.machine
      _ = machine.apply(.roleIdle(ordinal: 1))
      _ = machine.apply(.injectionSucceeded(ordinal: 1, dispatchID: "dispatch-1"))
      pendingByPane[WorkflowRunMachineTests.authorPane.surfaceID] = "dispatch-1"
      return WorkflowRunSession(
        run: machine.run,
        worktree: Worktree(id: "wt", name: "feature", detail: "", workingDirectory: root, repositoryRootURL: root),
        launchPlans: [:])
    }
  }

  @Test func contentReadRequiresTheAssignedPaneRunAndInvocation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    try session.store.ensureLayout(runID: session.run.id)
    let grant = try #require(session.run.currentInvocation?.content)
    let request = WorkflowInput(action: .read, invocation: grant.invocation, runID: grant.runID.uuidString)
    #expect(await fixture.coordinator.read(request, callerPane: Self.authorCaller).ok)
    #expect(await fixture.coordinator.read(request, callerPane: Self.strangerCaller).ok == false)
    #expect(
      await fixture.coordinator.read(
        .init(action: .read, invocation: grant.invocation + 1, runID: grant.runID.uuidString),
        callerPane: Self.authorCaller
      ).ok == false)
    #expect(
      await fixture.coordinator.read(
        .init(
          action: .read, invocation: grant.invocation, contentResource: "/etc/passwd", runID: grant.runID.uuidString),
        callerPane: Self.authorCaller
      ).ok == false)
    fixture.contentOwner = UUID()
    #expect(await fixture.coordinator.read(request, callerPane: Self.authorCaller).ok == false)
    fixture.contentOwner = nil
    _ = fixture.coordinator.cancel(
      .init(action: .cancel, runID: session.run.id.uuidString), callerPane: Self.authorCaller)
    #expect(await fixture.coordinator.read(request, callerPane: Self.authorCaller).ok == false)
  }

  @Test func skippedAndRevokedTasksCannotBeRead() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var session = try fixture.waitingSession()
    try session.store.ensureLayout(runID: session.run.id)
    let request = WorkflowInput(action: .read, invocation: 1, runID: session.run.id.uuidString)
    session.run.invocations[0].activation?.state = .skipped
    fixture.sessions = [session]
    #expect(await fixture.coordinator.read(request, callerPane: Self.authorCaller).ok == false)
    session.run.invocations[0].activation?.state = .revoked
    fixture.sessions = [session]
    #expect(await fixture.coordinator.read(request, callerPane: Self.authorCaller).ok == false)
  }

  @Test func completedTaskRemainsReadableUntilReassignmentOrHistoryRemoval() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var session = try fixture.waitingSession()
    session.run.status = .completed
    session.run.invocations[0].activation = nil
    try session.store.ensureLayout(runID: session.run.id)
    fixture.sessions = [session]
    let request = WorkflowInput(action: .read, invocation: 1, runID: session.run.id.uuidString)
    #expect(await fixture.coordinator.read(request, callerPane: Self.authorCaller).ok)
    let wrongRun = WorkflowInput(action: .read, invocation: 1, runID: UUID().uuidString)
    #expect(await fixture.coordinator.read(wrongRun, callerPane: Self.authorCaller).ok == false)
    fixture.contentOwner = UUID()
    #expect(await fixture.coordinator.read(request, callerPane: Self.authorCaller).ok == false)
    fixture.contentOwner = nil
    try FileManager.default.removeItem(at: session.run.runDirectory)
    #expect(await fixture.coordinator.read(request, callerPane: Self.authorCaller).ok == false)
  }

  @Test func assignedArtifactDirectoryListsOnlyItsContainedFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var session = try fixture.waitingSession()
    try session.store.ensureLayout(runID: session.run.id)
    let directory = session.run.runDirectory.appending(path: "actions/test/artifacts")
    try session.store.storage.prepare(directory)
    try Data("artifact bytes".utf8).write(to: directory.appending(path: "result.txt"))
    let old = try #require(session.run.currentInvocation?.content)
    session.run.invocations[0].content = .make(
      text: "Read \(directory.path)", task: (old.runID, old.invocation),
      runDirectory: session.run.runDirectory,
      knownPaths: [directory.path], skill: nil)
    fixture.sessions = [session]
    let response = await fixture.coordinator.read(
      .init(action: .read, invocation: old.invocation, contentResource: "resource-1", runID: old.runID.uuidString),
      callerPane: Self.authorCaller)
    guard case .read(let listing) = try payload(response) else {
      Issue.record("Expected directory listing")
      return
    }
    #expect(listing.body.contains("resource-1-file-1"))
    let file = await fixture.coordinator.read(
      .init(
        action: .read, invocation: old.invocation, contentResource: "resource-1-file-1", runID: old.runID.uuidString),
      callerPane: Self.authorCaller)
    guard case .read(let content) = try payload(file) else {
      Issue.record("Expected artifact content")
      return
    }
    #expect(content.body == "artifact bytes")
  }

  @Test func deletedTerminalHistoryIsNotReturnedFromTheSessionCache() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var session = try fixture.waitingSession()
    var machine = session.machine(now: { Self.now }, makeToken: { "token" })
    _ = machine.apply(.user(.cancel))
    session.run = machine.run
    try session.store.ensureLayout(runID: session.run.id)
    try session.store.writeRecord(WorkflowRunRecord(run: session.run))
    fixture.sessions = [session]
    let request = WorkflowInput(action: .status, runID: session.run.id.uuidString)
    #expect(fixture.coordinator.status(request, callerPane: nil).ok)
    try FileManager.default.removeItem(at: session.run.runDirectory)
    #expect(fixture.coordinator.status(request, callerPane: nil).error?.code == CLIErrorCode.runNotFound)
  }

  private static let authorCaller = CallerPane(
    worktreeID: "wt", surfaceID: WorkflowRunMachineTests.authorPane.surfaceID)
  private static let strangerCaller = CallerPane(worktreeID: "wt", surfaceID: UUID())

  private func delivered(_ session: WorkflowRunSession) throws -> WorkflowRequestResolution {
    var machine = session.machine(now: { Self.now }, makeToken: { "T" })
    let (result, _) = machine.deliver(
      ordinal: 1, selector: .token("TOKEN-1"), body: "## Scope\nx\n## Claims\ny", verdict: nil)
    _ = machine.apply(.deliveryPersisted(ordinal: 1))
    return .delivered(run: machine.run, receipt: try result.get())
  }

  private func payload(_ response: CommandResponse) throws -> WorkflowCommandPayload {
    try JSONDecoder().decode(WorkflowCommandPayload.self, from: try #require(response.data).bytes)
  }

  // MARK: - deliver attribution (decision W3)

  @Test func deliverFromTheRolePaneIsAttributedByItsPendingDispatch() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    fixture.answer = try delivered(session)

    let response = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, body: "## Scope\nx\n## Claims\ny", token: "TOKEN-1"),
      callerPane: Self.authorCaller)
    #expect(response.ok, "\(response.error?.message ?? "")")
    guard case .deliver(let request) = fixture.sent.first else {
      Issue.record("expected a deliver action")
      return
    }
    #expect(request.requestID == fixture.requestID)
    #expect(request.runID == session.run.id)
    #expect(request.ordinal == 1)
    #expect(request.selector == .token("TOKEN-1"))
    #expect(request.source == "pane")
    #expect(request.body == "## Scope\nx\n## Claims\ny")
    guard case .deliver(let deliver) = try payload(response) else {
      Issue.record("expected a deliver payload")
      return
    }
    #expect(deliver.delivery.state == .delivered)
    #expect(deliver.delivery.role == "author")
    #expect(deliver.delivery.record.name == "brief")
    #expect(deliver.run.role == "author")
    #expect(fixture.rendezvous.pendingRequestIDs.isEmpty)
  }

  @Test func deliverWithoutABodyOrHalfAManualTargetIsInvalid() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let noBody = await fixture.coordinator.deliver(WorkflowInput(action: .deliver), callerPane: Self.authorCaller)
    #expect(noBody.error?.code == CLIErrorCode.invalidArgument)
    let half = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: UUID().uuidString, body: "x"), callerPane: Self.authorCaller)
    #expect(half.error?.code == CLIErrorCode.invalidArgument)
    let badID = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: "nope", stepID: "brief", body: "x"), callerPane: nil)
    #expect(badID.error?.code == CLIErrorCode.invalidArgument)
    #expect(fixture.sent.isEmpty)
  }

  @Test func deliverOutsideAnyPaneNeedsAnExplicitTargetAndThenIsManual() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    fixture.answer = .failed(code: CLIErrorCode.stepNotExpecting, message: "no")

    let missing = await fixture.coordinator.deliver(WorkflowInput(action: .deliver, body: "x"), callerPane: nil)
    #expect(missing.error?.code == CLIErrorCode.sourceRequired)
    #expect(fixture.sent.isEmpty)

    let manual = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: session.run.id.uuidString, stepID: "brief", body: "x"), callerPane: nil)
    #expect(manual.error?.code == CLIErrorCode.stepNotExpecting, "the reducer's answer is passed through")
    guard case .deliver(let request) = fixture.sent.first else {
      Issue.record("expected a deliver action")
      return
    }
    #expect(request.ordinal == nil)
    #expect(request.selector == .manual(stepID: "brief"))
    #expect(request.source == "manual")

    let unknown = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: UUID().uuidString, stepID: "brief", body: "x"), callerPane: nil)
    #expect(unknown.error?.code == CLIErrorCode.runNotFound)
  }

  @Test func aPaneWithoutAnActivationCanStillDeliverManuallyButNotImplicitly() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    fixture.answer = .failed(code: CLIErrorCode.stepNotExpecting, message: "no")

    let implicit = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, body: "x"), callerPane: Self.strangerCaller)
    #expect(implicit.error?.code == CLIErrorCode.stepNotExpecting)
    #expect(fixture.sent.isEmpty)

    _ = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: session.run.id.uuidString, stepID: "brief", body: "x"),
      callerPane: Self.strangerCaller)
    guard case .deliver(let request) = fixture.sent.first else {
      Issue.record("expected a deliver action")
      return
    }
    #expect(request.source == "manual")
  }

  @Test func anExplicitTargetThatDisagreesWithTheCallerPaneNeedsForce() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    fixture.answer = .failed(code: CLIErrorCode.stepNotExpecting, message: "no")

    let mismatch = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: session.run.id.uuidString, stepID: "launch", body: "x"),
      callerPane: Self.authorCaller)
    #expect(mismatch.error?.code == CLIErrorCode.roleMismatch)
    #expect(fixture.sent.isEmpty)

    let agreeing = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: session.run.id.uuidString, stepID: "brief", body: "x", token: "TOKEN-1"),
      callerPane: Self.authorCaller)
    #expect(agreeing.error?.code == CLIErrorCode.stepNotExpecting)
    guard case .deliver(let agreed) = fixture.sent.last else {
      Issue.record("expected a deliver action")
      return
    }
    #expect(agreed.source == "pane")
    #expect(agreed.ordinal == 1)

    _ = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: session.run.id.uuidString, stepID: "launch", body: "x", force: true),
      callerPane: Self.authorCaller)
    guard case .deliver(let forced) = fixture.sent.last else {
      Issue.record("expected a deliver action")
      return
    }
    #expect(forced.source == "manual --force")
    #expect(forced.selector == .manual(stepID: "launch"))
  }

  @Test func deliverAwaitsTheReducerAndAProvisionalAnswerIsReportedAsProvisional() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    // No synchronous answer: the reducer resolves later, after persistence.
    let task = Task { @MainActor in
      await fixture.coordinator.deliver(
        WorkflowInput(action: .deliver, body: "## Scope\nonly", token: "TOKEN-1"), callerPane: Self.authorCaller)
    }
    await Task.yield()
    #expect(fixture.rendezvous.pendingRequestIDs == [fixture.requestID])
    var machine = session.machine(now: { Self.now }, makeToken: { "T" })
    let (result, _) = machine.deliver(ordinal: 1, selector: .token("TOKEN-1"), body: "## Scope\nonly", verdict: nil)
    _ = machine.apply(.deliveryPersisted(ordinal: 1))
    fixture.coordinator.resolve(fixture.requestID, .provisional(run: machine.run, receipt: try result.get()))
    let response = await task.value
    #expect(response.ok)
    guard case .deliver(let deliver) = try payload(response) else {
      Issue.record("expected a deliver payload")
      return
    }
    #expect(deliver.delivery.state == .provisional)
    #expect(deliver.delivery.warnings.map(\.code) == ["missing_sections"])
    #expect(deliver.run.status.state == "needs_attention")
    #expect(deliver.run.status.attention?.issues == ["missing_sections"])
  }

  @Test func aDuplicateRequestIDIsRefusedWithoutEnteringTheReducer() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    // No synchronous answer: the first request stays pending under the fixed request id.
    let first = Task { @MainActor in
      await fixture.coordinator.deliver(
        WorkflowInput(action: .deliver, body: "x", token: "TOKEN-1"), callerPane: Self.authorCaller)
    }
    await Task.yield()
    #expect(fixture.rendezvous.pendingRequestIDs == [fixture.requestID])
    let duplicate = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, body: "y", token: "TOKEN-1"), callerPane: Self.authorCaller)
    #expect(duplicate.error?.code == CLIErrorCode.requestConflict)
    #expect(fixture.sent.count == 1, "the duplicate never reaches the reducer")
    fixture.coordinator.resolve(fixture.requestID, .failed(code: CLIErrorCode.stepNotExpecting, message: "no"))
    #expect((await first.value).error?.code == CLIErrorCode.stepNotExpecting)
  }

  /// A waiter the socket cancelled frees its slot, but its request id stays in flight until the
  /// reducer answers: a reused id can neither be answered by the old transaction nor inherit
  /// its verified caller role.
  @Test func aCancelledWaitersRequestIDStaysUnusableUntilTheReducerAnswers() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    let first = Task { @MainActor in
      await fixture.coordinator.deliver(
        WorkflowInput(action: .deliver, body: "x", token: "TOKEN-1"), callerPane: Self.authorCaller)
    }
    await Task.yield()
    first.cancel()
    #expect((await first.value).error?.code == CLIErrorCode.requestCancelled)
    #expect(fixture.rendezvous.pendingRequestIDs.isEmpty)

    let reuse = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: session.run.id.uuidString, stepID: "brief", body: "y"), callerPane: nil)
    #expect(reuse.error?.code == CLIErrorCode.requestConflict)
    #expect(fixture.sent.count == 1)

    // The old transaction's answer goes nowhere, and only then is the id free again.
    fixture.coordinator.resolve(fixture.requestID, .failed(code: CLIErrorCode.stepNotExpecting, message: "late"))
    fixture.answer = .failed(code: CLIErrorCode.stepNotExpecting, message: "fresh")
    let fresh = await fixture.coordinator.deliver(
      WorkflowInput(action: .deliver, runID: session.run.id.uuidString, stepID: "brief", body: "y"), callerPane: nil)
    #expect(fresh.error?.message == "fresh")
    #expect(fixture.sent.count == 2)
  }

  /// Tokens are spelled only to the pane that owns the activation: a manual delivery advancing
  /// the run to the same role's next step must not learn that step's completion command.
  @Test func aManualDeliveryIsAnsweredWithoutTheNextActivationsToken() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]
    // The delivered resolution's run has advanced to the launch step, whose activation waits.
    var machine = session.machine(now: { Self.now }, makeToken: { "TOKEN-2" })
    let (result, _) = machine.deliver(
      ordinal: nil, selector: .manual(stepID: "brief"), body: "## Scope\nx\n## Claims\ny", verdict: nil)
    _ = machine.apply(.deliveryPersisted(ordinal: 1))
    #expect(machine.run.phase == .launching(ordinal: 2))
    let reviewerPane = WorkflowPaneIdentity(surfaceID: UUID(), tabID: nil, handle: "p9", displayName: "Pi", agent: "pi")
    _ = machine.apply(.launched(ordinal: 2, pane: reviewerPane, dispatchID: "dispatch-2"))
    fixture.answer = .delivered(run: machine.run, receipt: try result.get())

    let response = await fixture.coordinator.deliver(
      WorkflowInput(
        action: .deliver, runID: session.run.id.uuidString, stepID: "brief", body: "## Scope\nx\n## Claims\ny"),
      callerPane: nil)
    #expect(response.ok, "\(response.error?.message ?? "")")
    guard case .deliver(let deliver) = try payload(response) else {
      Issue.record("expected a deliver payload")
      return
    }
    #expect(deliver.delivery.role == "author")
    #expect(deliver.run.role == nil)
    #expect(deliver.run.activation?.role == "reviewer")
    #expect(deliver.run.activation?.expect.completion == [], "a manual caller is not the reviewer's pane")
  }

  /// `run` spells the completion command only for the caller's own activation: a workflow whose
  /// first awaited step is a launch must not hand the launcher the reviewer's token.
  @Test func aRunResponseNeverSpellsAnotherRolesCompletion() throws {
    let yaml = """
      schema: prowl.workflow/v1
      id: launch-first
      name: Launch First
      roles:
        author:
          source: current
        reviewer:
          source: launch
      steps:
        - id: launch
          launch: reviewer
          prompt: "Review."
          expect: { delivery: findings }
      """
    let definition = try #require(WorkflowDocumentParser.parse(yaml).definition)
    let started = try WorkflowRunMachine.start(
      WorkflowRunStartRequest(
        definition: definition, runID: UUID(),
        context: WorkflowRunContext(
          scope: .user, definitionPath: nil,
          worktree: WorkflowRunWorktree(id: "wt", name: "feature", branch: "feat/x", path: "/tmp")),
        bindings: [
          "author": .current(WorkflowRunMachineTests.authorPane),
          "reviewer": .launch(WorkflowRunMachineTests.reviewerProfile, pane: nil),
        ],
        selfInitiated: true),
      now: { Self.now }, makeToken: { "SECRET" })
    var machine = started.machine
    let reviewerPane = WorkflowPaneIdentity(surfaceID: UUID(), tabID: nil, handle: "p9", displayName: "Pi", agent: "pi")
    _ = machine.apply(.launched(ordinal: 1, pane: reviewerPane, dispatchID: "dispatch-1"))
    #expect(machine.run.currentActivation?.role == "reviewer")

    let asAuthor = WorkflowRunPayload(run: machine.run, callerRole: "author", includeSelfInitiated: true)
    #expect(asAuthor.activation?.expect.completion == [])
    #expect(asAuthor.selfInitiated == nil)
    let asNobody = WorkflowRunPayload(run: machine.run, callerRole: nil, includeSelfInitiated: true)
    #expect(asNobody.activation?.expect.completion == [])
    let asReviewer = WorkflowRunPayload(run: machine.run, callerRole: "reviewer", includeSelfInitiated: false)
    #expect(asReviewer.activation?.expect.completion == ["PROWL_WORKFLOW_TOKEN=SECRET prowl workflow deliver -"])
  }

  /// `agents dispatch-complete` is refused for a workflow activation even after its run ended:
  /// the abandon is queued behind earlier work and must not lose to a plain completion.
  @Test func deliveryRefusalCoversTerminalRuns() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    let live = WorkflowRuntimeCoordinator.deliveryRefusal(dispatchID: "dispatch-1", sessions: [session])
    #expect(live?.code == CLIErrorCode.workflowDeliveryRequired)
    #expect(live?.message.contains("prowl workflow deliver") == true)
    var machine = session.machine(now: { Self.now }, makeToken: { "T" })
    _ = machine.apply(.user(.cancel))
    var ended = session
    ended.run = machine.run
    let terminal = WorkflowRuntimeCoordinator.deliveryRefusal(dispatchID: "dispatch-1", sessions: [ended])
    #expect(terminal?.code == CLIErrorCode.workflowDeliveryRequired)
    #expect(terminal?.message.contains("already ended") == true)
    #expect(WorkflowRuntimeCoordinator.deliveryRefusal(dispatchID: "unrelated", sessions: [session, ended]) == nil)
  }

  // MARK: - status (decision W5)

  @Test func statusReadsTheCallerPaneRunALiveRunOrARecordedRun() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]

    let mine = fixture.coordinator.status(WorkflowInput(action: .status), callerPane: Self.authorCaller)
    guard case .status(let whoAmI) = try payload(mine) else {
      Issue.record("expected a status payload")
      return
    }
    #expect(whoAmI.source == .live)
    #expect(whoAmI.role == "author")
    #expect(whoAmI.step == "brief")
    #expect(whoAmI.activation?.expect.completion == ["PROWL_WORKFLOW_TOKEN=TOKEN-1 prowl workflow deliver -"])
    #expect(whoAmI.selfInitiated == nil)

    let stranger = fixture.coordinator.status(WorkflowInput(action: .status), callerPane: Self.strangerCaller)
    #expect(stranger.error?.code == CLIErrorCode.runNotFound)
    let outside = fixture.coordinator.status(WorkflowInput(action: .status), callerPane: nil)
    #expect(outside.error?.code == CLIErrorCode.sourceRequired)

    let byID = fixture.coordinator.status(
      WorkflowInput(action: .status, runID: session.run.id.uuidString), callerPane: Self.strangerCaller)
    guard case .status(let other) = try payload(byID) else {
      Issue.record("expected a status payload")
      return
    }
    #expect(other.role == nil)
    #expect(other.activation?.expect.completion == [], "tokens are spelled only to the role's own pane")

    // A run that is not live any more is read back from its record: no activation, no tokens.
    try session.store.ensureLayout(runID: session.run.id)
    try session.store.writeRecord(WorkflowRunRecord(run: session.run).interrupted(at: Self.now))
    fixture.sessions = []
    let recorded = fixture.coordinator.status(
      WorkflowInput(action: .status, runID: session.run.id.uuidString), callerPane: nil)
    guard case .status(let record) = try payload(recorded) else {
      Issue.record("expected a status payload")
      return
    }
    #expect(record.source == .record)
    #expect(record.status.state == "interrupted")
    #expect(record.activation == nil)
    #expect(record.bindings["author"]?.pane?.handle == "p1")

    let missing = fixture.coordinator.status(WorkflowInput(action: .status, runID: UUID().uuidString), callerPane: nil)
    #expect(missing.error?.code == CLIErrorCode.runNotFound)
    let malformed = fixture.coordinator.status(WorkflowInput(action: .status, runID: "x"), callerPane: nil)
    #expect(malformed.error?.code == CLIErrorCode.invalidArgument)
  }

  /// An invocation stuck in an injection attention has no activation `deliver` could address, so
  /// `status` must not advertise one (the caller would otherwise retry `deliver` forever).
  @Test func statusReportsNoActivationWhileTheStepIsInAnInjectionAttention() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var session = try fixture.waitingSession()
    var machine = session.machine(now: { Self.now }, makeToken: { "T" })
    _ = machine.apply(.user(.cancel))
    _ = session
    // Rebuild a fresh session whose first step failed to inject.
    let definition = try #require(WorkflowDocumentParser.parse(WorkflowRunMachineTests.adversarialReview).definition)
    let started = try WorkflowRunMachine.start(
      WorkflowRunStartRequest(
        definition: definition, runID: UUID(),
        context: WorkflowRunContext(
          scope: .user, definitionPath: nil,
          worktree: WorkflowRunWorktree(
            id: "wt", name: "feature", branch: "feat/x", path: fixture.root.path(percentEncoded: false))),
        bindings: [
          "author": .current(WorkflowRunMachineTests.authorPane),
          "reviewer": .launch(WorkflowRunMachineTests.reviewerProfile, pane: nil),
        ]),
      now: { Self.now }, makeToken: { "T" })
    machine = started.machine
    _ = machine.apply(.roleUnavailable(ordinal: 1, .roleBlocked))
    session = WorkflowRunSession(
      run: machine.run,
      worktree: Worktree(
        id: "wt", name: "feature", detail: "", workingDirectory: fixture.root, repositoryRootURL: fixture.root),
      launchPlans: [:])
    fixture.sessions = [session]
    let response = fixture.coordinator.status(WorkflowInput(action: .status), callerPane: Self.authorCaller)
    guard case .status(let payload) = try payload(response) else {
      Issue.record("expected a status payload")
      return
    }
    #expect(payload.status.state == "needs_attention")
    #expect(payload.status.attention?.reason == "injection_failed:role_blocked")
    #expect(payload.activation == nil)
  }

  /// A pane a finished run kept is free again: reservations are pruned against every run that
  /// ever bound the pane, not only the active ones.
  @Test func reservationsAreReleasedOncePaneWasBoundEvenByAFinishedRun() {
    let reservations = WorkflowPaneReservations()
    let launched = UUID()
    let gone = UUID()
    reservations.reserve(launched)
    reservations.reserve(gone)
    #expect(reservations.pending(everBound: [], isLive: { _ in true }) == [launched, gone])
    #expect(reservations.pending(everBound: [], isLive: { $0 == launched }) == [launched])
    #expect(reservations.pending(everBound: [launched], isLive: { _ in true }).isEmpty)
    #expect(reservations.pending(everBound: [], isLive: { _ in true }).isEmpty, "pruning is permanent")
  }

  // MARK: - cancel

  @Test func cancelEntersTheReducerAndReportsTheEndedRun() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let session = try fixture.waitingSession()
    fixture.sessions = [session]

    let response = fixture.coordinator.cancel(
      WorkflowInput(action: .cancel, runID: session.run.id.uuidString), callerPane: Self.authorCaller)
    #expect(fixture.sent == [.userAction(runID: session.run.id, .cancel)])
    guard case .cancel(let cancelled) = try payload(response) else {
      Issue.record("expected a cancel payload")
      return
    }
    #expect(cancelled.status.state == "cancelled")
    #expect(cancelled.role == "author")

    let again = fixture.coordinator.cancel(
      WorkflowInput(action: .cancel, runID: session.run.id.uuidString), callerPane: nil)
    #expect(again.error?.code == CLIErrorCode.runNotFound)
    #expect(again.error?.message.contains("already ended") == true)
    let unknown = fixture.coordinator.cancel(WorkflowInput(action: .cancel, runID: UUID().uuidString), callerPane: nil)
    #expect(unknown.error?.code == CLIErrorCode.runNotFound)
  }
}
