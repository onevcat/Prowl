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
  private var lastDiagnosticAt: [String: TimeInterval] = [:]
  private var reportedFailure = false
  private var processID: pid_t?
  private(set) var metadataReadCount = 0
  private let diagnostic: @Sendable (String) -> Void
  private let time: @Sendable () -> TimeInterval
  private let startedAt: Date
  private var cursors: [URL: Cursor] = [:]
  private var needsBaseline = false
  private let byteLimit = 8 * 1_024 * 1_024
  /// Codex 0.157+ TUIs attached to the shared daemon hold no rollout; the daemon does
  /// (docs-ai 073.002). Nil for a caller that has no pane.
  private let daemonBinding: DaemonBinding?

  typealias DaemonBinding = @Sendable (AgentProcessGeneration, URL?) async -> CodexDaemonBinding?

  init(
    surfaceID: UUID? = nil,
    startedAt: Date = Date(),
    time: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    diagnostic: @escaping @Sendable (String) -> Void = { ProwlLogger("AgentDetection").warning($0) },
    daemonBinding: DaemonBinding? = nil
  ) {
    self.startedAt = startedAt
    self.time = time
    self.diagnostic = diagnostic
    self.daemonBinding = daemonBinding ?? surfaceID.map(Self.daemonBinding(surfaceID:))
  }

  func sample(process: AgentProcessGeneration, configRoot: URL?) async -> [AgentDetectionEvent] {
    processID = process.pid
    guard ProcessDetection.processStartDate(pid: process.pid) == process.startedAt else { return [.unavailable] }
    let parse = AgentSessionResolver.pathParser(profile: .profile(for: .codex), configRoot: configRoot)
    var complete = false
    var paths = ProcessDetection.openFilePaths(pid: process.pid, complete: &complete)
      .compactMap { parse($0)?.transcriptPath }
    var liveOffsets: [URL: UInt64] = [:]
    // An embedded TUI owns its rollouts. A TUI that owns none may drive daemon threads.
    if complete, paths.isEmpty, let daemonBinding {
      if let binding = await daemonBinding(process, configRoot) {
        paths = binding.paths.map { URL(filePath: $0, directoryHint: .notDirectory) }
        for (path, offset) in binding.liveOffsets {
          liveOffsets[URL(filePath: path, directoryHint: .notDirectory)] = offset
        }
      } else if !cursors.isEmpty {
        // A failed lookup does not prove that previously bound work disappeared.
        // Suspend authority and keep the cursors until a complete binding returns.
        complete = false
      }
    }
    let events = sample(paths: paths, inventoryComplete: complete, liveOffsets: liveOffsets)
    guard ProcessDetection.processStartDate(pid: process.pid) == process.startedAt else { return [.unavailable] }
    return events
  }

  /// `liveOffsets` start a newly discovered rollout at a turn boundary instead of its end, so
  /// a daemon thread bound after its turn began still reports that turn.
  func sample(
    paths: [URL], inventoryComplete: Bool = true, liveOffsets: [URL: UInt64] = [:]
  ) -> [AgentDetectionEvent] {
    guard inventoryComplete else {
      report("incompleteInventory")
      return [.suspended]
    }
    do {
      let events = try read(paths: Array(Set(paths)), liveOffsets: liveOffsets)
      report(nil)
      return events
    } catch Failure.notReady {
      report("partialHeader")
      return [.suspended]
    } catch Failure.unknownLineage {
      report("unknownLineage")
      return [.suspended]
    } catch {
      cursors.removeAll()
      let detail =
        error is CodexLogDecoder.Failure
        ? "invalidRecord" : error is Failure ? "incomplete" : "ioOrJSON(code=\((error as NSError).code))"
      report("continuityLost", detail: detail)
      needsBaseline = true
      return [.unavailable]
    }
  }

  private func report(_ failure: String?, detail: String? = nil) {
    let now = time()
    if let failure {
      reportedFailure = true
      guard lastDiagnosticAt[failure].map({ now - $0 >= 30 }) ?? true else { return }
      lastDiagnosticAt[failure] = now
    } else {
      guard reportedFailure else { return }
      reportedFailure = false
    }
    let pid = processID.map(String.init) ?? "unbound"
    diagnostic(
      "Log provider pid=\(pid) status=\(failure ?? "recovered") cursors=\(cursors.count) detail=\(detail ?? "none")")
  }

  private func read(paths: [URL], liveOffsets: [URL: UInt64]) throws -> [AgentDetectionEvent] {
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
      // A live offset points at a `task_started` after any inherited history.
      let liveOffset = liveOffsets[path].flatMap { $0 > UInt64(end) && $0 <= size ? $0 : nil }
      next[path] = Cursor(
        metadata: metadata, inode: inode, offset: liveOffset ?? (baseline ? size : UInt64(end + 1)),
        decoder: CodexLogDecoder(
          sessionID: metadata.id, isLive: liveOffset != nil || baseline || !metadata.hasInheritedHistory))
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

  private static func daemonBinding(surfaceID: UUID) -> DaemonBinding {
    { process, configRoot in
      await lookupDaemonBinding(surfaceID: surfaceID, process: process, configRoot: configRoot).binding
    }
  }

  nonisolated static func lookupDaemonBinding(
    surfaceID: UUID, process: AgentProcessGeneration, configRoot: URL?
  ) async -> CodexDaemonBindingLookup {
    let home = configRoot ?? codexHome(forTUI: process.pid)
    guard let daemonPID = managedDaemonPID(codexHome: home) else { return .unavailable }
    return await CodexDaemonThreadMapper.shared.bindingLookup(
      surfaceID: surfaceID, daemonPID: daemonPID, tuiStartedAt: process.startedAt)
  }

  /// The TUI's own `CODEX_HOME` selects its daemon socket, so it also selects the daemon.
  nonisolated static func codexHome(forTUI pid: pid_t) -> URL {
    if let home = ProcessDetection.processEnvironmentValue(pid: pid, name: "CODEX_HOME"), home.hasPrefix("/") {
      return URL(filePath: home, directoryHint: .isDirectory)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
  }

  /// `daemon.pid` names the managed daemon; the pid must still be that daemon.
  nonisolated static func managedDaemonPID(
    codexHome: URL,
    isManagedDaemon: (pid_t) -> Bool = ProcessDetection.isCodexManagedDaemon
  ) -> pid_t? {
    let url = codexHome.appending(path: "app-server-daemon/daemon.pid", directoryHint: .notDirectory)
    guard let data = try? Data(contentsOf: url),
      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pid = (record["pid"] as? NSNumber).map({ pid_t(truncating: $0) }), pid > 1,
      isManagedDaemon(pid)
    else { return nil }
    return pid
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
