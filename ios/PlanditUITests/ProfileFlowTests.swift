import XCTest

/// 1.0.1's bar and Profile: four items, preferences first, Appearance and Account inside Profile.
final class ProfileFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skipAuth", "-startDetent", "large"] + (reset ? ["-resetData"] : []) + extra
        app.launch()
        return app
    }

    @MainActor private func header(in app: XCUIApplication) -> XCUIElement {
        let header = app.buttons["profile-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Profile didn't open")
        return header
    }

    // MARK: - Bar (NAV-2, NAV-3, D-2)

    @MainActor func testSettingsLaunchValueOpensProfileAndThereIsNoSettingsTab() {
        let app = launch(["-startTab", "settings"])
        _ = header(in: app)

        let bar = UITestScrolling.bar(in: app)
        XCTAssertFalse(bar.buttons["Settings"].exists)
        XCTAssertTrue(bar.buttons["Profile"].isSelected)
    }

    @MainActor func testBarIsTodaySavedPlanProfileWithFullSizeTargets() {
        let app = launch(["-startTab", "today"])
        let bar = UITestScrolling.bar(in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5))

        let items = bar.buttons.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(items.map(\.label), ["Today", "Saved", "Plan a day", "Profile"])
        XCTAssertEqual(items[2].identifier, "plan-button")
        for item in items {
            XCTAssertGreaterThanOrEqual(item.frame.height, 44, "\(item.label) is too short to tap")
            XCTAssertGreaterThanOrEqual(item.frame.width, 44, "\(item.label) is too narrow to tap")
        }
        XCTAssertTrue(bar.buttons["Today"].isSelected)

        bar.buttons["Profile"].tap()
        _ = header(in: app)
        XCTAssertTrue(bar.buttons["Profile"].isSelected)

        bar.buttons["plan-button"].tap()
        XCTAssertTrue(app.navigationBars["Plan a day"].waitForExistence(timeout: 3))
    }

    // MARK: - Profile (D-6, PRO-2, W-6, W-7)

    @MainActor func testBarStopsGrowingAtTheLargestStandardTextSize() {
        // Like the system tab bar: text stops growing at XXXL, and a long press shows the large
        // version at accessibility sizes.
        func barHeight(at size: String) -> CGFloat {
            let app = launch(["-startTab", "today", "-UIPreferredContentSizeCategoryName", size])
            let bar = UITestScrolling.bar(in: app)
            let items = bar.buttons.allElementsBoundByIndex
            XCTAssertEqual(items.count, 4)
            for item in items {
                XCTAssertGreaterThanOrEqual(item.frame.width, 44, "\(item.label) at \(size)")
                XCTAssertGreaterThanOrEqual(item.frame.height, 44, "\(item.label) at \(size)")
            }
            let height = bar.frame.height
            app.terminate()
            return height
        }
        let largestStandard = barHeight(at: "UICTContentSizeCategoryXXXL")
        let largestAccessibility = barHeight(at: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertEqual(largestAccessibility, largestStandard, accuracy: 0.5)
    }

    @MainActor func testProfileReadsInTheDraftsOrder() {
        let app = launch(["-startTab", "profile"])
        let landmarks: [(String, XCUIElement)] = [
            ("header", header(in: app)),
            ("Preferences", app.staticTexts["Preferences"]),
            ("Home base", app.staticTexts["Home base"]),
            ("Default budget", app.staticTexts["Default budget"]),
            ("Preferred transportation", app.staticTexts["Preferred transportation"]),
            ("Appearance", app.staticTexts["Appearance"]),
            ("How it works", app.staticTexts["How it works"]),
            ("Activity", app.staticTexts["Activity"]),
            ("Plans completed", stat("Plans completed", in: app)),
            ("Past plans", app.staticTexts["Past plans"]),
            ("Account", app.staticTexts["Account"]),
            ("footer", app.descendants(matching: .any)["profile-footer"]),
        ]
        var tops: [CGFloat] = []
        for (name, element) in landmarks {
            XCTAssertTrue(element.waitForExistence(timeout: 3), "\(name) is missing")
            tops.append(element.frame.minY)
        }
        XCTAssertEqual(tops, tops.sorted(), "out of order: \(zip(landmarks.map(\.0), tops).map { "\($0) \(Int($1))" })")

        // Three numbers, side by side, and nothing from 1.0's grid.
        let numbers = ["Plans completed", "Neighborhoods explored", "Places saved"].map { stat($0, in: app) }
        XCTAssertEqual(Set(numbers.map { Int($0.frame.minY) }).count, 1, "the numbers share one row, tops lined up")
        XCTAssertLessThan(numbers[0].frame.minX, numbers[1].frame.minX)
        XCTAssertLessThan(numbers[1].frame.minX, numbers[2].frame.minX)
        for gone in ["Walked", "Under budget", "Average per plan", "streak", "Notifications", "Coming soon"] {
            XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", gone)).count, 0, "\(gone) is still on Profile")
        }
    }

    @MainActor func testActivityNumbersStackAtAccessibilitySizes() {
        // AX3. Side by side, "Neighborhoods" would have to break mid-word.
        let app = launch(["-startTab", "profile", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        _ = header(in: app)
        let numbers = ["Plans completed", "Neighborhoods explored", "Places saved"].map { stat($0, in: app) }
        XCTAssertTrue(numbers[0].waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(numbers[0].frame.maxY, numbers[1].frame.minY + 0.5, "one under another")
        XCTAssertLessThanOrEqual(numbers[1].frame.maxY, numbers[2].frame.minY + 0.5, "one under another")
        XCTAssertEqual(Set(numbers.map { Int($0.frame.minX) }).count, 1, "stacked in one column")
    }

    @MainActor func testPreferenceRowsUseTheDraftsWords() {
        let app = launch(["-startTab", "profile"])
        _ = header(in: app)

        XCTAssertTrue(app.staticTexts["$60 per person"].exists, "default budget reads per person")
        XCTAssertTrue(app.staticTexts["Saving places from TikTok and Instagram"].exists)

        app.staticTexts["Preferred transportation"].tap()
        XCTAssertTrue(app.navigationBars["Preferred transportation"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()

        app.staticTexts["How it works"].tap()
        XCTAssertTrue(app.navigationBars["Save from TikTok and Instagram"].waitForExistence(timeout: 3))
    }

    @MainActor func testPastPlansAreInlineRowsThatDontOpen() {
        let app = launch(["-startTab", "profile"])
        _ = header(in: app)

        let rows = app.descendants(matching: .any).matching(identifier: "past-plan")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(app.buttons.matching(identifier: "past-plan").count, 0, "past plans aren't buttons")

        let crawl = rows.element(boundBy: 1)
        XCTAssertTrue(crawl.label.hasPrefix("Harlem food crawl, "), crawl.label)
        XCTAssertTrue(crawl.label.contains(" · 4 stops · $38 per person, fares included"), crawl.label)
        XCTAssertTrue(crawl.label.hasSuffix("$22 under budget"), crawl.label)
        XCTAssertFalse(rows.element(boundBy: 2).label.contains("under"), "1.0 plans without a budget show no mark")

        UITestScrolling.scrollIntoView(crawl, in: app)
        crawl.tap()
        XCTAssertTrue(app.staticTexts["Past plans"].exists, "tapping a past plan stays on Profile")
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists, "nothing was pushed")
    }

    @MainActor func testNoTabSaysComingSoon() {
        let app = launch(["-startTab", "today"])
        let bar = UITestScrolling.bar(in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        for tab in ["Today", "Saved", "Profile"] {
            bar.buttons[tab].tap()
            XCTAssertTrue(bar.buttons[tab].isSelected)
            let comingSoon = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'coming soon'"))
            XCTAssertEqual(comingSoon.count, 0, "\(tab) says Coming soon")
        }
    }

    @MainActor func testTappingTheHeaderEditsTheNameWhichSavesAsYouType() {
        let app = launch(["-startTab", "profile"])
        header(in: app).tap()

        let field = app.textFields["profile-name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Changes save as you type."].exists)

        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Sam")
        // No Done, no leaving the screen: quit while the keyboard is still up.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the store writes to disk")], timeout: 1.5)
        app.terminate()

        let relaunched = launch(["-startTab", "profile"], reset: false)
        XCTAssertTrue(header(in: relaunched).label.hasPrefix("Sam"), header(in: relaunched).label)
    }

    // MARK: - Account (PRO-3, W-5)

    @MainActor func testAccountSitsInProfileAndCancelLeavesItAlone() {
        let app = launch(["-startTab", "profile"])
        _ = header(in: app)

        let delete = app.buttons["delete-account"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        UITestScrolling.scrollIntoView(delete, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["account-signed-in"].label, "Signed in as test@plandit.local")
        XCTAssertTrue(app.buttons["sign-out"].exists)

        delete.tap()
        let title = app.staticTexts["Delete your account?"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["This permanently removes your account, saved places and plans."].exists)
        XCTAssertTrue(app.buttons["Delete account"].exists)

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "the dialog has a Cancel button")
        cancel.tap()

        XCTAssertTrue(title.waitForNonExistence(timeout: 3))
        XCTAssertTrue(delete.isHittable, "still signed in, still on Profile")
        XCTAssertEqual(app.descendants(matching: .any)["account-signed-in"].label, "Signed in as test@plandit.local")
    }

    @MainActor private func stat(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", name)).firstMatch
    }
}
