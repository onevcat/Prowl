import ComposableArchitecture
import Foundation

typealias CLIInstallStatus = SymlinkInstallStatus

extension CLIInstallStatus {
  /// The workflow banners' button for this slot: a fresh install, a repair of a dangling link,
  /// or a reinstall over a foreign link. nil when a real file or directory occupies the path —
  /// the installer refuses to replace those, so no button is honest there.
  nonisolated var installActionTitle: String? {
    switch self {
    case .notInstalled: "Install"
    case .broken: "Repair"
    case .installedDifferentSource(_, let destination): destination == nil ? nil : "Reinstall"
    case .installed: "Reinstall"
    }
  }

  /// Why a workflow cannot start with this slot (docs-ai 063 D1 preflight), for the Settings
  /// and start-sheet banners; says what to do when no button can.
  nonisolated var workflowBlockerCopy: String {
    let delivery = "Participants deliver their results through prowl, so a run cannot start until "
    switch self {
    case .notInstalled:
      return delivery + "it is installed."
    case .broken(let path, _):
      return "The link at \(path) points at an app that is gone. " + delivery + "it is repaired."
    case .installedDifferentSource(let path, let destination):
      if destination == nil {
        return "\(path) is a file or folder that is not an executable prowl command, and Prowl never replaces "
          + "one. Remove it, then install the command from Settings › Agents › CLI & Skills."
      }
      return "The link at \(path) points at something that is not an executable command. " + delivery
        + "it is replaced."
    case .installed(let path):
      return "\(path) is not executable. " + delivery + "it is reinstalled."
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
  /// Whether a shell can run `prowl` from the slot (docs-ai 063 D1): the path — through any
  /// symlink — is an executable regular file. Another build's live link qualifies (063.011);
  /// a dangling link, a directory, or a non-executable file in the way does not, whatever
  /// `installationStatus` calls it.
  var isUsable: @Sendable (_ installPath: URL) -> Bool
  var install: @Sendable (_ installPath: URL) async throws -> Void
  var uninstall: @Sendable (_ installPath: URL) async throws -> Void

  nonisolated static func isExecutableCommand(at path: String, fileManager: FileManager = .default) -> Bool {
    var isDirectory: ObjCBool = false
    // fileExists follows symlinks, so a dangling link reports absent.
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
    return fileManager.isExecutableFile(atPath: path)
  }
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
    isUsable: { installPath in
      CLIInstallClient.isExecutableCommand(at: installPath.path(percentEncoded: false))
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
    isUsable: { _ in true },
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
