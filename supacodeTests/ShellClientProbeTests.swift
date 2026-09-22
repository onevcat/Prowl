import Darwin
import Foundation
import Testing

@testable import supacode

struct ShellClientProbeTests {
  @Test(arguments: [false, true])
  func timeoutStopsProbeAndItsChildren(login: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appending(path: "zsh")
    try Data(
      """
      #!/bin/sh
      trap '' TERM
      /bin/sleep 60 &
      printf '%s\\n' "$$" "$!"
      wait
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let shell = ShellClient.probe(timeout: 1, userShell: script)
    do {
      if login {
        _ = try await shell.runLogin(URL(fileURLWithPath: "/usr/bin/printenv"), ["PATH"], nil)
      } else {
        _ = try await shell.run(script, [], nil)
      }
      Issue.record("A stalled probe must time out")
    } catch let error as ShellClientError {
      #expect(error.stderr.contains("timeout"))
      let pids = error.stdout.split(separator: "\n").compactMap { Int32($0) }
      #expect(pids.count == 2)
      // This is a real process-lifetime check, not a scheduling delay for app logic.
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      for pid in pids {
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(kill(pid, 0) == -1)
      }
    }
  }

  @Test func cancellationStopsProbeAndItsChildren() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
      try await ShellClient.probe(timeout: 60).run(
        URL(fileURLWithPath: "/bin/sh"),
        [
          "-c", "trap '' TERM; /bin/sleep 60 & printf '%s\\n' \"$$\" \"$!\" > \"$1\"; wait",
          "probe", marker.path,
        ], nil)
    }
    let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    var pids: [Int32] = []
    while pids.count != 2, ContinuousClock.now < readyDeadline {
      pids =
        (try? String(contentsOf: marker, encoding: .utf8))?
        .split(separator: "\n").compactMap { Int32($0) } ?? []
      await Task.yield()
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(pids.count == 2)
    let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    for pid in pids {
      while kill(pid, 0) == 0, ContinuousClock.now < exitDeadline { await Task.yield() }
      #expect(kill(pid, 0) == -1)
    }
  }

  @Test func successfulProbeKeepsOutputAndEnvironment() async throws {
    let output = try await ShellClient.probe().run(
      URL(fileURLWithPath: "/usr/bin/env"),
      [
        "PROWL_PROBE_TEST=selected", "/bin/sh", "-c",
        "printf '%s' \"$PROWL_PROBE_TEST\"; printf detail >&2",
      ], nil)
    #expect(output == ShellOutput(stdout: "selected", stderr: "detail", exitCode: 0))
  }
}
