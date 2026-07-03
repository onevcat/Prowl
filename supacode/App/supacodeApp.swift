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
import Sentry
import Sharing
import SwiftUI

@MainActor
private final class SupacodeAppStoreBox {
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
  var telegramBotRuntime: TelegramBotRuntime?

  func applicationDidFinishLaunching(_ notification: Notification) {
    WindowLifecycleDiagnostics.startMainThreadHeartbeat()
    WindowLifecycleDiagnostics.logWithWindows("applicationDidFinishLaunching")
    WindowLifecycleDiagnostics.noteWindowlessIfNoMainWindow("launch")
    WindowLifecycleDiagnostics.applyLaunchStallIfConfigured()
    // Disable press-and-hold accent menu so that key repeat works in the terminal.
    UserDefaults.standard.register(defaults: [
      "ApplePressAndHoldEnabled": false
    ])
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
      cliSocketServer?.stop()
      telegramBotRuntime?.stop()
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
  @State private var worktreeInfoWatcher: WorktreeInfoWatcherManager
  @State private var pullRequestRefreshCoordinator: PullRequestRefreshCoordinator
  @State private var commandKeyObserver: CommandKeyObserver
  @State private var cliSocketServer: CLISocketServer
  @State private var telegramBotRuntime: TelegramBotRuntime
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
      let environment = initialSettings.updateChannel == .tip ? "tip" : "production"

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

  @MainActor init() {
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
    let ghosttyArgv = GhosttyCLI.argv(resolvedKeybindings: initialResolvedKeybindings)
    ghosttyArgv.withUnsafeBufferPointer { buffer in
      let argc = UInt(max(0, buffer.count - 1))
      let argv = UnsafeMutablePointer(mutating: buffer.baseAddress)
      if ghostty_init(argc, argv) != GHOSTTY_SUCCESS {
        preconditionFailure("ghostty_init failed")
      }
    }
    let runtime = GhosttyRuntime(initialColorScheme: initialSettings.appearanceMode.colorScheme)
    _ghostty = State(initialValue: runtime)
    let shortcuts = GhosttyShortcutManager(runtime: runtime)
    _ghosttyShortcuts = State(initialValue: shortcuts)
    let terminalManager = WorktreeTerminalManager(
      runtime: runtime,
      preferredFontSize: initialSettings.terminalFontSize
    )
    _terminalManager = State(initialValue: terminalManager)
    let worktreeInfoWatcher = WorktreeInfoWatcherManager()
    _worktreeInfoWatcher = State(initialValue: worktreeInfoWatcher)
    let storeBox = SupacodeAppStoreBox()
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
    }
    _store = State(initialValue: appStore)
    storeBox.store = appStore

    let cliRouter = Self.makeCLICommandRouter(appStore: appStore, terminalManager: terminalManager)
    let cliServer = Self.makeCLISocketServer(router: cliRouter)
    _cliSocketServer = State(initialValue: cliServer)
    let telegramRuntime = TelegramBotRuntime(
      client: .liveValue,
      route: { envelope in
        await cliRouter.route(envelope)
      }
    )
    telegramRuntime.apply(configuration: initialAppState.settings.telegramBotConfiguration)
    _telegramBotRuntime = State(initialValue: telegramRuntime)

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
    appDelegate.cliSocketServer = cliServer
    appDelegate.telegramBotRuntime = telegramRuntime
    SettingsWindowManager.shared.configure(
      store: appStore,
      ghosttyShortcuts: shortcuts,
      commandKeyObserver: keyObserver
    )
    #if DEBUG
      DebugWindowManager.shared.configure(store: appStore)
    #endif
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
      events: {
        terminalManager.eventStream()
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
      latestUnreadNotification: {
        terminalManager.latestUnreadNotificationLocation()
      },
      focusSurface: { worktreeID, surfaceID in
        terminalManager.focusSurface(worktreeID: worktreeID, surfaceID: surfaceID)
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

  private static func makeTargetResolver(
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

  // swiftlint:disable:next function_body_length
  static func makeCLICommandRouter(
    appStore: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> CLICommandRouter {
    let listHandler = ListCommandHandler {
      ListRuntimeSnapshotBuilder.makeSnapshot(
        repositoriesState: appStore.state.repositories,
        terminalManager: terminalManager
      )
    }
    let agentsHandler = AgentsCommandHandler {
      AgentsRuntimeSnapshot(
        repositoriesState: appStore.state.repositories,
        listSnapshot: ListRuntimeSnapshotBuilder.makeSnapshot(
          repositoriesState: appStore.state.repositories,
          terminalManager: terminalManager
        )
      )
    }
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
    let tabHandler = TabCommandHandler(
      resolveProvider: { selector in
        let resolver = TargetResolver {
          TargetResolutionSnapshotBuilder.makeSnapshot(
            repositoriesState: appStore.state.repositories,
            terminalManager: terminalManager
          )
        }
        return resolver.resolve(selector).map { TabResolvedTarget(from: $0) }
      },
      createTab: { target, path in
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
      },
      closeTab: { target, force in
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
    )
    let paneHandler = PaneCommandHandler(
      resolveProvider: { selector in
        let resolver = TargetResolver {
          TargetResolutionSnapshotBuilder.makeSnapshot(
            repositoriesState: appStore.state.repositories,
            terminalManager: terminalManager
          )
        }
        return resolver.resolve(selector).map { TabResolvedTarget(from: $0) }
      },
      closePane: { target, force in
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
    )
    return CLICommandRouter(
      openHandler: openHandler,
      listHandler: listHandler,
      agentsHandler: agentsHandler,
      focusHandler: focusHandler,
      sendHandler: sendHandler,
      keyHandler: keyHandler,
      readHandler: readHandler,
      tabHandler: tabHandler,
      paneHandler: paneHandler
    )
  }

  private static func makeCLISocketServer(router cliRouter: CLICommandRouter) -> CLISocketServer {
    let cliServer = CLISocketServer(router: cliRouter)
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

  private static func selectCLIWorktreeContext(
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
      .onAppear {
        WindowLifecycleDiagnostics.logWithWindows("mainWindow content onAppear")
        WindowLifecycleDiagnostics.noteMainWindowAppeared()
        syncGhosttyManagedShortcuts(with: store.resolvedKeybindings)
        telegramBotRuntime.apply(configuration: store.settings.telegramBotConfiguration)
      }
      .onDisappear {
        WindowLifecycleDiagnostics.logWithWindows("mainWindow content onDisappear")
      }
      .onChange(of: store.resolvedKeybindings) { _, newValue in
        syncGhosttyManagedShortcuts(with: newValue)
      }
      .onChange(of: store.settings.telegramBotConfiguration) { _, newValue in
        telegramBotRuntime.apply(configuration: newValue)
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
          resolvedKeybindings: store.resolvedKeybindings,
          settingsWindowManager: SettingsWindowManager.shared
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
      CommandGroup(replacing: .appSettings) {
        Button("Settings...") {
          SettingsWindowManager.shared.show()
        }
        .modifier(
          KeyboardShortcutModifier(
            shortcut: store.resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.openSettings)
          )
        )
      }
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
