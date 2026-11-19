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

    @MainActor func testSavedLastRowScrollsAboveTheBar() {
        let app = launch(["-startTab", "saved", "-startDetent", "large"])
        // Newest first, so the tram (saved 20 days ago) is the last row.
        let last = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-row-' AND label CONTAINS 'Roosevelt Island Tram'")).firstMatch
        XCTAssertTrue(app.staticTexts["Levain Bakery"].firstMatch.waitForExistence(timeout: 5))
        var swipes = 0
        while !last.exists, swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(last.waitForExistence(timeout: 3))
        UITestScrolling.scrollToEnd(watching: last, in: app)
        UITestScrolling.assertAboveBar(last, in: app)
        XCTAssertTrue(last.isHittable)
    }

    // Pushed screens get the bar's space too. At the largest text size both run past the sheet,
    // so their last button has to scroll up out from under the bar.

    @MainActor func testSavedPostsLastButtonScrollsAboveTheBar() {
        let app = launch(["-startTab", "saved", "-startDetent", "large",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        _ = UITestScrolling.bar(in: app)
        // The list is lazy, and at this size the first rows start below the sheet.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-row-' AND label CONTAINS 'Levain Bakery'")).firstMatch
        var swipes = 0
        while !row.exists, swipes < 10 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        UITestScrolling.scrollIntoView(row, in: app)
        row.tap()

        let remove = app.buttons["remove-saved-place"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        UITestScrolling.scrollToEnd(watching: remove, in: app)
        UITestScrolling.assertAboveBar(remove, in: app)
        XCTAssertTrue(remove.isHittable)
    }

    @MainActor func testProfileSubpagesLastButtonScrollsAboveTheBar() {
        let app = launch(["-startTab", "profile", "-startDetent", "large",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'How it works'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        UITestScrolling.scrollIntoView(row, in: app)
        row.tap()

        let goToSaved = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Go to Saved'")).firstMatch
        XCTAssertTrue(goToSaved.waitForExistence(timeout: 3))
        UITestScrolling.scrollToEnd(watching: goToSaved, in: app)
        UITestScrolling.assertAboveBar(goToSaved, in: app)
        XCTAssertTrue(goToSaved.isHittable)
    }

    /// The bar floats over the sheet: the list runs on under it instead of stopping at its top.
    @MainActor func testSavedListRunsUnderTheFloatingBar() {
        let app = launch(["-startTab", "saved", "-startDetent", "large"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let bar = UITestScrolling.bar(in: app)
        guard let list = app.scrollViews.containing(NSPredicate(format: "identifier BEGINSWITH 'saved-row-'"))
            .allElementsBoundByIndex
            .max(by: { $0.frame.height < $1.frame.height })
        else { return XCTFail("no saved list") }
        XCTAssertGreaterThanOrEqual(list.frame.maxY, bar.frame.maxY - 0.5,
                                    "the list stops at \(list.frame.maxY) pt, above the bar's bottom at \(bar.frame.maxY) pt")
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
            // The list runs on under the floating undo and tab bars, so bring the row out first.
            UITestScrolling.scrollIntoView(row, in: app)
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
