// ProwlCLI/Commands/OpenCommand.swift

import ArgumentParser
import Foundation
import ProwlCLIShared

struct OpenCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Open a path in Prowl, or bring the app to front."
  )

  @OptionGroup var options: GlobalOptions

  @Argument(help: "Path to open. Omit to bring Prowl to front.")
  var path: String?

  mutating func run() throws {
    try CLIExecution.run(command: "open", output: options.outputMode) {
      let resolvedPath: String? = try path.map { try normalizePath($0) }
      let invocation = Self.deriveInvocation(path: resolvedPath)

      if let resolvedPath {
        setenv(ProwlSocket.cliOpenPathEnvironmentKey, resolvedPath, 1)
      } else {
        unsetenv(ProwlSocket.cliOpenPathEnvironmentKey)
      }

      // If the app is not running, launch it first.
      let appLaunched = try Self.ensureAppRunning()

      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .open(OpenInput(
          path: resolvedPath,
          invocation: invocation,
          appLaunched: appLaunched
        ))
      )
      try CLIRunner.execute(envelope)
    }
  }

  /// Check if Prowl is reachable via socket; if not, launch it.
  /// Returns `true` only when the app was not running and had to be launched.
  private static func ensureAppRunning() throws -> Bool {
    try AppLauncher.ensureAppRunning()
  }

  private static func deriveInvocation(path: String?) -> String {
    guard path != nil else { return "bare" }
    let args = ProcessInfo.processInfo.arguments.dropFirst()
    let firstPositional = args.first { !$0.hasPrefix("-") }
    if firstPositional == "open" {
      return "open-subcommand"
    }
    return "implicit-open"
  }

  private func normalizePath(_ raw: String) throws -> String {
    let path: String
    if raw.hasPrefix("file://") {
      guard let fileURL = URL(string: raw), fileURL.isFileURL else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "Invalid file URL: \(raw)"
        )
      }
      path = fileURL.standardizedFileURL.path
    } else {
      let expanded = NSString(string: raw).expandingTildeInPath
      if expanded.hasPrefix("/") {
        path = URL(fileURLWithPath: expanded).standardizedFileURL.path
      } else {
        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        path = URL(fileURLWithPath: expanded, relativeTo: cwdURL).standardizedFileURL.path
      }
    }

    let fileManager = FileManager.default
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
      throw ExitError(
        code: CLIErrorCode.pathNotFound,
        message: "Path not found: \(raw)"
      )
    }
    guard isDir.boolValue else {
      throw ExitError(
        code: CLIErrorCode.pathNotDirectory,
        message: "Not a directory: \(raw)"
      )
    }
    return path
  }
}
