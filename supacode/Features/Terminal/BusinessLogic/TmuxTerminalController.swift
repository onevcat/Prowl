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

private nonisolated func tmuxShellQuote(_ value: String) -> String {
  "'\(value.replacing("'", with: "'\"'\"'"))'"
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

  internal var defaultSocketURL: URL? {
    guard isAvailable else { return nil }
    return SupacodePaths.cacheDirectory
      .appending(path: "tmux", directoryHint: .isDirectory)
      .appending(path: "prowl.sock")
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
    title: String,
    metadata: TmuxWindowMetadata
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
    do {
      try await setWindowMetadata(metadata, windowID: windowID, socketURL: target.socketURL)
      try await ensureClientSession(target: updated)
    } catch {
      try? await killCreatedWindow(windowID: windowID, socketURL: target.socketURL)
      throw error
    }
    return updated
  }

  internal func ensureClientSession(target: TmuxTerminalTarget) async throws {
    guard let windowID = target.windowID else {
      try await ensureGroupedClientSession(target: target)
      return
    }

    _ = try await run(
      [
        "-S", target.socketURL.path,
        "kill-session",
        "-t", target.clientSession,
      ],
      allowFailure: true
    )

    try await createIsolatedClientSession(target: target)
    do {
      _ = try await run([
        "-S", target.socketURL.path,
        "link-window",
        "-s", windowID.rawValue,
        "-t", "\(target.clientSession):",
      ])
      try await selectWindow(windowID, in: target)
      _ = try await run(
        [
          "-S", target.socketURL.path,
          "kill-window",
          "-t", "\(target.clientSession):\(TmuxRecoveryScan.clientBootstrapWindowName)",
        ],
        allowFailure: true
      )
      try await configureClientSessionOptions(in: target)
    } catch {
      _ = try await run(
        [
          "-S", target.socketURL.path,
          "kill-session",
          "-t", target.clientSession,
        ],
        allowFailure: true
      )
      throw error
    }
  }

  private func ensureGroupedClientSession(target: TmuxTerminalTarget) async throws {
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

    try await configureClientSessionOptions(in: target)
  }

  private func createIsolatedClientSession(target: TmuxTerminalTarget) async throws {
    _ = try await run([
      "-S", target.socketURL.path,
      "new-session", "-d",
      "-s", target.clientSession,
      "-n", TmuxRecoveryScan.clientBootstrapWindowName,
      TmuxRecoveryScan.clientBootstrapCommand,
    ])
  }

  private func selectWindow(_ windowID: TmuxWindowID, in target: TmuxTerminalTarget) async throws {
    _ = try await run([
      "-S", target.socketURL.path,
      "select-window",
      "-t", "\(target.clientSession):\(windowID.rawValue)",
    ])
  }

  private func configureClientSessionOptions(in target: TmuxTerminalTarget) async throws {
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
    let arguments: [String] = [
      tmuxShellQuote(executableURL?.path ?? "tmux"),
      "-S", tmuxShellQuote(target.socketURL.path),
      "attach-session",
      "-t", tmuxShellQuote(target.clientSession),
    ]
    return arguments.joined(separator: " ")
  }

  internal func panePID(for target: TmuxTerminalTarget) async throws -> pid_t? {
    guard let paneID = target.paneID else { return nil }
    let result = try await run([
      "-S", target.socketURL.path,
      "display-message",
      "-p",
      "-t", paneID.rawValue,
      "#{pane_pid}",
    ])
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(trimmed), pid > 0 else { return nil }
    return pid
  }

  internal func detachedCardSnapshot(
    visibleWindowIDs: Set<TmuxWindowID>
  ) async throws -> TmuxCardRecoverySnapshot {
    let sessions = try await listSessions()
    let diagnostics = structureDiagnostics(from: sessions)
    guard sessions.contains(where: { $0.name == TmuxTerminalTarget.cardContainerSession }) else {
      return TmuxCardRecoverySnapshot(candidates: [], diagnostics: diagnostics)
    }

    let visibleIDs = Set(visibleWindowIDs.map(\.rawValue))
    let records = try await listRawWindowRecords()
    let candidates = records
      .compactMap { TmuxDetachedCardCandidate(record: $0) }
      .filter { !visibleIDs.contains($0.windowID.rawValue) }
      .sorted { left, right in
        if left.createdAt != right.createdAt {
          return (left.createdAt ?? "") > (right.createdAt ?? "")
        }
        return left.windowID.rawValue < right.windowID.rawValue
      }

    return TmuxCardRecoverySnapshot(candidates: candidates, diagnostics: diagnostics)
  }

  private func setWindowMetadata(
    _ metadata: TmuxWindowMetadata,
    windowID: TmuxWindowID,
    socketURL: URL
  ) async throws {
    let options: [(name: String, value: String)] = [
      (ProwlWindowOption.managed, "1"),
      (ProwlWindowOption.cardID, metadata.cardID.rawValue),
      (ProwlWindowOption.worktreeID, metadata.worktreeID),
      (ProwlWindowOption.worktreePath, metadata.worktreePath),
      (ProwlWindowOption.repositoryRoot, metadata.repositoryRoot),
      (ProwlWindowOption.createdAt, metadata.createdAt),
    ]

    for option in options {
      _ = try await run([
        "-S", socketURL.path,
        "set-window-option",
        "-t", windowID.rawValue,
        option.name,
        option.value,
      ])
    }
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

  internal func detachClientSession(target: TmuxTerminalTarget) async throws {
    _ = try await run(
      [
        "-S", target.socketURL.path,
        "kill-session",
        "-t", target.clientSession,
      ],
      allowFailure: true
    )
  }

  private func killCreatedWindow(windowID: TmuxWindowID, socketURL: URL) async throws {
    _ = try await run(
      [
        "-S", socketURL.path,
        "kill-window",
        "-t", windowID.rawValue,
      ],
      allowFailure: true
    )
  }

  private func listSessions() async throws -> [TmuxSessionRecord] {
    guard let socketURL = defaultSocketURL else { return [] }
    let result = try await run(
      ["-S", socketURL.path, "list-sessions", "-F", TmuxRecoveryScan.sessionFormat],
      allowFailure: true
    )
    guard result.exitCode == 0 else { return [] }
    return result.stdout.split(separator: "\n").compactMap { line in
      let fields = line.split(
        separator: Character(TmuxRecoveryScan.separator),
        omittingEmptySubsequences: false
      )
      guard fields.count == 3, let windowCount = Int(fields[1]) else { return nil }
      return TmuxSessionRecord(name: String(fields[0]), windowCount: windowCount, groupName: String(fields[2]))
    }
  }

  private func listRawWindowRecords() async throws -> [TmuxRawWindowRecord] {
    guard let socketURL = defaultSocketURL else { return [] }
    let result = try await run([
      "-S", socketURL.path,
      "list-windows",
      "-t", TmuxTerminalTarget.cardContainerSession,
      "-F", TmuxRecoveryScan.windowFormat,
    ])
    return result.stdout.split(separator: "\n").compactMap(parseRawWindowRecord)
  }

  private func parseRawWindowRecord(_ line: Substring) -> TmuxRawWindowRecord? {
    let fields = line.split(
      separator: Character(TmuxRecoveryScan.separator),
      omittingEmptySubsequences: false
    )
    guard
      fields.count == TmuxRecoveryScan.windowFieldCount
        || fields.count == TmuxRecoveryScan.legacyWindowFieldCount
    else { return nil }
    let includesPaneID = fields.count == TmuxRecoveryScan.windowFieldCount
    let paneOffset = includesPaneID ? 1 : 0
    return TmuxRawWindowRecord(
      sessionName: String(fields[0]),
      windowID: String(fields[1]),
      paneID: includesPaneID ? String(fields[2]) : "",
      windowName: String(fields[2 + paneOffset]),
      activePath: String(fields[3 + paneOffset]),
      activeCommand: String(fields[4 + paneOffset]),
      activeTitle: String(fields[5 + paneOffset]),
      managed: String(fields[6 + paneOffset]),
      cardID: String(fields[7 + paneOffset]),
      worktreeID: String(fields[8 + paneOffset]),
      worktreePath: String(fields[9 + paneOffset]),
      repositoryRoot: String(fields[10 + paneOffset]),
      createdAt: String(fields[11 + paneOffset])
    )
  }

  private func structureDiagnostics(from sessions: [TmuxSessionRecord]) -> [TmuxCardStructureDiagnostic] {
    let anomalous = sessions.filter { session in
      session.name.hasPrefix(TmuxRecoveryScan.legacyWorktreeSessionPrefix)
        || (session.name.hasPrefix(TmuxRecoveryScan.clientSessionPrefix)
          && session.groupName != TmuxTerminalTarget.cardContainerSession
          && session.groupName != session.name
          && !session.groupName.isEmpty)
        || (session.name.hasPrefix(TmuxRecoveryScan.prowlSessionPrefix)
          && session.name != TmuxTerminalTarget.cardContainerSession
          && !session.name.hasPrefix(TmuxRecoveryScan.clientSessionPrefix))
    }
    guard !anomalous.isEmpty, let socketPath = defaultSocketURL?.path else { return [] }

    let sessionNames = sessions.map(\.name).sorted()
    let windowCounts = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0.windowCount) })
    logger.warning(
      "tmux recovery found unexpected sessions socket=\(socketPath) sessions=\(sessionNames) "
        + "windowCounts=\(windowCounts)"
    )
    return [
      TmuxCardStructureDiagnostic(
        message: "Unexpected tmux sessions found. Restore will show safe managed cards only.",
        socketPath: socketPath,
        sessionNames: sessionNames,
        windowCountsBySession: windowCounts
      )
    ]
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

private nonisolated enum TmuxRecoveryScan {
  static let separator = "\u{1F}"
  static let prowlSessionPrefix = "prowl-"
  static let clientSessionPrefix = TmuxTerminalTarget.clientSessionPrefix
  static let legacyWorktreeSessionPrefix = "prowl-wt-"
  static let clientBootstrapWindowName = "__prowl_client_bootstrap"
  static let clientBootstrapCommand = "/bin/sleep 1000000"
  static let legacyWindowFieldCount = 12
  static let windowFieldCount = 13
  static let sessionFormat = "#{session_name}\(separator)#{session_windows}\(separator)#{session_group}"
  static let windowFormat = [
    "#{session_name}",
    "#{window_id}",
    "#{pane_id}",
    "#{window_name}",
    "#{pane_current_path}",
    "#{pane_current_command}",
    "#{pane_title}",
    "#{\(ProwlWindowOption.managed)}",
    "#{\(ProwlWindowOption.cardID)}",
    "#{\(ProwlWindowOption.worktreeID)}",
    "#{\(ProwlWindowOption.worktreePath)}",
    "#{\(ProwlWindowOption.repositoryRoot)}",
    "#{\(ProwlWindowOption.createdAt)}",
  ].joined(separator: separator)
}

private nonisolated struct TmuxSessionRecord: Equatable {
  let name: String
  let windowCount: Int
  let groupName: String
}

private nonisolated enum ProwlWindowOption {
  static let managed = "@prowl.managed"
  static let cardID = "@prowl.card_id"
  static let worktreeID = "@prowl.worktree_id"
  static let worktreePath = "@prowl.worktree_path"
  static let repositoryRoot = "@prowl.repository_root"
  static let createdAt = "@prowl.created_at"
}
