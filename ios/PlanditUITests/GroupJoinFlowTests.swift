import XCTest

/// Joining a group plan by link (GE-2, JN-1 to JN-3) against `-fakeGroupPlans`: you're in Maya's
/// group, and Jordan's (`fake-invite-jordans-day`) is open to join. Until Today shows group plans,
/// `debug-group-plans` (DEBUG, `-fakeGroupPlans` only) lists the groups this phone holds.
final class GroupJoinFlowTests: XCTestCase {
    private let jordansLink = "https://plandit.app/j/fake-invite-jordans-day"
    private let jordansGroup = "AD1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6"
    private let mayasGroup = "9C1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor private func launchWithGroups(_ extra: [String] = []) -> XCUIApplication {
        launch(["-skipAuth", "-fakeGroupPlans", "-startTab", "saved", "-startDetent", "large"] + extra)
    }

    /// Types `link` into "Add a link" (opened from `button`) and taps Save.
    @MainActor private func paste(_ link: String, in app: XCUIApplication, from button: String = "Add a link") {
        let open = app.buttons[button]
        XCTAssertTrue(open.waitForExistence(timeout: 10), button)
        open.tap()
        let field = app.textFields["social-link-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(link)
        app.buttons["save-social-link"].tap()
    }

    @MainActor private func probe(_ app: XCUIApplication) -> XCUIElement {
        let probe = app.descendants(matching: .any)["debug-group-plans"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "no group plans probe")
        return probe
    }

    @MainActor private func groups(in app: XCUIApplication) -> [String] {
        probe(app).label.dropFirst("groups:".count).split(separator: ",").map(String.init)
    }

    /// Waits until the probe lists exactly `ids`, in any order.
    @MainActor private func waitForGroups(_ ids: Set<String>, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let element = probe(app)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let shown = element.label.dropFirst("groups:".count).split(separator: ",").map(String.init)
            if Set(shown) == ids, shown.count == ids.count { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("groups were \(element.label), expected \(ids.sorted())", file: file, line: line)
    }

    @MainActor private func joinSheetShowsJordansPlan(in app: XCUIApplication, members: String = "Just Jordan so far.") {
        XCTAssertTrue(app.staticTexts["Join Jordan's plan for today?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[members].exists, members)
        XCTAssertTrue(app.staticTexts["Your first name will show to the group."].exists)
        XCTAssertTrue(app.buttons["join-group"].exists)
        XCTAssertTrue(app.buttons["join-not-now"].exists)
    }

    // MARK: - JN-1

    @MainActor func testPastingAnInviteInSavedOpensTheJoinSheetAndJoinOpensToday() {
        let app = launchWithGroups()
        waitForGroups([mayasGroup], in: app)

        paste(jordansLink, in: app)

        joinSheetShowsJordansPlan(in: app)
        XCTAssertFalse(app.staticTexts["Places found"].exists, "not place finding")
        XCTAssertEqual(app.buttons["join-group"].label, "Join")
        XCTAssertEqual(app.buttons["join-not-now"].label, "Not now")
        app.buttons["join-group"].tap()

        XCTAssertTrue(app.buttons["join-group"].waitForNonExistence(timeout: 10), "the sheets close")
        XCTAssertFalse(app.textFields["social-link-field"].exists)
        XCTAssertTrue(UITestScrolling.bar(in: app).buttons["Today"].isSelected)
        waitForGroups([mayasGroup, jordansGroup], in: app)
    }

    /// The `/j/` page tells friends to tap Paste a link in an empty Saved: it leads here too.
    @MainActor func testPasteALinkInAnEmptySavedLeadsToTheJoinSheet() {
        let app = launchWithGroups(["-resetSavedData"])

        paste(jordansLink, in: app, from: "Paste a link")

        joinSheetShowsJordansPlan(in: app)
        app.buttons["join-not-now"].tap()
        XCTAssertTrue(app.buttons["join-not-now"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(UITestScrolling.bar(in: app).buttons["Saved"].isSelected, "Not now leaves you where you were")
        waitForGroups([mayasGroup], in: app)
    }

    @MainActor func testASharedPlanLinkStillGoesWhereItWent() {
        let app = launchWithGroups()

        paste("https://plandit.app/p/Ab12Cd34Ef", in: app)

        XCTAssertTrue(app.staticTexts["Use a link to a TikTok or an Instagram post or Reel."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["social-link-field"].exists, "Add a link stays open")
        XCTAssertFalse(app.buttons["join-group"].exists)
        XCTAssertFalse(app.staticTexts["Join Jordan's plan for today?"].exists)
    }

    // MARK: - JN-2

    @MainActor func testADeadInviteSaysItDoesntWork() {
        let app = launchWithGroups()

        paste("https://plandit.app/j/AAAAAAAAAAAAAAAAAAAAAA", in: app)

        XCTAssertTrue(app.staticTexts["This invite doesn't work any more"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["join-group"].exists)
        app.buttons["join-close"].tap()
        XCTAssertTrue(app.buttons["join-close"].waitForNonExistence(timeout: 5))
        waitForGroups([mayasGroup], in: app)
    }

    // MARK: - JN-3

    @MainActor func testJoiningTwiceKeepsOneGroup() {
        let app = launchWithGroups()
        paste(jordansLink, in: app)
        joinSheetShowsJordansPlan(in: app)
        app.buttons["join-group"].tap()
        waitForGroups([mayasGroup, jordansGroup], in: app)

        UITestScrolling.bar(in: app).buttons["Saved"].tap()
        paste(jordansLink, in: app)

        joinSheetShowsJordansPlan(in: app, members: "2 people in the group so far.")
        app.buttons["join-group"].tap()
        XCTAssertTrue(app.buttons["join-group"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(UITestScrolling.bar(in: app).buttons["Today"].isSelected)
        waitForGroups([mayasGroup, jordansGroup], in: app)
        XCTAssertEqual(groups(in: app).count, 2)
    }

    // MARK: - From the share sheet

    /// `-seedInvite` holds an invite as the share extension does: Plandit opens its join sheet
    /// once, and not again the next time it becomes active.
    @MainActor func testAnInviteFromTheShareSheetOpensOnceWhenPlanditOpens() {
        let app = launch(["-skipAuth", "-fakeGroupPlans", "-startDetent", "large", "-seedInvite", "fake-invite-jordans-day"])

        joinSheetShowsJordansPlan(in: app)
        app.buttons["join-not-now"].tap()
        XCTAssertTrue(app.buttons["join-not-now"].waitForNonExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(UITestScrolling.bar(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["join-group"].waitForExistence(timeout: 3), "opened once only")
    }

    // MARK: - No group plans

    @MainActor func testALocalOnlyAccountIsToldGroupPlansNeedAnAccount() {
        let app = launch(["-skipAuth", "-startTab", "saved", "-startDetent", "large"])

        paste(jordansLink, in: app)

        XCTAssertTrue(app.staticTexts["Group plans need an account"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["join-group"].exists)
        app.buttons["join-close"].tap()
        XCTAssertTrue(app.buttons["join-close"].waitForNonExistence(timeout: 5))
    }
}
