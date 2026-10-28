import Foundation
import GhosttyKit

/// Runs Ghostty CLI actions (`ghostty +ssh`, `ghostty +list-themes`, ...) when the app
/// executable starts through its `Contents/MacOS/ghostty` symlink (docs-ai 085).
///
/// libghostty sets `GHOSTTY_BIN_DIR` to `Contents/MacOS` in every pane, and Ghostty's shell
/// integration runs `$GHOSTTY_BIN_DIR/ghostty` (for example, the `ssh` wrapper of the
/// `ssh-env` and `ssh-terminfo` features). Ghostty.app uses one executable for the GUI and
/// the CLI; Prowl does the same with the libghostty it embeds.
nonisolated enum GhosttyCLIEntry {
  static let programName = "ghostty"

  static func isGhosttyInvocation(argv0: String?) -> Bool {
    argv0?.split(separator: "/").last == Substring(programName)
  }

  static func run() -> Never {
    GhosttyBundledResources.export()
    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      writeToStandardError(
        """
        Ghostty failed to initialize. This is usually because an invalid action or multiple \
        actions were specified. Actions start with the `+` character.

        View all available actions by running `ghostty +help`.

        """
      )
      exit(1)
    }
    // Runs the action and exits. It returns only when the arguments name no action.
    ghostty_cli_try_action()
    writeToStandardError(
      """
      This `ghostty` comes with Prowl and runs only Ghostty CLI actions, such as \
      `ghostty +ssh` or `ghostty +list-themes`. It cannot open terminal windows.

      View all available actions by running `ghostty +help`.

      """
    )
    exit(1)
  }

  private static func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
  }
}

nonisolated enum GhosttyBundledResources {
  /// Points libghostty at the resources in the app bundle (themes, shell integration,
  /// terminfo), whatever the parent process set.
  static func export() {
    // No directory hint: the value keeps no trailing slash, as it had before.
    guard let resourceURL = Bundle.main.resourceURL?.appending(path: "ghostty") else { return }
    setenv("GHOSTTY_RESOURCES_DIR", resourceURL.path(percentEncoded: false), 1)
  }
}
