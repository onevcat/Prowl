import Foundation
import Testing

@testable import Prowl

struct CodexDaemonThreadMapperTests {
  private typealias Mapper = CodexDaemonThreadMapper

  private static let paneA = UUID()
  private static let paneB = UUID()
  private static let start = Date(timeIntervalSince1970: 1_000)

  private static func log(_ surfaceID: UUID, _ submits: [(String, TimeInterval)]) -> Mapper.SessionLog {
    Mapper.SessionLog(
      surfaceID: surfaceID,
      startedAt: start,
      submits: submits.map { .init(clientID: $0.0, submittedAt: start.addingTimeInterval($0.1)) }
    )
  }

  private static func rollout(_ id: String, parent: String? = nil, _ clientIDs: [String]) -> Mapper.Rollout {
    Mapper.Rollout(id: id, parentID: parent, clientIDs: clientIDs)
  }

  @Test func panesSharingACwdResolveToTheirOwnThreads() {
    let rollouts = [Self.rollout("t1", ["a1"]), Self.rollout("t2", ["b1"])]
    let logs = [Self.log(Self.paneA, [("a1", 1)]), Self.log(Self.paneB, [("b1", 2)])]

    #expect(Mapper.resolve(threadID: "t1", rollouts: rollouts, logs: logs)?.surfaceID == Self.paneA)
    #expect(Mapper.resolve(threadID: "t2", rollouts: rollouts, logs: logs)?.surfaceID == Self.paneB)
    #expect(Mapper.resolve(threadID: "t1", rollouts: rollouts, logs: logs)?.sessionStartedAt == Self.start)
  }

  @Test func aPaneFollowsItsNewestIndexedSubmit() {
    // `/new` moved pane A from t1 to t2; t1 has no driving pane any more.
    let rollouts = [Self.rollout("t1", ["a1"]), Self.rollout("t2", ["a2"])]
    let logs = [Self.log(Self.paneA, [("a1", 1), ("a2", 2)])]

    #expect(Mapper.resolve(threadID: "t1", rollouts: rollouts, logs: logs) == nil)
    #expect(Mapper.resolve(threadID: "t2", rollouts: rollouts, logs: logs)?.surfaceID == Self.paneA)
  }

  @Test func aSubmitNotYetWrittenKeepsThePreviousBinding() {
    // A steered message reaches the rollout only at the next tool boundary.
    let rollouts = [Self.rollout("t1", ["a1"])]
    let logs = [Self.log(Self.paneA, [("a1", 1), ("a2-pending", 2)])]

    #expect(Mapper.resolve(threadID: "t1", rollouts: rollouts, logs: logs)?.surfaceID == Self.paneA)
  }

  @Test func aChildThreadResolvesThroughItsRoot() {
    let rollouts = [
      Self.rollout("root", ["a1"]),
      Self.rollout("child", parent: "root", []),
      Self.rollout("grandchild", parent: "child", []),
    ]
    let logs = [Self.log(Self.paneA, [("a1", 1)])]

    #expect(Mapper.resolve(threadID: "grandchild", rollouts: rollouts, logs: logs)?.surfaceID == Self.paneA)
  }

  @Test func aThreadDrivenFromTwoPanesGoesToTheNewestSubmitter() {
    let rollouts = [Self.rollout("t1", ["a1", "b1"])]
    let newestB = [Self.log(Self.paneA, [("a1", 1)]), Self.log(Self.paneB, [("b1", 2)])]
    let tie = [Self.log(Self.paneA, [("a1", 1)]), Self.log(Self.paneB, [("b1", 1)])]

    #expect(Mapper.resolve(threadID: "t1", rollouts: rollouts, logs: newestB)?.surfaceID == Self.paneB)
    #expect(Mapper.resolve(threadID: "t1", rollouts: rollouts, logs: tie) == nil)
  }

  @Test func missingEvidenceResolvesToNoPane() {
    let rollouts = [Self.rollout("t1", ["a1"])]

    #expect(Mapper.resolve(threadID: "t9", rollouts: rollouts, logs: [Self.log(Self.paneA, [("a1", 1)])]) == nil)
    #expect(Mapper.resolve(threadID: "t1", rollouts: rollouts, logs: [Self.log(Self.paneA, [])]) == nil)
    #expect(Mapper.resolve(threadID: "t1", rollouts: rollouts, logs: []) == nil)
  }

  @Test func sessionLogKeepsOnlyTheLatestTUISubmits() throws {
    let data = Data(
      """
      {"ts":"2026-09-28T14:24:00.000Z","dir":"meta","kind":"session_start","cwd":"/w"}
      {"ts":"2026-09-28T14:24:01.000Z","kind":"op","payload":{"UserTurn":{"client_user_message_id":"old"}}}
      {"ts":"2026-09-28T14:25:00.500Z","dir":"meta","kind":"session_start","cwd":"/w"}
      {"ts":"2026-09-28T14:25:01.000Z","dir":"to_tui","kind":"app_event","variant":"CommitTick"}
      {"ts":"2026-09-28T14:25:02.000Z","dir":"from_tui","kind":"op","payload":"Interrupt"}
      {"ts":"2026-09-28T14:25:03.250Z","kind":"op","payload":{"UserTurn":{"client_user_message_id":"new"}}}
      not json

      """.utf8)

    let log = try #require(Mapper.parseSessionLog(data, surfaceID: Self.paneA))

    #expect(log.startedAt == Date(timeIntervalSince1970: 1_790_605_500.5))
    #expect(log.submits.map(\.clientID) == ["new"])
    #expect(log.submits.first?.submittedAt == Date(timeIntervalSince1970: 1_790_605_503.25))
    #expect(Mapper.parseSessionLog(Data("{}".utf8), surfaceID: Self.paneA) == nil)
  }

  @Test func rolloutLinesYieldHeaderLineageAndUserMessageIDs() {
    let child = Data(
      #"{"type":"session_meta","payload":{"id":"c","source":{"subagent":{"thread_spawn":{"parent_thread_id":"p"}}}}}"#
        .utf8)
    let root = Data(#"{"type":"session_meta","payload":{"id":"p","source":"vscode"}}"#.utf8)
    let user = Data(
      #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","client_id":"x"}}}"#
        .utf8)
    let agent = Data(
      #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","client_id":"y"}}}"#
        .utf8)

    #expect(Mapper.header(child) == Mapper.Rollout(id: "c", parentID: "p", clientIDs: []))
    #expect(Mapper.header(root) == Mapper.Rollout(id: "p", parentID: nil, clientIDs: []))
    #expect(Mapper.header(user) == nil)
    #expect(Mapper.userMessageClientID(user) == "x")
    #expect(Mapper.userMessageClientID(agent) == nil)
    #expect(Mapper.isRolloutPath("/h/.codex/sessions/2026/09/28/rollout-2026-09-28T22-30-41-id.jsonl"))
    #expect(!Mapper.isRolloutPath("/h/.codex/logs_2.sqlite"))
  }

  @Test func mapsFromFilesAndFollowsAppendedSubmits() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "codex-map-\(UUID().uuidString)")
    let logs = directory.appending(path: "logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appending(path: "rollout-2026-09-28T00-00-00-t1.jsonl")
    let second = directory.appending(path: "rollout-2026-09-28T00-01-00-t2.jsonl")
    let invalid = directory.appending(path: "rollout-2026-09-28T00-02-00-bad.jsonl")
    func header(_ id: String) -> String {
      #"{"type":"session_meta","payload":{"id":""# + id + #"","source":"vscode"}}"#
    }
    func user(_ id: String) -> String {
      #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","client_id":""# + id
        + #""}}}"#
    }
    func submit(_ id: String, _ second: Int) -> String {
      #"{"ts":"2026-09-28T14:25:0\#(second).000Z","kind":"op","payload":{"UserTurn":{"client_user_message_id":""#
        + id + #""}}}"#
    }
    let start = #"{"ts":"2026-09-28T14:25:00.000Z","kind":"session_start"}"#
    try Data([header("t1"), user("a1"), ""].joined(separator: "\n").utf8).write(to: first)
    try Data([header("t2"), ""].joined(separator: "\n").utf8).write(to: second)
    try Data([user("a9"), user("a9"), ""].joined(separator: "\n").utf8).write(to: invalid)
    let logA = CodexTUISessionLog.url(for: Self.paneA, in: logs)
    try Data([start, submit("a1", 1), ""].joined(separator: "\n").utf8).write(to: logA)
    try Data("ignored".utf8).write(to: logs.appending(path: "notes.txt"))
    let open = [first, second, invalid].map { $0.path(percentEncoded: false) } + ["/dev/null"]
    let mapper = CodexDaemonThreadMapper(sessionLogDirectory: logs, openFilePaths: { _ in open })

    #expect(await mapper.pane(threadID: "t1", daemonPID: 1)?.surfaceID == Self.paneA)
    #expect(await mapper.pane(threadID: "t2", daemonPID: 1) == nil)

    let handle = try FileHandle(forWritingTo: second)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((user("a2") + "\n").utf8))
    try handle.close()
    try Data([start, submit("a1", 1), submit("a2", 2), ""].joined(separator: "\n").utf8).write(to: logA)

    #expect(await mapper.pane(threadID: "t2", daemonPID: 1)?.surfaceID == Self.paneA)
    #expect(await mapper.pane(threadID: "t1", daemonPID: 1) == nil)
    let incomplete = CodexDaemonThreadMapper(sessionLogDirectory: logs, openFilePaths: { _ in nil })
    #expect(await incomplete.pane(threadID: "t2", daemonPID: 1) == nil)
  }

  @Test func bindingCoversTheRootFamilyAndStartsAtTheBoundTurn() {
    var root = Self.rollout("root", ["a1"])
    root.path = "/r"
    root.turnStartOffsets = ["a1": 100]
    var child = Self.rollout("child", parent: "root", [])
    child.path = "/c"
    var other = Self.rollout("other", ["b1"])
    other.path = "/o"
    let rollouts = [root, child, other]

    let binding = Mapper.binding(for: Self.log(Self.paneA, [("a1", 1), ("a2-pending", 2)]), rollouts: rollouts)

    #expect(binding == CodexDaemonBinding(rootID: "root", paths: ["/c", "/r"], liveOffsets: ["/r": 100]))
    #expect(Mapper.binding(for: Self.log(Self.paneA, [("pending", 1)]), rollouts: rollouts) == nil)
  }

  @Test func indexRecordsTurnStartsAndSkipsInheritedHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "codex-bind-\(UUID().uuidString)")
    let logs = directory.appending(path: "logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func event(_ type: String, _ extra: String = "") -> String {
      #"{"type":"event_msg","payload":{"type":""# + type + #"""# + extra + "}}"
    }
    func user(_ id: String) -> String {
      event("item_completed", #","item":{"type":"UserMessage","client_id":""# + id + #""}"#)
    }
    let main = directory.appending(path: "rollout-main.jsonl")
    let mainHead = [
      #"{"type":"session_meta","payload":{"id":"main","source":"vscode"}}"#,
      event("task_started", #","turn_id":"1""#), user("a1"), event("task_complete", #","turn_id":"1""#), "",
    ].joined(separator: "\n")
    let mainTail = [event("task_started", #","turn_id":"2""#), user("a2"), ""].joined(separator: "\n")
    try Data((mainHead + mainTail).utf8).write(to: main)
    let fork = directory.appending(path: "rollout-fork.jsonl")
    let forkHead = [
      #"{"type":"session_meta","payload":{"id":"fork","forked_from_id":"main","source":"vscode"}}"#,
      event("task_started", #","turn_id":"old""#), user("copied"),
      event("thread_settings_applied", #","thread_id":"fork""#), "",
    ].joined(separator: "\n")
    let forkTail = [event("task_started", #","turn_id":"3""#), user("f1"), ""].joined(separator: "\n")
    try Data((forkHead + forkTail).utf8).write(to: fork)
    let tuiStart = Date(timeIntervalSince1970: 1_790_605_490)
    let start = #"{"ts":"2026-09-28T14:25:00.000Z","kind":"session_start"}"#
    let submit =
      #"{"ts":"2026-09-28T14:25:05.000Z","kind":"op","payload":{"UserTurn":{"client_user_message_id":"f1"}}}"#
    try Data([start, submit, ""].joined(separator: "\n").utf8).write(
      to: CodexTUISessionLog.url(for: Self.paneA, in: logs))
    let open = [main, fork].map { $0.path(percentEncoded: false) }
    let mapper = CodexDaemonThreadMapper(sessionLogDirectory: logs, openFilePaths: { _ in open })

    let binding = await mapper.binding(surfaceID: Self.paneA, daemonPID: 1, tuiStartedAt: tuiStart)
    #expect(binding?.rootID == "fork")
    #expect(binding?.paths == [open[1]])
    #expect(binding?.liveOffsets == [open[1]: UInt64(forkHead.utf8.count)])
    #expect(await mapper.pane(threadID: "main", daemonPID: 1) == nil)
    let late = await mapper.binding(
      surfaceID: Self.paneA, daemonPID: 1, tuiStartedAt: tuiStart.addingTimeInterval(-3_600))
    #expect(late == nil)

    let submitB = submit.replacing("f1", with: "a2")
    try Data([start, submitB, ""].joined(separator: "\n").utf8).write(
      to: CodexTUISessionLog.url(for: Self.paneB, in: logs))
    let mainBinding = await mapper.binding(surfaceID: Self.paneB, daemonPID: 1, tuiStartedAt: tuiStart)
    #expect(mainBinding?.rootID == "main")
    #expect(mainBinding?.liveOffsets == [open[0]: UInt64(mainHead.utf8.count)])
  }

  @Test func preparingTheLogDirectoryRemovesOnlyStaleLogs() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "codex-logs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    let stale = CodexTUISessionLog.url(for: UUID(), in: directory)
    let fresh = CodexTUISessionLog.url(for: UUID(), in: directory)
    let unrelated = directory.appending(path: "keep.txt")
    for url in [stale, fresh, unrelated] { try Data().write(to: url) }
    let old = now.addingTimeInterval(-CodexTUISessionLog.staleAge - 60)
    for url in [stale, unrelated] {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path(percentEncoded: false))
    }

    CodexTUISessionLog.prepareDirectory(directory, now: now)

    let permissions =
      try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))[
        .posixPermissions] as? Int
    #expect(permissions == 0o700)
    #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: fresh.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: unrelated.path(percentEncoded: false)))
  }
}
