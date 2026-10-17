import Foundation
import Testing

@testable import Prowl

/// The live runner's budgets with local commands in place of `ssh` (docs-ai 082, C4).
nonisolated struct RemoteCommandRunnerTests {
  private let runner = RemoteCommandRunner.live

  @Test func stdinReachesTheCommandAndOutputReturns() async {
    let outcome = await runner.run(URL(filePath: "/bin/cat"), [], Data("hello\n".utf8), RemoteCommandLimits())
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }
    #expect(result.exitCode == 0)
    #expect(result.output == Data("hello\n".utf8))
    #expect(!result.outputTruncated)
  }

  @Test func outputBeyondTheLimitIsTruncatedAndStopsTheCommand() async {
    let limits = RemoteCommandLimits(deadline: 10, outputBytes: 1024)
    let outcome = await runner.run(URL(filePath: "/usr/bin/yes"), [], Data(), limits)
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }
    #expect(result.outputTruncated)
    #expect(result.output.count == 1024)
  }

  /// Runs `script` with `$PIDFILE` naming a file for the descendant's pid, and returns it.
  private func runRecordingDescendant(_ script: String) async throws -> (RemoteCommandOutcome, pid_t) {
    let file = FileManager.default.temporaryDirectory.appending(path: "prowl-runner-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    let outcome = await runner.run(
      URL(filePath: "/bin/sh"), ["-c", "PIDFILE='\(file.path(percentEncoded: false))'; \(script)"], Data(),
      RemoteCommandLimits(deadline: 0.3, outputBytes: 1024))
    let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return (outcome, try #require(pid_t(text)))
  }

  /// Gone, or a zombie waiting for launchd: either way it no longer holds the pipes.
  private func isDead(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 else { return true }
    return ProcessDetection.processBSDInfo(pid: pid).map { $0.pbi_status == SZOMB } ?? true
  }

  // Each descendant shares stdout. The checks are on processes, not on elapsed time: a
  // loaded test host can delay this task's resumption by tens of seconds.

  @Test func theDeadlineStopsTheGroupWhenTheLeaderExitsEarly() async throws {
    let (outcome, child) = try await runRecordingDescendant("sleep 30 & echo $! > \"$PIDFILE\"; exit 0")
    #expect(outcome == .timedOut)
    #expect(isDead(child))
  }

  @Test func theKillGraceEndsADescendantThatIgnoresSIGTERM() async throws {
    let (outcome, child) = try await runRecordingDescendant(
      "(trap '' TERM; exec sleep 30) & echo $! > \"$PIDFILE\"; wait")
    #expect(outcome == .timedOut)
    #expect(isDead(child))
  }

  @Test func readsAreAbandonedWhenADescendantLeftTheGroup() async throws {
    // The descendant outlives the run; returning while it still holds the pipes proves
    // the reads were abandoned instead of waiting for its end of file.
    let (outcome, child) = try await runRecordingDescendant(
      "/usr/bin/perl -e 'setpgrp(0, 0); sleep 120' & echo $! > \"$PIDFILE\"; wait")
    defer { kill(child, SIGKILL) }
    #expect(outcome == .timedOut)
    #expect(!isDead(child))
  }

  @Test func aSignalDeathReportsTheShellStatus() async {
    let outcome = await runner.run(URL(filePath: "/bin/sh"), ["-c", "kill -9 $$"], Data(), RemoteCommandLimits())
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }
    #expect(result.exitCode == 128 + SIGKILL)
  }

  @Test func stderrAndExitStatusAreKept() async {
    let outcome = await runner.run(
      URL(filePath: "/bin/sh"), ["-c", "echo oops >&2; exit 3"], Data(), RemoteCommandLimits())
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }
    #expect(result.exitCode == 3)
    #expect(result.errorOutput == "oops\n")
  }

  @Test func theCommandRunsInTheGivenDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "prowl-runner-cwd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outcome = await runner.run(
      URL(filePath: "/bin/pwd"), ["-P"], Data(), RemoteCommandLimits(),
      workingDirectory: directory.path(percentEncoded: false))
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }
    let printed = String(bytes: result.output, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
    #expect(printed.hasSuffix(directory.lastPathComponent))
    // A directory that no longer exists falls back to the app's own.
    let missing = await runner.run(
      URL(filePath: "/bin/pwd"), [], Data(), RemoteCommandLimits(), workingDirectory: "/nonexistent/prowl")
    guard case .exited(let fallback) = missing else {
      Issue.record("expected exit, got \(missing)")
      return
    }
    #expect(fallback.exitCode == 0)
  }

  @Test func aMissingExecutableFailsToLaunch() async {
    let outcome = await runner.run(URL(filePath: "/nonexistent/ssh"), [], Data(), RemoteCommandLimits())
    guard case .launchFailed = outcome else {
      Issue.record("expected launch failure, got \(outcome)")
      return
    }
  }
}
