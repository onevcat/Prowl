import Foundation
import SQLite3

/// Read-only lookup into OpenCode's shared sqlite database
/// (`~/.local/share/opencode/opencode.db`). The `session` table stores the
/// plain working directory per session, so process-lifetime filtering works
/// the same way it does for file-based agents.
nonisolated enum OpenCodeSessionStore {
  static func candidates(
    databaseURL: URL,
    directory: String,
    modifiedAfter threshold: Date,
    limit: Int = 8
  ) -> [AgentSessionCandidate] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
      sqlite3_close(database)
      return []
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 50)

    // Sub-agent sessions carry a `parent_id` and update more often than the session the user
    // is talking to; they are never the pane's session and must not displace it.
    let query =
      "SELECT id, time_updated FROM session WHERE directory = ?1 AND time_updated >= ?2 "
      + "AND parent_id IS NULL ORDER BY time_updated DESC LIMIT ?3"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, directory, -1, transient)
    sqlite3_bind_int64(statement, 2, Int64(threshold.timeIntervalSince1970 * 1_000))
    sqlite3_bind_int(statement, 3, Int32(limit))

    var candidates: [AgentSessionCandidate] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idPointer = sqlite3_column_text(statement, 0) else { continue }
      let updatedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)) / 1_000)
      candidates.append(
        AgentSessionCandidate(
          session: AgentSession(id: String(cString: idPointer), transcriptPath: nil, source: .storeRecord),
          modifiedAt: updatedAt
        )
      )
    }
    return candidates
  }
}
