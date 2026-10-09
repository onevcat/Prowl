import Foundation

/// What a Codex rollout says about ownership: its thread, its parent thread, and the
/// client message ids of the user messages it holds, in file order.
nonisolated struct CodexDaemonRollout: Sendable, Equatable {
  let id: String
  let parentID: String?
  var clientIDs: [String]
  var path = ""
  /// A fork copies history before its own `thread_settings_applied`; that part is not live.
  var isForked = false
  /// Byte offset of the live `task_started` line that precedes each client message id.
  var turnStartOffsets: [String: UInt64] = [:]
}

/// The rollouts a pane's Codex TUI currently drives through the daemon (docs-ai 073.002).
nonisolated struct CodexDaemonBinding: Sendable, Equatable {
  let rootID: String
  /// The root thread and every descendant the daemon holds open.
  let paths: [String]
  /// Where reading the bound rollout starts: the turn that holds the pane's newest submit.
  let liveOffsets: [String: UInt64]
}

/// A known selection change must not fall back to matching the previous thread's history.
nonisolated enum CodexDaemonBindingLookup: Sendable {
  case unavailable
  case selectionPending
  /// This selection was bound, but its current evidence is temporarily unavailable.
  case selectionUnavailable
  case bound(CodexDaemonBinding)

  var binding: CodexDaemonBinding? {
    if case .bound(let binding) = self { return binding }
    return nil
  }
}

/// The submits of the TUI that last started a pane's session log.
nonisolated struct CodexTUISessionRecord: Sendable, Equatable {
  struct Submit: Sendable, Equatable {
    let clientID: String
    let submittedAt: Date
  }

  let surfaceID: UUID
  let startedAt: Date
  let submits: [Submit]
  /// Earlier submits still route callers, but cannot identify the selected transcript.
  var selectionSubmitOffset: Int?
  /// Distinguishes repeated resets without an intervening submit.
  var selectionRevision = 0
}

/// Maps a thread that Codex's shared app-server daemon runs to the pane whose TUI drives it
/// (docs-ai 073).
///
/// Each pane runs Codex with a `CodexTUISessionLog`. Every submit writes a `UserTurn` op with
/// a fresh `client_user_message_id`, and the daemon stores the same value as the `client_id`
/// of the `UserMessage` item in the target thread's rollout. A pane is bound to the thread of
/// its newest submit that a rollout already holds: a newer unmatched id is a turn whose item
/// is not written yet, or a steer that waits for the next tool boundary. A child thread
/// belongs to the root its rollout header names.
actor CodexDaemonThreadMapper {
  static let shared = CodexDaemonThreadMapper()

  typealias Rollout = CodexDaemonRollout
  typealias SessionLog = CodexTUISessionRecord

  private struct Cursor {
    let inode: UInt64
    var offset: UInt64
    var pending = Data()
    var headerRead = false
    var live = true
    var lastTurnStart: UInt64?
    var rollout: Rollout?
  }

  private struct Selection {
    let tuiStartedAt: Date
    let logStartedAt: Date
    let revision: Int
    var hasBound = false

    var missing: CodexDaemonBindingLookup { hasBound ? .selectionUnavailable : .selectionPending }
  }

  // Keep only the selection fence across read failures, never stale rollout evidence.
  private var selections: [UUID: Selection] = [:]
  private let openFilePaths: @Sendable (pid_t) -> [String]?
  private var sessionLogCache: CodexTUISessionLogCache
  private let sessionLogDirectory: URL
  private let fileManager: FileManager
  private var cursors: [String: Cursor] = [:]
  /// A first lookup reads each open rollout once; later lookups read only appended bytes.
  private let readBudget = 256 * 1_024 * 1_024

  init(
    sessionLogDirectory: URL = ProwlPaths.codexTUISessionLogDirectory,
    fileManager: FileManager = .default,
    readSessionLog: @escaping @Sendable (URL) throws -> Data = CodexTUISessionLogCache.readStable,
    openFilePaths: @escaping @Sendable (pid_t) -> [String]? = { pid in
      var complete = false
      let paths = ProcessDetection.openFilePaths(pid: pid, complete: &complete)
      return complete ? paths : nil
    }
  ) {
    self.sessionLogDirectory = sessionLogDirectory
    self.fileManager = fileManager
    self.sessionLogCache = CodexTUISessionLogCache(read: readSessionLog)
    self.openFilePaths = openFilePaths
  }

  /// The pane driving `threadID`, or nil when the evidence is missing, incomplete, or ambiguous.
  func pane(threadID: String, daemonPID: pid_t) -> CodexThreadPane? {
    guard let paths = openFilePaths(daemonPID), let rollouts = refreshRollouts(paths.filter(Self.isRolloutPath))
    else { return nil }
    return Self.resolve(threadID: threadID, rollouts: rollouts, logs: sessionLogs())
  }

  /// What the pane's current Codex TUI drives, or nil before its first indexed submit. The
  /// session log must belong to the TUI process that started at `tuiStartedAt`.
  func binding(surfaceID: UUID, daemonPID: pid_t, tuiStartedAt: Date) -> CodexDaemonBinding? {
    bindingLookup(surfaceID: surfaceID, daemonPID: daemonPID, tuiStartedAt: tuiStartedAt).binding
  }

  func bindingLookup(surfaceID: UUID, daemonPID: pid_t, tuiStartedAt: Date) -> CodexDaemonBindingLookup {
    if selections[surfaceID]?.tuiStartedAt != tuiStartedAt { selections[surfaceID] = nil }
    let url = CodexTUISessionLog.url(for: surfaceID, in: sessionLogDirectory)
    guard let log = sessionLogCache.record(at: url, surfaceID: surfaceID),
      CodexTUISessionLog.belongs(sessionStartedAt: log.startedAt, toProcessStartedAt: tuiStartedAt)
    else { return selections[surfaceID]?.missing ?? .unavailable }
    if log.selectionSubmitOffset == nil {
      selections[surfaceID] = nil
    } else if selections[surfaceID]?.logStartedAt != log.startedAt
      || selections[surfaceID]?.revision != log.selectionRevision
    {
      selections[surfaceID] = Selection(
        tuiStartedAt: tuiStartedAt, logStartedAt: log.startedAt, revision: log.selectionRevision)
    }
    guard !log.submits.isEmpty, let paths = openFilePaths(daemonPID),
      let rollouts = refreshRollouts(paths.filter(Self.isRolloutPath)),
      let binding = Self.binding(for: log, rollouts: rollouts)
    else { return selections[surfaceID]?.missing ?? .unavailable }
    selections[surfaceID]?.hasBound = true
    return .bound(binding)
  }

  // MARK: - Resolution

  static func binding(for log: SessionLog, rollouts: [Rollout]) -> CodexDaemonBinding? {
    let byID = Dictionary(rollouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard let owner = owners(rollouts) else { return nil }
    guard let submit = log.submits.dropFirst(log.selectionSubmitOffset ?? 0).last(where: { owner[$0.clientID] != nil }),
      let bound = owner[submit.clientID].flatMap({ byID[$0] })
    else { return nil }
    let rootID = root(of: bound.id, in: byID)
    let family = rollouts.filter { root(of: $0.id, in: byID) == rootID }
    return CodexDaemonBinding(
      rootID: rootID,
      paths: family.map(\.path).sorted(),
      liveOffsets: bound.turnStartOffsets[submit.clientID].map { [bound.path: $0] } ?? [:]
    )
  }

  private static func owners(_ rollouts: [Rollout]) -> [String: String]? {
    var owner: [String: String] = [:]
    for rollout in rollouts {
      for clientID in rollout.clientIDs {
        guard owner[clientID] == nil || owner[clientID] == rollout.id else { return nil }
        owner[clientID] = rollout.id
      }
    }
    return owner
  }

  private static func root(of id: String, in byID: [String: Rollout]) -> String {
    var current = id
    var visited: Set<String> = []
    while let parent = byID[current]?.parentID, visited.insert(current).inserted {
      current = parent
    }
    return current
  }

  static func resolve(threadID: String, rollouts: [Rollout], logs: [SessionLog]) -> CodexThreadPane? {
    let byID = Dictionary(rollouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard let owner = owners(rollouts) else { return nil }
    func root(_ id: String) -> String { Self.root(of: id, in: byID) }
    let target = root(threadID)
    let bound = logs.compactMap { log -> (log: SessionLog, submittedAt: Date)? in
      guard let submit = log.submits.last(where: { owner[$0.clientID] != nil }),
        let thread = owner[submit.clientID], root(thread) == target
      else { return nil }
      return (log, submit.submittedAt)
    }
    guard let newest = bound.max(by: { $0.submittedAt < $1.submittedAt }),
      bound.filter({ $0.submittedAt == newest.submittedAt }).count == 1
    else { return nil }
    return CodexThreadPane(surfaceID: newest.log.surfaceID, sessionStartedAt: newest.log.startedAt)
  }

  // MARK: - Session logs

  private func sessionLogs() -> [SessionLog] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: sessionLogDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return entries.compactMap { entry in
      guard let surfaceID = CodexTUISessionLog.surfaceID(forFileName: entry.lastPathComponent) else { return nil }
      return sessionLogCache.record(at: entry, surfaceID: surfaceID)
    }
  }

  /// The submits of the TUI that last started this log. Each TUI launch truncates the file.
  static func parseSessionLog(_ data: Data, surfaceID: UUID) -> SessionLog? {
    var startedAt: Date?
    var submits: [SessionLog.Submit] = []
    var selectionSubmitOffset: Int?
    var selectionRevision = 0
    for line in data.split(separator: 10) {
      let isStart = line.range(of: Data("\"session_start\"".utf8)) != nil
      let isSelection =
        line.range(of: Data("\"new_session\"".utf8)) != nil
        || line.range(of: Data("\"clear_ui\"".utf8)) != nil
        || line.range(of: Data("ResetTranscriptForThreadSwitch".utf8)) != nil
      guard isStart || isSelection || line.range(of: Data("\"UserTurn\"".utf8)) != nil,
        let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let timestamp = (record["ts"] as? String).flatMap(parseTimestamp)
      else { continue }
      if record["kind"] as? String == "session_start" {
        startedAt = timestamp
        submits = []
        selectionSubmitOffset = nil
        selectionRevision = 0
      } else if isSelection,
        record["kind"] as? String == "new_session" || record["kind"] as? String == "clear_ui"
          || (record["kind"] as? String == "app_event"
            && ["ResetTranscriptForThreadSwitch", "ResetTranscriptForThreadSwitchPreservingScreen"]
              .contains(record["variant"] as? String ?? ""))
      {
        selectionSubmitOffset = submits.count
        selectionRevision += 1
      } else if record["kind"] as? String == "op",
        let turn = (record["payload"] as? [String: Any])?["UserTurn"] as? [String: Any],
        let clientID = turn["client_user_message_id"] as? String, !clientID.isEmpty
      {
        submits.append(.init(clientID: clientID, submittedAt: timestamp))
      }
    }
    return startedAt.map {
      SessionLog(
        surfaceID: surfaceID, startedAt: $0, submits: submits,
        selectionSubmitOffset: selectionSubmitOffset, selectionRevision: selectionRevision)
    }
  }

  private static func parseTimestamp(_ value: String) -> Date? {
    try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
  }

  // MARK: - Rollouts

  static func isRolloutPath(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
  }

  /// Reads the bytes appended since the last lookup. Returns nil when a file changed identity
  /// or the budget ran out, because a partial index could bind a pane to a stale thread.
  private func refreshRollouts(_ paths: [String]) -> [Rollout]? {
    var next = cursors.filter { paths.contains($0.key) }
    var budget = readBudget
    for path in paths {
      guard let attributes = try? fileManager.attributesOfItem(atPath: path),
        let inode = attributes[.systemFileNumber] as? UInt64,
        let size = attributes[.size] as? UInt64
      else { return nil }
      var cursor =
        next[path].flatMap { $0.inode == inode && size >= $0.offset ? $0 : nil }
        ?? Cursor(inode: inode, offset: 0)
      guard size > cursor.offset else {
        next[path] = cursor
        continue
      }
      guard size - cursor.offset <= UInt64(budget), let handle = FileHandle(forReadingAtPath: path) else {
        cursors = next
        return nil
      }
      defer { try? handle.close() }
      do {
        try handle.seek(toOffset: cursor.offset)
        let bytes = try handle.read(upToCount: Int(size - cursor.offset)) ?? Data()
        budget -= bytes.count
        cursor.offset += UInt64(bytes.count)
        cursor.pending.append(bytes)
      } catch {
        return nil
      }
      Self.consume(&cursor, path: path)
      next[path] = cursor
    }
    cursors = next
    return next.values.compactMap(\.rollout)
  }

  private static func consume(_ cursor: inout Cursor, path: String) {
    let base = cursor.offset - UInt64(cursor.pending.count)
    var start = cursor.pending.startIndex
    while let end = cursor.pending[start...].firstIndex(of: 10) {
      let line = cursor.pending[start..<end]
      let lineOffset = base + UInt64(start - cursor.pending.startIndex)
      start = end + 1
      if !cursor.headerRead {
        cursor.headerRead = true
        cursor.rollout = header(line)
        cursor.rollout?.path = path
        cursor.live = cursor.rollout?.isForked != true
        continue
      }
      guard let id = cursor.rollout?.id else { continue }
      if !cursor.live {
        cursor.live = isLiveBoundary(line, threadID: id)
      } else if isTaskStarted(line) {
        cursor.lastTurnStart = lineOffset
      } else if let clientID = userMessageClientID(line) {
        cursor.rollout?.clientIDs.append(clientID)
        cursor.rollout?.turnStartOffsets[clientID] = cursor.lastTurnStart
      }
    }
    cursor.pending.removeSubrange(cursor.pending.startIndex..<start)
  }

  static func header(_ line: Data) -> Rollout? {
    guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      record["type"] as? String == "session_meta",
      let payload = record["payload"] as? [String: Any],
      let id = payload["id"] as? String, !id.isEmpty
    else { return nil }
    let source = payload["source"] as? [String: Any]
    let spawn = (source?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
    return Rollout(
      id: id, parentID: spawn?["parent_thread_id"] as? String, clientIDs: [],
      isForked: payload["forked_from_id"] is String)
  }

  private static func eventPayload(_ line: Data, type: String) -> [String: Any]? {
    guard line.range(of: Data("\"\(type)\"".utf8)) != nil,
      let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      record["type"] as? String == "event_msg",
      let payload = record["payload"] as? [String: Any],
      payload["type"] as? String == type
    else { return nil }
    return payload
  }

  static func isTaskStarted(_ line: Data) -> Bool {
    eventPayload(line, type: "task_started") != nil
  }

  static func isLiveBoundary(_ line: Data, threadID: String) -> Bool {
    eventPayload(line, type: "thread_settings_applied")?["thread_id"] as? String == threadID
  }

  static func userMessageClientID(_ line: Data) -> String? {
    guard line.range(of: Data("\"client_id\"".utf8)) != nil,
      let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      record["type"] as? String == "event_msg",
      let payload = record["payload"] as? [String: Any],
      payload["type"] as? String == "item_completed",
      let item = payload["item"] as? [String: Any],
      item["type"] as? String == "UserMessage",
      let clientID = item["client_id"] as? String, !clientID.isEmpty
    else { return nil }
    return clientID
  }
}
