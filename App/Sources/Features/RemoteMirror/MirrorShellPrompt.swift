import Foundation

/// Whether a command from a mirror can go to a shell pane now. Two kinds of evidence are
/// needed, because neither is enough alone:
///
/// - The terminal belongs to the interactive shell: at its prompt, a shell with job control is
///   the only process of the foreground group, and it runs no script. This names a program
///   that runs in front.
/// - The cursor is on the input line of a primary prompt, from shell integration (OSC 133).
///   The process inventory looks the same at a continuation prompt of a pending command and
///   while a builtin such as `read` waits for input, and a command sent there would join the
///   pending command or become the builtin's answer.
nonisolated enum MirrorShellPrompt {
  static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish"]

  /// What the terminal reports about the input line (`ghostty_surface_input_state`).
  struct InputState: Equatable, Sendable {
    /// The cursor is on the input line of a primary shell prompt.
    let primaryPrompt: Bool
    /// The shell asked for bracketed paste, so pasted newlines and tabs stay text.
    let bracketedPaste: Bool
  }

  /// Nil when `text` can go to the shell now, else why not.
  static func refusal(for job: ForegroundJob?, input: InputState?, text: String) -> String? {
    if let refusal = refusal(for: job) { return refusal }
    guard let input else { return String(localized: "The Mac could not read the state of this terminal.") }
    guard input.primaryPrompt else {
      return String(
        localized: """
          The shell is not waiting for a new command: a command is still pending or running, \
          or the shell has no Ghostty shell integration. Check the pane on the Mac.
          """)
    }
    if needsPaste(text), !input.bracketedPaste {
      return String(localized: "This shell takes one line without tabs from a mirror.")
    }
    return nil
  }

  /// Text that must be pasted: typed, a newline would run its line and a tab would complete.
  static func needsPaste(_ text: String) -> Bool {
    text.contains { $0 == "\n" || $0 == "\r" || $0 == "\t" }
  }

  /// Nil when the shell alone is in front, else why a command cannot go now.
  static func refusal(for job: ForegroundJob?) -> String? {
    guard let job, let leader = job.processes.first(where: { $0.ref == .local(job.processGroupID) }) else {
      return String(localized: "The Mac could not read what runs in this pane.")
    }
    let name = shellName(leader.name)
    guard job.processes.count == 1, shells.contains(name) else {
      let program = job.processes.first { !shells.contains(shellName($0.name)) }?.name ?? leader.name
      return String(localized: "\(program) is running in this pane. Stop it first, for example with ⌃C.")
    }
    guard let arguments = leader.arguments else {
      return String(localized: "The Mac could not read what runs in this pane.")
    }
    // A shell that runs a script or `-c` has an operand; an interactive one has only options.
    guard arguments.dropFirst().allSatisfy({ $0.hasPrefix("-") }) else {
      return String(localized: "A script is running in this pane. Wait for it or stop it first.")
    }
    return nil
  }

  /// A login shell's name starts with `-`.
  private static func shellName(_ name: String) -> String {
    String(name.drop { $0 == "-" }).lowercased()
  }
}
