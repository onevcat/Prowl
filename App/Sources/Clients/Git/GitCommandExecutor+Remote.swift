import ConcurrencyExtras
import Foundation

nonisolated enum RemoteRepositoryHostError: Error, Equatable, LocalizedError {
  /// `ssh` could not reach the host or log in.
  case connection(RemoteProbeFailure)
  case timedOut
  /// `ssh -G` rejected the host profile's options.
  case configurationRejected
  /// The SSH configuration now reaches another user, host name or port than the one the
  /// host profile was bound to; C1 asks the user to rebind it.
  case authorityChanged
  /// `git` is not on the host's login `PATH`.
  case gitMissing
  /// The output reached the lane's output budget, so it is incomplete.
  case outputTooLarge
  /// The operation has no remote implementation yet.
  case unsupported

  var errorDescription: String? {
    switch self {
    case .connection(let failure): failure.remoteFolderDescription
    case .timedOut: String(localized: "The remote host did not answer in time.")
    case .configurationRejected: String(localized: "SSH rejected the options of this remote host.")
    case .authorityChanged:
      String(localized: "The SSH configuration of this remote host now reaches another user, host or port.")
    case .gitMissing: String(localized: "Git was not found on the remote host.")
    case .outputTooLarge: String(localized: "The remote host sent more output than Prowl reads.")
    case .unsupported: String(localized: "Remote folders do not support this yet.")
    }
  }
}

extension RemoteProbeFailure {
  /// The reason shown when a remote folder operation fails to connect.
  nonisolated var remoteFolderDescription: String {
    switch self {
    case .authentication: String(localized: "The remote host refused the SSH login.")
    case .hostKey: String(localized: "The remote host key is unknown or has changed.")
    case .unresolvableHost: String(localized: "The remote host name could not be resolved.")
    case .unreachable: String(localized: "The remote host could not be reached.")
    case .launch(let reason): String(localized: "SSH could not start: \(reason)")
    case .exit(_, let line): String(localized: "SSH failed: \(line)")
    case .unrecognizedOutput: String(localized: "The remote host sent output that Prowl cannot read.")
    }
  }
}

nonisolated extension GitCommandExecutor {
  /// Runs `GitClient` commands on a host through its command lane (docs-ai 084 B3). Use it
  /// only for the `GitClient` methods that run commands; the local-only paths (A5b, 009)
  /// have their own remote implementations in `RemoteRepositoryHost`. Executors of one
  /// host share `gitCache`, so `git` is found once per host.
  static func remote(
    lane: RemoteCommandLane, limits: RemoteCommandLimits,
    gitCache: LockIsolated<GitExecutable?> = LockIsolated(nil)
  ) -> GitCommandExecutor {
    GitCommandExecutor(
      shell: RemoteGitShell.shell(lane: lane, limits: limits),
      resolveGit: { revalidate in
        if !revalidate, let executable = gitCache.value { return executable }
        let executable = try await RemoteGitShell.resolveGit(lane: lane)
        gitCache.setValue(executable)
        return executable
      },
      wtScriptURL: { throw RemoteRepositoryHostError.unsupported }
    )
  }
}

/// Turns the `/usr/bin/env` command lines of `GitClient` into lane commands.
nonisolated enum RemoteGitShell {
  static func shell(lane: RemoteCommandLane, limits: RemoteCommandLimits) -> ShellClient {
    let run: @Sendable (URL, [String], URL?) async throws -> ShellOutput = { executable, arguments, directory in
      let command = command(executable: executable, arguments: arguments, directory: directory)
      return try output(of: try await lane.run(command, limits), command: command)
    }
    return ShellClient(
      run: run,
      runLoginImpl: { executable, arguments, directory, _ in
        try await run(executable, arguments, directory)
      })
  }

  /// `GitExecutable.run` calls `/usr/bin/env NAME=value… git args`. The assignments become
  /// the command's environment, except `PATH`, which the lane sets to the login `PATH`, and
  /// `DEVELOPER_DIR`, which names a folder on this Mac.
  static func command(executable: URL, arguments: [String], directory: URL?) -> RemoteShellCommand {
    var arguments = arguments
    var program = executable.path(percentEncoded: false)
    var environment: [(name: String, value: String)] = []
    if program == "/usr/bin/env" {
      while let first = arguments.first, let separator = first.firstIndex(of: "="),
        RemoteShellCommand.isValidName(String(first[..<separator]))
      {
        environment.append((name: String(first[..<separator]), value: String(first[first.index(after: separator)...])))
        arguments.removeFirst()
      }
      program = arguments.isEmpty ? program : arguments.removeFirst()
    }
    environment.removeAll { $0.name == "PATH" || $0.name == "DEVELOPER_DIR" }
    return RemoteShellCommand(
      executable: program, arguments: arguments,
      workingDirectory: directory?.path(percentEncoded: false), environment: environment)
  }

  /// A non-zero exit becomes a `ShellClientError`, as a local process does, so `GitClient`
  /// handles it the same way. Exit 255 with one of `ssh`'s own messages is a connection
  /// error; git can exit 255 too, and then it stays a git failure.
  static func output(of outcome: RemoteCommandOutcome, command: RemoteShellCommand) throws -> ShellOutput {
    switch outcome {
    case .timedOut:
      throw RemoteRepositoryHostError.timedOut
    case .launchFailed(let reason):
      throw RemoteRepositoryHostError.connection(.launch(reason))
    case .exited(let result):
      guard !result.outputTruncated else { throw RemoteRepositoryHostError.outputTooLarge }
      let stdout = String(bytes: result.output, encoding: .utf8) ?? String(bytes: result.output, encoding: .isoLatin1)
      if result.exitCode == 255, case let failure = RemoteConnectionOwner.failure(result), !failure.isExitStatus {
        throw RemoteRepositoryHostError.connection(failure)
      }
      guard result.exitCode == 0 else {
        throw ShellClientError(
          command: ([command.executable] + command.arguments).joined(separator: " "),
          stdout: stdout ?? "", stderr: result.errorOutput, exitCode: result.exitCode)
      }
      return ShellOutput(stdout: stdout ?? "", stderr: result.errorOutput, exitCode: 0)
    }
  }

  static func resolveGit(lane: RemoteCommandLane) async throws -> GitExecutable {
    let command = RemoteShellCommand(executable: "sh", arguments: ["-c", "command -v git"])
    let output: ShellOutput
    do {
      output = try Self.output(of: try await lane.run(command, .commandLane), command: command)
    } catch is ShellClientError {
      throw RemoteRepositoryHostError.gitMissing
    }
    let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/") else { throw RemoteRepositoryHostError.gitMissing }
    // The lane sets the login `PATH`, so the search path is not sent.
    return GitExecutable(url: URL(filePath: path, directoryHint: .notDirectory), searchPath: "")
  }
}

extension RemoteProbeFailure {
  fileprivate nonisolated var isExitStatus: Bool {
    if case .exit = self { return true }
    return false
  }
}
