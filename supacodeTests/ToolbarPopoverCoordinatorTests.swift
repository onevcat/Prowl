import Clocks
import Testing

@testable import supacode

@MainActor
struct ToolbarPopoverCoordinatorTests {
  @Test func historyToBellIgnoresOldPopoverCallbacksAndTimeout() async {
    let clock = TestClock()
    let popovers = ToolbarPopoverCoordinator(clock: clock)
    popovers.hoverButton(.history, hovering: true)
    popovers.hoverButton(.history, hovering: false)
    popovers.hoverButton(.notifications, hovering: true)
    popovers.hoverPopover(.history, hovering: false)
    popovers.dismiss(.history)
    await clock.advance(by: .seconds(1))
    #expect(popovers.presented == .notifications)
    popovers.hoverButton(.notifications, hovering: false)
    await clock.advance(by: .seconds(1))
    #expect(popovers.presented == nil)
  }

  @Test func enteringPanelCancelsCloseAndPinSurvivesHoverExit() async {
    let clock = TestClock()
    let popovers = ToolbarPopoverCoordinator(clock: clock)
    popovers.hoverButton(.history, hovering: true)
    popovers.hoverButton(.history, hovering: false)
    popovers.hoverPopover(.history, hovering: true)
    await clock.advance(by: .seconds(1))
    #expect(popovers.presented == .history)
    popovers.pin(.history)
    popovers.hoverPopover(.history, hovering: false)
    popovers.hoverButton(.notifications, hovering: true)
    await clock.advance(by: .seconds(1))
    #expect(popovers.presented == .history)
    popovers.toggle(.notifications)
    #expect(popovers.presented == .notifications)
    popovers.dismiss(.history)
    #expect(popovers.presented == .notifications)
    popovers.toggle(.notifications)
    #expect(popovers.presented == nil)
  }

  @Test func lateBellExitCannotClearHistoryHover() async {
    let clock = TestClock()
    let popovers = ToolbarPopoverCoordinator(clock: clock)
    popovers.hoverButton(.notifications, hovering: true)
    popovers.hoverButton(.history, hovering: true)
    popovers.hoverButton(.notifications, hovering: false)
    popovers.hoverPopover(.notifications, hovering: true)
    popovers.dismiss(.notifications)
    await clock.advance(by: .seconds(1))
    #expect(popovers.presented == .history)
    popovers.dismiss(.history)
    #expect(popovers.presented == nil)
  }
}
