import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

nonisolated enum CodexConfigReadProcessError: Error, Equatable, Sendable {
  case cancelled
  case executableUnavailable
  case invalidProfile
  case outputTooLarge
  case processFailed
  case timeout
}

nonisolated struct CodexConfigReadProcess: Sendable {
  private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func install(_ process: Process) {
      lock.lock()
      self.process = process
      lock.unlock()
    }

    func terminate() {
      lock.lock()
      let process = self.process
      lock.unlock()
      if process?.isRunning == true { process?.terminate() }
    }
  }

  let executableURL: URL
  let temporaryBaseDirectory: URL
  let timeout: TimeInterval

  init(
    executableURL: URL = URL(filePath: "/usr/bin/env", directoryHint: .notDirectory),
    temporaryBaseDirectory: URL = FileManager.default.temporaryDirectory,
    timeout: TimeInterval = 1
  ) {
    self.executableURL = executableURL
    self.temporaryBaseDirectory = temporaryBaseDirectory
    self.timeout = max(0.05, timeout)
  }

  func usingExecutable(_ executableURL: URL) -> CodexConfigReadProcess {
    CodexConfigReadProcess(
      executableURL: executableURL,
      temporaryBaseDirectory: temporaryBaseDirectory,
      timeout: timeout
    )
  }

  func query(_ query: CodexConfigQuery) async throws -> Data {
    let fileManager = FileManager.default
    var parserHome: URL?
    let effectiveHome: URL
    switch query.kind {
    case .base:
      effectiveHome = query.codexHome
    case .profile(let profileURL):
      let data = try readStableProfile(profileURL)
      let home = try makeTemporaryHome(fileManager: fileManager)
      parserHome = home
      let configURL = home.appending(path: "config.toml", directoryHint: .notDirectory)
      try data.write(to: configURL, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: configURL.path(percentEncoded: false)
      )
      effectiveHome = home
    case .explicitNotify:
      let home = try makeTemporaryHome(fileManager: fileManager)
      parserHome = home
      effectiveHome = home
    }
    defer {
      if let parserHome { try? fileManager.removeItem(at: parserHome) }
    }

    let processBox = ProcessBox()
    let task = Task.detached(priority: .userInitiated) {
      try Self.run(
        query: query,
        effectiveHome: effectiveHome,
        executableURL: executableURL,
        timeout: timeout,
        processBox: processBox
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
      processBox.terminate()
    }
  }

  private func makeTemporaryHome(fileManager: FileManager) throws -> URL {
    try fileManager.createDirectory(
      at: temporaryBaseDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let home = temporaryBaseDirectory.appending(
      path: "prowl-codex-parser-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
      at: home,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: home.path(percentEncoded: false)
    )
    return home
  }

  private func readStableProfile(_ url: URL) throws -> Data {
    guard
      case .stable(let data) = StableOwnerFileReader.read(
        url,
        maximumBytes: 256 * 1_024
      )
    else {
      throw CodexConfigReadProcessError.invalidProfile
    }
    return data
  }

  private static func run(
    query: CodexConfigQuery,
    effectiveHome: URL,
    executableURL: URL,
    timeout: TimeInterval,
    processBox: ProcessBox
  ) throws -> Data {
    guard FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false)) else {
      throw CodexConfigReadProcessError.executableUnavailable
    }
    let process = Process()
    process.executableURL = executableURL
    var arguments: [String]
    if executableURL.path(percentEncoded: false) == "/usr/bin/env" {
      arguments = ["codex", "app-server", "--listen", "stdio://"]
    } else {
      arguments = ["app-server", "--listen", "stdio://"]
    }
    for override in query.overrides {
      arguments += ["-c", override]
    }
    process.arguments = arguments
    process.currentDirectoryURL = query.cwd
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = effectiveHome.path(percentEncoded: false)
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard configureNoSigPipe(input.fileHandleForWriting.fileDescriptor) else {
      throw CodexConfigReadProcessError.processFailed
    }
    processBox.install(process)
    try process.run()
    defer {
      stop(process)
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
    }
    let request = CodexConfigReadProtocol.requestData(
      cwd: query.cwd.path(percentEncoded: false)
    )
    // The request pipe stays open until the response has arrived: Codex ≥ 0.149.1's
    // app-server shuts down on stdin EOF and drops any request it has not answered yet.
    // The deferred `stop` ends the server and closes the pipe once the read loop returns.
    do {
      try input.fileHandleForWriting.write(contentsOf: request)
    } catch {
      throw CodexConfigReadProcessError.processFailed
    }

    let descriptor = output.fileHandleForReading.fileDescriptor
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    var transcript = Data()

    while DispatchTime.now().uptimeNanoseconds < deadline {
      if Task.isCancelled { throw CodexConfigReadProcessError.cancelled }
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      let status = poll(&pollDescriptor, 1, 25)
      if status < 0 {
        if errno == EINTR { continue }
        throw CodexConfigReadProcessError.processFailed
      }
      if status == 0 { continue }
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count > 0 {
        transcript.append(contentsOf: buffer.prefix(count))
        guard transcript.count <= 1_024 * 1_024 else {
          throw CodexConfigReadProcessError.outputTooLarge
        }
        do {
          // A decoded nil is a complete response with no notifier, not missing output.
          _ = try CodexConfigReadProtocol.decodeNotify(from: transcript)
          return transcript
        } catch CodexConfigReadError.missingResponse {
          continue
        }
      } else if count == 0 {
        throw CodexConfigReadProcessError.processFailed
      } else if errno != EINTR && errno != EAGAIN {
        throw CodexConfigReadProcessError.processFailed
      }
    }
    throw CodexConfigReadProcessError.timeout
  }

  static func configureNoSigPipe(_ descriptor: Int32) -> Bool {
    #if canImport(Darwin)
      fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
    #else
      true
    #endif
  }

  private static func stop(_ process: Process) {
    if process.isRunning { process.terminate() }
    for _ in 0..<100 where process.isRunning {
      usleep(1_000)
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
}
