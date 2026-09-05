import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Testing

@testable import supacode

@MainActor
struct AgentIslandIsolationTests {
  @Test(.dependencies) func panelFollowsTheSettingThroughObservation() async {
    let store: StoreOf<AppFeature> = Store(initialState: AppFeature.State()) {
      Scope(state: \.settings, action: \.settings) {
        BindingReducer()
      }
    }
    let controller = AgentIslandWindowController(
      store: store,
      terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime())
    )

    controller.activate()
    #expect(!controller.isRunning)

    // Each change must be observed without any manual refresh, including after the
    // observation has fired once and re-registered.
    store.send(.settings(.binding(.set(\.agentIslandEnabled, true))))
    await settle { controller.isRunning }
    #expect(controller.isRunning)
    let firstRunningGeneration = controller.observationGeneration

    store.send(.settings(.binding(.set(\.agentIslandEnabled, false))))
    await settle { !controller.isRunning }
    #expect(!controller.isRunning)
    let stoppedGeneration = controller.observationGeneration
    #expect(stoppedGeneration != firstRunningGeneration)

    store.send(.settings(.binding(.set(\.agentIslandEnabled, true))))
    await settle { controller.isRunning }
    #expect(controller.isRunning)
    #expect(controller.observationGeneration != stoppedGeneration)

    controller.stop()
  }

  /// The observer hops to the main actor once before re-reading the setting; yielding lets
  /// that hop run without sleeping.
  private func settle(_ condition: () -> Bool) async {
    for _ in 0..<50 where !condition() {
      await Task.yield()
    }
  }

  @Test func panelOnlyAcceptsKeyboardInputForTheExpandedRoster() {
    let panel = AgentIslandPanel(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 40),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    #expect(!panel.canBecomeKey)
    panel.acceptsKeyboardInput = true
    #expect(panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
  }

  @Test func dedicatedGlobalHotKeyOnlyTogglesTheIsland() {
    #expect(
      AgentIslandHotKeyAction.resolve(
        isRosterExpanded: false,
        hasEntries: true
      ) == .toggleIslandRoster)
    #expect(
      AgentIslandHotKeyAction.resolve(
        isRosterExpanded: true,
        hasEntries: true
      ) == .collapseIsland)
    #expect(
      AgentIslandHotKeyAction.resolve(
        isRosterExpanded: false,
        hasEntries: false
      ) == nil)
  }

  @Test func globalHotKeyConfigurationRegistersOnlyForBackgroundEntries() {
    let binding = Keybinding(
      key: "p",
      modifiers: KeybindingModifiers(command: true, shift: true)
    )
    let registered = AgentIslandGlobalHotKeyConfiguration(
      toggleBinding: binding,
      hasEntries: true,
      isAppActive: false
    )
    let noEntries = AgentIslandGlobalHotKeyConfiguration(
      toggleBinding: binding,
      hasEntries: false,
      isAppActive: false
    )
    let appActive = AgentIslandGlobalHotKeyConfiguration(
      toggleBinding: binding,
      hasEntries: true,
      isAppActive: true
    )
    let unassigned = AgentIslandGlobalHotKeyConfiguration(
      toggleBinding: nil,
      hasEntries: true,
      isAppActive: false
    )
    let appActiveWithChangedBinding = AgentIslandGlobalHotKeyConfiguration(
      toggleBinding: Keybinding(
        key: "j",
        modifiers: .init(command: true, option: true)
      ),
      hasEntries: true,
      isAppActive: true
    )

    #expect(registered.binding == binding)
    #expect(registered.configuredBinding == binding)
    #expect(noEntries.binding == nil)
    #expect(noEntries.configuredBinding == binding)
    #expect(appActive.binding == nil)
    #expect(appActive.configuredBinding == binding)
    #expect(unassigned.binding == nil)
    #expect(unassigned.configuredBinding == nil)
    #expect(registered.requiresRefresh(from: nil))
    #expect(!registered.requiresRefresh(from: registered))
    #expect(registered.requiresRefresh(from: noEntries))
    #expect(appActiveWithChangedBinding.requiresRefresh(from: appActive))
    #expect(registered.requiresRefresh(from: registered, force: true))
  }

  @Test func expandedRosterRecognizesTheAssignedToggleBeforeLocalNavigation() {
    let binding = Keybinding(
      key: "return",
      modifiers: KeybindingModifiers(command: true, option: true)
    )

    #expect(
      AgentIslandShortcutEventMatcher.matches(
        keyCode: 36,
        charactersIgnoringModifiers: nil,
        modifiers: [.command, .option],
        binding: binding
      ))
    #expect(
      !AgentIslandShortcutEventMatcher.matches(
        keyCode: 36,
        charactersIgnoringModifiers: nil,
        modifiers: [.command],
        binding: binding
      ))
    #expect(
      !AgentIslandShortcutEventMatcher.matches(
        keyCode: 36,
        charactersIgnoringModifiers: nil,
        modifiers: [.command, .option],
        binding: nil
      ))
  }

  @Test func expandedRosterKeyMapSupportsArrowsVimiumActivationAndLocalNumbers() {
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 126, characters: nil, modifiers: [])
        == .move(.previous))
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 125, characters: nil, modifiers: [])
        == .move(.next))
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 0, characters: "k", modifiers: [])
        == .move(.previous))
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 0, characters: "j", modifiers: []) == .move(.next)
    )
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 123, characters: nil, modifiers: [])
        == .page(.previous))
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 124, characters: nil, modifiers: [])
        == .page(.next))
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 0, characters: "h", modifiers: [])
        == .page(.previous))
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 0, characters: "l", modifiers: []) == .page(.next)
    )
    #expect(AgentIslandKeyboardCommand.resolve(keyCode: 0, characters: "u", modifiers: []) == nil)
    #expect(AgentIslandKeyboardCommand.resolve(keyCode: 0, characters: "d", modifiers: []) == nil)
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 36, characters: nil, modifiers: [])
        == .activateSelection)
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 49, characters: nil, modifiers: [])
        == .activateSelection)
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 53, characters: nil, modifiers: []) == .collapse)
    #expect(
      AgentIslandKeyboardCommand.resolve(keyCode: 18, characters: "1", modifiers: [])
        == .activateVisibleEntry(0))
    #expect(
      AgentIslandKeyboardCommand.resolve(
        keyCode: 25,
        characters: "9",
        modifiers: [.command, .shift, .option, .control]
      )
        == .activateVisibleEntry(8))
  }

  @Test func eventMonitorsExistOnlyForAVisibleExpandedRoster() {
    #expect(
      !AgentIslandInteractionPolicy.shouldInstallEventMonitors(
        isVisible: false,
        isRosterExpanded: false
      ))
    #expect(
      !AgentIslandInteractionPolicy.shouldInstallEventMonitors(
        isVisible: false,
        isRosterExpanded: true
      ))
    #expect(
      !AgentIslandInteractionPolicy.shouldInstallEventMonitors(
        isVisible: true,
        isRosterExpanded: false
      ))
    #expect(
      AgentIslandInteractionPolicy.shouldInstallEventMonitors(
        isVisible: true,
        isRosterExpanded: true
      ))
  }

  @Test func compactPanelDoesNotRetainExpandedRosterWidth() {
    #expect(
      AgentIslandRootLayout.width(
        notchCompactWidth: nil,
        isRosterExpanded: false,
        attentionEntryCount: 0
      ) == 340)
    #expect(
      AgentIslandRootLayout.width(
        notchCompactWidth: nil,
        isRosterExpanded: false,
        attentionEntryCount: 2
      ) == 380)
    #expect(
      AgentIslandRootLayout.width(
        notchCompactWidth: nil,
        isRosterExpanded: true,
        attentionEntryCount: 0
      ) == 420)
    #expect(
      AgentIslandRootLayout.width(
        notchCompactWidth: 425,
        isRosterExpanded: false,
        attentionEntryCount: 0
      ) == 425)
  }

  @Test func floatingCompactBarUsesTheDisplayMenuBarHeight() {
    #expect(
      AgentIslandRootLayout.compactHeight(
        notchCompactHeight: nil,
        floatingMenuBarHeight: 32
      ) == 32)
    #expect(
      AgentIslandRootLayout.compactHeight(
        notchCompactHeight: 36,
        floatingMenuBarHeight: 32
      ) == 36)
  }

  @Test func rosterDisplayControlRequiresMultipleConnectedDisplays() {
    #expect(!AgentIslandRootLayout.showsDisplayControl(connectedDisplayCount: 0))
    #expect(!AgentIslandRootLayout.showsDisplayControl(connectedDisplayCount: 1))
    #expect(AgentIslandRootLayout.showsDisplayControl(connectedDisplayCount: 2))
  }

  @Test func floatingBarKeepsAStableWidthAndCompactsTheAllStateSummary() {
    #expect(!AgentIslandRootLayout.usesCompactFloatingSummary(stateCount: 3))
    #expect(AgentIslandRootLayout.usesCompactFloatingSummary(stateCount: 4))
    #expect(AgentIslandRootLayout.floatingCompactWidth == 340)
    #expect(
      AgentIslandRootLayout.width(
        notchCompactWidth: nil,
        isRosterExpanded: false,
        attentionEntryCount: 0
      ) == 340)
  }

  @Test func coreAnimationRingStopsForReduceMotionAndIdle() {
    let ring = AgentIslandStateRingView(frame: CGRect(x: 0, y: 0, width: 21, height: 21))

    ring.update(state: .working, reduceMotion: false)
    #expect(ring.isRotationActive)

    ring.update(state: .working, reduceMotion: true)
    #expect(!ring.isRotationActive)

    ring.update(state: .idle, reduceMotion: false)
    #expect(!ring.isRotationActive)
  }

  @Test func compactBarRingUsesOnlyTheStaticStateOutline() {
    let ring = AgentIslandStateRingView(frame: CGRect(x: 0, y: 0, width: 21, height: 21))

    ring.update(state: .working, reduceMotion: false, allowsAnimation: false)

    #expect(!ring.isRotationActive)
    #expect(!ring.isAnimatedRingVisible)
  }
}
