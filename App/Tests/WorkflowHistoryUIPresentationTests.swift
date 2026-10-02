import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowHistoryUIPresentationTests {
  @Test func durationUsesHoursMinutesAndSeconds() {
    #expect(WorkflowHistoryTiming.duration(3661) == "1h 1m 1s")
    #expect(WorkflowHistoryTiming.duration(139) == "2m 19s")
    #expect(WorkflowHistoryTiming.duration(0.4) == "<1s")
    #expect(WorkflowHistoryTiming.duration(-1) == "<1s")
    #expect(WorkflowHistoryTiming.duration(60) == "1m 0s")
  }

  @Test func previewCountsCharactersRatherThanBytes() {
    let body = String(repeating: "🐈‍⬛", count: 213)
    let preview = WorkflowHistoryTextPreview(body)
    #expect(preview.text == String(repeating: "🐈‍⬛", count: 200))
    #expect(preview.remainingCharacters == 13)
    #expect(WorkflowHistoryTextPreview("short").remainingCharacters == 0)
  }

  @Test func fieldsPreserveNestingAndOnlyRecognizeNamedAbsolutePaths() {
    let fields = WorkflowHistoryOutputField.fields([
      "output": .object(["path": .string("/tmp/context.md"), "branch": .string("main")]),
      "output_path": .string("/tmp/result.json"),
      "description": .string("/tmp/not-a-file"),
      "relative_path": .string("../escape"),
    ])
    #expect(fields.map(\.key) == ["description", "output", "output_path", "relative_path"])
    let output = fields.first { $0.key == "output" }
    #expect(output?.children?.map(\.key) == ["branch", "path"])
    #expect(output?.children?.last?.fileURL == URL(filePath: "/tmp/context.md"))
    #expect(fields.first?.fileURL == nil)
    #expect(fields.last?.fileURL == nil)
  }

  @Test func fieldTreesBoundWidthDepthAndText() {
    let fields = WorkflowHistoryOutputField.fields(
      Dictionary(
        (0..<100).map { ("field-\($0)", WorkflowJSONValue.integer($0)) }, uniquingKeysWith: { first, _ in first }))
    #expect(fields.count == 32)
    var value = WorkflowJSONValue.string(String(repeating: "x", count: 100_000))
    for _ in 0..<20 { value = .object(["child": value]) }
    var node = WorkflowHistoryOutputField(key: "root", value: value)
    for _ in 0..<5 { node = node.children?.first ?? node }
    #expect(node.children == nil)
    #expect(
      WorkflowHistoryOutputField(key: "text", value: .string(String(repeating: "x", count: 100_000))).summary.count
        <= 201)
  }

  @Test func closedPaneRetainsRecordedRuntimeButNoHandle() {
    let pane = WorkflowPaneIdentity(surfaceID: UUID(), tabID: nil, handle: "p14", displayName: "Writer", agent: "pi")
    let binding = WorkflowRunRecord.Binding(source: .current, profile: nil, pane: pane)
    let closed = WorkflowHistoryRole(role: "author", binding: binding, livePaneIDs: [])
    #expect(closed.agent == "pi")
    #expect(closed.livePane == nil)
    let live = WorkflowHistoryRole(role: "author", binding: binding, livePaneIDs: [pane.surfaceID])
    #expect(live.livePane?.handle == "p14")
  }

  @Test func actionTimingRequiresBothValidTimestamps() throws {
    let data = Data(#"{"started_at":"2026-09-09T12:00:00Z","finished_at":"2026-09-09T12:02:19Z"}"#.utf8)
    #expect(WorkflowHistoryTiming.actionDuration(data) == 139)
    #expect(WorkflowHistoryTiming.actionDuration(Data(#"{"started_at":"2026-09-09T12:00:00Z"}"#.utf8)) == nil)
    #expect(
      WorkflowHistoryTiming.actionDuration(
        Data(#"{"started_at":"2026-09-09T12:00:00Z","finished_at":"2026-09-09T11:00:00Z"}"#.utf8)) == nil)
  }

  @Test func durationProjectionUsesExactInvocationsAndDoesNotGuessMissingTiming() throws {
    let definition = WorkflowDefinition(id: "test", name: "Test", steps: [.init(id: "step", action: .notify("done"))])
    let run = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "wt", name: "Test", branch: "main", path: "/tmp")), bindings: [:]),
      now: { Date(timeIntervalSince1970: 100) }
    ).machine.run
    var json = try #require(
      JSONSerialization.jsonObject(with: WorkflowRunRecord.makeEncoder().encode(WorkflowRunRecord(run: run)))
        as? [String: Any])
    json["steps"] = [["id": "step", "state": "completed", "ordinal": 7]]
    json["invocations"] = [
      [
        "ordinal": 7, "step": "step", "role": "author", "kind": "message",
        "started_at": "2026-09-09T12:00:00Z", "ended_at": "2026-09-09T12:00:30Z",
      ]
    ]
    let record = try WorkflowRunRecord.makeDecoder().decode(
      WorkflowRunRecord.self, from: JSONSerialization.data(withJSONObject: json))
    let groups = WorkflowHistoryStepGroup.groups(record)
    let timing = WorkflowHistoryTiming.durations(groups, record: record, directory: nil, storage: .configured)
    #expect(timing[groups[0].id] == 30)
    let untimed = WorkflowRunRecord(run: run)
    #expect(
      WorkflowHistoryTiming.durations(
        WorkflowHistoryStepGroup.groups(untimed), record: untimed, directory: nil, storage: .configured
      ).isEmpty)
  }

  @Test func fileActionsKeepHistoryAndHandoffContainment() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "history-ui-\(UUID().uuidString)")
    let handoff = root.appending(path: ".prowl/handoff")
    try FileManager.default.createDirectory(at: handoff, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = handoff.appending(path: "current.md")
    try Data("handoff".utf8).write(to: file)
    let storage = WorkflowHistoryStorage(baseURL: root.appending(path: "history"))
    #expect(throws: Never.self) {
      try WorkflowHistoryArtifact.validate(file, worktree: root, storage: storage)
      let canonicalRoot = WorkflowHistoryStorage.canonicalURL(root)
      let canonicalFile = canonicalRoot.appending(path: ".prowl/handoff/current.md")
      try WorkflowHistoryArtifact.validate(canonicalFile, worktree: canonicalRoot, storage: storage)
      try WorkflowHistoryArtifact.validate(canonicalFile, worktree: root, storage: storage)
    }
    let outside = root.appending(path: "private.txt")
    try Data().write(to: outside)
    #expect(throws: (any Error).self) {
      try WorkflowHistoryArtifact.validate(outside, worktree: root, storage: storage)
    }
    let link = handoff.appending(path: "linked.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: (any Error).self) {
      try WorkflowHistoryArtifact.validate(link, worktree: root, storage: storage)
    }
    let directoryLink = handoff.appending(path: "archive")
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
    #expect(throws: (any Error).self) {
      try WorkflowHistoryArtifact.validate(
        directoryLink.appending(path: "private.txt"), worktree: root, storage: storage)
    }
  }
}
