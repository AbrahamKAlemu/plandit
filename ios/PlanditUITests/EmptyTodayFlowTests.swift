import XCTest

/// An empty Today at half height, the height the app opens at: its next step must sit above the
/// tab bar without scrolling, on every iPhone size (run on iPhone 17 Pro, 17e and SE). Run at the
/// default text size: at large sizes scrolling is the intended fallback.
final class EmptyTodayFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Removes every stop from the sample day at full height, then quits so the next launch opens at half height.
    @MainActor private func emptyTheSampleDay() {
        let app = XCUIApplication()
        // Planning from 11:45 PM: the sample saves still open then are too far apart for a suggested
        // plan, so the emptied day shows the empty Today, not suggestion cards.
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-clock", "11:00", "-planStart", "23:45"]
        app.launch()
        XCTAssertTrue(app.buttons["edit-plan"].waitForExistence(timeout: 5))
        let firstStop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stop 1,'")).firstMatch
        var removed = 0
        while firstStop.waitForExistence(timeout: 3), removed < 10 {
            let label = firstStop.label
            firstStop.press(forDuration: 1.2)
            let remove = app.buttons["Remove from plan"]
            XCTAssertTrue(remove.waitForExistence(timeout: 3))
            remove.tap()
            // The removed row stays in the tree during its exit animation: wait it out, or the next
            // press lands on the dying row and opens no menu.
            XCTAssertTrue(app.buttons[label].waitForNonExistence(timeout: 3))
            removed += 1
        }
        XCTAssertTrue(app.staticTexts["Nothing planned yet"].waitForExistence(timeout: 3))
        // Let the emptied day save before quitting.
        sleep(2)
        app.terminate()
    }

    @MainActor private func assertAboveTheTabBar(_ id: String, extraArguments: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-clock", "11:00"] + extraArguments
        app.launch()
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(id) shows", file: file, line: line)

        // XCUITest frames aren't clipped and a 1 pt strip is hittable, so check the layout itself:
        // at the default text size the empty Today fits without falling back to scrolling, and the
        // button lies wholly inside whatever clips it.
        let scrollView = app.scrollViews.containing(.button, identifier: id).firstMatch
        XCTAssertFalse(scrollView.exists, "\(id) fell back to scrolling at half height", file: file, line: line)
        let container = scrollView.exists ? scrollView : app.otherElements["empty-today"]
        XCTAssertTrue(container.exists, file: file, line: line)
        // Frames come back rounded to Float precision; allow a point either way.
        XCTAssertTrue(container.frame.insetBy(dx: -1, dy: -1).contains(button.frame),
                      "\(id) at \(button.frame) runs outside its container at \(container.frame)", file: file, line: line)

        let bar = app.otherElements["tab-bar"]
        XCTAssertTrue(bar.exists, file: file, line: line)
        XCTAssertLessThanOrEqual(button.frame.maxY, bar.frame.minY,
                                 "\(id) ends at \(button.frame.maxY), under the tab bar at \(bar.frame.minY)", file: file, line: line)
        XCTAssertTrue(button.isHittable, file: file, line: line)
    }

    @MainActor func testPlanADayShowsAboveTheTabBarAtHalfHeight() {
        emptyTheSampleDay()
        // The empty Today itself, not the cards: those are checked in SuggestedPlansFlowTests.
        assertAboveTheTabBar("today-plan-a-day", extraArguments: ["-planStart", "23:45"])
    }

    @MainActor func testPasteALinkShowsAboveTheTabBarAtHalfHeight() {
        emptyTheSampleDay()
        // Nothing saved either: the first step is pasting a link.
        assertAboveTheTabBar("today-paste-link", extraArguments: ["-resetSavedData"])
    }
}
