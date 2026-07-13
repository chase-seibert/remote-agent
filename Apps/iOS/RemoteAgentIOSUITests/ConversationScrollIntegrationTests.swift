import XCTest

final class ConversationScrollIntegrationTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testDirectSessionRestorationOpensAtBottom() {
    let app = launch(fixture: "long-conversation")

    assertLatestMessageVisible(in: app)
  }

  func testOpeningLongSessionFromGlobalListOpensAtBottom() {
    let app = launch(fixture: "long-conversation-from-list")

    openLongSession(in: app)
    assertLatestMessageVisible(in: app)
  }

  func testSwitchingFromAnotherSessionOpensLongSessionAtBottom() {
    let app = launch(fixture: "long-conversation-from-session")
    let back = app.buttons["Back to sessions"]
    XCTAssertTrue(back.waitForExistence(timeout: 5))

    back.tap()
    openLongSession(in: app)
    assertLatestMessageVisible(in: app)
  }

  func testDeleteConfirmationUsesCompactActionLabel() {
    let app = launch(fixture: "recent-sessions")
    let session = app.staticTexts["Update project documentation"].firstMatch
    XCTAssertTrue(session.waitForExistence(timeout: 5))

    session.swipeLeft()
    let deleteAction = app.buttons["Delete"].firstMatch
    XCTAssertTrue(deleteAction.waitForExistence(timeout: 2))
    deleteAction.tap()

    let dialog = app.sheets.firstMatch
    XCTAssertTrue(dialog.waitForExistence(timeout: 2))
    XCTAssertTrue(dialog.buttons["Delete"].exists)
    XCTAssertFalse(
      dialog.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete “")).firstMatch
        .exists
    )
  }

  func testConnectionScreenClearlyShowsConnectedMac() {
    let app = launch(fixture: "connection-connected")

    XCTAssertTrue(app.staticTexts["Connected to Mac"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Ready to use Remote Agent on this Mac."].exists)
    XCTAssertTrue(app.descendants(matching: .any)["connection-status-endpoint"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["connection-status-version"].exists)
  }

  func testConnectionScreenClearlyShowsFailureAndRecoveryAction() {
    let app = launch(fixture: "connection-failed")

    XCTAssertTrue(app.staticTexts["Connection Unavailable"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts[
        "The saved Mac did not respond. Make sure it is awake and on the same Wi-Fi."
      ].exists
    )
    XCTAssertTrue(app.descendants(matching: .any)["connection-status-endpoint"].exists)
    XCTAssertTrue(app.buttons["Try Again"].exists)
  }

  func testQueuedPromptOpensEditablePromptSheet() {
    let app = launch(fixture: "prompt-queue")
    let edit = app.buttons["Edit queued prompt"].firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))

    edit.tap()

    XCTAssertTrue(app.navigationBars["Edit Queued Prompt"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.textViews["Queued prompt text"].exists)
    XCTAssertTrue(app.buttons["Save"].exists)
  }

  private func launch(fixture: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["REMOTE_AGENT_FIXTURE"] = fixture
    app.launch()
    return app
  }

  private func openLongSession(in app: XCUIApplication) {
    let session = app.staticTexts["Scroll to latest message"].firstMatch
    XCTAssertTrue(session.waitForExistence(timeout: 5))
    session.tap()
  }

  private func assertLatestMessageVisible(in app: XCUIApplication) {
    let latest = app.descendants(matching: .any)["conversation-last-message"]
    XCTAssertTrue(latest.waitForExistence(timeout: 5))

    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"),
      object: latest
    )
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)

    let first = app.descendants(matching: .any)["conversation-first-message"]
    XCTAssertTrue(first.exists)
    XCTAssertFalse(first.isHittable, "The first message should be above the visible viewport.")
  }
}
