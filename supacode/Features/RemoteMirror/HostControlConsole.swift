import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class HostControlConsole {
  static let worktreeID = "prowl:remote-mirror-control"
  var enabled = false { didSet { saveConfiguration() } }
  var profile: AgentProfile { didSet { saveConfiguration() } }
  var preset: ConsoleAgentPreset = .codex { didSet { saveConfiguration() } }
  var command = "codex --yolo" {
    didSet {
      preset = preset.matching(command: command)
      saveConfiguration()
    }
  }
  var directory = "" { didSet { saveConfiguration() } }
  private(set) var isStarting = false
  private(set) var error: String?
  private(set) var configurationNotice: String?
  private(set) var surface: LaunchedSurface?
  let profiles: [AgentProfile]
  var makeServer: (() throws -> CLISocketServer)?
  var isSelected = false
  @ObservationIgnored private var configurationLoaded = false
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let manager: WorktreeTerminalManager
  @ObservationIgnored private var server: CLISocketServer?
  @ObservationIgnored private var launchTask: Task<Void, Never>?

  static var defaultDirectory: URL {
    SupacodePaths.appSupportDirectory.appending(
      path: "RemoteMirror/ControlConsole", directoryHint: .isDirectory)
  }

  var worktree: Worktree {
    Worktree(
      id: Self.worktreeID, name: "Host Console", detail: "Remote Mirror control session",
      workingDirectory: Self.defaultDirectory, repositoryRootURL: Self.defaultDirectory)
  }

  var isAlive: Bool {
    guard let surface else { return false }
    return manager.stateIfExists(for: Self.worktreeID)?.surfaces[surface.surfaceID]?.surface != nil
  }

  init(
    manager: WorktreeTerminalManager, profiles: [AgentProfile], defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    self.manager = manager
    let supported = profiles.filter {
      $0.isEnabled && ($0.runtime == .codex || $0.runtime == .claude)
    }
    self.profiles =
      supported
      + [AgentProfileRuntime.codex, .claude].compactMap { runtime in
        supported.contains(where: { $0.runtime == runtime })
          ? nil : AgentProfile(name: runtime == .codex ? "Codex" : "Claude", runtime: runtime)
      }
    self.profile =
      self.profiles.first(where: { AgentProfileAvailability.isRuntimeInstalled($0.runtime) })
      ?? self.profiles[0]
    self.profile.executionMode = .standard
    self.preset = self.profile.runtime == .claude ? .claude : .codex
    self.command = self.preset.command
    if let data = defaults.data(forKey: Self.configurationKey) {
      do {
        let saved = try JSONDecoder().decode(Configuration.self, from: data)
        if let selected = self.profiles.first(where: { $0.id == saved.profileID })
          ?? self.profiles.first(where: { $0.runtime == saved.runtime })
        {
          self.profile = selected
          self.profile.model = saved.model
          self.profile.executionMode = saved.bypass ? .unrestricted : .standard
          self.enabled = saved.enabled
          self.directory = saved.directory
        } else {
          self.enabled = saved.enabled
          self.directory = saved.directory
          self.configurationNotice =
            "The previous Agent Profile is unavailable. Review the launch command."
        }
        self.preset = saved.preset ?? (saved.runtime == .claude ? .claude : .codex)
        self.command = saved.command ?? Self.legacyCommand(saved)
      } catch {
        self.configurationNotice =
          "Cannot read saved control-console settings. Review the launch command."
      }
    }
    preset = preset.matching(command: command)
    configurationLoaded = true
    manager.showControlConsole = { [weak self] in self?.show() }
  }

  private static let configurationKey = "remoteMirrorControlConsole"

  private struct Configuration: Codable {
    let enabled: Bool
    let profileID: UUID
    let runtime: AgentProfileRuntime
    let model: String?
    let bypass: Bool
    let directory: String
    var preset: ConsoleAgentPreset?
    var command: String?
  }

  private func saveConfiguration() {
    guard configurationLoaded else { return }
    do {
      let value = Configuration(
        enabled: enabled, profileID: profile.id, runtime: profile.runtime, model: profile.model,
        bypass: profile.executionMode == .unrestricted, directory: directory,
        preset: preset, command: command)
      defaults.set(try JSONEncoder().encode(value), forKey: Self.configurationKey)
      configurationNotice = nil
    } catch { self.error = "Cannot save control-console settings: \(error.localizedDescription)" }
  }

  private static func legacyCommand(_ saved: Configuration) -> String {
    var words = [saved.runtime.rawValue]
    if saved.bypass {
      words.append(saved.runtime == .codex ? "--yolo" : "--dangerously-skip-permissions")
    }
    if let model = saved.model, !model.isEmpty {
      words += ["--model", AgentInvocation.shellQuote(model)]
    }
    return words.joined(separator: " ")
  }

  func selectPreset(_ selected: ConsoleAgentPreset) {
    preset = selected
    command = selected.command
    if let runtime = selected.runtime,
      let selectedProfile = profiles.first(where: { $0.runtime == runtime })
    {
      profile = selectedProfile
    }
    error = nil
  }

  func start() {
    guard enabled, !isStarting, !isAlive else { return }
    error = nil
    isStarting = true
    let selectedProfile = profile
    let selectedPreset = preset.matching(command: command)
    let selectedCommand = command
    let selectedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
    launchTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isStarting = false
        self.launchTask = nil
      }
      do {
        let cwd = try Self.prepareDirectory(selectedDirectory)
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
        manager.registerControlConsole(worktree)
        manager.controlConsoleSocketPath = socket
        let invocation = try ConsoleAgentPreset.invocation(command: selectedCommand, prompt: prompt)
        if selectedPreset == .custom {
          try launchCustom(invocation: invocation, prompt: prompt, directory: cwd)
          return
        }
        let plan = try selectedPreset.plan(
          profile: selectedProfile, invocation: invocation, prompt: prompt)
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

  private static func prepareDirectory(_ selectedDirectory: String) throws -> URL {
    let cwd =
      selectedDirectory.isEmpty
      ? defaultDirectory : URL(fileURLWithPath: selectedDirectory)
    if selectedDirectory.isEmpty {
      try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    } else {
      var isDirectory: ObjCBool = false
      guard selectedDirectory.hasPrefix("/"),
        FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw ConsoleError("Choose an existing absolute working directory.") }
    }
    // The internal CLI context must exist even when the Agent uses a custom directory.
    try FileManager.default.createDirectory(
      at: defaultDirectory, withIntermediateDirectories: true)
    return cwd
  }

  private func launchCustom(invocation: AgentInvocation, prompt: String, directory: URL) throws {
    let state = manager.state(for: worktree)
    let carrier = AgentProfileLaunchPlanner.promptCarrierName
    guard
      let tabID = state.createTab(
        focusing: false, title: "AI Control Console",
        initialInput: "env -u \(carrier) "
          + invocation.terminalInput(
            replacingFinalArgumentWithEnvironmentVariable: carrier),
        workingDirectoryOverride: directory,
        additionalEnvironment: [carrier: prompt], locksTitle: true),
      let surfaceID = state.focusedSurfaceId(in: tabID)
    else { throw ConsoleError("Cannot create the control terminal.") }
    surface = LaunchedSurface(tabID: tabID, surfaceID: surfaceID)
    manager.controlConsoleSurfaceID = surfaceID
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
    isSelected = true
    _ = NSApp.surfaceMainWindow()
  }

  func stop() {
    cancelPreparation()
    server?.stop()
    server = nil
    isSelected = false
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
