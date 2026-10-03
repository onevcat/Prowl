// ProwlCLI/AppLauncher.swift
// Launches Prowl.app when CLI detects the app is not running, then waits
// for the CLI socket to become available.

import AppKit
import Foundation
import ProwlCLIShared

enum AppLauncher {
  private static let prowlAppBundleIdentifiers: Set<String> = [
    "com.onevcat.prowl",
    "com.onevcat.prowl.debug",
  ]

  /// Maximum time to wait for the socket after launching the app.
  private static let socketTimeoutSeconds: TimeInterval = 15
  /// Interval between socket availability checks.
  private static let pollIntervalSeconds: TimeInterval = 0.25

  /// Check whether the CLI socket is currently connectable.
  static func isSocketAvailable() -> Bool {
    socketStatus().isConnected
  }

  /// Ensure the app is running and the socket is ready.
  /// Returns `true` only when the app was not running and had to be launched.
  ///
  /// When `PROWL_CLI_SOCKET` is set (e.g. integration tests), auto-launch is
  /// disabled — the caller controls the socket endpoint.
  static func ensureAppRunning() throws -> Bool {
    // If a custom socket path is set, skip auto-launch entirely.
    if let override = ProcessInfo.processInfo.environment[ProwlSocket.environmentKey],
      !override.isEmpty
    {
      return false
    }

    let initialStatus = socketStatus()
    // Fast path: socket file exists and is connectable.
    if initialStatus.isConnected {
      return false
    }
    if let error = initialStatus.permissionBlocker {
      throw error
    }

    // Socket not available — check if the app process is running.
    if isAppProcessRunning() {
      // App is running but socket isn't ready yet. Wait without launching.
      try waitForSocket(initialStatus: initialStatus)
      return false
    }

    // App is genuinely not running. Launch and wait.
    try launchApp()
    try waitForSocket(initialStatus: initialStatus)
    return true
  }

  // MARK: - Process detection

  /// Check whether a Prowl app instance is currently running.
  private static func isAppProcessRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { application in
      isProwlAppBundleIdentifier(application.bundleIdentifier)
    }
  }

  static func isProwlAppBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return prowlAppBundleIdentifiers.contains(bundleIdentifier)
  }

  // MARK: - App launch

  private static func launchApp() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = launchArguments()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw ExitError(
        code: CLIErrorCode.launchFailed,
        message: "Failed to launch Prowl: \(error.localizedDescription)"
      )
    }
    guard process.terminationStatus == 0 else {
      throw ExitError(
        code: CLIErrorCode.launchFailed,
        message: "Failed to launch Prowl (exit code \(process.terminationStatus))."
      )
    }
  }

  private static func launchArguments() -> [String] {
    var args = ["-a", "Prowl"]
    if let openPath = ProcessInfo.processInfo.environment[ProwlSocket.cliOpenPathEnvironmentKey],
      !openPath.isEmpty
    {
      args.append(contentsOf: ["--args", ProwlSocket.cliOpenPathArgument, openPath])
    }
    return args
  }

  // MARK: - Socket readiness

  private static func waitForSocket(initialStatus: SocketConnectionProbe.Status) throws {
    let deadline = Date().addingTimeInterval(socketTimeoutSeconds)
    var lastStatus = initialStatus
    while Date() < deadline {
      let status = socketStatus()
      if status.isConnected {
        return
      }
      if let error = status.immediateLaunchBlocker {
        throw error
      }
      lastStatus = status
      Thread.sleep(forTimeInterval: pollIntervalSeconds)
    }
    let message = """
      Prowl CLI socket did not become available within \(Int(socketTimeoutSeconds))s. \
      Last connection error: \(lastStatus.diagnosticMessage).
      """
    throw ExitError(code: CLIErrorCode.launchFailed, message: message)
  }

  private static func socketStatus() -> SocketConnectionProbe.Status {
    SocketConnectionProbe.check(socketPath: ProwlSocket.defaultPath)
  }
}

extension SocketConnectionProbe.Status {
  fileprivate var permissionBlocker: ExitError? {
    if case .permissionDenied = self {
      return exitError()
    }
    return nil
  }

  fileprivate var immediateLaunchBlocker: ExitError? {
    switch self {
    case .connected, .appUnavailable:
      nil
    case .permissionDenied, .transportFailed:
      exitError()
    }
  }
}
