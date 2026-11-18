import XCTest

/// Nothing in the sheet ends up under the bottom bar (W-1): the last thing on each screen scrolls
/// fully above it.
final class SheetLayoutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(_ extra: [String], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-planStart", "11:00"] + (reset ? ["-resetData"] : []) + extra
        app.launch()
        return app
    }

    // MARK: - W-1

    @MainActor func testStopDetailsRemoveButtonScrollsAboveTheBar() {
        let app = launch(["-startDetent", "large"])
        let stop = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Los Tacos'")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        UITestScrolling.scrollIntoView(stop, in: app)
        stop.tap()

        let remove = app.buttons["Remove from plan"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        UITestScrolling.scrollToEnd(watching: remove, in: app)
        UITestScrolling.assertAboveBar(remove, in: app)
        XCTAssertTrue(remove.isHittable)
    }

    @MainActor func testProfileFooterScrollsAboveTheBar() {
        let app = launch(["-startTab", "profile", "-startDetent", "large"])
        let version = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Version'")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        UITestScrolling.scrollToEnd(watching: version, in: app)
        UITestScrolling.assertAboveBar(version, in: app)
    }

    @MainActor func testTodaysLastStopScrollsAboveTheBarAtFullHeight() {
        let app = launch(["-startDetent", "large"])
        let last = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Joe's Pizza")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        UITestScrolling.scrollToEnd(watching: last, in: app)
        UITestScrolling.assertAboveBar(last, in: app)
    }

    @MainActor func testEmptyTodaysPlanButtonIsAboveTheBarAfterExpanding() {
        // Empty the sample day through each stop's menu, then reopen at half height. The first
        // swipe there expands the sheet to full height (the system sheet resizes before it
        // scrolls), so this checks the button at full height. Fitting it at half height without
        // a swipe is the empty state's layout in TodaySheet (slice C).
        var app = launch(["-startDetent", "large"])
        for _ in 0..<6 {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stop '")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "a stop row is left")
            row.press(forDuration: 1.0)
            let remove = app.buttons["Remove from plan"]
            XCTAssertTrue(remove.waitForExistence(timeout: 3))
            remove.tap()
            XCTAssertTrue(remove.waitForNonExistence(timeout: 3))
        }
        app.terminate()

        app = launch(["-startDetent", "medium"], reset: false)
        let plan = app.buttons.matching(NSPredicate(format: "label == 'Plan a day' AND identifier != 'plan-button'")).firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        UITestScrolling.scrollToEnd(watching: plan, in: app)
        UITestScrolling.assertAboveBar(plan, in: app)
        XCTAssertTrue(plan.isHittable)
    }
}

/// Shared by the UI tests that need to reach the end of a sheet or compare frames with the bar.
enum UITestScrolling {
    /// The bottom bar inside the sheet.
    @MainActor static func bar(in app: XCUIApplication) -> XCUIElement {
        let bar = app.descendants(matching: .any)["tab-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no tab bar")
        return bar
    }

    /// Swipes up until the element stops moving, which is the end of the scroll.
    @MainActor static func scrollToEnd(watching element: XCUIElement, in app: XCUIApplication) {
        var last = element.frame.minY
        var still = 0
        for _ in 0..<12 {
            app.swipeUp()
            let now = element.frame.minY
            if abs(now - last) < 1 {
                still += 1
                if still == 2 { return }
            } else {
                still = 0
            }
            last = now
        }
    }

    /// Scrolls until the element is in the top part of the window, clear of the bar.
    @MainActor static func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let limit = app.windows.firstMatch.frame.height * 0.6
        var swipes = 0
        while !element.isHittable || element.frame.maxY > limit, swipes < 10 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    @MainActor static func assertAboveBar(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let top = bar(in: app).frame.minY
        XCTAssertLessThanOrEqual(
            element.frame.maxY, top + 0.5,
            "\(element.label) ends at \(element.frame.maxY) pt; the bar starts at \(top) pt",
            file: file, line: line
        )
    }
}
