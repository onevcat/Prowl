import ComposableArchitecture
import Foundation

typealias CLIInstallStatus = SymlinkInstallStatus

extension CLIInstallStatus {
  /// Whether the slot holds a `prowl` a shell can run: this bundle's link or another live
  /// build's (docs-ai 063.011: distinguishing foreign installs is Settings' business). A
  /// dangling link is not usable even though something occupies the path.
  nonisolated var isUsable: Bool {
    switch self {
    case .installed, .installedDifferentSource: true
    case .notInstalled, .broken: false
    }
  }
}

struct CLIInstallError: Error, Equatable, Sendable, LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

let cliDefaultInstallPath = URL(fileURLWithPath: "/usr/local/bin/prowl")

struct CLIInstallClient: Sendable {
  var bundledCLIURL: @Sendable () -> URL?
  var installationStatus: @Sendable (_ installPath: URL) -> CLIInstallStatus
  var install: @Sendable (_ installPath: URL) async throws -> Void
  var uninstall: @Sendable (_ installPath: URL) async throws -> Void
}

extension CLIInstallClient: DependencyKey {
  static let liveValue = CLIInstallClient(
    bundledCLIURL: {
      Bundle.main.resourceURL?.appendingPathComponent("prowl-cli/prowl")
    },
    installationStatus: { installPath in
      let bundledURL = Bundle.main.resourceURL?.appendingPathComponent("prowl-cli/prowl")
      return SymlinkInstaller.status(
        linkPath: installPath.path(percentEncoded: false),
        source: bundledURL?.path(percentEncoded: false) ?? ""
      )
    },
    install: { installPath in
      guard let bundledURL = Bundle.main.resourceURL?.appendingPathComponent("prowl-cli/prowl") else {
        throw CLIInstallError(message: "Could not locate bundled CLI binary.")
      }
      let bundledPath = bundledURL.path(percentEncoded: false)
      guard FileManager.default.fileExists(atPath: bundledPath) else {
        throw CLIInstallError(message: "Bundled CLI binary not found at \(bundledPath).")
      }
      try cliSymlinkInstall(source: bundledPath, destination: installPath.path(percentEncoded: false))
    },
    uninstall: { installPath in
      try cliSymlinkUninstall(path: installPath.path(percentEncoded: false))
    }
  )

  static let testValue = CLIInstallClient(
    bundledCLIURL: { nil },
    installationStatus: { _ in .notInstalled },
    install: { _ in },
    uninstall: { _ in }
  )
}

// MARK: - Symlink operations with privilege escalation

/// Creates the CLI symlink through the shared installer. Falls back to osascript privilege
/// escalation on permission failure; conflicts and other typed failures surface as-is.
private nonisolated func cliSymlinkInstall(source: String, destination: String) throws {
  do {
    try SymlinkInstaller.install(source: source, linkPath: destination)
    return
  } catch SymlinkInstallError.conflict {
    throw CLIInstallError(
      message: "A file already exists at \(destination) and is not a symlink. "
        + "Remove it manually before installing."
    )
  } catch let error as SymlinkInstallError {
    throw CLIInstallError(message: error.localizedDescription)
  } catch let error as NSError where isPermissionError(error) {
    // Fall through to privilege escalation
  }

  let dir = (destination as NSString).deletingLastPathComponent
  let script =
    "mkdir -p '\(shellEscape(dir))' && "
    + "rm -f '\(shellEscape(destination))' && "
    + "ln -s '\(shellEscape(source))' '\(shellEscape(destination))'"
  try runPrivileged(script: script)
}

/// Removes the CLI symlink through the shared installer. Falls back to osascript privilege
/// escalation on permission failure; real files are refused before any attempt.
private nonisolated func cliSymlinkUninstall(path: String) throws {
  do {
    try SymlinkInstaller.uninstall(linkPath: path)
    return
  } catch SymlinkInstallError.notInstalled {
    throw CLIInstallError(message: "No CLI tool found at \(path).")
  } catch SymlinkInstallError.conflict {
    throw CLIInstallError(message: "File at \(path) is not a symlink. Refusing to remove for safety.")
  } catch let error as SymlinkInstallError {
    throw CLIInstallError(message: error.localizedDescription)
  } catch let error as NSError where isPermissionError(error) {
    // Fall through to privilege escalation
  }

  let script = "rm -f '\(shellEscape(path))'"
  try runPrivileged(script: script)
}

private nonisolated func isPermissionError(_ error: NSError) -> Bool {
  (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError)
    || (error.domain == NSPOSIXErrorDomain && error.code == 13)
}

/// Runs a shell command with administrator privileges via osascript.
private nonisolated func runPrivileged(script: String) throws {
  let osa = Process()
  osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  osa.arguments = ["-e", "do shell script \"\(script)\" with administrator privileges"]
  let pipe = Pipe()
  osa.standardError = pipe
  do {
    try osa.run()
  } catch {
    throw CLIInstallError(message: "Failed to launch authorization prompt: \(error.localizedDescription)")
  }
  osa.waitUntilExit()
  guard osa.terminationStatus == 0 else {
    let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if stderr.contains("User canceled") || stderr.contains("-128") {
      throw CLIInstallError(message: "Installation was canceled.")
    }
    throw CLIInstallError(message: "Installation failed: \(stderr)")
  }
}

private nonisolated func shellEscape(_ value: String) -> String {
  value.replacing("'", with: "'\\''")
}

extension DependencyValues {
  var cliInstallClient: CLIInstallClient {
    get { self[CLIInstallClient.self] }
    set { self[CLIInstallClient.self] = newValue }
  }
}
