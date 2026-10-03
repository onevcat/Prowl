import Foundation

nonisolated enum ClaudeRuntimeDecoder {
  enum Failure: Error { case unsupported }

  struct Record: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let kind: String
    let pidDomain: String
    let procStart: String
    let status: String
    let updatedAt: Double
    let statusUpdatedAt: Double
  }

  static func decode(_ data: Data, process: AgentProcessGeneration) throws -> AgentNativeSnapshot {
    try snapshot(record(data), process: process)
  }

  static func record(_ data: Data) throws -> Record {
    guard data.count <= 65_536 else { throw Failure.unsupported }
    return try JSONDecoder().decode(Record.self, from: data)
  }

  static func snapshot(_ record: Record, process: AgentProcessGeneration) throws -> AgentNativeSnapshot {
    // The registry uses `TZ=UTC ps -o lstart`, which has whole-second precision.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    guard record.pid == process.pid, record.kind == "interactive", record.pidDomain == "darwin",
      UUID(uuidString: record.sessionId) != nil, record.cwd.hasPrefix("/"),
      let start = formatter.date(from: record.procStart),
      start.timeIntervalSince1970 == floor(process.startedAt.timeIntervalSince1970),
      record.updatedAt.isFinite, record.statusUpdatedAt.isFinite,
      record.updatedAt >= record.statusUpdatedAt,
      record.statusUpdatedAt / 1000 >= start.timeIntervalSince1970
    else { throw Failure.unsupported }
    let state: AgentRawState
    switch record.status {
    case "busy", "shell": state = .working
    case "waiting": state = .blocked
    case "idle": state = .idle
    default: throw Failure.unsupported
    }
    return AgentNativeSnapshot(sessionID: record.sessionId, state: state, statusUpdatedAt: record.statusUpdatedAt)
  }
}
