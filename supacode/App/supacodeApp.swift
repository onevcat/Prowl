//
//  supacodeApp.swift
//  supacode
//
//  Created by khoi on 20/1/26.
//

import AppKit
import ComposableArchitecture
import Foundation
import GhosttyKit
import PostHog
import ProwlCLIShared
import Sentry
import Sharing
import SwiftUI

@MainActor
final class SupacodeAppStoreBox {
  weak var store: StoreOf<AppFeature>?
}

private enum GhosttyCLI {
  static func argv(resolvedKeybindings: ResolvedKeybindingMap) -> [UnsafeMutablePointer<CChar>?] {
    var args: [UnsafeMutablePointer<CChar>?] = []
    let executable = CommandLine.arguments.first ?? "supacode"
    args.append(strdup(executable))
    for keybindArgument in AppShortcuts.ghosttyCLIKeybindArguments(from: resolvedKeybindings) {
      args.append(strdup(keybindArgument))
    }
    args.append(nil)
    return args
  }
}

@MainActor
final class SupacodeAppDelegate: NSObject, NSApplicationDelegate {
  var appStore: StoreOf<AppFeature>? {
    didSet {
      guard let appStore else { return }
      setSystemNotificationTapHandler { [weak appStore] worktreeID, surfaceID in
        appStore?.send(.systemNotificationTapped(worktreeID: worktreeID, surfaceID: surfaceID))
      }
    }
  }
  var terminalManager: WorktreeTerminalManager?
  var cliSocketServer: CLISocketServer?
  var remoteMirror: RemoteMirrorStore?
  var agentIslandWindowController: AgentIslandWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    WindowLifecycleDiagnostics.startMainThreadHeartbeat()
    WindowLifecycleDiagnostics.logWithWindows("applicationDidFinishLaunching")
    WindowLifecycleDiagnostics.noteWindowlessIfNoMainWindow("launch")
    WindowLifecycleDiagnostics.applyLaunchStallIfConfigured()
    // Disable press-and-hold accent menu so that key repeat works in the terminal.
    UserDefaults.standard.register(defaults: [
      "ApplePressAndHoldEnabled": false
    ])
    AgentProfileSeeder.seedIfNeeded()
    Task { await AgentRuntimeAvailabilityProbe.refresh() }
    agentIslandWindowController?.activate()
    appStore?.send(.appLaunched)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    let app = NSApplication.shared
    let hasVisibleMainWindow = MainWindowSurface.hasVisibleMainWindow(in: app.windows)
    WindowLifecycleDiagnostics.logWithWindows(
      "applicationDidBecomeActive hasVisibleMainWindow=\(hasVisibleMainWindow)"
    )
    guard !hasVisibleMainWindow else { return }
    WindowLifecycleDiagnostics.log("applicationDidBecomeActive -> surfaceMainWindow()")
    app.surfaceMainWindow()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    WindowLifecycleDiagnostics.logWithWindows("applicationShouldHandleReopen hasVisibleWindows=\(flag)")
    if flag, MainWindowSurface.hasVisibleMainWindow(in: sender.windows) {
      WindowLifecycleDiagnostics.noteMainWindowAppeared()
      return true
    }
    let surfaced = sender.surfaceMainWindow()
    WindowLifecycleDiagnostics.log("applicationShouldHandleReopen surfaced=\(surfaced) -> handled=\(!surfaced)")
    return !surfaced
  }

  func applicationWillTerminate(_ notification: Notification) {
    WindowLifecycleDiagnostics.logWithWindows("applicationWillTerminate")
    defer {
      agentIslandWindowController?.stop()
      cliSocketServer?.stop()
      remoteMirror?.stop()
    }
    guard appStore?.state.settings.restoreTerminalLayoutOnLaunch == true else { return }
    guard appStore?.state.suppressLayoutSaveUntilRelaunch != true else { return }
    terminalManager?.persistLayoutSnapshotSync()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

}

@main
@MainActor
struct SupacodeApp: App {
  @NSApplicationDelegateAdaptor(SupacodeAppDelegate.self) private var appDelegate
  @State private var ghostty: GhosttyRuntime
  @State private var ghosttyShortcuts: GhosttyShortcutManager
  @State private var terminalManager: WorktreeTerminalManager
  @State private var remoteMirror: RemoteMirrorStore
  @State private var worktreeInfoWatcher: WorktreeInfoWatcherManager
  @State private var pullRequestRefreshCoordinator: PullRequestRefreshCoordinator
  @State private var commandKeyObserver: CommandKeyObserver
  @State private var cliSocketServer: CLISocketServer
  @State private var store: StoreOf<AppFeature>
  @State private var memoryWatchdog: MemoryWatchdog
  @State private var askAgentHelp = AskAgentHelpPresenter()

  private static func cliLaunchOpenPath() -> String? {
    let args = ProcessInfo.processInfo.arguments
    guard let flagIndex = args.firstIndex(of: ProwlSocket.cliOpenPathArgument),
      args.indices.contains(flagIndex + 1)
    else {
      return nil
    }
    let path = args[flagIndex + 1]
    return path.isEmpty ? nil : path
  }

  /// Reads a secret from Info.plist, returning nil when the value is empty or
  /// still contains an unsubstituted `$(VAR)` placeholder (the Makefile did not
  /// inject a value for that key).
  private static func infoPlistSecret(_ dictionary: [String: Any], key: String) -> String? {
    guard let value = dictionary[key] as? String else { return nil }
    guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
    return value
  }

  private static func bootstrapTelemetry(initialSettings: GlobalSettings) {
    #if !DEBUG
      let infoDictionary = Bundle.main.infoDictionary ?? [:]
      let releaseName = (infoDictionary["CFBundleShortVersionString"] as? String).map { "prowl@\($0)" }
      let environment = "production"

      if initialSettings.crashReportsEnabled, let dsn = infoPlistSecret(infoDictionary, key: "ProwlSentryDSN") {
        SentrySDK.start { options in
          options.dsn = dsn
          options.environment = environment
          if let releaseName { options.releaseName = releaseName }
          options.tracesSampleRate = 0.05
          options.enableAppHangTracking = false
          // Don't report failed HTTP requests. The SDK swizzles URLSession to
          // turn any 5xx response into an HTTPClientError, but every request we
          // make goes to servers we don't own (e.g. Sparkle fetching the
          // appcast from GitHub), so their 502s are noise, not our bugs.
          options.enableCaptureFailedRequests = false
        }
        // Match the Sentry user id to the PostHog distinct id so an event in
        // one system can be traced to the same install in the other.
        let sentryUser = Sentry.User(userId: InstallIdentifier.current)
        SentrySDK.setUser(sentryUser)
      }
      if initialSettings.analyticsEnabled,
        let apiKey = infoPlistSecret(infoDictionary, key: "ProwlPostHogAPIKey"),
        let host = infoPlistSecret(infoDictionary, key: "ProwlPostHogHost")
      {
        let config = PostHogConfig(apiKey: apiKey, host: host)
        config.enableSwizzling = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.register(AnalyticsContext.superProperties)
        PostHogSDK.shared.identify(InstallIdentifier.current)
      }
    #endif
  }

  private static func initializeGhostty(resolvedKeybindings: ResolvedKeybindingMap) {
    let ghosttyArgv = GhosttyCLI.argv(resolvedKeybindings: resolvedKeybindings)
    ghosttyArgv.withUnsafeBufferPointer { buffer in
      let argc = UInt(max(0, buffer.count - 1))
      let argv = UnsafeMutablePointer(mutating: buffer.baseAddress)
      if ghostty_init(argc, argv) != GHOSTTY_SUCCESS {
        preconditionFailure("ghostty_init failed")
      }
    }
  }

  @MainActor init() {
    MirrorRelay.runIfRequested()
    NSWindow.allowsAutomaticWindowTabbing = false
    UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")
    @Shared(.settingsFile) var settingsFile
    let initialSettings = settingsFile.global
    let initialResolvedKeybindings = KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: initialSettings.keybindingUserOverrides
    )
    Self.bootstrapTelemetry(initialSettings: initialSettings)
    if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty") {
      setenv("GHOSTTY_RESOURCES_DIR", resourceURL.path, 1)
    }
    Self.initializeGhostty(resolvedKeybindings: initialResolvedKeybindings)
    let runtime = GhosttyRuntime(initialColorScheme: initialSettings.appearanceMode.colorScheme)
    _ghostty = State(initialValue: runtime)
    let shortcuts = GhosttyShortcutManager(runtime: runtime)
    _ghosttyShortcuts = State(initialValue: shortcuts)
    let terminalManager = WorktreeTerminalManager(
      runtime: runtime,
      preferredFontSize: initialSettings.terminalFontSize
    )
    terminalManager.startAgentHookRuntimeMaintenance()
    _terminalManager = State(initialValue: terminalManager)
    _remoteMirror = State(initialValue: RemoteMirrorStore(manager: terminalManager, runtime: runtime))
    let worktreeInfoWatcher = WorktreeInfoWatcherManager()
    _worktreeInfoWatcher = State(initialValue: worktreeInfoWatcher)
    let storeBox = SupacodeAppStoreBox()
    let handoffRequestRegistry = HandoffRequestRegistry()
    let workflowRuntime = Self.makeWorkflowRuntime(terminalManager: terminalManager, storeBox: storeBox)

    let coordinator = Self.makePullRequestRefreshCoordinator(storeBox: storeBox)
    _pullRequestRefreshCoordinator = State(initialValue: coordinator)
    let keyObserver = CommandKeyObserver()
    _commandKeyObserver = State(initialValue: keyObserver)
    var initialAppState = AppFeature.State(settings: SettingsFeature.State(settings: initialSettings))
    if let cliOpenPath = Self.cliLaunchOpenPath() {
      initialAppState.launchRestoreMode = .cliOpenPath(cliOpenPath)
    }
    let appStore = Store(
      initialState: initialAppState
    ) {
      AppFeature()
        .logActions()
    } withDependencies: { values in
      values.terminalClient = Self.makeTerminalClient(terminalManager: terminalManager)
      values.worktreeInfoWatcher = WorktreeInfoWatcherClient(
        send: { command in
          worktreeInfoWatcher.handleCommand(command)
        },
        events: {
          worktreeInfoWatcher.eventStream()
        }
      )
      values[BranchNameSuggestionClient.self] = Self.makeBranchNameSuggestionClient(
        terminalManager: terminalManager
      )
      values.pullRequestRefreshCoordinator = Self.makePullRequestRefreshCoordinatorClient(
        coordinator: coordinator
      )
      values.handoffRequestClient = HandoffRequestClient(
        register: { requestID in
          handoffRequestRegistry.register(requestID)
        },
        supersede: { requestID in
          handoffRequestRegistry.supersede(requestID)
        }
      )
      workflowRuntime.install(into: &values)
      values.outgoingChangesClient = Self.makeOutgoingChangesClient(storeBox: storeBox)

    }

    _store = State(initialValue: appStore)
    storeBox.store = appStore

    let cliServer = Self.makeCLISocketServer(
      appStore: appStore,
      terminalManager: terminalManager,
      handoffRequestRegistry: handoffRequestRegistry,
      workflowCoordinatorBox: workflowRuntime.coordinatorBox,
      workflowReservations: workflowRuntime.reservations
    )

    _cliSocketServer = State(initialValue: cliServer)

    let watchdog = Self.makeMemoryWatchdog(appStore: appStore, terminalManager: terminalManager)
    #if !DEBUG
      watchdog.start()
    #endif
    _memoryWatchdog = State(initialValue: watchdog)

    runtime.onQuit = { [weak appStore] in
      appStore?.send(.requestQuit)
    }
    appDelegate.appStore = appStore
    appDelegate.terminalManager = terminalManager
    appDelegate.remoteMirror = remoteMirror
    appDelegate.cliSocketServer = cliServer
    appDelegate.agentIslandWindowController = .init(store: appStore, terminalManager: terminalManager)
    #if DEBUG
      DebugWindowManager.shared.configure(store: appStore)
    #endif
  }

  /// Reads live store state so outgoing-changes resolvers pick up pull
  /// requests created or retargeted after the diff window was opened.
  @MainActor
  private static func makeOutgoingChangesClient(
    storeBox: SupacodeAppStoreBox
  ) -> OutgoingChangesClient {
    .live(
      pullRequestInfo: { targetID in
        storeBox.store?.withState { $0.repositories.pullRequest(for: targetID) } ?? nil
      }
    )
  }

  @MainActor
  private static func makePullRequestRefreshCoordinator(
    storeBox: SupacodeAppStoreBox
  ) -> PullRequestRefreshCoordinator {
    PullRequestRefreshCoordinator(
      githubCLI: .liveValue,
      clock: ContinuousClock()
    ) { outcome in
      storeBox.store?.send(
        .repositories(.githubIntegration(.pullRequestRefreshBatchOutcome(outcome)))
      )
    }
  }

  private static func makePullRequestRefreshCoordinatorClient(
    coordinator: PullRequestRefreshCoordinator
  ) -> PullRequestRefreshCoordinatorClient {
    PullRequestRefreshCoordinatorClient(
      enqueue: { request in
        Task { @MainActor in
          coordinator.enqueue(request)
        }
      },
      cancelHost: { host in
        Task { @MainActor in
          coordinator.cancelHost(host)
        }
      },
      reset: {
        Task { @MainActor in
          coordinator.reset()
        }
      }
    )
  }

  private static func makeMemoryWatchdog(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> MemoryWatchdog {
    MemoryWatchdog(
      analyticsCapture: AnalyticsClient.liveValue.capture,
      contextProvider: { [appStore, terminalManager] in
        let repositoriesState = appStore.state.repositories
        let repositories = repositoriesState.repositories
        let repositoryCount = repositories.count
        let openedWorktreeCount = repositories.reduce(0) { $0 + $1.worktrees.count }
        let activeStates = terminalManager.activeWorktreeStates
        let terminalTabCount = activeStates.reduce(0) { $0 + $1.tabManager.tabs.count }
        return MemoryWatchdog.Context(
          repositoryCount: repositoryCount,
          openedWorktreeCount: openedWorktreeCount,
          terminalTabCount: terminalTabCount
        )
      }
    )
  }

  private static func makeTerminalClient(terminalManager: WorktreeTerminalManager) -> TerminalClient {
    TerminalClient(
      send: { command in
        terminalManager.handleCommand(command)
      },
      createTabInDirectory: { worktree, directory in
        terminalManager.createTabInDirectory(worktree, directory: directory)
      },
      launchAgentProfile: { worktree, request in
        switch await terminalManager.prepareAgentProfileLaunch(request, in: worktree) {
        case .success(let preparation):
          terminalManager.launchPreparedAgentProfile(preparation, in: worktree)
        case .failure(let error):
          .failure(error)
        }
      },
      events: {
        terminalManager.eventStream()
      },
      observeAgentState: { surfaceID in
        terminalManager.observeAgentState(surfaceID: surfaceID)
      },
      canvasFocusedWorktreeID: {
        terminalManager.canvasFocusedWorktreeID
      },
      selectedSurfaceID: { worktreeID in
        guard let state = terminalManager.stateIfExists(for: worktreeID),
          let tabID = state.tabManager.selectedTabId
        else { return nil }
        return state.activeSurfaceID(for: tabID)
      },
      handoffSourceContext: { worktreeID in
        guard let state = terminalManager.stateIfExists(for: worktreeID),
          let tabID = state.tabManager.selectedTabId,
          let surfaceID = state.activeSurfaceID(for: tabID)
        else { return nil }
        return makeHandoffSourceContext(
          worktreeID: worktreeID,
          surfaceID: surfaceID,
          terminalManager: terminalManager
        )
      },
      handoffSourceContextForSurface: { worktreeID, surfaceID in
        makeHandoffSourceContext(
          worktreeID: worktreeID,
          surfaceID: surfaceID,
          terminalManager: terminalManager
        )
      },
      handoffSessionContextForSurface: { worktreeID, surfaceID in
        return makeHandoffSessionContext(
          worktreeID: worktreeID,
          paneID: surfaceID,
          paneTitle: nil,
          terminalManager: terminalManager
        )
      },
      latestUnreadNotification: {
        terminalManager.latestUnreadNotificationLocation()
      },
      focusSurface: { worktreeID, surfaceID in
        terminalManager.focusSurface(worktreeID: worktreeID, surfaceID: surfaceID)
      },
      sendTextToSurface: { worktreeID, surfaceID, text in
        guard let state = terminalManager.stateIfExists(for: worktreeID) else { return false }
        guard state.insertCommittedText(text, in: surfaceID) else { return false }
        return state.submitLine(in: surfaceID)
      },
      markNotificationRead: { worktreeID, notificationID in
        terminalManager.markNotificationRead(worktreeID: worktreeID, notificationID: notificationID)
      },
      markNotificationsReadForSurface: { worktreeID, surfaceID in
        terminalManager.markNotificationsRead(worktreeID: worktreeID, surfaceID: surfaceID)
      }
    )
  }

  @MainActor
  private static func makeBranchNameSuggestionClient(
    terminalManager: WorktreeTerminalManager
  ) -> BranchNameSuggestionClient {
    var client = BranchNameSuggestionClient.liveValue
    client.gatherContext = { repositoryName, repositoryRootURL, existingBranchNames in
      let allStates = terminalManager.activeWorktreeStates
      let sameRepoStates = allStates.filter { $0.repositoryRootURL == repositoryRootURL }

      let selectedID = terminalManager.selectedWorktreeID
      let sorted = sameRepoStates.sorted { lhs, rhs in
        if lhs.worktreeID == selectedID { return true }
        if rhs.worktreeID == selectedID { return false }
        let lhsTime = lhs.lastDefocusedAt ?? .distantPast
        let rhsTime = rhs.lastDefocusedAt ?? .distantPast
        return lhsTime > rhsTime
      }

      let hints: [BranchNameSuggestionContext.TerminalHint] = sorted.prefix(3).compactMap {
        (state) -> BranchNameSuggestionContext.TerminalHint? in
        guard let selectedTabID = state.tabManager.selectedTabId,
          let focusedSurfaceID = state.focusedSurfaceIdByTab[selectedTabID]
        else { return nil }

        let fallbackTitle =
          state.tabManager.tabs
          .first(where: { $0.id == selectedTabID })?.displayTitle ?? ""
        let paneTitle = state.paneTitle(
          surfaceID: focusedSurfaceID,
          fallbackTabTitle: fallbackTitle
        )

        let activeContent: String?
        if let surfaceView = state.surfaceView(for: focusedSurfaceID) {
          activeContent = surfaceView.readActiveContentsForCLI()
            .map { String($0.prefix(300)) }
        } else {
          activeContent = nil
        }

        return BranchNameSuggestionContext.TerminalHint(
          worktreeBranch: state.worktreeName,
          title: paneTitle,
          activeContent: activeContent
        )
      }

      return BranchNameSuggestionContext(
        repositoryName: repositoryName,
        existingBranchNames: Array(existingBranchNames.prefix(10)),
        terminalContexts: hints,
        llmAvailable: FoundationModelLLMService().isAvailable
      )
    }
    return client
  }

  private static func makeHandoffSourceContext(
    worktreeID: Worktree.ID,
    surfaceID: UUID,
    terminalManager: WorktreeTerminalManager
  ) -> HandoffSourceContext? {
    guard let state = terminalManager.stateIfExists(for: worktreeID) else { return nil }
    let agentState = state.surfaceAgentStates[surfaceID]
    return HandoffSourceContext(
      sessionContext: makeHandoffSessionContext(
        worktreeID: worktreeID,
        paneID: surfaceID,
        paneTitle: nil,
        terminalManager: terminalManager
      ),
      observation: agentState?.launchObservation
    )
  }

  private static func makeHandoffSessionContext(
    worktreeID: Worktree.ID,
    paneID: UUID,
    paneTitle: String?,
    terminalManager: WorktreeTerminalManager
  ) -> HandoffStore.SessionContext? {
    guard let state = terminalManager.stateIfExists(for: worktreeID),
      let surface = state.surfaceView(for: paneID)
    else {
      return nil
    }

    let agentState = state.surfaceAgentStates[paneID]
    let detectedAgent = agentState?.detectedAgent?.rawValue
    let nativeSession = agentState?.session
    let title = paneTitle ?? state.paneTitle(surfaceID: paneID, fallbackTabTitle: "")
    let screenText = surface.readScreenContentsForCLI() ?? surface.readViewportContentsForCLI()
    return HandoffStore.SessionContext(
      agent: detectedAgent,
      sessionID: nativeSession?.id,
      paneID: paneID.uuidString,
      paneTitle: title.isEmpty ? nil : title,
      source: nativeSession?.source.rawValue ?? (screenText == nil ? "terminal-unavailable" : "terminal-scrollback"),
      confidence: nativeSession?.confidence.rawValue ?? "fallback",
      transcriptPath: nativeSession?.transcriptPath?.path(percentEncoded: false),
      excerptText: screenText
    )
  }

  static func makeTargetResolver(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> TargetResolver {
    TargetResolver {
      TargetResolutionSnapshotBuilder.makeSnapshot(
        repositoriesState: appStore.state.repositories,
        terminalManager: terminalManager
      )
    }
  }

  private static func makeReadCapture(
    request: ReadCaptureRequest,
    terminalManager: WorktreeTerminalManager
  ) -> ReadCaptureInput? {
    let target = request.target
    guard let state = terminalManager.stateIfExists(for: target.worktreeID),
      let surface = state.surfaceView(for: target.paneID)
    else {
      return nil
    }

    switch request.source {
    case .viewport:
      guard let viewportText = surface.readViewportContentsForCLI() else { return nil }
      return ReadCaptureInput(
        viewportText: viewportText,
        screenText: surface.readScreenContentsForCLI()
      )
    case .detection:
      guard let detectionText = surface.readActiveContentsForCLI() else { return nil }
      return ReadCaptureInput(detectionText: detectionText)
    }
  }

  private static func makeAgentReadRuntimeSnapshot(
    pane: String,
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) async -> Result<AgentReadRuntimeSnapshot, AgentReadSnapshotError> {
    let resolver = makeTargetResolver(appStore: appStore, terminalManager: terminalManager)
    let resolved: ResolvedTarget
    switch resolver.resolve(.pane(pane)) {
    case .success(let target):
      resolved = target
    case .failure(let error):
      let message =
        switch error {
        case .notFound(let message), .notUnique(let message): message
        }
      return .failure(.targetNotFound(message))
    }

    guard let state = terminalManager.stateIfExists(for: resolved.worktreeID),
      let surface = state.surfaceView(for: resolved.paneID),
      let tabID = state.tabId(containing: resolved.paneID)
    else {
      return .failure(.targetNotFound("Pane '\(pane)' is no longer available."))
    }

    _ = await state.detectAgentState(for: surface, tabId: tabID)
    guard let agentState = state.surfaceAgentStates[resolved.paneID],
      let detectedAgent = agentState.detectedAgent
    else {
      return .failure(.agentNotFound("Pane '\(pane)' does not host an active agent."))
    }
    guard detectedAgent == .codex || detectedAgent == .claude else {
      return .failure(.unsupportedAgent("Agent '\(detectedAgent.rawValue)' is not supported by agents read."))
    }
    guard let activeText = surface.readActiveContentsForCLI() else {
      return .failure(.activeScreenUnreadable)
    }

    let detection = detectedAgent.detectScreen(in: activeText)
    let detectorScreen = detectedAgent.detectionSnapshot(from: activeText)
    let blockerText: String? =
      switch detectedAgent {
      case .codex: CodexScreenProfile.blockerText(in: detectorScreen)
      case .claude: ClaudeScreenProfile.blockerText(in: detectorScreen)
      default: nil
      }
    if detection.state == .blocked, blockerText == nil {
      return .failure(.blockerUnreadable)
    }

    let job = await AgentProcessProbe.shared.foregroundJob(
      processGroupID: surface.bridge.foregroundProcessGroupID(),
      childPID: surface.bridge.childPID()
    )
    guard let identified = job.flatMap(identifyAgentInJob), identified.agent == detectedAgent else {
      return .failure(.agentNotFound("Pane '\(pane)' no longer hosts the selected agent."))
    }

    let freshResolution = await AgentSessionResolver.shared.resolveFresh(
      identified: identified,
      workingDirectory: state.activeAgentWorkingDirectory(surfaceID: resolved.paneID),
      activeText: activeText,
      configRoot: state.launchProfilesBySurface[resolved.paneID]?.configRoot(forDetected: detectedAgent)
    )
    let transcriptSession = freshResolution.session.flatMap { session -> AgentSession? in
      guard session.confidence == .exact || session.confidence == .high,
        session.transcriptPath != nil
      else {
        return nil
      }
      return session
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let status = AgentsCommandStatus(rawValue: agentState.displayState.rawValue) ?? .idle
    return .success(
      AgentReadRuntimeSnapshot(
        target: agentReadTarget(from: resolved),
        agent: detectedAgent,
        status: status,
        rawState: detection.state.rawValue,
        detectionReason: detection.reason.identifier,
        lastChangedAt: formatter.string(from: agentState.lastChangedAt),
        blockerText: blockerText,
        transcriptSession: transcriptSession
      )
    )
  }

  private static func agentReadTarget(from target: ResolvedTarget) -> ReadTarget {
    ReadTarget(
      worktree: ReadTargetWorktree(
        id: target.worktreeID,
        name: target.worktreeName,
        path: target.worktreePath,
        rootPath: target.worktreeRootPath,
        kind: target.worktreeKind.rawValue
      ),
      tab: ReadTargetTab(id: target.tabID.uuidString, title: target.tabTitle, selected: target.tabSelected),
      pane: ReadTargetPane(
        id: target.paneID.uuidString,
        title: target.paneTitle,
        cwd: target.paneCWD,
        focused: target.paneFocused
      )
    )
  }

  private static func dispatchDateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  // swiftlint:disable:next function_body_length cyclomatic_complexity
  static func makeCLICommandRouter(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager,
    handoffRequestRegistry: HandoffRequestRegistry = HandoffRequestRegistry(),
    workflowCoordinatorBox: WorkflowCoordinatorBox = WorkflowCoordinatorBox(),
    workflowReservations: WorkflowPaneReservations = WorkflowPaneReservations(),
    agentSignalCallerResolver: AgentSignalCommandHandler.ResolveCaller? = nil
  ) -> CLICommandRouter {

    let listHandler = ListCommandHandler {
      ListRuntimeSnapshotBuilder.makeSnapshot(
        repositoriesState: appStore.state.repositories,
        terminalManager: terminalManager
      )
    }
    let profilesHandler = ProfilesCommandHandler {
      @Shared(.userGlobalSettings) var settings
      @Shared(.agentRuntimeAvailabilityProbeResults) var probeResults
      return ProfilesRuntimeSnapshot(
        profiles: settings.agentProfiles,
        probeResults: probeResults
      )
    }
    let agentsHandler = AgentsCommandHandler {
      var screenDetectionsBySurfaceID: [UUID: AgentScreenDetection] = [:]
      var signalsBySurfaceID: [UUID: AgentSignalsPayload] = [:]
      for terminalState in terminalManager.activeWorktreeStates {
        for (surfaceID, scan) in terminalState.lastAgentScreenScanBySurface {
          screenDetectionsBySurfaceID[surfaceID] = scan.detection
        }
        for surfaceID in terminalState.surfaceAgentStates.keys {
          signalsBySurfaceID[surfaceID] = terminalManager.agentSignalsPayload(
            surfaceID: surfaceID,
            includeDiagnosticLast: false
          )
        }
      }
      return AgentsRuntimeSnapshot(
        repositoriesState: appStore.state.repositories,
        listSnapshot: ListRuntimeSnapshotBuilder.makeSnapshot(
          repositoriesState: appStore.state.repositories,
          terminalManager: terminalManager
        ),
        screenDetectionsBySurfaceID: screenDetectionsBySurfaceID,
        signalsBySurfaceID: signalsBySurfaceID
      )
    }
    let resolveAgentSignalCaller: AgentSignalCommandHandler.ResolveCaller =
      agentSignalCallerResolver ?? { callerProcessID in
        CallerPaneResolver.pane(
          forCallerProcess: callerProcessID,
          paneByShellPID: terminalManager.paneByShellPID()
        )
      }
    let agentSignalHandler = AgentSignalCommandHandler(
      resolveCaller: resolveAgentSignalCaller,
      recordSignal: { caller, signal in
        terminalManager.recordAgentSignal(signal, caller: caller)
      }
    )
    let agentHookHandler = AgentNativeHookCommandHandler(
      resolveCaller: { context in
        if !context.callerProcessAncestry.isEmpty {
          return CallerPaneResolver.pane(
            forCallerProcessAncestry: context.callerProcessAncestry,
            paneByShellPID: terminalManager.paneByShellPID()
          )
        }
        guard let processID = context.callerProcessID else { return nil }
        return resolveAgentSignalCaller(processID)
      },
      recordHook: { caller, input in
        terminalManager.recordAgentNativeHook(input, caller: caller)
      }
    )
    let dispatchCompleteHandler = AgentDispatchCompleteCommandHandler(
      resolveCaller: resolveAgentSignalCaller,
      complete: { surfaceID, outcome, summary in
        do {
          return .success(
            try terminalManager.completeAgentDispatch(
              surfaceID: surfaceID,
              outcome: outcome,
              summary: summary
            ))
        } catch let error as AgentDispatchStoreError {
          return .failure(error)
        } catch {
          return .failure(.notFound)
        }
      },
      intercept: { surfaceID in
        Self.workflowDeliveryRefusal(surfaceID: surfaceID, appStore: appStore, terminalManager: terminalManager)
      }
    )
    let dispatchAbandonHandler = AgentDispatchAbandonCommandHandler(
      abandon: { dispatchID, reason in
        do {
          return .success(
            try terminalManager.abandonAgentDispatch(dispatchID: dispatchID, reason: reason))
        } catch let error as AgentDispatchStoreError {
          return .failure(error)
        } catch {
          return .failure(.notFound)
        }
      }
    )
    let agentReadHandler = AgentReadCommandHandler(
      snapshotProvider: { pane in
        await Self.makeAgentReadRuntimeSnapshot(
          pane: pane,
          appStore: appStore,
          terminalManager: terminalManager
        )
      },
      resultProvider: { agent, path, maxBytes in
        await Task.detached(priority: .userInitiated) {
          AgentTranscriptResultReader.read(agent: agent, at: path, maxBytes: maxBytes)
        }.value
      }
    )
    let sendHandler = SendCommandHandler(
      resolveProvider: { selector in
        let resolver = TargetResolver {
          TargetResolutionSnapshotBuilder.makeSnapshot(
            repositoriesState: appStore.state.repositories,
            terminalManager: terminalManager
          )
        }
        return resolver.resolve(selector).map { SendResolvedTarget(from: $0) }
      },
      textDelivery: { target, text, trailingEnter in
        guard let state = terminalManager.stateIfExists(for: target.worktreeID) else { return }
        let delivery = CLISendTextDelivery(
          insertText: { paneID, payload in
            state.insertCommittedText(payload, in: paneID)
          },
          submitLine: { paneID in
            state.submitLine(in: paneID)
          }
        )
        delivery.deliver(to: target, text: text, trailingEnter: trailingEnter)
      },
      waiterProvider: { worktreeID, surfaceID in
        terminalManager.stateIfExists(for: worktreeID)?
          .waitForCommandFinished(surfaceID: surfaceID)
      },
      captureProvider: { target in
        guard let state = terminalManager.stateIfExists(for: target.worktreeID),
          let surface = state.surfaceView(for: target.paneID),
          let viewportText = surface.readViewportContentsForCLI()
        else {
          return nil
        }
        return ReadCaptureInput(
          viewportText: viewportText,
          screenText: surface.readScreenContentsForCLI()
        )
      }
    )
    let focusHandler = FocusCommandHandler(
      resolveProvider: { selector in
        let resolver = TargetResolver {
          TargetResolutionSnapshotBuilder.makeSnapshot(
            repositoriesState: appStore.state.repositories,
            terminalManager: terminalManager
          )
        }
        return resolver.resolve(selector).map { FocusResolvedTarget(from: $0) }
      },
      focusPerformer: { target in
        selectCLIWorktreeContext(
          worktreeID: target.worktreeID,
          appStore: appStore,
          terminalManager: terminalManager
        )
        guard let state = terminalManager.stateIfExists(for: target.worktreeID) else {
          return false
        }
        return state.focusSurface(id: target.paneID)
      },
      bringToFront: {
        bringMainWindowToFront()
      }
    )
    let openHandler = Self.makeOpenHandler(appStore: appStore, terminalManager: terminalManager)
    let readHandler = ReadCommandHandler(
      resolveProvider: { selector in
        let resolver = TargetResolver {
          TargetResolutionSnapshotBuilder.makeSnapshot(
            repositoriesState: appStore.state.repositories,
            terminalManager: terminalManager
          )
        }
        return resolver.resolve(selector).map { ReadResolvedTarget(from: $0) }
      },
      captureProvider: { request in
        Self.makeReadCapture(request: request, terminalManager: terminalManager)
      }
    )
    let keyHandler = KeyCommandHandler(
      resolveProvider: { selector in
        let resolver = TargetResolver {
          TargetResolutionSnapshotBuilder.makeSnapshot(
            repositoriesState: appStore.state.repositories,
            terminalManager: terminalManager
          )
        }
        return resolver.resolve(selector).map { KeyResolvedTarget(from: $0) }
      },
      keyDelivery: { target, token, repeatCount in
        guard let state = terminalManager.stateIfExists(for: target.worktreeID) else {
          return KeyDeliveryResult(attempted: repeatCount, delivered: 0)
        }
        let delivered = (0..<repeatCount).count { _ in
          state.sendKeyToken(token, in: target.paneID)
        }
        return KeyDeliveryResult(attempted: repeatCount, delivered: delivered)
      }
    )
    let resolveTabTarget: TabCommandHandler.ResolveProvider = { selector in
      let resolver = TargetResolver {
        TargetResolutionSnapshotBuilder.makeSnapshot(
          repositoriesState: appStore.state.repositories,
          terminalManager: terminalManager
        )
      }
      return resolver.resolve(selector).map { TabResolvedTarget(from: $0) }
    }
    let resolveLifecycleTarget: LifecycleCommandHandler.ResolveCloseTargetProvider = { selector in
      let resolver = TargetResolver {
        TargetResolutionSnapshotBuilder.makeSnapshot(
          repositoriesState: appStore.state.repositories,
          terminalManager: terminalManager
        )
      }
      return resolver.resolveLifecycleTarget(selector)
    }
    let agentConditionSnapshot: @MainActor (TabResolvedTarget) -> AgentConditionSnapshot = { target in
      guard let surfaceID = UUID(uuidString: target.paneID) else {
        return .init(agent: nil, signal: nil, revision: 0, isLive: false, signals: .empty)
      }
      let observed = terminalManager.agentObservationSnapshot(surfaceID: surfaceID)
      let agent = appStore.state.repositories.activeAgents.entries.first {
        $0.surfaceID == surfaceID
      }
      let signalEvidence = terminalManager.currentAgentSignalEvidence(surfaceID: surfaceID)
      return .init(
        agent: agent,
        signal: signalEvidence.activeTerminal,
        changedSignal: signalEvidence.latest,
        revision: observed?.revision ?? 0,
        isLive: terminalManager.isSurfaceLive(surfaceID),
        signals: terminalManager.agentSignalsPayload(surfaceID: surfaceID)
      )
    }
    let agentWaitHandler = AgentWaitCommandHandler(
      observeDispatch: { dispatchID in
        do {
          return .success(try terminalManager.observeAgentDispatch(dispatchID: dispatchID))
        } catch let error as AgentDispatchStoreError {
          return .failure(error)
        } catch {
          return .failure(.notFound)
        }
      },
      observeCondition: { surfaceID in
        terminalManager.observeAgentState(surfaceID: surfaceID)
      },
      resolveConditionTarget: { pane in
        resolveTabTarget(.pane(pane))
      },
      conditionSnapshot: agentConditionSnapshot,
      signalsProvider: { target in
        guard let surfaceID = UUID(uuidString: target.pane.id) else { return .empty }
        return terminalManager.agentSignalsPayload(surfaceID: surfaceID)
      },
      screenProvider: { target in
        guard let surfaceID = UUID(uuidString: target.pane.id),
          let state = terminalManager.stateIfExists(for: target.worktree.id),
          let surface = state.surfaceView(for: surfaceID)
        else {
          return nil
        }
        return surface.readActiveContentsForCLI()
      }
    )
    let dispatchHandler = AgentDispatchCommandHandler(
      resolveTarget: { pane in
        resolveTabTarget(.pane(pane))
      },
      pendingDispatch: { target in
        UUID(uuidString: target.paneID).flatMap { terminalManager.pendingAgentDispatchSnapshot(surfaceID: $0) }
      },
      conditionSnapshot: agentConditionSnapshot,
      issueDispatch: { target in
        do {
          return .success(try terminalManager.issueAgentDispatch(boundTo: target))
        } catch let error as AgentDispatchStoreError {
          return .failure(error)
        } catch {
          return .failure(.bindingMissing)
        }
      },
      deliverPrompt: { target, text in
        // The same input path as `prowl send`: one committed-text paste, then Enter.
        guard let surfaceID = UUID(uuidString: target.paneID),
          let state = terminalManager.stateIfExists(for: target.worktreeID),
          state.insertCommittedText(text, in: surfaceID)
        else {
          return false
        }
        return state.submitLine(in: surfaceID)
      },
      cancelDispatch: { dispatchID in
        terminalManager.cancelAgentDispatchIssuance(dispatchID: dispatchID)
      }
    )
    let createTab: TabCommandHandler.CreateTabProvider = { target, path in
      let repositories = Array(appStore.state.repositories.repositories)
      guard let worktree = resolveCLITerminalWorktree(id: target.worktreeID, repositories: repositories) else {
        return nil
      }
      selectCLIWorktreeContext(
        worktreeID: target.worktreeID,
        appStore: appStore,
        terminalManager: terminalManager
      )
      let state = terminalManager.state(for: worktree)
      let directory = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
      guard let tabID = state.createTab(workingDirectoryOverride: directory) else {
        return nil
      }
      let resolver = makeTargetResolver(appStore: appStore, terminalManager: terminalManager)
      switch resolver.resolve(.tab(tabID.rawValue.uuidString)) {
      case .success(let resolved):
        return TabResolvedTarget(from: resolved)
      case .failure:
        return nil
      }
    }
    let createPane: LifecycleCommandHandler.CreatePaneProvider = { anchor, direction in
      createCLIPane(
        anchor: anchor,
        direction: direction,
        appStore: appStore,
        terminalManager: terminalManager
      )
    }
    let closeTab: TabCommandHandler.CloseTabProvider = { target, force in
      guard let tabUUID = UUID(uuidString: target.tabID),
        let state = terminalManager.stateIfExists(for: target.worktreeID)
      else {
        return false
      }
      return state.closeTab(
        TerminalTabID(rawValue: tabUUID),
        confirmation: force ? .skip : .prompt(.tab)
      )
    }
    let closePane: PaneCommandHandler.ClosePaneProvider = { target, force in
      guard let paneID = UUID(uuidString: target.paneID),
        let state = terminalManager.stateIfExists(for: target.worktreeID)
      else {
        return false
      }
      return state.closeSurface(
        id: paneID,
        confirmation: force ? .skip : .prompt(.pane)
      )
    }
    let lifecycleHandler = LifecycleCommandHandler(
      resolveCreateTarget: resolveTabTarget,
      resolveCloseTarget: resolveLifecycleTarget,
      createTab: createTab,
      createPane: createPane,
      profiles: {
        @Shared(.userGlobalSettings) var settings
        return settings.agentProfiles
      },
      prepareAgentProfile: { request in
        await prepareCLIProfileLaunch(
          request,
          appStore: appStore,
          terminalManager: terminalManager
        )
      },
      launchAgentProfile: { request in
        launchCLIProfile(
          request,
          appStore: appStore,
          terminalManager: terminalManager
        )
      },
      cancelProfilePreparation: { request in
        guard let preparation = request.preparedLaunch else { return }
        terminalManager.discardPreparedAgentProfileLaunch(preparation)
      },
      issueDispatch: {
        do {
          let snapshot = try terminalManager.issueAgentDispatch()
          guard case .pending(let record) = snapshot.payload(using: Self.dispatchDateFormatter()) else {
            return .failure(.capacityExceeded)
          }
          return .success(record)
        } catch let error as AgentDispatchStoreError {
          return .failure(error)
        } catch {
          return .failure(.capacityExceeded)
        }
      },
      bindDispatch: { dispatchID, target in
        do {
          try terminalManager.bindAgentDispatch(dispatchID: dispatchID, target: target)
          return .success(())
        } catch let error as AgentDispatchStoreError {
          return .failure(error)
        } catch {
          return .failure(.notFound)
        }
      },
      cancelDispatch: { dispatchID in
        terminalManager.cancelAgentDispatchIssuance(dispatchID: dispatchID)
      },
      rollbackProfileLaunch: { resource, target in
        switch resource {
        case .tab: _ = closeTab(target, true)
        case .pane: _ = closePane(target, true)
        }
      },
      closeTab: closeTab,
      closePane: closePane
    )
    let tabHandler = TabCommandHandler(
      resolveProvider: resolveTabTarget,
      createTab: createTab,
      closeTab: closeTab
    )
    let paneHandler = PaneCommandHandler(
      resolveProvider: resolveTabTarget,
      closePane: closePane
    )
    let handoffHandler = HandoffCommandHandler(
      resolveProvider: { selector, callerPID in
        let resolver = TargetResolver {
          TargetResolutionSnapshotBuilder.makeSnapshot(
            repositoriesState: appStore.state.repositories,
            terminalManager: terminalManager
          )
        }
        // The caller's own pane is the default source; an explicit selector
        // overrides it. Never fall back to the focused pane — a handoff must
        // not guess its subject from unstable UI state.
        let callerPane = callerPID.flatMap { pid in
          CallerPaneResolver.pane(
            forCallerProcess: pid,
            paneByShellPID: terminalManager.paneByShellPID()
          )
        }
        let effectiveSelector: TargetSelector
        if case .none = selector {
          guard let callerPane else { return .failure(.noCallerPane) }
          effectiveSelector = .pane(callerPane.surfaceID.uuidString)
        } else {
          effectiveSelector = selector
        }
        return resolver.resolve(effectiveSelector)
          .map { resolved in
            let agentState = terminalManager.stateIfExists(for: resolved.worktreeID)?
              .surfaceAgentStates[resolved.paneID]
            let agent = agentState?.detectedAgent?.rawValue
            return HandoffResolvedTarget(
              worktreeID: resolved.worktreeID,
              worktreeName: resolved.worktreeName,
              rootPath: resolved.worktreePath,
              paneID: resolved.paneID.uuidString,
              outgoingAgent: agent,
              outgoingLaunchObservation: agentState?.launchObservation,
              sessionContext: makeHandoffSessionContext(
                worktreeID: resolved.worktreeID,
                paneID: resolved.paneID,
                paneTitle: resolved.paneTitle,
                terminalManager: terminalManager
              )
            )
          }
          .mapError { .resolver($0) }
      },
      launchProvider: { target, request in
        Self.launchHandoffReceiver(
          target: target,
          request: request,
          appStore: appStore,
          terminalManager: terminalManager
        )
      },
      notifyLaunch: { launched, from, toAgent in
        Self.notifyHandoffLaunch(
          launched: launched,
          from: from,
          toAgent: toAgent,
          terminalManager: terminalManager
        )
      },
      completionObserver: { completion in
        appStore.send(.handoffCliCompleted(completion))
      },
      requestAuthorizer: { requestID in
        handoffRequestRegistry.claim(requestID)
      }

    )
    let workflowCoordinator = Self.makeWorkflowCoordinator(
      appStore: appStore,
      terminalManager: terminalManager,
      rendezvous: WorkflowCLIRendezvous(),
      reservations: workflowReservations
    )
    workflowCoordinatorBox.coordinator = workflowCoordinator
    let workflowHandler = WorkflowCommandHandler(
      snapshotProvider: { Self.makeWorkflowRuntimeSnapshot(appStore: appStore, terminalManager: terminalManager) },
      runtime: workflowCoordinator
    )
    return CLICommandRouter(
      openHandler: openHandler,
      listHandler: listHandler,
      agentsHandler: agentsHandler,
      agentsReadHandler: agentReadHandler,
      agentsSignalHandler: agentSignalHandler,
      agentsHookHandler: agentHookHandler,
      agentsDispatchHandler: dispatchHandler,
      agentsDispatchCompleteHandler: dispatchCompleteHandler,
      agentsDispatchAbandonHandler: dispatchAbandonHandler,
      agentsWaitHandler: agentWaitHandler,
      profilesHandler: profilesHandler,
      focusHandler: focusHandler,
      sendHandler: sendHandler,
      keyHandler: keyHandler,
      readHandler: readHandler,
      createHandler: lifecycleHandler,
      closeHandler: lifecycleHandler,
      tabHandler: tabHandler,
      paneHandler: paneHandler,
      handoffHandler: handoffHandler,
      workflowHandler: workflowHandler
    )
  }

  /// Headless by construction: the receiving agent starts in a background tab
  /// of the source's worktree — no worktree switch, no focus steal, no tab
  /// selection. Awareness comes from `notifyHandoffLaunch`.
  private static func launchHandoffReceiver(
    target: HandoffResolvedTarget,
    request: AgentStartRequest,
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> HandoffLaunchedPane? {
    let repositories = Array(appStore.state.repositories.repositories)
    guard let worktree = resolveCLITerminalWorktree(id: target.worktreeID, repositories: repositories) else {
      return nil
    }
    guard let initialInput = try? AgentRuntimeAdapterRegistry.makeStartInvocation(request).terminalInput else {
      return nil
    }
    let state = terminalManager.state(for: worktree)
    guard
      let tabID = state.createTab(
        focusing: false,
        selecting: false,
        initialInput: initialInput,
        workingDirectoryOverride: URL(fileURLWithPath: target.rootPath, isDirectory: true)
      )
    else {
      return nil
    }
    let resolver = makeTargetResolver(appStore: appStore, terminalManager: terminalManager)
    switch resolver.resolve(.tab(tabID.rawValue.uuidString)) {
    case .success(let resolved):
      return HandoffLaunchedPane(
        worktreeID: resolved.worktreeID,
        worktreeName: resolved.worktreeName,
        tabID: resolved.tabID.uuidString,
        paneID: resolved.paneID.uuidString,
        paneTitle: resolved.paneTitle
      )
    case .failure:
      return nil
    }
  }

  /// One completion notification per launched transition, suppressed when the
  /// user is already watching the target worktree (the appearing tab is the
  /// signal there). Click-to-focus routes to the receiving pane through the
  /// regular notification pipeline.
  private static func notifyHandoffLaunch(
    launched: HandoffLaunchedPane,
    from: String,
    toAgent: String,
    terminalManager: WorktreeTerminalManager
  ) {
    let watching =
      terminalManager.selectedWorktreeID == launched.worktreeID
      && NSApplication.shared.isActive
    guard !watching else { return }
    guard let paneID = UUID(uuidString: launched.paneID),
      let state = terminalManager.stateIfExists(for: launched.worktreeID)
    else { return }
    state.appendNotification(
      title: "\(from) → \(toAgent)",
      body: "Took over in \(launched.worktreeName)",
      surfaceId: paneID
    )
  }

  @MainActor
  static func makeWorkflowRuntimeSnapshot(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> WorkflowRuntimeSnapshot {
    @Shared(.userGlobalSettings) var settings
    @Shared(.agentRuntimeAvailabilityProbeResults) var probeResults
    let bundledSkills = Bundle.main.resourceURL.flatMap { try? ProwlSkills.bundled(resourcesURL: $0) }
    let installedAgents =
      probeResults.isEmpty
      ? nil
      : Set(probeResults.filter { $0.value.isAvailable }.keys.map { $0.agent.rawValue })
    return WorkflowRuntimeSnapshot(
      resolution: TargetResolutionSnapshotBuilder.makeSnapshot(
        repositoriesState: appStore.state.repositories,
        terminalManager: terminalManager
      ),
      paneByShellPID: terminalManager.paneByShellPID(),
      bundleWorkflowsURL: SupacodePaths.bundledWorkflowsURL,
      userWorkflowsURL: WorkflowSources.userDirectory(home: FileManager.default.homeDirectoryForCurrentUser),
      disabledWorkflowIDs: Set(settings.disabledWorkflowIDs),
      bundledSkillIDs: bundledSkills.map { Set($0.map(\.id)) },
      knownAgents: Set(DetectedAgent.allCases.map(\.rawValue)),
      installedAgents: installedAgents,
      enabledProfiles: settings.agentProfiles.filter(\.isEnabled).map { profile in
        WorkflowProfileSuggestion(
          agent: profile.runtime.agent.rawValue,
          model: profile.model,
          reasoningEffort: profile.reasoningEffort,
          executionMode: profile.executionMode.rawValue
        )
      }
    )

  }

  private static func makeCLISocketServer(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager,
    handoffRequestRegistry: HandoffRequestRegistry,
    workflowCoordinatorBox: WorkflowCoordinatorBox,
    workflowReservations: WorkflowPaneReservations
  ) -> CLISocketServer {

    let cliRouter = makeCLICommandRouter(
      appStore: appStore,
      terminalManager: terminalManager,
      handoffRequestRegistry: handoffRequestRegistry,
      workflowCoordinatorBox: workflowCoordinatorBox,
      workflowReservations: workflowReservations
    )
    let cliServer = CLISocketServer(
      router: cliRouter,
      onStatusChanged: { CLIServiceStatusPublisher.shared.publish($0) }
    )
    let logger = SupaLogger("CLIService")
    do {
      try cliServer.start()
      logger.info("CLI socket server started at \(ProwlSocket.defaultPath)")
    } catch {
      logger.warning("Failed to start CLI socket server: \(String(describing: error))")
    }
    return cliServer
  }

  // MARK: - Open handler factory

  private static func makeOpenHandler(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> OpenCommandHandler {
    OpenCommandHandler(
      resolver: { path in
        resolveOpenPath(path, repositories: appStore.state.repositories)
      },
      selectWorktree: { worktreeID in
        selectCLIWorktreeContext(
          worktreeID: worktreeID,
          appStore: appStore,
          terminalManager: terminalManager
        )
      },
      addAndOpen: { url in
        appStore.send(.repositories(.repositoryManagement(.openRepositories([url]))))
      },
      createTabAtPath: { worktreeID, path in
        let repositories = Array(appStore.state.repositories.repositories)
        guard let worktree = resolveCLITerminalWorktree(id: worktreeID, repositories: repositories) else {
          return
        }
        terminalManager.handleCommand(
          .createTabInDirectory(worktree, directory: URL(fileURLWithPath: path, isDirectory: true))
        )
      },
      resolveTarget: { selector in
        switch makeTargetResolver(appStore: appStore, terminalManager: terminalManager).resolve(selector) {
        case .success(let target):
          return OpenResolvedTarget(
            worktreeID: target.worktreeID,
            worktreeName: target.worktreeName,
            worktreePath: target.worktreePath,
            worktreeRootPath: target.worktreeRootPath,
            worktreeKind: target.worktreeKind.rawValue,
            tabID: target.tabID.uuidString,
            tabTitle: target.tabTitle,
            tabCWD: target.paneCWD,
            paneID: target.paneID.uuidString,
            paneTitle: target.paneTitle,
            paneCWD: target.paneCWD
          )
        case .failure:
          return nil
        }
      },
      isRepositoriesReady: {
        appStore.state.repositories.isInitialLoadComplete
      }
    )
  }

  // MARK: - Open path resolution

  private static func resolveOpenPath(
    _ path: String?,
    repositories: RepositoriesFeature.State
  ) -> OpenResolverResult {
    guard let path else {
      return OpenResolverResult(
        resolution: .noArgument, worktreeID: nil, worktreeName: nil,
        worktreePath: nil, rootPath: nil, worktreeKind: nil, resolvedPath: nil
      )
    }
    let normalized = URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL.path(percentEncoded: false)
    // Exact match: worktree working directory or repository root
    for repository in repositories.repositories {
      let kind = repository.kind.rawValue
      for worktree in repository.worktrees {
        let wtPath = worktree.workingDirectory
          .standardizedFileURL.path(percentEncoded: false)
        if wtPath == normalized {
          return OpenResolverResult(
            resolution: .exactRoot, worktreeID: worktree.id,
            worktreeName: worktree.name, worktreePath: wtPath,
            rootPath: repository.rootURL.standardizedFileURL.path(percentEncoded: false),
            worktreeKind: kind, resolvedPath: normalized
          )
        }
      }
      let repoRoot = repository.rootURL
        .standardizedFileURL.path(percentEncoded: false)
      if repoRoot == normalized,
        !repository.capabilities.supportsWorktrees,
        repository.capabilities.supportsRunnableFolderActions
      {
        return OpenResolverResult(
          resolution: .exactRoot, worktreeID: repository.id,
          worktreeName: repository.name, worktreePath: repoRoot,
          rootPath: repoRoot, worktreeKind: kind, resolvedPath: normalized
        )
      }
    }
    // Inside-root: path is inside an existing worktree/repo root
    let normalizedSlash = normalized.hasSuffix("/") ? normalized : normalized + "/"
    for repository in repositories.repositories {
      let kind = repository.kind.rawValue
      for worktree in repository.worktrees {
        let wtPath = worktree.workingDirectory
          .standardizedFileURL.path(percentEncoded: false)
        let wtSlash = wtPath.hasSuffix("/") ? wtPath : wtPath + "/"
        if normalizedSlash.hasPrefix(wtSlash) {
          return OpenResolverResult(
            resolution: .insideRoot, worktreeID: worktree.id,
            worktreeName: worktree.name, worktreePath: wtPath,
            rootPath: repository.rootURL.standardizedFileURL.path(percentEncoded: false),
            worktreeKind: kind, resolvedPath: normalized
          )
        }
      }
      if !repository.capabilities.supportsWorktrees,
        repository.capabilities.supportsRunnableFolderActions
      {
        let repoRoot = repository.rootURL
          .standardizedFileURL.path(percentEncoded: false)
        let repoSlash = repoRoot.hasSuffix("/") ? repoRoot : repoRoot + "/"
        if normalizedSlash.hasPrefix(repoSlash) {
          return OpenResolverResult(
            resolution: .insideRoot, worktreeID: repository.id,
            worktreeName: repository.name, worktreePath: repoRoot,
            rootPath: repoRoot, worktreeKind: kind, resolvedPath: normalized
          )
        }
      }
    }
    // New root: unknown path
    return OpenResolverResult(
      resolution: .newRoot, worktreeID: nil, worktreeName: nil,
      worktreePath: nil, rootPath: nil, worktreeKind: nil, resolvedPath: normalized
    )
  }

  static func resolveCLITerminalWorktree(
    id: Worktree.ID,
    repositories: [Repository]
  ) -> Worktree? {
    for repository in repositories {
      if let worktree = repository.worktrees[id: id] {
        return worktree
      }
      if repository.id == id,
        repository.capabilities.supportsRunnableFolderActions,
        !repository.capabilities.supportsWorktrees
      {
        return Worktree(
          id: repository.id,
          name: repository.name,
          detail: repository.rootURL.path(percentEncoded: false),
          workingDirectory: repository.rootURL,
          repositoryRootURL: repository.rootURL
        )
      }
    }
    return nil
  }

  private static func prepareCLIProfileLaunch(
    _ request: CLIProfileLaunchRequest,
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) async -> Result<CLIProfileLaunchRequest, CLIProfileLaunchFailure> {
    let repositories = Array(appStore.state.repositories.repositories)
    guard
      let worktree = resolveCLITerminalWorktree(
        id: request.target.worktreeID,
        repositories: repositories
      )
    else {
      return .failure(.createFailed("The resolved worktree is no longer available."))
    }
    let intent = request.prompt.map(AgentStartIntent.prompt) ?? .interactive
    let plan: AgentProfileLaunchPlan
    do {
      plan = try AgentProfileLaunchPlanner.plan(
        for: request.profile,
        intent: intent,
        homeBaseDirectory: SupacodePaths.agentProfileHomesDirectory
      )
    } catch {
      return .failure(.planning(error, profile: request.profile))
    }
    let placement: AgentProfileLaunchRequest.Placement
    switch request.resource {
    case .tab:
      placement = .tab(background: request.background)
    case .pane:
      guard let anchor = UUID(uuidString: request.target.paneID),
        let direction = request.direction
      else {
        return .failure(.createFailed("The resolved split anchor is invalid."))
      }
      placement = .split(
        anchor: anchor,
        direction: direction.terminalSplitDirection,
        background: request.background
      )
    }
    let launchRequest = AgentProfileLaunchRequest(
      plan: plan,
      placement: placement,
      workingDirectoryOverride: request.path.map { URL(fileURLWithPath: $0, isDirectory: true) },
      title: request.profile.name
    )
    switch await terminalManager.prepareAgentProfileLaunch(launchRequest, in: worktree) {
    case .failure(let error):
      return .failure(.creation(error, profile: request.profile))
    case .success(let preparation):
      return .success(
        CLIProfileLaunchRequest(
          resource: request.resource,
          target: request.target,
          profile: request.profile,
          prompt: request.prompt,
          path: request.path,
          direction: request.direction,
          background: request.background,
          dispatchID: nil,
          preparedLaunch: preparation
        )
      )
    }
  }

  private static func launchCLIProfile(
    _ request: CLIProfileLaunchRequest,
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> Result<TabResolvedTarget, CLIProfileLaunchFailure> {
    let repositories = Array(appStore.state.repositories.repositories)
    guard
      let worktree = resolveCLITerminalWorktree(
        id: request.target.worktreeID,
        repositories: repositories
      ),
      var preparation = request.preparedLaunch
    else {
      return .failure(.createFailed("The prepared Agent Profile launch is no longer available."))
    }
    if let dispatchID = request.dispatchID, let prompt = request.prompt {
      do {
        let pairedPlan = try preparation.context.request.plan.attachingDispatch(
          id: dispatchID,
          userPrompt: prompt
        )
        preparation = PreparedAgentProfileLaunch(
          context: FrozenAgentProfileLaunchContext(
            request: AgentProfileLaunchRequest(
              plan: pairedPlan,
              placement: preparation.context.request.placement,
              workingDirectoryOverride: preparation.context.request.workingDirectoryOverride,
              inheritanceAnchor: preparation.context.request.inheritanceAnchor,
              title: preparation.context.request.title
            ),
            inheritedCWD: preparation.context.inheritedCWD,
            anchorSurfaceID: preparation.context.anchorSurfaceID,
            tracksFocusedAnchor: preparation.context.tracksFocusedAnchor,
            tracksInheritedCWD: preparation.context.tracksInheritedCWD
          ),
          warnings: preparation.warnings
        )
      } catch {
        return .failure(.planning(error, profile: request.profile))
      }
    }
    let launched: LaunchedSurface
    switch terminalManager.launchPreparedAgentProfile(preparation, in: worktree) {
    case .success(let surface):
      launched = surface
    case .failure(let error):
      return .failure(.creation(error, profile: request.profile))
    }

    if !request.background {
      selectCLIWorktreeContext(
        worktreeID: request.target.worktreeID,
        appStore: appStore,
        terminalManager: terminalManager
      )
      terminalManager.state(for: worktree).selectTab(launched.tabID)
    }
    let resolver = makeTargetResolver(appStore: appStore, terminalManager: terminalManager)
    switch resolver.resolve(.pane(launched.surfaceID.uuidString)) {
    case .success(let resolved):
      return .success(TabResolvedTarget(from: resolved))
    case .failure:
      let state = terminalManager.state(for: worktree)
      switch request.resource {
      case .tab:
        _ = state.closeTab(launched.tabID, confirmation: .skip)
      case .pane:
        _ = state.closeSurface(id: launched.surfaceID, confirmation: .skip)
      }
      return .failure(.createFailed("The launched Profile pane could not be resolved."))
    }
  }

  private static func createCLIPane(
    anchor: TabResolvedTarget,
    direction: CreatePaneDirection,
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> TabResolvedTarget? {
    guard let anchorPaneID = UUID(uuidString: anchor.paneID),
      let state = terminalManager.stateIfExists(for: anchor.worktreeID)
    else {
      return nil
    }
    let createdPaneID: UUID
    switch state.createSplit(
      of: anchorPaneID,
      direction: direction.terminalSplitDirection,
      initialInput: nil,
      additionalEnvironment: [:],
      focusing: true
    ) {
    case .success(let paneID):
      createdPaneID = paneID
    case .failure:
      return nil
    }

    // Resolve and split the explicit anchor before changing any UI focus.
    // Selection happens only after creation so mutable focus can never retarget the split.
    selectCLIWorktreeContext(
      worktreeID: anchor.worktreeID,
      appStore: appStore,
      terminalManager: terminalManager
    )
    if let tabID = state.tabId(containing: createdPaneID) {
      state.selectTab(tabID)
    }
    let resolver = makeTargetResolver(appStore: appStore, terminalManager: terminalManager)
    switch resolver.resolve(.pane(createdPaneID.uuidString)) {
    case .success(let resolved):
      return TabResolvedTarget(from: resolved)
    case .failure:
      return nil
    }
  }

  static func selectCLIWorktreeContext(
    worktreeID: Worktree.ID,
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) {
    let repositories = appStore.state.repositories
    if repositories.worktree(for: worktreeID) != nil {
      appStore.send(.repositories(.selectWorktree(worktreeID)))
    } else if let repository = repositories.repositories[id: worktreeID],
      repository.capabilities.supportsRunnableFolderActions
    {
      appStore.send(.repositories(.selectRepository(worktreeID)))
    }
    terminalManager.handleCommand(.setSelectedWorktreeID(worktreeID))
  }

  private static func bringMainWindowToFront() -> Bool {
    NSApplication.shared.surfaceMainWindow()
  }

  var body: some Scene {
    Window("Prowl", id: WindowID.main) {
      GhosttyColorSchemeSyncView(
        ghostty: ghostty,
        preferredColorScheme: store.settings.appearanceMode.colorScheme
      ) {
        ContentView(store: store, terminalManager: terminalManager)
          .environment(remoteMirror)
          .environment(ghosttyShortcuts)
          .environment(commandKeyObserver)
          .environment(\.resolvedKeybindings, store.resolvedKeybindings)
          .environment(askAgentHelp)
          .sheet(
            isPresented: Binding(
              get: { askAgentHelp.isPresented },
              set: { askAgentHelp.isPresented = $0 }
            )
          ) {
            AskAgentHelpView { askAgentHelp.dismiss() }
          }
      }
      .registersMainWindowOpener()
      .registersSettingsWindowOpener()
      .onAppear {
        WindowLifecycleDiagnostics.logWithWindows("mainWindow content onAppear")
        WindowLifecycleDiagnostics.noteMainWindowAppeared()
        syncGhosttyManagedShortcuts(with: store.resolvedKeybindings)
      }
      .onDisappear {
        WindowLifecycleDiagnostics.logWithWindows("mainWindow content onDisappear")
      }
      .onChange(of: store.resolvedKeybindings) { _, newValue in
        syncGhosttyManagedShortcuts(with: newValue)
      }
      .preferredColorScheme(store.settings.appearanceMode.colorScheme)
    }
    .environment(ghosttyShortcuts)
    .environment(commandKeyObserver)
    .commands {
      // Grouped to keep `commands` under SwiftUI's CommandsBuilder
      // tuple-arity limit when `#if DEBUG` adds the Debug menu below.
      Group {
        WorktreeCommands(store: store, terminalManager: terminalManager)
        SidebarCommands(store: store)
        TerminalCommands(
          ghosttyShortcuts: ghosttyShortcuts,
          resolvedKeybindings: store.resolvedKeybindings
        )
        WindowCommands(
          store: store,
          terminalManager: terminalManager,
          ghosttyShortcuts: ghosttyShortcuts,
          resolvedKeybindings: store.resolvedKeybindings
        )
      }
      CommandGroup(after: .textEditing) {
        Button("Command Palette") {
          store.send(.commandPalette(.togglePresented))
        }
        .modifier(
          KeyboardShortcutModifier(
            shortcut: store.resolvedKeybindings.keyboardShortcut(
              for: AppShortcuts.CommandID.commandPalette
            )
          )
        )
        .help(helpText(title: "Command Palette", commandID: AppShortcuts.CommandID.commandPalette))
      }
      UpdateCommands(
        store: store.scope(state: \.updates, action: \.updates),
        resolvedKeybindings: store.resolvedKeybindings
      )
      CommandGroup(after: .appSettings) {
        Button("Install Command Line Tool") {
          store.send(.settings(.installCLIButtonTapped(showAlert: false)))
        }
        .help("Install the prowl command line tool to /usr/local/bin")
      }
      #if DEBUG
        CommandMenu("Debug") {
          Button("Icon Catalog") {
            DebugWindowManager.shared.show()
          }
        }
      #endif
      CommandGroup(replacing: .help) {
        Button("Ask Agent About Prowl…", systemImage: "sparkles") {
          askAgentHelp.present()
        }
        .help("Copy a prompt that points your AI agent at Prowl's bundled docs")
        Divider()
        Button("Homepage", systemImage: "house") {
          if let url = URL(string: "https://prowl.onev.cat/") {
            NSWorkspace.shared.open(url)
          }
        }
        Button("Release Notes", systemImage: "note.text") {
          if let url = URL(string: "https://prowl.onev.cat/releases/") {
            NSWorkspace.shared.open(url)
          }
        }
      }
      CommandGroup(replacing: .appTermination) {
        Button("Quit Prowl") {
          store.send(.requestQuit)
        }
        .modifier(
          KeyboardShortcutModifier(
            shortcut: store.resolvedKeybindings.keyboardShortcut(
              for: AppShortcuts.CommandID.quitApplication
            )
          )
        )
        .help(helpText(title: "Quit Prowl", commandID: AppShortcuts.CommandID.quitApplication))
      }
    }
    Window("Settings", id: WindowID.settings) {
      SettingsView(store: store)
        .environment(ghosttyShortcuts)
        .environment(commandKeyObserver)
        .environment(\.resolvedKeybindings, store.resolvedKeybindings)
        .preferredColorScheme(store.settings.appearanceMode.colorScheme)
    }
    .defaultSize(width: 840, height: 680)
    .windowToolbarStyle(.automatic)
  }

  private func syncGhosttyManagedShortcuts(with resolvedKeybindings: ResolvedKeybindingMap) {
    ghostty.applyAppKeybindArguments(
      AppShortcuts.ghosttyCLIKeybindArguments(from: resolvedKeybindings)
    )
  }

  private func helpText(title: String, commandID: String) -> String {
    if let shortcut = store.resolvedKeybindings.display(for: commandID) {
      return "\(title) (\(shortcut))"
    }
    return title
  }
}
