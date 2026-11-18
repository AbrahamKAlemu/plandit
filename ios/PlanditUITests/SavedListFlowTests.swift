import XCTest

/// The Saved list's category pictures, Filter and Sort menus, and slim rows, tapped like a user would.
final class SavedListFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startTab", "saved", "-startDetent", "large"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Levain Bakery"].firstMatch.waitForExistence(timeout: 5))
        return app
    }

    /// Opens a Filter or Sort menu with a tap at its center.
    @MainActor private func openMenu(_ control: XCUIElement) {
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor func testTipNamesTikTokAndInstagram() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Save from TikTok and Instagram"].exists)
    }

    @MainActor func testCategoryPictureFiltersAndTappingAgainShowsAll() {
        let app = launch()
        // The sample places cover six groups; nothing is shopping, so Others isn't shown.
        let food = app.buttons["saved-category-food"]
        XCTAssertTrue(food.exists)
        XCTAssertEqual(food.label, "Food, 3 places")
        XCTAssertFalse(app.buttons["saved-category-others"].exists)
        XCTAssertFalse(food.isSelected)

        food.tap()
        XCTAssertTrue(food.isSelected)
        XCTAssertTrue(app.staticTexts["Little Island"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Levain Bakery"].exists)
        XCTAssertTrue(app.staticTexts["Los Tacos No. 1"].exists)

        food.tap()
        XCTAssertFalse(food.isSelected)
        XCTAssertTrue(app.staticTexts["Little Island"].waitForExistence(timeout: 3))
    }

    @MainActor func testFreeOnlyAndOldest() {
        let app = launch()
        let filter = app.buttons["saved-filter"]
        XCTAssertTrue(filter.exists)
        openMenu(filter)
        app.buttons["Free only"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Levain Bakery"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Little Island"].exists)
        XCTAssertTrue(app.staticTexts["The High Line"].exists)
        XCTAssertEqual(filter.value as? String, "Free only")
        XCTAssertTrue(app.staticTexts["Outdoors · Hudson River Park · Free"].exists)

        openMenu(filter)
        app.buttons["All"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Levain Bakery"].waitForExistence(timeout: 3))

        let sort = app.buttons["saved-sort"]
        openMenu(sort)
        app.buttons["Oldest"].firstMatch.tap()
        XCTAssertEqual(sort.value as? String, "Oldest")
        // Oldest first: the tram (saved 20 days ago) comes before Levain (yesterday).
        let tram = app.staticTexts["Roosevelt Island Tram"].firstMatch
        XCTAssertTrue(tram.waitForExistence(timeout: 3))
        XCTAssertLessThan(tram.frame.minY, app.staticTexts["Levain Bakery"].firstMatch.frame.minY)
    }

    @MainActor func testPlusAddsToTodayAndBecomesInPlan() {
        let app = launch()
        let add = app.buttons["Add Little Island to today's plan"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["In plan"].exists, "places already in the sample day read In plan")
        let inPlanBefore = app.staticTexts.matching(identifier: "In plan").count

        add.tap()

        XCTAssertTrue(add.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts.matching(identifier: "In plan").count, inPlanBefore + 1)
        XCTAssertFalse(app.staticTexts["Added"].exists)
    }

    @MainActor func testRowsAreSlimAndStatusesKeepTheName() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Food · Upper West Side"].exists, "no price on the row")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '@uws.snacks'")).firstMatch.exists, "no source line")

        // Smalls needs a check; its status sits beside the full name.
        let smalls = app.staticTexts["Smalls Jazz Club"].firstMatch
        var swipes = 0
        while !smalls.isHittable, swipes < 6 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        let status = app.staticTexts["Check this place"].firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertLessThanOrEqual(smalls.frame.maxX, status.frame.minX)
    }

    /// W-9: the longest sample name sits next to its In plan pill, shown in full and clear of it.
    @MainActor func testALongNameNextToAStatusIsShownInFull() {
        let app = launch()
        let fullName = "The Hungarian Pastry Shop"
        let name = app.staticTexts[fullName].firstMatch
        var swipes = 0
        while !name.isHittable, swipes < 6 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(name.isHittable)
        XCTAssertEqual(name.label, fullName)

        // The In plan pill on the same row: the one whose frame shares the name's vertical span.
        let pills = app.staticTexts.matching(identifier: "In plan").allElementsBoundByIndex
        let pill = pills.first { $0.frame.maxY > name.frame.minY && $0.frame.minY < name.frame.maxY }
        XCTAssertNotNil(pill, "the pastry shop is in the sample day, so its row reads In plan")
        if let pill {
            XCTAssertFalse(name.frame.intersects(pill.frame), "the name doesn't run under the status")
            XCTAssertLessThanOrEqual(name.frame.maxX, pill.frame.minX)
        }
    }
}
