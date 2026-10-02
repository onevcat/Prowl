import Darwin
import Foundation
import Testing

@testable import supacode

struct CodexShellProbeProcessTests {
  @Test func successfulChildReturnsOutputBeforeTheDeadline() async throws {
    let root = temporaryDirectory("shell-success")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = CodexShellProbeProcess(
      timeout: 0.5,
      maximumOutputBytes: 1_024,
      shellOverride: URL(filePath: "/bin/sh"),
      shellOverrideArguments: ["-c", "printf stdout; printf stderr >&2"]
    )
    let output = try await process.run(cwd: root, script: "ignored")

    #expect(output.stdout == "stdout")
    #expect(output.stderr == "stderr")
    #expect(output.exitCode == 0)
  }

  @Test func successfulChildDoesNotWaitForBackgroundDescendantEOF() async throws {
    let root = temporaryDirectory("shell-background-child")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let shell = try executableScript(
      in: root,
      name: "background-child.sh",
      contents: """
        #!/bin/sh
        printf stdout
        sleep 2 &
        """
    )
    let process = CodexShellProbeProcess(
      timeout: 0.5,
      maximumOutputBytes: 1_024,
      shellOverride: URL(filePath: "/bin/sh"),
      shellOverrideArguments: [shell.path(percentEncoded: false)]
    )

    let output = try await process.run(cwd: root, script: "ignored")

    #expect(output.stdout == "stdout")
    #expect(output.exitCode == 0)
  }

  @Test func hardTimeoutKillsLoginShellThatIgnoresTermination() async throws {
    let root = temporaryDirectory("shell-timeout")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appending(path: "pid", directoryHint: .notDirectory)
    let shell = try executableScript(
      in: root,
      name: "hang.sh",
      contents: """
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > \(shellQuote(pidFile.path))
        while :; do sleep 1; done
        """
    )
    let process = CodexShellProbeProcess(
      timeout: 0.5,
      maximumOutputBytes: 1_024,
      shellOverride: URL(filePath: "/bin/sh"),
      shellOverrideArguments: [shell.path(percentEncoded: false)]
    )

    await #expect(throws: CodexShellProbeProcessError.timeout) {
      try await process.run(cwd: root, script: "ignored")
    }

    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try #require(pid_t(pidText))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test func streamingOutputBoundStopsNoisyLoginShell() async throws {
    let root = temporaryDirectory("shell-output")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let shell = try executableScript(
      in: root,
      name: "noisy.sh",
      contents: """
        #!/bin/sh
        while :; do printf '0123456789abcdef'; done
        """
    )
    let process = CodexShellProbeProcess(
      timeout: 2,
      maximumOutputBytes: 128,
      shellOverride: URL(filePath: "/bin/sh"),
      shellOverrideArguments: [shell.path(percentEncoded: false)]
    )

    await #expect(throws: CodexShellProbeProcessError.outputTooLarge) {
      try await process.run(cwd: root, script: "ignored")
    }
  }

  /// A shell-exported `OPENCODE_CONFIG_CONTENT` can legitimately be tens of kilobytes, so the
  /// environment probe must be able to raise the bound the Codex config probe defaults to.
  @Test func outputBoundIsConfigurableForLargeEnvironmentValues() async throws {
    let root = temporaryDirectory("shell-large-output")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let shell = try executableScript(
      in: root,
      name: "large.sh",
      contents: """
        #!/bin/sh
        head -c 20480 /dev/zero | tr '\\0' a
        """
    )
    let defaultBound = CodexShellProbeProcess(
      timeout: 2,
      shellOverride: URL(filePath: "/bin/sh"),
      shellOverrideArguments: [shell.path(percentEncoded: false)]
    )
    await #expect(throws: CodexShellProbeProcessError.outputTooLarge) {
      try await defaultBound.run(cwd: root, script: "ignored")
    }

    let raised = CodexShellProbeProcess(
      timeout: 2,
      maximumOutputBytes: ShellEnvironmentProbe.maximumOutputBytes,
      shellOverride: URL(filePath: "/bin/sh"),
      shellOverrideArguments: [shell.path(percentEncoded: false)]
    )
    let output = try await raised.run(cwd: root, script: "ignored")
    #expect(output.stdout.utf8.count == 20_480)
    #expect(output.exitCode == 0)
  }

  private func executableScript(in root: URL, name: String, contents: String) throws -> URL {
    let url = root.appending(path: name, directoryHint: .notDirectory)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "prowl-tests-\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacing("'", with: "'\"'\"'") + "'"
  }
}
