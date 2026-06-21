import Foundation
import OSLog

nonisolated struct SupaLogger: Sendable {
  private let category: String
  #if !DEBUG
    private let logger: Logger
  #endif
  /// Signposter for emitting `os_signpost` intervals/events visible in
  /// Instruments. Signposts are essentially zero-cost when no Instruments
  /// session is attached (a single TLS read), so they are always live —
  /// no DEBUG gating.
  ///
  /// The signposter uses the well-known `"PointsOfInterest"` category
  /// regardless of the logger's own `category` so that intervals and
  /// events automatically surface in Apple's **Points of Interest**
  /// instrument (the discoverable, "just drag it in" track most people
  /// will reach for). The signpost `name:` argument carries the actual
  /// origin (e.g. `"OpenBook.onAppear"`, `"focusSelectedTab"`) so source
  /// granularity is preserved — only the routing category differs from
  /// the regular log channel.
  let signposter: OSSignposter

  init(_ category: String) {
    self.category = category
    let subsystem = Bundle.main.bundleIdentifier ?? "com.onevcat.prowl"
    #if !DEBUG
      self.logger = Logger(subsystem: subsystem, category: category)
    #endif
    self.signposter = OSSignposter(subsystem: subsystem, category: "PointsOfInterest")
  }

  func debug(_ message: String) {
    #if DEBUG
      print("[\(category)] \(message)")
    #else
      logger.notice("\(message, privacy: .public)")
    #endif
  }

  func info(_ message: String) {
    #if DEBUG
      print("[\(category)] \(message)")
    #else
      logger.notice("\(message, privacy: .public)")
    #endif
  }

  func diagnostic(_ message: String) {
    #if DEBUG
      print("[\(category)] \(message)")
      Task.detached(priority: .utility) {
        await DiagnosticFileLog.shared.append(category: category, message: message)
      }
    #else
      logger.notice("\(message, privacy: .public)")
    #endif
  }

  func warning(_ message: String) {
    #if DEBUG
      print("[\(category)] \(message)")
    #else
      logger.warning("\(message, privacy: .public)")
    #endif
  }

  /// Wraps `body` in an `os_signpost` interval named `name`. The
  /// interval renders as a labeled bar on the Instruments timeline,
  /// making it trivial to correlate hotspots with hangs/hitches without
  /// post-processing the trace XML.
  func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(name, id: id)
    defer { signposter.endInterval(name, state) }
    return try body()
  }

  /// Manual begin/end pair for code paths that can't use the closure
  /// form — e.g. inside a TCA reducer case where `inout state` cannot
  /// be captured by a non-escaping closure. The returned `IntervalToken`
  /// is opaque to callers, so they don't have to import `OSLog`
  /// themselves.
  func beginInterval(_ name: StaticString) -> IntervalToken {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(name, id: id)
    return IntervalToken(name: name, state: state)
  }

  func endInterval(_ token: IntervalToken) {
    signposter.endInterval(token.name, token.state)
  }

  /// Emits an instantaneous `os_signpost` event marker — useful for
  /// marking discrete moments (e.g. "user clicked book") without an
  /// associated duration.
  func event(_ name: StaticString) {
    signposter.emitEvent(name)
  }
}

/// Opaque token bundling a signpost name and its interval state so
/// callers can `beginInterval` / `endInterval` without depending on
/// `OSLog` themselves.
struct IntervalToken {
  fileprivate let name: StaticString
  fileprivate let state: OSSignpostIntervalState
}

#if DEBUG
  private actor DiagnosticFileLog {
    static let shared = DiagnosticFileLog()

    private static let flushByteThreshold = 16 * 1024
    private static let maxFileBytes = 20 * 1024 * 1024
    private static let flushDelay: Duration = .seconds(1)

    private let fileURL: URL
    private var fileHandle: FileHandle?
    private var bufferedLines: [String] = []
    private var bufferedByteCount = 0
    private var writtenByteCount = 0
    private var flushTask: Task<Void, Never>?
    private var hasReportedPath = false
    private var isClosedForSizeLimit = false

    private init() {
      let logsDirectory = Self.logsDirectory()
      try? FileManager.default.createDirectory(
        at: logsDirectory,
        withIntermediateDirectories: true
      )
      fileURL = logsDirectory.appending(path: Self.launchFileName())
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
      fileHandle = try? FileHandle(forWritingTo: fileURL)
    }

    func append(category: String, message: String) {
      guard !isClosedForSizeLimit else { return }
      if !hasReportedPath {
        hasReportedPath = true
        print("[Diagnostics] file=\(fileURL.path)")
      }

      let line = "\(Self.timestamp()) [\(category)] \(message)\n"
      let byteCount = line.utf8.count
      guard writtenByteCount + bufferedByteCount + byteCount <= Self.maxFileBytes else {
        bufferedLines.append(
          "\(Self.timestamp()) [Diagnostics] stopped: max file size \(Self.maxFileBytes) bytes reached\n"
        )
        bufferedByteCount += bufferedLines.last?.utf8.count ?? 0
        flush()
        isClosedForSizeLimit = true
        return
      }

      bufferedLines.append(line)
      bufferedByteCount += byteCount
      if bufferedByteCount >= Self.flushByteThreshold {
        flush()
      } else {
        scheduleFlush()
      }
    }

    private func scheduleFlush() {
      guard flushTask == nil else { return }
      flushTask = Task { [weak self] in
        try? await ContinuousClock().sleep(for: Self.flushDelay)
        guard !Task.isCancelled else { return }
        await self?.flushAfterDelay()
      }
    }

    private func flushAfterDelay() {
      flushTask = nil
      flush()
    }

    private func flush() {
      flushTask?.cancel()
      flushTask = nil
      guard !bufferedLines.isEmpty, let fileHandle else { return }
      let contents = bufferedLines.joined()
      bufferedLines.removeAll(keepingCapacity: true)
      bufferedByteCount = 0
      guard let data = contents.data(using: .utf8) else { return }
      do {
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
        writtenByteCount += data.count
      } catch {
        self.fileHandle = nil
      }
    }

    private static func logsDirectory() -> URL {
      if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
        return libraryURL.appending(path: "Logs/Prowl/Diagnostics")
      }
      return URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ProwlDiagnostics")
    }

    private static func launchFileName() -> String {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      let timestamp = formatter.string(from: Date())
      return "prowl-\(timestamp)-p\(ProcessInfo.processInfo.processIdentifier).log"
    }

    private static func timestamp() -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter.string(from: Date())
    }
  }
#endif
