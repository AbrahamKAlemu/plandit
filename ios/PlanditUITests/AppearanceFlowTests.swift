import XCTest

@MainActor
final class AppearanceFlowTests: XCTestCase {
    func testSelectingDarkPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-startTab", "profile", "-startDetent", "large"]
        continueAfterFailure = false
        app.launch()
        openAppearance(in: app)

        let light = app.buttons["Light"]
        XCTAssertTrue(light.waitForExistence(timeout: 3))
        light.tap()
        XCTAssertTrue(light.isSelected)
        assertAppearance("Selected light, effective light", in: app)

        let dark = app.buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 3))
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        assertAppearance("Selected dark, effective dark", in: app)

        app.terminate()
        app.launch()
        openAppearance(in: app)

        XCTAssertTrue(app.buttons["Dark"].isSelected)
    }

    private func assertAppearance(_ expected: String, in app: XCUIApplication) {
        let screen = app.descendants(matching: .any)["appearance-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 3))

        let predicate = NSPredicate(format: "value == %@", expected)
        expectation(for: predicate, evaluatedWith: screen)
        waitForExpectations(timeout: 3)
    }

    private func openAppearance(in app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()

        let appearance = app.staticTexts["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.tap()

        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 3))
    }
}
