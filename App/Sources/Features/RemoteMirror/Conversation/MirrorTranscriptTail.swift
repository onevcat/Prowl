import Foundation

/// Splits appended bytes into complete JSONL lines. A partial last line waits for more
/// bytes; a line over `maximumLineBytes` is dropped whole and counted.
nonisolated struct MirrorJSONLineReader: Sendable {
  var maximumLineBytes = 8 * 1024 * 1024
  private(set) var droppedLines = 0
  private var buffer = Data()
  private var skippingOversizedLine = false

  mutating func append(_ data: Data) -> [Data] {
    buffer.append(data)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = buffer.subdata(in: buffer.startIndex..<newline)
      buffer.removeSubrange(buffer.startIndex...newline)
      if skippingOversizedLine {
        skippingOversizedLine = false
        continue
      }
      if line.last == 0x0D { line.removeLast() }
      if line.count > maximumLineBytes {
        droppedLines += 1
      } else if !line.isEmpty {
        lines.append(line)
      }
    }
    if buffer.count > maximumLineBytes {
      buffer.removeAll()
      skippingOversizedLine = true
      droppedLines += 1
    }
    return lines
  }

  /// Drops the bytes before the first newline: the tail of a file read from a middle offset.
  mutating func discardPartialFirstLine() {
    skippingOversizedLine = true
  }

  mutating func reset() {
    buffer.removeAll()
    skippingOversizedLine = false
  }
}

/// Follows one transcript file on a serial queue: replays what exists (bounded), then
/// delivers appended bytes as the writer adds them. A vnode source wakes the read; a slow
/// timer is the backstop. Replacement or truncation of the file is reported as `rotated`.
/// `stop()` is required; the tail keeps no `deinit` behaviour.
nonisolated final class MirrorTranscriptTail: @unchecked Sendable {
  enum Change: Sendable {
    case replay(Data, startsMidRecord: Bool)
    case appended(Data)
    case rotated
    case missing
  }

  struct Options: Sendable {
    var replayLimitBytes = 32 * 1024 * 1024
    var pollInterval: Duration = .seconds(1)
  }

  private let url: URL
  private let queue: DispatchQueue
  private let options: Options
  private let onChange: @Sendable (Change) -> Void
  private var handle: FileHandle?
  private var inode: UInt64?
  private var offset: UInt64 = 0
  private var vnode: DispatchSourceFileSystemObject?
  private var timer: DispatchSourceTimer?
  private var reportedMissing = false
  private var stopped = false

  init(url: URL, queue: DispatchQueue, options: Options = Options(), onChange: @escaping @Sendable (Change) -> Void) {
    self.url = url
    self.queue = queue
    self.options = options
    self.onChange = onChange
  }

  func start() {
    queue.async { [self] in
      guard !stopped, timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      let interval = DispatchTimeInterval.milliseconds(max(50, Int(options.pollInterval / .milliseconds(1))))
      timer.schedule(deadline: .now() + interval, repeating: interval)
      timer.setEventHandler { [weak self] in self?.readMore() }
      timer.resume()
      self.timer = timer
      open()
    }
  }

  func stop() {
    queue.async { [self] in
      stopped = true
      timer?.cancel()
      timer = nil
      closeFile()
    }
  }

  /// Runs `body` after everything queued so far; tests use it to observe a settled state.
  func sync(_ body: @escaping @Sendable () -> Void) {
    queue.async(execute: body)
  }

  // MARK: - Queue-confined

  private func open() {
    guard !stopped, handle == nil else { return }
    guard let attributes = Self.attributes(of: url), let handle = try? FileHandle(forReadingFrom: url) else {
      if !reportedMissing {
        reportedMissing = true
        onChange(.missing)
      }
      return
    }
    reportedMissing = false
    self.handle = handle
    inode = attributes.inode
    let limit = UInt64(options.replayLimitBytes)
    let start = attributes.size > limit ? attributes.size - limit : 0
    let data = read(from: start, to: attributes.size, with: handle)
    offset = attributes.size
    onChange(.replay(data, startsMidRecord: start > 0))
    let vnode = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: handle.fileDescriptor, eventMask: [.extend, .write, .delete, .rename], queue: queue)
    vnode.setEventHandler { [weak self] in self?.readMore() }
    // The descriptor closes only once the source is gone, or a reused number could be watched.
    vnode.setCancelHandler { try? handle.close() }
    vnode.resume()
    self.vnode = vnode
  }

  private func readMore() {
    guard !stopped else { return }
    guard let handle else {
      open()
      return
    }
    guard let attributes = Self.attributes(of: url), attributes.inode == inode, attributes.size >= offset else {
      closeFile()
      onChange(.rotated)
      open()
      return
    }
    guard attributes.size > offset else { return }
    let data = read(from: offset, to: attributes.size, with: handle)
    offset = attributes.size
    if !data.isEmpty { onChange(.appended(data)) }
  }

  private func read(from start: UInt64, to end: UInt64, with handle: FileHandle) -> Data {
    guard end > start, (try? handle.seek(toOffset: start)) != nil else { return Data() }
    return (try? handle.read(upToCount: Int(end - start))) ?? Data()
  }

  private func closeFile() {
    if let vnode {
      vnode.cancel()
    } else {
      try? handle?.close()
    }
    vnode = nil
    handle = nil
    inode = nil
    offset = 0
  }

  private static func attributes(of url: URL) -> (size: UInt64, inode: UInt64)? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
      let size = attributes[.size] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber
    else { return nil }
    return (size.uint64Value, inode.uint64Value)
  }
}
