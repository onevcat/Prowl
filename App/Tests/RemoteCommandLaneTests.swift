import ConcurrencyExtras
import Foundation
import Testing

@testable import Prowl

/// The command lane of `RemoteConnectionOwner` (docs-ai 084 B1).
nonisolated struct RemoteCommandLaneTests {
  private static let recipe = SSHConnectionRecipe(destination: "mini")
  private static let key = ConnectionKey(user: "onevcat", hostname: "mini.local")

  // MARK: - bash -s input, run by the local bash

  @Test func scriptArgumentsAndWorkingDirectoryReachBashWithoutTheLoginShell() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "prowl-lane-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = RemoteScript(
      text: #"printf '%s|' "$#" "$1" "$2" "$(pwd -P)""#,
      arguments: ["a b", "it's $HOME"],
      workingDirectory: directory.path(percentEncoded: false))

    let result = try await Self.runBash(script.standardInput(path: nil))

    // `pwd -P` resolves `/var` to `/private/var`, so compare the folder itself.
    #expect(result.hasPrefix("2|a b|it's $HOME|/"))
    #expect(result.hasSuffix("/\(directory.lastPathComponent)|"))
  }

  @Test func aCommandThatReadsStdinCannotConsumeTheRestOfTheScript() async throws {
    let script = RemoteScript(text: "cat\necho after-cat\n")

    let result = try await Self.runBash(script.standardInput(path: nil))

    #expect(result == "after-cat\n")
  }

  @Test func theLoginPathIsExportedBeforeTheScript() async throws {
    let script = RemoteScript(text: #"printf '%s' "$PATH""#)

    let result = try await Self.runBash(script.standardInput(path: "/opt/tools/bin:/usr/bin:/bin"))

    #expect(result == "/opt/tools/bin:/usr/bin:/bin")
  }

  @Test func aMissingWorkingDirectoryFailsWithItsOwnStatus() async throws {
    let script = RemoteScript(text: "echo ran", workingDirectory: "/nonexistent-\(UUID().uuidString)")
    let outcome = await RemoteCommandRunner.live.run(
      URL(filePath: "/bin/bash"), ["-s"], Data(try script.standardInput(path: nil).utf8), RemoteCommandLimits())
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }
    #expect(result.exitCode == RemoteShellCommand.workingDirectoryFailureStatus)
    #expect(result.output.isEmpty)
  }

  @Test func aNULByteIsRejected() {
    #expect(throws: RemoteShellCommand.ValidationError.nulByte) {
      try RemoteScript(text: "echo", arguments: ["a\0b"]).standardInput(path: nil)
    }
  }

  // MARK: - Login PATH

  @Test func theLoginPathIsReadBetweenItsMarkers() {
    #expect(
      RemoteConnectionOwner.parseLoginPath(Data("Welcome!\n\u{1}/opt/homebrew/bin:/usr/bin\u{1}".utf8))
        == "/opt/homebrew/bin:/usr/bin")
    #expect(RemoteConnectionOwner.parseLoginPath(Data("no markers".utf8)) == nil)
    #expect(RemoteConnectionOwner.parseLoginPath(Data("\u{1}\u{1}".utf8)) == nil)
  }

  @Test func theLoginPathScriptRunsWithTheLocalShell() async throws {
    let outcome = await RemoteCommandRunner.live.run(
      URL(filePath: "/bin/sh"), ["-s"], Data(RemoteConnectionOwner.loginPathScript.utf8),
      RemoteCommandLimits(deadline: 10))
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }
    #expect(RemoteConnectionOwner.parseLoginPath(result.output)?.contains("/usr/bin") == true)
  }

  // MARK: - The lane on the owner

  @Test func commandsUseTheSharedConnectionAndTheLoginPath() async throws {
    let calls = LockIsolated<[(arguments: [String], input: String)]>([])
    let owner = Self.makeOwner(
      runner: RemoteCommandRunner { _, arguments, input, _, _ in
        let text = (String(bytes: input, encoding: .utf8) ?? "")
        calls.withValue { $0.append((arguments, text)) }
        let output = text.contains("print_path") ? "banner\n\u{1}/opt/bin:/usr/bin\u{1}" : "ok\n"
        return .exited(
          RemoteCommandResult(exitCode: 0, output: Data(output.utf8), outputTruncated: false, errorOutput: ""))
      })

    _ = try await owner.run(RemoteShellCommand(executable: "git", arguments: ["status"]))
    _ = try await owner.run(RemoteScript(text: "wt ls", arguments: ["--json"]))

    let recorded = calls.value
    // The login PATH is resolved once, then reused.
    #expect(recorded.count == 3)
    #expect(recorded[0].arguments.suffix(4) == ["--", "mini", "sh", "-s"])
    #expect(recorded[1].arguments.suffix(4) == ["--", "mini", "sh", "-s"])
    #expect(recorded[1].input.hasPrefix("PATH='/opt/bin:/usr/bin'\nexport PATH\n"))
    #expect(recorded[2].arguments.suffix(4) == ["--", "mini", "bash", "-s"])
    #expect(recorded[2].input.contains("PATH='/opt/bin:/usr/bin'\nexport PATH\nset -- '--json'\n"))
    #expect(recorded.allSatisfy { $0.arguments.contains("ControlMaster=auto") })
  }

  @Test func atMostTheConfiguredNumberOfCommandsRunAtOnce() async throws {
    let gate = CommandGate()
    var configuration = RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-ssh-tests")
    configuration.maxConcurrentCommands = 2
    let owner = RemoteConnectionOwner(
      connection: Self.key, recipe: Self.recipe, configuration: configuration,
      runner: RemoteCommandRunner { _, _, input, _, _ in
        let isLoginPath = (String(bytes: input, encoding: .utf8) ?? "").contains("print_path")
        if !isLoginPath { await gate.enter() }
        let output = isLoginPath ? "\u{1}/usr/bin\u{1}" : ""
        return .exited(
          RemoteCommandResult(exitCode: 0, output: Data(output.utf8), outputTruncated: false, errorOutput: ""))
      })
    _ = await owner.loginPath()

    let commands = Task {
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<6 {
          group.addTask { _ = try? await owner.run(RemoteShellCommand(executable: "true", arguments: ["\(index)"])) }
        }
      }
    }
    await gate.waitUntilEntered(2)
    for _ in 0..<100 { await Task.yield() }
    #expect(await gate.entered == 2)
    #expect(await owner.runningCommandCount == 2)
    await gate.openAll()
    await commands.value

    #expect(await gate.entered == 6)
    #expect(await gate.peak == 2)
    #expect(await owner.runningCommandCount == 0)
  }

  @Test func aCancelledWaiterLeavesTheQueueWithoutConnecting() async throws {
    let gate = CommandGate()
    var configuration = RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-ssh-tests")
    configuration.maxConcurrentCommands = 1
    let owner = RemoteConnectionOwner(
      connection: Self.key, recipe: Self.recipe, configuration: configuration,
      runner: RemoteCommandRunner { _, _, input, _, _ in
        let isLoginPath = (String(bytes: input, encoding: .utf8) ?? "").contains("print_path")
        if !isLoginPath { await gate.enter() }
        return .exited(RemoteCommandResult(exitCode: 0, output: Data(), outputTruncated: false, errorOutput: ""))
      })
    _ = await owner.loginPath()
    let first = Task { try await owner.run(RemoteShellCommand(executable: "true")) }
    await gate.waitUntilEntered(1)
    let waiting = Task { try await owner.run(RemoteShellCommand(executable: "true")) }
    for _ in 0..<100 { await Task.yield() }

    waiting.cancel()
    let cancelled = try await waiting.value
    await gate.openAll()
    _ = try await first.value

    #expect(cancelled == .launchFailed(RemoteConnectionOwner.laneClosedReason))
    #expect(await gate.entered == 1)
    #expect(await owner.runningCommandCount == 0)
  }

  @Test func afterShutdownTheLaneRunsNothing() async throws {
    let calls = LockIsolated<[[String]]>([])
    let owner = Self.makeOwner(
      runner: RemoteCommandRunner { _, arguments, _, _, _ in
        calls.withValue { $0.append(arguments) }
        return .exited(RemoteCommandResult(exitCode: 0, output: Data(), outputTruncated: false, errorOutput: ""))
      })
    await owner.shutdown()
    let before = calls.value.count

    let outcome = try await owner.run(RemoteShellCommand(executable: "true"))

    #expect(outcome == .launchFailed(RemoteConnectionOwner.laneClosedReason))
    #expect(calls.value.count == before)
  }

  @Test func shutdownStopsActiveCommandsBeforeItsExitAndQueuedOnesNeverConnect() async throws {
    let gate = CommandGate()
    let events = LockIsolated<[String]>([])
    var configuration = RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-ssh-tests")
    configuration.maxConcurrentCommands = 1
    let owner = RemoteConnectionOwner(
      connection: Self.key, recipe: Self.recipe, configuration: configuration,
      runner: RemoteCommandRunner { _, arguments, input, _, _ in
        let text = String(bytes: input, encoding: .utf8) ?? ""
        if arguments.contains("-O") {
          events.withValue { $0.append("exit") }
        } else if !text.contains("print_path") {
          let name = text.contains("queued") ? "queued" : "active"
          events.withValue { $0.append("start \(name)") }
          // Like the live runner, a cancelled command stops.
          await withTaskCancellationHandler {
            await gate.enter()
          } onCancel: {
            Task { await gate.openAll() }
          }
          events.withValue { $0.append("end \(name)") }
        }
        return .exited(RemoteCommandResult(exitCode: 0, output: Data(), outputTruncated: false, errorOutput: ""))
      })
    _ = await owner.loginPath()
    let active = Task { try await owner.run(RemoteShellCommand(executable: "echo", arguments: ["active"])) }
    await gate.waitUntilEntered(1)
    let queued = Task { try await owner.run(RemoteShellCommand(executable: "echo", arguments: ["queued"])) }
    for _ in 0..<100 { await Task.yield() }

    await owner.shutdown()

    #expect(events.value == ["start active", "end active", "exit"])
    #expect(try await queued.value == .launchFailed(RemoteConnectionOwner.laneClosedReason))
    _ = try await active.value
    #expect(await owner.runningCommandCount == 0)
  }

  @Test func theLoginPathHonoursAZDOTDIRSetInZshenv() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "prowl-zdot-\(UUID().uuidString)")
    let zdot = home.appending(path: "zdot")
    try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try #"export ZDOTDIR="$HOME/zdot""#.write(to: home.appending(path: ".zshenv"), atomically: true, encoding: .utf8)
    try #"export PATH="/prowl-zdot-marker:$PATH""#.write(
      to: zdot.appending(path: ".zshrc"), atomically: true, encoding: .utf8)

    let outcome = await RemoteCommandRunner.live.run(
      URL(filePath: "/usr/bin/env"),
      ["-u", "ZDOTDIR", "HOME=\(home.path(percentEncoded: false))", "SHELL=/bin/zsh", "/bin/sh", "-s"],
      Data(RemoteConnectionOwner.loginPathScript.utf8), RemoteCommandLimits(deadline: 10))
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }

    #expect(RemoteConnectionOwner.parseLoginPath(result.output)?.hasPrefix("/prowl-zdot-marker:") == true)
  }

  @Test func concurrentCallersShareOneLoginPathReadAndAFailureIsKept() async {
    let reads = LockIsolated(0)
    let owner = Self.makeOwner(
      runner: RemoteCommandRunner { _, _, _, _, _ in
        reads.withValue { $0 += 1 }
        return .exited(RemoteCommandResult(exitCode: 1, output: Data(), outputTruncated: false, errorOutput: "no"))
      })

    async let first = owner.loginPath()
    async let second = owner.loginPath()
    let results = await [first, second]
    let third = await owner.loginPath()

    #expect(results == [nil, nil])
    #expect(third == nil)
    #expect(reads.value == 1)
  }

  @Test func streamedOutputAndErrorOutputArriveLineByLine() async throws {
    let lines = LockIsolated<[String]>([])
    let owner = Self.makeOwner(
      runner: RemoteCommandRunner(
        execute: { _, _, _, _, _ in
          .exited(
            RemoteCommandResult(
              exitCode: 0, output: Data("\u{1}/usr/bin\u{1}".utf8), outputTruncated: false, errorOutput: ""))
        },
        executeStreaming: { _, _, _, _, _, onOutput in
          onOutput(.standardError, Data("Preparing wor".utf8))
          onOutput(.standardOutput, Data("/srv/wt/".utf8))
          onOutput(.standardError, Data("ktree\nHEAD is now".utf8))
          onOutput(.standardError, Data(" at abc\n".utf8))
          onOutput(.standardOutput, Data("feature\n".utf8))
          return .exited(RemoteCommandResult(exitCode: 0, output: Data(), outputTruncated: false, errorOutput: ""))
        }))

    _ = try await owner.stream(RemoteScript(text: "wt switch feature")) { stream, line in
      lines.withValue { $0.append("\(stream == .standardError ? "err" : "out"): \(line)") }
    }

    #expect(lines.value == ["err: Preparing worktree", "err: HEAD is now at abc", "out: /srv/wt/feature"])
  }

  // MARK: - Live streaming

  @Test func theLiveRunnerStreamsChunksBeforeTheCommandExits() async {
    let chunks = LockIsolated<[String]>([])
    let outcome = await RemoteCommandRunner.live.runStreaming(
      URL(filePath: "/bin/sh"), ["-c", "printf 'one\\n'; printf 'warn\\n' >&2; sleep 0.3; printf 'two\\n'"], Data(),
      RemoteCommandLimits()
    ) { stream, chunk in
      chunks.withValue {
        $0.append("\(stream == .standardError ? "E" : "O")" + (String(bytes: chunk, encoding: .utf8) ?? ""))
      }
    }
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return
    }
    #expect(result.output == Data("one\ntwo\n".utf8))
    #expect(chunks.value.filter { $0.hasPrefix("O") }.map { String($0.dropFirst()) }.joined() == "one\ntwo\n")
    #expect(chunks.value.contains("Ewarn\n"))
    #expect(chunks.value.filter { $0.hasPrefix("O") }.count >= 2)
  }

  // MARK: - A real host (opt-in)

  /// Runs against a real SSH host when `PROWL_REMOTE_LANE_HOST` names one, such as
  /// `TEST_RUNNER_PROWL_REMOTE_LANE_HOST=mini xcodebuild test …`. Skipped otherwise.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PROWL_REMOTE_LANE_HOST"] != nil))
  func aRealHostRunsCommandsScriptsAndStreams() async throws {
    let host = try #require(ProcessInfo.processInfo.environment["PROWL_REMOTE_LANE_HOST"])
    let owner = RemoteConnectionOwner(
      connection: ConnectionKey(user: NSUserName(), hostname: host), recipe: SSHConnectionRecipe(destination: host),
      configuration: RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-lane-live"))

    let path = try #require(await owner.loginPath())
    #expect(path.contains("/usr/bin"))

    guard case .exited(let git) = try await owner.run(RemoteShellCommand(executable: "git", arguments: ["--version"]))
    else {
      Issue.record("git did not run")
      return
    }
    #expect(git.exitCode == 0)
    #expect((String(bytes: git.output, encoding: .utf8) ?? "").hasPrefix("git version"))

    let script = RemoteScript(
      text: #"printf '%s|%s|%s\n' "$1" "$2" "$(pwd -P)""#, arguments: ["a b", "it's"], workingDirectory: "/")
    guard case .exited(let ran) = try await owner.run(script) else {
      Issue.record("the script did not run")
      return
    }
    #expect((String(bytes: ran.output, encoding: .utf8) ?? "") == "a b|it's|/\n")

    let lines = LockIsolated<[String]>([])
    _ = try await owner.stream(RemoteScript(text: "echo one; sleep 0.3; echo progress >&2; echo two")) {
      stream, line in lines.withValue { $0.append("\(stream == .standardError ? "err" : "out"): \(line)") }
    }
    // Output and error output are separate pipes, so only the order within each is fixed.
    #expect(lines.value.filter { $0.hasPrefix("out") } == ["out: one", "out: two"])
    #expect(lines.value.contains("err: progress"))

    await owner.shutdown()
  }

  // MARK: - Helpers

  private static func makeOwner(runner: RemoteCommandRunner) -> RemoteConnectionOwner {
    RemoteConnectionOwner(
      connection: key, recipe: recipe,
      configuration: RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-ssh-tests"), runner: runner)
  }

  private static func runBash(_ input: String) async throws -> String {
    let outcome = await RemoteCommandRunner.live.run(
      URL(filePath: "/bin/bash"), ["-s"], Data(input.utf8), RemoteCommandLimits(deadline: 10))
    guard case .exited(let result) = outcome else {
      Issue.record("expected exit, got \(outcome)")
      return ""
    }
    #expect(result.exitCode == 0, "stderr: \(result.errorOutput)")
    return (String(bytes: result.output, encoding: .utf8) ?? "")
  }

}

/// Holds lane commands until the test opens it, and counts how many ran at once.
private actor CommandGate {
  private(set) var entered = 0
  private(set) var peak = 0
  private var inside = 0
  private var isOpen = false
  private var held: [CheckedContinuation<Void, Never>] = []
  private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func enter() async {
    entered += 1
    inside += 1
    peak = max(peak, inside)
    for watcher in watchers where entered >= watcher.count { watcher.continuation.resume() }
    watchers.removeAll { entered >= $0.count }
    if !isOpen { await withCheckedContinuation { held.append($0) } }
    inside -= 1
  }

  func waitUntilEntered(_ count: Int) async {
    guard entered < count else { return }
    await withCheckedContinuation { watchers.append((count, $0)) }
  }

  func openAll() {
    isOpen = true
    for continuation in held { continuation.resume() }
    held.removeAll()
  }
}
