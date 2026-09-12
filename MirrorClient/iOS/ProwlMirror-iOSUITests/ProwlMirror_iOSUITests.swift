import UIKit
import XCTest

final class ProwlMirror_iOSUITests: XCTestCase {
  @MainActor
  func testStructuredAgentLaunchForm() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-launch-fixture"]
    XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    app.launch()
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
  func testPhoneStartsInDetailAndCanAddConnection() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Phone navigation coverage")
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    XCTAssertTrue(app.staticTexts["Choose a Remote Pane"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Connect to Prowl"].isHittable)
    app.buttons["Add Remote Pane"].tap()
    XCTAssertTrue(app.textFields["host-address"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.staticTexts["Choose a Remote Pane"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSidebarClosesMirrorsWithOneClick() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-multiple-fixtures"]
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
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
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
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
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
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
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
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
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
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
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
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
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
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
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
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
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    let wide = NSPredicate { _, _ in app.frame.width > app.frame.height }
    expectation(for: wide, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    let addButton = app.buttons["add-remote-pane"]
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
    XCTAssertTrue(app.buttons["add-remote-pane"].waitForExistence(timeout: 5))
  }
}
