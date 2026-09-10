import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowHistoryReviewTests {
  private func start(_ body: String, roles: [String: WorkflowRoleBinding] = [:]) throws -> WorkflowRunMachine {
    let definition = try #require(WorkflowDocumentParser.parse(body).definition)
    return try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "wt", name: "test", branch: "main", path: "/tmp/history-review-tests")), bindings: roles),
      now: { Date(timeIntervalSince1970: 100) }
    ).machine
  }

  @Test func sessionIdentityUsesCurrentExactHookEvidence() {
    let signal = AgentSignal(
      kind: .sessionStart, source: .hook(runtime: .pi, event: "session-start"),
      confidence: .exact, timestamp: .distantPast, sessionID: "pi-session", detail: nil, claimedOrigin: nil)
    #expect(WorkflowHistorySessionIdentity.resolve(agent: .pi, detected: nil, currentSignal: signal) == "pi:pi-session")
    let stale = AgentSession(id: "old-session", transcriptPath: nil, source: .recentFile, confidence: .medium)
    #expect(
      WorkflowHistorySessionIdentity.resolve(agent: .pi, detected: stale, currentSignal: signal) == "pi:pi-session")
    #expect(WorkflowHistorySessionIdentity.resolve(agent: .codex, detected: nil, currentSignal: signal) == nil)
    #expect(WorkflowHistorySessionIdentity.resolve(agent: .pi, detected: stale, currentSignal: nil) == nil)
    let exact = AgentSession(id: "known", transcriptPath: nil, source: .commandLine, confidence: .exact)
    #expect(WorkflowHistorySessionIdentity.resolve(agent: .codex, detected: exact, currentSignal: nil) == "codex:known")
    let claimed = AgentSignal(
      kind: .sessionStart, source: .cooperativeCLI, confidence: .exact,
      timestamp: .distantPast, sessionID: "claimed", detail: nil, claimedOrigin: "hook_pi")
    #expect(WorkflowHistorySessionIdentity.resolve(agent: .pi, detected: nil, currentSignal: claimed) == nil)
    let ended = AgentSignal(
      kind: .sessionEnd, source: .hook(runtime: .pi, event: "session-end"),
      confidence: .exact, timestamp: .distantPast, sessionID: "ended", detail: nil, claimedOrigin: nil)
    #expect(WorkflowHistorySessionIdentity.resolve(agent: .pi, detected: exact, currentSignal: ended) == nil)
  }

  @Test func controlErrorsKeepCompletedWorkAndErrorAfterCancellation() throws {
    var machine = try start(
      """
      schema: prowl.workflow/v1
      id: error
      name: Error
      steps:
        - id: good
          set: {}
        - id: broken
          if: context.roles.missing.observed.exists
          then: [{id: unreachable, notify: Never}]
      """)
    #expect(machine.run.status.attention?.stepID == "broken")
    _ = machine.apply(.user(.cancel))
    let encoded = try WorkflowRunRecord.makeEncoder().encode(WorkflowRunRecord(run: machine.run))
    let record = try WorkflowRunRecord.makeDecoder().decode(WorkflowRunRecord.self, from: encoded)
    #expect(record.steps.first { $0.id == "good" }?.state == .completed)
    #expect(record.steps.first { $0.id == "broken" }?.error?.contains("missing") == true)
  }

  @Test func controlLimitRetainsExecutedRounds() throws {
    let machine = try start(
      """
      schema: prowl.workflow/v1
      id: limit
      name: Limit
      steps:
        - id: rounds
          while: 'true'
          max_iterations: 2
          steps: [{id: tick, set: {}}]
      """)
    let steps = WorkflowRunRecord(run: machine.run).steps
    #expect(machine.run.status == .iterationLimitReached)
    #expect(steps.filter { $0.id == "tick" && $0.state == .completed }.count == 2)
  }

  @Test func breakUsesItsPositionBeforePoppingTheLoop() throws {
    let machine = try start(
      """
      schema: prowl.workflow/v1
      id: nested
      name: Nested
      state: {count: {type: integer, initial: 0}}
      steps:
        - id: outer
          while: state.count < 2
          steps:
            - id: inner
              while: 'true'
              steps:
                - id: work
                  notify: Work
                - id: stop
                  break: true
            - id: increment
              set: {count: state.count + 1}
      """)
    let steps = WorkflowRunRecord(run: machine.run).steps
    #expect(
      steps.filter { $0.id == "stop" }.map(\.iterationPath) == [["outer:1", "inner:1"], ["outer:2", "inner:1"]])
    #expect(steps.filter { $0.id == "inner" }.map(\.iterationPath) == [["outer:1"], ["outer:2"]])
    let work = WorkflowHistoryStepGroup.groups(WorkflowRunRecord(run: machine.run)).filter { $0.id.hasPrefix("work:") }
    #expect(Set(work.map(\.subtitle)).count == 2)
    #expect(work.allSatisfy { $0.subtitle.contains("outer") && $0.subtitle.contains("inner") })
  }

  @Test func actionHistoryDoesNotReconstructMissingAttemptOutputs() throws {
    var machine = try start(
      """
      schema: prowl.workflow/v1
      id: old-action
      name: Old Action
      steps: [{id: snapshot, action: 'builtin:collect-worktree-context'}]
      """)
    let file = FileManager.default.temporaryDirectory.appending(path: "legacy-action-\(UUID().uuidString).json")
    try Data("{\"branch\":\"main\"}".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let output: [String: WorkflowJSONValue] = [
      "output": .object(["branch": .string("main")]), "output_path": .string(file.path),
    ]
    _ = machine.apply(
      .actionCompleted(stepID: "snapshot", outputs: output, executionID: try #require(machine.run.actionExecutionID)))
    var json = try #require(
      JSONSerialization.jsonObject(
        with: WorkflowRunRecord.makeEncoder().encode(
          WorkflowRunRecord(run: machine.run))) as? [String: Any])
    json["steps"] = [["id": "snapshot", "state": "completed"]]
    let single = try WorkflowRunRecord.makeDecoder().decode(
      WorkflowRunRecord.self,
      from: JSONSerialization.data(withJSONObject: json))
    #expect(WorkflowHistoryStepGroup.groups(single).first?.attempts.first?.outputs == nil)
    json["steps"] = [1, 2].map { ["id": "snapshot", "state": "completed", "iteration": $0] as [String: Any] }
    let repeated = try WorkflowRunRecord.makeDecoder().decode(
      WorkflowRunRecord.self,
      from: JSONSerialization.data(withJSONObject: json))
    #expect(WorkflowHistoryStepGroup.groups(repeated).flatMap(\.attempts).compactMap(\.outputs).isEmpty)
  }

  @Test(arguments: [false, true])
  func provisionalAndCorrectedSubmissionsKeepBothBodies(retrySave: Bool) throws {
    let pane = WorkflowPaneIdentity(surfaceID: UUID(), tabID: nil, handle: "p1", displayName: "Pi", agent: "pi")
    var machine = try start(
      """
      schema: prowl.workflow/v1
      id: delivery
      name: Delivery
      roles: {author: {source: current}}
      steps:
        - id: review
          message: author
          prompt: Review
          expect: {delivery: report, sections: ['## Findings']}
      """, roles: ["author": .current(pane)])
    _ = machine.apply(.roleIdle(ordinal: 1))
    _ = machine.apply(.injectionSucceeded(ordinal: 1, dispatchID: "dispatch"))
    let disk = WorkflowRunStore(rootURL: machine.run.context.worktree.rootURL, directory: machine.run.runDirectory)
    try disk.ensureLayout(runID: machine.run.id)
    defer { try? FileManager.default.removeItem(at: machine.run.runDirectory) }
    func persist(_ effects: [WorkflowRunEffect]) throws {
      for case .persistDelivery(let name, let ordinal, let body) in effects {
        try disk.writeDelivery(runID: machine.run.id, name: name, ordinal: ordinal, body: body)
      }
    }
    let first = machine.deliver(ordinal: 1, selector: .manual(stepID: "review"), body: "First output", verdict: nil)
    try persist(first.effects)
    _ = machine.apply(.deliveryPersisted(ordinal: 1))
    #expect(WorkflowRunRecord(run: machine.run).steps.last?.delivery != nil)
    _ = machine.apply(.user(.askAgain))
    let second = machine.deliver(
      ordinal: 1, selector: .manual(stepID: "review"), body: "## Findings\nCorrected output", verdict: nil)
    var effects = second.effects
    if retrySave {
      _ = machine.apply(.deliveryPersistFailed(ordinal: 1, reason: "Disk unavailable"))
      effects = machine.apply(.user(.retry))
    }
    try persist(effects)
    _ = machine.apply(.deliveryPersisted(ordinal: 1))
    let record = WorkflowRunRecord(run: machine.run)
    #expect(record.steps.last?.submissions?.map(\.accepted) == [false, true])
    #expect(record.steps.last?.submissions?.last?.issues.isEmpty == true)
    let json = try #require(
      JSONSerialization.jsonObject(with: WorkflowRunRecord.makeEncoder().encode(record)) as? [String: Any])
    let steps = try #require(json["steps"] as? [[String: Any]])
    let submissions = try #require(steps.last?["submissions"] as? [[String: Any]])
    try #require(submissions.count == 2)
    let paths = try submissions.map { entry -> String in
      let delivery = try #require(entry["delivery"] as? [String: Any])
      return try #require(delivery["path"] as? String)
    }
    #expect(Set(paths).count == 2)
    #expect(try String(contentsOfFile: paths[0], encoding: .utf8).contains("First output"))
    #expect(try String(contentsOfFile: paths[1], encoding: .utf8).contains("Corrected output"))

    let decoded = try WorkflowRunRecord.makeDecoder().decode(
      WorkflowRunRecord.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(WorkflowHistoryStepGroup.groups(decoded).flatMap(\.attempts).flatMap { $0.submissions ?? [] }.count == 2)
  }

  @Test func cancelledSaveRetryKeepsTheSubmittedBody() throws {
    let pane = WorkflowPaneIdentity(surfaceID: UUID(), tabID: nil, handle: "p1", displayName: "Pi", agent: "pi")
    var machine = try start(
      """
      schema: prowl.workflow/v1
      id: delivery
      name: Delivery
      roles: {author: {source: current}}
      steps:
        - id: review
          message: author
          prompt: Review
          expect: {delivery: report, sections: ['## Findings']}
      """, roles: ["author": .current(pane)])
    _ = machine.apply(.roleIdle(ordinal: 1))
    _ = machine.apply(.injectionSucceeded(ordinal: 1, dispatchID: "dispatch"))
    let disk = WorkflowRunStore(rootURL: machine.run.context.worktree.rootURL, directory: machine.run.runDirectory)
    try disk.ensureLayout(runID: machine.run.id)
    defer { try? FileManager.default.removeItem(at: machine.run.runDirectory) }
    _ = machine.deliver(
      ordinal: 1, selector: .manual(stepID: "review"), body: "## Findings\nSaved after retry", verdict: nil)
    _ = machine.apply(.deliveryPersistFailed(ordinal: 1, reason: "Disk unavailable"))
    let effects = machine.apply(.user(.retry))
    _ = machine.apply(.user(.cancel))
    for case .persistDelivery(let name, let ordinal, let body) in effects {
      try disk.writeDelivery(runID: machine.run.id, name: name, ordinal: ordinal, body: body)
    }
    _ = machine.apply(.deliveryPersisted(ordinal: 1))
    let record = WorkflowRunRecord(run: machine.run)
    #expect(machine.run.status == .cancelled)
    #expect(record.steps.last?.submissions?.count == 1)
    #expect(record.steps.last?.submissions?.first?.accepted == false)
  }

  @Test func textPreviewKeepsMultibyteCharacterBoundaries() {
    for character in ["é", "中", "🐈", "🐈‍⬛"] {
      let prefix = String(repeating: "a", count: 199) + character
      let preview = WorkflowHistoryTextPreview(prefix + "tail")
      #expect(preview.text == prefix)
      #expect(preview.remainingCharacters == 4)
    }
  }

  @Test func groupingKeepsTenThousandRoundsInNumericOrder() throws {
    let machine = try start(
      """
      schema: prowl.workflow/v1
      id: large
      name: Large
      steps: [{id: tick, set: {}}]
      """)
    let original = WorkflowRunRecord(run: machine.run)
    var object = try #require(
      JSONSerialization.jsonObject(with: WorkflowRunRecord.makeEncoder().encode(original)) as? [String: Any])
    object["steps"] = (1...10_000).map { index in
      ["id": "tick", "state": "completed", "iteration": index, "iterationPath": ["rounds:\(index)"]] as [String: Any]
    }
    let record = try WorkflowRunRecord.makeDecoder().decode(
      WorkflowRunRecord.self,
      from: JSONSerialization.data(withJSONObject: object))
    let groups = WorkflowHistoryStepGroup.groups(record)
    #expect(groups.count == 10_000)
    #expect(groups.map(\.iteration) == Array(1...10_000))
  }

  @Test func longKeysCannotEscapeThePreviewBudget() {
    let key = String(repeating: "k", count: 1_000_000)
    #expect(WorkflowHistoryOutputField(key: key, value: .string("value")).displayKey.count == 100)
  }
}
