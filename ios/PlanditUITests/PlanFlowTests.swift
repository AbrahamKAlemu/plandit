import XCTest

/// The + in the tab bar, tapped through like a user would.
final class PlanFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetData", "-startDetent", "large"] + extra
        app.launch()
        return app
    }

    @MainActor private func openPlanner(_ app: XCUIApplication) {
        let plus = app.buttons["plan-button"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(app.navigationBars["Plan a day"].waitForExistence(timeout: 3))
    }

    /// Scrolls the planner until the row is on screen, then taps it.
    @MainActor private func pick(_ name: String, in app: XCUIApplication) {
        let row = app.buttons["pick-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "no row for \(name)")
        var swipes = 0
        while !row.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        row.tap()
        XCTAssertTrue(row.isSelected, "\(name) should be picked")
    }

    @MainActor private func todaySummary(_ text: String, in app: XCUIApplication) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch.waitForExistence(timeout: 5)
    }

    @MainActor func testPlanIsInTheTabBarOnEveryTab() {
        for tab in ["today", "saved", "profile", "settings"] {
            let app = launch(["-startTab", tab])
            XCTAssertTrue(app.buttons["plan-button"].waitForExistence(timeout: 5), "missing on \(tab)")
            XCTAssertEqual(app.buttons["plan-button"].label, "Plan a day")
            app.terminate()
        }
    }

    @MainActor func testStartOverBuildsANewDayFromPickedPlaces() {
        let app = launch()
        XCTAssertTrue(todaySummary("6 stops", in: app))
        openPlanner(app)

        app.buttons["Start over"].tap()
        let build = app.buttons["build-plan"]
        XCTAssertFalse(build.isEnabled, "nothing picked yet")

        pick("Levain Bakery", in: app)
        pick("Little Island", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["preview-stop-2"].waitForExistence(timeout: 2))
        XCTAssertTrue(build.isEnabled)
        build.tap()

        XCTAssertTrue(app.navigationBars["Plan a day"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(todaySummary("2 stops", in: app), "Today shows the new plan")
    }

    @MainActor func testAddToTodayKeepsTheDayAndAddsThePick() {
        let app = launch()
        openPlanner(app)
        XCTAssertTrue(app.buttons["Add to today"].isSelected, "a day in progress defaults to adding")
        pick("Levain Bakery", in: app)
        app.buttons["build-plan"].tap()

        XCTAssertTrue(app.navigationBars["Plan a day"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(todaySummary("7 stops", in: app))
    }

    @MainActor func testCancelLeavesThePlanAlone() {
        let app = launch()
        openPlanner(app)
        app.buttons["Start over"].tap()
        pick("Levain Bakery", in: app)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.navigationBars["Plan a day"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(todaySummary("6 stops", in: app))
    }

    @MainActor func testFreeUntilShowsAnEndTime() {
        let app = launch()
        openPlanner(app)
        let toggle = app.switches["free-until-toggle"]
        var swipes = 0
        while !toggle.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertFalse(app.datePickers["free-until-time"].exists)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.datePickers["free-until-time"].waitForExistence(timeout: 2))
    }

    @MainActor func testPlacesShowWhenTheyWereSaved() {
        let app = launch()
        openPlanner(app)
        XCTAssertTrue(app.buttons["pick-Levain Bakery"].label.contains("Saved yesterday"))
    }

    @MainActor func testBudgetStepperChangesTheBudget() {
        let app = launch()
        openPlanner(app)
        let value = app.staticTexts["budget-value"]
        var swipes = 0
        while !value.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertEqual(value.label, "$60")
        app.steppers.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Increment'")).firstMatch.tap()
        XCTAssertEqual(value.label, "$65")
    }
}
