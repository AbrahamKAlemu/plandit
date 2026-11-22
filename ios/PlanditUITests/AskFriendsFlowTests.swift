import XCTest

/// "Ask friends what works" (group plans, mode 2), from the planner. `-fakeSharing -fakeRequests`
/// stand in for the server: once the link exists, Maya ($20, 1 to 6 PM) has starred the 2nd and
/// 1st places and Jordan ($35, noon to 5 PM) the 2nd and 3rd. With `-fakeRequests clash`, Maya is
/// free noon to 2 PM and Jordan 4 to 8 PM.
final class AskFriendsFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(clash: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-resetData", "-startDetent", "large", "-planStart", "11:00", "-clock", "11:00",
                               "-fakeSharing", "-fakeRequests"] + (clash ? ["clash"] : [])
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

    /// GI-1: four saved places today, noon to 8 PM by default, then the link.
    @MainActor private func makeLink(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Ask friends what works"].waitForExistence(timeout: 3))
        let create = app.buttons["ask-create"]
        XCTAssertFalse(create.isEnabled, "nothing picked yet")
        for name in ["The High Line", "Los Tacos No. 1", "Levain Bakery", "Little Island"] {
            let row = app.buttons["ask-pick-\(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "no row for \(name)")
            scrollTo(row, in: app)
            row.tap()
            // Now and then the simulator drops a tap on this list; a dropped tap changed nothing,
            // so one more is safe. The check before Get the link catches anything else.
            if !row.wait(for: \.isSelected, toEqual: true, timeout: 2) { row.tap() }
            XCTAssertTrue(row.wait(for: \.isSelected, toEqual: true, timeout: 2), "\(name) should be picked")
        }
        for name in ["The High Line", "Los Tacos No. 1", "Levain Bakery", "Little Island"] {
            XCTAssertTrue(app.buttons["ask-pick-\(name)"].isSelected, "\(name) is still picked")
        }
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.navigationBars["Friends' answers"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["request-link-url"].label, "Link: https://plandit.app/g/req123abcd")
        XCTAssertTrue(app.buttons["request-send-link"].exists)
        XCTAssertEqual(text(app.staticTexts["request-status"]), "Friends can answer until 1:00 PM.")
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
        XCTAssertTrue(text(inputs).contains("Budget: $20 each"), text(inputs))
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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Built our plan'")).firstMatch.waitForExistence(timeout: 3),
                      "and it can be undone")

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

        XCTAssertTrue(build.isEnabled)
        build.tap()
        XCTAssertTrue(app.navigationBars["Friends' answers"].waitForNonExistence(timeout: 5), "the planner closes")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Built our plan'")).firstMatch.waitForExistence(timeout: 3))
    }
}
