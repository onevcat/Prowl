import Foundation

nonisolated struct CodexShellLaunchEnvironment: Equatable, Sendable {
  let executableURL: URL
  let processEnvironment: [String: String]
}

nonisolated enum CodexShellLaunchEnvironmentProbe {
  private static let executableMarker = "__PROWL_CODEX_EXECUTABLE__"
  private static let homeMarker = "__PROWL_CODEX_HOME_BASE__"
  private static let codexHomeMarker = "__PROWL_CODEX_HOME__"
  private static let endMarker = "__PROWL_CODEX_END__"
  private static let script = """
    executable="$(command -v -- codex)" || exit 1
    printf '%s%s\n' '\(executableMarker)' "$executable"
    printf '%s%s\n' '\(homeMarker)' "${HOME-}"
    printf '%s%s\n' '\(codexHomeMarker)' "${CODEX_HOME-}"
    printf '%s\n' '\(endMarker)'
    """

  static func resolve(
    cwd: URL,
    pathOverride: String? = nil,
    run: (@Sendable (URL, String) async throws -> ShellOutput)? = nil,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) async -> CodexShellLaunchEnvironment? {
    let execute =
      run ?? { cwd, script in
        try await CodexShellProbeProcess().run(cwd: cwd, script: script)
      }
    let effectiveScript: String
    if let pathOverride {
      effectiveScript = "PATH=\(AgentInvocation.shellQuote(pathOverride)); export PATH\n" + script
    } else {
      effectiveScript = script
    }
    guard
      let output = try? await execute(cwd, effectiveScript),
      output.exitCode == 0,
      output.stdout.utf8.count <= 16 * 1_024,
      let values = parse(output.stdout),
      let executable = values[executableMarker], executable.hasPrefix("/"),
      isExecutable(executable),
      let home = values[homeMarker], home.hasPrefix("/")
    else { return nil }

    var environment = ["HOME": home]
    if let codexHome = values[codexHomeMarker], !codexHome.isEmpty {
      guard codexHome.hasPrefix("/") else { return nil }
      environment["CODEX_HOME"] = codexHome
    }
    return CodexShellLaunchEnvironment(
      executableURL: URL(filePath: executable, directoryHint: .notDirectory).standardizedFileURL,
      processEnvironment: environment
    )
  }

  private static func parse(_ output: String) -> [String: String]? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let markers = [executableMarker, homeMarker, codexHomeMarker]
    guard
      markers.allSatisfy({ marker in lines.count(where: { $0.hasPrefix(marker) }) == 1 }),
      lines.count(where: { $0 == endMarker }) == 1,
      let startIndex = lines.firstIndex(where: { $0.hasPrefix(executableMarker) }),
      lines.indices.contains(startIndex + 3),
      lines[startIndex + 1].hasPrefix(homeMarker),
      lines[startIndex + 2].hasPrefix(codexHomeMarker),
      lines[startIndex + 3] == endMarker
    else { return nil }
    return [
      executableMarker: String(lines[startIndex].dropFirst(executableMarker.count)),
      homeMarker: String(lines[startIndex + 1].dropFirst(homeMarker.count)),
      codexHomeMarker: String(lines[startIndex + 2].dropFirst(codexHomeMarker.count)),
    ]
  }
}
