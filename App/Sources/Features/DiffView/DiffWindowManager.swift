import AppKit
import SwiftUI

/// Decides when a `didBecomeKey` notification should trigger a content
/// refresh. Showing the window loads fresh content already, so the focus
/// event caused by the show itself must be swallowed — but only that one:
/// the flag is armed solely when the show is expected to produce a key
/// notification (window not key yet), so a later genuine refocus always
/// refreshes.
nonisolated struct DiffWindowFocusPolicy: Equatable {
  private var skipNextFocusRefresh = false

  mutating func noteShow(windowIsKey: Bool) {
    skipNextFocusRefresh = !windowIsKey
  }

  mutating func shouldRefreshOnBecomeKey() -> Bool {
    if skipNextFocusRefresh {
      skipNextFocusRefresh = false
      return false
    }
    return true
  }
}

@MainActor
final class DiffWindowManager {
  static let shared = DiffWindowManager()

  let state = DiffWindowState()
  private var window: NSWindow?
  private var focusPolicy = DiffWindowFocusPolicy()
  private var localEventMonitor: Any?

  private init() {
    state.onPresentationChange = { [weak self] in
      self?.syncWindowTitle()
    }
  }

  func show(
    worktreeURL: URL,
    branchName: String,
    comparison: DiffComparison = .workingTree,
    outgoingResolver: OutgoingComparisonResolver? = nil,
    resolvedKeybindings: ResolvedKeybindingMap = .appDefaults,
    colorScheme: ColorScheme? = nil
  ) {
    state.load(
      worktreeURL: worktreeURL,
      branchName: branchName,
      comparison: comparison,
      outgoingResolver: outgoingResolver
    )
    let rootView = AnyView(
      DiffWindowContentView(state: state)
        .environment(\.resolvedKeybindings, resolvedKeybindings)
    )

    let appearance = NSAppearance.from(colorScheme)

    if let existingWindow = window {
      if let hostingController = existingWindow.contentViewController as? NSHostingController<AnyView> {
        hostingController.rootView = rootView
      }
      existingWindow.title = windowTitle()
      existingWindow.appearance = appearance
      if existingWindow.isMiniaturized {
        existingWindow.deminiaturize(nil)
      }
      focusPolicy.noteShow(windowIsKey: existingWindow.isKeyWindow)
      existingWindow.makeKeyAndOrderFront(nil)
      return
    }

    let hostingController = NSHostingController(rootView: rootView)

    let newWindow = NSWindow(contentViewController: hostingController)
    newWindow.title = windowTitle()
    newWindow.identifier = NSUserInterfaceItemIdentifier("diff")
    newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    newWindow.tabbingMode = .disallowed
    newWindow.collectionBehavior = [.moveToActiveSpace]
    newWindow.toolbarStyle = .unified
    newWindow.toolbar = NSToolbar(identifier: "DiffToolbar")
    newWindow.isReleasedWhenClosed = false
    newWindow.appearance = appearance
    newWindow.minSize = NSSize(width: 600, height: 400)
    let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame DiffWindow") != nil
    newWindow.setFrameAutosaveName("DiffWindow")
    if !hasSavedFrame {
      newWindow.setContentSize(NSSize(width: 1000, height: 700))
      newWindow.center()
    }

    window = newWindow

    // The observer must exist before the window can become key; registering it
    // after `makeKeyAndOrderFront` misses the initial notification, leaving the
    // armed skip flag to swallow the first genuine refocus instead.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey),
      name: NSWindow.didBecomeKeyNotification,
      object: newWindow,
    )
    focusPolicy.noteShow(windowIsKey: false)
    newWindow.makeKeyAndOrderFront(nil)

    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let window = self.window, window == event.window else { return event }
      if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers == "w"
      {
        window.performClose(nil)
        return nil
      }
      return event
    }
  }

  var hasChanges: Bool {
    !state.changedFiles.isEmpty || state.isLoadingFiles
  }

  private func windowTitle() -> String {
    switch state.mode {
    case .uncommitted:
      return String(localized: "Changes — \(state.branchName)")
    case .outgoing:
      guard let base = state.outgoingBase else {
        return String(localized: "Outgoing Changes — \(state.branchName)")
      }
      return String(localized: "Outgoing Changes — \(state.branchName) vs \(base.displayName)")
    }
  }

  private func syncWindowTitle() {
    window?.title = windowTitle()
  }

  @objc private func windowDidBecomeKey(_ notification: Notification) {
    guard focusPolicy.shouldRefreshOnBecomeKey() else { return }
    state.refresh()
  }
}

extension NSAppearance {
  fileprivate static func from(_ colorScheme: ColorScheme?) -> NSAppearance? {
    switch colorScheme {
    case .none: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    @unknown default: nil
    }
  }
}
