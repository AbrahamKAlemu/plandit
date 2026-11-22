import XCTest

/// Friends' answers on the shared plan, in Today (group plans, mode 1). `-fakeSharing -fakeAnswers`
/// stand in for the server: once the link exists, Maya is in and picks Little Island instead of
/// the High Line, Jordan is in and would swap it without a pick, and Sam can't make it.
final class ShareAnswersFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-clock", "11:00", "-fakeSharing", "-fakeAnswers"]
        app.launch()
        return app
    }

    /// Scrolls until the element is in the top part of the screen, clear of the tab bar at the bottom.
    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let limit = app.windows.firstMatch.frame.height * 0.6
        var swipes = 0
        while !element.isHittable || element.frame.maxY > limit, swipes < 10 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    /// GV-9: the swaps toggle is on and the preview lists the saved places before the link exists.
    /// Then the link is made and Today shows the answers (GV-5).
    @MainActor private func shareWithSwaps(_ app: XCUIApplication) {
        let send = app.buttons["send-plan"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        scrollTo(send, in: app)
        send.tap()
        XCTAssertTrue(app.navigationBars["Share plan"].waitForExistence(timeout: 3))

        let swaps = app.switches["share-swaps"]
        XCTAssertTrue(swaps.waitForExistence(timeout: 2))
        XCTAssertEqual(swaps.value as? String, "1", "on by default")
        let preview = app.otherElements["share-swap-preview"].exists ? app.otherElements["share-swap-preview"] : app.staticTexts["share-swap-preview"]
        XCTAssertTrue(preview.exists)
        XCTAssertTrue(preview.label.contains("Instead of The High Line: Little Island"), preview.label)

        app.buttons["share-create-link"].tap()
        XCTAssertTrue(app.staticTexts["share-link-url"].waitForExistence(timeout: 5))
        app.navigationBars["Share plan"].buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Share plan"].waitForNonExistence(timeout: 3))
    }

    @MainActor func testTodayShowsWhoIsInAndSwapItCanBeUndone() {
        let app = launch()
        shareWithSwaps(app)

        let summary = app.buttons["answers-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "Friends' answers: 2 in, 1 can't make it")

        let mark = app.buttons["swap-mark-The High Line"]
        XCTAssertTrue(mark.waitForExistence(timeout: 3))
        XCTAssertEqual(mark.label, "2 friends would swap The High Line")
        scrollTo(mark, in: app)
        mark.tap()

        let swap = app.buttons["swap-it-Little Island"]
        XCTAssertTrue(swap.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Little Island instead'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Maya picked this'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Jordan'")).firstMatch.exists)
        swap.tap()

        // GV-6: the stop is replaced in place, and Undo puts it back.
        let undo = app.staticTexts["undo-message"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertEqual(undo.label, "Swapped The High Line for Little Island")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Stop 3' AND label CONTAINS 'Little Island'")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS 'The High Line'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["swap-mark-The High Line"].exists)

        app.buttons["undo-button"].tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Stop 3' AND label CONTAINS 'The High Line'")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Little Island'")).firstMatch.exists)
    }

    /// "Keep it" keeps the stop and hides the mark.
    @MainActor func testKeepItHidesTheMark() {
        let app = launch()
        shareWithSwaps(app)
        let mark = app.buttons["swap-mark-The High Line"]
        XCTAssertTrue(mark.waitForExistence(timeout: 5))
        scrollTo(mark, in: app)
        mark.tap()
        let keep = app.buttons["keep-it"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        keep.tap()
        XCTAssertTrue(mark.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'The High Line'")).firstMatch.exists, "the stop stays")
    }

    /// GV-7: removing an answer takes it out of Today.
    @MainActor func testRemovingAnAnswer() {
        let app = launch()
        shareWithSwaps(app)
        let summary = app.buttons["answers-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        scrollTo(summary, in: app)
        summary.tap()

        XCTAssertTrue(app.navigationBars["Friends' answers"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Would swap The High Line for Little Island'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Only you can see who can't make it."].exists)
        app.buttons["remove-answer-Sam"].tap()
        // The dialog's button can show up twice in the tree (the sheet and its popover form).
        let confirm = app.buttons["confirm-remove-answer"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.buttons["remove-answer-Sam"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Only you can see who can't make it."].exists)

        app.navigationBars["Friends' answers"].buttons["Close"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertEqual(summary.label, "Friends' answers: 2 in")
    }
}
