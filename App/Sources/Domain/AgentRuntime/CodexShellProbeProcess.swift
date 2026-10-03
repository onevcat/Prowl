import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

nonisolated enum CodexShellProbeProcessError: Error, Equatable, Sendable {
  case cancelled
  case outputTooLarge
  case processFailed
  case timeout
}

nonisolated struct CodexShellProbeProcess: Sendable {
  private struct RunOptions {
    let timeout: TimeInterval
    let maximumOutputBytes: Int
    let shellOverride: URL?
    let shellOverrideArguments: [String]
    let environment: [String: String]?
  }

  private struct OutputDescriptor {
    let fileDescriptor: Int32
    let isStandardOutput: Bool
  }

  private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func install(_ process: Process) {
      lock.withLock { self.process = process }
    }

    func terminate() {
      lock.withLock {
        if process?.isRunning == true { process?.terminate() }
      }
    }
  }

  let timeout: TimeInterval
  let maximumOutputBytes: Int
  let shellOverride: URL?
  let shellOverrideArguments: [String]
  /// The child's environment; `nil` inherits the app's, which is what every launch probe wants.
  let environment: [String: String]?

  init(
    timeout: TimeInterval = 1,
    maximumOutputBytes: Int = 16 * 1_024,
    shellOverride: URL? = nil,
    shellOverrideArguments: [String] = [],
    environment: [String: String]? = nil
  ) {
    self.timeout = max(0.05, timeout)
    self.maximumOutputBytes = max(1, maximumOutputBytes)
    self.shellOverride = shellOverride
    self.shellOverrideArguments = shellOverrideArguments
    self.environment = environment
  }

  func run(cwd: URL, script: String) async throws -> ShellOutput {
    let processBox = ProcessBox()
    let task = Task.detached(priority: .userInitiated) {
      try Self.runSynchronously(
        cwd: cwd,
        script: script,
        options: RunOptions(
          timeout: timeout,
          maximumOutputBytes: maximumOutputBytes,
          shellOverride: shellOverride,
          shellOverrideArguments: shellOverrideArguments,
          environment: environment
        ),
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

  private static func runSynchronously(
    cwd: URL,
    script: String,
    options: RunOptions,
    processBox: ProcessBox
  ) throws -> ShellOutput {
    let process = Process()
    if let shellOverride = options.shellOverride {
      process.executableURL = shellOverride
      process.arguments = options.shellOverrideArguments
    } else {
      let invocation = ShellClient.loginShellInvocation(userShell: defaultShellURL())
      process.executableURL = invocation.shell
      process.arguments = [
        "-l", "-c", invocation.command, "--",
        "/bin/sh", "-c", script,
      ]
    }
    process.currentDirectoryURL = cwd
    if let environment = options.environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    processBox.install(process)
    try process.run()
    var descriptors = [
      OutputDescriptor(
        fileDescriptor: output.fileHandleForReading.fileDescriptor,
        isStandardOutput: true
      ),
      OutputDescriptor(
        fileDescriptor: errors.fileHandleForReading.fileDescriptor,
        isStandardOutput: false
      ),
    ]
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(options.timeout * 1_000_000_000)
    var stdout = Data()
    var stderr = Data()
    defer {
      stop(process)
      try? output.fileHandleForReading.close()
      try? errors.fileHandleForReading.close()
    }

    while process.isRunning || !descriptors.isEmpty {
      if Task.isCancelled { throw CodexShellProbeProcessError.cancelled }
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw CodexShellProbeProcessError.timeout
      }
      guard !descriptors.isEmpty else {
        usleep(1_000)
        continue
      }
      var pollDescriptors = descriptors.map {
        pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      }
      let processIsRunning = process.isRunning
      let status = poll(
        &pollDescriptors,
        nfds_t(pollDescriptors.count),
        processIsRunning ? 25 : 0
      )
      if status < 0 {
        if errno == EINTR { continue }
        throw CodexShellProbeProcessError.processFailed
      }
      if status == 0, !processIsRunning { break }
      try drainReadyDescriptors(
        &descriptors,
        pollDescriptors: pollDescriptors,
        standardOutput: &stdout,
        standardError: &stderr,
        maximumOutputBytes: options.maximumOutputBytes
      )
    }
    guard process.terminationStatus == 0 else { throw CodexShellProbeProcessError.processFailed }
    guard let stdoutText = String(data: stdout, encoding: .utf8),
      let stderrText = String(data: stderr, encoding: .utf8)
    else { throw CodexShellProbeProcessError.processFailed }
    return ShellOutput(stdout: stdoutText, stderr: stderrText, exitCode: process.terminationStatus)
  }

  private static func drainReadyDescriptors(
    _ descriptors: inout [OutputDescriptor],
    pollDescriptors: [pollfd],
    standardOutput: inout Data,
    standardError: inout Data,
    maximumOutputBytes: Int
  ) throws {
    for index in pollDescriptors.indices.reversed() {
      let events = pollDescriptors[index].revents
      if events & Int16(POLLNVAL | POLLERR) != 0 {
        throw CodexShellProbeProcessError.processFailed
      }
      guard events & Int16(POLLIN | POLLHUP) != 0 else { continue }
      var chunk = [UInt8](repeating: 0, count: 4 * 1_024)
      let count = chunk.withUnsafeMutableBytes {
        Darwin.read(descriptors[index].fileDescriptor, $0.baseAddress, $0.count)
      }
      if count > 0 {
        if descriptors[index].isStandardOutput {
          standardOutput.append(contentsOf: chunk.prefix(count))
        } else {
          standardError.append(contentsOf: chunk.prefix(count))
        }
        guard standardOutput.count + standardError.count <= maximumOutputBytes else {
          throw CodexShellProbeProcessError.outputTooLarge
        }
      } else if count == 0 {
        descriptors.remove(at: index)
      } else if errno != EINTR && errno != EAGAIN {
        throw CodexShellProbeProcessError.processFailed
      }
    }
  }

  private static func stop(_ process: Process) {
    if process.isRunning { process.terminate() }
    for _ in 0..<100 where process.isRunning { usleep(1_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }

  private static func defaultShellURL() -> URL {
    if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
      return URL(filePath: shell, directoryHint: .notDirectory)
    }
    return URL(filePath: "/bin/zsh", directoryHint: .notDirectory)
  }
}
