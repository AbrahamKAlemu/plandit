import XCTest

@MainActor
final class SavedPlaceExtractionFlowTests: XCTestCase {
    func testVideoCanBeChosenFromPhotos() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startTab", "saved",
            "-startDetent", "large",
        ]
        app.launch()

        app.buttons["Add a link"].tap()

        XCTAssertTrue(app.buttons["choose-video-photos"].waitForExistence(timeout: 5))
    }

    func testPasteConfirmAndRelaunchPersistsPlace() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startTab", "saved",
            "-startDetent", "large",
            "-resetSavedData",
        ]
        app.launch()

        app.buttons["Add a link"].tap()
        let field = app.textFields["social-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Try Levain Bakery on the Upper West Side https://www.tiktok.com/@creator/video/123")
        app.buttons["save-social-link"].tap()

        XCTAssertTrue(app.staticTexts["Places found"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["not-right-place"].exists)
        let confirm = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Confirm Levain Bakery")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["167 W 74th St"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add to today's plan"].exists)
        XCTAssertTrue(app.buttons["remove-saved-place"].isHittable)
        let finish = app.buttons["finish-place-confirmation"]
        XCTAssertTrue(finish.isHittable)
        finish.tap()
        XCTAssertTrue(app.buttons["Add a link"].waitForExistence(timeout: 5))

        let savedRow = app.staticTexts["Levain Bakery"].firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        savedRow.tap()
        XCTAssertTrue(app.buttons["Add to today's plan"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["finish-place-confirmation"].exists)

        app.terminate()
        app.launchArguments = ["-startTab", "saved", "-startDetent", "large"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Levain Bakery"].firstMatch.waitForExistence(timeout: 5))
    }

    func testUnresolvedLinkOffersVideoFallbackInPlace() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startTab", "saved",
            "-startDetent", "large",
            "-resetData",
        ]
        app.launch()

        let unresolved = app.staticTexts["More details needed"].firstMatch
        XCTAssertTrue(unresolved.waitForExistence(timeout: 5))
        unresolved.tap()

        XCTAssertTrue(app.staticTexts["Use the saved video instead"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fallback-video-photos"].exists)
        XCTAssertTrue(app.buttons["fallback-video-files"].exists)
    }

    func testNotRightPlaceOpensNameAndAddressSearch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startTab", "saved",
            "-startDetent", "large",
            "-resetSavedData",
        ]
        app.launch()

        app.buttons["Add a link"].tap()
        let field = app.textFields["social-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Try Levain Bakery https://www.tiktok.com/@creator/video/123")
        app.buttons["save-social-link"].tap()

        let notRight = app.buttons["not-right-place"]
        XCTAssertTrue(notRight.waitForExistence(timeout: 5))
        notRight.tap()

        XCTAssertTrue(app.textFields["place-search-name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["place-search-address"].exists)
        let search = app.buttons["search-for-place"]
        XCTAssertFalse(search.isEnabled)
        app.textFields["place-search-name"].tap()
        app.textFields["place-search-name"].typeText("Levain Bakery")
        XCTAssertTrue(search.isEnabled)
        app.textFields["place-search-address"].tap()
        app.textFields["place-search-address"].typeText("167 W 74th St")
        search.tap()

        XCTAssertTrue(app.staticTexts["Places found"].waitForExistence(timeout: 5))
        let candidates = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Confirm ")
        )
        XCTAssertGreaterThan(candidates.count, 0)
        XCTAssertLessThanOrEqual(candidates.count, 3)
        XCTAssertFalse(app.buttons["Add to today's plan"].exists)
    }
}
