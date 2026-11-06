import Foundation

/// Whether a shell pane's terminal belongs to its interactive shell, so a command from a mirror
/// goes to the shell and not to a program that runs in front of it. At its prompt, a shell
/// with job control is the only process of the terminal's foreground group, and it runs no
/// script.
nonisolated enum MirrorShellPrompt {
  static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish"]

  /// Nil when the shell is at its prompt, else why a command cannot go now.
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
