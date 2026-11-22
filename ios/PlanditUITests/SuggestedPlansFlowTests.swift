import XCTest

/// Suggested plans in an empty Today, from the five fixed saves of `-seedSuggestions`: three places
/// in Chelsea and two on the Upper West Side, planned from 2 PM.
final class SuggestedPlansFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-seedSuggestions", "-planStart", "14:00", "-clock", "13:55",
                               "-startDetent", "large"] + extra
        app.launch()
        return app
    }

    /// The stop names at the end of a card's label, in plan order: "Title. Facts. A, B, C."
    private func stopNames(inCardLabel label: String) -> [String] {
        let parts = label.components(separatedBy: ". ")
        guard parts.count >= 3, var names = parts.last else { return [] }
        if names.hasSuffix(".") { names.removeLast() }
        return names.components(separatedBy: ", ").map { $0.replacingOccurrences(of: " (check hours)", with: "") }
    }

    @MainActor func testUseThisPlan() {
        let app = launch()
        let suggestions = app.descendants(matching: .any)["today-suggestions"]
        XCTAssertTrue(suggestions.waitForExistence(timeout: 5), "an empty Today with saves shows plans")
        XCTAssertTrue(app.staticTexts["Plans from your saves"].exists)

        let card = app.descendants(matching: .any)["suggestion-card-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        // The best plan: all three Chelsea places, walking, $15 at Chelsea Market.
        XCTAssertTrue(card.label.hasPrefix("Chelsea and Hudson River Park. 3 stops, 2:00 to "), card.label)
        XCTAssertTrue(card.label.contains("$15 each, all walking."), card.label)
        let names = stopNames(inCardLabel: card.label)
        XCTAssertEqual(Set(names), ["Chelsea Market", "The High Line", "Little Island"], card.label)
        // The Upper West Side pair is the second card; nothing is in two cards.
        let second = app.descendants(matching: .any)["suggestion-card-1"]
        XCTAssertTrue(second.exists)
        XCTAssertTrue(second.label.hasPrefix("Upper West Side. 2 stops"), second.label)
        XCTAssertFalse(app.descendants(matching: .any)["suggestion-card-2"].exists)

        // "Plan a day" stays, below the cards.
        let planADay = app.buttons["today-plan-a-day"]
        XCTAssertTrue(planADay.exists)
        XCTAssertGreaterThan(planADay.frame.minY, second.frame.maxY)
        XCTAssertTrue(app.buttons["suggestion-change-0"].exists)

        // It opens the planner with nothing picked, as before; cancelling leaves the cards.
        planADay.tap()
        XCTAssertTrue(app.navigationBars["Plan a day"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["build-plan"].isEnabled, "nothing picked yet")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Plan a day"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(card.waitForExistence(timeout: 3))

        app.buttons["suggestion-use-0"].tap()

        // Today is that plan: the same places in the same order, at the card's price.
        XCTAssertTrue(app.buttons["edit-plan"].waitForExistence(timeout: 5))
        XCTAssertFalse(suggestions.exists)
        for (index, name) in names.enumerated() {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop \(index + 1),")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3), "no stop \(index + 1)")
            XCTAssertTrue(row.label.contains(name), "stop \(index + 1) should be \(name): \(row.label)")
        }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stop 4,'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["budget-metric"].label.hasPrefix("$15"), app.buttons["budget-metric"].label)

        // Undo brings the empty Today and its cards back.
        XCTAssertEqual(app.staticTexts["undo-message"].label, "Made a new plan")
        app.buttons["undo-button"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(stopNames(inCardLabel: card.label), names)
    }

    @MainActor func testChangeIt() {
        let app = launch()
        let card = app.descendants(matching: .any)["suggestion-card-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let names = stopNames(inCardLabel: card.label)
        XCTAssertEqual(names.count, 3, card.label)

        app.buttons["suggestion-change-0"].tap()
        XCTAssertTrue(app.navigationBars["Plan a day"].waitForExistence(timeout: 3))

        // The card's places are picked, and the planner lays them out in the card's order, from the
        // card's start time, on the same budget.
        for name in names {
            XCTAssertTrue(app.buttons["pick-\(name)"].isSelected, "\(name) should be picked")
        }
        XCTAssertTrue(app.staticTexts["3 picked"].exists)
        for (index, name) in names.enumerated() {
            let row = app.descendants(matching: .any)["preview-stop-\(index + 1)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "no preview stop \(index + 1)")
            XCTAssertTrue(row.label.contains(name), "preview stop \(index + 1) should be \(name): \(row.label)")
        }
        // "2:00 PM to 5:25 PM", with whatever space the locale puts before PM.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2:00' AND label CONTAINS ' to '")).firstMatch.exists,
                      "the plan starts at the card's time")
        XCTAssertEqual(app.staticTexts["budget-value"].label, "$60")
        XCTAssertTrue(app.buttons["build-plan"].isEnabled)

        // Nothing changes in Today until "Build my plan".
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Plan a day"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["edit-plan"].exists, "Today is still empty")
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertEqual(stopNames(inCardLabel: card.label), names)

        // The + still opens an empty planner afterwards.
        app.buttons["plan-button"].tap()
        XCTAssertTrue(app.navigationBars["Plan a day"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["0 picked"].exists)
        XCTAssertFalse(app.buttons["build-plan"].isEnabled)
    }
}
