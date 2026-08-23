import AppKit
import ConcurrencyExtras
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct CleanWindowAndSurfaceTests {
  @Test func processInfoCachePublishesOnlyWhenPaneStateChanges() throws {
    let lazygit = HerdrPaneProcessInfo(
      paneID: "p1",
      foregroundProcesses: [HerdrPaneProcess(pid: 20, name: "lazygit")]
    )
    let shell = HerdrPaneProcessInfo(
      paneID: "p1",
      foregroundProcesses: [HerdrPaneProcess(pid: 10, name: "zsh")]
    )
    let current = ["p1": lazygit]

    #expect(
      HerdrProcessInfoCache.updated(current, with: [("p1", lazygit)]) == nil
    )
    let updated = try #require(
      HerdrProcessInfoCache.updated(current, with: [("p1", shell)])
    )
    #expect(updated["p1"] == shell)
  }

  @Test func processPaneTrackingKeepsRepresentativesUntilFocusIsKnown() {
    let representatives: Set<String> = ["p1", "p2"]

    #expect(
      HerdrProcessPaneTracking.resolvedFocusedPaneID(
        selectedPaneID: "p2",
        snapshotFocusedPaneID: "p1"
      ) == "p2"
    )
    #expect(
      HerdrProcessPaneTracking.resolvedFocusedPaneID(
        selectedPaneID: nil,
        snapshotFocusedPaneID: "p1"
      ) == "p1"
    )
    #expect(
      HerdrProcessPaneTracking.shouldRefreshImmediately(
        from: nil,
        to: "p1",
        isHerdrForeground: true
      )
    )
    #expect(
      HerdrProcessPaneTracking.shouldRefreshImmediately(
        from: "p1",
        to: "p2",
        isHerdrForeground: true
      )
    )
    #expect(
      !HerdrProcessPaneTracking.shouldRefreshImmediately(
        from: "p1",
        to: "p1",
        isHerdrForeground: true
      )
    )
    #expect(
      !HerdrProcessPaneTracking.shouldRefreshImmediately(
        from: "p1",
        to: "p2",
        isHerdrForeground: false
      )
    )
    #expect(
      HerdrProcessPaneTracking.paneIDsAfterInitialScan(
        representativePaneIDs: representatives,
        focusedPaneIDs: []
      ) == representatives
    )
    #expect(
      HerdrProcessPaneTracking.paneIDsAfterInitialScan(
        representativePaneIDs: representatives,
        focusedPaneIDs: ["p2"]
      ) == ["p2"]
    )
  }

  @Test func defaultSurfaceConfigurationStartsPlainHomeShell() {
    let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
    let configuration = CleanSurfaceConfiguration.default(
      homeDirectory: home,
      preferredFontSize: 15
    )

    #expect(configuration.workingDirectory == home)
    #expect(configuration.initialInput == nil)
    #expect(configuration.command == nil)
    #expect(configuration.fontSize == 15)
    #expect(configuration.context == GHOSTTY_SURFACE_CONTEXT_WINDOW)
  }

  @Test func terminalHostCreatesItsPlainHomeSurfaceOnlyOnce() {
    let runtime = GhosttyRuntime()
    let createdSurface = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
      skipsSurfaceCreationForTesting: true
    )
    var configurations: [CleanSurfaceConfiguration] = []
    let host = CleanTerminalHost(
      runtime: runtime,
      preferredFontSize: 15,
      surfaceFactory: { configuration in
        configurations.append(configuration)
        return createdSurface
      }
    )

    host.start()
    host.start()

    #expect(
      configurations == [
        .default(
          homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
          preferredFontSize: 15
        )
      ]
    )
    #expect(host.surface === createdSurface)
    host.suspend()
  }

  @Test func foregroundProbeIgnoresAnOlderRequestThatFinishesLast() async throws {
    let continuations = LockIsolated<[pid_t: CheckedContinuation<ForegroundJob?, Never>]>([:])
    let probe = CleanForegroundJobProbe { processGroupID, _ in
      guard let processGroupID else { return nil }
      return await withCheckedContinuation { continuation in
        continuations.withValue { $0[processGroupID] = continuation }
      }
    }
    let olderJob = makeForegroundJob(processGroupID: 1, name: "older")
    let newerJob = makeForegroundJob(processGroupID: 2, name: "newer")
    var appliedJobs: [ForegroundJob?] = []

    probe.request(processGroupID: 1, childPID: nil) { appliedJobs.append($0) }
    await waitForCleanCondition { continuations.value[1] != nil }
    probe.request(processGroupID: 2, childPID: nil) { appliedJobs.append($0) }
    await waitForCleanCondition { continuations.value[2] != nil }

    let newerContinuation = try #require(continuations.withValue { $0.removeValue(forKey: 2) })
    newerContinuation.resume(returning: newerJob)
    await waitForCleanCondition { appliedJobs == [newerJob] }

    let olderContinuation = try #require(continuations.withValue { $0.removeValue(forKey: 1) })
    olderContinuation.resume(returning: olderJob)
    for _ in 0..<20 {
      await Task.yield()
    }

    #expect(appliedJobs == [newerJob])
    probe.cancel()
  }

  @Test func configuresFocusableWindowWithoutRemovingNativeCapabilities() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )

    CleanWindowConfigurator.configure(window)

    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.styleMask.contains(.titled))
    #expect(window.canBecomeKey)
    #expect(window.styleMask.contains(.closable))
    #expect(window.styleMask.contains(.miniaturizable))
    #expect(window.styleMask.contains(.resizable))
    #expect(window.titleVisibility == .hidden)
    #expect(window.titlebarAppearsTransparent)
    #expect(window.toolbar == nil)
    #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
    #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
    #expect(window.standardWindowButton(.zoomButton)?.isHidden == true)
    #expect(CleanWindowConfigurator.titlebarContainer(in: window)?.isHidden == true)
    #expect(window.contentView?.frame.minY == 0)
    #expect(window.contentView?.frame.maxY == window.frame.height)
  }

  @Test func forwardsTitlebarMouseGestureToTerminalContent() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    let contentView = try #require(window.contentView)
    let terminalView = NSView(frame: contentView.bounds)
    terminalView.autoresizingMask = [.width, .height]
    contentView.addSubview(terminalView)
    CleanWindowConfigurator.configure(window)
    var forwardedTypes: [NSEvent.EventType] = []
    let forwarder = CleanTitlebarMouseForwarder(surfaceView: terminalView) { event in
      forwardedTypes.append(event.type)
    }
    let titlebarPoint = NSPoint(x: window.frame.width / 2, y: window.frame.height - 1)
    let contentPoint = NSPoint(x: window.frame.width / 2, y: window.contentLayoutRect.midY)
    let down = makeCleanMouseEvent(type: .leftMouseDown, location: titlebarPoint, window: window)
    let drag = makeCleanMouseEvent(type: .leftMouseDragged, location: contentPoint, window: window)
    let up = makeCleanMouseEvent(type: .leftMouseUp, location: contentPoint, window: window)
    let regularContentDown = makeCleanMouseEvent(
      type: .leftMouseDown,
      location: contentPoint,
      window: window
    )

    #expect(forwarder.route(down) == nil)
    #expect(forwarder.route(drag) == nil)
    #expect(forwarder.route(up) == nil)
    #expect(forwarder.route(regularContentDown) === regularContentDown)
    #expect(forwardedTypes == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
  }

  @Test func newContentMouseDownCancelsStaleTitlebarGesture() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    let contentView = try #require(window.contentView)
    let terminalView = NSView(frame: contentView.bounds)
    contentView.addSubview(terminalView)
    CleanWindowConfigurator.configure(window)
    var forwardedTypes: [NSEvent.EventType] = []
    let forwarder = CleanTitlebarMouseForwarder(surfaceView: terminalView) { event in
      forwardedTypes.append(event.type)
    }
    let titlebarPoint = NSPoint(x: window.frame.width / 2, y: window.frame.height - 1)
    let contentPoint = NSPoint(x: window.frame.width / 2, y: window.contentLayoutRect.midY)
    let titlebarDown = makeCleanMouseEvent(
      type: .leftMouseDown, location: titlebarPoint, window: window)
    let contentDown = makeCleanMouseEvent(
      type: .leftMouseDown, location: contentPoint, window: window)
    let contentDrag = makeCleanMouseEvent(
      type: .leftMouseDragged, location: contentPoint, window: window)
    let contentUp = makeCleanMouseEvent(type: .leftMouseUp, location: contentPoint, window: window)

    #expect(forwarder.route(titlebarDown) == nil)
    #expect(forwarder.route(contentDown) === contentDown)
    #expect(forwarder.route(contentDrag) === contentDrag)
    #expect(forwarder.route(contentUp) === contentUp)
    #expect(forwardedTypes == [.leftMouseDown])
  }

  @Test func titlebarForwarderPreservesNativeControlClicks() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    let contentView = try #require(window.contentView)
    let terminalView = NSView(frame: contentView.bounds)
    contentView.addSubview(terminalView)
    let menuButton = HerdrSpacesMenuControl(menuProvider: { NSMenu() })
    menuButton.frame = NSRect(x: 760, y: 570, width: 24, height: 24)
    contentView.addSubview(menuButton)
    CleanWindowConfigurator.configure(window)
    var forwardedTypes: [NSEvent.EventType] = []
    let forwarder = CleanTitlebarMouseForwarder(surfaceView: terminalView) { event in
      forwardedTypes.append(event.type)
    }
    let buttonPoint = NSPoint(x: menuButton.frame.midX, y: menuButton.frame.midY)
    let down = makeCleanMouseEvent(type: .leftMouseDown, location: buttonPoint, window: window)

    #expect(forwarder.route(down) === down)
    #expect(forwardedTypes.isEmpty)
    #expect(menuButton.acceptsFirstMouse(for: down))
  }

  @Test func enteringFullScreenReappliesHiddenTitlebarChrome() async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    let configurationView = CleanWindowConfigurationView()
    window.contentView?.addSubview(configurationView)
    await configurationView.waitForPendingConfiguration()
    let titlebarContainer = try #require(CleanWindowConfigurator.titlebarContainer(in: window))
    titlebarContainer.isHidden = false

    NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    await waitForCleanCondition { titlebarContainer.isHidden }

    #expect(titlebarContainer.isHidden)
  }
}

private func makeCleanMouseEvent(
  type: NSEvent.EventType,
  location: NSPoint,
  window: NSWindow
) -> NSEvent {
  NSEvent.mouseEvent(
    with: type,
    location: location,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    eventNumber: 1,
    clickCount: 1,
    pressure: type == .leftMouseUp ? 0 : 1
  )!
}

private func makeForegroundJob(processGroupID: pid_t, name: String) -> ForegroundJob {
  ForegroundJob(
    processGroupID: processGroupID,
    processes: [
      ForegroundProcess(
        pid: processGroupID,
        name: name,
        argv0: name,
        cmdline: name
      )
    ]
  )
}

@MainActor
private func waitForCleanCondition(
  _ condition: @MainActor @escaping () -> Bool,
  maxIterations: Int = 500
) async {
  for _ in 0..<maxIterations {
    guard !condition() else { return }
    await Task.yield()
  }
}
