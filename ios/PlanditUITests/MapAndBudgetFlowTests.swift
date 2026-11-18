import XCTest

/// Changing how you get between stops, and changing what the day costs, tapped through like a user would.
final class MapAndBudgetFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-clock", "11:00"]
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

    @MainActor func testSwitchingATripToDrive() {
        let app = launch()
        // Sample day: stop 3 is the High Line, then a walk to Los Tacos.
        let trip = app.buttons["leg-3"]
        XCTAssertTrue(trip.waitForExistence(timeout: 5))
        scrollTo(trip, in: app)
        XCTAssertTrue(trip.label.contains("Walk"))
        trip.tap()

        XCTAssertTrue(app.navigationBars["Getting there"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["travel-walk"].isSelected)
        XCTAssertTrue(app.buttons["travel-subway"].exists)
        let drive = app.buttons["travel-drive"]
        XCTAssertTrue(drive.label.contains("Arrive"), "each option says when you'd get there")
        drive.tap()
        XCTAssertTrue(drive.isSelected)
        XCTAssertTrue(app.buttons["travel-open-maps"].exists)
        app.buttons["Done"].tap()

        XCTAssertTrue(app.navigationBars["Getting there"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["leg-3"].label.contains("Drive"))
    }

    @MainActor func testTripsAlreadyMadeCannotBeChanged() {
        let app = launch()
        // Stop 1 (done) to stop 2 (now): that trip has happened.
        let trip = app.buttons["leg-1"]
        XCTAssertTrue(trip.waitForExistence(timeout: 5))
        XCTAssertFalse(trip.isEnabled)
    }

    @MainActor func testBudgetSheetShowsEveryStopAndTakesExtras() {
        let app = launch()
        let metric = app.buttons["budget-metric"]
        XCTAssertTrue(metric.waitForExistence(timeout: 5))
        metric.tap()

        XCTAssertTrue(app.navigationBars["Budget"].waitForExistence(timeout: 3))
        let total = app.staticTexts["budget-total"]
        XCTAssertEqual(total.label, "$42 of $60")
        XCTAssertTrue(app.buttons["budget-stop-6"].exists)

        let add = app.buttons["add-cost-item"]
        scrollTo(add, in: app)
        add.tap()
        let name = app.textFields["item-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.tap()
        name.typeText("Snacks")
        // Close the keyboard first: the sheet shifts while it's open, and a second tap can miss.
        app.buttons["keyboard-done"].tap()
        let amount = app.textFields["item-amount"].firstMatch
        scrollTo(amount, in: app)
        amount.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        amount.typeText("8")

        XCTAssertTrue(app.staticTexts["$50 of $60"].waitForExistence(timeout: 3))
    }

    @MainActor func testChangingAStopsTimeAfterPlanning() {
        let app = launch()
        let stop = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Los Tacos'")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        scrollTo(stop, in: app)
        stop.tap()

        let when = app.buttons["stop-time"]
        XCTAssertTrue(when.waitForExistence(timeout: 3))
        XCTAssertTrue(when.label.contains("45 min"))
        when.tap()

        XCTAssertTrue(app.navigationBars["Time"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["time-duration-value"].label, "45 min")
        XCTAssertTrue(app.switches["time-move-later"].exists, "later stops can move with it")
        app.steppers.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Increment'")).firstMatch.tap()
        XCTAssertEqual(app.staticTexts["time-duration-value"].label, "1 hr")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '→'")).firstMatch.exists, "shows which stops move")
        app.buttons["time-save"].tap()

        XCTAssertTrue(app.navigationBars["Time"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["stop-time"].label.contains("1 hr"))
    }

    @MainActor func testReorderingTheStopsAhead() {
        let app = launch()
        let reorder = app.buttons["reorder-stops"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 5))
        scrollTo(reorder, in: app)
        reorder.tap()
        XCTAssertTrue(app.navigationBars["Reorder"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Done or underway"].exists)

        // Drag the High Line below Los Tacos.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'was'")).firstMatch.exists,
                       "nothing moves until you drag")
        let highLine = app.buttons["Reorder Stop 3"]
        let tacos = app.buttons["Reorder Stop 4"]
        XCTAssertTrue(highLine.waitForExistence(timeout: 3))
        highLine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: tacos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.2)))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'was'")).firstMatch.waitForExistence(timeout: 3),
                      "moved stops show their old time")
        app.buttons["reorder-save"].tap()

        XCTAssertTrue(app.navigationBars["Reorder"].waitForNonExistence(timeout: 3))
        let tacosRow = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Los Tacos'")).firstMatch
        let highLineRow = app.buttons.containing(NSPredicate(format: "label CONTAINS 'The High Line'")).firstMatch
        XCTAssertLessThan(tacosRow.frame.minY, highLineRow.frame.minY, "Los Tacos now comes first")
    }

    @MainActor func testAddingASavedPlaceSaysWhereItLanded() {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startTab", "saved", "-startDetent", "large", "-clock", "11:00"]
        app.launch()
        let levain = app.staticTexts["Levain Bakery"].firstMatch
        XCTAssertTrue(levain.waitForExistence(timeout: 5))
        levain.tap()
        let add = app.buttons["Add to today's plan"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let placement = app.staticTexts["today-placement"]
        XCTAssertTrue(placement.waitForExistence(timeout: 3))
        XCTAssertTrue(placement.label.hasPrefix("Stop "), placement.label)
        XCTAssertTrue(app.staticTexts["today-placement-trip"].label.contains("from"))

        // Out of today, still saved.
        app.buttons["remove-from-today"].tap()
        XCTAssertTrue(app.buttons["Add to today's plan"].waitForExistence(timeout: 3))
    }

    @MainActor func testRunningBehindCardCatchesUpWithTheClock() {
        let app = XCUIApplication()
        // 4 PM: the Met, the High Line and Los Tacos are all past their planned times.
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-clock", "16:00"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Running behind?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["catchup-later"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Moving the rest later ends your day at'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Directions to The High Line"].exists, "no directions to a stop the card says you missed")
        app.buttons["catchup-done"].tap()
        XCTAssertTrue(app.staticTexts["Running behind?"].waitForNonExistence(timeout: 3))
        let park = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Washington Square Park'")).firstMatch
        XCTAssertTrue(park.label.hasPrefix("Stop 5, Now"), park.label)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Directions to Joe'")).firstMatch.exists, "directions come back for the next stop")
    }

    @MainActor func testChangingAStopsCost() {
        let app = launch()
        let stop = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Los Tacos'")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        scrollTo(stop, in: app)
        stop.tap()

        let cost = app.buttons["stop-cost"]
        XCTAssertTrue(cost.waitForExistence(timeout: 3))
        scrollTo(cost, in: app)
        cost.tap()

        XCTAssertTrue(app.navigationBars["Cost"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '$15 per person'")).firstMatch.exists, "shows the post's price")
        XCTAssertTrue(app.staticTexts["budget-line"].label.contains("$42 of $60"))
        app.steppers.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Increment'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["budget-line"].label.contains("$43 of $60"))
        XCTAssertTrue(app.buttons["reset-cost"].waitForExistence(timeout: 2), "a changed price can go back to the post's")
    }
}
