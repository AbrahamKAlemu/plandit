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

        let savedRow = app.staticTexts["Levain Bakery"].firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        savedRow.tap()

        XCTAssertTrue(app.staticTexts["best-place-match"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review-extracted-details"].exists)
        let confirm = app.buttons["Confirm Levain Bakery"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["167 W 74th St"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["-startTab", "saved", "-startDetent", "large"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Levain Bakery"].firstMatch.waitForExistence(timeout: 5))
    }
}
