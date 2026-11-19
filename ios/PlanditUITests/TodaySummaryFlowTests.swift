import XCTest

/// Today's stat tiles stay inside the summary card, side by side or one under the other, without
/// running into each other. Run on iPhone SE for a 375 pt screen.
final class TodaySummaryFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// At accessibility text sizes "Directions to …" wraps instead of cutting the place name off,
    /// so the button grows past one line; at the default size it stays one line.
    @MainActor func testDirectionsWrapAtAccessibilitySizes() {
        func directionsHeight(_ extra: [String], screenshot: String? = nil) -> CGFloat {
            let app = XCUIApplication()
            app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-clock", "11:00"] + extra
            app.launch()
            let directions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Directions to'")).firstMatch
            XCTAssertTrue(directions.waitForExistence(timeout: 5))
            if let screenshot {
                // The date, then the Directions button, then the first trips.
                func capture(_ part: String) {
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "\(screenshot)-\(part)"
                    shot.lifetime = .keepAlways
                    add(shot)
                }
                capture("top")
                for _ in 0..<4 where !directions.isHittable { app.swipeUp(velocity: .slow) }
                capture("directions")
                app.swipeUp(velocity: .slow)
                capture("trips")
            }
            return directions.frame.height
        }
        let standard = directionsHeight([])
        let accessibility = directionsHeight(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"],
                                             screenshot: "today-axl")
        XCTAssertLessThan(standard, 60, "one line at the default size")
        XCTAssertGreaterThan(accessibility, standard * 1.5, "the label wraps at AccessibilityXL")
    }

    @MainActor func testStatTilesSitInsideTheCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-clock", "11:00"]
        app.launch()
        let budget = app.buttons["budget-metric"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        let time = app.descendants(matching: .any)["time-metric"]
        let travel = app.descendants(matching: .any)["travel-metric"]
        XCTAssertTrue(time.exists)
        XCTAssertTrue(travel.exists)
        // The card is as wide as the Directions button under it.
        let directions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Directions to'")).firstMatch
        XCTAssertTrue(directions.exists)
        let card = directions.frame

        // Frames come back rounded to Float precision; allow a point either way.
        let tiles = [("time", time.frame), ("budget", budget.frame), ("travel", travel.frame)]
        for (name, frame) in tiles {
            XCTAssertGreaterThanOrEqual(frame.minX, card.minX - 1, "\(name) starts left of the card at \(card.minX): \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 1, "\(name) runs past the card at \(card.maxX): \(frame)")
            XCTAssertLessThanOrEqual(frame.maxY, card.minY + 1, "\(name) runs into the Directions button: \(frame)")
        }
        let sideBySide = abs(time.frame.minY - budget.frame.minY) < 1
        for ((first, a), (second, b)) in zip(tiles, tiles.dropFirst()) {
            if sideBySide {
                XCTAssertLessThanOrEqual(a.maxX, b.minX + 1, "\(first) at \(a) runs into \(second) at \(b)")
            } else {
                XCTAssertLessThanOrEqual(a.maxY, b.minY + 1, "\(first) at \(a) runs into \(second) at \(b)")
            }
        }
    }
}
