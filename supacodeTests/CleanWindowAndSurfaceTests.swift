import AppKit
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
  }
}
