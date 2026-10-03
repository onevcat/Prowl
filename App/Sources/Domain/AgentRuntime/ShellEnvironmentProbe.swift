import Foundation

/// Resolves environment variables from the user's login shell (rc sourced) so a value exported
/// there — not only a Prowl Profile override — is visible before a managed hook is injected.
/// One spawn answers several variables; a value may span lines, and "set but empty" is kept
/// apart from "unset" because runtimes treat the two differently.
nonisolated enum ShellEnvironmentProbe {
  enum Resolution: Equatable, Sendable {
    /// The shell answered: every requested variable maps to its exported value, or `nil` when unset.
    case values([String: String?])
    /// The shell could not be consulted, so the variables' presence is unknown.
    case failed
  }

  static let maximumOutputBytes = 256 * 1_024
  private static let beginMarker = "__PROWL_ENV_BEGIN__"
  private static let valueMarker = "__PROWL_ENV_VALUE__"
  private static let endMarker = "__PROWL_ENV_END__"

  static func script(for variables: [String]) -> String {
    variables.map { name in
      """
      printf '%s %s %s\\n' '\(beginMarker)' '\(name)' "${\(name)+set}"
      printf '%s\\n' '\(valueMarker)'
      printf '%s\\n' "${\(name)-}"
      printf '%s\\n' '\(endMarker)'
      """
    }.joined(separator: "\n")
  }

  static func resolve(
    variables: [String],
    cwd: URL,
    pathOverride: String? = nil,
    run: (@Sendable (URL, String) async throws -> ShellOutput)? = nil
  ) async -> Resolution {
    guard !variables.isEmpty, variables.allSatisfy(isShellIdentifier) else { return .failed }
    let execute = run ?? defaultRunner()
    var effectiveScript = script(for: variables)
    if let pathOverride {
      effectiveScript = "PATH=\(AgentInvocation.shellQuote(pathOverride)); export PATH\n" + effectiveScript
    }
    guard
      let output = try? await execute(cwd, effectiveScript),
      output.exitCode == 0,
      output.stdout.utf8.count <= maximumOutputBytes,
      let values = parse(output.stdout, variables: variables)
    else { return .failed }
    return .values(values)
  }

  /// The production runner: the login-shell probe Codex uses, with this probe's output bound.
  /// The Codex config probe defaults to 16 KiB; an exported `OPENCODE_CONFIG_CONTENT` can
  /// legitimately be larger. `environment` is for tests that must not mutate the host's.
  static func defaultRunner(
    timeout: TimeInterval = 1,
    environment: [String: String]? = nil
  ) -> @Sendable (URL, String) async throws -> ShellOutput {
    let process = CodexShellProbeProcess(
      timeout: timeout,
      maximumOutputBytes: maximumOutputBytes,
      environment: environment
    )
    return { cwd, script in try await process.run(cwd: cwd, script: script) }
  }

  private static func isShellIdentifier(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else {
      return false
    }
    return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
  }

  /// Every requested variable must appear exactly once, in a complete begin/value/end block.
  private static func parse(_ output: String, variables: [String]) -> [String: String?]? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var values: [String: String?] = [:]
    var index = 0
    while index < lines.count {
      let line = lines[index]
      guard line.hasPrefix(beginMarker + " ") else {
        index += 1
        continue
      }
      let header = line.dropFirst(beginMarker.count + 1).split(separator: " ", omittingEmptySubsequences: false)
      guard header.count == 2, lines.indices.contains(index + 1), lines[index + 1] == valueMarker else { return nil }
      let name = String(header[0])
      let isSet = header[1] == "set"
      guard let end = lines[(index + 2)...].firstIndex(of: endMarker) else { return nil }
      let value = lines[(index + 2)..<end].joined(separator: "\n")
      guard values[name] == nil else { return nil }
      values[name] = isSet ? .some(value) : .some(nil)
      index = end + 1
    }
    guard Set(values.keys) == Set(variables) else { return nil }
    return values
  }
}
