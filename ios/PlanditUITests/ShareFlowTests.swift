import XCTest

/// Shares waiting when Plandit opens, and the screens that find their place. `-seedShares N`
/// queues N sample TikToks the way the share extension does; `-fakeExtraction` stands in for the
/// backend.
final class ShareFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetSavedData"] + extra
        app.launch()
        return app
    }

    @MainActor private func rows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-row-'"))
    }

    // MARK: - PRC-1 opening on new shares

    @MainActor func testOneShareOpensItsPost() {
        let app = launch(["-seedShares", "1", "-fakeExtraction", "pick", "-startDetent", "large"])

        XCTAssertTrue(app.staticTexts["Places found"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["not-right-place"].exists)
        XCTAssertTrue(UITestScrolling.bar(in: app).buttons["Saved"].isSelected)
    }

    @MainActor func testSeveralSharesOpenSavedWithEachOne() {
        let app = launch(["-seedShares", "3", "-fakeExtraction", "pick", "-startDetent", "large"])

        XCTAssertTrue(app.buttons["saved-filter"].waitForExistence(timeout: 10))
        XCTAssertTrue(UITestScrolling.bar(in: app).buttons["Saved"].isSelected)
        let deadline = Date().addingTimeInterval(5)
        while rows(in: app).count < 3, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertEqual(rows(in: app).count, 3)
        XCTAssertFalse(app.staticTexts["Places found"].exists)
    }

    @MainActor func testNoSharesStaysOnToday() {
        let app = launch(["-startTab", "today"])

        let bar = UITestScrolling.bar(in: app)
        XCTAssertTrue(bar.buttons["Today"].isSelected)
        XCTAssertFalse(bar.buttons["Saved"].isSelected)
    }

    @MainActor func testSharesRaiseACollapsedSheet() {
        let app = launch(["-seedShares", "3", "-fakeExtraction", "pick", "-startDetent", "peek"])

        // The list is hidden while the sheet is at its lowest height, so seeing a row means the
        // sheet came up.
        XCTAssertTrue(rows(in: app).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(rows(in: app).firstMatch.isHittable)
    }

    // MARK: - PRC-2 finding the place

    @MainActor func testSlowSearchSaysStillLookingAfterEightSeconds() {
        let app = launch(["-seedShares", "1", "-fakeExtraction", "slow", "-startDetent", "large"])

        let finding = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Finding the place in'")).firstMatch
        XCTAssertTrue(finding.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "post-source").firstMatch.exists, "what was shared shows first")
        XCTAssertFalse(app.staticTexts["still-looking"].exists)
        XCTAssertTrue(app.staticTexts["still-looking"].waitForExistence(timeout: 12))
        XCTAssertTrue(finding.exists)
    }

    // MARK: - PRC-3, W-12 and W-13 when no place turns up

    @MainActor func testFailedSearchSaysWeCouldntFindAPlace() {
        let app = launch(["-seedShares", "1", "-fakeExtraction", "fail", "-startDetent", "large"])

        // One automatic retry after 2 s, then the failure.
        XCTAssertTrue(app.staticTexts["We couldn't find a place"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["retry-extraction"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "We couldn't find a place")).count, 1)

        // Empty search fields, not the caption copied in (W-12).
        let name = app.textFields["place-search-name"]
        XCTAssertTrue(name.exists)
        XCTAssertTrue((name.value as? String ?? "").isEmpty || name.value as? String == name.placeholderValue)
        XCTAssertFalse(app.textViews.firstMatch.exists, "no caption editor")

        // The caption shows without its link.
        XCTAssertTrue(app.staticTexts["“The cookies at Levain Bakery are worth the line”"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'tiktok.com'")).count, 0)

        // Remove sits below what was shared (W-13).
        let remove = app.buttons["remove-saved-place"]
        UITestScrolling.scrollToEnd(watching: remove, in: app)
        // The card's identifier reaches each of its parts; the lowest one is its bottom.
        let sourceParts = app.descendants(matching: .any).matching(identifier: "post-source").allElementsBoundByIndex
        XCTAssertFalse(sourceParts.isEmpty)
        let sourceBottom = sourceParts.map(\.frame.maxY).max() ?? 0
        XCTAssertGreaterThan(remove.frame.minY, sourceBottom)
    }

    @MainActor func testTryAgainSearchesOnceMore() {
        let app = launch(["-seedShares", "1", "-fakeExtraction", "fail", "-startDetent", "large"])

        let retry = app.buttons["retry-extraction"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        retry.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Finding the place in'")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["retry-extraction"].waitForExistence(timeout: 15))
    }

    // MARK: - PRC-7 an exact match is added on its own

    @MainActor func testExactMatchIsReadyToAdd() {
        let app = launch(["-seedShares", "1", "-fakeExtraction", "match", "-startDetent", "large"])

        XCTAssertTrue(app.buttons["Add to today's plan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Levain Bakery"].exists)
        XCTAssertFalse(app.staticTexts["Places found"].exists)
    }

    // MARK: - W-11 adding a link

    @MainActor func testAddLinkKeepsSaveAboveTheKeyboardAndCancelOnTop() {
        let app = launch(["-startTab", "saved", "-startDetent", "large"])

        app.buttons["Add a link"].tap()
        let field = app.textFields["social-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let cancel = app.buttons["cancel-add-link"]
        XCTAssertTrue(cancel.isHittable)
        XCTAssertLessThan(cancel.frame.minY, field.frame.minY, "Cancel is in the top bar")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let save = app.buttons["save-social-link"]
        XCTAssertTrue(save.isHittable)
        XCTAssertLessThanOrEqual(save.frame.maxY, app.keyboards.firstMatch.frame.minY)
    }
}
