import Foundation
import Sharing

/// A pane that Prowl opened for a remote folder (docs-ai 084 C3b): the host profile, the
/// stored recipe that the pane's `ssh` uses, and the launch whose completion marker this
/// pane accepts once.
nonisolated struct RemoteLaunchOrigin: Equatable, Sendable {
  let hostProfileID: UUID
  /// The profile's alias, the label that the pane and its agents show.
  let alias: String
  let recipe: SSHConnectionRecipe
  let nonce: String
  /// Whether the launch has a first command, so a marker is expected.
  let hasFirstCommand: Bool
  /// When the pane started its `ssh` (staging is not part of the command's duration).
  var launchedAt: Date
  /// The host directory that the pane's shell started in. Where the pane is while no
  /// snapshot reads its session: a macOS host hides its system shell's environment, so a
  /// pane with only that shell in front never maps.
  var workingDirectory: String?
  /// The pane's `ssh`, once a probe saw it in the foreground: the `ssh` whose arguments
  /// carry the launch's nonce (the launcher path), never one the user typed later.
  var ssh: LocalProcessGeneration?
  /// The `ssh` ended: the pane is a local shell again, and its later commands are local.
  var sessionEnded = false
  /// A local "command finished" came before any probe saw the `ssh`: the next probe tells
  /// whether it was the `ssh` ending (no `ssh` in front) or a remote shell's OSC 133.
  var unboundFinishSeen = false
  /// A probe saw the `ssh` exit before the local shell reported its finish: that finish is
  /// still to come and completes nothing.
  var swallowsNextFinish = false
  /// The completion marker arrived (it counts once).
  var completed = false
}

/// The line that a remote pane's local shell runs: `ssh -t <recipe> -- exec sh <launcher>`.
nonisolated enum RemoteTerminalLine {
  enum LineError: Error, Equatable, LocalizedError {
    /// An option or the launcher path has a character that no local shell takes the same
    /// way in a typed line (a backslash or a control character), or a launcher path that
    /// the host's shell would split.
    case untypeable

    var errorDescription: String? {
      String(localized: "The SSH options of this remote host cannot be typed into a terminal.")
    }
  }

  /// The session options that a configuration could set to something else than running the
  /// launcher in the foreground: a `RemoteCommand` (such as `tmux attach`) conflicts with the
  /// command (`Cannot execute command-line and remote command`), and `SessionType`,
  /// `ForkAfterAuthentication` or `StdinNull` would run no interactive session. `ssh` keeps
  /// the first value it obtains, so these come before the recipe. Forwardings, the agent and
  /// the other options stay as the user's configuration sets them.
  static let sessionOverrides = [
    "-o", "RemoteCommand=none",
    "-o", "SessionType=default",
    "-o", "ForkAfterAuthentication=no",
    "-o", "StdinNull=no",
  ]

  /// Characters that zsh, bash and fish all take literally outside quotes.
  private static let safeCharacters = Set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")

  /// The typed line, with a leading space (shells that ignore such lines keep it out of the
  /// history) and a newline. Each argument is bare when it is safe, otherwise single-quoted;
  /// a backslash or a control character is refused, because fish reads `\\` inside single
  /// quotes. The launcher path is a word of the remote command, so it must be safe as is.
  static func typed(recipe: SSHConnectionRecipe, launcherPath: String) throws(LineError) -> String {
    guard !launcherPath.isEmpty, launcherPath.allSatisfy(safeCharacters.contains) else { throw .untypeable }
    let arguments =
      ["/usr/bin/ssh", "-t"] + sessionOverrides + recipe.options
      + ["--", recipe.destination, "exec", "sh", launcherPath]
    var words: [String] = []
    for argument in arguments {
      if !argument.isEmpty, argument.allSatisfy(safeCharacters.contains) {
        words.append(argument)
        continue
      }
      guard !argument.unicodeScalars.contains(where: { $0 == "\\" || $0.value < 0x20 || $0.value == 0x7f })
      else { throw .untypeable }
      words.append(RemoteShellCommand.quote(argument))
    }
    return " " + words.joined(separator: " ") + "\n"
  }
}

/// Stages the launcher of a remote pane on its host (docs-ai 084 C3b).
nonisolated struct RemoteTerminalStager: Sendable {
  /// The stored host profile, read when the tab opens.
  var profile: @MainActor @Sendable (_ hostProfileID: UUID) -> HostProfile?
  /// Writes the launch on the host and returns the launcher's path.
  var stage: @Sendable (_ profile: HostProfile, _ launch: RemoteLaunch) async throws -> String

  static let live = RemoteTerminalStager(
    profile: { hostProfileID in
      @Shared(.hostProfiles) var hostProfiles: [HostProfile]
      return hostProfiles.first { $0.id == hostProfileID }
    },
    stage: { profile, launch in
      let outcome = try await RemoteCommandLane.leased(profile).run(
        try RemoteLauncher.stagingCommand(for: launch), .commandLane)
      switch outcome {
      case .exited(let result) where result.exitCode == 0:
        return try RemoteLauncher.stagedLauncherPath(
          from: String(bytes: result.output, encoding: .utf8) ?? "", for: launch)
      case .exited(let result):
        let reason = result.errorOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        throw RemoteRepositoryHostError.connection(.exit(result.exitCode, reason))
      case .timedOut:
        throw RemoteRepositoryHostError.timedOut
      case .launchFailed(let reason):
        throw RemoteRepositoryHostError.connection(.launch(reason))
      }
    })
}
