import Foundation

nonisolated enum AgentTranscriptResultState: Equatable, Sendable {
  case complete
  case missing
  case incomplete
  case tooLarge
}

nonisolated struct AgentTranscriptResult: Equatable, Sendable {
  let state: AgentTranscriptResultState
  let text: String?

  static func complete(_ text: String) -> Self {
    Self(state: .complete, text: text)
  }

  static func failure(_ state: AgentTranscriptResultState) -> Self {
    Self(state: state, text: nil)
  }
}

/// Reads a closed, final agent response from a single native transcript snapshot.
///
/// This intentionally accepts only the narrow, observed Codex and Claude Code
/// completion schemas. Unknown or partially-written JSONL is not a weaker form of
/// success: callers must preserve the live snapshot while withholding transcript text.
nonisolated enum AgentTranscriptResultReader {
  /// Reads a stable file snapshot. A concurrent append gets one immediate retry;
  /// accepting a moving file would make a JSONL boundary ambiguous.
  static func read(agent: DetectedAgent, at url: URL, maxBytes: Int) -> AgentTranscriptResult {
    let fileManager = FileManager.default
    for _ in 0..<2 {
      guard let before = attributes(at: url, fileManager: fileManager),
        let tail = tailData(at: url, byteLimit: tailByteLimit(for: maxBytes)),
        let after = attributes(at: url, fileManager: fileManager),
        before.size == after.size,
        before.modifiedAt == after.modifiedAt,
        let jsonl = completeJSONL(tail)
      else {
        continue
      }
      return decode(agent: agent, jsonl: jsonl, maxBytes: maxBytes)
    }
    return .failure(.incomplete)
  }

  static func decode(
    agent: DetectedAgent,
    jsonl: String,
    maxBytes: Int
  ) -> AgentTranscriptResult {
    guard maxBytes > 0 else { return .failure(.tooLarge) }
    guard jsonl.isEmpty || jsonl.hasSuffix("\n") else { return .failure(.incomplete) }
    let records = decodeRecords(jsonl)
    guard let records else { return .failure(.incomplete) }

    switch agent {
    case .codex:
      return decodeCodex(records: records, maxBytes: maxBytes)
    case .claude:
      return decodeClaude(records: records, maxBytes: maxBytes)
    default:
      return .failure(.incomplete)
    }
  }

  private struct TranscriptTail {
    let data: Data
    let startsMidRecord: Bool
  }

  /// JSON escaping can expand one UTF-8 control byte to six ASCII bytes.
  /// Six times the requested result plus 1 MiB therefore preserves one
  /// maximal latest record while keeping the 4 MiB request bounded to 25 MiB.
  private static func tailByteLimit(for maxBytes: Int) -> UInt64 {
    let scaled = max(0, maxBytes) * 6 + 1_024 * 1_024
    return UInt64(min(25 * 1_024 * 1_024, max(1_024 * 1_024, scaled)))
  }

  private static func tailData(at url: URL, byteLimit: UInt64) -> TranscriptTail? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let offset = size > byteLimit ? size - byteLimit : 0
    do {
      try handle.seek(toOffset: offset)
      guard let data = try handle.readToEnd() else { return nil }
      return TranscriptTail(data: data, startsMidRecord: offset > 0)
    } catch {
      return nil
    }
  }

  private static func completeJSONL(_ tail: TranscriptTail) -> String? {
    let data: Data
    if tail.startsMidRecord {
      guard let firstNewline = tail.data.firstIndex(of: 0x0A) else { return nil }
      data = tail.data.suffix(from: tail.data.index(after: firstNewline))
    } else {
      data = tail.data
    }
    return String(data: data, encoding: .utf8)
  }

  private static func attributes(
    at url: URL,
    fileManager: FileManager
  ) -> (size: UInt64, modifiedAt: Date)? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      let modifiedAt = attributes[.modificationDate] as? Date
    else {
      return nil
    }
    return (size.uint64Value, modifiedAt)
  }

  private static func decodeRecords(_ jsonl: String) -> [[String: Any]]? {
    var records: [[String: Any]] = []
    for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        return nil
      }
      records.append(object)
    }
    return records
  }

  private static func decodeCodex(records: [[String: Any]], maxBytes: Int) -> AgentTranscriptResult {
    guard let payload = records.reversed().lazy.compactMap(codexTerminalPayload).first else {
      return .failure(.missing)
    }
    guard payload["type"] as? String == "task_complete",
      let turnID = payload["turn_id"] as? String,
      !turnID.isEmpty,
      let completedAt = payload["completed_at"] as? NSNumber,
      CFGetTypeID(completedAt) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(completedAt),
      payload["error"] == nil,
      let text = payload["last_agent_message"] as? String,
      !text.isEmpty
    else {
      return .failure(.incomplete)
    }
    return bounded(text, maxBytes: maxBytes)
  }

  private static func codexTerminalPayload(_ record: [String: Any]) -> [String: Any]? {
    guard record["type"] as? String == "event_msg",
      let payload = record["payload"] as? [String: Any],
      let type = payload["type"] as? String,
      type == "task_complete" || type == "turn_aborted"
    else {
      return nil
    }
    return payload
  }

  private static func decodeClaude(records: [[String: Any]], maxBytes: Int) -> AgentTranscriptResult {
    guard let closeRecord = records.last(where: isClaudeTurnDuration) else {
      return .failure(.missing)
    }
    guard let closeSessionID = closeRecord["sessionId"] as? String,
      var parentID = closeRecord["parentUuid"] as? String
    else {
      return .failure(.incomplete)
    }

    var recordsByUUID: [String: [String: Any]] = [:]
    for record in records {
      guard let uuid = record["uuid"] as? String else { continue }
      guard recordsByUUID[uuid] == nil else { return .failure(.incomplete) }
      recordsByUUID[uuid] = record
    }

    for _ in 0..<32 {
      guard let record = recordsByUUID[parentID], record["sessionId"] as? String == closeSessionID else {
        return .failure(.incomplete)
      }
      if record["type"] as? String == "assistant" {
        return decodeClaudeAssistant(record, maxBytes: maxBytes)
      }
      guard let nextParentID = record["parentUuid"] as? String, nextParentID != parentID else {
        return .failure(.incomplete)
      }
      parentID = nextParentID
    }
    return .failure(.incomplete)
  }

  private static func isClaudeTurnDuration(_ record: [String: Any]) -> Bool {
    record["type"] as? String == "system" && record["subtype"] as? String == "turn_duration"
  }

  private static func decodeClaudeAssistant(
    _ record: [String: Any],
    maxBytes: Int
  ) -> AgentTranscriptResult {
    guard let message = record["message"] as? [String: Any],
      let stopReason = message["stop_reason"] as? String,
      stopReason == "end_turn" || stopReason == "stop_sequence",
      let content = message["content"] as? [[String: Any]],
      !content.isEmpty
    else {
      return .failure(.incomplete)
    }

    var text = ""
    for block in content {
      guard block["type"] as? String == "text", let value = block["text"] as? String else {
        return .failure(.incomplete)
      }
      text += value
    }
    guard !text.isEmpty else { return .failure(.incomplete) }
    return bounded(text, maxBytes: maxBytes)
  }

  private static func bounded(_ text: String, maxBytes: Int) -> AgentTranscriptResult {
    text.utf8.count <= maxBytes ? .complete(text) : .failure(.tooLarge)
  }
}
