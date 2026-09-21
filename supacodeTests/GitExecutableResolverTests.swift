import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

struct GitExecutableResolverTests {
  @Test func brokenAppleGitFallsBackAndResolutionDoesNotChangeDeveloperDirectory() async throws {
    let broken = LockIsolated(true)
    let calls = LockIsolated<[[String]]>([])
    let shell = ShellClient(
      run: { _, arguments, _ in
        calls.withValue { $0.append(arguments) }
        if broken.value {
          throw ShellClientError(
            command: "git --version", stdout: "", stderr: "xcrun: invalid developer path",
            exitCode: 1)
        }
        return ShellOutput(stdout: "git version 2.50\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let resolver = GitExecutableResolver(processPath: "/usr/bin", fallbackPaths: [])
    await #expect(throws: GitClientError.self) { try await resolver.resolve(shell: shell) }
    #expect(resolver.cachedExecutable == nil)
    broken.setValue(false)
    let result = try await resolver.resolve(shell: shell)
    #expect(result.url.path == "/usr/bin/git")
    let developerArguments = calls.value.joined().filter { $0.hasPrefix("DEVELOPER_DIR=") }
    if let original = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
      #expect(developerArguments.allSatisfy { $0 == "DEVELOPER_DIR=\(original)" })
    } else {
      #expect(developerArguments.isEmpty)
    }
    broken.setValue(true)
    await #expect(throws: GitClientError.self) {
      try await resolver.resolve(revalidate: true, shell: shell)
    }
    #expect(resolver.cachedExecutable == nil)
  }

  @Test func cancelledWaiterReturnsBeforeProbeCompletes() async {
    await withMainSerialExecutor {
      let clock = TestClock()
      let cancelled = LockIsolated(false)
      let probeCancelled = LockIsolated(false)
      let shell = ShellClient(
        run: { _, _, _ in
          try await withTaskCancellationHandler {
            try await clock.sleep(for: .seconds(60))
            return ShellOutput(stdout: "git version 2.50", stderr: "", exitCode: 0)
          } onCancel: {
            probeCancelled.setValue(true)
          }
        },
        runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
      )
      let resolver = GitExecutableResolver(processPath: "/usr/bin", fallbackPaths: [])
      let waiter = Task {
        do {
          _ = try await resolver.resolve(shell: shell)
        } catch is CancellationError {
          cancelled.setValue(true)
        } catch {
          Issue.record("Expected cancellation, got \(error)")
        }
      }
      await Task.megaYield()
      waiter.cancel()
      await Task.megaYield()
      #expect(cancelled.value)
      #expect(probeCancelled.value)
      #expect(resolver.cachedExecutable == nil)
      await clock.advance(by: .seconds(60))
      await waiter.value
    }
  }

  @Test func cancelledCallerCannotUseCachedExecutable() async throws {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "git version 2.50", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let resolver = GitExecutableResolver(processPath: "/usr/bin", fallbackPaths: [])
    _ = try await resolver.resolve(shell: shell)
    let caller = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await resolver.resolve(shell: shell)
    }
    await #expect(throws: CancellationError.self) { try await caller.value }
  }

  @Test(arguments: [0, 1])
  func cancellingOneWaiterDoesNotCancelSharedDiscovery(cancelledIndex: Int) async {
    await withMainSerialExecutor {
      let clock = TestClock()
      let calls = LockIsolated(0)
      let cancelled = LockIsolated<[Int]>([])
      let succeeded = LockIsolated<[Int]>([])
      let shell = ShellClient(
        run: { _, _, _ in
          calls.withValue { $0 += 1 }
          try await clock.sleep(for: .seconds(60))
          return ShellOutput(stdout: "git version 2.50", stderr: "", exitCode: 0)
        },
        runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
      )
      let resolver = GitExecutableResolver(processPath: "/usr/bin", fallbackPaths: [])
      let waiters = (0..<2).map { index in
        Task {
          do {
            _ = try await resolver.resolve(shell: shell)
            succeeded.withValue { $0.append(index) }
          } catch is CancellationError {
            cancelled.withValue { $0.append(index) }
          } catch {
            Issue.record("Unexpected discovery failure: \(error)")
          }
        }
      }
      await Task.megaYield()
      waiters[cancelledIndex].cancel()
      await Task.megaYield()
      #expect(cancelled.value == [cancelledIndex])
      #expect(succeeded.value.isEmpty)
      #expect(calls.value == 1)
      await clock.advance(by: .seconds(60))
      for waiter in waiters { await waiter.value }
      #expect(succeeded.value == [1 - cancelledIndex])
      #expect(resolver.cachedExecutable != nil)
    }
  }

  @Test func lateCancelledDiscoveryCannotClearRetryCache() async throws {
    try await withMainSerialExecutor {
      let completion = LockIsolated<CheckedContinuation<ShellOutput, Never>?>(nil)
      let shell = ShellClient(
        run: { _, _, _ in
          await withCheckedContinuation { continuation in completion.setValue(continuation) }
        },
        runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
      )
      let resolver = GitExecutableResolver(processPath: "/usr/bin", fallbackPaths: [])
      let first = Task { try await resolver.resolve(shell: shell) }
      await Task.megaYield()
      let suspended = try #require(completion.value)
      first.cancel()
      await Task.megaYield()
      var recoveredShell = shell
      recoveredShell.run = { _, _, _ in
        ShellOutput(stdout: "git version 2.50", stderr: "", exitCode: 0)
      }
      let retry = try await resolver.resolve(shell: recoveredShell)
      suspended.resume(returning: ShellOutput(stdout: "invalid", stderr: "", exitCode: 0))
      await Task.megaYield()
      #expect(resolver.cachedExecutable == retry)
      await #expect(throws: CancellationError.self) { try await first.value }
    }
  }

  @Test(arguments: [false, true])
  func timedOutProbeFallsBack(login: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let working = directory.appending(path: "working")
    let stalled = directory.appending(path: "stalled")
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: stalled, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = working.appending(path: "git")
    let probe = stalled.appending(path: login ? "zsh" : "git")
    try Data("#!/bin/sh\nprintf 'git version 2.50\\n'\n".utf8).write(to: git)
    try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: probe)
    for executable in [git, probe] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    let bounded = ShellClient.probe(timeout: 0.1, userShell: probe)
    let normal = ShellClient.probe()
    var shell = normal
    // Only the stalled fixture needs a short deadline; cold successful spawns keep the normal limit.
    shell.run = { executable, arguments, directory in
      if arguments.contains(probe.path) {
        return try await bounded.run(executable, arguments, directory)
      }
      return try await normal.run(executable, arguments, directory)
    }
    if login {
      shell.runLoginImpl = bounded.runLoginImpl
    } else {
      shell.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    }
    let resolver = GitExecutableResolver(processPath: stalled.path, fallbackPaths: [working.path])
    let selected = try await resolver.resolve(shell: shell)
    #expect(selected.url == git)
    #expect(resolver.cachedExecutable == selected)
  }

  @Test func unavailableAfterTimeoutCanRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = directory.appending(path: "git")
    try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: git)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
    var shell = ShellClient.probe(timeout: 0.1)
    shell.runLoginImpl = { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    let resolver = GitExecutableResolver(processPath: directory.path, fallbackPaths: [])
    do {
      _ = try await resolver.resolve(shell: shell)
      Issue.record("The only Git executable must time out")
    } catch GitClientError.unavailable(let details) {
      #expect(details.contains("timeout"))
    }
    #expect(resolver.cachedExecutable == nil)
    try Data("#!/bin/sh\nprintf 'git version 2.50\\n'\n".utf8).write(to: git)
    shell.run = ShellClient.probe().run
    #expect(try await resolver.resolve(shell: shell).url == git)
  }

  @Test func loginPathCanSupplyIndependentGit() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "git")
    try Data().write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains(executable.path(percentEncoded: false)) {
          #expect(arguments.contains(where: { $0.hasPrefix("PATH=\(directory.path)") }))
          return ShellOutput(stdout: "git version 2.50\n", stderr: "", exitCode: 0)
        }
        throw ShellClientError(
          command: "git --version", stdout: "", stderr: "xcrun failed", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in
        ShellOutput(stdout: "\(directory.path):/usr/bin:/bin\n", stderr: "", exitCode: 0)
      }
    )
    let resolver = GitExecutableResolver(processPath: "/usr/bin", fallbackPaths: [])
    #expect(try await resolver.resolve(shell: shell).url == executable)
  }
}
