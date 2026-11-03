import AppKit
import Carbon
import ComposableArchitecture
import SwiftUI

final class AgentIslandPanel: NSPanel {
  var acceptsKeyboardInput = false

  override var canBecomeKey: Bool { acceptsKeyboardInput }
  override var canBecomeMain: Bool { false }
}

enum AgentIslandInteractionPolicy {
  static func shouldInstallEventMonitors(
    isVisible: Bool,
    isRosterExpanded: Bool
  ) -> Bool {
    isVisible && isRosterExpanded
  }
}

@MainActor
@Observable
final class AgentIslandWindowController {
  private let appStore: StoreOf<AppFeature>
  private let terminalManager: WorktreeTerminalManager
  private let injectedDisplayCatalog: AgentIslandDisplayCatalog?
  /// Resolved on first use so a disabled island never enumerates displays or installs the
  /// catalog's screen observer at launch.
  private var displayCatalog: AgentIslandDisplayCatalog {
    injectedDisplayCatalog ?? .shared
  }
  private let presentation = AgentIslandPresentationModel()
  private var panel: AgentIslandPanel?
  private var observers: [NSObjectProtocol] = []
  private var localEventMonitor: Any?
  private var globalEventMonitor: Any?
  private var keyboardLayoutObserver: NSObjectProtocol?
  private var globalHotKeys: AgentIslandGlobalHotKeys?
  private var registeredGlobalHotKeyConfiguration: AgentIslandGlobalHotKeyConfiguration?
  private var registeredVisibilityHotKeyConfiguration: AgentIslandVisibilityHotKeyConfiguration?
  /// Arms the system-wide show/hide shortcut; see `AgentIslandVisibilityHotKeyConfiguration`.
  private(set) var wasIslandEnabledThisSession = false
  private var visibilityObservers: [NSObjectProtocol] = []
  private(set) var observationGeneration = 0
  private var isVisible = false
  private var isRosterExpanded = false
  private var displayPreference: AgentIslandDisplayPreference = .automatic
  private var contentSize = CGSize(width: 420, height: 40)
  private var floatingDragPointerOffsetX: CGFloat?
  private weak var previousKeyWindow: NSWindow?

  init(
    store: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager,
    displayCatalog: AgentIslandDisplayCatalog? = nil
  ) {
    appStore = store
    self.terminalManager = terminalManager
    injectedDisplayCatalog = displayCatalog
  }

  /// Runs the panel only while the setting is on, re-evaluating whenever it changes.
  func activate() {
    refreshLifecycle()
    observeEnabledSetting()
  }

  var isRunning: Bool { panel != nil }

  /// The synchronous half of `activate()`, shared by the observer and by tests.
  func refreshLifecycle() {
    if appStore.settings.agentIslandEnabled {
      armVisibilityHotKey()
      start()
    } else {
      stop()
    }
    refreshVisibilityHotKey()
  }

  private func observeEnabledSetting() {
    withObservationTracking {
      _ = appStore.settings.agentIslandEnabled
    } onChange: { [weak self] in
      // `onChange` fires before the new value lands; hop once so the read below sees it.
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.refreshLifecycle()
        self.observeEnabledSetting()
      }
    }
  }

  func start() {
    guard panel == nil else { return }
    observationGeneration &+= 1
    let generation = observationGeneration
    let panel = AgentIslandPanel(
      contentRect: CGRect(origin: .zero, size: contentSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.identifier = NSUserInterfaceItemIdentifier("agent-island")
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.tabbingMode = .disallowed
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
      .canJoinAllApplications,
    ]

    panel.contentView = NSHostingView(
      rootView: AgentIslandView(
        store: appStore,
        terminalManager: terminalManager,
        presentation: presentation
      ) { [weak self] isVisible, isRosterExpanded, preference, size in
        self?.updatePresentation(
          isVisible: isVisible,
          isRosterExpanded: isRosterExpanded,
          preference: preference,
          size: size
        )
      } floatingDragChanged: { [weak self] event in
        self?.handleFloatingDrag(event)
      }
    )
    self.panel = panel
    installObservers()
    refreshGlobalHotKeys()
    observeGlobalHotKeyState(generation: generation)
    observeFloatingPositions(generation: generation)
    refreshPlacement()
  }

  func stop() {
    observationGeneration &+= 1
    removeObservers()
    removeEventMonitors()
    // The registrar stays alive for the show/hide shortcut; only the roster shortcut goes away.
    _ = globalHotKeys?.register(command: .toggleRoster, binding: nil)
    registeredGlobalHotKeyConfiguration = nil
    setGlobalHotKeyRegistrationFailure(nil, for: AppShortcuts.CommandID.toggleAgentIsland)
    floatingDragPointerOffsetX = nil
    restoreKeyWindowAfterCollapse()
    panel?.orderOut(nil)
    panel = nil
  }

  private func updatePresentation(
    isVisible: Bool,
    isRosterExpanded: Bool,
    preference: AgentIslandDisplayPreference,
    size: CGSize
  ) {
    let wasRosterExpanded = self.isRosterExpanded
    if !wasRosterExpanded, isRosterExpanded, NSApp.isActive {
      previousKeyWindow = NSApp.keyWindow === panel ? mainProwlWindow : NSApp.keyWindow
    }
    self.isVisible = isVisible
    self.isRosterExpanded = isRosterExpanded
    panel?.acceptsKeyboardInput = isRosterExpanded
    if wasRosterExpanded, !isRosterExpanded {
      restoreKeyWindowAfterCollapse()
    }
    displayPreference = preference
    if size.width > 0, size.height > 0 {
      contentSize = size
    }
    updateEventMonitors()
    refreshPlacement()
  }

  private func refreshPlacement() {
    guard let panel else { return }
    guard let screen = resolvedScreen else {
      panel.orderOut(nil)
      return
    }

    let notchSize = screen.notchFrame?.size
    if presentation.notchSize != notchSize {
      presentation.notchSize = notchSize
    }
    let floatingWidth = AgentIslandRootLayout.floatingWidth(screens: displayCatalog.screens)
    if presentation.floatingCompactWidth != floatingWidth {
      presentation.floatingCompactWidth = floatingWidth
    }
    let floatingMenuBarHeight = screen.hasNotch ? nil : screen.menuBarHeight
    if presentation.floatingMenuBarHeight != floatingMenuBarHeight {
      presentation.floatingMenuBarHeight = floatingMenuBarHeight
    }
    let frame = AgentIslandScreenLayout.panelFrame(
      contentSize: contentSize,
      screen: screen,
      floatingHorizontalPosition: appStore.settings.agentIslandFloatingPositions
        .normalizedPosition(for: screen.id)
    )
    setPanelFrame(frame, screen: screen, display: panel.isVisible)
    if isVisible {
      if isRosterExpanded {
        panel.makeKeyAndOrderFront(nil)
      } else {
        panel.orderFrontRegardless()
      }
    } else {
      panel.orderOut(nil)
    }
  }

  private func setPanelFrame(_ frame: CGRect, screen: AgentIslandScreenDescriptor, display: Bool) {
    let barHeight = AgentIslandRootLayout.compactHeight(
      notchCompactHeight: nil,
      floatingMenuBarHeight: screen.menuBarHeight
    )
    let barFrame =
      screen.hasNotch
      ? nil
      : AgentIslandRootLayout.floatingBarScreenFrame(
        in: frame, height: barHeight
      )
    // Publish the final hit region before AppKit refreshes tracking areas for the resized panel.
    if presentation.floatingBarScreenFrame != barFrame {
      presentation.floatingBarScreenFrame = barFrame
    }
    panel?.setFrame(frame, display: display)
  }

  private var mainProwlWindow: NSWindow? {
    NSApplication.shared.windows.first { $0.identifier?.rawValue == WindowID.main }
  }

  private func restoreKeyWindowAfterCollapse() {
    guard panel?.isKeyWindow == true else {
      previousKeyWindow = nil
      return
    }
    if NSApp.isActive {
      let target = previousKeyWindow?.isVisible == true ? previousKeyWindow : mainProwlWindow
      target?.makeKey()
    } else {
      panel?.orderOut(nil)
    }
    previousKeyWindow = nil
  }

  private var resolvedScreen: AgentIslandScreenDescriptor? {
    let mainWindowScreenID = displayCatalog.descriptor(for: mainProwlWindow?.screen)?.id
    let mainScreenID = displayCatalog.descriptor(for: NSScreen.main)?.id
    return AgentIslandScreenLayout.resolve(
      preference: displayPreference,
      screens: displayCatalog.screens,
      mainWindowScreenID: mainWindowScreenID,
      mainScreenID: mainScreenID
    )
  }

  private func handleFloatingDrag(_ event: AgentIslandFloatingDragEvent) {
    guard let panel, let screen = resolvedScreen, !screen.hasNotch else { return }

    let pointerX: CGFloat
    switch event {
    case .began(let pointerX):
      floatingDragPointerOffsetX = panel.frame.midX - pointerX
      return
    case .changed(let currentPointerX), .ended(let currentPointerX):
      pointerX = currentPointerX
    }
    guard let pointerOffsetX = floatingDragPointerOffsetX else { return }

    let requestedAnchorX = pointerX + pointerOffsetX
    let normalizedPosition = Double((requestedAnchorX - screen.frame.minX) / screen.frame.width)
    let frame = AgentIslandScreenLayout.panelFrame(
      contentSize: contentSize,
      screen: screen,
      floatingHorizontalPosition: normalizedPosition
    )
    setPanelFrame(frame, screen: screen, display: true)

    guard case .ended = event else { return }
    floatingDragPointerOffsetX = nil
    let persistedPosition = Double((frame.midX - screen.frame.minX) / screen.frame.width)
    appStore.send(
      .settings(
        .setAgentIslandFloatingPosition(
          displayID: screen.id,
          normalizedPosition: persistedPosition
        )
      )
    )
  }

  private func installObservers() {
    observe(NSApplication.didChangeScreenParametersNotification, object: nil) { [weak self] _ in
      guard let self else { return }
      self.displayCatalog.refresh()
      self.refreshPlacement()
    }
    observe(NSWindow.didMoveNotification, object: nil) { [weak self] windowIdentifier in
      guard let self, windowIdentifier == self.mainProwlWindow.map(ObjectIdentifier.init) else {
        return
      }
      self.refreshPlacement()
    }
    observe(NSWindow.didChangeScreenNotification, object: nil) { [weak self] windowIdentifier in
      guard let self, windowIdentifier == self.mainProwlWindow.map(ObjectIdentifier.init) else {
        return
      }
      self.refreshPlacement()
    }
    observe(NSApplication.didBecomeActiveNotification, object: NSApp) { [weak self] _ in
      self?.refreshGlobalHotKeys()
    }
    observe(NSApplication.didResignActiveNotification, object: NSApp) { [weak self] _ in
      self?.refreshGlobalHotKeys()
    }
    keyboardLayoutObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshGlobalHotKeys(force: true)
      }
    }
  }

  private func observe(
    _ name: Notification.Name,
    object: AnyObject?,
    handler: @escaping @MainActor (ObjectIdentifier?) -> Void
  ) {
    let observer = NotificationCenter.default.addObserver(
      forName: name,
      object: object,
      queue: .main
    ) { notification in
      let windowIdentifier = (notification.object as? NSWindow).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        handler(windowIdentifier)
      }
    }
    observers.append(observer)
  }

  private func removeObservers() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    if let keyboardLayoutObserver {
      DistributedNotificationCenter.default().removeObserver(keyboardLayoutObserver)
      self.keyboardLayoutObserver = nil
    }
  }

  private func installEventMonitors() {
    guard localEventMonitor == nil, globalEventMonitor == nil else { return }
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .keyDown,
    ]) {
      [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown, event.window === panel, isRosterExpanded {
        if AgentIslandShortcutEventMatcher.matches(
          keyCode: event.keyCode,
          charactersIgnoringModifiers: event.charactersIgnoringModifiers,
          modifiers: event.modifierFlags,
          binding: appStore.resolvedKeybindings.keybinding(
            for: AppShortcuts.CommandID.toggleAgentIsland
          )
        ) {
          handleToggleHotKey()
          return nil
        }
        if AgentIslandShortcutEventMatcher.matches(
          keyCode: event.keyCode,
          charactersIgnoringModifiers: event.charactersIgnoringModifiers,
          modifiers: event.modifierFlags,
          binding: appStore.resolvedKeybindings.keybinding(
            for: AppShortcuts.CommandID.toggleAgentIslandVisibility
          )
        ) {
          handleVisibilityHotKey()
          return nil
        }
        if let command = AgentIslandKeyboardCommand.resolve(
          keyCode: event.keyCode,
          characters: event.charactersIgnoringModifiers,
          modifiers: event.modifierFlags
        ) {
          handleKeyboardCommand(command)
        }
        return nil
      }
      if event.window !== panel, isRosterExpanded {
        appStore.send(.repositories(.activeAgents(.islandCollapseRoster)))
      }
      return event
    }
    globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown,
    ]) {
      [weak self] _ in
      Task { @MainActor in
        guard let self, self.isRosterExpanded else { return }
        self.appStore.send(.repositories(.activeAgents(.islandCollapseRoster)))
      }
    }
  }

  private func removeEventMonitors() {
    if let localEventMonitor {
      NSEvent.removeMonitor(localEventMonitor)
      self.localEventMonitor = nil
    }
    if let globalEventMonitor {
      NSEvent.removeMonitor(globalEventMonitor)
      self.globalEventMonitor = nil
    }
  }

  private func handleKeyboardCommand(_ command: AgentIslandKeyboardCommand) {
    let action: ActiveAgentsFeature.Action
    switch command {
    case .collapse:
      action = .islandCollapseRoster
    case .move(let direction):
      action = .islandMoveSelection(direction)
    case .page(let direction):
      action = .islandMovePage(direction)
    case .activateSelection:
      action = .islandActivateSelection
    case .activateVisibleEntry(let index):
      action = .islandActivateVisibleEntry(index)
    }
    appStore.send(.repositories(.activeAgents(action)))
  }

  private func handleGlobalHotKey(_ command: AgentIslandGlobalHotKeyCommand) {
    switch command {
    case .toggleRoster:
      handleToggleHotKey()
    case .toggleVisibility:
      handleVisibilityHotKey()
    }
  }

  private func handleVisibilityHotKey() {
    appStore.send(.repositories(.activeAgents(.islandToggleEnabledTapped)))
  }

  private func handleToggleHotKey() {
    let activeAgents = appStore.repositories.activeAgents
    guard
      let action = AgentIslandHotKeyAction.resolve(
        isRosterExpanded: activeAgents.isIslandRosterExpanded,
        isIslandVisible: shouldShowIsland
      )
    else {
      return
    }
    switch action {
    case .toggleIslandRoster:
      appStore.send(.repositories(.activeAgents(.islandToggleRoster)))
    case .collapseIsland:
      appStore.send(.repositories(.activeAgents(.islandCollapseRoster)))
    }
  }

  private var shouldShowIsland: Bool {
    AgentIslandVisibilityPolicy.isVisible(
      isEnabled: appStore.settings.agentIslandEnabled,
      onlyShowWithAgents: appStore.settings.agentIslandOnlyShowWithAgents,
      hasEntries: !appStore.repositories.activeAgents.entries.isEmpty
    )
  }

  private func refreshGlobalHotKeys(force: Bool = false) {
    let toggleBinding = appStore.resolvedKeybindings.keybinding(
      for: AppShortcuts.CommandID.toggleAgentIsland
    )
    let configuration = AgentIslandGlobalHotKeyConfiguration(
      toggleBinding: toggleBinding,
      isIslandVisible: shouldShowIsland,
      isAppActive: NSApp.isActive
    )
    guard
      configuration.requiresRefresh(
        from: registeredGlobalHotKeyConfiguration,
        force: force
      )
    else { return }
    if registeredGlobalHotKeyConfiguration?.configuredBinding != configuration.configuredBinding {
      setGlobalHotKeyRegistrationFailure(nil, for: AppShortcuts.CommandID.toggleAgentIsland)
    }
    register(
      .toggleRoster,
      binding: configuration.binding,
      commandID: AppShortcuts.CommandID.toggleAgentIsland
    )
    registeredGlobalHotKeyConfiguration = configuration
  }

  private func armVisibilityHotKey() {
    guard !wasIslandEnabledThisSession else { return }
    wasIslandEnabledThisSession = true
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      let observer = NotificationCenter.default.addObserver(
        forName: name,
        object: NSApp,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refreshVisibilityHotKey()
        }
      }
      visibilityObservers.append(observer)
    }
    let layoutObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshVisibilityHotKey(force: true)
      }
    }
    visibilityObservers.append(layoutObserver)
    observeVisibilityHotKeyBinding()
  }

  private func refreshVisibilityHotKey(force: Bool = false) {
    let configuration = AgentIslandVisibilityHotKeyConfiguration(
      visibilityBinding: appStore.resolvedKeybindings.keybinding(
        for: AppShortcuts.CommandID.toggleAgentIslandVisibility
      ),
      wasIslandEnabledThisSession: wasIslandEnabledThisSession,
      isAppActive: NSApp.isActive
    )
    guard
      configuration.requiresRefresh(
        from: registeredVisibilityHotKeyConfiguration,
        force: force
      )
    else { return }
    if registeredVisibilityHotKeyConfiguration?.configuredBinding != configuration.configuredBinding {
      setGlobalHotKeyRegistrationFailure(nil, for: AppShortcuts.CommandID.toggleAgentIslandVisibility)
    }
    register(
      .toggleVisibility,
      binding: configuration.binding,
      commandID: AppShortcuts.CommandID.toggleAgentIslandVisibility
    )
    registeredVisibilityHotKeyConfiguration = configuration
  }

  private func observeVisibilityHotKeyBinding() {
    withObservationTracking {
      _ = appStore.resolvedKeybindings.keybinding(
        for: AppShortcuts.CommandID.toggleAgentIslandVisibility
      )
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.refreshVisibilityHotKey()
        self.observeVisibilityHotKeyBinding()
      }
    }
  }

  private func register(
    _ command: AgentIslandGlobalHotKeyCommand,
    binding: Keybinding?,
    commandID: String
  ) {
    if binding != nil, globalHotKeys == nil {
      globalHotKeys = AgentIslandGlobalHotKeys { [weak self] command in
        self?.handleGlobalHotKey(command)
      }
    }
    let result = globalHotKeys?.register(command: command, binding: binding)
    guard let binding else { return }
    switch result {
    case .registered:
      setGlobalHotKeyRegistrationFailure(nil, for: commandID)
    case .failed, nil:
      setGlobalHotKeyRegistrationFailure(binding, for: commandID)
    case .inactive:
      break
    }
  }

  private func setGlobalHotKeyRegistrationFailure(_ binding: Keybinding?, for commandID: String) {
    guard
      appStore.repositories.activeAgents.islandHotKeyRegistrationFailures[commandID] != binding
    else { return }
    appStore.send(
      .repositories(
        .activeAgents(.setIslandHotKeyRegistrationFailure(commandID: commandID, binding: binding))
      )
    )
  }

  private func observeGlobalHotKeyState(generation: Int) {
    withObservationTracking {
      _ = appStore.resolvedKeybindings.keybinding(
        for: AppShortcuts.CommandID.toggleAgentIsland
      )
      _ = shouldShowIsland
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.panel != nil, self.observationGeneration == generation else { return }
        self.refreshGlobalHotKeys()
        self.observeGlobalHotKeyState(generation: generation)
      }
    }
  }

  private func observeFloatingPositions(generation: Int) {
    withObservationTracking {
      _ = appStore.settings.agentIslandFloatingPositions
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.panel != nil, self.observationGeneration == generation else { return }
        self.refreshPlacement()
        self.observeFloatingPositions(generation: generation)
      }
    }
  }

  private func updateEventMonitors() {
    if AgentIslandInteractionPolicy.shouldInstallEventMonitors(
      isVisible: isVisible,
      isRosterExpanded: isRosterExpanded
    ) {
      installEventMonitors()
    } else {
      removeEventMonitors()
    }
  }
}
