import Foundation

/// Resolves `FACTORY_RUNTIME_SETTINGS_PATH` from the user's login shell so a value exported in
/// an rc file (not just a Prowl Profile override) is visible before Prowl injects its own
/// `--settings`. Droid's flag outranks the variable, so overriding it silently would drop the
/// user's models, keys, and hooks; the caller merges the resolved file as the base instead, and
/// degrades — never injects — when the probe cannot run.
nonisolated enum DroidSettingsEnvironmentProbe {
  static let variableName = "FACTORY_RUNTIME_SETTINGS_PATH"

  enum Resolution: Equatable, Sendable {
    /// The shell answered: `path` is the exported value, or `nil` when the variable is unset.
    case value(String?)
    /// The shell could not be consulted, so the variable's presence is unknown.
    case failed
  }

  static func resolve(
    cwd: URL,
    pathOverride: String? = nil,
    run: (@Sendable (URL, String) async throws -> ShellOutput)? = nil
  ) async -> Resolution {
    switch await ShellEnvironmentProbe.resolve(
      variables: [variableName],
      cwd: cwd,
      pathOverride: pathOverride,
      run: run
    ) {
    case .failed:
      return .failed
    case .values(let values):
      guard let entry = values[variableName] else { return .failed }
      // Droid treats a blank value as unset; trim so trailing shell whitespace does not become a path.
      let trimmed = (entry ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return .value(trimmed.isEmpty ? nil : trimmed)
    }
  }
}
