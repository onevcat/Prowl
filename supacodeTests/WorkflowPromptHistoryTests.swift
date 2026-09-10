import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowPromptHistoryTests {
  private let pane = WorkflowPaneIdentity(
    surfaceID: UUID(), tabID: nil, handle: "p1", displayName: "Writer", agent: "pi")

  @Test func savedPromptContainsOnlyTheRenderedTask() throws {
    var machine = try start([
      .init(id: "write", action: .message(role: "author", prompt: "# Task\nWrite a report.", expect: .init()))
    ])
    let effects = machine.apply(.roleIdle(ordinal: 1))
    #expect(effects.contains(.materializePrompt(ordinal: 1, stepID: "write", text: "# Task\nWrite a report.")))
    #expect(machine.run.invocations[0].promptPath?.hasSuffix("prompts/write.1.md") == true)
    let encoded = try json(machine)
    let invocations = try #require(encoded["invocations"] as? [[String: Any]])
    #expect(invocations[0]["prompt_path"] != nil)
    #expect(invocations[0]["instruction_path"] == nil)
  }

  @Test func controlAndNotifyKeepExecutionTimeTitlesAndSummaries() throws {
    let machine = try start(
      [
        .init(
          id: "choose", title: "Choose {{ state.count }}",
          action: .control(
            .conditional(
              condition: "state.count == 1",
              then: [
                .init(id: "change", action: .control(.set(["count": "2"])))
              ], else: []))),
        .init(id: "sent", title: "Saved {{ state.count }}", action: .notify("Saved version {{ state.count }}")),
      ], state: ["count": .init(type: "integer", initial: .integer(1))])
    let steps = try #require(try json(machine)["steps"] as? [[String: Any]])
    let choice = try #require(steps.first { $0["id"] as? String == "choose" })
    #expect(choice["title"] as? String == "Choose 1")
    #expect((choice["summary"] as? String)?.contains("true") == true)
    let sent = try #require(steps.first { $0["id"] as? String == "sent" })
    #expect(sent["title"] as? String == "Saved 2")
    #expect(sent["summary"] as? String == "Saved version 2")
  }

  @Test func invocationKeepsItsTargetAfterRelaunch() throws {
    let profile = WorkflowProfileBinding(id: UUID(), name: "Reviewer", agent: "pi")
    var machine = try WorkflowRunMachine.start(
      .init(
        definition: .init(
          id: "targets", name: "Targets",
          roles: [
            .init(name: "reviewer", source: .launch, launch: .init())
          ],
          steps: [
            .init(id: "launch", action: .launch(role: "reviewer", prompt: "Review", skill: nil, expect: .init()))
          ]),
        runID: UUID(), context: context, bindings: ["reviewer": .launch(profile, pane: nil)]
      ), now: { Date(timeIntervalSince1970: 100) }
    ).machine
    _ = machine.apply(.launched(ordinal: 1, pane: pane, dispatchID: "first"))
    _ = machine.apply(.watchdog(ordinal: 1, .attention(.agentGone(.paneClosed))))
    _ = machine.apply(.user(.relaunch))
    let replacement = WorkflowPaneIdentity(
      surfaceID: UUID(), tabID: nil, handle: "p2", displayName: "Reviewer", agent: "pi")
    _ = machine.apply(.launched(ordinal: 2, pane: replacement, dispatchID: "second"))
    let invocations = try #require(try json(machine)["invocations"] as? [[String: Any]])
    #expect(invocations.count == 2)
    let targets = invocations.compactMap { $0["target"] as? [String: Any] }
    #expect(targets.count == 2)
    #expect(targets.compactMap { ($0["pane"] as? [String: Any])?["handle"] as? String } == ["p1", "p2"])
  }

  @Test func loopRecordsEachCheckWithoutInventingRetryAttempts() throws {
    let machine = try start(
      [
        .init(
          id: "rounds", title: "Loop {{ state.count }}",
          action: .control(
            .loop(
              condition: "state.count < 2", maximum: 3,
              steps: [.init(id: "increment", action: .control(.set(["count": "state.count + 1"])))])
          ))
      ], state: ["count": .init(type: "integer", initial: .integer(0))])
    let checks = machine.run.stepRecords.filter { $0.stepID == "rounds" }
    #expect(checks.map(\.title) == ["Loop 0", "Loop 1", "Loop 2"])
    #expect(checks.last?.summary?.contains("false") == true)
    #expect(checks.allSatisfy { $0.iterationPath == [] && $0.iteration == nil })
    let group = try #require(WorkflowHistoryStepGroup.groups(WorkflowRunRecord(run: machine.run)).first)
    #expect(group.contextLabel == "3 checks")
  }

  @Test func failedControlKeepsItsRenderedTitle() throws {
    let machine = try start(
      [
        .init(
          id: "choose", title: "Choose {{ state.count }}",
          action: .control(
            .conditional(
              condition: "state.count", then: [], else: [])))
      ], state: ["count": .init(type: "integer", initial: .integer(1))])
    #expect(machine.run.stepRecords.last?.title == "Choose 1")
    #expect(machine.run.status.attention != nil)
  }

  @Test func promptPreviewReadsBeyondTheDeliveryLimitAndRejectsLinks() throws {
    let root = WorkflowHistoryStorage.canonicalURL(FileManager.default.temporaryDirectory)
      .appending(path: "prompt-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "prompt.md")
    let count = WorkflowSizeLimits.payload + 1
    try Data(repeating: 120, count: count).write(to: file)
    let storage = WorkflowHistoryStorage(baseURL: root)
    let preview = try WorkflowHistoryTextPreview.read(file, storage: storage)
    #expect(preview.text == String(repeating: "x", count: 200))
    #expect(preview.remainingCharacters == count - 200)
    let link = root.appending(path: "link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: (any Error).self) { try WorkflowHistoryTextPreview.read(link, storage: storage) }
  }

  @Test func fileLoadKeyChangesWhenAnAttemptFinishesOrPublishesAgain() {
    let url = URL(filePath: "/tmp/request.json")
    let active = WorkflowHistoryFileLoadKey(url: url, revision: .init(updatedAt: .distantPast, state: "active"))
    #expect(active != WorkflowHistoryFileLoadKey(url: url, revision: .init(updatedAt: .distantFuture, state: "active")))
    #expect(
      active != WorkflowHistoryFileLoadKey(url: url, revision: .init(updatedAt: .distantPast, state: "completed")))
  }

  @Test func actionInputUsesOnlyTheSavedTypedInput() throws {
    let request = Data(
      #"{"input":{"enabled":true,"items":[1,"two"],"empty":null},"context":{"private":"not input"}}"#.utf8)
    #expect(
      try WorkflowHistoryExecution.actionInput(request) == [
        "enabled": .boolean(true), "items": .array([.integer(1), .string("two")]), "empty": .null,
      ])
    #expect(throws: (any Error).self) {
      try WorkflowHistoryExecution.actionInput(Data(#"{"context":{}}"#.utf8))
    }
  }

  @Test func promptReferenceMustMatchItsRunStepAndInvocation() throws {
    var machine = try start([.init(id: "write", action: .message(role: "author", prompt: "Write", expect: nil))])
    _ = machine.apply(.roleIdle(ordinal: 1))
    let directory = machine.run.runDirectory
    var json = try json(machine)
    let record = WorkflowRunRecord(run: machine.run)
    #expect(
      WorkflowHistoryExecution.promptURL(record.invocations[0], directory: directory)?.lastPathComponent == "write.1.md"
    )
    for path in ["/tmp/private.md", "prompts/write.2.md", "../other/prompts/write.1.md"] {
      var invocations = try #require(json["invocations"] as? [[String: Any]])
      invocations[0]["prompt_path"] = path
      json["invocations"] = invocations
      let changed = try WorkflowRunRecord.makeDecoder().decode(
        WorkflowRunRecord.self, from: JSONSerialization.data(withJSONObject: json))
      #expect(WorkflowHistoryExecution.promptURL(changed.invocations[0], directory: directory) == nil)
    }
  }

  @Test func failedLaunchDoesNotClaimAnAgentStarted() throws {
    let profile = WorkflowProfileBinding(id: UUID(), name: "Reviewer", agent: "pi")
    var machine = try WorkflowRunMachine.start(
      .init(
        definition: .init(
          id: "launch", name: "Launch", roles: [.init(name: "reviewer", source: .launch, launch: .init())],
          steps: [
            .init(id: "review", action: .launch(role: "reviewer", prompt: "Review", skill: nil, expect: .init()))
          ]), runID: UUID(), context: context, bindings: ["reviewer": .launch(profile, pane: nil)]
      ), now: { Date(timeIntervalSince1970: 100) })
    #expect(machine.effects.contains(.materializePrompt(ordinal: 1, stepID: "review", text: "Review")))
    _ = machine.machine.apply(.launchFailed(ordinal: 1, reason: "Unavailable"))
    let invocation = try #require(WorkflowRunRecord(run: machine.machine.run).invocations.first)
    #expect(WorkflowHistoryExecution.agentStatus(invocation) == "Agent has not started.")
  }

  private var context: WorkflowRunContext {
    .init(scope: .user, definitionPath: nil, worktree: .init(id: "wt", name: "Test", branch: "main", path: "/tmp"))
  }

  private func start(_ steps: [WorkflowStepDefinition], state: [String: WorkflowStateDeclaration] = [:]) throws
    -> WorkflowRunMachine
  {
    try WorkflowRunMachine.start(
      .init(
        definition: .init(
          id: "history", name: "History", roles: [.init(name: "author", source: .current)], steps: steps, state: state),
        runID: UUID(), context: context, bindings: ["author": .current(pane)]
      ), now: { Date(timeIntervalSince1970: 100) }
    ).machine
  }

  private func json(_ machine: WorkflowRunMachine) throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(
        with: WorkflowRunRecord.makeEncoder().encode(WorkflowRunRecord(run: machine.run))) as? [String: Any])
  }
}
