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

  @Test func theDeadlineStopsAHungCommandAndWhatItSpawned() async {
    // The background child shares stdout: if the stop missed it, the run would wait for
    // its end-of-file for 30 seconds.
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = await runner.run(
      URL(filePath: "/bin/sh"), ["-c", "sleep 30 & sleep 30"], Data(),
      RemoteCommandLimits(deadline: 0.3, outputBytes: 1024))
    #expect(outcome == .timedOut)
    #expect(clock.now - started < .seconds(20))
  }

  @Test(arguments: [
    // The leader exits at once; a child it left behind keeps stdout open.
    "sleep 30 & exit 0",
    // The descendant ignores SIGTERM; SIGKILL after the grace period ends it.
    "(trap '' TERM; sleep 30) & wait",
    // The descendant leaves the process group; the reads are abandoned after the grace.
    "/usr/bin/perl -e 'setpgrp(0, 0); sleep 8' & wait",
  ])
  func theBudgetCoversDescendantsThatKeepThePipesOpen(script: String) async {
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = await runner.run(
      URL(filePath: "/bin/sh"), ["-c", script], Data(), RemoteCommandLimits(deadline: 0.3, outputBytes: 1024))
    #expect(outcome == .timedOut)
    // Deadline plus kill grace plus one poll interval, with room for a loaded machine.
    #expect(clock.now - started < .seconds(6))
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

  @Test func aMissingExecutableFailsToLaunch() async {
    let outcome = await runner.run(URL(filePath: "/nonexistent/ssh"), [], Data(), RemoteCommandLimits())
    guard case .launchFailed = outcome else {
      Issue.record("expected launch failure, got \(outcome)")
      return
    }
  }
}
