import Foundation

internal nonisolated struct TmuxCommandResult: Equatable, Sendable {
  internal let stdout: String
  internal let stderr: String
  internal let exitCode: Int32

  internal init(stdout: String, stderr: String, exitCode: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

internal typealias TmuxCommandExecutor =
  @Sendable (_ executable: URL, _ arguments: [String]) async throws -> TmuxCommandResult

internal typealias TmuxExecutableResolver = @Sendable () -> URL?

internal nonisolated enum TmuxTerminalControllerError: Error, Equatable, Sendable {
  case tmuxUnavailable
  case commandFailed(arguments: [String], stderr: String, exitCode: Int32)
  case invalidNewWindowOutput(String)
}

@MainActor
internal final class TmuxTerminalController {
  private let executableURL: URL?
  private let userConfigPath: String
  private let execute: TmuxCommandExecutor
  private let logger = SupaLogger("TmuxTerminal")

  internal init(
    resolveExecutable: @escaping TmuxExecutableResolver = TmuxTerminalController.defaultResolveExecutable,
    userConfigPath: String = TmuxTerminalController.defaultUserConfigPath,
    execute: @escaping TmuxCommandExecutor = TmuxTerminalController.liveExecute
  ) {
    self.executableURL = resolveExecutable()
    self.userConfigPath = userConfigPath
    self.execute = execute
  }

  internal init(
    executableURL: URL,
    userConfigPath: String = TmuxTerminalController.defaultUserConfigPath,
    execute: @escaping TmuxCommandExecutor = TmuxTerminalController.liveExecute
  ) {
    self.executableURL = executableURL
    self.userConfigPath = userConfigPath
    self.execute = execute
  }

  internal var isAvailable: Bool {
    executableURL != nil
  }

  internal func ensureGroup(target: TmuxTerminalTarget, cwd: URL) async throws {
    let result = try await run(
      [
        "-S", target.socketURL.path,
        "has-session",
        "-t", target.groupSession,
      ],
      allowFailure: true
    )
    if result.exitCode != 0 {
      _ = try await run([
        "-S", target.socketURL.path,
        "-f", "/dev/null",
        "new-session", "-d",
        "-s", target.groupSession,
        "-n", "__prowl_bootstrap",
        "-c", cwd.path,
      ])
    }

    try await configureGroupSessionOptions(in: target.groupSession, socketURL: target.socketURL)
  }

  private func configureGroupSessionOptions(in session: String, socketURL: URL) async throws {
    _ = try await run([
      "-S", socketURL.path,
      "set-option",
      "-t", session,
      "status", "off",
    ])
    try await enableMouseScrolling(in: session, socketURL: socketURL)
    try await configureProwlKeyBindings(socketURL: socketURL)
  }

  internal func createWindow(
    target: TmuxTerminalTarget,
    cwd: URL,
    title: String
  ) async throws -> TmuxTerminalTarget {
    var updated = target
    let result = try await run([
      "-S", target.socketURL.path,
      "new-window", "-d", "-P",
      "-F", "#{window_id} #{pane_id}",
      "-t", "\(target.groupSession):",
      "-n", title,
      "-c", cwd.path,
    ])
    let ids = result.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
    guard ids.count >= 2,
      let windowID = TmuxWindowID(rawValue: ids[0]),
      let paneID = TmuxPaneID(rawValue: ids[1])
    else {
      throw TmuxTerminalControllerError.invalidNewWindowOutput(result.stdout)
    }

    updated.windowID = windowID
    updated.paneID = paneID
    try await ensureClientSession(target: updated)
    return updated
  }

  internal func ensureClientSession(target: TmuxTerminalTarget) async throws {
    let result = try await run(
      [
        "-S", target.socketURL.path,
        "has-session",
        "-t", target.clientSession,
      ],
      allowFailure: true
    )
    if result.exitCode != 0 {
      _ = try await run([
        "-S", target.socketURL.path,
        "new-session", "-d",
        "-t", target.groupSession,
        "-s", target.clientSession,
      ])
    }

    if let windowID = target.windowID {
      _ = try await run([
        "-S", target.socketURL.path,
        "select-window",
        "-t", "\(target.clientSession):\(windowID.rawValue)",
      ])
    }

    _ = try await run([
      "-S", target.socketURL.path,
      "set-option",
      "-t", target.clientSession,
      "status", "off",
    ])
    try await enableMouseScrolling(in: target.clientSession, socketURL: target.socketURL)
    try await configureProwlKeyBindings(socketURL: target.socketURL)
  }

  private func enableMouseScrolling(in session: String, socketURL: URL) async throws {
    _ = try await run([
      "-S", socketURL.path,
      "set-option",
      "-t", session,
      "mouse", "on",
    ])
  }

  private func configureProwlKeyBindings(socketURL: URL) async throws {
    _ = try await run([
      "-S", socketURL.path,
      "set-option",
      "-g",
      "prefix2",
      "C-q",
    ])
    _ = try await run([
      "-S", socketURL.path,
      "bind-key",
      "C-q",
      "send-prefix",
      "-2",
    ])
    _ = try await run([
      "-S", socketURL.path,
      "bind-key",
      "-T",
      "copy-mode-vi",
      "v",
      "send-keys",
      "-X",
      "begin-selection",
    ])
    _ = try await run([
      "-S", socketURL.path,
      "bind-key",
      "-T",
      "copy-mode-vi",
      "y",
      "send-keys",
      "-X",
      "copy-pipe-and-cancel",
      "reattach-to-user-namespace pbcopy",
    ])
    _ = try await run([
      "-S", socketURL.path,
      "bind-key",
      "-T",
      "copy-mode-vi",
      "Enter",
      "send-keys",
      "-X",
      "copy-pipe-and-cancel",
      "reattach-to-user-namespace pbcopy",
    ])
    _ = try await run([
      "-S", socketURL.path,
      "source-file",
      userConfigPath,
    ], allowFailure: true)
  }

  internal func prepareExistingWindowForAttach(target: TmuxTerminalTarget) async throws -> TmuxTerminalTarget {
    guard let windowID = target.windowID else {
      throw TmuxTerminalControllerError.invalidNewWindowOutput("missing restore window id")
    }
    let result = try await run(
      [
        "-S", target.socketURL.path,
        "display-message",
        "-p",
        "-t", windowID.rawValue,
        "#{window_id}",
      ],
      allowFailure: true
    )
    guard result.exitCode == 0,
      result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == windowID.rawValue
    else {
      throw TmuxTerminalControllerError.commandFailed(
        arguments: ["display-message", "-t", windowID.rawValue],
        stderr: result.stderr,
        exitCode: result.exitCode
      )
    }
    try await ensureClientSession(target: target)
    return target
  }

  internal func attachCommand(for target: TmuxTerminalTarget) -> String {
    [
      shellQuote(executableURL?.path ?? "tmux"),
      "-S", shellQuote(target.socketURL.path),
      "-CC",
      "attach-session",
      "-t", shellQuote(target.clientSession),
    ]
    .joined(separator: " ")
  }

  internal func killWindow(target: TmuxTerminalTarget) async throws {
    guard let windowID = target.windowID else { return }

    _ = try await run(
      [
        "-S", target.socketURL.path,
        "kill-window",
        "-t", windowID.rawValue,
      ],
      allowFailure: true
    )
    _ = try await run(
      [
        "-S", target.socketURL.path,
        "kill-session",
        "-t", target.clientSession,
      ],
      allowFailure: true
    )
  }

  private func run(_ arguments: [String], allowFailure: Bool = false) async throws -> TmuxCommandResult {
    guard let executableURL else {
      throw TmuxTerminalControllerError.tmuxUnavailable
    }

    let result = try await execute(executableURL, arguments)
    guard result.exitCode == 0 || allowFailure else {
      logger.warning("tmux failed args=\(arguments.joined(separator: " ")) stderr=\(result.stderr)")
      throw TmuxTerminalControllerError.commandFailed(
        arguments: arguments,
        stderr: result.stderr,
        exitCode: result.exitCode
      )
    }
    return result
  }

  internal nonisolated static func resolveExecutable(
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> URL? {
    let path = executableCandidatePaths.first(where: isExecutable)
    return path.map { URL(fileURLWithPath: $0, isDirectory: false) }
  }

  private nonisolated static var executableCandidatePaths: [String] {
    [
      "/opt/homebrew/bin/tmux",
      "/usr/local/bin/tmux",
      "/usr/bin/tmux",
    ]
  }

  private nonisolated static func defaultResolveExecutable() -> URL? {
    resolveExecutable()
  }

  private nonisolated static var defaultUserConfigPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/prowl/tmux.conf", directoryHint: .notDirectory)
      .path(percentEncoded: false)
  }

  internal nonisolated static func liveExecute(executable: URL, arguments: [String]) async throws -> TmuxCommandResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    async let stdoutData = readDataToEndOfFile(from: stdout.fileHandleForReading)
    async let stderrData = readDataToEndOfFile(from: stderr.fileHandleForReading)
    process.waitUntilExit()

    let outputData = await stdoutData
    let errorData = await stderrData
    return TmuxCommandResult(
      stdout: String(data: outputData, encoding: .utf8) ?? "",
      stderr: String(data: errorData, encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
  }

  private nonisolated static func readDataToEndOfFile(from fileHandle: FileHandle) async -> Data {
    (try? fileHandle.readToEnd()) ?? Data()
  }
}
