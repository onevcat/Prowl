import ComposableArchitecture
import Darwin
import Foundation
import ProwlCLIShared

nonisolated struct ShellClient: Sendable {
  var run: @Sendable (URL, [String], URL?) async throws -> ShellOutput
  var runLoginImpl: @Sendable (URL, [String], URL?, Bool) async throws -> ShellOutput
  var runStream: @Sendable (URL, [String], URL?) -> AsyncThrowingStream<ShellStreamEvent, Error>
  var runLoginStreamImpl: @Sendable (URL, [String], URL?, Bool) -> AsyncThrowingStream<ShellStreamEvent, Error>

  init(
    run: @escaping @Sendable (URL, [String], URL?) async throws -> ShellOutput,
    runLoginImpl: @escaping @Sendable (URL, [String], URL?, Bool) async throws -> ShellOutput,
    runStream: (@Sendable (URL, [String], URL?) -> AsyncThrowingStream<ShellStreamEvent, Error>)? = nil,
    runLoginStreamImpl:
      (@Sendable (URL, [String], URL?, Bool) -> AsyncThrowingStream<ShellStreamEvent, Error>)? = nil
  ) {
    self.run = run
    self.runLoginImpl = runLoginImpl
    self.runStream =
      runStream
      ?? { executableURL, arguments, currentDirectoryURL in
        AsyncThrowingStream { continuation in
          Task {
            do {
              let output = try await run(executableURL, arguments, currentDirectoryURL)
              continuation.yield(.finished(output))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
        }
      }
    self.runLoginStreamImpl =
      runLoginStreamImpl
      ?? { executableURL, arguments, currentDirectoryURL, log in
        AsyncThrowingStream { continuation in
          Task {
            do {
              let output = try await runLoginImpl(executableURL, arguments, currentDirectoryURL, log)
              continuation.yield(.finished(output))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
        }
      }
  }

  func runLogin(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) async throws -> ShellOutput {
    try await runLoginImpl(executableURL, arguments, currentDirectoryURL, log)
  }

  func runLoginStream(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) -> AsyncThrowingStream<ShellStreamEvent, Error> {
    runLoginStreamImpl(executableURL, arguments, currentDirectoryURL, log)
  }
}

extension ShellClient: DependencyKey {
  nonisolated static let live = ShellClient(
    run: { executableURL, arguments, currentDirectoryURL in
      try await runProcess(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL
      )
    },
    runLoginImpl: { executableURL, arguments, currentDirectoryURL, log in
      let (shellURL, execCommand) = ShellClient.loginShellInvocation(
        userShell: URL(fileURLWithPath: defaultShellPath()))
      let shellArguments =
        ["-l", "-c", execCommand, "--", executableURL.path(percentEncoded: false)] + arguments
      if log {
        let cwd = currentDirectoryURL?.path(percentEncoded: false) ?? "nil"
        let cmd = shellArguments.joined(separator: " ")
        shellLogger.debug("runLogin cwd=\(cwd) cmd=\(shellURL.path) \(cmd)")
      }
      let result = try await runProcess(
        executableURL: shellURL,
        arguments: shellArguments,
        currentDirectoryURL: currentDirectoryURL
      )
      return result
    },
    runStream: { executableURL, arguments, currentDirectoryURL in
      runProcessStream(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL
      )
    },
    runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, log in
      let (shellURL, execCommand) = ShellClient.loginShellInvocation(
        userShell: URL(fileURLWithPath: defaultShellPath()))
      let shellArguments =
        ["-l", "-c", execCommand, "--", executableURL.path(percentEncoded: false)] + arguments
      if log {
        let cwd = currentDirectoryURL?.path(percentEncoded: false) ?? "nil"
        let cmd = shellArguments.joined(separator: " ")
        shellLogger.debug("runLoginStream cwd=\(cwd) cmd=\(shellURL.path) \(cmd)")
      }
      return runProcessStream(
        executableURL: shellURL,
        arguments: shellArguments,
        currentDirectoryURL: currentDirectoryURL
      )
    }
  )

  static let liveValue = live

  static let testValue = ShellClient(
    run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
    runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
    runStream: { _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
        continuation.finish()
      }
    },
    runLoginStreamImpl: { _, _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
        continuation.finish()
      }
    }
  )
}

extension DependencyValues {
  var shellClient: ShellClient {
    get { self[ShellClient.self] }
    set { self[ShellClient.self] = newValue }
  }
}

private nonisolated let shellLogger = SupaLogger("Shell")

/// Coordinates cancellation before and after the worker has started the
/// subprocess. A cancellation request must never be lost while `Process.run()`
/// is still racing with task or stream teardown.
nonisolated final class ProcessCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellationRequested = false
  private var termination: (@Sendable () -> Void)?
  private var didTerminate = false

  func installTermination(_ termination: @escaping @Sendable () -> Void) {
    let action: (@Sendable () -> Void)?
    lock.lock()
    self.termination = termination
    action = takeTerminationLocked()
    lock.unlock()
    action?()
  }

  func cancel() {
    let action: (@Sendable () -> Void)?
    lock.lock()
    cancellationRequested = true
    action = takeTerminationLocked()
    lock.unlock()
    action?()
  }

  private func takeTerminationLocked() -> (@Sendable () -> Void)? {
    guard cancellationRequested, !didTerminate, let termination else { return nil }
    didTerminate = true
    return termination
  }
}

private struct ProcessExecution: Sendable {
  let stream: AsyncThrowingStream<ShellStreamEvent, Error>
  let cancel: @Sendable () -> Void
}

nonisolated private func runProcess(
  executableURL: URL,
  arguments: [String],
  currentDirectoryURL: URL?
) async throws -> ShellOutput {
  let execution = makeProcessExecution(
    executableURL: executableURL,
    arguments: arguments,
    currentDirectoryURL: currentDirectoryURL
  )
  let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
  return try await withTaskCancellationHandler {
    try await collectOutput(from: execution.stream, command: command)
  } onCancel: {
    execution.cancel()
  }
}

nonisolated private func runProcessStream(
  executableURL: URL,
  arguments: [String],
  currentDirectoryURL: URL?
) -> AsyncThrowingStream<ShellStreamEvent, Error> {
  makeProcessExecution(
    executableURL: executableURL,
    arguments: arguments,
    currentDirectoryURL: currentDirectoryURL
  ).stream
}

nonisolated private func makeProcessExecution(
  executableURL: URL,
  arguments: [String],
  currentDirectoryURL: URL?
) -> ProcessExecution {
  let cancellation = ProcessCancellation()
  let stream = AsyncThrowingStream<ShellStreamEvent, Error> { continuation in
    let processBox = LockIsolated<Process?>(nil)
    let workerTask = Task {
      let outputAccumulator = ShellOutputAccumulator()
      let process = Process()
      process.executableURL = executableURL
      process.arguments = arguments
      process.currentDirectoryURL = currentDirectoryURL
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      let outputHandle = outputPipe.fileHandleForReading
      let errorHandle = errorPipe.fileHandleForReading
      let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
      do {
        try process.run()
        processBox.setValue(process)
        cancellation.installTermination {
          processBox.withValue { $0?.terminate() }
        }
        let stdoutTask = Task {
          for await line in lineStream(from: outputHandle) {
            await outputAccumulator.append(line, source: .stdout)
            continuation.yield(.line(ShellStreamLine(source: .stdout, text: line)))
          }
        }
        let stderrTask = Task {
          for await line in lineStream(from: errorHandle) {
            await outputAccumulator.append(line, source: .stderr)
            continuation.yield(.line(ShellStreamLine(source: .stderr, text: line)))
          }
        }
        await withTaskCancellationHandler {
          await waitForExit(of: process)
        } onCancel: {
          cancellation.cancel()
        }
        await stdoutTask.value
        await stderrTask.value
        let output = await outputAccumulator.output(exitCode: process.terminationStatus)
        if process.terminationStatus != 0 {
          continuation.finish(
            throwing: ShellClientError(
              command: command,
              stdout: output.stdout,
              stderr: output.stderr,
              exitCode: output.exitCode
            )
          )
          return
        }
        continuation.yield(.finished(output))
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in
      cancellation.cancel()
      workerTask.cancel()
    }
  }
  return ProcessExecution(stream: stream, cancel: cancellation.cancel)
}

/// Waits asynchronously for `process` to exit using `terminationHandler`
/// instead of `process.waitUntilExit()` so the caller's Task cancellation
/// can be honoured. The handler is paired with a synchronous `isRunning`
/// check to cover the race where the process exits before the handler is
/// installed.
nonisolated private func waitForExit(of process: Process) async {
  await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    let resumed = LockIsolated(false)
    let resumeOnce: @Sendable () -> Void = {
      let shouldResume = resumed.withValue { (value: inout Bool) -> Bool in
        guard !value else { return false }
        value = true
        return true
      }
      if shouldResume {
        continuation.resume()
      }
    }
    process.terminationHandler = { _ in resumeOnce() }
    if !process.isRunning {
      resumeOnce()
    }
  }
}

nonisolated private func collectOutput(
  from stream: AsyncThrowingStream<ShellStreamEvent, Error>,
  command: String
) async throws -> ShellOutput {
  var finalOutput: ShellOutput?
  for try await event in stream {
    if case .finished(let output) = event {
      finalOutput = output
    }
  }
  guard let finalOutput else {
    throw ShellClientError(command: command, stdout: "", stderr: "", exitCode: -1)
  }
  return finalOutput
}

extension ShellClient {
  /// Read-only discovery uses a bounded process group, not the mutation or streaming runner.
  nonisolated static func probe(timeout: TimeInterval = 5, userShell: URL? = nil) -> ShellClient {
    ShellClient(
      run: { executable, arguments, directory in
        try await runProbe(executable, arguments, directory, timeout: timeout)
      },
      runLoginImpl: { executable, arguments, directory, _ in
        let (shell, command) = loginShellInvocation(
          userShell: userShell ?? URL(fileURLWithPath: defaultShellPath()))
        return try await runProbe(
          shell, ["-l", "-c", command, "--", executable.path(percentEncoded: false)] + arguments,
          directory, timeout: timeout)
      }
    )
  }

  nonisolated private static func runProbe(
    _ executable: URL, _ arguments: [String], _ directory: URL?, timeout: TimeInterval
  ) async throws -> ShellOutput {
    do {
      let result = try await WorkflowScriptExecutor.run(
        .init(
          executable: executable.path(percentEncoded: false), arguments: arguments,
          directory: directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
          environment: ProcessInfo.processInfo.environment
        ).limits(timeout: timeout, outputLimit: 64 * 1024, errorLimit: 64 * 1024),
        request: Data())
      return ShellOutput(
        stdout: (String(bytes: result.stdout, encoding: .utf8) ?? "").trimmingCharacters(
          in: .whitespacesAndNewlines),
        stderr: (String(bytes: result.stderr, encoding: .utf8) ?? "").trimmingCharacters(
          in: .whitespacesAndNewlines),
        exitCode: result.exitStatus)
    } catch let error as WorkflowScriptExecutionError {
      if error.code == "cancelled" { throw CancellationError() }
      throw ShellClientError(
        command: ([executable.path(percentEncoded: false)] + arguments).joined(separator: " "),
        stdout: String(bytes: error.stdout, encoding: .utf8) ?? "",
        stderr: "Probe failed (\(error.code)): \(error.message)\n"
          + (String(bytes: error.stderr, encoding: .utf8) ?? ""),
        exitCode: -1)
    }
  }

  /// Builds the `(shell, -c command)` pair for a one-shot login-shell command.
  /// We only drive shells we have a correct rc snippet for — zsh, bash, fish.
  /// Anything else (nushell, sh/dash/ksh, pwsh, …) falls back to /bin/zsh, which
  /// can actually parse the snippet, so the command runs instead of failing
  /// (upstream #100). The interactive terminal still uses the user's real shell.
  nonisolated static func loginShellInvocation(userShell: URL) -> (shell: URL, command: String) {
    let drivable: Set<String> = ["zsh", "bash", "fish"]
    let shell =
      drivable.contains(userShell.lastPathComponent)
      ? userShell : URL(fileURLWithPath: "/bin/zsh")
    let command: String
    switch shell.lastPathComponent {
    case "fish":
      command = "test -f ~/.config/fish/config.fish; and source ~/.config/fish/config.fish >/dev/null 2>&1; exec $argv"
    case "bash":
      command = posixLoginCommand(rcFile: "~/.bashrc")
    default:
      command = posixLoginCommand(rcFile: "~/.zshrc")
    }
    return (shell, command)
  }

  /// Builds the zsh/bash one-shot command: capture the positional parameters, clear them, then source
  /// the rc file and exec from the saved array. Sourcing shares `$@` with the caller, so an rc that
  /// resets the positionals (e.g. `set --`) would otherwise wipe the command before `exec` (upstream
  /// #441). Clearing `$@` with `set --` before sourcing also keeps the target command out of the rc's
  /// view: a dual-mode script dispatching on `$1` (e.g. `fzf-git.sh`) would otherwise see the probe's
  /// arguments, hit its own `exit`, and kill the probe shell before `exec` ran (upstream #477). The
  /// exec reads from the saved array, so clearing the live positionals is safe.
  nonisolated private static func posixLoginCommand(rcFile: String) -> String {
    let capture = "__supacode_login_argv=(\"$@\")"
    let clear = "set --"
    let source = "[ -f \(rcFile) ] && . \(rcFile) >/dev/null 2>&1"
    return "\(capture); \(clear); \(source); exec \"${__supacode_login_argv[@]}\""
  }
}

nonisolated private func defaultShellPath() -> String {
  if let env = ProcessInfo.processInfo.environment["SHELL"], !env.isEmpty {
    shellLogger.info("Using SHELL env: \(env)")
    return env
  }

  var pwd = passwd()
  var result: UnsafeMutablePointer<passwd>?
  let bufSize = sysconf(_SC_GETPW_R_SIZE_MAX)
  let size = bufSize > 0 ? Int(bufSize) : 1024
  var buffer = [CChar](repeating: 0, count: size)
  let lookup = getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result)
  if lookup == 0, let result, let shell = result.pointee.pw_shell {
    let value = String(cString: shell)
    if !value.isEmpty {
      shellLogger.info("Using passwd shell: \(value)")
      return value
    }
  }

  shellLogger.info("Using fallback: /bin/zsh")
  return "/bin/zsh"
}

private actor ShellOutputAccumulator {
  private var stdoutLines: [String] = []
  private var stderrLines: [String] = []

  func append(_ line: String, source: ShellStreamSource) {
    switch source {
    case .stdout:
      stdoutLines.append(line)
    case .stderr:
      stderrLines.append(line)
    }
  }

  func output(exitCode: Int32) -> ShellOutput {
    ShellOutput(
      stdout: ShellOutputAccumulator.normalized(lines: stdoutLines),
      stderr: ShellOutputAccumulator.normalized(lines: stderrLines),
      exitCode: exitCode
    )
  }

  private static func normalized(lines: [String]) -> String {
    lines.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

nonisolated private func lineStream(from handle: FileHandle) -> AsyncStream<String> {
  AsyncStream { continuation in
    let buffer = LockIsolated(Data())
    handle.readabilityHandler = { readableHandle in
      let chunk = readableHandle.availableData
      if chunk.isEmpty {
        readableHandle.readabilityHandler = nil
        if let remainingLine = buffer.withValue({ data -> String? in
          guard !data.isEmpty else {
            return nil
          }
          let value = String(bytes: data, encoding: .utf8) ?? ""
          data.removeAll(keepingCapacity: false)
          return value
        }) {
          continuation.yield(remainingLine)
        }
        continuation.finish()
        return
      }
      let lines = buffer.withValue { data in
        data.append(chunk)
        return consumeLines(from: &data)
      }
      for line in lines {
        continuation.yield(line)
      }
    }
    continuation.onTermination = { _ in
      handle.readabilityHandler = nil
    }
  }
}

nonisolated private func consumeLines(from buffer: inout Data) -> [String] {
  var lines: [String] = []
  while let newlineIndex = buffer.firstIndex(of: 0x0A) {
    var lineData = buffer.prefix(upTo: newlineIndex)
    if lineData.last == 0x0D {
      lineData = lineData.dropLast()
    }
    lines.append(String(bytes: lineData, encoding: .utf8) ?? "")
    buffer.removeSubrange(...newlineIndex)
  }
  return lines
}
