import AppKit
import Darwin
import Foundation
import GhosttyKit
import Observation

internal struct CleanSurfaceConfiguration: Equatable {
  internal let workingDirectory: URL
  internal let initialInput: String?
  internal let command: String?
  internal let fontSize: Float32?
  internal let context: ghostty_surface_context_e

  internal static func `default`(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    preferredFontSize: Float32?
  ) -> Self {
    Self(
      workingDirectory: homeDirectory,
      initialInput: nil,
      command: nil,
      fontSize: preferredFontSize,
      context: GHOSTTY_SURFACE_CONTEXT_WINDOW
    )
  }
}

@MainActor
internal final class CleanForegroundJobProbe {
  internal typealias Provider = @Sendable (pid_t?, pid_t?) async -> ForegroundJob?
  internal typealias ResultHandler = @MainActor (ForegroundJob?) -> Void

  private let provider: Provider
  private var task: Task<Void, Never>?
  private var requestID: UInt64 = 0

  internal init(
    provider: @escaping Provider = { processGroupID, childPID in
      AgentProcessProbe.shared.foregroundJob(
        processGroupID: processGroupID,
        childPID: childPID
      )
    }
  ) {
    self.provider = provider
  }

  isolated deinit {
    task?.cancel()
  }

  internal func request(
    processGroupID: pid_t?,
    childPID: pid_t?,
    onResult: @escaping ResultHandler
  ) {
    requestID &+= 1
    let currentRequestID = requestID
    task?.cancel()
    let provider = provider
    task = Task { @MainActor [weak self] in
      let job = await provider(processGroupID, childPID)
      guard !Task.isCancelled, let self, requestID == currentRequestID else { return }
      onResult(job)
    }
  }

  internal func cancel() {
    requestID &+= 1
    task?.cancel()
    task = nil
  }
}

@MainActor
@Observable
internal final class CleanTerminalHost {
  internal typealias SurfaceFactory = @MainActor (CleanSurfaceConfiguration) -> GhosttySurfaceView

  internal private(set) var surface: GhosttySurfaceView?

  private let preferredFontSize: Float32?
  private let inputSourceCoordinator: TerminalInputSourceCoordinator
  private let surfaceFactory: SurfaceFactory
  private let foregroundJobProbe: CleanForegroundJobProbe
  private let logger = SupaLogger("CleanTerminal")
  private var periodicProbeTask: Task<Void, Never>?
  private var delayedProbeTask: Task<Void, Never>?
  private var isHerdrForeground = false
  private var isWindowActive = false
  @ObservationIgnored private var herdrAdapter: HerdrInputContextAdapter?

  internal init(
    runtime: GhosttyRuntime,
    preferredFontSize: Float32?,
    inputSourceCoordinator: TerminalInputSourceCoordinator = TerminalInputSourceCoordinator(),
    surfaceFactory: SurfaceFactory? = nil,
    foregroundJobProbe: CleanForegroundJobProbe = CleanForegroundJobProbe()
  ) {
    self.preferredFontSize = preferredFontSize
    self.inputSourceCoordinator = inputSourceCoordinator
    self.surfaceFactory =
      surfaceFactory ?? { configuration in
        GhosttySurfaceView(
          runtime: runtime,
          workingDirectory: configuration.workingDirectory,
          initialInput: configuration.initialInput,
          command: configuration.command,
          fontSize: configuration.fontSize,
          context: configuration.context
        )
      }
    self.foregroundJobProbe = foregroundJobProbe
    herdrAdapter = HerdrInputContextAdapter { [weak self] pane in
      guard let self else { return }
      applyHerdrPaneContext(pane)
    }
  }

  isolated deinit {
    periodicProbeTask?.cancel()
    delayedProbeTask?.cancel()
    foregroundJobProbe.cancel()
    herdrAdapter?.stop()
    surface?.closeSurface()
  }

  internal func start() {
    let surface = ensureSurface()
    surface.setOcclusion(true)
    if periodicProbeTask == nil {
      periodicProbeTask = Task { @MainActor [weak self] in
        guard let self else { return }
        while !Task.isCancelled {
          reevaluateInputContext(reason: .processContextChanged)
          try? await ContinuousClock().sleep(for: .seconds(1))
        }
      }
    }
    DispatchQueue.main.async { [weak surface] in
      surface?.requestFocus()
    }
  }

  internal func suspend() {
    periodicProbeTask?.cancel()
    periodicProbeTask = nil
    delayedProbeTask?.cancel()
    delayedProbeTask = nil
    foregroundJobProbe.cancel()
    isWindowActive = false
    isHerdrForeground = false
    herdrAdapter?.stop()
    surface?.focusDidChange(false)
    surface?.setOcclusion(false)
  }

  internal func updateWindowActivity(_ activity: WindowActivityState) {
    isWindowActive = activity.isKeyWindow && activity.isVisible
    surface?.setOcclusion(activity.isVisible)
    surface?.focusDidChange(isWindowActive)
    guard isWindowActive else { return }
    reevaluateInputContext(reason: .focusChanged)
  }

  internal func appBecameActive() {
    guard isWindowActive else { return }
    reevaluateInputContext(reason: .appBecameActive)
  }

  internal func reevaluateInputContext(reason: TerminalInputSourceCoordinator.Reason) {
    guard isWindowActive, let surface else { return }
    foregroundJobProbe.request(
      processGroupID: surface.bridge.foregroundProcessGroupID(),
      childPID: surface.bridge.childPID()
    ) { [weak self, weak surface] job in
      guard let self, let surface, self.isWindowActive else { return }
      if job == nil, self.isHerdrForeground {
        return
      }
      if HerdrProcessDetector.isHerdr(job) {
        self.isHerdrForeground = true
        self.herdrAdapter?.start()
        return
      }

      self.isHerdrForeground = false
      self.herdrAdapter?.resetAfterHerdrExit()
      let context = TerminalInputContextClassifier.context(
        job: job,
        viewportText: surface.bridge.readViewportText() ?? ""
      )
      self.inputSourceCoordinator.applyFocusedContext(
        context,
        targetID: .surface(surface.id),
        reason: reason
      )
    }
  }

  private func ensureSurface() -> GhosttySurfaceView {
    if let surface {
      return surface
    }
    let configuration = CleanSurfaceConfiguration.default(preferredFontSize: preferredFontSize)
    let surface = surfaceFactory(configuration)
    self.surface = surface
    configureCallbacks(for: surface)
    return surface
  }

  private func configureCallbacks(for surface: GhosttySurfaceView) {
    surface.bridge.onSplitAction = { _ in true }
    surface.bridge.onNewTab = { true }
    surface.bridge.onCloseTab = { [weak surface] _ in
      surface?.window?.performClose(nil)
      return true
    }
    surface.bridge.onGotoTab = { _ in true }
    surface.bridge.onMoveTab = { _ in true }
    surface.bridge.onCommandPaletteToggle = { true }
    surface.bridge.onCommandFinished = { [weak self] _, _ in
      self?.reevaluateInputContext(reason: .processContextChanged)
    }
    surface.bridge.onCloseRequest = { [weak self, weak surface] processAlive in
      guard let self, let surface else { return }
      closeWindow(for: surface, discardingSurface: !processAlive)
    }
    surface.onFocusChange = { [weak self] focused in
      guard focused else { return }
      self?.reevaluateInputContext(reason: .focusChanged)
    }
    surface.onKeyInput = { [weak self] in
      self?.scheduleInputContextProbe()
    }
  }

  private func scheduleInputContextProbe() {
    delayedProbeTask?.cancel()
    delayedProbeTask = Task { @MainActor [weak self] in
      try? await ContinuousClock().sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      self?.reevaluateInputContext(reason: .processContextChanged)
    }
  }

  private func closeWindow(for surface: GhosttySurfaceView, discardingSurface: Bool) {
    let window = surface.window
    if discardingSurface, self.surface === surface {
      surface.closeSurface()
      self.surface = nil
    }
    window?.performClose(nil)
  }

  private func applyHerdrPaneContext(_ pane: HerdrPaneInfo) {
    guard isWindowActive, isHerdrForeground else { return }
    inputSourceCoordinator.applyFocusedContext(
      pane.inputContext,
      targetID: .herdrPane(pane.paneID),
      reason: .processContextChanged
    )
    logger.debug(
      "applied Herdr pane input context pane=\(pane.paneID) agent=\(pane.agent ?? "none")")
  }
}
