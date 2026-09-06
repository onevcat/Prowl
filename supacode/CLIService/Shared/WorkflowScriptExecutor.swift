import Darwin
import Foundation

nonisolated public struct WorkflowScriptExecutionResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let exitStatus: Int32
}

nonisolated public struct WorkflowScriptExecutionError: Error, Equatable, Sendable {
  public let code: String
  public let message: String
  public let stderr: Data
}

nonisolated private final class WorkflowScriptCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.withLock { cancelled = true } }
  var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Uses a process group created atomically by spawn, with concurrent nonblocking pipe I/O.
nonisolated public enum WorkflowScriptExecutor {
  public struct Configuration: Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: URL
    public var environment: [String: String]
    public var timeout: TimeInterval = 30
    public var outputLimit: Int = 1_048_576

    public func limits(timeout: TimeInterval, outputLimit: Int = 1_048_576) -> Self {
      var copy = self
      copy.timeout = timeout
      copy.outputLimit = outputLimit
      return copy
    }

    public init(executable: String, arguments: [String], directory: URL, environment: [String: String]) {
      self.executable = executable
      self.arguments = arguments
      self.directory = directory
      self.environment = environment
    }
  }

  public static func run(
    _ configuration: Configuration, request: Data,
    onSpawn: @escaping @Sendable (Int32) throws -> Void = { _ in }
  ) async throws -> WorkflowScriptExecutionResult {
    let cancellation = WorkflowScriptCancellation()
    return try await withTaskCancellationHandler {
      try await Task.detached {
        try execute(configuration, request: request, cancellation: cancellation, onSpawn: onSpawn)
      }.value
    } onCancel: {
      cancellation.cancel()
    }
  }

  private static func execute(
    _ configuration: Configuration, request: Data, cancellation: WorkflowScriptCancellation,
    onSpawn: @Sendable (Int32) throws -> Void
  ) throws -> WorkflowScriptExecutionResult {
    let executable = configuration.executable
    let arguments = configuration.arguments
    let directory = configuration.directory
    let environment = configuration.environment
    let timeout = configuration.timeout
    let outputLimit = configuration.outputLimit
    guard !cancellation.isCancelled else { throw failure("cancelled", "Action cancelled.") }
    guard timeout > 0, timeout.isFinite, outputLimit > 0, request.count <= 1_048_576 else {
      throw failure("request_limit", "Invalid execution limits or request exceeds 1 MiB.")
    }
    let pipes = try ScriptPipes()
    defer { pipes.closeAll() }
    let pid = try spawn(executable, arguments: arguments, directory: directory, environment: environment, pipes: pipes)
    pipes.closeChildEnds()
    do { try onSpawn(pid) } catch {
      kill(-pid, SIGKILL)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      throw error
    }
    let pump = ScriptPump(pid: pid, pipes: pipes, request: request, outputLimit: outputLimit)
    return try pump.run(timeout: timeout, cancelled: { cancellation.isCancelled })
  }

  private static func spawn(
    _ executable: String, arguments: [String], directory: URL, environment: [String: String], pipes: ScriptPipes
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawn_file_actions_adddup2(&actions, pipes.input[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, pipes.output[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, pipes.error[1], STDERR_FILENO)
    let chdirResult = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
    guard chdirResult == 0 else { throw failure("spawn", "Cannot select action worktree: \(chdirResult).") }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0] ?? "")") } + [nil]
    defer {
      for value in argv { free(value) }
      for value in envp { free(value) }
    }
    var pid: pid_t = 0
    let result = argv.withUnsafeBufferPointer { argv in
      envp.withUnsafeBufferPointer { envp in
        posix_spawn(
          &pid, executable, &actions, &attributes,
          UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
      }
    }
    guard result == 0 else { throw failure("spawn", "Cannot launch interpreter: \(result).") }
    return pid
  }

  fileprivate static func failure(_ code: String, _ message: String, stderr: Data = Data())
    -> WorkflowScriptExecutionError
  {
    WorkflowScriptExecutionError(code: code, message: message, stderr: stderr)
  }
}

nonisolated private final class ScriptPipes {
  var input: [Int32] = [-1, -1]
  var output: [Int32] = [-1, -1]
  var error: [Int32] = [-1, -1]

  init() throws {
    guard pipe(&input) == 0, pipe(&output) == 0, pipe(&error) == 0 else {
      closeAll()
      throw WorkflowScriptExecutor.failure("spawn", "Cannot create action pipes.")
    }
    for descriptor in [input[1], output[0], error[0]] {
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
  }

  func closeChildEnds() {
    close(&input[0])
    close(&output[1])
    close(&error[1])
  }

  func closeInput() { close(&input[1]) }
  func closeOutput() { close(&output[0]) }
  func closeError() { close(&error[0]) }

  func closeAll() {
    for index in 0..<2 {
      close(&input[index])
      close(&output[index])
      close(&error[index])
    }
  }

  private func close(_ descriptor: inout Int32) {
    if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
  }
}

nonisolated private final class ScriptPump {
  let pid: pid_t
  let pipes: ScriptPipes
  let request: Data
  let outputLimit: Int
  private var stdout = Data()
  private var stderr = Data()
  private var written = 0
  private var exitStatus: Int32?
  private var stopReason: String?
  private var stopTime: TimeInterval?

  init(pid: pid_t, pipes: ScriptPipes, request: Data, outputLimit: Int) {
    self.pid = pid
    self.pipes = pipes
    self.request = request
    self.outputLimit = outputLimit
  }

  func run(timeout: TimeInterval, cancelled: () -> Bool) throws -> WorkflowScriptExecutionResult {
    let started = ProcessInfo.processInfo.systemUptime
    defer {
      // Own the group's lifetime even when the entrypoint exits before a background child.
      kill(-pid, SIGKILL)
      if exitStatus == nil {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      }
    }
    while true {
      let now = ProcessInfo.processInfo.systemUptime
      if cancelled() { stop("cancelled", at: now) }
      if now - started >= timeout { stop("timeout", at: now) }
      if let stopTime, now - stopTime >= 0.25 { kill(-pid, SIGKILL) }
      writeInput()
      try drain(pipes.output[0], into: &stdout, kind: "stdout_limit", now: now)
      try drain(pipes.error[0], into: &stderr, kind: "stderr_limit", now: now)
      var status: Int32 = 0
      if exitStatus == nil, waitpid(pid, &status, WNOHANG) == pid {
        exitStatus = status
        pipes.closeInput()
        if stopTime == nil {
          stopTime = now
          kill(-pid, SIGTERM)
        }
      }
      if exitStatus != nil, pipes.output[0] < 0, pipes.error[0] < 0 { break }
      if let stopTime, now - stopTime > 1, exitStatus != nil { break }
      var descriptors = [
        pollfd(fd: pipes.output[0], events: Int16(POLLIN), revents: 0),
        pollfd(fd: pipes.error[0], events: Int16(POLLIN), revents: 0),
        pollfd(fd: pipes.input[1], events: Int16(POLLOUT), revents: 0),
      ]
      _ = poll(&descriptors, nfds_t(descriptors.count), 20)
    }
    if let stopReason { throw WorkflowScriptExecutor.failure(stopReason, "Action \(stopReason).", stderr: stderr) }
    guard exitStatus == 0 else {
      let status = exitStatus ?? -1
      let signal = status & 0x7f
      let message =
        signal == 0
        ? "Action exited with status \((status >> 8) & 0xff)."
        : "Action terminated by signal \(signal)."
      throw WorkflowScriptExecutor.failure("exit", message, stderr: stderr)
    }
    return WorkflowScriptExecutionResult(stdout: stdout, stderr: stderr, exitStatus: 0)
  }

  private func stop(_ reason: String, at time: TimeInterval) {
    guard stopReason == nil else { return }
    stopReason = reason
    stopTime = time
    kill(-pid, SIGTERM)
    pipes.closeInput()
  }

  private func writeInput() {
    guard pipes.input[1] >= 0 else { return }
    if written == request.count {
      pipes.closeInput()
      return
    }
    let count = request.withUnsafeBytes { bytes in
      Darwin.write(pipes.input[1], bytes.baseAddress!.advanced(by: written), request.count - written)
    }
    if count > 0 { written += count } else if count < 0 && errno != EAGAIN && errno != EINTR { pipes.closeInput() }
  }

  private func drain(_ descriptor: Int32, into data: inout Data, kind: String, now: TimeInterval) throws {
    guard descriptor >= 0 else { return }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    // Bound each drain so continuous output cannot starve cancellation or the other pipe.
    for _ in 0..<16 {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 {
        if descriptor == pipes.output[0] { pipes.closeOutput() } else { pipes.closeError() }
        return
      }
      if count < 0 {
        if errno == EAGAIN || errno == EINTR { return }
        throw WorkflowScriptExecutor.failure("pipe", "Cannot read action pipe.", stderr: stderr)
      }
      let remaining = max(0, outputLimit - data.count)
      data.append(contentsOf: buffer.prefix(min(count, remaining)))
      if count > remaining {
        stop(kind, at: now)
        return
      }
    }
  }
}
