import XCTest

/// D-1, the first-run tutorial. `-showTutorial` counts the `-skipAuth` account as brand-new, so the
/// real decision runs, including the record that it was finished; `-resetTutorial` forgets that record.
///
/// Screenshot passes set `TEST_RUNNER_TUTORIAL_APPEARANCE` (light or dark) and
/// `TEST_RUNNER_TUTORIAL_TEXT_SIZE` (a UIContentSizeCategory name) on `xcodebuild`; the default is
/// light at the simulator's text size.
final class TutorialFlowTests: XCTestCase {
    private let pages = [
        ("Share the saved places you want to visit", "Add a place from Instagram or TikTok."),
        ("Tell us what you want your day to look like", "Pick your saved places, then set your time and budget."),
        ("Get a plan for your day", "See your stops in order and how to get between them."),
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor private func launch(_ arguments: [String], textSize: String? = nil) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        var display = ["-plandit.appearanceMode", environment["TUTORIAL_APPEARANCE"] ?? "light"]
        if let size = textSize ?? environment["TUTORIAL_TEXT_SIZE"] {
            display += ["-UIPreferredContentSizeCategoryName", size]
        }
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth"] + arguments + display
        app.launch()
        return app
    }

    @MainActor private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let hittable = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    @MainActor func testSkipOnTheFirstPageOpensTheMapAndARelaunchDoesNotRepeatIt() {
        let app = launch(["-resetTutorial", "-showTutorial"])
        let skip = app.buttons["tutorial-skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(app.staticTexts["tutorial-title-1"]))
        XCTAssertFalse(app.buttons["plan-button"].exists, "the tutorial comes before the map")

        skip.tap()
        XCTAssertTrue(app.buttons["plan-button"].waitForExistence(timeout: 5), "Skip goes straight to the map")
        XCTAssertFalse(skip.exists)

        // Still counted as a brand-new account, but this phone remembers it was finished.
        app.terminate()
        let relaunched = launch(["-showTutorial"])
        XCTAssertTrue(relaunched.buttons["plan-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(relaunched.buttons["tutorial-skip"].exists, "a relaunch never repeats the tutorial")
    }

    @MainActor func testSkipOnTheSecondPageOpensTheMapAndARelaunchDoesNotRepeatIt() {
        skipsFromPage(2)
    }

    @MainActor func testSkipOnTheLastPageOpensTheMapAndARelaunchDoesNotRepeatIt() {
        skipsFromPage(3)
    }

    /// Continue to `number`, then one tap on Skip closes the whole tutorial for good.
    @MainActor private func skipsFromPage(_ number: Int) {
        let app = launch(["-resetTutorial", "-showTutorial"])
        let continueButton = app.buttons["tutorial-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        for earlier in 1..<number {
            XCTAssertTrue(waitUntilHittable(app.staticTexts["tutorial-title-\(earlier)"]))
            continueButton.tap()
        }
        XCTAssertTrue(waitUntilHittable(app.staticTexts["tutorial-title-\(number)"]), "on page \(number)")

        app.buttons["tutorial-skip"].tap()
        XCTAssertTrue(app.buttons["plan-button"].waitForExistence(timeout: 5), "Skip goes straight to the map")
        XCTAssertFalse(app.buttons["tutorial-skip"].exists)

        app.terminate()
        let relaunched = launch(["-showTutorial"])
        XCTAssertTrue(relaunched.buttons["plan-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(relaunched.buttons["tutorial-skip"].exists, "a relaunch never repeats the tutorial")
    }

    @MainActor func testContinueWalksThroughThreePagesThenOpensTheMap() {
        let app = launch(["-resetTutorial", "-showTutorial"])
        let continueButton = app.buttons["tutorial-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertEqual(continueButton.label, "Continue")

        for (index, page) in pages.enumerated() {
            let number = index + 1
            let title = app.staticTexts["tutorial-title-\(number)"]
            XCTAssertTrue(waitUntilHittable(title), "page \(number) is on screen")
            XCTAssertEqual(title.label, page.0)
            XCTAssertEqual(title.value as? String, "Page \(number) of 3", "VoiceOver hears the page number")
            XCTAssertEqual(app.staticTexts["tutorial-subtitle-\(number)"].label, page.1)
            XCTAssertTrue(continueButton.isHittable, "Continue stays reachable")

            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "tutorial-page-\(number)"
            shot.lifetime = .keepAlways
            add(shot)

            continueButton.tap()
        }
        XCTAssertTrue(app.buttons["plan-button"].waitForExistence(timeout: 5), "the last Continue opens the map")
        XCTAssertFalse(continueButton.exists)
    }

    /// A second tap while the page is still turning must not skip the next page unread.
    @MainActor func testADoubleTapOnContinueTurnsOnePage() {
        let app = launch(["-resetTutorial", "-showTutorial"])
        let continueButton = app.buttons["tutorial-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(app.staticTexts["tutorial-title-1"]))

        continueButton.doubleTap()
        XCTAssertTrue(waitUntilHittable(app.staticTexts["tutorial-title-2"]), "page 2, not page 3")
        XCTAssertFalse(app.staticTexts["tutorial-title-3"].isHittable)

        continueButton.doubleTap()
        XCTAssertTrue(waitUntilHittable(app.staticTexts["tutorial-title-3"]), "page 3 is shown, not skipped")
        XCTAssertFalse(app.buttons["plan-button"].exists, "still in the tutorial")

        continueButton.tap()
        XCTAssertTrue(app.buttons["plan-button"].waitForExistence(timeout: 5))
    }

    /// At the largest accessibility text size the words come first: the drawing steps aside.
    @MainActor func testAtTheLargestTextSizeTheWordsSitAboveContinue() {
        let app = launch(["-resetTutorial", "-showTutorial"], textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let continueButton = app.buttons["tutorial-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))

        for number in 1...3 {
            let title = app.staticTexts["tutorial-title-\(number)"]
            XCTAssertTrue(waitUntilHittable(title), "page \(number)")
            XCTAssertLessThanOrEqual(title.frame.maxY, continueButton.frame.minY, "page \(number): the whole title is above Continue")
            XCTAssertLessThan(app.staticTexts["tutorial-subtitle-\(number)"].frame.minY, continueButton.frame.minY, "page \(number): the subtitle starts above it")
            if number < 3 { continueButton.tap() }
        }
    }

    @MainActor func testSwipeMovesForward() {
        let app = launch(["-resetTutorial", "-showTutorial"])
        let first = app.staticTexts["tutorial-title-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(first))

        first.swipeLeft()
        XCTAssertTrue(waitUntilHittable(app.staticTexts["tutorial-title-2"]))
        XCTAssertFalse(first.isHittable)
    }

    @MainActor func testTargetsAreAtLeast44Points() {
        let app = launch(["-resetTutorial", "-showTutorial"])
        let skip = app.buttons["tutorial-skip"]
        let continueButton = app.buttons["tutorial-continue"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertEqual(skip.label, "Skip")

        for button in [skip, continueButton] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, button.identifier)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, button.identifier)
        }
        XCTAssertLessThan(skip.frame.midY, continueButton.frame.minY, "Skip at the top, Continue at the bottom")
        XCTAssertGreaterThan(skip.frame.midX, app.frame.midX, "Skip on the right")
    }

    /// On iPad the card and buttons stay about 440 pt wide and centered, like Welcome (W-4).
    /// On iPhone this holds anyway.
    @MainActor func testTheColumnIsAtMost440PointsWideAndCentered() {
        let app = launch(["-resetTutorial", "-showTutorial"])
        let continueButton = app.buttons["tutorial-continue"]
        let title = app.staticTexts["tutorial-title-1"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(title))

        XCTAssertLessThanOrEqual(continueButton.frame.width, 440)
        XCTAssertEqual(continueButton.frame.midX, app.frame.midX, accuracy: 1, "centered")
        XCTAssertGreaterThanOrEqual(title.frame.minX, continueButton.frame.minX, "the card sits in the same column")
        XCTAssertLessThanOrEqual(title.frame.maxX, continueButton.frame.maxX)
        XCTAssertLessThanOrEqual(app.buttons["tutorial-skip"].frame.maxX, continueButton.frame.maxX + 1, "Skip sits over the column")
    }

    @MainActor func testEveryPagePassesTheAccessibilityAudit() throws {
        let app = launch(["-resetTutorial", "-showTutorial"])
        let continueButton = app.buttons["tutorial-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))

        for number in 1...3 {
            XCTAssertTrue(waitUntilHittable(app.staticTexts["tutorial-title-\(number)"]))
            try app.performAccessibilityAudit { issue in
                // The logo stops growing past the largest standard size, on purpose (TutorialView).
                let isLogo = issue.auditType == .dynamicType && issue.element?.label == "Plandit"
                // The status bar belongs to the system.
                return isLogo || issue.element?.elementType == .statusBar
            }
            if number < 3 { continueButton.tap() }
        }
    }

    @MainActor func testSkipAuthAloneNeverShowsIt() {
        // Even with the record forgotten: the local test account is not a new account.
        let app = launch(["-resetTutorial"])
        XCTAssertTrue(app.buttons["plan-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["tutorial-skip"].exists)
    }
}
