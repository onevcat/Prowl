import AppKit

/// Keeps the system titlebar double-click action (zoom, fill, or minimize) on windows
/// that set `titlebarAppearsTransparent`.
///
/// From macOS 27.2, AppKit ignores a double-click on a transparent titlebar unless the window
/// sets `titlebarHandlesDoubleClickWhenTransparent`. That property is not in the public SDK,
/// so this checks that the window responds to it before it uses key-value coding.
/// Earlier releases do not need the property for double-click, but the property also changes
/// which view gets hits in the titlebar area. Thus, it is set only on releases that need it.
enum TitlebarDoubleClick {
  static let windowKey = "titlebarHandlesDoubleClickWhenTransparent"

  static func needsOptIn(on version: OperatingSystemVersion) -> Bool {
    (version.majorVersion, version.minorVersion) >= (27, 2)
  }

  @MainActor
  static func keepEnabled(
    in window: NSWindow,
    operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
  ) {
    guard needsOptIn(on: operatingSystemVersion),
      window.responds(to: NSSelectorFromString(windowKey)),
      window.responds(to: NSSelectorFromString("setTitlebarHandlesDoubleClickWhenTransparent:"))
    else { return }
    // The value lives on the current titlebar container view, which AppKit can rebuild,
    // so read it every time instead of caching it.
    guard window.value(forKey: windowKey) as? Bool != true else { return }
    window.setValue(true, forKey: windowKey)
  }
}
