import Foundation

/// Every pane asks a Codex TUI to record its session to a pane-owned file. The daemon that
/// runs Codex 0.157+ threads does not know which terminal drives a thread; this log is the
/// only per-pane record of the messages the TUI submitted (docs-ai 073).
///
/// The log holds prompt text. Codex creates it with mode 0600 and truncates it at each TUI
/// launch; Prowl removes it when the pane's surface is freed (after the undo-close window) and
/// sweeps files a crash left behind.
nonisolated enum CodexTUISessionLog {
  static let recordEnvironmentKey = "CODEX_TUI_RECORD_SESSION"
  static let pathEnvironmentKey = "CODEX_TUI_SESSION_LOG_PATH"
  static let fileExtension = "jsonl"
  /// Debug and Release share the directory, so launch only removes stale files.
  static let staleAge: TimeInterval = 7 * 24 * 60 * 60

  /// A TUI writes its session header during startup; a later header belongs to a later TUI.
  static let processStartWindow: TimeInterval = 120

  /// Whether a log whose header was written at `sessionStartedAt` came from the process that
  /// started at `processStartedAt`. Each launch truncates the log, so a stale log fails this.
  static func belongs(sessionStartedAt: Date, toProcessStartedAt processStartedAt: Date) -> Bool {
    let delay = sessionStartedAt.timeIntervalSince(processStartedAt)
    return delay >= -1 && delay <= processStartWindow
  }

  static func url(for surfaceID: UUID, in directory: URL = SupacodePaths.codexTUISessionLogDirectory) -> URL {
    directory.appending(path: "\(surfaceID.uuidString).\(fileExtension)", directoryHint: .notDirectory)
  }

  static func surfaceID(forFileName name: String) -> UUID? {
    guard name.hasSuffix(".\(fileExtension)") else { return nil }
    return UUID(uuidString: String(name.dropLast(fileExtension.count + 1)))
  }

  /// Variables a pane adds to its launch environment. A value the caller already set wins.
  static func environment(
    for surfaceID: UUID,
    directory: URL = SupacodePaths.codexTUISessionLogDirectory
  ) -> [String: String] {
    [
      recordEnvironmentKey: "1",
      pathEnvironmentKey: url(for: surfaceID, in: directory).path(percentEncoded: false),
    ]
  }

  static func removeLog(
    for surfaceID: UUID,
    directory: URL = SupacodePaths.codexTUISessionLogDirectory,
    fileManager: FileManager = .default
  ) {
    try? fileManager.removeItem(at: url(for: surfaceID, in: directory))
  }

  /// Creates the private directory and removes logs untouched for `staleAge`.
  static func prepareDirectory(
    _ directory: URL = SupacodePaths.codexTUISessionLogDirectory,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) {
    try? fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
    else { return }
    for entry in entries where surfaceID(forFileName: entry.lastPathComponent) != nil {
      let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, now.timeIntervalSince(modified) > staleAge {
        try? fileManager.removeItem(at: entry)
      }
    }
  }
}
