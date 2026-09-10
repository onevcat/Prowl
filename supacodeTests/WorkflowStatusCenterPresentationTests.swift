import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowStatusCenterPresentationTests {
  nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func selectsActiveRunsForTheWorktreeAndOrdersMostRecentlyStartedFirst() throws {
    let older = try makeSession(
      id: UUID(1),
      worktreeID: "selected",
      startedAt: Self.now.addingTimeInterval(-120),
      updatedAt: Self.now
    )
    var attention = try makeSession(
      id: UUID(2),
      worktreeID: "selected",
      startedAt: Self.now.addingTimeInterval(-70),
      updatedAt: Self.now.addingTimeInterval(-10)
    )
    attention.run.status = .needsAttention(
      WorkflowAttention(
        reason: .blocked,
        stepID: "brief",
        role: "author",
        ordinal: attention.run.currentInvocation?.ordinal,
        actions: [.focusPane, .cancel],
        message: "author is blocked"
      ))
    let otherWorktree = try makeSession(id: UUID(3), worktreeID: "other", updatedAt: Self.now)
    var completed = try makeSession(id: UUID(4), worktreeID: "selected", updatedAt: Self.now)
    completed.run.status = .completed

    var state = WorkflowRunsFeature.State()
    state.sessions = [
      older.run.id: older,
      attention.run.id: attention,
      otherWorktree.run.id: otherWorktree,
      completed.run.id: completed,
    ]

    let presentation = WorkflowStatusCenterPresentation(
      state: state,
      selectedWorktreeID: "selected",
      now: Self.now
    )

    #expect(presentation.runs.map(\.id) == [attention.run.id, older.run.id])
    #expect(presentation.primary?.id == attention.run.id)
    #expect(presentation.activeRunCount == 2)
    #expect(presentation.primary?.status == .needsAttention("author is blocked"))
    #expect(presentation.primary?.currentStepTitle == "Write the brief")
    #expect(presentation.primary?.elapsedText == "1m")
  }

  @Test func runOrderingUsesUpdateAndIdentityOnlyAsStableTieBreakers() throws {
    let lowerID = try makeSession(
      id: UUID(10),
      worktreeID: "selected",
      startedAt: Self.now.addingTimeInterval(-60),
      updatedAt: Self.now.addingTimeInterval(-20)
    )
    let newerUpdate = try makeSession(
      id: UUID(11),
      worktreeID: "selected",
      startedAt: lowerID.run.startedAt,
      updatedAt: Self.now.addingTimeInterval(-10)
    )
    let higherID = try makeSession(
      id: UUID(12),
      worktreeID: "selected",
      startedAt: lowerID.run.startedAt,
      updatedAt: lowerID.run.updatedAt
    )
    var state = WorkflowRunsFeature.State()
    state.sessions = [
      lowerID.run.id: lowerID,
      newerUpdate.run.id: newerUpdate,
      higherID.run.id: higherID,
    ]

    let presentation = WorkflowStatusCenterPresentation(
      state: state,
      selectedWorktreeID: "selected",
      now: Self.now
    )

    #expect(presentation.runs.map(\.id) == [newerUpdate.run.id, higherID.run.id, lowerID.run.id])
  }

  @Test func anyRunNeedingAttentionIsVisibleWithoutChangingThePrimaryRun() throws {
    var olderAttention = try makeSession(
      id: UUID(14),
      worktreeID: "selected",
      startedAt: Self.now.addingTimeInterval(-120),
      updatedAt: Self.now
    )
    olderAttention.run.status = .needsAttention(
      WorkflowAttention(
        reason: .blocked,
        stepID: "brief",
        role: "author",
        ordinal: olderAttention.run.currentInvocation?.ordinal,
        actions: [.focusPane, .keepWaiting, .cancel],
        message: "The older run needs attention."
      ))
    let newerRunning = try makeSession(
      id: UUID(15),
      worktreeID: "selected",
      startedAt: Self.now.addingTimeInterval(-30),
      updatedAt: Self.now
    )
    var state = WorkflowRunsFeature.State()
    state.sessions = [
      olderAttention.run.id: olderAttention,
      newerRunning.run.id: newerRunning,
    ]

    let presentation = WorkflowStatusCenterPresentation(
      state: state,
      selectedWorktreeID: "selected",
      now: Self.now
    )

    #expect(presentation.primary?.id == newerRunning.run.id)
    #expect(presentation.attentionRun?.id == olderAttention.run.id)
    #expect(presentation.hasAttention)
  }

  @Test func attentionControlsExhaustivelyMapEveryMachineAction() throws {
    var session = try makeSession(id: UUID(5), worktreeID: "selected", updatedAt: Self.now)
    let ordinal = try #require(session.run.currentInvocation?.ordinal)
    let expectation = WorkflowExpectation(delivery: "brief", verdicts: ["clean", "issues"])
    session.run.invocations[0].activation = WorkflowActivation(
      ordinal: ordinal,
      stepID: "brief",
      role: "author",
      token: "token",
      expect: expectation,
      deliveryName: "brief",
      dispatchID: "dispatch",
      state: .provisional,
      pendingDelivery: WorkflowValidatedDelivery(
        body: "body",
        verdict: nil,
        issues: [.verdictMissing(allowed: ["clean", "issues"])]
      )
    )
    session.run.phase = .waitingForDelivery(ordinal: ordinal)
    session.run.status = .needsAttention(
      WorkflowAttention(
        reason: .deliveryIssues([.verdictMissing(allowed: ["clean", "issues"])]),
        stepID: "brief",
        role: "author",
        ordinal: ordinal,
        actions: WorkflowAttentionAction.allCases,
        message: "Choose how to continue."
      ))

    session.run.stepValues = session.run.expressionValues(capturedAt: Self.now)
    let run = WorkflowRunPresentation(run: session.run, now: Self.now)

    #expect(run.attentionControls.map(\.action) == WorkflowAttentionAction.allCases)
    #expect(run.attentionControls.first { $0.action == .acceptWithVerdict }?.verdicts == ["clean", "issues"])
    for control in run.attentionControls {
      if control.action == .acceptWithVerdict {
        #expect(control.intent(runID: run.id, worktreeID: run.worktreeID, verdict: "clean") != nil)
      } else {
        #expect(control.intent(runID: run.id, worktreeID: run.worktreeID) != nil)
      }
    }

    #expect(
      run.attentionControls.first { $0.action == .focusPane }?.intent(
        runID: run.id,
        worktreeID: run.worktreeID
      ) == .focusPane(worktreeID: "selected", surfaceID: Self.authorPane.surfaceID)
    )
    #expect(
      run.attentionControls.first { $0.action == .acceptWithVerdict }?.intent(
        runID: run.id,
        worktreeID: run.worktreeID,
        verdict: "issues"
      ) == .userAction(runID: run.id, action: .acceptDelivery(verdict: "issues"))
    )
  }

  @Test func stepListPreservesDocumentOrderAndGroupsLoopIterations() throws {
    var session = try makeSession(id: UUID(6), worktreeID: "selected", updatedAt: Self.now)
    var cursor = try #require(session.run.controlCursor)
    for _ in 0..<3 {
      cursor.complete()
      _ = try cursor.next(values: session.run.expressionValues(capturedAt: Self.now))
    }
    session.run.controlCursor = cursor
    session.run.stepRecords = [
      WorkflowStepRecord(stepID: "brief", iteration: nil, state: .completed, ordinal: 1),
      WorkflowStepRecord(stepID: "fix", iteration: 1, state: .completed, ordinal: 2),
      WorkflowStepRecord(stepID: "rereview", iteration: 1, state: .completed, ordinal: 3),
      WorkflowStepRecord(stepID: "fix", iteration: 2, state: .active, ordinal: 4),
    ]
    let briefPath = "/tmp/selected/.prowl/workflow-runs/\(session.run.id.uuidString)/deliveries/brief.md"
    session.run.deliveries["brief"] = WorkflowDeliveryRecord(
      name: "brief",
      ordinal: 1,
      path: briefPath,
      latestPath: briefPath,
      verdict: nil,
      deliveredAt: Self.now
    )
    session.run.invocations = [
      WorkflowInvocation(
        ordinal: 4,
        stepID: "fix",
        iteration: 2,
        role: "author",
        kind: .message,
        startedAt: Self.now,
        promptPath: nil,
        activation: nil,
        endedAt: nil
      )
    ]
    session.run.phase = .waitingForRole(role: "author", ordinal: 4)

    session.run.stepValues = session.run.expressionValues(capturedAt: Self.now)
    let run = WorkflowRunPresentation(run: session.run, now: Self.now)
    let expectedInstruction =
      "Read /tmp/selected/.prowl/workflow-runs/\(run.id.uuidString)/deliveries/brief.md "
      + "and address the findings in round 2."

    #expect(run.currentStepTitle == "Round 2: address findings")
    #expect(run.currentPrompt == expectedInstruction)
    #expect(run.stepItems.count == 4)
    guard case .step(let brief) = run.stepItems[0] else {
      Issue.record("Expected the top-level brief step first")
      return
    }
    #expect(brief.stepID == "brief")
    #expect(brief.state == .completed)
    guard case .round(let firstRound) = run.stepItems[1] else {
      Issue.record("Expected round 1 after the brief")
      return
    }
    #expect(firstRound.index == 1)
    #expect(firstRound.maximum == 3)
    #expect(firstRound.steps.map(\.stepID) == ["fix", "rereview"])
    guard case .round(let secondRound) = run.stepItems[2] else {
      Issue.record("Expected round 2 after round 1")
      return
    }
    #expect(secondRound.steps.map(\.stepID) == ["fix", "rereview"])
    #expect(secondRound.steps.map(\.state) == [.active, .pending])
    guard case .step(let finish) = run.stepItems[3] else {
      Issue.record("Expected the final top-level step last")
      return
    }
    #expect(finish.stepID == "finish")
    #expect(finish.state == .pending)
  }

  @Test func rolesAndElapsedTimeStayHonestAtPresentationEdges() throws {
    var session = try makeSession(
      id: UUID(13),
      worktreeID: "selected",
      startedAt: Self.now.addingTimeInterval(-90_061),
      updatedAt: Self.now,
      yaml: Self.twoRoleWorkflow,
      bindings: [
        "author": .current(Self.authorPane),
        "reviewer": .launch(Self.reviewerProfile, pane: nil),
      ]
    )
    session.run.controlCursor = nil

    session.run.stepValues = session.run.expressionValues(capturedAt: Self.now)
    let run = WorkflowRunPresentation(run: session.run, now: Self.now)

    #expect(run.roles.map(\.displayName) == ["Author", "Pi Reviewer"])
    #expect(run.roles.map(\.surfaceID) == [Self.authorPane.surfaceID, nil])
    #expect(run.currentStepTitle == "Finishing workflow")
    #expect(run.currentPrompt == nil)
    #expect(run.elapsedText == "1d 1h")
    #expect(run.elapsedText(at: session.run.startedAt.addingTimeInterval(-1)) == "0s")
  }

  @Test func skipControlExplainsWhetherTheRunContinuesOrEnds() throws {
    var ending = try makeSession(id: UUID(7), worktreeID: "selected", updatedAt: Self.now)
    let ordinal = try #require(ending.run.currentInvocation?.ordinal)
    ending.run.status = .needsAttention(
      WorkflowAttention(
        reason: .idleWithoutDelivery,
        stepID: "brief",
        role: "author",
        ordinal: ordinal,
        actions: [.skip, .cancel],
        message: "No delivery."
      ))

    let endingRun = WorkflowRunPresentation(run: ending.run, now: Self.now)
    let endingSkip = try #require(endingRun.attentionControls.first { $0.action == .skip })
    #expect(endingSkip.confirmationMessage?.contains("ends the run") == true)
    #expect(endingSkip.confirmationMessage?.contains("fix") == true)

    var continuing = try makeSession(
      id: UUID(8),
      worktreeID: "selected",
      updatedAt: Self.now,
      yaml: Self.independentOutputWorkflow
    )
    let continuingOrdinal = try #require(continuing.run.currentInvocation?.ordinal)
    continuing.run.status = .needsAttention(
      WorkflowAttention(
        reason: .idleWithoutDelivery,
        stepID: "note",
        role: "author",
        ordinal: continuingOrdinal,
        actions: [.skip, .cancel],
        message: "No delivery."
      ))
    let continuingRun = WorkflowRunPresentation(run: continuing.run, now: Self.now)
    let continuingSkip = try #require(continuingRun.attentionControls.first { $0.action == .skip })
    #expect(continuingSkip.confirmationMessage?.contains("continues") == true)
  }

  @Test func toolbarSelectionKeepsToastAboveWorkflowAndWorkflowAboveFallbacks() throws {
    let session = try makeSession(id: UUID(9), worktreeID: "selected", updatedAt: Self.now)
    var state = WorkflowRunsFeature.State()
    state.sessions[session.run.id] = session
    let workflow = WorkflowStatusCenterPresentation(
      state: state,
      selectedWorktreeID: "selected",
      now: Self.now
    )

    #expect(
      ToolbarStatusSelection(
        toast: .success("Saved"),
        workflow: workflow,
        pullRequest: nil
      ) == .toast(.success("Saved"))
    )
    #expect(
      ToolbarStatusSelection(
        toast: nil,
        workflow: workflow,
        pullRequest: nil
      ) == .workflow(workflow)
    )
    #expect(
      ToolbarStatusSelection(
        toast: nil,
        workflow: WorkflowStatusCenterPresentation(
          state: WorkflowRunsFeature.State(),
          selectedWorktreeID: "selected",
          now: Self.now
        ),
        pullRequest: nil
      ) == .motivational
    )
  }

  nonisolated private static let authorPane = WorkflowPaneIdentity(
    surfaceID: UUID(101),
    tabID: UUID(102),
    handle: "p1",
    displayName: "Author",
    agent: "codex"
  )

  nonisolated private static let reviewerProfile = WorkflowProfileBinding(
    id: UUID(100),
    name: "Pi Reviewer",
    agent: "pi"
  )

  nonisolated private static let workflow = """
    schema: prowl.workflow/v1
    id: test.status-center
    name: Status Center Test
    roles:
      author:
        source: current
    steps:
      - id: brief
        title: "Write the brief"
        message: author
        prompt: "Write a brief."
        expect: { delivery: brief }
      - id: rounds
        while: 'true'
        max_iterations: 3
        steps:
          - id: fix
            title: "Round {{ context.step.iteration }}: address findings"
            message: author
            prompt: >-
              Read {{ deliveries.brief.path }} and address the findings in round {{ context.step.iteration }}.
            expect: { delivery: disposition }
          - id: rereview
            title: "Round {{ context.step.iteration }}: re-review"
            message: author
            prompt: "Review again."
            expect: { delivery: findings, verdicts: [clean, issues] }
      - id: finish
        notify: "Done"
    """

  nonisolated private static let independentOutputWorkflow = """
    schema: prowl.workflow/v1
    id: test.independent-output
    name: Independent Output
    roles:
      author:
        source: current
    steps:
      - id: note
        message: author
        prompt: "Write an optional note."
        expect: { delivery: note }
      - id: finish
        notify: "Done"
    """

  nonisolated private static let twoRoleWorkflow = """
    schema: prowl.workflow/v1
    id: test.two-role
    name: Two Role Test
    roles:
      author:
        source: current
      reviewer:
        source: launch
        agents: [claude]
    steps:
      - id: brief
        message: author
        prompt: "Write a brief."
    """

  private func makeSession(
    id: UUID,
    worktreeID: String,
    startedAt: Date = Self.now.addingTimeInterval(-70),
    updatedAt: Date,
    yaml: String = Self.workflow,
    bindings: [String: WorkflowRoleBinding]? = nil
  ) throws -> WorkflowRunSession {
    let definition = try #require(WorkflowDocumentParser.parse(yaml).definition)
    let started = try WorkflowRunMachine.start(
      WorkflowRunStartRequest(
        definition: definition,
        runID: id,
        context: WorkflowRunContext(
          scope: .user,
          definitionPath: nil,
          worktree: WorkflowRunWorktree(
            id: worktreeID,
            name: worktreeID,
            branch: "feat/status",
            path: "/tmp/\(worktreeID)"
          )
        ),
        bindings: bindings ?? ["author": .current(Self.authorPane)],
        selfInitiated: false
      ),
      now: { startedAt },
      makeToken: { "token" }
    )
    var run = started.machine.run
    run.updatedAt = updatedAt
    let worktree = Worktree(
      id: worktreeID,
      name: worktreeID,
      detail: "",
      workingDirectory: URL(filePath: "/tmp/\(worktreeID)", directoryHint: .isDirectory),
      repositoryRootURL: URL(filePath: "/tmp/\(worktreeID)", directoryHint: .isDirectory)
    )
    return WorkflowRunSession(run: run, worktree: worktree, launchPlans: [:])
  }
}

extension UUID {
  fileprivate nonisolated init(_ value: UInt8) {
    self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}
