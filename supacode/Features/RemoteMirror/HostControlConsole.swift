import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class HostControlConsole {
  static let worktreeID = "prowl:remote-mirror-control"
  var enabled = false
  var profile: AgentProfile
  var directory = ""
  private(set) var isStarting = false
  private(set) var error: String?
  private(set) var surface: LaunchedSurface?
  let profiles: [AgentProfile]
  var makeServer: (() throws -> CLISocketServer)?
  @ObservationIgnored private let manager: WorktreeTerminalManager
  @ObservationIgnored private var server: CLISocketServer?
  @ObservationIgnored private var launchTask: Task<Void, Never>?
  @ObservationIgnored private var window: NSWindow?

  static var defaultDirectory: URL {
    SupacodePaths.appSupportDirectory.appending(
      path: "RemoteMirror/ControlConsole", directoryHint: .isDirectory)
  }

  var worktree: Worktree {
    Worktree(
      id: Self.worktreeID, name: "AI Control Console", detail: "Remote Mirror control session",
      workingDirectory: Self.defaultDirectory, repositoryRootURL: Self.defaultDirectory)
  }

  var isAlive: Bool {
    guard let surface else { return false }
    return manager.stateIfExists(for: Self.worktreeID)?.surfaces[surface.surfaceID]?.surface != nil
  }

  init(manager: WorktreeTerminalManager, profiles: [AgentProfile]) {
    self.manager = manager
    let supported = profiles.filter {
      $0.isEnabled && ($0.runtime == .codex || $0.runtime == .claude)
    }
    self.profiles =
      supported.isEmpty
      ? [.init(name: "Codex", runtime: .codex), .init(name: "Claude Code", runtime: .claude)]
      : supported
    self.profile =
      self.profiles.first(where: { AgentProfileAvailability.isRuntimeInstalled($0.runtime) })
      ?? self.profiles[0]
    self.profile.executionMode = .standard
  }

  func start() {
    guard enabled, !isStarting, !isAlive else { return }
    error = nil
    isStarting = true
    let selectedProfile = profile
    let selectedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
    launchTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isStarting = false
        self.launchTask = nil
      }
      do {
        let cwd =
          selectedDirectory.isEmpty
          ? Self.defaultDirectory : URL(fileURLWithPath: selectedDirectory)
        if selectedDirectory.isEmpty {
          try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        } else {
          var isDirectory: ObjCBool = false
          guard selectedDirectory.hasPrefix("/"),
            FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory),
            isDirectory.boolValue
          else { throw ConsoleError("Choose an existing absolute working directory.") }
        }
        if server == nil {
          guard let makeServer else {
            throw ConsoleError("The control CLI endpoint is unavailable.")
          }
          server = try makeServer()
        }
        guard let server, case .listening(let socket) = server.status,
          let cli = SupacodePaths.bundledCLIURL, let docs = SupacodePaths.bundledDocsURL
        else { throw ConsoleError("The control CLI endpoint is not listening.") }
        let guide = docs.appending(path: "remote-mirror-control.md")
        guard FileManager.default.fileExists(atPath: guide.path) else {
          throw ConsoleError(
            "The bundled control-console guide is missing. Rebuild Prowl resources.")
        }
        let prompt = Self.prompt(guide: guide, cli: cli, socket: socket)
        let plan = try AgentProfileLaunchPlanner.plan(
          for: selectedProfile, intent: .prompt(prompt),
          homeBaseDirectory: SupacodePaths.agentProfileHomesDirectory)
        manager.registerControlConsole(worktree)
        manager.controlConsoleSocketPath = socket
        var request = AgentProfileLaunchRequest(
          plan: plan, placement: .tab(background: true),
          workingDirectoryOverride: cwd, title: "AI Control Console")
        request.locksTitle = true
        let preparation = await manager.prepareAgentProfileLaunch(request, in: worktree)
        if Task.isCancelled, case .success(let prepared) = preparation {
          manager.discardPreparedAgentProfileLaunch(prepared)
        }
        try Task.checkCancellation()
        switch preparation {
        case .failure(let failure): throw ConsoleError("Cannot prepare Agent: \(failure)")
        case .success(let prepared):
          switch manager.launchPreparedAgentProfile(prepared, in: worktree) {
          case .failure(let failure): throw ConsoleError("Cannot launch Agent: \(failure)")
          case .success(let launched):
            surface = launched
            manager.controlConsoleSurfaceID = launched.surfaceID
          }
        }
      } catch is CancellationError {
        error = "Control-console startup was cancelled."
      } catch { self.error = error.localizedDescription }
    }
  }

  func cancelPreparation() { launchTask?.cancel() }

  func restart() {
    guard !isStarting else { return }
    if let surface { manager.stateIfExists(for: Self.worktreeID)?.closeTab(surface.tabID) }
    surface = nil
    manager.controlConsoleSurfaceID = nil
    start()
  }

  func show() {
    guard isAlive else { return }
    if window == nil {
      let content = WorktreeTerminalTabsView(
        worktree: worktree, manager: manager, shouldRunSetupScript: false,
        forceAutoFocus: true,
        createTab: { [weak self] in
          guard let self else { return }
          _ = self.manager.createTabInDirectory(self.worktree, directory: Self.defaultDirectory)
        })
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.title = "Prowl — AI Control Console"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: content)
      window.center()
      self.window = window
    }
    window?.makeKeyAndOrderFront(nil)
  }

  func stop() {
    cancelPreparation()
    server?.stop()
    server = nil
    window?.close()
    window = nil
  }

  static func prompt(guide: URL, cli: URL, socket: String) -> String {
    """
    You are the Prowl AI control console. Read the bundled guide at \(guide.path) before using tools.
    For every Prowl CLI call use this instance-specific command prefix:
    env PROWL_CLI_SOCKET=\(AgentInvocation.shellQuote(socket)) \(AgentInvocation.shellQuote(cli.path))
    Never fall back to another Prowl instance or the default socket.
    Read the bundled CLI skills referenced by the guide.
    First inspect the available Prowl commands and open panes, then tell the user you are ready for their request.
    Do not modify repositories or close existing panes merely to initialize this session.
    """
  }

  private struct ConsoleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
