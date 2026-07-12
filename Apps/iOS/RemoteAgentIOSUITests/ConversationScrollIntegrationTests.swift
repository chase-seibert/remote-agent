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
