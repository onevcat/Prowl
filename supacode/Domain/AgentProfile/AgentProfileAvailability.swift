import Foundation
import ProwlCLIShared

/// One shared availability judgment for every profile launcher surface
/// (Agents popover, Command Palette), so entry points can never disagree
/// (docs-ai 053/005). The installation heuristic is deliberately soft — the
/// runtime's default home exists iff the CLI has ever run — so a non-nil
/// warning must gray a row, never block the launch: a false negative
/// (installed but never run, or a dedicated-home-only login) would otherwise
/// lock out a perfectly launchable profile.
nonisolated enum AgentProfileAvailability {
  /// Two-tier judgment. The login-shell probe is ground truth once it has
  /// answered — it resolves the executable exactly the way a launch will, in
  /// both directions (installed-but-never-run stops warning; uninstalled with
  /// a leftover home starts warning). Until it answers, the home-directory
  /// heuristic fills in.
  static func launchWarning(
    for profile: AgentProfile,
    probedAvailable: Bool?,
    isRuntimeInstalled: (AgentProfileRuntime) -> Bool = isRuntimeInstalled
  ) -> String? {
    let name = AgentRuntimeAdapterRegistry.displayName(for: profile.runtime)
    switch probedAvailable {
    case true?:
      return nil
    case false?:
      return "\(name) is not on your shell's PATH"
    case nil:
      return isRuntimeInstalled(profile.runtime) ? nil : "\(name) may not be installed"
    }
  }

  /// The runtime's default home exists iff the CLI has ever run; PATH lookups
  /// from a GUI app are unreliable (docs-ai 053). Also the seeding heuristic.
  static func isRuntimeInstalled(_ runtime: AgentProfileRuntime) -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: runtime.defaultHomeDirectoryName, directoryHint: .isDirectory)
    return FileManager.default.fileExists(atPath: home.path(percentEncoded: false))
  }
}
