import AppKit
import Testing

@testable import Prowl

@MainActor
struct TitlebarDoubleClickTests {
  @Test func optsInFromMacOS27Point2() {
    #expect(TitlebarDoubleClick.needsOptIn(on: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0)))
    #expect(TitlebarDoubleClick.needsOptIn(on: .init(majorVersion: 27, minorVersion: 3, patchVersion: 1)))
    #expect(TitlebarDoubleClick.needsOptIn(on: .init(majorVersion: 28, minorVersion: 0, patchVersion: 0)))
  }

  @Test func leavesEarlierReleasesUnchanged() {
    #expect(!TitlebarDoubleClick.needsOptIn(on: .init(majorVersion: 26, minorVersion: 4, patchVersion: 0)))
    #expect(!TitlebarDoubleClick.needsOptIn(on: .init(majorVersion: 27, minorVersion: 0, patchVersion: 1)))
    #expect(!TitlebarDoubleClick.needsOptIn(on: .init(majorVersion: 27, minorVersion: 1, patchVersion: 9)))
  }

  @Test func keepsDoubleClickOnTransparentTitlebarWhenTheReleaseNeedsIt() {
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )
    window.titlebarAppearsTransparent = true

    TitlebarDoubleClick.keepEnabled(
      in: window, operatingSystemVersion: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0))

    #expect(window.value(forKey: TitlebarDoubleClick.windowKey) as? Bool == true)
  }

  @Test func doesNotTouchTheWindowOnEarlierReleases() {
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )
    window.titlebarAppearsTransparent = true

    TitlebarDoubleClick.keepEnabled(
      in: window, operatingSystemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 1))

    #expect(window.value(forKey: TitlebarDoubleClick.windowKey) as? Bool == false)
  }
}
