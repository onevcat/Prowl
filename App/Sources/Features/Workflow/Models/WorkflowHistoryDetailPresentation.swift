import Foundation
import ProwlCLIShared

nonisolated struct WorkflowHistoryRole {
  let role: String
  let agent: String?
  let livePane: WorkflowPaneIdentity?

  init(role: String, binding: WorkflowRunRecord.Binding, livePaneIDs: Set<UUID>) {
    self.role = role
    agent = binding.pane?.agent ?? binding.profile?.agent
    livePane = binding.pane.flatMap { livePaneIDs.contains($0.surfaceID) ? $0 : nil }
  }
}

nonisolated struct WorkflowHistoryTextPreview {
  static let maximumBytes = 64 * 1024 * 1024
  let text: String
  let remainingCharacters: Int

  init(_ body: String) {
    text = String(body.prefix(200))
    remainingCharacters = max(0, body.count - text.count)
  }

  static func read(_ url: URL, storage: WorkflowHistoryStorage) throws -> Self {
    let data = try storage.read(url, limit: maximumBytes)
    guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
    return Self(text)
  }
}

nonisolated struct WorkflowHistoryFileRevision: Hashable {
  var updatedAt: Date?
  var state: String?
}

nonisolated struct WorkflowHistoryFileLoadKey: Hashable {
  let url: URL
  let revision: WorkflowHistoryFileRevision
}

nonisolated struct WorkflowHistoryOutputField: Identifiable {
  let key: String
  let value: WorkflowJSONValue
  var depth = 0
  var id: String { key }
  var displayKey: String { String(key.prefix(100)) }

  static func fields(_ values: [String: WorkflowJSONValue], depth: Int = 0) -> [Self] {
    values.keys.sorted().prefix(32).map { Self(key: $0, value: values[$0]!, depth: depth) }
  }

  var children: [Self]? {
    guard depth < 5 else { return nil }
    switch value {
    case .object(let values): return Self.fields(values, depth: depth + 1)
    case .array(let values):
      return values.prefix(32).enumerated().map { Self(key: "[\($0.offset)]", value: $0.element, depth: depth + 1) }
    default: return nil
    }
  }

  var childCount: Int {
    switch value {
    case .object(let values): values.count
    case .array(let values): values.count
    default: 0
    }
  }

  var summary: String {
    switch value {
    case .object(let values): "\(values.count) fields"
    case .array(let values): "\(values.count) items"
    case .string(let text): String(text.prefix(200)) + (text.dropFirst(200).isEmpty ? "" : "…")
    default: (try? String(bytes: JSONEncoder().encode(value), encoding: .utf8)) ?? "null"
    }
  }

  var fileURL: URL? {
    guard key == "path" || key.hasSuffix("_path"), case .string(let path) = value,
      path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0")
    else { return nil }
    return URL(filePath: path)
  }
}

nonisolated enum WorkflowHistoryTiming {
  static func duration(_ interval: TimeInterval) -> String {
    guard interval.isFinite, interval >= 1 else { return "<1s" }
    let seconds = Int(min(interval, Double(Int.max / 2)))
    var parts: [String] = []
    if seconds >= 3600 { parts.append("\(seconds / 3600)h") }
    if seconds >= 60 { parts.append("\(seconds % 3600 / 60)m") }
    parts.append("\(seconds % 60)s")
    return parts.joined(separator: " ")
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }

  static func actionDuration(_ data: Data) -> TimeInterval? {
    guard let value = try? JSONDecoder().decode(WorkflowJSONValue.self, from: data),
      case .object(let fields) = value,
      case .string(let start) = fields["started_at"], case .string(let end) = fields["finished_at"]
    else { return nil }
    let formatter = ISO8601DateFormatter()
    guard let start = formatter.date(from: start), let end = formatter.date(from: end), end >= start else { return nil }
    return end.timeIntervalSince(start)
  }

  static func durations(
    _ groups: [WorkflowHistoryStepGroup], record: WorkflowRunRecord, directory: URL?, storage: WorkflowHistoryStorage
  ) -> [String: TimeInterval] {
    let invocations = Dictionary(record.invocations.map { ($0.ordinal, $0) }, uniquingKeysWith: { first, _ in first })
    var result: [String: TimeInterval] = [:]
    for group in groups {
      let durations: [TimeInterval] = group.attempts.compactMap { attempt in
        if let ordinal = attempt.ordinal, let invocation = invocations[ordinal], let end = invocation.endedAt,
          end >= invocation.startedAt
        {
          return end.timeIntervalSince(invocation.startedAt)
        }
        guard let directory, let path = diagnosticDirectory(attempt, directory: directory),
          let data = try? storage.read(path.appending(path: "execution.json"), limit: 64 * 1024)
        else { return nil }
        return actionDuration(data)
      }
      if !durations.isEmpty, durations.count == group.attempts.count {
        result[group.id] = durations.reduce(0, +)
      }
    }
    return result
  }

  static func diagnosticDirectory(_ attempt: WorkflowRunRecord.Step, directory: URL) -> URL? {
    guard WorkflowSchema.isSlug(attempt.id), let execution = attempt.actionExecutionID,
      UUID(uuidString: execution) != nil
    else { return nil }
    return directory.appending(path: "actions/\(attempt.id)/\(execution)")
  }
}

nonisolated enum WorkflowHistoryArtifact {
  static func validate(_ url: URL, worktree: URL, storage: WorkflowHistoryStorage) throws {
    if url.path.hasPrefix(storage.baseURL.path + "/") {
      try storage.validate(url)
    } else {
      // Resolve the worktree alias, but never resolve links within the artifact path.
      let files = WorkflowHistoryStorage(baseURL: worktree)
      let roots = [worktree.path, files.baseURL.path]
      guard let root = roots.first(where: { url.path.hasPrefix($0 + "/.prowl/handoff/") }) else {
        throw WorkflowHistoryError.unsafePath(url.path)
      }
      let relative = String(url.path.dropFirst(root.count + 1))
      try files.validate(files.baseURL.appending(path: relative))
    }
  }
}
