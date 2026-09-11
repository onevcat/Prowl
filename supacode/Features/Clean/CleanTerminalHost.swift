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
  internal let environment: [String: String]

  internal static func `default`(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    preferredFontSize: Float32?,
    nativeChromeEnvironment: [String: String] = [:]
  ) -> Self {
    Self(
      workingDirectory: homeDirectory,
      initialInput: nil,
      command: nil,
      fontSize: preferredFontSize,
      context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
      environment: ["PROWL_HERDR_NATIVE_CHROME": "1"].merging(nativeChromeEnvironment) { _, new in
        new
      }
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
      AgentProcessProbe.shared.refreshForegroundJob(
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

nonisolated internal enum HerdrProcessInfoCache {
  internal static func updated(
    _ current: [HerdrPaneTarget: HerdrPaneProcessInfo],
    with results: [(HerdrPaneTarget, HerdrPaneProcessInfo?)]
  ) -> [HerdrPaneTarget: HerdrPaneProcessInfo]? {
    var next: [HerdrPaneTarget: HerdrPaneProcessInfo]?
    for (paneTarget, processInfo) in results {
      if let processInfo {
        guard current[paneTarget] != processInfo else { continue }
        if next == nil { next = current }
        next?[paneTarget] = processInfo
      } else {
        guard current[paneTarget] != nil else { continue }
        if next == nil { next = current }
        next?.removeValue(forKey: paneTarget)
      }
    }
    return next
  }
}

nonisolated internal enum HerdrProcessPaneTracking {
  internal static func resolvedFocusedPaneID(
    selectedPaneID: String?,
    snapshotFocusedPaneID: String?
  ) -> String? {
    selectedPaneID ?? snapshotFocusedPaneID
  }

  internal static func shouldRefreshImmediately(
    from previousFocusedPaneID: String?,
    to currentFocusedPaneID: String?,
    isHerdrForeground: Bool
  ) -> Bool {
    isHerdrForeground && previousFocusedPaneID != currentFocusedPaneID
  }

  internal static func paneIDsAfterInitialScan(
    representativePaneIDs: Set<String>,
    focusedPaneIDs: Set<String>
  ) -> Set<String> {
    focusedPaneIDs.isEmpty ? representativePaneIDs : focusedPaneIDs
  }
}

@MainActor
@Observable
internal final class CleanTerminalHost {
  internal typealias SurfaceFactory = @MainActor (CleanSurfaceConfiguration) -> GhosttySurfaceView
  internal typealias HerdrProcessInfoProvider =
    @Sendable (HerdrPaneTarget) async throws -> HerdrPaneProcessInfo
  internal typealias HerdrCompatibilityFailureHandler = @MainActor (HerdrSocketError) -> Void
  internal typealias HerdrForegroundHandler = @MainActor (Bool) -> Void

  private static let periodicProbeInterval = Duration.milliseconds(200)
  private static let delayedProbeInterval = Duration.milliseconds(50)
  private static let herdrProcessInfoPollingInterval = Duration.seconds(1)

  internal private(set) var surface: GhosttySurfaceView?
  internal private(set) var processInfoByPaneTarget: [HerdrPaneTarget: HerdrPaneProcessInfo] = [:]

  private let preferredFontSize: Float32?
  private let inputSourceCoordinator: TerminalInputSourceCoordinator
  private let surfaceFactory: SurfaceFactory
  private let foregroundJobProbe: CleanForegroundJobProbe
  private let herdrProcessInfoProvider: HerdrProcessInfoProvider
  private let nativeChromeCoordinator: HerdrNativeChromeCoordinator
  private let onHerdrForegroundChanged: HerdrForegroundHandler
  private let logger = SupaLogger("CleanTerminal")
  private var periodicProbeTask: Task<Void, Never>?
  private var delayedProbeTask: Task<Void, Never>?
  private var herdrProcessInfoTask: Task<Void, Never>?
  private var herdrProcessPaneTargets: Set<HerdrPaneTarget> = []
  private var representativeHerdrProcessPaneTargets: Set<HerdrPaneTarget> = []
  private var currentFocusedHerdrProcessPaneTarget: HerdrPaneTarget?
  private var previousFocusedHerdrProcessPaneTarget: HerdrPaneTarget?
  private var hasCompletedHerdrProcessInitialScan = false
  private var isHerdrForeground = false
  private var herdrAuthorityMode = HerdrTerminalChromeFeature.State.AuthorityMode.bootstrap
  private var aggregateEndpointKey: HerdrEndpointKey?
  private var aggregateFocusedPane: HerdrClientShellPane?
  private var isWindowActive = false
  @ObservationIgnored private var herdrAdapter: HerdrInputContextAdapter?
  @ObservationIgnored private var titlebarMouseForwarder: CleanTitlebarMouseForwarder?

  internal init(
    runtime: GhosttyRuntime,
    preferredFontSize: Float32?,
    inputSourceCoordinator: TerminalInputSourceCoordinator = TerminalInputSourceCoordinator(),
    surfaceFactory: SurfaceFactory? = nil,
    foregroundJobProbe: CleanForegroundJobProbe = CleanForegroundJobProbe(),
    herdrProcessInfoProvider: @escaping HerdrProcessInfoProvider = { paneTarget in
      guard paneTarget.endpointKey == .local else {
        throw HerdrTerminalChromeFailure.unavailable
      }
      return try await HerdrSocketClient().paneProcessInfo(paneID: paneTarget.paneID)
    },
    nativeChromeCoordinator: HerdrNativeChromeCoordinator = HerdrNativeChromeCoordinator(),
    onHerdrCompatibilityFailure: @escaping HerdrCompatibilityFailureHandler = { _ in },
    onHerdrForegroundChanged: @escaping HerdrForegroundHandler = { _ in }
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
          context: configuration.context,
          environment: configuration.environment
        )
      }
    self.foregroundJobProbe = foregroundJobProbe
    self.herdrProcessInfoProvider = herdrProcessInfoProvider
    self.nativeChromeCoordinator = nativeChromeCoordinator
    self.onHerdrForegroundChanged = onHerdrForegroundChanged
    herdrAdapter = HerdrInputContextAdapter(
      onCompatibilityFailure: onHerdrCompatibilityFailure,
      onPaneContext: { [weak self] pane in
        guard let self else { return }
        applyHerdrPaneContext(pane)
      }
    )
  }

  isolated deinit {
    periodicProbeTask?.cancel()
    delayedProbeTask?.cancel()
    herdrProcessInfoTask?.cancel()
    foregroundJobProbe.cancel()
    herdrAdapter?.stop()
    nativeChromeCoordinator.stopSurface()
    titlebarMouseForwarder?.stop()
    surface?.closeSurface()
  }

  internal func start() {
    let surface = ensureSurface()
    titlebarMouseForwarder?.start()
    surface.setOcclusion(true)
    if periodicProbeTask == nil {
      periodicProbeTask = Task { @MainActor [weak self] in
        guard let self else { return }
        while !Task.isCancelled {
          reevaluateInputContext(reason: .processContextChanged)
          try? await ContinuousClock().sleep(for: Self.periodicProbeInterval)
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
    herdrProcessInfoTask?.cancel()
    herdrProcessInfoTask = nil
    herdrProcessPaneTargets = []
    representativeHerdrProcessPaneTargets = []
    currentFocusedHerdrProcessPaneTarget = nil
    previousFocusedHerdrProcessPaneTarget = nil
    hasCompletedHerdrProcessInitialScan = false
    processInfoByPaneTarget = [:]
    isWindowActive = false
    setHerdrForeground(false)
    herdrAdapter?.stop()
    titlebarMouseForwarder?.stop()
    surface?.focusDidChange(false)
    surface?.setOcclusion(false)
  }

  internal func updateWindowActivity(_ activity: WindowActivityState) {
    let wasWindowActive = isWindowActive
    isWindowActive = activity.isKeyWindow && activity.isVisible
    surface?.setOcclusion(activity.isVisible)
    surface?.focusDidChange(isWindowActive)
    guard isWindowActive else { return }
    if !wasWindowActive, isHerdrForeground {
      if herdrAuthorityMode == .aggregate {
        applyAggregateInputContext()
      } else {
        herdrAdapter?.reapplyLastPaneContext()
      }
    }
    reevaluateInputContext(reason: .focusChanged)
  }

  internal func appBecameActive() {
    guard isWindowActive else { return }
    reevaluateInputContext(reason: .appBecameActive)
  }

  internal func updateHerdrAuthority(
    mode: HerdrTerminalChromeFeature.State.AuthorityMode,
    endpointKey: HerdrEndpointKey?,
    focusedPane: HerdrClientShellPane?
  ) {
    herdrAuthorityMode = mode
    aggregateEndpointKey = endpointKey
    aggregateFocusedPane = focusedPane
    guard mode == .aggregate else {
      if isHerdrForeground { herdrAdapter?.start() }
      return
    }
    herdrAdapter?.stop()
    herdrProcessInfoTask?.cancel()
    herdrProcessInfoTask = nil
    processInfoByPaneTarget = [:]
    applyAggregateInputContext()
  }

  private func applyAggregateInputContext() {
    guard isWindowActive,
      isHerdrForeground,
      let endpointKey = aggregateEndpointKey,
      let focusedPane = aggregateFocusedPane
    else { return }
    inputSourceCoordinator.applyFocusedContext(
      focusedPane.inputContext.terminalContext,
      targetID: .herdrPane(
        HerdrPaneTarget(endpointKey: endpointKey, paneID: focusedPane.paneID)
      ),
      reason: .processContextChanged
    )
  }

  internal func updateHerdrProcessPanes(
    _ panes: [HerdrPane],
    authorityMode: HerdrTerminalChromeFeature.State.AuthorityMode = .legacy,
    endpointKey: HerdrEndpointKey = .local,
    focusedPaneID: String? = nil
  ) {
    guard authorityMode != .aggregate, herdrAuthorityMode != .aggregate else {
      herdrProcessInfoTask?.cancel()
      herdrProcessInfoTask = nil
      processInfoByPaneTarget = [:]
      return
    }
    let panesByTabID = Dictionary(grouping: panes, by: \.tabID)
    let representativePaneTargets = Set(
      panesByTabID.values.compactMap { tabPanes in
        (tabPanes.first { $0.focused } ?? tabPanes.first).map {
          HerdrPaneTarget(endpointKey: endpointKey, paneID: $0.id)
        }
      }
    )
    if panes.isEmpty {
      representativeHerdrProcessPaneTargets = []
      hasCompletedHerdrProcessInitialScan = false
      currentFocusedHerdrProcessPaneTarget = nil
      previousFocusedHerdrProcessPaneTarget = nil
    }
    if representativePaneTargets != representativeHerdrProcessPaneTargets {
      representativeHerdrProcessPaneTargets = representativePaneTargets
      processInfoByPaneTarget = processInfoByPaneTarget.filter { paneTarget, _ in
        representativePaneTargets.contains(paneTarget)
      }
    }
    let previousFocusedTarget = currentFocusedHerdrProcessPaneTarget
    let resolvedFocusedPaneID = focusedPaneID ?? panes.first(where: \.focused)?.id
    let resolvedFocusedTarget = resolvedFocusedPaneID.map {
      HerdrPaneTarget(endpointKey: endpointKey, paneID: $0)
    }
    if let resolvedFocusedTarget, resolvedFocusedTarget != currentFocusedHerdrProcessPaneTarget {
      previousFocusedHerdrProcessPaneTarget = currentFocusedHerdrProcessPaneTarget
      currentFocusedHerdrProcessPaneTarget = resolvedFocusedTarget
    }
    let trackedPaneTargets = Set(
      [previousFocusedHerdrProcessPaneTarget, currentFocusedHerdrProcessPaneTarget].compactMap {
        $0
      }
    )
    let desiredPaneTargets =
      hasCompletedHerdrProcessInitialScan ? trackedPaneTargets : representativePaneTargets
    guard desiredPaneTargets != herdrProcessPaneTargets else {
      if HerdrProcessPaneTracking.shouldRefreshImmediately(
        from: previousFocusedTarget?.paneID,
        to: resolvedFocusedTarget?.paneID,
        isHerdrForeground: isHerdrForeground
      ) {
        startHerdrProcessInfoPolling()
      }
      return
    }
    herdrProcessPaneTargets = desiredPaneTargets
    guard isHerdrForeground else {
      herdrProcessInfoTask?.cancel()
      herdrProcessInfoTask = nil
      processInfoByPaneTarget = [:]
      return
    }
    startHerdrProcessInfoPolling()
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
        self.setHerdrForeground(true)
        return
      }

      self.setHerdrForeground(false)
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
    let nativeChromeEnvironment: [String: String]
    do {
      nativeChromeEnvironment = try nativeChromeCoordinator.prepareSurface().environment
    } catch {
      nativeChromeEnvironment = [:]
      logger.warning("could not prepare Herdr native chrome rendezvous: \(error)")
    }
    let configuration = CleanSurfaceConfiguration.default(
      preferredFontSize: preferredFontSize,
      nativeChromeEnvironment: nativeChromeEnvironment
    )
    let surface = surfaceFactory(configuration)
    self.surface = surface
    configureCallbacks(for: surface)
    configureTitlebarMouseForwarding(for: surface)
    return surface
  }

  private func configureTitlebarMouseForwarding(for surface: GhosttySurfaceView) {
    titlebarMouseForwarder = CleanTitlebarMouseForwarder(surfaceView: surface) {
      [weak surface] event in
      guard let surface else { return }
      switch event.type {
      case .leftMouseDown:
        NSApp.activate(ignoringOtherApps: true)
        surface.window?.makeKey()
        surface.requestFocus()
        surface.sendMousePosition(event)
        surface.mouseDown(with: event)
      case .leftMouseDragged:
        surface.mouseDragged(with: event)
      case .leftMouseUp:
        surface.sendMousePosition(event)
        surface.mouseUp(with: event)
      case .mouseMoved:
        surface.mouseMoved(with: event)
      case .scrollWheel:
        surface.scrollWheel(with: event)
      default:
        break
      }
    }
  }

  private func configureCallbacks(for surface: GhosttySurfaceView) {
    surface.bridge.onSplitAction = { _ in true }
    surface.bridge.onNewTab = { [weak self] in
      self?.herdrAdapter?.refreshNow()
      return true
    }
    surface.bridge.onCloseTab = { [weak surface] _ in
      surface?.window?.performClose(nil)
      return true
    }
    surface.bridge.onGotoTab = { [weak self] _ in
      self?.herdrAdapter?.refreshNow()
      return true
    }
    surface.bridge.onMoveTab = { [weak self] _ in
      self?.herdrAdapter?.refreshNow()
      return true
    }
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
      try? await ContinuousClock().sleep(for: Self.delayedProbeInterval)
      guard !Task.isCancelled else { return }
      if self?.isHerdrForeground == true {
        self?.herdrAdapter?.refreshNow()
      }
      self?.reevaluateInputContext(reason: .processContextChanged)
    }
  }

  private func closeWindow(for surface: GhosttySurfaceView, discardingSurface: Bool) {
    let window = surface.window
    if discardingSurface, self.surface === surface {
      surface.closeSurface()
      self.surface = nil
      nativeChromeCoordinator.stopSurface()
    }
    window?.performClose(nil)
  }

  private func applyHerdrPaneContext(_ pane: HerdrPaneInfo) {
    guard isWindowActive, isHerdrForeground else { return }
    inputSourceCoordinator.applyFocusedContext(
      pane.inputContext,
      targetID: .herdrPane(HerdrPaneTarget(endpointKey: .local, paneID: pane.paneID)),
      reason: .processContextChanged
    )
    logger.debug(
      "applied Herdr pane input context pane=\(pane.paneID) agent=\(pane.agent ?? "none")")
  }

  private func setHerdrForeground(_ isForeground: Bool) {
    guard isHerdrForeground != isForeground else { return }
    isHerdrForeground = isForeground
    if isForeground {
      if herdrAuthorityMode != .aggregate {
        herdrAdapter?.start()
      }
      if !herdrProcessPaneTargets.isEmpty, herdrAuthorityMode != .aggregate {
        startHerdrProcessInfoPolling()
      }
    } else {
      herdrProcessInfoTask?.cancel()
      herdrProcessInfoTask = nil
      processInfoByPaneTarget = [:]
      herdrAdapter?.resetAfterHerdrExit()
    }
    onHerdrForegroundChanged(isForeground)
  }

  private func startHerdrProcessInfoPolling() {
    herdrProcessInfoTask?.cancel()
    let provider = herdrProcessInfoProvider
    herdrProcessInfoTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let paneTargets = self.herdrProcessPaneTargets
        let results = await withTaskGroup(of: (HerdrPaneTarget, HerdrPaneProcessInfo?).self) {
          group in
          for paneTarget in paneTargets {
            group.addTask {
              do {
                return (paneTarget, try await provider(paneTarget))
              } catch {
                return (paneTarget, nil)
              }
            }
          }
          var results: [(HerdrPaneTarget, HerdrPaneProcessInfo?)] = []
          for await result in group {
            results.append(result)
          }
          return results
        }
        guard
          !Task.isCancelled,
          self.isHerdrForeground,
          self.herdrProcessPaneTargets == paneTargets
        else { return }
        if let updatedProcessInfo = HerdrProcessInfoCache.updated(
          self.processInfoByPaneTarget,
          with: results
        ) {
          self.processInfoByPaneTarget = updatedProcessInfo
        }
        if !self.hasCompletedHerdrProcessInitialScan {
          self.hasCompletedHerdrProcessInitialScan = true
          let focusedPaneTargets = Set(
            [self.previousFocusedHerdrProcessPaneTarget, self.currentFocusedHerdrProcessPaneTarget]
              .compactMap { $0 }
          )
          self.herdrProcessPaneTargets =
            focusedPaneTargets.isEmpty
            ? self.representativeHerdrProcessPaneTargets
            : focusedPaneTargets
        }
        try? await ContinuousClock().sleep(for: Self.herdrProcessInfoPollingInterval)
      }
    }
  }
}
