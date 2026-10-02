import AppKit
import ComposableArchitecture
import SwiftUI

#if DEBUG

  /// Manages the singleton Debug Window. This debug-only auxiliary surface
  /// caches its `NSWindow`, deminiaturises and fronts it on subsequent shows,
  /// and is configured once during app bootstrap with the root store so it can
  /// mirror the user's appearance setting.
  @MainActor
  final class DebugWindowManager {
    static let shared = DebugWindowManager()

    private var window: NSWindow?
    private var store: StoreOf<AppFeature>?

    private init() {}

    func configure(store: StoreOf<AppFeature>) {
      self.store = store
    }

    func show() {
      if let existing = window {
        if existing.isMiniaturized {
          existing.deminiaturize(nil)
        }
        existing.makeKeyAndOrderFront(nil)
        return
      }

      guard let store else { return }
      let host = NSHostingController(rootView: DebugView(store: store))
      let new = NSWindow(contentViewController: host)
      new.title = "Prowl Debug"
      new.identifier = NSUserInterfaceItemIdentifier("debug")
      new.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      new.tabbingMode = .disallowed
      new.collectionBehavior = [.moveToActiveSpace]
      new.toolbarStyle = .unified
      new.toolbar = NSToolbar(identifier: "DebugToolbar")
      if #unavailable(macOS 15.0) {
        new.toolbar?.showsBaselineSeparator = false
      }
      new.isReleasedWhenClosed = false
      new.setContentSize(NSSize(width: 800, height: 600))
      new.minSize = NSSize(width: 700, height: 500)
      new.center()
      new.makeKeyAndOrderFront(nil)
      window = new
    }
  }

#endif
