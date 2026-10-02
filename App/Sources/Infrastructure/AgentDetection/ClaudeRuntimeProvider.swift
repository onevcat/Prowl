import Foundation

/// The native status includes assigned children and background shell work. Transcript
/// edges cannot reconstruct this per-process state when two panes share a session.
actor ClaudeRuntimeProvider {
  private let processStart: @Sendable (pid_t) -> Date?
  private let diagnostic: @Sendable (String) -> Void
  private let time: @Sendable () -> TimeInterval
  private var lastUpdatedAt: Double?
  private var lastFailureAt: [String: TimeInterval] = [:]
  private var failed = false

  init(
    processStart: @escaping @Sendable (pid_t) -> Date? = { ProcessDetection.processStartDate(pid: $0) },
    time: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    diagnostic: @escaping @Sendable (String) -> Void = { SupaLogger("AgentDetection").warning($0) }
  ) {
    self.processStart = processStart
    self.time = time
    self.diagnostic = diagnostic
  }

  func sample(process: AgentProcessGeneration, configRoot: URL?) -> [AgentDetectionEvent] {
    guard processStart(process.pid) == process.startedAt else {
      lastUpdatedAt = nil
      report("processChanged")
      return [.unavailable]
    }
    let root = configRoot ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    do {
      let handle = try FileHandle(forReadingFrom: root.appending(path: "sessions/\(process.pid).json"))
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 65_537) ?? Data()
      let record = try ClaudeRuntimeDecoder.record(data)
      let snapshot = try ClaudeRuntimeDecoder.snapshot(record, process: process)
      guard processStart(process.pid) == process.startedAt else {
        lastUpdatedAt = nil
        report("processChanged")
        return [.unavailable]
      }
      guard lastUpdatedAt.map({ record.updatedAt >= $0 }) ?? true else {
        report("olderSnapshot")
        return [.suspended]
      }
      lastUpdatedAt = record.updatedAt
      report(nil)
      return [.native(snapshot)]
    } catch is ClaudeRuntimeDecoder.Failure {
      lastUpdatedAt = nil
      report("unsupportedSnapshot")
      return [.unavailable]
    } catch {
      // A missing startup file or a partial rewrite does not discard the last
      // observation. Authority resumes from a complete current snapshot.
      report("snapshotUnavailable")
      return [.suspended]
    }
  }

  private func report(_ failure: String?) {
    if let failure {
      failed = true
      let now = time()
      guard lastFailureAt[failure].map({ now - $0 >= 30 }) ?? true else { return }
      lastFailureAt[failure] = now
      diagnostic("Native provider status=\(failure)")
    } else if failed {
      failed = false
      diagnostic("Native provider status=recovered")
    }
  }
}
