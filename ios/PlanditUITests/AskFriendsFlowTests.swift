import XCTest

/// "Ask friends what works" (group plans, mode 2), from the planner. `-fakeSharing -fakeRequests`
/// stand in for the server: once the link exists, Maya ($20, 1 to 6 PM) has starred the 2nd and
/// 1st places and Jordan ($35, noon to 5 PM) the 2nd and 3rd. With `-fakeRequests clash`, Maya is
/// free noon to 2 PM and Jordan 4 to 8 PM.
final class AskFriendsFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(clash: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-planStart", "11:00", "-clock", "11:00",
                               "-fakeSharing", "-fakeRequests"] + (clash ? ["clash"] : []) + extra
        app.launch()
        return app
    }

    /// Drags the screen until the element sits between the navigation bar and the bar at the
    /// bottom. Drags end with a hold, so nothing keeps gliding and a tap lands where it's aimed.
    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let height = window.frame.height
        let top = height * 0.22, bottom = height * 0.62
        for _ in 0..<12 {
            let frame = element.frame
            if element.isHittable, frame.minY >= top, frame.maxY <= bottom { return }
            let shift = max(-height * 0.35, min(height * 0.35, (top + bottom) / 2 - frame.midY))
            // From the side margin, where no button is: a drag that starts on a row can pick it.
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: shift)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    @MainActor private func scrollBackUp(_ app: XCUIApplication) {
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
    }

    @MainActor private func openAskFriends(_ app: XCUIApplication) {
        let plus = app.buttons["plan-button"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(app.navigationBars["Plan a day"].waitForExistence(timeout: 3))
        let entry = app.buttons["ask-friends"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
    }

    /// GI-1: four saved places today, noon to 8 PM by default, then the link. At 11 AM answers are
    /// due when the time starts, at noon: sooner than 2 hours from now.
    @MainActor private func makeLink(_ app: XCUIApplication, isToday: Bool = true) {
        XCTAssertTrue(app.navigationBars["Ask friends what works"].waitForExistence(timeout: 3))
        let create = app.buttons["ask-create"]
        XCTAssertFalse(create.isEnabled, "nothing picked yet")
        for name in ["The High Line", "Los Tacos No. 1", "Levain Bakery", "Little Island"] {
            let row = app.buttons["ask-pick-\(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "no row for \(name)")
            pick(row, in: app)
            XCTAssertTrue(row.isSelected, "\(name) should be picked")
        }
        for name in ["The High Line", "Los Tacos No. 1", "Levain Bakery", "Little Island"] {
            XCTAssertTrue(app.buttons["ask-pick-\(name)"].isSelected, "\(name) is still picked")
        }
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.navigationBars["Friends' answers"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["request-link-url"].label, "Link: https://plandit.app/g/req123abcd")
        XCTAssertTrue(app.buttons["request-send-link"].exists)
        if isToday { XCTAssertEqual(text(app.staticTexts["request-status"]), "Friends can answer until 12:00 PM.") }
    }

    /// Sets the form's day to `daysAhead` days from today, in the day picker's calendar.
    @MainActor private func chooseDay(_ daysAhead: Int, in app: XCUIApplication) {
        let picker = element("ask-day", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        scrollTo(picker, in: app)
        picker.tap()
        let day = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date())!
        let label = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), "no \(label) in the calendar")
        button.tap()
        sleep(1)
        // Closes the calendar: a tap above it, on the navigation bar's empty middle.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        sleep(1)
    }

    /// Picks a place on the form, or leaves it picked: a row that's already picked is never tapped,
    /// since a tap would unpick it. Each pick moves the form for a moment (the line under the list
    /// changes), and a tap aimed while it moves lands on the next row, so it taps only once the row
    /// is still. Then it waits for the row to change, and reads it again before tapping again.
    @MainActor private func pick(_ row: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            if row.isSelected { return }
            scrollTo(row, in: app)
            waitUntilStill(row)
            if row.isSelected { return }
            row.tap()
            if row.wait(for: \.isSelected, toEqual: true, timeout: 4) {
                waitUntilStill(row)
                return
            }
        }
    }

    /// Waits until the element stays put for a quarter of a second, up to about 3 seconds.
    @MainActor private func waitUntilStill(_ element: XCUIElement) {
        var last = element.frame
        var stillFor = 0
        for _ in 0..<24 {
            usleep(125_000)
            let now = element.frame
            stillFor = now == last ? stillFor + 1 : 0
            if stillFor >= 2 { return }
            last = now
        }
    }

    /// The label with the narrow space iOS puts before AM and PM made a plain one.
    @MainActor private func text(_ element: XCUIElement) -> String {
        element.label.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor func testAskBuildAndShareOurPlan() {
        let app = launch()
        openAskFriends(app)
        makeLink(app)

        // GI-4: each answer's name, budget, window and stars.
        let maya = element("answer-Maya", in: app)
        XCTAssertTrue(maya.waitForExistence(timeout: 3))
        XCTAssertTrue(text(maya).contains("$20 · free 1:00 PM to 6:00 PM"), text(maya))
        XCTAssertTrue(text(maya).contains("Starred The High Line and Los Tacos No. 1"), text(maya))
        let jordan = element("answer-Jordan", in: app)
        XCTAssertTrue(text(jordan).contains("$35 · free 12:00 PM to 5:00 PM"), text(jordan))

        // GI-5: the latest from, the earliest until and the lowest budget, without saying whose.
        let inputs = element("group-inputs", in: app)
        scrollTo(inputs, in: app)
        XCTAssertTrue(text(inputs).contains("Everyone's free 1:00 PM to 5:00 PM."), text(inputs))
        XCTAssertTrue(text(inputs).contains("Budget: $20 each, the lowest anyone gave"), text(inputs))
        XCTAssertFalse(inputs.label.contains("Maya"))
        XCTAssertTrue(element("preview-stop-1", in: app).waitForExistence(timeout: 2))

        // Removing Jordan's answer: his times no longer count.
        scrollBackUp(app)
        app.buttons["remove-answer-Jordan"].tap()
        let confirm = app.buttons["confirm-remove-answer"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.buttons["remove-answer-Jordan"].waitForNonExistence(timeout: 3))
        scrollTo(inputs, in: app)
        XCTAssertTrue(text(inputs).contains("Everyone's free 1:00 PM to 6:00 PM."), text(inputs))

        // GI-7: it goes into Today, and the link now opens it.
        let build = app.buttons["build-our-plan"]
        XCTAssertTrue(build.isEnabled)
        build.tap()
        XCTAssertTrue(app.navigationBars["Friends' answers"].waitForNonExistence(timeout: 5), "the planner closes")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Los Tacos No. 1'")).firstMatch.waitForExistence(timeout: 5),
                      "Today shows the plan")
        // Friends' link opens it now, so there's no Undo: it would put the old plan there.
        XCTAssertFalse(app.staticTexts["undo-message"].exists)

        openAskFriends(app)
        XCTAssertTrue(app.navigationBars["Friends' answers"].waitForExistence(timeout: 3))
        let status = app.staticTexts["request-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.label, "Done. The link now opens your plan.")
        XCTAssertFalse(app.buttons["build-our-plan"].exists)
    }

    @MainActor func testClashingTimesAreNamedAndSomeoneCanBeLeftOut() {
        let app = launch(clash: true)
        openAskFriends(app)
        makeLink(app)

        // GI-6: nothing is planned over anyone's times until the organizer leaves someone out.
        let clash = element("group-clash", in: app)
        XCTAssertTrue(clash.waitForExistence(timeout: 3))
        scrollTo(clash, in: app)
        XCTAssertEqual(clash.label, "These times don't overlap by an hour: Maya and Jordan.")
        let build = app.buttons["build-our-plan"]
        XCTAssertFalse(build.isEnabled)
        XCTAssertEqual(app.staticTexts["build-clash-hint"].label, "Leave out someone's times above to build.")
        XCTAssertFalse(element("preview-stop-1", in: app).exists)

        let leaveOut = app.switches["leave-out-Maya"]
        XCTAssertTrue(leaveOut.exists)
        XCTAssertTrue(app.switches["leave-out-Jordan"].exists)
        leaveOut.switches.firstMatch.tap()

        let inputs = element("group-inputs", in: app)
        XCTAssertTrue(inputs.waitForExistence(timeout: 3))
        scrollTo(inputs, in: app)
        XCTAssertTrue(text(inputs).contains("Everyone's free 4:00 PM to 8:00 PM."), text(inputs))
        XCTAssertTrue(text(inputs).contains("Budget: $20 each"), "Maya's budget still counts: \(text(inputs))")
        XCTAssertEqual(app.switches["leave-out-Maya"].value as? String, "1", "she can be put back")
        XCTAssertFalse(element("group-clash", in: app).exists)
        XCTAssertFalse(app.staticTexts["build-clash-hint"].exists)

        XCTAssertTrue(build.isEnabled)
        build.tap()
        XCTAssertTrue(app.navigationBars["Friends' answers"].waitForNonExistence(timeout: 5), "the planner closes")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Los Tacos No. 1'")).firstMatch.waitForExistence(timeout: 5),
                      "Today shows the plan")
        XCTAssertFalse(app.staticTexts["undo-message"].exists)
    }

    /// At the largest text sizes only the button stays pinned: the line about the clash scrolls with
    /// the answers, after them, so it never sits over the switches (round 3 persona review).
    @MainActor func testAtTheLargestTextTheClashLineScrollsWithTheAnswers() {
        let app = launch(clash: true, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        openAskFriends(app)
        makeLink(app)
        let first = app.switches["leave-out-Maya"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        scrollTo(first, in: app)
        let build = app.buttons["build-our-plan"]
        let hint = app.staticTexts["build-clash-hint"]
        XCTAssertTrue(hint.exists)
        XCTAssertLessThanOrEqual(first.frame.maxY, build.frame.minY)
        // From the top of the list, a pinned line would still sit over the answers.
        scrollBackUp(app)
        XCTAssertGreaterThan(hint.frame.minY, build.frame.minY, "the line is pinned over the answers")

        scrollTo(hint, in: app)
        XCTAssertLessThanOrEqual(hint.frame.maxY, build.frame.minY, "at the end it sits right above Build our plan")
        XCTAssertGreaterThan(hint.frame.minY, app.buttons["request-new"].frame.maxY, "after the answers and the links' buttons")
    }

    /// On a later day, the line saying when the plan can be built is there at the largest text sizes
    /// too: last in the list, reachable right above the disabled button (round 4 persona review).
    @MainActor func testAtTheLargestTextTheLaterDayLineIsReachable() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        openAskFriends(app)
        XCTAssertTrue(app.navigationBars["Ask friends what works"].waitForExistence(timeout: 3))
        chooseDay(2, in: app)
        makeLink(app, isToday: false)
        let line = app.staticTexts["build-day-hint"]
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        let day = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        XCTAssertEqual(line.label, "You can build it on \(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
        let build = app.buttons["build-our-plan"]
        XCTAssertFalse(build.isEnabled, "a later day's plan is built on that day")

        scrollBackUp(app)
        XCTAssertGreaterThan(line.frame.minY, build.frame.minY, "the line is pinned over the answers")
        scrollTo(line, in: app)
        XCTAssertTrue(line.isHittable)
        XCTAssertLessThanOrEqual(line.frame.maxY, build.frame.minY, "at the end it sits right above Build our plan")
    }
}
