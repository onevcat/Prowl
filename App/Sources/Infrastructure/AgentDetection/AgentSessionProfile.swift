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
  /// Layout under a relocated config root for account-bound Prowl-launched
  /// surfaces (docs-ai 053): the runtime's entire home moved, so paths carry
  /// no `.claude`/`.codex` component and the default markers cannot match.
  /// Only runtimes with verified account isolation define these; when a
  /// surface has a config root, the resolver uses the rooted layout
  /// exclusively — scanning the default home would misattribute sessions.
  var rootedCandidateRoots:
    (@Sendable (_ configRoot: URL, _ cwd: URL?, _ processStartedAt: Date, _ now: Date) -> [URL])?
  var rootedFallbackRoots: (@Sendable (_ configRoot: URL, _ cwd: URL?) -> [URL])?
  var rootedParsePath: (@Sendable (_ path: String, _ configRoot: URL) -> AgentSession?)?
  /// Exact pid lookup under a relocated native config root. Kept separate from
  /// `pidKeyedSession` because default layouts prepend `.copilot`/`.qwen`,
  /// while their relocation variables already point at those directories.
  var rootedPIDKeyedSession: (@Sendable (_ configRoot: URL, _ pid: pid_t, _ processStartedAt: Date) -> AgentSession?)?

  static func profile(for agent: DetectedAgent) -> AgentSessionProfile {
    switch agent {
    case .codex: .codex
    case .claude: .claude
    case .pi: .pi
    case .omp: .omp
    case .gemini: .gemini
    case .cursor: .cursor
    case .cline: .cline
    case .copilot: .copilot
    case .kimi: .kimi
    case .droid: .droid
    case .opencode: .opencode
    case .amp: .amp
    case .qoder: .qoder
    case .qwen: .qwen
    case .grok: .grok
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
    },
    rootedCandidateRoots: { configRoot, _, processStartedAt, now in
      dayDirectories(
        root: configRoot.appending(path: "sessions"),
        from: processStartedAt,
        to: now
      )
    },
    rootedFallbackRoots: { configRoot, _ in
      [configRoot.appending(path: "sessions")]
    },
    rootedParsePath: { path, configRoot in
      uuidJSONL(path: path, underRoot: configRoot.appending(path: "sessions"))
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
    },
    rootedCandidateRoots: { configRoot, cwd, _, _ in
      guard let cwd else { return [] }
      return [configRoot.appending(path: "projects/\(alphanumericDashed(cwd.path))")]
    },
    rootedParsePath: { path, configRoot in
      uuidJSONL(path: path, underRoot: configRoot.appending(path: "projects"))
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
    },
    rootedCandidateRoots: { configRoot, cwd, _, _ in
      guard let cwd else { return [] }
      return [configRoot.appending(path: "sessions/-\(slashDashed(cwd.path))--")]
    },
    rootedParsePath: { path, configRoot in
      uuidJSONL(path: path, underRoot: configRoot.appending(path: "sessions"))
    }
  )

  /// Oh My Pi ≥ 17: `~/.omp/agent/sessions/<home-relative cwd>/*.jsonl`.
  /// OMP migrated from Pi's absolute `--<cwd>--` buckets to `-<relative>`
  /// buckets for directories below the user's home. Keep a broad fallback
  /// root for migrated and canonicalized paths while preferring the exact
  /// current bucket.
  fileprivate static let omp = AgentSessionProfile(
    parsePath: { uuidJSONL(path: $0, marker: "/.omp/agent/sessions/") },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [] }
      return [
        home.appending(path: ".omp/agent/sessions/\(ompSessionDirectoryName(home: home, cwd: cwd))")
      ]
    },
    fallbackRoots: { home, _ in
      [home.appending(path: ".omp/agent/sessions")]
    },
    rootedCandidateRoots: { configRoot, cwd, _, _ in
      guard let cwd else { return [] }
      return [
        configRoot.appending(
          path: "sessions/\(ompSessionDirectoryName(home: FileManager.default.homeDirectoryForCurrentUser, cwd: cwd))"
        )
      ]
    },
    rootedFallbackRoots: { configRoot, _ in
      [configRoot.appending(path: "sessions")]
    },
    rootedParsePath: { path, configRoot in
      uuidJSONL(path: path, underRoot: configRoot.appending(path: "sessions"))
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
    },
    rootedCandidateRoots: { configRoot, cwd, _, _ in
      guard let cwd else { return [configRoot.appending(path: "tmp")] }
      let tmp = configRoot.appending(path: "tmp")
      var roots: [URL] = []
      if let slug = geminiProjectSlug(configRoot: configRoot, cwd: cwd) {
        roots.append(tmp.appending(path: "\(slug)/chats"))
      }
      roots.append(tmp.appending(path: "\(sha256Hex(cwd.path))/chats"))
      return roots
    },
    rootedFallbackRoots: { configRoot, _ in
      [configRoot.appending(path: "tmp")]
    },
    rootedParsePath: { path, configRoot in
      geminiSession(path: path, underRoot: configRoot.appending(path: "tmp"))
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
    },
    rootedCandidateRoots: { configRoot, _, _, _ in
      [configRoot.appending(path: "tasks")]
    },
    rootedParsePath: { path, configRoot in
      firstComponent(path: path, underRoot: configRoot.appending(path: "tasks"))
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
    },
    rootedCandidateRoots: { configRoot, _, _, _ in
      [configRoot.appending(path: "session-state")]
    },
    rootedParsePath: { path, configRoot in
      firstComponent(
        path: path,
        underRoot: configRoot.appending(path: "session-state")
      )
    },
    rootedPIDKeyedSession: { configRoot, pid, processStartedAt in
      CopilotProcessLog.session(
        logsDirectory: configRoot.appending(path: "logs"),
        sessionStateDirectory: configRoot.appending(path: "session-state"),
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

  /// Qoder CLI ≥ 1.0.48: `~/.qoder/projects/<sanitized cwd>/<uuid>.jsonl`,
  /// Claude Code's layout under a different root — every non-alphanumeric cwd
  /// character becomes `-`. Verified against a local 1.0.48 install.
  fileprivate static let qoder = AgentSessionProfile(
    parsePath: { uuidJSONL(path: $0, marker: "/.qoder/projects/") },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [] }
      return [home.appending(path: ".qoder/projects/\(alphanumericDashed(cwd.path))")]
    },
    rootedCandidateRoots: { configRoot, cwd, _, _ in
      guard let cwd else { return [] }
      return [configRoot.appending(path: "projects/\(alphanumericDashed(cwd.path))")]
    },
    rootedParsePath: { path, configRoot in
      uuidJSONL(path: path, underRoot: configRoot.appending(path: "projects"))
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
    },
    rootedCandidateRoots: { configRoot, cwd, _, _ in
      guard let cwd else { return [configRoot.appending(path: "projects")] }
      return [configRoot.appending(path: "projects/\(alphanumericDashed(cwd.path))/chats")]
    },
    rootedFallbackRoots: { configRoot, _ in
      [configRoot.appending(path: "projects")]
    },
    rootedParsePath: { path, configRoot in
      uuidJSONL(path: path, underRoot: configRoot.appending(path: "projects"))
    },
    rootedPIDKeyedSession: { configRoot, pid, processStartedAt in
      QwenRuntimeStatus.session(
        projectsRoot: configRoot.appending(path: "projects"),
        pid: pid,
        processStartedAt: processStartedAt
      )
    }
  )

  /// Grok Build ≥ 0.2: `~/.grok/sessions/<percent-encoded cwd>/<session-id>/`
  /// with `events.jsonl` / `chat_history.jsonl` held open during the turn, plus
  /// an exact pid map in `~/.grok/active_sessions.json`. Cwd encoding is
  /// full-path percent-encoding (`/Users/me/App` → `%2FUsers%2Fme%2FApp`).
  /// Verified against Grok Build 0.2.101.
  fileprivate static let grok = AgentSessionProfile(
    parsePath: { path in
      let url = URL(fileURLWithPath: path)
      guard path.contains("/.grok/sessions/") else { return nil }
      let components = url.pathComponents
      // Anchor on a `.grok` component whose next component is `sessions`
      // (not the first bare `sessions`, and not an earlier unrelated `.grok`).
      guard
        let grokIndex = components.indices.first(where: { index in
          components[index] == ".grok"
            && components.indices.contains(index + 1)
            && components[index + 1] == "sessions"
        }),
        components.count > grokIndex + 3
      else { return nil }
      // Layout: …/.grok/sessions/<encoded-cwd>/<session-id>/…
      let id = components[grokIndex + 3]
      guard uuid(in: id) != nil else { return nil }
      // Walk up from the open path to the session root
      // (…/sessions/<cwd>/<id>/). Nested paths like `terminal/<log>.log`
      // still resolve.
      var dir = url.deletingLastPathComponent()
      while dir.lastPathComponent != id, dir.pathComponents.count > grokIndex + 3 {
        dir = dir.deletingLastPathComponent()
      }
      guard dir.lastPathComponent == id else { return nil }
      // Prefer the conversation transcript. If it has not been created yet,
      // retain the opened events log rather than claiming a nonexistent path.
      let chatHistory = dir.appending(path: "chat_history.jsonl")
      let transcript: URL?
      if url.lastPathComponent == "chat_history.jsonl" || FileManager.default.fileExists(atPath: chatHistory.path) {
        transcript = chatHistory
      } else if url.lastPathComponent == "events.jsonl" {
        transcript = url
      } else {
        transcript = nil
      }
      return AgentSession(id: id, transcriptPath: transcript, source: .recentFile)
    },
    candidateRoots: { home, cwd, _, _ in
      guard let cwd else { return [home.appending(path: ".grok/sessions")] }
      return [home.appending(path: ".grok/sessions/\(percentEncodedPath(cwd.path))")]
    },
    fallbackRoots: { home, _ in
      [home.appending(path: ".grok/sessions")]
    },
    pidKeyedSession: { home, pid, processStartedAt in
      GrokActiveSessions.session(home: home, pid: pid, processStartedAt: processStartedAt)
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

  /// Marker matching for relocated homes: the config root replaces the global
  /// `/.codex/…` substring, so ownership is a root prefix check instead.
  fileprivate static func uuidJSONL(path: String, underRoot root: URL) -> AgentSession? {
    let rootPath = root.standardizedFileURL.path(percentEncoded: false)
    guard path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
    let url = URL(fileURLWithPath: path)
    guard url.pathExtension == "jsonl",
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

  fileprivate static func firstComponent(path: String, underRoot root: URL) -> AgentSession? {
    let rootPath = root.standardizedFileURL.path(percentEncoded: false)
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard standardizedPath.hasPrefix(prefix),
      let id = standardizedPath.dropFirst(prefix.count).split(separator: "/").first
    else { return nil }
    return AgentSession(
      id: String(id),
      transcriptPath: URL(fileURLWithPath: standardizedPath),
      source: .recentFile
    )
  }

  fileprivate static func geminiSession(path: String, underRoot root: URL) -> AgentSession? {
    let rootPath = root.standardizedFileURL.path(percentEncoded: false)
    let url = URL(fileURLWithPath: path)
    guard path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/"), path.contains("/chats/"),
      url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("session-")
    else { return nil }
    guard let id = url.deletingPathExtension().lastPathComponent.split(separator: "-").last.map(String.init),
      !id.isEmpty
    else { return nil }
    return AgentSession(id: id, transcriptPath: url, source: .recentFile)
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

  /// OMP's current session buckets are home-relative when possible and retain
  /// Pi's legacy absolute encoding for paths outside the home directory.
  fileprivate static func ompSessionDirectoryName(home: URL, cwd: URL) -> String {
    let slash = CharacterSet(charactersIn: "/")
    let rawHomePath = home.standardizedFileURL.path(percentEncoded: false)
    let rawCwdPath = cwd.standardizedFileURL.path(percentEncoded: false)
    let homePath = rawHomePath.count > 1 ? rawHomePath.trimmingCharacters(in: slash) : rawHomePath
    let cwdPath = rawCwdPath.count > 1 ? rawCwdPath.trimmingCharacters(in: slash) : rawCwdPath
    if cwdPath == homePath {
      return "-"
    }
    let homePrefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
    if cwdPath.hasPrefix(homePrefix) {
      return "-" + cwdPath.dropFirst(homePrefix.count).replacing("/", with: "-")
    }
    return "--" + cwdPath.drop(while: { $0 == "/" }).replacing("/", with: "-") + "--"
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

  /// Grok session directories encode the absolute cwd as a single path
  /// component: every character outside RFC 3986 unreserved is percent-encoded
  /// (`/Users/me/My App` → `%2FUsers%2Fme%2FMy%20App`).
  fileprivate static func percentEncodedPath(_ path: String) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
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
    geminiProjectSlug(configRoot: home.appending(path: ".gemini"), cwd: cwd)
  }

  fileprivate static func geminiProjectSlug(configRoot: URL, cwd: URL) -> String? {
    let url = configRoot.appending(path: "projects.json")
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let projects = object["projects"] as? [String: Any]
    else { return nil }
    return projects[cwd.path] as? String
  }
}
