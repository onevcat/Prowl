import AppKit
import ComposableArchitecture
import SwiftUI

@MainActor
@Observable
final class SettingsWindowManager {
  @ObservationIgnored static let shared = SettingsWindowManager()

  private(set) var isOpen: Bool = false

  @ObservationIgnored private var settingsWindow: NSWindow?
  @ObservationIgnored private var makeContent: (() -> AnyView)?
  @ObservationIgnored private var ghosttyShortcuts: GhosttyShortcutManager?
  @ObservationIgnored private var commandKeyObserver: CommandKeyObserver?
  @ObservationIgnored private var localEventMonitor: Any?
  @ObservationIgnored private var willCloseObserver: NSObjectProtocol?

  private init() {}

  internal func configure(
    store: StoreOf<AppFeature>,
    ghosttyShortcuts: GhosttyShortcutManager,
    commandKeyObserver: CommandKeyObserver
  ) {
    makeContent = { AnyView(SettingsView(store: store)) }
    self.ghosttyShortcuts = ghosttyShortcuts
    self.commandKeyObserver = commandKeyObserver
  }

  internal func configure(
    settingsStore: StoreOf<SettingsFeature>,
    updatesStore: StoreOf<UpdatesFeature>,
    ghosttyShortcuts: GhosttyShortcutManager,
    commandKeyObserver: CommandKeyObserver
  ) {
    makeContent = {
      AnyView(SettingsView(settingsStore: settingsStore, updatesStore: updatesStore))
    }
    self.ghosttyShortcuts = ghosttyShortcuts
    self.commandKeyObserver = commandKeyObserver
  }

  func show() {
    if let existingWindow = settingsWindow {
      if existingWindow.isMiniaturized {
        existingWindow.deminiaturize(nil)
      }
      existingWindow.makeKeyAndOrderFront(nil)
      isOpen = true
      return
    }

    guard let makeContent, let ghosttyShortcuts, let commandKeyObserver else {
      return
    }
    let settingsView = makeContent()
      .environment(ghosttyShortcuts)
      .environment(commandKeyObserver)
    let hostingController = NSHostingController(rootView: settingsView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "Settings"
    window.titleVisibility = .hidden
    window.identifier = NSUserInterfaceItemIdentifier(WindowID.settings)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.tabbingMode = .disallowed
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: "SettingsToolbar")
    if #unavailable(macOS 15.0) {
      window.toolbar?.showsBaselineSeparator = false
    }
    window.isReleasedWhenClosed = false
    window.isExcludedFromWindowsMenu = true
    window.setContentSize(NSSize(width: 800, height: 600))
    window.minSize = NSSize(width: 800, height: 500)

    willCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.isOpen = false
      }
    }

    window.center()
    window.makeKeyAndOrderFront(nil)

    settingsWindow = window
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
      guard let window, event.window === window else { return event }
      if SettingsWindowKeyboardShortcutPolicy.isCloseWindowShortcut(
        modifierFlags: event.modifierFlags,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers
      ) {
        window.performClose(nil)
        return nil
      }
      return event
    }
    isOpen = true
  }
}

enum SettingsWindowKeyboardShortcutPolicy {
  static func isCloseWindowShortcut(
    modifierFlags: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String?
  ) -> Bool {
    modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
      && charactersIgnoringModifiers == "w"
  }
}
