import XCTest

/// The gate without `-skipAuth`: a fresh install lands on Welcome. No network is needed to get there.
final class WelcomeFlowTests: XCTestCase {
    @MainActor func testWelcomeShowsWhenSignedOutAndLeadsToTheEmailForm() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-resetAuth"]
        app.launch()

        let continueWithEmail = app.buttons["continue-with-email"]
        XCTAssertTrue(continueWithEmail.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["welcome-headline"].label, "Turn the places you want to go into a real day.")
        XCTAssertTrue(app.buttons["sign-in-with-apple"].exists)
        XCTAssertFalse(app.buttons["plan-button"].exists, "the app itself stays behind the gate")

        continueWithEmail.tap()
        let title = app.staticTexts["auth-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "Create your account")
        XCTAssertTrue(app.buttons["auth-submit"].exists)

        app.buttons["Sign in"].firstMatch.tap()
        XCTAssertEqual(title.label, "Welcome back")
    }
}
