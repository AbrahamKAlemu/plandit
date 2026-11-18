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

    /// The gate's call when a session opens, with these debug launch arguments.
    @MainActor private func opens(_ userID: String = "user-1", isNewAccount: Bool, _ arguments: [String] = []) -> Bool {
        tutorial().decide(userID: userID, isNewAccount: isNewAccount, launch: TutorialLaunchOptions(arguments: ["Plandit"] + arguments))
    }

    // MARK: - Decision

    @MainActor func testBrandNewAccountSeesIt() {
        XCTAssertTrue(opens(isNewAccount: true))
    }

    @MainActor func testExistingAccountNeverSeesIt() {
        XCTAssertFalse(opens(isNewAccount: false), "including on a new phone, where nothing is recorded")
    }

    @MainActor func testFinishedNeverShowsAgainEvenForANewAccount() {
        tutorial().recordFinished(userID: "user-1")
        XCTAssertFalse(opens(isNewAccount: true))
    }

    @MainActor func testFinishingRecordsItSoARelaunchDoesNotRepeatIt() {
        XCTAssertTrue(opens(isNewAccount: true))
        tutorial().recordFinished(userID: "user-1")

        XCTAssertTrue(tutorial().hasFinished(userID: "user-1"))
        XCTAssertFalse(opens(isNewAccount: false))
        XCTAssertFalse(opens(isNewAccount: false, ["-skipAuth", "-showTutorial"]), "the UI test's relaunch")
    }

    @MainActor func testTheRecordIsPerUser() {
        tutorial().recordFinished(userID: "user-1")
        XCTAssertTrue(opens("user-2", isNewAccount: true), "another account on this phone still gets it")
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

    @MainActor func testShowTutorialForcesItForAnExistingAccount() {
        XCTAssertTrue(opens(isNewAccount: false, ["-skipAuth", "-showTutorial"]))
    }

    @MainActor func testResetTutorialClearsTheRecord() {
        tutorial().recordFinished(userID: "user-1")

        XCTAssertTrue(opens(isNewAccount: false, ["-skipAuth", "-resetTutorial", "-showTutorial"]))
        XCTAssertFalse(tutorial().hasFinished(userID: "user-1"))
    }

    @MainActor func testResetTutorialAloneDoesNotShowIt() {
        tutorial().recordFinished(userID: "user-1")

        XCTAssertFalse(opens(isNewAccount: false, ["-skipAuth", "-resetTutorial"]), "-skipAuth's account is not new")
        XCTAssertFalse(tutorial().hasFinished(userID: "user-1"))
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
