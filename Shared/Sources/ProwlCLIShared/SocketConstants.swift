// ProwlShared/SocketConstants.swift
// Shared socket path convention between CLI client and app server.

import Foundation

nonisolated public enum ProwlSocket {
  /// Environment variable for overriding socket path.
  public static let environmentKey = "PROWL_CLI_SOCKET"

  /// Environment key used only by CLI process to pass the normalized open path
  /// into app launch arguments during cold launch.
  public static let cliOpenPathEnvironmentKey = "PROWL_CLI_OPEN_PATH"

  /// App launch argument used by CLI open flow to pass the requested path
  /// during cold launch, so app startup can prefer CLI open behavior.
  public static let cliOpenPathArgument = "--prowl-cli-open-path"

  /// Default Unix domain socket path.
  ///
  /// Located under `~/Library/Application Support/com.onevcat.prowl/` because macOS periodically
  /// sweeps `/var/folders/.../T/` (NSTemporaryDirectory) and removes the socket file out from
  /// under a long-running app, leaving a bound FD with no path entry — connect() then fails with
  /// ENOENT and the CLI mistakenly reports `APP_NOT_RUNNING`.
  ///
  /// If `PROWL_CLI_SOCKET` is set and not empty, it takes precedence.
  /// Falls back to NSTemporaryDirectory if the preferred path would exceed the AF_UNIX limit.
  public static var defaultPath: String {
    if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
      return override
    }
    let preferred = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library", directoryHint: .isDirectory)
      .appending(path: "Application Support", directoryHint: .isDirectory)
      .appending(path: "com.onevcat.prowl", directoryHint: .isDirectory)
      .appending(path: "cli.sock", directoryHint: .notDirectory)
      .path(percentEncoded: false)
    // sockaddr_un.sun_path is 104 bytes on Darwin (including NUL terminator).
    if preferred.utf8.count < 104 {
      return preferred
    }
    let tmpDir = NSTemporaryDirectory()
    return (tmpDir as NSString).appendingPathComponent("prowl-cli.sock")
  }
}
