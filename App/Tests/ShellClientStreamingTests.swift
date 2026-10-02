import Darwin
import Foundation
import Testing

@testable import supacode

nonisolated final class LoginStreamCallRecorder: @unchecked Sendable {
  struct Snapshot {
    let executableURL: URL?
    let arguments: [String]
    let currentDirectoryURL: URL?
    let log: Bool
  }

  private let lock = NSLock()
  private var executableURLValue: URL?
  private var argumentsValue: [String] = []
  private var currentDirectoryURLValue: URL?
  private var logValue = true

  func record(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?,
    log: Bool
  ) {
    lock.lock()
    executableURLValue = executableURL
    argumentsValue = arguments
    currentDirectoryURLValue = currentDirectoryURL
    logValue = log
    lock.unlock()
  }

  func snapshot() -> Snapshot {
    lock.lock()
    let value = Snapshot(
      executableURL: executableURLValue,
      arguments: argumentsValue,
      currentDirectoryURL: currentDirectoryURLValue,
      log: logValue
    )
    lock.unlock()
    return value
  }
}

nonisolated final class TerminationCallRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var countValue = 0

  func record() {
    lock.lock()
    countValue += 1
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return countValue
  }
}

nonisolated private final class ProcessReadyCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellation: (@Sendable () -> Void)?
  private var ready = false
  private var didCancel = false

  func installCancellation(_ cancellation: @escaping @Sendable () -> Void) {
    let action: (@Sendable () -> Void)?
    lock.lock()
    self.cancellation = cancellation
    action = takeCancellationLocked()
    lock.unlock()
    action?()
  }

  func signalReady() {
    let action: (@Sendable () -> Void)?
    lock.lock()
    ready = true
    action = takeCancellationLocked()
    lock.unlock()
    action?()
  }

  var cancellationWasIssued: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didCancel
  }

  private func takeCancellationLocked() -> (@Sendable () -> Void)? {
    guard ready, !didCancel, let cancellation else { return nil }
    didCancel = true
    return cancellation
  }
}

nonisolated private final class NamedPipeState: @unchecked Sendable {
  private static let cancellationByte: UInt8 = 0

  private let lock = NSLock()
  private var descriptor: Int32

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func read() -> String? {
    let descriptor = lock.withLock { self.descriptor }
    guard descriptor >= 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = buffer.withUnsafeMutableBytes { bytes -> Int in
      while true {
        let count = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        if count < 0, errno == EINTR { continue }
        return count
      }
    }
    closeDescriptor()
    guard count > 0, buffer[0] != Self.cancellationByte else { return nil }
    return String(bytes: buffer.prefix(count), encoding: .utf8)
  }

  func cancel() {
    lock.withLock {
      guard descriptor >= 0 else { return }
      var byte = Self.cancellationByte
      _ = Darwin.write(descriptor, &byte, 1)
    }
  }

  private func closeDescriptor() {
    lock.withLock {
      guard descriptor >= 0 else { return }
      Darwin.close(descriptor)
      descriptor = -1
    }
  }
}

/// Uses a dedicated OS thread so a loaded cooperative or Dispatch pool cannot delay
/// the process-ready cancellation signal.
nonisolated private final class NamedPipeWatcher: @unchecked Sendable {
  private let state: NamedPipeState

  init(
    url: URL,
    onCompletion: @escaping @Sendable (String?) -> Void
  ) throws {
    let path = url.path(percentEncoded: false)
    guard mkfifo(path, 0o600) == 0 else { throw NamedPipeWatcherError.creationFailed }
    let descriptor = open(path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { throw NamedPipeWatcherError.openFailed }
    let state = NamedPipeState(descriptor: descriptor)
    self.state = state
    let thread = Thread {
      onCompletion(state.read())
    }
    thread.name = "Prowl shell cancellation fixture"
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  deinit {
    state.cancel()
  }
}

nonisolated private final class NamedPipeSender {
  private let descriptor: Int32

  init(url: URL) throws {
    let path = url.path(percentEncoded: false)
    guard mkfifo(path, 0o600) == 0 else { throw NamedPipeWatcherError.creationFailed }
    let descriptor = open(path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { throw NamedPipeWatcherError.openFailed }
    self.descriptor = descriptor
  }

  deinit {
    Darwin.close(descriptor)
  }

  func send(_ value: String) throws {
    let data = Data(value.utf8)
    let count = data.withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    guard count == data.count else { throw NamedPipeWatcherError.writeFailed }
  }
}

nonisolated private enum NamedPipeWatcherError: Error {
  case creationFailed
  case openFailed
  case writeFailed
}

private struct ShellCancellationFixture {
  let root: URL
  let readyURL: URL
  let resultURL: URL
  let watchdogURL: URL
  let executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  let arguments: [String]

  init(name: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "prowl-tests-shell-cancellation-\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scriptURL = root.appending(path: "fixture.py", directoryHint: .notDirectory)
    let readyURL = root.appending(path: "ready", directoryHint: .notDirectory)
    let resultURL = root.appending(path: "result", directoryHint: .notDirectory)
    let watchdogURL = root.appending(path: "watchdog", directoryHint: .notDirectory)
    try """
    import pathlib
    import signal
    import sys

    ready = pathlib.Path(sys.argv[1])
    result = pathlib.Path(sys.argv[2])
    watchdog = pathlib.Path(sys.argv[3])

    def publish(path, value):
        with path.open("w") as stream:
            stream.write(value)
            stream.flush()

    def finish(value):
        publish(result, value)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, lambda *_: finish("terminated"))
    # Arm the fallback only after the Swift consumer has observed cancellation.
    signal.signal(signal.SIGALRM, lambda *_: finish("natural"))
    publish(ready, "ready")
    with watchdog.open("r") as stream:
        stream.read(3)
    signal.alarm(5)
    signal.pause()
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    self.root = root
    self.readyURL = readyURL
    self.resultURL = resultURL
    self.watchdogURL = watchdogURL
    arguments = [
      scriptURL.path(percentEncoded: false), readyURL.path(percentEncoded: false),
      resultURL.path(percentEncoded: false), watchdogURL.path(percentEncoded: false),
    ]
  }
}

struct ShellClientStreamingTests {

  @Test func cancellationTerminatesOnceBeforeOrAfterProcessRegistration() {
    let beforeRegistration = ProcessCancellation()
    let beforeRecorder = TerminationCallRecorder()
    beforeRegistration.cancel()
    beforeRegistration.installTermination { beforeRecorder.record() }
    beforeRegistration.cancel()
    #expect(beforeRecorder.count == 1)

    let afterRegistration = ProcessCancellation()
    let afterRecorder = TerminationCallRecorder()
    afterRegistration.installTermination { afterRecorder.record() }
    afterRegistration.cancel()
    afterRegistration.cancel()
    #expect(afterRecorder.count == 1)
  }
  @Test func runStreamYieldsStdoutAndStderrLines() async throws {
    let shell = ShellClient.liveValue
    let commandURL = URL(fileURLWithPath: "/bin/sh")
    let stream = shell.runStream(
      commandURL,
      ["-c", "printf 'out-1\\n'; printf 'err-1\\n' 1>&2; printf 'out-2\\n'"],
      nil
    )
    var stdoutLines: [String] = []
    var stderrLines: [String] = []
    var finishedOutput: ShellOutput?
    for try await event in stream {
      switch event {
      case .line(let line):
        switch line.source {
        case .stdout:
          stdoutLines.append(line.text)
        case .stderr:
          stderrLines.append(line.text)
        }
      case .finished(let output):
        finishedOutput = output
      }
    }

    #expect(stdoutLines == ["out-1", "out-2"])
    #expect(stderrLines == ["err-1"])
    #expect(finishedOutput == ShellOutput(stdout: "out-1\nout-2", stderr: "err-1", exitCode: 0))
  }

  @Test func runStreamYieldsLinesBeforeProcessFinishes() async throws {
    let shell = ShellClient.liveValue
    let commandURL = URL(fileURLWithPath: "/bin/sh")
    let stream = shell.runStream(
      commandURL,
      ["-c", "printf 'first\\n'; sleep 0.4; printf 'last\\n'"],
      nil
    )
    var sawFirstLine = false
    var finishedAfterFirstLine = false
    for try await event in stream {
      switch event {
      case .line(let line):
        if line.source == .stdout, line.text == "first" {
          sawFirstLine = true
        }
      case .finished:
        finishedAfterFirstLine = sawFirstLine
      }
    }

    #expect(sawFirstLine)
    #expect(finishedAfterFirstLine)
  }

  @Test func runStreamThrowsShellClientErrorOnNonZeroExit() async throws {
    let shell = ShellClient.liveValue
    let commandURL = URL(fileURLWithPath: "/bin/sh")
    let stream = shell.runStream(
      commandURL,
      ["-c", "printf 'out\\n'; printf 'err\\n' 1>&2; exit 7"],
      nil
    )
    var streamedLines: [ShellStreamLine] = []
    do {
      for try await event in stream {
        if case .line(let line) = event {
          streamedLines.append(line)
        }
      }
      Issue.record("Expected stream to throw for non-zero exit")
    } catch let shellError as ShellClientError {
      #expect(shellError.exitCode == 7)
      #expect(shellError.stdout == "out")
      #expect(shellError.stderr == "err")
      #expect(shellError.command.contains("/bin/sh"))
    }

    let expectedStdoutLine = ShellStreamLine(source: .stdout, text: "out")
    let expectedStderrLine = ShellStreamLine(source: .stderr, text: "err")
    #expect(streamedLines.contains(expectedStdoutLine))
    #expect(streamedLines.contains(expectedStderrLine))
  }

  @Test func cancellingRunStreamConsumerTerminatesProcessAfterItIsReady() async throws {
    let fixture = try ShellCancellationFixture(name: "stream")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let readyCancellation = ProcessReadyCancellation()
    let readyWatcher = try NamedPipeWatcher(
      url: fixture.readyURL,
      onCompletion: { if $0 == "ready" { readyCancellation.signalReady() } }
    )
    let watchdog = try NamedPipeSender(url: fixture.watchdogURL)
    let resultEvent = AsyncStream<String>.makeStream()
    let resultWatcher = try NamedPipeWatcher(
      url: fixture.resultURL,
      onCompletion: {
        if let value = $0 { resultEvent.continuation.yield(value) }
        resultEvent.continuation.finish()
      }
    )
    let stream = ShellClient.liveValue.runStream(
      fixture.executableURL,
      fixture.arguments,
      nil
    )
    let consumer = Task {
      do {
        for try await _ in stream {}
      } catch {
        // CancellationError or ShellClientError after SIGTERM both indicate
        // that the consumer observed process teardown.
      }
    }
    readyCancellation.installCancellation { consumer.cancel() }

    await consumer.value
    try #require(readyCancellation.cancellationWasIssued)
    try watchdog.send("arm")
    var resultIterator = resultEvent.stream.makeAsyncIterator()
    let result = try #require(await resultIterator.next())
    withExtendedLifetime((readyWatcher, resultWatcher, watchdog)) {}

    #expect(result == "terminated")
  }

  @Test func runTerminatesReadyProcessWhenCallingTaskIsCancelled() async throws {
    let fixture = try ShellCancellationFixture(name: "run")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let readyCancellation = ProcessReadyCancellation()
    let readyWatcher = try NamedPipeWatcher(
      url: fixture.readyURL,
      onCompletion: { if $0 == "ready" { readyCancellation.signalReady() } }
    )
    let watchdog = try NamedPipeSender(url: fixture.watchdogURL)
    let resultEvent = AsyncStream<String>.makeStream()
    let resultWatcher = try NamedPipeWatcher(
      url: fixture.resultURL,
      onCompletion: {
        if let value = $0 { resultEvent.continuation.yield(value) }
        resultEvent.continuation.finish()
      }
    )
    let runTask = Task {
      try await ShellClient.liveValue.run(
        fixture.executableURL,
        fixture.arguments,
        nil
      )
    }
    readyCancellation.installCancellation { runTask.cancel() }

    _ = await runTask.result
    try #require(readyCancellation.cancellationWasIssued)
    try watchdog.send("arm")
    var resultIterator = resultEvent.stream.makeAsyncIterator()
    let result = try #require(await resultIterator.next())
    withExtendedLifetime((readyWatcher, resultWatcher, watchdog)) {}

    #expect(result == "terminated")
  }

  @Test func runStreamSucceedsForShortLivedProcessAfterCancellationFixes() async throws {
    // Regression guard: terminationHandler / isRunning race in waitForExit
    // must not deadlock or double-resume on fast-exiting processes.
    let shell = ShellClient.liveValue
    let commandURL = URL(fileURLWithPath: "/bin/sh")
    let stream = shell.runStream(commandURL, ["-c", "true"], nil)
    var finished: ShellOutput?
    for try await event in stream {
      if case .finished(let output) = event {
        finished = output
      }
    }
    #expect(finished?.exitCode == 0)
  }

  @Test func runLoginStreamForwardsParameters() async throws {
    let recorder = LoginStreamCallRecorder()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, log in
        recorder.record(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL,
          log: log
        )
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let currentDirectoryURL = URL(fileURLWithPath: "/tmp")
    let stream = shell.runLoginStream(
      executableURL,
      ["echo", "hello"],
      currentDirectoryURL,
      log: false
    )
    for try await _ in stream {}

    let snapshot = recorder.snapshot()
    #expect(snapshot.executableURL == executableURL)
    #expect(snapshot.arguments == ["echo", "hello"])
    #expect(snapshot.currentDirectoryURL == currentDirectoryURL)
    #expect(snapshot.log == false)
  }
}
