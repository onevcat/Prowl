import Foundation

/// Copilot CLI writes `~/.copilot/logs/process-<epoch-ms>-<pid>.log` and logs
/// "Registering foreground session: <uuid>" once the interactive session is
/// live, giving an exact pid→session mapping without descriptor inspection.
nonisolated enum CopilotProcessLog {
  static func session(
    logsDirectory: URL,
    sessionStateDirectory: URL,
    pid: pid_t,
    processStartedAt: Date,
    fileManager: FileManager = .default
  ) -> AgentSession? {
    guard let log = latestLog(in: logsDirectory, pid: pid, fileManager: fileManager),
      let modifiedAt = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
      modifiedAt >= processStartedAt.addingTimeInterval(-2),
      let id = lastRegisteredSession(in: log)
    else { return nil }
    let transcript = sessionStateDirectory.appending(path: "\(id)/events.jsonl")
    return AgentSession(
      id: id,
      transcriptPath: fileManager.fileExists(atPath: transcript.path) ? transcript : nil,
      source: .processLog,
      confidence: .exact
    )
  }

  /// Pid reuse across app restarts leaves several `process-*-<pid>.log` files;
  /// the largest epoch prefix is the current process's log.
  private static func latestLog(in directory: URL, pid: pid_t, fileManager: FileManager) -> URL? {
    let suffix = "-\(pid).log"
    let logs = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return
      logs
      .filter { $0.lastPathComponent.hasPrefix("process-") && $0.lastPathComponent.hasSuffix(suffix) }
      .max { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func lastRegisteredSession(in url: URL, byteLimit: Int = 262_144) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    try? handle.seek(toOffset: size > UInt64(byteLimit) ? size - UInt64(byteLimit) : 0)
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
    let pattern = /Registering foreground session: ([0-9a-fA-F-]{36})/
    return text.matches(of: pattern).last.map { String($0.output.1).lowercased() }
  }
}

/// Qwen Code writes `<chats dir>/<session id>.runtime.json` sidecars for every
/// live interactive session, explicitly for external observers (source:
/// `packages/core/src/utils/runtimeStatus.ts`). Session rotation (`/clear`,
/// `/resume`) atomically swaps the sidecar, but quit/crash leaves it behind —
/// consumers must verify the claim against the live process. A claim whose
/// `started_at` predates the process start belongs to a previous owner of a
/// reused pid.
nonisolated enum QwenRuntimeStatus {
  private static let schemaVersion = 1

  static func session(
    projectsRoot: URL,
    pid: pid_t,
    processStartedAt: Date,
    fileManager: FileManager = .default
  ) -> AgentSession? {
    let projects = (try? fileManager.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
    for project in projects {
      let chats = project.appending(path: "chats")
      let sidecars = (try? fileManager.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)) ?? []
      for sidecar in sidecars where sidecar.lastPathComponent.hasSuffix(".runtime.json") {
        guard let data = try? Data(contentsOf: sidecar),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["schema_version"] as? Int == schemaVersion,
          let sidecarPID = object["pid"] as? Int, sidecarPID == Int(pid),
          let startedAt = object["started_at"] as? Double,
          startedAt >= processStartedAt.timeIntervalSince1970 - 2,
          let id = object["session_id"] as? String, !id.isEmpty
        else { continue }
        let transcript = chats.appending(path: "\(id).jsonl")
        return AgentSession(
          id: id,
          transcriptPath: fileManager.fileExists(atPath: transcript.path) ? transcript : nil,
          source: .processLog,
          confidence: .exact
        )
      }
    }
    return nil
  }
}

/// Grok Build writes `~/.grok/active_sessions.json` with one entry per live
/// interactive session: `{ session_id, pid, cwd, opened_at }`. The pid map is
/// exact while the process is alive; quit/crash eventually drops the row, but
/// a reused pid can still carry a stale claim until Grok rewrites the file —
/// reject entries whose `opened_at` predates the process start.
nonisolated enum GrokActiveSessions {
  static func session(
    home: URL,
    pid: pid_t,
    processStartedAt: Date,
    fileManager: FileManager = .default
  ) -> AgentSession? {
    let url = home.appending(path: ".grok/active_sessions.json")
    guard let data = try? Data(contentsOf: url),
      let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }

    for row in rows {
      guard let rowPID = row["pid"] as? Int, rowPID == Int(pid),
        let id = row["session_id"] as? String, !id.isEmpty,
        // Require a parseable opened_at: a missing/unreadable timestamp cannot
        // prove the claim belongs to this process (pid reuse → stale exact).
        let openedAtRaw = row["opened_at"] as? String,
        let openedAt = parseOpenedAt(openedAtRaw),
        openedAt >= processStartedAt.addingTimeInterval(-2)
      else { continue }
      let cwd = row["cwd"] as? String
      let transcript = transcriptURL(home: home, sessionID: id, cwd: cwd, fileManager: fileManager)
      return AgentSession(
        id: id,
        transcriptPath: transcript,
        source: .processLog,
        confidence: .exact
      )
    }
    return nil
  }

  private static func parseOpenedAt(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    return basic.date(from: value)
  }

  private static func transcriptURL(
    home: URL,
    sessionID: String,
    cwd: String?,
    fileManager: FileManager
  ) -> URL? {
    let sessionsRoot = home.appending(path: ".grok/sessions")
    let candidates: [URL]
    if let cwd {
      // Prefer chat_history.jsonl: it is the conversation transcript
      // (messages incl. system prompt); events.jsonl only logs
      // MCP/infrastructure events.
      let encoded = percentEncodedPath(cwd)
      candidates = [
        sessionsRoot.appending(path: "\(encoded)/\(sessionID)/chat_history.jsonl"),
        sessionsRoot.appending(path: "\(encoded)/\(sessionID)/events.jsonl"),
      ]
    } else {
      candidates = []
    }
    for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
      return candidate
    }
    // Fall back to a shallow scan when cwd is missing or encoding diverged.
    let projectDirs = (try? fileManager.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? []
    for project in projectDirs {
      let chat = project.appending(path: "\(sessionID)/chat_history.jsonl")
      if fileManager.fileExists(atPath: chat.path) { return chat }
      let events = project.appending(path: "\(sessionID)/events.jsonl")
      if fileManager.fileExists(atPath: events.path) { return events }
    }
    return nil
  }

  private static func percentEncodedPath(_ path: String) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
  }
}
