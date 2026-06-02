import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct GhosttySurfaceBridgeTests {
  @Test func activeTextReturnsNilWithoutSurfaceView() {
    let bridge = GhosttySurfaceBridge()

    #expect(bridge.readActiveText() == nil)
  }

  @Test func agentDetectionTextReturnsNilWithoutSurfaceView() {
    let bridge = GhosttySurfaceBridge()

    #expect(bridge.readAgentDetectionText() == nil)
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
}
