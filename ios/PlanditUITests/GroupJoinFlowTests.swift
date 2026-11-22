import XCTest

/// Joining a group plan by link (GE-2, JN-1 to JN-3) against `-fakeGroupPlans`: you're in Maya's
/// group, and Jordan's (`fake-invite-jordans-day`) is open to join. Today's switcher shows which
/// group plans you're in: Mine, Maya's plan, and Jordan's plan once you join.
final class GroupJoinFlowTests: XCTestCase {
    private let jordansLink = "https://plandit.app/j/fake-invite-jordans-day"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Opens on Today until Maya's plan is in the switcher (the group plans have loaded), then Saved.
    @MainActor private func launchWithGroups(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["-skipAuth", "-fakeGroupPlans", "-startDetent", "large"] + extra)
        XCTAssertTrue(switcher(app).buttons["Maya's plan"].waitForExistence(timeout: 10), "group plans loaded")
        UITestScrolling.bar(in: app).buttons["Saved"].tap()
        return app
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

    @MainActor private func switcher(_ app: XCUIApplication) -> XCUIElement {
        app.segmentedControls["today-switcher"]
    }

    /// After joining: Today is open with Jordan's plan picked, next to yours and Maya's, and shows
    /// its stops and who's in.
    @MainActor private func todayShowsJordansPlan(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(UITestScrolling.bar(in: app).buttons["Today"].isSelected, file: file, line: line)
        let jordans = switcher(app).buttons["Jordan's plan"]
        XCTAssertTrue(jordans.waitForExistence(timeout: 10), "Jordan's plan is in the switcher", file: file, line: line)
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: jordans)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 5), .completed, "Today shows the plan just joined", file: file, line: line)
        XCTAssertEqual(switcher(app).buttons.count, 3, "Mine, Maya's plan and Jordan's plan", file: file, line: line)
        let members = app.buttons["group-members"]
        XCTAssertTrue(members.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(members.label.contains("Jordan"), members.label, file: file, line: line)
        let firstStop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop 1, ")).firstMatch
        XCTAssertTrue(firstStop.waitForExistence(timeout: 10), "its stops show", file: file, line: line)
    }

    /// Today still has only your plan and Maya's.
    @MainActor private func todayHasNoNewPlan(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        UITestScrolling.bar(in: app).buttons["Today"].tap()
        let switcher = switcher(app)
        XCTAssertTrue(switcher.buttons["Maya's plan"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(switcher.buttons["Jordan's plan"].exists, file: file, line: line)
        XCTAssertEqual(switcher.buttons.count, 2, "Mine and Maya's plan", file: file, line: line)
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

        paste(jordansLink, in: app)

        joinSheetShowsJordansPlan(in: app)
        XCTAssertFalse(app.staticTexts["Places found"].exists, "not place finding")
        XCTAssertEqual(app.buttons["join-group"].label, "Join")
        XCTAssertEqual(app.buttons["join-not-now"].label, "Not now")
        app.buttons["join-group"].tap()

        XCTAssertTrue(app.buttons["join-group"].waitForNonExistence(timeout: 10), "the sheets close")
        XCTAssertFalse(app.textFields["social-link-field"].exists)
        todayShowsJordansPlan(in: app)
    }

    /// The `/j/` page tells friends to tap Paste a link in an empty Saved: it leads here too.
    @MainActor func testPasteALinkInAnEmptySavedLeadsToTheJoinSheet() {
        let app = launchWithGroups(["-resetSavedData"])

        paste(jordansLink, in: app, from: "Paste a link")

        joinSheetShowsJordansPlan(in: app)
        app.buttons["join-not-now"].tap()
        XCTAssertTrue(app.buttons["join-not-now"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(UITestScrolling.bar(in: app).buttons["Saved"].isSelected, "Not now leaves you where you were")
        todayHasNoNewPlan(in: app)
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
        todayHasNoNewPlan(in: app)
    }

    // MARK: - JN-3

    @MainActor func testJoiningTwiceKeepsOneGroup() {
        let app = launchWithGroups()
        paste(jordansLink, in: app)
        joinSheetShowsJordansPlan(in: app)
        app.buttons["join-group"].tap()
        XCTAssertTrue(app.buttons["join-group"].waitForNonExistence(timeout: 10))
        todayShowsJordansPlan(in: app)

        UITestScrolling.bar(in: app).buttons["Saved"].tap()
        paste(jordansLink, in: app)

        joinSheetShowsJordansPlan(in: app, members: "2 people in the group so far.")
        app.buttons["join-group"].tap()
        XCTAssertTrue(app.buttons["join-group"].waitForNonExistence(timeout: 10))
        todayShowsJordansPlan(in: app)
        XCTAssertFalse(switcher(app).buttons["Jordan's plan 2"].exists, "still one Jordan's plan")
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
