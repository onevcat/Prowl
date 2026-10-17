import Darwin
import Foundation

/// Budgets for one remote command (docs-ai 082, C4).
nonisolated struct RemoteCommandLimits: Equatable, Sendable {
  /// The whole command, including connection setup.
  var deadline: TimeInterval = 5
  var outputBytes = 256 * 1024
  var errorBytes = 16 * 1024
}

nonisolated struct RemoteCommandResult: Equatable, Sendable {
  let exitCode: Int32
  let output: Data
  /// The output reached `RemoteCommandLimits.outputBytes`; the command was stopped.
  let outputTruncated: Bool
  let errorOutput: String
}

nonisolated enum RemoteCommandOutcome: Equatable, Sendable {
  case exited(RemoteCommandResult)
  case timedOut
  case launchFailed(String)
}

/// Runs one local command (`ssh …`) with stdin input and the C4 budgets, off the main
/// actor. The child runs in its own process group, so a stop also reaches what it spawned
/// (a `ProxyCommand`); a cancelled caller stops it, and it is always reaped.
///
/// Waiting, reading, and the deadline start on dedicated threads before the first
/// suspension and never wait for a shared pool: a busy app must not turn a finished probe
/// into a timeout.
nonisolated struct RemoteCommandRunner: Sendable {
  var execute:
    @Sendable (
      _ executable: URL, _ arguments: [String], _ input: Data, _ limits: RemoteCommandLimits,
      _ workingDirectory: String?
    ) async -> RemoteCommandOutcome

  init(
    execute: @escaping @Sendable (URL, [String], Data, RemoteCommandLimits, String?) async -> RemoteCommandOutcome
  ) {
    self.execute = execute
  }

  /// Runs in `workingDirectory` when it names an existing directory, else in the app's.
  func run(
    _ executable: URL, _ arguments: [String], _ input: Data, _ limits: RemoteCommandLimits,
    workingDirectory: String? = nil
  ) async -> RemoteCommandOutcome {
    await execute(executable, arguments, input, limits, workingDirectory)
  }

  static let live = RemoteCommandRunner { executable, arguments, input, limits, workingDirectory in
    var isDirectory: ObjCBool = false
    let directory = workingDirectory.flatMap {
      FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil
    }
    return await RemoteProcess.run(
      executable: executable, arguments: arguments, input: input, limits: limits, workingDirectory: directory)
  }

  /// Grace period between SIGTERM and SIGKILL.
  static let killGrace: TimeInterval = 1
}

private nonisolated final class RemoteProcess: @unchecked Sendable {
  private let lock = NSLock()
  private let processGroup: pid_t
  /// Every part (exit status, output, error output) arrived; nothing is stopped after it.
  private var done = false
  private var timedOut = false
  /// Set after the kill grace: readers return what they have even if a descendant that
  /// left the process group still holds a pipe.
  private var abandonReads = false
  private var status: Int32?
  private var output: (Data, Bool)?
  private var errorOutput: Data?
  private var continuation: CheckedContinuation<RemoteCommandOutcome, Never>?

  private init(processGroup: pid_t) {
    self.processGroup = processGroup
  }

  /// SIGTERM to the group, then SIGKILL and abandoned reads after the grace period. It
  /// acts until the command's I/O is finished, not only until the leader exits: a
  /// descendant that keeps a pipe open is part of the command.
  func stop() {
    guard lock.withLock({ !done }) else { return }
    kill(-processGroup, SIGTERM)
    DispatchQueue(label: "com.onevcat.prowl.remote-command.kill")
      .asyncAfter(deadline: .now() + RemoteCommandRunner.killGrace) { [self] in
        guard lock.withLock({ !done }) else { return }
        kill(-processGroup, SIGKILL)
        lock.withLock { abandonReads = true }
      }
  }

  private func expire() {
    let expired = lock.withLock {
      guard !done else { return false }
      timedOut = true
      return true
    }
    if expired { stop() }
  }

  private var readsAbandoned: Bool { lock.withLock { abandonReads } }

  /// Each part arrives from its own thread; the last one resumes the caller.
  private func finish(_ update: (RemoteProcess) -> Void) {
    let ready: (CheckedContinuation<RemoteCommandOutcome, Never>, RemoteCommandOutcome)? = lock.withLock {
      update(self)
      guard let status, let output, let errorOutput, let continuation else { return nil }
      done = true
      self.continuation = nil
      let outcome: RemoteCommandOutcome =
        timedOut
        ? .timedOut
        : .exited(
          RemoteCommandResult(
            exitCode: status, output: output.0, outputTruncated: output.1,
            errorOutput: String(bytes: errorOutput, encoding: .utf8) ?? ""))
      return (continuation, outcome)
    }
    if let (continuation, outcome) = ready { continuation.resume(returning: outcome) }
  }

  static func run(
    executable: URL, arguments: [String], input: Data, limits: RemoteCommandLimits, workingDirectory: String?
  ) async -> RemoteCommandOutcome {
    let pipes = Pipes()
    let pid: pid_t
    switch spawn(executable: executable, arguments: arguments, pipes: pipes, workingDirectory: workingDirectory) {
    case .success(let spawned): pid = spawned
    case .failure(let message): return .launchFailed(message)
    }
    try? pipes.input.fileHandleForReading.close()
    try? pipes.output.fileHandleForWriting.close()
    try? pipes.error.fileHandleForWriting.close()
    let process = RemoteProcess(processGroup: pid)
    // Every thread starts here, before the first suspension, so the exit is recorded
    // when it happens even while the caller's executor is busy.
    process.start(pid: pid, pipes: pipes, input: input, limits: limits)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        process.finish { $0.continuation = continuation }
      }
    } onCancel: {
      process.stop()
    }
  }

  private func start(pid: pid_t, pipes: Pipes, input: Data, limits: RemoteCommandLimits) {
    Thread.detachNewThread {
      let handle = pipes.input.fileHandleForWriting
      try? handle.write(contentsOf: input)
      try? handle.close()
    }
    Thread.detachNewThread { [self] in
      let output = read(pipes.output.fileHandleForReading, limit: limits.outputBytes) { self.stop() }
      finish { $0.output = output }
    }
    Thread.detachNewThread { [self] in
      let (errorOutput, _) = read(pipes.error.fileHandleForReading, limit: limits.errorBytes, onLimit: nil)
      finish { $0.errorOutput = errorOutput }
    }
    Thread.detachNewThread { [self] in
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1, errno == EINTR {}
      let signal = status & 0x7F
      // A signal death reports 128 + the signal number, as a shell does.
      let code = signal == 0 ? (status >> 8) & 0xFF : 128 + signal
      finish { $0.status = code }
    }
    DispatchQueue(label: "com.onevcat.prowl.remote-command.deadline")
      .asyncAfter(deadline: .now() + limits.deadline) { [self] in expire() }
  }

  private struct Pipes: Sendable {
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
  }

  private enum Spawned {
    case success(pid_t)
    case failure(String)
  }

  private static func spawn(executable: URL, arguments: [String], pipes: Pipes, workingDirectory: String?) -> Spawned {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) }
    posix_spawn_file_actions_adddup2(&actions, pipes.input.fileHandleForReading.fileDescriptor, 0)
    posix_spawn_file_actions_adddup2(&actions, pipes.output.fileHandleForWriting.fileDescriptor, 1)
    posix_spawn_file_actions_adddup2(&actions, pipes.error.fileHandleForWriting.fileDescriptor, 2)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // A new process group, default signal handling, and no descriptor besides the pipes.
    posix_spawnattr_setpgroup(&attributes, 0)
    var defaultSignals = sigset_t()
    sigfillset(&defaultSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attributes, Int16(flags))

    let path = executable.path(percentEncoded: false)
    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
    guard result == 0 else { return .failure(String(cString: strerror(result))) }
    return .success(pid)
  }

  /// Reads until EOF or abandonment, keeping at most `limit` bytes. Reaching the limit
  /// calls `onLimit` once and keeps draining, so the writer never blocks on a full pipe.
  private func read(_ handle: FileHandle, limit: Int, onLimit: (() -> Void)?) -> (Data, Bool) {
    let descriptor = handle.fileDescriptor
    var data = Data()
    var truncated = false
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    reading: while !readsAbandoned {
      let ready = poll(&poller, 1, 100)
      if ready == 0 || (ready < 0 && errno == EINTR) { continue }
      guard ready > 0 else { break }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      switch count {
      case ..<0 where errno == EINTR || errno == EAGAIN:
        continue
      case ...0:
        break reading
      default:
        guard !truncated else { continue }
        let room = limit - data.count
        if count > room {
          data.append(contentsOf: buffer[..<room])
          truncated = true
          onLimit?()
        } else {
          data.append(contentsOf: buffer[..<count])
        }
      }
    }
    try? handle.close()
    return (data, truncated)
  }
}
