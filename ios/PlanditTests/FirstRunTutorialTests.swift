import XCTest
@testable import Plandit

/// D-1: a brand-new account sees the tutorial once on this phone; an account with data never does.
final class FirstRunTutorialTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FirstRunTutorialTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor private func tutorial() -> FirstRunTutorial {
        FirstRunTutorial(defaults: defaults)
    }

    // MARK: - Decision

    @MainActor func testBrandNewAccountSeesIt() {
        XCTAssertTrue(tutorial().shouldShow(userID: "user-1", isNewAccount: true))
    }

    @MainActor func testExistingAccountNeverSeesIt() {
        XCTAssertFalse(tutorial().shouldShow(userID: "user-1", isNewAccount: false), "including on a new phone, where nothing is recorded")
    }

    @MainActor func testFinishingRecordsItSoARelaunchDoesNotRepeatIt() {
        tutorial().recordFinished(userID: "user-1")

        let relaunched = tutorial()
        XCTAssertTrue(relaunched.hasFinished(userID: "user-1"))
        XCTAssertFalse(relaunched.shouldShow(userID: "user-1", isNewAccount: true))
    }

    @MainActor func testTheRecordIsPerUser() {
        tutorial().recordFinished(userID: "user-1")
        XCTAssertTrue(tutorial().shouldShow(userID: "user-2", isNewAccount: true), "another account on this phone still gets it")
        XCTAssertNotEqual(FirstRunTutorial.finishedKey(for: "user-1"), FirstRunTutorial.finishedKey(for: "user-2"))
        XCTAssertTrue(FirstRunTutorial.finishedKey(for: "user-1").contains("user-1"))
    }

    @MainActor func testForgetClearsTheRecordForThatUserOnly() {
        tutorial().recordFinished(userID: "user-1")
        tutorial().recordFinished(userID: "user-2")
        tutorial().forget(userID: "user-1")

        XCTAssertFalse(tutorial().hasFinished(userID: "user-1"))
        XCTAssertTrue(tutorial().hasFinished(userID: "user-2"))
    }

    // MARK: - Debug launch arguments

    func testSkipAuthAloneChangesNothing() {
        let options = TutorialLaunchOptions(arguments: ["Plandit", "-skipAuth"])
        XCTAssertFalse(options.countsAsNewAccount)
        XCTAssertFalse(options.resetsFinished)
    }

    func testShowTutorialCountsTheSessionAsNew() {
        let options = TutorialLaunchOptions(arguments: ["Plandit", "-skipAuth", "-showTutorial"])
        XCTAssertTrue(options.countsAsNewAccount)
        XCTAssertFalse(options.resetsFinished)
    }

    func testResetTutorialForgetsTheRecord() {
        let options = TutorialLaunchOptions(arguments: ["Plandit", "-skipAuth", "-resetTutorial", "-showTutorial"])
        XCTAssertTrue(options.countsAsNewAccount)
        XCTAssertTrue(options.resetsFinished)
    }

    // MARK: - Pages

    func testThreePagesInOrder() {
        XCTAssertEqual(TutorialPage.allCases.map(\.number), [1, 2, 3])
        XCTAssertEqual(TutorialPage.allCases.map(\.pageLabel), ["Page 1 of 3", "Page 2 of 3", "Page 3 of 3"])
        XCTAssertEqual(TutorialPage.share.next, .shape)
        XCTAssertEqual(TutorialPage.shape.next, .plan)
        XCTAssertNil(TutorialPage.plan.next, "Continue on the last page finishes")
    }
}
