import Foundation

/// Incremental, bounded log acquisition. The existing detection clock drives reconciliation;
/// no file inactivity timeout is used to infer completion.
actor CodexLogProvider {
  private struct Metadata {
    let id: String
    let parent: String?
    let hasInheritedHistory: Bool
  }

  private struct Cursor {
    let metadata: Metadata
    let inode: UInt64
    var offset: UInt64
    var pending = Data()
    var decoder: CodexLogDecoder
  }

  private enum Failure: Error { case incomplete, notReady }
  private let startedAt: Date
  private var cursors: [URL: Cursor] = [:]
  private var needsBaseline = false
  private let byteLimit = 8 * 1_024 * 1_024

  init(startedAt: Date = Date()) {
    self.startedAt = startedAt
  }

  func sample(process: AgentProcessGeneration, configRoot: URL?) -> [AgentDetectionEvent] {
    guard ProcessDetection.processStartDate(pid: process.pid) == process.startedAt else { return [.unavailable] }
    let parse = AgentSessionResolver.pathParser(profile: .profile(for: .codex), configRoot: configRoot)
    var complete = false
    let paths = ProcessDetection.openFilePaths(pid: process.pid, complete: &complete)
      .compactMap { parse($0)?.transcriptPath }
    guard complete else { return [.suspended] }
    let events = sample(paths: paths)
    guard ProcessDetection.processStartDate(pid: process.pid) == process.startedAt else { return [.unavailable] }
    return events
  }

  func sample(paths: [URL]) -> [AgentDetectionEvent] {
    do {
      return try read(paths: Array(Set(paths)))
    } catch Failure.notReady {
      return [.suspended]
    } catch {
      cursors.removeAll()
      needsBaseline = true
      return [.unavailable]
    }
  }

  private func read(paths: [URL]) throws -> [AgentDetectionEvent] {
    guard paths.count <= 32 else { throw Failure.incomplete }
    var next = cursors.filter { paths.contains($0.key) }
    var remaining = byteLimit
    for path in paths where next[path] == nil {
      let handle = try FileHandle(forReadingFrom: path)
      defer { try? handle.close() }
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
      throw Failure.incomplete
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
      while let end = cursor.pending.firstIndex(of: 10) {
        let line = cursor.pending.prefix(upTo: end)
        events += try cursor.decoder.consume(Data(line), root: rootID)
        cursor.pending.removeSubrange(...end)
      }
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
    if let source = payload["source"] as? [String: Any] {
      guard let subagent = source["subagent"] as? [String: Any],
        let spawn = subagent["thread_spawn"] as? [String: Any],
        let parentID = spawn["parent_thread_id"] as? String
      else { throw Failure.incomplete }
      parent = parentID
    } else if payload["source"] as? String != "cli" {
      throw Failure.incomplete
    }
    // Fresh mains and children can omit settings events. Lineage alone does not
    // imply copied history; only forks need their own live boundary.
    return Metadata(id: id, parent: parent, hasInheritedHistory: payload["forked_from_id"] is String)
  }
}
