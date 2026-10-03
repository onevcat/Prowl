import UIKit
import XCTest

final class ProwlMirror_iOSUITests: XCTestCase {
  @MainActor
  func testHostBoundariesDisableOnlyTheReachedDirection() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-scroll-fixture", "--mirror-ui-scroll-boundary-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let scrollUp = app.buttons["mirror-scroll-up"]
    let scrollDown = app.buttons["mirror-scroll-down"]
    XCTAssertTrue(scrollUp.waitForExistence(timeout: 10))
    func page(_ number: Int) -> XCUIElement {
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote page \(number)\n")).firstMatch
    }
    XCTAssertTrue(scrollUp.isEnabled)
    XCTAssertFalse(scrollDown.isEnabled)
    XCTAssertLessThan(scrollUp.frame.maxY, page(0).frame.minY)
    scrollUp.tap()
    XCTAssertTrue(page(-1).waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUp.isEnabled && scrollDown.isEnabled)
    scrollUp.tap()
    XCTAssertTrue(page(-2).waitForExistence(timeout: 5))
    XCTAssertFalse(scrollUp.isEnabled)
    XCTAssertTrue(scrollDown.isEnabled)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Top controls at Host scroll boundary"
    attachment.lifetime = .keepAlways
    add(attachment)
    scrollDown.tap()
    XCTAssertTrue(page(-1).waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUp.isEnabled && scrollDown.isEnabled)
    scrollDown.tap()
    XCTAssertTrue(page(0).waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUp.isEnabled)
    XCTAssertFalse(scrollDown.isEnabled)
    app.buttons["History"].tap()
    XCTAssertTrue(app.buttons["Load Earlier 200 Lines"].waitForExistence(timeout: 5))
    XCTAssertFalse(scrollUp.exists)
    app.buttons["Live Output"].tap()
    XCTAssertTrue(scrollUp.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUp.isEnabled)
    XCTAssertFalse(scrollDown.isEnabled)
  }

  @MainActor
  func testOldHostKeepsScrollButtonsDisabledAndLocalReaderAvailable() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-scroll-fixture", "--mirror-ui-no-scroll-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let scrollUp = app.buttons["mirror-scroll-up"]
    let scrollDown = app.buttons["mirror-scroll-down"]
    XCTAssertTrue(scrollUp.waitForExistence(timeout: 10))
    XCTAssertFalse(scrollUp.isEnabled)
    XCTAssertFalse(scrollDown.isEnabled)
    let text = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote page 0\n")).firstMatch
    XCTAssertTrue(text.exists)
    XCTAssertLessThan(scrollUp.frame.maxY, text.frame.minY)
    app.scrollViews["mirror-live-scroll"].swipeDown()
    app.scrollViews["mirror-live-scroll"].swipeUp()
    XCTAssertTrue(text.exists)
    XCTAssertTrue(app.buttons["Latest"].isEnabled)
  }

  @MainActor
  func testSelectingTextDoesNotScrollTheHost() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-scroll-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let text = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote page 0\n")).firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 10))
    let start = text.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25))
    start.press(forDuration: 1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 140)))
    XCTAssertTrue(text.exists)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch.exists)
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote page -1\n")).firstMatch.exists)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Text selection leaves Host scroll unchanged"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testRemoteScrollAlwaysRevealsTheTopWhileInteriorDragStaysLocal() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--mirror-ui-fixture", "--mirror-ui-scroll-fixture", "--mirror-ui-scroll-long-fixture",
    ]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let scrollUp = app.buttons["mirror-scroll-up"]
    let reading = app.scrollViews["mirror-live-scroll"]
    XCTAssertTrue(scrollUp.waitForExistence(timeout: 10))
    scrollUp.tap()
    let earlier = app.staticTexts["Remote -1 marker 1"]
    expectation(
      for: NSPredicate { _, _ in
        earlier.exists && earlier.isHittable && earlier.frame.minY >= reading.frame.minY
          && earlier.frame.maxY <= reading.frame.maxY
      }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
    reading.swipeUp()
    let sameScreen = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote -1 marker "))
    XCTAssertTrue(sameScreen.allElementsBoundByIndex.contains { $0.isHittable })
    app.buttons["mirror-scroll-down"].tap()
    let later = app.staticTexts["Remote 0 marker 1"]
    expectation(
      for: NSPredicate { _, _ in
        later.exists && later.isHittable && later.frame.minY >= reading.frame.minY
          && later.frame.maxY <= reading.frame.maxY
      }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
  }

  @MainActor
  func testRemoteScrollShowsLoadingAndKeepsHistoryIndependent() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--mirror-ui-fixture", "--mirror-ui-scroll-fixture", "--mirror-ui-scroll-hold-fixture",
    ]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let scrollUp = app.buttons["mirror-scroll-up"]
    let scrollDown = app.buttons["mirror-scroll-down"]
    let progress = app.descendants(matching: .any).matching(identifier: "mirror-scroll-progress").firstMatch
    XCTAssertTrue(scrollUp.waitForExistence(timeout: 10))
    scrollUp.tap()
    XCTAssertTrue(progress.waitForExistence(timeout: 5))
    XCTAssertFalse(scrollUp.isEnabled)
    XCTAssertFalse(scrollDown.isEnabled)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Remote scroll loading"
    attachment.lifetime = .keepAlways
    add(attachment)
    releaseHeldScrolls()
    let olderPage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote page -1\n")).firstMatch
    XCTAssertTrue(olderPage.waitForExistence(timeout: 8))
    XCTAssertFalse(progress.exists)
    scrollDown.tap()
    XCTAssertTrue(progress.waitForExistence(timeout: 5))
    app.buttons["History"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 202–401"].waitForExistence(timeout: 5))
    XCTAssertFalse(scrollUp.exists)
    // Host confirms the downward scroll while History is open.
    releaseHeldScrolls()
    app.buttons["Load Earlier 200 Lines"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 2–401"].waitForExistence(timeout: 5))
    app.buttons["Live Output"].tap()
    let latestPage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote page 0\n")).firstMatch
    XCTAssertTrue(latestPage.waitForExistence(timeout: 8))
    XCTAssertTrue(scrollUp.isEnabled)
    XCTAssertTrue(scrollDown.isEnabled)
  }

  @MainActor
  func testRemoteScrollButtonsLeaveLocalGesturesAndHistoryUnchanged() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-scroll-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let scrollUp = app.buttons["mirror-scroll-up"]
    let down = app.buttons["mirror-scroll-down"]
    XCTAssertTrue(scrollUp.waitForExistence(timeout: 10))
    XCTAssertTrue(scrollUp.isEnabled)
    func page(_ number: Int) -> XCUIElement {
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote page \(number)\n")).firstMatch
    }
    scrollUp.tap()
    XCTAssertTrue(page(-1).waitForExistence(timeout: 5))
    down.tap()
    XCTAssertTrue(page(0).waitForExistence(timeout: 5))
    XCTAssertLessThan(scrollUp.frame.maxY, page(0).frame.minY)
    let reading = app.scrollViews["mirror-live-scroll"]
    reading.swipeDown()
    XCTAssertTrue(page(0).exists)
    reading.swipeUp()
    XCTAssertTrue(page(0).exists)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Remote scroll controls"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["History"].tap()
    XCTAssertTrue(app.buttons["Load Earlier 200 Lines"].waitForExistence(timeout: 5))
    XCTAssertFalse(scrollUp.exists)
    XCTAssertFalse(down.exists)
    app.buttons["Load Earlier 200 Lines"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 2–401"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testClearingBothPairingHalvesAllowsCredentialReconnect() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    app.launch()
    XCTAssertTrue(app.buttons["Edit Connection"].waitForExistence(timeout: 10))
    app.buttons["Edit Connection"].tap()
    let first = app.textFields["pairing-code-first"]
    let second = app.textFields["pairing-code-second"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    first.tap()
    first.typeText("ABCD")
    second.typeText("2345")
    second.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
    first.tap()
    first.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
    app.buttons["Reconnect"].tap()
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Reconnect"].exists)
  }

  @MainActor
  func testLaunchNavigationKeepsTheConnectionUntilSheetDismissal() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-connection-fixture"]
    app.launch()
    let add = app.buttons["Add Remote Pane"].firstMatch
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    add.tap()
    let launch = app.buttons["new-agent-pane"]
    XCTAssertTrue(launch.waitForExistence(timeout: 5))
    launch.tap()
    let create = app.buttons["create-and-mirror"]
    XCTAssertTrue(create.waitForExistence(timeout: 15))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 15)
    app.navigationBars["New Agent Pane"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(launch.waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertFalse(launch.exists)
    XCTAssertTrue(add.waitForExistence(timeout: 5))
  }

  @MainActor
  func testStructuredAgentLaunchForm() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-launch-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    let create = app.buttons["create-and-mirror"]
    XCTAssertTrue(create.waitForExistence(timeout: 10))
    XCTAssertTrue(create.isEnabled)
    XCTAssertTrue(app.staticTexts["Uses the Host Profile’s model, permissions and launch settings."].exists)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Structured Agent launch"
    attachment.lifetime = .keepAlways
    add(attachment)
    create.tap()
    XCTAssertTrue(app.staticTexts["created-mirror"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSidebarClosesMirrorsWithOneClick() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-multiple-fixtures"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    let closeFirst = app.buttons["close-mirror-UI Fixture"]
    XCTAssertTrue(closeFirst.waitForExistence(timeout: 10))
    closeFirst.tap()
    XCTAssertFalse(closeFirst.exists)
    XCTAssertTrue(app.navigationBars["Second Fixture · Codex"].waitForExistence(timeout: 5))
    app.buttons["close-mirror-Second Fixture"].tap()
    XCTAssertTrue(app.staticTexts["Connect to Prowl"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testPairingCodeUsesTwoEditableHalves() {
    let app = XCUIApplication()
    app.launchArguments += ["--mirror-ui-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["Edit Connection"].waitForExistence(timeout: 10))
    app.buttons["Edit Connection"].tap()
    let first = app.textFields["pairing-code-first"]
    let second = app.textFields["pairing-code-second"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    first.tap()
    first.typeText("k7mp")
    second.typeText("3x9r")
    XCTAssertEqual(first.value as? String, "K7MP")
    XCTAssertEqual((second.value as? String)?.uppercased(), "3X9R")
    first.tap()
    first.typeText(XCUIKeyboardKey.delete.rawValue + "n")
    XCTAssertEqual((first.value as? String)?.uppercased(), "K7MN")
    first.typeText(XCUIKeyboardKey.delete.rawValue + "q")
    XCTAssertEqual((first.value as? String)?.uppercased(), "K7MQ")
    XCTAssertEqual((second.value as? String)?.uppercased(), "3X9R")
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Two-part pairing code"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["Cancel"].tap()
  }

  @MainActor
  func testLargeFrozenTableShowsRowsAndScrolls() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-large-table-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["Expand"].waitForExistence(timeout: 10))
    app.buttons["Expand"].tap()
    XCTAssertTrue(app.navigationBars["Frozen detail"].waitForExistence(timeout: 5))
    let detail = app.scrollViews["mirror-frozen-table"]
    XCTAssertTrue(detail.waitForExistence(timeout: 5))
    let first = detail.staticTexts["Row 0"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(first.isHittable)
    detail.swipeUp()
    let rows = detail.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Row "))
    XCTAssertTrue(
      rows.allElementsBoundByIndex.contains { row in
        let index = Int(row.label.dropFirst(4)) ?? -1
        return index > 10 && row.frame.minY > detail.frame.minY
          && row.frame.maxY < detail.frame.maxY && row.isHittable
      })
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Large frozen table after scrolling"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testPaneSwitchRestoresLiveReadingPosition() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-multiple-fixtures"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    let reading = app.scrollViews["mirror-live-scroll"]
    XCTAssertTrue(reading.waitForExistence(timeout: 10))
    reading.swipeDown()
    let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Live marker "))
    guard
      let anchor = rows.allElementsBoundByIndex.first(where: {
        $0.frame.minY > reading.frame.minY + 20
          && $0.frame.maxY < reading.frame.maxY && $0.isHittable
      })
    else {
      XCTFail("No visible live anchor")
      return
    }
    let label = anchor.label
    let y = anchor.frame.minY
    app.staticTexts["Second Fixture"].tap()
    XCTAssertTrue(app.navigationBars["Second Fixture · Codex"].waitForExistence(timeout: 5))
    app.staticTexts["UI Fixture"].tap()
    let restored = app.staticTexts[label]
    expectation(
      for: NSPredicate { _, _ in
        restored.exists && restored.isHittable && abs(restored.frame.minY - y) < 12
      }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
  }

  @MainActor
  func testPaneSwitchRestoresHistoryReadingPosition() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-multiple-fixtures"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 10))
    app.buttons["History"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 202–401"].waitForExistence(timeout: 5))
    let history = app.scrollViews["mirror-history-scroll"]
    history.swipeUp()
    let rows = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Retained line "))
    guard
      let anchor = rows.allElementsBoundByIndex.first(where: {
        $0.frame.minY > history.frame.minY + 20
          && $0.frame.maxY < history.frame.maxY && $0.isHittable
      })
    else {
      XCTFail("No visible history anchor")
      return
    }
    let label = anchor.label
    let y = anchor.frame.minY
    app.staticTexts["Second Fixture"].tap()
    XCTAssertTrue(app.navigationBars["Second Fixture · Codex"].waitForExistence(timeout: 5))
    app.staticTexts["UI Fixture"].tap()
    XCTAssertTrue(app.buttons["Live Output"].waitForExistence(timeout: 5))
    let restored = app.staticTexts[label]
    expectation(
      for: NSPredicate { _, _ in
        restored.exists && restored.isHittable && abs(restored.frame.minY - y) < 12
      }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
  }

  @MainActor
  func testComposerExpandsOnFocusAndCollapsesWithoutLosingDraft() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input")
      .firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    let collapsedHeight = input.frame.height
    input.tap()
    input.typeText("First line\nSecond line\nThird line")
    XCTAssertGreaterThan(input.frame.height, collapsedHeight)
    app.buttons["mirror-dismiss-keyboard"].tap()
    expectation(
      for: NSPredicate { _, _ in input.frame.height <= collapsedHeight + 2 }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
    input.tap()
    XCTAssertTrue(app.buttons["Send"].isEnabled)
    app.buttons["Send"].tap()
    XCTAssertTrue(app.staticTexts["Host checks Agent readiness when you send."].waitForExistence(timeout: 5))
  }

  @MainActor
  func testMultilineDraftRequiresExplicitSend() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    let wide = NSPredicate { _, _ in app.frame.width > app.frame.height }
    expectation(for: wide, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input")
      .firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
    XCTAssertTrue(app.buttons["mirror-dismiss-keyboard"].waitForExistence(timeout: 5))
    input.typeText("First line\nSecond line")
    XCTAssertTrue(app.buttons["Send"].isEnabled)
    XCTAssertTrue(app.buttons["Send"].isEnabled)
    app.buttons["Send"].tap()
    XCTAssertTrue(app.staticTexts["Host checks Agent readiness when you send."].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Send"].isEnabled)
  }

  @MainActor
  func testReadingHistoryDetailsAndConnectionEditing() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    let wide = NSPredicate { _, _ in app.frame.width > app.frame.height }
    expectation(for: wide, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 10))
    let live = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    live.name = "Fixture live reading"
    live.lifetime = .keepAlways
    add(live)
    app.buttons["Expand"].firstMatch.tap()
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    let detail = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    detail.name = "Fixture frozen code detail"
    detail.lifetime = .keepAlways
    add(detail)
    app.buttons["Done"].tap()
    app.buttons["History"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 202–401"].waitForExistence(timeout: 5))
    app.buttons["Load Earlier 200 Lines"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 2–401"].waitForExistence(timeout: 5))
    let history = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    history.name = "Fixture history paging"
    history.lifetime = .keepAlways
    add(history)
    app.buttons["Live Output"].tap()
    XCTAssertTrue(app.buttons["Expand"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["Edit Connection"].tap()
    let key = app.textFields["pairing-code-first"]
    XCTAssertTrue(key.waitForExistence(timeout: 5))
    key.tap()
    key.typeText("x")
    app.buttons["Reconnect"].tap()
    XCTAssertTrue(
      app.staticTexts[
        "Enter the current 8-character pairing code shown on Host."
      ].waitForExistence(
        timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testConnectionFormRemainsUsableAcrossRotation() {
    let app = XCUIApplication()
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    let wide = NSPredicate { _, _ in app.frame.width > app.frame.height }
    expectation(for: wide, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    let addButton = app.buttons["Add Remote Pane"].firstMatch
    XCTAssertTrue(addButton.waitForExistence(timeout: 10))
    XCTAssertTrue(addButton.isHittable)
    addButton.tap()
    let address = app.textFields["host-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    XCTAssertTrue(address.isHittable)
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unable to access saved"))
        .firstMatch.exists)
    let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    landscape.name = "Landscape connection form"
    landscape.lifetime = .keepAlways
    add(landscape)
    XCUIDevice.shared.orientation = .portrait
    let tall = NSPredicate { _, _ in app.frame.height > app.frame.width }
    expectation(for: tall, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    XCTAssertTrue(address.isHittable)
    let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    portrait.name = "Portrait connection form"
    portrait.lifetime = .keepAlways
    add(portrait)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["Add Remote Pane"].firstMatch.waitForExistence(timeout: 5))
  }

  /// Makes the fixture Host confirm the scrolls that `--mirror-ui-scroll-hold-fixture` holds.
  /// The name matches `MirrorUIFixture.releaseScrollNotification`.
  private func releaseHeldScrolls() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName("com.awhisper.ProwlMirror-iOS.ui-fixture.release-scroll" as CFString), nil, nil,
      true)
  }
}
