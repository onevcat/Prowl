import Foundation

/// Incremental, bounded log acquisition. The existing detection clock drives reconciliation;
/// no file inactivity timeout is used to infer completion.
actor CodexLogProvider {
  private struct Metadata {
    let id: String
    let parent: String?
    let hasInheritedHistory: Bool
    let understood: Bool
  }

  private struct Cursor {
    let metadata: Metadata
    let inode: UInt64
    var offset: UInt64
    var pending = Data()
    var decoder: CodexLogDecoder
  }

  private enum Failure: Error { case incomplete, notReady, unknownLineage }
  private var lastDiagnosticAt: TimeInterval?
  private var reportedFailure = false
  private var processID: pid_t?
  private(set) var metadataReadCount = 0
  private let diagnostic: @Sendable (String) -> Void
  private let time: @Sendable () -> TimeInterval
  private let startedAt: Date
  private var cursors: [URL: Cursor] = [:]
  private var needsBaseline = false
  private let byteLimit = 8 * 1_024 * 1_024

  init(
    startedAt: Date = Date(),
    time: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    diagnostic: @escaping @Sendable (String) -> Void = { SupaLogger("AgentDetection").warning($0) }
  ) {
    self.startedAt = startedAt
    self.time = time
    self.diagnostic = diagnostic
  }

  func sample(process: AgentProcessGeneration, configRoot: URL?) -> [AgentDetectionEvent] {
    processID = process.pid
    guard ProcessDetection.processStartDate(pid: process.pid) == process.startedAt else { return [.unavailable] }
    let parse = AgentSessionResolver.pathParser(profile: .profile(for: .codex), configRoot: configRoot)
    var complete = false
    let paths = ProcessDetection.openFilePaths(pid: process.pid, complete: &complete)
      .compactMap { parse($0)?.transcriptPath }
    let events = sample(paths: paths, inventoryComplete: complete)
    guard ProcessDetection.processStartDate(pid: process.pid) == process.startedAt else { return [.unavailable] }
    return events
  }

  func sample(paths: [URL], inventoryComplete: Bool = true) -> [AgentDetectionEvent] {
    guard inventoryComplete else {
      report("incompleteInventory")
      return [.suspended]
    }
    do {
      let events = try read(paths: Array(Set(paths)))
      report(nil)
      return events
    } catch Failure.notReady {
      report("partialHeader")
      return [.suspended]
    } catch Failure.unknownLineage {
      report("unknownLineage")
      return [.suspended]
    } catch {
      report("continuityLost")
      cursors.removeAll()
      needsBaseline = true
      return [.unavailable]
    }
  }

  private func report(_ failure: String?) {
    let now = time()
    if failure != nil {
      guard lastDiagnosticAt.map({ now - $0 >= 30 }) ?? true else { return }
      lastDiagnosticAt = now
      reportedFailure = true
    } else {
      guard reportedFailure else { return }
      reportedFailure = false
    }
    let pid = processID.map(String.init) ?? "unbound"
    diagnostic("Log provider pid=\(pid) status=\(failure ?? "recovered") cursors=\(cursors.count)")
  }

  private func read(paths: [URL]) throws -> [AgentDetectionEvent] {
    guard paths.count <= 32 else { throw Failure.incomplete }
    var next = cursors.filter { paths.contains($0.key) }
    var remaining = byteLimit
    for path in paths where next[path] == nil {
      let handle = try FileHandle(forReadingFrom: path)
      defer { try? handle.close() }
      metadataReadCount += 1
      let header = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
      guard let end = header.firstIndex(of: 10) else {
        throw header.count < 1_024 * 1_024 ? Failure.notReady : Failure.incomplete
      }
      let metadata = try metadata(from: header.prefix(upTo: end))
      let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
      guard let inode = attributes[.systemFileNumber] as? UInt64,
        let size = attributes[.size] as? UInt64,
        let createdAt = attributes[.creationDate] as? Date
      else { throw Failure.incomplete }
      let baseline = needsBaseline || createdAt < startedAt
      next[path] = Cursor(
        metadata: metadata, inode: inode, offset: baseline ? size : UInt64(end + 1),
        decoder: CodexLogDecoder(sessionID: metadata.id, isLive: baseline || !metadata.hasInheritedHistory))
    }
    // Cache discovery separately from event consumption. Unsupported lineage
    // suspends authority without rereading headers or discarding observed work.
    for (path, cursor) in next {
      let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
      guard attributes[.systemFileNumber] as? UInt64 == cursor.inode,
        let size = attributes[.size] as? UInt64, size >= cursor.offset
      else { throw Failure.incomplete }
    }
    cursors = next
    guard next.values.allSatisfy({ $0.metadata.understood }) else { throw Failure.unknownLineage }
    let parents = Dictionary(
      next.values.map { ($0.metadata.id, $0.metadata.parent) }, uniquingKeysWith: { first, _ in first })
    func root(for id: String) throws -> String {
      var current = id
      var visited: Set<String> = []
      while let entry = parents[current] {
        guard visited.insert(current).inserted else { throw Failure.incomplete }
        guard let parent = entry else { return current }
        current = parent
      }
      throw Failure.unknownLineage
    }
    let roots = try Set(next.values.map { try root(for: $0.metadata.id) })
    var events: [AgentDetectionEvent] = [.inventory(roots)]
    // Root starts are delivered before child-file starts. Own child turn IDs replace
    // provisional spawn IDs, so a delayed completion cannot close reused child work.
    let ordered = paths.sorted {
      (next[$0]?.metadata.parent == nil ? 0 : 1) < (next[$1]?.metadata.parent == nil ? 0 : 1)
    }
    for path in ordered {
      guard var cursor = next[path] else { throw Failure.incomplete }
      let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
      guard attributes[.systemFileNumber] as? UInt64 == cursor.inode,
        let size = attributes[.size] as? UInt64, size >= cursor.offset,
        size - cursor.offset <= UInt64(remaining)
      else { throw Failure.incomplete }
      if size == cursor.offset { continue }
      let handle = try FileHandle(forReadingFrom: path)
      defer { try? handle.close() }
      try handle.seek(toOffset: cursor.offset)
      let bytes = try handle.read(upToCount: Int(size - cursor.offset)) ?? Data()
      cursor.offset += UInt64(bytes.count)
      remaining -= bytes.count
      cursor.pending.append(bytes)
      let rootID = try root(for: cursor.metadata.id)
      var consumed = cursor.pending.startIndex
      while let end = cursor.pending[consumed...].firstIndex(of: 10) {
        let line = cursor.pending[consumed..<end]
        events += try cursor.decoder.consume(Data(line), root: rootID)
        consumed = end + 1
      }
      cursor.pending.removeSubrange(cursor.pending.startIndex..<consumed)
      guard cursor.pending.count <= 1_024 * 1_024 else { throw Failure.incomplete }
      next[path] = cursor
    }
    cursors = next
    needsBaseline = false
    return events
  }

  private func metadata(from data: Data) throws -> Metadata {
    guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      record["type"] as? String == "session_meta",
      let payload = record["payload"] as? [String: Any],
      let id = payload["id"] as? String, !id.isEmpty
    else { throw Failure.incomplete }
    var parent: String?
    let understood: Bool
    if let source = payload["source"] as? [String: Any] {
      let subagent = source["subagent"] as? [String: Any]
      let spawn = subagent?["thread_spawn"] as? [String: Any]
      parent = spawn?["parent_thread_id"] as? String
      understood = parent?.isEmpty == false
    } else {
      // Resume keeps the original launch source in the rollout header.
      understood = ["cli", "exec", "vscode", "mcp"].contains(payload["source"] as? String ?? "")
    }
    // Fresh mains and children can omit settings events. Lineage alone does not
    // imply copied history; only forks need their own live boundary.
    return Metadata(
      id: id, parent: parent, hasInheritedHistory: payload["forked_from_id"] is String, understood: understood)
  }
}
