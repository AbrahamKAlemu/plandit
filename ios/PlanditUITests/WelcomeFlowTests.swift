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

        // W-4: on iPad the text and buttons stay a readable width, centered.
        let window = app.windows.firstMatch.frame
        for element in [continueWithEmail, app.buttons["sign-in-with-apple"], app.staticTexts["welcome-headline"]] {
            XCTAssertLessThanOrEqual(element.frame.width, 441, "\(element.identifier) is too wide")
        }
        XCTAssertEqual(continueWithEmail.frame.midX, window.midX, accuracy: 1, "buttons are centered")

        continueWithEmail.tap()
        let title = app.staticTexts["auth-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "Create your account")
        XCTAssertTrue(app.buttons["auth-submit"].exists)
        // W-3: the password rule shows only where it applies.
        XCTAssertTrue(app.staticTexts["At least 8 characters"].exists)

        app.buttons["Sign in"].firstMatch.tap()
        XCTAssertEqual(title.label, "Welcome back")
        XCTAssertFalse(app.staticTexts["At least 8 characters"].exists, "signing in has no password rule")
    }
}
