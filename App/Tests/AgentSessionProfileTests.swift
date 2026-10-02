import Darwin
import Foundation
import SQLite3
import Testing

@testable import supacode

struct AgentSessionProfileTests {
  private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
  private let now = Date(timeIntervalSince1970: 1_783_800_000)

  // MARK: - Relocated config roots (docs-ai 053)

  @Test func rootedClaudeLayoutFollowsRelocatedConfigRoot() throws {
    let configRoot = URL(fileURLWithPath: "/Users/me/.prowl/agent-profiles/ABC", isDirectory: true)
    let cwd = URL(fileURLWithPath: "/tmp/repo")
    let profile = AgentSessionProfile.profile(for: .claude)

    let roots = try #require(profile.rootedCandidateRoots?(configRoot, cwd, now, now))
    #expect(roots.map(\.path) == ["/Users/me/.prowl/agent-profiles/ABC/projects/-tmp-repo"])
    #expect(profile.rootedCandidateRoots?(configRoot, nil, now, now).isEmpty == true)

    let id = "3f19a50a-2bd5-49b0-a071-1f59970ebcdf"
    let transcript = "/Users/me/.prowl/agent-profiles/ABC/projects/-tmp-repo/\(id).jsonl"
    #expect(profile.rootedParsePath?(transcript, configRoot)?.id == id)
    // The default marker cannot own a relocated path, and the rooted parser
    // must not claim files from the default home.
    #expect(profile.parsePath(transcript) == nil)
    #expect(
      profile.rootedParsePath?("/Users/me/.claude/projects/-tmp-repo/\(id).jsonl", configRoot) == nil
    )
  }

  @Test func rootedCodexLayoutFollowsRelocatedConfigRoot() throws {
    let configRoot = URL(fileURLWithPath: "/Users/me/.prowl/agent-profiles/ABC", isDirectory: true)
    let profile = AgentSessionProfile.profile(for: .codex)

    let fallback = try #require(profile.rootedFallbackRoots?(configRoot, nil))
    #expect(fallback.map(\.path) == ["/Users/me/.prowl/agent-profiles/ABC/sessions"])
    let dayRoots = try #require(profile.rootedCandidateRoots?(configRoot, nil, now, now))
    #expect(dayRoots.allSatisfy { $0.path.hasPrefix("/Users/me/.prowl/agent-profiles/ABC/sessions/") })

    let id = "019fadfd-9ecd-7b71-b849-70fd53ee7231"
    let rollout =
      "/Users/me/.prowl/agent-profiles/ABC/sessions/2026/07/29/rollout-2026-07-29T22-08-27-\(id).jsonl"
    #expect(profile.rootedParsePath?(rollout, configRoot)?.id == id)
    #expect(profile.parsePath(rollout) == nil)
    #expect(
      profile.rootedParsePath?(
        "/Users/me/.codex/sessions/2026/07/29/rollout-2026-07-29T22-08-27-\(id).jsonl",
        configRoot
      ) == nil
    )
  }

  @Test func additionalAccountBoundRuntimesDefineRootedSessionLayouts() throws {
    let root = URL(fileURLWithPath: "/Users/me/.prowl/agent-profiles/ABC", isDirectory: true)
    let cwd = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let uuid = "3f19a50a-2bd5-49b0-a071-1f59970ebcdf"

    let gemini = AgentSessionProfile.profile(for: .gemini)
    let geminiRoots = try #require(gemini.rootedCandidateRoots?(root, cwd, now, now))
    #expect(
      geminiRoots.last?.path
        == "\(root.path)/tmp/b6fe87a9b936bea650481980f473639b9dd1934ddab7f48221cd6b9ab5ffc1f4/chats")
    #expect(
      gemini.rootedParsePath?("\(root.path)/tmp/project/chats/session-2026-08-01-3f19a50a.jsonl", root)?.id
        == "3f19a50a"
    )

    let cline = AgentSessionProfile.profile(for: .cline)
    #expect(cline.rootedCandidateRoots?(root, cwd, now, now).map(\.path) == ["\(root.path)/tasks"])
    #expect(cline.rootedParsePath?("\(root.path)/tasks/1783800000000/events.jsonl", root)?.id == "1783800000000")
    let clineRootWithMarkerAncestor = URL(fileURLWithPath: "/Users/tasks/agent-profile/data", isDirectory: true)
    #expect(
      cline.rootedParsePath?(
        "\(clineRootWithMarkerAncestor.path)/tasks/1783800000001/events.jsonl",
        clineRootWithMarkerAncestor
      )?.id == "1783800000001"
    )

    let piProfile = AgentSessionProfile.profile(for: .pi)
    #expect(piProfile.rootedCandidateRoots?(root, cwd, now, now).map(\.path) == ["\(root.path)/sessions/--tmp-repo--"])
    #expect(piProfile.rootedParsePath?("\(root.path)/sessions/--tmp-repo--/\(uuid).jsonl", root)?.id == uuid)

    let ompProfile = AgentSessionProfile.profile(for: .omp)
    #expect(ompProfile.rootedCandidateRoots?(root, cwd, now, now).map(\.path) == ["\(root.path)/sessions/--tmp-repo--"])
    #expect(
      ompProfile.rootedParsePath?("\(root.path)/sessions/--tmp-repo--/2026-08-01T12-00-00-000Z_\(uuid).jsonl", root)?.id
        == uuid
    )

    let copilot = AgentSessionProfile.profile(for: .copilot)
    #expect(copilot.rootedCandidateRoots?(root, cwd, now, now).map(\.path) == ["\(root.path)/session-state"])
    #expect(copilot.rootedParsePath?("\(root.path)/session-state/\(uuid)/events.jsonl", root)?.id == uuid)
    #expect(copilot.rootedPIDKeyedSession != nil)

    let qoder = AgentSessionProfile.profile(for: .qoder)
    #expect(qoder.rootedCandidateRoots?(root, cwd, now, now).map(\.path) == ["\(root.path)/projects/-tmp-repo"])
    #expect(qoder.rootedParsePath?("\(root.path)/projects/-tmp-repo/\(uuid).jsonl", root)?.id == uuid)

    let qwen = AgentSessionProfile.profile(for: .qwen)
    #expect(qwen.rootedCandidateRoots?(root, cwd, now, now).map(\.path) == ["\(root.path)/projects/-tmp-repo/chats"])
    #expect(qwen.rootedParsePath?("\(root.path)/projects/-tmp-repo/chats/\(uuid).jsonl", root)?.id == uuid)
    #expect(qwen.rootedPIDKeyedSession != nil)
  }

  // MARK: - Working-directory encoders

  @Test func claudeRootSanitizesEveryNonAlphanumericCharacter() {
    let roots = AgentSessionProfile.profile(for: .claude).candidateRoots(
      home,
      URL(fileURLWithPath: "/private/tmp/prowl_556.enc", isDirectory: true),
      now,
      now
    )
    #expect(roots.map(\.path) == ["/Users/me/.claude/projects/-private-tmp-prowl-556-enc"])
  }

  @Test func claudeRootMatchesJavaScriptCodeUnitSemantics() {
    // Claude Code replaces per UTF-16 code unit: a surrogate-pair emoji
    // becomes TWO dashes. Observed live: /private/tmp/prowl556-review-🐱-café
    // → -private-tmp-prowl556-review----caf-
    let roots = AgentSessionProfile.profile(for: .claude).candidateRoots(
      home,
      URL(fileURLWithPath: "/private/tmp/prowl556-review-🐱-café", isDirectory: true),
      now,
      now
    )
    #expect(roots.map(\.path) == ["/Users/me/.claude/projects/-private-tmp-prowl556-review----caf-"])
  }

  @Test func qoderReusesClaudeLayoutUnderQoderRoot() {
    // Verified against Qoder CLI 1.0.48: ~/.qoder/projects/<sanitized cwd>/<uuid>.jsonl.
    let profile = AgentSessionProfile.profile(for: .qoder)
    let cwd = URL(fileURLWithPath: "/Users/me/Sync/github/Prowl", isDirectory: true)
    #expect(
      profile.candidateRoots(home, cwd, now, now).map(\.path)
        == ["/Users/me/.qoder/projects/-Users-me-Sync-github-Prowl"]
    )
    #expect(profile.candidateRoots(home, nil, now, now).isEmpty)
    let id = "40e2d9c9-dca4-4969-a9a0-56fb423e58e6"
    let path = "/Users/me/.qoder/projects/-Users-me-Sync-github-Prowl/\(id).jsonl"
    let parsed = profile.parsePath(path)
    #expect(parsed?.id == id)
    #expect(parsed?.transcriptPath?.path == path)
    // Sibling checkpoint directories and foreign roots must not parse.
    #expect(profile.parsePath("/Users/me/.qoder/projects/-Users-me-Sync-github-Prowl/\(id)") == nil)
    #expect(profile.parsePath("/Users/me/.claude/projects/-Users-me-Sync-github-Prowl/\(id).jsonl") == nil)
  }

  @Test func piOmpAndDroidUseIndependentSessionLayouts() {
    let cwd = URL(fileURLWithPath: "/Users/me/.prowl/repos/My App", isDirectory: true)
    let piRoots = AgentSessionProfile.profile(for: .pi).candidateRoots(home, cwd, now, now)
    #expect(piRoots.map(\.path) == ["/Users/me/.pi/agent/sessions/--Users-me-.prowl-repos-My App--"])
    let ompRoots = AgentSessionProfile.profile(for: .omp).candidateRoots(home, cwd, now, now)
    #expect(ompRoots.map(\.path) == ["/Users/me/.omp/agent/sessions/-.prowl-repos-My App"])
    let droidRoots = AgentSessionProfile.profile(for: .droid).candidateRoots(home, cwd, now, now)
    #expect(droidRoots.map(\.path) == ["/Users/me/.factory/sessions/-Users-me-.prowl-repos-My App"])
  }

  // MARK: - Candidate-root narrowing

  @Test func codexRootsNarrowToProcessLifetimeDays() {
    let calendar = Calendar.current
    let processStartedAt = calendar.date(byAdding: .day, value: -2, to: now)!
    let roots = AgentSessionProfile.profile(for: .codex).candidateRoots(home, nil, processStartedAt, now)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    let expected = (0...3).map { offset in
      let day = calendar.date(byAdding: .day, value: -offset, to: now)!
      return "/Users/me/.codex/sessions/\(formatter.string(from: day))"
    }
    #expect(Set(roots.map(\.path)) == Set(expected))
    let fallback = AgentSessionProfile.profile(for: .codex).fallbackRoots(home, nil)
    #expect(fallback.map(\.path) == ["/Users/me/.codex/sessions"])
  }

  @Test func kimiAndCursorRootsUseMD5OfWorkingDirectory() {
    let cwd = URL(fileURLWithPath: "/Users/onevcat/Sync/github/Prowl", isDirectory: true)
    let hash = "62c1e94d156560ededc10a672654f7ad"
    let kimi = AgentSessionProfile.profile(for: .kimi)
    #expect(kimi.candidateRoots(home, cwd, now, now).map(\.path) == ["/Users/me/.kimi/sessions/\(hash)"])
    #expect(kimi.fallbackRoots(home, cwd).map(\.path) == ["/Users/me/.kimi/sessions"])
    let cursor = AgentSessionProfile.profile(for: .cursor)
    #expect(cursor.candidateRoots(home, cwd, now, now).map(\.path) == ["/Users/me/.cursor/chats/\(hash)"])
    #expect(cursor.fallbackRoots(home, cwd).map(\.path) == ["/Users/me/.cursor/chats"])
  }

  @Test func geminiRootsPreferProjectsJSONSlugAndHash() throws {
    let temporaryHome = FileManager.default.temporaryDirectory
      .appending(path: "prowl-gemini-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryHome.appending(path: ".gemini"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryHome) }
    let cwd = URL(fileURLWithPath: "/Users/onevcat/Sync/github/Prowl", isDirectory: true)
    try #"{"projects": {"/Users/onevcat/Sync/github/Prowl": "prowl"}}"#
      .write(to: temporaryHome.appending(path: ".gemini/projects.json"), atomically: true, encoding: .utf8)

    let roots = AgentSessionProfile.profile(for: .gemini).candidateRoots(temporaryHome, cwd, now, now)
    let paths = Set(roots.map(\.path))
    let sha = "a165a63702653924c088535c5594c435580d1ddeaf52f638d8a1fa830adf95e0"
    #expect(paths.contains(temporaryHome.appending(path: ".gemini/tmp/prowl/chats").path))
    #expect(paths.contains(temporaryHome.appending(path: ".gemini/tmp/\(sha)/chats").path))
    let fallback = AgentSessionProfile.profile(for: .gemini).fallbackRoots(temporaryHome, cwd)
    #expect(fallback.map(\.path) == [temporaryHome.appending(path: ".gemini/tmp").path])
  }

  // MARK: - Session-id grouping

  @Test func uniqueActiveCandidateAcceptsMultipleFilesOfOneSession() {
    let start = Date(timeIntervalSince1970: 1_000)
    let files = ["context.jsonl", "wire.jsonl", "state.json"].enumerated().map { index, name in
      AgentSessionCandidate(
        session: AgentSession(
          id: "fe8b1447",
          transcriptPath: URL(fileURLWithPath: "/tmp/session/\(name)"),
          source: .recentFile
        ),
        modifiedAt: Date(timeIntervalSince1970: 1_001 + TimeInterval(index))
      )
    }
    let unique = AgentSessionCandidate.uniqueActiveCandidate(files, processStartedAt: start)
    #expect(unique?.session.id == "fe8b1447")
    #expect(unique?.modifiedAt == Date(timeIntervalSince1970: 1_003))
  }

  @Test func fingerprintDoesNotApplyMarginBetweenFilesOfOneSession() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-same-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let content = #"{"message":{"content":"Refactor the authentication middleware without changing its API."}}"#
    let urls = [root.appending(path: "context.jsonl"), root.appending(path: "wire.jsonl")]
    for url in urls { try content.write(to: url, atomically: true, encoding: .utf8) }
    let candidates = urls.map { url in
      AgentSessionCandidate(
        session: AgentSession(id: "same-session", transcriptPath: url, source: .recentFile),
        modifiedAt: .now
      )
    }

    let match = AgentSessionFingerprintMatcher.bestMatch(
      activeText: "❯ Refactor the authentication middleware without changing its API.",
      candidates: candidates
    )
    #expect(match?.session.id == "same-session")
  }

  @Test func fingerprintCapCannotEvictACompetingSession() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let content = #"{"message":{"content":"Reply exactly READY and wait for further instructions."}}"#

    // Session A floods the recency window with 20 files; session B has one
    // older file with the same on-screen text. B must still veto uniqueness.
    var candidates: [AgentSessionCandidate] = []
    for index in 0..<20 {
      let url = root.appending(path: "a-\(index).jsonl")
      try content.write(to: url, atomically: true, encoding: .utf8)
      candidates.append(
        AgentSessionCandidate(
          session: AgentSession(id: "session-a", transcriptPath: url, source: .recentFile),
          modifiedAt: Date(timeIntervalSince1970: 2_000 + TimeInterval(index))
        )
      )
    }
    let bURL = root.appending(path: "b.jsonl")
    try content.write(to: bURL, atomically: true, encoding: .utf8)
    candidates.append(
      AgentSessionCandidate(
        session: AgentSession(id: "session-b", transcriptPath: bURL, source: .recentFile),
        modifiedAt: Date(timeIntervalSince1970: 1_000)
      )
    )

    let match = AgentSessionFingerprintMatcher.bestMatch(
      activeText: "Reply exactly READY and wait for further instructions.",
      candidates: candidates
    )
    #expect(match == nil)
  }

  @Test func fingerprintRefusesUniquenessBeyondSessionBudget() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-many-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let unique = root.appending(path: "match.jsonl")
    try #"{"message":{"content":"An unmistakably distinctive fingerprint phrase."}}"#
      .write(to: unique, atomically: true, encoding: .utf8)
    var candidates = [
      AgentSessionCandidate(
        session: AgentSession(id: "target", transcriptPath: unique, source: .recentFile),
        modifiedAt: Date(timeIntervalSince1970: 5_000)
      )
    ]
    for index in 0..<13 {
      let url = root.appending(path: "other-\(index).jsonl")
      try #"{"message":{"content":"irrelevant"}}"#.write(to: url, atomically: true, encoding: .utf8)
      candidates.append(
        AgentSessionCandidate(
          session: AgentSession(id: "other-\(index)", transcriptPath: url, source: .recentFile),
          modifiedAt: Date(timeIntervalSince1970: 4_000 - TimeInterval(index))
        )
      )
    }

    // 14 distinct sessions exceed the read budget; uniqueness cannot be
    // proven, so no match may be declared.
    let match = AgentSessionFingerprintMatcher.bestMatch(
      activeText: "An unmistakably distinctive fingerprint phrase.",
      candidates: candidates
    )
    #expect(match == nil)
  }

  @Test func fingerprintRefusesWhenACompetitorIsUnscoreable() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-unscoreable-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Session A scores against the screen; session B's transcript yields no
    // comparable text at all (Cline-style oversized single-line JSON whose
    // tail is a truncated fragment). B might be the real session, so no
    // high-confidence uniqueness may be declared.
    let aURL = root.appending(path: "a.jsonl")
    try #"{"message":{"content":"Shared prompt visible on both panes right now."}}"#
      .write(to: aURL, atomically: true, encoding: .utf8)
    let bURL = root.appending(path: "b.json")
    try #""tail_fragment_of_a_huge_single_line_json":true}]}"#
      .write(to: bURL, atomically: true, encoding: .utf8)
    let candidates = [
      AgentSessionCandidate(
        session: AgentSession(id: "session-a", transcriptPath: aURL, source: .recentFile),
        modifiedAt: Date(timeIntervalSince1970: 2_000)
      ),
      AgentSessionCandidate(
        session: AgentSession(id: "session-b", transcriptPath: bURL, source: .recentFile),
        modifiedAt: Date(timeIntervalSince1970: 2_001)
      ),
    ]

    let match = AgentSessionFingerprintMatcher.bestMatch(
      activeText: "Shared prompt visible on both panes right now.",
      candidates: candidates
    )
    #expect(match == nil)
  }

  @Test func fingerprintRefusesWhenACompetitorHasOnlyShortFragments() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-short-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Session B parses cleanly but only yields fragments below the 12-char
    // comparison floor ("OK"): it never actually testified, so it must block
    // uniqueness exactly like an unreadable session.
    let aURL = root.appending(path: "a.jsonl")
    try #"{"message":{"content":"Shared prompt visible on both panes right now."}}"#
      .write(to: aURL, atomically: true, encoding: .utf8)
    let bURL = root.appending(path: "b.jsonl")
    try #"{"message":{"content":"OK"}}"#.write(to: bURL, atomically: true, encoding: .utf8)
    let candidates = [
      AgentSessionCandidate(
        session: AgentSession(id: "session-a", transcriptPath: aURL, source: .recentFile),
        modifiedAt: Date(timeIntervalSince1970: 2_000)
      ),
      AgentSessionCandidate(
        session: AgentSession(id: "session-b", transcriptPath: bURL, source: .recentFile),
        modifiedAt: Date(timeIntervalSince1970: 2_001)
      ),
    ]

    let match = AgentSessionFingerprintMatcher.bestMatch(
      activeText: "Shared prompt visible on both panes right now.",
      candidates: candidates
    )
    #expect(match == nil)
  }

  @Test func fingerprintSurvivesTailCutInsideMultibyteCharacter() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-utf8-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A transcript larger than the 128 KiB tail window whose cut point lands
    // inside a multi-byte character: lossy decoding must keep the intact
    // trailing lines scoreable instead of voiding the whole tail.
    let filler = #"{"message":{"content":"\#(String(repeating: "汉", count: 44_000))"}}"#
    let match = #"{"message":{"content":"A perfectly distinctive closing message for this pane."}}"#
    let url = root.appending(path: "big.jsonl")
    try (filler + "\n" + match).write(to: url, atomically: true, encoding: .utf8)

    let result = AgentSessionFingerprintMatcher.bestMatch(
      activeText: "A perfectly distinctive closing message for this pane.",
      candidates: [
        AgentSessionCandidate(
          session: AgentSession(id: "big", transcriptPath: url, source: .recentFile),
          modifiedAt: .now
        )
      ]
    )
    #expect(result?.session.id == "big")
  }

  // MARK: - Header enrichment stays per-profile

  @Test func headerEnrichmentNeverOverridesDirectoryDerivedIDs() throws {
    // Copilot-style layout: the directory name is the session id and the
    // event stream is a JSONL whose first line may carry unrelated ids.
    // Generic header sniffing once replaced the correct id with such a field.
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-copilot-header-\(UUID().uuidString)", directoryHint: .isDirectory)
    let id = "50b5bd49-d8e8-4ee9-9bae-4eaae5c0bdd8"
    let sessionDir = root.appending(path: ".copilot/session-state/\(id)")
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #"{"type":"event","id":"99999999-aaaa-bbbb-cccc-dddddddddddd","sessionId":"not-this-one"}"#
      .write(to: sessionDir.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)

    let profile = AgentSessionProfile.profile(for: .copilot)
    let parsed = try #require(profile.parsePath(sessionDir.appending(path: "events.jsonl").path))
    #expect(parsed.id == id)
    #expect(profile.headerSessionIDKeys.isEmpty)
  }

  @Test func geminiHeaderKeysExpandTruncatedFilenameID() {
    // Gemini filenames only carry the first 8 id characters; the header's
    // sessionId is the full uuid, so gemini opts in to enrichment.
    #expect(AgentSessionProfile.profile(for: .gemini).headerSessionIDKeys == ["sessionId"])
    #expect(AgentSessionProfile.profile(for: .claude).headerSessionIDKeys.isEmpty)
    #expect(AgentSessionProfile.profile(for: .kimi).headerSessionIDKeys.isEmpty)
  }

  // MARK: - Pid-keyed artifacts

  @Test func copilotProcessLogYieldsRegisteredSession() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-copilot-\(UUID().uuidString)", directoryHint: .isDirectory)
    let logs = root.appending(path: "logs")
    let state = root.appending(path: "session-state")
    let id = "e7f43538-26a4-4dfd-a4af-06427bc9d69d"
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state.appending(path: id), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: state.appending(path: "\(id)/events.jsonl").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: root) }
    let log = """
      2026-07-11T02:58:34.100Z [INFO] Registering foreground session: 11111111-2222-3333-4444-555555555555
      2026-07-11T02:58:34.500Z [INFO] Unregistering foreground session: 11111111-2222-3333-4444-555555555555
      2026-07-11T02:58:34.928Z [INFO] Registering foreground session: \(id)
      """
    try log.write(to: logs.appending(path: "process-1783748855136-4242.log"), atomically: true, encoding: .utf8)

    let session = CopilotProcessLog.session(
      logsDirectory: logs,
      sessionStateDirectory: state,
      pid: 4242,
      processStartedAt: .now.addingTimeInterval(-60)
    )
    #expect(session?.id == id)
    #expect(session?.source == .processLog)
    #expect(session?.confidence == .exact)
    #expect(session?.transcriptPath?.path == state.appending(path: "\(id)/events.jsonl").path)

    let mismatch = CopilotProcessLog.session(
      logsDirectory: logs,
      sessionStateDirectory: state,
      pid: 9999,
      processStartedAt: .now.addingTimeInterval(-60)
    )
    #expect(mismatch == nil)
  }

  @Test func qwenRuntimeSidecarYieldsPidMatchedSession() throws {
    let projects = FileManager.default.temporaryDirectory
      .appending(path: "prowl-qwen-\(UUID().uuidString)", directoryHint: .isDirectory)
    let chats = projects.appending(path: "-Users-me-App/chats")
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: projects) }
    let processStartedAt = Date(timeIntervalSince1970: 1_783_800_000)
    let id = "019f4f1b-3650-7661-a56d-351f02f01139"
    try sidecarJSON(id: id, pid: 555, startedAt: processStartedAt.timeIntervalSince1970 + 5)
      .write(to: chats.appending(path: "\(id).runtime.json"), atomically: true, encoding: .utf8)
    try "{}".write(to: chats.appending(path: "\(id).jsonl"), atomically: true, encoding: .utf8)

    let session = QwenRuntimeStatus.session(projectsRoot: projects, pid: 555, processStartedAt: processStartedAt)
    #expect(session?.id == id)
    #expect(session?.source == .processLog)
    #expect(session?.confidence == .exact)
    // contentsOfDirectory resolves the /var → /private/var symlink; align both sides.
    #expect(
      session?.transcriptPath?.resolvingSymlinksInPath()
        == chats.appending(path: "\(id).jsonl").resolvingSymlinksInPath()
    )
    #expect(QwenRuntimeStatus.session(projectsRoot: projects, pid: 556, processStartedAt: processStartedAt) == nil)
  }

  @Test func qwenRuntimeSidecarRejectsStaleClaimsFromReusedPids() throws {
    let projects = FileManager.default.temporaryDirectory
      .appending(path: "prowl-qwen-stale-\(UUID().uuidString)", directoryHint: .isDirectory)
    let chats = projects.appending(path: "-Users-me-App/chats")
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: projects) }
    let processStartedAt = Date(timeIntervalSince1970: 1_783_800_000)

    // Sidecars survive quit/crash; a claim older than the live process's start
    // time belongs to a previous owner of the reused pid.
    let stale = "11111111-2222-3333-4444-555555555555"
    try sidecarJSON(id: stale, pid: 555, startedAt: processStartedAt.timeIntervalSince1970 - 3_600)
      .write(to: chats.appending(path: "\(stale).runtime.json"), atomically: true, encoding: .utf8)
    #expect(QwenRuntimeStatus.session(projectsRoot: projects, pid: 555, processStartedAt: processStartedAt) == nil)

    // Unknown schema versions are not ours to interpret.
    let futuristic = "66666666-7777-8888-9999-000000000000"
    try sidecarJSON(id: futuristic, pid: 555, startedAt: processStartedAt.timeIntervalSince1970 + 5, schema: 2)
      .write(to: chats.appending(path: "\(futuristic).runtime.json"), atomically: true, encoding: .utf8)
    #expect(QwenRuntimeStatus.session(projectsRoot: projects, pid: 555, processStartedAt: processStartedAt) == nil)
  }

  private func sidecarJSON(id: String, pid: Int, startedAt: TimeInterval, schema: Int = 1) -> String {
    #"{"schema_version":\#(schema),"pid":\#(pid),"session_id":"\#(id)","work_dir":"/Users/me/App","#
      + #""hostname":"test","started_at":\#(startedAt),"qwen_version":"0.23.0"}"#
  }

  @Test func qwenRootsNarrowToSanitizedProjectDirectory() {
    let cwd = URL(fileURLWithPath: "/private/tmp/prowl_556.enc", isDirectory: true)
    let qwen = AgentSessionProfile.profile(for: .qwen)
    #expect(
      qwen.candidateRoots(home, cwd, now, now).map(\.path)
        == ["/Users/me/.qwen/projects/-private-tmp-prowl-556-enc/chats"]
    )
    #expect(qwen.fallbackRoots(home, cwd).map(\.path) == ["/Users/me/.qwen/projects"])
  }

  @Test func grokActiveSessionsYieldsPidMatchedSession() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-grok-\(UUID().uuidString)", directoryHint: .isDirectory)
    let id = "019f5e7e-4269-7e33-9eaf-d535ff8ebafb"
    let cwd = "/Users/me/App"
    let encoded = "%2FUsers%2Fme%2FApp"
    let sessionDir = root.appending(path: ".grok/sessions/\(encoded)/\(id)")
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "{}".write(to: sessionDir.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
    let processStartedAt = Date(timeIntervalSince1970: 1_783_800_000)
    let payload = """
      [
        {
          "session_id": "\(id)",
          "pid": 4242,
          "cwd": "\(cwd)",
          "opened_at": "2026-07-14T02:39:21.306116Z"
        }
      ]
      """
    try payload.write(
      to: root.appending(path: ".grok/active_sessions.json"),
      atomically: true,
      encoding: .utf8
    )

    let session = GrokActiveSessions.session(
      home: root,
      pid: 4242,
      processStartedAt: processStartedAt
    )
    #expect(session?.id == id)
    #expect(session?.source == .processLog)
    #expect(session?.confidence == .exact)
    // Only events.jsonl exists — the transcript falls back to it.
    #expect(
      session?.transcriptPath?.resolvingSymlinksInPath()
        == sessionDir.appending(path: "events.jsonl").resolvingSymlinksInPath()
    )
    #expect(GrokActiveSessions.session(home: root, pid: 9999, processStartedAt: processStartedAt) == nil)

    // chat_history.jsonl is the conversation log; prefer it once present.
    try "{}".write(to: sessionDir.appending(path: "chat_history.jsonl"), atomically: true, encoding: .utf8)
    let refreshed = GrokActiveSessions.session(
      home: root,
      pid: 4242,
      processStartedAt: processStartedAt
    )
    #expect(
      refreshed?.transcriptPath?.resolvingSymlinksInPath()
        == sessionDir.appending(path: "chat_history.jsonl").resolvingSymlinksInPath()
    )
  }

  @Test func grokActiveSessionsRejectsStaleClaimsFromReusedPids() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-grok-stale-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: ".grok"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let processStartedAt = Date(timeIntervalSince1970: 1_783_800_000)
    let payload = """
      [
        {
          "session_id": "11111111-2222-3333-4444-555555555555",
          "pid": 4242,
          "cwd": "/Users/me/App",
          "opened_at": "2026-07-01T00:00:00.000000Z"
        }
      ]
      """
    try payload.write(
      to: root.appending(path: ".grok/active_sessions.json"),
      atomically: true,
      encoding: .utf8
    )
    #expect(GrokActiveSessions.session(home: root, pid: 4242, processStartedAt: processStartedAt) == nil)
  }

  @Test func grokActiveSessionsRejectsMissingOrUnparseableOpenedAt() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-grok-opened-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: ".grok"),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let processStartedAt = Date(timeIntervalSince1970: 1_783_800_000)

    try """
    [{"session_id":"11111111-2222-3333-4444-555555555555","pid":4242,"cwd":"/Users/me/App"}]
    """.write(to: root.appending(path: ".grok/active_sessions.json"), atomically: true, encoding: .utf8)
    #expect(GrokActiveSessions.session(home: root, pid: 4242, processStartedAt: processStartedAt) == nil)

    try """
    [{"session_id":"11111111-2222-3333-4444-555555555555","pid":4242,"cwd":"/Users/me/App","opened_at":"not-a-date"}]
    """.write(to: root.appending(path: ".grok/active_sessions.json"), atomically: true, encoding: .utf8)
    #expect(GrokActiveSessions.session(home: root, pid: 4242, processStartedAt: processStartedAt) == nil)
  }

  @Test func grokRootsUsePercentEncodedWorkingDirectory() {
    let cwd = URL(fileURLWithPath: "/Users/me/My App", isDirectory: true)
    let grok = AgentSessionProfile.profile(for: .grok)
    #expect(
      grok.candidateRoots(home, cwd, now, now).map(\.path)
        == ["/Users/me/.grok/sessions/%2FUsers%2Fme%2FMy%20App"]
    )
    #expect(grok.fallbackRoots(home, cwd).map(\.path) == ["/Users/me/.grok/sessions"])
  }

  @Test func grokParsePathResolvesSessionDirectoryFromNestedFiles() {
    let profile = AgentSessionProfile.profile(for: .grok)
    let id = "019f5e7e-4269-7e33-9eaf-d535ff8ebafb"
    // The parser must never claim a transcript path that does not exist.
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-grok-parse-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sessionDir = root.appending(path: ".grok/sessions/%2FUsers%2Fme%2FApp/\(id)")
    try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try? "{}".write(to: sessionDir.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)

    let parsedEvents = profile.parsePath(sessionDir.appending(path: "events.jsonl").path)
    #expect(parsedEvents?.id == id)
    // Before chat history exists, the opened events log is the only known log.
    #expect(parsedEvents?.transcriptPath?.lastPathComponent == "events.jsonl")

    try? FileManager.default.createDirectory(
      at: sessionDir.appending(path: "terminal"),
      withIntermediateDirectories: true
    )
    let nestedPath = sessionDir.appending(path: "terminal/call-1.log").path
    FileManager.default.createFile(atPath: nestedPath, contents: Data())
    let parsedNested = profile.parsePath(nestedPath)
    #expect(parsedNested?.id == id)
    // An arbitrary nested file identifies the session but is not itself a session log.
    #expect(parsedNested?.transcriptPath == nil)

    let chatHistory = sessionDir.appending(path: "chat_history.jsonl")
    try? "{}".write(to: chatHistory, atomically: true, encoding: .utf8)
    let parsedAfterChat = profile.parsePath(nestedPath)
    #expect(parsedAfterChat?.transcriptPath?.path == chatHistory.path)

    #expect(profile.parsePath("/Users/me/.grok/sessions/%2FUsers%2Fme%2FApp/not-a-uuid/events.jsonl") == nil)
  }

  @Test func grokParsePathAnchorsOnDotGrokSessionsNotEarlierSessionsComponent() {
    let profile = AgentSessionProfile.profile(for: .grok)
    let id = "019f5e7e-4269-7e33-9eaf-d535ff8ebafb"
    // An earlier `sessions` path component must not steal the index.
    let path =
      "/Volumes/sessions/home/.grok/sessions/%2FUsers%2Fme%2FApp/\(id)/events.jsonl"
    #expect(profile.parsePath(path)?.id == id)

    // An earlier unrelated `.grok` component must also be skipped.
    let earlierDotGrok =
      "/Volumes/.grok/home/.grok/sessions/%2FUsers%2Fme%2FApp/\(id)/events.jsonl"
    #expect(profile.parsePath(earlierDotGrok)?.id == id)
  }

  @Test func geminiParsePathRequiresSessionPrefix() {
    let profile = AgentSessionProfile.profile(for: .gemini)
    #expect(profile.parsePath("/Users/me/.gemini/tmp/prowl/chats/session-2026-07-11T05-41-2fab0218.jsonl") != nil)
    #expect(profile.parsePath("/Users/me/.gemini/tmp/prowl/chats/notes-2026-07-11.jsonl") == nil)
  }

  @Test func headerEnrichmentUpgradesTruncatedGeminiID() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-header-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appending(path: "session-2026-07-11T05-41-23ce3e98.jsonl")
    try #"{"sessionId":"23ce3e98-af90-4d5c-8b83-ffcc258dff2b","projectHash":"x"}"#
      .write(to: transcript, atomically: true, encoding: .utf8)

    #expect(
      AgentSessionResolver.sessionIDFromHeader(at: transcript, keys: ["sessionId"])
        == "23ce3e98-af90-4d5c-8b83-ffcc258dff2b"
    )
    // Empty key list (every agent except gemini) never reads the file.
    #expect(AgentSessionResolver.sessionIDFromHeader(at: transcript, keys: []) == nil)
    // Oversized first lines fall back to the filename-derived id.
    let huge = root.appending(path: "huge.jsonl")
    try (#"{"sessionId":""# + String(repeating: "x", count: 9_000) + #""}"#)
      .write(to: huge, atomically: true, encoding: .utf8)
    #expect(AgentSessionResolver.sessionIDFromHeader(at: huge, keys: ["sessionId"]) == nil)
  }

  @Test func truncatedScansYieldNoCandidates() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-truncate-\(UUID().uuidString)/.claude/projects/-tmp-x", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<5 {
      try "{}".write(
        to: root.appending(path: "0000000\(index)-1111-2222-3333-444444444444.jsonl"),
        atomically: true,
        encoding: .utf8
      )
    }
    let resolver = AgentSessionResolver()
    let profile = AgentSessionProfile.profile(for: .claude)
    let full = await resolver.scanCandidates(in: [root], profile: profile, processStartedAt: .distantPast)
    #expect(full?.count == 5)
    // A truncated enumeration cannot prove uniqueness; the whole scan is void.
    let truncated = await resolver.scanCandidates(
      in: [root],
      profile: profile,
      processStartedAt: .distantPast,
      visitLimit: 3
    )
    #expect(truncated == nil)
  }

  @Test func geminiCandidatesRequireSuccessfulHeaderEnrichment() async throws {
    let chats = FileManager.default.temporaryDirectory
      .appending(path: "prowl-gemini-req-\(UUID().uuidString)/.gemini/tmp/proj/chats", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: chats) }
    try #"{"sessionId":"23ce3e98-af90-4d5c-8b83-ffcc258dff2b"}"#
      .write(to: chats.appending(path: "session-2026-07-11T05-41-23ce3e98.jsonl"), atomically: true, encoding: .utf8)
    try "not json at all"
      .write(to: chats.appending(path: "session-2026-07-11T05-42-6827d721.jsonl"), atomically: true, encoding: .utf8)

    let resolver = AgentSessionResolver()
    let profile = AgentSessionProfile.profile(for: .gemini)
    let candidates = await resolver.scanCandidates(in: [chats], profile: profile, processStartedAt: .distantPast)
    // The corrupt header must drop its file rather than surface a truncated
    // 8-hex id that cannot be resumed.
    #expect(candidates?.map(\.session.id) == ["23ce3e98-af90-4d5c-8b83-ffcc258dff2b"])
  }

  @Test func truncatedPrimaryScanSkipsFallbackEntirely() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-trunc-fb-\(UUID().uuidString)", directoryHint: .isDirectory)
    let primaryDir = root.appending(path: "primary")
    let fallbackDir = root.appending(path: "fallback")
    try FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Primary trips the visit limit; the fallback holds ONE cleanly parsable
    // session below the limit. If a truncated primary scan wrongly proceeded
    // to the fallback, this candidate would surface — the assertion below
    // would catch it.
    for index in 0..<4 {
      try "{}".write(
        to: primaryDir.appending(path: "0000000\(index)-1111-2222-3333-444444444444.jsonl"),
        atomically: true,
        encoding: .utf8
      )
    }
    try "{}".write(
      to: fallbackDir.appending(path: "99999999-1111-2222-3333-444444444444.jsonl"),
      atomically: true,
      encoding: .utf8
    )
    let profile = AgentSessionProfile(
      parsePath: { path in
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "jsonl" else { return nil }
        return AgentSession(
          id: url.deletingPathExtension().lastPathComponent,
          transcriptPath: url,
          source: .recentFile
        )
      },
      candidateRoots: { _, _, _, _ in [primaryDir] },
      fallbackRoots: { _, _ in [fallbackDir] }
    )

    let resolver = AgentSessionResolver()
    let result = await resolver.recentCandidates(
      profile: profile,
      processStartedAt: .distantPast,
      workingDirectory: nil,
      now: .now,
      visitLimit: 3
    )
    #expect(result.candidates.isEmpty)
    #expect(result.usedWideScan)
  }

  @Test func unresolvedStreakResetsWhenAResolvedSessionTurnsAmbiguous() {
    // resolved → ambiguous starts a NEW unresolved episode at streak 0 so the
    // first retry keeps the documented 1 s / 8 s pacing (e.g. right after
    // /clear); only consecutive unresolved results escalate.
    #expect(
      AgentSessionResolver.nextUnresolvedStreak(resolvedNow: true, previousWasUnresolved: false, previousStreak: 5) == 0
    )
    #expect(
      AgentSessionResolver.nextUnresolvedStreak(resolvedNow: false, previousWasUnresolved: false, previousStreak: 0)
        == 0)
    #expect(
      AgentSessionResolver.nextUnresolvedStreak(resolvedNow: false, previousWasUnresolved: true, previousStreak: 0) == 1
    )
    #expect(
      AgentSessionResolver.nextUnresolvedStreak(resolvedNow: false, previousWasUnresolved: true, previousStreak: 3) == 4
    )
  }

  // MARK: - Cache pacing

  @Test func unresolvedLookupsBackOffExponentially() {
    #expect(AgentSessionResolver.cacheLifetime(hasSession: true, usedWideScan: false, unresolvedStreak: 9) == 5)
    #expect(AgentSessionResolver.cacheLifetime(hasSession: false, usedWideScan: false, unresolvedStreak: 0) == 1)
    #expect(AgentSessionResolver.cacheLifetime(hasSession: false, usedWideScan: false, unresolvedStreak: 1) == 2)
    #expect(AgentSessionResolver.cacheLifetime(hasSession: false, usedWideScan: false, unresolvedStreak: 3) == 8)
    #expect(AgentSessionResolver.cacheLifetime(hasSession: false, usedWideScan: false, unresolvedStreak: 8) == 15)
    #expect(AgentSessionResolver.cacheLifetime(hasSession: false, usedWideScan: true, unresolvedStreak: 0) == 8)
    #expect(AgentSessionResolver.cacheLifetime(hasSession: false, usedWideScan: true, unresolvedStreak: 5) == 15)
  }

  @Test func soleCandidateNeedsTwoConsistentSamples() {
    let sole = AgentSession(id: "abc", transcriptPath: nil, source: .recentFile)
    let first = AgentSessionResolver.confirmSole(sole, previousProvisionalID: nil)
    #expect(first.session == nil)
    #expect(first.provisionalID == "abc")
    let second = AgentSessionResolver.confirmSole(sole, previousProvisionalID: "abc")
    #expect(second.session?.id == "abc")
    #expect(second.provisionalID == nil)
    let changed = AgentSessionResolver.confirmSole(sole, previousProvisionalID: "other")
    #expect(changed.session == nil)
    #expect(changed.provisionalID == "abc")
    // Exact/high evidence is never held back.
    let exact = AgentSession(id: "xyz", transcriptPath: nil, source: .openFile, confidence: .exact)
    #expect(AgentSessionResolver.confirmSole(exact, previousProvisionalID: nil).session?.id == "xyz")
  }

  // MARK: - Amp thread log parsing

  @Test func ampParsesOpenThreadLogPath() throws {
    let path = "/Users/me/.cache/amp/logs/threads/T-019f4fbf-040b-704b-8247-d4754f7dae6c.log"
    let session = try #require(AgentSessionPathParser.parse(path: path, agent: .amp))
    #expect(session.id == "T-019f4fbf-040b-704b-8247-d4754f7dae6c")
    #expect(AgentSessionPathParser.parse(path: "/Users/me/.cache/amp/logs/cli.log", agent: .amp) == nil)
  }

  // MARK: - OpenCode store

  @Test func openCodeStoreReturnsLifetimeCandidatesForDirectory() throws {
    let databaseURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-opencode-\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    let schema =
      "CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, time_updated INTEGER);"
    #expect(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
    let threshold = Date(timeIntervalSince1970: 1_783_700_000)
    // A sub-agent session (`parent_id` set) updates more often than the session the user is
    // talking to and must never displace it (docs-ai 064.010).
    let rows = [
      "('ses_current', NULL, '/tmp/project', \(Int64((threshold.timeIntervalSince1970 + 60) * 1_000)))",
      "('ses_child', 'ses_current', '/tmp/project', \(Int64((threshold.timeIntervalSince1970 + 120) * 1_000)))",
      "('ses_stale', NULL, '/tmp/project', \(Int64((threshold.timeIntervalSince1970 - 60) * 1_000)))",
      "('ses_other', NULL, '/tmp/other', \(Int64((threshold.timeIntervalSince1970 + 60) * 1_000)))",
    ]
    for row in rows {
      #expect(sqlite3_exec(database, "INSERT INTO session VALUES \(row);", nil, nil, nil) == SQLITE_OK)
    }

    let candidates = OpenCodeSessionStore.candidates(
      databaseURL: databaseURL,
      directory: "/tmp/project",
      modifiedAfter: threshold
    )
    #expect(candidates.map(\.session.id) == ["ses_current"])
    #expect(candidates.first?.session.source == .storeRecord)
  }
}
