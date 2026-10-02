import Darwin
import Foundation
import Testing

@testable import supacode

struct AgentSessionResolverTests {
  @Test func parsesKnownSessionPaths() throws {
    let fixtures: [(DetectedAgent, (path: String, id: String))] = [
      (
        .codex,
        (
          "/Users/me/.codex/sessions/2026/07/11/rollout-2026-07-11T00-00-00-019f4e9e-1234-4567-89ab-0123456789ab.jsonl",
          "019f4e9e-1234-4567-89ab-0123456789ab"
        )
      ),
      (
        .claude,
        (
          "/Users/me/.claude/projects/-Users-me-App/8f43a7f5-eb10-476d-848b-b51999be23ba.jsonl",
          "8f43a7f5-eb10-476d-848b-b51999be23ba"
        )
      ),
      (
        .pi,
        (
          "/Users/me/.pi/agent/sessions/--Users-me-App--/session_019f4f1b-3650-7661-a56d-351f02f01139.jsonl",
          "019f4f1b-3650-7661-a56d-351f02f01139"
        )
      ),
      (
        .omp,
        (
          "/Users/me/.omp/agent/sessions/-Sync-github-App/"
            + "2026-08-01T12-00-00-000Z_019fa3e9-d625-7000-87d0-f3b1cfbe7d49.jsonl",
          "019fa3e9-d625-7000-87d0-f3b1cfbe7d49"
        )
      ),
      (.gemini, ("/Users/me/.gemini/tmp/app/chats/session-2fab0218.jsonl", "2fab0218")),
      (
        .cursor,
        (
          "/Users/me/.cursor/chats/project/49ebc2f9-80da-4462-b20a-030f6d1ea944/store.db",
          "49ebc2f9-80da-4462-b20a-030f6d1ea944"
        )
      ),
      (.cline, ("/Users/me/.cline/data/tasks/1778406986752/history.json", "1778406986752")),
      (
        .copilot,
        (
          "/Users/me/.copilot/session-state/49d53d20-5cde-4511-98d2-788e2def14fb/events.jsonl",
          "49d53d20-5cde-4511-98d2-788e2def14fb"
        )
      ),
      (
        .kimi,
        (
          "/Users/me/.kimi/sessions/project/e447232d-2601-4905-a943-3a4e4ac6c434/context.jsonl",
          "e447232d-2601-4905-a943-3a4e4ac6c434"
        )
      ),
      (
        .droid,
        (
          "/Users/me/.factory/sessions/-Users-me-App/02d412eb-2402-44d0-be90-faeb3f27fab6.jsonl",
          "02d412eb-2402-44d0-be90-faeb3f27fab6"
        )
      ),
      (
        .grok,
        (
          "/Users/me/.grok/sessions/%2FUsers%2Fme%2FApp/019f5e7e-4269-7e33-9eaf-d535ff8ebafb/chat_history.jsonl",
          "019f5e7e-4269-7e33-9eaf-d535ff8ebafb"
        )
      ),
      (
        .grok,
        (
          // Earlier `sessions` path component must not be used as the marker.
          "/Volumes/sessions/home/.grok/sessions/%2FUsers%2Fme%2FApp/019f5e7e-4269-7e33-9eaf-d535ff8ebafb/"
            + "chat_history.jsonl",
          "019f5e7e-4269-7e33-9eaf-d535ff8ebafb"
        )
      ),
    ]

    for (agent, expected) in fixtures {
      let parsed = try #require(AgentSessionPathParser.parse(path: expected.path, agent: agent))
      #expect(parsed.id == expected.id)
      #expect(parsed.transcriptPath?.path == expected.path)
    }
  }

  @Test func rejectsLookalikeFilesOutsideAgentStorage() {
    #expect(AgentSessionPathParser.parse(path: "/tmp/rollout-019f4e9e.jsonl", agent: .codex) == nil)
    #expect(AgentSessionPathParser.parse(path: "/tmp/session.jsonl", agent: .claude) == nil)
    #expect(AgentSessionPathParser.parse(path: "/tmp/store.db", agent: .cursor) == nil)
  }

  @Test func uniqueCandidateRejectsAmbiguityAndFilesOlderThanProcess() {
    let start = Date(timeIntervalSince1970: 1_000)
    let old = AgentSessionCandidate(
      session: AgentSession(id: "old", transcriptPath: URL(fileURLWithPath: "/tmp/old"), source: .recentFile),
      modifiedAt: Date(timeIntervalSince1970: 900)
    )
    let first = AgentSessionCandidate(
      session: AgentSession(id: "first", transcriptPath: URL(fileURLWithPath: "/tmp/first"), source: .recentFile),
      modifiedAt: Date(timeIntervalSince1970: 1_001)
    )
    let second = AgentSessionCandidate(
      session: AgentSession(id: "second", transcriptPath: URL(fileURLWithPath: "/tmp/second"), source: .recentFile),
      modifiedAt: Date(timeIntervalSince1970: 1_002)
    )

    #expect(AgentSessionCandidate.uniqueActiveCandidate([old, first], processStartedAt: start)?.session.id == "first")
    #expect(AgentSessionCandidate.uniqueActiveCandidate([first, second], processStartedAt: start) == nil)
  }

  @Test func staleSessionsExpireAfterConsecutiveMisses() {
    let session = AgentSession(id: "old", transcriptPath: nil, source: .recentFile)
    var previous = PaneAgentState(agentProcessID: 42, session: session)
    previous.sessionMissStreak = 0

    // Same process, FRESH ambiguous resolution: retained for two misses,
    // dropped on the third.
    let miss1 = PaneAgentState.retainedSession(resolved: nil, isFresh: true, previous: previous, identifiedPID: 42)
    #expect(miss1.session?.id == "old")
    #expect(miss1.missStreak == 1)
    previous.sessionMissStreak = 2
    let miss3 = PaneAgentState.retainedSession(resolved: nil, isFresh: true, previous: previous, identifiedPID: 42)
    #expect(miss3.session == nil)

    // Cached nil replayed during resolver backoff must NOT age the session:
    // only fresh resolutions count as misses.
    previous.sessionMissStreak = 2
    let replay = PaneAgentState.retainedSession(resolved: nil, isFresh: false, previous: previous, identifiedPID: 42)
    #expect(replay.session?.id == "old")
    #expect(replay.missStreak == 2)

    // Presence hold (probe returned no process): keep without aging.
    previous.sessionMissStreak = 2
    let held = PaneAgentState.retainedSession(resolved: nil, isFresh: false, previous: previous, identifiedPID: nil)
    #expect(held.session?.id == "old")
    #expect(held.missStreak == 2)

    // Fresh resolution resets the streak; new pid drops the session.
    let fresh = PaneAgentState.retainedSession(resolved: session, isFresh: true, previous: previous, identifiedPID: 42)
    #expect(fresh.missStreak == 0)
    #expect(
      PaneAgentState.retainedSession(resolved: nil, isFresh: true, previous: previous, identifiedPID: 43).session
        == nil
    )
  }

  @Test func openFilePathsExcludeReadOnlyDescriptors() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "prowl-readonly-\(UUID().uuidString).jsonl")
    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    let descriptor = open(url.path, O_RDONLY)
    #expect(descriptor >= 0)
    defer {
      close(descriptor)
      try? FileManager.default.removeItem(at: url)
    }

    let paths = ProcessDetection.openFilePaths(pid: getpid())
    #expect(!paths.contains { URL(fileURLWithPath: $0).lastPathComponent == url.lastPathComponent })
  }

  @Test func readsCurrentProcessOpenFilePaths() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "prowl-agent-session-\(UUID().uuidString).jsonl")
    FileManager.default.createFile(atPath: url.path, contents: Data())
    let descriptor = open(url.path, O_WRONLY)
    #expect(descriptor >= 0)
    defer {
      close(descriptor)
      try? FileManager.default.removeItem(at: url)
    }

    let paths = ProcessDetection.openFilePaths(pid: getpid())
    #expect(
      paths.contains { URL(fileURLWithPath: $0).lastPathComponent == url.lastPathComponent },
      "Expected \(url.lastPathComponent) in \(paths)"
    )
  }

  @Test func matchesUniqueRecentTranscriptAgainstPaneText() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-session-match-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstURL = root.appending(path: "first.jsonl")
    let secondURL = root.appending(path: "second.jsonl")
    let firstContent =
      #"{"type":"user","message":{"content":"Refactor authentication middleware without changing its API."}}"#
    try firstContent.write(to: firstURL, atomically: true, encoding: .utf8)
    try #"{"type":"user","message":{"content":"Investigate the unrelated rendering regression."}}"#
      .write(to: secondURL, atomically: true, encoding: .utf8)

    let candidates = [
      AgentSessionCandidate(
        session: AgentSession(id: "first", transcriptPath: firstURL, source: .recentFile),
        modifiedAt: .now
      ),
      AgentSessionCandidate(
        session: AgentSession(id: "second", transcriptPath: secondURL, source: .recentFile),
        modifiedAt: .now
      ),
    ]

    let match = AgentSessionFingerprintMatcher.bestMatch(
      activeText: "❯ Refactor authentication middleware without changing its API.",
      candidates: candidates
    )
    #expect(match?.session.id == "first")
  }

  @Test func rejectsTranscriptMatchWhenPaneTextIsSharedByCandidates() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-session-ambiguous-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let content = #"{"message":{"content":"Reply exactly READY and wait."}}"#
    let urls = [root.appending(path: "a.jsonl"), root.appending(path: "b.jsonl")]
    for url in urls { try content.write(to: url, atomically: true, encoding: .utf8) }
    let candidates = urls.enumerated().map { index, url in
      AgentSessionCandidate(
        session: AgentSession(id: String(index), transcriptPath: url, source: .recentFile),
        modifiedAt: .now
      )
    }

    #expect(
      AgentSessionFingerprintMatcher.bestMatch(
        activeText: "Reply exactly READY and wait.",
        candidates: candidates
      ) == nil
    )
  }
}
