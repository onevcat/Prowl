import UIKit
import XCTest

final class ProwlMirror_iOSUITests: XCTestCase {
  // MARK: - Helpers

  /// Opens the pane actions menu and taps one of its items.
  @MainActor
  private func tapPaneAction(_ app: XCUIApplication, _ label: String) {
    app.descendants(matching: .any).matching(identifier: "pane-actions").firstMatch.tap()
    let item = app.buttons[label]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "menu item \(label)")
    item.tap()
  }

  /// The toolbar button that switches Chat and Terminal (docs-ai 089 S2); `label` is the
  /// view it opens.
  @MainActor
  private func segment(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.buttons.matching(identifier: "pane-mode").matching(
      NSPredicate(format: "label == %@", label == "Screen" ? "Terminal" : label)
    ).firstMatch
  }

  @MainActor
  private func paneTitle(_ app: XCUIApplication, contains text: String) -> Bool {
    let title = app.descendants(matching: .any).matching(identifier: "pane-title").firstMatch
    expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: title)
    waitForExpectations(timeout: 5)
    return title.label.contains(text)
  }

  @MainActor
  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func waitForOrientation(_ app: XCUIApplication, wide: Bool) {
    expectation(
      for: NSPredicate { _, _ in wide ? app.frame.width > app.frame.height : app.frame.height > app.frame.width },
      evaluatedWith: nil)
    waitForExpectations(timeout: 10)
  }

  // MARK: - Screen (text-v1)

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
    attach("Top controls at Host scroll boundary")
    scrollDown.tap()
    XCTAssertTrue(page(-1).waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUp.isEnabled && scrollDown.isEnabled)
    scrollDown.tap()
    XCTAssertTrue(page(0).waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUp.isEnabled)
    XCTAssertFalse(scrollDown.isEnabled)
    tapPaneAction(app, "History")
    XCTAssertTrue(app.buttons["Load Earlier 200 Lines"].waitForExistence(timeout: 5))
    XCTAssertFalse(scrollUp.exists)
    tapPaneAction(app, "Live Output")
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
    // The short screen fits, so its end stays in view and there is nothing to return to.
    XCTAssertFalse(app.buttons["mirror-latest"].exists)
  }

  /// The reader follows the newest output while its end is in view. Latest shows only after
  /// scrolling away, not for a drag down at the end, and a tap returns to the end.
  @MainActor
  func testTerminalLatestShowsOnlyAwayFromTheEnd() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-scroll-fixture", "--mirror-ui-scroll-long-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let reading = app.scrollViews["mirror-live-scroll"]
    let latest = app.buttons["mirror-latest"]
    XCTAssertTrue(reading.waitForExistence(timeout: 10))
    XCTAssertFalse(latest.exists)
    reading.swipeUp()
    XCTAssertFalse(latest.waitForExistence(timeout: 2))
    reading.swipeDown(velocity: .fast)
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    attach("Terminal away from the end")
    latest.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: latest)
    waitForExpectations(timeout: 5)
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
    attach("Text selection leaves Host scroll unchanged")
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
    attach("Remote scroll loading")
    releaseHeldScrolls()
    let olderPage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote page -1\n")).firstMatch
    XCTAssertTrue(olderPage.waitForExistence(timeout: 8))
    XCTAssertFalse(progress.exists)
    scrollDown.tap()
    XCTAssertTrue(progress.waitForExistence(timeout: 5))
    tapPaneAction(app, "History")
    XCTAssertTrue(app.staticTexts["Loaded lines 202–401"].waitForExistence(timeout: 5))
    XCTAssertFalse(scrollUp.exists)
    // Host confirms the downward scroll while History is open.
    releaseHeldScrolls()
    app.buttons["Load Earlier 200 Lines"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 2–401"].waitForExistence(timeout: 5))
    tapPaneAction(app, "Live Output")
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
    attach("Remote scroll controls")
    tapPaneAction(app, "History")
    XCTAssertTrue(app.buttons["Load Earlier 200 Lines"].waitForExistence(timeout: 5))
    XCTAssertFalse(scrollUp.exists)
    XCTAssertFalse(down.exists)
    app.buttons["Load Earlier 200 Lines"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 2–401"].waitForExistence(timeout: 5))
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
    attach("Large frozen table after scrolling")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["mirror-scroll-up"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testReadingHistoryDetails() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    waitForOrientation(app, wide: true)
    XCTAssertTrue(app.buttons["Expand"].firstMatch.waitForExistence(timeout: 10))
    attach("Fixture live reading")
    app.buttons["Expand"].firstMatch.tap()
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    attach("Fixture frozen code detail")
    app.buttons["Done"].tap()
    tapPaneAction(app, "History")
    XCTAssertTrue(app.staticTexts["Loaded lines 202–401"].waitForExistence(timeout: 5))
    app.buttons["Load Earlier 200 Lines"].tap()
    XCTAssertTrue(app.staticTexts["Loaded lines 2–401"].waitForExistence(timeout: 5))
    attach("Fixture history paging")
    tapPaneAction(app, "Live Output")
    XCTAssertTrue(app.buttons["Expand"].firstMatch.waitForExistence(timeout: 5))
  }

  // MARK: - Composer

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
    // A delivered message clears the draft; the composer shows no note for a plain success (089 S2).
    expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: app.buttons["Send"])
    waitForExpectations(timeout: 5)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "composer-note").firstMatch.exists)
  }

  /// Send grows with Dynamic Type; the text must end before it (089 S2-R3). Hide Keyboard floats
  /// above the field, away from Send and Stop.
  @MainActor
  func testComposerTextStaysClearOfItsButtonsAtAccessibilitySizes() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--mirror-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    let dismiss = app.buttons["mirror-dismiss-keyboard"]
    XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
    input.typeText("git log --oneline --graph --decorate --all")
    attach("Composer at accessibility size")
    XCTAssertLessThanOrEqual(input.frame.maxX, app.buttons["mirror-send"].frame.minX + 0.5)
    XCTAssertLessThanOrEqual(dismiss.frame.maxY, input.frame.minY)
  }

  @MainActor
  func testMultilineDraftRequiresExplicitSend() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    waitForOrientation(app, wide: true)
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input")
      .firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
    XCTAssertTrue(app.buttons["mirror-dismiss-keyboard"].waitForExistence(timeout: 5))
    input.typeText("First line\nSecond line")
    XCTAssertTrue(app.buttons["Send"].isEnabled)
    app.buttons["Send"].tap()
    expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: app.buttons["Send"])
    waitForExpectations(timeout: 5)
  }

  // MARK: - Conversation (conversation-v1)

  /// Claude Code's visible thinking reads like a reply between the steps, in secondary type.
  @MainActor
  func testVisibleThinkingShowsAsItsOwnRow() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let thought = app.descendants(matching: .any).matching(identifier: "conversation-thought").firstMatch
    let assistant = app.descendants(matching: .any).matching(identifier: "conversation-assistant").firstMatch
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
    for _ in 0..<12 where !(thought.exists && thought.isHittable) {
      app.swipeDown()
    }
    XCTAssertTrue(thought.exists)
    XCTAssertTrue(thought.label.contains("iOS decoder") || app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS 'iOS decoder'")).firstMatch.exists)
    attach("Visible thinking between steps")
  }

  @MainActor
  func testConversationFixtureRendersTheChatAndSwitchesToTheScreen() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let assistant = app.descendants(matching: .any).matching(identifier: "conversation-assistant").firstMatch
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
    let steps = app.descendants(matching: .any).matching(identifier: "conversation-steps").firstMatch
    XCTAssertTrue(steps.waitForExistence(timeout: 5))
    XCTAssertTrue(paneTitle(app, contains: "Idle"))
    attach("Claude conversation, latest")
    segment(app, "Screen").tap()
    XCTAssertTrue(app.buttons["mirror-scroll-up"].waitForExistence(timeout: 5))
    XCTAssertFalse(assistant.exists)
    attach("Same pane as the terminal screen")
    segment(app, "Chat").tap()
    XCTAssertTrue(assistant.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["mirror-scroll-up"].exists)
  }

  /// The chat opens at its end, also when the snapshot arrives late and in batches.
  @MainActor
  func testChatOpensAtTheEndWithoutTheLatestButton() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude", "--mirror-ui-slow-snapshot"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let last = lastChatEntry(app)
    XCTAssertTrue(last.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: last)
    waitForExpectations(timeout: 5)
    XCTAssertFalse(app.buttons["conversation-latest"].exists)
    attach("Chat opened at its end")
  }

  /// Latest shows only away from the end: not for a drag down at the end, and a tap reaches it.
  @MainActor
  func testLatestButtonShowsOnlyAwayFromTheEnd() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let last = lastChatEntry(app)
    XCTAssertTrue(last.waitForExistence(timeout: 10))
    let scroll = app.descendants(matching: .any).matching(identifier: "conversation-scroll").firstMatch
    let latest = app.buttons["conversation-latest"]
    scroll.swipeUp()
    XCTAssertFalse(latest.waitForExistence(timeout: 2))
    scroll.swipeDown(velocity: .fast)
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    attach("Away from the end")
    latest.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: latest)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(last.isHittable)
  }

  /// Hide Keyboard and Latest float in one row above the field, with the same size: Hide Keyboard
  /// at its leading edge, Latest at its trailing edge.
  @MainActor
  func testHideKeyboardAndLatestShareOneRowAboveTheField() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let last = lastChatEntry(app)
    XCTAssertTrue(last.waitForExistence(timeout: 10))
    let scroll = app.descendants(matching: .any).matching(identifier: "conversation-scroll").firstMatch
    let latest = app.buttons["conversation-latest"]
    scroll.swipeDown(velocity: .fast)
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input").firstMatch
    input.tap()
    let dismiss = app.buttons["mirror-dismiss-keyboard"]
    XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
    // Let the keyboard and the row settle before measuring.
    expectation(
      for: NSPredicate { _, _ in abs(dismiss.frame.midY - latest.frame.midY) < 2 }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
    attach("Hide Keyboard and Latest")
    XCTAssertLessThan(dismiss.frame.maxX, latest.frame.minX)
    XCTAssertEqual(dismiss.frame.size.width, latest.frame.size.width, accuracy: 0.5)
    XCTAssertEqual(dismiss.frame.size.height, latest.frame.size.height, accuracy: 0.5)
    XCTAssertLessThan(abs(dismiss.frame.minX - input.frame.minX), 24)
    // The text view ends before Send; Send marks the field's trailing edge.
    XCTAssertLessThan(abs(latest.frame.maxX - app.buttons["mirror-send"].frame.maxX), 24)
    XCTAssertLessThanOrEqual(latest.frame.maxY, input.frame.minY)
    dismiss.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dismiss)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(latest.exists)
  }

  /// A refused message explains why above the field, on its own background, not over the chat.
  @MainActor
  func testRefusedMessageExplainsAboveTheField() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude", "--mirror-ui-refuse-input"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("Run the tests again")
    app.buttons["mirror-send"].tap()
    let note = app.descendants(matching: .any).matching(identifier: "composer-note").firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    XCTAssertTrue(note.label.contains("existing draft"))
    XCTAssertLessThanOrEqual(note.frame.maxY, input.frame.minY)
    attach("Refused message")
  }

  /// A draft in the Mac's input box turns the refusal into a decision: the card shows the draft
  /// and Replace sends the message with the draft stashed on the Mac (docs-ai 090).
  @MainActor
  func testDraftOnTheMacOffersReplaceAndBringHere() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude", "--mirror-ui-refuse-input-draft"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("Run the tests again")
    app.buttons["mirror-send"].tap()
    let card = app.descendants(matching: .any).matching(identifier: "composer-draft-card").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["composer-draft-text"].label.contains("review the tests"))
    XCTAssertTrue(app.buttons["mirror-bring-draft"].isEnabled)
    attach("Draft on the Mac")
    app.buttons["mirror-replace-draft"].tap()
    let note = app.descendants(matching: .any).matching(identifier: "composer-note").firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    XCTAssertTrue(note.label.contains("stashed"))
    XCTAssertFalse(card.exists)
    attach("Replaced and sent")
  }

  /// A message in flight turns Send into a spinner and adds nothing above the field, so the chat
  /// does not jump for each message.
  @MainActor
  func testMessageInFlightKeepsTheLayout() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude", "--mirror-ui-hold-input"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("Run the tests again")
    let send = app.buttons["mirror-send"]
    send.tap()
    expectation(for: NSPredicate(format: "label == %@", "Sending"), evaluatedWith: send)
    waitForExpectations(timeout: 5)
    XCTAssertFalse(send.isEnabled)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "composer-note").firstMatch.exists)
    XCTAssertFalse(app.buttons["Check Receipt"].exists)
    attach("Message in flight")
  }

  /// On a wide screen the chat keeps a readable column, and the composer lines up with it.
  @MainActor
  func testChatKeepsAReadableColumnOnIPad() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide screens only")
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    waitForOrientation(app, wide: true)
    let assistant = app.descendants(matching: .any).matching(identifier: "conversation-assistant").firstMatch
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(assistant.frame.width, 721)
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input").firstMatch
    XCTAssertLessThanOrEqual(input.frame.width, 729)
    // The field leaves room for Send on its right, so check its left edge against the column.
    XCTAssertGreaterThanOrEqual(input.frame.minX, (app.frame.width - 728) / 2)
    attach("Readable chat column")
    XCUIDevice.shared.orientation = .portrait
  }

  /// The recap note that ends the Claude fixture.
  @MainActor
  private func lastChatEntry(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'disable recaps'")).firstMatch
  }

  @MainActor
  func testCodexConversationFixtureRendersTools() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "codex"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let assistant = app.descendants(matching: .any).matching(identifier: "conversation-assistant").firstMatch
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
    XCTAssertTrue(paneTitle(app, contains: "Idle"))
    attach("Codex conversation, latest")
    app.descendants(matching: .any).matching(identifier: "conversation-scroll").firstMatch.swipeDown()
    // Tool calls fold into steps rows; a row opens to one line per call, a line to its details.
    let steps = app.descendants(matching: .any).matching(identifier: "conversation-steps").firstMatch
    XCTAssertTrue(steps.waitForExistence(timeout: 5))
    steps.tap()
    let tool = app.descendants(matching: .any).matching(identifier: "conversation-tool").firstMatch
    XCTAssertTrue(tool.waitForExistence(timeout: 5))
    attach("Codex tool calls unfolded")
    tool.tap()
    XCTAssertTrue(app.staticTexts["Command"].waitForExistence(timeout: 5))
    attach("Codex tool call details")
  }

  @MainActor
  func testModeSwitchRestoresTheScreenReadingPosition() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude", "--mirror-ui-multiple-fixtures"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    waitForOrientation(app, wide: true)
    let assistant = app.descendants(matching: .any).matching(identifier: "conversation-assistant").firstMatch
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
    segment(app, "Screen").tap()
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
    segment(app, "Chat").tap()
    XCTAssertTrue(assistant.waitForExistence(timeout: 5))
    segment(app, "Screen").tap()
    let restored = app.staticTexts[label]
    expectation(
      for: NSPredicate { _, _ in
        restored.exists && restored.isHittable && abs(restored.frame.minY - y) < 12
      }, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
  }

  // MARK: - Hosts and panes

  @MainActor
  func testHostsFlowOpensAPaneFromTheRoster() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-connection-fixture", "--mirror-ui-conversation-fixture", "claude"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    // The app opens on the agents of the only Host (docs-ai 089).
    let pane = app.descendants(matching: .any).matching(identifier: "pane-0F1C2D3E-4A5B-6C7D-8E9F-A0B1C2D3E4F5")
      .firstMatch
    XCTAssertTrue(pane.waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "host-menu").firstMatch.exists)
    attach("Agents of one Host")
    pane.tap()
    let assistant = app.descendants(matching: .any).matching(identifier: "conversation-assistant").firstMatch
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pane-mode").firstMatch.exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(pane.waitForExistence(timeout: 5))
  }

  @MainActor
  func testLaunchSheetKeepsTheRosterUntilDismissal() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-connection-fixture"]
    app.launch()
    let launch = app.buttons["new-agent-pane"]
    XCTAssertTrue(launch.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: launch)
    waitForExpectations(timeout: 10)
    launch.tap()
    let create = app.buttons["create-and-mirror"]
    XCTAssertTrue(create.waitForExistence(timeout: 15))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 15)
    app.buttons["Cancel"].tap()
    XCTAssertFalse(create.waitForExistence(timeout: 2))
    XCTAssertTrue(launch.waitForExistence(timeout: 5))
  }

  @MainActor
  func testStructuredAgentLaunchForm() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-launch-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let create = app.buttons["create-and-mirror"]
    XCTAssertTrue(create.waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Uses the Host Profile’s model, permissions and launch settings."].exists)
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 15)
    attach("Structured launch form")
    create.tap()
    XCTAssertTrue(app.staticTexts["created-mirror"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testPairingCodeUsesTwoEditableHalves() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-connection-fixture", "--mirror-ui-onboarding-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    let add = app.buttons["add-host"]
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    add.tap()
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
    attach("Two-part pairing code")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(add.waitForExistence(timeout: 5))
  }

  @MainActor
  func testAddHostFormRemainsUsableAcrossRotation() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-connection-fixture", "--mirror-ui-onboarding-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    waitForOrientation(app, wide: true)
    let add = app.buttons["add-host"]
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    XCTAssertTrue(add.isHittable)
    add.tap()
    let address = app.textFields["host-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    XCTAssertTrue(address.isHittable)
    attach("Landscape Add Host form")
    XCUIDevice.shared.orientation = .portrait
    waitForOrientation(app, wide: false)
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    XCTAssertTrue(address.isHittable)
    attach("Portrait Add Host form")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(add.waitForExistence(timeout: 5))
  }

  @MainActor
  func testAgentsScreenSummarizesStatesAndFoldsTerminals() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--mirror-ui-connection-fixture", "--mirror-ui-roster-fixture", "--mirror-ui-conversation-fixture", "claude",
    ]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let blocked = app.descendants(matching: .any).matching(identifier: "pane-A1000000-0000-0000-0000-000000000001")
      .firstMatch
    XCTAssertTrue(blocked.waitForExistence(timeout: 10))
    let summary = app.buttons["state-summary-blocked"]
    XCTAssertTrue(summary.exists)
    // VoiceOver reads which agent runs in a row, as the mark shows it.
    XCTAssertTrue(blocked.label.contains("Claude Code"), blocked.label)
    let shell = app.descendants(matching: .any).matching(identifier: "pane-A1000000-0000-0000-0000-000000000005")
      .firstMatch
    XCTAssertFalse(shell.exists)
    attach("Agents grouped like the Mac sidebar")
    app.descendants(matching: .any).matching(identifier: "terminals-toggle").firstMatch.tap()
    XCTAssertTrue(shell.waitForExistence(timeout: 5))
    summary.tap()
    let working = app.descendants(matching: .any).matching(identifier: "pane-A1000000-0000-0000-0000-000000000003")
      .firstMatch
    XCTAssertTrue(working.waitForNonExistence(timeout: 5))
    XCTAssertTrue(blocked.exists)
    attach("Only the blocked agents")
    blocked.tap()
    let assistant = app.descendants(matching: .any).matching(identifier: "conversation-assistant").firstMatch
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
  }

  /// A blocked agent whose prompt the Host did not read as a menu: Chat offers the terminal
  /// screen, where the key bar answers it.
  @MainActor
  func testBlockedChatWithoutAPromptPanelLeadsToTheTerminalKeys() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-conversation-fixture", "claude", "--mirror-ui-blocked-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let answer = app.buttons["pane-blocked-terminal"]
    XCTAssertTrue(answer.waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["pane-blocked-text"].label, "Blocked · Waiting for a permission decision")
    attach("Blocked in Chat")
    answer.tap()
    XCTAssertTrue(app.buttons["key-enter"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["pane-blocked-text"].exists)
    XCTAssertFalse(answer.exists)
    attach("Blocked in Terminal")
  }

  @MainActor
  func testOnboardingLeadsToPairing() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-connection-fixture", "--mirror-ui-onboarding-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let add = app.buttons["add-host"]
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Prowl Mirror"].exists)
    attach("Onboarding")
    add.tap()
    XCTAssertTrue(app.buttons["scan-pairing-qr"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testTerminalKeyBarPressesKeysOnTheHost() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let escape = app.buttons["key-esc"]
    XCTAssertTrue(escape.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["key-shift-tab"].exists)
    attach("Terminal key bar")
    escape.tap()
    app.buttons["key-up"].tap()
    let note = app.descendants(matching: .any).matching(identifier: "composer-note").firstMatch
    XCTAssertFalse(note.waitForExistence(timeout: 2) && note.label.contains("typing"))
  }

  /// A refused key shows under the composer, where a refused Stop shows too (089 review S5-R2).
  @MainActor
  func testRefusedKeysExplainWhyInTheComposer() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-refuse-keys"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let escape = app.buttons["key-esc"]
    XCTAssertTrue(escape.waitForExistence(timeout: 10))
    escape.tap()
    let note = app.descendants(matching: .any).matching(identifier: "composer-note").firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    XCTAssertEqual(note.label, "Someone is typing in this pane on the Mac.")
  }

  /// A working agent takes a message as typed on the Mac, so Send stays and no note says the
  /// message waits (089 S6).
  @MainActor
  func testAWorkingAgentTakesAMessage() {
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-working-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.buttons["mirror-stop"].waitForExistence(timeout: 10))
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input").firstMatch
    input.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
    XCTAssertTrue(app.buttons["mirror-dismiss-keyboard"].waitForExistence(timeout: 5))
    input.typeText("Also check the tests")
    let send = app.buttons["mirror-send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "composer-note").firstMatch.exists)
    attach("Message to a working agent")
    send.tap()
    // The Host confirmed the message, so the draft is cleared.
    expectation(
      for: NSPredicate(format: "NOT (value CONTAINS %@)", "Also check the tests"), evaluatedWith: input)
    waitForExpectations(timeout: 5)
  }

  /// A phone on its side gives the reader no spare height while composing: Latest waits until
  /// the keyboard is down, then returns to the end.
  @MainActor
  func testTerminalLatestHidesWhileComposingOnALandscapePhone() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Compact height only on iPhone")
    let app = XCUIApplication()
    app.launchArguments = ["--mirror-ui-fixture", "--mirror-ui-scroll-fixture", "--mirror-ui-scroll-long-fixture"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let reading = app.scrollViews["mirror-live-scroll"]
    let latest = app.buttons["mirror-latest"]
    XCTAssertTrue(reading.waitForExistence(timeout: 10))
    reading.swipeDown(velocity: .fast)
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    XCUIDevice.shared.orientation = .landscapeLeft
    waitForOrientation(app, wide: true)
    let input = app.descendants(matching: .any).matching(identifier: "mirror-message-input").firstMatch
    input.tap()
    let dismiss = app.buttons["mirror-dismiss-keyboard"]
    XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
    XCTAssertFalse(latest.exists)
    attach("Landscape phone composing")
    dismiss.tap()
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    latest.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: latest)
    waitForExpectations(timeout: 5)
    XCUIDevice.shared.orientation = .portrait
  }

  /// A drag at the local end while a remote scroll is on its way must not turn following back
  /// on: the result shows the new screen's top with Latest, and History keeps that position.
  @MainActor
  func testLocalDragDuringRemoteScrollKeepsTheNewTop() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--mirror-ui-fixture", "--mirror-ui-scroll-fixture", "--mirror-ui-scroll-long-fixture",
      "--mirror-ui-scroll-hold-fixture",
    ]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    let scrollUp = app.buttons["mirror-scroll-up"]
    let reading = app.scrollViews["mirror-live-scroll"]
    XCTAssertTrue(scrollUp.waitForExistence(timeout: 10))
    scrollUp.tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "mirror-scroll-progress").firstMatch
        .waitForExistence(timeout: 5))
    reading.swipeUp()
    releaseHeldScrolls()
    let top = app.staticTexts["Remote -1 marker 1"]
    expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: top)
    waitForExpectations(timeout: 8)
    XCTAssertTrue(app.buttons["mirror-latest"].waitForExistence(timeout: 5))
    tapPaneAction(app, "History")
    XCTAssertTrue(app.buttons["Load Earlier 200 Lines"].waitForExistence(timeout: 5))
    tapPaneAction(app, "Live Output")
    XCTAssertTrue(top.waitForExistence(timeout: 5))
    XCTAssertTrue(top.isHittable)
  }

  /// Makes the fixture Host confirm the scrolls that `--mirror-ui-scroll-hold-fixture` holds.
  /// The name matches `MirrorUIFixture.releaseScrollNotification`.
  private func releaseHeldScrolls() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName("com.onevcat.prowl.mirror.ui-fixture.release-scroll" as CFString), nil, nil,
      true)
  }
}
