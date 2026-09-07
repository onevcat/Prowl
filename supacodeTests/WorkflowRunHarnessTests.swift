import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

/// Interprets the machine's effects against the run store, a fake activation bridge, a fake
/// launch boundary, and the native action runner — the executable specification of how B3's
/// wiring must perform each effect (docs-ai 063.007, decision H2).
@MainActor
final class WorkflowRunHarness {
  final class FakeActivationBridge: WorkflowActivationBridge {
    private(set) var opened: [(surfaceID: UUID, dispatchID: String)] = []
    private(set) var cancelled: [String] = []
    private(set) var abandoned: [(dispatchID: String, reason: String)] = []
    private(set) var completed: [(dispatchID: String, summary: String)] = []
    var busyOnce = false
    private var counter = 0

    func openMessageActivation(surfaceID: UUID) -> Result<String, WorkflowActivationOpenFailure> {
      if busyOnce {
        busyOnce = false
        return .failure(.roleBusy)
      }
      return .success(issue(surfaceID: surfaceID))
    }

    func openLaunchActivation(surfaceID: UUID) -> String {
      issue(surfaceID: surfaceID)
    }

    private func issue(surfaceID: UUID) -> String {
      counter += 1
      let id = "dispatch-\(counter)"
      opened.append((surfaceID, id))
      return id
    }

    func cancelActivation(dispatchID: String) { cancelled.append(dispatchID) }
    func abandonActivation(dispatchID: String, reason: String) { abandoned.append((dispatchID, reason)) }
    func completeActivation(dispatchID: String, summary: String) { completed.append((dispatchID, summary)) }
    func observeActivation(dispatchID: String) -> AgentDispatchObservationStream? { nil }
  }

  private(set) var machine: WorkflowRunMachine
  let store: WorkflowRunStore
  let bridge = FakeActivationBridge()
  let actions: any WorkflowActionExecuting
  let skillsDirectory: URL
  let now: Date
  private(set) var typedLines: [(surfaceID: UUID, line: String)] = []
  private(set) var launches: [WorkflowLaunchRequest] = []
  private(set) var watchdogs: [WorkflowWatchdogRequest] = []
  private(set) var disarmed: [Int] = []
  private(set) var notifications: [String] = []
  private(set) var closed: [String] = []
  private(set) var finished: WorkflowRunStatus?
  private var paneCounter = 10

  init(
    machine: WorkflowRunMachine,
    effects: [WorkflowRunEffect],
    store: WorkflowRunStore,
    actions: any WorkflowActionExecuting,
    skillsDirectory: URL,
    now: Date
  ) async throws {
    self.machine = machine
    self.store = store
    self.actions = actions
    self.skillsDirectory = skillsDirectory
    self.now = now
    try store.ensureLayout(runID: machine.run.id)
    try await perform(effects)
  }

  var run: WorkflowRun { machine.run }

  func deliver(token: String, body: String, verdict: String? = nil) async throws -> Result<
    WorkflowDeliveryReceipt, WorkflowDeliveryError
  > {
    let (result, effects) = machine.deliver(ordinal: nil, selector: .token(token), body: body, verdict: verdict)
    try await perform(effects)
    return result
  }

  func user(_ action: WorkflowUserAction) async throws {
    try await perform(machine.apply(.user(action)))
  }

  func watchdog(_ verdict: WorkflowWatchdogVerdict) async throws {
    guard let ordinal = machine.run.currentActivation?.ordinal else { return }
    try await perform(machine.apply(.watchdog(ordinal: ordinal, verdict)))
  }

  private func apply(_ event: WorkflowRunEvent) async throws {
    try await perform(machine.apply(event))
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func perform(_ effects: [WorkflowRunEffect]) async throws {
    let runID = machine.run.id
    for effect in effects {
      switch effect {
      case .awaitRoleIdle(_, _, let ordinal):
        try await apply(.roleIdle(ordinal: ordinal))
      case .cancelRoleWait:
        break
      case .openActivation(_, let surfaceID, let ordinal):
        let dispatchID = bridge.openLaunchActivation(surfaceID: surfaceID)
        try await apply(.injectionSucceeded(ordinal: ordinal, dispatchID: dispatchID))
      case .materializeInstruction(let ordinal, let stepID, let text):
        try store.writeInstruction(runID: runID, stepID: stepID, ordinal: ordinal, text: text)
      case .materializeSkill(let id):
        let skill = BundledSkill(
          id: id, name: id, description: "d", audience: .workflow,
          directoryURL: skillsDirectory.appending(path: id, directoryHint: .isDirectory))
        try store.materializeSkill(runID: runID, skill: skill)
      case .inject(_, let surfaceID, let ordinal, let line, let opensActivation):
        var dispatchID: String?
        if opensActivation {
          switch bridge.openMessageActivation(surfaceID: surfaceID) {
          case .failure(let failure):
            try await apply(.injectionFailed(ordinal: ordinal, failure.injectionFailure))
            continue
          case .success(let id):
            dispatchID = id
          }
        }
        typedLines.append((surfaceID, line))
        try await apply(.injectionSucceeded(ordinal: ordinal, dispatchID: dispatchID))
      case .typeLine(_, let surfaceID, let line):
        typedLines.append((surfaceID, line))
      case .launch(let request):
        launches.append(request)
        paneCounter += 1
        let pane = WorkflowPaneIdentity(
          surfaceID: UUID(), tabID: UUID(), handle: "p\(paneCounter)", displayName: request.profile.name,
          agent: request.profile.agent)
        let dispatchID = request.expectsDelivery ? bridge.openLaunchActivation(surfaceID: pane.surfaceID) : nil
        try await apply(.launched(ordinal: request.ordinal, pane: pane, dispatchID: dispatchID))
      case .runAction(let stepID, let actionID, let inputs):
        let context = WorkflowActionContext(
          runID: runID, rootURL: machine.run.context.worktree.rootURL,
          roleAgents: machine.run.bindings.mapValues { $0.agent.isEmpty ? nil : $0.agent },
          outgoingAgent: machine.run.bindings.values.first { $0.source == .current }?.pane?.agent, now: now)
        do {
          let outputs = try await actions.execute(actionID: actionID, inputs: inputs, context: context)
          try await apply(
            .actionCompleted(stepID: stepID, outputs: outputs, executionID: machine.run.actionExecutionID ?? ""))
        } catch {
          try await apply(
            .actionFailed(stepID: stepID, reason: "\(error)", executionID: machine.run.actionExecutionID ?? ""))
        }
      case .yieldControl:
        try await apply(.continueControlFlow)
      case .notify(let text):
        notifications.append(text)
      case .close(let role, _):
        closed.append(role)
      case .abandonActivation(let dispatchID, let reason):
        bridge.abandonActivation(dispatchID: dispatchID, reason: reason)
      case .completeActivation(let dispatchID, let summary):
        bridge.completeActivation(dispatchID: dispatchID, summary: summary)
      case .armWatchdog(let request):
        watchdogs.append(request)
      case .disarmWatchdog(let ordinal):
        disarmed.append(ordinal)
      case .persistOutput(let name, let ordinal, let body):
        do {
          try store.writeOutput(runID: runID, name: name, ordinal: ordinal, body: body)
        } catch {
          try await apply(.outputPersistFailed(ordinal: ordinal, reason: "\(error)"))
          continue
        }
        try await apply(.outputPersisted(ordinal: ordinal))
      case .persist:
        try store.writeRecord(WorkflowRunRecord(run: machine.run))
      case .log(let line):
        try store.appendLog(runID: runID, line: line, now: now)
      case .finished(let status):
        finished = status
      }
    }
  }
}

@MainActor
struct WorkflowRunHarnessTests {
  nonisolated private static let now = Date(timeIntervalSince1970: 1_760_000_000)

  private struct FakeActions: WorkflowActionExecuting {
    func execute(
      actionID: String, inputs: [String: WorkflowJSONValue], context: WorkflowActionContext
    ) throws -> [String: WorkflowJSONValue] {
      [
        "output": .object([
          "path": .string(context.directory.appending(path: "artifacts/context.md").path),
          "branch": .string("feat/x"), "kickoff_prompt": .string("Take over."),
        ]), "output_path": .string(context.directory.appending(path: "result.json").path),
      ]
    }
  }

  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "workflow-harness-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let skills = url.appending(path: "skills/prowl.adversarial-reviewer", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
    try "---\nname: r\ndescription: d\n---\n# Reviewer\n".write(
      to: skills.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    return url
  }

  private func makeHarness(
    _ yaml: String = WorkflowRunMachineTests.adversarialReview,
    root: URL,
    inputs: [String: String] = [:],
    skipped: Set<String> = [],
    actions: any WorkflowActionExecuting = FakeActions()
  ) async throws -> WorkflowRunHarness {
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
          definition.roles[0].name: .current(WorkflowRunMachineTests.authorPane),
          definition.roles[1].name: .launch(WorkflowRunMachineTests.reviewerProfile, pane: nil),
        ],
        inputs: inputs,
        skippedSteps: skipped),
      now: { Self.now },
      makeToken: { counter.next() })
    return try await WorkflowRunHarness(
      machine: started.machine, effects: started.effects, store: WorkflowRunStore(rootURL: root),
      actions: actions, skillsDirectory: root.appending(path: "skills", directoryHint: .isDirectory), now: Self.now)
  }

  @Test func adversarialReviewRunsEndToEndAgainstFakeBoundaries() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try await makeHarness(root: root, inputs: ["max_rounds": "3", "focus": "the parser"])
    let runDirectory = harness.store.directory(for: harness.run.id)

    // brief: the pointer line was typed with the token after the activation opened.
    #expect(harness.typedLines.count == 1)
    #expect(
      harness.typedLines[0].line.hasPrefix(
        "[Prowl] Read the assigned task with `prowl workflow read --run \(harness.run.id.uuidString) --invocation 1`"))
    #expect(harness.typedLines[0].line.contains("PROWL_WORKFLOW_TOKEN=TOKEN-1 prowl workflow deliver -"))
    #expect(harness.bridge.opened.map(\.dispatchID) == ["dispatch-1"])
    #expect(harness.run.phase == .waitingForDelivery(ordinal: 1))
    let instruction = try String(contentsOf: runDirectory.appending(path: "instructions/brief.1.md"), encoding: .utf8)
    #expect(
      instruction.hasPrefix(
        "Write a short brief for an adversarial reviewer: ## Scope, ## Claims.\nFocus: the parser\n\n---\n"))
    #expect(instruction.contains("PROWL_WORKFLOW_TOKEN=TOKEN-1 prowl workflow deliver -"))

    _ = try await harness.deliver(token: "TOKEN-1", body: "# Brief\n## Scope\nx\n## Claims\ny")
    #expect(harness.bridge.completed.map(\.dispatchID) == ["dispatch-1"])
    #expect(harness.disarmed == [1])
    #expect(harness.launches.count == 1)
    #expect(
      harness.launches[0].prompt.hasPrefix(
        "Read workflow-resource:resource-1 and review (strict)."))
    #expect(harness.launches[0].environment["PROWL_WORKFLOW_TOKEN"] == "TOKEN-2")
    #expect(
      FileManager.default.fileExists(
        atPath: runDirectory.appending(path: "skills/prowl.adversarial-reviewer/SKILL.md").path(percentEncoded: false)))
    #expect(harness.run.bindings["reviewer"]?.pane?.handle == "p11")
    #expect(harness.run.phase == .waitingForDelivery(ordinal: 2))

    _ = try await harness.deliver(token: "TOKEN-2", body: "## Findings\n- a\n## Verdict\nissues", verdict: "issues")
    #expect(harness.typedLines.count == 2)
    #expect(
      harness.typedLines[1].line
        == "[Prowl] Findings: workflow-resource:resource-1. Fix or rebut each item. "
        + (harness.run.currentInvocation?.content?.guidance ?? "")
        + " — finish with: PROWL_WORKFLOW_TOKEN=TOKEN-3 prowl workflow deliver -")
    _ = try await harness.deliver(token: "TOKEN-3", body: "# Done")
    #expect(harness.typedLines[2].surfaceID == harness.run.bindings["reviewer"]?.pane?.surfaceID)
    _ = try await harness.deliver(token: "TOKEN-4", body: "# Findings\nnone", verdict: "clean")

    #expect(harness.finished == .completed)
    #expect(harness.notifications == ["Adversarial review: clean after 1 round(s)"])
    #expect(harness.closed == ["reviewer"])
    #expect(harness.bridge.opened.map(\.dispatchID) == ["dispatch-1", "dispatch-2", "dispatch-3", "dispatch-4"])
    #expect(harness.bridge.completed.map(\.dispatchID) == ["dispatch-1", "dispatch-2", "dispatch-3", "dispatch-4"])
    #expect(harness.bridge.abandoned.isEmpty)
    #expect(harness.watchdogs.map(\.ordinal) == [1, 2, 3, 4])

    let deliveries = try FileManager.default.contentsOfDirectory(
      atPath: runDirectory.appending(path: "deliveries").path(percentEncoded: false)
    ).sorted()
    #expect(
      deliveries == [
        "brief.1.md", "brief.md", "disposition.3.md", "disposition.md", "findings.2.md", "findings.md",
        "round_findings.4.md", "round_findings.md",
      ])
    #expect(
      try String(contentsOf: runDirectory.appending(path: "deliveries/round_findings.md"), encoding: .utf8)
        == "# Findings\nnone\n")
    let record = try harness.store.readRecord(runID: harness.run.id)
    #expect(record.run.status.state == "completed")
    #expect(record.invocations.map(\.ordinal) == [1, 2, 3, 4])
    #expect(
      record.invocations.compactMap(\.activation?.dispatchID) == [
        "dispatch-1", "dispatch-2", "dispatch-3", "dispatch-4",
      ])
    #expect(record.state?["rounds"] == .integer(1))
    let log = try String(contentsOf: runDirectory.appending(path: "log.md"), encoding: .utf8)
    #expect(log.contains("Run finished: completed."))
    #expect(!log.contains("TOKEN-1"))
    #expect(!log.contains("TOKEN-2"))
    #expect(!log.contains("TOKEN-3"))
    #expect(!log.contains("TOKEN-4"))
    #expect(!FileManager.default.fileExists(atPath: harness.store.rootURL.appending(path: ".prowl/workflow-runs").path))
  }

  @Test func aFailingStoreLeavesTheDeliveryInAttentionUntilRetried() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try await makeHarness(root: root)
    let deliveries = harness.store.directory(for: harness.run.id).appending(
      path: "deliveries", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: deliveries)
    let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: deliveries, withDestinationURL: elsewhere)
    let result = try await harness.deliver(token: "TOKEN-1", body: "## Scope\nx\n## Claims\ny")
    #expect((try? result.get()) != nil)
    #expect(harness.run.status.attention?.reason.code == "persist_failed")
    #expect(harness.bridge.completed.isEmpty)
    #expect(harness.launches.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path(percentEncoded: false)).isEmpty)
    try FileManager.default.removeItem(at: deliveries)
    try FileManager.default.createDirectory(at: deliveries, withIntermediateDirectories: true)
    try await harness.user(.retry)
    #expect(harness.bridge.completed.map(\.dispatchID) == ["dispatch-1"])
    #expect(harness.launches.count == 1)
    #expect(try harness.store.readRecord(runID: harness.run.id).deliveries["brief"]?.ordinal == 1)
  }

  @Test func aProvisionalDeliveryIsKeptOnDiskUntilTheUserAcceptsIt() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try await makeHarness(root: root)
    let result = try await harness.deliver(token: "TOKEN-1", body: "## Scope\nonly")
    #expect(try result.get().issues == [.missingSections(["## Claims"])])
    #expect(harness.run.status.attention?.reason.code == "delivery_issues")
    #expect(harness.bridge.completed.isEmpty)
    #expect(harness.launches.isEmpty)
    let brief = harness.store.directory(for: harness.run.id).appending(path: "deliveries/brief.md")
    #expect(try String(contentsOf: brief, encoding: .utf8) == "## Scope\nonly\n")
    #expect(try harness.store.readRecord(runID: harness.run.id).run.status.attention?.issues == ["missing_sections"])
    try await harness.user(.acceptDelivery(verdict: nil))
    #expect(harness.bridge.completed.map(\.dispatchID) == ["dispatch-1"])
    #expect(harness.launches.count == 1)
    #expect(try harness.store.readRecord(runID: harness.run.id).deliveries["brief"]?.ordinal == 1)
  }

  @Test func cancelAbandonsThePendingActivationAndKeepsDeliveredOutputs() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try await makeHarness(root: root)
    _ = try await harness.deliver(token: "TOKEN-1", body: "## Scope\nx\n## Claims\ny")
    try await harness.user(.cancel)
    #expect(harness.finished == .cancelled)
    #expect(harness.bridge.abandoned.map(\.dispatchID) == ["dispatch-2"])
    #expect(
      harness.bridge.abandoned[0].reason == "Workflow run \(harness.run.id.uuidString) cancelled at step 'launch'.")
    #expect(try harness.store.readRecord(runID: harness.run.id).run.status.state == "cancelled")
    #expect(
      FileManager.default.fileExists(
        atPath: harness.store.directory(for: harness.run.id).appending(path: "deliveries/brief.md").path(
          percentEncoded: false)))
    #expect(harness.closed.isEmpty)
  }

  @Test func aBusyRoleIsWaitedForAgainBeforeAnythingIsTyped() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try await makeHarness(root: root)
    _ = try await harness.deliver(token: "TOKEN-1", body: "## Scope\nx\n## Claims\ny")
    harness.bridge.busyOnce = true
    _ = try await harness.deliver(token: "TOKEN-2", body: "## Findings\n## Verdict", verdict: "issues")
    #expect(harness.run.phase == .waitingForDelivery(ordinal: 3))
    #expect(harness.typedLines.count == 2)
    #expect(harness.run.invocations.count == 3)
    #expect(harness.bridge.opened.map(\.dispatchID) == ["dispatch-1", "dispatch-2", "dispatch-3"])
    #expect(harness.run.invocations[2].activation?.token == "TOKEN-3")
    let delivered = try await harness.deliver(token: "TOKEN-3", body: "# Done")
    #expect(try delivered.get().ordinal == 3)
    #expect(harness.run.phase == .waitingForDelivery(ordinal: 4))
  }

  @Test func nudgeAndAttentionFlowThroughTheWatchdogVerdicts() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try await makeHarness(root: root)
    try await harness.watchdog(.nudge)
    #expect(
      harness.typedLines.last?.line.hasPrefix(
        "[Prowl] When your work for this step is fully complete, finish with: PROWL_WORKFLOW_TOKEN=TOKEN-1") == true)
    try await harness.watchdog(.attention(.idleWithoutDelivery))
    #expect(try harness.store.readRecord(runID: harness.run.id).run.status.state == "needs_attention")
    try await harness.user(.keepWaiting)
    #expect(harness.watchdogs.last?.nudgedAlready == true)
    _ = try await harness.deliver(token: "TOKEN-1", body: "## Scope\nx\n## Claims\ny")
    #expect(harness.run.status == .running)
  }

  @Test func handoffWithSkippedBriefRunsTheContextOnlyTransition() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try await makeHarness(
      WorkflowRunMachineTests.handoff, root: root, skipped: ["brief"])
    #expect(harness.finished == .completed)
    #expect(harness.typedLines.isEmpty)
    #expect(harness.launches.count == 1)
    #expect(try #require(harness.launches.first).prompt.hasPrefix("Take over.\n"))
    #expect(!harness.launches[0].expectsDelivery)
    #expect(harness.notifications == ["Handed off to Pi Reviewer"])
    let record = try harness.store.readRecord(runID: harness.run.id)
    #expect(record.skippedOutputs == ["brief": "brief"])
    #expect(record.actions["transition"]?["output"] != nil)
  }
}
