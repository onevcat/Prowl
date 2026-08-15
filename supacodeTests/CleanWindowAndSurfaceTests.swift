import AppKit
import ConcurrencyExtras
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct CleanWindowAndSurfaceTests {
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

  @Test func configuresFullSizeWindowWithoutRemovingNativeCapabilities() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )

    CleanWindowConfigurator.configure(window)

    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.styleMask.contains(.titled))
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
