import CryptoKit
import Foundation

/// Single source of truth for one agent CLI's native session knowledge.
///
/// Prowl tracks only the latest released CLI of each agent. When a CLI changes
/// its storage layout, environment contract, or identity artifacts, update that
/// agent's builder below in place; do not add version detection layers.
nonisolated struct AgentSessionProfile: Sendable {
  /// Parses an absolute file path owned by the agent (open descriptor or
  /// storage scan hit) into a session.
  var parsePath: @Sendable (_ path: String) -> AgentSession? = { _ in nil }
  /// Top-level JSON keys in a transcript's first line whose value REPLACES the
  /// path-derived session id. Opt-in per agent: only meaningful when the
  /// filename carries a truncated id (Gemini). Leave empty when the path
  /// already holds the full id — generic sniffing can grab an unrelated field
  /// from event-stream layouts like Copilot's events.jsonl.
  var headerSessionIDKeys: [String] = []
  /// When true, a candidate whose header lookup fails is DROPPED instead of
  /// falling back to the path-derived id (Gemini: the filename only holds an
  /// 8-hex prefix that cannot be resumed).
  var requiresHeaderSessionID: Bool = false
  /// Storage roots scanned for session files modified during the process
  /// lifetime. Narrow these as much as the layout allows.
  var candidateRoots: @Sendable (_ home: URL, _ cwd: URL?, _ processStartedAt: Date, _ now: Date) -> [URL] = {
    _, _, _, _ in []
  }
  /// Wider roots scanned only when `candidateRoots` yields no candidate, e.g.
  /// resumed Codex rollouts that live in their original date directory.
  var fallbackRoots: @Sendable (_ home: URL, _ cwd: URL?) -> [URL] = { _, _ in [] }
  /// Exact artifact lookup keyed by the agent process id (Copilot process log,
  /// Qwen runtime sidecar).
  var pidKeyedSession: (@Sendable (_ home: URL, _ pid: pid_t, _ processStartedAt: Date) -> AgentSession?)?
  /// Candidate enumeration for agents whose sessions live in a shared store
  /// instead of per-session files (OpenCode's sqlite database).
  var storeCandidates: (@Sendable (_ home: URL, _ cwd: URL?, _ processStartedAt: Date) -> [AgentSessionCandidate])?

  static func profile(for agent: DetectedAgent) -> AgentSessionProfile {
    switch agent {
    case .codex: .codex
    case .claude: .claude
    case .pi: .pi
    case .gemini: .gemini
    case .cursor: .cursor
    case .cline: .cline
    case .copilot: .copilot
    case .kimi: .kimi
    case .droid: .droid
    case .opencode: .opencode
    case .amp: .amp
    case .qwen: .qwen
    case .grok: .init()
    }
  }
}

// MARK: - Per-agent profiles

nonisolated extension AgentSessionProfile {
  /// Codex ≥ 0.144: `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`,
  /// held open for the whole interactive session. `CODEX_THREAD_ID` on exec
  /// tool children. New sessions land in day directories within the process
  /// lifetime; resumed rollouts stay in their original day, hence the full
  /// fallback root.
  fileprivate static let codex = AgentSessionProfile(
    parsePath: { uuidJSONL(path: $0, marker: "/.codex/sessions/") },
    candidateRoots: { home, _, processStartedAt, now in
      dayDirectories(
        root: home.appending(path: ".codex/sessions"),
        from: processStartedAt,
        to: now
      )
    },
    fallbackRoots: { home, _ in
      [home.appending(path: ".codex/sessions")]
    }
  )

  /// Claude Code ≥ 2.1: `~/.claude/projects/<sanitized cwd>/<uuid>.jsonl`,
  /// closed between writes; every non-alphanumeric cwd character becomes `-`.
  /// `CLAUDE_CODE_SESSION_ID` on Bash/MCP tool children.
  fileprivate static let claude = AgentSessionProfile(
    parsePath: { uuidJSONL(path: $0, marker: "/.claude/projects/") },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [] }
      return [home.appending(path: ".claude/projects/\(alphanumericDashed(cwd.path))")]
    }
  )

  // Pi ≥ 0.79: `~/.pi/agent/sessions/--<cwd, slashes dashed>--/*.jsonl`; dots
  // and spaces in the cwd are preserved.
  // swiftlint:disable:next identifier_name
  fileprivate static let pi = AgentSessionProfile(
    parsePath: { uuidJSONL(path: $0, marker: "/.pi/agent/sessions/") },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [] }
      return [home.appending(path: ".pi/agent/sessions/-\(slashDashed(cwd.path))--")]
    }
  )

  /// Gemini CLI ≥ 0.46: `~/.gemini/tmp/<slug>/chats/session-<ts>-<uuid[0..8)>.jsonl`
  /// with the full id in the JSONL header; `~/.gemini/projects.json` maps the
  /// absolute cwd to the slug, and older layouts used `sha256(cwd)` directories.
  fileprivate static let gemini = AgentSessionProfile(
    parsePath: { path in
      let url = URL(fileURLWithPath: path)
      guard path.contains("/.gemini/tmp/"), path.contains("/chats/"), url.pathExtension == "jsonl",
        url.lastPathComponent.hasPrefix("session-")
      else { return nil }
      guard let id = url.deletingPathExtension().lastPathComponent.split(separator: "-").last.map(String.init),
        !id.isEmpty
      else { return nil }
      return AgentSession(id: id, transcriptPath: url, source: .recentFile)
    },
    headerSessionIDKeys: ["sessionId"],
    requiresHeaderSessionID: true,
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [home.appending(path: ".gemini/tmp")] }
      let tmp = home.appending(path: ".gemini/tmp")
      var roots: [URL] = []
      if let slug = geminiProjectSlug(home: home, cwd: cwd) {
        roots.append(tmp.appending(path: "\(slug)/chats"))
      }
      roots.append(tmp.appending(path: "\(sha256Hex(cwd.path))/chats"))
      return roots
    },
    fallbackRoots: { home, _ in
      [home.appending(path: ".gemini/tmp")]
    }
  )

  /// Cursor Agent: `~/.cursor/chats/<md5(cwd)>/<uuid>/store.db`.
  fileprivate static let cursor = AgentSessionProfile(
    parsePath: { parentID(path: $0, marker: "/.cursor/chats/", filename: "store.db") },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [home.appending(path: ".cursor/chats")] }
      return [home.appending(path: ".cursor/chats/\(md5Hex(cwd.path))")]
    },
    fallbackRoots: { home, _ in
      [home.appending(path: ".cursor/chats")]
    }
  )

  /// Cline 2.x: `~/.cline/data/tasks/<epoch-ms task id>/...`.
  fileprivate static let cline = AgentSessionProfile(
    parsePath: { markedComponent(path: $0, marker: "/.cline/data/tasks/", component: "tasks") },
    candidateRoots: { home, _, _, _ in
      [home.appending(path: ".cline/data/tasks")]
    }
  )

  /// Copilot CLI ≥ 1.0: `~/.copilot/session-state/<uuid>/...` plus
  /// `~/.copilot/logs/process-<epoch-ms>-<pid>.log` containing
  /// "Registering foreground session: <uuid>". `COPILOT_AGENT_SESSION_ID` on
  /// shell children.
  fileprivate static let copilot = AgentSessionProfile(
    parsePath: { markedComponent(path: $0, marker: "/.copilot/session-state/", component: "session-state") },
    candidateRoots: { home, _, _, _ in
      [home.appending(path: ".copilot/session-state")]
    },
    pidKeyedSession: { home, pid, processStartedAt in
      CopilotProcessLog.session(
        logsDirectory: home.appending(path: ".copilot/logs"),
        sessionStateDirectory: home.appending(path: ".copilot/session-state"),
        pid: pid,
        processStartedAt: processStartedAt
      )
    }
  )

  /// Kimi (Python CLI 1.x): `~/.kimi/sessions/<md5(cwd)>/<uuid>/{context.jsonl,
  /// wire.jsonl, state.json}`.
  fileprivate static let kimi = AgentSessionProfile(
    parsePath: { path in
      guard path.contains("/.kimi/sessions/") else { return nil }
      let components = URL(fileURLWithPath: path).pathComponents
      guard let index = components.firstIndex(of: "sessions"), components.count > index + 2 else { return nil }
      return AgentSession(
        id: components[index + 2],
        transcriptPath: URL(fileURLWithPath: path),
        source: .recentFile
      )
    },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [home.appending(path: ".kimi/sessions")] }
      return [home.appending(path: ".kimi/sessions/\(md5Hex(cwd.path))")]
    },
    fallbackRoots: { home, _ in
      [home.appending(path: ".kimi/sessions")]
    }
  )

  /// Droid ≥ 0.147: `~/.factory/sessions/<cwd, slashes dashed>/<uuid>.jsonl`;
  /// spaces in the cwd are preserved.
  fileprivate static let droid = AgentSessionProfile(
    parsePath: { uuidJSONL(path: $0, marker: "/.factory/sessions/") },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [] }
      return [home.appending(path: ".factory/sessions/\(slashDashed(cwd.path))")]
    }
  )

  /// OpenCode ≥ 1.2: sessions live in the shared sqlite database
  /// `~/.local/share/opencode/opencode.db` (`session.directory` = plain cwd);
  /// the TUI holds no per-session file, so store rows stand in for candidate
  /// files. Rows carry no transcript, so text correlation is unavailable and
  /// parallel sessions in one directory stay unresolved.
  fileprivate static let opencode = AgentSessionProfile(
    storeCandidates: { home, cwd, processStartedAt in
      guard let cwd else { return [] }
      return OpenCodeSessionStore.candidates(
        databaseURL: home.appending(path: ".local/share/opencode/opencode.db"),
        directory: cwd.path,
        modifiedAfter: processStartedAt
      )
    }
  )

  /// Amp: threads are server-side; the logged-in TUI holds a per-thread log
  /// `~/.cache/amp/logs/threads/T-<uuid>.log` open, and injects
  /// `AMP_CURRENT_THREAD_ID` into Bash tool children (undocumented).
  fileprivate static let amp = AgentSessionProfile(
    parsePath: { path in
      let url = URL(fileURLWithPath: path)
      let id = url.deletingPathExtension().lastPathComponent
      guard id.hasPrefix("T-") else { return nil }
      if path.contains("/.cache/amp/logs/threads/"), url.pathExtension == "log" {
        return AgentSession(id: id, transcriptPath: nil, source: .recentFile)
      }
      if path.contains("/.local/share/amp/threads/"), url.pathExtension == "json" {
        return AgentSession(id: id, transcriptPath: url, source: .recentFile)
      }
      return nil
    }
  )

  /// Qwen Code: `~/.qwen/projects/<sanitized cwd>/chats/<uuid>.jsonl` plus the
  /// official pid→session sidecar `<uuid>.runtime.json` next to it. The cwd
  /// sanitizer is Claude's rule (`[^a-zA-Z0-9]` → `-`, `sanitizeCwd` in
  /// `packages/core/src/utils/paths.ts`). Source-verified against QwenLM/
  /// qwen-code@deb45ae; not exercised against a local install.
  fileprivate static let qwen = AgentSessionProfile(
    parsePath: { uuidJSONL(path: $0, marker: "/.qwen/projects/") },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [home.appending(path: ".qwen/projects")] }
      return [home.appending(path: ".qwen/projects/\(alphanumericDashed(cwd.path))/chats")]
    },
    fallbackRoots: { home, _ in
      [home.appending(path: ".qwen/projects")]
    },
    pidKeyedSession: { home, pid, processStartedAt in
      QwenRuntimeStatus.session(
        projectsRoot: home.appending(path: ".qwen/projects"),
        pid: pid,
        processStartedAt: processStartedAt
      )
    }
  )
}

// MARK: - Path parsing helpers

nonisolated extension AgentSessionProfile {
  fileprivate static func uuidJSONL(path: String, marker: String) -> AgentSession? {
    let url = URL(fileURLWithPath: path)
    guard path.contains(marker), url.pathExtension == "jsonl",
      let id = uuid(in: url.deletingPathExtension().lastPathComponent)
    else { return nil }
    return AgentSession(id: id, transcriptPath: url, source: .recentFile)
  }

  fileprivate static func parentID(path: String, marker: String, filename: String) -> AgentSession? {
    let url = URL(fileURLWithPath: path)
    guard path.contains(marker), url.lastPathComponent == filename,
      let id = url.pathComponents.dropLast().last
    else { return nil }
    return AgentSession(id: id, transcriptPath: url, source: .recentFile)
  }

  fileprivate static func markedComponent(path: String, marker: String, component: String) -> AgentSession? {
    guard path.contains(marker) else { return nil }
    let components = URL(fileURLWithPath: path).pathComponents
    guard let index = components.firstIndex(of: component), components.indices.contains(index + 1) else { return nil }
    return AgentSession(
      id: components[index + 1],
      transcriptPath: URL(fileURLWithPath: path),
      source: .recentFile
    )
  }

  fileprivate static func uuid(in value: String) -> String? {
    let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    guard let range = value.range(of: pattern, options: .regularExpression) else { return nil }
    return String(value[range]).lowercased()
  }
}

// MARK: - Working-directory encoders

nonisolated extension AgentSessionProfile {
  /// `/a/b` → `-a-b`; only slashes are replaced (Pi and Droid keep every other
  /// character verbatim).
  fileprivate static func slashDashed(_ path: String) -> String {
    path.replacing("/", with: "-")
  }

  /// Claude Code's project-directory rule: every UTF-16 code unit outside
  /// `[A-Za-z0-9]` becomes `-`. Code-unit (not Character) semantics match the
  /// JavaScript `replace(/[^a-zA-Z0-9]/g, "-")`: a surrogate-pair emoji yields
  /// TWO dashes (verified live: `…-🐱-café` → `…----caf-`). File URLs decompose
  /// accented characters (NFD) while Node keeps the shell's precomposed form,
  /// so normalize to NFC first; NFD-named directories stay unresolved, which
  /// is the safe direction.
  fileprivate static func alphanumericDashed(_ path: String) -> String {
    String(
      path.precomposedStringWithCanonicalMapping.utf16.map { unit -> Character in
        let isAlphanumeric =
          (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
        guard isAlphanumeric, let scalar = UnicodeScalar(unit) else { return "-" }
        return Character(scalar)
      }
    )
  }

  fileprivate static func md5Hex(_ value: String) -> String {
    Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Day directories `root/YYYY/MM/DD` covering one day before the process
  /// start through today. Long-lived processes fall back to the full root
  /// instead of enumerating an unbounded directory list.
  fileprivate static func dayDirectories(root: URL, from processStartedAt: Date, to now: Date, cap: Int = 32) -> [URL] {
    let calendar = Calendar(identifier: .gregorian)
    let start = calendar.startOfDay(for: processStartedAt.addingTimeInterval(-86_400))
    let end = calendar.startOfDay(for: now)
    guard let span = calendar.dateComponents([.day], from: start, to: end).day, span >= 0, span < cap else {
      return []
    }
    let formatter = DateFormatter()
    // Codex writes Gregorian day directories; pin locale and calendar so a
    // Buddhist or Japanese system calendar cannot derail the narrow scan.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy/MM/dd"
    return (0...span).compactMap { offset in
      calendar.date(byAdding: .day, value: offset, to: start).map { root.appending(path: formatter.string(from: $0)) }
    }
  }

  fileprivate static func geminiProjectSlug(home: URL, cwd: URL) -> String? {
    let url = home.appending(path: ".gemini/projects.json")
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let projects = object["projects"] as? [String: Any]
    else { return nil }
    return projects[cwd.path] as? String
  }
}
