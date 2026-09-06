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
    for (script, expected) in [("exit 7", "exit"), ("sleep 10", "timeout"), ("yes x", "stdout_limit")] {
      do {
        _ = try await WorkflowScriptExecutor.run(.init(executable: "/bin/sh", arguments: ["-c", script],
          directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"]).limits(timeout: 0.1, outputLimit: 1024),
          request: Data())
        Issue.record("Expected \(expected)")
      } catch let error as WorkflowScriptExecutionError {
        #expect(error.code == expected)
        if expected == "exit" { #expect(error.message == "Action exited with status 7.") }
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
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var child: Int32?
    while child == nil, ContinuousClock.now < deadline {
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
    while kill(pid, 0) == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }
}
