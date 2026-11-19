import XCTest

/// An empty Today at half height, the height the app opens at: its next step must sit above the
/// tab bar without scrolling, on every iPhone size (run on iPhone 17 Pro, 17e and SE).
final class EmptyTodayFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Removes every stop from the sample day at full height, then quits so the next launch opens at half height.
    @MainActor private func emptyTheSampleDay() {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-clock", "11:00"]
        app.launch()
        XCTAssertTrue(app.buttons["edit-plan"].waitForExistence(timeout: 5))
        let firstStop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stop 1,'")).firstMatch
        var removed = 0
        while firstStop.waitForExistence(timeout: 3), removed < 10 {
            firstStop.press(forDuration: 1.2)
            let remove = app.buttons["Remove from plan"]
            XCTAssertTrue(remove.waitForExistence(timeout: 3))
            remove.tap()
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
        let bar = app.otherElements["tab-bar"]
        XCTAssertTrue(bar.exists, file: file, line: line)
        XCTAssertLessThanOrEqual(button.frame.maxY, bar.frame.minY,
                                 "\(id) ends at \(button.frame.maxY), under the tab bar at \(bar.frame.minY)", file: file, line: line)
        XCTAssertTrue(button.isHittable, file: file, line: line)
    }

    @MainActor func testPlanADayShowsAboveTheTabBarAtHalfHeight() {
        emptyTheSampleDay()
        assertAboveTheTabBar("today-plan-a-day")
    }

    @MainActor func testPasteALinkShowsAboveTheTabBarAtHalfHeight() {
        emptyTheSampleDay()
        // Nothing saved either: the first step is pasting a link.
        assertAboveTheTabBar("today-paste-link", extraArguments: ["-resetSavedData"])
    }
}
