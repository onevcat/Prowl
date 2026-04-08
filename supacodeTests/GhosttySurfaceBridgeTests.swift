import Clocks
import Foundation
import GhosttyKit
import Testing

@testable import supacode

// Serialized: the coalescing tests drive a TestClock with two concurrent
// sleepers (flush + stale watch); parallel execution can race `advance` before
// a task suspends and flake.
@MainActor
@Suite(.serialized)
struct GhosttySurfaceBridgeTests {
  @Test func activeTextReturnsNilWithoutSurfaceView() {
    let bridge = GhosttySurfaceBridge()

    #expect(bridge.readActiveText() == nil)
  }

  @Test func desktopNotificationEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var received: (String, String)?
    bridge.onDesktopNotification = { title, body in
      received = (title, body)
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
    let target = ghostty_target_s()

    "Title".withCString { titlePtr in
      "Body".withCString { bodyPtr in
        action.action.desktop_notification = ghostty_action_desktop_notification_s(
          title: titlePtr,
          body: bodyPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(received?.0 == "Title")
    #expect(received?.1 == "Body")
  }

  @Test func configChangeEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var callbackCount = 0
    bridge.onConfigChange = {
      callbackCount += 1
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_CONFIG_CHANGE
    let target = ghostty_target_s()

    _ = bridge.handleAction(target: target, action: action)

    #expect(callbackCount == 1)
    #expect(bridge.state.configChangeCount == 1)
  }

  @Test func coalescesBurstOfProgressReports() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    // Leading edge applies the first report immediately; the rest coalesce.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 10)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 20)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    #expect(bridge.state.progressValue == 10)
    #expect(callbackCount == 1)

    // One throttle tick flushes only the latest coalesced value.
    await advanceProgressClock(clock, by: .milliseconds(50))
    #expect(bridge.state.progressValue == 50)
    #expect(callbackCount == 2)
  }

  @Test func staleProgressClearsAfterTimeout() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(200)
    )
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)

    // No further reports: the driver synthesizes a REMOVE once the window lapses.
    await advanceProgressClock(clock, by: .milliseconds(200))
    #expect(bridge.state.progressState == nil)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  @Test func continuedReportsKeepProgressAlivePastStaleWindow() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(100)
    )
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    // A long indeterminate run re-fires identical reports; the stale timer must
    // keep resetting even though the value never changes.
    for _ in 0..<6 {
      bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
      await advanceProgressClock(clock, by: .milliseconds(50))
    }
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
  }

  @Test func progressDriverRestartsAfterStaleRemoval() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(100)
    )
    bridge.onProgressReport = { _ in }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    // No further reports: the stale window synthesizes a REMOVE and tears down
    // the driver.
    await advanceProgressClock(clock, by: .milliseconds(100))
    #expect(bridge.state.progressState == nil)

    // A report after the stale REMOVE must re-arm the driver, not freeze.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 30)
    #expect(bridge.state.progressValue == 30)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 60)
    await advanceProgressClock(clock, by: .milliseconds(50))
    #expect(bridge.state.progressValue == 60)
  }

  @Test func determinateValuePaintsPromptlyAfterIdlePeriod() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    bridge.onProgressReport = { _ in }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 10)
    #expect(bridge.state.progressValue == 10)

    // Sit idle well past the throttle window, then a fresh value must paint on
    // its leading edge instead of waiting for a slow idle tick.
    await advanceProgressClock(clock, by: .seconds(1))
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 80)
    #expect(bridge.state.progressValue == 80)
  }

  @Test func identicalReportsNeverReapply() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(callbackCount == 1)

    // A flood of identical reports keeps the bar alive but never re-applies, so
    // the downstream callback fires exactly once across the whole stream.
    for _ in 0..<10 {
      bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
      await advanceProgressClock(clock, by: .milliseconds(50))
    }
    #expect(callbackCount == 1)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
  }

  @Test func removeWinsOverUnappliedTrailingValue() {
    let bridge = GhosttySurfaceBridge(
      clock: TestClock(),
      progressThrottleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var states: [ghostty_action_progress_report_state_e] = []
    bridge.onProgressReport = { states.append($0) }

    // First SET applies on the leading edge; the second sits un-applied in
    // pendingProgress because no throttle tick has fired yet.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 100)
    // REMOVE before the tick drops the trailing 100 and clears.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)

    #expect(bridge.state.progressState == nil)
    #expect(bridge.state.progressValue == nil)
    #expect(states == [GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_REMOVE])
  }

  @Test func openUrlUsesOpenURLHandler() {
    let bridge = GhosttySurfaceBridge()
    var openedURL: URL?
    var openedKind: ghostty_action_open_url_kind_e?
    bridge.openURLHandler = { url, kind in
      openedURL = url
      openedKind = kind
      return true
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_OPEN_URL
    let target = ghostty_target_s()
    let rawURL = "https://example.com/docs"

    rawURL.withCString { urlPtr in
      var openURLAction = ghostty_action_open_url_s()
      openURLAction.kind = GHOSTTY_ACTION_OPEN_URL_KIND_HTML
      openURLAction.url = urlPtr
      openURLAction.len = UInt(rawURL.utf8.count)
      action.action.open_url = openURLAction
      _ = bridge.handleAction(target: target, action: action)
    }

    #expect(openedURL == URL(string: rawURL))
    #expect(openedKind == GHOSTTY_ACTION_OPEN_URL_KIND_HTML)
    #expect(bridge.state.openUrl == rawURL)
    #expect(bridge.state.openUrlKind == GHOSTTY_ACTION_OPEN_URL_KIND_HTML)
  }

  private func advanceProgressClock(_ clock: TestClock<Duration>, by duration: Duration) async {
    // Let background progress tasks register and wake around TestClock advancement.
    await Task.yield()
    await clock.advance(by: duration)
    await Task.yield()
  }
}
