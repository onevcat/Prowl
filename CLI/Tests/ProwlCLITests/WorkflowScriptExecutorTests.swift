import Foundation
import Darwin
import Testing
@testable import ProwlCLIShared

struct WorkflowScriptExecutorTests {
  @Test func transportsJSONAndDrainsBothPipes() async throws {
    let result = try await WorkflowScriptExecutor.run(
      .init(executable: "/bin/sh", arguments: ["-c", "cat; printf diagnostic >&2"],
      directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"]).limits(timeout: 5),
      request: Data("{\"ok\":true}".utf8))
    #expect(String(decoding: result.stdout, as: UTF8.self) == "{\"ok\":true}")
    #expect(String(decoding: result.stderr, as: UTF8.self) == "diagnostic")
  }

  @Test func exitFailureTimeoutAndOutputLimitAreDistinct() async {
    // Only the timeout case needs a short deadline. The others get a generous one so that a slow
    // spawn on a loaded machine does not turn an exit or output-limit failure into a timeout.
    for (script, expected, timeout) in [
      ("exit 7", "exit", 5.0), ("sleep 10", "timeout", 0.1), ("yes x", "stdout_limit", 5.0),
    ] {
      do {
        _ = try await WorkflowScriptExecutor.run(.init(executable: "/bin/sh", arguments: ["-c", script],
          directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"]).limits(timeout: timeout, outputLimit: 1024),
          request: Data())
        Issue.record("Expected \(expected)")
      } catch let error as WorkflowScriptExecutionError {
        #expect(error.code == expected)
        if expected == "exit" { #expect(error.message == "Action exited with status 7.") }
        if expected == "stdout_limit" { #expect(error.stdout.count == 1024) }
      } catch { Issue.record("Unexpected error: \(error)") }
    }
  }


  @Test func cancellationTerminatesRunningChildProcess() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
      try await WorkflowScriptExecutor.run(.init(executable: "/bin/sh",
        arguments: ["-c", "sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; wait", "action", marker.path],
        directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"]).limits(timeout: 60),
        request: Data())
    }
    defer { task.cancel() }
    // The shell must fork twice and write the marker; on a loaded CI runner that has exceeded 5 seconds.
    let spawnDeadline = ContinuousClock.now.advanced(by: .seconds(30))
    var child: Int32?
    while child == nil, ContinuousClock.now < spawnDeadline {
      child = (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int32.init)
      await Task.yield()
    }
    let pid = try #require(child)
    #expect(kill(pid, 0) == 0)
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled script succeeded")
    } catch let error as WorkflowScriptExecutionError { #expect(error.code == "cancelled") }
    let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while kill(pid, 0) == 0, ContinuousClock.now < exitDeadline { await Task.yield() }
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }
}

extension WorkflowScriptExecutorTests {
  @Test func acceptsSixteenMiBRequestAndStdout() async throws {
    let bytes = Data(repeating: 120, count: 16 * 1024 * 1024)
    let result = try await WorkflowScriptExecutor.run(
      .init(executable: "/bin/cat", arguments: [], directory: FileManager.default.temporaryDirectory,
            environment: [:]).limits(timeout: 30), request: bytes)
    #expect(result.stdout == bytes)
  }

  @Test func stderrStopsAtFourMiB() async throws {
    do {
      _ = try await WorkflowScriptExecutor.run(
        .init(executable: "/bin/sh", arguments: ["-c", "yes diagnostic >&2"],
              directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
          .limits(timeout: 30), request: Data())
      Issue.record("Expected stderr limit")
    } catch let error as WorkflowScriptExecutionError {
      #expect(error.code == "stderr_limit")
      #expect(error.stderr.count == 4 * 1024 * 1024)
    }
  }
}
