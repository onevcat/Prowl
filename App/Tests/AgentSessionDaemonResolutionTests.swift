import Foundation
import Synchronization
import Testing

@testable import Prowl

struct AgentSessionDaemonResolutionTests {
  private nonisolated struct Fixture {
    let directory: URL
    let home: URL
    let first: URL
    let second: URL
    let child: URL
    let tui: Process
    let input: Pipe
    let firstID = "11111111-1111-4111-8111-111111111111"
    let secondID = "22222222-2222-4222-8222-222222222222"
    let childID = "33333333-3333-4333-8333-333333333333"

    init(ownsRollout: Bool = false) throws {
      tui = Process()
      input = Pipe()
      tui.executableURL = URL(filePath: "/bin/cat")
      tui.standardInput = input
      tui.standardOutput = FileHandle.nullDevice
      directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "prowl-session-\(UUID())")
      home = directory.appending(path: "custom-codex")
      let sessions = home.appending(path: "sessions/2026/10/08")
      try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
      first = sessions.appending(path: "rollout-2026-10-08T00-00-00-\(firstID).jsonl")
      second = sessions.appending(path: "rollout-2026-10-08T00-00-00-\(secondID).jsonl")
      child = sessions.appending(path: "rollout-2026-10-08T00-00-00-\(childID).jsonl")
      for (url, id) in [(first, firstID), (second, secondID), (child, childID)] {
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n".utf8).write(to: url)
      }
      if ownsRollout { tui.standardOutput = try FileHandle(forWritingTo: first) }
      try tui.run()
    }

    @MainActor var process: IdentifiedAgentProcess {
      IdentifiedAgentProcess(
        agent: .codex, name: "codex",
        process: ForegroundProcess(
          pid: tui.processIdentifier, name: "codex", argv0: nil, cmdline: nil))
    }

    func cleanUp() {
      try? input.fileHandleForWriting.close()
      tui.waitUntilExit()
      try? FileManager.default.removeItem(at: directory)
    }

    func binding(_ id: String, _ paths: [URL]) -> CodexDaemonBindingLookup {
      .bound(CodexDaemonBinding(rootID: id, paths: paths.map { $0.path }, liveOffsets: [:]))
    }
  }

  @Test func daemonIdentityIgnoresViewportAndSeparatesPanes() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let paneA = UUID()
    let paneB = UUID()
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in [] },
      daemonBinding: { pane, process, home in
        #expect(process.pid == fixture.tui.processIdentifier)
        #expect(home == fixture.home)
        return pane == paneA
          ? fixture.binding(fixture.firstID, [fixture.child, fixture.first])
          : fixture.binding(fixture.secondID, [fixture.second])
      })
    for screen in ["", "Old shell output with no transcript match", "Current response"] {
      for (pane, expectedID, expectedPath) in [
        (paneA, fixture.firstID, fixture.first), (paneB, fixture.secondID, fixture.second),
      ] {
        let result = await resolver.resolveFresh(
          identified: fixture.process, workingDirectory: fixture.directory, activeText: screen,
          configRoot: fixture.home, surfaceID: pane)
        #expect(result.session?.id == expectedID)
        #expect(result.session?.transcriptPath == expectedPath)
        #expect(result.session?.source == .processLog)
        #expect(result.session?.confidence == .exact)
      }
    }
    let background = await resolver.resolve(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home, surfaceID: paneA)
    #expect(background.session?.id == fixture.firstID)
    #expect(background.session?.confidence == .exact)
  }

  @Test func bindingChangesBypassTheProcessResultCache() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    actor BindingStore {
      var value: CodexDaemonBindingLookup = .unavailable
      func set(_ value: CodexDaemonBindingLookup) { self.value = value }
    }
    let store = BindingStore()
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in [] }, daemonBinding: { _, _, _ in await store.value })
    let pane = UUID()
    for (id, path) in [(fixture.firstID, fixture.first), (fixture.secondID, fixture.second)] {
      await store.set(fixture.binding(id, [path]))
      let result = await resolver.resolve(
        identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
        configRoot: fixture.home, surfaceID: pane)
      #expect(result.session?.id == id)
      #expect(result.session?.confidence == .exact)
    }
    await store.set(.unavailable)
    let lost = await resolver.resolveFresh(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home, surfaceID: pane)
    #expect(lost.session == nil)
  }

  @Test func missingMismatchedAmbiguousAndOutsideRootPathsAreNotExact() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let outside = fixture.directory.appending(path: fixture.first.lastPathComponent)
    try FileManager.default.copyItem(at: fixture.first, to: outside)
    let duplicate = fixture.home.appending(path: "sessions/\(fixture.first.lastPathComponent)")
    try FileManager.default.copyItem(at: fixture.first, to: duplicate)
    for paths in [[fixture.child], [fixture.second], [outside], [fixture.first, duplicate]] {
      let binding = fixture.binding(fixture.firstID, paths)
      let resolver = AgentSessionResolver(
        tuiOpenFilePaths: { _ in [] }, daemonBinding: { _, _, _ in binding })
      let result = await resolver.resolveFresh(
        identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
        configRoot: fixture.home, surfaceID: UUID())
      #expect(result.session?.confidence != .exact)
    }
  }

  @Test(arguments: [24_000, 1_048_576])
  func validatesLargeHeadersWithinTheProviderLimit(padding: Int) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let header: [String: Any] = [
      "type": "session_meta",
      "payload": [
        "id": fixture.firstID, "base_instructions": String(repeating: "x", count: padding),
      ],
    ]
    var data = try JSONSerialization.data(withJSONObject: header)
    data.append(10)
    try data.write(to: fixture.first)
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in [] },
      daemonBinding: { _, _, _ in fixture.binding(fixture.firstID, [fixture.first]) })
    let result = await resolver.resolveFresh(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home, surfaceID: UUID())
    #expect((result.session?.confidence == .exact) == (padding < 1_048_576))
  }

  @Test(arguments: [false, true])
  func knownSelectionChangeDoesNotMatchCopiedHistoryOrReplayTheCache(incomplete: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try FileManager.default.removeItem(at: fixture.second)
    try FileManager.default.removeItem(at: fixture.child)
    let text = "The previous session has a unique complete answer that is copied into the fork."
    let handle = try FileHandle(forWritingTo: fixture.first)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"text\":\"\(text)\"}\n".utf8))
    try handle.close()
    actor Selection {
      var changed = false
      func change() { changed = true }
      func restore() { changed = false }
    }
    let selection = Selection()
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in incomplete ? nil : [] },
      daemonBinding: { _, _, _ in await selection.changed ? .selectionPending : .unavailable })
    let pane = UUID()
    let initial = await resolver.resolve(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: text,
      configRoot: fixture.home, surfaceID: pane)
    #expect(initial.session?.confidence == .high)
    await selection.change()
    let cached = await resolver.resolve(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: text,
      configRoot: fixture.home, surfaceID: pane)
    let fresh = await resolver.resolveFresh(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: text,
      configRoot: fixture.home, surfaceID: pane)
    #expect(cached.session == nil)
    #expect(fresh.session == nil)
    await selection.restore()
    let afterGap = await resolver.resolve(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home, surfaceID: pane)
    #expect(afterGap.session == nil)
    #expect(afterGap.isFresh)
  }

  @Test(arguments: [false, true])
  func boundIdentityStillRequiresCompleteInventoryWithoutLocalRollouts(incomplete: Bool)
    async throws
  {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in incomplete ? nil : [fixture.first.path] },
      daemonBinding: { _, _, _ in fixture.binding(fixture.secondID, [fixture.second]) })
    let result = await resolver.resolveFresh(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home, surfaceID: UUID())
    #expect(result.session?.confidence != .exact)
  }

  @Test(arguments: [false, true])
  func ownedLocalRolloutTakesPrecedenceOverDaemonSelection(pending: Bool) async throws {
    let fixture = try Fixture(ownsRollout: true)
    defer { fixture.cleanUp() }
    #expect(ProcessDetection.openFilePaths(pid: fixture.tui.processIdentifier).contains(fixture.first.path))
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in [fixture.first.path] },
      daemonBinding: { _, _, _ in
        pending ? .selectionPending : fixture.binding(fixture.secondID, [fixture.second])
      })
    let pane = UUID()
    let background = await resolver.resolve(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home, surfaceID: pane)
    let fresh = await resolver.resolveFresh(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home, surfaceID: pane)
    for result in [background, fresh] {
      #expect(result.session?.id == fixture.firstID)
      #expect(result.session?.source == .openFile)
      #expect(result.session?.confidence == .exact)
    }
  }

  @Test(arguments: [false, true])
  func selectionResetDuringInventoryDoesNotReturnThePreviousBinding(fresh: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let selection = Mutex(fixture.binding(fixture.firstID, [fixture.first]))
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in
        selection.withLock { $0 = .selectionPending }
        return []
      },
      daemonBinding: { _, _, _ in selection.withLock { $0 } })
    let result =
      if fresh {
        await resolver.resolveFresh(
          identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
          configRoot: fixture.home, surfaceID: UUID())
      } else {
        await resolver.resolve(
          identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
          configRoot: fixture.home, surfaceID: UUID())
      }
    #expect(result.isFresh)
    #expect(result.session == nil)
  }

  @Test func backgroundSelectionResetClearsRetainedIdentityBeforeRebinding() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let binding = Mutex(fixture.binding(fixture.firstID, [fixture.first]))
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in [] }, daemonBinding: { _, _, _ in binding.withLock { $0 } })
    let pane = UUID()
    let initial = await resolver.resolve(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home, surfaceID: pane)
    #expect(initial.session?.id == fixture.firstID)
    #expect(initial.session?.confidence == .exact)
    var previous = PaneAgentState(agentProcessID: fixture.tui.processIdentifier, session: initial.session)
    let transitions: [(CodexDaemonBindingLookup, String?)] = [
      (.unavailable, fixture.firstID),
      (.selectionPending, nil),
      (.selectionPending, nil),
      (fixture.binding(fixture.secondID, [fixture.second]), fixture.secondID),
    ]
    for (lookup, expected) in transitions {
      binding.withLock { $0 = lookup }
      let resolution = await resolver.resolve(
        identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
        configRoot: fixture.home, surfaceID: pane)
      let retained = PaneAgentState.retainedSession(
        resolution: resolution,
        previous: previous, identifiedPID: fixture.tui.processIdentifier)
      #expect(retained.session?.id == expected)
      if expected == nil { #expect(retained.missStreak == 0) }
      previous.session = retained.session
      previous.sessionMissStreak = retained.missStreak
    }
    #expect(previous.session?.confidence == .exact)
  }

  @MainActor
  @Test(arguments: [false, true], [false, true])
  func selectionFenceSurvivesReadFailureAndCompletedBindingMisses(exact: Bool, fresh: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try FileManager.default.removeItem(at: fixture.child)
    let text = "The old session has a unique answer that remains visible after switching."
    func append(_ text: String, to url: URL) throws {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((text + "\n").utf8))
    }
    func user(_ id: String) -> String {
      #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","client_id":"\#(id)"}}}"#
    }
    try append("{\"text\":\"\(text)\"}", to: fixture.first)
    try append(user("a"), to: fixture.first)
    // Keep fingerprint candidates unambiguous before B exists.
    try FileManager.default.removeItem(at: fixture.second)
    let pane = UUID()
    let log = CodexTUISessionLog.url(for: pane, in: fixture.directory)
    let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
    let start = "{\"ts\":\"\(timestamp)\",\"kind\":\"session_start\"}"
    let reset = "{\"ts\":\"\(timestamp)\",\"kind\":\"new_session\"}"
    func submit(_ id: String) -> String {
      "{\"ts\":\"\(timestamp)\",\"kind\":\"op\",\"payload\":{\"UserTurn\":{\"client_user_message_id\":\"\(id)\"}}}"
    }
    try Data((start + "\n" + (exact ? submit("a") + "\n" : "")).utf8).write(to: log)
    let unstable = Mutex(false)
    let inventory = Mutex<[String]?>([fixture.first.path])
    let mapper = CodexDaemonThreadMapper(
      sessionLogDirectory: fixture.directory,
      readSessionLog: { url in
        let data = try Data(contentsOf: url)
        if unstable.withLock({ $0 }) {
          var changed = data
          changed.append(32)
          try changed.write(to: url)
        }
        return data
      }, openFilePaths: { _ in inventory.withLock { $0 } })
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in [] },
      daemonBinding: { surface, process, _ in
        await mapper.bindingLookup(surfaceID: surface, daemonPID: 1, tuiStartedAt: process.startedAt)
      })
    func resolve() async -> AgentSessionResolution {
      if fresh {
        return await resolver.resolveFresh(
          identified: fixture.process, workingDirectory: fixture.directory, activeText: text,
          configRoot: fixture.home, surfaceID: pane)
      }
      return await resolver.resolve(
        identified: fixture.process, workingDirectory: fixture.directory, activeText: text,
        configRoot: fixture.home, surfaceID: pane)
    }
    let initial = await resolve()
    #expect(initial.session?.id == fixture.firstID)
    #expect(initial.session?.confidence == (exact ? .exact : .high))
    var previous = PaneAgentState(agentProcessID: fixture.tui.processIdentifier, session: initial.session)
    try append(reset, to: log)
    for failRead in [false, true, false] {
      unstable.withLock { $0 = failRead }
      try append(" ", to: log)
      let resolution = await resolve()
      #expect(resolution.session == nil)
      #expect(resolution.invalidatesRetainedSession)
      let retained = PaneAgentState.retainedSession(
        resolution: resolution, previous: previous, identifiedPID: fixture.tui.processIdentifier)
      #expect(retained.session == nil)
      previous.session = retained.session
      previous.sessionMissStreak = retained.missStreak
    }
    try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(fixture.secondID)\"}}\n".utf8)
      .write(to: fixture.second)
    try append(user("b"), to: fixture.second)
    try append(submit("b"), to: log)
    inventory.withLock { $0 = [fixture.first.path, fixture.second.path] }
    let bound = await resolve()
    #expect(bound.session?.id == fixture.secondID)
    #expect(bound.session?.confidence == .exact)
    previous.session = bound.session
    inventory.withLock { $0 = nil }
    for miss in 1...3 {
      let resolution = await resolve()
      #expect(resolution.session == nil)
      #expect(resolution.isFresh)
      #expect(!resolution.invalidatesRetainedSession)
      let retained = PaneAgentState.retainedSession(
        resolution: resolution, previous: previous, identifiedPID: fixture.tui.processIdentifier)
      #expect(retained.session?.id == (miss < 3 ? fixture.secondID : nil))
      previous.session = retained.session
      previous.sessionMissStreak = retained.missStreak
    }
    inventory.withLock { $0 = [fixture.first.path, fixture.second.path] }
    #expect(await resolve().session?.id == fixture.secondID)
    try append(reset, to: log)
    #expect(await resolve().invalidatesRetainedSession)
    let restarted = await mapper.bindingLookup(
      surfaceID: pane, daemonPID: 1, tuiStartedAt: Date().addingTimeInterval(3_600))
    if case .unavailable = restarted {} else { Issue.record("A new TUI must not inherit the old fence") }
  }

  @Test func noPaneDoesNotConsultDaemonBinding() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let resolver = AgentSessionResolver(
      tuiOpenFilePaths: { _ in [] },
      daemonBinding: { _, _, _ in
        Issue.record("A pane is required for daemon attribution")
        return .unavailable
      })
    let result = await resolver.resolveFresh(
      identified: fixture.process, workingDirectory: fixture.directory, activeText: "",
      configRoot: fixture.home)
    #expect(result.session == nil)
  }
}
