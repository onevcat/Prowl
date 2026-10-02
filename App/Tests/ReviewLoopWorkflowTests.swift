import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct ReviewLoopWorkflowTests {
  private struct BundleActions: WorkflowActionExecuting {
    let bundle: WorkflowPreparedBundle

    func execute(
      actionID: String, inputs: [String: WorkflowJSONValue], context: WorkflowActionContext
    ) async throws -> [String: WorkflowJSONValue] {
      try await WorkflowNativeActionRunner().execute(
        actionID: actionID, inputs: inputs,
        context: .init(
          runID: context.runID, rootURL: context.rootURL, roleAgents: [:], outgoingAgent: nil,
          now: context.now, bundle: bundle))
    }
  }

  private func harness(root: URL, inputs: [String: String] = [:]) async throws -> WorkflowRunHarness {
    let repository = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = WorkflowDiscovery.load(
      url: repository.appending(path: "Resources/workflows/review-loop.pwlworkflow"),
      scope: .bundle, context: .init(scope: .bundle))
    #expect(source.isValid, "\(source.diagnostics)")
    let definition = try #require(source.definition)
    let bundle = try WorkflowPreparedBundle(
      source: source, directory: root.appending(path: "bundle"), environment: [:])
    let started = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .bundle, definitionPath: nil,
          worktree: .init(id: "test", name: "test", branch: "feature", path: root.path)),
        bindings: [
          "main": .current(WorkflowRunMachineTests.authorPane),
          "reviewer": .launch(WorkflowRunMachineTests.reviewerProfile, pane: nil),
        ], inputs: inputs, selfInitiated: true), now: { Date(timeIntervalSince1970: 1) })
    #expect(started.machine.run.selfInitiatedLine != nil)
    return try await WorkflowRunHarness(
      machine: started.machine, effects: started.effects, store: WorkflowRunStore(rootURL: root),
      actions: BundleActions(bundle: bundle), skillsDirectory: root,
      now: Date(timeIntervalSince1970: 1))
  }

  private func deliver(_ harness: WorkflowRunHarness, verdict: String? = nil) async throws {
    let activation = try #require(harness.run.currentActivation)
    let body = """
      ## Scope
      Current changes.
      ## Plan
      Preserve behavior.
      ## Verification
      Tests passed.
      ## Findings
      See verdict.
      ## Disposition
      Verified each finding.
      ## Review State
      No additional changes.
      ## Summary
      See review state.
      ## Remaining Work
      None.
      """
    let receipt = try await harness.deliver(token: activation.token, body: body, verdict: verdict)
    guard case .success(let value) = receipt else {
      Issue.record("Delivery rejected: \(receipt)")
      return
    }
    #expect(value.issues.isEmpty)
  }

  @Test(arguments: [2, 3])
  func cleanReviewHonorsMinimumAndReusesReviewer(minimum: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let run = try await harness(root: root, inputs: ["min_rounds": "\(minimum)"])
    try await deliver(run)
    for round in 1...minimum {
      #expect(run.run.currentInvocation?.role == "reviewer")
      try await deliver(run, verdict: "clean")
      #expect(run.run.currentInvocation?.role == "main")
      try await deliver(run, verdict: "unchanged")
      if round < minimum { #expect(run.finished == nil) }
    }
    #expect(run.run.currentStep?.id == "summary")
    try await deliver(run)
    #expect(run.finished == .completed)
    #expect(run.launches.count == 1)
    #expect(run.launches.first?.placement == .split)
    #expect(run.launches.first?.direction == .right)
    #expect(run.closed.isEmpty)
    #expect(run.notifications.last?.contains("clean") == true)
  }

  @Test(arguments: ["changed", "unchanged"])
  func maximumStillAssessesLastFindingsAndDoesNotClaimClean(disposition: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let run = try await harness(root: root)
    try await deliver(run)
    for _ in 1...4 {
      try await deliver(run, verdict: "issues")
      #expect(run.run.currentInvocation?.role == "main")
      try await deliver(run, verdict: disposition)
    }
    #expect(run.run.currentStep?.id == "summary")
    try await deliver(run)
    #expect(run.finished == .completed)
    #expect(run.notifications.last?.contains("not clean") == true)
    #expect(run.launches.count == 1)
  }

  @Test(arguments: ["changed", "follow-up"])
  func changesAfterCleanRequireAnotherReview(disposition: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let run = try await harness(root: root, inputs: ["min_rounds": "1", "max_rounds": "2"])
    try await deliver(run)
    try await deliver(run, verdict: "clean")
    try await deliver(run, verdict: disposition)
    #expect(run.run.currentInvocation?.role == "reviewer")
    try await deliver(run, verdict: "clean")
    try await deliver(run, verdict: "unchanged")
    try await deliver(run)
    #expect(run.finished == .completed)
  }

  @Test func invalidRangeStopsBeforeReviewerLaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let run = try await harness(root: root, inputs: ["min_rounds": "3", "max_rounds": "2"])
    try await deliver(run)
    #expect(run.run.status.attention != nil)
    #expect(run.launches.isEmpty)
    #expect(run.finished == nil)
  }

  @Test(arguments: [true, false])
  func conditionActionEnforcesItsBoolean(condition: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = WorkflowActionContext(
      runID: UUID(), rootURL: root, roleAgents: [:], outgoingAgent: nil, now: Date())
    do {
      _ = try await WorkflowNativeActionRunner().execute(
        actionID: "builtin:assert-condition",
        inputs: ["condition": .boolean(condition), "message": .string("Invalid round range.")],
        context: context)
      #expect(condition)
    } catch {
      #expect(!condition)
      #expect(error as? WorkflowActionError == .failed("Invalid round range."))
    }
  }

  @Test func reviewerMustSupplyAValidVerdictAndRequiredSections() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let run = try await harness(root: root)
    try await deliver(run)
    let activation = try #require(run.run.currentActivation)
    for verdict in [nil, "approved", "clean"] {
      let result = try await run.deliver(
        token: activation.token, body: "Incomplete report", verdict: verdict)
      guard case .failure = result else {
        Issue.record("Invalid report was accepted")
        continue
      }
      #expect(run.run.currentActivation?.token == activation.token)
    }
  }

  @Test func conditionActionRejectsStringBooleans() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = WorkflowActionContext(
      runID: UUID(), rootURL: root, roleAgents: [:], outgoingAgent: nil, now: Date())
    await #expect(throws: WorkflowActionError.self) {
      _ = try await WorkflowNativeActionRunner().execute(
        actionID: "builtin:assert-condition",
        inputs: ["condition": .string("true"), "message": .string("Stop")],
        context: context)
    }
  }
}
