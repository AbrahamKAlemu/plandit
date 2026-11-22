import XCTest

/// Group plans in Today (mode 3, "edit together"), against the fake group plan server
/// (`-fakeGroupPlans`). You're Sofia; Maya organizes a plan for today with you and Jordan in it,
/// every stop still planned: Hungarian Pastry, The Met, The High Line, Los Tacos, Washington
/// Square Park, Joe's Pizza. Your own plan is the sample day.
final class GroupPlanFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 9 AM: nothing in Maya's plan is past its time yet.
    @MainActor private func launch(_ scenario: String = "seeded") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-clock", "09:00", "-fakeGroupPlans", scenario]
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

    /// The stop's row in the timeline ("Stop 2, Planned, The Met…"), not the directions card.
    @MainActor private func stop(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Stop ", name)).firstMatch
    }

    @MainActor private func switcher(_ app: XCUIApplication) -> XCUIElement {
        app.segmentedControls["today-switcher"]
    }

    @MainActor private func openMayasPlan(_ app: XCUIApplication) {
        let switcher = switcher(app)
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.buttons["Maya's plan"].tap()
        XCTAssertTrue(app.buttons["group-members"].waitForExistence(timeout: 3))
    }

    /// Taps a stop in the timeline, then a status on its detail screen.
    @MainActor private func setStatus(_ status: String, of name: String, in app: XCUIApplication) {
        let row = stop(name, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        scrollTo(row, in: app)
        row.tap()
        let picker = app.segmentedControls["stop-status"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.buttons[status].tap()
    }

    @MainActor private func backToToday(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(switcher(app).waitForExistence(timeout: 3))
    }

    // MARK: - Editing together

    /// UI-1: Maya removes stop 2 just before your change to it reaches the server, so it isn't
    /// made and the message names her; a change to another stop lands.
    @MainActor func testAChangeToAStopMayaRemovedIsntMade() {
        let app = launch("mayaRemovesStop2")
        openMayasPlan(app)

        setStatus("I'm here", of: "The Met", in: app)
        let message = app.staticTexts["group-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "Maya removed that stop, so your change wasn't made.")
        XCTAssertTrue(app.staticTexts["Stop removed"].waitForExistence(timeout: 3), "the stop's screen says it's gone")
        app.buttons["group-message-close"].tap()
        backToToday(app)
        XCTAssertTrue(stop("The Met", in: app).waitForNonExistence(timeout: 3))
        let pastry = stop("Hungarian Pastry", in: app)
        XCTAssertTrue(pastry.label.hasPrefix("Stop 1, Planned"), "your change was undone with it: \(pastry.label)")

        setStatus("I'm here", of: "The High Line", in: app)
        backToToday(app)
        let highLine = stop("The High Line", in: app)
        XCTAssertTrue(highLine.label.hasPrefix("Stop 2, Now"), highLine.label)
        XCTAssertTrue(app.staticTexts["group-saving"].waitForNonExistence(timeout: 8), "the server took it")
        XCTAssertFalse(app.staticTexts["group-message"].exists, "nothing went wrong this time")
        XCTAssertTrue(stop("The High Line", in: app).label.hasPrefix("Stop 2, Now"))
        XCTAssertTrue(pastry.label.hasPrefix("Stop 1, Done"), pastry.label)
    }

    @MainActor func testAGroupPlanHasNoUndoBudgetOrSharing() {
        let app = launch()
        openMayasPlan(app)

        XCTAssertFalse(app.buttons["budget-metric"].exists, "the budget isn't changed here")
        XCTAssertTrue(app.descendants(matching: .any)["budget-metric-fixed"].exists)
        XCTAssertFalse(app.buttons["Send the plan"].exists)
        XCTAssertFalse(app.buttons["send-plan"].exists)
        XCTAssertFalse(app.buttons["start-group"].exists)
        XCTAssertFalse(app.buttons["answers-summary"].exists)

        setStatus("I'm here", of: "The Met", in: app)
        XCTAssertTrue(app.segmentedControls["stop-status"].buttons["I'm here"].isSelected)
        XCTAssertFalse(app.buttons["stop-cost"].exists, "a stop's cost isn't changed here")
        XCTAssertFalse(app.buttons["undo-button"].waitForExistence(timeout: 2), "no Undo in a group plan")
        XCTAssertFalse(app.staticTexts["undo-message"].exists)
    }

    // MARK: - Switching plans

    @MainActor func testSwitchingBetweenYourPlanAndMayas() {
        let app = launch()
        let switcher = switcher(app)
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        XCTAssertTrue(switcher.buttons["Mine"].isSelected, "your own plan first")
        XCTAssertTrue(stop("Hungarian Pastry", in: app).label.hasPrefix("Stop 1, Done"))
        XCTAssertTrue(app.buttons["budget-metric"].exists)
        XCTAssertFalse(app.buttons["group-members"].exists)

        switcher.buttons["Maya's plan"].tap()
        XCTAssertTrue(switcher.buttons["Maya's plan"].isSelected)
        XCTAssertTrue(app.buttons["group-members"].waitForExistence(timeout: 3))
        let planned = NSPredicate(format: "label BEGINSWITH %@", "Stop 1, Planned")
        let pastry = stop("Hungarian Pastry", in: app)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: planned, evaluatedWith: pastry)], timeout: 5), .completed,
                       "Maya's plan, every stop still ahead: \(pastry.label)")

        switcher.buttons["Mine"].tap()
        XCTAssertTrue(app.buttons["group-members"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(stop("Hungarian Pastry", in: app).label.hasPrefix("Stop 1, Done"))
    }

    // MARK: - Starting one

    @MainActor func testStartingAGroupPlanFromYourOwn() {
        let app = launch("empty")
        let start = app.buttons["start-group"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(switcher(app).exists, "no group plans yet")
        scrollTo(start, in: app)
        XCTAssertEqual(app.staticTexts["start-group-note"].label,
                       "Friends with Plandit can change it with you. They'll see your first name and the whole plan, budget included.")
        start.tap()

        XCTAssertTrue(waitForShareSheet(app), "the link goes out through the share sheet")
        closeShareSheet(app)

        let switcher = switcher(app)
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertTrue(switcher.buttons["Group plan"].isSelected, "the new group plan is shown")
        XCTAssertTrue(app.buttons["group-members"].exists)
        app.buttons["group-members"].tap()
        let link = app.staticTexts["group-invite-url"]
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        XCTAssertTrue(link.label.hasPrefix("https://plandit.app/j/"), link.label)
    }

    /// The system share sheet's look changes between iOS versions; any of its usual parts will do.
    @MainActor private func waitForShareSheet(_ app: XCUIApplication) -> Bool {
        let candidates = [
            app.otherElements["ActivityListView"],
            app.navigationBars["UIActivityContentView"],
            app.buttons["Copy"],
            app.cells["Copy"],
        ]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if candidates.contains(where: \.exists) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    @MainActor private func closeShareSheet(_ app: XCUIApplication) {
        for close in [app.buttons["Close"], app.navigationBars["UIActivityContentView"].buttons.firstMatch] where close.exists {
            close.tap()
            return
        }
        app.swipeDown(velocity: .fast)
    }

    // MARK: - Members

    @MainActor func testTheOrganizerManagesWhoIsIn() {
        let app = launch("youOrganize")
        let switcher = switcher(app)
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.buttons["Group plan"].tap()
        let members = app.buttons["group-members"]
        XCTAssertTrue(members.waitForExistence(timeout: 3))
        XCTAssertEqual(members.label, "Who's in: Sofia, Maya, and Jordan")
        members.tap()
        XCTAssertTrue(app.navigationBars["Who's in"].waitForExistence(timeout: 3))

        // An organizer can't leave, only end the plan.
        XCTAssertFalse(app.buttons["group-leave"].exists)
        XCTAssertTrue(app.staticTexts["organizer-cant-leave"].exists)

        let link = app.staticTexts["group-invite-url"]
        XCTAssertTrue(link.exists)
        let oldLink = link.label
        app.buttons["group-new-link"].tap()
        app.buttons["confirm-new-link"].firstMatch.tap()
        let changed = NSPredicate(format: "label != %@", oldLink)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: changed, evaluatedWith: link)], timeout: 5), .completed, "the old link stops working")

        app.buttons["remove-member-Jordan"].tap()
        app.buttons["confirm-remove"].firstMatch.tap()
        XCTAssertTrue(app.buttons["remove-member-Jordan"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["remove-member-Maya"].exists)

        app.buttons["group-end"].tap()
        app.buttons["confirm-end"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Who's in"].waitForNonExistence(timeout: 5))
        let message = app.staticTexts["group-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertEqual(message.label, "You ended the plan.")
        XCTAssertFalse(switcher.buttons["Group plan"].exists, "gone for everyone")
        XCTAssertTrue(switcher.buttons["Maya's plan"].exists)
    }

    @MainActor func testAMemberCanLeave() {
        let app = launch()
        openMayasPlan(app)
        app.buttons["group-members"].tap()
        XCTAssertTrue(app.navigationBars["Who's in"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["member-Maya"].label.contains("Organizer"))
        XCTAssertFalse(app.buttons["group-end"].exists, "only the organizer ends it")
        XCTAssertFalse(app.buttons["remove-member-Jordan"].exists, "only the organizer removes people")

        app.buttons["group-leave"].tap()
        app.buttons["confirm-leave"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Who's in"].waitForNonExistence(timeout: 5))
        let message = app.staticTexts["group-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertEqual(message.label, "You left Maya's plan.")
        XCTAssertTrue(switcher(app).waitForNonExistence(timeout: 3), "no group plans left")
        XCTAssertTrue(stop("Hungarian Pastry", in: app).label.hasPrefix("Stop 1, Done"), "back to your own plan")
    }
}
